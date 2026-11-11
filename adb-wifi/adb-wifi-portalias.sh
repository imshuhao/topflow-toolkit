#!/bin/sh
# ============================================================
# adb-wifi-portalias — 手机 ADB 客户端「写死 5555」兼容层（LAN 侧端口别名）
#
# 用途:
#   部分手机 ADB App 只给「IP + 用户名 + 密码」三个输入框，端口写死 5555，
#   连不到本机的 15555。本脚本在 **nat PREROUTING** 做 LAN 侧端口别名：
#       br-lan 上的客户端 → 192.168.0.1:5555  ==> REDIRECT 到 15555
#   adbd 依旧只监听 15555，设备侧不重启、不改属性、不写配置。
#
# 铁律（与 adb-wifi 其它组件一致）:
#   · 不重启 adbd、不改 service.adb.tcp.port、不碰 /data/adb-wifi/config、
#     不改 rc.local、不碰看门狗。
#   · **一次性**：本脚本自己不做持久化，重启后规则消失，需要重新 `on`。
#   · 只对 br-lan + 目的地址 192.168.0.1 生效，WAN 侧永远不暴露。
#   · 不落任何 state/ 文件；唯一设备侧副作用是 nat 表里的
#     ADB_WIFI_ALIAS 链 + 一条 PREROUTING 跳转。
#
# 链路:
#   nat PREROUTING -i br-lan -d 192.168.0.1 -p tcp --dport 5555 -j ADB_WIFI_ALIAS
#   ADB_WIFI_ALIAS -p tcp -j REDIRECT --to-ports 15555
#   → 包进入 INPUT 时 dport 已是 15555，命中 ADB_WIFI 链的 br-lan ACCEPT
#
# 用法: sh adb-wifi-portalias.sh on|off|status|help
#   on      建链 + 建跳转（幂等；重复执行只有一套规则）
#   off     拆掉本脚本自己的跳转与链（幂等；不碰别人的 nat 规则）
#   status  打印链内容 / 跳转 / 5555 当前是否在重定向 / 15555 监听状态
#   help    本帮助
#
# 注意:
#   · fw3 reload（/etc/init.d/firewall reload 或 UCI 提交防火墙）会清空 nat 表，
#     别名随之消失 → 重新 `on` 即可。
#   · 别名开着时，15555 依旧直连可用，两条路并存。
# ============================================================
set -u

BASE="${ADB_WIFI_BASE:-/data/adb-wifi}"
CONFIG="$BASE/config"
CHAIN=ADB_WIFI_ALIAS
ALIAS_PORT=5555
LAN_IF=br-lan
LAN_IP=192.168.0.1
DEFAULT_PORT=15555

ADB_WIFI_PORT="$DEFAULT_PORT"

is_port() {
    case "${1:-}" in
        ''|*[!0-9]*|0*) return 1 ;;
    esac
    [ "${#1}" -le 5 ] || return 1
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# 与 adb-wifi.sh 相同的读配置方式：非法值回落默认端口
load_config() {
    ADB_WIFI_PORT="$DEFAULT_PORT"
    if [ -f "$CONFIG" ]; then
        # shellcheck source=/dev/null
        . "$CONFIG" 2>/dev/null || true
    fi
    ADB_WIFI_PORT=$(printf '%s' "${ADB_WIFI_PORT:-$DEFAULT_PORT}" | tr -d ' \r\t')
    if ! is_port "$ADB_WIFI_PORT"; then
        echo "portalias: invalid ADB_WIFI_PORT in $CONFIG -> fallback $DEFAULT_PORT" >&2
        ADB_WIFI_PORT="$DEFAULT_PORT"
    fi
}

jump_spec_ok() {
    iptables -t nat -C PREROUTING -i "$LAN_IF" -d "$LAN_IP" -p tcp \
        --dport "$ALIAS_PORT" -j "$CHAIN" 2>/dev/null
}

chain_present() {
    iptables -t nat -S "$CHAIN" >/dev/null 2>&1
}

# 链里是否真有一条指向 $ADB_WIFI_PORT 的 REDIRECT
redirect_ok() {
    iptables -t nat -S "$CHAIN" 2>/dev/null | \
        grep -q -- "-j REDIRECT --to-ports $ADB_WIFI_PORT\$"
}

remove_jumps() {
    _n=0
    while iptables -t nat -D PREROUTING -i "$LAN_IF" -d "$LAN_IP" -p tcp \
        --dport "$ALIAS_PORT" -j "$CHAIN" 2>/dev/null; do
        _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ] && echo "portalias: removed $_n PREROUTING jump(s)"
    return 0
}

do_on() {
    load_config
    if [ "$ADB_WIFI_PORT" = "$ALIAS_PORT" ]; then
        echo "portalias: adbd port is already $ALIAS_PORT; nothing to alias" >&2
        return 2
    fi

    iptables -t nat -N "$CHAIN" 2>/dev/null || true
    # 幂等：每次先清空自己的链，再写唯一一条 REDIRECT
    iptables -t nat -F "$CHAIN" 2>/dev/null || {
        echo "portalias: cannot create/flush nat chain $CHAIN" >&2
        return 1
    }
    iptables -t nat -A "$CHAIN" -p tcp -j REDIRECT --to-ports "$ADB_WIFI_PORT" 2>/dev/null || {
        echo "portalias: REDIRECT append failed (xt_REDIRECT missing?)" >&2
        return 1
    }

    if ! jump_spec_ok; then
        # 先清掉历史重复跳转，再插入到 PREROUTING 第 1 条
        remove_jumps >/dev/null 2>&1 || true
        iptables -t nat -I PREROUTING 1 -i "$LAN_IF" -d "$LAN_IP" -p tcp \
            --dport "$ALIAS_PORT" -j "$CHAIN" 2>/dev/null || {
            echo "portalias: PREROUTING jump insert failed" >&2
            return 1
        }
    fi

    if redirect_ok && jump_spec_ok; then
        echo "portalias: ON  $LAN_IP:$ALIAS_PORT -> $ADB_WIFI_PORT (iface $LAN_IF, nat PREROUTING)"
        echo "portalias: one-shot — not persisted; re-run 'sh $0 on' after reboot or firewall reload"
        return 0
    fi
    echo "portalias: verify failed" >&2
    return 1
}

do_off() {
    remove_jumps
    if chain_present; then
        iptables -t nat -F "$CHAIN" 2>/dev/null || true
        iptables -t nat -X "$CHAIN" 2>/dev/null || true
        echo "portalias: chain $CHAIN removed"
    fi
    if jump_spec_ok || chain_present; then
        echo "portalias: teardown incomplete" >&2
        return 1
    fi
    echo "portalias: OFF (adbd/15555 untouched)"
    return 0
}

do_status() {
    load_config
    echo "== adb-wifi-portalias =="
    echo "alias       : $LAN_IP:$ALIAS_PORT -> $ADB_WIFI_PORT (iface $LAN_IF)"
    if chain_present; then
        echo "chain       : $CHAIN present"
        iptables -t nat -S "$CHAIN" 2>/dev/null
    else
        echo "chain       : $CHAIN missing"
    fi
    if jump_spec_ok; then
        echo "prerouting  : jump present"
        iptables -t nat -S PREROUTING 2>/dev/null | grep -F -- "$CHAIN"
    else
        echo "prerouting  : jump missing"
    fi
    if chain_present && redirect_ok && jump_spec_ok; then
        echo "state       : ON (5555 redirects to $ADB_WIFI_PORT)"
    else
        echo "state       : OFF (5555 does not redirect)"
    fi
    if netstat -ltn 2>/dev/null | grep -q ":$ADB_WIFI_PORT "; then
        echo "adbd        : listening on tcp:$ADB_WIFI_PORT"
    else
        echo "adbd        : NOT listening on tcp:$ADB_WIFI_PORT"
    fi
    echo "persistence : none (one-shot; re-run 'on' after reboot / firewall reload)"
}

usage() {
    cat <<EOF
usage: sh $0 on|off|status|help
  on       create $CHAIN + PREROUTING jump ($LAN_IP:$ALIAS_PORT -> $ADB_WIFI_PORT), idempotent
  off      remove exactly those rules (idempotent)
  status   show chain / jump / whether 5555 redirects / listener
  help     this text
scope:  -i $LAN_IF -d $LAN_IP -p tcp --dport $ALIAS_PORT   (LAN only, never WAN)
config: $CONFIG (ADB_WIFI_PORT, default $DEFAULT_PORT)
note:   adbd keeps listening on $ADB_WIFI_PORT only; nothing is persisted across reboot.
EOF
}

case "${1:-help}" in
    on)     do_on ;;
    off)    do_off ;;
    status) do_status ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
