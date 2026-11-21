#!/bin/sh
# ============================================================
# adb-wifi/deploy.sh — 一键推送并安装无线 ADB 组件
#
# 用法（PC 侧，仓库根目录或任意目录）:
#   sh adb-wifi/deploy.sh                # 推送 + 安装
#   sh adb-wifi/deploy.sh --no-install   # 只推送，不安装
#
# 环境变量:
#   ADB          adb 可执行文件（默认 adb）
#   ADB_SERIAL   多设备时指定 serial（USB: 0123456789ABCDEF / 无线: 192.168.0.1:15555）
#   ADB_WIFI_BASE 设备侧目录（默认 /data/adb-wifi）
#
# 说明:
#   · 逐文件 push 后 tr -d '\r' 去 CR，chmod 755，sh -n 校验
#   · 安装会改 /etc/init.d/adbd.init 与 /etc/rc.local（均有备份、可一键还原）
#   · TCP 监听要重启后才出现（adbd 只在进程启动时读端口）
#   · 全程不重启 adbd（运行时重启会拆 USB gadget）
# ============================================================
set -eu

MSYS_NO_PATHCONV=1
MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if command -v cygpath >/dev/null 2>&1; then
    ROOT=$(cygpath -w "$ROOT")
fi

DEV="${ADB_WIFI_BASE:-/data/adb-wifi}"
ADB="${ADB:-adb}"

adb_run() {
    if [ -n "${ADB_SERIAL:-}" ]; then
        "$ADB" -s "$ADB_SERIAL" "$@"
    else
        "$ADB" "$@"
    fi
}

FILES="adb-wifi.sh adb-wifi-watchdog.sh adbd-preset.sh adbd-wrapper.sh
install-adbd-preset.sh remove-adbd-preset.sh
install-boot-hook.sh remove-boot-hook.sh install.sh config.example"

echo "deploy: $ROOT -> $DEV"
adb_run shell "mkdir -p '$DEV/state' '$DEV/backup'"

# shellcheck disable=SC2086
for f in $FILES; do
    if [ ! -f "$ROOT/$f" ]; then
        echo "missing $ROOT/$f" >&2
        exit 1
    fi
    adb_run push "$ROOT/$f" "/tmp/$f" >/dev/null
    adb_run shell "tr -d '\r' < '/tmp/$f' > '$DEV/$f'; chmod 755 '$DEV/$f'"
done

echo "syntax check"
# shellcheck disable=SC2086
for f in $FILES; do
    case "$f" in
        *.sh)
            adb_run shell "sh -n '$DEV/$f'" || {
                echo "syntax error: $f" >&2
                exit 1
            }
            ;;
    esac
done
echo "syntax ok"

if [ "${1:-}" = "--no-install" ]; then
    echo "pushed to $DEV (not installed)"
    exit 0
fi

echo "install"
adb_run shell "sh '$DEV/install.sh'"
echo
echo "next: reboot once so adbd opens tcp:15555"
echo "      adb connect 192.168.0.1:15555"
