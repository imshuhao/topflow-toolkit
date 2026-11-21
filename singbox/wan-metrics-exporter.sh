#!/bin/sh
# Prometheus exporter for the three cellular WANs (TopFlow MU5252 B20).
#
# sing-box's own /observability/v1/metrics knows nothing about per-card
# traffic: it aggregates by outbound chain.  This exporter exposes the kernel
# counters the three-card panel needs, plus mwan3 tracker state:
#
#   wan_interface_receive_bytes_total{device="rmnet_data0"}
#   wan_interface_transmit_bytes_total{device="rmnet_data0"}
#   wan_interface_up{device="rmnet_data0"}            1/0 (operstate)
#   wan_interface_present{device="rmnet_data0"}       1/0
#   wan_mwan3_online{iface="5G",device="rmnet_data0"} 1/0
#
# Usage:
#   sh wan-metrics-exporter.sh                 # print one scrape to stdout
#   sh wan-metrics-exporter.sh --serve         # busybox httpd on :9102
#   sh wan-metrics-exporter.sh --serve 9103
#
# With --serve the scrape URL is http://<device>:9102/metrics, which is what
# prometheus-scrape.yml expects.  The file is refreshed every 5 s and served as
# a static document, so no CGI support is required from busybox httpd.  It is
# read-only and needs no secrets; restrict the port to the LAN.
#
# Environment:
#   WAN_DEVICES="rmnet_data0 V3E1net0 V3E2net0"
#   SINGBOX_STATE=/data/sing-box/state
#   SINGBOX_WANBAL_POOL=$SINGBOX_STATE/wan-balance.pool
#   MWAN3_TRACK_DIR=/tmp/run/mwan3/iface_state

set -u

DEVICES="${WAN_DEVICES:-rmnet_data0 V3E1net0 V3E2net0}"
STATE="${SINGBOX_STATE:-/data/sing-box/state}"
POOL="${SINGBOX_WANBAL_POOL:-$STATE/wan-balance.pool}"
TRACK_DIR="${MWAN3_TRACK_DIR:-/tmp/run/mwan3/iface_state}"
MODE=once
PORT=9102

usage() {
	cat <<'EOF'
usage: wan-metrics-exporter.sh [--once] [--serve [PORT]] [-h]

  --once          print the Prometheus text once (default)
  --serve [PORT]  serve /metrics via busybox httpd (default 9102)
  -h, --help      this text
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--once)
		MODE=once
		;;
	--serve)
		MODE=serve
		if [ "$#" -ge 2 ] && [ "$2" != "-h" ] && [ "$2" != "--help" ]; then
			PORT="$2"
			shift
		fi
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "unknown argument: $1" >&2
		usage >&2
		exit 2
		;;
	esac
	shift
done

case "$PORT" in
'' | *[!0-9]*) echo "port must be numeric" >&2; exit 2 ;;
esac

escape_label() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

emit() {
	echo '# HELP wan_interface_receive_bytes_total Per-WAN received bytes (kernel counter).'
	echo '# TYPE wan_interface_receive_bytes_total counter'
	echo '# HELP wan_interface_transmit_bytes_total Per-WAN transmitted bytes (kernel counter).'
	echo '# TYPE wan_interface_transmit_bytes_total counter'
	echo '# HELP wan_interface_up Per-WAN operstate (1=up).'
	echo '# TYPE wan_interface_up gauge'
	echo '# HELP wan_interface_present Per-WAN device presence (1=present).'
	echo '# TYPE wan_interface_present gauge'
	echo '# HELP wan_mwan3_online mwan3 tracker state per WAN (1=online).'
	echo '# TYPE wan_mwan3_online gauge'

	for _dev in $DEVICES; do
		_dev_l=$(escape_label "$_dev")
		_vals=$(awk -v d="$_dev" '$1 == d ":" { print $2, $10; exit }' /proc/net/dev 2>/dev/null)
		if [ -n "$_vals" ]; then
			_rx=${_vals%% *}
			_tx=${_vals##* }
			_present=1
		else
			_rx=0
			_tx=0
			_present=0
		fi
		echo "wan_interface_receive_bytes_total{device=\"$_dev_l\"} $_rx"
		echo "wan_interface_transmit_bytes_total{device=\"$_dev_l\"} $_tx"
		echo "wan_interface_present{device=\"$_dev_l\"} $_present"

		_state=$(cat "/sys/class/net/$_dev/operstate" 2>/dev/null) || _state=unknown
		if [ "$_state" = "up" ]; then
			_up=1
		else
			_up=0
		fi
		echo "wan_interface_up{device=\"$_dev_l\"} $_up"
	done

	if [ -d "$TRACK_DIR" ]; then
		for _f in "$TRACK_DIR"/*; do
			[ -f "$_f" ] || continue
			_iface=${_f##*/}
			_state=$(cat "$_f" 2>/dev/null) || _state=""
			if [ "$_state" = "online" ]; then
				_online=1
			else
				_online=0
			fi
			_dev=$(awk -v i="$_iface" '$1 == i { print $2; exit }' "$POOL" 2>/dev/null) || _dev=""
			echo "wan_mwan3_online{iface=\"$(escape_label "$_iface")\",device=\"$(escape_label "$_dev")\"} $_online"
		done
	fi
}

if [ "$MODE" = "once" ]; then
	emit
	exit 0
fi

if ! command -v httpd >/dev/null 2>&1; then
	echo "wan-metrics-exporter: busybox httpd not found" >&2
	exit 1
fi

DIR="${TMPDIR:-/tmp}/wan-exporter.$$"
mkdir -p "$DIR" || exit 1
emit >"$DIR/metrics.tmp" && mv "$DIR/metrics.tmp" "$DIR/metrics"
(
	while :; do
		emit >"$DIR/metrics.tmp" 2>/dev/null && mv "$DIR/metrics.tmp" "$DIR/metrics"
		sleep "${WAN_EXPORT_INTERVAL:-5}"
	done
) &
_loop=$!
trap 'kill "$_loop" 2>/dev/null; rm -rf "$DIR"' EXIT INT TERM
echo "wan-metrics-exporter: http://0.0.0.0:$PORT/metrics" >&2
httpd -f -p "$PORT" -h "$DIR"
