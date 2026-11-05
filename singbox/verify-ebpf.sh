#!/bin/sh
# Post-deploy verification for the TUN <-> eBPF profiles (TopFlow MU5252 B20).
#
# Runs ON THE DEVICE and answers one question: does the deployed config do what
# the migration phase claims?  Read-only apart from the optional download
# burst (which only sets WAN and observability counters):
#   * static  : `sing-box check`, JSON structure (jq or jsonfilter), inbound
#               type (tun vs ebpf), local/shared data planes, zero-direct
#               routing, DNS exemptions, diagnostics 8088 vs Clash 9999;
#   * runtime : Clash API /version + /observability, native `api ebpf` on 8088,
#               sbtun0 state, mark source (rule vs default), fragment guard,
#               singbox-wan-balance.sh status, per-card rx across a burst.
#
# Usage:
#   sh verify-ebpf.sh                  # static + runtime + download test
#   sh verify-ebpf.sh --static         # config file only, core may be stopped
#   sh verify-ebpf.sh --no-load        # skip the concurrent download burst
#   sh verify-ebpf.sh --quiet-load     # download burst without per-card detail
#
# Environment:
#   SINGBOX_BASE=/data/sing-box            base directory
#   SINGBOX_CONFIG=$BASE/config.json       config to inspect (deploy.sh may
#                                          point this at config.json.new before
#                                          the atomic move; unchanged by us)
#   SINGBOX_API=http://127.0.0.1:9999      Clash controller
#   SINGBOX_API_SECRET=...                 sends Authorization: Bearer
#   SINGBOX_DIAG_API=http://127.0.0.1:8088 native gRPC API (api ebpf)
#   SINGBOX_BALANCE=$BASE/singbox-wan-balance.sh
#   WAN_DEVICES="rmnet_data0 V3E1net0 V3E2net0"
#   VERIFY_DOWNLOAD_URL=https://speed.cloudflare.com/__down?bytes=8000000
#   VERIFY_LOAD_CONCURRENCY=6              parallel downloads
#   VERIFY_LOAD_TIMEOUT=20                 per-download --max-time (s)
#   VERIFY_MIN_ACTIVE=3                    cards that must move bytes
#
# Exit codes: 0 = every check PASS/SKIP, 1 = at least one FAIL, 2 = bad usage.
#
# JSON structure checks need `jq` (workstation) or `jsonfilter` (OpenWrt).  If
# neither exists the structural section is SKIP, never a silent PASS; the
# remaining `sing-box check`/runtime checks still run.  Predicates are applied
# to values emitted by a real JSON parser, never to whitespace/indentation
# guesses, so a minified or reformatted config is checked identically.
#
# Note on scope: the mixed/-x probe only proves the proxy stack; the no-`-x`
# probe is device-originated (TUN or the eBPF local hook).  Neither proves
# LAN-client capture through shared.packet_rewrite/socket_assign, and
# `api ebpf` reports runtime attachment state, not client forwarding.  LAN
# capture can only be proven from a br-lan client.

set -u

BASE="${SINGBOX_BASE:-/data/sing-box}"
BIN="$BASE/sing-box"
CONF="${SINGBOX_CONFIG:-$BASE/config.json}"
API="${SINGBOX_API:-http://127.0.0.1:9999}"
DIAG_API="${SINGBOX_DIAG_API:-http://127.0.0.1:8088}"
SECRET="${SINGBOX_API_SECRET:-}"
BALANCE="${SINGBOX_BALANCE:-$BASE/singbox-wan-balance.sh}"
STATE="${SINGBOX_STATE:-$BASE/state}"
WAN_DEVICES="${WAN_DEVICES:-rmnet_data0 V3E1net0 V3E2net0}"
PROXY="http://127.0.0.1:7890"
DOWNLOAD_URL="${VERIFY_DOWNLOAD_URL:-https://speed.cloudflare.com/__down?bytes=8000000}"
LOAD_N="${VERIFY_LOAD_CONCURRENCY:-6}"
LOAD_TIMEOUT="${VERIFY_LOAD_TIMEOUT:-20}"
MIN_ACTIVE="${VERIFY_MIN_ACTIVE:-3}"
STATIC_ONLY=0
DO_LOAD=1
VERBOSE_LOAD=1

# Must match singbox/convert.py.
MIANLIU_TAG='🚀 免流模式'
DIRECT_GROUP='🟢 直连模式'
BOOTSTRAP_ADDR='223.5.5.5'
PRIVATE_SETS='private-domain private-ip'

PASS=0
FAIL=0
SKIP=0

# Filled in by static_checks() and reused by runtime_checks(); never assume a
# value before the static section runs.
JSON_TOOL=''
CONF_READY=0
EBPF_CONFIG=0
SHARED_CONFIG=0
ALLPROXY=0
DIAG_DECLARED=0
NONBASE=0

usage() {
	cat <<'EOF'
usage: verify-ebpf.sh [--static] [--no-load] [--quiet-load]

  --static      check config.json only (works while the core is stopped)
  --no-load     skip the concurrent download burst
  --quiet-load  run the download burst, print only the verdict line
  -h, --help    this text

Exit 0 = all PASS/SKIP, 1 = at least one FAIL, 2 = bad usage.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--static) STATIC_ONLY=1 ;;
	--no-load) DO_LOAD=0 ;;
	--quiet-load) VERBOSE_LOAD=0 ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "unknown argument: $1" >&2
		usage >&2
		exit 2
		;;
	esac
	shift
done

ok() { PASS=$((PASS + 1)); echo "PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $*"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP  $*"; }
info() { echo "      $*"; }

for _pair in "concurrency:$LOAD_N" "timeout:$LOAD_TIMEOUT" "min_active:$MIN_ACTIVE"; do
	_val="${_pair#*:}"
	case "$_val" in
	'' | *[!0-9]*)
		echo "${_pair%%:*}: expected a positive integer, got '$_val'" >&2
		exit 2
		;;
	esac
	[ "$_val" -gt 0 ] || {
		echo "${_pair%%:*}: must be > 0" >&2
		exit 2
	}
done

api_get() {
	if [ -n "$SECRET" ]; then
		curl -fsS -m 3 -H "Authorization: Bearer $SECRET" "$API$1" 2>/dev/null
	else
		curl -fsS -m 3 "$API$1" 2>/dev/null
	fi
}

json_total() {
	sed -n 's/.*"total"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | sed -n '1p'
}

human_bytes() {
	awk -v b="${1:-0}" 'BEGIN {
		split("B KiB MiB GiB TiB", u, " ")
		i = 1
		while (b >= 1024 && i < 5) { b /= 1024; i++ }
		printf "%.1f %s", b, u[i]
	}'
}

core_pid() {
	_pid=$(cat "$STATE/sing-box.pid" 2>/dev/null) || _pid=""
	if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
		echo "$_pid"
	fi
}

# ------------------------------------------------------------------- JSON
# One parser for both hosts: jq on the workstation, jsonfilter on OpenWrt.
# `jsonfilter` prints strings raw and objects/arrays as compact JSON, one
# value per line, so the shell only ever sees parser-emitted values.
json_tool() {
	[ -n "$JSON_TOOL" ] && {
		[ "$JSON_TOOL" != none ]
		return
	}
	if command -v jq >/dev/null 2>&1; then
		JSON_TOOL=jq
	elif command -v jsonfilter >/dev/null 2>&1; then
		JSON_TOOL=jsonfilter
	else
		JSON_TOOL=none
	fi
	[ "$JSON_TOOL" != none ]
}

json_validate() {
	case "$JSON_TOOL" in
	jq) jq -e . "$CONF" >/dev/null 2>&1 ;;
	jsonfilter) jsonfilter -i "$CONF" -e '@.inbounds[*].type' >/dev/null 2>&1 ;;
	*) return 1 ;;
	esac
}

jraw() { # jraw <jq-filter> <jsonfilter-path>
	case "$JSON_TOOL" in
	jq) jq -r "$1" "$CONF" 2>/dev/null | tr -d '\r' ;;
	jsonfilter) jsonfilter -i "$CONF" -e "$2" 2>/dev/null | tr -d '\r' ;;
	esac
}

jval() { # scalar, null folded to empty
	_v=$(jraw "$1" "$2")
	case "$_v" in null) _v='' ;; esac
	printf '%s\n' "$_v"
}

jcount() { # jcount <jq-length-filter> <jsonfilter-wildcard-path>
	case "$JSON_TOOL" in
	jq) jq -r "$1" "$CONF" 2>/dev/null ;;
	jsonfilter) jsonfilter -i "$CONF" -e "$2" 2>/dev/null | grep -c . ;;
	esac
}

jfile_raw() { # jfile_raw <file> <jq-filter> <jsonfilter-path>
	case "$JSON_TOOL" in
	jq) jq -r "$2" "$1" 2>/dev/null | tr -d '\r' ;;
	jsonfilter) jsonfilter -i "$1" -e "$3" 2>/dev/null | tr -d '\r' ;;
	esac
}

json_file_valid() {
	case "$JSON_TOOL" in
	jq) jq -e 'has("schemaVersion") or has("schema_version")' "$1" >/dev/null 2>&1 ;;
	jsonfilter)
		jsonfilter -i "$1" -e '@.schemaVersion' >/dev/null 2>&1 ||
			jsonfilter -i "$1" -e '@.schema_version' >/dev/null 2>&1
		;;
	*) return 1 ;;
	esac
}

is_direct_tag() {
	# DIRECT tags come from the parsed `type` field, not from a display name.
	# Literal "DIRECT" is also rejected because a member that does not resolve
	# to an outbound still fails `sing-box check` and must never be generated.
	case "
$DIRECT_TAGS
DIRECT
" in *"
$1
"*) return 0 ;; esac
	return 1
}

# --------------------------------------------------------------- direct map
# Normalize outbounds into "O<TAB>tag<TAB>type<TAB>default" and
# "M<TAB>tag<TAB>member" lines.  The values came out of jq/jsonfilter; awk
# here only does graph reachability, it never parses raw config text.
collect_outbounds() {
	_out=$1
	_n=$(jcount '.outbounds | length' '@.outbounds[*].tag')
	_i=0
	while [ "$_i" -lt "${_n:-0}" ]; do
		_tag=$(jval ".outbounds[$_i].tag" "@.outbounds[$_i].tag")
		_type=$(jval ".outbounds[$_i].type" "@.outbounds[$_i].type")
		_def=$(jval ".outbounds[$_i].default" "@.outbounds[$_i].default")
		if [ -n "$_tag" ]; then
			printf 'O\t%s\t%s\t%s\n' "$_tag" "$_type" "$_def" >>"$_out"
			jraw ".outbounds[$_i].outbounds[]?" "@.outbounds[$_i].outbounds[*]" |
				while IFS= read -r _m; do
					[ -n "$_m" ] && printf 'M\t%s\t%s\n' "$_tag" "$_m" >>"$_out"
				done
		fi
		_i=$((_i + 1))
	done
}

# Taint = "can reach a direct outbound".  Fixed point over selector/urltest/
# loadbalance members and defaults catches deep aliases whose display name
# says nothing about their contents.
analyze_outbound_graph() { # <file> <final-tag>
	awk -F '\t' -v final="$2" -v group="$DIRECT_GROUP" '
		$1 == "O" {
			tag[++n] = $2
			ty[$2] = tolower($3)
			df[$2] = $4
		}
		$1 == "M" { mb[$2] = mb[$2] $3 "\034" }
		END {
			for (i = 1; i <= n; i++) {
				t = tag[i]
				if (ty[t] == "direct" || t == "DIRECT") taint[t] = 1
			}
			do {
				changed = 0
				for (i = 1; i <= n; i++) {
					t = tag[i]
					if (ty[t] != "selector" && ty[t] != "urltest" && ty[t] != "loadbalance") continue
					if (taint[t]) continue
					hit = 0
					k = split(mb[t], a, "\034")
					for (j = 1; j <= k; j++)
						if (a[j] != "" && (a[j] == "DIRECT" || taint[a[j]])) { hit = 1; break }
					if (!hit && df[t] != "" && (df[t] == "DIRECT" || taint[df[t]])) hit = 1
					if (hit) { taint[t] = 1; changed = 1 }
				}
			} while (changed)
			for (i = 1; i <= n; i++) {
				t = tag[i]
				if (t == group) printf "GROUP\t%s\n", t
				if ((ty[t] == "selector" || ty[t] == "urltest" || ty[t] == "loadbalance") && taint[t])
					printf "TAINT\t%s\t%s\n", ty[t], t
			}
			if (final != "" && (final == "DIRECT" || taint[final])) printf "FINAL\t%s\n", final
		}
	' "$1" 2>/dev/null
}

# -------------------------------------------------------------- rule audit
# A DIRECT rule may only carry private-domain/private-ip rule-sets: no empty
# match (would match the whole internet), no invert (would invert the private
# sets into a public match), no public rule-set names.
rule_audit() { # prints offenders; updates RULE_BAD
	RULE_BAD=0
	_n=$(jcount '.route.rules | length' '@.route.rules[*]')
	_i=0
	while [ "$_i" -lt "${_n:-0}" ]; do
		_ob=$(jval ".route.rules[$_i].outbound" "@.route.rules[$_i].outbound")
		if [ -n "$_ob" ] && is_direct_tag "$_ob"; then
			_why=''
			_inv=$(jval ".route.rules[$_i].invert" "@.route.rules[$_i].invert")
			[ "$_inv" = true ] && _why="inverted match"
			_sets=$(jraw ".route.rules[$_i].rule_set[]?" "@.route.rules[$_i].rule_set[*]" | tr '\n' ' ')
			if [ -z "$_sets" ]; then
				[ -n "$_why" ] || _why="empty match (no private rule-set)"
			else
				for _s in $_sets; do
					case " $PRIVATE_SETS " in
					*" $_s "*) ;;
					*) _why="${_why:+$_why; }rule_set $_s is not private" ;;
					esac
				done
			fi
			for _k in domain domain_suffix domain_keyword domain_regex ip_cidr ip_is_private \
				geoip geosite port port_range network protocol process_name package_name; do
				_v=$(jval ".route.rules[$_i].$_k" "@.route.rules[$_i].$_k")
				[ -n "$_v" ] && _why="${_why:+$_why; }$_k condition"
			done
			if [ -n "$_why" ]; then
				RULE_BAD=$((RULE_BAD + 1))
				printf '      #%s -> %s: %s\n' "$_i" "$_ob" "$_why"
			fi
		fi
		_i=$((_i + 1))
	done
	[ "$RULE_BAD" -eq 0 ]
}

# ------------------------------------------------------------------ config
static_checks() {
	echo "== config =="
	echo "file  : $CONF"
	CONF_READY=0
	EBPF_CONFIG=0
	SHARED_CONFIG=0
	ALLPROXY=0
	DIAG_DECLARED=0
	NONBASE=0
	if [ ! -f "$CONF" ]; then
		bad "config.json missing"
		return 0
	fi
	if [ ! -x "$BIN" ]; then
		bad "sing-box binary missing: $BIN (cannot validate the config)"
	else
		_out=$("$BIN" check -c "$CONF" 2>&1)
		_rc=$?
		# The 1.14 fork prints nothing on success and one FATAL line on failure.
		_first=$(printf '%s\n' "$_out" | sed -n '1p')
		if [ "$_rc" -eq 0 ]; then
			ok "sing-box check rc=0"
		else
			bad "sing-box check rc=$_rc ${_first:+(${_first})}"
		fi
	fi

	if ! json_tool; then
		bad "structured config checks need jq or jsonfilter on PATH (no indentation fallback)"
		return 0
	fi
	if ! json_validate; then
		bad "config is not valid JSON (parser: $JSON_TOOL)"
		return 0
	fi
	CONF_READY=1

	_final=$(jval '.route.final' '@.route.final')
	case "$_final" in "$MIANLIU_TAG") ALLPROXY=1 ;; esac

	_in_n=$(jcount '.inbounds | length' '@.inbounds[*].type')
	_ebpf_i=''
	_tun_i=''
	_i=0
	while [ "$_i" -lt "${_in_n:-0}" ]; do
		_t=$(jval ".inbounds[$_i].type" "@.inbounds[$_i].type")
		case "$_t" in
		ebpf) _ebpf_i=$_i ;;
		tun) _tun_i=$_i ;;
		esac
		_i=$((_i + 1))
	done

	_obs=$(jval '.experimental.observability.enabled' '@.experimental.observability.enabled')
	[ "$_obs" = true ] && NONBASE=1

	if [ -n "$_ebpf_i" ]; then
		EBPF_CONFIG=1
		ok "inbound: ebpf (no TUN)"
		[ -n "$_tun_i" ] && bad "both ebpf and tun inbounds present (eBPF profile must not own a TUN)"
		_l_en=$(jval ".inbounds[$_ebpf_i].local.enabled" "@.inbounds[$_ebpf_i].local.enabled")
		_l_dp=$(jval ".inbounds[$_ebpf_i].local.data_plane" "@.inbounds[$_ebpf_i].local.data_plane")
		if [ "$_l_en" = true ]; then
			ok "local.enabled=true (data_plane=${_l_dp:-?})"
		else
			bad "local.enabled is not true"
		fi
		# Both local planes are legitimate in this build; the A/B is allowed on
		# either hook.  `tc` names no plane here and is refused by name (no
		# alias), and an empty/unknown value is a typo, not a default.
		case "${_l_dp:-}" in
		cgroup | socket_assign) ;;
		tc) bad "local.data_plane=tc is not a plane in this build; use socket_assign (no tc alias)" ;;
		'') bad "local hook has no data_plane" ;;
		*) bad "local.data_plane=${_l_dp} (expected cgroup or socket_assign)" ;;
		esac

		_sh_en=$(jval ".inbounds[$_ebpf_i].shared.enabled" "@.inbounds[$_ebpf_i].shared.enabled")
		_sh_dp=$(jval ".inbounds[$_ebpf_i].shared.data_plane" "@.inbounds[$_ebpf_i].shared.data_plane")
		if [ -z "$_sh_en" ]; then
			# local-only leaves every LAN client outside the data plane: their
			# traffic leaves on the SIM as real data.  Minutes-long test only.
			bad "no shared hook: LAN clients are NOT captured (direct egress = real data)"
			info "        local-only is a test window only; deploy a shared profile before handing the link back"
		elif [ "$_sh_en" = true ]; then
			SHARED_CONFIG=1
			ok "shared.enabled=true (data_plane=${_sh_dp:-?})"
			case "$_sh_dp" in
			packet_rewrite | socket_assign) ;;
			'') bad "shared hook has no data_plane (expected packet_rewrite or socket_assign)" ;;
			*) bad "shared.data_plane=${_sh_dp} (expected packet_rewrite or socket_assign)" ;;
			esac
			_iface=$(jraw ".inbounds[$_ebpf_i].shared.interface[]?" "@.inbounds[$_ebpf_i].shared.interface[*]" | tr '\n' ' ')
			info "interface: ${_iface:-?}"
			if [ "$_sh_dp" = packet_rewrite ] && [ -z "$_iface" ]; then
				bad "shared packet_rewrite has no interface (needs the LAN ethernet bridge)"
			fi
			_bp=$(jcount ".inbounds[$_ebpf_i].shared.bypass_port | length" "@.inbounds[$_ebpf_i].shared.bypass_port[*]")
			if [ "$ALLPROXY" = 1 ] && [ "${_bp:-0}" -gt 0 ]; then
				bad "all-proxy shared.bypass_port has ${_bp} port(s): bypassed public ports are direct egress"
			else
				info "bypass_port: ${_bp:-0} entr(ies)"
			fi
			info "bypass_private_address: $(jval ".inbounds[$_ebpf_i].shared.bypass_private_address" "@.inbounds[$_ebpf_i].shared.bypass_private_address")"
			info "shared capture can only be proven from a br-lan client; static scope is deployment, not forwarding"
		else
			bad "shared block present but enabled != true"
		fi

		_dm=$(jval '.route.default_mark' '@.route.default_mark')
		case "$_dm" in
		8228 | 0x2024 | 0X2024) ok "route.default_mark=${_dm} (0x2024)" ;;
		'') bad "eBPF config has no route.default_mark (nothing stamps 0x2024 for wan-balance)" ;;
		*) bad "route.default_mark=${_dm} (contract: 8228 / 0x2024)" ;;
		esac

		if [ "$ALLPROXY" = 1 ]; then
			_l6=$(jval ".inbounds[$_ebpf_i].local.ipv6" "@.inbounds[$_ebpf_i].local.ipv6")
			[ "$_l6" = true ] || bad "all-proxy local hook lacks ipv6=true (v6 would leave unproxied)"
			if [ "$SHARED_CONFIG" = 1 ]; then
				_s6=$(jval ".inbounds[$_ebpf_i].shared.ipv6" "@.inbounds[$_ebpf_i].shared.ipv6")
				[ "$_s6" = true ] || bad "all-proxy shared hook lacks ipv6=true (v6 would leave unproxied)"
			fi
		else
			info "ipv6: local=$(jval ".inbounds[$_ebpf_i].local.ipv6" "@.inbounds[$_ebpf_i].local.ipv6") shared=$(jval ".inbounds[$_ebpf_i].shared.ipv6" "@.inbounds[$_ebpf_i].shared.ipv6")"
		fi
	else
		ok "inbound: TUN stack"
		if [ -n "$_tun_i" ]; then
			info "tun-in present (interface $(jval ".inbounds[$_tun_i].interface_name" "@.inbounds[$_tun_i].interface_name"))"
		else
			bad "no tun-in and no ebpf inbound"
		fi
		_dm=$(jval '.route.default_mark' '@.route.default_mark')
		if [ -n "$_dm" ]; then
			bad "TUN config carries route.default_mark=${_dm} (conflicts with tun.auto_redirect)"
		else
			ok "no route.default_mark (TUN auto_route supplies the bypass mark)"
		fi
		if [ "$ALLPROXY" = 1 ] && [ -n "$_tun_i" ]; then
			_v6=$(jraw ".inbounds[$_tun_i].route_address[]?" "@.inbounds[$_tun_i].route_address[*]" | grep -cx '::/0')
			if [ "${_v6:-0}" -gt 0 ]; then
				ok "TUN captures IPv6 (route_address ::/0)"
			else
				bad "all-proxy TUN does not route ::/0 (IPv6 would bypass the proxy)"
			fi
		fi
	fi

	# Profile split: all-proxy accepts no automatic direct path at all; the
	# ordinary profiles keep the manual 🟢 直连模式 override by design.
	if [ "$ALLPROXY" = 1 ]; then
		info "profile: all-proxy (route.final=$MIANLIU_TAG)"
	else
		info "profile: non-all-proxy (route.final=${_final:-?}); manual direct override retained"
	fi

	_tmpd="${TMPDIR:-/tmp}/verify-ebpf.$$"
	if ! mkdir -p "$_tmpd" 2>/dev/null; then
		_tmpd=''
	fi
	_objs="${_tmpd:-/dev/null}/outbounds"
	: >"$_objs" 2>/dev/null || _objs=''
	if [ -n "$_objs" ]; then
		collect_outbounds "$_objs"
	else
		bad "cannot create a temp file for the normalized outbound map"
	fi
	DIRECT_TAGS=''
	[ -n "$_objs" ] && DIRECT_TAGS=$(awk -F '\t' '$1 == "O" && tolower($3) == "direct" { print $2 }' "$_objs" 2>/dev/null)
	if [ -n "$_final" ] && is_direct_tag "$_final"; then
		bad "route.final is the DIRECT outbound '$_final' (default egress would be unproxied)"
	fi

	if [ "$ALLPROXY" = 1 ] && [ -n "$_objs" ]; then
		_graph=$(analyze_outbound_graph "$_objs" "$_final")
		if [ -n "$_graph" ]; then
			bad "DIRECT is reachable from the automatic path:"
			printf '%s\n' "$_graph" | while IFS='	' read -r _kind _a _b; do
				case "$_kind" in
				GROUP) info "forbidden group present: $_a" ;;
				TAINT) info "$_a $_b can reach DIRECT" ;;
				FINAL) info "route.final $_a can reach DIRECT" ;;
				esac
			done
		else
			ok "no DIRECT reachable from selector/urltest/loadbalance members, defaults, or final"
		fi
		if [ -n "$DIRECT_TAGS" ]; then
			info "direct outbounds present for private routing only: $(printf '%s' "$DIRECT_TAGS" | tr '\n' ' ')"
		fi
	fi

	if [ -z "$_objs" ]; then
		bad "cannot audit DIRECT route rules without the outbound map"
	elif rule_audit; then
		ok "DIRECT route rules are private-only and non-inverted"
	else
		bad "public/empty/inverted DIRECT route rule(s) present"
	fi

	[ -n "$_tmpd" ] && rm -rf "$_tmpd"

	# --------------------------------------------------------------- DNS
	dns_checks

	# ------------------------------------------------------- APIs / services
	api_config_checks
}

# All-proxy exemptions are exact: bootstrap = udp/223.5.5.5 without detour,
# fakeip is local, every other resolver must detour through the proxy.  An
# extra plain udp server or a detoured bootstrap fails.  Non-all-proxy keeps
# its historical resolver set (a direct node resolver), so only the bootstrap
# invariant is enforced there.
dns_checks() {
	echo "== dns =="
	_n=$(jcount '.dns.servers | length' '@.dns.servers[*].tag')
	_i=0
	_boot=0
	_fake=0
	_bad=0
	while [ "$_i" -lt "${_n:-0}" ]; do
		_tag=$(jval ".dns.servers[$_i].tag" "@.dns.servers[$_i].tag")
		_type=$(jval ".dns.servers[$_i].type" "@.dns.servers[$_i].type")
		_server=$(jval ".dns.servers[$_i].server" "@.dns.servers[$_i].server")
		_detour=$(jval ".dns.servers[$_i].detour" "@.dns.servers[$_i].detour")
		if [ "$_tag" = bootstrap ]; then
			_boot=$((_boot + 1))
			if [ "$_type" != udp ] || [ "$_server" != "$BOOTSTRAP_ADDR" ] || [ -n "$_detour" ]; then
				bad "bootstrap must be exactly udp/$BOOTSTRAP_ADDR with no detour (got ${_type:-?}/${_server:-?}${_detour:+, detour=$_detour})"
				_bad=$((_bad + 1))
			fi
		elif [ "$_type" = fakeip ]; then
			_fake=1
			[ -n "$_detour" ] && {
				bad "fakeip answers locally but has detour=$_detour"
				_bad=$((_bad + 1))
			}
		elif [ "$ALLPROXY" != 1 ]; then
			info "resolver ${_tag:-?} (${_type:-?} ${_server:-?}) detour=${_detour:-none} (non-all-proxy)"
		elif [ "$_type" = udp ]; then
			bad "extra unproxied UDP resolver '${_tag:-?}' ($_server): only bootstrap/$BOOTSTRAP_ADDR may use udp"
			_bad=$((_bad + 1))
		else
			case "$_type" in
			hosts | local) ;;
			*)
				if [ -z "$_detour" ]; then
					bad "DNS server '${_tag:-?}' ($_type ${_server:-?}) has no detour"
					_bad=$((_bad + 1))
				elif is_direct_tag "$_detour"; then
					bad "DNS server '${_tag:-?}' detours through DIRECT ($_detour)"
					_bad=$((_bad + 1))
				fi
				;;
			esac
		fi
		_i=$((_i + 1))
	done
	[ "$_boot" -eq 0 ] && {
		bad "no bootstrap resolver (expected exactly udp/$BOOTSTRAP_ADDR)"
		_bad=$((_bad + 1))
	}
	[ "$_boot" -gt 1 ] && {
		bad "$_boot bootstrap resolvers (expected exactly one)"
		_bad=$((_bad + 1))
	}
	[ "$_fake" -eq 0 ] && {
		bad "no fakeip server"
		_bad=$((_bad + 1))
	}
	if [ "$_bad" -eq 0 ]; then
		if [ "$ALLPROXY" = 1 ]; then
			ok "DNS: bootstrap udp/$BOOTSTRAP_ADDR only, fakeip local, every other server proxied"
		else
			ok "DNS: bootstrap udp/$BOOTSTRAP_ADDR and fakeip present (non-all-proxy resolver set retained)"
		fi
	fi

	# AAAA must reach fakeip before geo rules can answer a real AAAA, and the
	# AAAA fakeip rule must precede the A fakeip rule.  This is the all-proxy
	# dual-stack contract; ordinary profiles keep their historical rule order.
	if [ "$ALLPROXY" = 1 ]; then
		_rn=$(jcount '.dns.rules | length' '@.dns.rules[*].server')
		_ri=0
		_aaaa=-1
		_a=-1
		while [ "$_ri" -lt "${_rn:-0}" ]; do
			_srv=$(jval ".dns.rules[$_ri].server" "@.dns.rules[$_ri].server")
			_qt=$(jraw ".dns.rules[$_ri].query_type[]?" "@.dns.rules[$_ri].query_type[*]")
			if printf '%s\n' "$_qt" | grep -qx AAAA; then
				if [ "$_srv" = fakeip ]; then
					[ "$_aaaa" -lt 0 ] && _aaaa=$_ri
				elif [ "$_aaaa" -lt 0 ]; then
					bad "DNS rule #$_ri answers AAAA via '${_srv:-?}' before the fakeip rule"
				fi
			fi
			if printf '%s\n' "$_qt" | grep -qx A && [ "$_srv" = fakeip ] && [ "$_a" -lt 0 ]; then
				_a=$_ri
			fi
			_ri=$((_ri + 1))
		done
		if [ "$_aaaa" -lt 0 ]; then
			bad "no query_type AAAA -> fakeip DNS rule (v6 would resolve to real addresses)"
		elif [ "$_a" -ge 0 ] && [ "$_aaaa" -gt "$_a" ]; then
			bad "A->fakeip precedes AAAA->fakeip (AAAA priority lost)"
		else
			ok "AAAA -> fakeip precedes A and other answering rules"
		fi
	fi
	return 0
}

api_config_checks() {
	echo "== apis =="
	_ctrl=$(jval '.experimental.clash_api.external_controller' '@.experimental.clash_api.external_controller')
	_secret=$(jval '.experimental.clash_api.secret' '@.experimental.clash_api.secret')
	case "$_ctrl" in
	*:9999) ok "Clash API controller ${_ctrl} (dashboard/observability, not gRPC)" ;;
	'') bad "experimental.clash_api.external_controller missing" ;;
	*) bad "Clash API controller is '${_ctrl}' (expected port 9999)" ;;
	esac
	if [ -z "$_secret" ]; then
		ok "Clash API secret stays empty"
	else
		bad "Clash API secret is set (contract: empty)"
	fi

	_sn=$(jcount '.services | length' '@.services[*].type')
	_si=0
	_diag=0
	_apis=0
	while [ "$_si" -lt "${_sn:-0}" ]; do
		_st=$(jval ".services[$_si].type" "@.services[$_si].type")
		if [ "$_st" = api ]; then
			_apis=$((_apis + 1))
			_tag=$(jval ".services[$_si].tag" "@.services[$_si].tag")
			_listen=$(jval ".services[$_si].listen" "@.services[$_si].listen")
			_port=$(jval ".services[$_si].listen_port" "@.services[$_si].listen_port")
			_dash=$(jval ".services[$_si].dashboard" "@.services[$_si].dashboard")
			_ssec=$(jval ".services[$_si].secret" "@.services[$_si].secret")
			if [ "$_tag" = diagnostics-api ] || [ "$_port" = 8088 ]; then
				_diag=1
				if [ "$_tag" != diagnostics-api ] || [ "$_listen" != 127.0.0.1 ] || [ "$_port" != 8088 ]; then
					bad "diagnostics API must be tag=diagnostics-api listen=127.0.0.1 port=8088 (got tag=${_tag:-?} listen=${_listen:-?} port=${_port:-?})"
				elif [ -n "$_dash" ] || [ -n "$_ssec" ]; then
					bad "diagnostics API must carry no dashboard/secret"
				else
					ok "native diagnostics API on 127.0.0.1:8088 (gRPC, separate from Clash 9999)"
				fi
			fi
			[ "$_port" = 9999 ] && bad "services.api listens on 9999 (collides with the Clash controller)"
		fi
		_si=$((_si + 1))
	done

	if [ "$_diag" = 0 ]; then
		if [ "$EBPF_CONFIG" = 1 ] && [ "$NONBASE" = 1 ]; then
			bad "non-base eBPF profile lacks services api tag=diagnostics-api 127.0.0.1:8088"
		elif [ "$NONBASE" = 1 ]; then
			skip "native diagnostics API not declared (baseline TUN: Clash 9999 remains the only API)"
		else
			info "base profile: no diagnostics service required"
		fi
	elif [ "$_apis" -gt 1 ]; then
		info "$_apis api services declared"
	fi
	DIAG_DECLARED=$_diag
}

# ----------------------------------------------------------------- runtime
# Bounded child: the device has no standalone `timeout`, so a background
# watcher escalates TERM -> KILL and the caller reads the captured file.
bounded_capture() { # <outfile> <seconds> <cmd...>
	_bc_out=$1
	_bc_secs=$2
	shift 2
	"$@" >"$_bc_out" 2>&1 &
	_bc_pid=$!
	(
		sleep "$_bc_secs"
		kill -TERM "$_bc_pid" 2>/dev/null
		sleep 1
		kill -KILL "$_bc_pid" 2>/dev/null
	) &
	_bc_watch=$!
	wait "$_bc_pid"
	_bc_rc=$?
	kill "$_bc_watch" 2>/dev/null
	wait "$_bc_watch" 2>/dev/null
	return "$_bc_rc"
}

runtime_checks() {
	echo ""
	echo "== runtime =="
	_pid=$(core_pid)
	if [ -z "$_pid" ]; then
		bad "core not running (start it, then re-run without --static)"
		return 0
	fi
	ok "core running pid=$_pid"

	_ver=$(api_get /version | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')
	if [ -n "$_ver" ]; then
		ok "Clash API 9999 /version: $_ver"
	else
		bad "Clash API 9999 /version unreachable ($API)"
	fi

	# A stale capture path is the classic half-applied deploy: the new config
	# says ebpf while the running core still owns sbtun0 (or the reverse).
	if [ "$EBPF_CONFIG" = 1 ]; then
		if ip link show sbtun0 >/dev/null 2>&1; then
			bad "stale sbtun0 present while config is eBPF -> restart the core"
		else
			ok "no sbtun0 (expected for eBPF)"
		fi
	else
		if ip link show sbtun0 >/dev/null 2>&1; then
			ok "sbtun0 present (expected for TUN)"
		else
			bad "sbtun0 missing while config is TUN"
		fi
	fi

	_active=$(api_get /observability/v1/connections/active)
	if [ -z "$_active" ]; then
		bad "/observability/v1/connections/active unreachable"
	else
		_total=$(printf '%s\n' "$_active" | json_total)
		ok "connections/active total=${_total:-?}"
	fi

	# Native gRPC API is a different listener from Clash 9999.  A TUN run may
	# legitimately return an empty eBPF list; only reachability + valid JSON
	# are asserted, never a live attachment.
	if [ "$DIAG_DECLARED" = 1 ]; then
		if [ ! -x "$BIN" ]; then
			skip "native diagnostics $DIAG_API (binary missing: $BIN)"
		elif ! json_tool; then
			skip "native diagnostics $DIAG_API (need jq or jsonfilter to read the JSON report)"
		else
			_dtmp="${TMPDIR:-/tmp}/verify-ebpf.diag.$$"
			bounded_capture "$_dtmp" 8 "$BIN" api ebpf --url "$DIAG_API"
			_drc=$?
			if json_file_valid "$_dtmp"; then
				_schema=$(jfile_raw "$_dtmp" '(.schemaVersion // .schema_version // empty)' '@.schemaVersion')
				[ -n "$_schema" ] || _schema=$(jfile_raw "$_dtmp" '.schema_version // empty' '@.schema_version')
				_state=$(jfile_raw "$_dtmp" '(.state // .status // empty)' '@.state')
				[ -n "$_state" ] || _state=$(jfile_raw "$_dtmp" '.status // empty' '@.status')
				ok "native diagnostics API $DIAG_API answered (schema=${_schema:-?}${_state:+, state=$_state})"
				info "api ebpf reports attachment/runtime state; it does NOT prove LAN client forwarding"
			else
				bad "native diagnostics API $DIAG_API returned no valid JSON (rc=$_drc)"
			fi
			rm -f "$_dtmp"
		fi
	else
		skip "native diagnostics API $DIAG_API not declared in this config"
	fi

	# Shared eBPF fragments bypass tuple rewriting; the guard is part of the
	# data plane, so its absence OR incompleteness fails closed while shared is
	# enabled.  The verdict comes from the guard's own status (hook priority,
	# per-interface fragment DROP rules, interface set equality, interface
	# existence) -- a bare `nft list table` would pass a flushed chain.
	if [ "$SHARED_CONFIG" = 1 ]; then
		_guard="${SINGBOX_FRAGGUARD:-$BASE/ebpf-fragment-guard.sh}"
		if ! command -v nft >/dev/null 2>&1; then
			skip "nft missing; cannot verify the fragment guard"
		elif [ ! -x "$_guard" ]; then
			bad "shared eBPF enabled but $_guard is missing (the guard is part of the plane)"
		else
			_gout=$(sh "$_guard" status 2>&1)
			_grc=$?
			case "$_grc" in
			0) ok "fragment guard complete (hook prerouting priority -450, three fragment DROPs per configured interface)" ;;
			3) bad "fragment guard INCOMPLETE for the shared plane (rc=3): $(printf '%s\n' "$_gout" | sed -n 's/^guard: *//p' | sed -n '1p')" ;;
			4) bad "fragment guard reports no shared plane while the config enables it (rc=4)" ;;
			5) bad "fragment guard table is stale (shared disabled) while the config enables shared (rc=5)" ;;
			*) bad "fragment guard status failed (rc=$_grc): $(printf '%s\n' "$_gout" | sed -n '1p')" ;;
			esac
		fi
	fi

	# Mixed inbound only: proves the proxy stack answers, NOT that transparent
	# capture works (curl -x talks proxy protocol to mixed:7890).
	_code=$(curl -4 -s -o /dev/null -w '%{http_code}' --max-time 20 -x "$PROXY" \
		https://www.gstatic.com/generate_204 2>/dev/null)
	if [ "$_code" = "204" ]; then
		ok "mixed inbound probe via $PROXY: 204 (proxy stack only)"
	else
		bad "mixed inbound probe via $PROXY: ${_code:-000} (expect 204)"
	fi

	# Transparent path: no -x, so the flow must be captured by TUN or by the
	# eBPF local hook.  000 here with a 204 above means the capture plane is
	# dead while the proxy itself is fine (the §31.1 signature on the device).
	_code=$(curl -4 -s -o /dev/null -w '%{http_code}' --max-time 20 \
		https://www.gstatic.com/generate_204 2>/dev/null)
	if [ "$_code" = "204" ]; then
		ok "transparent probe (no -x): 204 (device-local capture; not LAN proof)"
	else
		bad "transparent probe (no -x): ${_code:-000} (capture plane not working)"
	fi
}

# ------------------------------------------------------------ wan balancing
wan_checks() {
	echo ""
	echo "== wan balance =="
	if [ ! -f "$BALANCE" ]; then
		skip "missing $BALANCE"
		return 0
	fi
	_bal=$(sh "$BALANCE" status 2>/dev/null) || _bal=""
	if [ -z "$_bal" ]; then
		bad "singbox-wan-balance.sh status produced no output"
		return 0
	fi
	_poolsec=$(printf '%s\n' "$_bal" | sed -n '/^== pool/,/^== bypass mark/p' | sed '$d')
	printf '%s\n' "$_poolsec" | sed 's/^/      /'
	_pool=$(printf '%s\n' "$_poolsec" | awk 'NF >= 5 && $3 ~ /^[0-9]+$/ { n++ } END { print n + 0 }')
	_markline=$(printf '%s\n' "$_bal" | sed -n '/^== bypass mark/ { n; p; }' | sed -n '1p')
	_mark=$(printf '%s\n' "$_markline" | sed -n '1s/ .*//p')
	_src=$(printf '%s\n' "$_markline" | sed -n 's/.*(source: \([a-z]*\)).*/\1/p')
	if [ "$_pool" -gt 0 ]; then
		ok "balance pool: $_pool WAN(s)"
	else
		bad "balance pool empty (no online WAN with a usable mwan3 table)"
	fi

	# Mark contract: TUN gets its 0x2024 from the auto_route rule (source
	# rule); eBPF has no TUN, so the core's route.default_mark must supply it
	# (source default).  `ebpf`/`fallback` mean nothing stamps the mark.
	if [ "$EBPF_CONFIG" = 1 ]; then
		case "$_src" in
		default)
			case "$_mark" in
			0x2024 | 0X2024 | 8228) ok "wan-balance mark source:default ($_mark = route.default_mark 8228)" ;;
			*) bad "wan-balance mark source:default but value '${_mark:-?}' is not 0x2024" ;;
			esac
			;;
		*) bad "eBPF config requires wan-balance mark source:default, got '${_src:-unknown}'" ;;
		esac
	else
		case "$_src" in
		rule)
			case "$_mark" in
			0x2024 | 0X2024 | 8228) ok "wan-balance mark source:rule ($_mark from tun.auto_route)" ;;
			*) bad "wan-balance mark source:rule but value '${_mark:-?}' is not 0x2024" ;;
			esac
			;;
		*) bad "TUN config requires wan-balance mark source:rule, got '${_src:-unknown}'" ;;
		esac
	fi

	if ip rule show 2>/dev/null | grep -Eq '0x0?f000000'; then
		ok "wan-balance selector rules present (0x0f000000)"
	else
		skip "no 0x0f000000 rules (normal when every WAN is offline)"
	fi
	if command -v nft >/dev/null 2>&1 && nft list table ip tf-sbwan >/dev/null 2>&1; then
		ok "nft tf-sbwan present"
	else
		skip "nft tf-sbwan absent (normal when the WAN pool is empty)"
	fi
}

# --------------------------------------------------------- load distribution
rx_bytes() { # rx_bytes <dev> -> bytes or empty
	awk -v d="$1" '$1 == d":" { print $2; exit }' /proc/net/dev 2>/dev/null
}

sample_wan() { # sample_wan <outfile>
	: >"$1"
	for _dev in $WAN_DEVICES; do
		_v=$(rx_bytes "$_dev")
		echo "$_dev ${_v:-0}" >>"$1"
	done
}

distribution_test() {
	echo ""
	echo "== three-card distribution =="
	_before="/tmp/verify-ebpf.before.$$"
	_after="/tmp/verify-ebpf.after.$$"
	trap 'rm -f "$_before" "$_after"' EXIT INT TERM

	sample_wan "$_before"
	_i=0
	while [ "$_i" -lt "$LOAD_N" ]; do
		curl -4 -s -o /dev/null --max-time "$LOAD_TIMEOUT" -x "$PROXY" "$DOWNLOAD_URL" &
		_i=$((_i + 1))
	done
	# Every download is time-boxed by --max-time, so this cannot hang.
	wait
	sample_wan "$_after"

	_delta="/tmp/verify-ebpf.delta.$$"
	awk 'NR == FNR { b[$1] = $2; next } { d = $2 - (b[$1] + 0); if (d < 0) d = 0; printf "%s %d\n", $1, d }' \
		"$_before" "$_after" >"$_delta"
	_total=$(awk '{ s += $2 } END { print s + 0 }' "$_delta")
	_active=$(awk '$2 > 0 { n++ } END { print n + 0 }' "$_delta")

	if [ "$VERBOSE_LOAD" -eq 1 ]; then
		while read -r _dev _bytes; do
			_pct=$(awk -v b="$_bytes" -v t="$_total" 'BEGIN { printf "%.0f", (t > 0 ? b * 100 / t : 0) }')
			printf '      %-12s %10s  %3s%%\n' "$_dev" "$(human_bytes "$_bytes")" "$_pct"
		done <"$_delta"
	fi
	rm -f "$_delta"

	_need="$MIN_ACTIVE"
	_wan_count=$(printf '%s\n' "$WAN_DEVICES" | wc -w | tr -d ' ')
	if [ "$_need" -gt "$_wan_count" ]; then
		_need="$_wan_count"
	fi
	if [ "$_total" -lt 1048576 ]; then
		bad "download burst moved $(human_bytes "$_total") < 1 MiB (proxy path down or nodes stalled)"
	elif [ "$_active" -lt "$_need" ]; then
		bad "only $_active/$_wan_count cards carried traffic (expected >= $_need): all proxied egress on one card"
	else
		ok "$(human_bytes "$_total") across $_active/$_wan_count cards"
	fi
}

# ------------------------------------------------------------------- summary
echo "== verify $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
static_checks
if [ "$STATIC_ONLY" -eq 0 ]; then
	runtime_checks
	if [ -n "$(core_pid)" ]; then
		wan_checks
		if [ "$DO_LOAD" -eq 1 ]; then
			distribution_test
		else
			skip "download distribution (--no-load)"
		fi
	else
		skip "wan balance + distribution (core not running)"
	fi
fi

echo ""
echo "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
if [ "$FAIL" -gt 0 ]; then
	echo "VERDICT: FAIL"
	exit 1
fi
echo "VERDICT: PASS"
exit 0
