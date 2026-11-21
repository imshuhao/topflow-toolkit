#!/bin/sh
# TopFlow MU5252 B20 — weak-network black box (aligned with wan-balance).
#
# Records the *same* signals singbox-wan-balance.sh uses for QUALITY/BIAS:
#   - mwan3track LATENCY_*/LOSS_* (max per iface; NOT a private ping)
#   - quality class + lat/loss/rsrp from /data/sing-box/state/wan-balance.quality
#   - effective TCP/UDP weights after quality+soft-bias
#   - preset / pool_mode / quality / bias flags
#   - 5G radio snap (also written for wan-balance RSRP auxiliary)
#   - proxy 204 + DNS latency + mode/rules/sbwan + transition events
#
# Log: /data/local/weaknet/<YYYYMMDD>.jsonl  (keeps 7 days, ~8 MiB cap)
#
# Usage:  weaknet-watch.sh [interval_seconds]     (default 30)
#         kill $(cat /tmp/weaknet-watch.pid)       to stop

BASE=${BASE:-/data/local/weaknet}
INTERVAL=${1:-30}
PIDF=/tmp/weaknet-watch.pid
SB_STATE=${SINGBOX_STATE:-/data/sing-box/state}
TRACK_DIR=${MWAN3_TRACK_DIR:-/tmp/run/mwan3/iface_state}
TRACK_METRICS_DIR=${MWAN3TRACK_DIR:-/var/run/mwan3track}
# Some boots only populate /tmp/run/mwan3track — fall back.
[ -d "$TRACK_METRICS_DIR/zte_mwan2" ] || TRACK_METRICS_DIR=/tmp/run/mwan3track

QDETAIL="$SB_STATE/wan-balance.quality"
WEIGHTS_TCP="$SB_STATE/wan-balance.weights.tcp"
WEIGHTS_UDP="$SB_STATE/wan-balance.weights.udp"
PRESET_STATE="$SB_STATE/wan-balance.preset"
MODE_STATE="$SB_STATE/wan-balance.pool-mode"
CONF=/data/sing-box/wan-balance.conf

mkdir -p "$BASE" || exit 1
echo $$ >"$PIDF"

prev_cards=""
prev_mode=""
prev_preset=""
prev_q=""
prev_wt=""
prev_wu=""
prev_guard=""
prev_sberr=""

# Max LATENCY_* / LOSS_* for one iface — same rule as singbox-wan-balance.sh.
iface_track_metrics() {
	_lat=0
	_loss=0
	_tdir="$TRACK_METRICS_DIR/$1"
	if [ -d "$_tdir" ]; then
		for _f in "$_tdir"/LATENCY_*; do
			[ -f "$_f" ] || continue
			_v=$(cat "$_f" 2>/dev/null | tr -d ' \t\r')
			case "$_v" in ''|*[!0-9]*) continue ;; esac
			[ "$_v" -gt "$_lat" ] && _lat=$_v
		done
		for _f in "$_tdir"/LOSS_*; do
			[ -f "$_f" ] || continue
			_v=$(cat "$_f" 2>/dev/null | tr -d ' \t\r')
			case "$_v" in ''|*[!0-9]*) continue ;; esac
			[ "$_v" -gt "$_loss" ] && _loss=$_v
		done
	fi
	TRACK_LAT=$_lat
	TRACK_LOSS=$_loss
}

iface_online() {
	[ "$(cat "$TRACK_DIR/$1" 2>/dev/null)" = "online" ]
}

# Weight file lines: "iface dev weight table gw" → "iface:weight,..."
fmt_weights() {
	awk 'NF>=3 { printf "%s%s:%s", (n++?",":""), $1, $3 } END { print "" }' "$1" 2>/dev/null
}

weight_of() {
	# $1=iface $2=weights file → integer weight or 0
	awk -v i="$1" '$1==i { print $3+0; found=1; exit } END { if (!found) print 0 }' "$2" 2>/dev/null
}

qclass_of() {
	# From "zte_mwan2:ok:lat=66:loss=0 rsrp=-82"
	printf '%s' "$1" | tr ';' '\n' | awk -F: -v i="$2" '$1==i { print $2; exit }'
}

read_conf_flag() {
	# $1=KEY default $2
	_v=$(sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -1 | tr -d ' \t\r')
	[ -n "$_v" ] && printf '%s' "$_v" || printf '%s' "$2"
}

day=$(date '+%Y%m%d')
out="$BASE/$day.jsonl"

while :; do
	ts=$(date '+%Y-%m-%d %H:%M:%S')
	day=$(date '+%Y%m%d')
	out="$BASE/$day.jsonl"

	mode=$(uci -q get zwrt_router.network.opms_wan_mode 2>/dev/null)
	rules=$(ip rule show 2>/dev/null | grep -c 'fwmark 0x.000000/0xf000000 lookup 1[234]')
	sbwan=$(nft list tables 2>/dev/null | grep -c 'table ip tf-sbwan')

	preset=$(cat "$PRESET_STATE" 2>/dev/null | tr -d ' \t\r')
	[ -n "$preset" ] || preset=$(read_conf_flag PRESET auto)
	pool_mode=$(cat "$MODE_STATE" 2>/dev/null | tr -d ' \t\r')
	[ -n "$pool_mode" ] || pool_mode=$(read_conf_flag MODE shared)
	quality=$(read_conf_flag QUALITY 1)
	bias=$(read_conf_flag BIAS 1)

	qdetail=$(tr '\n' ';' < "$QDETAIL" 2>/dev/null | sed 's/;$//')
	w_tcp=$(fmt_weights "$WEIGHTS_TCP")
	w_udp=$(fmt_weights "$WEIGHTS_UDP")

	# ---- per-card: track metrics + online + effective weights + class ----
	cards=""
	events=""
	for pair in "zte_mwan2 rmnet_data0" "zte_mwan3 V3E1net0" "zte_mwan4 V3E2net0"; do
		set -- $pair
		ifc=$1
		iface_track_metrics "$ifc"
		on=0
		iface_online "$ifc" && on=1
		cls=$(qclass_of "$qdetail" "$ifc")
		[ -n "$cls" ] || cls="?"
		wt=$(weight_of "$ifc" "$WEIGHTS_TCP")
		wu=$(weight_of "$ifc" "$WEIGHTS_UDP")
		cards="$cards,\"$ifc\":{\"on\":$on,\"lat\":$TRACK_LAT,\"loss\":$TRACK_LOSS,\"cls\":\"$cls\",\"w_tcp\":$wt,\"w_udp\":$wu}"
		if [ -n "$prev_cards" ]; then
			old=$(printf '%s' "$prev_cards" | tr ',' '\n' | grep "\"$ifc\"" | sed -n 's/.*"on":\([0-9]\).*/\1/p')
			if [ -n "$old" ] && [ "$on" != "$old" ]; then
				events="$events,\"${ifc}_on=$on\""
			fi
			oldc=$(printf '%s' "$prev_cards" | tr ',' '\n' | grep "\"$ifc\"" | sed -n 's/.*"cls":"\([^"]*\)".*/\1/p')
			if [ -n "$oldc" ] && [ "$cls" != "$oldc" ]; then
				events="$events,\"${ifc}_cls=$cls\""
			fi
		fi
	done

	if [ -n "$prev_mode" ] && [ "$mode" != "$prev_mode" ]; then
		events="$events,\"mode=$mode\""
	fi
	if [ -n "$prev_preset" ] && [ "$preset" != "$prev_preset" ]; then
		events="$events,\"preset=$preset\""
	fi
	if [ -n "$prev_q" ] && [ "$qdetail" != "$prev_q" ]; then
		events="$events,\"quality_changed=1\""
	fi
	if [ -n "$prev_wt" ] && [ "$w_tcp" != "$prev_wt" ]; then
		events="$events,\"w_tcp_changed=1\""
	fi
	if [ -n "$prev_wu" ] && [ "$w_udp" != "$prev_wu" ]; then
		events="$events,\"w_udp_changed=1\""
	fi

	# ---- radio (5G) + snap for wan-balance ----
	net=$(curl -s --max-time 4 http://127.0.0.1:9460/state 2>/dev/null | sed -n 's/.*"net":{\([^}]*\)}.*/\1/p')
	rget_raw() {
		printf '%s' "$net" | tr ',' '\n' | grep "\"$1\":" | head -1 | \
			sed "s/.*\"$1\":\(.*\)/\1/" | tr -d '"'
	}
	_rsrp=$(rget_raw nr_rsrp)
	_snr=$(rget_raw nr_snr)
	_band=$(rget_raw band)
	_type=$(rget_raw type)
	radio="\"type\":\"$_type\",\"band\":\"$_band\",\"rsrp\":\"$_rsrp\",\"rsrq\":\"$(rget_raw nr_rsrq)\",\"snr\":\"$_snr\",\"lte_rsrp\":\"$(rget_raw lte_rsrp)\",\"bars\":\"$(rget_raw bars)\""
	{
		echo "rsrp=$_rsrp"
		echo "snr=$_snr"
		echo "band=$_band"
		echo "type=$_type"
	} >"$BASE/radio.snap.tmp" && mv -f "$BASE/radio.snap.tmp" "$BASE/radio.snap"

	# ---- proxy + DNS ----
	px=$(curl -s -o /dev/null -w '%{http_code}:%{time_total}' --max-time 8 \
		-x http://127.0.0.1:7890 https://www.gstatic.com/generate_204 2>/dev/null)
	dns=$(curl -s -o /dev/null -w '%{time_namelookup}' --max-time 6 \
		https://www.qq.com 2>/dev/null)
	dnsms=$(printf '%s' "$dns" | awk '{ printf "%d", $1 * 1000 + 0.5 }')
	dns_err=$(grep -c 'process DNS packet' /data/sing-box/state/sing-box.log 2>/dev/null)

	sberr=$(tail -n 400 /data/sing-box/state/sing-box.log 2>/dev/null | grep ' ERROR ' | grep -vc 'REJECT-DROP')
	if [ -n "$prev_sberr" ] && [ "${sberr:-0}" -gt "${prev_sberr:-0}" ]; then
		events="$events,\"sberr_delta=$((sberr - prev_sberr))\""
	fi

	guard=$(tail -1 /tmp/topflow-mode-recover.log 2>/dev/null | cut -c1-19)
	if [ -n "$prev_guard" ] && [ "$guard" != "$prev_guard" ]; then
		events="$events,\"guard=$guard\""
	fi

	printf '{"t":"%s","mode":"%s","preset":"%s","pool_mode":"%s","quality":%s,"bias":%s,"q":"%s","w_tcp":"%s","w_udp":"%s","rules":%s,"sbwan":%s,"radio":{%s},"proxy":"%s","dns_ms":%s,"dns_err":%s,"cards":{%s}%s}\n' \
		"$ts" "${mode:-?}" "${preset:-?}" "${pool_mode:-?}" "${quality:-0}" "${bias:-0}" \
		"$qdetail" "$w_tcp" "$w_udp" \
		"${rules:-0}" "${sbwan:-0}" "$radio" "${px:-?}" "${dnsms:-0}" "${dns_err:-0}" \
		"${cards#,}" \
		"$([ -n "$events" ] && printf ',"events":[%s]' "${events#,}")" >>"$out"

	if [ -n "$prev_cards" ] && [ -n "$events" ]; then
		echo "$ts $(printf '%s' "${events#,}" | tr ',' ' ')" >>"$BASE/events.log"
	fi

	prev_cards="$cards"
	prev_mode="$mode"
	prev_preset="$preset"
	prev_q="$qdetail"
	prev_wt="$w_tcp"
	prev_wu="$w_udp"
	prev_guard="$guard"
	prev_sberr="$sberr"

	find "$BASE" -name '*.jsonl' -mtime +7 -delete 2>/dev/null
	if [ -f "$out" ] && [ "$(wc -c <"$out" 2>/dev/null || echo 0)" -gt 8388608 ]; then
		mv -f "$out" "$out.1" 2>/dev/null
	fi
	sleep "$INTERVAL"
done
