#!/bin/sh
# Remove the sing-box WebUI page (#singbox_manager) and its rpcd API.
# The Mihomo page, Mihomo service and the sing-box service are not touched.

set -eu

MSYS_NO_PATHCONV=1
MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ADB_BIN="${ADB_BIN:-adb}"
MODE="${1:-apply}"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mu5252-singbox-manager-uninstall.XXXXXX")"

if command -v cygpath >/dev/null 2>&1; then
    HERE_LOCAL="$(cygpath -w "$HERE")"
    TEMP_LOCAL="$(cygpath -w "$TEMP_DIR")"
else
    HERE_LOCAL="$HERE"
    TEMP_LOCAL="$TEMP_DIR"
fi

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT INT TERM

[ "$MODE" = apply ] || [ "$MODE" = --check ] || {
    echo "usage: $0 [--check]" >&2
    exit 2
}

"$ADB_BIN" get-state >/dev/null
[ "$("$ADB_BIN" shell 'id -u' | tr -d '\r')" = 0 ] || {
    echo "ADB shell is not root" >&2
    exit 1
}

if [ "$MODE" = --check ]; then
    "$ADB_BIN" shell '
        echo "api=$([ -f /data/mihomo-manager/rpcd/singbox.api ] && echo present || echo absent)"
        echo "acl=$([ -f /data/mihomo-manager/acl.d/singbox.json ] && echo present || echo absent)"
        echo "page=$([ -f /data/mihomo-manager/web/js-auth-adm/singbox_manager.js ] && echo present || echo absent)"
        echo "script=$([ -x /data/singbox-manager/singbox-manager.sh ] && echo present || echo absent)"
        echo "route=$(grep -q "#singbox_manager" /usr/zte_web/web/js/config/ufi/U60Pro/menu.js && echo present || echo absent)"
        echo "menu=$(grep -q "#singbox_manager" /usr/zte_web/web/index.html && echo present || echo absent)"
    '
    exit 0
fi

# Revert the shared menu/index copies in place (keeps the Mihomo entry).
if "$ADB_BIN" shell '[ -f /usr/zte_web/web/index.html ] && [ -f /usr/zte_web/web/js/config/ufi/U60Pro/menu.js ]'; then
    "$ADB_BIN" pull /usr/zte_web/web/index.html "$TEMP_LOCAL/index.html" >/dev/null
    "$ADB_BIN" pull /usr/zte_web/web/js/config/ufi/U60Pro/menu.js "$TEMP_LOCAL/menu.js" >/dev/null
    node "$HERE_LOCAL/patch-webui.mjs" remove \
        "$TEMP_LOCAL/index.html" "$TEMP_LOCAL/menu.js" \
        "$TEMP_LOCAL/index.unpatched.html" "$TEMP_LOCAL/menu.unpatched.js"
    "$ADB_BIN" push "$TEMP_LOCAL/index.unpatched.html" /tmp/singbox-index.html >/dev/null
    "$ADB_BIN" push "$TEMP_LOCAL/menu.unpatched.js" /tmp/singbox-menu.js >/dev/null
    "$ADB_BIN" shell 'cat /tmp/singbox-index.html > /data/mihomo-manager/web-root/index.html
                      cat /tmp/singbox-menu.js > /data/mihomo-manager/web-root/menu.js
                      rm -f /tmp/singbox-index.html /tmp/singbox-menu.js'
fi

"$ADB_BIN" shell '
    rm -f /data/mihomo-manager/rpcd/singbox.api \
          /data/mihomo-manager/acl.d/singbox.json \
          /data/mihomo-manager/web/js-auth-adm/singbox_manager.js \
          /data/mihomo-manager/web/tmpl-auth-adm/singbox_manager.html
    rm -rf /data/singbox-manager
    /etc/init.d/rpcd restart
    sync
'
sleep 1

"$ADB_BIN" shell '
    ! ubus list singbox.api >/dev/null 2>&1
    ! grep -q "#singbox_manager" /usr/zte_web/web/index.html
    ! grep -q "#singbox_manager" /usr/zte_web/web/js/config/ufi/U60Pro/menu.js
    grep -q "#mihomo_manager" /usr/zte_web/web/index.html
'

echo "Sing-box WebUI manager removed; sing-box and Mihomo were not changed"
