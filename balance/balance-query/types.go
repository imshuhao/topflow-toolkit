package main

import "time"

const (
	OperatorUnicom  = "unicom"
	OperatorTelecom = "telecom"
)

// Account is one SIM's credentials (slot-agnostic; keyed by phone).
type Account struct {
	ID          string `json:"id"`
	Operator    string `json:"operator"` // unicom | telecom
	Phone       string `json:"phone"`
	Label       string `json:"label"`
	TokenOnline string `json:"token_online"` // unicom
	AppID       string `json:"app_id"`       // unicom optional
	Password    string `json:"password"`     // telecom 6-digit service password
	TeleBD      string `json:"tele_bd"`      // telecom captured body (optional alt)
	LimitRE     string `json:"limit_re"`     // optional package name regex → general
	UnlimitRE   string `json:"unlimit_re"`   // optional package name regex → directed
	AndroidID   string `json:"android_id"`
	DeviceUID   string `json:"device_uid"`
}

// AccountsFile is /data/local/balance/accounts.json
type AccountsFile struct {
	Proxy   string    `json:"proxy"` // default http://127.0.0.1:7890
	Timeout int       `json:"timeout_sec"`
	Cards   []Account `json:"cards"`
}

// CardStatus is one card snapshot for the touch UI.
type CardStatus struct {
	ID               string `json:"id"`
	Phone            string `json:"phone"`
	PhoneTail        string `json:"phone_tail"`
	Operator         string `json:"operator"`
	Label            string `json:"label"`
	OK               bool   `json:"ok"`
	Error            string `json:"error,omitempty"`
	GeneralRemainKB       int64  `json:"general_remain_kb"`
	GeneralTotalKB        int64  `json:"general_total_kb"`
	GeneralUsedKB         int64  `json:"general_used_kb"`
	DirectedRemainKB      int64  `json:"directed_remain_kb"` // 有限定向剩余
	DirectedTotalKB       int64  `json:"directed_total_kb"`  // 有限定向总量
	DirectedUsedKB        int64  `json:"directed_used_kb"`   // 有限+无限已用（跳点用）
	DirectedUnlimited     bool   `json:"directed_unlimited"` // 存在无限定向包
	DirectedUnlimitUsedKB int64  `json:"directed_unlimit_used_kb"`
	JumpDeltaKB           int64  `json:"jump_delta_kb"`
	FreeDeltaKB           int64  `json:"free_delta_kb"`
	JumpTodayKB           int64  `json:"jump_today_kb"`
	UpdatedAt             string `json:"updated_at"`
}

// StatusFile is /data/local/balance/status.json
type StatusFile struct {
	OK          bool         `json:"ok"`
	UpdatedAt   string       `json:"updated_at"`   // 本次查询 RFC3339
	Updated     string       `json:"updated"`      // 本次查询 HH:MM:SS
	NextAt      string       `json:"next_at"`      // 下次查询 RFC3339
	Next        string       `json:"next"`         // 下次查询 HH:MM:SS
	IntervalSec int          `json:"interval_sec"` // 采样间隔
	Error       string       `json:"error,omitempty"`
	Cards       []CardStatus `json:"cards"`
}

// HistorySnap is one line in history.jsonl for jump-point diffs.
type HistorySnap struct {
	ID               string `json:"id"`
	Day              string `json:"day"`
	TS               string `json:"ts"`
	GeneralUsedKB    int64  `json:"general_used_kb"`
	DirectedUsedKB   int64  `json:"directed_used_kb"`
	GeneralRemainKB  int64  `json:"general_remain_kb"`
	DirectedRemainKB int64  `json:"directed_remain_kb"`
}

func nowLocal() time.Time { return time.Now().Local() }

func phoneTail(phone string) string {
	digits := make([]rune, 0, len(phone))
	for _, r := range phone {
		if r >= '0' && r <= '9' {
			digits = append(digits, r)
		}
	}
	if len(digits) < 4 {
		return string(digits)
	}
	return string(digits[len(digits)-4:])
}

func maskPhone(phone string) string {
	digits := make([]rune, 0, len(phone))
	for _, r := range phone {
		if r >= '0' && r <= '9' {
			digits = append(digits, r)
		}
	}
	if len(digits) < 7 {
		return phone
	}
	return string(digits[:3]) + "****" + string(digits[len(digits)-4:])
}
