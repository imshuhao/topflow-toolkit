#!/bin/sh
# install-boot-hook.sh — start the wireless ADB service (adb-wifi) from rc.local.
#
# Why rc.local: this device's rcS does not run init.d services added to the
# overlay, so every component of this toolkit is started from /etc/rc.local.
#
# Idempotent: the block is bounded by the two marker comments below; a re-run
# drops the old copy and writes the same one back before the final `exit 0`, so
# a second run leaves the file byte-identical (no duplicate block). When rc.local
# has no `exit 0` line the block is appended at EOF instead.
#
# Atomic: the new rc.local is built as "$RC_LOCAL.adb-wifi.new", checked with
# `sh -n`, then renamed over the old file; a failed check leaves rc.local as is.
#
# Rollback: ./remove-boot-hook.sh, or
#   cp /data/adb-wifi/backup/rc.local.bak-pre-adbwifi /etc/rc.local
#
# Environment:
#   RC_LOCAL           rc.local to patch (default: /etc/rc.local)
#   ADB_WIFI_DATA_DIR  data dir holding the backup (default: /data/adb-wifi)

set -eu

RC_LOCAL="${RC_LOCAL:-/etc/rc.local}"
ADB_WIFI_DATA_DIR="${ADB_WIFI_DATA_DIR:-/data/adb-wifi}"
BACKUP="$ADB_WIFI_DATA_DIR/backup/rc.local.bak-pre-adbwifi"
TEMP="$RC_LOCAL.adb-wifi.new"
BEGIN_MARKER='# Start the TopFlow wireless ADB service.'
END_MARKER='# End the TopFlow wireless ADB service.'

cleanup() {
    rm -f "$TEMP"
}
trap cleanup EXIT INT TERM

if [ ! -f "$RC_LOCAL" ]; then
    echo "rc.local not found: $RC_LOCAL" >&2
    exit 1
fi
if [ ! -w "$RC_LOCAL" ]; then
    echo "rc.local not writable: $RC_LOCAL (run as root)" >&2
    exit 1
fi
if ! : >"$TEMP" 2>/dev/null; then
    echo "cannot create $TEMP (is the directory of $RC_LOCAL writable?)" >&2
    exit 1
fi

# Keep exactly one pre-change copy: never overwrite the vendor file on re-runs.
if [ ! -f "$BACKUP" ]; then
    if mkdir -p "$ADB_WIFI_DATA_DIR/backup" 2>/dev/null && cp "$RC_LOCAL" "$BACKUP"; then
        echo "backup: $BACKUP"
    else
        echo "warning: cannot write backup $BACKUP, continuing without it" >&2
    fi
fi

if ! awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    function emit_block() {
        print begin
        print "if [ -x /data/adb-wifi/adb-wifi.sh ]; then"
        print "    adbwifi_ok=0"
        print "    /data/adb-wifi/adb-wifi.sh apply >/dev/null 2>&1 && adbwifi_ok=1"
        print "    if [ \"$adbwifi_ok\" = 0 ]; then"
        print "        sleep 5"
        print "        /data/adb-wifi/adb-wifi.sh apply >/dev/null 2>&1 && adbwifi_ok=1"
        print "    fi"
        print "    if [ \"$adbwifi_ok\" = 0 ]; then"
        print "        # failsafe: next boot skips the preset so adbd returns to USB-only"
        print "        mkdir -p /data/adb-wifi/state 2>/dev/null"
        print "        touch /data/adb-wifi/state/disable-preset 2>/dev/null"
        print "        echo \"$(date) boot: tcp listener missing, disable-preset set\" >> /tmp/adb-wifi-watchdog.log 2>/dev/null"
        print "    fi"
        print "fi"
        print "[ -x /data/adb-wifi/adb-wifi-watchdog.sh ] && /data/adb-wifi/adb-wifi-watchdog.sh >/dev/null 2>&1 &"
        print end
    }
    $0 == begin { skipping = 1; next }
    $0 == end { skipping = 0; drop_blank = 1; next }
    drop_blank && $0 == "" { drop_blank = 0; next }
    drop_blank { drop_blank = 0 }
    !skipping {
        if (!inserted && $0 ~ /^exit 0[[:space:]]*$/) {
            emit_block()
            print ""
            inserted = 1
        }
        print
    }
    END {
        if (skipping) exit 42
        if (!inserted) emit_block()
    }
' "$RC_LOCAL" >"$TEMP"; then
    echo "rewrite failed (unterminated \"$BEGIN_MARKER\" block?), $RC_LOCAL left unchanged" >&2
    exit 1
fi

if ! sh -n "$TEMP"; then
    echo "syntax check failed, $RC_LOCAL left unchanged" >&2
    exit 1
fi
if [ "$(grep -cF "$BEGIN_MARKER" "$TEMP")" -ne 1 ]; then
    echo "expected one \"$BEGIN_MARKER\" marker, $RC_LOCAL left unchanged" >&2
    exit 1
fi

if cmp -s "$TEMP" "$RC_LOCAL"; then
    echo "rc.local hook already installed: $RC_LOCAL"
else
    chmod 0755 "$TEMP"
    mv -f "$TEMP" "$RC_LOCAL"
    echo "rc.local hook installed: $RC_LOCAL"
fi
