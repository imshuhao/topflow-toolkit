#!/bin/sh
# ============================================================
# install-adbd-preset.sh — 让 adbd 开机时真正读到 TCP 端口
#
# 为什么不能只 setprop:
#   实测 propwatch.log：开机前 ~40s，setprop 返回 0 但属性区未就绪，
#   getprop 读不到；adbd 在 S10（~17s）启动，属性必为空 → 只开 USB。
#   rc.local（~46s）之后 setprop 才真正生效。
#
# 做法（/etc/init.d/adbd.init，/etc 是 overlay，可写、持久）:
#   1. start_service() 开头插入 adbd-preset.sh（早设一次，无害）
#   2. 把 procd_set_param command /sbin/adbd 换成 /bin/sh -c 包装：
#      等 rc.local 的 /tmp/adb-wifi-rc-done（最多 60s）再 exec adbd；
#      文件缺失/超时都退回 /sbin/adbd，不会锁死。
#   3. **respawn 加固**：把 procd_set_param respawn 的 retry 从 10 抬到 1000。
#      原因：实测「客户端连上再断开」会让 adbd 退出（见 HANDOVER §24.9/§24.11），
#      默认 10 次/小时很快就打光，procd 放弃后 adbd 永久 down，只能整机重启。
#      原行原样保存在 backup/adbd.init.respawn.orig，供 remove 脚本精确还原。
#
# 备份: /data/adb-wifi/backup/adbd.init.bak-pre-adbwifi（只备份一次）
# 回滚: sh /data/adb-wifi/remove-adbd-preset.sh  然后重启
# 每一步都是 marker 幂等的，可以重复执行。
# ============================================================
set -eu

BASE="${ADB_WIFI_DATA_DIR:-/data/adb-wifi}"
INIT="${ADBD_INIT:-/etc/init.d/adbd.init}"
BACKUP_DIR="$BASE/backup"
BACKUP="$BACKUP_DIR/adbd.init.bak-pre-adbwifi"
BEGIN='# >>> TopFlow adb wifi preset >>>'
END='# <<< TopFlow adb wifi preset <<<'
WBEGIN='# >>> TopFlow adb wifi wrapper >>>'
WEND='# <<< TopFlow adb wifi wrapper <<<'
RBEGIN='# >>> TopFlow adb wifi respawn >>>'
REND='# <<< TopFlow adb wifi respawn <<<'
RESPAWN_ORIG="$BACKUP_DIR/adbd.init.respawn.orig"
# retry=1000：不依赖 procd 对 0 / -1 的具体语义，显式给一个「一小时内几乎用不完」的次数
RESPAWN_NEW='	procd_set_param respawn ${respawn_threshold:-3600} ${respawn_timeout:-5} ${respawn_retry:-1000}'

[ -f "$INIT" ] || { echo "adbd init not found: $INIT" >&2; exit 1; }
[ -w "$INIT" ] || { echo "adbd init not writable: $INIT" >&2; exit 1; }

mkdir -p "$BACKUP_DIR" 2>/dev/null || true
if [ ! -f "$BACKUP" ]; then
    cp "$INIT" "$BACKUP" || { echo "backup failed: $BACKUP" >&2; exit 1; }
    echo "backup: $BACKUP"
fi

TMP="$INIT.adb-wifi.new"
have_wrapper=0
grep -qF "$WBEGIN" "$INIT" && have_wrapper=1

if [ "$have_wrapper" = 0 ]; then
    have_preset=0
    grep -qF "$BEGIN" "$INIT" && have_preset=1

    awk -v begin="$BEGIN" -v end="$END" -v wbegin="$WBEGIN" -v wend="$WEND" \
        -v have_preset="$have_preset" -v have_wrapper="$have_wrapper" '
    BEGIN { inserted = (have_preset == 1); wrapped = (have_wrapper == 1) }
    {
        if (!wrapped && $0 ~ /^[[:space:]]*procd_set_param command[[:space:]]+\/sbin\/adbd[[:space:]]*$/) {
            print "\t" wbegin
            print "\tprocd_set_param command /bin/sh -c \"[ -f /data/adb-wifi/adbd-wrapper.sh ] && exec sh /data/adb-wifi/adbd-wrapper.sh; exec /sbin/adbd\""
            print "\t" wend
            wrapped = 1
            next
        }
        print
        if (!inserted && $0 ~ /^start_service[[:space:]]*\(\)[[:space:]]*\{/) {
            print "\t" begin
            print "\t[ -x /data/adb-wifi/adbd-preset.sh ] && /data/adb-wifi/adbd-preset.sh"
            print "\t" end
            inserted = 1
        }
    }
    END { if (!inserted || !wrapped) exit 3 }
    ' "$INIT" > "$TMP" || { rc=$?; rm -f "$TMP"; echo "patch failed (rc=$rc; start_service/procd command not found)" >&2; exit 1; }

    if [ "$(grep -cF "$BEGIN" "$TMP")" -ne 1 ] || [ "$(grep -cF "$WBEGIN" "$TMP")" -ne 1 ]; then
        rm -f "$TMP"
        echo "patch failed (marker count != 1)" >&2
        exit 1
    fi

    if ! sh -n "$TMP"; then
        rm -f "$TMP"
        echo "syntax check failed, $INIT untouched" >&2
        exit 1
    fi

    chmod 0755 "$TMP" 2>/dev/null || true
    mv -f "$TMP" "$INIT"
    echo "adbd preset + wrapper installed: $INIT"
else
    echo "adbd wrapper already installed: $INIT"
fi

# ---------- 第三步：respawn 加固（独立 marker，可单独补装） ----------
if grep -qF "$RBEGIN" "$INIT"; then
    echo "adbd respawn already hardened: $INIT"
else
    _orig=$(grep -E '^[[:space:]]*procd_set_param[[:space:]]+respawn' "$INIT" | head -n 1 || true)
    if [ -z "$_orig" ]; then
        echo "respawn line not found in $INIT, $INIT untouched" >&2
        exit 1
    fi
    if [ ! -f "$RESPAWN_ORIG" ]; then
        printf '%s\n' "$_orig" > "$RESPAWN_ORIG" || {
            echo "cannot save original respawn line to $RESPAWN_ORIG" >&2
            exit 1
        }
        echo "respawn original saved: $RESPAWN_ORIG"
    fi

    awk -v begin="$RBEGIN" -v end="$REND" -v new="$RESPAWN_NEW" '
    !done && $0 ~ /^[[:space:]]*procd_set_param[[:space:]]+respawn/ {
        print begin
        print new
        print end
        done = 1
        next
    }
    { print }
    END { if (!done) exit 3 }
    ' "$INIT" > "$TMP" || { rc=$?; rm -f "$TMP"; echo "respawn patch failed (rc=$rc)" >&2; exit 1; }

    if [ "$(grep -cF "$RBEGIN" "$TMP")" -ne 1 ] || [ "$(grep -cF "$REND" "$TMP")" -ne 1 ]; then
        rm -f "$TMP"
        echo "respawn patch failed (marker count != 1)" >&2
        exit 1
    fi

    if ! sh -n "$TMP"; then
        rm -f "$TMP"
        echo "respawn syntax check failed, $INIT untouched" >&2
        exit 1
    fi

    chmod 0755 "$TMP" 2>/dev/null || true
    mv -f "$TMP" "$INIT"
    echo "adbd respawn hardened (retry 10 -> 1000): $INIT"
fi

echo "note: takes effect on next boot; adbd is never restarted at runtime"
