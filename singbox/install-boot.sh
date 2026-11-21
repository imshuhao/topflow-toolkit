#!/bin/sh
# Install sing-box boot hook + provider cron. Run on the device, after a
# successful switchover or during a maintenance window. Idempotent.
set -eu

# shellcheck disable=SC2034  # documented override point; used by callers/muscle memory
BASE="${SINGBOX_BASE:-/data/sing-box}"
RC=/etc/rc.local
CRON=/etc/crontabs/root
STAMP=$(date '+%Y%m%d-%H%M%S')

if [ ! -f "$RC" ]; then
    echo "missing $RC" >&2
    exit 1
fi

if ! grep -q 'TopFlow sing-box watchdog' "$RC"; then
    cp -p "$RC" "$RC.bak-pre-singbox-$STAMP"
    awk '
        function emit() {
            print "# >>> TopFlow sing-box watchdog >>>"
            print "touch /tmp/mihomo-netns-manual-stop"
            print "[ -x /data/sing-box/singbox-watchdog.sh ] && /data/sing-box/singbox-watchdog.sh >/dev/null 2>&1 &"
            print "# >>> end TopFlow sing-box watchdog >>>"
        }
        /^exit 0[[:space:]]*$/ && !done { emit(); done = 1 }
        { print }
        END { if (!done) emit() }
    ' "$RC.bak-pre-singbox-$STAMP" > "$RC.tmp"
    mv "$RC.tmp" "$RC"
    chmod 755 "$RC"
    sh -n "$RC" || { echo "rc.local syntax error; restored backup" >&2; cp -p "$RC.bak-pre-singbox-$STAMP" "$RC"; exit 1; }
    grep -q 'TopFlow sing-box watchdog' "$RC"
    echo "rc.local: sing-box block added (backup $RC.bak-pre-singbox-$STAMP)"
else
    echo "rc.local: sing-box block already present"
fi

mkdir -p "$(dirname "$CRON")"
touch "$CRON"
if ! grep -q '/data/sing-box/update-providers.sh' "$CRON"; then
    echo '0 4 * * * /data/sing-box/update-providers.sh' >> "$CRON"
    /etc/init.d/cron restart >/dev/null 2>&1 || true
    echo "cron: provider updater added"
else
    echo "cron: provider updater already present"
fi

/etc/init.d/mihomo-netns disable >/dev/null 2>&1 || true
touch /tmp/mihomo-netns-manual-stop
echo "mihomo-netns init disabled (rollback re-enables it)"
