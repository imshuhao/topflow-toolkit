#!/bin/sh
set -eu
CHAIN=LUCI_READONLY
case "${1:-ensure}" in
remove)
    while iptables -w 5 -C INPUT -p tcp --dport 8080 -j "$CHAIN" 2>/dev/null; do
        iptables -w 5 -D INPUT -p tcp --dport 8080 -j "$CHAIN"
    done
    iptables -w 5 -F "$CHAIN" 2>/dev/null || true
    iptables -w 5 -X "$CHAIN" 2>/dev/null || true
    ;;
ensure)
    # Install the complete chain before making it reachable; never flush a live chain.
    if ! iptables -w 5 -nL "$CHAIN" >/dev/null 2>&1; then
        iptables -w 5 -N "$CHAIN"
    fi
    iptables -w 5 -C "$CHAIN" -i lo -j ACCEPT 2>/dev/null ||
        iptables -w 5 -A "$CHAIN" -i lo -j ACCEPT
    iptables -w 5 -C "$CHAIN" -i br-lan -j ACCEPT 2>/dev/null ||
        iptables -w 5 -A "$CHAIN" -i br-lan -j ACCEPT
    iptables -w 5 -C "$CHAIN" -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null ||
        iptables -w 5 -A "$CHAIN" -p tcp -j REJECT --reject-with tcp-reset
    iptables -w 5 -C INPUT -p tcp --dport 8080 -j "$CHAIN" 2>/dev/null ||
        iptables -w 5 -I INPUT 1 -p tcp --dport 8080 -j "$CHAIN"
    ;;
*) exit 2;;
esac
