#!/bin/sh
# Install (or remove) the cron guard that repairs the MULTIWAN data plane after
# the device was switched to SMULTIWAN (vendor ICG aggregation) and back.
#
#   install-mode-guard.sh             # install / refresh the guard
#   install-mode-guard.sh --uninstall # remove it
#
# The guard is one cron line:
#   */2 * * * * /data/local/mwan3-tuning/recover.sh --check
# recover.sh --check is silent and read-only unless mwan3 is down, the tuned
# weights (6/3/3) drifted, the wan-balance ip rules disappeared, or the nft
# tf-sbwan table is missing while sing-box is running.  Only then does it run
# the full recovery (apply-rules + mwan3 restart + wan-balance apply).
#
# Idempotent: re-running replaces the managed line.  Backup of the previous
# crontab is kept next to the tuning payload.

set -eu

BASE=${BASE:-/data/local/mwan3-tuning}
CRON=${CRON:-/etc/crontabs/root}
MARK='# topflow-mode-guard: recover MULTIWAN after SMULTIWAN switch'
LINE='*/2 * * * * /data/local/mwan3-tuning/recover.sh --check >/dev/null 2>&1'

[ -x "$BASE/recover.sh" ] || { echo "recover.sh missing in $BASE" >&2; exit 1; }
mkdir -p "$(dirname "$CRON")"

tmp=$(mktemp) || exit 1
trap 'rm -f "$tmp"' EXIT INT TERM

if [ "${1:-}" = "--uninstall" ]; then
	grep -v -F "$MARK" "$CRON" 2>/dev/null | grep -v -F "$LINE" >"$tmp" || true
	cat "$tmp" >"$CRON"
	/etc/init.d/cron restart >/dev/null 2>&1 || true
	echo "mode guard removed from $CRON"
	exit 0
fi

if [ -f "$CRON" ] && [ ! -f "$BASE/crontab.bak-mode-guard" ]; then
	cp -p "$CRON" "$BASE/crontab.bak-mode-guard"
fi

# Keep every unrelated line, then append the managed pair (marker + line).
grep -v -F "$MARK" "$CRON" 2>/dev/null | grep -v -F "$LINE" >"$tmp" || true
{
	cat "$tmp"
	printf '%s\n' "$MARK"
	printf '%s\n' "$LINE"
} >"$tmp.new"
cat "$tmp.new" >"$CRON"
rm -f "$tmp.new"
chmod 0600 "$CRON"

/etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/cron reload >/dev/null 2>&1 || true
echo "mode guard installed in $CRON:"
grep -F "$LINE" "$CRON" | sed 's/^/  /'
