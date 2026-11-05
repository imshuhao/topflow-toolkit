#!/bin/sh
# TopFlow MU5252 B20 — weak-network report (wan-balance aligned).
#
# Usage:
#   weaknet-report.sh            # today
#   weaknet-report.sh YYYYMMDD   # one day
#   weaknet-report.sh --events   # transition log
#   weaknet-report.sh --live     # current wan-balance snapshot only

BASE=${BASE:-/data/local/weaknet}
SB_STATE=${SINGBOX_STATE:-/data/sing-box/state}
day=${1:-$(date '+%Y%m%d')}

if [ "$day" = "--events" ]; then
	echo "== weaknet events (last 60) =="
	tail -60 "$BASE/events.log" 2>/dev/null || echo "(no events yet)"
	exit 0
fi

if [ "$day" = "--live" ]; then
	echo "== 现行分流快照 =="
	if [ -x /data/sing-box/singbox-wan-balance.sh ]; then
		sh /data/sing-box/singbox-wan-balance.sh preset-get
		echo
		sh /data/sing-box/singbox-wan-balance.sh status 2>/dev/null | sed -n '1,40p'
	else
		echo "(无 singbox-wan-balance.sh)"
	fi
	exit 0
fi

f="$BASE/$day.jsonl"
[ -f "$f" ] || { echo "没有 $day 的采样文件（$f 不存在）"; echo "看看有哪些："; ls -l "$BASE"/*.jsonl 2>/dev/null; exit 1; }

n=$(wc -l <"$f")
echo "== 弱网黑匣子报告 ($day) =="
echo "采样数: $n  文件: $f"
echo "口径: mwan3track lat/loss + wan-balance 质量档/权重（与分流同信号）"
echo

echo "-- 时间范围 --"
head -1 "$f" | sed 's/.*"t":"\([^"]*\)".*/起: \1/'
tail -1 "$f" | sed 's/.*"t":"\([^"]*\)".*/止: \1/'
echo

echo "-- 分流预设分布 --"
awk '
	{
		if (match($0, /"preset":"[^"]*"/)) {
			p = substr($0, RSTART+10, RLENGTH-11); preset[p]++; n++
		}
		if (match($0, /"pool_mode":"[^"]*"/)) {
			m = substr($0, RSTART+13, RLENGTH-14); mode[m]++
		}
	}
	END {
		if (n == 0) { print "  (旧格式或无 preset 字段)"; exit }
		printf "  采样 %d\n", n
		for (p in preset) printf "  preset=%-8s %d (%.0f%%)\n", p, preset[p], preset[p]*100/n
		for (m in mode) printf "  pool_mode=%-8s %d\n", m, mode[m]
	}
' "$f"
echo

echo "-- 各卡（mwan3track lat/loss + 质量档 + 有效权重） --"
for ifc in zte_mwan2 zte_mwan3 zte_mwan4; do
	case "$ifc" in
	zte_mwan2) label="5G   (rmnet_data0 / zte_mwan2)";;
	zte_mwan3) label="4G#1 (V3E1net0 / zte_mwan3)  ";;
	zte_mwan4) label="4G#2 (V3E2net0 / zte_mwan4)  ";;
	esac
	awk -v ifc="$ifc" -v label="$label" '
		{
			# new format
			re = "\"" ifc "\":\\{[^}]*\\}"
			if (!match($0, re)) next
			seg = substr($0, RSTART, RLENGTH)
			samples++
			if (match(seg, /"on":[0-9]/)) { on = substr(seg, RSTART+5, 1) + 0; upon += on }
			if (match(seg, /"lat":[0-9]+/)) {
				lat = substr(seg, RSTART+6, RLENGTH-6) + 0
				latsum += lat; latn++
				if (latn == 1 || lat < minlat) minlat = lat
				if (latn == 1 || lat > maxlat) maxlat = lat
				if (lat >= 600) weaklat++
				if (lat >= 1500) droplat++
			}
			if (match(seg, /"loss":[0-9]+/)) {
				loss = substr(seg, RSTART+7, RLENGTH-7) + 0
				losssum += loss
				if (loss >= 30) weakloss++
				if (loss >= 70) droploss++
			}
			if (match(seg, /"cls":"[^"]*"/)) {
				cls = substr(seg, RSTART+7, RLENGTH-8)
				clsc[cls]++
			}
			if (match(seg, /"w_tcp":[0-9]+/)) { wt = substr(seg, RSTART+8, RLENGTH-8) + 0; wts += wt; wtn++ }
			if (match(seg, /"w_udp":[0-9]+/)) { wu = substr(seg, RSTART+8, RLENGTH-8) + 0; wus += wu; wun++ }
		}
		END {
			if (samples == 0) { printf "  %s 无新格式数据\n", label; exit }
			printf "  %s\n", label
			printf "    采样%d  在线率%.0f%%  track延迟 avg %.0fms (min %.0f / max %.0f)\n",
				samples, (samples?upon*100/samples:0), (latn?latsum/latn:0), minlat, maxlat
			printf "    track丢包 avg %.1f%%  ≥enter600ms:%d  ≥drop1500ms:%d  ≥enter30%%loss:%d\n",
				(samples?losssum/samples:0), weaklat, droplat, weakloss
			printf "    质量档:"
			for (c in clsc) printf " %s×%d", c, clsc[c]
			printf "\n    有效权重 avg tcp=%.1f udp=%.1f\n", (wtn?wts/wtn:0), (wun?wus/wun:0)
		}
	' "$f"
done
echo

echo "-- 5G 主卡射频 --"
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
			if (r <= -105) badradio++
		}
		s = val(seg, "snr")
		if (s != "") { s = s + 0; ss += s; sn++; if (sn == 1 || s < smin) smin = s; if (sn == 1 || s > smax) smax = s }
	}
	END {
		if (n == 0) { print "  无射频数据"; exit }
		printf "  采样 %d\n", n
		printf "  频段:"; for (b in bands) printf " %s×%d", b, bands[b]; print ""
		printf "  制式:"; for (t in types) printf " %s×%d", t, types[t]; print ""
		if (rn) printf "  RSRP avg %.0f (min %.0f / max %.0f)  ≤-105: %d\n", rs/rn, rmin, rmax, badradio
		if (sn) printf "  SNR  avg %.1f (min %.1f / max %.1f)\n", ss/sn, smin, smax
	}
' "$f"
echo

echo "-- 代理可用性（7890 → gstatic 204） --"
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

echo "-- DNS 解析延迟 --"
awk '{ if (match($0, /"dns_ms":[0-9]+/)) { v = substr($0, RSTART+9, RLENGTH-9) + 0; s += v; n++; if (v > m) m = v } }
	END { if (n) printf "  平均 %.0fms  最大 %.0fms（n=%d）\n", s/n, m, n; else print "  无数据" }' "$f"
echo

echo "-- 异常事件 --"
dayd=$(printf '%s' "$day" | sed 's/^\([0-9][0-9][0-9][0-9]\)\([0-9][0-9]\)\([0-9][0-9]\)$/\1-\2-\3/')
if [ -s "$BASE/events.log" ]; then
	sel=$(grep "^$dayd" "$BASE/events.log" 2>/dev/null | tail -25)
	[ -n "$sel" ] && printf '%s\n' "$sel" | sed 's/^/  /' || echo "  (当天无事件)"
else
	echo "  (无)"
fi
echo

echo "-- 当前分流（live） --"
if [ -x /data/sing-box/singbox-wan-balance.sh ]; then
	sh /data/sing-box/singbox-wan-balance.sh preset-get | sed 's/^/  /'
else
	echo "  (无 wan-balance 脚本)"
fi
