#!/bin/sh

set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ADB_BIN="${ADB_BIN:-adb}"
MODE="${1:-apply}"
BASE=/data/local/mwan3-tuning
TARGET=/sbin/sdx75_set_mwan3.sh
HOTPLUG_TARGET=/etc/hotplug.d/iface/90-mwan3-selective-conntrack

if [ "$MODE" != apply ] && [ "$MODE" != --check ]; then
    echo "用法：$0 [--check]" >&2
    exit 2
fi

"$ADB_BIN" get-state >/dev/null
[ "$("$ADB_BIN" shell 'id -u' | tr -d '\r')" = 0 ] || {
    echo "设备端 ADB 不是 root" >&2
    exit 1
}
"$ADB_BIN" shell 'command -v stat >/dev/null'

if [ "$MODE" = --check ]; then
    "$ADB_BIN" shell "
        test -d '$BASE'
        test -x '$BASE/sdx75_set_mwan3.stock.sh'
        if awk -v target='$TARGET' '\$2 == target { found=1 } END { exit !found }' /proc/mounts; then
            test \"\$(stat -c '%d:%i' '$BASE/sdx75-set-mwan3-wrapper.sh')\" = \
                \"\$(stat -c '%d:%i' '$TARGET')\"
        fi
        echo '可以卸载；若当前为 MULTIWAN，mwan3 会短暂重启'
    "
    exit
fi

"$ADB_BIN" push "$HERE/remove-boot-hook.sh" /tmp/remove-mwan3-tuning-boot-hook.sh >/dev/null
if "$ADB_BIN" shell "awk -v target='$TARGET' '\$2 == target { found=1 } END { exit !found }' /proc/mounts"; then
    wrapper_inode="$("$ADB_BIN" shell "stat -c '%d:%i' '$BASE/sdx75-set-mwan3-wrapper.sh' 2>/dev/null" | tr -d '\r' || true)"
    target_inode="$("$ADB_BIN" shell "stat -c '%d:%i' '$TARGET' 2>/dev/null" | tr -d '\r' || true)"
    if [ -z "$wrapper_inode" ] || [ "$wrapper_inode" != "$target_inode" ]; then
        echo "$TARGET 顶层是其他 bind mount，拒绝卸载以免遗留被遮盖的本组件挂载" >&2
        "$ADB_BIN" shell 'rm -f /tmp/remove-mwan3-tuning-boot-hook.sh'
        exit 1
    fi
fi

"$ADB_BIN" shell "
    set -eu
    hook=/tmp/remove-mwan3-tuning-boot-hook.sh
    if [ -x '$BASE/remove-boot-hook.sh' ]; then
        hook='$BASE/remove-boot-hook.sh'
    fi
    # Windows 工作区 push 可能带 CRLF；执行前必须剥掉，否则半卸载
    tr -d '\r' <\"\$hook\" >\"\$hook.lf\" && cat \"\$hook.lf\" >\"\$hook\" && rm -f \"\$hook.lf\"
    chmod 0755 \"\$hook\"
    \"\$hook\"
    rm -f /tmp/remove-mwan3-tuning-boot-hook.sh
"

while "$ADB_BIN" shell "awk -v target='$TARGET' '\$2 == target { found=1 } END { exit !found }' /proc/mounts"; do
    wrapper_inode="$("$ADB_BIN" shell "stat -c '%d:%i' '$BASE/sdx75-set-mwan3-wrapper.sh' 2>/dev/null" | tr -d '\r' || true)"
    target_inode="$("$ADB_BIN" shell "stat -c '%d:%i' '$TARGET' 2>/dev/null" | tr -d '\r' || true)"
    [ -n "$wrapper_inode" ] && [ "$wrapper_inode" = "$target_inode" ] || break
    "$ADB_BIN" shell "umount '$TARGET'"
done

"$ADB_BIN" shell "
    set -eu
    if [ -L '$HOTPLUG_TARGET' ] \
        && [ \"\$(readlink '$HOTPLUG_TARGET')\" = '$BASE/90-mwan3-selective-conntrack' ]; then
        rm -f '$HOTPLUG_TARGET'
    fi

    if [ -f '$BASE/original-targets' ]; then
        original=\$(cat '$BASE/original-targets')
        if [ -n \"\$original\" ]; then
            uci set zwrt_router.multiwan.targets=\"\$original\"
        else
            uci -q delete zwrt_router.multiwan.targets
        fi
        uci commit zwrt_router
    fi

    if [ \"\$(uci -q get zwrt_router.network.opms_wan_mode)\" = MULTIWAN ]; then
        '$BASE/sdx75_set_mwan3.stock.sh'
        /etc/init.d/mwan3 restart
    fi

    # 先移除恢复守护（cron 行），否则脚本删掉后 cron 仍会每 2 分钟报错
    if [ -x '$BASE/install-mode-guard.sh' ]; then
        '$BASE/install-mode-guard.sh' --uninstall >/dev/null 2>&1 || true
    fi

    rm -rf '$BASE'
    rm -rf /tmp/run/mwan3-selective-conntrack
    rm -f /tmp/mwan3-tuning.lock
    sync

    ! grep -q 'TopFlow mwan3 tuning' /etc/rc.local
"

echo "mwan3 tuning 已卸载并恢复厂商生成路径"
