#!/bin/sh
# ============================================================
# topflow-ota-block — 冻结官方 OTA 升级 + 屏蔽相关上报域名
# 2026-10-14 上线；目标清单 = 用户 2026-10-10 清单 + zte_dm 实测全集
#
# 用法: sh /data/topflow-ota-block/ota-block.sh apply|keeper|status|revert
#
# 原理:
#   ① /etc/hosts : 目标域名 -> 127.0.0.1（设备自身解析即失败）
#   ② iptables/ip6tables OUTPUT 第 1 链（独立链 TOPFLOW_OTA_BLOCK4/6）:
#        - TCP 443/8883 payload 含 ztems.com / seecom.com.cn / nubia.* -> DROP
#          （TLS SNI 明文匹配，覆盖全部子域，不依赖 DNS；内核 xt_string 已实测）
#        - 指定 IP 直连 -> DROP
#   ③ uci : zwrt_zte_dm.dm_update.dm_startup_no_check=1（开机不再做升级检查）
#
# 依据（2026-10-14 只读排查）:
#   zte_dm 硬编码 https://dmas/dms/dmin/dmeu/dmcan(.ztems.com):443/zxmdmp/dm
#   下载域名 dl*.ztems.com；2026-09-07 曾被 "Critical;Auto" 自动升级 B16->B20
#   详见 ota-block/README.md 与 私人交接文档（未公开发布） §21
# ============================================================

DIR=/data/topflow-ota-block
LOG="$DIR/ota-block.log"
HOSTS=/etc/hosts
C4=TOPFLOW_OTA_BLOCK4
C6=TOPFLOW_OTA_BLOCK6
BEGIN="# >>> topflow-ota-block BEGIN (managed) >>>"
END="# >>> topflow-ota-block END <<<"

DOMAINS="ztems.com dmcn.ztems.com dms.ztems.com dms6.ztems.com dmas.ztems.com dmas6.ztems.com dmin.ztems.com dmeu.ztems.com dmeu6.ztems.com dmcan.ztems.com dmcan6.ztems.com dl14.ztems.com upgrade.ztems.com seecom.com.cn ufi.seecom.com.cn uapp.seecom.com.cn report.server.nubia.cn api-data.nubia.com"
SNIS="ztems.com seecom.com.cn nubia.cn nubia.com"
IPS4="36.133.8.210 61.145.136.87"
PORTS="443 8883"

log() {
	mkdir -p "$DIR"
	if [ -f "$LOG" ]; then
		sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
		case "$sz" in (*[!0-9]*|"") sz=0 ;; esac
		[ "$sz" -gt 262144 ] && : > "$LOG"
	fi
	echo "$(date '+%F %T') $*" >> "$LOG"
}

hosts_ok() {
	grep -qF "127.0.0.1 dmcn.ztems.com" "$HOSTS" 2>/dev/null &&
	grep -qF "127.0.0.1 ufi.seecom.com.cn" "$HOSTS" 2>/dev/null
}

# $1=append|strip
rebuild_hosts() {
	_mode="$1"
	_tmp="$HOSTS.topflow.tmp"
	awk -v b="$BEGIN" -v e="$END" '
		$0==b {skip=1; next}
		$0==e {skip=0; next}
		!skip {print}
	' "$HOSTS" > "$_tmp" || return 1
	if [ "$_mode" = "append" ]; then
		{
			echo "$BEGIN"
			for d in $DOMAINS; do echo "127.0.0.1 $d"; done
			echo "$END"
		} >> "$_tmp" || return 1
	fi
	cat "$_tmp" > "$HOSTS" && rm -f "$_tmp"
}

FW_CHANGED=0
# $1=fw  $2=chain  $3=ips
fw_ensure() {
	_fw="$1"; _ch="$2"; _ips="$3"
	$_fw -N "$_ch" 2>/dev/null
	for _s in $SNIS; do
		for _p in $PORTS; do
			if ! $_fw -C "$_ch" -p tcp --dport "$_p" -m string --algo bm --string "$_s" -j DROP 2>/dev/null; then
				$_fw -A "$_ch" -p tcp --dport "$_p" -m string --algo bm --string "$_s" -j DROP 2>/dev/null && FW_CHANGED=1
			fi
		done
	done
	for _ip in $_ips; do
		if ! $_fw -C "$_ch" -d "$_ip" -j DROP 2>/dev/null; then
			$_fw -A "$_ch" -d "$_ip" -j DROP 2>/dev/null && FW_CHANGED=1
		fi
	done
	if ! $_fw -C OUTPUT -j "$_ch" 2>/dev/null; then
		$_fw -I OUTPUT 1 -j "$_ch" 2>/dev/null && FW_CHANGED=1
	fi
}

# $1=fw  $2=chain  $3=ips
fw_reset() {
	_fw="$1"; _ch="$2"; _ips="$3"
	$_fw -D OUTPUT -j "$_ch" 2>/dev/null
	$_fw -F "$_ch" 2>/dev/null
	fw_ensure "$_fw" "$_ch" "$_ips"
}

uci_ensure() {
	_v=$(uci -q get zwrt_zte_dm.dm_update.dm_startup_no_check 2>/dev/null)
	if [ "$_v" != "1" ]; then
		uci set zwrt_zte_dm.dm_update.dm_startup_no_check='1' 2>/dev/null &&
		uci commit zwrt_zte_dm 2>/dev/null &&
		log "uci: dm_startup_no_check='$_v' -> '1'"
	fi
}

ensure_all() {
	hosts_ok || { rebuild_hosts append && log "hosts: block (re)written"; }
	FW_CHANGED=0; fw_ensure iptables "$C4" "$IPS4"
	[ "$FW_CHANGED" = 1 ] && log "fw: $C4 rules (re)added"
	FW_CHANGED=0; fw_ensure ip6tables "$C6" ""
	[ "$FW_CHANGED" = 1 ] && log "fw: $C6 rules (re)added"
	uci_ensure
}

do_apply() {
	mkdir -p "$DIR/backup"
	[ -f "$DIR/backup/hosts.pre-ota-block" ] || \
		cp "$HOSTS" "$DIR/backup/hosts.pre-ota-block" 2>/dev/null
	if [ ! -f "$DIR/backup/uci.pre-ota-block.txt" ]; then
		{
			echo "dm_startup_no_check=$(uci -q get zwrt_zte_dm.dm_update.dm_startup_no_check)"
			echo "TURNOFFPOLLING=$(uci -q get zwrt_zte_dm.dm_update.TURNOFFPOLLING)"
			echo "dm_update_mode=$(uci -q get zwrt_zte_dm.dm_update.dm_update_mode)"
		} > "$DIR/backup/uci.pre-ota-block.txt" 2>/dev/null
	fi
	rebuild_hosts append && log "apply: hosts block written"
	FW_CHANGED=0; fw_reset iptables "$C4" "$IPS4"
	[ "$FW_CHANGED" = 1 ] && log "apply: $C4 built"
	FW_CHANGED=0; fw_reset ip6tables "$C6" ""
	[ "$FW_CHANGED" = 1 ] && log "apply: $C6 built"
	uci_ensure
	log "apply done"
}

do_keeper() {
	mkdir -p "$DIR"
	exec 9>"$DIR/.keeper.flock"
	flock -n 9 || { log "keeper already running, exit"; exit 0; }
	log "keeper start pid=$$"
	ensure_all
	while :; do
		sleep 30
		ensure_all
	done
}

do_status() {
	echo "== /etc/hosts =="
	awk -v b="$BEGIN" -v e="$END" '$0==b{s=1} s{print} $0==e{s=0}' "$HOSTS" 2>/dev/null || echo "(block absent)"
	echo "== $C4 =="
	iptables -S "$C4" 2>/dev/null | head -20 || echo "(missing)"
	iptables -S OUTPUT 2>/dev/null | grep -F "$C4" || echo "(jump missing)"
	echo "== $C6 =="
	ip6tables -S "$C6" 2>/dev/null | head -20 || echo "(missing)"
	ip6tables -S OUTPUT 2>/dev/null | grep -F "$C6" || echo "(jump missing)"
	echo "== uci =="
	echo "dm_startup_no_check=$(uci -q get zwrt_zte_dm.dm_update.dm_startup_no_check)"
	echo "TURNOFFPOLLING=$(uci -q get zwrt_zte_dm.dm_update.TURNOFFPOLLING)"
	echo "dm_update_mode=$(uci -q get zwrt_zte_dm.dm_update.dm_update_mode)"
	echo "== keeper =="
	ps | grep '[o]ta-block.sh keeper' || echo "(not running)"
}

do_revert() {
	iptables -D OUTPUT -j "$C4" 2>/dev/null
	iptables -F "$C4" 2>/dev/null; iptables -X "$C4" 2>/dev/null
	ip6tables -D OUTPUT -j "$C6" 2>/dev/null
	ip6tables -F "$C6" 2>/dev/null; ip6tables -X "$C6" 2>/dev/null
	rebuild_hosts strip && log "revert: hosts restored"
	uci set zwrt_zte_dm.dm_update.dm_startup_no_check='0' 2>/dev/null
	uci commit zwrt_zte_dm 2>/dev/null
	log "revert done"
}

case "$1" in
	apply)  do_apply ;;
	keeper) do_keeper ;;
	status) do_status ;;
	revert) do_revert ;;
	*) echo "usage: $0 apply|keeper|status|revert"; exit 2 ;;
esac
