#!/bin/sh
# HTTP Date 校时 + 持续守卫。
# 背景见 docs/TIMEZONE-FIX-2026-09-08.md：B20 原厂 ntpclient/NITZ 会把 UTC+8
# 写进系统时钟，VMess 因此全部失败。timekeeper 的 UTC 补丁负责从源头止血；
# 本脚本是独立安全网——尤其在「时钟已偏 → 国内代理挂 → 直连取不到 Date」
# 的死锁下，通过国外节点（mixed 7890）仍能取到 HTTP Date 并回拨。

# Defensive: pin all date parsing/logging in this script to UTC.
# busybox `date -d` interprets the HTTP Date header (GMT) relative to the
# current TZ. If the system TZ is set to CST-8 (e.g. by the timekeeper
# component), parsing yields epoch - 28800, and the clock ends up 8 hours
# slow. Pinning TZ=UTC here makes the script independent of the system TZ.
export TZ=UTC
LOG_FILE=/tmp/fix-time-http.log
LOCK_FILE=/tmp/fix-time-http.lock
PROXY="${FIX_TIME_HTTP_PROXY:-http://127.0.0.1:7890}"

# Boot-time pin: keep user-space SNTP off (any SIM slot / uplink). Its UTC+8
# write is the recurring clock corruption; manual mode disables it.
uci set zwrt_zte_sntp.settings.time_set_mode='manual' 2>/dev/null
uci commit zwrt_zte_sntp 2>/dev/null

if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    echo "$(date) already running" >>"$LOG_FILE"
    exit 0
fi

cleanup() {
    rmdir "$LOCK_FILE" 2>/dev/null
}
trap cleanup EXIT INT TERM

# Truncate log if it grows without bound on tmpfs.
if [ -f "$LOG_FILE" ]; then
    sz="$(wc -c <"$LOG_FILE" 2>/dev/null || echo 0)"
    case "$sz" in (*[!0-9]*|'') sz=0 ;; esac
    [ "$sz" -gt 2097152 ] && : >"$LOG_FILE"
fi

parse_date_header() {
    # stdin: HTTP response headers
    local header timestamp
    header="$(grep -i '^date:' | head -1 | sed 's/^[Dd]ate: //' | tr -d '\r\n')"
    [ -z "$header" ] && return 1
    timestamp="$(date -D '%a, %d %b %Y %T' -d "$header" +%s 2>/dev/null)"
    [ -z "$timestamp" ] && return 1
    if [ "$timestamp" -gt 1700000000 ] && [ "$timestamp" -lt 2200000000 ]; then
        echo "$timestamp"
        return 0
    fi
    return 1
}

fetch_one() {
    # $1=url  $2=optional curl proxy arg (empty = direct)
    local url="$1" proxy_arg="$2" header_blob
    if [ -n "$proxy_arg" ]; then
        header_blob="$(curl -sI --max-time 5 -x "$proxy_arg" "$url" 2>/dev/null)" || return 1
    else
        header_blob="$(curl -sI --max-time 5 "$url" 2>/dev/null)" || return 1
    fi
    printf '%s\n' "$header_blob" | parse_date_header
}

get_http_time() {
    local ts host

    # Phase A: direct — works early boot / when clock already correct.
    for host in \
        http://www.baidu.com/ \
        http://www.aliyun.com/ \
        http://www.qq.com/ \
        http://connectivitycheck.gstatic.com/generate_204
    do
        ts="$(fetch_one "$host" "")" || continue
        [ -n "$ts" ] || continue
        echo "$ts"
        return 0
    done

    # Phase B: via mixed inbound — foreign nodes still work when VMess
    # domestic is dead due to +8h skew (the deadlock this script breaks).
    if [ -n "$PROXY" ]; then
        for host in \
            http://www.google.com/ \
            http://www.cloudflare.com/ \
            http://connectivitycheck.gstatic.com/generate_204 \
            http://www.baidu.com/
        do
            ts="$(fetch_one "$host" "$PROXY")" || continue
            [ -n "$ts" ] || continue
            echo "$ts"
            return 0
        done
    fi

    return 1
}

apply_time() {
    local ts="$1" reason="$2"
    date -s "@$ts" >>"$LOG_FILE" 2>&1
    /sbin/hwclock -w -u -f /dev/rtc0 2>/dev/null
    logger -t fix-time-http "$reason: $ts"
    echo "$(date) $reason: $ts" >>"$LOG_FILE"
}

MAX_SKEW=60
CHECK_INTERVAL=60

echo "$(date) start waiting for HTTP time" >>"$LOG_FILE"

# Phase 1: initial sync (wait up to 450s)
for _i in $(seq 1 90); do
    ts="$(get_http_time)"
    if [ -n "$ts" ]; then
        apply_time "$ts" "synced"
        break
    fi
    sleep 5
done

# Phase 2: persistent guard against late NITZ/time_daemon re-corruption
echo "$(date) entering persistent guard (every ${CHECK_INTERVAL}s)" >>"$LOG_FILE"
while :; do
    sleep "$CHECK_INTERVAL"
    cur="$(date +%s)"
    ts="$(get_http_time)"
    if [ -n "$ts" ]; then
        diff=$((cur - ts))
        if [ "$diff" -gt "$MAX_SKEW" ] || [ "$diff" -lt "-$MAX_SKEW" ]; then
            apply_time "$ts" "re-corrected skew=${diff}s ->"
        fi
    else
        echo "$(date) guard: HTTP Date unreachable (direct+proxy)" >>"$LOG_FILE"
    fi
done
