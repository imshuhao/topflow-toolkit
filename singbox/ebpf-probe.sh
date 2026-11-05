#!/bin/sh
# eBPF inbound readiness probe for ZTE TopFlow B20 (read-only).
#
# Runs the fork's built-in, non-mounting kernel capability probe for the eBPF
# inbound paths we plan to use, and collects the environment needed to interpret
# the result.  NOTHING is mounted, loaded, rewritten or restarted:
#   * `sing-box tools ebpf status` creates and immediately closes temporary BPF
#     objects; it does not attach programs, touch cgroup/qdisc/route/sysctl or
#     alter traffic;
#   * iptables is only inspected with -S.
#
# Both shared TC data planes are probed independently so a socket_assign result
# can never be inferred from packet_rewrite (or the reverse):
#   local cgroup, local socket_assign, shared packet_rewrite, shared socket_assign
# --shared-data-plane only marks which one the deployed config uses; it does not
# skip or shortcut the other probe.
#
# Usage (on device, as root):
#   sh /data/sing-box/ebpf-probe.sh                 # all four capability probes
#   sh /data/sing-box/ebpf-probe.sh --local-only    # skip br-lan/shared probes
#   sh /data/sing-box/ebpf-probe.sh --shared-data-plane socket_assign
#   SINGBOX_BASE=/data/sing-box EBPF_SHARED_IFACE=br-lan sh ebpf-probe.sh
#
# A requested interface that does not exist is reported as FAIL/UNKNOWN: the
# shared probes are not executed against a random link.
#
# Exit codes: 0 = every requested probe passed; 1 = at least one FAIL/UNKNOWN;
#             2 = build has no eBPF inbound (or binary missing).
#
# Output: $SINGBOX_BASE/diagnostics/ebpf-probe-<utc>/*  (+ summary on stdout)

set -u

BASE="${SINGBOX_BASE:-/data/sing-box}"
BIN="$BASE/sing-box"
IFACE="${EBPF_SHARED_IFACE:-br-lan}"
PLANE="${EBPF_SHARED_DATA_PLANE:-packet_rewrite}"
PROBE_TIMEOUT="${EBPF_PROBE_TIMEOUT:-10}"
LOCAL_ONLY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --local-only)
            LOCAL_ONLY=1
            ;;
        --shared-data-plane)
            [ "$#" -ge 2 ] || { echo "missing value for --shared-data-plane" >&2; exit 2; }
            PLANE="$2"
            shift
            ;;
        --iface)
            [ "$#" -ge 2 ] || { echo "missing value for --iface" >&2; exit 2; }
            IFACE="$2"
            shift
            ;;
        -h|--help)
            sed -n '2,31p' "$0"
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
    shift
done
case "$PLANE" in
    packet_rewrite|socket_assign) ;;
    *) echo "invalid --shared-data-plane: $PLANE (packet_rewrite|socket_assign)" >&2; exit 2 ;;
esac
case "$PROBE_TIMEOUT" in
    '' | *[!0-9]*) echo "EBPF_PROBE_TIMEOUT must be a positive integer" >&2; exit 2 ;;
esac
[ "$PROBE_TIMEOUT" -gt 0 ] || { echo "EBPF_PROBE_TIMEOUT must be > 0" >&2; exit 2; }

TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$BASE/diagnostics/ebpf-probe-$TS"
mkdir -p "$OUT" || { echo "cannot create $OUT" >&2; exit 2; }
FAILED=0
MISSING=0

say() { echo "$@"; }

save() { # save <file> <command...>
    _name="$1"
    shift
    "$@" >"$OUT/$_name.txt" 2>&1
    return $?
}

say "== eBPF probe $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
say "binary : $BIN"
say "output : $OUT"
say ""

if [ ! -x "$BIN" ]; then
    say "FATAL: $BIN not executable"
    exit 2
fi

# ---------------------------------------------------------------- 0. identity
save version "$BIN" version
say "-- version --"
sed -n '1,6p' "$OUT/version.txt"
say ""

# ------------------------------------------------------------ 1. environment
save uname uname -a
save proc_version cat /proc/version
save openwrt_release cat /etc/openwrt_release
save meminfo sh -c 'head -3 /proc/meminfo'
save cgroup_mounts sh -c 'mount | grep -E "cgroup|bpf" || echo "(no cgroup/bpf mount)"'
save cgroup_self cat /proc/self/cgroup
save cgroup_tree sh -c 'ls /sys/fs/cgroup 2>&1'
save bpffs sh -c 'ls -l /sys/fs/bpf 2>&1'
save links sh -c 'ip -details link show 2>&1'
save link_names sh -c 'ip -o link show 2>/dev/null | sed -n "s/^[0-9][0-9]*: //p" | cut -d@ -f1 | cut -d: -f1'
save bridges sh -c 'ip -o link show type bridge 2>&1'
save qdisc sh -c 'tc qdisc show 2>&1'
save zte_chains sh -c 'iptables -S 2>/dev/null | grep -Ei "zte|gms|fw_IN|fw_OUT" || echo "(no zte/gms/fw_* chains)"'
save modules sh -c 'lsmod 2>/dev/null | grep -E "bpf|sched|veth|cls" || echo "(no bpf/sched/veth modules loaded)"'

IFACE_PRESENT=0
if grep -Fxq "$IFACE" "$OUT/link_names.txt" 2>/dev/null; then
    IFACE_PRESENT=1
fi

say "-- kernel --"
sed -n '1p' "$OUT/uname.txt"
say "-- cgroup --"
sed -n '1,4p' "$OUT/cgroup_mounts.txt"
say "-- bridge --"
grep -E "^[0-9]+: (br-lan|wlan)" "$OUT/links.txt" 2>/dev/null | sed -n '1,6p'
say "-- zte/gms chains --"
sed -n '1,6p' "$OUT/zte_chains.txt"
say ""

# ------------------------------------------------------------- 2. capability
# Bounded execution: busybox has no `timeout`, so a watchdog subshell enforces
# the 10 s cap (EBPF_PROBE_TIMEOUT) and the probe can never wedge on a hung
# netlink/BPF syscall.
run_bounded() { # run_bounded <stdout> <stderr> <cmd...>
    _out="$1"
    _err="$2"
    shift 2
    "$@" >"$_out" 2>"$_err" &
    _bpid=$!
    (sleep "$PROBE_TIMEOUT"; kill -TERM "$_bpid" 2>/dev/null; sleep 1; kill -KILL "$_bpid" 2>/dev/null) \
        >/dev/null 2>&1 &
    _bwd=$!
    wait "$_bpid"
    _brc=$?
    kill "$_bwd" 2>/dev/null
    wait "$_bwd" 2>/dev/null
    return "$_brc"
}

probe() { # probe <label> <outfile> <args...>
    _label="$1"
    _file="$2"
    shift 2
    say "-- probe: $_label --"
    run_bounded "$OUT/$_file.json" "$OUT/$_file.err" \
        "$BIN" tools ebpf status "$@" --json
    _rc=$?
    if [ "$_rc" -eq 143 ] || [ "$_rc" -eq 137 ]; then
        echo "rc=timeout timeout=$PROBE_TIMEOUT" >"$OUT/$_file.rc"
        FAILED=1
        say "   FAIL/UNKNOWN: timed out after ${PROBE_TIMEOUT}s"
        sed -n '1,5p' "$OUT/$_file.err" 2>/dev/null | sed 's/^/   /'
        say ""
        return 0
    fi
    echo "rc=$_rc" >"$OUT/$_file.rc"
    if [ "$_rc" -ne 0 ]; then
        if grep -qiE 'not included in this build|unknown command|unknown flag' \
            "$OUT/$_file.err" "$OUT/$_file.json" 2>/dev/null; then
            MISSING=1
            echo "rc=missing" >"$OUT/$_file.rc"
            say "   NOT AVAILABLE IN THIS BUILD:"
            sed -n '1,3p' "$OUT/$_file.err" | sed 's/^/   /'
        else
            FAILED=1
            say "   FAIL/UNKNOWN (rc=$_rc):"
            sed -n '1,8p' "$OUT/$_file.err" 2>/dev/null | sed 's/^/   /'
            sed -n '1,20p' "$OUT/$_file.json" 2>/dev/null | sed 's/^/   /'
        fi
    else
        say "   OK"
        if command -v jq >/dev/null 2>&1; then
            jq -r '.. | objects | select(has("status")) | "   \(.name // .id // "?")=\(.status)"' \
                "$OUT/$_file.json" 2>/dev/null | sed -n '1,12p'
        fi
    fi
    say ""
}

# Requested interface missing: do not run shared probes against a fallback link,
# and do not let the previous "NOTE" turn into a silently-passing result.
probe_needs_iface() { # probe_needs_iface <label> <outfile>
    _label="$1"
    _file="$2"
    say "-- probe: $_label --"
    say "   FAIL/UNKNOWN: requested interface '$IFACE' is not present"
    printf '[UNKNOWN] requested interface %s is not present\n' "$IFACE" >"$OUT/$_file.json"
    printf 'requested interface %s is not present; probe not executed\n' "$IFACE" >"$OUT/$_file.err"
    echo "rc=unknown" >"$OUT/$_file.rc"
    FAILED=1
    say ""
}

status_of() { # status_of <outfile-basename> -> PASS|FAIL|UNKNOWN|MISSING|NOTRUN
    _rc=$(sed -n '1p' "$OUT/$1.rc" 2>/dev/null)
    case "$_rc" in
    rc=0) echo PASS ;;
    rc=missing) echo MISSING ;;
    rc=unknown) echo UNKNOWN ;;
    rc=*) echo FAIL ;;
    *) echo NOTRUN ;;
    esac
}

probe "local cgroup (device traffic)" "local-cgroup" --mode local
probe "local socket_assign" "local-socket-assign" --local-data-plane socket_assign --network tcp,udp
if [ "$LOCAL_ONLY" -eq 0 ]; then
    if [ "$IFACE_PRESENT" -ne 1 ]; then
        probe_needs_iface "shared packet_rewrite ($IFACE)" "shared-packet-rewrite"
        probe_needs_iface "shared socket_assign ($IFACE)" "shared-socket-assign"
        say "NOTE: requested interface $IFACE not found.  Shared capability stays UNKNOWN."
        say "      pass --iface <bridge> (or EBPF_SHARED_IFACE=<bridge>) and re-run; bridges seen:"
        sed -n '1,10p' "$OUT/bridges.txt"
        say ""
    else
        probe "shared packet_rewrite ($IFACE)" "shared-packet-rewrite" \
            --shared-data-plane packet_rewrite --interface "$IFACE" --network tcp,udp
        probe "shared socket_assign ($IFACE)" "shared-socket-assign" \
            --shared-data-plane socket_assign --interface "$IFACE" --network tcp,udp
    fi
fi

# ------------------------------------------------------------------ 3. verdict
DEPLOYED="shared-packet-rewrite"
[ "$PLANE" = "socket_assign" ] && DEPLOYED="shared-socket-assign"

say "== summary =="
say "local cgroup        : $(status_of local-cgroup)"
say "local socket_assign : $(status_of local-socket-assign)"
if [ "$LOCAL_ONLY" -eq 0 ]; then
    say "shared packet_rewrite: $(status_of shared-packet-rewrite)"
    say "shared socket_assign : $(status_of shared-socket-assign)"
    say "deployed shared plane: $PLANE ($(status_of "$DEPLOYED"))"
fi
say "artifacts: $OUT"

if [ "$MISSING" -eq 1 ]; then
    say "RESULT: this binary has no eBPF inbound (with_ebpf missing)."
    say "        Device should run 1.14.4-reF1nd; verify /data/sing-box/sing-box."
    exit 2
fi
if [ "$FAILED" -eq 0 ]; then
    say "RESULT: all requested probes passed."
    say "        A real start can still fail on mount permission / qdisc conflict;"
    say "        see docs/TELEGRAM-E58695-SINGBOX-DIGEST-2026-10-30.md §3.7."
    exit 0
fi

say "RESULT: at least one probe reported FAIL/UNKNOWN.  Do NOT switch the"
say "        production config yet; attach $OUT/*.json when reporting upstream."
if [ "$LOCAL_ONLY" -eq 0 ] && [ "$(status_of "$DEPLOYED")" != PASS ]; then
    say "        Deployed shared data plane '$PLANE' is not PASS: keep TUN as the"
    say "        production data plane and record $(status_of "$DEPLOYED") for it."
fi
exit 1
