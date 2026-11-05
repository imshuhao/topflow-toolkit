#!/bin/sh
# Per-connection WAN balancing for host-mode sing-box (TopFlow MU5252 B20).
#
# Why this exists
# ---------------
# sing-box stamps every outbound socket with SO_MARK 0x2024 and relies on that
# mark staying untouched to keep its own traffic out of its TUN:
#   ip rule 9000: from all fwmark 0x2024 goto 9002
#   ip rule 32768: not from all fwmark 0x2024 lookup 2022   (table 2022 = sbtun0)
#   nft "inet sing-box": meta mark 0x2024 ... return
# 0x2024 & 0x3f00 = 0x2000, so every mwan3_hook rule
# ("-m mark --mark 0x0/0x3f00") skips these packets.  mwan3 therefore never
# assigns a WAN, the packet falls through to table main, and rmnet_data0
# (metric 256) always wins -> all proxied traffic leaves on the 5G card while
# the two 4G cards carry nothing but mwan3 tracking pings.
#
# The mark cannot be rewritten before sing-box sees it: the packet would be
# redirected back into sbtun0 and loop.  So the WAN choice is applied *after*
# sing-box's hooks, in a separate mark field:
#
#   nft chain ip tf-sbwan/out   (type route, hook output, priority mangle + 3)
#       sing-box mark -> set bits 0x0f000000, hashed from the 5-tuple
#   ip rule pref 2005.. fwmark 0x0X000000/0x0f000000 lookup <mwan3 table>
#       mwan3's own per-interface table (12/13/14) already carries
#       "default via <gw> dev <if> src <wan addr>", so source address, PMTU and
#       the return path are mwan3's, not ours.
#
# With the eBPF inbound there is no TUN and no auto_route rule at all: the core
# stamps route.default_mark ("default_mark" in config.json, 8228 = 0x2024) on
# every proxied packet itself.  That value *is* the contract for this chain —
# singbox_mark() reads it from the config first, so the mark can move without
# touching this script.
#
# The hash makes every connection stick to one WAN without keeping state, and
# the bucket widths follow the weights of mwan3's policy, so this stays a
# mirror of mwan3 rather than a second routing policy.  Interfaces whose
# mwan3 tracker state is not "online" (or that have no live default route) are
# dropped from the pool on the next refresh.
#
# Optional protocol pools (MODE=proto in wan-balance.conf)
# -------------------------------------------------------
# B20 only has three cellular WANs.  MODE=proto lets TCP and UDP use different
# subsets of that same three-card set (e.g. TCP -> 5G+4G#1, UDP -> 4G#2).
# Bits are assigned once per iface across the union; TCP/UDP never share a
# packet so the same 0x0f000000 space stays collision-free.  Default remains
# MODE=shared (identical to the pre-split behaviour).
set -u

BASE="${SINGBOX_BASE:-/data/sing-box}"
CONFIG="${SINGBOX_CONFIG:-$BASE/config.json}"
CONF="${SINGBOX_WANBAL_CONF:-$BASE/wan-balance.conf}"
STATE="${SINGBOX_STATE:-$BASE/state}"
LOG="$STATE/wan-balance.log"
SPEC="$STATE/wan-balance.nft"
RULES="$STATE/wan-balance.rules"
WORK="$STATE/wan-balance.pool"
WORK_TCP="$STATE/wan-balance.pool.tcp"
WORK_UDP="$STATE/wan-balance.pool.udp"
BITS="$STATE/wan-balance.bits"
MEMBERS="$STATE/wan-balance.members"
MODE_STATE="$STATE/wan-balance.pool-mode"
QSTATE="$STATE/wan-balance.qstate"
QDETAIL="$STATE/wan-balance.quality"
WEIGHTS_TCP="$STATE/wan-balance.weights.tcp"
WEIGHTS_UDP="$STATE/wan-balance.weights.udp"
# Overridable so the pool logic can be exercised against a scratch table.
NFT_TABLE="${SINGBOX_WANBAL_TABLE:-tf-sbwan}"
PREF_BASE="${SINGBOX_WANBAL_PREF:-1990}"
PREF_FLOOR="${SINGBOX_WANBAL_PREF_FLOOR:-1990}"
PREF_CEIL="${SINGBOX_WANBAL_PREF_CEIL:-2011}"
MAX_WAN=4
SEL_MASK="0x0f000000"
SEL_MASK_HEX=$(printf '0x%x' $((SEL_MASK)))
HASH_SEED="0x9e3779b9"
FALLBACK_MARK="0x2024"
TRACK_DIR="${MWAN3_TRACK_DIR:-/tmp/run/mwan3/iface_state}"
# mwan3track metrics (LATENCY_*/LOSS_*). Overridable for offline tests.
TRACK_METRICS_DIR="${MWAN3TRACK_DIR:-/var/run/mwan3track}"
RADIO_SNAP_DEFAULT="/data/local/weaknet/radio.snap"

# Runtime pool mode (filled by load_conf / apply).
POOL_MODE=shared
TCP_POOL_CSV=
UDP_POOL_CSV=
# Touch / manager presets:
#   auto   — quality-weighted shared cards + soft TCP→5G / UDP→4G bias (recommended)
#   shared — flat three-card pool; quality degrade still on; no soft bias
#   game   — legacy hard bind (CLI only; not offered on touch)
PRESET=
PRESET_STATE="$STATE/wan-balance.preset"
QUALITY=0
BIAS=0
IFACE_5G=zte_mwan2
# Enter weak when latency/loss cross ENTER; leave only below EXIT (hysteresis).
Q_ENTER_LATENCY=600
Q_EXIT_LATENCY=350
Q_ENTER_LOSS=30
Q_EXIT_LOSS=10
# Hard drop from pool (still online in mwan3, but too bad to keep hashing onto).
Q_DROP_LATENCY=1500
Q_DROP_LOSS=70
# Weak card keeps this percent of base weight (min 1) so spill remains possible.
Q_WEAK_SCALE=15
# Optional 5G RSRP from weaknet radio.snap (dBm). Empty snap = ignored.
Q_RSRP_ENTER=-105
Q_RSRP_EXIT=-95
RADIO_SNAP=
# Soft bias multipliers (percent). Only applied when BIAS=1 (auto preset).
BIAS_TCP_5G=150
BIAS_TCP_4G=70
BIAS_UDP_5G=70
BIAS_UDP_4G=130

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null || true
	if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 262144 ]; then
		tail -c 131072 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
	fi
}

# Normalize comma lists for compare: drop spaces, stable order as written.
_norm_csv() {
	printf '%s' "$1" | tr -d ' \t\r' | tr ',' '\n' | sed '/^$/d' | paste -sd, -
}

# Map known MODE+pools back to a preset id (or "custom").
infer_preset() {
	_m=$1
	_tcp=$(_norm_csv "$2")
	_udp=$(_norm_csv "$3")
	_q=${4:-0}
	_b=${5:-0}
	if [ "$_m" = proto ] && [ -z "$_tcp" ] && [ -z "$_udp" ] && \
		[ "$_q" = 1 ] && [ "$_b" = 1 ]; then
		echo auto
		return 0
	fi
	if [ "$_m" = shared ]; then
		echo shared
		return 0
	fi
	if [ "$_m" = proto ] && [ "$_tcp" = "zte_mwan2" ] && \
		{ [ "$_udp" = "zte_mwan3,zte_mwan4" ] || [ "$_udp" = "zte_mwan4,zte_mwan3" ]; }; then
		echo game
		return 0
	fi
	# legacy split3 / other hand-edits → custom (not offered in UI)
	echo custom
}

_defaults_quality() {
	QUALITY=0
	BIAS=0
	IFACE_5G=zte_mwan2
	Q_ENTER_LATENCY=600
	Q_EXIT_LATENCY=350
	Q_ENTER_LOSS=30
	Q_EXIT_LOSS=10
	Q_DROP_LATENCY=1500
	Q_DROP_LOSS=70
	Q_WEAK_SCALE=15
	Q_RSRP_ENTER=-105
	Q_RSRP_EXIT=-95
	RADIO_SNAP=$RADIO_SNAP_DEFAULT
	BIAS_TCP_5G=150
	BIAS_TCP_4G=70
	BIAS_UDP_5G=70
	BIAS_UDP_4G=130
}

preset_fill() {
	# Sets POOL_MODE / pools / QUALITY / BIAS / PRESET for a known id.
	# Does not reset latency thresholds or RADIO_SNAP (load_conf owns those).
	case "$1" in
	auto)
		PRESET=auto
		POOL_MODE=proto
		TCP_POOL_CSV=
		UDP_POOL_CSV=
		QUALITY=1
		BIAS=1
		;;
	shared)
		PRESET=shared
		POOL_MODE=shared
		TCP_POOL_CSV=
		UDP_POOL_CSV=
		QUALITY=1
		BIAS=0
		;;
	game)
		PRESET=game
		POOL_MODE=proto
		TCP_POOL_CSV=zte_mwan2
		UDP_POOL_CSV=zte_mwan3,zte_mwan4
		QUALITY=0
		BIAS=0
		;;
	*)
		return 1
		;;
	esac
	return 0
}

write_conf_preset() {
	_id=$1
	preset_fill "$_id" || return 1
	mkdir -p "$(dirname "$CONF")" 2>/dev/null || true
	{
		echo "# Generated by singbox-wan-balance.sh preset-set"
		echo "# Rollback: restore previous wan-balance.conf then: $0 apply"
		echo "PRESET=$PRESET"
		echo "MODE=$POOL_MODE"
		echo "QUALITY=$QUALITY"
		echo "BIAS=$BIAS"
		if [ "$POOL_MODE" = proto ]; then
			echo "TCP_POOL=$TCP_POOL_CSV"
			echo "UDP_POOL=$UDP_POOL_CSV"
		fi
	} > "$CONF.new"
	mv "$CONF.new" "$CONF"
	printf '%s\n' "$PRESET" > "$PRESET_STATE"
	return 0
}

load_conf() {
	POOL_MODE=shared
	TCP_POOL_CSV=
	UDP_POOL_CSV=
	PRESET=
	_defaults_quality
	[ -f "$CONF" ] || {
		PRESET=shared
		return 0
	}
	_had_q=0
	_had_b=0
	# Only assign known keys; ignore junk / comments via a tiny parser.
	while IFS= read -r _line || [ -n "$_line" ]; do
		case "$_line" in
		''|\#*) continue ;;
		esac
		_key=${_line%%=*}
		_val=${_line#*=}
		_key=$(printf '%s' "$_key" | tr -d ' \t\r')
		_val=$(printf '%s' "$_val" | tr -d ' \t\r' | tr -d '"' | tr -d "'")
		case "$_key" in
		MODE) POOL_MODE=$_val ;;
		TCP_POOL) TCP_POOL_CSV=$_val ;;
		UDP_POOL) UDP_POOL_CSV=$_val ;;
		PRESET) PRESET=$_val ;;
		QUALITY) QUALITY=$_val; _had_q=1 ;;
		BIAS) BIAS=$_val; _had_b=1 ;;
		IFACE_5G) IFACE_5G=$_val ;;
		Q_ENTER_LATENCY) Q_ENTER_LATENCY=$_val ;;
		Q_EXIT_LATENCY) Q_EXIT_LATENCY=$_val ;;
		Q_ENTER_LOSS) Q_ENTER_LOSS=$_val ;;
		Q_EXIT_LOSS) Q_EXIT_LOSS=$_val ;;
		Q_DROP_LATENCY) Q_DROP_LATENCY=$_val ;;
		Q_DROP_LOSS) Q_DROP_LOSS=$_val ;;
		Q_WEAK_SCALE) Q_WEAK_SCALE=$_val ;;
		Q_RSRP_ENTER) Q_RSRP_ENTER=$_val ;;
		Q_RSRP_EXIT) Q_RSRP_EXIT=$_val ;;
		RADIO_SNAP) RADIO_SNAP=$_val ;;
		BIAS_TCP_5G) BIAS_TCP_5G=$_val ;;
		BIAS_TCP_4G) BIAS_TCP_4G=$_val ;;
		BIAS_UDP_5G) BIAS_UDP_5G=$_val ;;
		BIAS_UDP_4G) BIAS_UDP_4G=$_val ;;
		esac
	done < "$CONF"
	case "$QUALITY" in 0|1) ;; *) QUALITY=0 ;; esac
	case "$BIAS" in 0|1) ;; *) BIAS=0 ;; esac
	case "$POOL_MODE" in
	shared|proto) ;;
	*)
		log "WARN: unknown MODE=$POOL_MODE in $CONF; falling back to shared"
		POOL_MODE=shared
		;;
	esac
	# Prefer explicit PRESET when it matches the allow-list; otherwise infer.
	# Thresholds / RADIO_SNAP already applied from conf; only restore QUALITY/BIAS
	# when the conf omitted them (preset defaults then win).
	case "$PRESET" in
	auto|shared|game)
		_saved_q=$QUALITY
		_saved_b=$BIAS
		_saved_snap=$RADIO_SNAP
		preset_fill "$PRESET" || true
		[ "$_had_q" = 1 ] && QUALITY=$_saved_q
		[ "$_had_b" = 1 ] && BIAS=$_saved_b
		RADIO_SNAP=$_saved_snap
		;;
	*)
		PRESET=$(infer_preset "$POOL_MODE" "$TCP_POOL_CSV" "$UDP_POOL_CSV" "$QUALITY" "$BIAS")
		;;
	esac
	[ -n "${RADIO_SNAP:-}" ] || RADIO_SNAP=$RADIO_SNAP_DEFAULT
}

preset_list() {
	echo "auto    自动质量  质量加权共池 + TCP偏5G/UDP偏4G（弱网可溢出）"
	echo "shared  三卡共池  强制共池；仍按质量降权，无协议软偏置"
	echo "game    游戏硬绑  TCP=5G UDP=双4G（遗留；触控不提供）"
}

_fmt_weights() {
	# stdin: pool rows → "iface:w,iface:w"
	awk 'NF>=3 {
		if (n++) printf ","
		printf "%s:%s", $1, $3
	}'
}

preset_get() {
	load_conf
	echo "preset=$PRESET"
	echo "mode=$POOL_MODE"
	echo "quality=$QUALITY"
	echo "bias=$BIAS"
	echo "tcp_pool=$TCP_POOL_CSV"
	echo "udp_pool=$UDP_POOL_CSV"
	_tw=
	_uw=
	_deg=
	[ -s "$WEIGHTS_TCP" ] && _tw=$(_fmt_weights < "$WEIGHTS_TCP")
	[ -s "$WEIGHTS_UDP" ] && _uw=$(_fmt_weights < "$WEIGHTS_UDP")
	if [ -s "$QSTATE" ]; then
		_deg=$(awk '$2=="weak" || $2=="drop" { if (n++) printf ","; printf "%s", $1 }' "$QSTATE")
	fi
	echo "tcp_weights=${_tw}"
	echo "udp_weights=${_uw}"
	echo "degraded=${_deg}"
	if [ -s "$QDETAIL" ]; then
		echo "quality_detail=$(tr '\n' ';' < "$QDETAIL" | sed 's/;$//')"
	else
		echo "quality_detail="
	fi
}

preset_set() {
	_id=${1:-}
	case "$_id" in
	auto|shared|game) ;;
	*)
		echo "preset-set: unknown id '$_id' (want auto|shared|game)" >&2
		return 2
		;;
	esac
	write_conf_preset "$_id" || return 1
	# apply when nft is available; render-only hosts skip silently via apply().
	apply
	preset_get
}

# sing-box's own egress mark.  MARK_SOURCE records where it came from, in the
# order singbox_mark() tries them:
#
#   default   "default_mark" in config.json (route.default_mark).  The eBPF
#             outbound has neither TUN nor auto_route rule, but the core stamps
#             this value on every proxied packet itself, so the jhash chain
#             below does see the traffic.  The config is the contract: prefer it.
#   rule      the TUN stack's auto_route bypass rule
#             ("not from all fwmark 0x... lookup ...").
#   ebpf      an eBPF config that carries no default_mark and no rule: nothing
#             stamps the mark, the chain matches nothing -> apply() warns.
#   fallback  no rule, no eBPF config: assume 0x2024, same caveat.
MARK_SOURCE="unknown"
MARK_VALUE="$FALLBACK_MARK"
singbox_mark() {
	# Sets MARK_VALUE / MARK_SOURCE in the caller.  Do not wrap this in $(...):
	# a command substitution runs in a subshell and would drop the assignment
	# (that bug left MARK_SOURCE at "unknown" and silenced the apply() warning).
	#
	# config.json wins: ASCII digits and a leading 0x are both accepted, and the
	# decimal form is normalised to hex because nft/ip compare marks as hex.
	_dm=$(sed -n 's/.*"default_mark"[[:space:]]*:[[:space:]]*\(0[xX][0-9a-fA-F]*\|[0-9][0-9]*\).*/\1/p' \
		"$CONFIG" 2>/dev/null | head -1)
	case "${_dm:-}" in
	0[xX]*)
		MARK_SOURCE=default
		MARK_VALUE=$(printf '0x%s' "$(printf '%s' "${_dm#0[xX]}" | tr 'A-F' 'a-f')")
		return 0
		;;
	[0-9]*)
		# Strip leading zeros so printf cannot read the value as octal.
		_dz=$(printf '%s' "$_dm" | sed 's/^0*//')
		[ -n "$_dz" ] || _dz=0
		MARK_SOURCE=default
		MARK_VALUE=$(printf '0x%x' "$_dz")
		return 0
		;;
	esac
	_m=$(ip rule show 2>/dev/null |
		sed -n 's/.*not from all fwmark \(0x[0-9a-fA-F]*\) lookup.*/\1/p' | head -1)
	if [ -n "${_m:-}" ]; then
		MARK_SOURCE=rule
		MARK_VALUE="$_m"
	elif grep -q '"type": "ebpf"' "$CONFIG" 2>/dev/null; then
		MARK_SOURCE=ebpf
		MARK_VALUE="$FALLBACK_MARK"
	else
		MARK_SOURCE=fallback
		MARK_VALUE="$FALLBACK_MARK"
	fi
}

# mwan3 policy members as "<interface> <weight>" for IPv4 only.
policy_members() {
	_pol="${WANBAL_POLICY:-$(uci -q get mwan3.default_rule.use_policy 2>/dev/null)}"
	[ -n "${_pol:-}" ] || _pol=balanced
	for _m in $(uci -q get "mwan3.$_pol.use_member" 2>/dev/null); do
		_if=$(uci -q get "mwan3.$_m.interface" 2>/dev/null) || continue
		_w=$(uci -q get "mwan3.$_m.weight" 2>/dev/null) || _w=1
		case "$_if" in ''|*_6) continue ;; esac
		echo "$_if $_w"
	done
}

iface_dev() {
	iptables -t mangle -S "mwan3_iface_in_$1" 2>/dev/null |
		sed -n 's/.*-i \([^ ][^ ]*\).*/\1/p' | head -1
}

iface_mark() {
	iptables -t mangle -S "mwan3_iface_in_$1" 2>/dev/null |
		sed -n "s/.*--comment $1 -j MARK --set-xmark \(0x[0-9a-f]*\)\/0x3f00.*/\1/p" | head -1
}

mark_table() {
	ip rule show 2>/dev/null |
		sed -n "s/.*fwmark $1\/0x3f00 lookup \([0-9][0-9]*\)$/\1/p" | head -1
}

dev_gw() {
	ip route show table "$1" 2>/dev/null |
		awk -v d="$2" '$1=="default" && $2=="via" && $4=="dev" && $5==d {print $3; exit}'
}

iface_online() {
	[ "$(cat "$TRACK_DIR/$1" 2>/dev/null)" = "online" ]
}

# Max LATENCY_* / LOSS_* across mwan3track targets for one iface.
# Sets TRACK_LAT / TRACK_LOSS (integers; 0 if no metrics).
iface_track_metrics() {
	TRACK_LAT=0
	TRACK_LOSS=0
	_tdir="$TRACK_METRICS_DIR/$1"
	[ -d "$_tdir" ] || return 0
	for _f in "$_tdir"/LATENCY_*; do
		[ -f "$_f" ] || continue
		_v=$(cat "$_f" 2>/dev/null | tr -d ' \t\r')
		case "$_v" in ''|*[!0-9]*) continue ;; esac
		[ "$_v" -gt "$TRACK_LAT" ] && TRACK_LAT=$_v
	done
	for _f in "$_tdir"/LOSS_*; do
		[ -f "$_f" ] || continue
		_v=$(cat "$_f" 2>/dev/null | tr -d ' \t\r')
		case "$_v" in ''|*[!0-9]*) continue ;; esac
		[ "$_v" -gt "$TRACK_LOSS" ] && TRACK_LOSS=$_v
	done
}

# Optional 5G RSRP from weaknet radio.snap (rsrp=<int dBm>). Empty → RADIO_RSRP="".
read_radio_rsrp() {
	RADIO_RSRP=
	_snap=${RADIO_SNAP:-$RADIO_SNAP_DEFAULT}
	[ -f "$_snap" ] || return 0
	_v=$(sed -n 's/^rsrp=//p' "$_snap" 2>/dev/null | head -1 | tr -d ' \t\r')
	case "$_v" in
	''|*[!0-9-]*) return 0 ;;
	*) RADIO_RSRP=$_v ;;
	esac
}

qstate_get() {
	# $1=iface → prints ok|weak|drop (default ok)
	_s=$(awk -v i="$1" '$1==i {print $2; exit}' "$QSTATE" 2>/dev/null)
	case "$_s" in weak|drop|ok) echo "$_s" ;; *) echo ok ;; esac
}

# Decide quality class for one iface given metrics + prior hysteresis state.
# Prints: ok|weak|drop
quality_class() {
	_if=$1
	_lat=$2
	_loss=$3
	_prev=$(qstate_get "$_if")
	case "$_prev" in weak|drop|ok) ;; *) _prev=ok ;; esac

	_cand=ok
	if [ "$_lat" -ge "$Q_DROP_LATENCY" ] || [ "$_loss" -ge "$Q_DROP_LOSS" ]; then
		_cand=drop
	elif [ "$_lat" -ge "$Q_ENTER_LATENCY" ] || [ "$_loss" -ge "$Q_ENTER_LOSS" ]; then
		_cand=weak
	fi
	# Auxiliary RSRP only for the 5G iface when snap is present.
	if [ "$_if" = "$IFACE_5G" ] && [ -n "${RADIO_RSRP:-}" ]; then
		if [ "$RADIO_RSRP" -le "$Q_RSRP_ENTER" ]; then
			[ "$_cand" = ok ] && _cand=weak
		fi
	fi

	case "$_prev" in
	ok)
		echo "$_cand"
		;;
	weak)
		if [ "$_cand" = drop ]; then
			echo drop
		elif [ "$_lat" -le "$Q_EXIT_LATENCY" ] && [ "$_loss" -le "$Q_EXIT_LOSS" ]; then
			_ok=1
			if [ "$_if" = "$IFACE_5G" ] && [ -n "${RADIO_RSRP:-}" ] && \
				[ "$RADIO_RSRP" -lt "$Q_RSRP_EXIT" ]; then
				_ok=0
			fi
			if [ "$_ok" = 1 ]; then
				echo ok
			else
				echo weak
			fi
		else
			echo weak
		fi
		;;
	drop)
		if [ "$_lat" -le "$Q_EXIT_LATENCY" ] && [ "$_loss" -le "$Q_EXIT_LOSS" ]; then
			_ok=1
			if [ "$_if" = "$IFACE_5G" ] && [ -n "${RADIO_RSRP:-}" ] && \
				[ "$RADIO_RSRP" -lt "$Q_RSRP_EXIT" ]; then
				_ok=0
			fi
			if [ "$_ok" = 1 ]; then
				echo ok
			else
				echo drop
			fi
		else
			echo drop
		fi
		;;
	esac
}

# Rewrite WORK weights from quality signals. Drops "drop" rows. Updates QSTATE/QDETAIL.
apply_quality() {
	[ "$QUALITY" = 1 ] || {
		: > "$QDETAIL"
		: > "$QSTATE"
		return 0
	}
	[ -s "$WORK" ] || return 0
	read_radio_rsrp
	_prev_q=$QSTATE.prev
	cp "$QSTATE" "$_prev_q" 2>/dev/null || : > "$_prev_q"
	: > "$QSTATE.new"
	: > "$QDETAIL"
	: > "$WORK.q"
	while read -r _if _dev _w _tbl _gw; do
		[ -n "${_if:-}" ] || continue
		iface_track_metrics "$_if"
		_cls=$(quality_class "$_if" "$TRACK_LAT" "$TRACK_LOSS")
		echo "$_if $_cls" >> "$QSTATE.new"
		_rs=
		[ "$_if" = "$IFACE_5G" ] && [ -n "${RADIO_RSRP:-}" ] && _rs=" rsrp=$RADIO_RSRP"
		echo "$_if:$_cls:lat=$TRACK_LAT:loss=$TRACK_LOSS$_rs" >> "$QDETAIL"
		case "$_cls" in
		drop)
			log "quality: $_if drop (lat=$TRACK_LAT loss=$TRACK_LOSS$_rs)"
			continue
			;;
		weak)
			_nw=$((_w * Q_WEAK_SCALE / 100))
			[ "$_nw" -ge 1 ] || _nw=1
			log "quality: $_if weak scale $_w->$_nw (lat=$TRACK_LAT loss=$TRACK_LOSS$_rs)"
			_w=$_nw
			;;
		esac
		echo "$_if $_dev $_w $_tbl $_gw" >> "$WORK.q"
	done < "$WORK"
	mv "$QSTATE.new" "$QSTATE"
	rm -f "$_prev_q"
	if [ -s "$WORK.q" ]; then
		mv "$WORK.q" "$WORK"
	else
		# All dropped → keep original WORK so apply() does not clear routing
		# entirely; log and leave unscaled (better than blackhole).
		log "WARN: quality would empty the pool; keeping unscaled WORK"
		rm -f "$WORK.q"
	fi
}

# Soft bias: multiply weights in a pool file by TCP/UDP preference percents.
apply_bias_pool() {
	_pool=$1
	_side=$2
	[ "$BIAS" = 1 ] || return 0
	[ -s "$_pool" ] || return 0
	: > "$_pool.b"
	while read -r _if _dev _w _tbl _gw; do
		[ -n "${_if:-}" ] || continue
		if [ "$_if" = "$IFACE_5G" ]; then
			if [ "$_side" = tcp ]; then
				_pct=$BIAS_TCP_5G
			else
				_pct=$BIAS_UDP_5G
			fi
		else
			if [ "$_side" = tcp ]; then
				_pct=$BIAS_TCP_4G
			else
				_pct=$BIAS_UDP_4G
			fi
		fi
		_nw=$((_w * _pct / 100))
		[ "$_nw" -ge 1 ] || _nw=1
		echo "$_if $_dev $_nw $_tbl $_gw" >> "$_pool.b"
	done < "$_pool"
	mv "$_pool.b" "$_pool"
}

write_weight_snapshots() {
	cp "$WORK_TCP" "$WEIGHTS_TCP" 2>/dev/null || : > "$WEIGHTS_TCP"
	cp "$WORK_UDP" "$WEIGHTS_UDP" 2>/dev/null || : > "$WEIGHTS_UDP"
}

# Pool of usable WANs: "<iface> <dev> <weight> <table> <gw>".
collect() {
	mkdir -p "$STATE" 2>/dev/null || true
	: > "$WORK"
	policy_members > "$MEMBERS" 2>/dev/null || : > "$MEMBERS"
	_n=0
	while read -r _if _w; do
		[ -n "${_if:-}" ] || continue
		[ "$_n" -lt "$MAX_WAN" ] || break
		case "$_w" in ''|*[!0-9]*) _w=1 ;; esac
		[ "$_w" -gt 0 ] || _w=1
		iface_online "$_if" || continue
		_dev=$(iface_dev "$_if"); [ -n "$_dev" ] || continue
		_mark=$(iface_mark "$_if"); [ -n "$_mark" ] || continue
		_tbl=$(mark_table "$_mark"); [ -n "$_tbl" ] || continue
		_gw=$(dev_gw "$_tbl" "$_dev"); [ -n "$_gw" ] || continue
		echo "$_if $_dev $_w $_tbl $_gw" >> "$WORK"
		_n=$((_n + 1))
	done < "$MEMBERS"
}

# Filter WORK rows whose iface is in a comma-separated allow-list into $1.
# Empty allow-list copies WORK unchanged (shared fallback for that side).
filter_pool() {
	_out=$1
	_csv=$2
	: > "$_out"
	if [ -z "${_csv:-}" ]; then
		cat "$WORK" > "$_out"
		return 0
	fi
	_csv=$(printf '%s' "$_csv" | tr ',' ' ')
	while read -r _if _rest; do
		[ -n "${_if:-}" ] || continue
		for _want in $_csv; do
			[ "$_if" = "$_want" ] || continue
			echo "$_if $_rest" >> "$_out"
			break
		done
	done < "$WORK"
}

# Assign one selector bit per iface across the union of TCP+UDP pools.
# BITS lines: "<iface> <bit> <pref_offset> <dev> <weight> <table> <gw>"
assign_bits() {
	: > "$BITS"
	_i=0
	# Prefer TCP order, then UDP-only additions.
	for _src in "$WORK_TCP" "$WORK_UDP"; do
		[ -s "$_src" ] || continue
		while read -r _if _dev _w _tbl _gw; do
			[ -n "${_if:-}" ] || continue
			grep -q "^$_if " "$BITS" 2>/dev/null && continue
			[ "$_i" -lt "$MAX_WAN" ] || break
			_bit=$(printf '0x%08x' $((0x01000000 << _i)))
			echo "$_if $_bit $_i $_dev $_w $_tbl $_gw" >> "$BITS"
			_i=$((_i + 1))
		done < "$_src"
	done
}

bit_for_iface() {
	awk -v i="$1" '$1==i {print $2; exit}' "$BITS"
}

# Emit jhash (or single-bit) rules for one pool file into stdout.
# $1 = pool file, $2 = optional nft match prefix (e.g. "meta l4proto tcp ").
emit_jhash() {
	_pool=$1
	_pfx=${2:-}
	[ -s "$_pool" ] || return 0
	_total=$(awk '{s += $3} END {print s + 0}' "$_pool")
	[ "$_total" -gt 0 ] || return 0
	_cum=0
	while read -r _if _dev _w _tbl _gw; do
		[ -n "${_if:-}" ] || continue
		_bit=$(bit_for_iface "$_if")
		[ -n "${_bit:-}" ] || continue
		_lo=$((_cum * 100 / _total))
		_cum=$((_cum + _w))
		_hi=$((_cum * 100 / _total - 1))
		[ "$_hi" -le 99 ] || _hi=99
		if [ "$_lo" -eq 0 ] && [ "$_hi" -eq 99 ]; then
			echo "		${_pfx}counter meta mark set meta mark | $_bit"
		else
			echo "		${_pfx}jhash ip daddr . th sport . th dport mod 100 seed $HASH_SEED $_lo-$_hi counter meta mark set meta mark | $_bit"
		fi
	done < "$_pool"
}

prepare_pools() {
	load_conf
	apply_quality
	if [ "$POOL_MODE" = proto ]; then
		filter_pool "$WORK_TCP" "$TCP_POOL_CSV"
		filter_pool "$WORK_UDP" "$UDP_POOL_CSV"
		if [ ! -s "$WORK_TCP" ] && [ ! -s "$WORK_UDP" ]; then
			log "WARN: MODE=proto but both pools empty after filter; falling back to shared"
			POOL_MODE=shared
			cp "$WORK" "$WORK_TCP"
			cp "$WORK" "$WORK_UDP"
		else
			# Empty side inherits the shared balanced pool so that protocol
			# is not blackholed when its dedicated cards are offline.
			if [ ! -s "$WORK_TCP" ]; then
				log "WARN: TCP_POOL empty/offline; TCP falls back to shared pool"
				cp "$WORK" "$WORK_TCP"
			fi
			if [ ! -s "$WORK_UDP" ]; then
				log "WARN: UDP_POOL empty/offline; UDP falls back to shared pool"
				cp "$WORK" "$WORK_UDP"
			fi
		fi
	else
		cp "$WORK" "$WORK_TCP"
		cp "$WORK" "$WORK_UDP"
	fi
	# Soft bias needs per-protocol weight vectors → emit via proto path.
	if [ "$BIAS" = 1 ]; then
		apply_bias_pool "$WORK_TCP" tcp
		apply_bias_pool "$WORK_UDP" udp
		POOL_MODE=proto
	fi
	assign_bits
	write_weight_snapshots
	printf '%s\n' "$POOL_MODE" > "$MODE_STATE"
}

build_spec() {
	singbox_mark
	_mark="$MARK_VALUE"
	{
		echo "table ip $NFT_TABLE {"
		echo "	chain out {"
		echo "		type route hook output priority mangle + 3; policy accept;"
		echo "		meta mark != $_mark counter return"
		echo "		meta l4proto != { tcp, udp } return"
		# LAN/management traffic carries the same mark (route.default_mark is
		# global, and the DIRECT outbound is marked too) but must never be
		# hashed onto a cellular WAN: mwan3's per-interface tables carry only a
		# default route, so a private destination would be sent out the modem.
		echo "		ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } counter return"
		if [ "$POOL_MODE" = proto ]; then
			# Comment line so SPEC fingerprint changes with mode even if
			# the two pools happen to equal the shared set.
			echo "		# mode=proto tcp=[$TCP_POOL_CSV] udp=[$UDP_POOL_CSV] q=$QUALITY b=$BIAS"
			emit_jhash "$WORK_TCP" "meta l4proto tcp "
			emit_jhash "$WORK_UDP" "meta l4proto udp "
		else
			echo "		# mode=shared q=$QUALITY"
			emit_jhash "$WORK" ""
		fi
		echo "	}"
		echo "}"
	} > "$SPEC.new"
}

build_rules() {
	: > "$RULES.new"
	[ -s "$BITS" ] || return 0
	while read -r _if _bit _off _dev _w _tbl _gw; do
		[ -n "${_if:-}" ] || continue
		echo "$((PREF_BASE + _off)) $_bit $_tbl $_if $_dev $_w $_gw" >> "$RULES.new"
	done < "$BITS"
}

# A rule is ours only if it carries our selector mask; mwan3's rules in the
# same pref range use 0x3f00 and are never touched.
rule_is_ours() {
	ip rule show 2>/dev/null | grep -q "^$1:.*fwmark 0x[0-9a-f]*/$SEL_MASK_HEX lookup "
}

drop_rules() {
	_p=$PREF_FLOOR
	while [ "$_p" -le "$PREF_CEIL" ]; do
		rule_is_ours "$_p" && ip rule del pref "$_p" 2>/dev/null
		_p=$((_p + 1))
	done
	return 0
}

add_rules() {
	while read -r _p _bits _tbl _rest; do
		[ -n "${_p:-}" ] || continue
		ip rule add pref "$_p" fwmark "$_bits/$SEL_MASK" lookup "$_tbl" 2>/dev/null || true
	done < "$RULES"
}

# True when a rule carrying our selector mask sits outside the current pool
# (e.g. left behind by a previous run or a weight change).
stray_rules() {
	_expected=$(awk '{print $1}' "$RULES" 2>/dev/null | tr '\n' ' ')
	for _p in $(ip rule show 2>/dev/null |
		sed -n "s/^\([0-9][0-9]*\):.*fwmark 0x[0-9a-f]*\/$SEL_MASK_HEX lookup .*/\1/p"); do
		case " $_expected " in
			*" $_p "*) ;;
			*) return 0 ;;
		esac
	done
	return 1
}

rules_present() {
	[ -s "$RULES" ] || return 1
	while read -r _p _bits _tbl _rest; do
		[ -n "${_p:-}" ] || continue
		ip rule show 2>/dev/null | grep -q "^$_p:.*lookup $_tbl\$" || return 1
	done < "$RULES"
	return 0
}

clear() {
	nft delete table ip "$NFT_TABLE" 2>/dev/null || true
	drop_rules
	rm -f "$SPEC" "$RULES" "$WORK_TCP" "$WORK_UDP" "$BITS" "$MODE_STATE" "$PRESET_STATE" \
		"$QSTATE" "$QDETAIL" "$WEIGHTS_TCP" "$WEIGHTS_UDP"
}

# Dry-run: build SPEC/RULES from a pre-seeded WORK (+ optional conf). No nft/ip.
render() {
	mkdir -p "$STATE"
	load_conf
	[ -s "$WORK" ] || {
		echo "render: $WORK is empty (seed iface rows first)" >&2
		return 1
	}
	prepare_pools
	build_spec
	build_rules
	mv "$SPEC.new" "$SPEC"
	mv "$RULES.new" "$RULES"
	echo "mode=$POOL_MODE"
	echo "--- spec ---"
	cat "$SPEC"
	echo "--- rules ---"
	cat "$RULES"
}

apply() {
	mkdir -p "$STATE"
	command -v nft >/dev/null 2>&1 || return 0
	load_conf
	collect
	if [ ! -s "$WORK" ]; then
		if [ -f "$SPEC" ]; then
			log "no usable WAN (all offline/unrouted); clearing"
			clear
		fi
		return 0
	fi
	prepare_pools
	build_spec
	build_rules
	# Log the mode note once per transition (this runs every 15 s from the
	# watchdog; unconditional logging would spam the state log).
	_mode_file="$STATE/wan-balance.mode"
	_prev_mode=$(cat "$_mode_file" 2>/dev/null || true)
	if [ "$MARK_SOURCE" != "$_prev_mode" ]; then
		if [ "$MARK_SOURCE" = default ]; then
			log "NOTE: route.default_mark $MARK_VALUE: core stamps it on every proxied packet; jhash chain is live."
			log "NOTE: verify three cards via nft counters and per-card rx deltas in /proc/net/dev."
		elif [ "$MARK_SOURCE" = ebpf ]; then
			log "WARN: eBPF config without \"default_mark\" (and no auto_route fwmark rule):"
			log "WARN: nothing stamps the bypass mark, the custom jhash chain is a no-op."
			log "WARN: add route.default_mark to config.json (eBPF mode has no TUN to supply it)."
		elif [ "$MARK_SOURCE" = fallback ]; then
			log "WARN: no auto_route fwmark rule found and config is not eBPF; assuming $FALLBACK_MARK."
			log "WARN: if the core no longer stamps SO_MARK, the nft rule matches nothing and"
			log "WARN: three-card balancing is a no-op. Check counters: $(basename "$0") status"
		fi
		echo "$MARK_SOURCE" > "$_mode_file" 2>/dev/null || true
	fi
	if cmp -s "$SPEC.new" "$SPEC" 2>/dev/null && cmp -s "$RULES.new" "$RULES" 2>/dev/null; then
		rm -f "$SPEC.new" "$RULES.new"
		if ! nft list chain ip "$NFT_TABLE" out >/dev/null 2>&1; then
			log "nft table missing; re-applied"
			nft -f "$SPEC" || return 1
		fi
		if ! rules_present || stray_rules; then
			drop_rules
			add_rules
		fi
		return 0
	fi
	mv "$SPEC.new" "$SPEC"
	mv "$RULES.new" "$RULES"
	nft delete table ip "$NFT_TABLE" 2>/dev/null || true
	if ! nft -f "$SPEC"; then
		log "nft apply failed; routing left on 5G"
		return 1
	fi
	drop_rules
	add_rules
	if [ "$POOL_MODE" = proto ]; then
		log "mode=proto tcp: $(awk '{printf "%s(%sw) ", $1, $3}' "$WORK_TCP") udp: $(awk '{printf "%s(%sw) ", $1, $3}' "$WORK_UDP")"
	else
		log "pool: $(awk '{printf "%s(%sw keep %s/%s) ", $1, $3, $5, $4}' "$WORK")"
	fi
}

pool() {
	[ -s "$WORK" ] || collect
	awk '{printf "%s(w%s,%s) ", $1, $3, $4}' "$WORK"
}

status() {
	load_conf
	echo "== preset =="
	echo "preset=$PRESET quality=$QUALITY bias=$BIAS"
	echo "== pool-mode =="
	echo "$POOL_MODE (conf: $CONF)"
	if [ "$POOL_MODE" = proto ]; then
		echo "TCP_POOL=$TCP_POOL_CSV"
		echo "UDP_POOL=$UDP_POOL_CSV"
	fi
	echo "== quality thresholds =="
	echo "enter lat/loss=${Q_ENTER_LATENCY}ms/${Q_ENTER_LOSS}% exit=${Q_EXIT_LATENCY}/${Q_EXIT_LOSS} drop=${Q_DROP_LATENCY}/${Q_DROP_LOSS} weak_scale=${Q_WEAK_SCALE}%"
	if [ -s "$QDETAIL" ]; then
		echo "== quality detail =="
		cat "$QDETAIL"
	fi
	echo "== pool shared (iface dev weight gateway table) =="
	[ -s "$WORK" ] || collect
	cat "$WORK" 2>/dev/null
	if [ -s "$WORK_TCP" ] || [ -s "$WORK_UDP" ]; then
		echo "== pool tcp =="
		cat "$WORK_TCP" 2>/dev/null || echo "(none)"
		echo "== pool udp =="
		cat "$WORK_UDP" 2>/dev/null || echo "(none)"
	fi
	singbox_mark
	_mark="$MARK_VALUE"
	echo "== bypass mark =="
	echo "$_mark (source: $MARK_SOURCE)"
	if [ "$MARK_SOURCE" = default ]; then
		echo "NOTE: default_mark=$_mark (eBPF mode has no TUN; the core stamps"
		echo "      route.default_mark itself, so the jhash chain below is live)."
		echo "      Verify with the nft counters and the per-card rx deltas"
		echo "      (/proc/net/dev) under load on all three cards."
	elif [ "$MARK_SOURCE" = ebpf ]; then
		echo "NOTE: eBPF config has no route.default_mark and there is no auto_route"
		echo "      rule — nothing stamps the mark, the jhash chain is a no-op."
		echo "      Add route.default_mark to config.json and re-apply."
	elif [ "$MARK_SOURCE" = fallback ]; then
		echo "NOTE: fallback mark assumed; no TUN auto_route rule and no config mark —"
		echo "      verify the chain counters below actually increase under load."
	fi
	echo "== ip rules =="
	ip rule show 2>/dev/null | sed -n "/lookup/ p" | grep -E "^[0-9]+:.*fwmark 0x[0-9a-f]*/$SEL_MASK_HEX " || echo "(none)"
	echo "== nft chain (counters show real hits) =="
	nft list chain ip "$NFT_TABLE" out 2>/dev/null || echo "(none)"
}

case "${1:-apply}" in
	apply) apply ;;
	pool) pool ;;
	status) status ;;
	clear) clear; log "cleared by request" ;;
	render) render ;;
	preset-list) preset_list ;;
	preset-get) preset_get ;;
	preset-set) preset_set "${2:-}" ;;
	*) echo "usage: $0 {apply|pool|status|clear|render|preset-list|preset-get|preset-set}" >&2; exit 2 ;;
esac
