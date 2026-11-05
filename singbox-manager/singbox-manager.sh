#!/bin/sh
# sing-box device-side manager for the MU5252 WebUI panel (#singbox_manager).
# Fixed subcommands only: no arbitrary shell input, no arbitrary file paths.
# All lifecycle work is delegated to /data/sing-box/sing-box.sh.
# No `set -u`: libubox jshn.sh expands an unset JSON_PREFIX internally.

BASE="${SINGBOX_BASE:-/data/sing-box}"
CTL="$BASE/sing-box.sh"
BIN="$BASE/sing-box"
CONF="$BASE/config.json"
LOG="${SINGBOX_LOG:-$BASE/state/sing-box.log}"
STATE="$BASE/state"
PIDFILE="$STATE/sing-box.pid"
WATCHDOG_PIDFILE="$STATE/watchdog.pid"
KEEPER_PIDFILE="$STATE/dhcp-keeper.pid"
MANUAL_STOP="/tmp/sing-box-manual-stop"
API_URL="http://127.0.0.1:9999"
UI_URL="http://192.168.0.1:9999/ui/"
DHCP_OPTIONS="dhcp.lan.dhcp_option"
MIHOMO_NETNS="/data/mihomo/mihomo-netns.sh"
LOCK_DIR="/tmp/singbox-manager.lock"
MAX_TEXT=4000

. /usr/share/libubox/jshn.sh

# Touch UI redirects our stderr to /tmp/touchui-singbox-manager.log. Without
# explicit stderr lines that file stays 0 bytes and panel actions are opaque.
MGR_LOG="${SINGBOX_MANAGER_LOG:-/tmp/touchui-singbox-manager.log}"
mgr_log() {
    _line="$(date '+%Y-%m-%d %H:%M:%S') [singbox-manager] $*"
    printf '%s\n' "$_line" >&2
    # Also append directly: some callers only capture stdout and never wire stderr.
    printf '%s\n' "$_line" >>"$MGR_LOG" 2>/dev/null || true
}

json_result() {
    _ok="$1"
    _message="$2"
    _details="${3:-}"
    mgr_log "result ok=$_ok msg=$_message"
    json_init
    json_add_boolean ok "$_ok"
    json_add_string message "$_message"
    [ -n "$_details" ] && json_add_string details "$_details"
    json_dump
}

clip() {
    printf '%s' "$1" | tail -c "$MAX_TEXT"
}

is_running() {
    [ -f "$PIDFILE" ] || return 1
    _p="$(cat "$PIDFILE" 2>/dev/null)" || return 1
    [ -n "$_p" ] || return 1
    kill -0 "$_p" 2>/dev/null || return 1
    tr '\0' ' ' <"/proc/$_p/cmdline" 2>/dev/null | grep -q 'sing-box' || return 1
    return 0
}

pidfile_alive() {
    [ -f "$1" ] || return 1
    _p="$(cat "$1" 2>/dev/null)" || return 1
    [ -n "$_p" ] || return 1
    kill -0 "$_p" 2>/dev/null || return 1
    grep -qa "$2" "/proc/$_p/cmdline" 2>/dev/null
}

mihomo_process() {
    ps | grep -F '/data/mihomo/mihomo ' | grep -v grep >/dev/null 2>&1
}

mihomo_running() {
    mihomo_process && return 0
    ps | grep -F 'mihomo-netns.sh' | grep -v grep >/dev/null 2>&1 && return 0
    ps | grep -F 'mihomo-smart.sh' | grep -v grep >/dev/null 2>&1 && return 0
    return 1
}

api_text() {
    curl -s -m 3 "$API_URL$1" 2>/dev/null
}

acquire_lock() {
    _i=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        _p="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; then
            _i=$((_i + 1))
            [ "$_i" -ge 10 ] && return 1
            sleep 1
        else
            rm -rf "$LOCK_DIR" 2>/dev/null || true
        fi
    done
    echo $$ >"$LOCK_DIR/pid" 2>/dev/null || true
    trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
    return 0
}

dhcp_list() {
    uci -q get "$DHCP_OPTIONS" 2>/dev/null || true
}

dhcp_has() {
    _list="$(dhcp_list)"
    [ -n "$_list" ] || return 1
    case " $_list " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

verify_singbox() {
    _out=""
    if is_running; then
        _out="核心: 运行中 (pid $(cat "$PIDFILE" 2>/dev/null))"
    else
        _out="核心: 未运行"
    fi
    if ip link show sbtun0 >/dev/null 2>&1; then
        _addr="$(ip -o -4 addr show sbtun0 2>/dev/null | awk '{print $4; exit}')"
        _out="$_out
TUN sbtun0: UP ${_addr}"
    else
        _out="$_out
TUN sbtun0: 不存在"
    fi
    _list="$(dhcp_list)"
    _out="$_out
DHCP 3/6: ${_list:-空}"
    if dhcp_has '3,192.168.0.1' && dhcp_has '6,192.168.0.1'; then
        _out="$_out
DHCP 校验: 通过（网关/DNS = 192.168.0.1）"
    else
        _out="$_out
DHCP 校验: 未通过（应为 3/6 = 192.168.0.1）"
    fi
    if api_text /version | grep -q 'sing-box'; then
        _out="$_out
API: 正常"
    else
        _out="$_out
API: 不可用"
    fi
    printf '%s' "$_out"
}

verify_mihomo() {
    _out=""
    if is_running; then
        _out="sing-box: 仍在运行（异常）"
    else
        _out="sing-box: 已停止"
    fi
    if [ -x "$MIHOMO_NETNS" ]; then
        _status="$("$MIHOMO_NETNS" status 2>/dev/null || true)"
        _ns="$(printf '%s\n' "$_status" | grep '^namespace=' | head -1)"
        _proc="$(printf '%s\n' "$_status" | grep '^process=' | head -1)"
        _out="$_out
netns: ${_ns:-未知}
mihomo: ${_proc:-未知}"
    else
        _out="$_out
netns: 缺少 $MIHOMO_NETNS"
    fi
    _list="$(dhcp_list)"
    _out="$_out
DHCP 3/6: ${_list:-空}"
    if dhcp_has '3,192.168.0.254'; then
        if dhcp_has '6,192.168.0.254'; then
            _out="$_out
DHCP 校验: 通过（网关/DNS = 192.168.0.254）"
        else
            _out="$_out
DHCP 校验: 网关已切换，DNS 未切换"
        fi
    else
        _out="$_out
DHCP 校验: 未通过（网关仍不是 192.168.0.254）"
    fi
    printf '%s' "$_out"
}

# Cheap inbound mode from config content (same contract as sing-box.sh).
inbound_mode() {
    if [ -f "$CONF" ] && grep -q '"type": *"ebpf"' "$CONF" 2>/dev/null; then
        echo ebpf
    else
        echo tun
    fi
}

# Best-effort shared eBPF plane/iface for status JSON. Missing parser → unknown/-.
capture_ebpf_shared() {
    _plane=unknown
    _iface=-
    if [ -f "$CONF" ] && command -v jsonfilter >/dev/null 2>&1; then
        _types=$(jsonfilter -i "$CONF" -e '@.inbounds[*].type' 2>/dev/null) || _types=
        _i=0
        _found=
        if [ -n "$_types" ]; then
            while IFS= read -r _t; do
                if [ "$_t" = ebpf ]; then
                    _found=$_i
                    break
                fi
                _i=$((_i + 1))
            done <<EOF
$_types
EOF
        fi
        if [ -n "$_found" ]; then
            _en=$(jsonfilter -i "$CONF" -e "@.inbounds[$_found].shared.enabled" 2>/dev/null | tr -d '"')
            if [ "$_en" = true ]; then
                _plane=$(jsonfilter -i "$CONF" -e "@.inbounds[$_found].shared.data_plane" 2>/dev/null | tr -d '"')
                [ -n "$_plane" ] || _plane=unknown
                _iface=$(jsonfilter -i "$CONF" -e "@.inbounds[$_found].shared.interface[*]" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
                [ -n "$_iface" ] || _iface=-
            fi
        fi
    fi
    echo "$_plane $_iface"
}

status_json() {
    _running=0
    _mihomo=0
    _api=0
    _tun=0
    _manual=0
    _watchdog=0
    _keeper=0
    _dhcp_gw=0
    _dhcp_dns=0
    _dhcp_mihomo=0
    _pid=""
    _rss=0
    _version=""
    _mode="unknown"
    _rx=0
    _tx=0
    _engine="none"
    _state="stopped"
    _tun_addr=""
    _tun_addr6=""
    _providers=0
    _last_log=""
    _inbound=tun
    _capture_plane=tun
    _capture_iface=sbtun0
    _capture_ok=0

    is_running && _running=1
    mihomo_running && _mihomo=1
    [ -f "$MANUAL_STOP" ] && _manual=1
    pidfile_alive "$WATCHDOG_PIDFILE" 'singbox-watchdog.sh' && _watchdog=1
    pidfile_alive "$KEEPER_PIDFILE" 'singbox-dhcp-keeper.sh' && _keeper=1
    ip link show sbtun0 >/dev/null 2>&1 && _tun=1
    _inbound="$(inbound_mode)"

    if [ "$_running" -eq 1 ]; then
        _pid="$(cat "$PIDFILE" 2>/dev/null || true)"
        if [ -n "$_pid" ]; then
            _rss="$(awk '/^VmRSS:/ {print $2; exit}' "/proc/$_pid/status" 2>/dev/null || echo 0)"
        fi
    fi
    case "$_rss" in ''|*[!0-9]*) _rss=0 ;; esac

    _version="$(api_text /version | jsonfilter -e '@.version' 2>/dev/null || true)"
    case "$_version" in *sing-box*) _api=1 ;; esac

    if [ "$_api" -eq 1 ]; then
        _mode="$(api_text /configs | jsonfilter -e '@.mode' 2>/dev/null || true)"
        _conn="$(api_text /connections)"
        if [ -n "$_conn" ]; then
            _rx="$(printf '%s' "$_conn" | jsonfilter -e '@.downloadTotal' 2>/dev/null || true)"
            _tx="$(printf '%s' "$_conn" | jsonfilter -e '@.uploadTotal' 2>/dev/null || true)"
        fi
    fi
    [ -n "$_mode" ] || _mode="unknown"
    case "$_rx" in ''|*[!0-9]*) _rx=0 ;; esac
    case "$_tx" in ''|*[!0-9]*) _tx=0 ;; esac

    dhcp_has '3,192.168.0.1' && _dhcp_gw=1
    _dhcp_dns=0
    dhcp_has '6,192.168.0.1' && _dhcp_dns=1
    dhcp_has '3,192.168.0.254' && _dhcp_mihomo=1

    if [ "$_tun" -eq 1 ]; then
        _tun_addr="$(ip -o -4 addr show sbtun0 2>/dev/null | awk '{print $4; exit}')"
        _tun_addr6="$(ip -o -6 addr show sbtun0 2>/dev/null | awk '{print $4; exit}')"
    fi

    if [ "$_inbound" = ebpf ]; then
        _cap="$(capture_ebpf_shared)"
        _capture_plane="${_cap%% *}"
        _capture_iface="${_cap#* }"
        [ -n "$_capture_plane" ] || _capture_plane=unknown
        [ -n "$_capture_iface" ] || _capture_iface=-
        # eBPF: no sbtun0 is expected; leftover TUN means two capture paths.
        if [ "$_running" -eq 1 ] && [ "$_api" -eq 1 ] && [ "$_tun" -eq 0 ]; then
            _capture_ok=1
        fi
    else
        _capture_plane=tun
        _capture_iface=sbtun0
        if [ "$_running" -eq 1 ] && [ "$_api" -eq 1 ] && [ "$_tun" -eq 1 ]; then
            _capture_ok=1
        fi
    fi

    _providers="$(ls "$BASE/providers"/*.json 2>/dev/null | wc -l | tr -d ' ')"
    case "$_providers" in ''|*[!0-9]*) _providers=0 ;; esac
    [ -f "$LOG" ] && _last_log="$(tail -n 1 "$LOG" 2>/dev/null | cut -c1-200)"

    if [ "$_running" -eq 1 ]; then
        _engine=sing-box
        if [ "$_api" -eq 1 ]; then
            _state=running
        else
            _state=starting
        fi
    elif [ "$_mihomo" -eq 1 ]; then
        _engine=mihomo
        _state=mihomo_active
    elif [ "$_manual" -eq 1 ]; then
        _state=stopped_manual
    fi

    _dhcp_text="$(dhcp_list | sed 's/ / · /g')"
    mgr_log "status state=${_state:-unknown} pid=$_pid api=$_api inbound=$_inbound capture_ok=$_capture_ok"

    json_init
    json_add_boolean ok 1
    json_add_boolean service_running "$_running"
    json_add_string service_state "$_state"
    json_add_boolean api_ok "$_api"
    json_add_string version "$_version"
    json_add_string proxy_mode "$_mode"
    json_add_string pid "$_pid"
    json_add_int rss_kb "$_rss"
    json_add_boolean tun_up "$_tun"
    json_add_string tun_addr "$_tun_addr"
    json_add_string tun_addr6 "$_tun_addr6"
    json_add_string inbound_mode "$_inbound"
    json_add_string capture_plane "$_capture_plane"
    json_add_string capture_iface "$_capture_iface"
    json_add_boolean capture_ok "$_capture_ok"
    json_add_string dhcp_options "$_dhcp_text"
    json_add_boolean dhcp_gateway_ok "$_dhcp_gw"
    json_add_boolean dhcp_dns_ok "$_dhcp_dns"
    json_add_boolean dhcp_points_to_mihomo "$_dhcp_mihomo"
    json_add_int providers "$_providers"
    json_add_boolean watchdog_running "$_watchdog"
    json_add_boolean keeper_running "$_keeper"
    json_add_boolean manual_stop "$_manual"
    json_add_boolean mihomo_running "$_mihomo"
    json_add_string engine "$_engine"
    json_add_int download_total "$_rx"
    json_add_int upload_total "$_tx"
    json_add_string ui_url "$UI_URL"
    json_add_string last_log "$_last_log"
    json_dump
}

require_ctl() {
    [ -x "$CTL" ] || {
        json_result 0 "缺少可执行的 $CTL"
        return 1
    }
    return 0
}

cmd_service_start() {
    require_ctl || return 0
    mgr_log "service-start begin"
    if is_running; then
        json_result 1 "sing-box 已在运行" "$(verify_singbox)"
        return 0
    fi
    acquire_lock || {
        json_result 0 "另一个管理操作正在执行，请稍后再试"
        return 0
    }
    _out="$(clip "$("$CTL" start 2>&1)")"
    if is_running; then
        json_result 1 "sing-box 已启动" "$_out
$(verify_singbox)"
    else
        json_result 0 "启动失败" "$_out"
    fi
}

cmd_service_stop() {
    require_ctl || return 0
    mgr_log "service-stop begin"
    if ! is_running; then
        json_result 1 "sing-box 未在运行" "$(verify_singbox)"
        return 0
    fi
    acquire_lock || {
        json_result 0 "另一个管理操作正在执行，请稍后再试"
        return 0
    }
    _out="$(clip "$("$CTL" stop 2>&1)")"
    if is_running; then
        json_result 0 "停止失败，核心仍在运行" "$_out"
    else
        json_result 1 "sing-box 已停止（客户端将直连）" "$_out"
    fi
}

cmd_service_restart() {
    require_ctl || return 0
    mgr_log "service-restart begin pid=$(cat "$PIDFILE" 2>/dev/null || echo none)"
    acquire_lock || {
        json_result 0 "另一个管理操作正在执行，请稍后再试"
        return 0
    }
    _out="$(clip "$("$CTL" restart 2>&1)")"
    if is_running; then
        mgr_log "service-restart done pid=$(cat "$PIDFILE" 2>/dev/null || echo none)"
        json_result 1 "sing-box 已重启" "$_out
$(verify_singbox)"
    else
        mgr_log "service-restart FAILED core down"
        json_result 0 "重启失败，核心未运行" "$_out"
    fi
}

cmd_config_check() {
    [ -x "$BIN" ] || {
        json_result 0 "缺少 $BIN"
        return 0
    }
    [ -f "$CONF" ] || {
        json_result 0 "缺少 $CONF"
        return 0
    }
    _out="$("$BIN" check -c "$CONF" 2>&1)"
    _rc=$?
    _out="$(clip "${_out:-（无输出）}")"
    if [ "$_rc" -eq 0 ]; then
        json_result 1 "配置检查通过" "$_out"
    else
        json_result 0 "配置检查失败（退出码 $_rc）" "$_out"
    fi
}

cmd_logs() {
    _lines="${1:-120}"
    case "$_lines" in ''|*[!0-9]*) _lines=120 ;; esac
    [ "$_lines" -gt 500 ] && _lines=500
    [ "$_lines" -lt 10 ] && _lines=10
    _log=""
    [ -f "$LOG" ] && _log="$(tail -n "$_lines" "$LOG" 2>/dev/null)"
    json_init
    json_add_boolean ok 1
    json_add_string log "$(printf '%s' "$_log" | tail -c 20000)"
    json_dump
}

cmd_switchover() {
    require_ctl || return 0
    if is_running; then
        json_result 1 "sing-box 已在运行，无需切换" "$(verify_singbox)"
        return 0
    fi
    acquire_lock || {
        json_result 0 "另一个管理操作正在执行，请稍后再试"
        return 0
    }
    _out="$(clip "$("$CTL" switchover 2>&1)")"
    _rc=$?
    _checks="$(verify_singbox)"
    if [ "$_rc" -eq 0 ] && is_running; then
        json_result 1 "已切换到 sing-box" "$_out
---
$_checks"
    else
        json_result 0 "切换失败（脚本已按流程尝试回滚）" "$_out
---
$_checks"
    fi
}

cmd_rollback() {
    require_ctl || return 0
    if ! is_running && mihomo_process; then
        json_result 1 "当前已是 mihomo 回滚态" "$(verify_mihomo)"
        return 0
    fi
    acquire_lock || {
        json_result 0 "另一个管理操作正在执行，请稍后再试"
        return 0
    }
    _out="$(clip "$("$CTL" rollback 2>&1)")"
    _i=0
    while [ "$_i" -lt 30 ]; do
        mihomo_process && break
        sleep 1
        _i=$((_i + 1))
    done
    _checks="$(verify_mihomo)"
    if mihomo_process; then
        json_result 1 "已切回 mihomo netns" "$_out
---
$_checks"
    else
        json_result 0 "回滚未确认成功，请立即检查网络" "$_out
---
$_checks"
    fi
}

WANBAL_SH="${SINGBOX_WANBAL:-$BASE/singbox-wan-balance.sh}"

cmd_wan_mode_status() {
    if [ ! -x "$WANBAL_SH" ]; then
        json_result 0 "wan-balance 脚本缺失" ""
        return
    fi
    _out="$("$WANBAL_SH" preset-get 2>/dev/null || true)"
    _preset="$(printf '%s\n' "$_out" | sed -n 's/^preset=//p' | head -1)"
    _mode="$(printf '%s\n' "$_out" | sed -n 's/^mode=//p' | head -1)"
    _tcp="$(printf '%s\n' "$_out" | sed -n 's/^tcp_pool=//p' | head -1)"
    _udp="$(printf '%s\n' "$_out" | sed -n 's/^udp_pool=//p' | head -1)"
    _quality="$(printf '%s\n' "$_out" | sed -n 's/^quality=//p' | head -1)"
    _bias="$(printf '%s\n' "$_out" | sed -n 's/^bias=//p' | head -1)"
    _tw="$(printf '%s\n' "$_out" | sed -n 's/^tcp_weights=//p' | head -1)"
    _uw="$(printf '%s\n' "$_out" | sed -n 's/^udp_weights=//p' | head -1)"
    _deg="$(printf '%s\n' "$_out" | sed -n 's/^degraded=//p' | head -1)"
    [ -n "$_preset" ] || _preset=unknown
    [ -n "$_mode" ] || _mode=unknown
    [ -n "$_quality" ] || _quality=0
    [ -n "$_bias" ] || _bias=0
    mgr_log "wan-mode-status preset=$_preset mode=$_mode q=$_quality deg=$_deg"
    json_init
    json_add_boolean ok 1
    json_add_string message "ok"
    json_add_string preset "$_preset"
    json_add_string mode "$_mode"
    json_add_string tcp_pool "$_tcp"
    json_add_string udp_pool "$_udp"
    json_add_string quality "$_quality"
    json_add_string bias "$_bias"
    json_add_string tcp_weights "$_tw"
    json_add_string udp_weights "$_uw"
    json_add_string degraded "$_deg"
    json_dump
}

cmd_wan_mode_set() {
    _id="${1:-}"
    case "$_id" in
    auto|shared|game) ;;
    *)
        json_result 0 "非法分流预设" "want auto|shared"
        return
        ;;
    esac
    if [ ! -x "$WANBAL_SH" ]; then
        json_result 0 "wan-balance 脚本缺失" ""
        return
    fi
    mgr_log "wan-mode-set begin id=$_id"
    _out="$("$WANBAL_SH" preset-set "$_id" 2>&1)" || {
        json_result 0 "切换分流失败" "$(clip "$_out")"
        return
    }
    _preset="$(printf '%s\n' "$_out" | sed -n 's/^preset=//p' | head -1)"
    [ "$_preset" = "$_id" ] || {
        json_result 0 "切换未确认" "$(clip "$_out")"
        return
    }
    case "$_id" in
    auto) _msg="已切换：自动质量分流" ;;
    shared) _msg="已切换：三卡共池" ;;
    game) _msg="已切换：游戏硬绑（遗留）" ;;
    esac
    mgr_log "wan-mode-set ok id=$_id"
    json_init
    json_add_boolean ok 1
    json_add_string message "$_msg"
    json_add_string preset "$_id"
    json_dump
}

case "${1:-status}" in
    status) status_json ;;
    service-start) cmd_service_start ;;
    service-stop) cmd_service_stop ;;
    service-restart) cmd_service_restart ;;
    config-check) cmd_config_check ;;
    logs) cmd_logs "${2:-120}" ;;
    switchover) cmd_switchover ;;
    rollback) cmd_rollback ;;
    wan-mode-status) cmd_wan_mode_status ;;
    wan-mode-set) cmd_wan_mode_set "${2:-}" ;;
    *)
        echo "usage: $0 {status|service-start|service-stop|service-restart|config-check|logs|switchover|rollback|wan-mode-status|wan-mode-set}" >&2
        exit 2
        ;;
esac
