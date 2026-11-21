#!/bin/sh
# Run one bounded eBPF trial, then always restore the verified TUN baseline.
# Usage: sh ebpf-trial.sh /data/sing-box/config.ebpf-allproxy.json [seconds]
# The foreground process owns rollback; HUP/INT/TERM also restore TUN.
#
# The trial is a plane A/B harness, so it refuses to grade a round whose plane
# it cannot confirm: `api ebpf` must report the data planes it attached and
# they must match the candidate.  An unconfirmed round prints TRIAL_INVALID and
# exits non-zero even when traffic looked fine.  The watchdog is disabled for
# the whole window (SINGBOX_NO_WATCHDOG=1) so a failed candidate cannot be
# restarted behind the trial's back.
set -u
umask 077
BASE="${SINGBOX_BASE:-/data/sing-box}"
CONF="$BASE/config.json"
STATE="$BASE/state"
BIN="$BASE/sing-box"
SERVICE="$BASE/sing-box.sh"
BACKUP="$BASE/backup-config.sh"
VERIFY="$BASE/verify-ebpf.sh"
SNAPSHOT="$BASE/ebpf-snapshot.sh"
API_URL="${SINGBOX_SERVICE_API:-http://127.0.0.1:8088}"
LOCK="$STATE/ebpf-trial.lock"
ACTIVE="$STATE/ebpf-trial.active"
# Inbound probe window shared with sing-box.sh / ebpf-snapshot.sh.
MAX_INBOUNDS=8

# ---------------------------------------------------------------------------
# Internal mode: independent restorer.  Launched detached (start-stop-daemon, or
# a plain background child when that is unavailable) because a foreground
# process only restores TUN through its EXIT trap -- an SSH channel torn down or
# a SIGKILLed parent leaves the candidate live with the marker behind (measured
# on 2026-10-31 with the "| tee" topology).  The watchdog polls the parent, and
# restores only while $ACTIVE still names that parent, so a newer trial is never
# reverted by an older watchdog.
#   --watch <parent_pid> <restore> <active> <out> <backup> <seconds>
# ---------------------------------------------------------------------------
if [ "${1:-}" = --watch ]; then
    _wpid="${2:-}"
    _wrestore="${3:-}"
    _wactive="${4:-}"
    _wout="${5:-}"
    _wbackup="${6:-}"
    _wsecs="${7:-90}"
    case "$_wpid" in ''|*[!0-9]*) exit 2 ;; esac
    _we=0
    while [ "$_we" -lt "$((_wsecs + 90))" ]; do
        sleep 15
        _we=$((_we + 15))
        kill -0 "$_wpid" 2>/dev/null || break
    done
    [ -n "$_wrestore" ] && [ -f "$_wrestore" ] || exit 0
    if [ -f "$_wactive" ] && grep -q "^pid=$_wpid$" "$_wactive" 2>/dev/null; then
        kill -TERM "$_wpid" 2>/dev/null || true
        _ww=0
        while [ "$_ww" -lt 60 ] && [ -f "$_wactive" ]; do
            sleep 5
            _ww=$((_ww + 5))
        done
        if [ -f "$_wactive" ] && grep -q "^pid=$_wpid$" "$_wactive" 2>/dev/null; then
            echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) WATCHDOG_RESTORE pid=$_wpid" \
                >> "$_wout/deadline-restore.log"
            if sh "$_wbackup" restore "$_wrestore" --force >> "$_wout/deadline-restore.log" 2>&1; then
                echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) WATCHDOG_TUN_RESTORED" \
                    >> "$_wout/deadline-restore.log"
                _wstate=$(dirname "$_wactive")
                # The parent is gone: its EXIT trap may never have reaped these,
                # and a stale lock dir/pidfile would misreport the next trial as
                # still locked.  Only $LOCK/pid and $LOCK are removed -- the
                # flock target (ebpf-trial.lockfile) is kernel-owned and stays.
                rm -f "$_wstate/ebpf-trial.lock/pid" 2>/dev/null
                rmdir "$_wstate/ebpf-trial.lock" 2>/dev/null
                rm -f "$_wstate/ebpf-trial-watchdog.pid" 2>/dev/null
                rm -f "$_wactive"
            else
                echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) WATCHDOG_RESTORE_FAILED baseline=$_wrestore" \
                    >> "$_wout/deadline-restore.log"
            fi
        fi
    fi
    exit 0
fi

case "${1:-}" in
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    '') echo "usage: $0 <candidate.json> [seconds: 15..300]" >&2; exit 2 ;;
esac
CANDIDATE="$1"
TRIAL_SECONDS="${2:-90}"
case "$TRIAL_SECONDS" in ''|*[!0-9]*) echo "seconds must be 15..300" >&2; exit 2 ;; esac
[ "$TRIAL_SECONDS" -ge 15 ] && [ "$TRIAL_SECONDS" -le 300 ] || exit 2
[ "$#" -le 2 ] || exit 2
[ -f "$CANDIDATE" ] || { echo "candidate missing" >&2; exit 2; }
for helper in "$BIN" "$SERVICE" "$BACKUP" "$VERIFY" "$SNAPSHOT"; do
    [ -x "$helper" ] || { echo "missing $helper" >&2; exit 2; }
done
command -v jsonfilter >/dev/null 2>&1 || { echo "jsonfilter missing" >&2; exit 2; }
# An experiment must begin from TUN, with a separately stored immutable copy.
[ -n "$(jsonfilter -i "$CONF" -e '@.inbounds[@.type="tun"].tag' 2>/dev/null)" ] || {
    echo "trial requires a running TUN configuration" >&2; exit 1;
}
[ "$(jsonfilter -i "$CANDIDATE" -e '@.inbounds[@.type="ebpf"].shared.enabled' 2>/dev/null)" = true ] || {
    echo "candidate must enable shared eBPF" >&2; exit 1;
}

# One field of the eBPF inbound in <file>; empty output = field absent, rc 1 =
# no eBPF inbound, rc 2 = cannot enumerate (device jsonfilter exits 1 both for an
# out-of-range index and for a missing optional field).
plane_of() { # plane_of <file> <field>
    _file="$1"
    command -v jsonfilter >/dev/null 2>&1 || return 2
    _types=$(jsonfilter -i "$_file" -e '@.inbounds[*].type' 2>/dev/null) || return 2
    [ -n "$_types" ] || return 2
    _cnt=$(printf '%s\n' "$_types" | grep -c .)
    [ "$_cnt" -le "$MAX_INBOUNDS" ] || return 2
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
    jsonfilter -i "$_file" -e "@.inbounds[$_idx].$2" 2>/dev/null | tr -d '"'
}

CAND_LOCAL=$(plane_of "$CANDIDATE" local.data_plane) || CAND_LOCAL=unknown
CAND_SHARED=$(plane_of "$CANDIDATE" shared.data_plane) || CAND_SHARED=unknown
[ -n "$CAND_LOCAL" ] || CAND_LOCAL=unset
[ -n "$CAND_SHARED" ] || CAND_SHARED=unset

sh "$VERIFY" --no-load || { echo "TUN baseline verification failed" >&2; exit 1; }
"$BIN" check -c "$CANDIDATE" || exit 1
SINGBOX_CONFIG="$CANDIDATE" sh "$VERIFY" --static || exit 1
mkdir -p "$STATE" || exit 1
command -v flock >/dev/null 2>&1 || { echo "flock missing" >&2; exit 1; }
exec 9>"$STATE/ebpf-trial.lockfile"
flock -n 9 || { echo "another trial holds the process lock" >&2; exit 1; }
# Kernel lock releases even after a crash/reboot; the directory is just status.
if [ -d "$LOCK" ]; then
    rm -f "$LOCK/pid"
    rmdir "$LOCK" || { echo "unexpected files in $LOCK" >&2; exit 1; }
fi
mkdir "$LOCK" || exit 1
echo "$$" > "$LOCK/pid"
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$BASE/diagnostics/ebpf-trial-$TS-$$"
mkdir -p "$OUT" || { rm -f "$LOCK/pid"; rmdir "$LOCK"; exit 1; }
RESTORE="$OUT/tun-baseline.json"
cp -p "$CONF" "$RESTORE" || { rm -f "$LOCK/pid"; rmdir "$LOCK"; exit 1; }
md5sum "$RESTORE" > "$RESTORE.md5" || { rm -f "$LOCK/pid"; rmdir "$LOCK"; exit 1; }

# Trial-active marker: readable status for anyone (or any script) that finds
# the box mid-experiment.  Removed by the same trap that restores TUN.
printf 'pid=%s\nstarted=%s\ncandidate=%s\nlocal_data_plane=%s\nshared_data_plane=%s\nbaseline=%s\nwatchdog=off\n' \
    "$$" "$TS" "$(basename "$CANDIDATE")" "$CAND_LOCAL" "$CAND_SHARED" "$RESTORE" > "$ACTIVE" 2>/dev/null || true

ARMED=0
INVALID=0
CHILD=
DEADLINE=
finish() {
    result=$?
    trap - EXIT HUP INT TERM
    if [ -n "$CHILD" ]; then kill "$CHILD" 2>/dev/null || true; fi
    if [ -n "$DEADLINE" ]; then kill "$DEADLINE" 2>/dev/null || true; fi
    rm -f "$STATE/ebpf-trial-watchdog.pid"
    if [ "$ARMED" = 1 ]; then
        echo "RESTORING_TUN $RESTORE"
        # The exact file, not a mutable phase alias, is the trial baseline.
        if sh "$BACKUP" restore "$RESTORE" --force 9>&-; then
            echo "TUN_RESTORED $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            sh "$SNAPSHOT" --output "$OUT/restored" 9>&- || true
        else
            echo "TUN_RESTORE_FAILED; baseline=$RESTORE" >&2
            result=1
        fi
    fi
    [ "$INVALID" = 1 ] && result=1
    rm -f "$CONF.trial.$$" "$LOCK/pid" "$ACTIVE"
    rmdir "$LOCK" 2>/dev/null || true
    exit "$result"
}
trap finish EXIT
trap 'exit 130' HUP INT TERM
sh "$BACKUP" save tun 9>&- || exit 1
sh "$SNAPSHOT" --output "$OUT/before" 9>&- || true
cp -p "$CANDIDATE" "$CONF.trial.$$" || exit 1
ARMED=1
# Detached restorer/deadline.  start-stop-daemon puts it in its own session, so
# a process-group teardown of this shell cannot take it down with it; without
# ssd a background child is the fallback (SIGHUP-only protection).
WATCHDOG_PIDFILE="$STATE/ebpf-trial-watchdog.pid"
rm -f "$WATCHDOG_PIDFILE"
if [ -x /sbin/start-stop-daemon ]; then
    # 9>&-: fd 9 is the flock target.  A restorer that inherits it hands the
    # kernel lock to every daemon it restarts, so the next trial reports
    # "another trial holds the process lock" long after this one ended.
    /sbin/start-stop-daemon -S -b -m -p "$WATCHDOG_PIDFILE" -x /bin/sh -- \
        "$0" --watch "$$" "$RESTORE" "$ACTIVE" "$OUT" "$BACKUP" "$TRIAL_SECONDS" \
        >>"$OUT/watchdog-start.log" 2>&1 9>&-
    sleep 1
    DEADLINE=$(cat "$WATCHDOG_PIDFILE" 2>/dev/null) || DEADLINE=
else
    sh "$0" --watch "$$" "$RESTORE" "$ACTIVE" "$OUT" "$BACKUP" "$TRIAL_SECONDS" \
        >/dev/null 2>&1 9>&- &
    DEADLINE=$!
fi
mv -f "$CONF.trial.$$" "$CONF" || exit 1
# SINGBOX_NO_WATCHDOG=1: stop_core kills the watchdog and start_core must not
# bring it back (both branches honour it), otherwise the watchdog would restart
# a candidate after the trial decided to roll back.
SINGBOX_NO_WATCHDOG=1 sh "$SERVICE" restart 9>&- || exit 1
echo "TRIAL_READY seconds=$TRIAL_SECONDS artifacts=$OUT local_data_plane=$CAND_LOCAL shared_data_plane=$CAND_SHARED"
sleep 3 9>&-

# ------------------------------------------------------- plane confirmation
# What the core reports it attached, versus what the candidate declared.  The
# gRPC report is attachment evidence; the capability probe is not.
sh "$SNAPSHOT" --output "$OUT/during" --label plane-confirm 9>&- >/dev/null 2>&1 || true
_att="$OUT/during/ebpf-api.txt"
_live_local=$(sed -n 's/^local_data_plane=//p' "$OUT/during/meta.txt" 2>/dev/null | sed -n '1p')
_att_local=$(jsonfilter -i "$_att" -e '@.inbounds[0].localDataPlane' 2>/dev/null | tr -d '"')
_att_shared=$(jsonfilter -i "$_att" -e '@.inbounds[0].sharedDataPlane' 2>/dev/null | tr -d '"')
_att_en=$(jsonfilter -i "$_att" -e '@.inbounds[0].sharedEnabled' 2>/dev/null | tr -d '"')
_att_state=$(jsonfilter -i "$_att" -e '@.inbounds[0].state' 2>/dev/null | tr -d '"')
_intf=$(jsonfilter -i "$_att" -e '@.inbounds[0].tcDeliveryInterface' 2>/dev/null | tr -d '"')
_sweep=$(jsonfilter -i "$_att" -e '@.inbounds[0].tcAssignmentSweepEntries' 2>/dev/null | tr -d '"')
_reason=
[ -n "$_att_local" ] || _reason="no attachment report ($_att)"
if [ -z "$_reason" ] && [ "${_live_local:-unknown}" != "$CAND_LOCAL" ]; then
    _reason="config local plane ${_live_local:-unknown} != candidate $CAND_LOCAL"
fi
if [ -z "$_reason" ] && [ "$_att_local" != "$CAND_LOCAL" ]; then
    _reason="attached local plane $_att_local != candidate $CAND_LOCAL"
fi
if [ -z "$_reason" ] && [ "$_att_en" != true ]; then
    _reason="shared hook not enabled in the attachment report (sharedEnabled=${_att_en:-?})"
fi
if [ -z "$_reason" ] && [ "$_att_shared" != "$CAND_SHARED" ]; then
    _reason="attached shared plane ${_att_shared:-?} != candidate $CAND_SHARED"
fi
{
    printf 'candidate_local=%s\n' "$CAND_LOCAL"
    printf 'candidate_shared=%s\n' "$CAND_SHARED"
    printf 'config_local=%s\n' "${_live_local:-unknown}"
    printf 'attached_local=%s\n' "${_att_local:-unknown}"
    printf 'attached_shared=%s\n' "${_att_shared:-unknown}"
    printf 'attached_shared_enabled=%s\n' "${_att_en:-unknown}"
    printf 'attached_state=%s\n' "${_att_state:-unknown}"
    printf 'tc_delivery_interface=%s\n' "${_intf:-unknown}"
    printf 'assignment_sweep_entries=%s\n' "${_sweep:-unknown}"
    printf 'match=%s\n' "$([ -z "$_reason" ] && echo yes || echo no)"
    printf 'reason=%s\n' "${_reason:-none}"
} > "$OUT/plane-confirm.txt"
if [ -z "$_reason" ]; then
    echo "TRIAL_PLANE local=$_att_local shared=$_att_shared state=${_att_state:-?} confirmed"
else
    INVALID=1
    echo "TRIAL_INVALID plane not confirmed: $_reason" >&2
fi

# ---------------------------------------------------------- hold the window
# Independent sleep so the shell handles signals immediately while waiting;
# the confirmation above already consumed part of the window.
_rest=$((TRIAL_SECONDS - 9))
[ "$_rest" -ge 1 ] || _rest=1
sleep "$_rest" 9>&- &
CHILD=$!
wait "$CHILD" || exit 1
CHILD=
sh "$SNAPSHOT" --output "$OUT/after" 9>&- || true
exit 0
