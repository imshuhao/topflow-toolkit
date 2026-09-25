#!/bin/sh
umask 077
BASE=/tmp/luci-admin-action
trap 'rmdir "$BASE/lock" 2>/dev/null' EXIT
if [ "$1" = mihomo-manager ]; then
 /data/mihomo-manager/mihomo-manager.sh "$2" > "$BASE/action.log" 2>&1
 result=$?
 [ "$(jsonfilter -i "$BASE/action.log" -e '@.ok' 2>/dev/null)" = true ] || result=1
else
 /etc/init.d/"$1" "$2" > "$BASE/action.log" 2>&1
 result=$?
fi
if [ "$result" -eq 0 ]; then
 printf '{"state":"done","ok":true}\n' > "$BASE/state.new"
else
 printf '{"state":"failed","ok":false,"error":"服务操作失败，请检查系统日志"}\n' > "$BASE/state.new"
fi
mv "$BASE/state.new" "$BASE/state.json"
exit "$result"
