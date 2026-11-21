#!/bin/sh
# Keep DHCP option 3/6 pointed at the device when sing-box is the gateway.
set -u
# shellcheck disable=SC2034  # documented override point (SINGBOX_BASE)
BASE="${SINGBOX_BASE:-/data/sing-box}"
MANUAL_STOP="/tmp/sing-box-manual-stop"
DHCP_OPTIONS="dhcp.lan.dhcp_option"
LOG="${SINGBOX_DHCP_LOG:-/tmp/sing-box-dhcp.log}"

while [ ! -f "$MANUAL_STOP" ]; do
    _opts=" $(uci -q get "$DHCP_OPTIONS" 2>/dev/null || true) "
    _need=0
    case "$_opts" in *" 3,192.168.0.1 "*) ;; *) _need=1 ;; esac
    case "$_opts" in *" 6,192.168.0.1 "*) ;; *) _need=1 ;; esac
    if [ "$_need" -eq 1 ]; then
        uci -q del_list "$DHCP_OPTIONS=3,192.168.0.254" 2>/dev/null || true
        uci -q del_list "$DHCP_OPTIONS=6,192.168.0.254" 2>/dev/null || true
        uci -q del_list "$DHCP_OPTIONS=3,192.168.0.1" 2>/dev/null || true
        uci -q del_list "$DHCP_OPTIONS=6,192.168.0.1" 2>/dev/null || true
        uci add_list "$DHCP_OPTIONS=3,192.168.0.1"
        uci add_list "$DHCP_OPTIONS=6,192.168.0.1"
        uci commit dhcp
        /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
        echo "$(date '+%Y-%m-%d %H:%M:%S') restored DHCP 3/6 -> 192.168.0.1" >> "$LOG"
    fi
    sleep 15
done
