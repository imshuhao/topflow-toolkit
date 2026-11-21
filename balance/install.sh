#!/bin/sh
# Install balance querier + cron/rc.local hook on the device.
# Push files first, then:
#   adb shell 'sh /data/local/balance/install.sh'
#   adb shell 'sh /data/local/balance/install.sh --uninstall'

set -eu
BASE=${BASE:-/data/local/balance}
RC_LOCAL=${RC_LOCAL:-/etc/rc.local}
BEGIN='# >>> TopFlow balance watch >>>'
END='# <<< TopFlow balance watch <<<'
INTERVAL=${INTERVAL:-900}
CRON_LINE="*/15 * * * * $BASE/balance-watch.sh once >/dev/null 2>&1"

kill_watch() {
	if [ -f /tmp/balance-watch.pid ]; then
		kill "$(cat /tmp/balance-watch.pid)" 2>/dev/null || true
		rm -f /tmp/balance-watch.pid
	fi
	ps | grep balance-watch | grep -v grep | while read -r _pid _rest; do
		kill -9 "$_pid" 2>/dev/null || true
	done
}

remove_rc_hook() {
	tmp=/tmp/rc.local.balance.$$
	awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$RC_LOCAL" >"$tmp"
	sh -n "$tmp" && cat "$tmp" >"$RC_LOCAL"
	rm -f "$tmp"
}

if [ "${1:-}" = "--uninstall" ]; then
	kill_watch
	remove_rc_hook
	# best-effort cron cleanup
	if command -v crontab >/dev/null 2>&1; then
		crontab -l 2>/dev/null | grep -v 'balance-watch.sh' | crontab - 2>/dev/null || true
	fi
	echo "balance watch removed (status/accounts kept in $BASE)"
	exit 0
fi

mkdir -p "$BASE"
chmod 0755 "$BASE/balance-watch.sh" "$BASE/install.sh" 2>/dev/null || true
chmod 0755 "$BASE/balance-query" 2>/dev/null || true
chmod 0600 "$BASE/accounts.json" 2>/dev/null || true

if [ ! -f "$BASE/accounts.json" ] && [ -f "$BASE/accounts.json.example" ]; then
	cp -p "$BASE/accounts.json.example" "$BASE/accounts.json"
	chmod 0600 "$BASE/accounts.json"
	echo "seeded accounts.json from example — fill credentials before use"
fi

[ -f "$BASE/rc.local.bak-balance" ] || cp -p "$RC_LOCAL" "$BASE/rc.local.bak-balance"

remove_rc_hook
tmp=/tmp/rc.local.balance.$$
awk -v b="$BEGIN" -v e="$END" -v interval="$INTERVAL" '
	$0==b { skip=1; next }
	$0==e { skip=0; next }
	skip { next }
	{
		if (!done && $0 == "exit 0") {
			print b
			print "if [ -x /data/local/balance/balance-watch.sh ]; then"
			print "    [ -f /tmp/balance-watch.pid ] && kill \"$(cat /tmp/balance-watch.pid)\" 2>/dev/null"
			print "    (nohup sh /data/local/balance/balance-watch.sh " interval " </dev/null >/dev/null 2>&1 &)"
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
			print "if [ -x /data/local/balance/balance-watch.sh ]; then"
			print "    [ -f /tmp/balance-watch.pid ] && kill \"$(cat /tmp/balance-watch.pid)\" 2>/dev/null"
			print "    (nohup sh /data/local/balance/balance-watch.sh " interval " </dev/null >/dev/null 2>&1 &)"
			print "fi"
			print e
		}
	}
' "$RC_LOCAL" >"$tmp"
sh -n "$tmp"
cat "$tmp" >"$RC_LOCAL"
rm -f "$tmp"
chmod 0755 "$RC_LOCAL"

# Prefer cron if available (lighter than a permanent sleep loop)
if command -v crontab >/dev/null 2>&1; then
	(crontab -l 2>/dev/null | grep -v 'balance-watch.sh'; echo "$CRON_LINE") | crontab - 2>/dev/null || true
fi

kill_watch
# one immediate sample
if [ -x "$BASE/balance-query" ] && [ -f "$BASE/accounts.json" ]; then
	sh "$BASE/balance-watch.sh" once || true
fi
# also start the loop (rc.local will re-start on boot)
( nohup sh "$BASE/balance-watch.sh" "$INTERVAL" </dev/null >/dev/null 2>&1 & ) || true

echo "installed: $BASE  interval=${INTERVAL}s"
echo "fill credentials: $BASE/accounts.json"
echo "status:           $BASE/status.json"
echo "manual:           sh $BASE/balance-watch.sh once"
