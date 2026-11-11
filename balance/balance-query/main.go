package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	base := flag.String("dir", "/data/local/balance", "balance state directory")
	accountsPath := flag.String("accounts", "", "accounts.json path (default: <dir>/accounts.json)")
	outPath := flag.String("out", "", "status.json path (default: <dir>/status.json)")
	intervalFlag := flag.Int("interval", 0, "seconds until next query (default env BALANCE_INTERVAL_SEC or 900)")
	flag.Parse()

	dir := *base
	accFile := *accountsPath
	if accFile == "" {
		accFile = filepath.Join(dir, "accounts.json")
	}
	statusFile := *outPath
	if statusFile == "" {
		statusFile = filepath.Join(dir, "status.json")
	}
	_ = os.MkdirAll(dir, 0700)

	intervalSec := resolveIntervalSec(*intervalFlag)

	cfg, err := loadAccounts(accFile)
	if err != nil {
		writeFail(statusFile, err.Error(), intervalSec)
		fmt.Fprintf(os.Stderr, "load accounts: %v\n", err)
		os.Exit(1)
	}
	proxy := strings.TrimSpace(cfg.Proxy)
	if proxy == "" {
		proxy = "http://127.0.0.1:7890"
	}
	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = 25
	}
	client, err := httpClient(proxy, time.Duration(timeout)*time.Second)
	if err != nil {
		writeFail(statusFile, err.Error(), intervalSec)
		fmt.Fprintf(os.Stderr, "http client: %v\n", err)
		os.Exit(1)
	}

	prev := loadHistory(filepath.Join(dir, "history.jsonl"))
	todayJump := loadTodayJump(filepath.Join(dir, "history.jsonl"))

	now := nowLocal()
	next := now.Add(time.Duration(intervalSec) * time.Second)
	status := StatusFile{
		UpdatedAt:   now.Format(time.RFC3339),
		Updated:     now.Format("15:04:05"),
		NextAt:      next.Format(time.RFC3339),
		Next:        next.Format("15:04:05"),
		IntervalSec: intervalSec,
		Cards:       make([]CardStatus, 0, len(cfg.Cards)),
	}
	allOK := true
	for _, acc := range cfg.Cards {
		op := strings.ToLower(strings.TrimSpace(acc.Operator))
		var card CardStatus
		switch op {
		case OperatorUnicom, "联通", "cu":
			acc.Operator = OperatorUnicom
			card = queryUnicom(client, acc)
		case OperatorTelecom, "电信", "ct":
			acc.Operator = OperatorTelecom
			card = queryTelecom(client, dir, acc)
		default:
			card = CardStatus{
				ID:        orDefault(acc.ID, "unknown"),
				Phone:     maskPhone(acc.Phone),
				PhoneTail: phoneTail(acc.Phone),
				Operator:  acc.Operator,
				Label:     orDefault(acc.Label, acc.Operator),
				Error:     "unknown operator (use unicom|telecom)",
				UpdatedAt: now.Format(time.RFC3339),
			}
		}
		if card.ID == "" {
			card.ID = orDefault(acc.ID, acc.Operator+"-"+phoneTail(acc.Phone))
		}
		if card.OK {
			id := card.ID
			if p, ok := prev[id]; ok {
				// 跳点 = 相对上次采样，通用少用了多少（已用增量优先；否则用剩余减量）
				if card.GeneralUsedKB >= p.GeneralUsedKB {
					card.JumpDeltaKB = card.GeneralUsedKB - p.GeneralUsedKB
				}
				if card.JumpDeltaKB == 0 && p.GeneralRemainKB > card.GeneralRemainKB {
					card.JumpDeltaKB = p.GeneralRemainKB - card.GeneralRemainKB
				}
				if card.DirectedUsedKB >= p.DirectedUsedKB {
					card.FreeDeltaKB = card.DirectedUsedKB - p.DirectedUsedKB
				}
			}
			card.JumpTodayKB = todayJump[id] + card.JumpDeltaKB
			appendHistory(filepath.Join(dir, "history.jsonl"), HistorySnap{
				ID:               id,
				Day:              now.Format("2006-01-02"),
				TS:               now.Format(time.RFC3339),
				GeneralUsedKB:    card.GeneralUsedKB,
				DirectedUsedKB:   card.DirectedUsedKB,
				GeneralRemainKB:  card.GeneralRemainKB,
				DirectedRemainKB: card.DirectedRemainKB,
			})
		} else {
			allOK = false
		}
		status.Cards = append(status.Cards, card)
		dirExtra := ""
		if card.DirectedUnlimited {
			dirExtra = fmt.Sprintf(" unlimUsed=%d", card.DirectedUnlimitUsedKB)
		}
		fmt.Fprintf(os.Stderr, "%s %s ok=%v err=%s gen=%d/%d dir=%d/%d%s jump=%d\n",
			card.Operator, card.PhoneTail, card.OK, card.Error,
			card.GeneralRemainKB, card.GeneralTotalKB,
			card.DirectedRemainKB, card.DirectedTotalKB, dirExtra, card.JumpDeltaKB)
	}
	status.OK = allOK && len(status.Cards) > 0
	if len(status.Cards) == 0 {
		status.Error = "no cards configured"
		status.OK = false
	}
	if err := writeStatus(statusFile, &status); err != nil {
		fmt.Fprintf(os.Stderr, "write status: %v\n", err)
		os.Exit(1)
	}
	if !status.OK {
		os.Exit(2)
	}
}

func loadAccounts(path string) (*AccountsFile, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg AccountsFile
	if err := json.Unmarshal(b, &cfg); err != nil {
		return nil, err
	}
	if len(cfg.Cards) == 0 {
		return nil, fmt.Errorf("accounts.cards empty")
	}
	return &cfg, nil
}

func httpClient(proxy string, timeout time.Duration) (*http.Client, error) {
	transport := &http.Transport{}
	if proxy != "" && proxy != "direct" && proxy != "none" {
		u, err := url.Parse(proxy)
		if err != nil {
			return nil, err
		}
		transport.Proxy = http.ProxyURL(u)
	}
	return &http.Client{Timeout: timeout, Transport: transport}, nil
}

func writeStatus(path string, st *StatusFile) error {
	b, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func resolveIntervalSec(flagVal int) int {
	if flagVal > 0 {
		return flagVal
	}
	if v := strings.TrimSpace(os.Getenv("BALANCE_INTERVAL_SEC")); v != "" {
		var n int
		if _, err := fmt.Sscanf(v, "%d", &n); err == nil && n > 0 {
			return n
		}
	}
	return 900 // 默认 15 分钟
}

func writeFail(path, msg string, intervalSec int) {
	if intervalSec <= 0 {
		intervalSec = resolveIntervalSec(0)
	}
	now := nowLocal()
	next := now.Add(time.Duration(intervalSec) * time.Second)
	_ = writeStatus(path, &StatusFile{
		OK:          false,
		UpdatedAt:   now.Format(time.RFC3339),
		Updated:     now.Format("15:04:05"),
		NextAt:      next.Format(time.RFC3339),
		Next:        next.Format("15:04:05"),
		IntervalSec: intervalSec,
		Error:       msg,
		Cards:       []CardStatus{},
	})
}

func loadHistory(path string) map[string]HistorySnap {
	out := map[string]HistorySnap{}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var h HistorySnap
		if json.Unmarshal([]byte(line), &h) == nil && h.ID != "" {
			out[h.ID] = h
		}
	}
	return out
}

func loadTodayJump(path string) map[string]int64 {
	out := map[string]int64{}
	day := nowLocal().Format("2006-01-02")
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()
	prev := map[string]int64{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var h HistorySnap
		if json.Unmarshal([]byte(line), &h) != nil || h.Day != day {
			continue
		}
		if p, ok := prev[h.ID]; ok && h.GeneralUsedKB >= p {
			out[h.ID] += h.GeneralUsedKB - p
		}
		prev[h.ID] = h.GeneralUsedKB
	}
	return out
}

func appendHistory(path string, h HistorySnap) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	b, _ := json.Marshal(h)
	_, _ = f.Write(append(b, '\n'))
}
