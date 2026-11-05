#!/bin/sh
# ============================================================
# remove-adbd-preset.sh — 还原 /etc/init.d/adbd.init
#
# 删除 install-adbd-preset.sh 插入的三个 marker 块，并把
# procd_set_param command /sbin/adbd 补回 procd_open_instance 之后；
# respawn 那一行按 backup/adbd.init.respawn.orig 原样还原。
# 原子写 + sh -n；没有 marker 时是 no-op。
# 还原后重启一次 adbd 才会回到 USB-only（不运行时重启，避免拆 gadget）。
# ============================================================
set -eu

BASE="${ADB_WIFI_DATA_DIR:-/data/adb-wifi}"
INIT="${ADBD_INIT:-/etc/init.d/adbd.init}"
BACKUP_DIR="$BASE/backup"
BEGIN='# >>> TopFlow adb wifi preset >>>'
END='# <<< TopFlow adb wifi preset <<<'
WBEGIN='# >>> TopFlow adb wifi wrapper >>>'
WEND='# <<< TopFlow adb wifi wrapper <<<'
RBEGIN='# >>> TopFlow adb wifi respawn >>>'
REND='# <<< TopFlow adb wifi respawn <<<'
RESPAWN_ORIG="$BACKUP_DIR/adbd.init.respawn.orig"
# 没有保存原件时的出厂默认（与安装前实测一致）
RESPAWN_DEFAULT='	procd_set_param respawn ${respawn_threshold:-3600} ${respawn_timeout:-5} ${respawn_retry:-10}'
CMD='	procd_set_param command /sbin/adbd'

[ -f "$INIT" ] || { echo "adbd init not found: $INIT" >&2; exit 1; }
[ -w "$INIT" ] || { echo "adbd init not writable: $INIT" >&2; exit 1; }

if ! grep -qF "$BEGIN" "$INIT" && ! grep -qF "$WBEGIN" "$INIT" && ! grep -qF "$RBEGIN" "$INIT"; then
    echo "no adbd preset in $INIT, nothing to do"
    exit 0
fi

TMP="$INIT.adb-wifi.new"

# ---------- 第一步：respawn 还原（先做，避免后续 pass 干扰） ----------
if grep -qF "$RBEGIN" "$INIT"; then
    _orig="$RESPAWN_DEFAULT"
    if [ -f "$RESPAWN_ORIG" ]; then
        _orig=$(cat "$RESPAWN_ORIG")
    fi
    awk -v begin="$RBEGIN" -v end="$REND" -v orig="$_orig" '
    index($0, begin) > 0 { skip = 1; print orig; next }
    index($0, end) > 0 && skip { skip = 0; next }
    skip { next }
    { print }
    ' "$INIT" > "$TMP" || { rc=$?; rm -f "$TMP"; echo "respawn restore failed (rc=$rc)" >&2; exit 1; }

    if grep -qF "$RBEGIN" "$TMP"; then
        rm -f "$TMP"
        echo "unterminated respawn marker block, $INIT untouched" >&2
        exit 1
    fi
    if ! sh -n "$TMP"; then
        rm -f "$TMP"
        echo "respawn restore syntax check failed, $INIT untouched" >&2
        exit 1
    fi
    chmod 0755 "$TMP" 2>/dev/null || true
    mv -f "$TMP" "$INIT"
    echo "adbd respawn restored: $INIT"
fi

# ---------- 第二步：preset / wrapper 还原 ----------
if ! grep -qF "$BEGIN" "$INIT" && ! grep -qF "$WBEGIN" "$INIT"; then
    echo "no adbd preset/wrapper block in $INIT"
    if [ -f "$BACKUP_DIR/adbd.init.bak-pre-adbwifi" ]; then
        echo "backup kept: $BACKUP_DIR/adbd.init.bak-pre-adbwifi"
    fi
    echo "reboot once to return adbd to USB-only"
    exit 0
fi

awk -v begin="$BEGIN" -v end="$END" -v wbegin="$WBEGIN" -v wend="$WEND" '
index($0, begin) > 0 || index($0, wbegin) > 0 { skip = 1; next }
index($0, end) > 0 && skip { skip = 0; next }
index($0, wend) > 0 && skip { skip = 0; need_cmd = 1; next }
skip { next }
{ print }
END {
    if (need_cmd) {
        # 重新读入已在 stdout 的内容无法回插，改用二次处理
        exit 10
    }
}
' "$INIT" > "$TMP" || {
    rc=$?
    if [ "$rc" -eq 10 ]; then
        # 需要补回命令行：在 procd_open_instance 之后插入
        mv -f "$TMP" "$TMP.1"
        awk -v cmd="$CMD" '
        { print }
        /^[[:space:]]*procd_open_instance[[:space:]]*$/ && !done { print cmd; done = 1 }
        END { if (!done) exit 3 }
        ' "$TMP.1" > "$TMP" || { rm -f "$TMP" "$TMP.1"; echo "restore command failed" >&2; exit 1; }
        rm -f "$TMP.1"
    else
        rm -f "$TMP"
        echo "rewrite failed (rc=$rc)" >&2
        exit 1
    fi
}

if grep -qF "$BEGIN" "$TMP" || grep -qF "$WBEGIN" "$TMP"; then
    rm -f "$TMP"
    echo "unterminated marker block, $INIT untouched" >&2
    exit 1
fi

if ! grep -qE '^[[:space:]]*procd_set_param command[[:space:]]+/sbin/adbd[[:space:]]*$' "$TMP"; then
    rm -f "$TMP"
    echo "restored file has no /sbin/adbd command, $INIT untouched" >&2
    exit 1
fi

if ! sh -n "$TMP"; then
    rm -f "$TMP"
    echo "syntax check failed, $INIT untouched" >&2
    exit 1
fi

chmod 0755 "$TMP" 2>/dev/null || true
mv -f "$TMP" "$INIT"
echo "adbd preset removed: $INIT"
if [ -f "$BACKUP_DIR/adbd.init.bak-pre-adbwifi" ]; then
    echo "backup kept: $BACKUP_DIR/adbd.init.bak-pre-adbwifi"
fi
echo "reboot once to return adbd to USB-only"
