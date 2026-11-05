#!/bin/sh
# Install (or remove) the weak-network black box recorder on the device.
# Run this *on the device* (push it first), e.g.:
#   adb push weaknet/weaknet-watch.sh  /data/local/weaknet/weaknet-watch.sh
#   adb push weaknet/weaknet-report.sh /data/local/weaknet/weaknet-report.sh
#   adb push weaknet/install-weaknet.sh /tmp/install-weaknet.sh
#   adb shell 'sh /tmp/install-weaknet.sh'
#
#   install-weaknet.sh              # install hook + (re)start recorder
#   install-weaknet.sh --uninstall  # stop recorder + remove hook (logs kept)
#
# The recorder is a plain background loop; rc.local starts it on every boot so
# the device keeps logging while it is at the weak-network site.

set -eu
BASE=${BASE:-/data/local/weaknet}
RC_LOCAL=${RC_LOCAL:-/etc/rc.local}
BEGIN='# >>> TopFlow weaknet recorder >>>'
END='# <<< TopFlow weaknet recorder <<<'
INTERVAL=${INTERVAL:-30}

kill_all_recorders() {
	# pidfile alone misses orphans (busybox nohup twin / stale starts)
	ps | grep weaknet-watch | grep -v grep | while read -r _pid _rest; do
		kill -9 "$_pid" 2>/dev/null || true
	done
	rm -f /tmp/weaknet-watch.pid
}

start_recorder() {
	kill_all_recorders
	sleep 1
	( nohup sh "$BASE/weaknet-watch.sh" "$INTERVAL" </dev/null >/dev/null 2>&1 & )
	sleep 1
	echo "recorder pid=$(cat /tmp/weaknet-watch.pid 2>/dev/null || echo '?')"
}

if [ "${1:-}" = "--uninstall" ]; then
	kill_all_recorders
	tmp=/tmp/rc.local.weaknet.$$
	awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$RC_LOCAL" >"$tmp"
	sh -n "$tmp" && cat "$tmp" >"$RC_LOCAL"
	rm -f "$tmp"
	echo "weaknet recorder removed from $RC_LOCAL (logs kept in $BASE)"
	exit 0
fi

chmod 0755 "$BASE/weaknet-watch.sh" "$BASE/weaknet-report.sh"
[ -f "$BASE/rc.local.bak-weaknet" ] || cp -p "$RC_LOCAL" "$BASE/rc.local.bak-weaknet"

tmp=/tmp/rc.local.weaknet.$$
awk -v b="$BEGIN" -v e="$END" -v interval="$INTERVAL" '
	$0==b { skip=1; next }
	$0==e { skip=0; next }
	skip { next }
	{
		if (!done && $0 == "exit 0") {
			print b
			print "if [ -x /data/local/weaknet/weaknet-watch.sh ]; then"
			print "    [ -f /tmp/weaknet-watch.pid ] && kill \"$(cat /tmp/weaknet-watch.pid)\" 2>/dev/null"
			print "    (nohup sh /data/local/weaknet/weaknet-watch.sh " interval " </dev/null >/dev/null 2>&1 &)"
			print "fi"
			print e
			print ""
			done=1
		}
		print
	}
	END {
		if (!done) {
			print ""
			print b
			print "if [ -x /data/local/weaknet/weaknet-watch.sh ]; then"
			print "    [ -f /tmp/weaknet-watch.pid ] && kill \"$(cat /tmp/weaknet-watch.pid)\" 2>/dev/null"
			print "    (nohup sh /data/local/weaknet/weaknet-watch.sh " interval " </dev/null >/dev/null 2>&1 &)"
			print "fi"
			print e
		}
	}
' "$RC_LOCAL" >"$tmp"
sh -n "$tmp"
cat "$tmp" >"$RC_LOCAL"
rm -f "$tmp"
chmod 0755 "$RC_LOCAL"

start_recorder
echo "installed: hook in $RC_LOCAL, logs in $BASE/<YYYYMMDD>.jsonl"
echo "report:   $BASE/weaknet-report.sh"
