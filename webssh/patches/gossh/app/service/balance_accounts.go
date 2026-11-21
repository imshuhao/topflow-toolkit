package service

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
)

type accountCard struct {
	ID          string `json:"id"`
	Operator    string `json:"operator"`
	Phone       string `json:"phone"`
	Label       string `json:"label"`
	TokenOnline string `json:"token_online,omitempty"`
	AppID       string `json:"app_id,omitempty"`
	Password    string `json:"password,omitempty"`
	DeviceUID   string `json:"device_uid,omitempty"`
	LimitRE     string `json:"limit_re,omitempty"`
	UnlimitRE   string `json:"unlimit_re,omitempty"`
}

type accountsFile struct {
	Proxy      string        `json:"proxy"`
	TimeoutSec int           `json:"timeout_sec"`
	Cards      []accountCard `json:"cards"`
}

var accountsMu sync.Mutex

func loadAccounts(path string) (*accountsFile, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return &accountsFile{Proxy: "http://127.0.0.1:7890", TimeoutSec: 25, Cards: nil}, nil
		}
		return nil, err
	}
	var f accountsFile
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, err
	}
	if f.Proxy == "" {
		f.Proxy = "http://127.0.0.1:7890"
	}
	if f.TimeoutSec == 0 {
		f.TimeoutSec = 25
	}
	return &f, nil
}

func saveAccounts(path string, f *accountsFile) error {
	b, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func upsertUnicom(path, phone, token, appID string) error {
	accountsMu.Lock()
	defer accountsMu.Unlock()
	f, err := loadAccounts(path)
	if err != nil {
		return err
	}
	phone = digitsOnly(phone)
	found := false
	for i := range f.Cards {
		c := &f.Cards[i]
		if c.Operator == "unicom" && digitsOnly(c.Phone) == phone {
			c.TokenOnline = token
			if appID != "" {
				c.AppID = appID
			}
			if c.Label == "" {
				c.Label = "联通免流"
			}
			if c.ID == "" {
				c.ID = "unicom-main"
			}
			found = true
			break
		}
	}
	if !found {
		f.Cards = append(f.Cards, accountCard{
			ID:          "unicom-main",
			Operator:    "unicom",
			Phone:       phone,
			Label:       "联通免流",
			TokenOnline: token,
			AppID:       appID,
		})
	}
	return saveAccounts(path, f)
}

func upsertTelecom(path, phone, password, deviceUID string) error {
	accountsMu.Lock()
	defer accountsMu.Unlock()
	f, err := loadAccounts(path)
	if err != nil {
		return err
	}
	phone = digitsOnly(phone)
	found := false
	for i := range f.Cards {
		c := &f.Cards[i]
		if c.Operator == "telecom" && digitsOnly(c.Phone) == phone {
			if password != "" {
				c.Password = password
			}
			if deviceUID != "" {
				c.DeviceUID = deviceUID
			}
			if c.Label == "" {
				c.Label = "电信免流"
			}
			if c.ID == "" {
				c.ID = "telecom-main"
			}
			found = true
			break
		}
	}
	if !found {
		f.Cards = append(f.Cards, accountCard{
			ID:        "telecom-main",
			Operator:  "telecom",
			Phone:     phone,
			Label:     "电信免流",
			Password:  password,
			DeviceUID: deviceUID,
		})
	}
	return saveAccounts(path, f)
}

func statusSummary(path string) map[string]any {
	accountsMu.Lock()
	defer accountsMu.Unlock()
	f, err := loadAccounts(path)
	if err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	cards := make([]map[string]any, 0, len(f.Cards))
	for _, c := range f.Cards {
		item := map[string]any{
			"id":       c.ID,
			"operator": c.Operator,
			"label":    c.Label,
			"phone":    maskPhone(c.Phone),
		}
		switch c.Operator {
		case "unicom":
			item["has_token"] = strings.TrimSpace(c.TokenOnline) != ""
			item["has_app_id"] = strings.TrimSpace(c.AppID) != ""
		case "telecom":
			item["has_password"] = strings.TrimSpace(c.Password) != ""
			item["has_device_uid"] = strings.TrimSpace(c.DeviceUID) != ""
		}
		cards = append(cards, item)
	}
	return map[string]any{"ok": true, "proxy": f.Proxy, "cards": cards}
}

func digitsOnly(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func maskPhone(phone string) string {
	d := digitsOnly(phone)
	if len(d) < 7 {
		return phone
	}
	return d[:3] + "****" + d[len(d)-4:]
}

func mustPhone11(phone string) (string, error) {
	d := digitsOnly(phone)
	if len(d) != 11 {
		return "", fmt.Errorf("手机号须为 11 位数字")
	}
	return d, nil
}
