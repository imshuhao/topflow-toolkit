#!/bin/sh
# MU5252 B22 only. Run on the device as root; no background enforcement.
set -eu
umask 077

service=/etc/init.d/zte_mqtt_sdk_st
state=/data/local/vendor-control
keys='seecom_card_flag sub_1_seecom_card_flag sub_2_seecom_card_flag'
mode=${1:-status}
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
case "$mode" in apply|status|check) ;; *) fail 'Usage: disable-mqtt-auth.sh [apply|status|check]' ;; esac
[ "$(id -u)" = 0 ] || fail 'Run as root on the device.'
[ "$(uci -q get zwrt_common_info.common_config.wa_inner_version)" = BD_ENCNMU5252V1.0.0B22 ] || fail 'Only audited MU5252 B22 is supported.'
[ -x "$service" ] || fail 'Missing vendor MQTT init script.'
for tool in ubus jsonfilter iptables-save ip6tables-save sha256sum; do
    command -v "$tool" >/dev/null || fail "Missing tool: $tool"
done

# The UBus close handler and its configuration reload were audited in this binary.
expected=d88f431f34177c52fc65af9ca870ea20fef54bb2e8997bb7cc5acfa9f0d9f584
[ "$(sha256sum /usr/bin/zte_topsw_redirect | awk '{print $1}')" = "$expected" ] || fail 'Redirect binary differs from audited B22.'
for key in $keys; do
    value=$(uci -q get "zwrt_zte_mdm.sim_info.$key") || fail "Missing auth key: $key"
    case "$value" in 0|1) ;; *) fail "Unexpected auth value: $key" ;; esac
done

inspect() {
    ok=1
    if "$service" enabled >/dev/null 2>&1; then
        echo 'mqtt_autostart=enabled'; ok=0
    else
        echo 'mqtt_autostart=disabled'
    fi
    if pidof zte_mqtt_sdk_st >/dev/null; then
        echo 'mqtt_process=running'; ok=0
    else
        echo 'mqtt_process=stopped'
    fi
    for key in $keys; do
        value=$(uci -q get "zwrt_zte_mdm.sim_info.$key")
        printf '%s=%s\n' "$key" "$value"
        [ "$value" = 0 ] || ok=0
    done
    # Count chain contents, not harmless jumps to empty chains; print no client IDs.
    for family in iptables-save ip6tables-save; do
        rules=$("$family") || return 1
        count=$(printf '%s\n' "$rules" | awk '$1 == "-A" && $2 ~ /^(second_auth_redirect_chain|second_redirect_chain(_ip6)?|second_wan[123]_chain(_ip6)?)$/ {n++} END {print n+0}')
        printf '%s_auth_rules=%s\n' "$family" "$count"
        [ "$count" = 0 ] || ok=0
    done
    result=$(ubus call zwrt_redirect.api get_second_auth_multi_wan_unauth_list '{}') || return 1
    count=$(printf '%s\n' "$result" | jsonfilter -e '@.count')
    printf 'unauthenticated_clients=%s\n' "${count:-unknown}"
    [ "$count" = 0 ] || ok=0
    sync_info=$(ubus call zwrt_topsw_daemon.sync get_sync_info '{}') || return 1
    synced=$(printf '%s\n' "$sync_info" | jsonfilter -e '@.noSyncModuleName')
    registered=$(printf '%s\n' "$sync_info" | jsonfilter -e '@.noRegModuleName')
    if [ "$synced" = 'sync success' ] && [ "$registered" = 'register success' ]; then
        echo 'vendor_startup=ready'
    else
        echo 'vendor_startup=not_ready'; ok=0
    fi
    [ "$ok" = 1 ]
}

if [ "$mode" != apply ]; then
    inspect
    exit $?
fi

# Do not commit unrelated pending changes from another process/operator.
[ -z "$(uci changes zwrt_zte_mdm)" ] || fail 'Pending zwrt_zte_mdm changes exist; resolve them before applying.'
if grep -Eq '^[[:space:]]*sync[[:space:]]+ALL[[:space:]]+zte_mqtt_sdk_st([[:space:]]|$)' /etc/config/zte_topsw_daemon.conf; then
    fail 'MQTT is a mandatory startup dependency on this device; review before disabling.'
fi
ubus -v list zwrt_redirect.msg | grep -q 'redirect_msg' || fail 'Redirect notification interface unavailable.'
mkdir -p "$state"
chmod 700 "$state"
mkdir "$state/apply.lock" 2>/dev/null || fail 'Another apply is running (or an interrupted run left apply.lock).'
trap 'rmdir "$state/apply.lock"' EXIT
trap 'exit 1' HUP INT TERM
if [ ! -e "$state/before.txt" ]; then
    {
        for key in $keys; do
            printf '%s=%s\n' "$key" "$(uci -q get "zwrt_zte_mdm.sim_info.$key")"
        done
        if "$service" enabled >/dev/null 2>&1; then echo 'mqtt_enabled=1'; else echo 'mqtt_enabled=0'; fi
        if pidof zte_mqtt_sdk_st >/dev/null; then echo 'mqtt_running=1'; else echo 'mqtt_running=0'; fi
    } > "$state/before.tmp"
    mv "$state/before.tmp" "$state/before.txt"
fi
# procd stop prevents respawn; disabling removes the boot symlinks.
"$service" disable
# OpenWrt prints "Not found" when stop is repeated after procd removal.
instances=$(ubus call service list '{"name":"zte_mqtt_sdk_st"}')
instances=$(printf '%s\n' "$instances" | jsonfilter -e '@.zte_mqtt_sdk_st.instances' || :)
if [ -n "$instances" ] || pidof zte_mqtt_sdk_st >/dev/null; then
    "$service" stop
fi
n=0
while pidof zte_mqtt_sdk_st >/dev/null; do
    [ "$n" -lt 10 ] || fail 'MQTT did not stop; auth settings were not changed.'
    n=$((n + 1)); sleep 1
done
[ -z "$(uci changes zwrt_zte_mdm)" ] || fail 'Configuration changed during apply; MQTT is disabled, retry after resolving pending changes.'
changed=0
for key in $keys; do
    if [ "$(uci -q get "zwrt_zte_mdm.sim_info.$key")" != 0 ]; then
        uci set "zwrt_zte_mdm.sim_info.$key=0"
        changed=1
    fi
done
[ "$changed" = 0 ] || uci commit zwrt_zte_mdm
# B22 handler re-reads all three flags. msg_data is the vendor SIM index (1..3).
# It does not mark a client authenticated or require a data-plane restart.
for sim in 1 2 3; do
    ubus call zwrt_redirect.msg redirect_msg "{\"msg_module_name\":\"topflow-toolkit\",\"msg_cmd\":\"second_auth_close\",\"msg_data\":\"$sim\"}" >/dev/null
done
n=0
while ! inspect > "$state/last-check.txt"; do
    [ "$n" -lt 15 ] || { cat "$state/last-check.txt"; fail 'Settings saved but runtime checks failed; inspect before rebooting.'; }
    n=$((n + 1)); sleep 1
done
cat "$state/last-check.txt"
echo 'Applied. Original switch/service state: /data/local/vendor-control/before.txt'
