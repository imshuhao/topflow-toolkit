#!/bin/sh
# Bound DNS lookup too: this vendor BusyBox has no timeout applet.
case "$1" in
 ping) /usr/bin/ping -c 4 -W 2 "$2" & ;;
 traceroute) /bin/traceroute -m 8 -w 1 -q 1 "$2" & ;;
 nslookup) /usr/bin/nslookup "$2" & ;;
 *) exit 2 ;;
esac
worker=$!
(sleep 12; kill -TERM "$worker" 2>/dev/null) &
watchdog=$!
wait "$worker"
result=$?
kill "$watchdog" 2>/dev/null
wait "$watchdog" 2>/dev/null
exit "$result"
