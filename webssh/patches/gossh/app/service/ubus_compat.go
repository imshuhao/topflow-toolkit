package service

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"time"

	"gossh/app/utils"
)

// 本文件是 /api/ubus 的设备兼容层（B20 固件）。
//
// 背景：前端仪表盘 Empty.vue 的 fetchAllData 用 Promise.all 并发打 11 个
// /api/ubus。其中 zwrt_data.get_wwandst 与 zwrt_data.get_wwaniface 在 MU5252
// B20 上不带 subid 会直接返回 "Invalid argument"（实测：三卡机型要求 cid/type/
// subid 齐全），一个调用失败就让整页报「加载失败 / ubus 调用失败」。
//
// 兼容策略（仅对白名单 service.method 生效，其它调用完全走原路径）：
//  1. 先按调用方原始参数调 ubus（在参数本来就正确的机型上行为与旧版本一致）；
//  2. 失败且不是「ubus 缺失/超时」时，用 zwrt-datad(127.0.0.1:9460) 的当前
//     主用 subid 补齐参数重试一次；
//  3. 仍然失败则从 /state 取数，重排成前端 TS 接口期望的字段后返回 code 0。
//
// ubus 命令本身不可用或超时属于环境问题，不参与兼容，原样返回错误。

const (
	// zwrtDatadBaseURL 是设备上 zwrt-datad 的本机监听（-b 127.0.0.1 -p 9460），
	// 状态端是 <base>/state。做成变量只为了离线单测能指向假服务。
	zwrtDatadDefaultBaseURL = "http://127.0.0.1:9460"
	// zwrtDatadTimeout 控制本机取数超时。实测 daemon 重采样时 /state 会到
	// 2.85s，所以给到 3s；正常值 ~2ms。
	zwrtDatadTimeout = 3 * time.Second
	// zwrtDatadCacheTTL 让 1Hz 刷新的仪表盘在同一秒内的多次降级共用一份快照。
	zwrtDatadCacheTTL = time.Second
	// zwrtDatadStaleTTL 是取数失败时允许复用的快照年龄上限。
	zwrtDatadStaleTTL = 5 * time.Second
	// zwrtSubidTTL 是 subid 的复用窗口。subid 只在切卡时变化，窗口内直接复用，
	// 9460 偶发变慢就不再连带打挂仪表盘（实测 1.5s 超时时 60s 内会漏 3 次）。
	zwrtSubidTTL = 30 * time.Second
	// zwrtDatadMaxBody 防止异常响应把内存打满。
	zwrtDatadMaxBody = 4 << 20
)

// zwrtDatadBaseURL 是当前 9460 服务地址；离线单测会把它指向 httptest 服务。
var zwrtDatadBaseURL = zwrtDatadDefaultBaseURL

// zwrtDatadClient 显式禁用代理：9460 在回环上，环境里的 http_proxy 会把
// 本机请求转发到别处。
var zwrtDatadClient = &http.Client{
	Transport: &http.Transport{Proxy: nil},
	Timeout:   zwrtDatadTimeout,
}

// datadSnapshot 是 zwrt-datad /state 的一份已解析快照（数字保留 json.Number，
// 避免字节计数走 float64 丢精度）。
type datadSnapshot struct {
	state map[string]interface{}
}

var (
	datadMu     sync.Mutex
	datadCache  *datadSnapshot
	datadCached time.Time
	// knownSubid 是最近一次从设备读到的 subid。参数兼容重试优先用它，
	// 这样 9460 偶发变慢不会把仪表盘一起打挂。
	knownSubid   int
	knownSubidAt time.Time
)

// datadSnapshotCached 返回 1 秒内可复用的 /state 快照。
// 取数在锁外进行：9460 卡住时不应把并发请求串行化。
// 取数失败但手上有 5s 内的快照时复用它——仪表盘 1Hz 刷新，这种"旧数"无感。
func datadSnapshotCached() (*datadSnapshot, error) {
	datadMu.Lock()
	cached, cachedAt := datadCache, datadCached
	datadMu.Unlock()
	if cached != nil && time.Since(cachedAt) < zwrtDatadCacheTTL {
		return cached, nil
	}

	snap, err := fetchDatadSnapshot()
	if err == nil {
		datadMu.Lock()
		datadCache, datadCached = snap, time.Now()
		knownSubid, knownSubidAt = snap.subid(), time.Now()
		datadMu.Unlock()
		return snap, nil
	}

	datadMu.Lock()
	stale, staleAt := datadCache, datadCached
	datadMu.Unlock()
	if stale != nil && time.Since(staleAt) < zwrtDatadStaleTTL {
		slog.Debug("zwrt-datad 取数失败，复用最近快照", "err_msg", err.Error())
		return stale, nil
	}
	return nil, err
}

// subidForRepair 返回参数兼容重试要用的 subid：
//   - 30s 内读到过就直接用（不碰 9460，一次 ubus 就够）；
//   - 过期或从未读到，读一次 /state 刷新（切卡后能自行跟上）；
//   - 刷新失败就退回最近一次已知值；从未读到则返回 0（不做猜测）。
func subidForRepair() int {
	datadMu.Lock()
	known, at := knownSubid, knownSubidAt
	datadMu.Unlock()
	if known > 0 && time.Since(at) < zwrtSubidTTL {
		return known
	}
	if snap, err := datadSnapshotCached(); err == nil {
		return snap.subid()
	}
	return known
}

func fetchDatadSnapshot() (*datadSnapshot, error) {
	resp, err := zwrtDatadClient.Get(zwrtDatadBaseURL + "/state")
	if err != nil {
		return nil, fmt.Errorf("zwrt-datad 取数失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("zwrt-datad 取数失败: HTTP %d", resp.StatusCode)
	}
	dec := json.NewDecoder(io.LimitReader(resp.Body, zwrtDatadMaxBody))
	dec.UseNumber()
	var state map[string]interface{}
	if err := dec.Decode(&state); err != nil {
		return nil, fmt.Errorf("zwrt-datad 响应解析失败: %w", err)
	}
	if len(state) == 0 {
		return nil, errors.New("zwrt-datad 响应为空")
	}
	return &datadSnapshot{state: state}, nil
}

// mapAt 沿 path 取嵌套对象，任一层缺失或类型不符返回 nil。
func mapAt(m map[string]interface{}, path ...string) map[string]interface{} {
	cur := m
	for _, key := range path {
		if cur == nil {
			return nil
		}
		next, ok := cur[key].(map[string]interface{})
		if !ok {
			return nil
		}
		cur = next
	}
	return cur
}

// block 沿 path 取嵌套对象，任一层缺失或类型不符返回 nil。
func (s *datadSnapshot) block(path ...string) map[string]interface{} {
	if s == nil {
		return nil
	}
	return mapAt(s.state, path...)
}

// subid 取当前主用蜂窝链路的 subid。B20 上 zwrt_data.get_wwandst /
// get_wwaniface 必须带这个值；多卡机型上它不等于卡槽号（本机 x75=1、
// V3E1=3、V3E2=5），所以只能从设备自己的状态里读，不能写死。
func (s *datadSnapshot) subid() int {
	if cell := s.block("interfaces", "cellular"); cell != nil {
		if v := integer(cell, "subid"); v > 0 {
			return v
		}
	}
	if modems, ok := s.state["modems"].([]interface{}); ok {
		for _, raw := range modems {
			modem, ok := raw.(map[string]interface{})
			if !ok {
				continue
			}
			if v := integer(modem, "subid"); v > 0 {
				return v
			}
		}
	}
	return 1
}

// number 原样返回 JSON 数字，缺失或非数字时返回 0。
func number(m map[string]interface{}, key string) json.Number {
	switch v := m[key].(type) {
	case json.Number:
		if _, err := v.Int64(); err == nil {
			return v
		}
		if _, err := v.Float64(); err == nil {
			return v
		}
	case float64:
		return json.Number(strconv.FormatFloat(v, 'f', -1, 64))
	}
	return json.Number("0")
}

func integer(m map[string]interface{}, key string) int {
	n, err := number(m, key).Int64()
	if err != nil {
		return 0
	}
	return int(n)
}

func text(m map[string]interface{}, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}

func boolean(m map[string]interface{}, key string) bool {
	switch v := m[key].(type) {
	case bool:
		return v
	case json.Number:
		n, err := v.Int64()
		return err == nil && n != 0
	case float64:
		return v != 0
	}
	return false
}

// floatAt 取数字字段；9460 把 SINR 这类值既可能给字符串也可能给数字。
func floatAt(m map[string]interface{}, key string) (float64, bool) {
	switch v := m[key].(type) {
	case json.Number:
		f, err := v.Float64()
		return f, err == nil
	case float64:
		return v, true
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
		return f, err == nil
	}
	return 0, false
}

// stringList 取字符串数组；缺失时返回空数组（不是 nil），保证 JSON 里是 [] 而不是 null。
func stringList(m map[string]interface{}, key string) []string {
	raw, ok := m[key].([]interface{})
	if !ok {
		return []string{}
	}
	out := make([]string, 0, len(raw))
	for _, item := range raw {
		if s, ok := item.(string); ok && s != "" {
			out = append(out, s)
		}
	}
	return out
}

// ubusCompatRule 描述一条已知在 B20 上失效的 ubus 调用的兼容策略。
type ubusCompatRule struct {
	// repair 按设备实际接受的参数形状补齐字段（只补不改，已有值优先）。
	// subid 为 0 表示设备当前 subid 未知，此时不补。
	repair func(params map[string]interface{}, subid int) map[string]interface{}
	// rebuild 把 zwrt-datad 快照重排成前端 TS 接口期望的结构。
	rebuild func(snap *datadSnapshot) (map[string]interface{}, error)
}

// ubusCompatRules 是兼容层白名单。键为 "service.method"。
// 未列出的调用一律走 utils.GetDataFromUbus 的原路径，行为不变。
var ubusCompatRules = map[string]ubusCompatRule{
	// 前端 TrafficData：需要 real_*/total_*/day_*/month_* 共 12 个计数字段。
	"zwrt_data.get_wwandst": {
		repair: func(params map[string]interface{}, subid int) map[string]interface{} {
			out := copyParams(params)
			defaultParam(out, "cid", json.Number("1"))
			defaultParam(out, "type", json.Number("4"))
			defaultSubid(out, subid)
			return out
		},
		rebuild: trafficFromDatad,
	},
	// 前端 WwanInfo：需要 connect_status 与 ipv4_*/ipv6_* 地址组。
	"zwrt_data.get_wwaniface": {
		repair: func(params map[string]interface{}, subid int) map[string]interface{} {
			out := copyParams(params)
			defaultParam(out, "cid", json.Number("1"))
			defaultSubid(out, subid)
			return out
		},
		rebuild: wwanFromDatad,
	},
}

// CallUbusCompat 是 /api/ubus 的唯一入口。
func CallUbusCompat(service, method string, params map[string]interface{}) (map[string]interface{}, error) {
	key := service + "." + method
	rule, whitelisted := ubusCompatRules[key]

	result, err := utils.GetDataFromUbus(service, method, params)
	if err == nil {
		return result, nil
	}
	if !whitelisted {
		return nil, err
	}
	if utils.IsUbusUnavailable(err) {
		// ubus 缺失/超时与参数形状无关，保持原有错误语义，不做降级。
		return nil, err
	}

	// ① 参数兼容重试：subid 走 30s 缓存，正常情况下这一步不碰 9460。
	if subid := subidForRepair(); subid > 0 {
		if repaired := rule.repair(params, subid); !reflect.DeepEqual(repaired, params) {
			if retried, retryErr := utils.GetDataFromUbus(service, method, repaired); retryErr == nil {
				slog.Debug("ubus 参数兼容重试成功", "call", key, "params", repaired)
				return retried, nil
			} else if utils.IsUbusUnavailable(retryErr) {
				return nil, err
			}
		}
	}

	// ② 仍然失败才降级到 zwrt-datad 重排。
	snap, snapErr := datadSnapshotCached()
	if snapErr != nil {
		slog.Debug("ubus 兼容层无法读取 zwrt-datad", "call", key, "err_msg", snapErr.Error())
		return nil, err
	}
	rebuilt, rebuildErr := rule.rebuild(snap)
	if rebuildErr != nil {
		slog.Debug("ubus 兼容层无法重排数据", "call", key, "err_msg", rebuildErr.Error())
		return nil, err
	}
	slog.Debug("ubus 调用降级到 zwrt-datad", "call", key, "err_msg", err.Error())
	return rebuilt, nil
}

func copyParams(params map[string]interface{}) map[string]interface{} {
	out := make(map[string]interface{}, len(params)+4)
	for k, v := range params {
		out[k] = v
	}
	return out
}

func defaultParam(m map[string]interface{}, key string, fallback interface{}) {
	if _, ok := m[key]; !ok {
		m[key] = fallback
	}
}

// defaultSubid 在缺少 subid（或给了非正数）时补上设备当前主用 subid。
// subid<=0（设备值未知）时不补，宁可报错也不猜别的卡。
func defaultSubid(m map[string]interface{}, subid int) {
	if subid <= 0 {
		return
	}
	if raw, ok := m["subid"]; ok {
		switch v := raw.(type) {
		case json.Number:
			if n, err := v.Int64(); err == nil && n > 0 {
				return
			}
		case float64:
			if v > 0 {
				return
			}
		case int:
			if v > 0 {
				return
			}
		}
	}
	m["subid"] = json.Number(strconv.Itoa(subid))
}

// trafficFromDatad 把 /state.traffic 重排成前端 TrafficData。
// 字段对应关系（9460 -> 前端）写死在映射表里，不透传原始结构。
func trafficFromDatad(snap *datadSnapshot) (map[string]interface{}, error) {
	traffic := snap.block("traffic")
	if len(traffic) == 0 {
		return nil, errors.New("zwrt-datad 快照缺少 traffic")
	}
	mapping := [...][2]string{
		{"real_tx_speed", "tx_speed"},
		{"real_rx_speed", "rx_speed"},
		{"real_tx_bytes", "tx_bytes"},
		{"real_rx_bytes", "rx_bytes"},
		{"real_max_tx_speed", "max_tx_speed"},
		{"real_max_rx_speed", "max_rx_speed"},
		{"total_tx_bytes", "total_tx_bytes"},
		{"total_rx_bytes", "total_rx_bytes"},
		{"day_tx_bytes", "day_tx_bytes"},
		{"day_rx_bytes", "day_rx_bytes"},
		{"month_tx_bytes", "month_tx_bytes"},
		{"month_rx_bytes", "month_rx_bytes"},
	}
	out := make(map[string]interface{}, len(mapping)+2)
	for _, pair := range mapping {
		out[pair[0]] = number(traffic, pair[1])
	}
	out["cid"] = json.Number("1")
	out["subid"] = json.Number(strconv.Itoa(snap.subid()))
	return out, nil
}

// wwanFromDatad 把 /state.interfaces.cellular 重排成前端 WwanInfo。
func wwanFromDatad(snap *datadSnapshot) (map[string]interface{}, error) {
	cellular := snap.block("interfaces", "cellular")
	if len(cellular) == 0 {
		return nil, errors.New("zwrt-datad 快照缺少 interfaces.cellular")
	}
	stringFields := [...]string{
		"connect_status",
		"ipv4_dev_name", "ipv4_address", "ipv4_gateway", "ipv4_netmask",
		"ipv4_dns_prefer", "ipv4_dns_standby",
		"ipv6_dev_name", "ipv6_address", "ipv6_gateway",
		"ipv6_dns_prefer", "ipv6_dns_standby",
	}
	out := make(map[string]interface{}, len(stringFields)+4)
	for _, key := range stringFields {
		out[key] = text(cellular, key)
	}
	out["connect_fail_count"] = number(cellular, "connect_fail_count")
	out["roam_enable"] = number(cellular, "roam_enable")
	out["cid"] = json.Number("1")
	out["subid"] = json.Number(strconv.Itoa(snap.subid()))
	return out, nil
}
