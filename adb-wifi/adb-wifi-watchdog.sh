#!/bin/sh
# ============================================================
# adb-wifi-watchdog — 无线 ADB 自愈（30s 周期，busybox ash）
#
# 作用:
#   保证 ADB_WIFI 防火墙链与配置一致、service.adb.tcp.port 为期望值，
#   并在监听缺失时留下可诊断日志。
#
# 铁律（2026-10-27 实机事故）:
#   **绝不重启 adbd**。本机 adbd 退出会拆掉 functionfs，新 adbd 再打开
#   ep0 失败，USB gadget（含 RNDIS）整体消失，只能重启设备恢复。
#   因此本脚本只做：补属性（供下次 adbd 启动使用）、重建防火墙、记录状态。
#
# 循环:
#   · 30s 一轮；单实例: mkdir 锁目录 + state/watchdog.pid
#   · /tmp/adb-wifi-manual-stop 存在或 ADB_WIFI_ENABLED=0 → 维持 block 链
#   · 正常时每 10 轮（约 5 分钟）打一条 "watch:" 心跳
#   · 监听缺失每 10 轮才记一次，避免刷屏
#   · 日志 /tmp/adb-wifi-watchdog.log 超 1MB 时只留尾部 512KB
#
# 路径:
#   BASE=/data/adb-wifi（ADB_WIFI_BASE 可覆盖）
#   $BASE/config 由 adb-wifi.sh 维护，这里只读
#
# 停止 / 回滚:
#   kill "$(cat /data/adb-wifi/state/watchdog.pid)"   # trap 清锁目录
#   sh /data/adb-wifi/adb-wifi.sh stop                # 封端口
#   sh /data/adb-wifi/remove-boot-hook.sh             # 去 rc.local 钩子
#   sh /data/adb-wifi/remove-adbd-preset.sh           # 还原 adbd.init
# ============================================================
set -u

BASE="${ADB_WIFI_BASE:-/data/adb-wifi}"
CONFIG="$BASE/config"
STATE="$BASE/state"
PORT_STATE="$STATE/port"
LOCK="$STATE/watchdog.lock"
PIDFILE="$STATE/watchdog.pid"
LOG="${ADB_WIFI_WATCHDOG_LOG:-/tmp/adb-wifi-watchdog.log}"
MANUAL_STOP="/tmp/adb-wifi-manual-stop"
CHAIN=ADB_WIFI
DEFAULT_PORT=15555
INTERVAL=30

PORT="$DEFAULT_PORT"
ENABLED=1
CYCLE=0

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

is_port() {
    case "${1:-}" in
        ''|*[!0-9]*|0*) return 1 ;;
    esac
    [ "${#1}" -le 5 ] || return 1
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

load_config() {
    PORT="$DEFAULT_PORT"
    ENABLED=1
    if [ -f "$CONFIG" ]; then
        # shellcheck source=/dev/null
        . "$CONFIG" 2>/dev/null || true
    fi
    PORT=$(printf '%s' "${ADB_WIFI_PORT:-$DEFAULT_PORT}" | tr -d ' \r\t')
    is_port "$PORT" || PORT="$DEFAULT_PORT"
    case "$ENABLED" in
        0|no|off|false) ENABLED=0 ;;
        *) ENABLED=1 ;;
    esac
}

listener_up() {
    netstat -ltn 2>/dev/null | grep -q ":$PORT "
}

prune_stale_jump() {
    _prev=""
    if [ -f "$PORT_STATE" ]; then
        _prev=$(cat "$PORT_STATE" 2>/dev/null || true)
    fi
    if [ -n "$_prev" ] && [ "$_prev" != "$PORT" ] && is_port "$_prev"; then
        while iptables -D INPUT -p tcp --dport "$_prev" -j "$CHAIN" 2>/dev/null; do :; done
        log "fw: removed stale INPUT jump for port $_prev"
    fi
}

ensure_firewall() {
    _mode="${1:-allow}"
    prune_stale_jump
    iptables -N "$CHAIN" 2>/dev/null || true
    iptables -F "$CHAIN" 2>/dev/null || true
    if [ "$_mode" = block ]; then
        iptables -A "$CHAIN" -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null || true
        iptables -A "$CHAIN" -j REJECT 2>/dev/null || true
    else
        iptables -A "$CHAIN" -i lo -j ACCEPT 2>/dev/null || true
        iptables -A "$CHAIN" -i br-lan -j ACCEPT 2>/dev/null || true
        iptables -A "$CHAIN" -j DROP 2>/dev/null || true
    fi
    if ! iptables -C INPUT -p tcp --dport "$PORT" -j "$CHAIN" 2>/dev/null; then
        iptables -I INPUT 1 -p tcp --dport "$PORT" -j "$CHAIN" 2>/dev/null || \
            log "fw: insert INPUT jump failed"
    fi
    mkdir -p "$STATE" 2>/dev/null || true
    printf '%s\n' "$PORT" > "$PORT_STATE" 2>/dev/null || true

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
    return 0
}

rotate_log() {
    [ -f "$LOG" ] || return 0
    [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] || return 0
    tail -c 524288 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
    rm -f "$LOG.tmp" 2>/dev/null || true
}

# ---------- 单实例 ----------
mkdir -p "$STATE" 2>/dev/null || true
if ! mkdir "$LOCK" 2>/dev/null; then
    _old=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
        exit 0
    fi
    rmdir "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || exit 0
fi
cleanup() { rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 0' INT TERM
echo $$ > "$PIDFILE"

log "watchdog: started (pid $$)"

while :; do
    CYCLE=$((CYCLE + 1))
    load_config

    if [ "$ENABLED" = 0 ] || [ -f "$MANUAL_STOP" ]; then
        if ! ensure_firewall block; then
            log "watch: block chain incomplete (port $PORT)"
        fi
        rotate_log
        sleep "$INTERVAL"
        continue
    fi

    if ! ensure_firewall allow; then
        log "watch: allow chain incomplete (port $PORT)"
    fi

    _prop=$(getprop service.adb.tcp.port 2>/dev/null || true)
    if [ "$_prop" != "$PORT" ]; then
        setprop service.adb.tcp.port "$PORT" >> "$LOG" 2>&1 || \
            log "watch: setprop failed (port $PORT)"
        log "watch: property was '${_prop:-unset}', restored to $PORT (effective at next adbd start)"
    fi

    if listener_up; then
        if [ $((CYCLE % 10)) -eq 0 ]; then
            log "watch: port=$PORT listener=up adbd=$(pidof adbd 2>/dev/null || echo none)"
        fi
    elif [ $((CYCLE % 10)) -eq 0 ]; then
        log "watch: port=$PORT listener=DOWN adbd=$(pidof adbd 2>/dev/null || echo none) (adbd is never restarted; reboot if it stays down)"
    fi

    rotate_log
    sleep "$INTERVAL"
done
