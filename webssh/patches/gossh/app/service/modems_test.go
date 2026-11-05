package service

// 三卡接口的离线单测：用 testdata 里的一份脱敏 9460 快照起假服务，
// 不依赖设备、不真跑 ubus，`go test ./app/service/` 可直接跑。
//
// 注入点都是生产代码里已有的接缝：
//   - zwrtDatadBaseURL  → 指向 httptest 假 9460
//   - callUbusRaw       → 退化路径的 ubus 桩
//   - netdevCnt/Rate/Gate → 替代 /proc/net/dev 与 /proc/net/route 的采样结果

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"testing"
	"time"

	"gossh/gin"
)

// fixture：x75 subid=1 / v3e1 subid=3 / v3e2 subid=5，三卡都 online，
// aggregation.paths 全部 enabled；modems[] 的原始顺序是 [x75, v3e1, v3e2]。
const modemFixture = "testdata/state_mu5252.json"

func loadFixture(t *testing.T) []byte {
	t.Helper()
	body, err := os.ReadFile(modemFixture)
	if err != nil {
		t.Fatalf("读取 fixture 失败: %v", err)
	}
	return body
}

// fakeDatad 起一个假的 zwrt-datad，只实现 GET /state。
func fakeDatad(t *testing.T, payload []byte) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/state" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = w.Write(payload)
	}))
	t.Cleanup(srv.Close)

	old := zwrtDatadBaseURL
	zwrtDatadBaseURL = srv.URL
	t.Cleanup(func() { zwrtDatadBaseURL = old })
}

// breakDatad 把 9460 指向一个必然拒绝连接的地址。
func breakDatad(t *testing.T) {
	t.Helper()
	old := zwrtDatadBaseURL
	zwrtDatadBaseURL = "http://127.0.0.1:1"
	t.Cleanup(func() { zwrtDatadBaseURL = old })
}

// resetDatadCache 只清 9460 快照缓存，保留卡身份缓存（用来模拟"刚断线"的场景）。
func resetDatadCache() {
	datadMu.Lock()
	datadCache, datadCached = nil, time.Time{}
	datadMu.Unlock()
}

func resetServiceCaches() {
	datadMu.Lock()
	datadCache, datadCached = nil, time.Time{}
	knownSubid, knownSubidAt = 0, time.Time{}
	datadMu.Unlock()

	modemIDMu.Lock()
	modemIDCache = nil
	modemIDMu.Unlock()
}

// seedNetdev 冻结后台采样器并注入一份 /proc 采样结果（含默认网关）。
func seedNetdev(cnt map[string]ifaceCounters, rates map[string]ifaceRate, gates map[string]string) {
	netdevOnce.Do(func() {}) // 阻止真实采样器启动，保证断言确定
	netdevMu.Lock()
	netdevCnt, netdevRate, netdevGate = cnt, rates, gates
	netdevMu.Unlock()
}

func seedNetdevFromFixture() {
	seedNetdev(
		map[string]ifaceCounters{
			"rmnet_data0": {rxBytes: 3_572_627_142, txBytes: 163_606_151},
			"rmnet_ipa0":  {rxBytes: 818_345_141, txBytes: 172_845_619},
			"V3E1net0":    {rxBytes: 52_801, txBytes: 68_032},
			"V3E2net0":    {rxBytes: 57_726, txBytes: 75_649},
		},
		map[string]ifaceRate{
			"rmnet_data0": {rxSpeed: 2000, txSpeed: 900},
			"rmnet_ipa0":  {rxSpeed: 500, txSpeed: 200},
			"V3E1net0":    {rxSpeed: 71, txSpeed: 70},
			"V3E2net0":    {rxSpeed: 85, txSpeed: 84},
		},
		map[string]string{
			"rmnet_data0": "10.70.159.62",
			"V3E1net0":    "10.80.111.173",
			"V3E2net0":    "10.64.54.78",
		},
	)
}

type modemsResponse struct {
	Code int    `json:"code"`
	Msg  string `json:"msg"`
	Err  string `json:"err"`
	Data struct {
		Cards []ModemCard `json:"cards"`
	} `json:"data"`
}

func getModems(t *testing.T) modemsResponse {
	t.Helper()
	engine := gin.New()
	engine.GET("/api/modems", ModemsAction)
	rec := httptest.NewRecorder()
	engine.ServeHTTP(rec, httptest.NewRequest("GET", "/api/modems", nil))

	var payload modemsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("响应不是 JSON: %v\n%s", err, rec.Body.String())
	}
	return payload
}

func requireCard(t *testing.T, cards []ModemCard, id string) ModemCard {
	t.Helper()
	for _, card := range cards {
		if card.ID == id {
			return card
		}
	}
	t.Fatalf("缺少 %s 卡片", id)
	return ModemCard{}
}

// TestModemsCardsFromSnapshot 三卡解析 + 顺序 + netdev 流量口径。
func TestModemsCardsFromSnapshot(t *testing.T) {
	resetServiceCaches()
	fakeDatad(t, loadFixture(t))
	seedNetdevFromFixture()

	resp := getModems(t)
	if resp.Code != 0 {
		t.Fatalf("期望 code=0，实际 %d (%s)", resp.Code, resp.Msg)
	}
	if len(resp.Data.Cards) != 3 {
		t.Fatalf("期望 3 张卡，实际 %d", len(resp.Data.Cards))
	}
	// 顺序固定：5G 主卡 → 4G 模块1(槽2=V3E2) → 4G 模块2(槽3=V3E1)
	want := []struct {
		id, slot string
		slotNum  int
	}{{"x75", "5G 主卡", 1}, {"v3e2", "4G 模块 1", 2}, {"v3e1", "4G 模块 2", 3}}
	for i, w := range want {
		card := resp.Data.Cards[i]
		if card.ID != w.id || card.Slot != w.slot || card.SlotNum != w.slotNum {
			t.Fatalf("第 %d 张卡应为 %s/%s/槽%d，实际 %s/%s/槽%d",
				i+1, w.id, w.slot, w.slotNum, card.ID, card.Slot, card.SlotNum)
		}
	}

	x75 := requireCard(t, resp.Data.Cards, "x75")
	if x75.SubID != 1 || x75.State != "connected" || !x75.Online || !x75.Present {
		t.Fatalf("x75 基础字段错: %+v", x75)
	}
	if x75.Net.RAT != "5G NR" || x75.Net.BandLabel != "N78" || x75.Net.RSRP == nil || *x75.Net.RSRP != -88 {
		t.Fatalf("x75 信号字段错: %+v", x75.Net)
	}
	// x75 的 nr_rssi 只在顶层 net 里，必须补进来
	if x75.Net.RSSI == nil || *x75.Net.RSSI != -76 {
		t.Fatalf("x75 应合并顶层 nr_rssi=-76，实际 %v", x75.Net.RSSI)
	}
	if x75.IPv4.Address != "10.70.159.61" || x75.IPv4.Gateway != "10.70.159.62" {
		t.Fatalf("x75 IPv4 错: %+v", x75.IPv4)
	}
	// x75 流量 = rmnet_data0 + rmnet_ipa0
	if x75.Traffic.Source != "netdev" ||
		x75.Traffic.RxBytes != 3_572_627_142+818_345_141 ||
		x75.Traffic.RxSpeed != 2500 || x75.Traffic.TxSpeed != 1100 {
		t.Fatalf("x75 流量口径错: %+v", x75.Traffic)
	}

	v3e2 := requireCard(t, resp.Data.Cards, "v3e2")
	if v3e2.SubID != 5 || v3e2.Net.BandLabel != "B5" || v3e2.Net.RAT != "4G LTE" {
		t.Fatalf("v3e2 字段错: %+v / %+v", v3e2, v3e2.Net)
	}
	if v3e2.IPv4.Address != "10.64.54.77" || v3e2.IPv4.Gateway != "10.64.54.78" {
		t.Fatalf("v3e2 IPv4 错: %+v", v3e2.IPv4)
	}
	if v3e2.Traffic.Source != "netdev" || v3e2.Traffic.RxBytes != 57_726 || v3e2.Traffic.RxSpeed != 85 {
		t.Fatalf("v3e2 流量口径错: %+v", v3e2.Traffic)
	}
	// 4G 卡绝不允许借用顶层（x75）的信号值
	if v3e2.Net.RSSI != nil && x75.Net.RSSI != nil && *v3e2.Net.RSSI == *x75.Net.RSSI {
		t.Fatalf("4G 卡疑似借用了 x75 的 RSSI: %v", *v3e2.Net.RSSI)
	}

	v3e1 := requireCard(t, resp.Data.Cards, "v3e1")
	if v3e1.SubID != 3 || v3e1.IPv4.Address != "10.80.111.174" || v3e1.Traffic.RxBytes != 52_801 {
		t.Fatalf("v3e1 字段错: %+v", v3e1)
	}
}

// TestModemsOfflineAndDisabled 4G 掉线 / 被停用的判定。
func TestModemsOfflineAndDisabled(t *testing.T) {
	resetServiceCaches()
	seedNetdevFromFixture()

	var st map[string]interface{}
	if err := json.Unmarshal(loadFixture(t), &st); err != nil {
		t.Fatal(err)
	}
	for _, raw := range st["modems"].([]interface{}) {
		modem := raw.(map[string]interface{})
		switch modem["id"] {
		case "v3e1": // 掉线：断开 + 无制式 + 无信号
			modem["wwan"].(map[string]interface{})["status"] = "disconnected"
			net := modem["net"].(map[string]interface{})
			net["operate_mode"] = "OFFLINE"
			net["type"] = ""
			net["bars"] = float64(0)
		case "v3e2": // 被人为停用
			modem["wwan"].(map[string]interface{})["status"] = "disconnected"
			modem["net"].(map[string]interface{})["operate_mode"] = "OFFLINE"
		}
	}
	for _, raw := range st["aggregation"].(map[string]interface{})["paths"].([]interface{}) {
		path := raw.(map[string]interface{})
		if path["id"] == "v3e2" {
			path["enabled"] = false
			path["status"] = "disabled"
		}
	}
	doctored, _ := json.Marshal(st)
	fakeDatad(t, doctored)

	resp := getModems(t)
	if resp.Code != 0 {
		t.Fatalf("期望 code=0，实际 %d", resp.Code)
	}
	if x75 := requireCard(t, resp.Data.Cards, "x75"); x75.State != "connected" || !x75.Online {
		t.Fatalf("x75 不该受影响: %+v", x75)
	}
	v3e1 := requireCard(t, resp.Data.Cards, "v3e1")
	if v3e1.State != "offline" || v3e1.Online {
		t.Fatalf("v3e1 应判为 offline: state=%s online=%v", v3e1.State, v3e1.Online)
	}
	v3e2 := requireCard(t, resp.Data.Cards, "v3e2")
	if v3e2.State != "disabled" || v3e2.Enabled {
		t.Fatalf("v3e2 应判为 disabled: state=%s enabled=%v", v3e2.State, v3e2.Enabled)
	}
	t.Logf("offline=%s disabled=%s", v3e1.State, v3e2.State)
}

// TestModemsOnlineTriplet online 判定的三路来源各测一遍。
func TestModemsOnlineTriplet(t *testing.T) {
	cases := []struct {
		name string
		net  ModemNet
		wwan string
		op   string
		want bool
	}{
		{"operate_mode 命中", ModemNet{}, "", "ONLINE", true},
		{"wwan 已连接", ModemNet{}, "ipv4_ipv6_connected", "", true},
		{"制式+信号格", ModemNet{Type: "LTE", Bars: 3}, "disconnected", "OFFLINE", true},
		{"三路都没有", ModemNet{}, "disconnected", "OFFLINE", false},
		{"disconnected 不算已连接", ModemNet{}, "disconnected", "", false},
		{"大小写不敏感", ModemNet{}, "", "online", true},
	}
	for _, c := range cases {
		if got := modemOnline(c.net, c.wwan, c.op); got != c.want {
			t.Fatalf("%s: modemOnline=%v 期望 %v", c.name, got, c.want)
		}
	}
}

// TestModemsFieldTolerance 字段大面积缺失时不 panic、不留脏值。
func TestModemsFieldTolerance(t *testing.T) {
	resetServiceCaches()
	seedNetdevFromFixture()

	var st map[string]interface{}
	if err := json.Unmarshal(loadFixture(t), &st); err != nil {
		t.Fatal(err)
	}
	for _, raw := range st["modems"].([]interface{}) {
		modem := raw.(map[string]interface{})
		if modem["id"] != "v3e1" {
			continue
		}
		for _, key := range []string{"net", "interfaces", "traffic", "wwan", "usb"} {
			delete(modem, key)
		}
	}
	doctored, _ := json.Marshal(st)
	fakeDatad(t, doctored)

	resp := getModems(t)
	if resp.Code != 0 {
		t.Fatalf("缺字段不应导致接口失败: code=%d msg=%s err=%s", resp.Code, resp.Msg, resp.Err)
	}
	v3e1 := requireCard(t, resp.Data.Cards, "v3e1")
	if v3e1.Net.RSRP != nil || v3e1.Net.PCI != nil || v3e1.Net.Bandwidth != nil {
		t.Fatalf("缺失字段应为 null，实际 %+v", v3e1.Net)
	}
	if v3e1.Net.BandLabel != "" || v3e1.IPv4.Address != "" || v3e1.Wwan.Status != "" {
		t.Fatalf("缺失字段应为空串: %+v", v3e1)
	}
	if v3e1.State != "offline" || v3e1.Online {
		t.Fatalf("无任何在线证据应判 offline: %s", v3e1.State)
	}
	if v3e1.Traffic.Source != "netdev" || v3e1.Traffic.RxBytes != 52_801 {
		t.Fatalf("流量仍应走 netdev 口径: %+v", v3e1.Traffic)
	}
	if requireCard(t, resp.Data.Cards, "x75").State != "connected" {
		t.Fatal("x75 被缺字段的卡带崩了")
	}
}

// TestModemsAbsentCard 模块不在（未插 / 掉线且 datad 已摘掉该卡）时仍返回卡片占位。
func TestModemsAbsentCard(t *testing.T) {
	resetServiceCaches()
	seedNetdevFromFixture()

	var st map[string]interface{}
	if err := json.Unmarshal(loadFixture(t), &st); err != nil {
		t.Fatal(err)
	}
	kept := make([]interface{}, 0, 2)
	for _, raw := range st["modems"].([]interface{}) {
		if modem := raw.(map[string]interface{}); modem["id"] != "v3e1" {
			kept = append(kept, raw)
		}
	}
	st["modems"] = kept
	doctored, _ := json.Marshal(st)
	fakeDatad(t, doctored)

	resp := getModems(t)
	if resp.Code != 0 || len(resp.Data.Cards) != 3 {
		t.Fatalf("缺卡时仍应返回 3 张占位卡: code=%d cards=%d", resp.Code, len(resp.Data.Cards))
	}
	gone := requireCard(t, resp.Data.Cards, "v3e1")
	if gone.Present || gone.Online || gone.Enabled || gone.State != "absent" || gone.SubID != 0 {
		t.Fatalf("缺卡占位字段错: %+v", gone)
	}
	if gone.Slot != "4G 模块 2" || gone.SlotNum != 3 {
		t.Fatalf("占位卡也要保持槽位标签: %+v", gone)
	}
	if gone.IPv4.DNS == nil {
		t.Fatal("dns 应为空数组而不是 null")
	}
}

// TestModemsDatadDown 9460 挂掉时按缓存身份逐 subid 退化（ubus 用桩，不真跑命令）。
func TestModemsDatadDown(t *testing.T) {
	resetServiceCaches()
	seedNetdevFromFixture()

	// 先正常读一次，缓存硬件身份（id/subid/ifname）
	fakeDatad(t, loadFixture(t))
	if resp := getModems(t); resp.Code != 0 {
		t.Fatalf("预热失败: %+v", resp)
	}

	breakDatad(t)
	resetDatadCache() // 预热时缓存的快照必须失效，否则不会走退化路径

	oldCall := callUbusRaw
	t.Cleanup(func() { callUbusRaw = oldCall })
	seen := map[int]bool{}
	callUbusRaw = func(service, method string, params map[string]interface{}) (map[string]interface{}, error) {
		if service != "zwrt_data" {
			t.Fatalf("退化路径只该调 zwrt_data，实际 %s", service)
		}
		subid := 0
		switch v := params["subid"].(type) {
		case json.Number:
			n, _ := v.Int64()
			subid = int(n)
		case float64:
			subid = int(v)
		}
		seen[subid] = true
		switch method {
		case "get_wwandst":
			return map[string]interface{}{
				"real_rx_speed": float64(1000 + subid),
				"real_tx_speed": float64(200 + subid),
				"real_rx_bytes": float64(10_000 * subid),
				"real_tx_bytes": float64(1_000 * subid),
				"real_time":     float64(600),
			}, nil
		case "get_wwaniface":
			return map[string]interface{}{
				"connect_status":     "ipv4_ipv6_connected",
				"ipv4_address":       "10.9.9." + strconv.Itoa(subid),
				"ipv4_gateway":       "10.9.9.1",
				"ipv4_netmask":       "255.255.255.252",
				"ipv4_dns_prefer":    "202.99.224.70",
				"ipv4_dns_standby":   "",
				"ipv6_address":       "",
				"ipv6_gateway":       "",
				"connect_fail_count": float64(0),
			}, nil
		}
		t.Fatalf("意外的方法 %s", method)
		return nil, nil
	}

	resp := getModems(t)
	if resp.Code != 0 {
		t.Fatalf("9460 不可用时应退化而不是报错: %+v", resp)
	}
	if len(resp.Data.Cards) != 3 {
		t.Fatalf("退化后仍应有 3 张卡，实际 %d", len(resp.Data.Cards))
	}
	if !seen[1] || !seen[3] || !seen[5] {
		t.Fatalf("应以 subid 1/3/5 各调一次 ubus，实际 %v", seen)
	}
	for _, card := range resp.Data.Cards {
		if card.Traffic.Source != "datad" {
			t.Fatalf("%s 退化后流量口径应为 datad: %+v", card.ID, card.Traffic)
		}
		if card.Wwan.Status != "ipv4_ipv6_connected" || card.State != "connected" {
			t.Fatalf("%s 退化后状态错: %+v", card.ID, card)
		}
	}
	if got := requireCard(t, resp.Data.Cards, "v3e2"); got.Traffic.RxSpeed != 1005 || got.IPv4.Address != "10.9.9.5" {
		t.Fatalf("v3e2 退化数据错: %+v", got)
	}
	if got := requireCard(t, resp.Data.Cards, "v3e1"); got.IPv4.Address != "10.9.9.3" {
		t.Fatalf("v3e1 退化数据错: %+v", got.IPv4)
	}
}

// TestModemsDatadDownNoCache 9460 挂掉且从未读到过卡信息 → 明确报错（不猜 subid）。
func TestModemsDatadDownNoCache(t *testing.T) {
	resetServiceCaches()
	breakDatad(t)

	resp := getModems(t)
	if resp.Code != 2 {
		t.Fatalf("无缓存时应返回 code=2，实际 %d", resp.Code)
	}
	if resp.Err == "" {
		t.Fatal("应带上具体错误")
	}
	t.Logf("err=%s", resp.Err)
}

// TestNetdevParsing 用固定样本验证 /proc 解析、网关转换与差分。
func TestNetdevParsing(t *testing.T) {
	dev := "Inter-|   Receive                                                |  Transmit\n" +
		" face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n" +
		"    lo: 93823347   99978    0    0    0     0          0         0 93823347   99978    0    0    0     0       0          0\n" +
		"rmnet_data0: 3569178253 1506730 0 0 0 0 0 0 163471498 1151685 0 0 0 0 0 0\n" +
		"V3E1net0: 49241 774 0 0 0 0 0 0 63674 775 0 0 0 0 0 0\n"
	route := "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n" +
		"rmnet_data0\t00000000\t3E9F460A\t0003\t0\t0\t256\t00000000\t0\t0\t0\n" +
		"V3E1net0\t00000000\tAD6F500A\t0003\t0\t0\t556\t00000000\t0\t0\t0\n" +
		"V3E1net0\t0138A8C0\t00000000\t0005\t0\t0\t156\tFFFFFFFF\t0\t0\t0\n"

	devFile, err := os.CreateTemp("", "netdev-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(devFile.Name())
	_, _ = devFile.WriteString(dev)
	devFile.Close()

	routeFile, err := os.CreateTemp("", "route-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(routeFile.Name())
	_, _ = routeFile.WriteString(route)
	routeFile.Close()

	oldDev, oldRoute := procNetDevPath, procNetRoutePath
	procNetDevPath, procNetRoutePath = devFile.Name(), routeFile.Name()
	defer func() { procNetDevPath, procNetRoutePath = oldDev, oldRoute }()

	cnt, err := readNetdevCounters()
	if err != nil {
		t.Fatal(err)
	}
	if cnt["rmnet_data0"].rxBytes != 3569178253 || cnt["rmnet_data0"].txBytes != 163471498 {
		t.Fatalf("rmnet_data0 解析错: %+v", cnt["rmnet_data0"])
	}
	if cnt["V3E1net0"].rxBytes != 49241 || cnt["V3E1net0"].txBytes != 63674 {
		t.Fatalf("V3E1net0 解析错: %+v", cnt["V3E1net0"])
	}

	gw := readDefaultGateways()
	if gw["rmnet_data0"] != "10.70.159.62" || gw["V3E1net0"] != "10.80.111.173" {
		t.Fatalf("默认网关解析错: %v", gw)
	}
	if perSecond(100, 40, 2) != 30 {
		t.Fatalf("perSecond 错: %d", perSecond(100, 40, 2))
	}
	if perSecond(40, 100, 2) != 0 {
		t.Fatalf("计数器回绕应归零: %d", perSecond(40, 100, 2))
	}
}

// TestModemTrafficSum x75 必须把 rmnet_data0 与 rmnet_ipa0 相加；缺 netdev 时退回 datad。
func TestModemTrafficSum(t *testing.T) {
	seedNetdev(
		map[string]ifaceCounters{
			"rmnet_data0": {rxBytes: 3_572_627_142, txBytes: 163_606_151},
			"rmnet_ipa0":  {rxBytes: 818_345_141, txBytes: 172_845_619},
			"V3E1net0":    {rxBytes: 52_801, txBytes: 68_032},
		},
		map[string]ifaceRate{
			"rmnet_data0": {rxSpeed: 2000, txSpeed: 900},
			"rmnet_ipa0":  {rxSpeed: 500, txSpeed: 200},
			"V3E1net0":    {rxSpeed: 71, txSpeed: 70},
		},
		map[string]string{},
	)

	x75 := modemTraffic(map[string]interface{}{"traffic": map[string]interface{}{}}, []string{"rmnet_data0", "rmnet_ipa0"})
	if x75.Source != "netdev" || x75.RxBytes != 3_572_627_142+818_345_141 ||
		x75.RxSpeed != 2500 || x75.TxSpeed != 1100 {
		t.Fatalf("x75 汇总错: %+v", x75)
	}
	v3e1 := modemTraffic(map[string]interface{}{"traffic": map[string]interface{}{}}, []string{"V3E1net0"})
	if v3e1.RxBytes != 52_801 || v3e1.RxSpeed != 71 {
		t.Fatalf("V3E1 口径错: %+v", v3e1)
	}
	fallback := modemTraffic(map[string]interface{}{
		"traffic": map[string]interface{}{
			"rx_bytes": float64(123), "tx_bytes": float64(456), "rx_speed": float64(7),
		},
	}, []string{"NOPE0"})
	if fallback.Source != "datad" || fallback.RxBytes != 123 || fallback.RxSpeed != 7 {
		t.Fatalf("兜底口径错: %+v", fallback)
	}
}

// TestBandAndRATLabels 展示用的归一化。
func TestBandAndRATLabels(t *testing.T) {
	cases := map[string]string{"n78": "N78", "LTE BAND 5": "B5", "3": "B3", "": ""}
	for in, want := range cases {
		if got := bandLabel(in); got != want {
			t.Fatalf("bandLabel(%q)=%q want %q", in, got, want)
		}
	}
	if ratLabel("SA") != "5G NR" || ratLabel("LTE") != "4G LTE" || ratLabel("") != "" {
		t.Fatal("ratLabel 映射错")
	}
	if modemState(true, false, true, "ipv4_ipv6_connected") != "disabled" ||
		modemState(false, true, false, "") != "absent" ||
		modemState(true, true, false, "disconnected") != "offline" ||
		modemState(true, true, true, "disconnected") != "online" ||
		modemState(true, true, true, "ipv4_ipv6_connected") != "connected" {
		t.Fatal("modemState 判定错")
	}
	if wwanConnected("disconnected") {
		t.Fatal("disconnected 不能被判成已连接")
	}
}
