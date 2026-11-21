#!/bin/sh
# Bounded, read-only runtime snapshot for the sing-box data plane (TUN or eBPF).
#
# This is the common evidence collector used by diagnose-stall.sh and
# monitor-ebpf.sh.  It changes nothing: no config write, no nft/tc mutation, no
# restart, no provider fetch.  It only reads:
#   * process/core identity (pid, version, config md5 -- never config content)
#   * tc statistics (qdisc + ingress/egress filters) on managed LAN/veth links
#   * ip links/addresses/rules/routes and network namespaces
#   * the eBPF gRPC diagnostics endpoint through `sing-box api ebpf --deep`
#   * nftables ruleset counters
#   * /proc/net/dev
#
# Every capture is bounded by a background watchdog (TERM, then KILL); the
# busybox on OpenWrt has no `timeout` applet.  Failures are written into the
# artifact directory instead of being silently skipped:
#   <name>.txt   command stdout (or a [UNAVAILABLE]/[ABSENT]/[TIMEOUT] marker)
#   <name>.err   command stderr
#   <name>.rc    rc=<n> | rc=absent | rc=timeout
#   status.txt   SNAPSHOT_STATUS=ok|partial, per-source summary
#   failures.txt one line per failed capture
#
# Usage (on device, as root):
#   sh ebpf-snapshot.sh --output /data/sing-box/diagnostics/snap-<label>
#   sh ebpf-snapshot.sh --output DIR --label stall-pre --timeout 8
#   sh ebpf-snapshot.sh --no-deep --output DIR         # skip kernel map walk
#   SINGBOX_SNAPSHOT_LAN_IFACE=br-lan sh ebpf-snapshot.sh --output DIR
#
# Contract: `--output DIR` writes every artifact inside DIR (created if needed)
# and prints `snapshot: DIR` on stdout, so callers can correlate an incident
# with the timestamped directory.
#
# Exit codes: 0 = required captures complete; 1 = at least one required capture
#             failed (artifacts still written); 2 = usage / unwritable output.

set -u

BASE="${SINGBOX_BASE:-/data/sing-box}"
BIN="${SINGBOX_BIN:-$BASE/sing-box}"
CONF="${SINGBOX_CONFIG:-$BASE/config.json}"
STATE="${SINGBOX_STATE:-$BASE/state}"
API_URL="${SINGBOX_SERVICE_API:-http://127.0.0.1:8088}"
SECRET="${SINGBOX_API_SECRET:-}"
LAN_IFACE="${SINGBOX_SNAPSHOT_LAN_IFACE:-br-lan}"

OUT=""
LABEL=""
CMD_TIMEOUT=5
DEEP=1
MAX_IFACES=8
# Inbound probe bound.  More inbounds than this and the plane fields become
# unknown instead of partially inspected (a missed eBPF inbound would report
# tun/no-plane evidence for a live eBPF core).
MAX_INBOUNDS=64

usage() {
	cat <<'EOF'
usage: ebpf-snapshot.sh --output DIR [options]

  -o, --output DIR   artifact directory (created if missing); required
      --label TAG    free-form incident label stored in meta.txt
  -t, --timeout SEC  per-command bound in seconds (default 5)
      --deep         `api ebpf --deep` (default: on)
      --no-deep      light status only, skip kernel program/map walk
  -h, --help         this text

Read-only. Never prints config content, provider URLs or secrets; the config is
recorded as md5 + size + mtime only.  `snapshot: DIR` is the last stdout line
group start, followed by the status summary.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	-o | --output)
		[ "$#" -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
		OUT="$2"
		shift
		;;
	--label)
		[ "$#" -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
		LABEL="$2"
		shift
		;;
	-t | --timeout)
		[ "$#" -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
		CMD_TIMEOUT="$2"
		shift
		;;
	--deep)
		DEEP=1
		;;
	--no-deep)
		DEEP=0
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

[ -n "$OUT" ] || { echo "missing --output DIR" >&2; exit 2; }
case "$CMD_TIMEOUT" in
'' | *[!0-9]*) echo "--timeout must be a positive integer" >&2; exit 2 ;;
esac
[ "$CMD_TIMEOUT" -gt 0 ] || { echo "--timeout must be > 0" >&2; exit 2; }

mkdir -p "$OUT" 2>/dev/null || { echo "cannot create $OUT" >&2; exit 2; }
[ -w "$OUT" ] || { echo "cannot write $OUT" >&2; exit 2; }
OUT=$(cd "$OUT" 2>/dev/null && pwd) || { echo "cannot enter $OUT" >&2; exit 2; }

: >"$OUT/failures.txt"
: >"$OUT/absent.txt"
FAILREQ=0
FAILN=0
ABSENTN=0

note_fail() { # note_fail <required|optional> <name> <reason>
	printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$OUT/failures.txt"
	FAILN=$((FAILN + 1))
	[ "$1" = required ] && FAILREQ=1
	return 0
}

# Deliberate absence (e.g. TUN mode has no eBPF diagnostic), not a crash.
mark_absent() { # mark_absent <name> <text>  (known absence, never a failure)
	_name="$1"
	_text="$2"
	printf '[ABSENT] %s\n' "$_text" >"$OUT/$_name.txt"
	: >"$OUT/$_name.err"
	printf 'rc=absent\n' >"$OUT/$_name.rc"
	printf '%s\t%s\n' "$_name" "$_text" >>"$OUT/absent.txt"
	ABSENTN=$((ABSENTN + 1))
	return 0
}

# Bounded capture: kill the command after CMD_TIMEOUT via a watchdog subshell.
capture() { # capture <required|optional> <name> <cmd...>
	_req="$1"
	_name="$2"
	shift 2
	: >"$OUT/$_name.err"
	"$@" >"$OUT/$_name.txt" 2>"$OUT/$_name.err" &
	_pid=$!
	(sleep "$CMD_TIMEOUT"; kill -TERM "$_pid" 2>/dev/null; sleep 1; kill -KILL "$_pid" 2>/dev/null) \
		>/dev/null 2>&1 &
	_wd=$!
	wait "$_pid"
	_rc=$?
	kill "$_wd" 2>/dev/null
	wait "$_wd" 2>/dev/null
	if [ "$_rc" -eq 0 ]; then
		printf 'rc=0\n' >"$OUT/$_name.rc"
		return 0
	fi
	if [ "$_rc" -eq 143 ] || [ "$_rc" -eq 137 ]; then
		printf 'rc=timeout timeout=%s\n' "$CMD_TIMEOUT" >"$OUT/$_name.rc"
		_reason="timeout after ${CMD_TIMEOUT}s"
	elif [ "$_rc" -eq 127 ]; then
		printf 'rc=%s unavailable\n' "$_rc" >"$OUT/$_name.rc"
		_reason="tool missing (rc=127)"
	else
		printf 'rc=%s\n' "$_rc" >"$OUT/$_name.rc"
		_reason="failure rc=$_rc"
	fi
	if [ ! -s "$OUT/$_name.txt" ]; then
		printf '[UNAVAILABLE] %s\n' "$_reason" >"$OUT/$_name.txt"
	fi
	_first=$(sed -n '1p' "$OUT/$_name.err" 2>/dev/null)
	[ -n "$_first" ] && note_fail "$_req" "$_name" "$_reason: $_first" || note_fail "$_req" "$_name" "$_reason"
	return 0
}

# --------------------------------------------------------------- environment
UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || UTC="unknown"
UTC_COMPACT=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null) || UTC_COMPACT="unknown"
EPOCH=$(date +%s 2>/dev/null) || EPOCH=0
PID=""
[ -f "$STATE/sing-box.pid" ] && PID=$(sed -n '1p' "$STATE/sing-box.pid" 2>/dev/null | tr -d ' ')
PID_STATE="pidfile"
if [ -z "$PID" ]; then
	PID_STATE="no-pidfile"
fi
PID_LIVE=""
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
	PID_LIVE="alive"
else
	[ -n "$PID" ] && PID_LIVE="stale"
fi

# ---------------------------------------------------------- data plane state
# Plane fields come from a JSON parser, never from a text scan: a grepped
# `"shared"` object cannot tell enabled:true from enabled:false, and the old
# text scan reported a disabled block as "local+shared".  Every field stays
# unknown when the config cannot be enumerated -- a snapshot may not claim a
# plane the core never attached.
LOCAL_PLANE="unknown"
SHARED_ENABLED="unknown"
SHARED_PLANE="none"
SHARED_IFACES="-"
INBOUND_TYPE="none"
PLANE_STATE="ok"

plane_field() { # plane_field <index> <path>  (empty output = field absent)
	jsonfilter -i "$CONF" -e "@.inbounds[$1].$2" 2>/dev/null | tr -d '"'
}

# Sets INBOUND_TYPE (ebpf|other) and, for eBPF, the plane fields.  Exit 1 only
# when the config cannot be enumerated: device jsonfilter exits 1 both for an
# out-of-range index and for a missing optional field, so a per-index walk
# cannot separate "absent" from "broken" -- the array query can.
plane_probe() {
	[ -f "$CONF" ] || return 1
	command -v jsonfilter >/dev/null 2>&1 || return 1
	_types=$(jsonfilter -i "$CONF" -e '@.inbounds[*].type' 2>/dev/null) || return 1
	[ -n "$_types" ] || return 1
	_cnt=$(printf '%s\n' "$_types" | grep -c .)
	[ "$_cnt" -le "$MAX_INBOUNDS" ] || return 1
	_i=0
	while [ "$_i" -lt "$_cnt" ]; do
		if [ "$(printf '%s\n' "$_types" | sed -n "$((_i + 1))p")" = ebpf ]; then
			INBOUND_TYPE="ebpf"
			_lp=$(plane_field "$_i" local.data_plane)
			LOCAL_PLANE=${_lp:-unset}
			_se=$(plane_field "$_i" shared.enabled)
			case "$_se" in
			true) SHARED_ENABLED="true" ;;
			false) SHARED_ENABLED="false" ;;
			'') SHARED_ENABLED="absent" ;;
			*) SHARED_ENABLED="invalid:$_se" ;;
			esac
			if [ "$SHARED_ENABLED" = true ]; then
				_sp=$(plane_field "$_i" shared.data_plane)
				SHARED_PLANE=${_sp:-unset}
				_sifs=$(plane_field "$_i" 'shared.interface[*]')
				_sifs=$(printf '%s' "$_sifs" | tr '\n' ',' | sed 's/,$//')
				[ -n "$_sifs" ] || _sifs=-
				SHARED_IFACES=$_sifs
			fi
			return 0
		fi
		_i=$((_i + 1))
	done
	INBOUND_TYPE="other"
	return 0
}

if [ ! -f "$CONF" ]; then
	PLANE_STATE="no-config"
	MODE="config-missing"
elif ! plane_probe; then
	# Keep the inbound type for the gRPC branch, but no plane claim: without a
	# parser the only honest answer is unknown.
	PLANE_STATE="unknown"
	if grep -q '"type"[[:space:]]*:[[:space:]]*"ebpf"' "$CONF" 2>/dev/null; then
		INBOUND_TYPE="ebpf"
	else
		INBOUND_TYPE="other"
	fi
fi

case "$INBOUND_TYPE" in
ebpf)
	case "$SHARED_ENABLED" in
	true) MODE="ebpf local+shared" ;;
	absent | false) MODE="ebpf local" ;;
	*) MODE="ebpf plane-unknown" ;;
	esac
	;;
other)
	# No eBPF inbound: the planes do not exist, which is not the same answer
	# as "could not parse" and must not read as a plane claim.
	MODE="tun"
	LOCAL_PLANE="n/a"
	SHARED_ENABLED="n/a"
	SHARED_PLANE="n/a"
	SHARED_IFACES="n/a"
	;;
*) MODE="config-missing" ;;
esac

TUN_STATE="absent"
[ -e /sys/class/net/sbtun0 ] && TUN_STATE="present"

# ------------------------------------------------------------ identity/meta
capture required core-version "$BIN" version

if [ -f "$CONF" ]; then
	_md5=$(md5sum "$CONF" 2>/dev/null | awk '{print $1}')
	_bytes=$(wc -c <"$CONF" 2>/dev/null | tr -d ' ')
	_mtime=$(stat -c '%Y' "$CONF" 2>/dev/null)
	[ -n "$_mtime" ] || _mtime="?"
	_mtime_utc=$(date -u -d "@$_mtime" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || _mtime_utc="?"
	{
		printf 'config_path=%s\n' "$CONF"
		printf 'config_md5=%s\n' "${_md5:-unreadable}"
		printf 'config_bytes=%s\n' "${_bytes:-?}"
		printf 'config_mtime_epoch=%s\n' "$_mtime"
		printf 'config_mtime_utc=%s\n' "$_mtime_utc"
		printf 'note=config content, providers and secrets are never dumped\n'
	} >"$OUT/config-md5.txt"
	if [ -z "$_md5" ]; then
		printf 'rc=unreadable\n' >"$OUT/config-md5.rc"
		note_fail required config-md5 "config unreadable: $CONF"
	else
		printf 'rc=0\n' >"$OUT/config-md5.rc"
	fi
else
	mark_absent config-md5 "config not found: $CONF"
fi

{
	printf 'utc=%s\n' "$UTC"
	printf 'utc_compact=%s\n' "$UTC_COMPACT"
	printf 'epoch=%s\n' "$EPOCH"
	printf 'label=%s\n' "${LABEL:-none}"
	printf 'host=%s\n' "$(hostname 2>/dev/null || echo '?')"
	printf 'kernel=%s\n' "$(uname -r 2>/dev/null || echo '?')"
	printf 'arch=%s\n' "$(uname -m 2>/dev/null || echo '?')"
	printf 'uptime=%s\n' "$(awk '{printf "%.0f", $1}' /proc/uptime 2>/dev/null || echo '?')"
	printf 'base=%s\n' "$BASE"
	printf 'binary=%s\n' "$BIN"
	printf 'binary_executable=%s\n' "$([ -x "$BIN" ] && echo yes || echo no)"
	printf 'core_pid=%s\n' "${PID:-none}"
	printf 'core_pid_state=%s\n' "${PID_STATE}${PID_LIVE:+/$PID_LIVE}"
	printf 'mode=%s\n' "$MODE"
	printf 'plane_parse=%s\n' "$PLANE_STATE"
	printf 'local_data_plane=%s\n' "$LOCAL_PLANE"
	printf 'shared_enabled=%s\n' "$SHARED_ENABLED"
	printf 'shared_data_plane=%s\n' "$SHARED_PLANE"
	printf 'shared_interface=%s\n' "$SHARED_IFACES"
	printf 'sbtun0=%s\n' "$TUN_STATE"
	printf 'api_url=%s\n' "$API_URL"
	printf 'api_secret=%s\n' "$([ -n "$SECRET" ] && echo set || echo empty)"
	printf 'lan_iface=%s\n' "$LAN_IFACE"
	printf 'deep=%s\n' "$DEEP"
	printf 'cmd_timeout=%s\n' "$CMD_TIMEOUT"
} >"$OUT/meta.txt"

# ------------------------------------------------------------- netlink state
capture required proc-net-dev cat /proc/net/dev
capture required links ip -d link show
capture required link-summary ip -o link show
capture optional ip-addr ip -o addr show
capture optional ip-rule ip -o rule show
capture optional ip-rule6 ip -o -6 rule show
capture optional ip-route ip -o route show
capture optional ip-route6 ip -o -6 route show

dump_netns() {
	printf 'self_netns=%s\n' "$(readlink /proc/self/ns/net 2>/dev/null || echo '?')"
	printf 'self_netns_pid=%s\n' "$(readlink /proc/1/ns/net 2>/dev/null || echo '?')"
	printf 'ip_netns_list:\n'
	ip netns list 2>&1
	_nrc=$?
	printf 'ip_netns_rc=%s\n' "$_nrc"
	printf 'netns_files:\n'
	ls -1 /var/run/netns 2>/dev/null || echo '(none)'
	return "$_nrc"
}
capture optional netns dump_netns

# ------------------------------------------------------- tc on managed links
IFACES=""
add_iface() {
	case " $IFACES " in
	*" $1 "*) return 0 ;;
	esac
	IFACES="${IFACES:+$IFACES }$1"
}

add_iface "$LAN_IFACE"
for _n in $(sed -n 's/^[0-9][0-9]*: \([^:@ ]*\).*/\1/p' "$OUT/link-summary.txt" 2>/dev/null |
	awk '$0 ~ /^(veth|tf-|sbtun|tun)/ { print }' 2>/dev/null); do
	add_iface "$_n"
done
# Also catch veth links that carry no veth prefix.
for _n in $(ip -o link show type veth 2>/dev/null | sed -n 's/^[0-9][0-9]*: \([^:@ ]*\).*/\1/p'); do
	add_iface "$_n"
done

IFACE_COUNT=0
for _if in $IFACES; do
	IFACE_COUNT=$((IFACE_COUNT + 1))
	[ "$IFACE_COUNT" -gt "$MAX_IFACES" ] && break
	if ! ip -o link show dev "$_if" >/dev/null 2>&1; then
		mark_absent "tc-qdisc-$_if" "interface $_if not present"
		continue
	fi
	capture optional "tc-qdisc-$_if" tc -s -d qdisc show dev "$_if"
	capture optional "tc-filter-ingress-$_if" tc -s -d filter show dev "$_if" ingress
	capture optional "tc-filter-egress-$_if" tc -s -d filter show dev "$_if" egress
done
printf 'managed_ifaces=%s\n' "${IFACES:-none}" >"$OUT/tc-ifaces.txt"

# ------------------------------------------------------------------- nftables
if command -v nft >/dev/null 2>&1; then
	capture optional nft-ruleset nft -j list ruleset
	if nft list tables 2>/dev/null | grep -q 'inet tf_sb_ebpf_guard'; then
		capture optional nft-ebpf-guard nft list table inet tf_sb_ebpf_guard
	else
		mark_absent nft-ebpf-guard "table inet tf_sb_ebpf_guard not present"
	fi
else
	mark_absent nft-ruleset "nft not installed"
fi

# ------------------------------------------------------- eBPF runtime (gRPC)
printf 'sing-box api ebpf --url %s%s\n' "$API_URL" \
	"$([ "$DEEP" -eq 1 ] && echo ' --deep')$([ -n "$SECRET" ] && echo ' --secret <redacted>')" \
	>"$OUT/ebpf-api.cmd"

case "$MODE" in
ebpf*)
	if [ ! -x "$BIN" ]; then
		mark_absent ebpf-api "binary not executable: $BIN"
	elif [ "$DEEP" -eq 1 ]; then
		if [ -n "$SECRET" ]; then
			capture optional ebpf-api "$BIN" api ebpf --url "$API_URL" --secret "$SECRET" --deep
		else
			capture optional ebpf-api "$BIN" api ebpf --url "$API_URL" --deep
		fi
	else
		if [ -n "$SECRET" ]; then
			capture optional ebpf-api "$BIN" api ebpf --url "$API_URL" --secret "$SECRET"
		else
			capture optional ebpf-api "$BIN" api ebpf --url "$API_URL"
		fi
	fi
	;;
tun)
	mark_absent ebpf-api "inbound is tun; no eBPF runtime to report (expected)"
	;;
*)
	mark_absent ebpf-api "cannot determine inbound mode from $CONF"
	;;
esac

# ----------------------------------------------------------------- status/EOF
_api_state="absent"
if [ -f "$OUT/ebpf-api.rc" ]; then
	if grep -q '^rc=0' "$OUT/ebpf-api.rc" 2>/dev/null; then
		_api_state="ok"
	elif grep -q 'absent' "$OUT/ebpf-api.rc" 2>/dev/null; then
		_api_state="absent"
	else
		_api_state="error"
	fi
fi
_tc_ok=0
_tc_fail=0
_tc_absent=0
for _rcf in "$OUT"/tc-qdisc-*.rc; do
	[ -f "$_rcf" ] || continue
	if grep -q '^rc=0' "$_rcf" 2>/dev/null; then
		_tc_ok=$((_tc_ok + 1))
	elif grep -q '^rc=absent' "$_rcf" 2>/dev/null; then
		_tc_absent=$((_tc_absent + 1))
	else
		_tc_fail=$((_tc_fail + 1))
	fi
done
if [ "$_tc_fail" -gt 0 ]; then
	_tc_state="partial"
elif [ "$_tc_ok" -gt 0 ]; then
	_tc_state="ok"
elif [ "$_tc_absent" -gt 0 ]; then
	_tc_state="absent"
else
	_tc_state="none"
fi

if [ "$FAILREQ" -eq 1 ]; then
	_status="partial"
else
	_status="ok"
fi

{
	printf 'SNAPSHOT_STATUS=%s\n' "$_status"
	printf 'snapshot=%s\n' "$OUT"
	printf 'utc=%s\n' "$UTC"
	printf 'label=%s\n' "${LABEL:-none}"
	printf 'mode=%s\n' "$MODE"
	printf 'plane_parse=%s\n' "$PLANE_STATE"
	printf 'local_data_plane=%s\n' "$LOCAL_PLANE"
	printf 'shared_enabled=%s\n' "$SHARED_ENABLED"
	printf 'shared_data_plane=%s\n' "$SHARED_PLANE"
	printf 'sbtun0=%s\n' "$TUN_STATE"
	printf 'ebpf_api=%s\n' "$_api_state"
	printf 'tc=%s\n' "$_tc_state"
	printf 'failures=%s\n' "$FAILN"
	printf 'absent=%s\n' "$ABSENTN"
	printf 'required_failures=%s\n' "$FAILREQ"
} >"$OUT/status.txt"

echo "snapshot: $OUT"
sed 's/^/  /' "$OUT/status.txt"
if [ "$FAILN" -gt 0 ]; then
	echo "  failures:"
	sed -n '1,20p' "$OUT/failures.txt" | sed 's/^/    /'
fi
if [ "$ABSENTN" -gt 0 ]; then
	echo "  known absent (not failures):"
	sed -n '1,20p' "$OUT/absent.txt" | sed 's/^/    /'
fi

[ "$FAILREQ" -eq 0 ] && exit 0
exit 1
