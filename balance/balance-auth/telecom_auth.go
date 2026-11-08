package main

import (
	"bytes"
	"crypto/aes"
	"crypto/md5"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

const telecomRSAPubPEM = `-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDBkLT15ThVgz6/NOl6s8GNPofd
WzWbCkWnkaAm7O2LjkM1H7dMvzkiqdxU02jamGRHLX/ZNMCXHnPcW/sDhiFCBN18
qFvy8g6VYb9QtroI09e176s+ZCtiv7hbin2cCTj99iUpnEloZm19lwHyo69u5UMi
PMpq0/XKBO8lYhN/gwIDAQAB
-----END PUBLIC KEY-----`

type telecomSession struct {
	Phone       string
	UID         string
	Key         string
	IsCT        string
	SliderKey   string
	SliderExtra string
	DeviceID    string
	Token       string
	Province    string
	City        string
	SMSSent     bool
	SMSOK       bool
	Created     time.Time
}

var (
	telecomMu   sync.Mutex
	telecomSess = map[string]*telecomSession{}
)

func telecomCaesar(s string) string {
	out := make([]rune, 0, len(s))
	for _, r := range s {
		out = append(out, rune(int(r)+2))
	}
	return string(out)
}

func telecomRSA(plain string) (string, error) {
	block, _ := pem.Decode([]byte(telecomRSAPubPEM))
	if block == nil {
		return "", fmt.Errorf("pem decode failed")
	}
	pubAny, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return "", err
	}
	pub := pubAny.(*rsa.PublicKey)
	cipher, err := rsa.EncryptPKCS1v15(rand.Reader, pub, []byte(plain))
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(cipher), nil
}

func telecomAES(plain string, key []byte) (string, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	padLen := aes.BlockSize - len(plain)%aes.BlockSize
	padded := append([]byte(plain), bytes.Repeat([]byte{byte(padLen)}, padLen)...)
	out := make([]byte, len(padded))
	for i := 0; i < len(padded); i += aes.BlockSize {
		block.Encrypt(out[i:i+aes.BlockSize], padded[i:i+aes.BlockSize])
	}
	return base64.StdEncoding.EncodeToString(out), nil
}

func telecomPost(host, path string, body any) (map[string]any, error) {
	raw, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(host, "/")+path, bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json; charset=UTF-8")
	req.Header.Set("Connection", "Keep-Alive")
	req.Header.Set("user-agent", "P216010901")
	client := &http.Client{Timeout: 25 * time.Second, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	var out map[string]any
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, fmt.Errorf("telecom non-json: %s", truncate(string(b), 180))
	}
	return out, nil
}

func (s *telecomSession) loginV2(code string, fields map[string]any, headerExtra map[string]string) (map[string]any, map[string]any, error) {
	headers := map[string]any{
		"broadAccount": "", "broadToken": "", "fixedLineAccount": "", "fixedLineToken": "",
		"provinceCode": "", "code": code, "source": "120002", "sourcePassword": "TiqmIZ",
		"userLoginName": "", "clientType": "#13.4.0#channel50#iPhone 11 Pro Max#",
		"token": "", "timestamp": time.Now().Format("20060102150405"), "shopId": "20004",
	}
	for k, v := range headerExtra {
		headers[k] = v
	}
	body := map[string]any{
		"headerInfos": headers,
		"content":     map[string]any{"attach": "iPhone", "fieldData": fields},
	}
	result, err := telecomPost("https://appgologinsz.189.cn", "/login/client/"+code, body)
	if err != nil {
		return nil, nil, err
	}
	rd, _ := result["responseData"].(map[string]any)
	if rd == nil {
		return nil, nil, fmt.Errorf("INVALID_RESPONSE")
	}
	data, _ := rd["data"].(map[string]any)
	if data == nil {
		data = map[string]any{}
	}
	return rd, data, nil
}

func (s *telecomSession) updateState(data map[string]any) {
	if v := fmt.Sprint(data["key"]); v != "" && v != "<nil>" {
		s.Key = v
	}
	if _, ok := data["isChinatelecom"]; ok {
		s.IsCT = fmt.Sprint(data["isChinatelecom"])
	}
}

func newTelecomSession(phone string) (string, *telecomSession) {
	uidSum := md5.Sum([]byte("CT_IOS_11_" + phone))
	s := &telecomSession{
		Phone:   phone,
		UID:     hex.EncodeToString(uidSum[:]),
		IsCT:    "0",
		Created: time.Now(),
	}
	sid := make([]byte, 32)
	_, _ = rand.Read(sid)
	id := base64.RawURLEncoding.EncodeToString(sid)
	telecomMu.Lock()
	// prune old
	for k, v := range telecomSess {
		if time.Since(v.Created) > 10*time.Minute {
			delete(telecomSess, k)
		}
	}
	telecomSess[id] = s
	telecomMu.Unlock()
	return id, s
}

func getTelecomSession(id string) (*telecomSession, error) {
	telecomMu.Lock()
	defer telecomMu.Unlock()
	s := telecomSess[id]
	if s == nil {
		return nil, fmt.Errorf("会话无效或已过期")
	}
	if time.Since(s.Created) > 10*time.Minute {
		delete(telecomSess, id)
		return nil, fmt.Errorf("会话已过期")
	}
	return s, nil
}

func telecomChallenge(phone string) (sessionID string, challenge map[string]any, err error) {
	sid, s := newTelecomSession(phone)
	fields := map[string]any{
		"deviceUid": s.UID, "imsi": "", "key": s.Key, "payType": "",
		"phoneNum": telecomCaesar(phone), "salesProdId": "", "scene": "55",
		"signSignatureString": "", "validationCode": "",
	}
	_, data, err := s.loginV2("getLoginRandomCode", fields, nil)
	if err != nil {
		return "", nil, err
	}
	s.updateState(data)
	sliderFields := map[string]any{
		"account": telecomCaesar(phone), "clientType": "1",
		"deviceUid": telecomCaesar(s.UID), "scene": "1",
	}
	_, slider, err := s.loginV2("getSliderVerificationPicture", sliderFields, nil)
	if err != nil {
		return "", nil, err
	}
	bg := fmt.Sprint(slider["backgroundImg"])
	if bg == "" || bg == "<nil>" {
		bg = fmt.Sprint(slider["bigImg"])
	}
	piece := fmt.Sprint(slider["sliderImg"])
	if piece == "" || piece == "<nil>" {
		piece = fmt.Sprint(slider["smallImg"])
	}
	key := fmt.Sprint(slider["key"])
	extra := fmt.Sprint(slider["extra"])
	if bg == "" || bg == "<nil>" || piece == "" || piece == "<nil>" || key == "" || key == "<nil>" || extra == "" || extra == "<nil>" {
		return "", nil, fmt.Errorf("滑块挑战不完整")
	}
	s.SliderKey = key
	s.SliderExtra = extra
	challenge = map[string]any{
		"background_img":    bg,
		"slider_img":        piece,
		"background_width":  slider["backgroundWidth"],
		"background_height": slider["backgroundHeight"],
		"slider_width":      slider["sliderWidth"],
		"slider_height":     slider["sliderHeight"],
	}
	return sid, challenge, nil
}

func telecomRefreshChallenge(sessionID string) (map[string]any, error) {
	s, err := getTelecomSession(sessionID)
	if err != nil {
		return nil, err
	}
	fields := map[string]any{
		"deviceUid": s.UID, "imsi": "", "key": s.Key, "payType": "",
		"phoneNum": telecomCaesar(s.Phone), "salesProdId": "", "scene": "55",
		"signSignatureString": "", "validationCode": "",
	}
	_, data, err := s.loginV2("getLoginRandomCode", fields, nil)
	if err != nil {
		return nil, err
	}
	s.updateState(data)
	sliderFields := map[string]any{
		"account": telecomCaesar(s.Phone), "clientType": "1",
		"deviceUid": telecomCaesar(s.UID), "scene": "1",
	}
	_, slider, err := s.loginV2("getSliderVerificationPicture", sliderFields, nil)
	if err != nil {
		return nil, err
	}
	bg := fmt.Sprint(slider["backgroundImg"])
	if bg == "" || bg == "<nil>" {
		bg = fmt.Sprint(slider["bigImg"])
	}
	piece := fmt.Sprint(slider["sliderImg"])
	if piece == "" || piece == "<nil>" {
		piece = fmt.Sprint(slider["smallImg"])
	}
	s.SliderKey = fmt.Sprint(slider["key"])
	s.SliderExtra = fmt.Sprint(slider["extra"])
	return map[string]any{
		"background_img":    bg,
		"slider_img":        piece,
		"background_width":  slider["backgroundWidth"],
		"background_height": slider["backgroundHeight"],
		"slider_width":      slider["sliderWidth"],
		"slider_height":     slider["sliderHeight"],
	}, nil
}

func telecomSendSMS(sessionID string, distance float64, track string, startTime, endTime int64) error {
	s, err := getTelecomSession(sessionID)
	if err != nil {
		return err
	}
	if s.SliderExtra == "" {
		return fmt.Errorf("请先获取滑块")
	}
	key, err := base64.StdEncoding.DecodeString(s.SliderExtra)
	if err != nil {
		return fmt.Errorf("滑块密钥无效")
	}
	encDist, err := telecomAES(fmt.Sprintf("%.4f", distance), key)
	if err != nil {
		return err
	}
	encStart, err := telecomAES(fmt.Sprintf("%d", startTime), key)
	if err != nil {
		return err
	}
	encEnd, err := telecomAES(fmt.Sprintf("%d", endTime), key)
	if err != nil {
		return err
	}
	encTrack, err := telecomAES(track, key)
	if err != nil {
		return err
	}
	verifyFields := map[string]any{
		"account": telecomCaesar(s.Phone), "clientType": "1",
		"deviceUid": telecomCaesar(s.UID), "distance": encDist,
		"endTime": encEnd, "startTime": encStart, "key": s.SliderKey,
		"scene": "1", "shopId": "20002", "slidingTrack": encTrack,
	}
	_, verification, err := s.loginV2("verificationSliderPicture", verifyFields, nil)
	if err != nil {
		return err
	}
	sig := fmt.Sprint(verification["signSignatureString"])
	if sig == "" || sig == "<nil>" {
		return fmt.Errorf("滑块验证未通过")
	}
	smsFields := map[string]any{
		"deviceUid": s.UID, "imsi": "", "key": s.Key, "payType": "",
		"phoneNum": telecomCaesar(s.Phone), "salesProdId": "", "scene": "55",
		"signSignatureString": sig, "validationCode": "",
	}
	headers, data, err := s.loginV2("getLoginRandomCode", smsFields, nil)
	if err != nil {
		return err
	}
	s.updateState(data)
	rc := fmt.Sprint(headers["resultCode"])
	desc := fmt.Sprint(headers["resultDesc"])
	if rc != "0" && rc != "0000" && !strings.Contains(desc, "成功") && !strings.Contains(desc, "60s") && !strings.Contains(desc, "重复获取") {
		return fmt.Errorf("短信发送失败: %s %s", rc, desc)
	}
	s.SMSSent = true
	return nil
}

func padRight(s string, n int, pad byte) string {
	if len(s) >= n {
		return s[:n]
	}
	return s + strings.Repeat(string(pad), n-len(s))
}

func telecomSubmitSMS(sessionID, code string) (deviceID string, err error) {
	s, err := getTelecomSession(sessionID)
	if err != nil {
		return "", err
	}
	if !s.SMSSent {
		return "", fmt.Errorf("请先发送短信")
	}
	ts := time.Now().Format("20060102150405")
	modelPrefix := padRight("iPhone 11", 10, ' ')
	plain := modelPrefix + "16.1." + s.UID[:12] + s.Phone[:11] + ts[:14] +
		padRight(code, 6, '$') + padRight("0", 4, '$') + padRight("0.000000", 2, '$')
	enc, err := telecomRSA(plain)
	if err != nil {
		return "", err
	}
	fields := map[string]any{
		"accountType": "", "authentication": base64.StdEncoding.EncodeToString([]byte(telecomCaesar(code))),
		"clientType": "1", "deviceUid": s.UID, "isChinatelecom": orDefault(s.IsCT, "1"),
		"loginAuthCipherAsymmertric": enc, "loginType": "2",
		"phoneNum": telecomCaesar(s.Phone), "signSignatureString": "", "systemVersion": "16.1.1",
	}
	_, data, err := s.loginV2("userLoginNormal", fields, map[string]string{
		"userLoginName": telecomCaesar(s.Phone), "timestamp": ts,
	})
	if err != nil {
		return "", err
	}
	ls, _ := data["loginSuccessResult"].(map[string]any)
	if ls == nil || fmt.Sprint(ls["token"]) == "" || fmt.Sprint(ls["token"]) == "<nil>" {
		return "", fmt.Errorf("短信登录失败")
	}
	s.DeviceID = s.UID
	s.Token = fmt.Sprint(ls["token"])
	s.Province = fmt.Sprint(ls["provinceCode"])
	s.City = fmt.Sprint(ls["cityCode"])
	s.SMSOK = true
	return s.DeviceID, nil
}

func telecomVerifyPassword(sessionID, password string) error {
	s, err := getTelecomSession(sessionID)
	if err != nil {
		return err
	}
	if !s.SMSOK || s.DeviceID == "" {
		return fmt.Errorf("请先完成短信登录")
	}
	ts := time.Now().Format("200601021504") + "00"
	prefix := s.DeviceID
	if len(prefix) > 12 {
		prefix = prefix[:12]
	}
	encStr := fmt.Sprintf("iPhone 14 15.4.0%s%s%s%s0$$$0.", prefix, s.Phone, ts, password)
	enc, err := telecomRSA(encStr)
	if err != nil {
		return err
	}
	fields := map[string]any{
		"accountType": "", "authentication": telecomCaesar(password),
		"deviceUid": "3" + s.Phone, "isChinatelecom": "0",
		"loginAuthCipherAsymmertric": enc, "loginType": "4",
		"phoneNum": telecomCaesar(s.Phone), "systemVersion": "15.4.0",
		"androidId": telecomCaesar(s.DeviceID),
	}
	body := map[string]any{
		"content": map[string]any{"fieldData": fields, "attach": "iPhone"},
		"headerInfos": map[string]any{
			"code": "userLoginNormal", "clientType": "#12.2.0#channel50#iPhone 14 Pro#",
			"timestamp": ts, "shopId": "20002", "source": "110003", "sourcePassword": "Sid98s",
			"userLoginName": telecomCaesar(s.Phone),
		},
	}
	result, err := telecomPost("https://appgologin.189.cn:9031", "/login/client/userLoginNormal", body)
	if err != nil {
		return err
	}
	rd, _ := result["responseData"].(map[string]any)
	if rd == nil || fmt.Sprint(rd["resultCode"]) != "0000" {
		desc := ""
		if rd != nil {
			desc = fmt.Sprint(rd["resultDesc"])
		}
		return fmt.Errorf("服务密码验证失败: %s", desc)
	}
	if data, _ := rd["data"].(map[string]any); data != nil {
		if ls, _ := data["loginSuccessResult"].(map[string]any); ls != nil {
			if t := fmt.Sprint(ls["token"]); t != "" && t != "<nil>" {
				s.Token = t
			}
			if p := fmt.Sprint(ls["provinceCode"]); p != "" && p != "<nil>" {
				s.Province = p
			}
			if c := fmt.Sprint(ls["cityCode"]); c != "" && c != "<nil>" {
				s.City = c
			}
		}
	}
	return nil
}

func orDefault(v, d string) string {
	if v == "" || v == "<nil>" {
		return d
	}
	return v
}

func saveTelecomLoginCache(dir, phone, token, province, city, deviceID string) error {
	if token == "" {
		return nil
	}
	payload := map[string]any{
		"phonenum":     phone,
		"token":        token,
		"provinceCode": province,
		"cityCode":     city,
		"createTime":   time.Now().Format("2006-01-02 15:04:05"),
		"device_id":    deviceID,
		"source":       "balance-auth",
	}
	b, _ := json.MarshalIndent(payload, "", "  ")
	return writeFile0600(dir+"/telecom-login-"+phone+".json", b)
}
