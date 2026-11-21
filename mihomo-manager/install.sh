#!/bin/sh

set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
MIHOMO_NETNS="$(CDPATH='' cd -- "$HERE/../mihomo-netns" && pwd)"
ADB_BIN="${ADB_BIN:-adb}"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mu5252-mihomo-manager.XXXXXX")"

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

device_shell 'command -v stat >/dev/null'
if ! device_shell '[ ! -d /data/local/webui-full-menu ] && [ ! -x /etc/init.d/web-full-menu ]'; then
    echo "remove the full WebUI menu before installing or updating Mihomo Manager" >&2
    exit 1
fi

for file in \
    "$MIHOMO_NETNS/mihomo-netns.sh" \
    "$MIHOMO_NETNS/mihomo-netns-autostart.sh" \
    "$MIHOMO_NETNS/mihomo-netns.init"; do
    [ -f "$file" ] || { echo "missing dependency: $file" >&2; exit 1; }
done

(cd "$HERE/rewrite" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -mod=readonly -trimpath -ldflags='-s -w' -o "$TEMP_DIR/rewrite-policy" .)
device_shell 'command -v dig >/dev/null'

if device_shell '/etc/init.d/mihomo-netns enabled' >/dev/null 2>&1; then
    SERVICE_WAS_ENABLED=1
else
    SERVICE_WAS_ENABLED=0
fi

device_shell '
    set -eu
    mount_present() {
        awk -v target="$1" '\''$2 == target { found=1 } END { exit !found }'\'' /proc/mounts
    }
    same_inode() {
        [ -e "$1" ] && [ -e "$2" ] || return 1
        source_inode=$(stat -c "%d:%i" "$1" 2>/dev/null) || return 1
        target_inode=$(stat -c "%d:%i" "$2" 2>/dev/null) || return 1
        [ "$source_inode" = "$target_inode" ]
    }
    unmount_owned() {
        while mount_present "$2" && same_inode "$1" "$2"; do
            umount "$2"
        done
    }

    unmount_owned /data/mihomo-manager/web-root/menu.js /usr/zte_web/web/js/config/ufi/U60Pro/menu.js
    unmount_owned /data/mihomo-manager/web-root/index.html /usr/zte_web/web/index.html
    unmount_owned /data/mihomo-manager/web/tmpl-auth-adm /usr/zte_web/web/tmpl/auth/adm
    unmount_owned /data/mihomo-manager/web/js-auth-adm /usr/zte_web/web/js/auth/adm
    unmount_owned /data/mihomo-manager/acl.d /usr/share/rpcd/acl.d
    unmount_owned /data/mihomo-manager/rpcd /usr/libexec/rpcd

    for target in \
        /usr/zte_web/web/js/config/ufi/U60Pro/menu.js \
        /usr/zte_web/web/index.html \
        /usr/zte_web/web/tmpl/auth/adm \
        /usr/zte_web/web/js/auth/adm \
        /usr/share/rpcd/acl.d \
        /usr/libexec/rpcd; do
        if mount_present "$target"; then
            echo "$target already has an unrelated bind mount" >&2
            exit 1
        fi
    done
' >/dev/null
"$ADB_BIN" pull /usr/zte_web/web/index.html "$TEMP_DIR/index.html" >/dev/null
"$ADB_BIN" pull /usr/zte_web/web/js/config/ufi/U60Pro/menu.js "$TEMP_DIR/menu.js" >/dev/null
node "$HERE/patch-webui.mjs" \
    "$TEMP_DIR/index.html" "$TEMP_DIR/menu.js" \
    "$TEMP_DIR/index.patched.html" "$TEMP_DIR/menu.patched.js"

device_shell 'mkdir -p /data/mihomo-manager/rpcd /data/mihomo-manager/acl.d /data/mihomo-manager/web/js-auth-adm /data/mihomo-manager/web/tmpl-auth-adm /data/mihomo-manager/web-root /data/mihomo/state /data/mihomo'
device_push "$TEMP_DIR/rewrite-policy" /data/mihomo-manager/rewrite-policy.new
device_shell 'chmod 0700 /data/mihomo-manager/rewrite-policy.new && mv /data/mihomo-manager/rewrite-policy.new /data/mihomo-manager/rewrite-policy'
device_push "$HERE/mihomo-manager.sh" /data/mihomo-manager/mihomo-manager.sh
device_push "$HERE/rpcd-mihomo.api" /data/mihomo-manager/rpcd/mihomo.api
device_push "$HERE/mihomo-acl.json" /data/mihomo-manager/acl.d/mihomo.json
device_push "$HERE/web/mihomo_manager.js" /data/mihomo-manager/web/js-auth-adm/mihomo_manager.js
device_push "$HERE/web/mihomo_manager.html" /data/mihomo-manager/web/tmpl-auth-adm/mihomo_manager.html
device_push "$TEMP_DIR/index.patched.html" /data/mihomo-manager/web-root/index.html
device_push "$TEMP_DIR/menu.patched.js" /data/mihomo-manager/web-root/menu.js
device_push "$HERE/mihomo-manager-web.init" /etc/init.d/mihomo-manager-web
device_push "$HERE/install-boot-hook.sh" /data/mihomo-manager/install-boot-hook.sh
device_push "$HERE/remove-boot-hook.sh" /data/mihomo-manager/remove-boot-hook.sh
device_push "$MIHOMO_NETNS/mihomo-netns.sh" /data/mihomo/mihomo-netns.sh
device_push "$MIHOMO_NETNS/mihomo-netns-autostart.sh" /data/mihomo/mihomo-netns-autostart.sh
device_push "$MIHOMO_NETNS/mihomo-netns.init" /etc/init.d/mihomo-netns

device_shell 'chmod 0700 /data/mihomo-manager/mihomo-manager.sh; chmod 0755 /data/mihomo-manager/rpcd/mihomo.api /data/mihomo-manager/install-boot-hook.sh /data/mihomo-manager/remove-boot-hook.sh /etc/init.d/mihomo-manager-web /etc/init.d/mihomo-netns /data/mihomo/mihomo-netns.sh /data/mihomo/mihomo-netns-autostart.sh; chmod 0644 /data/mihomo-manager/acl.d/mihomo.json /data/mihomo-manager/web/js-auth-adm/mihomo_manager.js /data/mihomo-manager/web/tmpl-auth-adm/mihomo_manager.html /data/mihomo-manager/web-root/index.html /data/mihomo-manager/web-root/menu.js'
device_shell '/etc/init.d/mihomo-manager-web enable; /data/mihomo-manager/install-boot-hook.sh; /etc/init.d/mihomo-manager-web start; /etc/init.d/rpcd restart'

if [ "$SERVICE_WAS_ENABLED" -eq 1 ]; then
    device_shell '/etc/init.d/mihomo-netns enable; /etc/init.d/mihomo-netns restart'
else
    device_shell '/etc/init.d/mihomo-netns disable; /etc/init.d/mihomo-netns stop'
fi

device_shell 'ubus -v list mihomo.api >/dev/null; grep -q "#mihomo_manager" /usr/zte_web/web/index.html; grep -q "#mihomo_manager" /usr/zte_web/web/js/config/ufi/U60Pro/menu.js; sync'
echo "Mihomo WebUI manager installed: http://192.168.11.1/#mihomo_manager"
