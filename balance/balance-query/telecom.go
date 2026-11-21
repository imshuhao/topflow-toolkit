package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	mrand "math/rand"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const telecomPubPEM = `-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDBkLT15ThVgz6/NOl6s8GNPofd
WzWbCkWnkaAm7O2LjkM1H7dMvzkiqdxU02jamGRHLX/ZNMCXHnPcW/sDhiFCBN18
qFvy8g6VYb9QtroI09e176s+ZCtiv7hbin2cCTj99iUpnEloZm19lwHyo69u5UMi
PMpq0/XKBO8lYhN/gwIDAQAB
-----END PUBLIC KEY-----`

const telecomClientType = "#12.2.0#channel50#iPhone 14 Pro#"

type telecomLoginCache struct {
	Phonenum     string `json:"phonenum"`
	Token        string `json:"token"`
	ProvinceCode string `json:"provinceCode"`
	CityCode     string `json:"cityCode"`
	CreateTime   string `json:"createTime"`
}

func telecomCaesar(s string, encode bool) string {
	delta := 2
	if !encode {
		delta = -2
	}
	out := make([]rune, 0, len(s))
	for _, r := range s {
		out = append(out, rune(int(r)+delta))
	}
	return string(out)
}

func telecomEncrypt(plain string) (string, error) {
	block, _ := pem.Decode([]byte(telecomPubPEM))
	if block == nil {
		return "", fmt.Errorf("pem decode failed")
	}
	pubAny, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return "", err
	}
	pub, ok := pubAny.(*rsa.PublicKey)
	if !ok {
		return "", fmt.Errorf("not rsa public key")
	}
	cipher, err := rsa.EncryptPKCS1v15(rand.Reader, pub, []byte(plain))
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(cipher), nil
}

func telecomLoginPath(base string, phone string) string {
	return filepath.Join(base, "telecom-login-"+phone+".json")
}

func loadTelecomLogin(base, phone string) *telecomLoginCache {
	b, err := os.ReadFile(telecomLoginPath(base, phone))
	if err != nil {
		return nil
	}
	var c telecomLoginCache
	if json.Unmarshal(b, &c) != nil || c.Token == "" {
		return nil
	}
	return &c
}

func saveTelecomLogin(base string, c *telecomLoginCache) {
	_ = os.MkdirAll(base, 0700)
	b, _ := json.MarshalIndent(c, "", "  ")
	_ = os.WriteFile(telecomLoginPath(base, c.Phonenum), b, 0600)
}

func doTelecomLogin(client *http.Client, acc Account) (*telecomLoginCache, error) {
	phone := digitsOnly(acc.Phone)
	pass := strings.TrimSpace(acc.Password)
	if len(phone) != 11 || pass == "" {
		return nil, fmt.Errorf("telecom needs phone+password")
	}
	// 短信授权得到的 DeviceId：写入 androidId（凯撒编码）；deviceUid 固定为 "3"+手机号。
	// DeviceId 字段口径对齐 margrop/telecom-phone-device-id-tools（MIT）公开的 v1 校验说明；
	// 登录/查询流程对齐 ChinaTelecomOperators/ChinaTelecom（GPL-3.0）的公开协议描述。
	// 本文件为自行重写，非上游脚本拷贝。见 ../../NOTICE.md。
	deviceID := strings.TrimSpace(acc.DeviceUID)
	if deviceID == "" {
		deviceID = strings.TrimSpace(acc.AndroidID)
	}
	mrand.Seed(time.Now().UnixNano())
	ts := time.Now().Format("20060102150405")
	if len(ts) > 12 {
		// 与官方校验工具一致：秒位填 00，降低时钟漂移误判
		ts = ts[:12] + "00"
	}
	var (
		encStr    string
		androidID string
		deviceUID string
		sysVer    string
		attach    string
	)
	if deviceID != "" {
		prefix := deviceID
		if len(prefix) > 12 {
			prefix = prefix[:12]
		}
		encStr = fmt.Sprintf("iPhone 14 15.4.0%s%s%s%s0$$$0.", prefix, phone, ts, pass)
		androidID = telecomCaesar(deviceID, true)
		deviceUID = "3" + phone
		sysVer = "15.4.0"
		attach = "iPhone"
	} else {
		uuid := fmt.Sprintf("%016d", mrand.Int63n(1e16))
		encStr = fmt.Sprintf("iPhone 14 13.2.%s%s%s%s0$$$0.", uuid[:12], phone, ts, pass)
		androidID = strings.TrimSpace(acc.AndroidID)
		deviceUID = ""
		sysVer = "13.2.3"
		attach = "test"
	}
	enc, err := telecomEncrypt(encStr)
	if err != nil {
		return nil, err
	}
	body := map[string]any{
		"content": map[string]any{
			"fieldData": map[string]any{
				"accountType":                "",
				"androidId":                  androidID,
				"authentication":             telecomCaesar(pass, true),
				"deviceUid":                  deviceUID,
				"isChinatelecom":             "0",
				"loginAuthCipher":            "",
				"loginAuthCipherAsymmertric": enc,
				"loginType":                  "4",
				"phoneNum":                   telecomCaesar(phone, true),
				"signSignatureString":        "",
				"systemVersion":              sysVer,
			},
			"attach": attach,
		},
		"headerInfos": map[string]any{
			"broadAccount":     "",
			"broadToken":       "",
			"code":             "userLoginNormal",
			"clientType":       telecomClientType,
			"fixedLineAccount": "",
			"fixedLineToken":   "",
			"provinceCode":     "",
			"timestamp":        ts,
			"shopId":           "20002",
			"source":           "110003",
			"sourcePassword":   "Sid98s",
			"token":            "",
			"userLoginName":    telecomCaesar(phone, true),
		},
	}
	raw, err := postJSON(client, "https://appgologin.189.cn:9031/login/client/userLoginNormal", body)
	if err != nil {
		return nil, err
	}
	var resp map[string]any
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, err
	}
	rd, _ := resp["responseData"].(map[string]any)
	if rd == nil {
		return nil, fmt.Errorf("telecom login: no responseData: %s", truncate(string(raw), 200))
	}
	if fmt.Sprint(rd["resultCode"]) != "0000" {
		desc := strings.TrimSpace(fmt.Sprint(rd["resultDesc"]))
		code := fmt.Sprint(rd["resultCode"])
		if desc == "" || desc == "<nil>" {
			if data, _ := rd["data"].(map[string]any); data != nil {
				if fail, _ := data["loginFailResult"].(map[string]any); fail != nil {
					if v := fmt.Sprint(fail["deviceLockInterceptPrompt"]); v != "" && v != "<nil>" {
						desc = v
					}
				}
			}
		}
		if code == "3006" {
			return nil, fmt.Errorf("telecom login 3006 设备未信任：需要 accounts.json 的 device_uid（短信授权 DeviceId）")
		}
		if code == "3001" {
			return nil, fmt.Errorf("telecom login 3001 手机号或服务密码有误（DeviceId 已生效；请核对营业厅 6 位服务密码）")
		}
		if desc == "" || desc == "<nil>" {
			desc = truncate(string(raw), 180)
		}
		return nil, fmt.Errorf("telecom login failed code=%s %s", code, desc)
	}
	data, _ := rd["data"].(map[string]any)
	ls, _ := data["loginSuccessResult"].(map[string]any)
	if ls == nil {
		return nil, fmt.Errorf("telecom login: no loginSuccessResult")
	}
	c := &telecomLoginCache{
		Phonenum:     phone,
		Token:        fmt.Sprint(ls["token"]),
		ProvinceCode: fmt.Sprint(ls["provinceCode"]),
		CityCode:     fmt.Sprint(ls["cityCode"]),
		CreateTime:   time.Now().Format("2006-01-02 15:04:05"),
	}
	if c.Token == "" || c.Token == "<nil>" {
		return nil, fmt.Errorf("telecom login: empty token")
	}
	return c, nil
}

func telecomQueryImportant(client *http.Client, login *telecomLoginCache) (map[string]any, error) {
	ts := time.Now().Format("20060102150405")
	if len(ts) > 12 {
		ts = ts[:12] + "00"
	}
	body := map[string]any{
		"content": map[string]any{
			"fieldData": map[string]any{
				"provinceCode":   orDefault(login.ProvinceCode, "600101"),
				"cityCode":       orDefault(login.CityCode, "8441900"),
				"shopId":         "20002",
				"isChinatelecom": "0",
				"account":        telecomCaesar(login.Phonenum, true),
			},
			"attach": "test",
		},
		"headerInfos": map[string]any{
			"code":           "qryImportantData",
			"clientType":     telecomClientType,
			"timestamp":      ts,
			"shopId":         "20002",
			"source":         "110003",
			"sourcePassword": "Sid98s",
			"userLoginName":  telecomCaesar(login.Phonenum, true),
			"token":          login.Token,
		},
	}
	raw, err := postJSON(client, "https://appfuwu.189.cn:9021/query/qryImportantData", body)
	if err != nil {
		return nil, err
	}
	var resp map[string]any
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, err
	}
	return resp, nil
}

func queryTelecom(client *http.Client, stateDir string, acc Account) CardStatus {
	card := CardStatus{
		ID:        orDefault(acc.ID, "telecom-"+phoneTail(acc.Phone)),
		Phone:     maskPhone(acc.Phone),
		PhoneTail: phoneTail(acc.Phone),
		Operator:  OperatorTelecom,
		Label:     orDefault(acc.Label, "电信"),
		UpdatedAt: nowLocal().Format(time.RFC3339),
	}
	phone := digitsOnly(acc.Phone)
	login := loadTelecomLogin(stateDir, phone)
	var err error
	if login == nil {
		login, err = doTelecomLogin(client, acc)
		if err != nil {
			card.Error = err.Error()
			return card
		}
		saveTelecomLogin(stateDir, login)
	}
	resp, err := telecomQueryImportant(client, login)
	if err != nil {
		card.Error = err.Error()
		return card
	}
	// token expired → X201, re-login once
	if hi, _ := resp["headerInfos"].(map[string]any); hi != nil && fmt.Sprint(hi["code"]) == "X201" {
		login, err = doTelecomLogin(client, acc)
		if err != nil {
			card.Error = "relogin: " + err.Error()
			return card
		}
		saveTelecomLogin(stateDir, login)
		resp, err = telecomQueryImportant(client, login)
		if err != nil {
			card.Error = err.Error()
			return card
		}
	}
	rd, _ := resp["responseData"].(map[string]any)
	if rd == nil {
		card.Error = "telecom: empty responseData"
		return card
	}
	data, _ := rd["data"].(map[string]any)
	if data == nil {
		card.Error = "telecom: empty data"
		return card
	}
	general, directed := parseTelecomImportant(data, acc.LimitRE, acc.UnlimitRE)
	applyBuckets(&card, general, directed)
	card.OK = true
	return card
}

func parseTelecomImportant(data map[string]any, limitRE, unlimitRE string) (flowBucket, flowBucket) {
	var general, directed flowBucket
	flowInfo, _ := data["flowInfo"].(map[string]any)
	if flowInfo == nil {
		return general, directed
	}
	// 优先按 flowList 逐包分类：电信「专用流量(畅享)」是无限定向，只报已用、无剩余；
	// specialAmount 汇总会把畅享已用塞进有限专用，掩盖无限包。
	if list, ok := flowInfo["flowList"].([]any); ok && len(list) > 0 {
		classified := false
		for _, it := range list {
			item, _ := it.(map[string]any)
			if item == nil {
				continue
			}
			title := fmt.Sprint(item["title"])
			if !strings.Contains(title, "流量") {
				continue
			}
			remain, total, used := telecomFlowItemKB(item)
			unlimited := isTelecomUnlimitedPackage(title, item, remain, total)
			kind := classifyPackageName(title, limitRE, unlimitRE)
			if unlimited {
				if kind != "directed" {
					kind = "directed"
				}
				addUnlimitedBucket(&directed, used)
				classified = true
				continue
			}
			if kind == "directed" {
				addBucket(&directed, remain, total, used)
			} else {
				addBucket(&general, remain, total, used)
			}
			classified = true
		}
		if classified {
			return general, directed
		}
	}
	// 无明细时退回汇总字段
	if common, _ := flowInfo["commonFlow"].(map[string]any); common != nil {
		used := toInt64(common["used"])
		bal := toInt64(common["balance"])
		addBucket(&general, bal, used+bal, used)
	}
	if special, _ := flowInfo["specialAmount"].(map[string]any); special != nil {
		used := toInt64(special["used"])
		bal := toInt64(special["balance"])
		// balance 为空、只有 used → 多为畅享无限汇总，记无限已用
		if strings.TrimSpace(fmt.Sprint(special["balance"])) == "" && bal == 0 && used > 0 {
			addUnlimitedBucket(&directed, used)
		} else {
			addBucket(&directed, bal, used+bal, used)
		}
	}
	return general, directed
}

// 电信无限包：标题含「畅享」(且非「非畅享」)/无限/不限量；或仅有「已用」无「剩余」。
func isTelecomUnlimitedPackage(title string, item map[string]any, remain, total int64) bool {
	if strings.Contains(title, "非畅享") {
		return false
	}
	for _, h := range []string{"畅享", "无限", "不限量", "畅爽", "用不完"} {
		if strings.Contains(title, h) {
			return true
		}
	}
	leftTitle := fmt.Sprint(item["leftTitle"])
	rightTitle := strings.TrimSpace(fmt.Sprint(item["rightTitle"]))
	rightHH := strings.TrimSpace(fmt.Sprint(item["rightTitleHh"]))
	rightEnd := strings.TrimSpace(fmt.Sprint(item["rightTitleEnd"]))
	if strings.Contains(leftTitle, "已用") && rightTitle == "" && rightHH == "" && rightEnd == "" {
		return true
	}
	if total == 0 && remain == 0 {
		if used := parseFlowToKB(fmt.Sprint(item["leftTitleHh"]), ""); used > 0 && strings.Contains(leftTitle, "已用") {
			return rightTitle == "" || strings.Contains(rightTitle, "降速")
		}
	}
	return false
}

func telecomFlowItemKB(item map[string]any) (remain, total, used int64) {
	leftTitle := fmt.Sprint(item["leftTitle"])
	rightTitle := fmt.Sprint(item["rightTitle"])
	leftHH := fmt.Sprint(item["leftTitleHh"])
	rightHH := fmt.Sprint(item["rightTitleHh"])
	rightEnd := fmt.Sprint(item["rightTitleEnd"])
	if strings.Contains(leftTitle, "已用") && strings.Contains(rightTitle, "剩余") {
		used = parseFlowToKB(leftHH, "")
		remain = parseFlowToKB(rightHH, "")
		if strings.Contains(rightEnd, "/") {
			parts := strings.Split(rightEnd, "/")
			if len(parts) == 2 {
				if t := parseFlowToKB(strings.TrimSpace(parts[1]), ""); t > 0 {
					total = t
				}
			}
		}
		if total == 0 {
			total = used + remain
		}
		return
	}
	if strings.Contains(leftTitle, "超出") && strings.Contains(rightEnd, "/") {
		remain = -parseFlowToKB(leftHH, "")
		parts := strings.Split(rightEnd, "/")
		if len(parts) == 2 {
			total = parseFlowToKB(strings.TrimSpace(parts[1]), "")
			used = total - remain
		}
		return
	}
	if strings.Contains(leftTitle, "已用") && strings.Contains(rightTitle, "降速") {
		used = parseFlowToKB(leftHH, "")
		re := regexp.MustCompile(`(\d+(?:\.\d+)?\s*[KMGT]B)`)
		if m := re.FindStringSubmatch(rightTitle); len(m) > 1 {
			total = parseFlowToKB(strings.ReplaceAll(m[1], " ", ""), "")
		}
		remain = total - used
		return
	}
	// 畅享/无限：只有「已用」、无剩余
	if strings.Contains(leftTitle, "已用") {
		used = parseFlowToKB(leftHH, "")
		return 0, 0, used
	}
	return 0, 0, 0
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

func toInt64(v any) int64 {
	switch t := v.(type) {
	case float64:
		return int64(t)
	case json.Number:
		i, _ := t.Int64()
		return i
	case string:
		f, _ := strconv.ParseFloat(t, 64)
		return int64(f)
	case int64:
		return t
	case int:
		return int64(t)
	default:
		f, _ := strconv.ParseFloat(fmt.Sprint(v), 64)
		return int64(f)
	}
}

func orDefault(s, d string) string {
	if strings.TrimSpace(s) == "" {
		return d
	}
	return s
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func postJSON(client *http.Client, url string, body any) ([]byte, error) {
	b, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest(http.MethodPost, url, strings.NewReader(string(b)))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json; charset=UTF-8")
	req.Header.Set("Connection", "Keep-Alive")
	req.Header.Set("user-agent", "P216010901")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, truncate(string(raw), 160))
	}
	return raw, nil
}
