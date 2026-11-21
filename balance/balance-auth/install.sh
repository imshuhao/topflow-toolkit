#!/bin/sh
# balance-auth 旁路已退役：授信并进 WebSSH（:8899）单进程。
# 本脚本只保留 --uninstall（清 rc.local / 杀进程 / 去掉可执行位）。
set -eu
BASE=${BASE:-/data/local/balance}
RC_LOCAL=${RC_LOCAL:-/etc/rc.local}
BEGIN='# >>> TopFlow balance-auth >>>'
END='# <<< TopFlow balance-auth <<<'

kill_auth() {
	if [ -f /tmp/balance-auth.pid ]; then
		kill "$(cat /tmp/balance-auth.pid)" 2>/dev/null || true
		rm -f /tmp/balance-auth.pid
	fi
	pidof balance-auth >/dev/null 2>&1 && kill "$(pidof balance-auth)" 2>/dev/null || true
}

remove_rc_hook() {
	[ -f "$RC_LOCAL" ] || return 0
	tmp=/tmp/rc.local.balance-auth.$$
	awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$RC_LOCAL" >"$tmp"
	sh -n "$tmp" && cat "$tmp" >"$RC_LOCAL"
	rm -f "$tmp"
}

disable_binaries() {
	chmod a-x "$BASE/balance-auth" "$BASE/start-auth.sh" "$BASE/balance-auth-start.sh" 2>/dev/null || true
}

if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "" ]; then
	kill_auth
	remove_rc_hook
	disable_binaries
	echo "balance-auth retired (use WebSSH /api/balance/*)"
	exit 0
fi

echo "ERROR: balance-auth sidecar is retired; refuse install. Run: $0 --uninstall" >&2
exit 1
