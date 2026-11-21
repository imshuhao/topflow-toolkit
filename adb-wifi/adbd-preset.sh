#!/bin/sh
# ============================================================
# adbd-preset — 在 adbd 启动前预置 service.adb.tcp.port
#
# 由 /etc/init.d/adbd.init 的 start_service() 调用（install-adbd-preset.sh
# 插入一行）。adbd 是 AOSP 10 双模逻辑：启动时先 usb_init()，再读本属性
# setup_port()，因此这里设好就能 USB + TCP 同时监听，且**不需要重启 adbd**。
#
# 属性是内存态：每次开机都要重新设，这就是本脚本存在的理由。
# 关闭无线 ADB：$BASE/config 里 ADB_WIFI_ENABLED=0，重启后不再监听。
# ============================================================
set -u

BASE="${ADB_WIFI_BASE:-/data/adb-wifi}"
CONFIG="$BASE/config"
LOG="${ADB_WIFI_LOG:-/tmp/adb-wifi-watchdog.log}"
DEFAULT_PORT=15555

PORT="$DEFAULT_PORT"
ENABLED=1

# failsafe: rc.local sets this when the TCP listener never came up, so the
# next boot falls back to USB-only instead of repeating a broken preset.
if [ -f "$BASE/state/disable-preset" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') preset: skipped (state/disable-preset)" >> "$LOG" 2>/dev/null || true
    exit 0
fi

if [ -f "$CONFIG" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG" 2>/dev/null || true
fi

PORT=$(printf '%s' "${ADB_WIFI_PORT:-$DEFAULT_PORT}" | tr -d ' \r\t')
case "$PORT" in
    ''|*[!0-9]*|0*) PORT="$DEFAULT_PORT" ;;
esac
[ "${#PORT}" -le 5 ] || PORT="$DEFAULT_PORT"
{ [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; } 2>/dev/null || PORT="$DEFAULT_PORT"

case "$ENABLED" in
    0|no|off|false) exit 0 ;;
esac

if setprop service.adb.tcp.port "$PORT" 2>/dev/null; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') preset: service.adb.tcp.port=$PORT" >> "$LOG" 2>/dev/null || true
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') preset: setprop failed (port $PORT)" >> "$LOG" 2>/dev/null || true
fi
exit 0
