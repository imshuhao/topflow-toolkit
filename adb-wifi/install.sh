#!/bin/sh
# ============================================================
# install.sh — 设备侧安装（脚本已推送到 /data/adb-wifi 后执行）
#
# 做四件事:
#   1. 补 config（从 config.example 复制）
#   2. 给 /etc/init.d/adbd.init 加属性预置（adbd-preset）
#   3. 给 /etc/rc.local 加看门狗钩子
#   4. 立即 apply（设属性 + 建防火墙）
#
# 注意: TCP 监听要下一次重启才出现（adbd 只在启动时读属性）。
# 本脚本不会重启 adbd —— 运行时重启会拆掉 USB gadget，只能重启设备恢复。
# ============================================================
set -u

BASE="${ADB_WIFI_DATA_DIR:-/data/adb-wifi}"
CONFIG="$BASE/config"
EXAMPLE="$BASE/config.example"
WATCHDOG="$BASE/adb-wifi-watchdog.sh"
PIDFILE="$BASE/state/watchdog.pid"

[ -f "$BASE/adb-wifi.sh" ] || { echo "missing $BASE/adb-wifi.sh" >&2; exit 1; }
[ -f "$BASE/adbd-preset.sh" ] || { echo "missing $BASE/adbd-preset.sh" >&2; exit 1; }

mkdir -p "$BASE/state" "$BASE/backup" 2>/dev/null || true

if [ ! -f "$CONFIG" ] && [ -f "$EXAMPLE" ]; then
    cp "$EXAMPLE" "$CONFIG"
    echo "config: created $CONFIG"
fi

sh "$BASE/install-adbd-preset.sh" || exit 1
sh "$BASE/install-boot-hook.sh" || exit 1

sh "$BASE/adb-wifi.sh" apply || true

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null || echo 0)" 2>/dev/null; then
    echo "watchdog: already running (pid $(cat "$PIDFILE"))"
else
    "$WATCHDOG" >/dev/null 2>&1 &
    echo "watchdog: started"
fi

echo
sh "$BASE/adb-wifi.sh" status
echo
echo "next: reboot once so adbd opens tcp:15555 (USB stays up), then:"
echo "  adb connect 192.168.0.1:15555"
