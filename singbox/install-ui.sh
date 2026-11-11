#!/bin/sh
# Install / refresh the Zashboard UI on the device. Does not start sing-box.
set -eu
MSYS_NO_PATHCONV=1
MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

DEV="${SINGBOX_BASE:-/data/sing-box}"
ADB="${ADB:-adb}"
URL="https://gh-proxy.com/https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

curl -fsSL --max-time 300 -o "$TMP/zash.zip" "$URL"
python - "$TMP/zash.zip" "$TMP" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY

"$ADB" shell "rm -rf '$DEV/ui.new'; mkdir -p '$DEV/ui.new'"
"$ADB" push "$TMP/zashboard-gh-pages/." "$DEV/ui.new/"
"$ADB" shell "if [ -d '$DEV/ui' ]; then mv '$DEV/ui' '$DEV/ui-backup-$(date +%Y%m%d-%H%M%S)'; fi; mv '$DEV/ui.new' '$DEV/ui'; echo installed"
echo "Zashboard installed at $DEV/ui (restart sing-box or it serves immediately)"
