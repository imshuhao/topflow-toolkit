#!/bin/sh

# Repair the currently saved rule order and cellular quality policy without
# changing WAN mode.

set -u

BASE=/data/local/mwan3-tuning
CONFIG_FILE="$BASE/config"
LOCK_FILE=/tmp/mwan3-tuning.lock
HOTPLUG_SOURCE="$BASE/90-mwan3-selective-conntrack"
HOTPLUG_TARGET=/etc/hotplug.d/iface/90-mwan3-selective-conntrack
TRACK_IPS='199.7.83.42 180.76.76.76 192.58.128.30'
# 本机 mihomo netns 地址；11.11 为历史作者快照，实机从未命中（2026-09-10 修正）
MIHOMO_SOURCE='192.168.0.254'

if [ -f "$CONFIG_FILE" ]; then
	# Root-owned shell assignments only (see config.example). Still refuse to
	# source anything that is not root-owned or is world-writable, so a
	# compromised non-root account cannot inject shell into this path.
	# Keep the file mode 0644 (or tighter) and owner root on the device.
	if [ -n "$(find "$CONFIG_FILE" ! -user root -print 2>/dev/null)" ] \
		|| [ -n "$(find "$CONFIG_FILE" -perm -0002 -print 2>/dev/null)" ]; then
		echo "refusing to source $CONFIG_FILE (must be root-owned and not world-writable)" >&2
		exit 1
	fi
	# shellcheck source=/dev/null
	. "$CONFIG_FILE"
fi

# Default balanced weights: 5G gets 50%, each 4G gets 25%.
: "${WEIGHT_5G:=6}"
: "${WEIGHT_4G_1:=3}"
: "${WEIGHT_4G_2:=3}"

# V3E1net0 (4G#1) shows latency spikes past the generic 1s/1000ms budget
# (1281-1914ms recorded; flapped 2026-09-15).  Give that interface alone a
# looser reply timeout and failure latency threshold; recovery stays 700ms.
: "${TRACK_TIMEOUT_4G_1:=2}"
: "${TRACK_FAILURE_LATENCY_4G_1:=2000}"

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

# zte_mwan3-only track budget override (must win over the generic loop above).
if [ "$(uci -q get mwan3.zte_mwan3)" = "interface" ]; then
	uci set mwan3.zte_mwan3.timeout="$TRACK_TIMEOUT_4G_1"
	uci set mwan3.zte_mwan3.failure_latency="$TRACK_FAILURE_LATENCY_4G_1"
fi

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

# Apply balanced weights so 5G and both 4G cards are used proportionally.
uci set mwan3.zte_mwan2_m1_w1.weight="$WEIGHT_5G"
uci set mwan3.zte_mwan3_m1_w1.weight="$WEIGHT_4G_1"
uci set mwan3.zte_mwan4_m1_w1.weight="$WEIGHT_4G_2"

uci commit zwrt_router
uci commit mwan3

if [ "$(uci -q get zwrt_router.network.opms_wan_mode)" = "MULTIWAN" ] \
	&& [ "${1:-}" != "--no-reload" ]; then
	/etc/init.d/mwan3 restart
fi
