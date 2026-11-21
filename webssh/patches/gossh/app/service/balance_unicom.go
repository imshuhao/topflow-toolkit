package service

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	unicomPubPEM = `-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDc+CZK9bBA9IU+gZUOc6FUGu7y
O9WpTNB0PzmgFBh96Mg1WrovD1oqZ+eIF4LjvxKXGOdI79JRdve9NPhQo07+uqGQ
gE4imwNnRx7PFtCRryiIEcUoavuNtuRVoBAm6qdB0SrctgaqGfLgKvZHOnwTjyNq
jBUxzMeQlEC2czEMSwIDAQAB
-----END PUBLIC KEY-----`
	unicomPlaceholderAppID = "ChinaunicomMobileBusiness"
	unicomSendURL           = "https://m.client.10010.com/mobileService/sendRadomNum.htm"
	unicomLoginURL          = "https://m.client.10010.com/mobileService/radomLogin.htm"
	unicomSendUA            = "Dalvik/2.1.0 (Linux; U; Android 14; 2211133C Build/UKQ1.230804.001);unicom{version:android@11.0900}"
	unicomLoginUA           = "Dalvik/2.1.0 (Linux; U; Android 13; SM-S908U Build/TP1A.220624.014);unicom{version:android@10.0100}"
)

func unicomRSA(content string) (string, error) {
	suffix := make([]byte, 6)
	const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	rb := make([]byte, 6)
	if _, err := rand.Read(rb); err != nil {
		return "", err
	}
	for i := range suffix {
		suffix[i] = alphabet[int(rb[i])%len(alphabet)]
	}
	plain := content + string(suffix)
	block, _ := pem.Decode([]byte(unicomPubPEM))
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

func unicomPost(postURL string, form url.Values, ua string) (map[string]any, error) {
	req, err := http.NewRequest(http.MethodPost, postURL, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", ua)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "*/*")
	client := &http.Client{Timeout: 25 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		return nil, fmt.Errorf("HTTP %d 非 JSON: %s", resp.StatusCode, truncate(string(raw), 200))
	}
	return body, nil
}

func unicomCode(body map[string]any) string {
	for _, k := range []string{"code", "rsp_code", "rspCode", "resultCode", "status"} {
		if v, ok := body[k]; ok && fmt.Sprint(v) != "" && fmt.Sprint(v) != "<nil>" {
			return strings.TrimSpace(fmt.Sprint(v))
		}
	}
	return ""
}

func unicomMsg(body map[string]any) string {
	for _, k := range []string{"dsc", "desc", "rsp_desc", "rspDesc", "msg", "message"} {
		if v, ok := body[k]; ok && fmt.Sprint(v) != "" && fmt.Sprint(v) != "<nil>" {
			return strings.TrimSpace(fmt.Sprint(v))
		}
	}
	return ""
}

func unicomOK(code string) bool {
	return code == "0" || code == "0000" || code == "00000"
}

func unicomSendSMS(phone string) error {
	enc, err := unicomRSA(phone)
	if err != nil {
		return err
	}
	form := url.Values{}
	form.Set("mobile", enc)
	form.Set("version", "android@11.0900")
	form.Set("isFirstInstall", "1")
	form.Set("appId", unicomPlaceholderAppID)
	body, err := unicomPost(unicomSendURL, form, unicomSendUA)
	if err != nil {
		return err
	}
	code := unicomCode(body)
	msg := unicomMsg(body)
	if !unicomOK(code) && !strings.Contains(msg, "验证码已发送") {
		return fmt.Errorf("发码失败 code=%s %s", code, msg)
	}
	return nil
}

func unicomLoginSMS(phone, smsCode string) (token, appID string, err error) {
	encMobile, err := unicomRSA(phone)
	if err != nil {
		return "", "", err
	}
	encCode, err := unicomRSA(smsCode)
	if err != nil {
		return "", "", err
	}
	dev := make([]byte, 16)
	_, _ = rand.Read(dev)
	deviceID := fmt.Sprintf("%x", dev) // 32 hex chars
	androidID := deviceID[8:24]
	form := url.Values{}
	form.Set("deviceOS", "android13")
	form.Set("mobile", encMobile)
	form.Set("password", encCode)
	form.Set("deviceId", deviceID)
	form.Set("keyVersion", "")
	form.Set("deviceBrand", "")
	form.Set("provinceChanel", "general")
	form.Set("androidId", androidID)
	form.Set("deviceModel", "V1936A")
	form.Set("version", "android@10.0100")
	form.Set("timestamp", time.Now().Format("20060102150405"))
	form.Set("isFirstInstall", "1")
	form.Set("appId", unicomPlaceholderAppID)
	body, err := unicomPost(unicomLoginURL, form, unicomLoginUA)
	if err != nil {
		return "", "", err
	}
	code := unicomCode(body)
	msg := unicomMsg(body)
	if !unicomOK(code) {
		return "", "", fmt.Errorf("登录失败 code=%s %s", code, msg)
	}
	token = strings.TrimSpace(fmt.Sprint(body["token_online"]))
	if token == "" || token == "<nil>" {
		return "", "", fmt.Errorf("登录成功但无 token_online")
	}
	appID = strings.TrimSpace(fmt.Sprint(body["appId"]))
	if appID == "" || appID == "<nil>" {
		appID = strings.TrimSpace(fmt.Sprint(body["appid"]))
	}
	if appID == "<nil>" {
		appID = ""
	}
	return token, appID, nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
