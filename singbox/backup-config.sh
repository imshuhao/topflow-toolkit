#!/bin/sh
# Phase-tagged, md5-verified config backups for /data/sing-box.
#
#   sh backup-config.sh save <phase|auto>    # snapshot the CURRENT config.json
#   sh backup-config.sh import <phase> <file># adopt an existing backup file
#   sh backup-config.sh list                 # every backup, newest last
#   sh backup-config.sh verify <phase|file>  # md5 check only (no traffic change)
#   sh backup-config.sh restore <phase|file> [--force] [--proxy-check] [--no-verify]
#   sh backup-config.sh rescue               # newest of tun -> phase0-observability -> original
#   sh backup-config.sh prune                # enforce retention on every phase
#
# Phases used by the eBPF migration:
#   original              pre-observability TUN config (last resort)
#   phase0-observability  TUN + experimental.observability
#   phase1-ebpf-local     eBPF local hook only, either local plane (no TUN,
#                         LAN direct)
#   phase2-ebpf-shared    eBPF local + shared hook, either shared plane (LAN
#                         captured)
#   tun                   production TUN all-proxy (current known-good)
#   pre-restore           safety copy written by restore before it swaps a file
#   manual                anything an operator pins by hand
#
# Plane handling is deliberately neutral: cgroup|socket_assign on the local hook
# and packet_rewrite|socket_assign on the shared hook are all valid here, and no
# check below prefers one of them.  Phase detection keys off shared.enabled
# only, so an A/B candidate classifies exactly like its control.
#
# Layout (all under $SINGBOX_BASE, default /data/sing-box):
#   config.json.bak-<phase>-<UTC>       immutable copy
#   config.json.bak-<phase>-<UTC>.md5   sidecar: "<md5>  <basename>"
#   config.json.bak-<phase>             hardlink to the newest copy of that phase
#   state/backup-index.tsv              utc, phase, md5, bytes, basename
#
# Guarantees:
#   * save is idempotent: same phase + same md5 -> no new file, exit 0.
#   * restore is idempotent: already on that md5 and API healthy -> no restart.
#   * restore verifies md5 before the swap, atomically renames, runs
#     `sing-box check`, and puts the pre-restore config back if the check fails.
#   * restore never steps down to a local-only phase automatically: phase2 and
#     phase1 both fail forward to `tun`.  `restore phase1-ebpf-local` stays
#     available on explicit request for the LAN-disconnected diagnostic window.
#   * a config that already matches the target md5 is only a no-op when the
#     RUNNING core matches the restored mode and mark; otherwise the same
#     config is restarted once and re-verified.
#   * retention keeps the newest $SINGBOX_BACKUP_KEEP (default 5) per phase.
#
# Env overrides (testing / maintenance): SINGBOX_BASE, SINGBOX_CONFIG,
# SINGBOX_STATE, SINGBOX_BACKUP_KEEP, SINGBOX_SERVICE, SINGBOX_BIN,
# SINGBOX_NO_RESTART=1 (skip restart), SINGBOX_API_WAIT=<seconds>.
set -u

BASE="${SINGBOX_BASE:-/data/sing-box}"
CONF="${SINGBOX_CONFIG:-$BASE/config.json}"
STATE="${SINGBOX_STATE:-$BASE/state}"
INDEX="$STATE/backup-index.tsv"
SERVICE="${SINGBOX_SERVICE:-$BASE/sing-box.sh}"
BIN="${SINGBOX_BIN:-$BASE/sing-box}"
BALANCE="${SINGBOX_WANBAL:-$BASE/singbox-wan-balance.sh}"
KEEP="${SINGBOX_BACKUP_KEEP:-5}"
NOW="${SINGBOX_NOW:-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo 19700101T000000Z)}"

T0=0
_safe=

die() { echo "error: $*" >&2; exit 2; }

usage() {
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

phase_ok() {
    case "${1:-}" in
        ''|*[!a-z0-9-]*) return 1 ;;
    esac
    return 0
}

md5_of() { md5sum "$1" 2>/dev/null | awk 'NR == 1 {print $1}' | sed 's/^\\//'; }
size_of() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

# Structured readers: jq on the workstation, jsonfilter on the device.  The
# fallback is only for phase detection; restore still gates on `sing-box
# check`, so a misclassified malformed file cannot be started.
default_mark_of() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.route.default_mark // empty' "$1" 2>/dev/null | tr -d '\r'
    elif command -v jsonfilter >/dev/null 2>&1; then
        jsonfilter -i "$1" -e '@.route.default_mark' 2>/dev/null | tr -d '\r'
    else
        sed -n 's/.*"default_mark"[[:space:]]*:[[:space:]]*\(0[xX][0-9a-fA-F]*\|[0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -n 1
    fi
}

mark_is_8228() {
    case "${1:-}" in
        8228 | 0x2024 | 0X2024) return 0 ;;
    esac
    return 1
}

ebpf_shared_enabled() { # shared counts only when its enabled flag is true
    _f="$1"
    if command -v jq >/dev/null 2>&1; then
        _v=$(jq -r '[.inbounds[]? | select(.type == "ebpf") | .shared.enabled] | any' "$_f" 2>/dev/null)
        [ "$_v" = true ]
    elif command -v jsonfilter >/dev/null 2>&1; then
        jsonfilter -i "$_f" -e '@.inbounds[*].shared.enabled' 2>/dev/null | grep -qx true
    else
        awk '
            /"shared"[[:space:]]*:[[:space:]]*\{/ { on = 1 }
            on && /"enabled"[[:space:]]*:[[:space:]]*true/ { found = 1; exit }
            on && /^[[:space:]]*\}/ { exit }
            END { exit(found ? 0 : 1) }
        ' "$_f" 2>/dev/null
    fi
}

# tun | phase0-observability -> tun stack; ebpf without shared -> phase1;
# ebpf with shared.enabled=true -> phase2.  A shared block that is disabled
# (the old diagnostic downgrade) must not be mistaken for phase 2.
detect_phase() {
    _f="${1:-$CONF}"
    if [ -f "$_f" ] && grep -q '"type": *"ebpf"' "$_f" 2>/dev/null; then
        if ebpf_shared_enabled "$_f"; then
            echo phase2-ebpf-shared
        else
            echo phase1-ebpf-local
        fi
    else
        echo tun
    fi
}

# Newest timestamped copy of one phase (aliases are not matched).
# Newest timestamped copy of one phase.  The timestamp shape is matched
# explicitly: a bare "<phase>-*" glob also catches phases that merely start with
# the same word (config.json.bak-tun-zero4-...), and "restore tun" then silently
# lands on a stale config instead of the newest tun snapshot.
latest_for_phase() {
    ls -1 "$CONF.bak-$1"-* 2>/dev/null | grep -v '\.md5$' |
        grep -E -- "\.bak-$1-[0-9]{8}T[0-9]{6}Z$" | sort | tail -n 1
}

resolve_target() {
    _want="$1"
    # Alias path (config.json.bak-<phase>, no timestamp) -> newest verified copy.
    _b=$(basename "$_want")
    _cb=$(basename "$CONF")
    case "$_b" in
        "$_cb.bak-"*)
            _ap=${_b#"$_cb.bak-"}
            if phase_ok "$_ap"; then
                _l=$(latest_for_phase "$_ap")
                [ -n "$_l" ] && { echo "$_l"; return 0; }
            fi
            ;;
    esac
    [ -f "$_want" ] && { echo "$_want"; return 0; }
    phase_ok "$_want" || return 1
    # Prefer the timestamped copy: it carries the md5 sidecar/INDEX entry.
    _l=$(latest_for_phase "$_want")
    [ -n "$_l" ] && { echo "$_l"; return 0; }
    [ -f "$CONF.bak-$_want" ] && { echo "$CONF.bak-$_want"; return 0; }
    return 1
}

index_lookup() {
    [ -f "$INDEX" ] || return 1
    awk -F "$(printf '\t')" -v b="$1" '$5 == b { v = $3 } END { if (v != "") print v; else exit 1 }' "$INDEX"
}

expected_md5() {
    _side="$1.md5"
    if [ -f "$_side" ]; then
        awk '{print $1; exit}' "$_side"
        return 0
    fi
    index_lookup "$(basename "$1")"
}

index_add() {
    mkdir -p "$STATE" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$INDEX" 2>/dev/null || true
}

# Stable alias so the documented `cp config.json.bak-tun config.json` works.
pin() {
    ln -f "$1" "$CONF.bak-$2" 2>/dev/null || cp -p "$1" "$CONF.bak-$2" 2>/dev/null || true
}

prune_phase() {
    _p="$1"
    # Same strict shape as latest_for_phase: a phase named "tun" must not prune
    # (or count) the copies of unrelated "tun-zero*" phases, or real tun
    # snapshots get evicted by files this phase never wrote.
    _list=$(ls -1 "$CONF.bak-$_p"-* 2>/dev/null | grep -v '\.md5$' |
        grep -E -- "\.bak-$_p-[0-9]{8}T[0-9]{6}Z$" | sort)
    [ -n "$_list" ] || return 0
    _n=$(printf '%s\n' "$_list" | grep -c .)
    _excess=$((_n - KEEP))
    [ "$_excess" -gt 0 ] || return 0
    printf '%s\n' "$_list" | head -n "$_excess" | while IFS= read -r _f; do
        rm -f "$_f" "$_f.md5"
        echo "pruned: $(basename "$_f")"
    done
}

do_prune() {
    _phases="original phase0-observability phase1-ebpf-local phase2-ebpf-shared tun pre-restore manual"
    if [ -f "$INDEX" ]; then
        _phases="$_phases $(awk -F '\t' 'NF >= 5 {print $2}' "$INDEX" | sort -u | tr '\n' ' ')"
    fi
    for _p in $_phases; do
        phase_ok "$_p" && prune_phase "$_p"
    done
    return 0
}

store_phase() {
    _phase="$1"
    _src="$2"
    phase_ok "$_phase" || die "invalid phase '$_phase' (use auto or [a-z0-9-]+)"
    [ -f "$_src" ] || die "missing $_src"
    mkdir -p "$STATE" || die "cannot create $STATE"
    case "$KEEP" in ''|*[!0-9]*) KEEP=5 ;; esac
    [ "$KEEP" -ge 1 ] || KEEP=1

    _md5=$(md5_of "$_src")
    case "$_md5" in ''|*[!0-9a-f]*) die "md5sum failed for $_src" ;; esac
    _bytes=$(size_of "$_src")

    _newest=$(latest_for_phase "$_phase")
    if [ -n "$_newest" ] && [ "$(md5_of "$_newest")" = "$_md5" ]; then
        _nexp=$(expected_md5 "$_newest") || true
        if [ "${_nexp:-$_md5}" = "$_md5" ] && [ "${SINGBOX_BACKUP_FORCE:-0}" != 1 ]; then
            pin "$_newest" "$_phase"
            echo "unchanged: $(basename "$_newest") already holds $_md5"
            return 0
        fi
        [ "${SINGBOX_BACKUP_FORCE:-0}" = 1 ] ||
            echo "WARN: newest copy of $_phase has no/bad md5 record; storing a fresh copy"
    fi

    _file="$CONF.bak-$_phase-$NOW"
    _i=1
    while [ -e "$_file" ]; do
        _file="$CONF.bak-$_phase-$NOW-$_i"
        _i=$((_i + 1))
    done
    cp -p "$_src" "$_file" || die "copy to $_file failed"
    _copied=$(md5_of "$_file")
    if [ "$_copied" != "$_md5" ]; then
        rm -f "$_file"
        die "backup copy corrupted (expected $_md5, got $_copied)"
    fi
    ( cd "$(dirname "$_file")" && md5sum "$(basename "$_file")" > "$(basename "$_file").md5" ) ||
        die "cannot write sidecar for $_file"
    index_add "$NOW" "$_phase" "$_md5" "$_bytes" "$(basename "$_file")"
    pin "$_file" "$_phase"
    prune_phase "$_phase"
    echo "saved: $_file ($_md5, $_bytes B)"
}

do_save() {
    _phase="${1:-auto}"
    [ "$_phase" = auto ] && _phase=$(detect_phase "$CONF")
    store_phase "$_phase" "$CONF"
}

# Adopt an existing (historical/ad-hoc) backup file into the phase index.
do_import() {
    _phase="${1:-}"
    _src="${2:-}"
    [ -n "$_phase" ] && [ -n "$_src" ] || die "import needs <phase> <file>"
    store_phase "$_phase" "$_src"
}

do_list() {
    echo "== backups (oldest first) =="
    ls -1 "$CONF".bak-* 2>/dev/null | grep -v '\.md5$' | sort |
    while IFS= read -r _f; do
        case "$(basename "$_f")" in
            *-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z*) _kind=copy ;;
            *) _kind="alias" ;;
        esac
        printf '%s  %9s B  %-8s %s\n' "$(md5_of "$_f")" "$(size_of "$_f")" "$_kind" "$(basename "$_f")"
    done
    echo
    echo "phase of current $CONF: $(detect_phase "$CONF")"
    echo "retention: $KEEP per phase; index: $INDEX"
}

do_verify() {
    _want="${1:-}"
    [ -n "$_want" ] || die "verify needs a phase or file"
    _f=$(resolve_target "$_want") || die "no backup for '$_want' (try: sh $0 list)"
    _m=$(md5_of "$_f")
    _e=$(expected_md5 "$_f") || true
    if [ -z "${_e:-}" ]; then
        echo "UNVERIFIED: $(basename "$_f") has no sidecar/index entry"
        return 3
    fi
    if [ "$_m" != "$_e" ]; then
        echo "FAIL: $(basename "$_f") expected $_e got $_m"
        return 3
    fi
    echo "OK: $(basename "$_f") $_m"
    return 0
}

wait_api() {
    _i=0
    _max="${SINGBOX_API_WAIT:-12}"
    while [ "$_i" -lt "$_max" ]; do
        if [ "$(curl -s -o /dev/null -w '%{http_code}' -m 1 http://127.0.0.1:9999/version 2>/dev/null)" = 200 ]; then
            return 0
        fi
        sleep 1
        _i=$((_i + 1))
    done
    return 1
}

fail_count=0
check_fail() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }
check_pass() { echo "PASS: $*"; }
check_warn() { echo "WARN: $*"; }

verify_runtime() {
    _mode="$1"
    if ! wait_api; then
        check_fail "clash_api did not answer on 127.0.0.1:9999"
        return 1
    fi
    check_pass "clash_api 200 ($(curl -s -m 2 http://127.0.0.1:9999/version 2>/dev/null | head -1))"

    # The file on disk and the phase requested must agree before judging the
    # running core; phase0 is a TUN config with observability.
    _actual=$(detect_phase "$CONF")
    _want="$_mode"
    case "$_actual" in phase0-observability) _actual=tun ;; esac
    case "$_want" in phase0-observability) _want=tun ;; esac
    if [ "$_actual" = "$_want" ]; then
        check_pass "restored config classifies as $_mode"
    else
        check_fail "restored config classifies as $_actual, expected $_mode"
    fi

    _dm=$(default_mark_of "$CONF")
    case "$_mode" in
        phase1-ebpf-local|phase2-ebpf-shared)
            if [ -z "$_dm" ]; then
                check_fail "eBPF config has no route.default_mark (nothing stamps 0x2024)"
            elif mark_is_8228 "$_dm"; then
                check_pass "route.default_mark=$_dm (0x2024)"
            else
                check_fail "route.default_mark=$_dm (contract: 8228 / 0x2024)"
            fi
            if ip link show sbtun0 >/dev/null 2>&1; then
                check_fail "stale sbtun0 present while running an eBPF config (two capture paths)"
            else
                check_pass "no sbtun0 (expected for eBPF)"
            fi
            ;;
        *)
            if [ -n "$_dm" ]; then
                check_fail "TUN config carries route.default_mark=$_dm (conflicts with tun.auto_redirect)"
            else
                check_pass "no route.default_mark (TUN auto_route supplies the mark)"
            fi
            if ip link show sbtun0 >/dev/null 2>&1; then
                check_pass "sbtun0 present"
            else
                check_fail "sbtun0 missing on a TUN config"
            fi
            ;;
    esac

    if [ "$_mode" = phase1-ebpf-local ]; then
        check_warn "phase1 captures this device only: LAN clients egress direct (no shared hook) -- diagnostic window, not production"
    fi
    if [ "$_mode" = phase2-ebpf-shared ]; then
        # Same completeness gate as verify-ebpf.sh: an installed-but-flushed
        # table is not protection, and the guard is authoritative for
        # priority/interfaces.  Plane-agnostic: it never names a data plane.
        _guard="${SINGBOX_FRAGGUARD:-$BASE/ebpf-fragment-guard.sh}"
        if ! command -v nft >/dev/null 2>&1; then
            check_warn "nft missing; fragment guard not verified"
        elif [ ! -x "$_guard" ]; then
            check_fail "shared eBPF config but $_guard is missing"
        else
            _gout=$(sh "$_guard" status 2>&1)
            _grc=$?
            case "$_grc" in
                0) check_pass "fragment guard complete (inet tf_sb_ebpf_guard, pre-defrag hook, per-interface fragment drops)" ;;
                3) check_fail "fragment guard INCOMPLETE: $(printf '%s\n' "$_gout" | sed -n 's/^guard: *//p' | sed -n '1p')" ;;
                *) check_fail "fragment guard status failed: $(printf '%s\n' "$_gout" | sed -n '1p')" ;;
            esac
        fi
    fi

    _dhcp=$(uci -q get dhcp.lan.dhcp_option 2>/dev/null || true)
    case " $_dhcp " in
        *"3,192.168.0.1"*) check_pass "DHCP option 3 -> 192.168.0.1" ;;
        *) check_fail "DHCP option 3 does not point at 192.168.0.1 (got: ${_dhcp:-none})" ;;
    esac

    if [ -x "$BALANCE" ]; then
        _bal=$("$BALANCE" status 2>/dev/null || true)
        _src=$(printf '%s\n' "$_bal" | sed -n 's/.*(source: \([a-z]*\)).*/\1/p' | head -1)
        _markline=$(printf '%s\n' "$_bal" | sed -n '/^== bypass mark/ { n; p; }' | head -1)
        _mark=${_markline%% *}
        case "$_mode" in
            phase1-ebpf-local|phase2-ebpf-shared)
                if [ "$_src" != default ]; then
                    check_fail "eBPF needs wan-balance mark source:default, got '${_src:-unknown}' (no TUN rule stamps the mark)"
                elif ! mark_is_8228 "$_mark"; then
                    check_fail "wan-balance mark value '${_mark:-?}' is not 0x2024"
                else
                    check_pass "wan-balance mark source:default ($_mark = route.default_mark 8228)"
                fi
                ;;
            *)
                if [ "$_src" != rule ]; then
                    check_fail "TUN needs wan-balance mark source:rule, got '${_src:-unknown}'"
                elif ! mark_is_8228 "$_mark"; then
                    check_fail "wan-balance mark value '${_mark:-?}' is not 0x2024"
                else
                    check_pass "wan-balance mark source:rule ($_mark from tun.auto_route)"
                fi
                ;;
        esac
        if ip rule show 2>/dev/null | grep -Eq '0x0?f000000'; then
            check_pass "wan-balance selector rules present (0x0f000000)"
        else
            check_warn "no 0x0f000000 rules (normal when every WAN is offline)"
        fi
        if command -v nft >/dev/null 2>&1 && nft list table ip tf-sbwan >/dev/null 2>&1; then
            check_pass "nft tf-sbwan present"
        else
            check_warn "nft tf-sbwan absent (normal when the WAN pool is empty)"
        fi
    fi

    if [ "${PROXY_CHECK:-0}" = 1 ]; then
        _code=$(curl -s -o /dev/null -w '%{http_code}' -m 8 \
            -x http://127.0.0.1:7890 https://www.gstatic.com/generate_204 2>/dev/null)
        [ "$_code" = 204 ] && check_pass "device-local proxy test 204" ||
            check_fail "device-local proxy test returned ${_code:-000}"
    fi
    [ "$fail_count" -eq 0 ]
}

next_phase() {
    # Automatic fallback lands on the production TUN stack, never on a
    # local-only eBPF phase (LAN clients would egress direct = real data).
    case "$1" in
        phase2-ebpf-shared | phase1-ebpf-local) echo tun ;;
        tun) echo phase0-observability ;;
        phase0-observability) echo original ;;
        *) echo original ;;
    esac
}

do_restore() {
    _want="${1:-}"
    [ -n "$_want" ] || die "restore needs a phase or file"
    shift
    FORCE=0
    PROXY_CHECK=0
    NOVERIFY=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) FORCE=1 ;;
            --proxy-check) PROXY_CHECK=1 ;;
            --no-verify) NOVERIFY=1 ;;
            *) die "unknown restore option: $1" ;;
        esac
        shift
    done

    _target=$(resolve_target "$_want") || die "no backup for '$_want' (try: sh $0 list)"
    _tmd5=$(md5_of "$_target")
    _exp=$(expected_md5 "$_target") || true
    if [ -z "${_exp:-}" ]; then
        [ "$FORCE" = 1 ] || die "no md5 sidecar/index for $(basename "$_target") (see 'sh $0 list'); pass --force only if you trust it"
        check_warn "backup has no recorded md5; trusting current bytes ($_tmd5)"
        _exp="$_tmd5"
    fi
    [ "$_exp" = "$_tmd5" ] || die "md5 mismatch: $(basename "$_target") expected $_exp got $_tmd5"
    _mode=$(detect_phase "$_target")
    case "$_want" in
        tun|phase0-observability|original|phase2-ebpf-shared|phase1-ebpf-local|pre-restore|manual) _want_phase=$_want ;;
        *) _want_phase='' ;;
    esac
    if [ "$_mode" = phase1-ebpf-local ] && [ -n "$_want_phase" ] && [ "$_want_phase" != phase1-ebpf-local ]; then
        die "requested $_want but $(basename "$_target") is a local-only eBPF config (LAN clients would egress direct); restore phase1-ebpf-local explicitly for the diagnostic window"
    fi
    _cur=$(md5_of "$CONF" 2>/dev/null || true)
    T0=$(date +%s)

    if [ "$_cur" = "$_tmd5" ]; then
        echo "already at $(basename "$_target") ($_tmd5)"
        if [ -x "$BIN" ] && ! "$BIN" check -c "$CONF" >/tmp/backup-restore-check.$$ 2>&1; then
            echo "FAIL: the current config of this phase does not pass sing-box check:" >&2
            sed -n '1,20p' /tmp/backup-restore-check.$$ >&2
            rm -f /tmp/backup-restore-check.$$
            check_fail "config for $(basename "$_target") is invalid"
            echo "next: sh $0 restore $(next_phase "$_mode")" >&2
            return 3
        fi
        rm -f /tmp/backup-restore-check.$$
        if [ "$FORCE" != 1 ] && [ "$NOVERIFY" != 1 ]; then
            # md5 equality only proves the file; the running core can still be
            # on another mode or mark (stale start, failed earlier step).  The
            # no-op path must verify the runtime it claims to leave alone.
            echo "== runtime verification (same md5) =="
            fail_count=0
            if verify_runtime "$_mode"; then
                echo "core already matches $(basename "$_target") ($_mode); no restart needed"
                echo "rollback: $(basename "$_target") in $(($(date +%s) - T0))s"
                return 0
            fi
            echo "runtime does not match the restored config; restarting the same config once" >&2
            if [ "${SINGBOX_NO_RESTART:-0}" = 1 ]; then
                echo "SINGBOX_NO_RESTART=1: config is correct but the running core does not match" >&2
                echo "next: sh $0 restore $_mode --force" >&2
                return 4
            fi
            [ -x "$SERVICE" ] || die "missing $SERVICE"
            if ! sh "$SERVICE" restart; then
                check_fail "sing-box.sh restart failed; inspect $BASE/state/sing-box.log"
                echo "next: sh $0 rescue   (or restore $(next_phase "$_mode"))" >&2
                return 4
            fi
            echo "== runtime verification (after restart) =="
            fail_count=0
            if verify_runtime "$_mode"; then
                _elapsed=$(($(date +%s) - T0))
                echo "RESULT: PASS restored=$(basename "$_target") mode=$_mode elapsed=${_elapsed}s (restarted)"
                [ "$_elapsed" -le 30 ] || check_warn "elapsed exceeded the 30s rollback budget"
                return 0
            fi
            _elapsed=$(($(date +%s) - T0))
            echo "RESULT: FAIL restored=$(basename "$_target") mode=$_mode elapsed=${_elapsed}s"
            echo "next: sh $0 restore $(next_phase "$_mode")    # or: sh $0 list" >&2
            [ "$_elapsed" -le 30 ] || echo "WARN: over 30s — roll back the next step immediately" >&2
            return 4
        fi
    else
        if [ -f "$CONF" ]; then
            _safe="$CONF.bak-pre-restore-$NOW"
            _i=1
            while [ -e "$_safe" ]; do
                _safe="$CONF.bak-pre-restore-$NOW-$_i"
                _i=$((_i + 1))
            done
            if cp -p "$CONF" "$_safe"; then
                ( cd "$(dirname "$_safe")" && md5sum "$(basename "$_safe")" > "$(basename "$_safe").md5" )
                index_add "$NOW" pre-restore "$(md5_of "$_safe")" "$(size_of "$_safe")" "$(basename "$_safe")"
                pin "$_safe" pre-restore
                prune_phase pre-restore
                echo "safety: $(basename "$_safe")"
            else
                die "cannot create pre-restore safety copy; refusing to swap config"
            fi
        fi

        _tmp="$CONF.restore.$$"
        cp -p "$_target" "$_tmp" || die "cannot stage restore copy"
        if [ "$(md5_of "$_tmp")" != "$_exp" ]; then
            rm -f "$_tmp"
            die "staged copy md5 mismatch; config.json untouched"
        fi
        # Validate the staged bytes BEFORE the atomic swap: a rejected config
        # leaves the running file untouched, so no in-place revert is needed
        # and a failed copy can never truncate the original.
        if [ -x "$BIN" ]; then
            if ! "$BIN" check -c "$_tmp" >/tmp/backup-restore-check.$$ 2>&1; then
                echo "FAIL: sing-box check rejected the staged config:" >&2
                sed -n '1,20p' /tmp/backup-restore-check.$$ >&2
                rm -f /tmp/backup-restore-check.$$ "$_tmp"
                return 3
            fi
            rm -f /tmp/backup-restore-check.$$
        fi
        mv -f "$_tmp" "$CONF" || {
            rm -f "$_tmp"
            die "atomic replace of config.json failed"
        }
        echo "restored: $(basename "$_target") -> $CONF"
    fi

    if [ "${SINGBOX_NO_RESTART:-0}" = 1 ]; then
        echo "SINGBOX_NO_RESTART=1: config swapped, restart skipped"
        return 0
    fi
    [ -x "$SERVICE" ] || die "missing $SERVICE"
    if ! sh "$SERVICE" restart; then
        check_fail "sing-box.sh restart failed; inspect $BASE/state/sing-box.log"
        echo "next: sh $0 rescue   (or restore $(next_phase "$_mode"))" >&2
        return 4
    fi

    _ok=1
    if [ "$NOVERIFY" != 1 ]; then
        echo "== runtime verification =="
        fail_count=0
        verify_runtime "$_mode" || _ok=0
    fi

    _elapsed=$(($(date +%s) - T0))
    if [ "$_ok" = 1 ]; then
        echo "RESULT: PASS restored=$(basename "$_target") mode=$_mode elapsed=${_elapsed}s"
        [ "$_elapsed" -le 30 ] || check_warn "elapsed exceeded the 30s rollback budget"
        return 0
    fi
    echo "RESULT: FAIL restored=$(basename "$_target") mode=$_mode elapsed=${_elapsed}s"
    echo "next: sh $0 restore $(next_phase "$_mode")    # or: sh $0 list" >&2
    [ "$_elapsed" -le 30 ] || echo "WARN: over 30s — roll back the next step immediately" >&2
    return 4
}

do_rescue() {
    for _p in tun phase0-observability original; do
        _t=$(resolve_target "$_p" 2>/dev/null) || continue
        if [ "$(detect_phase "$_t")" = phase1-ebpf-local ]; then
            check_warn "$_p resolves to a local-only eBPF config; skipping (LAN would egress direct)"
            continue
        fi
        echo "rescue -> $_p"
        do_restore "$_p"
        return $?
    done
    die "no tun/phase0-observability/original backup found (or all are local-only)"
}

case "${1:-}" in
    save) shift; do_save "${1:-auto}" ;;
    import) shift; do_import "${1:-}" "${2:-}" ;;
    list|ls) do_list ;;
    verify) shift; do_verify "${1:-}" ;;
    restore) shift; do_restore "$@" ;;
    rescue) do_rescue ;;
    prune) do_prune ;;
    -h|--help|help) usage ;;
    *) usage ;;
esac
