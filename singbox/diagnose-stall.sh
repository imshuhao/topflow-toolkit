#!/bin/sh
# Diagnose the eBPF shared-plane LAN TCP stall (HANDOVER §31.1).
#
# The plane is read from the running config and printed; the verdict is
# "shared-plane stall", not a packet_rewrite verdict.  packet_rewrite shipped
# the first failure evidence, but socket_assign is the A/B candidate and must
# not inherit that conclusion by name.
#
# Evidence is collected from four independent places, and the verdict keeps
# their scopes apart:
#   1. observability API vs traffic counters (path-agnostic: an empty
#      /connections/active while counters move does NOT identify the LAN path);
#   2. br-lan capture retransmissions (only LAN-client traffic proves the
#      shared/TC LAN path was exercised);
#   3. three sequential local HTTPS probes (device-originated: success can never
#      prove LAN health, failure shows the local/proxy path is broken);
#   4. bounded runtime snapshots from ebpf-snapshot.sh (tc counters, ip rules,
#      netns, nft counters, /proc/net/dev, gRPC eBPF diagnostics on :8088)
#      before and after the capture window.
#
# Usage (on device, as root):
#   sh diagnose-stall.sh                    # 10 s capture on br-lan, ports 443/80
#   sh diagnose-stall.sh --seconds 20 --count 800
#   sh diagnose-stall.sh --iface br-lan --port 443
#   sh diagnose-stall.sh --no-capture       # skip the pcap (verdict can then
#                                           # only be INCONCLUSIVE)
#
# Environment:
#   SINGBOX_BASE=/data/sing-box
#   SINGBOX_API=http://127.0.0.1:9999      Clash + observability HTTP (not gRPC)
#   SINGBOX_API_SECRET=...
#   STALL_IFACE=br-lan
#   STALL_OUT=$BASE/diagnostics
#   STALL_PORTS="443 80"
#   STALL_TEST_URL=https://www.gstatic.com/generate_204
#   STALL_SNAPSHOT=0                       disable runtime snapshots
#   STALL_SNAPSHOT_TIMEOUT=5               per-command bound inside snapshots
#
# Exit codes: 0 = LAN path observed clean in this window; 1 = stall confirmed
#             (empty active + LAN-client retransmissions); 2 = suspect /
#             inconclusive (including no LAN-client traffic or a failed
#             capture); 3 = observability API unavailable.

set -u

BASE="${SINGBOX_BASE:-/data/sing-box}"
API="${SINGBOX_API:-http://127.0.0.1:9999}"
SECRET="${SINGBOX_API_SECRET:-}"
IFACE="${STALL_IFACE:-br-lan}"
OUT="${STALL_OUT:-$BASE/diagnostics}"
PORTS="${STALL_PORTS:-443 80}"
TEST_URL="${STALL_TEST_URL:-https://www.gstatic.com/generate_204}"
DURATION=10
COUNT=400
CAPTURE=1
SNAPSHOT="${STALL_SNAPSHOT:-1}"
SNAP_TIMEOUT="${STALL_SNAPSHOT_TIMEOUT:-5}"

usage() {
	cat <<'EOF'
usage: diagnose-stall.sh [options]

  --iface IFACE      capture interface (default br-lan)
  --seconds N        capture duration (default 10)
  --count N          max packets to capture (default 400)
  --port LIST        comma/space separated TCP ports (default "443 80")
  --url URL          probe URL (default gstatic generate_204)
  --no-capture       skip packet capture (symptom 2); verdict stays inconclusive
  --no-snapshot      skip ebpf-snapshot.sh pre/post runtime snapshots
  -h, --help         this text

Artifacts kept under $SINGBOX_BASE/diagnostics/:
  stall-<utc>.pcap / .tcpdump.txt / .tcpdump.err   raw LAN capture + text dump
  stall-<utc>-pre/  stall-<utc>-post/              runtime snapshots
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--iface)
		[ "$#" -ge 2 ] || { usage >&2; exit 2; }
		IFACE="$2"
		shift
		;;
	--seconds)
		[ "$#" -ge 2 ] || { usage >&2; exit 2; }
		DURATION="$2"
		shift
		;;
	--count)
		[ "$#" -ge 2 ] || { usage >&2; exit 2; }
		COUNT="$2"
		shift
		;;
	--port)
		[ "$#" -ge 2 ] || { usage >&2; exit 2; }
		PORTS=$(printf '%s' "$2" | tr ',' ' ')
		shift
		;;
	--url)
		[ "$#" -ge 2 ] || { usage >&2; exit 2; }
		TEST_URL="$2"
		shift
		;;
	--no-capture)
		CAPTURE=0
		;;
	--no-snapshot)
		SNAPSHOT=0
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

case "$DURATION" in
'' | *[!0-9]*) echo "seconds must be a positive integer" >&2; exit 2 ;;
esac
case "$COUNT" in
'' | *[!0-9]*) echo "count must be a positive integer" >&2; exit 2 ;;
esac
[ "$DURATION" -gt 0 ] || { echo "seconds must be > 0" >&2; exit 2; }
[ "$COUNT" -gt 0 ] || { echo "count must be > 0" >&2; exit 2; }

api_get() {
	if [ -n "$SECRET" ]; then
		curl -fsS -m 3 -H "Authorization: Bearer $SECRET" "$API$1" 2>/dev/null
	else
		curl -fsS -m 3 "$API$1" 2>/dev/null
	fi
}

json_total() {
	sed -n 's/.*"total"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | sed -n '1p'
}

metric_sum() { # metric_sum <metrics-body> <name>
	printf '%s\n' "$1" | awk -v n="$2" '
		BEGIN { p = n "{" }
		$1 == n || index($0, p) == 1 { s += $NF }
		END { printf "%.0f", s + 0 }
	'
}

clash_connections() {
	_json=$(api_get /connections) || _json=""
	[ -n "$_json" ] || { echo "?"; return 0; }
	if command -v jq >/dev/null 2>&1; then
		printf '%s\n' "$_json" | jq -r '.connections | length' 2>/dev/null
	else
		printf '%s\n' "$_json" | grep -o '"id"[[:space:]]*:' 2>/dev/null | wc -l | tr -d ' '
	fi
}

if ! command -v curl >/dev/null 2>&1; then
	echo "[FAIL] curl not found; cannot query $API" >&2
	exit 3
fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUT" 2>/dev/null || OUT="${TMPDIR:-/tmp}"
PCAP="$OUT/stall-$TS.pcap"
TCPDUMP_ERR="$OUT/stall-$TS.tcpdump.err"
TCPDUMP_TXT="$OUT/stall-$TS.tcpdump.txt"
SNAP_PRE="$OUT/stall-$TS-pre"
SNAP_POST="$OUT/stall-$TS-post"

SNAP_SCRIPT="${SNAPSHOT_SCRIPT:-$BASE/ebpf-snapshot.sh}"
[ -f "$SNAP_SCRIPT" ] || SNAP_SCRIPT="$(dirname "$0")/ebpf-snapshot.sh"

SNAP_PRE_STATE="disabled"
SNAP_POST_STATE="disabled"

take_snapshot() { # take_snapshot <dir> <label> -> SNAP_LAST_STATE
	SNAP_LAST_STATE="disabled"
	[ "$SNAPSHOT" -eq 1 ] || return 0
	if [ ! -f "$SNAP_SCRIPT" ]; then
		echo "[WARN] snapshot collector not found ($SNAP_SCRIPT); runtime state NOT captured"
		SNAP_LAST_STATE="missing"
		return 1
	fi
	SINGBOX_BASE="$BASE" SINGBOX_SNAPSHOT_LAN_IFACE="$IFACE" \
		sh "$SNAP_SCRIPT" --output "$1" --label "$2" --timeout "$SNAP_TIMEOUT" >/dev/null 2>&1
	_rc=$?
	if [ -f "$1/status.txt" ]; then
		_st=$(sed -n 's/^SNAPSHOT_STATUS=//p' "$1/status.txt" 2>/dev/null | sed -n '1p')
		[ -n "$_st" ] || _st="unknown"
		SNAP_LAST_STATE="$_st"
		echo "snapshot: $1 ($_st)"
		return 0
	fi
	SNAP_LAST_STATE="failed"
	echo "[WARN] snapshot NOT captured (collector rc=$_rc, no status.txt in $1)"
	return 1
}

snapshot_ref() { # snapshot_ref <dir> <state> -> one evidence line or nothing
	case "$2" in
	ok) echo "$1" ;;
	partial) echo "$1 (PARTIAL; see failures.txt)" ;;
	*) : ;;
	esac
}

# Data plane actually declared by the running config.  Read through jsonfilter
# with one array query: device jsonfilter exits 1 for an out-of-range index and
# for a missing optional field alike, so per-index probes cannot tell "absent"
# from "unparseable".  Empty output = field absent; rc 1 = no eBPF inbound;
# rc 2 = cannot parse (callers print unknown).
diag_plane_field() { # diag_plane_field <local.data_plane|shared.enabled|...>
	_f="$BASE/config.json"
	[ -f "$_f" ] || return 2
	command -v jsonfilter >/dev/null 2>&1 || return 2
	_types=$(jsonfilter -i "$_f" -e '@.inbounds[*].type' 2>/dev/null) || return 2
	[ -n "$_types" ] || return 2
	_cnt=$(printf '%s\n' "$_types" | grep -c .)
	[ "$_cnt" -le 64 ] || return 2
	_i=0
	_idx=
	while [ "$_i" -lt "$_cnt" ]; do
		if [ "$(printf '%s\n' "$_types" | sed -n "$((_i + 1))p")" = ebpf ]; then
			_idx=$_i
			break
		fi
		_i=$((_i + 1))
	done
	[ -n "$_idx" ] || return 1
	jsonfilter -i "$_f" -e "@.inbounds[$_idx].$1" 2>/dev/null | tr -d '"'
}

echo "== eBPF stall diagnosis $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
echo "api     : $API"
echo "iface   : $IFACE"
echo "ports   : $PORTS"
echo "probe   : $TEST_URL"
echo

# LAN provenance: only an address inside this interface's subnet and different
# from the router itself counts as a LAN client.
LAN_CIDR=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4; exit}')
echo "lan ip  : ${LAN_CIDR:-unknown (LAN provenance cannot be evaluated)}"
take_snapshot "$SNAP_PRE" "stall-$TS-pre"
SNAP_PRE_STATE="$SNAP_LAST_STATE"
echo

# ---------------------------------------------------------- pre-capture state
_active1=$(api_get /observability/v1/connections/active) || _active1=""
if [ -z "$_active1" ]; then
	echo "[FAIL] observability API unavailable ($API/observability/v1/connections/active)"
	echo "       check experimental.observability and the controller port; cannot diagnose."
	exit 3
fi
_active1_total=$(printf '%s\n' "$_active1" | json_total)
_clash1=$(clash_connections)
_m1=$(api_get /observability/v1/metrics) || _m1=""
_sbtun=no
[ -e /sys/class/net/sbtun0 ] && _sbtun=yes
if [ -f "$BASE/config.json" ] && grep -q '"type"[[:space:]]*:[[:space:]]*"ebpf"' "$BASE/config.json" 2>/dev/null; then
	_mode="ebpf"
else
	_mode="tun"
fi
echo "mode    : $_mode | sbtun0=$_sbtun | active=$_active1_total | clash=$_clash1"
_lp=$(diag_plane_field local.data_plane 2>/dev/null) || _lp=unknown
_sh=$(diag_plane_field shared.enabled 2>/dev/null) || _sh=unknown
_sp=$(diag_plane_field shared.data_plane 2>/dev/null) || _sp=unknown
[ -n "$_lp" ] || _lp=unset
if [ "$_sh" = true ]; then
	SHARED_WORD=${_sp:-unset}
else
	SHARED_WORD=${_sh:-absent}
fi
# The plane the shared hook actually uses; symptom 2 below is reported against
# this value so a socket_assign run is never graded as packet_rewrite.
echo "planes  : local $_lp | shared $SHARED_WORD"

# ------------------------------------------------------------- packet capture
CAPTURED=0
REPORT=""
if [ "$CAPTURE" -eq 1 ]; then
	if ! command -v tcpdump >/dev/null 2>&1; then
		echo "[SKIP] tcpdump not installed; symptom 2 not checked"
	else
		FILTER="tcp and ("
		_first=1
		for _p in $PORTS; do
			case "$_p" in
			'' | *[!0-9]*) continue ;;
			esac
			if [ "$_first" -eq 1 ]; then
				FILTER="$FILTER port $_p"
				_first=0
			else
				FILTER="$FILTER or port $_p"
			fi
		done
		FILTER="$FILTER)"
		echo "capture : $DURATION s, max $COUNT packets on $IFACE ($FILTER)"
		: >"$TCPDUMP_ERR" 2>/dev/null || true
		tcpdump -i "$IFACE" -s 0 -c "$COUNT" -w "$PCAP" "$FILTER" >/dev/null 2>"$TCPDUMP_ERR" &
		_tpid=$!
		sleep "$DURATION"
		kill "$_tpid" 2>/dev/null || true
		wait "$_tpid" 2>/dev/null || true
		if [ -s "$PCAP" ]; then
			CAPTURED=1
			tcpdump -nn -tt -S -r "$PCAP" >"$TCPDUMP_TXT" 2>/dev/null || : >"$TCPDUMP_TXT"
			REPORT=$(awk -v lan="${LAN_CIDR:-}" '
				function toint(ip, a, n) {
					n = split(ip, a, ".")
					if (n != 4) return -1
					return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4]
				}
				BEGIN {
					net = -1; router = -1; size = 0
					if (lan != "") {
						split(lan, L, "/")
						router = toint(L[1])
						p = L[2] + 0
						if (p < 1 || p > 32) p = 32
						size = 2 ^ (32 - p)
						net = router - (router % size)
					}
				}
				function is_lan(ip, x) {
					if (net < 0) return 0
					x = toint(ip)
					if (x < 0) return 0
					return (x >= net && x < net + size && x != router)
				}
				{
					seq = ""; len = -1; flags = ""; src = ""; dst = ""
					for (i = 1; i <= NF; i++) {
						if ($i == "seq") { seq = $(i + 1); sub(/,.*/, "", seq) }
						else if ($i == "length") { len = $(i + 1) }
						else if ($i == "Flags") { flags = $(i + 1) }
						else if ($i == ">") {
							src = $(i - 1); dst = $(i + 1)
							sub(/:$/, "", src); sub(/:$/, "", dst)
						}
					}
					sub(/\.[0-9]+$/, "", src)
					sub(/\.[0-9]+$/, "", dst)
					lanflag = is_lan(src) || is_lan(dst)
					total++
					if (lanflag) lan_pkts++
					if (len > 0 && seq != "") {
						data++
						key = src " -> " dst " seq=" seq
						dcount[key]++
						if (lanflag) { lkey[key] = 1; lan_data++ }
					}
					if (flags ~ /S/ && flags ~ /\./ && seq != "") {
						skey = src " -> " dst " seq=" seq
						scount[skey]++
						if (lanflag) lskey[skey] = 1
					}
				}
				END {
					dupf = 0; dup = 0; landupf = 0; landup = 0
					for (k in dcount) if (dcount[k] > 1) {
						dupf++; dup += dcount[k] - 1
						if (k in lkey) { landupf++; landup += dcount[k] - 1 }
					}
					synf = 0; syn = 0; lansynf = 0; lansyn = 0
					for (k in scount) if (scount[k] > 1) {
						synf++; syn += scount[k] - 1
						if (k in lskey) { lansynf++; lansyn += scount[k] - 1 }
					}
					printf "packets=%d lan_packets=%d data_packets=%d lan_data_packets=%d dup_flows=%d dup_retrans=%d lan_dup_retrans=%d synack_flows=%d synack_retrans=%d lan_synack_retrans=%d\n", total + 0, lan_pkts + 0, data + 0, lan_data + 0, dupf, dup, landup, synf, syn, lansyn
					shown = 0
					for (k in dcount) if (dcount[k] > 1 && shown < 10) { printf "dup-data %dx %s\n", dcount[k], k; shown++ }
					shown = 0
					for (k in scount) if (scount[k] > 1 && shown < 10) { printf "dup-synack %dx %s\n", scount[k], k; shown++ }
				}
			' "$TCPDUMP_TXT" 2>/dev/null)
		else
			echo "[WARN] capture produced no packets (interface down, filter miss or no traffic)"
			[ -s "$TCPDUMP_ERR" ] && sed -n '1,3p' "$TCPDUMP_ERR"
			: >"$TCPDUMP_TXT" 2>/dev/null || true
		fi
	fi
else
	echo "capture : skipped (--no-capture)"
fi

# ----------------------------------------------------------- post state + S1
_active2=$(api_get /observability/v1/connections/active) || _active2=""
_active2_total=$(printf '%s\n' "$_active2" | json_total)
_clash2=$(clash_connections)
_m2=$(api_get /observability/v1/metrics) || _m2=""

take_snapshot "$SNAP_POST" "stall-$TS-post"
SNAP_POST_STATE="$SNAP_LAST_STATE"

_dupf=0
_dup=0
_synf=0
_syn=0
_lan_pkts=0
_lan_data=0
_lan_dup=0
_lan_syn=0
_packets=0
if [ -n "$REPORT" ]; then
	_line=$(printf '%s\n' "$REPORT" | sed -n '1p')
	for _kv in $_line; do
		case "$_kv" in
		packets=*) _packets=${_kv#*=} ;;
		lan_packets=*) _lan_pkts=${_kv#*=} ;;
		lan_data_packets=*) _lan_data=${_kv#*=} ;;
		dup_flows=*) _dupf=${_kv#*=} ;;
		dup_retrans=*) _dup=${_kv#*=} ;;
		lan_dup_retrans=*) _lan_dup=${_kv#*=} ;;
		synack_flows=*) _synf=${_kv#*=} ;;
		synack_retrans=*) _syn=${_kv#*=} ;;
		lan_synack_retrans=*) _lan_syn=${_kv#*=} ;;
		esac
	done
fi

if [ "$CAPTURED" -eq 1 ] && [ "$_packets" -eq 0 ]; then
	echo "[WARN] pcap contains no packets; symptom 2 stays unknown"
	CAPTURED=0
fi

_traffic_delta="?"
_conn_delta="?"
if [ -n "$_m1" ] && [ -n "$_m2" ]; then
	_up1=$(metric_sum "$_m1" singbox_traffic_upload_bytes_total)
	_dn1=$(metric_sum "$_m1" singbox_traffic_download_bytes_total)
	_up2=$(metric_sum "$_m2" singbox_traffic_upload_bytes_total)
	_dn2=$(metric_sum "$_m2" singbox_traffic_download_bytes_total)
	_ct1=$(metric_sum "$_m1" singbox_connections_total)
	_ct2=$(metric_sum "$_m2" singbox_connections_total)
	_traffic_delta=$(((_up2 + _dn2) - (_up1 + _dn1)))
	_conn_delta=$((_ct2 - _ct1))
fi

S1=0
if [ "$_active2_total" = 0 ]; then
	if [ "$_traffic_delta" != "?" ] && [ "$_traffic_delta" -gt 0 ]; then
		S1=1
	elif [ "$_conn_delta" != "?" ] && [ "$_conn_delta" -gt 0 ]; then
		S1=1
	elif [ "$_clash2" != "?" ] && [ "$_clash2" -gt 0 ]; then
		S1=1
	fi
fi

S2=-1
if [ "$CAPTURED" -eq 1 ]; then
	S2=0
	if [ "$_dup" -gt 0 ] || [ "$_syn" -ge 2 ]; then
		S2=1
	fi
fi
S2_LAN=0
if [ "$CAPTURED" -eq 1 ] && { [ "$_lan_dup" -gt 0 ] || [ "$_lan_syn" -ge 2 ]; }; then
	S2_LAN=1
fi
LAN_OBSERVED=0
if [ "$CAPTURED" -eq 1 ] && [ "$_lan_pkts" -gt 0 ]; then
	LAN_OBSERVED=1
fi

echo
echo "-- symptom 1: observability vs traffic (path-agnostic) --"
printf 'active  : before=%s after=%s | clash before=%s after=%s\n' "$_active1_total" "$_active2_total" "$_clash1" "$_clash2"
printf 'delta   : traffic=%s bytes connections=%s (over capture window)\n' "$_traffic_delta" "$_conn_delta"
if [ "$S1" -eq 1 ]; then
	echo "[FAIL] active=0 while traffic/Clash shows activity -- connection object missing (§31.1)"
	echo "       this alone does not say which path (local/shared) lost the object"
else
	echo "[ OK ] active state is consistent with traffic (path-agnostic)"
fi

echo
echo "-- symptom 2: LAN TCP retransmissions --"
if [ "$CAPTURED" -eq 1 ]; then
	printf 'packets : %s captured | lan-client=%s (data=%s) | data retrans=%s (%s flows) | SYN-ACK retrans=%s (%s flows)\n' \
		"$_packets" "$_lan_pkts" "$_lan_data" "$_dup" "$_dupf" "$_syn" "$_synf"
	printf 'lan-only: data retrans=%s | SYN-ACK retrans=%s\n' "$_lan_dup" "$_lan_syn"
	[ -f "$TCPDUMP_TXT" ] && sed -n '2,21p' "$TCPDUMP_TXT" | sed 's/^/         /'
	if [ "$LAN_OBSERVED" -eq 0 ]; then
		echo "[UNKNOWN] no LAN-client packet in this window ($IFACE subnet ${LAN_CIDR:-unknown})"
		echo "          retransmission counts above are not LAN evidence"
	elif [ "$S2_LAN" -eq 1 ]; then
		echo "[FAIL] LAN-client retransmissions without progress -- eBPF shared-plane stall signature (shared=$SHARED_WORD)"
	elif [ "$S2" -eq 1 ]; then
		echo "[SUSPECT] retransmissions seen, but not on LAN-client flows -- weak provenance"
	else
		echo "[ OK ] no repeated data/SYN-ACK segments on LAN-client flows"
	fi
	echo "pcap    : $PCAP"
	[ -f "$TCPDUMP_TXT" ] && echo "dump    : $TCPDUMP_TXT"
else
	echo "[SKIP] no pcap analysis -- LAN path unverified"
fi

echo
echo "-- symptom 3: local probe stability (device-originated) --"
_codes=""
_ok=0
_i=1
while [ "$_i" -le 3 ]; do
	_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$TEST_URL" 2>/dev/null) || _code=000
	[ -n "$_code" ] || _code=000
	case "$_code" in
	200 | 204) _ok=$((_ok + 1)) ;;
	esac
	_codes="$_codes $_code"
	echo "probe #$_i : $_code"
	sleep 2
	_i=$((_i + 1))
done
_distinct=$(printf '%s\n' "$_codes" | tr ' ' '\n' | sed '/^$/d' | sort -u | wc -l | tr -d ' ')
S3=0
[ "$_distinct" -gt 1 ] && S3=1
[ "$_ok" -eq 0 ] && S3=1
if [ "$S3" -eq 1 ]; then
	echo "[FAIL] local probes drift/fail (distinct codes=$_distinct, ok=$_ok/3) -- local/proxy path degraded"
else
	echo "[ OK ] local probes stable -- proves the local path only, NOT LAN client health"
fi

# --------------------------------------------------------------- final verdict
echo
echo "== verdict =="
if [ "$S1" -eq 1 ] && [ "$S2_LAN" -eq 1 ]; then
	echo "STALL: eBPF shared path confirmed (shared=$SHARED_WORD; missing connection object + LAN-client retransmissions)."
	echo "       Roll back to the TUN all-proxy config (see MONITORING.md)."
	echo "       evidence: $TCPDUMP_TXT"
	_ref=$(snapshot_ref "$SNAP_PRE" "$SNAP_PRE_STATE")
	[ -n "$_ref" ] && echo "       snapshot: $_ref"
	_ref=$(snapshot_ref "$SNAP_POST" "$SNAP_POST_STATE")
	[ -n "$_ref" ] && echo "                 $_ref"
	exit 1
fi
if [ "$S2_LAN" -eq 1 ]; then
	echo "SUSPECT: LAN-client retransmissions observed, but the connection-object symptom"
	echo "         did not fire in this window.  Keep the pcap and re-run under load."
	echo "         evidence: $TCPDUMP_TXT"
	exit 2
fi
if [ "$S2" -eq 1 ]; then
	echo "SUSPECT: retransmissions seen but only on non-LAN flows; provenance is weak."
	echo "         Not a LAN stall verdict.  Keep the pcap and re-run with LAN traffic."
	exit 2
fi
if [ "$S1" -eq 1 ]; then
	echo "SUSPECT: empty /connections/active with live traffic, no LAN-client retransmission"
	echo "         evidence.  Path not identified (local/shared); not a LAN stall verdict."
	exit 2
fi
if [ "$CAPTURE" -eq 0 ] || [ "$CAPTURED" -eq 0 ]; then
	echo "INCONCLUSIVE: no pcap analysis; the LAN client path was not exercised."
	echo "              Local probes and active counts cannot prove LAN health."
	exit 2
fi
if [ "$LAN_OBSERVED" -eq 0 ]; then
	echo "INCONCLUSIVE: capture ran but no LAN-client packet appeared in the window"
	echo "              (subnet ${LAN_CIDR:-unknown}).  The LAN path is unproven;"
	echo "              drive client traffic and re-run."
	exit 2
fi
if [ "$S3" -eq 1 ]; then
	echo "SUSPECT: LAN-client flows looked clean, but local probes drift/fail."
	echo "         Local/proxy path is degraded; LAN verdict is not a clean bill of health."
	exit 2
fi
if [ -z "$_active2" ]; then
	echo "SUSPECT: observability API disappeared mid-run; the connection-object"
	echo "         symptom is unknown.  Re-run once the controller is stable."
	exit 2
fi
echo "OK: LAN-client flows observed clean (no retransmissions) and local probes stable."
echo "    window: $_lan_pkts LAN-client packets, $_lan_data with data"
_ref=$(snapshot_ref "$SNAP_PRE" "$SNAP_PRE_STATE")
[ -n "$_ref" ] && echo "    snapshot: $_ref"
_ref=$(snapshot_ref "$SNAP_POST" "$SNAP_POST_STATE")
[ -n "$_ref" ] && echo "              $_ref"
exit 0
