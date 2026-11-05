#!/bin/sh
# install-rc-local-hook.sh — 给 topflow-ota-block 增加 rc.local 开机拉起钩子
# 背景：本设备 rcS 不执行 overlay 新增的 init.d 服务，项目统一用 rc.local 拉起。
# 特性：幂等（有 marker 则跳过）、原子写（awk 生成 .new 后 sh -n 校验再覆盖）、自动备份。
# 回滚：cp /data/topflow-ota-block/backup/rc.local.bak-pre-otablock /etc/rc.local

RC=/etc/rc.local
B=/data/topflow-ota-block/backup

mkdir -p "$B"
[ -f "$B/rc.local.bak-pre-otablock" ] || cp "$RC" "$B/rc.local.bak-pre-otablock"

if grep -qF "topflow-ota-block" "$RC"; then
	echo "marker already exists, skip"
	exit 0
fi

awk '
BEGIN { p = 0 }
/^exit 0[[:space:]]*$/ && p == 0 {
	print "# Start the TopFlow OTA block keeper."
	print "if [ -x /etc/init.d/topflow-ota-block ] &&"
	print "   /etc/init.d/topflow-ota-block enabled >/dev/null 2>&1; then"
	print "    /etc/init.d/topflow-ota-block start"
	print "fi"
	print "# End the TopFlow OTA block keeper."
	print ""
	p = 1
}
{ print }
' "$RC" > "$RC.new" || exit 1

if ! grep -qF "topflow-ota-block" "$RC.new"; then
	echo "insert failed (no exit 0 found?)"
	rm -f "$RC.new"
	exit 1
fi

sh -n "$RC.new" || { echo "syntax check failed"; rm -f "$RC.new"; exit 1; }
cat "$RC.new" > "$RC" && rm -f "$RC.new"
chmod 755 "$RC"
echo "rc.local hook installed"
