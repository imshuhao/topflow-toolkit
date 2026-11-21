#!/bin/sh
# Install the sing-box WebUI page (#singbox_manager).
#
# The page is co-hosted inside the existing mihomo-manager bind-mount host
# (/data/mihomo-manager/{rpcd,acl.d,web}), because only one bind mount can own
# /usr/libexec/rpcd, /usr/share/rpcd/acl.d, js/auth/adm and tmpl/auth/adm.
# Installing a second independent mount would shadow mihomo.api and the
# Mihomo page.

set -eu

MSYS_NO_PATHCONV=1
MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ADB_BIN="${ADB_BIN:-adb}"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mu5252-singbox-manager.XXXXXX")"

# Git Bash: adb.exe and node.exe need Windows paths, while the device paths
# passed to adb must stay literal (/data/...). cygpath bridges that.
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

device_shell() {
    "$ADB_BIN" shell "$@"
}

device_push() {
    "$ADB_BIN" push "$1" "$2" >/dev/null
}

"$ADB_BIN" get-state >/dev/null
[ "$(device_shell 'id -u' | tr -d '\r')" = 0 ] || {
    echo "ADB shell is not root" >&2
    exit 1
}

# The WebUI host must already exist (installed by mihomo-manager/install.sh).
if ! device_shell '
    for d in /data/mihomo-manager/rpcd /data/mihomo-manager/acl.d \
             /data/mihomo-manager/web/js-auth-adm /data/mihomo-manager/web/tmpl-auth-adm \
             /data/mihomo-manager/web-root; do
        [ -d "$d" ] || exit 1
    done
    grep -q " /usr/libexec/rpcd " /proc/mounts || exit 1
    grep -q " /usr/share/rpcd/acl.d " /proc/mounts || exit 1
    [ "$(stat -c %d:%i /data/mihomo-manager/rpcd/mihomo.api 2>/dev/null)" = \
      "$(stat -c %d:%i /usr/libexec/rpcd/mihomo.api 2>/dev/null)" ] || exit 1
' >/dev/null 2>&1; then
    echo "mihomo-manager WebUI host is required first (its bind mounts are reused)" >&2
    echo "install it with: sh mihomo-manager/install.sh" >&2
    exit 1
fi

# Patch the live menu/index copies (they are bind-mounted, so the browser and
# the boot service both see the change immediately).
"$ADB_BIN" pull /usr/zte_web/web/index.html "$TEMP_LOCAL/index.html" >/dev/null
"$ADB_BIN" pull /usr/zte_web/web/js/config/ufi/U60Pro/menu.js "$TEMP_LOCAL/menu.js" >/dev/null
node "$HERE_LOCAL/patch-webui.mjs" add \
    "$TEMP_LOCAL/index.html" "$TEMP_LOCAL/menu.js" \
    "$TEMP_LOCAL/index.patched.html" "$TEMP_LOCAL/menu.patched.js"

device_push "$TEMP_LOCAL/index.patched.html" /tmp/singbox-index.html
device_push "$TEMP_LOCAL/menu.patched.js" /tmp/singbox-menu.js
# cat > keeps the inode, so the file bind mount stays valid.
device_shell 'cat /tmp/singbox-index.html > /data/mihomo-manager/web-root/index.html
              cat /tmp/singbox-menu.js > /data/mihomo-manager/web-root/menu.js
              rm -f /tmp/singbox-index.html /tmp/singbox-menu.js'

device_shell 'mkdir -p /data/singbox-manager'
device_push "$HERE_LOCAL/singbox-manager.sh" /data/singbox-manager/singbox-manager.sh
device_push "$HERE_LOCAL/rpcd-singbox.api" /data/mihomo-manager/rpcd/singbox.api
device_push "$HERE_LOCAL/singbox-acl.json" /data/mihomo-manager/acl.d/singbox.json
device_push "$HERE_LOCAL/web/singbox_manager.js" /data/mihomo-manager/web/js-auth-adm/singbox_manager.js
device_push "$HERE_LOCAL/web/singbox_manager.html" /data/mihomo-manager/web/tmpl-auth-adm/singbox_manager.html

device_shell 'chmod 0700 /data/singbox-manager/singbox-manager.sh
              chmod 0755 /data/mihomo-manager/rpcd/singbox.api
              chmod 0644 /data/mihomo-manager/acl.d/singbox.json \
                         /data/mihomo-manager/web/js-auth-adm/singbox_manager.js \
                         /data/mihomo-manager/web/tmpl-auth-adm/singbox_manager.html'
device_shell 'for f in /data/singbox-manager/singbox-manager.sh /data/mihomo-manager/rpcd/singbox.api; do
                  tr -d "\r" <"$f" >"$f.lf" && cat "$f.lf" >"$f" && rm -f "$f.lf"
              done'
device_shell 'sh -n /data/singbox-manager/singbox-manager.sh
              sh -n /data/mihomo-manager/rpcd/singbox.api'

device_shell '/etc/init.d/rpcd restart'
sleep 1

device_shell 'ubus -v list "singbox.api" >/dev/null'
device_shell 'ubus call singbox.api status >/dev/null'
device_shell 'grep -q "#singbox_manager" /usr/zte_web/web/index.html
              grep -q "#singbox_manager" /usr/zte_web/web/js/config/ufi/U60Pro/menu.js
              grep -q "#mihomo_manager" /usr/zte_web/web/index.html
              grep -q "#mihomo_manager" /usr/zte_web/web/js/config/ufi/U60Pro/menu.js
              sync'

echo "Sing-box WebUI manager installed: http://192.168.0.1/#singbox_manager"

