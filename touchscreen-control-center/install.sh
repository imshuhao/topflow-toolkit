#!/bin/sh

set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ADB_BIN="${ADB_BIN:-adb}"
DEVICE_DIR=/data/touchscreen-control-center
INIT_FILE=/etc/init.d/touchscreen-control-center
EXPECTED_DEVUI_SHA256=781e3c6ffa2a9db4d61a3cf1bb38461131dc3faed07499a2c9360bc582040dd2

if [ ! -f "$HERE/touchui-hook.so" ]; then
    "$HERE/build.sh"
fi

device_shell() {
    "$ADB_BIN" shell "$@"
}

for file in touchui-hook.so start.sh restore-stock.sh touchscreen-control-center.init install-boot-hook.sh remove-boot-hook.sh; do
    [ -f "$HERE/$file" ] || {
        echo "missing build artifact: $HERE/$file" >&2
        exit 1
    }
done

"$ADB_BIN" get-state >/dev/null
[ "$(device_shell 'id -u' | tr -d '\r')" = 0 ] || {
    echo "ADB shell is not root" >&2
    exit 1
}

ACTUAL_DEVUI_SHA256="$(device_shell 'sha256sum /usr/bin/zte_topsw_devui' | tr -d '\r' | awk '{print $1}')"
[ "$ACTUAL_DEVUI_SHA256" = "$EXPECTED_DEVUI_SHA256" ] || {
    echo "unsupported zte_topsw_devui build: $ACTUAL_DEVUI_SHA256" >&2
    exit 1
}

# Stop an injected UI only when its library is actually mapped. Restarting an
# already-stock UI here caused two QPIC display-pipe turnovers back-to-back.
device_shell '
    ui="$(pidof zte_topsw_devui)"
    if [ -n "$ui" ] && grep -q /data/touchscreen-control-center/touchui-hook.so "/proc/$ui/maps" 2>/dev/null; then
        /etc/init.d/touchscreen-control-center stop
    elif [ -n "$ui" ] && grep -q /data/touchscreen-mihomo-manager/touchui-hook.so "/proc/$ui/maps" 2>/dev/null; then
        /etc/init.d/touchscreen-mihomo-manager stop
    fi
' >/dev/null
device_shell '
    ui="$(pidof zte_topsw_devui)"
    if [ -x /data/touchscreen-mihomo-poc/restore-stock.sh ] && [ -n "$ui" ] &&
       grep -q /data/touchscreen-mihomo-poc "/proc/$ui/maps" 2>/dev/null; then
        /data/touchscreen-mihomo-poc/restore-stock.sh
    fi
' >/dev/null

device_shell "mkdir -p '$DEVICE_DIR' && chmod 0755 '$DEVICE_DIR'"
"$ADB_BIN" push "$HERE/touchui-hook.so" "$DEVICE_DIR/touchui-hook.so" >/dev/null
"$ADB_BIN" push "$HERE/start.sh" "$DEVICE_DIR/start.sh" >/dev/null
"$ADB_BIN" push "$HERE/restore-stock.sh" "$DEVICE_DIR/restore-stock.sh" >/dev/null
"$ADB_BIN" push "$HERE/install-boot-hook.sh" "$DEVICE_DIR/install-boot-hook.sh" >/dev/null
"$ADB_BIN" push "$HERE/remove-boot-hook.sh" "$DEVICE_DIR/remove-boot-hook.sh" >/dev/null
"$ADB_BIN" push "$HERE/touchscreen-control-center.init" "$INIT_FILE" >/dev/null

device_shell "chmod 0644 '$DEVICE_DIR/touchui-hook.so'; chmod 0755 '$DEVICE_DIR/start.sh' '$DEVICE_DIR/restore-stock.sh' '$DEVICE_DIR/install-boot-hook.sh' '$DEVICE_DIR/remove-boot-hook.sh' '$INIT_FILE'"
device_shell "$INIT_FILE enable"
device_shell "$DEVICE_DIR/install-boot-hook.sh"
device_shell "$INIT_FILE start"
sleep 7

device_shell '
    pids="$(pidof zte_topsw_devui)"
    set -- $pids
    [ "$#" -eq 1 ] || exit 1
    grep -q /data/touchscreen-control-center/touchui-hook.so "/proc/$1/maps" || exit 1
    supervisor="$(cat /tmp/touchscreen-control-center-supervisor.pid)"
    kill -0 "$supervisor" || exit 1
    test -L /etc/rc.d/S60touchscreen-control-center || exit 1
    grep -q "^# Start the MU5252 touchscreen control center\\.$" /etc/rc.local || exit 1
'

# Remove superseded UI packages only after the new control center has passed
# its runtime checks. This does not touch Mihomo or zwrt-datad.
device_shell '
    [ ! -x /etc/init.d/touchscreen-mihomo-manager ] || /etc/init.d/touchscreen-mihomo-manager disable
    rm -f /etc/init.d/touchscreen-mihomo-manager
    rm -f /etc/rc.d/S60touchscreen-mihomo-manager /etc/rc.d/K05touchscreen-mihomo-manager
    rm -rf /data/touchscreen-mihomo-manager /data/touchscreen-mihomo-poc
    rm -f /tmp/touchscreen-mihomo-manager-supervisor.pid /tmp/touchscreen-mihomo-manager-ui.log
    rm -f /tmp/touchui-poc-supervisor.pid /tmp/touchui-poc.log
'
device_shell sync

echo "touchscreen control center installed and running"
