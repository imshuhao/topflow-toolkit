#!/bin/sh

# Install custom Mihomo/LAN rule precedence and tune cellular quality without
# changing WAN mode. Stock B20/B22 already order HTTPS before the default rule.

set -u

BASE=/data/local/mwan3-tuning
CONFIG_FILE="$BASE/config"
LOCK_FILE=/tmp/mwan3-tuning.lock
HOTPLUG_SOURCE="$BASE/90-mwan3-selective-conntrack"
HOTPLUG_TARGET=/etc/hotplug.d/iface/90-mwan3-selective-conntrack
TRACK_IPS='199.7.83.42 180.76.76.76 192.58.128.30'
MIHOMO_SOURCE='192.168.11.11'

if [ -f "$CONFIG_FILE" ]; then
	# Root-owned shell assignments only; this is not a user-supplied network
	# response or an untrusted WebUI value.
	# shellcheck source=/dev/null
	. "$CONFIG_FILE"
fi

case "$MIHOMO_SOURCE" in
	''|*[!0-9.]*) echo "invalid MIHOMO_SOURCE" >&2; exit 2 ;;
esac
[ -n "$TRACK_IPS" ] || {
	echo "TRACK_IPS must not be empty" >&2
	exit 2
}
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

if [ -x "$HOTPLUG_SOURCE" ]; then
	ln -sf "$HOTPLUG_SOURCE" "$HOTPLUG_TARGET"
fi

uci set zwrt_router.multiwan.targets="$TRACK_IPS"

for interface in zte_wan zte_mwan2 zte_mwan3 zte_mwan4; do
	[ "$(uci -q get mwan3.$interface)" = "interface" ] || continue
	uci -q delete mwan3.$interface.track_ip
	for target in $TRACK_IPS; do
		uci add_list mwan3.$interface.track_ip="$target"
	done
	# The vendor default flushes the entire conntrack table for every WAN
	# lifecycle event.  The separate hotplug helper now deletes only flows
	# marked for a failed interface, and only on ifdown/disconnected.
	uci -q delete mwan3.$interface.flush_conntrack
	[ "$interface" = "zte_wan" ] && continue
	uci set mwan3.$interface.reliability='1'
	uci set mwan3.$interface.count='3'
	uci set mwan3.$interface.size='56'
	uci set mwan3.$interface.check_quality='1'
	uci set mwan3.$interface.timeout='1'
	uci set mwan3.$interface.interval='2'
	uci set mwan3.$interface.failure_interval='2'
	uci set mwan3.$interface.recovery_interval='2'
	uci set mwan3.$interface.down='2'
	uci set mwan3.$interface.up='2'
	uci set mwan3.$interface.failure_loss='60'
	uci set mwan3.$interface.recovery_loss='10'
	uci set mwan3.$interface.failure_latency='1000'
	uci set mwan3.$interface.recovery_latency='700'
done

uci -q delete mwan3.mihomo_https
uci -q delete mwan3.https
uci -q delete mwan3.default_rule_v4

uci set mwan3.mihomo_https=rule
uci set mwan3.mihomo_https.src_ip="$MIHOMO_SOURCE"
uci set mwan3.mihomo_https.dest_port='443'
uci set mwan3.mihomo_https.proto='tcp'
uci set mwan3.mihomo_https.family='ipv4'
uci set mwan3.mihomo_https.sticky='0'
uci set mwan3.mihomo_https.use_policy='balanced'

uci set mwan3.https=rule
uci set mwan3.https.sticky='1'
uci set mwan3.https.timeout='600'
uci set mwan3.https.dest_port='443'
uci set mwan3.https.proto='tcp'
uci set mwan3.https.family='ipv4'
uci set mwan3.https.use_policy='balanced'

uci set mwan3.default_rule_v4=rule
uci set mwan3.default_rule_v4.dest_ip='0.0.0.0/0'
uci set mwan3.default_rule_v4.use_policy='balanced'
uci set mwan3.default_rule_v4.family='ipv4'
uci set mwan3.default_rule_v4.proto='all'
uci set mwan3.default_rule_v4.logging='1'
uci set mwan3.default_rule_v4.sticky='0'
uci commit zwrt_router
uci commit mwan3

if [ "$(uci -q get zwrt_router.network.opms_wan_mode)" = "MULTIWAN" ] \
	&& [ "${1:-}" != "--no-reload" ]; then
	/etc/init.d/mwan3 restart
fi
