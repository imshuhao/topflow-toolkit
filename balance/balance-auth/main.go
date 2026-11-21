package main

import (
	"crypto/rand"
	"embed"
	"encoding/base64"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

//go:embed static/*
var staticFS embed.FS

var (
	listenAddr   = flag.String("listen", "192.168.0.1:8898", "listen address (LAN only)")
	accountsPath = flag.String("accounts", "/data/local/balance/accounts.json", "accounts.json path")
	stateDir     = flag.String("dir", "/data/local/balance", "balance state directory")
)

var (
	accessMu     sync.Mutex
	accessTokens = map[string]time.Time{}
)

func issueAccessToken() string {
	b := make([]byte, 24)
	_, _ = rand.Read(b)
	tok := base64.RawURLEncoding.EncodeToString(b)
	accessMu.Lock()
	now := time.Now()
	for k, exp := range accessTokens {
		if now.After(exp) {
			delete(accessTokens, k)
		}
	}
	accessTokens[tok] = now.Add(30 * time.Minute)
	accessMu.Unlock()
	return tok
}

func validAccessToken(tok string) bool {
	accessMu.Lock()
	defer accessMu.Unlock()
	exp, ok := accessTokens[tok]
	if !ok {
		return false
	}
	if time.Now().After(exp) {
		delete(accessTokens, tok)
		return false
	}
	accessTokens[tok] = time.Now().Add(30 * time.Minute)
	return true
}

func writeFile0600(path string, b []byte) error {
	_ = os.MkdirAll(filepath.Dir(path), 0755)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func readJSON(r *http.Request, dst any) error {
	defer r.Body.Close()
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	return dec.Decode(dst)
}

func requireAccess(w http.ResponseWriter, r *http.Request) bool {
	h := r.Header.Get("Authorization")
	if !strings.HasPrefix(h, "Bearer ") || !validAccessToken(strings.TrimPrefix(h, "Bearer ")) {
		writeJSON(w, 401, map[string]any{"error": "Unauthorized"})
		return false
	}
	return true
}

func main() {
	flag.Parse()
	_ = os.MkdirAll(*stateDir, 0755)

	mux := http.NewServeMux()
	mux.HandleFunc("/", handleIndex)
	mux.HandleFunc("/style.css", serveStatic("static/style.css", "text/css; charset=utf-8"))
	mux.HandleFunc("/app.js", serveStatic("static/app.js", "text/javascript; charset=utf-8"))
	mux.HandleFunc("/api/status", handleStatus)
	mux.HandleFunc("/api/unicom/send", handleUnicomSend)
	mux.HandleFunc("/api/unicom/login", handleUnicomLogin)
	mux.HandleFunc("/api/telecom/challenge", handleTelecomChallenge)
	mux.HandleFunc("/api/telecom/refresh", handleTelecomRefresh)
	mux.HandleFunc("/api/telecom/send-sms", handleTelecomSendSMS)
	mux.HandleFunc("/api/telecom/submit-sms", handleTelecomSubmitSMS)
	mux.HandleFunc("/api/telecom/complete", handleTelecomComplete)

	ln, err := net.Listen("tcp", *listenAddr)
	if err != nil {
		log.Fatalf("listen %s: %v", *listenAddr, err)
	}
	log.Printf("balance-auth listening on http://%s/  accounts=%s", *listenAddr, *accountsPath)
	log.Fatal(http.Serve(ln, mux))
}

func serveStatic(name, ctype string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		b, err := staticFS.ReadFile(name)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", ctype)
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(b)
	}
}

func handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	b, err := staticFS.ReadFile("static/index.html")
	if err != nil {
		http.Error(w, "missing index", 500)
		return
	}
	tok := issueAccessToken()
	html := strings.Replace(string(b), `content=""`, `content="`+tok+`"`, 1)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte(html))
}

func handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		w.WriteHeader(405)
		return
	}
	writeJSON(w, 200, statusSummary(*accountsPath))
}

func handleUnicomSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || !requireAccess(w, r) {
		return
	}
	var req struct {
		Phone string `json:"phone"`
	}
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, 400, map[string]any{"error": "bad json"})
		return
	}
	phone, err := mustPhone11(req.Phone)
	if err != nil {
		writeJSON(w, 400, map[string]any{"error": err.Error()})
		return
	}
	if err := unicomSendSMS(phone); err != nil {
		writeJSON(w, 502, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "sent": true})
}

func handleUnicomLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || !requireAccess(w, r) {
		return
	}
	var req struct {
		Phone string `json:"phone"`
		Code  string `json:"code"`
	}
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, 400, map[string]any{"error": "bad json"})
		return
	}
	phone, err := mustPhone11(req.Phone)
	if err != nil {
		writeJSON(w, 400, map[string]any{"error": err.Error()})
		return
	}
	code := strings.TrimSpace(req.Code)
	if len(code) < 4 {
		writeJSON(w, 400, map[string]any{"error": "验证码无效"})
		return
	}
	token, appID, err := unicomLoginSMS(phone, code)
	if err != nil {
		writeJSON(w, 502, map[string]any{"error": err.Error()})
		return
	}
	if err := upsertUnicom(*accountsPath, phone, token, appID); err != nil {
		writeJSON(w, 500, map[string]any{"error": "写入 accounts 失败: " + err.Error()})
		return
	}
	writeJSON(w, 200, map[string]any{
		"ok": true, "phone": maskPhone(phone), "has_app_id": appID != "",
		"token_len": len(token),
	})
}

func handleTelecomChallenge(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || !requireAccess(w, r) {
		return
	}
	var req struct {
		Phone string `json:"phone"`
	}
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, 400, map[string]any{"error": "bad json"})
		return
	}
	phone, err := mustPhone11(req.Phone)
	if err != nil {
		writeJSON(w, 400, map[string]any{"error": err.Error()})
		return
	}
	sid, ch, err := telecomChallenge(phone)
	if err != nil {
		writeJSON(w, 502, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, 200, map[string]any{"session_id": sid, "challenge": ch})
}

func handleTelecomRefresh(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || !requireAccess(w, r) {
		return
	}
	var req struct {
		SessionID string `json:"session_id"`
	}
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, 400, map[string]any{"error": "bad json"})
		return
	}
	ch, err := telecomRefreshChallenge(req.SessionID)
	if err != nil {
		writeJSON(w, 502, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, 200, map[string]any{"challenge": ch})
}

func handleTelecomSendSMS(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || !requireAccess(w, r) {
		return
	}
	var req struct {
		SessionID string  `json:"session_id"`
		Distance  float64 `json:"distance"`
		Track     string  `json:"track"`
		StartTime int64   `json:"start_time"`
		EndTime   int64   `json:"end_time"`
	}
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, 400, map[string]any{"error": "bad json"})
		return
	}
	if err := telecomSendSMS(req.SessionID, req.Distance, req.Track, req.StartTime, req.EndTime); err != nil {
		writeJSON(w, 502, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, 200, map[string]any{"sent": true})
}

func handleTelecomSubmitSMS(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || !requireAccess(w, r) {
		return
	}
	var req struct {
		SessionID string `json:"session_id"`
		Code      string `json:"code"`
	}
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, 400, map[string]any{"error": "bad json"})
		return
	}
	deviceID, err := telecomSubmitSMS(req.SessionID, strings.TrimSpace(req.Code))
	if err != nil {
		writeJSON(w, 502, map[string]any{"error": err.Error()})
		return
	}
	s, _ := getTelecomSession(req.SessionID)
	if s != nil {
		_ = upsertTelecom(*accountsPath, s.Phone, "", deviceID)
		_ = saveTelecomLoginCache(*stateDir, s.Phone, s.Token, s.Province, s.City, deviceID)
	}
	writeJSON(w, 200, map[string]any{"device_id": deviceID, "saved": true})
}

func handleTelecomComplete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || !requireAccess(w, r) {
		return
	}
	var req struct {
		SessionID string `json:"session_id"`
		Password  string `json:"password"`
	}
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, 400, map[string]any{"error": "bad json"})
		return
	}
	pass := strings.TrimSpace(req.Password)
	if pass == "" {
		writeJSON(w, 400, map[string]any{"error": "请输入服务密码"})
		return
	}
	if err := telecomVerifyPassword(req.SessionID, pass); err != nil {
		writeJSON(w, 400, map[string]any{"error": err.Error()})
		return
	}
	s, err := getTelecomSession(req.SessionID)
	if err != nil {
		writeJSON(w, 410, map[string]any{"error": err.Error()})
		return
	}
	if err := upsertTelecom(*accountsPath, s.Phone, pass, s.DeviceID); err != nil {
		writeJSON(w, 500, map[string]any{"error": err.Error()})
		return
	}
	_ = saveTelecomLoginCache(*stateDir, s.Phone, s.Token, s.Province, s.City, s.DeviceID)
	writeJSON(w, 200, map[string]any{"completed": true, "device_id": s.DeviceID})
}
