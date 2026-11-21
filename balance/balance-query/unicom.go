package main

import (
	crand "crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strings"
	"time"
)

const (
	defaultUnicomAppID = "86b8be06f56ba55e9fa7dff134c6b16c62ca7f319da4a958dd0afa0bf9f36f1daa9922869a8d2313b6f2f9f3b57f2901f0021c4575e4b6949ae18b7f6761d465c12321788dcd980aa1a641789d1188bb"
	unicomOnLineURL    = "https://m.client.10010.com/mobileService/onLine.htm"
	unicomFlowURL      = "https://m.client.10010.com/servicequerybusiness/operationservice/queryOcsPackageFlowLeftContentRevisedInJune"
	unicomVersion      = "android@11.0900"
)

func unicomUA(phone string) string {
	p := digitsOnly(phone)
	if p == "" {
		p = "00000000000"
	}
	return fmt.Sprintf(
		"Mozilla/5.0 (Linux; Android 14; SM-S908U Build/TP1A.220624.014; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36; unicom{version:%s,desmobile:%s};devicetype{deviceBrand:samsung,deviceModel:SM-S908U};{yw_code:}",
		unicomVersion, p,
	)
}

func queryUnicom(client *http.Client, acc Account) CardStatus {
	card := CardStatus{
		ID:        orDefault(acc.ID, "unicom-"+phoneTail(acc.Phone)),
		Phone:     maskPhone(acc.Phone),
		PhoneTail: phoneTail(acc.Phone),
		Operator:  OperatorUnicom,
		Label:     orDefault(acc.Label, "联通"),
		UpdatedAt: nowLocal().Format(time.RFC3339),
	}
	token := strings.TrimSpace(acc.TokenOnline)
	if token == "" {
		card.Error = "missing token_online"
		return card
	}
	appID := strings.TrimSpace(acc.AppID)
	if appID == "" {
		appID = defaultUnicomAppID
	}

	// 必须复用 onLine 下发的整套 Cookie；只塞 ecs_token 会得到 999999。
	jar, err := cookiejar.New(nil)
	if err != nil {
		card.Error = err.Error()
		return card
	}
	sess := &http.Client{
		Timeout:   client.Timeout,
		Transport: client.Transport,
		Jar:       jar,
	}

	mobile, err := unicomOnLine(sess, token, appID, digitsOnly(acc.Phone))
	if err != nil {
		card.Error = err.Error()
		return card
	}
	if mobile != "" && !strings.HasPrefix(mobile, "enc_") {
		card.Phone = maskPhone(mobile)
		card.PhoneTail = phoneTail(mobile)
	}
	raw, err := unicomFlowLeft(sess, digitsOnly(acc.Phone))
	if err != nil {
		card.Error = err.Error()
		return card
	}
	general, directed, err := parseUnicomFlow(raw, acc.LimitRE, acc.UnlimitRE)
	if err != nil {
		card.Error = err.Error()
		return card
	}
	applyBuckets(&card, general, directed)
	card.OK = true
	return card
}

func unicomOnLine(client *http.Client, tokenOnline, appID, phone string) (mobile string, err error) {
	form := url.Values{}
	form.Set("token_online", tokenOnline)
	form.Set("reqtime", time.Now().Format("2006-01-02 15:04:05"))
	form.Set("appId", appID)
	form.Set("version", unicomVersion)
	form.Set("step", "bindlist")
	form.Set("isFirstInstall", "0")
	form.Set("deviceModel", "SM-S908U")
	form.Set("netWay", "Wifi")
	form.Set("deviceId", randomHex(32))
	form.Set("androidId", randomHex(16))
	form.Set("provinceChanel", "general")
	form.Set("flushkey", "1")
	req, err := http.NewRequest(http.MethodPost, unicomOnLineURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", unicomUA(phone))
	req.Header.Set("Accept", "application/json, text/plain, */*")
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if err != nil {
		return "", err
	}
	var data map[string]any
	if err := json.Unmarshal(raw, &data); err != nil {
		return "", fmt.Errorf("onLine parse: %w (%s)", err, truncate(string(raw), 120))
	}
	if fmt.Sprint(data["code"]) != "0" && fmt.Sprint(data["code"]) != "0000" {
		desc := fmt.Sprint(data["dsc"])
		if desc == "" || desc == "<nil>" {
			desc = fmt.Sprint(data["desc"])
		}
		if desc == "" || desc == "<nil>" {
			desc = truncate(string(raw), 160)
		}
		return "", fmt.Errorf("onLine failed: %s", desc)
	}
	ecsToken := fmt.Sprint(data["ecs_token"])
	mobile = fmt.Sprint(data["desmobile"])
	if ecsToken == "" || ecsToken == "<nil>" {
		return "", fmt.Errorf("onLine: empty ecs_token")
	}
	return mobile, nil
}

func unicomFlowLeft(client *http.Client, phone string) ([]byte, error) {
	req, err := http.NewRequest(http.MethodPost, unicomFlowURL, strings.NewReader(""))
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", unicomUA(phone))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json, text/plain, */*")
	req.Header.Set("Origin", "https://img.client.10010.com")
	req.Header.Set("Referer", "https://img.client.10010.com/")
	req.Header.Set("X-Requested-With", "com.sinovatech.unicom.ui")
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
		return nil, fmt.Errorf("flow HTTP %d: %s", resp.StatusCode, truncate(string(raw), 160))
	}
	text := strings.TrimSpace(string(raw))
	if text == "999999" || text == "999998" {
		return nil, fmt.Errorf("flow auth rejected (%s); onLine cookies missing?", text)
	}
	return raw, nil
}

func parseUnicomFlow(raw []byte, limitRE, unlimitRE string) (flowBucket, flowBucket, error) {
	var root any
	if err := json.Unmarshal(raw, &root); err != nil {
		return flowBucket{}, flowBucket{}, fmt.Errorf("flow json: %w", err)
	}
	unlimitIDs := collectUnlimitFeeIDs(root)
	var general, directed flowBucket
	packages := 0
	walkUnicomPackages(root, limitRE, unlimitRE, unlimitIDs, &general, &directed, &packages)
	if packages == 0 {
		if m, ok := root.(map[string]any); ok {
			code := fmt.Sprint(m["code"])
			if code != "" && code != "0000" && code != "0" && code != "<nil>" {
				msg := fmt.Sprint(m["msg"])
				if msg == "" || msg == "<nil>" {
					msg = fmt.Sprint(m["dsc"])
				}
				return flowBucket{}, flowBucket{}, fmt.Errorf("flow code=%s %s", code, msg)
			}
		}
		return flowBucket{}, flowBucket{}, fmt.Errorf("no flow packages in response")
	}
	return general, directed, nil
}

func collectUnlimitFeeIDs(root any) map[string]struct{} {
	out := make(map[string]struct{})
	var walk func(any)
	walk = func(n any) {
		switch v := n.(type) {
		case map[string]any:
			if raw, ok := v["unlimitExclusiveFeeIdSet"]; ok {
				switch arr := raw.(type) {
				case []any:
					for _, item := range arr {
						id := strings.TrimSpace(fmt.Sprint(item))
						if id != "" && id != "<nil>" {
							out[id] = struct{}{}
						}
					}
				}
			}
			for _, child := range v {
				walk(child)
			}
		case []any:
			for _, child := range v {
				walk(child)
			}
		}
	}
	walk(root)
	return out
}

func walkUnicomPackages(node any, limitRE, unlimitRE string, unlimitIDs map[string]struct{}, general, directed *flowBucket, count *int) {
	switch v := node.(type) {
	case map[string]any:
		name := firstString(v, "feePolicyName", "resourceName", "pkgName", "name", "title", "remainTitle")
		remain := firstFlow(v, "remainResource", "remain", "leftFlow", "remainFlow", "flowRemain")
		used := firstFlow(v, "use", "usedResource", "used", "already", "flowUsed", "useFlow")
		total := firstFlow(v, "totalResource", "total", "sumFlow", "flowTotal")
		unit := firstString(v, "unit", "flowUnit", "resourceUnit", "xsbUnit")
		rtype := firstString(v, "resourceType", "realresourcetype", "type", "ELEMENT_TYPE")
		limited := firstString(v, "limited")
		feeID := firstString(v, "feePolicyId", "productId", "pkgId")
		if name != "" && (remain != "" || used != "" || total != "") {
			rkRaw := parseFlowToKB(remain, unit)
			uk := parseFlowToKB(used, unit)
			tk := parseFlowToKB(total, unit)
			unitEmpty := unit == "" || unit == "<nil>"
			looksLikeMB := unitEmpty && !strings.Contains(strings.ToUpper(remain+used+total), "B")
			if looksLikeMB {
				// OCS 无 unit：流量多为 MB；无限包 total=0 也要按 MB 解 use/remain。
				if (tk > 0 && tk < 100000) || (tk == 0 && (uk != 0 || rkRaw != 0)) {
					rkRaw = parseFlowToKB(remain, "MB")
					uk = parseFlowToKB(used, "MB")
					tk = parseFlowToKB(total, "MB")
				}
			}
			if isVoiceOrSMS(name, rtype) {
				// skip
			} else {
				kind := classifyUnicomPackage(name, rtype, limitRE, unlimitRE)
				unlimited := isUnicomUnlimitedPackage(name, limited, feeID, tk, rkRaw, unlimitIDs)
				if unlimited {
					if uk == 0 && rkRaw < 0 {
						uk = -rkRaw
					}
					if kind == "general" {
						// 无限包几乎都是定向；名字偶发误判时仍归定向。
						kind = "directed"
					}
					addUnlimitedBucket(directed, uk)
					*count++
				} else if kind == "directed" {
					addBucket(directed, rkRaw, tk, uk)
					*count++
				} else {
					addBucket(general, rkRaw, tk, uk)
					*count++
				}
			}
		}
		for _, child := range v {
			walkUnicomPackages(child, limitRE, unlimitRE, unlimitIDs, general, directed, count)
		}
	case []any:
		for _, child := range v {
			walkUnicomPackages(child, limitRE, unlimitRE, unlimitIDs, general, directed, count)
		}
	}
}

// 联通无限包特征：feeId ∈ unlimitExclusiveFeeIdSet，或 limited=1，
// 或定向包 total=0 且 remain 为负（已用记在 use / -remain）。
func isUnicomUnlimitedPackage(name, limited, feeID string, totalKB, remainKB int64, unlimitIDs map[string]struct{}) bool {
	if feeID != "" {
		if _, ok := unlimitIDs[feeID]; ok {
			return true
		}
	}
	if limited == "1" {
		return true
	}
	if totalKB == 0 && remainKB < 0 {
		return true
	}
	if totalKB == 0 {
		for _, h := range []string{"无限", "畅爽", "不限量", "用不完"} {
			if strings.Contains(name, h) {
				return true
			}
		}
	}
	return false
}

func classifyUnicomPackage(name, rtype, limitRE, unlimitRE string) string {
	// resourceType: 01 通用流量；13/I3 等定向；02/03 语音短信（上层已跳过）
	switch strings.ToUpper(strings.TrimSpace(rtype)) {
	case "01", "1":
		return "general"
	case "13", "I3", "23", "33":
		return "directed"
	}
	return classifyPackageName(name, limitRE, unlimitRE)
}

func isVoiceOrSMS(name, rtype string) bool {
	n := name + " " + rtype
	for _, h := range []string{"语音", "通话", "短信", "彩信", "分钟", "voice", "sms"} {
		if strings.Contains(strings.ToLower(n), strings.ToLower(h)) {
			return true
		}
	}
	if rtype == "02" || rtype == "03" || rtype == "2" || rtype == "3" {
		if !strings.Contains(name, "流量") && !strings.Contains(strings.ToLower(name), "flow") {
			return true
		}
	}
	return false
}

func firstString(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			s := strings.TrimSpace(fmt.Sprint(v))
			if s != "" && s != "<nil>" {
				return s
			}
		}
	}
	return ""
}

func firstFlow(m map[string]any, keys ...string) string {
	return firstString(m, keys...)
}

func randomHex(n int) string {
	b := make([]byte, (n+1)/2)
	_, _ = crand.Read(b)
	s := hex.EncodeToString(b)
	if len(s) > n {
		return s[:n]
	}
	return s
}
