package service

// 余量查询 + 授信 API（并进 WebSSH 单进程；不再跑 :8898 旁路）。
// 触屏读 /data/local/balance/status.json；授信写 accounts.json。

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"gossh/gin"
)

const (
	balanceDir      = "/data/local/balance"
	balanceAccounts = "/data/local/balance/accounts.json"
	balanceStatus   = "/data/local/balance/status.json"
)

func writeFile0600(path string, b []byte) error {
	_ = os.MkdirAll(filepath.Dir(path), 0755)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func balanceJSON(c *gin.Context, status int, v any) {
	c.Header("Cache-Control", "no-store")
	c.JSON(status, v)
}

func balanceBind(c *gin.Context, dst any) bool {
	if err := c.ShouldBindJSON(dst); err != nil {
		balanceJSON(c, 400, gin.H{"error": "bad json"})
		return false
	}
	return true
}

// BalanceStatusAction GET /api/balance/status —— 触屏同源的 status.json
func BalanceStatusAction(c *gin.Context) {
	b, err := os.ReadFile(balanceStatus)
	if err != nil {
		if os.IsNotExist(err) {
			balanceJSON(c, 200, gin.H{"ok": false, "error": "尚无余量数据，等待查询器写入"})
			return
		}
		balanceJSON(c, 500, gin.H{"ok": false, "error": err.Error()})
		return
	}
	var raw any
	if err := json.Unmarshal(b, &raw); err != nil {
		balanceJSON(c, 500, gin.H{"ok": false, "error": "status.json 损坏"})
		return
	}
	c.Header("Cache-Control", "no-store")
	c.Header("Content-Type", "application/json; charset=utf-8")
	c.JSON(http.StatusOK, raw)
}

// BalanceAccountsAction GET /api/balance/accounts —— 授信状态摘要（不回显密钥）
func BalanceAccountsAction(c *gin.Context) {
	balanceJSON(c, 200, statusSummary(balanceAccounts))
}

func BalanceUnicomSend(c *gin.Context) {
	var req struct {
		Phone string `json:"phone"`
	}
	if !balanceBind(c, &req) {
		return
	}
	phone, err := mustPhone11(req.Phone)
	if err != nil {
		balanceJSON(c, 400, gin.H{"error": err.Error()})
		return
	}
	if err := unicomSendSMS(phone); err != nil {
		balanceJSON(c, 502, gin.H{"error": err.Error()})
		return
	}
	balanceJSON(c, 200, gin.H{"ok": true, "sent": true})
}

func BalanceUnicomLogin(c *gin.Context) {
	var req struct {
		Phone string `json:"phone"`
		Code  string `json:"code"`
	}
	if !balanceBind(c, &req) {
		return
	}
	phone, err := mustPhone11(req.Phone)
	if err != nil {
		balanceJSON(c, 400, gin.H{"error": err.Error()})
		return
	}
	code := strings.TrimSpace(req.Code)
	if len(code) < 4 {
		balanceJSON(c, 400, gin.H{"error": "验证码无效"})
		return
	}
	token, appID, err := unicomLoginSMS(phone, code)
	if err != nil {
		balanceJSON(c, 502, gin.H{"error": err.Error()})
		return
	}
	if err := upsertUnicom(balanceAccounts, phone, token, appID); err != nil {
		balanceJSON(c, 500, gin.H{"error": "写入 accounts 失败: " + err.Error()})
		return
	}
	balanceJSON(c, 200, gin.H{
		"ok": true, "phone": maskPhone(phone), "has_app_id": appID != "",
		"token_len": len(token),
	})
}

func BalanceTelecomChallenge(c *gin.Context) {
	var req struct {
		Phone string `json:"phone"`
	}
	if !balanceBind(c, &req) {
		return
	}
	phone, err := mustPhone11(req.Phone)
	if err != nil {
		balanceJSON(c, 400, gin.H{"error": err.Error()})
		return
	}
	sid, ch, err := telecomChallenge(phone)
	if err != nil {
		balanceJSON(c, 502, gin.H{"error": err.Error()})
		return
	}
	balanceJSON(c, 200, gin.H{"session_id": sid, "challenge": ch})
}

func BalanceTelecomRefresh(c *gin.Context) {
	var req struct {
		SessionID string `json:"session_id"`
	}
	if !balanceBind(c, &req) {
		return
	}
	ch, err := telecomRefreshChallenge(req.SessionID)
	if err != nil {
		balanceJSON(c, 502, gin.H{"error": err.Error()})
		return
	}
	balanceJSON(c, 200, gin.H{"challenge": ch})
}

func BalanceTelecomSendSMS(c *gin.Context) {
	var req struct {
		SessionID string  `json:"session_id"`
		Distance  float64 `json:"distance"`
		Track     string  `json:"track"`
		StartTime int64   `json:"start_time"`
		EndTime   int64   `json:"end_time"`
	}
	if !balanceBind(c, &req) {
		return
	}
	if err := telecomSendSMS(req.SessionID, req.Distance, req.Track, req.StartTime, req.EndTime); err != nil {
		balanceJSON(c, 502, gin.H{"error": err.Error()})
		return
	}
	balanceJSON(c, 200, gin.H{"sent": true})
}

func BalanceTelecomSubmitSMS(c *gin.Context) {
	var req struct {
		SessionID string `json:"session_id"`
		Code      string `json:"code"`
	}
	if !balanceBind(c, &req) {
		return
	}
	deviceID, err := telecomSubmitSMS(req.SessionID, strings.TrimSpace(req.Code))
	if err != nil {
		balanceJSON(c, 502, gin.H{"error": err.Error()})
		return
	}
	s, _ := getTelecomSession(req.SessionID)
	if s != nil {
		_ = upsertTelecom(balanceAccounts, s.Phone, "", deviceID)
		_ = saveTelecomLoginCache(balanceDir, s.Phone, s.Token, s.Province, s.City, deviceID)
	}
	balanceJSON(c, 200, gin.H{"device_id": deviceID, "saved": true})
}

func BalanceTelecomComplete(c *gin.Context) {
	var req struct {
		SessionID string `json:"session_id"`
		Password  string `json:"password"`
	}
	if !balanceBind(c, &req) {
		return
	}
	pass := strings.TrimSpace(req.Password)
	if pass == "" {
		balanceJSON(c, 400, gin.H{"error": "请输入服务密码"})
		return
	}
	if err := telecomVerifyPassword(req.SessionID, pass); err != nil {
		balanceJSON(c, 400, gin.H{"error": err.Error()})
		return
	}
	s, err := getTelecomSession(req.SessionID)
	if err != nil {
		balanceJSON(c, 410, gin.H{"error": err.Error()})
		return
	}
	if err := upsertTelecom(balanceAccounts, s.Phone, pass, s.DeviceID); err != nil {
		balanceJSON(c, 500, gin.H{"error": err.Error()})
		return
	}
	_ = saveTelecomLoginCache(balanceDir, s.Phone, s.Token, s.Province, s.City, s.DeviceID)
	balanceJSON(c, 200, gin.H{"completed": true, "device_id": s.DeviceID})
}
