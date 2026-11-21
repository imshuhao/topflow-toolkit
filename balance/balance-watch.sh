#!/bin/sh
# Periodic carrier balance / jump-point sampler for TopFlow MU5252.
# Writes /data/local/balance/status.json for the touchscreen page.
#
#   balance-watch.sh            # daemon loop (default interval 900s)
#   balance-watch.sh once       # single shot (INTERVAL from env or 900)
#   balance-watch.sh 600        # daemon with custom interval seconds
#   INTERVAL=600 balance-watch.sh once

set -eu
BASE=${BASE:-/data/local/balance}
BIN=${BIN:-$BASE/balance-query}
PIDFILE=/tmp/balance-watch.pid
LOG=$BASE/watch.log

# Default 15 minutes; allow env override for cron once runs.
INTERVAL=${INTERVAL:-900}
case "${1:-}" in
"" ) ;;
once) ;;
*[!0-9]*)
	echo "usage: $0 [once|seconds]" >&2
	exit 2
	;;
*)
	INTERVAL=$1
	;;
esac

log() {
	_ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')
	printf '%s %s\n' "$_ts" "$*" >>"$LOG" 2>/dev/null || true
	_sz=$(wc -c <"$LOG" 2>/dev/null || echo 0)
	if [ "$_sz" -gt 1048576 ]; then
		tail -c 262144 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
	fi
}

run_once() {
	if [ ! -x "$BIN" ]; then
		log "missing binary $BIN"
		return 1
	fi
	if [ ! -f "$BASE/accounts.json" ]; then
		log "missing $BASE/accounts.json"
		return 1
	fi
	# 把采样间隔传给查询器，写入 status.json 的下次查询时间
	BALANCE_INTERVAL_SEC=$INTERVAL
	export BALANCE_INTERVAL_SEC
	"$BIN" -dir "$BASE" -interval "$INTERVAL" >>"$LOG" 2>&1
	return $?
}

if [ "${1:-}" = "once" ]; then
	run_once
	exit $?
fi

# daemon
echo $$ >"$PIDFILE"
log "balance-watch start interval=${INTERVAL}s"
while :; do
	run_once || true
	sleep "$INTERVAL"
done
