#!/bin/sh
# ============================================================
# adb-wifi — TopFlow MU5252 B20 无线 ADB（LAN 侧 TCP）管理
#
# 设计前提（2026-10-27 实机 + 反汇编确认）:
#   · 本机 adbd 是 AOSP 10 双模逻辑：先 usb_init()，若
#     service.adb.tcp.port 有值再 setup_port()，USB 与 TCP 同时监听。
#   · 属性是内存态，重启即丢；且 adbd **只能第一次启动时**读它。
#   · 运行时重启 adbd 会拆掉 functionfs，新 adbd 再打开 ep0 失败，
#     USB gadget（含 RNDIS）整体消失，只能重启设备恢复。
#   ⇒ 本组件永不重启 adbd。开机由 /etc/init.d/adbd.init 里的
#     adbd-preset.sh 预置属性；本脚本只做属性/防火墙/状态。
#
# 安全前提:
#   · ro.adb.secure 未设置 = 无 ADB 认证：连上端口即 root
#   · 默认非标端口 15555；ADB_WIFI 链只放行 lo / br-lan
#
# 路径:
#   BASE=/data/adb-wifi            可用 ADB_WIFI_BASE 覆盖
#   $BASE/config                   配置: ADB_WIFI_PORT / ADB_WIFI_ENABLED
#   $BASE/state/port               上次生效端口（改端口时清 iptables 跳）
#   /tmp/adb-wifi-manual-stop      stop 标记（tmpfs，重启后自动清空）
#   /tmp/adb-wifi-watchdog.log     与 watchdog 共用的日志
#
# 用法: sh /data/adb-wifi/adb-wifi.sh start|stop|apply|status|help
#   start    清 manual-stop 标记；恢复放行链并补属性（不重启 adbd）
#   stop     立即封端口：ADB_WIFI 链改成全 DROP（不重启 adbd）
#   apply    开机/巡检用：按配置补属性 + 建放行链（不重启 adbd）
#   status   端口/属性/监听/进程/防火墙/日志/连接提示
#
# 回滚:
#   1) sh /data/adb-wifi/adb-wifi.sh stop          # 立即封端口
#   2) sh /data/adb-wifi/remove-boot-hook.sh       # 去 rc.local 钩子
#   3) sh /data/adb-wifi/remove-adbd-preset.sh     # 还原 adbd.init
#   4) kill "$(cat /data/adb-wifi/state/watchdog.pid)"
#   5) 重启设备 → 彻底回到 USB-only
# ============================================================
set -u

BASE="${ADB_WIFI_BASE:-/data/adb-wifi}"
CONFIG="$BASE/config"
STATE="$BASE/state"
PORT_STATE="$STATE/port"
MANUAL_STOP="/tmp/adb-wifi-manual-stop"
RC_DONE="/tmp/adb-wifi-rc-done"
LOG="${ADB_WIFI_LOG:-/tmp/adb-wifi-watchdog.log}"
DEFAULT_PORT=15555
CHAIN=ADB_WIFI

ADB_WIFI_PORT="$DEFAULT_PORT"
ADB_WIFI_ENABLED=1

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# 1..65535 的十进制整数（拒绝空串、符号、前导 0、超 5 位）
is_port() {
    case "${1:-}" in
        ''|*[!0-9]*|0*) return 1 ;;
    esac
    [ "${#1}" -le 5 ] || return 1
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

flag_state() {
    if [ -f "$1" ]; then
        echo yes
    else
        echo no
    fi
}

# 读配置；非法值回落默认端口并记日志
load_config() {
    ADB_WIFI_PORT="$DEFAULT_PORT"
    ADB_WIFI_ENABLED=1
    if [ -f "$CONFIG" ]; then
        # shellcheck source=/dev/null
        . "$CONFIG" 2>/dev/null || true
    fi
    ADB_WIFI_PORT=$(printf '%s' "${ADB_WIFI_PORT:-$DEFAULT_PORT}" | tr -d ' \r\t')
    if ! is_port "$ADB_WIFI_PORT"; then
        log "config: invalid ADB_WIFI_PORT in $CONFIG -> fallback $DEFAULT_PORT"
        ADB_WIFI_PORT="$DEFAULT_PORT"
    fi
    case "$ADB_WIFI_ENABLED" in
        0|no|off|false|no) ADB_WIFI_ENABLED=0 ;;
        *) ADB_WIFI_ENABLED=1 ;;
    esac
}

# 配置缺失时补一份：优先 $BASE/config.example，其次脚本同目录
ensure_config() {
    mkdir -p "$BASE" 2>/dev/null || true
    [ -f "$CONFIG" ] && return 0
    _ex="$BASE/config.example"
    if [ ! -f "$_ex" ]; then
        _sd=$(dirname "$0" 2>/dev/null || true)
        if [ -n "$_sd" ] && [ -f "$_sd/config.example" ]; then
            _ex="$_sd/config.example"
        fi
    fi
    if [ -f "$_ex" ] && cp "$_ex" "$CONFIG" 2>/dev/null; then
        log "config: created $CONFIG from $_ex"
        return 0
    fi
    printf '%s\n' "ADB_WIFI_PORT=$DEFAULT_PORT" "ADB_WIFI_ENABLED=1" > "$CONFIG" 2>/dev/null || \
        log "config: cannot write $CONFIG"
}

listener_up() {
    netstat -ltn 2>/dev/null | grep -q ":$ADB_WIFI_PORT "
}

# 等 adbd 启动并监听（开机时 adbd-wrapper 等本脚本创建 RC_DONE 才 exec adbd）
wait_listener() {
    _i=0
    while [ "$_i" -lt 15 ]; do
        listener_up && return 0
        sleep 1
        _i=$((_i + 1))
    done
    return 1
}

chain_present() {
    iptables -S "$CHAIN" >/dev/null 2>&1
}

# 清掉历史端口留下的 INPUT 跳
prune_stale_jump() {
    _prev=""
    if [ -f "$PORT_STATE" ]; then
        _prev=$(cat "$PORT_STATE" 2>/dev/null || true)
    fi
    if [ -n "$_prev" ] && [ "$_prev" != "$ADB_WIFI_PORT" ] && is_port "$_prev"; then
        while iptables -D INPUT -p tcp --dport "$_prev" -j "$CHAIN" 2>/dev/null; do :; done
        log "fw: removed stale INPUT jump for port $_prev"
    fi
}

# mode=allow: lo ACCEPT -> br-lan ACCEPT -> DROP
# mode=block: 全 DROP（stop 用，立即封端口）
ensure_firewall() {
    _mode="${1:-allow}"
    prune_stale_jump

    iptables -N "$CHAIN" 2>/dev/null || true
    iptables -F "$CHAIN" 2>/dev/null || true
    if [ "$_mode" = block ]; then
        # stop 用：立即重置连接（tcp-reset 避免对端留下半开连接卡住 adbd）
        iptables -A "$CHAIN" -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null || \
            iptables -A "$CHAIN" -j REJECT 2>/dev/null || log "fw: append REJECT failed"
    else
        iptables -A "$CHAIN" -i lo -j ACCEPT 2>/dev/null || log "fw: append lo ACCEPT failed"
        iptables -A "$CHAIN" -i br-lan -j ACCEPT 2>/dev/null || log "fw: append br-lan ACCEPT failed"
        iptables -A "$CHAIN" -j DROP 2>/dev/null || log "fw: append DROP failed"
    fi

    if ! iptables -C INPUT -p tcp --dport "$ADB_WIFI_PORT" -j "$CHAIN" 2>/dev/null; then
        iptables -I INPUT 1 -p tcp --dport "$ADB_WIFI_PORT" -j "$CHAIN" 2>/dev/null || \
            log "fw: insert INPUT jump failed"
    fi

    mkdir -p "$STATE" 2>/dev/null || true
    printf '%s\n' "$ADB_WIFI_PORT" > "$PORT_STATE" 2>/dev/null || true

    _rules=$(iptables -S "$CHAIN" 2>/dev/null || true)
    case "$_rules" in
        *DROP*|*REJECT*) ;;
        *) return 1 ;;
    esac
    if [ "$_mode" != block ]; then
        case "$_rules" in
            *br-lan*) ;;
            *) return 1 ;;
        esac
    fi
    iptables -C INPUT -p tcp --dport "$ADB_WIFI_PORT" -j "$CHAIN" 2>/dev/null || return 1
    return 0
}

# 幂等拆除：端口跳（当前 + 上次）-> 清链 -> 删链
drop_firewall() {
    _prev=""
    if [ -f "$PORT_STATE" ]; then
        _prev=$(cat "$PORT_STATE" 2>/dev/null || true)
    fi
    for _p in "$ADB_WIFI_PORT" "$_prev"; do
        [ -n "$_p" ] || continue
        is_port "$_p" || continue
        while iptables -D INPUT -p tcp --dport "$_p" -j "$CHAIN" 2>/dev/null; do :; done
    done
    iptables -F "$CHAIN" 2>/dev/null || true
    iptables -X "$CHAIN" 2>/dev/null || true
    rm -f "$PORT_STATE" 2>/dev/null || true
    return 0
}

set_prop() {
    if setprop service.adb.tcp.port "$ADB_WIFI_PORT" >> "$LOG" 2>&1; then
        log "prop: service.adb.tcp.port=$ADB_WIFI_PORT"
    else
        log "prop: setprop service.adb.tcp.port=$ADB_WIFI_PORT failed"
    fi
}

do_start() {
    rm -f "$MANUAL_STOP" 2>/dev/null || true
    load_config
    log "start: manual-stop flag cleared"
    if [ "$ADB_WIFI_ENABLED" = 0 ]; then
        echo "adb-wifi: disabled in $CONFIG (ADB_WIFI_ENABLED=0); set 1 + reboot" >&2
        return 1
    fi
    set_prop
    touch "$RC_DONE" 2>/dev/null || log "start: cannot create $RC_DONE"
    wait_listener >/dev/null 2>&1 || true
    if ensure_firewall allow; then
        log "start: firewall $CHAIN allow (lo+br-lan)"
    else
        log "start: firewall $CHAIN incomplete"
    fi
    if listener_up; then
        log "start: listener tcp:$ADB_WIFI_PORT up"
        return 0
    fi
    log "start: no listener on tcp:$ADB_WIFI_PORT (adbd reads the preset only at start)"
    echo "adb-wifi: listener not up; reboot once so adbd starts with TCP" >&2
    return 1
}

do_stop() {
    load_config
    mkdir -p "$BASE" 2>/dev/null || true
    touch "$MANUAL_STOP" 2>/dev/null || log "stop: cannot create $MANUAL_STOP"
    if ensure_firewall block; then
        log "stop: port $ADB_WIFI_PORT blocked in $CHAIN (adbd untouched)"
    else
        log "stop: firewall $CHAIN block incomplete"
    fi
    echo "adb-wifi: port $ADB_WIFI_PORT blocked (adbd/USB untouched)"
    echo "          resume: sh $0 start"
    return 0
}

do_apply() {
    ensure_config
    load_config
    if [ "$ADB_WIFI_ENABLED" = 0 ] || [ -f "$MANUAL_STOP" ]; then
        if ensure_firewall block; then
            log "apply: port $ADB_WIFI_PORT blocked (enabled=$ADB_WIFI_ENABLED manual_stop=$(flag_state "$MANUAL_STOP"))"
        else
            log "apply: firewall $CHAIN block incomplete"
        fi
        return 0
    fi
    set_prop
    # 让 adbd-wrapper 放行 adbd 启动，然后等它监听（最多 15s）
    touch "$RC_DONE" 2>/dev/null || log "apply: cannot create $RC_DONE"
    wait_listener >/dev/null 2>&1 || true
    if ensure_firewall allow; then
        log "apply: firewall $CHAIN ok (lo+br-lan accept, rest drop)"
    else
        log "apply: firewall $CHAIN incomplete"
    fi
    if listener_up; then
        log "apply: listener tcp:$ADB_WIFI_PORT up"
        return 0
    fi
    log "apply: no listener on tcp:$ADB_WIFI_PORT (preset takes effect at next adbd start)"
    return 1
}

do_status() {
    load_config
    _prop=$(getprop service.adb.tcp.port 2>/dev/null || true)
    [ -n "$_prop" ] || _prop="(unset)"
    _pids=$(pidof adbd 2>/dev/null || true)
    [ -n "$_pids" ] || _pids="(not running)"
    _wd=$(cat "$STATE/watchdog.pid" 2>/dev/null || true)
    _mode="allow"
    [ -f "$MANUAL_STOP" ] && _mode="block(manual-stop)"
    [ "$ADB_WIFI_ENABLED" = 0 ] && _mode="block(disabled)"

    echo "== adb-wifi =="
    echo "config      : $CONFIG ($(flag_state "$CONFIG"))"
    echo "enabled     : $ADB_WIFI_ENABLED"
    echo "port        : $ADB_WIFI_PORT"
    echo "mode        : $_mode"
    echo "manual stop : $(flag_state "$MANUAL_STOP")"
    echo "property    : service.adb.tcp.port=$_prop"
    if listener_up; then
        echo "listener    : yes (tcp:$ADB_WIFI_PORT)"
    else
        echo "listener    : no (tcp:$ADB_WIFI_PORT)"
    fi
    echo "adbd pid    : $_pids"
    if [ -n "$_wd" ] && kill -0 "$_wd" 2>/dev/null; then
        echo "watchdog    : running (pid $_wd)"
    else
        echo "watchdog    : not running"
    fi

    if chain_present; then
        echo "firewall    : $CHAIN present"
        iptables -L "$CHAIN" -v -n 2>/dev/null
        iptables -S INPUT 2>/dev/null | grep -F "$CHAIN" || echo "  (INPUT jump missing)"
    else
        echo "firewall    : $CHAIN missing"
    fi

    echo "-- last 5 log lines ($LOG) --"
    tail -n 5 "$LOG" 2>/dev/null || echo "(no log)"

    if [ "$ADB_WIFI_ENABLED" = 0 ]; then
        echo "hint        : disabled; set ADB_WIFI_ENABLED=1 in $CONFIG then reboot"
    elif [ -f "$MANUAL_STOP" ]; then
        echo "hint        : blocked by manual stop (run: sh $0 start)"
    else
        case "$(getprop sys.usb.config 2>/dev/null || true) $(getprop sys.usb.state 2>/dev/null || true)" in
            *adb*)
                echo "hint        : adb connect 192.168.0.1:$ADB_WIFI_PORT && adb -s 192.168.0.1:$ADB_WIFI_PORT shell   # USB adb active: -s required"
                ;;
            *)
                echo "hint        : adb connect 192.168.0.1:$ADB_WIFI_PORT"
                ;;
        esac
    fi
}

usage() {
    cat <<EOF
usage: sh $0 start|stop|apply|status|help
  start    clear manual-stop flag, restore allow chain + property (no adbd restart)
  stop     block the port immediately via $CHAIN REJECT (no adbd restart)
  apply    boot/idle reconcile: property + firewall per config (no adbd restart)
  status   show port/property/listener/pid/firewall/log/hint
  help     this text
config: $CONFIG (ADB_WIFI_PORT=1..65535, ADB_WIFI_ENABLED=1|0, default $DEFAULT_PORT)
note:   adbd is never restarted here; the TCP listener is opened by adbd-preset.sh at boot.
EOF
}

case "${1:-help}" in
    start)   do_start ;;
    stop)    do_stop ;;
    apply)   do_apply ;;
    status)  do_status ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
