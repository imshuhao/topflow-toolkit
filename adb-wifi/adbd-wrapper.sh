#!/bin/sh
# ============================================================
# adbd-wrapper v5 - 2026-10-31 (always keep functionfs)
#
# v2 教训: 开机 +1s 读 usb/online=0 -> 误判无主机.
# v3 教训: 开机 +13s 读到 online=1 但 type_mbb=0 (还没稳定) -> 误判无主机
#    -> 隐藏 ffs -> +34s gadget 组合 "failed to start g1: -19" -> gadget 消失.
# v4 教训 (2026-10-31): type_mbb 白名单 {4,5} 太窄。本次开机 +13s 读到
#   type_mbb=9 (瞬态, 之后稳定在 4=SDP) -> 判成充电器 -> `mount -t tmpfs`
#   盖住 /dev/usb-ffs/adb -> adbd 打不开 functionfs ep0 -> ffs.adb 没有接口
#   -> gadget 组合失败 -> g1/UDC 为空, udc "not attached" -> 主机零到达事件,
#   USB ADB 与 RNDIS 一起消失 (整条 USB 全灭, 不只是 ADB).
#
# v5 逻辑: 永不隐藏 functionfs.
#   * 藏 ffs 是自毁: 只要 ffs 里没有 daemon 打开 ep0, 组合就一定失败,
#     无论插的是电脑还是充电器. 保留 ffs 时, 充电器上最多多枚举一个复合设备,
#     插回电脑立刻可用, 没有代价.
#   * service.adb.tcp.port 仍然先设, TCP ADB 与 USB 互不影响.
#   * v4 的探测结果继续记日志 (只读), 供下次定位, 但不再驱动任何动作.
#
# 强制模式 (仅影响探测等待, 不再影响 ffs):
#   /data/adb-wifi/wrapper.forcemode 写 host / tcp / auto
# 回滚: cp -p /data/adb-wifi/adbd-wrapper.sh.bak-v4 /data/adb-wifi/adbd-wrapper.sh
# ============================================================
set -u

LOG=/tmp/adb-wifi-watchdog.log
FORCE=/data/adb-wifi/wrapper.forcemode
ADB_PORT=15555

_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') wrapper: $1" >> "$LOG" 2>/dev/null || true; }

# --- 1) 端口属性 ----------------------------------------------
_i=0
_prop_ok=0
while [ "$_i" -lt 20 ]; do
    setprop service.adb.tcp.port "$ADB_PORT" 2>/dev/null || true
    if [ "$(getprop service.adb.tcp.port 2>/dev/null)" = "$ADB_PORT" ]; then
        _prop_ok=1
        break
    fi
    sleep 1
    _i=$((_i + 1))
done
_log "v5: property ready=$_prop_ok after ${_i}s (port=$ADB_PORT)"

_force=""
if [ -f "$FORCE" ]; then
    _force=$(tr -d ' \r\t\n' < "$FORCE" 2>/dev/null || true)
fi

# --- 2) 只读探测 (诊断用, 不驱动动作) --------------------------
_online=0
_ctype=""
if [ "$_force" != "tcp" ]; then
    _i=0
    while [ "$_i" -lt 30 ]; do
        _online=$(cat /sys/class/power_supply/usb/online 2>/dev/null || echo 0)
        [ "$_online" = "1" ] && break
        sleep 1
        _i=$((_i + 1))
    done
    _t0=$_i
    _j=0
    while [ "$_j" -lt 20 ]; do
        _ctype=$(cat /sys/class/power_supply/charger_zte/type_mbb 2>/dev/null || echo "")
        case "$_ctype" in
            ''|0) sleep 1; _j=$((_j + 1)) ;;
            *)    break ;;
        esac
    done
    _log "v5: usb probe online=$_online type_mbb=$_ctype (online wait ${_t0}s, type wait ${_j}s)"
else
    _log "v5: forcemode=tcp, probe skipped"
fi

# --- 3) functionfs 保持可见 ------------------------------------
if mount 2>/dev/null | grep '/dev/usb-ffs/adb' | grep -q 'type tmpfs'; then
    # Left over from a v4 boot: unhide so adbd can open ep0 again.
    umount /dev/usb-ffs/adb 2>/dev/null || true
    _log "v5: removed stale tmpfs over /dev/usb-ffs/adb"
fi
_log "v5: functionfs kept visible (online=$_online type=$_ctype)"

exec /sbin/adbd
