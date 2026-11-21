#!/bin/sh
# Fragment guard for the experimental eBPF shared (LAN) data plane.
#
# Why this exists
# ---------------
# The shared hook intercepts LAN traffic at TC ingress, before netfilter, but
# its fragment handling passes *every* fragment of a fragmented datagram: the
# first fragment (MF set) and all later ones alike (fixed-source audit of the
# 732618a build).  Those packets reach the kernel, which routes them, and they
# leave directly on the cellular WAN.  Under the zero-rating rule that is a
# data leak, not a cosmetic bug -- and a single fragmented UDP flow can keep it
# up indefinitely.
#
# What the guard does
# -------------------
# A filter chain in `inet tf_sb_ebpf_guard` drops external fragments arriving
# on the interfaces the config actually hands to the shared plane, at a point
# where fragments still exist:
#
#   type filter hook prerouting priority raw - 150; policy accept;
#
# `raw` is -300 and ipv4_conntrack_defrag runs at -400, so -450 is before
# reassembly (and before TUN/eBPF redirects at mangle/-150).  A forward hook
# would be too late: nf_conntrack has already reassembled the datagram there.
#
# The chain verdicts nothing for whole traffic.  Destinations that must keep
# the kernel path return first, using exactly the confirmed local set from the
# generated config (`route_exclude_address`) plus loopback -- no broad
# RFC1918-adjacent widening:
#
#   10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 127.0.0.0/8
#   fd00:5252:0:1::/64 (LAN ULA), fe80::/10, ff00::/8, ::1/128
#
# LAN management (192.168.0.1 / fd00:5252:0:1::1), DHCP and NDP stay on the
# kernel path.  Deliberately NOT exempted: CGNAT 100.64.0.0/10, IPv4 multicast,
# and the whole fc00::/7 ULA range -- the fake-ip pool fdfe:dcba:9876::/64
# lives inside fc00::/7 and must stay subject to the guard.
# Only packets that are (a) fragments and (b) addressed outside those sets are
# dropped:
#
#   IPv4  ip frag-off & 0x3fff != 0   (MF set -> first fragment, or offset != 0)
#   IPv6  frag frag-off != 0 / frag more-fragments 1   (non-atomic fragments)
#
# A normal non-fragmented packet has frag-off 0x0000/0x4000 (DF) -> masked to 0,
# so it never matches.  IPv6 atomic fragments (fragment header, offset 0, M=0)
# are complete datagrams and keep flowing.
#
# Consequence worth knowing: the shared plane does not proxy fragments at all,
# so while it is active every public IPv4 fragment and every non-atomic IPv6
# fragment from a shared interface is dropped instead of leaked.  That is the
# intended fail-closed trade.  Atomic IPv6 fragments are the one class the
# contract keeps flowing (they are complete datagrams).
#
# Ownership
# ---------
# This script owns exactly one nftables table: inet tf_sb_ebpf_guard.  It never
# flushes, deletes or edits another table, and never touches TC attachments,
# cgroups, routes or sysctls.  `clear` removes the owned table and nothing else.
#
# Usage:
#   sh ebpf-fragment-guard.sh apply    # validate + install (idempotent, atomic)
#   sh ebpf-fragment-guard.sh clear    # delete the owned table only
#   sh ebpf-fragment-guard.sh status   # read-only report
#
# Exit codes:
#   apply   0 installed/already installed/not required, 1 fail-closed (no
#           partial ruleset is left behind), 2 bad usage
#   clear   0 removed/absent, 1 nft missing or delete failed
#   status  0 guard active and expected, 3 shared plane enabled but the guard
#           is absent or incomplete (missing hook priority, missing per-interface
#           fragment DROP, an extra interface, or a configured interface that
#           does not exist), 4 no shared plane (guard not required), 5 no shared
#           plane but the owned table is still installed (stale), 1 config
#           unparseable
#
# Env: SINGBOX_BASE (default /data/sing-box), SINGBOX_CONFIG, SINGBOX_STATE,
#      SINGBOX_SERVICE_API (default http://127.0.0.1:8088), NFT_BIN,
#      JSONFILTER_BIN.

set -u

BASE="${SINGBOX_BASE:-/data/sing-box}"
CONF="${SINGBOX_CONFIG:-$BASE/config.json}"
STATE="${SINGBOX_STATE:-$BASE/state}"
LOG="${SINGBOX_FRAGGUARD_LOG:-$STATE/ebpf-fragment-guard.log}"
SPEC="$STATE/ebpf-fragment-guard.nft"
API_URL="${SINGBOX_SERVICE_API:-http://127.0.0.1:8088}"
NFT="${NFT_BIN:-nft}"
JSONFILTER="${JSONFILTER_BIN:-jsonfilter}"

TABLE="tf_sb_ebpf_guard"
CHAIN="pre"
# nft accepts "name +/- integer" for a hook priority (man nftables, HOOK
# SPECIFICATION).  -450 = raw - 150: pre-defrag, post-TC-ingress.
PRIO="raw - 150"
# Confirmed local/management destinations only: the generated
# route_exclude_address list plus loopback.  See the header for what is
# deliberately absent (CGNAT, IPv4 multicast, fc00::/7 as a whole).
PRIVATE4="10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16"
PRIVATE6="::1/128, fd00:5252:0:1::/64, fe80::/10, ff00::/8"
# Index probe bound.  A config with more inbounds than this is refused rather
# than partially inspected: missing an eBPF inbound would silently skip the
# guard, so the only safe answer outside the window is failure.
MAX_INBOUNDS=64

log() {
    mkdir -p "$STATE" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null || true
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 131072 ]; then
        tail -c 65536 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

fail() {
    echo "ebpf-fragment-guard: $*" >&2
    log "FAIL: $*"
    exit 1
}

jf() { "$JSONFILTER" -i "$CONF" -e "$1" 2>/dev/null; }

# A config counts as parsed only when a mandatory array yields a value: an empty
# result could otherwise mean "no shared plane" and silently skip the guard.
config_ok() {
    [ -f "$CONF" ] || return 1
    have "$JSONFILTER" || return 1
    _out=$(jf '@.outbounds[0].type') || return 1
    [ -n "$_out" ]
}

# Index of the eBPF inbound in @.inbounds.  rc 0 = index, 1 = no eBPF inbound,
# 2 = config cannot be enumerated.  The array query is the only parse signal:
# device jsonfilter exits 1 both for an out-of-range index and for a missing
# optional field.
ebpf_index() {
    config_ok || return 2
    _types=$(jf '@.inbounds[*].type') || return 2
    [ -n "$_types" ] || return 2
    _cnt=$(printf '%s\n' "$_types" | grep -c .)
    [ "$_cnt" -le "$MAX_INBOUNDS" ] || return 2
    _i=0
    while [ "$_i" -lt "$_cnt" ]; do
        if [ "$(printf '%s\n' "$_types" | sed -n "$((_i + 1))p")" = ebpf ]; then
            echo "$_i"
            return 0
        fi
        _i=$((_i + 1))
    done
    return 1
}

# One field of the eBPF inbound; empty output means the field is absent.
field() { # field <index> <path>
    jf "@.inbounds[$1].$2" | tr -d '"'
}

# One line per enabled shared block: "<data_plane> <iface[,iface...]>".
# Exit 1 when the config cannot be verified (caller must fail closed).
shared_planes() {
    config_ok || return 1
    _i=$(ebpf_index)
    case $? in
    0) ;;
    # No eBPF inbound at all: nothing to guard (a TUN/plain config).
    1) return 0 ;;
    *) return 1 ;;
    esac
    [ "$(field "$_i" shared.enabled)" = true ] || return 0
    _dp=$(field "$_i" shared.data_plane)
    [ -n "$_dp" ] || _dp=unset
    _ifs=$(field "$_i" 'shared.interface[*]' |
        awk 'NF { printf "%s%s", sep, $1; sep="," }')
    [ -n "$_ifs" ] || _ifs=none
    echo "$_dp $_ifs"
}

# "ebpf" | "tun" from the config.  Exit 1 (unknown) when it cannot be enumerated.
inbound_kind() {
    _i=$(ebpf_index)
    case $? in
    0) echo ebpf ;;
    1) echo tun ;;
    *) return 1 ;;
    esac
}

# "<data_plane>" for the enabled local hook (display only: the guard protects
# the shared plane, but status must not claim cgroup while the config says
# socket_assign).  Exit 1 when the plane cannot be enumerated.
local_plane() {
    _i=$(ebpf_index) || return 1
    [ "$(field "$_i" local.enabled)" = true ] || return 1
    _dp=$(field "$_i" local.data_plane)
    echo "${_dp:-unset}"
}

# The live chain must carry the pre-defrag hook and every rule kind this
# script installs.  An externally flushed chain has none of them and must not
# read as "already applied".
#
# The priority is compared by value, not by "contains -450": raw - 150 and
# -450 are the same hook position (nft prints whichever spelling the ruleset
# used), and anything else is before reassembly only by accident.  A guard at
# the wrong priority drops nothing a forwarded fragment would see.
hook_priority() {
    "$NFT" list chain inet "$TABLE" "$CHAIN" 2>/dev/null |
        sed -n 's/.*hook prerouting priority \([^;]*\);.*/\1/p' | sed -n '1p'
}

table_active() {
    have "$NFT" || return 1
    _out=$("$NFT" list chain inet "$TABLE" "$CHAIN" 2>/dev/null) || return 1
    _prio=$(printf '%s\n' "$_out" | sed -n 's/.*hook prerouting priority \([^;]*\);.*/\1/p' | sed -n '1p')
    case "$_prio" in
        -450 | "raw - 150") ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$_out" | grep -q 'ip frag-off' || return 1
    printf '%s\n' "$_out" | grep -q 'frag frag-off' || return 1
    printf '%s\n' "$_out" | grep -q 'frag more-fragments' || return 1
    return 0
}

# True when the live chain covers exactly the configured interfaces: the
# iifname set is identical (no extra, no missing) and each interface carries
# one IPv4, one IPv6 offset and one IPv6 more-fragments DROP.
chain_matches() { # chain_matches <iface>...
    _out=$("$NFT" list chain inet "$TABLE" "$CHAIN" 2>/dev/null) || return 1
    _seen_ifs=$(printf '%s\n' "$_out" | sed -n 's/.*iifname "\([^"]*\)".*/\1/p' | sed '/^$/d' | sort -u)
    _want_ifs=$(printf '%s\n' "$@" | sed '/^$/d' | sort -u)
    [ -n "$_want_ifs" ] || return 1
    [ "$_seen_ifs" = "$_want_ifs" ] || return 1
    _want_sp=$(printf '%s\n' "$_want_ifs" | tr '\n' ' ' | sed 's/ *$//')
    printf '%s\n' "$_out" | awk -v expected="$_want_sp" '
        BEGIN { n=split(expected, interfaces, " ") }
        /counter.*drop/ { total++ }
        {
            for (i=1; i<=n; i++) {
                if (index($0, "iifname \"" interfaces[i] "\"") == 0) continue
                if ($0 ~ /ip frag-off/ && $0 ~ /drop/) v4[i]++
                if ($0 ~ /frag frag-off/ && $0 ~ /drop/) v6off[i]++
                if ($0 ~ /frag more-fragments/ && $0 ~ /drop/) v6more[i]++
            }
        }
        END {
            if (total != n*3) exit 1
            for (i=1; i<=n; i++)
                if (v4[i] != 1 || v6off[i] != 1 || v6more[i] != 1) exit 1
        }'
}

# Remove only the table this script owns.  Returns 0 when it is gone.
delete_owned_table() {
    have "$NFT" || return 1
    "$NFT" delete table inet "$TABLE" 2>/dev/null || true
    rm -f "$SPEC" "$SPEC.new"
    ! "$NFT" list table inet "$TABLE" >/dev/null 2>&1
}

build_spec() { # build_spec <outfile> <iface>...
    _out=$1
    shift
    {
        echo "add table inet $TABLE"
        echo "flush table inet $TABLE"
        echo "add chain inet $TABLE $CHAIN {"
        echo "    type filter hook prerouting priority $PRIO; policy accept;"
        echo "}"
        for _if in "$@"; do
            # Keep the kernel path for everything that is not a public
            # destination (management, DNS, NDP/MLD, LAN-to-LAN).
            echo "add rule inet $TABLE $CHAIN iifname \"$_if\" ip daddr { $PRIVATE4 } counter return"
            echo "add rule inet $TABLE $CHAIN iifname \"$_if\" ip6 daddr { $PRIVATE6 } counter return"
            # The shared hook passes every fragment (first-MF included), so no
            # fragment may be forwarded outside the proxied path.
            echo "add rule inet $TABLE $CHAIN iifname \"$_if\" ip frag-off & 0x3fff != 0 counter drop"
            echo "add rule inet $TABLE $CHAIN iifname \"$_if\" frag frag-off != 0 counter drop"
            echo "add rule inet $TABLE $CHAIN iifname \"$_if\" frag more-fragments 1 counter drop"
        done
    } > "$_out"
}

cmd_apply() {
    have "$NFT" || fail "nft not found; refusing to start the shared plane without a fragment guard"
    config_ok || fail "cannot parse $CONF (jsonfilter missing or invalid JSON); refusing to guess the shared interface set"

    _planes=$(shared_planes) || fail "shared plane detection failed on $CONF; refusing to install a guard for an unknown scope"

    if [ -z "$_planes" ]; then
        delete_owned_table || fail "could not remove stale inet $TABLE"
        echo "no enabled shared plane in $CONF; fragment guard not required"
        log "not required (no enabled shared plane)"
        return 0
    fi

    _ifs=$(printf '%s\n' "$_planes" | awk '{print $2}' | tr ',' '\n' | sed '/^$/d' | sort -u)
    [ -n "$_ifs" ] || fail "shared block carries no interface; cannot scope the guard"

    _n=0
    for _if in $_ifs; do
        case "$_if" in
            *[!A-Za-z0-9_.:-]*) fail "refusing interface name '$_if' (unexpected characters)" ;;
        esac
        ip link show dev "$_if" >/dev/null 2>&1 ||
            fail "shared interface '$_if' is absent; a guard that cannot match is not a guard"
        _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ] || fail "no shared interface resolved from $CONF"

    mkdir -p "$STATE" 2>/dev/null || fail "cannot create $STATE"
    build_spec "$SPEC.new" $_ifs

    # Idempotent path first: identical ruleset, live hook and exactly the
    # configured interfaces -> leave the running ruleset and its counters
    # alone (this runs on every watchdog restart, so it must not depend on a
    # successful re-validation).
    if cmp -s "$SPEC.new" "$SPEC" && table_active && chain_matches $_ifs; then
        rm -f "$SPEC.new"
        echo "fragment guard already applied (inet $TABLE)"
        return 0
    fi

    # Validate the exact ruleset before touching the live one.  A parser or
    # kernel capability gap has to stop the shared eBPF start, never degrade
    # into "some rules were skipped".  On failure the previously active guard
    # (if any) stays in place: this is a replacement, not a rollback.
    if ! "$NFT" -c -f "$SPEC.new" >/dev/null 2>"$STATE/ebpf-fragment-guard.check"; then
        _err=$(tr '\n' ' ' < "$STATE/ebpf-fragment-guard.check" 2>/dev/null)
        rm -f "$SPEC.new"
        fail "nft check failed: ${_err:-unknown error} (previous guard left untouched)"
    fi

    # nft -f applies the whole batch as one transaction, so a failed replace
    # leaves the running ruleset (and its counters) intact.
    if ! "$NFT" -f "$SPEC.new" 2>"$STATE/ebpf-fragment-guard.err"; then
        _err=$(tr '\n' ' ' < "$STATE/ebpf-fragment-guard.err" 2>/dev/null)
        rm -f "$SPEC.new"
        fail "nft load failed: ${_err:-unknown error} (previous guard left untouched)"
    fi
    mv "$SPEC.new" "$SPEC"

    if ! table_active; then
        delete_owned_table >/dev/null 2>&1 || true
        fail "guard hook missing after load; owned table removed, shared plane stays unprotected"
    fi

    _planefmt=$(printf '%s\n' "$_planes" | tr '\n' ' ' | sed 's/ *$//')
    echo "fragment guard installed: inet $TABLE ($_planefmt)"
    log "installed: $_planefmt"
}

cmd_clear() {
    have "$NFT" || fail "nft not found; cannot remove inet $TABLE"
    if "$NFT" list table inet "$TABLE" >/dev/null 2>&1; then
        "$NFT" delete table inet "$TABLE" || fail "nft delete table inet $TABLE failed"
        echo "removed inet $TABLE"
        log "cleared inet $TABLE"
    else
        echo "inet $TABLE not present"
    fi
    rm -f "$SPEC" "$SPEC.new"
    if "$NFT" list table inet "$TABLE" >/dev/null 2>&1; then
        fail "inet $TABLE still present after delete"
    fi
    return 0
}

cmd_status() {
    _want=0
    _active=0
    _state=ok
    _kind=$(inbound_kind 2>/dev/null) || _kind=unknown
    _loc=unknown

    echo "== eBPF shared plane =="
    if ! config_ok; then
        _state=unparseable
        echo "config:   UNPARSEABLE ($CONF; jsonfilter missing or invalid JSON)"
    elif [ "$_kind" = tun ]; then
        _state=tun
        echo "config:   no eBPF inbound (TUN/plain config; guard not required)"
    else
        _loc=$(local_plane 2>/dev/null) || _loc=unknown
        [ -n "$_loc" ] || _loc=unset
        echo "local:    $_loc"
        _planes=$(shared_planes) || _state=unparseable
        if [ "$_state" = ok ] && [ -z "$_planes" ]; then
            echo "plane:    none (shared disabled; local ${_loc} only)"
        elif [ "$_state" = ok ]; then
            _want=1
            printf '%s\n' "$_planes" | while read -r _dp _ifs; do
                echo "plane:    $_dp  interfaces: $_ifs"
            done
        else
            echo "plane:    UNKNOWN (shared plane could not be enumerated)"
        fi
    fi

    # Configured interfaces must exist: a guard scoped to an absent device
    # matches nothing, so the plane would be live and unprotected.
    _status_ifs=$(printf '%s\n' "${_planes:-}" | awk '{print $2}' | tr ',' '\n' | sed '/^$/d' | sort -u)
    _absent_ifs=
    for _if in $_status_ifs; do
        ip link show dev "$_if" >/dev/null 2>&1 || _absent_ifs="$_absent_ifs $_if"
    done

    if ! have "$NFT"; then
        echo "guard:    UNKNOWN (nft not found)"
        _state=nft-missing
    elif table_active; then
        if [ -n "$_absent_ifs" ]; then
            echo "guard:    INCOMPLETE (configured interface(s) absent:${_absent_ifs})"
            return 3
        fi
        if [ "$_want" -eq 1 ] && ! chain_matches $_status_ifs; then
            echo "guard:    INCOMPLETE (configured interfaces lack the three fragment DROP rules)"
            return 3
        fi
        _active=1
        echo "guard:    active (inet $TABLE, hook prerouting priority $PRIO)"
        "$NFT" list chain inet "$TABLE" "$CHAIN" 2>/dev/null | sed 's/^/          /'
    elif "$NFT" list table inet "$TABLE" >/dev/null 2>&1; then
        # The table exists but the chain is not the pre-defrag hook this script
        # installs (wrong priority, flushed rules).  With a shared plane that is
        # an unprotected live plane, not "not installed".
        _prio_found=$(hook_priority)
        if [ "$_want" -eq 1 ]; then
            echo "guard:    INCOMPLETE (inet $TABLE present but no valid pre-defrag hook: priority=${_prio_found:-missing})"
            return 3
        fi
        _active=1
        echo "guard:    installed without a valid pre-defrag hook (priority=${_prio_found:-missing})"
    else
        echo "guard:    not installed"
    fi

    # Attachment evidence is the gRPC service API, not a capability probe.
    echo "diag:     $API_URL (services.api; gRPC -- the 9999 Clash controller is not this endpoint)"
    echo "attach:   $BASE/sing-box api ebpf --url $API_URL --deep"
    echo "note:     ebpf-probe.sh probes kernel capability; it is not attachment proof"

    case "$_state" in
        unparseable) return 1 ;;
    esac
    if [ "$_want" -eq 1 ]; then
        [ "$_active" -eq 1 ] && return 0
        return 3
    fi
    if [ "$_active" -eq 1 ]; then
        echo "warn:     shared plane disabled but inet $TABLE is still installed"
        return 5
    fi
    return 4
}

case "${1:-}" in
    apply) cmd_apply ;;
    clear) cmd_clear ;;
    status) cmd_status ;;
    *) echo "usage: $0 {apply|clear|status}" >&2; exit 2 ;;
esac
