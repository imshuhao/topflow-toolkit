#!/bin/sh
# sing-box lifecycle for TopFlow MU5252.
# Not executed by the migration deploy; production cutover is explicit.
set -u

BASE="${SINGBOX_BASE:-/data/sing-box}"
BIN="$BASE/sing-box"
CONF="$BASE/config.json"
LOG="${SINGBOX_LOG:-$BASE/state/sing-box.log}"
STATE="$BASE/state"
PIDFILE="$STATE/sing-box.pid"
# Upper bound on inbounds inspected when locating the eBPF inbound.  A config
# with more than this is refused (planes print unknown) instead of partially
# walked.
MAX_INBOUNDS=64
KEEPER_PIDFILE="$STATE/dhcp-keeper.pid"
MANUAL_STOP="/tmp/sing-box-manual-stop"
WATCHDOG_PIDFILE="$STATE/watchdog.pid"
MIHOMO_SMART="/data/mihomo/smart/mihomo-smart.sh"
MIHOMO_NETNS="/data/mihomo/mihomo-netns.sh"
DHCP_OPTIONS="dhcp.lan.dhcp_option"
BALANCE="$BASE/singbox-wan-balance.sh"
CAPFLUSH="$BASE/singbox-capture-flush.sh"
GUARD="$BASE/ebpf-fragment-guard.sh"
DIAG="${SINGBOX_SERVICE_API:-http://127.0.0.1:8088}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

is_running() {
    [ -f "$PIDFILE" ] || return 1
    _pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
    [ -n "$_pid" ] || return 1
    kill -0 "$_pid" 2>/dev/null || return 1
    # Identity is the executable, not a substring of the command line: a stale
    # pidfile reused by a helper must not look like the core.  "(deleted)"
    # covers a binary replaced in place while the old process still runs.
    _exe=$(readlink "/proc/$_pid/exe" 2>/dev/null) || return 1
    _exe=${_exe% (deleted)}
    [ "$_exe" = "$BIN" ]
}

mihomo_running() {
    ps | grep -F '/data/mihomo/mihomo ' | grep -v grep >/dev/null 2>&1 && return 0
    ps | grep -F 'mihomo-smart.sh' | grep -v grep >/dev/null 2>&1 && return 0
    ps | grep -F 'mihomo-netns.sh' | grep -v grep >/dev/null 2>&1 && return 0
    return 1
}

proc_has() {
    _needle="$1"
    for _d in /proc/[0-9]*; do
        _pid=${_d#/proc/}
        [ "$_pid" = "$$" ] && continue
        [ -r "$_d/cmdline" ] || continue
        _cmd=$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null || true)
        case " $_cmd " in
            *"$_needle"*) echo "$_pid" ;;
        esac
    done
    return 0
}

is_watchdog_running() {
    [ -f "$WATCHDOG_PIDFILE" ] || return 1
    _pid=$(cat "$WATCHDOG_PIDFILE" 2>/dev/null) || return 1
    [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null || return 1
    grep -qa 'singbox-watchdog.sh' "/proc/$_pid/cmdline" 2>/dev/null
}

is_keeper_running() {
    [ -f "$KEEPER_PIDFILE" ] || return 1
    _pid=$(cat "$KEEPER_PIDFILE" 2>/dev/null) || return 1
    [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null || return 1
    grep -qa 'singbox-dhcp-keeper.sh' "/proc/$_pid/cmdline" 2>/dev/null
}

wait_api() {
    _i=0
    while [ "$_i" -lt 45 ]; do
        if curl -s -m 1 "http://127.0.0.1:9999/version" 2>/dev/null | grep -q 'sing-box'; then
            return 0
        fi
        sleep 1
        _i=$((_i + 1))
    done
    return 1
}

# Which transparent-capture stack does the current config use?
#   tun  -> production TUN (sbtun0 / auto_route / auto_redirect)
#   ebpf -> experimental eBPF inbound (local cgroup, optional shared LAN hook:
#           packet_rewrite or socket_assign, guarded by ebpf-fragment-guard.sh)
# Detection is by config content, so a hand-restored config keeps working.
inbound_mode() {
    if [ -f "$CONF" ] && grep -q '"type": *"ebpf"' "$CONF" 2>/dev/null; then
        echo ebpf
    else
        echo tun
    fi
}

# Index of the eBPF inbound inside @.inbounds, or rc 1 when there is none or the
# config cannot be enumerated.  "@.inbounds[*].type" is the only probe whose
# failure means "unparseable": on this device jsonfilter exits 1 both for an
# out-of-range index and for a missing optional field, so a fixed index walk
# cannot tell "absent" from "broken".
ebpf_index() {
    [ -f "$CONF" ] || return 1
    command -v jsonfilter >/dev/null 2>&1 || return 1
    _types=$(jsonfilter -i "$CONF" -e '@.inbounds[*].type' 2>/dev/null) || return 1
    [ -n "$_types" ] || return 1
    _cnt=$(printf '%s\n' "$_types" | grep -c .)
    [ "$_cnt" -le "$MAX_INBOUNDS" ] || return 1
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

# One field of the eBPF inbound.  Empty output means the field is absent (a
# missing optional field is not a parse failure).
ebpf_field() { # ebpf_field <index> <path>
    jsonfilter -i "$CONF" -e "@.inbounds[$1].$2" 2>/dev/null | tr -d '"'
}

# "<data_plane> <iface[,iface...]>" for the enabled shared hook.  Exit 1 when
# the hook is absent/disabled or the config cannot be enumerated -- callers
# print unknown then, never a build default.
ebpf_shared_plane() {
    _i=$(ebpf_index) || return 1
    [ "$(ebpf_field "$_i" shared.enabled)" = true ] || return 1
    _dp=$(ebpf_field "$_i" shared.data_plane)
    [ -n "$_dp" ] || _dp=unset
    _ifs=$(ebpf_field "$_i" 'shared.interface[*]' | tr '\n' ',' | sed 's/,$//')
    [ -n "$_ifs" ] || _ifs=-
    echo "$_dp $_ifs"
}

# "<data_plane>" for the enabled local hook, same failure contract.
ebpf_local_plane() {
    _i=$(ebpf_index) || return 1
    [ "$(ebpf_field "$_i" local.enabled)" = true ] || return 1
    _dp=$(ebpf_field "$_i" local.data_plane)
    [ -n "$_dp" ] || _dp=unset
    echo "$_dp"
}

# The shared block only counts when its boolean says so: "enabled": false keeps
# LAN clients on the kernel path and must not arm the fragment guard.
ebpf_shared_enabled() {
    [ -f "$CONF" ] || return 1
    grep -q '"type": *"ebpf"' "$CONF" 2>/dev/null || return 1
    if command -v jsonfilter >/dev/null 2>&1; then
        ebpf_shared_plane >/dev/null 2>&1
        return $?
    fi
    # No parser: a shared block that is not explicitly disabled is treated as
    # enabled, so the guard's own strict parse decides (and refuses) instead of
    # this check silently downgrading the plane.
    _sb=$(sed -n '/"shared"[[:space:]]*:[[:space:]]*{/,/}/p' "$CONF" 2>/dev/null | tr -d ' \t\r\n')
    case "$_sb" in
        *'"enabled":false'*) return 1 ;;
    esac
    [ -n "$_sb" ]
}

# Fragment guard lifecycle.  The guard owns inet tf_sb_ebpf_guard only; it is
# installed before the core can pass a LAN packet and removed when the core
# stops or a TUN config takes over.  No other table, TC or route is touched.
guard_apply() {
    [ -x "$GUARD" ] || {
        echo "missing $GUARD" >&2
        log "ebpf guard: missing $GUARD"
        return 1
    }
    if "$GUARD" apply >> "$LOG" 2>&1; then
        log "ebpf guard: applied"
        return 0
    fi
    log "ebpf guard: apply failed; shared eBPF start refused"
    echo "fragment guard failed to install; shared eBPF start refused (see $LOG)" >&2
    return 1
}

guard_clear() {
    [ -x "$GUARD" ] || {
        log "ebpf guard: $GUARD missing; inet tf_sb_ebpf_guard may be stale"
        return 1
    }
    "$GUARD" clear >> "$LOG" 2>&1 || {
        log "ebpf guard: clear failed; check inet tf_sb_ebpf_guard manually"
        return 1
    }
    return 0
}

# True only when the guard reports an active hook for an enabled shared plane.
guard_active() {
    [ -x "$GUARD" ] || return 1
    "$GUARD" status >/dev/null 2>&1
}

guard_status_word() {
    if [ ! -x "$GUARD" ]; then
        echo "unavailable (missing $GUARD)"
        return 0
    fi
    "$GUARD" status >/dev/null 2>&1
    case $? in
        0) echo "active (pre-defrag prerouting drop)" ;;
        3) echo "NOT ACTIVE (shared plane unprotected)" ;;
        4) echo "not required" ;;
        5) echo "STALE (shared plane disabled; run $GUARD clear)" ;;
        *) echo "unavailable (status failed)" ;;
    esac
}

stop_watchdog() {
    for _p in $(proc_has 'singbox-watchdog.sh'); do
        kill "$_p" 2>/dev/null || true
    done
    # Prefer a short graceful window over a fixed 1s sleep: restart downtime
    # was dominated by mandatory sleeps even when the watchdog exited instantly.
    _i=0
    while [ "$_i" -lt 3 ]; do
        is_watchdog_running || break
        sleep 1
        _i=$((_i + 1))
    done
    for _p in $(proc_has 'singbox-watchdog.sh'); do
        kill -9 "$_p" 2>/dev/null || true
    done
    rm -f "$WATCHDOG_PIDFILE"
    rmdir "$BASE/state/watchdog.lock" 2>/dev/null || true
}

stop_core() {
    stop_watchdog
    if is_running; then
        _pid=$(cat "$PIDFILE")
        kill "$_pid" 2>/dev/null || true
        # Restart/stop UX: 5s graceful then SIGKILL (was 10s). Core normally
        # exits in <1s; the long wait only padded the proxy outage window.
        _i=0
        while [ "$_i" -lt 5 ]; do
            kill -0 "$_pid" 2>/dev/null || break
            sleep 1
            _i=$((_i + 1))
        done
        if kill -0 "$_pid" 2>/dev/null; then
            kill -9 "$_pid" 2>/dev/null || true
            sleep 1
        fi
        # Never drop the pidfile or the fragment guard while the core may
        # still be capturing: that would read as "stopped" with a live data
        # plane (and, for shared, with its protection removed).
        if kill -0 "$_pid" 2>/dev/null; then
            log "stop: core pid $_pid survived SIGKILL; pidfile and guard kept"
            echo "core pid $_pid did not exit; pidfile and guard kept" >&2
            return 1
        fi
    fi
    rm -f "$PIDFILE"
    if [ -x "$BALANCE" ]; then
        "$BALANCE" clear >/dev/null 2>&1 || true
    fi
    # Owned table only; removed after the core is gone (or before a TUN core
    # takes over), never while packets are still being captured.
    guard_clear || true
}

start_core() {
    [ -x "$BIN" ] || { echo "missing $BIN" >&2; return 1; }
    [ -f "$CONF" ] || { echo "missing $CONF" >&2; return 1; }
    # SINGBOX_SKIP_CHECK=1: restart path only. The live config already passed
    # check when the previous core started; re-parsing ~70KB JSON costs ~3s of
    # proxy blackout on this device. Fresh start / switchover still check.
    if [ "${SINGBOX_SKIP_CHECK:-0}" != "1" ]; then
        "$BIN" check -c "$CONF" || { echo "config check failed" >&2; return 1; }
    fi
    if is_running; then
        echo "sing-box already running (pid $(cat "$PIDFILE"))"
        # An already-running core only ever *adds* protection: nothing clears an
        # existing guard here (the config on disk can differ from the live
        # process; only a new core start may replace or remove it).  The guard
        # itself decides whether a shared hook exists and refuses an
        # indeterminate config, so it is authoritative for every eBPF config.
        if [ "$(inbound_mode)" = ebpf ]; then
            if ! guard_apply; then
                log "ebpf guard: refusing to keep an unprotected eBPF plane running"
                stop_core
                return 1
            fi
        fi
        [ -x "$BALANCE" ] && "$BALANCE" apply >/dev/null 2>&1 || true
        start_dhcp_keeper
        # SINGBOX_NO_WATCHDOG=1 is a trial contract, not a fresh-start detail:
        # ebpf-trial.sh restarts through this branch and must not end up with a
        # watchdog that outlives the experiment and restarts a dead candidate.
        if [ "${SINGBOX_NO_WATCHDOG:-0}" != "1" ]; then
            start_watchdog
        fi
        return 0
    fi
    if mihomo_running; then
        echo "mihomo is running; use switchover (mutual exclusion)" >&2
        return 1
    fi
    mkdir -p "$STATE"
    # Guard first: the shared hook must never be live while a fragment can
    # still be forwarded unproxied.  The guard parses the config itself (and
    # fails closed on an indeterminate plane); only a TUN start clears it.
    _guard_on=0
    if [ "$(inbound_mode)" = ebpf ]; then
        guard_apply || return 1
        _guard_on=1
    else
        guard_clear || true
    fi
    rm -f "$MANUAL_STOP"
    /sbin/start-stop-daemon -S -b -m -p "$PIDFILE" -x "$BIN" -- run -c "$CONF" >> "$LOG" 2>&1
    # No fixed sleep: wait_api already polls. A mandatory 1s here padded every
    # restart even when the API was ready in the first poll.
    _i=0
    while [ "$_i" -lt 5 ]; do
        is_running && break
        sleep 1
        _i=$((_i + 1))
    done
    if ! is_running; then
        echo "sing-box failed to start; last log:" >&2
        tail -20 "$LOG" >&2
        rm -f "$PIDFILE"
        # Keep the guard: fragments stay dropped until the TUN replacement
        # starts (which clears it).  Removing it here would open a direct
        # fragment window while no capture path exists at all.
        if [ "$_guard_on" -eq 1 ]; then
            log "ebpf guard state kept after failed eBPF start (cleared by the TUN replacement or stop)"
        fi
        return 1
    fi
    if ! wait_api; then
        echo "clash_api did not come up" >&2
        return 1
    fi
    if [ -x "$BALANCE" ]; then
        "$BALANCE" apply >/dev/null 2>&1 || log "wan balance apply failed"
    fi
    # Kill flows that were established while the proxy was down: the NAT
    # redirect only applies at connection setup, so they would otherwise stay
    # online but unproxied.  eBPF local captures at socket level, so there is
    # no redirected conntrack state to clean.
    if [ "$(inbound_mode)" = ebpf ]; then
        log "ebpf mode: capture flush skipped (no TUN redirect); re-verify wan balance self-bypass"
        if ! grep -q '0x2024' "$BALANCE" 2>/dev/null; then
            log "wan balance: SO_MARK 0x2024 bypass not found (unexpected)"
        fi
    elif [ -x "$CAPFLUSH" ]; then
        "$CAPFLUSH" >/dev/null 2>&1 || log "capture flush failed"
    fi
    start_dhcp_keeper
    if [ "${SINGBOX_NO_WATCHDOG:-0}" != "1" ]; then
        start_watchdog
    fi
    echo "sing-box started (pid $(cat "$PIDFILE"))"
}

start_watchdog() {
    is_watchdog_running && return 0
    rmdir "$BASE/state/watchdog.lock" 2>/dev/null || true
    /sbin/start-stop-daemon -S -b -m -p "$WATCHDOG_PIDFILE" -x "$BASE/singbox-watchdog.sh" >> "$LOG" 2>&1
    # Non-blocking: watchdog failure is recovered on the next start/restart.
}

start_dhcp_keeper() {
    is_keeper_running && return 0
    /sbin/start-stop-daemon -S -b -m -p "$KEEPER_PIDFILE" -x "$BASE/singbox-dhcp-keeper.sh" >> "$LOG" 2>&1
}

stop_dhcp_keeper() {
    for _p in $(proc_has 'singbox-dhcp-keeper.sh'); do
        kill "$_p" 2>/dev/null || true
    done
    rm -f "$KEEPER_PIDFILE"
}

set_dhcp_gateway() {
    _gw="$1"
    uci -q del_list "$DHCP_OPTIONS=3,192.168.0.254" 2>/dev/null || true
    uci -q del_list "$DHCP_OPTIONS=6,192.168.0.254" 2>/dev/null || true
    uci -q del_list "$DHCP_OPTIONS=3,192.168.0.1" 2>/dev/null || true
    uci -q del_list "$DHCP_OPTIONS=6,192.168.0.1" 2>/dev/null || true
    uci add_list "$DHCP_OPTIONS=3,$_gw"
    uci add_list "$DHCP_OPTIONS=6,$_gw"
    uci commit dhcp
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    echo "DHCP 3/6 -> $_gw"
}

stop_mihomo() {
    touch /tmp/mihomo-netns-manual-stop
    if [ -f /data/mihomo/smart/mihomo-smart-watchdog.pid ]; then
        kill "$(cat /data/mihomo/smart/mihomo-smart-watchdog.pid 2>/dev/null)" 2>/dev/null || true
    fi
    if [ -x "$MIHOMO_SMART" ] && ps | grep -F 'mihomo-smart.sh' | grep -v grep >/dev/null 2>&1; then
        "$MIHOMO_SMART" stop >/dev/null 2>&1 || true
    fi
    if [ -x "$MIHOMO_NETNS" ] && ps | grep -F 'mihomo-netns.sh' | grep -v grep >/dev/null 2>&1; then
        "$MIHOMO_NETNS" stop >/dev/null 2>&1 || true
    fi
    /etc/init.d/mihomo-netns disable >/dev/null 2>&1 || true
    _i=0
    while mihomo_running && [ "$_i" -lt 10 ]; do
        sleep 1
        _i=$((_i + 1))
    done
}

verify_core() {
    if ! wait_api; then
        echo "verify: clash_api failed" >&2
        return 1
    fi
    if [ "$(inbound_mode)" = ebpf ]; then
        # eBPF mode intentionally has no TUN device: a leftover sbtun0 means the
        # old core/config is still in play (two capture paths fighting).
        if ip link show sbtun0 >/dev/null 2>&1; then
            echo "verify: stale sbtun0 present while running eBPF config" >&2
            return 1
        fi
    elif ! ip link show sbtun0 >/dev/null 2>&1; then
        echo "verify: sbtun0 missing" >&2
        return 1
    fi
    # Shared eBPF only: the fragment guard is part of the captured plane, so a
    # missing hook is a verification failure even when the proxy test passes.
    if [ "$(inbound_mode)" = ebpf ] && ebpf_shared_enabled; then
        if ! guard_active; then
            echo "verify: fragment guard inactive for the shared eBPF plane" >&2
            return 1
        fi
    fi
    _code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        -x http://127.0.0.1:7890 https://www.google.com/generate_204 2>/dev/null)
    [ "$_code" = "204" ] || { echo "verify: proxy test returned $_code" >&2; return 1; }
    return 0
}

cmd_status() {
    echo "== sing-box =="
    if is_running; then
        echo "core: running pid=$(cat "$PIDFILE")"
    else
        echo "core: stopped"
    fi
    echo "api:  $(curl -s -m 2 http://127.0.0.1:9999/version 2>/dev/null || echo down)"
    if [ "$(inbound_mode)" = ebpf ]; then
        # Both planes are read back from the config with a JSON parser.  A
        # missing/unparseable/unknown value prints unknown: the build defaults
        # (cgroup / packet_rewrite) are not evidence of what the core attached.
        _lp=$(ebpf_local_plane 2>/dev/null) || _lp=unknown
        _plane=$(ebpf_shared_plane 2>/dev/null || true)
        if [ -n "$_plane" ]; then
            echo "in:   ebpf (local ${_lp} + shared ${_plane%% *} on ${_plane#* })"
        elif ebpf_shared_enabled; then
            echo "in:   ebpf (local ${_lp} + shared; plane unknown, jsonfilter missing)"
        else
            echo "in:   ebpf (local ${_lp} only)"
        fi
        # Guard state is read from nftables, not inferred from the config or a
        # spec file on disk.
        echo "guard: $(guard_status_word)"
        echo "tun:  $(ip -o link show sbtun0 2>/dev/null | head -1 || echo '- (expected, eBPF mode)')"
        # Attachment evidence is the gRPC service API; the capability probe is
        # not proof that a hook is attached.
        echo "diag: $DIAG (services.api, gRPC; the 9999 Clash controller is not this endpoint)"
        echo "ebpf: attach evidence -> $BIN api ebpf --url $DIAG --deep"
        echo "note: ebpf-probe.sh probes kernel capability only; it is not attachment proof"
    else
        echo "tun:  $(ip -o link show sbtun0 2>/dev/null | head -1 || echo down)"
        echo "guard: $(guard_status_word)"
    fi
    echo "dhcp: $(uci -q get "$DHCP_OPTIONS" 2>/dev/null || true)"
    echo "providers: $(ls "$BASE/providers"/*.json 2>/dev/null | wc -l) files"
    echo "wan:  $("$BALANCE" pool 2>/dev/null || echo '-')"
    echo "log:  $(tail -1 "$LOG" 2>/dev/null || echo empty)"
}

cmd_switchover() {
    if is_running; then
        echo "sing-box already running" >&2
        return 1
    fi
    stop_mihomo
    set_dhcp_gateway 192.168.0.1
    if start_core && verify_core; then
        echo "switchover OK; sing-box is now the gateway"
        return 0
    fi
    echo "switchover failed; rolling back to mihomo netns" >&2
    cmd_rollback
    return 1
}

cmd_rollback() {
    rm -f "$MANUAL_STOP"
    if ! stop_core; then
        echo "rollback: core did not stop; refusing to start mihomo" >&2
        return 1
    fi
    stop_dhcp_keeper
    set_dhcp_gateway 192.168.0.254
    rm -f /tmp/mihomo-netns-manual-stop
    /etc/init.d/mihomo-netns enable >/dev/null 2>&1 || true
    "$MIHOMO_NETNS" start >/dev/null 2>&1 || true
    echo "rollback: mihomo-netns requested"
}

case "${1:-}" in
    start) start_core ;;
    stop)
        touch "$MANUAL_STOP"
        if ! stop_core; then
            echo "sing-box stop failed; pidfile and guard kept" >&2
            exit 1
        fi
        stop_dhcp_keeper
        echo "sing-box stopped"
        ;;
    restart)
        touch "$MANUAL_STOP"
        if ! stop_core; then
            echo "restart aborted: stop failed; pidfile and guard kept" >&2
            exit 1
        fi
        stop_dhcp_keeper
        rm -f "$MANUAL_STOP"
        # Skip re-check: this config was already accepted by the previous core.
        # Deploy paths that rewrite config.json must run `check` themselves
        # before restart (deploy.sh already does).
        SINGBOX_SKIP_CHECK=1 start_core
        ;;
    status) cmd_status ;;
    check) "$BIN" check -c "$CONF" ;;
    switchover) cmd_switchover ;;
    rollback) cmd_rollback ;;
    logs) tail -n "${2:-50}" "$LOG" ;;
    ebpf)
        shift
        if [ -x "$BASE/ebpf-probe.sh" ]; then
            sh "$BASE/ebpf-probe.sh" "$@"
        else
            echo "missing $BASE/ebpf-probe.sh" >&2
            exit 2
        fi
        ;;
    *) echo "usage: $0 {start|stop|restart|status|check|switchover|rollback|logs|ebpf}" >&2; exit 2 ;;
esac
