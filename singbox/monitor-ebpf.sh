#!/bin/sh
# Real-time health monitor for the TUN / eBPF migration (TopFlow MU5252 B20).
#
# One screen per interval, no state server, no dependencies beyond busybox,
# curl and (optionally) jq.  Everything is read-only:
#   * /observability/v1/{connections/active,connections/recent,metrics,top}
#   * /proc/net/dev (per-card counters, differenced over the interval)
#   * singbox-wan-balance.sh status (pool + bypass mark source)
#   * ebpf-snapshot.sh (bounded runtime evidence) on anomaly, not per interval
#
# Usage:
#   sh monitor-ebpf.sh                     # 5 s cadence, runs until Ctrl-C
#   sh monitor-ebpf.sh --interval 2
#   sh monitor-ebpf.sh --once              # one snapshot (baseline rates)
#   sh monitor-ebpf.sh > /data/sing-box/diagnostics/monitor.log
#
# Environment:
#   SINGBOX_BASE=/data/sing-box           base directory
#   SINGBOX_API=http://127.0.0.1:9999     Clash controller (observability prefix)
#   SINGBOX_API_SECRET=...                sends Authorization: Bearer
#   SINGBOX_BALANCE=$BASE/singbox-wan-balance.sh
#   SINGBOX_STATE=$BASE/state
#   SINGBOX_MONITOR_SNAPSHOT=/tmp/singbox-monitor.dev
#   WAN_DEVICES="rmnet_data0 V3E1net0 V3E2net0"
#
# Exit codes: 0 normal (also on Ctrl-C); 2 bad usage.

set -u

BASE="${SINGBOX_BASE:-/data/sing-box}"
API="${SINGBOX_API:-http://127.0.0.1:9999}"
SECRET="${SINGBOX_API_SECRET:-}"
CONF="${SINGBOX_CONFIG:-$BASE/config.json}"
BALANCE="${SINGBOX_BALANCE:-$BASE/singbox-wan-balance.sh}"
STATE="${SINGBOX_STATE:-$BASE/state}"
SNAP="${SINGBOX_MONITOR_SNAPSHOT:-/tmp/singbox-monitor.dev}"
WAN_DEVICES="${WAN_DEVICES:-rmnet_data0 V3E1net0 V3E2net0}"
SNAP_DIR="${SINGBOX_MONITOR_SNAPSHOT_DIR:-$BASE/diagnostics}"
SNAP_SCRIPT="${SINGBOX_MONITOR_SNAPSHOT_SCRIPT:-$BASE/ebpf-snapshot.sh}"
SNAP_COOLDOWN="${SINGBOX_MONITOR_SNAPSHOT_COOLDOWN:-120}"
SNAP_TIMEOUT="${SINGBOX_MONITOR_SNAPSHOT_TIMEOUT:-5}"
SNAP_KEEP="${SINGBOX_MONITOR_SNAPSHOT_KEEP:-8}"
INTERVAL=5
# Upper bound on inbounds inspected when locating the eBPF inbound.
MAX_INBOUNDS=64
ONCE=0
SNAPSHOT_ENABLED=1
SNAPSHOT_ONLY=0

usage() {
	cat <<'EOF'
usage: monitor-ebpf.sh [-1|--once] [-n|--interval SECONDS] [--snapshot] [--no-snapshot] [-h|--help]

  -1, --once              print one snapshot and exit
  -n, --interval SEC      seconds between snapshots (default 5)
      --snapshot          run ebpf-snapshot.sh once and exit (manual evidence)
      --no-snapshot       never auto-collect runtime evidence on anomaly
  -h, --help              this text

Read-only: observability API + /proc/net/dev + wan-balance status.
Runtime evidence (tc/ip/nft/eBPF gRPC counters) is collected by
ebpf-snapshot.sh only when this monitor flags an anomaly, with a cooldown
(SINGBOX_MONITOR_SNAPSHOT_COOLDOWN, default 120 s).  No daemon is started.
Redirect stdout to a file to keep a log (one screen per interval).
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	-1 | --once)
		ONCE=1
		;;
	-n | --interval)
		[ "$#" -ge 2 ] || { usage >&2; exit 2; }
		INTERVAL="$2"
		shift
		;;
	--snapshot)
		SNAPSHOT_ONLY=1
		;;
	--no-snapshot)
		SNAPSHOT_ENABLED=0
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

case "$INTERVAL" in
'' | *[!0-9]*)
	echo "interval must be a positive integer: $INTERVAL" >&2
	exit 2
	;;
esac
[ "$INTERVAL" -gt 0 ] || { echo "interval must be > 0" >&2; exit 2; }
case "$SNAP_COOLDOWN" in
'' | *[!0-9]*)
	echo "snapshot cooldown must be a non-negative integer: $SNAP_COOLDOWN" >&2
	exit 2
	;;
esac
case "$SNAP_TIMEOUT" in
'' | *[!0-9]*)
	echo "snapshot timeout must be a positive integer: $SNAP_TIMEOUT" >&2
	exit 2
	;;
esac
[ "$SNAP_TIMEOUT" -gt 0 ] || { echo "snapshot timeout must be > 0" >&2; exit 2; }
case "$SNAP_KEEP" in
'' | *[!0-9]*)
	echo "snapshot keep must be a positive integer: $SNAP_KEEP" >&2
	exit 2
	;;
esac
[ "$SNAP_KEEP" -gt 0 ] || { echo "snapshot keep must be > 0" >&2; exit 2; }

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

# Sum one metric family from a /metrics body.  Label sets are collapsed so a
# metric split by outbound/inbound still yields one total.
metric_sum() { # metric_sum <metrics-body> <name>
	printf '%s\n' "$1" | awk -v n="$2" '
		BEGIN { p = n "{" }
		$1 == n || index($0, p) == 1 { s += $NF }
		END { printf "%.0f", s + 0 }
	'
}

# Direct-egress bytes.  Under the zero-rating rule every non-LAN byte must
# leave through a proxy, so this must stay flat (DNS bootstrap / LAN / device
# management are the only legitimate exceptions).  Matches the direct outbound
# tag regardless of its display name.
metric_direct() { # metric_direct <metrics-body> <name>
	printf '%s\n' "$1" | awk -v n="$2" '
		BEGIN { p = n "{" }
		($1 == n || index($0, p) == 1) &&
			(index($0, "直连") || index($0, "DIRECT") || index($0, "direct")) { s += $NF }
		END { printf "%.0f", s + 0 }
	'
}

human_bytes() {
	awk -v b="${1:-0}" 'BEGIN {
		split("B KiB MiB GiB TiB", u, " ")
		i = 1
		while (b >= 1024 && i < 5) { b /= 1024; i++ }
		printf "%.1f %s", b, u[i]
	}'
}

# Index of the eBPF inbound; rc 1 when there is none, 2 when the config cannot
# be enumerated (device jsonfilter exits 1 for an out-of-range index and for a
# missing optional field alike, so the array query is the only parse signal).
ebpf_index() {
    [ -f "$CONF" ] || return 2
    command -v jsonfilter >/dev/null 2>&1 || return 2
    _types=$(jsonfilter -i "$CONF" -e '@.inbounds[*].type' 2>/dev/null) || return 2
    [ -n "$_types" ] || return 2
    _cnt=$(printf '%s\n' "$_types" | grep -c .)
    [ "$_cnt" -le "$MAX_INBOUNDS" ] || return 2
    _i=0
    while [ "$_i" -lt "$_cnt" ]; do
        if [ "$(printf '%s\n' "$_types" | sed -n "$((_i + 1))p")" = ebpf ]; then
            echo "$_i"
            return 0
        fi
        _i=$((_i + 1))
    done
    return 1
}

# One field of the eBPF inbound (empty output = field absent).  rc 1 when there
# is no eBPF inbound, 2 when the config cannot be parsed -- callers print
# unknown for 2 and never a build default.
ebpf_plane_field() { # ebpf_plane_field <shared.enabled|local.data_plane|...>
    _idx=$(ebpf_index) || return "$?"
    jsonfilter -i "$CONF" -e "@.inbounds[$_idx].$1" 2>/dev/null | tr -d '"'
}

detect_mode() {
	if [ ! -f "$CONF" ]; then
		echo "unknown"
		return 0
	fi
	if ! grep -q '"type"[[:space:]]*:[[:space:]]*"ebpf"' "$CONF" 2>/dev/null; then
		echo "tun"
		return 0
	fi
	# shared.enabled is the switch, not the presence of a "shared" object: a
	# block left at enabled:false keeps LAN clients off the data plane and must
	# not read as local+shared.  An unparseable config is 'plane-unknown', and
	# never silently downgraded to either real plane.
	_p=$(ebpf_plane_field shared.enabled 2>/dev/null) || _p=parse-failed
	case "$_p" in
	true) echo "ebpf local+shared" ;;
	'' | false) echo "ebpf local" ;;
	*) echo "ebpf plane-unknown" ;;
	esac
}

inbound_summary() {
	if command -v jq >/dev/null 2>&1; then
		printf '%s\n' "$1" | jq -r '[.data[]? | (.inbound // .metadata.inbound // "?")] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' 2>/dev/null
	else
		printf '%s\n' "$1" | grep -o '"inbound"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null |
			sed 's/.*"\([^"]*\)"$/\1/' | sort | uniq -c |
			awk '{ printf "%s=%s ", $2, $1 }'
	fi
}

top_outbounds() {
	command -v jq >/dev/null 2>&1 || return 0
	printf '%s\n' "$1" | jq -r '[.data[:5][]? | "\(.value)=\(.connections)"] | join(" ")' 2>/dev/null
}

wan_balance_summary() {
	if [ ! -f "$BALANCE" ]; then
		echo "balance        : (missing $BALANCE)"
		return 0
	fi
	_bal=$(sh "$BALANCE" status 2>/dev/null) || _bal=""
	if [ -z "$_bal" ]; then
		echo "balance        : (status failed)"
		return 0
	fi
	printf '%s\n' "$_bal" | awk '
		/^== pool/ { next }
		/^== bypass mark/ { getline; print "balance mark   : " $0; next }
		NF >= 5 && $3 ~ /^[0-9]+$/ {
			printf "balance pool   : %s dev=%s w=%s table=%s gw=%s\n", $1, $2, $3, $4, $5
			n++
		}
		END { if (n == 0) print "balance pool   : (empty)" }
	'
}

# ------------------------------------------------------- runtime evidence
# Spawn the bounded collector (no daemon).  It caps every command itself, so a
# missing nft/ip/tc or an unresponsive gRPC endpoint cannot wedge the monitor.
# Keep at most SNAP_KEEP auto-collected dirs.  Only exact auto-generated names
# inside SNAP_DIR are removed; manual snapshots and anything else are untouched.
prune_auto_snapshots() {
	_list=$(ls -1d "$SNAP_DIR"/monitor-[0-9]*T[0-9]*Z 2>/dev/null | sort)
	_n=$(printf '%s\n' "$_list" | sed '/^$/d' | wc -l | tr -d ' ')
	while [ "$_n" -ge "$SNAP_KEEP" ]; do
		_oldest=$(printf '%s\n' "$_list" | sed -n '1p')
		[ -n "$_oldest" ] || return 0
		case "$_oldest" in
		"$SNAP_DIR"/monitor-[0-9]*T[0-9]*Z) rm -rf "$_oldest" ;;
		*) return 0 ;;
		esac
		_list=$(printf '%s\n' "$_list" | sed -n '2,$p')
		_n=$((_n - 1))
	done
}

take_snapshot() { # take_snapshot <label> [dir] [wait]
	_snap_label="$1"
	_snap_dir="${2:-$SNAP_DIR/monitor-$(date -u +%Y%m%dT%H%M%SZ)}"
	if [ ! -f "$SNAP_SCRIPT" ]; then
		echo "snapshot       : skipped (missing $SNAP_SCRIPT)"
		return 1
	fi
	[ "${3:-}" = wait ] || prune_auto_snapshots
	if ! mkdir -p "$_snap_dir" 2>/dev/null; then
		echo "snapshot       : FAILED (cannot create $_snap_dir)"
		return 1
	fi
	if [ "${3:-}" = wait ]; then
		if SINGBOX_BASE="$BASE" sh "$SNAP_SCRIPT" --output "$_snap_dir" --label "$_snap_label" \
			--timeout "$SNAP_TIMEOUT" >/dev/null 2>&1; then
			echo "snapshot       : $_snap_dir"
		else
			echo "snapshot       : $_snap_dir (partial; see failures.txt)"
		fi
		return 0
	fi
	# Auto-triggered: run detached so one wedged command cannot delay the
	# monitoring cadence.  The collector is a bounded one-shot, not a daemon.
	(SINGBOX_BASE="$BASE" sh "$SNAP_SCRIPT" --output "$_snap_dir" --label "$_snap_label" \
		--timeout "$SNAP_TIMEOUT" >/dev/null 2>&1) &
	echo "snapshot       : $_snap_dir (collecting)"
	return 0
}

maybe_snapshot() { # maybe_snapshot <reason tokens>
	[ "$SNAPSHOT_ENABLED" -eq 1 ] || return 0
	[ -n "$1" ] || return 0
	_snap_reasons=$(printf '%s' "$1" | sed 's/^ *//; s/  */,/g')
	_snap_now=$(date +%s)
	_snap_last=$(cat "$SNAP.snapshot-ts" 2>/dev/null) || _snap_last=0
	case "$_snap_last" in
	'' | *[!0-9]*) _snap_last=0 ;;
	esac
	[ "$_snap_now" -ge "$_snap_last" ] || _snap_last=0
	if [ $((_snap_now - _snap_last)) -lt "$SNAP_COOLDOWN" ]; then
		echo "snapshot       : suppressed (cooldown $(( _snap_now - _snap_last ))s < ${SNAP_COOLDOWN}s) reason=$_snap_reasons"
		return 0
	fi
	echo "$_snap_now" >"$SNAP.snapshot-ts" 2>/dev/null || true
	take_snapshot "monitor:$_snap_reasons"
}

# One sampling cycle.  Uses only globals defined above.
cycle() {
	_epoch=$(date +%s)
	_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	_mode=$(detect_mode)
	case "$_mode" in
	tun) _mode_token="tun" ;;
	"ebpf local") _mode_token="ebpf-local" ;;
	"ebpf local+shared") _mode_token="ebpf-local-shared" ;;
	*) _mode_token="plane-unknown" ;;
	esac
	_reasons=""
	_pid=$(cat "$STATE/sing-box.pid" 2>/dev/null) || _pid=""
	if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
		_core="up pid=$_pid"
	else
		_core="down"
		_reasons="core-down"
	fi
	_ver=$(api_get /version | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')
	if [ -z "$_ver" ]; then
		_reasons="$_reasons api-unreachable"
	fi
	_prev_mode=$(awk '$2 == "@mode" { print $3; exit }' "$SNAP" 2>/dev/null) || _prev_mode=""
	if [ -n "$_prev_mode" ] && [ "$_prev_mode" != "$_mode_token" ]; then
		_reasons="$_reasons mode-change:$_prev_mode->$_mode_token"
	fi

	_active=$(api_get /observability/v1/connections/active)
	_recent=$(api_get '/observability/v1/connections/recent?limit=1')
	_metrics=$(api_get /observability/v1/metrics)
	_top=$(api_get '/observability/v1/top?dimension=outbound&limit=10')

	_active_total=""
	if [ -n "$_active" ]; then
		_active_total=$(printf '%s\n' "$_active" | json_total)
	fi
	_recent_total=""
	if [ -n "$_recent" ]; then
		_recent_total=$(printf '%s\n' "$_recent" | json_total)
	fi

	_up=""
	_down=""
	_conn_total=""
	_dir_up=""
	_dir_dn=""
	if [ -n "$_metrics" ]; then
		_up=$(metric_sum "$_metrics" singbox_traffic_upload_bytes_total)
		_down=$(metric_sum "$_metrics" singbox_traffic_download_bytes_total)
		_conn_total=$(metric_sum "$_metrics" singbox_connections_total)
		_dir_up=$(metric_direct "$_metrics" singbox_outbound_upload_bytes_total)
		_dir_dn=$(metric_direct "$_metrics" singbox_outbound_download_bytes_total)
	fi

	_prev_ts=$(awk 'NR == 1 { print $1 }' "$SNAP" 2>/dev/null) || _prev_ts=0
	[ -n "$_prev_ts" ] || _prev_ts=0
	_elapsed=$((_epoch - _prev_ts))
	[ "$_elapsed" -gt 0 ] || _elapsed=$INTERVAL
	_stale=0
	[ "$_elapsed" -gt $((INTERVAL * 10)) ] && _stale=1

	echo "=== $_utc ==="
	if [ -n "$_ver" ]; then
		echo "core           : $_core | version $_ver | mode $_mode"
	else
		echo "core           : $_core | mode $_mode | API unreachable ($API)"
	fi
	# Actual planes, not the profile name: the same profile can be built with
	# either shared plane, and "unknown" is a real answer when the config or
	# jsonfilter is unavailable.
	if [ "$_mode" != "tun" ]; then
		_lp=$(ebpf_plane_field local.data_plane 2>/dev/null) || _lp=unknown
		_sh=$(ebpf_plane_field shared.enabled 2>/dev/null) || _sh=unknown
		[ -n "$_lp" ] || _lp=unset
		if [ "$_sh" = true ]; then
			_sp=$(ebpf_plane_field shared.data_plane 2>/dev/null) || _sp=unknown
			[ -n "$_sp" ] || _sp=unset
			printf 'data plane     : local %s | shared %s\n' "$_lp" "$_sp"
		else
			printf 'data plane     : local %s | shared %s\n' "$_lp" "${_sh:-absent}"
		fi
	fi

	if [ -n "$_active_total" ]; then
		printf 'connections    : active %s | recent %s' "$_active_total" "${_recent_total:-?}"
		if [ -n "$_conn_total" ]; then
			printf ' | opened %s' "$_conn_total"
		fi
		echo
		echo "inbound        : $(inbound_summary "$_active")"
	else
		echo "connections    : observability unavailable (check experimental.observability)"
	fi

	_top_line=$(top_outbounds "$_top")
	[ -n "$_top_line" ] && echo "top outbounds  : $_top_line"

	_delta_total=-1
	if [ -n "$_up" ]; then
		printf 'traffic        : up %s | down %s' "$(human_bytes "$_up")" "$(human_bytes "$_down")"
		_prev_up=$(awk '$2 == "@up" { print $3; exit }' "$SNAP" 2>/dev/null) || _prev_up=""
		_prev_down=$(awk '$2 == "@down" { print $3; exit }' "$SNAP" 2>/dev/null) || _prev_down=""
		if [ "$_stale" -eq 0 ] && [ -n "$_prev_up" ] && [ -n "$_prev_down" ]; then
			if [ "$_up" -ge "$_prev_up" ] 2>/dev/null && [ "$_down" -ge "$_prev_down" ] 2>/dev/null; then
				_rx=$(((_up - _prev_up) / _elapsed))
				_tx=$(((_down - _prev_down) / _elapsed))
				_delta_total=$(((_up - _prev_up) + (_down - _prev_down)))
				printf ' | now ↓ %s/s ↑ %s/s' "$(human_bytes "$_rx")" "$(human_bytes "$_tx")"
			else
				printf ' | counters reset'
			fi
		else
			printf ' | baseline'
		fi
		echo
	else
		echo "traffic        : unavailable"
	fi
	if [ "$_active_total" = "0" ] && [ "$_delta_total" -gt 0 ]; then
		_reasons="$_reasons active-empty-with-traffic"
	fi
	if [ -z "$_active_total" ]; then
		case "$_reasons" in
		*api-unreachable*) ;;
		*) _reasons="$_reasons observability-unavailable" ;;
		esac
	fi

	_dir_delta=-1
	if [ -n "$_dir_up" ]; then
		printf 'direct egress  : up %s | down %s' "$(human_bytes "$_dir_up")" "$(human_bytes "$_dir_dn")"
		_prev_dup=$(awk '$2 == "@dup" { print $3; exit }' "$SNAP" 2>/dev/null) || _prev_dup=""
		_prev_ddn=$(awk '$2 == "@ddn" { print $3; exit }' "$SNAP" 2>/dev/null) || _prev_ddn=""
		if [ "$_stale" -eq 0 ] && [ -n "$_prev_dup" ] && [ -n "$_prev_ddn" ]; then
			if [ "$_dir_up" -ge "$_prev_dup" ] 2>/dev/null && [ "$_dir_dn" -ge "$_prev_ddn" ] 2>/dev/null; then
				_delta=$(((_dir_up - _prev_dup) + (_dir_dn - _prev_ddn)))
				_dir_delta=$_delta
				printf ' | +%s this interval' "$(human_bytes "$_delta")"
				[ "$_delta" -gt 0 ] && printf ' [CHECK: PT/DNS/ICMP only]'
			else
				printf ' | counters reset'
			fi
		else
			printf ' | baseline'
		fi
		echo
	fi
	if [ "$_dir_delta" -gt 0 ]; then
		_reasons="$_reasons direct-egress"
	fi

	_new="$_epoch"
	for _dev in $WAN_DEVICES; do
		_vals=$(awk -v d="$_dev" '$1 == d ":" { print $2, $10; exit }' /proc/net/dev 2>/dev/null)
		if [ -z "$_vals" ]; then
			printf 'wan %-10s : absent\n' "$_dev"
			_reasons="$_reasons wan-absent:$_dev"
			continue
		fi
		_cur_rx=${_vals%% *}
		_cur_tx=${_vals##* }
		_prev_vals=$(awk -v d="$_dev" '$2 == d { print $3, $4; exit }' "$SNAP" 2>/dev/null)
		if [ "$_stale" -eq 0 ] && [ -n "$_prev_vals" ]; then
			_prev_rx=${_prev_vals%% *}
			_prev_tx=${_prev_vals##* }
			if [ "$_cur_rx" -ge "$_prev_rx" ] 2>/dev/null && [ "$_cur_tx" -ge "$_prev_tx" ] 2>/dev/null; then
				_rx=$(((_cur_rx - _prev_rx) / _elapsed))
				_tx=$(((_cur_tx - _prev_tx) / _elapsed))
				printf 'wan %-10s : ↓ %s/s ↑ %s/s\n' "$_dev" "$(human_bytes "$_rx")" "$(human_bytes "$_tx")"
			else
				printf 'wan %-10s : counter reset (↓ %s ↑ %s total)\n' "$_dev" "$(human_bytes "$_cur_rx")" "$(human_bytes "$_cur_tx")"
			fi
		else
			printf 'wan %-10s : ↓ %s ↑ %s total (baseline)\n' "$_dev" "$(human_bytes "$_cur_rx")" "$(human_bytes "$_cur_tx")"
		fi
		_new=$(printf '%s\n%s %s %s %s' "$_new" "$_epoch" "$_dev" "$_cur_rx" "$_cur_tx")
	done

	[ -n "$_up" ] && _new=$(printf '%s\n%s @up %s 0' "$_new" "$_epoch" "$_up")
	[ -n "$_down" ] && _new=$(printf '%s\n%s @down %s 0' "$_new" "$_epoch" "$_down")
	[ -n "$_dir_up" ] && _new=$(printf '%s\n%s @dup %s 0' "$_new" "$_epoch" "$_dir_up")
	[ -n "$_dir_dn" ] && _new=$(printf '%s\n%s @ddn %s 0' "$_new" "$_epoch" "$_dir_dn")
	_new=$(printf '%s\n%s @mode %s 0' "$_new" "$_epoch" "$_mode_token")
	printf '%s\n' "$_new" >"$SNAP" 2>/dev/null || true

	maybe_snapshot "$_reasons"

	wan_balance_summary
	echo
}

trap 'echo; exit 0' INT TERM

if [ "$SNAPSHOT_ONLY" -eq 1 ]; then
	echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) manual runtime snapshot ==="
	if take_snapshot "monitor:manual" "$SNAP_DIR/monitor-manual-$(date -u +%Y%m%dT%H%M%SZ)" wait; then
		exit 0
	fi
	exit 2
fi

if [ "$ONCE" -eq 1 ]; then
	cycle
	exit 0
fi

while :; do
	cycle
	sleep "$INTERVAL"
done
