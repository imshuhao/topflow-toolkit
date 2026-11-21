#!/bin/sh
# Re-capture flows that were established while the proxy was down.
#
# The transparent capture is NAT-based (`nft ... redirect to :PORT` / `queue`),
# and netfilter applies NAT (and the redirect decision) only when a connection
# is created.  A flow that was established while sing-box was stopped keeps its
# direct path after the core is back: the app stays online, the panel shows no
# traffic, and nothing in the UI says the flow is bypassing the proxy.  Long
# lived sessions (WebSocket / QUIC / video) can sit in that state for hours and
# quietly burn cellular data.
#
# So right after every (re)start we delete the conntrack entries that are
# neither already captured by sing-box (0x2023 / 0x2024 / mwan3's 0x3f00) nor
# deliberately direct (LAN, loopback, private, link-local, multicast).  Those
# flows fail once and reconnect immediately, this time through the TUN.
#
# Runs after `sing-box.sh` has the TUN and its nft rules up; safe to repeat.
set -u

BASE="${SINGBOX_BASE:-/data/sing-box}"
LOG="${SINGBOX_FLUSH_LOG:-$BASE/state/capture-flush.log}"
CONNTRACK="${CONNTRACK_BIN:-/usr/sbin/conntrack}"
# Marks at or above 0x2000 are already "owned": 0x2023 redirected by sing-box,
# 0x2024 sing-box's own egress, 0x3f00 mwan3's "do not balance" marker.
KEEP_MARK_MIN=8192

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null || true
	if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 131072 ]; then
		tail -c 65536 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
	fi
}

command -v "$CONNTRACK" >/dev/null 2>&1 || CONNTRACK=conntrack
command -v "$CONNTRACK" >/dev/null 2>&1 || { log "conntrack tool missing; skipped"; exit 0; }
[ -r /proc/net/nf_conntrack ] || { log "/proc/net/nf_conntrack unreadable; skipped"; exit 0; }

# Emit "<family> <proto> <src> <dst> <sport> <dport>" for flows worth resetting.
flows() {
	awk -v keep="$KEEP_MARK_MIN" '
	function local4(ip,  a) {
		split(ip, a, ".")
		if (a[1] == 10 || a[1] == 127 || a[1] == 0 || a[1] == 255) return 1
		if (a[1] == 169 && a[2] == 254) return 1
		if (a[1] == 172 && a[2] >= 16 && a[2] <= 31) return 1
		if (a[1] == 192 && a[2] == 168) return 1
		if (a[1] == 100 && a[2] >= 64 && a[2] <= 127) return 1
		if (a[1] >= 224 && a[1] <= 239) return 1
		return 0
	}
	function local6(ip,  p) {
		p = tolower(ip)
		if (p == "::1") return 1
		if (substr(p, 1, 2) == "fc" || substr(p, 1, 2) == "fd") return 1
		if (substr(p, 1, 4) == "fe80" || substr(p, 1, 4) == "fe90" ||
		    substr(p, 1, 4) == "fea0" || substr(p, 1, 4) == "feb0") return 1
		if (substr(p, 1, 2) == "ff") return 1
		return 0
	}
	$1 == "ipv4" || $1 == "ipv6" {
		fam = $1; proto = $3; got = 0; mark = 0
		for (i = 4; i <= NF; i++) {
			if (!got) {
				if ($i ~ /^src=/)   { s  = substr($i, 5); continue }
				if ($i ~ /^dst=/)   { d  = substr($i, 5); continue }
				if ($i ~ /^sport=/) { sp = substr($i, 7); continue }
				if ($i ~ /^dport=/) { dp = substr($i, 7); got = 1; continue }
			}
			if ($i ~ /^mark=/) { mark = substr($i, 6) + 0 }
		}
		if (!got) next
		if (mark >= keep) next
		if (fam == "ipv4") { if (local4(d)) next } else { if (local6(d)) next }
		if (proto != "tcp" && proto != "udp") next
		print fam, proto, s, d, sp, dp
	}' /proc/net/nf_conntrack 2>/dev/null
}

deleted=0
listed=0
while read -r fam proto src dst sport dport; do
	[ -n "${fam:-}" ] || continue
	listed=$((listed + 1))
	if "$CONNTRACK" -D -f "$fam" -p "$proto" -s "$src" -d "$dst" \
		--sport "$sport" --dport "$dport" >/dev/null 2>&1; then
		deleted=$((deleted + 1))
	fi
done <<EOF
$(flows)
EOF

if [ "$deleted" -gt 0 ]; then
	log "reset $deleted flow(s) that bypassed the proxy (scanned $listed)"
fi
exit 0
