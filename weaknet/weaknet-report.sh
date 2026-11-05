#!/bin/sh
# TopFlow MU5252 B20 — weak-network report.
#
# Reads the JSONL black box written by weaknet-watch.sh and prints a compact,
# human-readable summary.  Designed to be run from a phone through WebSSH
# (http://192.168.0.1:8899/app) so no PC is needed at the weak-network site.
#
# Usage:
#   weaknet-report.sh            # today
#   weaknet-report.sh YYYYMMDD   # one specific day
#   weaknet-report.sh --events  # only the event log (transitions + guard)

BASE=${BASE:-/data/local/weaknet}
day=${1:-$(date '+%Y%m%d')}

if [ "$day" = "--events" ]; then
	echo "== weaknet events (last 60) =="
	tail -60 "$BASE/events.log" 2>/dev/null || echo "(no events yet)"
	exit 0
fi

f="$BASE/$day.jsonl"
[ -f "$f" ] || { echo "没有 $day 的采样文件（$f 不存在）"; echo "看看有哪些："; ls -l "$BASE"/*.jsonl 2>/dev/null; exit 1; }

n=$(wc -l <"$f")
echo "== 弱网黑匣子报告 ($day) =="
echo "采样数: $n  文件: $f"
echo

echo "-- 时间范围 --"
head -1 "$f" | sed 's/.*"t":"\([^"]*\)".*/起: \1/'
tail -1 "$f" | sed 's/.*"t":"\([^"]*\)".*/止: \1/'
echo

echo "-- 各卡质量（ICMP 到 223.5.5.5，采样时刻的快照） --"
for ifc in zte_mwan2 zte_mwan3 zte_mwan4; do
	dev=""
	case "$ifc" in
	zte_mwan2) dev="5G   (rmnet_data0)";;
	zte_mwan3) dev="4G#1 (V3E1net0)  ";;
	zte_mwan4) dev="4G#2 (V3E2net0)  ";;
	esac
	awk -v ifc="$ifc" -v label="$dev" '
		{
			if (match($0, "\""ifc"\":\\{\"st\":\"[^\"]*\",\"ping\":\"[^\"]*\"")) {
				seg = substr($0, RSTART, RLENGTH)
				if (match(seg, /"st":"[^"]*"/)) { st = substr(seg, RSTART+6, RLENGTH-7) }
				if (match(seg, /"ping":"[^"]*"/)) { pg = substr(seg, RSTART+8, RLENGTH-9) }
				split(st, s, " ")
				split(pg, p, " ")
				samples++
				up += s[1] + 0
				loss += p[1] + 0
				if (p[1] + 0 > maxloss) maxloss = p[1] + 0
				if (p[2] != "-") {
					lat = p[2] + 0
					latsum += lat; latn++
					if (lat > maxlat || latn == 1) maxlat = lat
					if (lat < minlat || latn == 1) minlat = lat
					if (lat > 300) slow++
				}
				if (p[1] + 0 > 20) badloss++
			}
		}
		END {
			if (samples == 0) { printf "  %s 无数据\n", label; exit }
			printf "  %s 采样%d  在线率%.0f%%  平均延迟%.0fms (min %.0f / max %.0f)  平均丢包%.1f%%  最大丢包%.0f%%\n",
				label, samples, up*100/samples, (latn?latsum/latn:0), minlat, maxlat, loss/samples, maxloss
			if (badloss > 0) printf "    ⚠ 有 %d 个采样点丢包 >20%%（占比 %.0f%%）\n", badloss, badloss*100/samples
			if (slow > 0) printf "    ⚠ 有 %d 个采样点延迟 >300ms（占比 %.0f%%）\n", slow, slow*100/samples
		}
	' "$f"
done
echo

echo "-- 5G 主卡射频（X75：频段/Rsrp/SINR，弱网的核心证据） --"
awk '
	function val(seg, key,   m, s) {
		m = "\"" key "\":\"[^\"]*\""
		if (match(seg, m)) { s = substr(seg, RSTART, RLENGTH); sub(".*:\"", "", s); sub("\"$", "", s); return s }
		return ""
	}
	{
		if (!match($0, /"radio":\{[^}]*\}/)) next
		seg = substr($0, RSTART, RLENGTH)
		n++
		b = val(seg, "band"); ty = val(seg, "type")
		if (b != "") bands[b]++
		if (ty != "") types[ty]++
		r = val(seg, "rsrp")
		if (r != "") {
			r = r + 0; rs += r; rn++
			if (rn == 1 || r < rmin) rmin = r
			if (rn == 1 || r > rmax) rmax = r
			if (r < -105) { badradio++; if (match($0, /"proxy":"[0-9]+/)) { if (substr($0, RSTART + 9, RLENGTH - 9) != "204") badfail++ } }
		}
		s = val(seg, "snr")
		if (s != "") { s = s + 0; ss += s; sn++; if (sn == 1 || s < smin) smin = s; if (sn == 1 || s > smax) smax = s }
	}
	END {
		if (n == 0) { print "  无射频数据"; exit }
		printf "  采样 %d\n", n
		printf "  频段分布:"
		for (b in bands) printf " %s×%d", b, bands[b]
		printf "\n  制式分布:"
		for (t in types) printf " %s×%d", t, types[t]
		if (rn) printf "\n  RSRP: 平均 %.0f dBm (min %.0f / max %.0f)\n", rs/rn, rmin, rmax
		if (sn) printf "  SNR:  平均 %.1f dB (min %.1f / max %.1f)\n", ss/sn, smin, smax
		if (badradio) printf "  ⚠ RSRP<-105dBm 的采样 %d 个（%.0f%%），其中代理失败 %d 次 → 射频劣化已影响代理\n", badradio, badradio*100/n, badfail
	}
' "$f"
echo

echo "-- 按频段对比（同一时段内 n78 / n1 / LTE 的代理表现） --"
awk '
	function val(seg, key,   m, s) {
		m = "\"" key "\":\"[^\"]*\""
		if (match(seg, m)) { s = substr(seg, RSTART, RLENGTH); sub(".*:\"", "", s); sub("\"$", "", s); return s }
		return ""
	}
	{
		if (!match($0, /"radio":\{[^}]*\}/)) next
		band = val(substr($0, RSTART, RLENGTH), "band"); if (band == "") band = "?"
		if (!match($0, /"proxy":"[0-9]+:[0-9.]+"/)) next
		seg = substr($0, RSTART, RLENGTH); sub(/.*:"/, "", seg); sub(/"$/, "", seg)
		split(seg, p, ":")
		cnt[band]++
		if (p[1] == "204") { ok[band]++; ms[band] += p[2] * 1000; if (p[2] * 1000 > maxms[band]) maxms[band] = p[2] * 1000 }
		else fail[band]++
	}
	END {
		if (length(cnt) == 0) { print "  无数据"; exit }
		for (b in cnt)
			printf "  %-5s 采样%d  代理成功%d/%d (%.0f%%)  平均%.0fms  最大%.0fms\n", \
				b, cnt[b], ok[b], cnt[b], (cnt[b] ? ok[b] * 100 / cnt[b] : 0), \
				(ok[b] ? ms[b] / ok[b] : 0), maxms[b]
	}
' "$f"
echo

echo "-- 代理可用性（经 7890 访问 gstatic 204） --"
awk '
	{
		if (match($0, /"proxy":"[^"]*"/)) {
			seg = substr($0, RSTART, RLENGTH); p = substr(seg, 10, RLENGTH-11)
			split(p, a, ":")
			samples++
			if (a[1] == "204") { ok++; t = a[2] + 0; sum += t; if (t > max) max = t }
			else { bad[a[1]]++ }
		}
	}
	END {
		if (samples == 0) { print "  无数据"; exit }
		printf "  成功 %d/%d (%.0f%%)  平均 %.0fms  最大 %.0fms\n", ok, samples, ok*100/samples, (ok?sum/ok*1000:0), max*1000
		for (c in bad) printf "  失败码 %s: %d 次\n", c, bad[c]
	}
' "$f"
echo

echo "-- 设备解析延迟（dns_ms） --"
awk '{ if (match($0, /"dns_ms":[0-9]+/)) { v = substr($0, RSTART+9, RLENGTH-9) + 0; s += v; n++; if (v > m) m = v } }
	END { if (n) printf "  平均 %.0fms  最大 %.0fms（n=%d）\n", s/n, m, n; else print "  无数据" }' "$f"
echo

echo "-- 异常事件（切换/守护/池变化） --"
dayd=$(printf '%s' "$day" | sed 's/^\([0-9][0-9][0-9][0-9]\)\([0-9][0-9]\)\([0-9][0-9]\)$/\1-\2-\3/')
if [ -s "$BASE/events.log" ]; then
	sel=$(grep "^$dayd" "$BASE/events.log" 2>/dev/null | tail -25)
	[ -n "$sel" ] && printf '%s\n' "$sel" | sed 's/^/  /' || echo "  (当天无事件)"
else
	echo "  (无)"
fi
echo

echo "-- 当前状态 --"
echo "  mode=$(uci -q get zwrt_router.network.opms_wan_mode)  rules=$(ip rule show 2>/dev/null | grep -c 'fwmark 0x.000000/0xf000000 lookup 1[234]')"
mwan3 status 2>/dev/null | grep -E 'zte_mwan[234] is' | sed 's/^/  /'
