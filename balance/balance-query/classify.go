package main

import (
	"regexp"
	"strconv"
	"strings"
)

type flowBucket struct {
	RemainKB      int64
	TotalKB       int64
	UsedKB        int64 // 有限包已用
	Unlimited     bool  // 至少有一个无限包
	UnlimitUsedKB int64 // 无限包已用（联通无限包 remain 常为负数）
}

func classifyPackageName(name, limitRE, unlimitRE string) string {
	n := strings.ToLower(name)
	if unlimitRE != "" {
		if re, err := regexp.Compile("(?i)" + unlimitRE); err == nil && re.MatchString(name) {
			return "directed"
		}
	}
	if limitRE != "" {
		if re, err := regexp.Compile("(?i)" + limitRE); err == nil && re.MatchString(name) {
			return "general"
		}
	}
	directedHints := []string{
		"定向", "专属", "专用", "免流", "畅享", "视频", "音乐", "阅读",
		"腾讯", "爱奇艺", "优酷", "抖音", "头条", "微博", "王卡", "冰淇淋",
		"天翼视讯", "高清", "教育",
	}
	for _, h := range directedHints {
		if strings.Contains(name, h) || strings.Contains(n, strings.ToLower(h)) {
			return "directed"
		}
	}
	generalHints := []string{"通用", "结转", "主套餐", "国内流量", "套餐内", "月包"}
	for _, h := range generalHints {
		if strings.Contains(name, h) {
			return "general"
		}
	}
	return "general"
}

func addBucket(dst *flowBucket, remain, total, used int64) {
	if remain < 0 {
		remain = 0
	}
	if total < 0 {
		total = 0
	}
	if used < 0 {
		used = 0
	}
	if used == 0 && total > 0 && remain <= total {
		used = total - remain
	}
	if total == 0 && remain > 0 {
		total = remain + used
	}
	dst.RemainKB += remain
	dst.TotalKB += total
	dst.UsedKB += used
}

// addUnlimitedBucket 记无限包：不进剩余/总量，只累计已用并打标。
func addUnlimitedBucket(dst *flowBucket, used int64) {
	dst.Unlimited = true
	if used < 0 {
		used = 0
	}
	dst.UnlimitUsedKB += used
}

func parseFlowToKB(raw, unit string) int64 {
	raw = strings.TrimSpace(raw)
	unit = strings.ToUpper(strings.TrimSpace(unit))
	if raw == "" {
		return 0
	}
	// Strip non-numeric trailing junk: "1.23GB" style handled below.
	mul := float64(1)
	switch {
	case strings.Contains(unit, "TB") || strings.HasSuffix(strings.ToUpper(raw), "TB"):
		mul = 1024 * 1024 * 1024
		raw = strings.TrimSuffix(strings.TrimSuffix(raw, "TB"), "tb")
	case strings.Contains(unit, "GB") || strings.HasSuffix(strings.ToUpper(raw), "GB"):
		mul = 1024 * 1024
		raw = strings.TrimSuffix(strings.TrimSuffix(raw, "GB"), "gb")
	case strings.Contains(unit, "MB") || strings.HasSuffix(strings.ToUpper(raw), "MB"):
		mul = 1024
		raw = strings.TrimSuffix(strings.TrimSuffix(raw, "MB"), "mb")
	case strings.Contains(unit, "KB") || strings.HasSuffix(strings.ToUpper(raw), "KB"):
		mul = 1
		raw = strings.TrimSuffix(strings.TrimSuffix(raw, "KB"), "kb")
	case unit == "03" || unit == "3": // some OCS codes: 01B 02KB 03MB 04GB
		mul = 1024
	case unit == "04" || unit == "4":
		mul = 1024 * 1024
	case unit == "02" || unit == "2":
		mul = 1
	}
	raw = strings.TrimSpace(raw)
	f, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		// try extract leading number
		var b strings.Builder
		for i, r := range raw {
			if (r >= '0' && r <= '9') || r == '.' || (r == '-' && i == 0) {
				b.WriteRune(r)
			} else if b.Len() > 0 {
				break
			}
		}
		f, err = strconv.ParseFloat(b.String(), 64)
		if err != nil {
			return 0
		}
	}
	return int64(f*mul + 0.5)
}

func applyBuckets(card *CardStatus, general, directed flowBucket) {
	card.GeneralRemainKB = general.RemainKB
	card.GeneralTotalKB = general.TotalKB
	card.GeneralUsedKB = general.UsedKB
	card.DirectedRemainKB = directed.RemainKB
	card.DirectedTotalKB = directed.TotalKB
	card.DirectedUnlimited = directed.Unlimited
	card.DirectedUnlimitUsedKB = directed.UnlimitUsedKB
	// 跳点/免流增量用「有限已用 + 无限已用」
	card.DirectedUsedKB = directed.UsedKB + directed.UnlimitUsedKB
}
