#!/bin/sh

. /usr/share/libubox/jshn.sh

umask 077

BASE=/data/mihomo
SERVICE="$BASE/mihomo-netns.sh"
CORE="$BASE/mihomo"
CONFIG="$BASE/config.yaml"
STATE_DIR="$BASE/state"
DHCP_ENABLED_FILE="$STATE_DIR/dhcp-enabled"
MANUAL_STOP_FILE=/tmp/mihomo-netns-manual-stop
PIDFILE="$BASE/run/mihomo.pid"
NS=mihomo
NS_IP=192.168.11.11
DHCP_GATEWAY_OPTION=3,192.168.11.11
DHCP_DNS_OPTION=6,192.168.11.11
ACTION_LOG=/tmp/mihomo-manager-action.log
CHECK_LOG=/tmp/mihomo-netns-check.log
LOCK_DIR=/tmp/mihomo-manager.lock
MAX_CONFIG_BYTES=1048576
TEMP_FILES=""
RELEASE_API=https://api.github.com/repos/MetaCubeX/mihomo/releases/latest

service_running() {
    [ -f "$PIDFILE" ] || return 1
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

namespace_present() {
    ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$NS"
}

dhcp_actual() {
    options=" $(uci -q get dhcp.lan.dhcp_option 2>/dev/null || true) "
    case "$options" in
        *" $DHCP_GATEWAY_OPTION "*) ;;
        *) return 1 ;;
    esac
    case "$options" in
        *" $DHCP_DNS_OPTION "*) return 0 ;;
    esac
    return 1
}

tun_enabled() {
    awk '
        /^tun:[[:space:]]*$/ { in_tun=1; next }
        in_tun && /^[^[:space:]]/ { in_tun=0 }
        in_tun && /^[[:space:]]+enable:[[:space:]]*/ {
            value=$0
            sub(/^[[:space:]]+enable:[[:space:]]*/, "", value)
            sub(/[[:space:]#].*$/, "", value)
            if (value == "true") exit 0
            exit 1
        }
        END { if (!in_tun) exit 1 }
    ' "$CONFIG" >/dev/null 2>&1
}

service_enabled() {
    /etc/init.d/mihomo-netns enabled >/dev/null 2>&1
}

service_supervisor_running() {
    /etc/init.d/mihomo-netns running >/dev/null 2>&1
}

lan_ipv6_disabled() {
    ubus call zwrt_router.api router_get_disable_lan_ipv6 '{}' 2>/dev/null \
        | jsonfilter -e '@.disable_lan_ipv6' | grep -qx 1
}

acquire_lock() {
    # Serialize stale-owner recovery, but never inherit the guard into services.
    lock_acquired=0
    exec 9>"$LOCK_DIR.guard" || return 1
    if flock -n 9; then
        if [ -d "$LOCK_DIR" ]; then
            lock_owner="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
            case "$lock_owner" in
                ''|*[!0-9]*) ;; # An ownerless legacy lock needs manual inspection.
                *)
                    if ! kill -0 "$lock_owner" 2>/dev/null; then
                        rm -f "$LOCK_DIR/pid"
                        rmdir "$LOCK_DIR" 2>/dev/null || true
                    fi
                    ;;
            esac
        fi
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            if printf '%s\n' "$$" >"$LOCK_DIR/pid"; then
                lock_acquired=1
            else
                rmdir "$LOCK_DIR" 2>/dev/null || true
            fi
        fi
        flock -u 9
    fi
    exec 9>&-
    [ "$lock_acquired" -eq 1 ] || return 1
    trap cleanup_runtime EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

cleanup_runtime() {
    if [ -n "$TEMP_FILES" ]; then
        rm -f $TEMP_FILES
    fi
    if [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
        rm -f "$LOCK_DIR/pid"
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}

result() {
    ok="$1"
    message="$2"
    json_init
    json_add_boolean ok "$ok"
    json_add_string message "$message"
    json_dump
}

result_with_details() {
    ok="$1"
    message="$2"
    details="$3"
    json_init
    json_add_boolean ok "$ok"
    json_add_string message "$message"
    json_add_string details "$details"
    json_dump
}

controller_secret() {
    awk '
        /^secret:[[:space:]]*/ {
            value=$0
            sub(/^secret:[[:space:]]*/, "", value)
            sub(/[[:space:]]+#.*$/, "", value)
            if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) {
                value=substr(value, 2, length(value) - 2)
            }
            print value
            exit
        }
    ' "$CONFIG"
}

controller_request() {
    method="$1"
    path="$2"
    body="${3:-}"
    secret="$(controller_secret)"
    namespace_present || return 1
    if [ "$method" = GET ]; then
        if [ -n "$secret" ]; then
            ip netns exec "$NS" curl -fsS --connect-timeout 2 --max-time 4 \
                -H "Authorization: Bearer $secret" "http://127.0.0.1:9090$path"
        else
            ip netns exec "$NS" curl -fsS --connect-timeout 2 --max-time 4 \
                "http://127.0.0.1:9090$path"
        fi
    elif [ -n "$secret" ]; then
        ip netns exec "$NS" curl -fsS --connect-timeout 2 --max-time 4 \
            -X "$method" -H "Authorization: Bearer $secret" -H 'Content-Type: application/json' \
            --data "$body" "http://127.0.0.1:9090$path"
    else
        ip netns exec "$NS" curl -fsS --connect-timeout 2 --max-time 4 \
            -X "$method" -H 'Content-Type: application/json' --data "$body" \
            "http://127.0.0.1:9090$path"
    fi
}

controller_mode() {
    response="$(controller_request GET /configs 2>/dev/null)" || return 1
    printf '%s' "$response" | jsonfilter -e '@.mode' 2>/dev/null
}

set_proxy_mode() {
    requested="$1"
    case "$requested" in
        rule) label="规则" ;;
        global) label="全局" ;;
        direct) label="直连" ;;
        *) result 0 "不支持的代理模式"; return ;;
    esac
    service_running && namespace_present || {
        result 0 "Mihomo 未运行"
        return
    }
    acquire_lock || {
        result 0 "另一个管理操作正在执行"
        return
    }
    if ! controller_request PATCH /configs "{\"mode\":\"$requested\"}" >"$ACTION_LOG" 2>&1; then
        result 0 "代理模式切换失败"
        return
    fi
    actual="$(controller_mode 2>/dev/null || true)"
    if [ "$actual" = "$requested" ]; then
        result 1 "已切换到${label}模式"
    else
        result 0 "控制接口未应用新的代理模式"
    fi
}

status_json() {
    running=0
    namespace=0
    enabled=0
    transparent=0
    dhcp=0
    dhcp_desired=0
    ipv6_disabled=0
    controller=0
    manual_stop=0
    start_pending=0
    proxy_mode=unknown
    service_running && running=1
    namespace_present && namespace=1
    service_enabled && enabled=1
    tun_enabled && transparent=1
    dhcp_actual && dhcp=1
    [ -f "$DHCP_ENABLED_FILE" ] && dhcp_desired=1
    [ -f "$MANUAL_STOP_FILE" ] && manual_stop=1
    lan_ipv6_disabled && ipv6_disabled=1

    if [ "$running" -eq 0 ] && [ "$enabled" -eq 1 ] && [ "$manual_stop" -eq 0 ]; then
        start_pending=1
    fi

    if [ "$namespace" -eq 1 ]; then
        ip netns exec "$NS" netstat -lnt 2>/dev/null | grep -q ':9090 ' && controller=1
    fi
    if [ "$controller" -eq 1 ]; then
        proxy_mode="$(controller_mode 2>/dev/null || echo unknown)"
    fi

    dhcp_start="$(uci -q get dhcp.lan.start 2>/dev/null || echo 0)"
    dhcp_limit="$(uci -q get dhcp.lan.limit 2>/dev/null || echo 0)"
    case "$dhcp_start:$dhcp_limit" in
        *[!0-9:]*|:*) dhcp_end=0 ;;
        *) dhcp_end=$((dhcp_start + dhcp_limit - 1)) ;;
    esac
    mode="$(uci -q get zwrt_router.network.opms_wan_mode 2>/dev/null || echo unknown)"
    version="$($BASE/mihomo -v 2>/dev/null | sed -n '1p' | cut -c1-120)"
    rss_kb=0
    pid=""
    if [ "$running" -eq 1 ]; then
        pid="$(cat "$PIDFILE" 2>/dev/null)"
        rss_kb="$(awk '/^VmRSS:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null || echo 0)"
    fi

    json_init
    json_add_boolean ok 1
    json_add_boolean service_running "$running"
    json_add_boolean service_enabled "$enabled"
    json_add_boolean namespace_present "$namespace"
    json_add_boolean autostart_enabled "$enabled"
    json_add_boolean manual_stop "$manual_stop"
    json_add_boolean start_pending "$start_pending"
    json_add_boolean transparent_enabled "$transparent"
    json_add_boolean dhcp_enabled "$dhcp"
    json_add_boolean dhcp_desired "$dhcp_desired"
    json_add_boolean lan_ipv6_disabled "$ipv6_disabled"
    json_add_boolean controller_listening "$controller"
    json_add_string namespace_ip "$NS_IP"
    json_add_string controller_url "http://$NS_IP:9090/ui/"
    json_add_string wan_mode "$mode"
    json_add_string proxy_mode "$proxy_mode"
    json_add_int dhcp_start "$dhcp_start"
    json_add_int dhcp_end "$dhcp_end"
    json_add_string version "$version"
    json_add_string pid "$pid"
    json_add_int rss_kb "${rss_kb:-0}"
    json_dump
}

validate_config() {
    file="$1"
    validate_config_with_core "$CORE" "$file"
}

validate_config_with_core() {
    core="$1"
    file="$2"
    if namespace_present; then
        ip netns exec "$NS" "$core" -t -d "$BASE" -f "$file" >"$CHECK_LOG" 2>&1
    else
        "$core" -t -d "$BASE" -f "$file" >"$CHECK_LOG" 2>&1
    fi
}

core_version_tag() {
    "$1" -v 2>/dev/null | sed -n '1s/.* \(v[0-9][0-9.]*\) .*/\1/p'
}

compare_versions() {
    latest="${1#v}"
    current="${2#v}"
    awk -v latest="$latest" -v current="$current" 'BEGIN {
        split(latest, a, ".")
        split(current, b, ".")
        for (i=1; i<=3; i++) {
            av=a[i]+0
            bv=b[i]+0
            if (av > bv) { print 1; exit }
            if (av < bv) { print -1; exit }
        }
        print 0
    }'
}

fetch_latest_release() {
    release_file="$1"
    # Use the same working route as core downloads. Two bounded attempts fit
    # within the page's 25-second timeout and rpcd's 30-second execution limit.
    if ! download_release_file "$release_file" "$RELEASE_API" 10 4; then
        return 1
    fi
    RELEASE_TAG="$(jsonfilter -i "$release_file" -e '@.tag_name' 2>/dev/null)"
    printf '%s' "$RELEASE_TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || return 1
    RELEASE_NAME="mihomo-linux-arm64-$RELEASE_TAG.gz"
    RELEASE_ASSET_NAME="$(jsonfilter -i "$release_file" -e "@.assets[@.name=\"$RELEASE_NAME\"].name" 2>/dev/null)"
    RELEASE_URL="$(jsonfilter -i "$release_file" -e "@.assets[@.name=\"$RELEASE_NAME\"].browser_download_url" 2>/dev/null)"
    RELEASE_DIGEST="$(jsonfilter -i "$release_file" -e "@.assets[@.name=\"$RELEASE_NAME\"].digest" 2>/dev/null)"
    RELEASE_SIZE="$(jsonfilter -i "$release_file" -e "@.assets[@.name=\"$RELEASE_NAME\"].size" 2>/dev/null)"
    [ "$RELEASE_ASSET_NAME" = "$RELEASE_NAME" ] || return 1
    case "$RELEASE_URL" in
        https://github.com/MetaCubeX/mihomo/releases/download/*/"$RELEASE_NAME") ;;
        *) return 1 ;;
    esac
    case "$RELEASE_DIGEST" in
        sha256:????????????????????????????????????????????????????????????????) ;;
        *) return 1 ;;
    esac
    case "$RELEASE_SIZE" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$RELEASE_SIZE" -gt 0 ]
}

local_proxy_url() {
    proxy_port="$(awk '
        /^mixed-port:[[:space:]]*/ {
            value=$0
            sub(/^mixed-port:[[:space:]]*/, "", value)
            sub(/[[:space:]#].*$/, "", value)
            gsub(/[^0-9]/, "", value)
            print value
            exit
        }
    ' "$CONFIG" 2>/dev/null)"
    case "$proxy_port" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$proxy_port" -ge 1 ] && [ "$proxy_port" -le 65535 ] || return 1
    printf 'http://%s:%s' "$NS_IP" "$proxy_port"
}

download_release_file() {
    output="$1"
    url="$2"
    download_max_time="${3:-300}"
    download_connect_timeout="${4:-15}"
    proxy_url=""
    if service_running && namespace_present; then
        proxy_url="$(local_proxy_url 2>/dev/null || true)"
    fi
    if [ -n "$proxy_url" ]; then
        echo "通过本机 Mihomo 代理下载" >>"$ACTION_LOG"
        if curl -fsSL --proxy "$proxy_url" --connect-timeout "$download_connect_timeout" --max-time "$download_max_time" \
            -A MU5252-Mihomo-Manager -o "$output" "$url" >>"$ACTION_LOG" 2>&1; then
            return 0
        fi
        rm -f "$output"
        echo "代理下载失败，改用设备直连" >>"$ACTION_LOG"
    fi
    curl -fsSL --connect-timeout "$download_connect_timeout" --max-time "$download_max_time" \
        -A MU5252-Mihomo-Manager -o "$output" "$url" >>"$ACTION_LOG" 2>&1
}

core_update_check_json() {
    acquire_lock || { result 0 "另一个管理操作正在执行，请稍后重试"; return; }
    release_file="$BASE/run/mihomo.release.$$"
    TEMP_FILES="$release_file"
    : >"$ACTION_LOG"
    if ! fetch_latest_release "$release_file"; then
        result 0 "无法读取官方版本信息"
        return
    fi
    current_tag="$(core_version_tag "$CORE")"
    relation=1
    [ -n "$current_tag" ] && relation="$(compare_versions "$RELEASE_TAG" "$current_tag")"
    update_available=0
    message="当前已是最新版本"
    if [ "$relation" -gt 0 ]; then
        update_available=1
        message="发现新版本 $RELEASE_TAG"
    elif [ "$relation" -lt 0 ]; then
        message="当前版本高于官方最新版本"
    fi
    current_line="$($CORE -v 2>/dev/null | sed -n '1p' | cut -c1-160)"
    json_init
    json_add_boolean ok 1
    json_add_string message "$message"
    json_add_string current_version "$current_tag"
    json_add_string current_line "$current_line"
    json_add_string latest_version "$RELEASE_TAG"
    json_add_boolean update_available "$update_available"
    json_add_string asset_name "$RELEASE_NAME"
    json_add_int asset_size "$RELEASE_SIZE"
    json_dump
}

core_update_apply() {
    acquire_lock || { result 0 "另一个管理操作正在执行，请稍后重试"; return; }
    release_file="$BASE/run/mihomo.release.$$"
    package_file="$BASE/run/mihomo.update.$$.gz"
    candidate="$BASE/run/mihomo.update.$$"
    rollback="$BASE/run/mihomo.rollback.$$"
    TEMP_FILES="$release_file $package_file $candidate $rollback"
    : >"$ACTION_LOG"

    if ! fetch_latest_release "$release_file"; then
        result 0 "无法读取官方版本信息"
        return
    fi
    current_tag="$(core_version_tag "$CORE")"
    relation=1
    [ -n "$current_tag" ] && relation="$(compare_versions "$RELEASE_TAG" "$current_tag")"
    if [ "$relation" -le 0 ]; then
        result 1 "当前核心不需要更新"
        return
    fi

    echo "下载 $RELEASE_NAME" >>"$ACTION_LOG"
    if ! download_release_file "$package_file" "$RELEASE_URL"; then
        result 0 "核心下载失败，请查看日志"
        return
    fi
    downloaded_size="$(wc -c <"$package_file" 2>/dev/null | tr -d ' ')"
    if [ "$downloaded_size" != "$RELEASE_SIZE" ]; then
        echo "下载大小不匹配" >>"$ACTION_LOG"
        result 0 "下载文件大小不匹配"
        return
    fi
    expected_digest="${RELEASE_DIGEST#sha256:}"
    actual_digest="$(sha256sum "$package_file" 2>/dev/null | awk '{print $1}')"
    if [ "$actual_digest" != "$expected_digest" ]; then
        echo "SHA-256 校验失败" >>"$ACTION_LOG"
        result 0 "核心 SHA-256 校验失败"
        return
    fi
    if ! gzip -dc "$package_file" >"$candidate" 2>>"$ACTION_LOG"; then
        result 0 "核心解压失败"
        return
    fi
    chmod 0755 "$candidate"
    new_tag="$(core_version_tag "$candidate")"
    if [ "$new_tag" != "$RELEASE_TAG" ]; then
        echo "二进制版本不匹配" >>"$ACTION_LOG"
        result 0 "下载核心的版本不匹配"
        return
    fi
    if ! validate_config_with_core "$candidate" "$CONFIG"; then
        tail -n 60 "$CHECK_LOG" >>"$ACTION_LOG" 2>/dev/null || true
        result 0 "新核心无法通过当前配置检查"
        return
    fi

    if ! ln "$CORE" "$rollback"; then
        result 0 "无法建立临时回滚链接"
        return
    fi
    was_running=false
    service_running && was_running=true
    if ! mv "$candidate" "$CORE"; then
        result 0 "替换核心失败"
        return
    fi
    chmod 0755 "$CORE"
    sync
    if [ "$was_running" = true ]; then
        if ! "$SERVICE" restart >>"$ACTION_LOG" 2>&1; then
            echo "新核心首次启动失败，重试一次" >>"$ACTION_LOG"
            sleep 1
            if ! "$SERVICE" restart >>"$ACTION_LOG" 2>&1; then
                mv -f "$rollback" "$CORE"
                chmod 0755 "$CORE"
                "$SERVICE" restart >>"$ACTION_LOG" 2>&1 || true
                result 0 "新核心启动失败，原核心已恢复"
                return
            fi
        fi
    fi
    rm -f "$rollback"
    if [ "$was_running" = true ]; then
        result 1 "核心已更新到 $RELEASE_TAG，Mihomo 已重启"
    else
        result 1 "核心已更新到 $RELEASE_TAG"
    fi
}

config_get_json() {
    if [ ! -f "$CONFIG" ]; then
        result 0 "配置文件不存在"
        return
    fi
    size="$(wc -c <"$CONFIG" 2>/dev/null | tr -d ' ')"
    case "$size" in
        ''|*[!0-9]*) result 0 "读取配置失败"; return ;;
    esac
    if [ "$size" -gt "$MAX_CONFIG_BYTES" ]; then
        result 0 "配置超过 1 MB"
        return
    fi
    content="$(cat "$CONFIG"; printf x)"
    content="${content%x}"
    checksum="$(sha256sum "$CONFIG" 2>/dev/null | awk '{print $1}')"
    json_init
    json_add_boolean ok 1
    json_add_string content "$content"
    json_add_string sha256 "$checksum"
    json_add_int size "${size:-0}"
    json_dump
}

read_config_candidate() {
    candidate="$1"
    mkdir -p "$BASE/run"
    cat >"$candidate" || return 1
    size="$(wc -c <"$candidate" 2>/dev/null | tr -d ' ')"
    case "$size" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$size" -gt 0 ] && [ "$size" -le "$MAX_CONFIG_BYTES" ]
}

config_validate_stdin() {
    acquire_lock || { result 0 "另一个管理操作正在执行，请稍后重试"; return; }
    candidate="$BASE/run/config.manager-check.$$"
    TEMP_FILES="$candidate"
    if ! read_config_candidate "$candidate"; then
        rm -f "$candidate"
        result 0 "配置为空、过大或读取失败"
        return
    fi
    if validate_config "$candidate"; then
        details="$(tail -n 60 "$CHECK_LOG" 2>/dev/null)"
        rm -f "$candidate"
        result_with_details 1 "配置检查通过" "$details"
    else
        details="$(tail -n 60 "$CHECK_LOG" 2>/dev/null)"
        rm -f "$candidate"
        result_with_details 0 "配置检查失败" "$details"
    fi
}

config_apply_stdin() {
    acquire_lock || { result 0 "另一个管理操作正在执行，请稍后重试"; return; }
    candidate="$BASE/run/config.manager-new.$$"
    rollback="/tmp/mihomo-config-manager-rollback.$$"
    TEMP_FILES="$candidate $rollback"
    if ! read_config_candidate "$candidate"; then
        rm -f "$candidate"
        result 0 "配置为空、过大或读取失败"
        return
    fi
    if ! validate_config "$candidate"; then
        details="$(tail -n 60 "$CHECK_LOG" 2>/dev/null)"
        rm -f "$candidate"
        result_with_details 0 "配置检查失败，未保存" "$details"
        return
    fi
    cp -p "$CONFIG" "$rollback" || {
        rm -f "$candidate"
        result 0 "无法建立临时回滚副本"
        return
    }
    was_running=false
    service_running && was_running=true
    chmod 0600 "$candidate"
    if ! mv "$candidate" "$CONFIG"; then
        rm -f "$candidate" "$rollback"
        result 0 "保存配置失败"
        return
    fi
    chmod 0600 "$CONFIG"
    sync
    if [ "$was_running" = true ]; then
        if ! "$SERVICE" restart >"$ACTION_LOG" 2>&1; then
            cp -p "$rollback" "$CONFIG"
            chmod 0600 "$CONFIG"
            "$SERVICE" restart >>"$ACTION_LOG" 2>&1 || true
            rm -f "$rollback"
            result 0 "Mihomo 重启失败，原配置已恢复"
            return
        fi
    fi
    rm -f "$rollback"
    if [ "$was_running" = true ]; then
        result 1 "配置已应用，Mihomo 已重启"
    else
        result 1 "配置已保存"
    fi
}

write_tun_setting() {
    enabled="$1"
    output="$2"
    awk -v enabled="$enabled" '
        BEGIN { in_tun=0; changed=0 }
        /^tun:[[:space:]]*$/ { in_tun=1; print; next }
        in_tun && /^[^[:space:]]/ { in_tun=0 }
        in_tun && /^[[:space:]]+enable:[[:space:]]*/ && !changed {
            match($0, /^[[:space:]]*/)
            indent=substr($0, 1, RLENGTH)
            print indent "enable: " enabled
            changed=1
            next
        }
        { print }
        END { if (!changed) exit 42 }
    ' "$CONFIG" >"$output"
}

set_transparent() {
    target="$1"
    acquire_lock || { result 0 "另一个管理操作正在执行，请稍后重试"; return; }

    current=false
    tun_enabled && current=true
    [ "$current" = "$target" ] && { result 1 "透明代理状态没有变化"; return; }

    if [ "$target" = false ]; then
        "$SERVICE" disable-dhcp-gateway >"$ACTION_LOG" 2>&1 || {
            result 0 "关闭 DHCP 下发失败，未修改透明代理"
            return
        }
    fi

    candidate="$BASE/run/config.manager-new.$$"
    rollback=/tmp/mihomo-config-manager-rollback.$$
    TEMP_FILES="$candidate $rollback"
    mkdir -p "$BASE/run"
    if ! write_tun_setting "$target" "$candidate"; then
        rm -f "$candidate"
        result 0 "找不到配置中的 tun.enable，未做修改"
        return
    fi
    if ! validate_config "$candidate"; then
        rm -f "$candidate"
        result 0 "修改后的配置未通过 Mihomo 检查"
        return
    fi

    cp -p "$CONFIG" "$rollback" || {
        rm -f "$candidate"
        result 0 "无法建立临时回滚副本"
        return
    }
    mv "$candidate" "$CONFIG"
    if ! "$SERVICE" restart >"$ACTION_LOG" 2>&1; then
        cp -p "$rollback" "$CONFIG"
        "$SERVICE" restart >>"$ACTION_LOG" 2>&1 || true
        rm -f "$rollback"
        result 0 "Mihomo 重启失败，配置已恢复"
        return
    fi
    rm -f "$rollback"
    if [ "$target" = true ]; then
        result 1 "透明代理能力已开启；需要时再开启 DHCP 下发"
    else
        result 1 "透明代理和 DHCP 下发已关闭"
    fi
}

set_dhcp() {
    target="$1"
    acquire_lock || { result 0 "另一个管理操作正在执行，请稍后重试"; return; }
    if [ "$target" = true ]; then
        if ! service_running || ! tun_enabled; then
            result 0 "请先启动 Mihomo 并开启透明代理"
            return
        fi
        if "$SERVICE" enable-dhcp-gateway >"$ACTION_LOG" 2>&1; then
            result 1 "DHCP 已下发 Mihomo 网关和 DNS"
        else
            result 0 "DHCP 下发失败"
        fi
    else
        if "$SERVICE" disable-dhcp-gateway >"$ACTION_LOG" 2>&1; then
            result 1 "DHCP 已恢复为设备默认网关和 DNS"
        else
            result 0 "恢复 DHCP 失败"
        fi
    fi
}

set_lan_ipv6() {
    disabled="$1"
    acquire_lock || { result 0 "另一个管理操作正在执行，请稍后重试"; return; }
    value=0
    [ "$disabled" = true ] && value=1
    response="$(ubus call zwrt_router.api router_set_disable_lan_ipv6 "{\"disable_lan_ipv6\":$value}" 2>/dev/null || true)"
    if printf '%s' "$response" | jsonfilter -e '@.result' 2>/dev/null | grep -qx 0; then
        if [ "$disabled" = true ]; then
            result 1 "LAN IPv6 已关闭"
        else
            result 1 "LAN IPv6 已恢复"
        fi
    else
        result 0 "修改 LAN IPv6 状态失败"
    fi
}

set_service_enabled() {
    target="$1"
    acquire_lock || { result 0 "另一个管理操作正在执行，请稍后重试"; return; }
    : >"$ACTION_LOG"
    if [ "$target" = true ]; then
        if ! /etc/init.d/mihomo-netns enable >>"$ACTION_LOG" 2>&1; then
            result 0 "启用 Mihomo 服务失败"
            return
        fi
        rm -f "$MANUAL_STOP_FILE"
        if service_supervisor_running; then
            if ! service_running; then
                /etc/init.d/mihomo-netns restart >>"$ACTION_LOG" 2>&1 || true
            fi
        elif ! /etc/init.d/mihomo-netns start >>"$ACTION_LOG" 2>&1; then
            /etc/init.d/mihomo-netns disable >>"$ACTION_LOG" 2>&1 || true
            result 0 "启动 Mihomo 服务监控失败，已恢复禁用状态"
            return
        fi
        if ! service_enabled || ! service_supervisor_running; then
            result 0 "Mihomo 服务未完整启用，请查看日志"
        elif service_running; then
            result 1 "Mihomo 服务已启用并运行"
        else
            result 1 "Mihomo 服务已启用，正在等待系统就绪"
        fi
    elif [ "$target" = false ]; then
        if ! /etc/init.d/mihomo-netns disable >>"$ACTION_LOG" 2>&1; then
            result 0 "禁用 Mihomo 服务失败"
            return
        fi
        if service_supervisor_running; then
            /etc/init.d/mihomo-netns stop >>"$ACTION_LOG" 2>&1 || true
        else
            "$SERVICE" stop >>"$ACTION_LOG" 2>&1 || true
        fi
        if service_running || namespace_present; then
            result 0 "服务已设为禁用，但当前进程未完整停止"
        else
            result 1 "Mihomo 服务已禁用；DHCP 当前下发已撤销，原设置已保留"
        fi
    else
        result 0 "服务状态参数无效"
    fi
}

service_action() {
    action="$1"
    acquire_lock || { result 0 "另一个管理操作正在执行，请稍后重试"; return; }
    case "$action" in
        restart)
            if ! service_enabled; then
                result 0 "Mihomo 服务已禁用，请先启用服务"
                return
            fi
            rm -f "$MANUAL_STOP_FILE"
            if ! /etc/init.d/mihomo-netns restart >"$ACTION_LOG" 2>&1; then
                result 0 "Mihomo 重启失败，请查看日志"
                return
            fi
            attempts=0
            while ! service_running && [ "$attempts" -lt 10 ]; do
                attempts=$((attempts + 1))
                sleep 1
            done
            if service_running; then
                result 1 "Mihomo 已重启"
            else
                result 1 "Mihomo 服务正在重启"
            fi
            ;;
    esac
}

logs_json() {
    lines="${1:-120}"
    case "$lines" in
        ''|*[!0-9]*) lines=120 ;;
    esac
    [ "$lines" -gt 200 ] && lines=200
    log="$(tail -n "$lines" /tmp/mihomo-netns.log 2>/dev/null)"
    action="$(tail -n 40 "$ACTION_LOG" 2>/dev/null)"
    json_init
    json_add_boolean ok 1
    json_add_string log "$log"
    json_add_string action_log "$action"
    json_dump
}

case "${1:-status}" in
    status) status_json ;;
    service-set) set_service_enabled "${2:-false}" ;;
    service-start) set_service_enabled true ;;
    service-stop) set_service_enabled false ;;
    service-restart) service_action restart ;;
    autostart-set) set_service_enabled "${2:-false}" ;;
    transparent-set) set_transparent "${2:-false}" ;;
    dhcp-set) set_dhcp "${2:-false}" ;;
    lan-ipv6-set) set_lan_ipv6 "${2:-false}" ;;
    proxy-mode-set) set_proxy_mode "${2:-}" ;;
    config-get) config_get_json ;;
    config-validate) config_validate_stdin ;;
    config-apply) config_apply_stdin ;;
    core-update-check) core_update_check_json ;;
    core-update-apply) core_update_apply ;;
    config-check)
        if validate_config "$CONFIG"; then result 1 "当前配置检查通过"; else result 0 "当前配置检查失败"; fi
        ;;
    logs) logs_json "${2:-120}" ;;
    *) result 0 "不支持的管理操作" ;;
esac
