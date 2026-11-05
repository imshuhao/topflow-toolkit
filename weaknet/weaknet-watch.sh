#!/bin/sh
# TopFlow MU5252 B20 — weak-network black box recorder.
#
# The weak-network place (office) has no PC, so the device records evidence by
# itself.  Every INTERVAL seconds it appends one JSON line with:
#   - mwan3 per-card state (up / online counter / score / lost / uptime)
#   - per-card ICMP quality to the tracking target (loss % + avg RTT)
#   - proxy health through sing-box mixed (204 code + total ms)
#   - DNS resolve latency through the device resolver
#   - wan-balance shape (ip rules count / nft table presence / mode)
#   - events: any per-card up/down transition, mode change, pool change,
#             recovery-guard action, new sing-box errors
#
# Log: /data/local/weaknet/<YYYYMMDD>.jsonl  (persistent, keeps 7 days)
#
# Usage:  weaknet-watch.sh [interval_seconds]     (default 30)
#         kill $(cat /tmp/weaknet-watch.pid)       to stop

BASE=${BASE:-/data/local/weaknet}
INTERVAL=${1:-30}
PIDF=/tmp/weaknet-watch.pid
mkdir -p "$BASE" || exit 1
echo $$ >"$PIDF"

prev_cards=""
prev_mode=""
prev_rules=""
prev_guard=""
prev_sberr=""

card_state() {
	# $1 = iface name; print up/online/score/lost/uptime from ubus
	ubus call mwan3 status 2>/dev/null | awk -v want="$1" '
		BEGIN { in_if=0 }
		$0 ~ "\""want"\": {" { in_if=1 }
		in_if && /"up":/ { gsub(/[",]/,""); up=$2 }
		in_if && /"online":/ { gsub(/[",]/,""); on=$2 }
		in_if && /"score":/ { gsub(/[",]/,""); sc=$2 }
		in_if && /"lost":/ { gsub(/[",]/,""); lo=$2 }
		in_if && /"uptime":/ { gsub(/[",]/,""); ut=$2 }
		in_if && /^[ \t]*},?[ \t]*$/ { if (seen) exit; seen=1 }
		END {
			# ubus prints JSON booleans (true/false); normalise to 1/0
			u = (up == "true") ? 1 : ((up == "false" || up == "") ? 0 : up + 0)
			printf "%s %s %s %s %s", u, (on?on:0), (sc?sc:0), (lo?lo:0), (ut?ut:0)
		}
	'
}

ping_quality() {
	# $1 = iface; print "loss avg_ms"
	ping -I "$1" -c 5 -W 2 -q 223.5.5.5 2>/dev/null | awk '
		/loss/ { for (i=1;i<=NF;i++) if ($i ~ /%/) { gsub(/%/,"",$i); loss=$i } }
		/rtt min\/avg/ { split($4, a, "/"); avg=a[2] }
		END { printf "%s %s", (loss!=""?loss:100), (avg!=""?avg:"-") }
	'
}

now=$(date '+%Y-%m-%d %H:%M:%S')
day=$(date '+%Y%m%d')
out="$BASE/$day.jsonl"

while :; do
	ts=$(date '+%Y-%m-%d %H:%M:%S')
	mode=$(uci -q get zwrt_router.network.opms_wan_mode 2>/dev/null)
	rules=$(ip rule show 2>/dev/null | grep -c 'fwmark 0x.000000/0xf000000 lookup 1[234]')
	sbwan=$(nft list tables 2>/dev/null | grep -c 'table ip tf-sbwan')

	# ---- per-card quality ----
	cards=""
	events=""
	for pair in "zte_mwan2 rmnet_data0" "zte_mwan3 V3E1net0" "zte_mwan4 V3E2net0"; do
		set -- $pair
		ifc=$1; dev=$2
		st=$(card_state "$ifc")
		pq=$(ping_quality "$dev")
		cards="$cards,\"$ifc\":{\"st\":\"$st\",\"ping\":\"$pq\"}"
		# transition detection is based on the ubus "up" flag
		cur=$(printf '%s' "$st" | awk '{print $1}')
		old=$(printf '%s' "$prev_cards" | tr ',' '\n' | grep "\"$ifc\"" | sed 's/.*"st":"\([0-9]*\) .*/\1/')
		if [ -n "$prev_cards" ] && [ "$cur" != "$old" ]; then
			events="$events,\"${ifc}_up=$cur\""
		fi
	done
	if [ -n "$prev_mode" ] && [ "$mode" != "$prev_mode" ]; then
		events="$events,\"mode=$mode\""
	fi
	if [ -n "$prev_rules" ] && [ "$rules" != "$prev_rules" ]; then
		events="$events,\"rules=$rules\""
	fi

	# ---- radio layer of the 5G main card (X75): band / RSRP / SNR ----
	# 9460/state exposes a flat "net" object; this is where rural/mountain
	# degradation becomes visible (n78 -> n1 -> LTE, RSRP falling, SNR < 0).
	net=$(curl -s --max-time 4 http://127.0.0.1:9460/state 2>/dev/null | sed -n 's/.*"net":{\([^}]*\)}.*/\1/p')
	rget_raw() {
		printf '%s' "$net" | tr ',' '\n' | grep "\"$1\":" | head -1 | \
			sed "s/.*\"$1\":\(.*\)/\1/" | tr -d '"'
	}
	radio="\"type\":\"$(rget_raw type)\",\"band\":\"$(rget_raw band)\",\"rsrp\":\"$(rget_raw nr_rsrp)\",\"rsrq\":\"$(rget_raw nr_rsrq)\",\"snr\":\"$(rget_raw nr_snr)\",\"lte_rsrp\":\"$(rget_raw lte_rsrp)\",\"bars\":\"$(rget_raw bars)\""
	# Live snap for wan-balance quality (5G RSRP auxiliary). Atomic replace.
	{
		echo "rsrp=$(rget_raw nr_rsrp)"
		echo "snr=$(rget_raw nr_snr)"
		echo "band=$(rget_raw band)"
		echo "type=$(rget_raw type)"
	} >"$BASE/radio.snap.tmp" && mv -f "$BASE/radio.snap.tmp" "$BASE/radio.snap"

	# ---- proxy + DNS health ----
	px=$(curl -s -o /dev/null -w '%{http_code}:%{time_total}' --max-time 8 \
		-x http://127.0.0.1:7890 https://www.gstatic.com/generate_204 2>/dev/null)
	# namelookup on a domestic name goes through dnsmasq -> sing-box DNS; a
	# stalled/failing resolver shows up here as a large or missing value.
	dns=$(curl -s -o /dev/null -w '%{time_namelookup}' --max-time 6 \
		https://www.qq.com 2>/dev/null)
	dnsms=$(printf '%s' "$dns" | awk '{ printf "%d", $1 * 1000 + 0.5 }')
	dns_err=$(grep -c 'process DNS packet' /data/sing-box/state/sing-box.log 2>/dev/null)

	# ---- sing-box error counter (ignore REJECT-DROP: it is rule-blocked ad noise) ----
	sberr=$(tail -n 400 /data/sing-box/state/sing-box.log 2>/dev/null | grep ' ERROR ' | grep -vc 'REJECT-DROP')
	if [ -n "$prev_sberr" ] && [ "${sberr:-0}" -gt "${prev_sberr:-0}" ]; then
		events="$events,\"sberr_delta=$((sberr - prev_sberr))\""
	fi

	# ---- recovery guard actions ----
	guard=$(tail -1 /tmp/topflow-mode-recover.log 2>/dev/null | cut -c1-19)
	if [ -n "$prev_guard" ] && [ "$guard" != "$prev_guard" ]; then
		events="$events,\"guard=$guard\""
	fi

	printf '{"t":"%s","mode":"%s","rules":%s,"sbwan":%s,"radio":{%s},"proxy":"%s","dns_ms":%s,"dns_err":%s,"cards":{%s}%s}\n' \
		"$ts" "${mode:-?}" "${rules:-0}" "${sbwan:-0}" "$radio" "${px:-?}" "${dnsms:-0}" "${dns_err:-0}" \
		"${cards#,}" \
		"$([ -n "$events" ] && printf ',"events":[%s]' "${events#,}")" >>"$out"

	if [ -n "$prev_cards" ] && [ -n "$events" ]; then
		echo "$ts $(printf '%s' "${events#,}" | tr ',' ' ')" >>"$BASE/events.log"
	fi

	prev_cards="$cards"
	prev_mode="$mode"
	prev_rules="$rules"
	prev_guard="$guard"
	prev_sberr="$sberr"

	# keep 7 days, cap the current file at ~8 MB
	find "$BASE" -name '*.jsonl' -mtime +7 -delete 2>/dev/null
	if [ -f "$out" ] && [ "$(wc -c <"$out" 2>/dev/null || echo 0)" -gt 8388608 ]; then
		mv -f "$out" "$out.1" 2>/dev/null
	fi
	sleep "$INTERVAL"
done
