#!/bin/sh
# 15s watchdog for sing-box. flock-like single instance via lock directory.
set -u

BASE="${SINGBOX_BASE:-/data/sing-box}"
LOG="${SINGBOX_WATCHDOG_LOG:-/tmp/sing-box-watchdog.log}"
LOCK="$BASE/state/watchdog.lock"
PIDFILE="$BASE/state/watchdog.pid"
MANUAL_STOP="/tmp/sing-box-manual-stop"
SERVICE="$BASE/sing-box.sh"
BALANCE="$BASE/singbox-wan-balance.sh"
CORE_LOG="$BASE/state/sing-box.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

mkdir -p "$BASE/state" 2>/dev/null
if ! mkdir "$LOCK" 2>/dev/null; then
    old=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
        exit 0
    fi
    rmdir "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || exit 0
fi
cleanup() { rmdir "$LOCK" 2>/dev/null; }
trap cleanup EXIT
trap 'exit 0' INT TERM
echo $$ > "$PIDFILE"

while :; do
    if [ -f "$MANUAL_STOP" ]; then
        sleep 15
        continue
    fi
    if ! "$SERVICE" status 2>/dev/null | grep -q 'core: running'; then
        log "core not running; restart"
        SINGBOX_NO_WATCHDOG=1 "$SERVICE" start >> "$LOG" 2>&1 || log "restart failed"
    fi
    # Refresh the per-connection WAN pool from live mwan3 state. Cheap and
    # idempotent: it only rewrites nft/ip rule when the pool changes.
    if [ -x "$BALANCE" ]; then
        "$BALANCE" apply >/dev/null 2>&1 || log "wan balance apply failed"
    fi
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then
        tail -c 524288 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
    if [ -f "$CORE_LOG" ] && [ "$(wc -c < "$CORE_LOG")" -gt 2097152 ]; then
        tail -c 1048576 "$CORE_LOG" > "$CORE_LOG.tmp" && cat "$CORE_LOG.tmp" > "$CORE_LOG" && rm -f "$CORE_LOG.tmp"
    fi
    sleep 15
done
