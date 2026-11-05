#!/bin/sh
# Offline render checks for singbox-wan-balance.sh protocol pools + presets.
# Run: sh singbox/tests/test_wan_balance_render.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/singbox/singbox-wan-balance.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export SINGBOX_BASE="$TMP"
export SINGBOX_STATE="$TMP/state"
export SINGBOX_CONFIG="$TMP/config.json"
export SINGBOX_WANBAL_CONF="$TMP/wan-balance.conf"
export MWAN3TRACK_DIR="$TMP/mwan3track"
mkdir -p "$SINGBOX_STATE"
printf '%s\n' '{"route":{"default_mark":8228}}' > "$SINGBOX_CONFIG"

seed_pool() {
	cat > "$SINGBOX_STATE/wan-balance.pool" <<'EOF'
zte_mwan2 rmnet_data0 6 12 10.0.0.1
zte_mwan3 V3E1net0 3 13 10.0.0.2
zte_mwan4 V3E2net0 3 14 10.0.0.3
EOF
}

seed_track() {
	# $1=iface $2=latency $3=loss
	_if=$1
	_lat=$2
	_loss=$3
	mkdir -p "$MWAN3TRACK_DIR/$_if"
	echo "$_lat" > "$MWAN3TRACK_DIR/$_if/LATENCY_1.1.1.1"
	echo "$_loss" > "$MWAN3TRACK_DIR/$_if/LOSS_1.1.1.1"
}

clear_track() {
	rm -rf "$MWAN3TRACK_DIR"
	mkdir -p "$MWAN3TRACK_DIR"
}

fail=0
assert_grep() {
	_pat=$1
	_file=$2
	_msg=$3
	if grep -qE "$_pat" "$_file"; then
		echo "PASS $_msg"
	else
		echo "FAIL $_msg (pattern: $_pat)"
		fail=1
	fi
}
assert_no_grep() {
	_pat=$1
	_file=$2
	_msg=$3
	if grep -qE "$_pat" "$_file"; then
		echo "FAIL $_msg (unexpected: $_pat)"
		fail=1
	else
		echo "PASS $_msg"
	fi
}

# --- shared (default, no conf, no quality metrics) ---
seed_pool
clear_track
rm -f "$SINGBOX_WANBAL_CONF"
sh "$SCRIPT" render > "$TMP/shared.out"
assert_grep 'mode=shared' "$TMP/shared.out" "shared mode banner"
assert_grep '# mode=shared' "$SINGBOX_STATE/wan-balance.nft" "shared nft comment"
assert_no_grep 'meta l4proto tcp' "$SINGBOX_STATE/wan-balance.nft" "shared has no tcp prefix"
assert_grep '0-49' "$SINGBOX_STATE/wan-balance.nft" "shared 50% 5G bucket"
assert_grep '50-74' "$SINGBOX_STATE/wan-balance.nft" "shared 25% 4G#1 bucket"
assert_grep '75-99' "$SINGBOX_STATE/wan-balance.nft" "shared 25% 4G#2 bucket"
assert_grep '1990 0x01000000 12' "$SINGBOX_STATE/wan-balance.rules" "shared rule pref 1990 -> table 12"
assert_grep '1992 0x04000000 14' "$SINGBOX_STATE/wan-balance.rules" "shared rule pref 1992 -> table 14"

# --- game preset via conf: TCP=5G, UDP=双4G ---
seed_pool
clear_track
cat > "$SINGBOX_WANBAL_CONF" <<'EOF'
PRESET=game
MODE=proto
TCP_POOL=zte_mwan2
UDP_POOL=zte_mwan3,zte_mwan4
EOF
sh "$SCRIPT" render > "$TMP/game.out"
assert_grep 'mode=proto' "$TMP/game.out" "game mode banner"
assert_grep 'meta l4proto tcp counter meta mark set' "$SINGBOX_STATE/wan-balance.nft" "game TCP single 5G full bucket"
assert_grep 'meta l4proto udp jhash' "$SINGBOX_STATE/wan-balance.nft" "game UDP dual-4G jhash"
assert_grep 'meta l4proto udp jhash.*0-49' "$SINGBOX_STATE/wan-balance.nft" "game UDP 4G#1 bucket"
assert_grep 'meta l4proto udp jhash.*50-99' "$SINGBOX_STATE/wan-balance.nft" "game UDP 4G#2 bucket"
assert_no_grep 'meta l4proto tcp jhash' "$SINGBOX_STATE/wan-balance.nft" "game TCP has no multi-bucket jhash"
cp "$SINGBOX_STATE/wan-balance.nft" "$TMP/game.nft"
_rc=$(wc -l < "$SINGBOX_STATE/wan-balance.rules" | tr -d ' ')
if [ "$_rc" -eq 3 ]; then
	echo "PASS game has 3 ip rules for union"
else
	echo "FAIL game rule count=$_rc want 3"
	fail=1
fi

# --- preset-get / preset-set (apply no-ops without nft) ---
sh "$SCRIPT" preset-get > "$TMP/pget.out"
assert_grep 'preset=game' "$TMP/pget.out" "preset-get reports game"
sh "$SCRIPT" preset-set shared > "$TMP/pset.out"
assert_grep 'preset=shared' "$TMP/pset.out" "preset-set shared"
assert_grep '^MODE=shared' "$SINGBOX_WANBAL_CONF" "conf MODE=shared after set"
assert_grep '^PRESET=shared' "$SINGBOX_WANBAL_CONF" "conf PRESET=shared after set"
assert_grep '^QUALITY=1' "$SINGBOX_WANBAL_CONF" "conf QUALITY=1 after shared"
seed_pool
clear_track
sh "$SCRIPT" render > "$TMP/shared2.out"
assert_grep '# mode=shared' "$SINGBOX_STATE/wan-balance.nft" "render after preset-set shared"

sh "$SCRIPT" preset-set auto > "$TMP/pseta.out"
assert_grep 'preset=auto' "$TMP/pseta.out" "preset-set auto"
assert_grep '^BIAS=1' "$SINGBOX_WANBAL_CONF" "conf BIAS=1 after auto"
assert_grep '^QUALITY=1' "$SINGBOX_WANBAL_CONF" "conf QUALITY=1 after auto"

sh "$SCRIPT" preset-set game > "$TMP/psetg.out"
assert_grep 'preset=game' "$TMP/psetg.out" "preset-set game"
assert_grep 'TCP_POOL=zte_mwan2' "$SINGBOX_WANBAL_CONF" "conf TCP_POOL after game"
assert_grep 'UDP_POOL=zte_mwan3,zte_mwan4' "$SINGBOX_WANBAL_CONF" "conf UDP_POOL after game"

# --- unknown preset id rejected ---
if sh "$SCRIPT" preset-set split3 >/dev/null 2>&1; then
	echo "FAIL preset-set should reject unknown id"
	fail=1
else
	echo "PASS preset-set rejects unknown id"
fi

# --- empty UDP falls back ---
seed_pool
clear_track
cat > "$SINGBOX_WANBAL_CONF" <<'EOF'
MODE=proto
TCP_POOL=zte_mwan2
UDP_POOL=zte_mwan_missing
QUALITY=0
BIAS=0
EOF
sh "$SCRIPT" render > "$TMP/fallback.out"
_udp=$(grep -cE 'meta l4proto udp jhash' "$SINGBOX_STATE/wan-balance.nft" || true)
if [ "$_udp" -ge 2 ]; then
	echo "PASS empty UDP_POOL falls back to shared multi-bucket"
else
	echo "FAIL UDP fallback buckets=$_udp"
	fail=1
fi
assert_grep 'meta l4proto tcp counter meta mark set' "$SINGBOX_STATE/wan-balance.nft" "TCP single-card full bucket"

# --- auto healthy: soft bias (TCP prefers 5G more than UDP) ---
seed_pool
clear_track
seed_track zte_mwan2 50 0
seed_track zte_mwan3 40 0
seed_track zte_mwan4 40 0
cat > "$SINGBOX_WANBAL_CONF" <<'EOF'
PRESET=auto
MODE=proto
QUALITY=1
BIAS=1
TCP_POOL=
UDP_POOL=
EOF
rm -f "$SINGBOX_STATE/wan-balance.qstate"
sh "$SCRIPT" render > "$TMP/auto.out"
assert_grep 'mode=proto' "$TMP/auto.out" "auto mode banner"
assert_grep 'meta l4proto tcp jhash' "$SINGBOX_STATE/wan-balance.nft" "auto TCP multi-bucket"
assert_grep 'meta l4proto udp jhash' "$SINGBOX_STATE/wan-balance.nft" "auto UDP multi-bucket"
# TCP weights 9+2+2=13 → 5G 0-68; UDP 4+3+3=10 → 5G 0-39
assert_grep 'meta l4proto tcp jhash.*0-68' "$SINGBOX_STATE/wan-balance.nft" "auto TCP 5G ~69%"
assert_grep 'meta l4proto udp jhash.*0-39' "$SINGBOX_STATE/wan-balance.nft" "auto UDP 5G 40%"
cp "$SINGBOX_STATE/wan-balance.weights.tcp" "$TMP/auto.tcp.w"
assert_grep 'zte_mwan2 rmnet_data0 9' "$TMP/auto.tcp.w" "auto TCP 5G weight 9"
assert_grep 'zte_mwan3 V3E1net0 2' "$TMP/auto.tcp.w" "auto TCP 4G weight 2"

# --- 5G weak: TCP still has 4G buckets (spill) ---
seed_pool
clear_track
seed_track zte_mwan2 900 0
seed_track zte_mwan3 40 0
seed_track zte_mwan4 40 0
rm -f "$SINGBOX_STATE/wan-balance.qstate"
sh "$SCRIPT" render > "$TMP/weak5g.out"
# 5G base 6→1 (15%), bias TCP →1; 4G 3→2 each. total 5 → 0-19 / 20-59 / 60-99
assert_grep 'meta l4proto tcp jhash.*0-19' "$SINGBOX_STATE/wan-balance.nft" "weak5G TCP 5G shrinks"
assert_grep 'meta l4proto tcp jhash.*20-59' "$SINGBOX_STATE/wan-balance.nft" "weak5G TCP spills to 4G#1"
assert_grep 'zte_mwan2:weak' "$SINGBOX_STATE/wan-balance.quality" "weak5G quality marks 5G weak"
sh "$SCRIPT" preset-get > "$TMP/pget_weak.txt"
assert_grep 'degraded=zte_mwan2' "$TMP/pget_weak.txt" "preset-get reports degraded 5G"

# --- 4G weak: UDP still has 5G bucket (spill) ---
seed_pool
clear_track
seed_track zte_mwan2 50 0
seed_track zte_mwan3 900 0
seed_track zte_mwan4 900 0
rm -f "$SINGBOX_STATE/wan-balance.qstate"
sh "$SCRIPT" render > "$TMP/weak4g.out"
# 4G weak scale 3→1 each, bias UDP 1*130=1; 5G 6*70→4. total 6 → 5G 0-65
assert_grep 'meta l4proto udp jhash.*0-65' "$SINGBOX_STATE/wan-balance.nft" "weak4G UDP shifts to 5G"
assert_grep 'zte_mwan3:weak' "$SINGBOX_STATE/wan-balance.quality" "weak4G marks 4G#1"
assert_grep 'zte_mwan4:weak' "$SINGBOX_STATE/wan-balance.quality" "weak4G marks 4G#2"

# --- hysteresis: stay weak until exit threshold ---
seed_pool
clear_track
seed_track zte_mwan2 900 0
seed_track zte_mwan3 40 0
seed_track zte_mwan4 40 0
rm -f "$SINGBOX_STATE/wan-balance.qstate"
sh "$SCRIPT" render >/dev/null
# now lat=500: still above EXIT 350 → remain weak
seed_track zte_mwan2 500 0
sh "$SCRIPT" render >/dev/null
assert_grep 'zte_mwan2:weak' "$SINGBOX_STATE/wan-balance.quality" "hysteresis keeps weak at 500ms"
# lat=300 → exit to ok
seed_track zte_mwan2 300 0
sh "$SCRIPT" render >/dev/null
assert_grep 'zte_mwan2:ok' "$SINGBOX_STATE/wan-balance.quality" "hysteresis exits weak at 300ms"

# --- optional RSRP auxiliary ---
seed_pool
clear_track
seed_track zte_mwan2 50 0
seed_track zte_mwan3 40 0
seed_track zte_mwan4 40 0
mkdir -p "$TMP/weaknet"
echo 'rsrp=-110' > "$TMP/weaknet/radio.snap"
cat > "$SINGBOX_WANBAL_CONF" <<EOF
PRESET=auto
MODE=proto
QUALITY=1
BIAS=1
RADIO_SNAP=$TMP/weaknet/radio.snap
TCP_POOL=
UDP_POOL=
EOF
rm -f "$SINGBOX_STATE/wan-balance.qstate"
sh "$SCRIPT" render >/dev/null
assert_grep 'zte_mwan2:weak' "$SINGBOX_STATE/wan-balance.quality" "RSRP -110 marks 5G weak"

if [ "$fail" -ne 0 ]; then
	echo "--- shared.out ---"; cat "$TMP/shared.out" || true
	echo "--- game nft ---"; cat "$TMP/game.nft" 2>/dev/null || true
	echo "--- auto nft ---"; cat "$SINGBOX_STATE/wan-balance.nft" 2>/dev/null || true
	exit 1
fi
echo "ALL PASS"
exit 0
