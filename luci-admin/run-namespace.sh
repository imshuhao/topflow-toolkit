#!/bin/sh
set -eu
BASE=/data/local/luci-readonly
STAGE=$BASE/stage
umask 077
[ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ] || exit 1
# Readiness can lag behind procd startup on this vendor firmware.
attempt=0
until [ "$(ubus list session 2>/dev/null)" = session ] &&
    [ -f /usr/share/rpcd/acl.d/luci-readonly-status.json ] &&
    ip -4 addr show dev br-lan | grep -q 'inet 192.168.11.1/'; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 60 ] || exit 1
    sleep 2
done
[ "$(uci -q get zwrt_common_info.common_config.wa_inner_version)" = BD_ENCNMU5252V1.0.0B22 ]
[ -z "$(ubus list luci 2>/dev/null)" ] || exit 1
mount -t overlay overlay -o "ro,lowerdir=$STAGE/usr/share:/usr/share" /usr/share
mount -t overlay overlay -o "ro,lowerdir=$STAGE/usr/lib:/usr/lib" /usr/lib
# A dedicated docroot exposes only LuCI assets, without vendor CGI endpoints.
export PATH="$STAGE/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin"
grant_login() {
    ubus call session grant '{"ubus_rpc_session":"00000000000000000000000000000000","scope":"ubus","objects":[["luci","getFeatures"],["file","list"]]}' >/dev/null
    ubus call session grant '{"ubus_rpc_session":"00000000000000000000000000000000","scope":"file","objects":[["/www/luci-static/resources/preload","list"]]}' >/dev/null
}
rpc_pid='' web_pid='' sleeper=''
cleanup() {
    [ -z "$sleeper" ] || kill "$sleeper" 2>/dev/null || true
    [ -z "$web_pid" ] || kill "$web_pid" 2>/dev/null || true
    [ -z "$rpc_pid" ] || kill "$rpc_pid" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' INT TERM
echo "$$" > "$BASE/runtime/supervisor.pid"
"$BASE/firewall.sh" ensure
grant_login
/usr/bin/ucode "$BASE/luci-readonly.uc" > "$BASE/runtime/luci-rpc.log" 2>&1 &
rpc_pid=$!
echo "$rpc_pid" > "$BASE/runtime/rpc-helper.pid"
"$STAGE/usr/sbin/uhttpd" -f -p 192.168.11.1:8080 -p 127.0.0.1:18080 -h "$STAGE/www" -x /cgi-bin -u /ubus -D -S -n 8 -N 50 -t 30 -T 30 -k 5 > "$BASE/runtime/uhttpd.log" 2>&1 &
web_pid=$!
echo "$web_pid" > "$BASE/runtime/uhttpd.pid"
while kill -0 "$rpc_pid" 2>/dev/null && kill -0 "$web_pid" 2>/dev/null; do
    # Reapply anonymous login permissions after an independent rpcd restart.
    grant_login || exit 1
    "$BASE/firewall.sh" ensure || exit 1
    sleep 10 & sleeper=$!
    wait "$sleeper"
    sleeper=
done
exit 1
