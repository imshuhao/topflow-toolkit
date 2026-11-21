#!/bin/sh

CONTROL_CENTER_DIR=/data/touchscreen-control-center
HOOK="$CONTROL_CENTER_DIR/touchui-hook.so"
SUPERVISOR_PID_FILE=/tmp/touchscreen-control-center-supervisor.pid
UI_LOG=/tmp/touchscreen-control-center-ui.log
# UI 日志写 tmpfs，不限幅会吃掉内存（实测曾 >150MB）
UI_LOG_MAX_BYTES=2097152

# 启动互斥：boot 与人工 start 并发只留一个（双注入 UI 会抢 QPIC pipe，M14）。
# 注意：supervisor nohup 行必须 9>&-，防锁 fd 被常驻进程继承。
exec 9>/tmp/touchscreen-control-center-start.lock
flock -n 9 || exit 0

rotate_ui_log() {
    [ -f "$UI_LOG" ] || return 0
    sz="$(wc -c <"$UI_LOG" 2>/dev/null || echo 0)"
    case "$sz" in (*[!0-9]*|'') return 0 ;; esac
    [ "$sz" -gt "$UI_LOG_MAX_BYTES" ] || return 0
    # O_APPEND 下原地 truncate，可立刻释放 tmpfs
    : >"$UI_LOG"
    echo "ui-log-truncated $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" >>"$UI_LOG"
}

stop_ui_cleanly() {
    ATTEMPTS=0
    killall zte_topsw_devui 2>/dev/null
    while [ -n "$(pidof zte_topsw_devui)" ] && [ "$ATTEMPTS" -lt 5 ]; do
        ATTEMPTS=$((ATTEMPTS + 1))
        sleep 1
    done
    if [ -n "$(pidof zte_topsw_devui)" ]; then
        killall -9 zte_topsw_devui 2>/dev/null
        sleep 2
    fi
    # Give the QPIC driver time to finish disabling the old display pipe
    # before another process attempts to claim it.
    sleep 2
}

rollback() {
    if [ -n "$SUPERVISOR_PID" ]; then
        kill "$SUPERVISOR_PID" 2>/dev/null
    fi
    rm -f "$SUPERVISOR_PID_FILE"
    stop_ui_cleanly
    /etc/init.d/zte_topsw_devui start
}

READY=0
ATTEMPT=0
while [ "$ATTEMPT" -lt 30 ]; do
    if [ -r "$HOOK" ] && [ -e /dev/input/event5 ] && [ -e /dev/dri/card0 ] && \
       [ -n "$(pidof zte_topsw_devui)" ]; then
        READY=1
        break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    sleep 1
done
if [ "$READY" -ne 1 ]; then
    echo "preflight failed after ${ATTEMPT}s; keeping stock UI"
    exit 1
fi

CURRENT_PIDS="$(pidof zte_topsw_devui)"
set -- $CURRENT_PIDS
if [ "$#" -eq 1 ] && grep -q "$HOOK" "/proc/$1/maps" 2>/dev/null && \
   [ -r "$SUPERVISOR_PID_FILE" ]; then
    CURRENT_SUPERVISOR="$(cat "$SUPERVISOR_PID_FILE")"
    if kill -0 "$CURRENT_SUPERVISOR" 2>/dev/null; then
        echo "touchscreen control center already running: $1"
        exit 0
    fi
fi

if [ -r "$SUPERVISOR_PID_FILE" ]; then
    OLD_SUPERVISOR="$(cat "$SUPERVISOR_PID_FILE")"
    case "$OLD_SUPERVISOR" in
        (*[!0-9]*|'') ;;
        (*) kill "$OLD_SUPERVISOR" 2>/dev/null ;;
    esac
fi
# 等旧 supervisor 真正退出（≤5s）：否则其 fallback（/etc/init.d/zte_topsw_devui start）
# 会与新注入 UI 并发双起（M15）；TERM 不死则补 KILL。
if [ -n "${OLD_SUPERVISOR:-}" ] && kill -0 "$OLD_SUPERVISOR" 2>/dev/null; then
    w=0
    while kill -0 "$OLD_SUPERVISOR" 2>/dev/null && [ "$w" -lt 10 ]; do
        sleep 0.5 2>/dev/null || sleep 1
        w=$((w + 1))
    done
    kill -9 "$OLD_SUPERVISOR" 2>/dev/null || true
fi
rm -f "$SUPERVISOR_PID_FILE"

rotate_ui_log

# Remove only the running procd instance.  Calling the vendor stop routine
# would also unload the Sitronix touchscreen driver.
ubus call service delete '{"name":"zte_topsw_devui"}' >/dev/null 2>&1
stop_ui_cleanly

# Keep the injected UI in the foreground of a detached supervisor.  If the UI
# ever exits, this same process immediately restores the vendor procd service.
# 日志用 O_APPEND + 周期原地截断，避免 tmpfs 被撑满。
nohup sh -c '
    LOG="$1"
    HOOK_SO="$2"
    MAX=2097152
    rotate() {
        [ -f "$LOG" ] || return 0
        sz=$(wc -c <"$LOG" 2>/dev/null || echo 0)
        case "$sz" in (*[!0-9]*|"") return 0 ;; esac
        [ "$sz" -gt "$MAX" ] || return 0
        : >"$LOG"
        echo "ui-log-truncated $(date -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)" >>"$LOG"
    }
    rotate
    (
        while :; do
            sleep 300
            rotate
        done
    ) &
    ROTATE_PID=$!
    # 被管理性 kill（TERM/INT）时带走轮转子壳，防泄漏（M16）；
    # 用命名函数规避外层单引号内嵌套引号断裂
    on_term() { kill "$ROTATE_PID" 2>/dev/null; exit 0; }
    trap on_term TERM INT
    env LD_PRELOAD="$HOOK_SO" TZ=CST-8 /usr/bin/zte_topsw_devui
    RC=$?
    kill "$ROTATE_PID" 2>/dev/null
    /etc/init.d/zte_topsw_devui start
    exit "$RC"
' sh "$UI_LOG" "$HOOK" </dev/null >>"$UI_LOG" 2>&1 9>&- &
SUPERVISOR_PID=$!
echo "$SUPERVISOR_PID" >"$SUPERVISOR_PID_FILE"
sleep 5

PIDS="$(pidof zte_topsw_devui)"
set -- $PIDS
UI_PID="$1"
if [ "$#" -ne 1 ] || ! kill -0 "$UI_PID" 2>/dev/null || \
   ! grep -q "$HOOK" "/proc/$UI_PID/maps" 2>/dev/null; then
    echo "injected UI failed; restoring vendor service"
    rollback
    exit 1
fi

echo "touchscreen control center running: $UI_PID (supervisor: $SUPERVISOR_PID)"
exit 0
