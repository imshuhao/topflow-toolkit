#!/bin/sh

set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ADB_BIN="${ADB_BIN:-adb}"
BASE=/data/local/mwan3-tuning
TARGET=/sbin/sdx75_set_mwan3.sh
KNOWN_STOCK_SHA=74bd9bdbd3f76ee674cc7d7fe1e53358e5f5188883ef1413478fb1e32e48f541
TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_DIR="$(mktemp -d "$TEMP_ROOT/topflow-mwan3-install.XXXXXX")"

cleanup() {
    case "$TEMP_DIR" in
        "$TEMP_ROOT"/topflow-mwan3-install.*) rm -rf "$TEMP_DIR" ;;
    esac
}
trap cleanup EXIT INT TERM

for file in \
    apply-rules.sh \
    90-mwan3-selective-conntrack \
    sdx75-set-mwan3-wrapper.sh \
    activate.sh \
    config.example \
    install-boot-hook.sh; do
    [ -f "$HERE/$file" ] || {
        echo "缺少安装文件：$HERE/$file" >&2
        exit 1
    }
done

"$ADB_BIN" get-state >/dev/null
[ "$("$ADB_BIN" shell 'id -u' | tr -d '\r')" = 0 ] || {
    echo "设备端 ADB 不是 root" >&2
    exit 1
}

if "$ADB_BIN" shell "awk -v target='$TARGET' '\$2 == target { found=1 } END { exit !found }' /proc/mounts"; then
    wrapper_inode="$("$ADB_BIN" shell "stat -c '%d:%i' '$BASE/sdx75-set-mwan3-wrapper.sh' 2>/dev/null" | tr -d '\r' || true)"
    target_inode="$("$ADB_BIN" shell "stat -c '%d:%i' '$TARGET' 2>/dev/null" | tr -d '\r' || true)"
    if [ -n "$wrapper_inode" ] && [ "$wrapper_inode" = "$target_inode" ] \
        && "$ADB_BIN" shell "test -x '$BASE/sdx75_set_mwan3.stock.sh'"; then
        mount_state=ours
    else
        mount_state=other
    fi
else
    mount_state=stock
fi

case "$mount_state" in
    stock)
        "$ADB_BIN" exec-out cat "$TARGET" >"$TEMP_DIR/stock.sh"
        ;;
    ours)
        "$ADB_BIN" exec-out cat "$BASE/sdx75_set_mwan3.stock.sh" >"$TEMP_DIR/stock.sh"
        ;;
    other)
        echo "$TARGET 已被其他来源 bind mount，拒绝覆盖" >&2
        exit 1
        ;;
esac

if command -v sha256sum >/dev/null; then
    stock_sha="$(sha256sum "$TEMP_DIR/stock.sh" | awk '{print $1}')"
else
    stock_sha="$(shasum -a 256 "$TEMP_DIR/stock.sh" | awk '{print $1}')"
fi
[ "$stock_sha" = "$KNOWN_STOCK_SHA" ] || {
    echo "原厂脚本摘要不匹配；当前公开补丁只支持已验证的 B22 文件（与 B20 同哈希）" >&2
    exit 1
}

"$ADB_BIN" shell '
    command -v uci >/dev/null
    command -v flock >/dev/null
    command -v conntrack >/dev/null
    command -v stat >/dev/null
    test -f /etc/rc.local
    test -d /etc/hotplug.d/iface
'

if [ "$mount_state" = ours ]; then
    while "$ADB_BIN" shell "awk -v target='$TARGET' '\$2 == target { found=1 } END { exit !found }' /proc/mounts"; do
        wrapper_inode="$("$ADB_BIN" shell "stat -c '%d:%i' '$BASE/sdx75-set-mwan3-wrapper.sh' 2>/dev/null" | tr -d '\r' || true)"
        target_inode="$("$ADB_BIN" shell "stat -c '%d:%i' '$TARGET' 2>/dev/null" | tr -d '\r' || true)"
        [ -n "$wrapper_inode" ] && [ "$wrapper_inode" = "$target_inode" ] || break
        "$ADB_BIN" shell "umount '$TARGET'"
    done
fi

if "$ADB_BIN" shell "awk -v target='$TARGET' '\$2 == target { found=1 } END { exit !found }' /proc/mounts"; then
    echo "$TARGET 清理本组件挂载后仍存在其他 bind mount，拒绝覆盖" >&2
    exit 1
fi

"$ADB_BIN" shell "mkdir -p '$BASE/.install'; chmod 0700 '$BASE/.install'"
"$ADB_BIN" push "$TEMP_DIR/stock.sh" "$BASE/.install/sdx75_set_mwan3.stock.sh" >/dev/null
for file in \
    apply-rules.sh \
    90-mwan3-selective-conntrack \
    sdx75-set-mwan3-wrapper.sh \
    activate.sh \
    config.example \
    install-boot-hook.sh; do
    "$ADB_BIN" push "$HERE/$file" "$BASE/.install/$file" >/dev/null
done

"$ADB_BIN" shell "
    set -e
    chmod 0755 \
        '$BASE/.install/'*.sh \
        '$BASE/.install/90-mwan3-selective-conntrack' \
        '$BASE/.install/sdx75_set_mwan3.stock.sh'
    if [ ! -f '$BASE/original-targets' ]; then
        uci -q get zwrt_router.multiwan.targets >'$BASE/original-targets' \
            || : >'$BASE/original-targets'
    fi
    chmod 0600 '$BASE/original-targets'
    mv -f '$BASE/.install/sdx75_set_mwan3.stock.sh' '$BASE/sdx75_set_mwan3.stock.sh'
    mv -f '$BASE/.install/apply-rules.sh' '$BASE/apply-rules.sh'
    mv -f '$BASE/.install/90-mwan3-selective-conntrack' '$BASE/90-mwan3-selective-conntrack'
    mv -f '$BASE/.install/sdx75-set-mwan3-wrapper.sh' '$BASE/sdx75-set-mwan3-wrapper.sh'
    mv -f '$BASE/.install/activate.sh' '$BASE/activate.sh'
    mv -f '$BASE/.install/install-boot-hook.sh' '$BASE/install-boot-hook.sh'
    [ -f '$BASE/config' ] || cp '$BASE/.install/config.example' '$BASE/config'
    chmod 0600 '$BASE/config'
    rm -rf '$BASE/.install'
    '$BASE/install-boot-hook.sh'
    '$BASE/activate.sh'
    sync
"

"$ADB_BIN" shell "test -x '$BASE/sdx75_set_mwan3.stock.sh'; test -L /etc/hotplug.d/iface/90-mwan3-selective-conntrack; awk -v target='$TARGET' '\$2 == target { found=1 } END { exit !found }' /proc/mounts"
wrapper_inode="$("$ADB_BIN" shell "stat -c '%d:%i' '$BASE/sdx75-set-mwan3-wrapper.sh'" | tr -d '\r')"
target_inode="$("$ADB_BIN" shell "stat -c '%d:%i' '$TARGET'" | tr -d '\r')"
[ "$wrapper_inode" = "$target_inode" ]

echo "mwan3 tuning 已安装；MULTIWAN 下 mwan3 已按新策略重新加载"
