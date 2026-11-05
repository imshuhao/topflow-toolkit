#!/bin/sh
# TopFlow MU5252 B20 — normal-mode (MULTIWAN) data-plane recovery.
#
# Why this exists
# ---------------
# The hardware toggle / WebUI / AT path can switch the device to SMULTIWAN
# (vendor ICG aggregation).  In SMULTIWAN the vendor stops mwan3 and takes the
# data plane over with ICG/tun0; our mwan3 tuning is explicitly out of scope
# there (see docs/RESEARCH.md "作用域" and HANDOVER §11.4).  When the user
# switches back to MULTIWAN nothing re-runs the chain:
#
#   apply-rules.sh (weights 6/3/3, https sticky rule, default rule)
#     -> /etc/init.d/mwan3 restart          (reload the tuned uci into runtime)
#     -> singbox-wan-balance.sh apply       (nft tf-sbwan + ip rules 1990-1992)
#
# The vendor stock generator is wrapped by sdx75-set-mwan3-wrapper.sh, but the
# wrapper calls apply-rules.sh with --no-reload on purpose, so the running
# mwan3 can keep the *previous* (stock or SMULTIWAN-era) config until something
# restarts it.  This script closes exactly that gap.
#
# Usage
#   recover.sh           full, idempotent recovery (restarts mwan3 once)
#   recover.sh --check   act only when inconsistent (used by the cron guard)
#   recover.sh --verify  read-only verification, never changes anything
#
# Exit codes: 0 ok / 1 verification failed / 2 wrong mode or usage.

set -u

BASE=${BASE:-/data/local/mwan3-tuning}
SB=${SB:-/data/sing-box}
LOG=${LOG:-/tmp/topflow-mode-recover.log}
LOCK=${LOCK:-/tmp/topflow-mode-recover.lock.d}
W5G=${W5G:-6}
W4G1=${W4G1:-3}
W4G2=${W4G2:-3}

log() {
	# tmpfs log: keep it bounded, ~200 lines max
	if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
		tail -n 200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
	fi
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null
	printf '%s\n' "$*"
}

mode() { uci -q get zwrt_router.network.opms_wan_mode 2>/dev/null; }
mwan3_running() { pgrep -f '/usr/sbin/mwan3track zte_mwan2' >/dev/null 2>&1; }
weights_ok() {
	[ "$(uci -q get mwan3.zte_mwan2_m1_w1.weight)" = "$W5G" ] || return 1
	[ "$(uci -q get mwan3.zte_mwan3_m1_w1.weight)" = "$W4G1" ] || return 1
	[ "$(uci -q get mwan3.zte_mwan4_m1_w1.weight)" = "$W4G2" ] || return 1
}
rules_ok() {
	n=$(ip rule show 2>/dev/null | grep -c 'fwmark 0x.000000/0xf000000 lookup 1[234]')
	[ "${n:-0}" -ge 3 ]
}
sbwan_ok() { nft list tables 2>/dev/null | grep -q 'table ip tf-sbwan'; }
sb_running() { pgrep -f "$SB/sing-box run" >/dev/null 2>&1; }
online_cards() { mwan3 status 2>/dev/null | grep -cE 'interface zte_mwan[234] is online'; }
consistent() { mwan3_running && weights_ok && rules_ok && { ! sb_running || sbwan_ok; }; }

verify() {
	rc=0
	m=$(mode)
	if [ "$m" = "MULTIWAN" ]; then
		log "OK   mode=MULTIWAN"
	else
		log "FAIL mode=${m:-unknown} (expected MULTIWAN)"; rc=1
	fi
	if mwan3_running; then log "OK   mwan3 running"; else log "FAIL mwan3 not running"; rc=1; fi
	if weights_ok; then
		log "OK   mwan3 weights $W5G/$W4G1/$W4G2"
	else
		log "FAIL mwan3 weights=$(uci -q get mwan3.zte_mwan2_m1_w1.weight)/$(uci -q get mwan3.zte_mwan3_m1_w1.weight)/$(uci -q get mwan3.zte_mwan4_m1_w1.weight) (expected $W5G/$W4G1/$W4G2)"; rc=1
	fi
	if rules_ok; then log "OK   wan-balance ip rules"; else log "FAIL wan-balance ip rules missing"; rc=1; fi
	n=$(online_cards)
	if [ "${n:-0}" -ge 1 ]; then log "OK   mwan3 online cards=$n"; else log "FAIL mwan3 online cards=0"; rc=1; fi
	if sb_running; then
		if sbwan_ok; then log "OK   nft tf-sbwan present"; else log "FAIL nft tf-sbwan missing"; rc=1; fi
		wan=$("$SB/sing-box.sh" status 2>/dev/null | sed -n 's/^wan:  *//p' | head -1)
		if [ -n "$wan" ]; then log "OK   sing-box wan: $wan"; else log "FAIL sing-box wan: line missing"; rc=1; fi
	else
		log "SKIP sing-box not running"
	fi
	return "$rc"
}

full_recover() {
	log "mode=$(mode) -> running full MULTIWAN recovery"
	# 1. Tuning assets: keep the vendor generator wrapped and the hotplug hook
	#    linked.  activate.sh re-applies rules *and* reloads mwan3, so only run
	#    it when the bind mount is missing (fresh flash / after OTA).
	if ! mount 2>/dev/null | grep -q ' /sbin/sdx75_set_mwan3.sh '; then
		if [ -x "$BASE/activate.sh" ]; then
			log "restoring tuning assets via activate.sh"
			"$BASE/activate.sh" >/dev/null 2>&1 || log "WARN activate.sh failed"
		fi
	fi
	# 2. Re-generate the tuned config (weights / rules) without reloading yet.
	if [ -x "$BASE/apply-rules.sh" ]; then
		"$BASE/apply-rules.sh" --no-reload >/dev/null 2>&1 || log "WARN apply-rules.sh failed"
	fi
	# 3. One controlled reload so the running mwan3 picks the tuned config up.
	log "restarting mwan3"
	/etc/init.d/mwan3 restart >/dev/null 2>&1 || log "WARN mwan3 restart failed"
	# 4. Wait for tracking to come back (up to ~45s).
	i=0
	while [ "$i" -lt 15 ]; do
		[ "$(online_cards)" -ge 1 ] && break
		sleep 3
		i=$((i + 1))
	done
	# 5. sing-box per-connection balancing follows mwan3's tables; refresh it
	#    after mwan3 is back so the nft buckets/ip rules match the live pool.
	if sb_running && [ -x "$SB/singbox-wan-balance.sh" ]; then
		log "refreshing sing-box wan-balance"
		"$SB/singbox-wan-balance.sh" apply >/dev/null 2>&1 || log "WARN wan-balance apply failed"
	fi
}

case "${1:-}" in
--verify)
	verify
	exit $?
	;;
--check)
	# Cron guard: silent and read-only unless something is actually off.
	[ "$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)" -lt 180 ] && exit 0
	[ "$(mode)" = "MULTIWAN" ] || exit 0   # SMULTIWAN is the vendor's business
	consistent && exit 0
	log "guard: inconsistent (mwan3=$(mwan3_running && echo up || echo down) weights=$(weights_ok && echo ok || echo drift) rules=$(rules_ok && echo ok || echo missing) nft=$(sbwan_ok && echo ok || echo missing)) -> recover"
	;;
"") : ;;
*)
	echo "usage: $0 [--check|--verify]" >&2
	exit 2
	;;
esac

# Serialise: a cron guard and a manual run must not fight over mwan3.
if ! mkdir "$LOCK" 2>/dev/null; then
	log "another recovery is already running"
	exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

formatted_verify() { verify || true; }

full_recover
if verify >/dev/null 2>&1; then
	log "recovery done: all checks passed"
else
	log "recovery finished with FAILURES"
	formatted_verify
	exit 1
fi
