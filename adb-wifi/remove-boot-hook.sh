#!/bin/sh
# remove-boot-hook.sh — drop the wireless ADB block from rc.local (rollback).
#
# Removes exactly the marker-bounded block (start line through end line
# inclusive) plus one trailing blank line, so `install-boot-hook.sh` can be
# undone. Without the block the file is not touched at all (no-op).
#
# Atomic: the rewritten rc.local is built as "$RC_LOCAL.adb-wifi.new", checked
# with `sh -n`, then renamed over the old file; a failed check leaves rc.local
# as is.
#
# Environment:
#   RC_LOCAL  rc.local to patch (default: /etc/rc.local)

set -eu

RC_LOCAL="${RC_LOCAL:-/etc/rc.local}"
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

if ! grep -qF "$BEGIN_MARKER" "$RC_LOCAL"; then
    echo "no adb-wifi hook in $RC_LOCAL, nothing to do"
    exit 0
fi

if [ ! -w "$RC_LOCAL" ]; then
    echo "rc.local not writable: $RC_LOCAL (run as root)" >&2
    exit 1
fi
if ! : >"$TEMP" 2>/dev/null; then
    echo "cannot create $TEMP (is the directory of $RC_LOCAL writable?)" >&2
    exit 1
fi

if ! awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    $0 == begin { skipping = 1; next }
    $0 == end { skipping = 0; drop_blank = 1; next }
    drop_blank && $0 == "" { drop_blank = 0; next }
    drop_blank { drop_blank = 0 }
    !skipping { print }
    END { if (skipping) exit 42 }
' "$RC_LOCAL" >"$TEMP"; then
    echo "unterminated \"$BEGIN_MARKER\" block, $RC_LOCAL left unchanged" >&2
    exit 1
fi

if ! sh -n "$TEMP"; then
    echo "syntax check failed, $RC_LOCAL left unchanged" >&2
    exit 1
fi

chmod 0755 "$TEMP"
mv -f "$TEMP" "$RC_LOCAL"
echo "rc.local hook removed: $RC_LOCAL"
