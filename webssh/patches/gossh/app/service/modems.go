package service

// 三卡状态：5G 主卡(x75) + 两个外挂 4G 模块(V3E1/V3E2)。
//
// 数据源优先级（不要在别处重复这套判断）：
//  1. zwrt-datad `http://127.0.0.1:9460/state` 的 `modems[]` —— 权威，逐卡齐全；
//     顶层 net/traffic/interfaces.cellular 只代表 x75，不能拿去冒充 4G。
//  2. 9460 不可用时，退化为逐 subid 调 `zwrt_data.get_wwandst / get_wwaniface`；
//     subid 只能来自 9460 缓存（硬件身份，读到过就不会变），取不到就不猜。
//
// 流量口径：netdev 差分（与触屏一致），x75 = rmnet_data0 + rmnet_ipa0。
// 9460 的 modems[].traffic 只作兜底，并在响应里用 source 标出，避免两种口径混用。

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"

	"gossh/app/utils"
	"gossh/gin"
)

// modemLayout 固定三张卡的展示顺序与槽位。槽位口径：槽2=4G1=V3E2、槽3=4G2=V3E1
// （与 subid 顺序 1/3/5 不同，别按 subid 排）。
type modemLayout struct {
	id     string
	slot   string
	slotNo int
	netdev []string
}

var modemLayouts = []modemLayout{
	{id: "x75", slot: "5G 主卡", slotNo: 1, netdev: []string{"rmnet_data0", "rmnet_ipa0"}},
	{id: "v3e2", slot: "4G 模块 1", slotNo: 2, netdev: []string{"V3E2net0"}},
	{id: "v3e1", slot: "4G 模块 2", slotNo: 3, netdev: []string{"V3E1net0"}},
}

type ModemNet struct {
	Type      string   `json:"type"`
	RAT       string   `json:"rat"`
	Operator  string   `json:"operator"`
	Band      string   `json:"band"`
	BandLabel string   `json:"band_label"`
	Bandwidth *int     `json:"bandwidth"`
	Channel   *int64   `json:"channel"`
	PCI       *int64   `json:"pci"`
	CellID    *int64   `json:"cell_id"`
	RSRP      *float64 `json:"rsrp"`
	RSRQ      *float64 `json:"rsrq"`
	SINR      *float64 `json:"sinr"`
	RSSI      *float64 `json:"rssi"`
	Bars      int      `json:"bars"`
	Roaming   string   `json:"roaming"`
}

type ModemWwan struct {
	Status string `json:"status"`
}

type ModemIP struct {
	Up      bool     `json:"up"`
	Address string   `json:"address"`
	Netmask string   `json:"netmask"`
	Gateway string   `json:"gateway"`
	DNS     []string `json:"dns"`
}

type ModemTraffic struct {
	RxSpeed     uint64 `json:"rx_speed"`
	TxSpeed     uint64 `json:"tx_speed"`
	RxBytes     uint64 `json:"rx_bytes"`
	TxBytes     uint64 `json:"tx_bytes"`
	SessionTime int64  `json:"session_time"`
	Source      string `json:"source"`
}

type ModemCard struct {
	ID           string       `json:"id"`
	Slot         string       `json:"slot"`
	SlotNum      int          `json:"slot_num"`
	Role         string       `json:"role"`
	IfName       string       `json:"ifname"`
	WanInterface string       `json:"wan_interface"`
	SubID        int          `json:"subid"`
	Present      bool         `json:"present"`
	Enabled      bool         `json:"enabled"`
	Online       bool         `json:"online"`
	State        string       `json:"state"`
	OperateMode  string       `json:"operate_mode"`
	Net          ModemNet     `json:"net"`
	Wwan         ModemWwan    `json:"wwan"`
	IPv4         ModemIP      `json:"ipv4"`
	IPv6         ModemIP      `json:"ipv6"`
	Traffic      ModemTraffic `json:"traffic"`
	Error        string       `json:"error,omitempty"`
}

// callUbusRaw 是 ubus 调用的唯一出口，抽成变量只为离线单测能替换（生产即 utils.GetDataFromUbus）。
var callUbusRaw = utils.GetDataFromUbus

type modemIdentity struct {
	id     string
	role   string
	ifname string
	wan    string
	subid  int
}

var (
	modemIDMu    sync.RWMutex
	modemIDCache []modemIdentity
)

// ModemsAction 返回三卡状态（auth 组，仅需 JWT；不在 PremCheck 白名单里，因此不限管理员）。
func ModemsAction(c *gin.Context) {
	cards, err := collectModemCards()
	if err != nil {
		slog.Error("读取三卡状态失败", "err_msg", err.Error())
		c.JSON(http.StatusOK, gin.H{"code": 2, "msg": "读取三卡状态失败", "err": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"code": 0, "msg": "success", "data": gin.H{"cards": cards}})
}

func collectModemCards() ([]ModemCard, error) {
	startNetdevSampler()

	snap, snapErr := datadSnapshotCached()
	if snapErr == nil {
		if len(snapshotModems(snap)) > 0 {
			identities := identitiesFromSnapshot(snap)
			rememberIdentities(identities)
			return cardsFromSnapshot(snap, identities), nil
		}
		// 快照里没有 modems[]（旧版 datad 或结构变更）：退回 ubus 降级路径，
		// 不要把三张卡都报成"未插入"。
		snapErr = errNoModems
	}

	// 9460 不可用：用缓存里的硬件身份做降级，单卡失败不影响其它卡。
	cached := cachedIdentities()
	if len(cached) == 0 {
		return nil, fmt.Errorf("zwrt-datad 不可用且无缓存的卡信息: %w", snapErr)
	}
	slog.Debug("9460 不可用，三卡状态降级为逐 subid ubus 读取", "err_msg", snapErr.Error())
	return cardsFromUbus(cached), nil
}

func identitiesFromSnapshot(snap *datadSnapshot) []modemIdentity {
	modems := snapshotModems(snap)
	out := make([]modemIdentity, 0, len(modems))
	for _, modem := range modems {
		id := text(modem, "id")
		if id == "" {
			continue
		}
		out = append(out, modemIdentity{
			id:     id,
			role:   text(modem, "role"),
			ifname: text(modem, "ifname"),
			wan:    text(modem, "wan_interface"),
			subid:  integer(modem, "subid"),
		})
	}
	return out
}

func rememberIdentities(list []modemIdentity) {
	if len(list) == 0 {
		return
	}
	modemIDMu.Lock()
	modemIDCache = append(modemIDCache[:0], list...)
	modemIDMu.Unlock()
}

func cachedIdentities() []modemIdentity {
	modemIDMu.RLock()
	defer modemIDMu.RUnlock()
	out := make([]modemIdentity, len(modemIDCache))
	copy(out, modemIDCache)
	return out
}

func snapshotModems(snap *datadSnapshot) []map[string]interface{} {
	if snap == nil {
		return nil
	}
	raw, ok := snap.state["modems"].([]interface{})
	if !ok {
		return nil
	}
	out := make([]map[string]interface{}, 0, len(raw))
	for _, item := range raw {
		if modem, ok := item.(map[string]interface{}); ok {
			out = append(out, modem)
		}
	}
	return out
}

func cardsFromSnapshot(snap *datadSnapshot, identities []modemIdentity) []ModemCard {
	byID := make(map[string]map[string]interface{}, len(identities))
	for _, modem := range snapshotModems(snap) {
		if id := text(modem, "id"); id != "" {
			byID[id] = modem
		}
	}
	paths := aggregationPaths(snap)
	topNet := snap.block("net")
	cellular := snap.block("interfaces", "cellular")

	cards := make([]ModemCard, 0, len(modemLayouts))
	for _, layout := range modemLayouts {
		modem, ok := byID[layout.id]
		if !ok {
			// 卡不在 = 没插或模块掉了；仍然返回卡片，让前端显示"未插入"而不是整块消失
			cards = append(cards, absentModemCard(layout))
			continue
		}
		cards = append(cards, cardFromModem(modem, layout, paths, topNet, cellular))
	}
	return cards
}

func cardFromModem(modem map[string]interface{}, layout modemLayout,
	paths map[string]map[string]interface{}, topNet, cellular map[string]interface{}) ModemCard {

	card := ModemCard{
		ID:           layout.id,
		Slot:         layout.slot,
		SlotNum:      layout.slotNo,
		Role:         text(modem, "role"),
		IfName:       text(modem, "ifname"),
		WanInterface: text(modem, "wan_interface"),
		SubID:        integer(modem, "subid"),
	}
	if card.Role == "" {
		card.Role = roleOf(layout.id)
	}

	// datad 既然列出了这张卡，就说明它在；只有 usb.present 明确为 false
	// （模块被拔掉但状态还没过期）才算未插入。
	card.Present = true
	if usb := mapAt(modem, "usb"); usb != nil {
		if _, tracked := usb["present"]; tracked {
			card.Present = boolean(usb, "present")
		}
	}

	wwan := mapAt(modem, "wwan")
	card.Wwan.Status = text(wwan, "status")
	card.OperateMode = text(mapAt(modem, "net"), "operate_mode")
	card.Net = buildModemNet(layout.id, modem, topNet)

	path, hasPath := paths[layout.id]
	card.Enabled = !hasPath || boolean(path, "enabled")
	card.Online = modemOnline(card.Net, card.Wwan.Status, card.OperateMode)
	card.State = modemState(card.Present, card.Enabled, card.Online, card.Wwan.Status)

	card.IPv4 = modemIPv4(modem, layout.id, cellular)
	card.IPv6 = modemIPv6(modem, layout.id, cellular)
	card.Traffic = modemTraffic(modem, layout.netdev)
	return card
}

func buildModemNet(id string, modem map[string]interface{}, topNet map[string]interface{}) ModemNet {
	netMap := mergeNetFor5G(id, mapAt(modem, "net"), topNet)
	net := ModemNet{
		Type:     text(netMap, "type"),
		Operator: text(netMap, "operator"),
		Band:     text(netMap, "band"),
		Roaming:  text(netMap, "roaming"),
		Bars:     integer(netMap, "bars"),
	}
	net.RAT = ratLabel(net.Type)
	net.BandLabel = bandLabel(net.Band)
	if bw, ok := floatAt(netMap, "bandwidth"); ok && bw > 0 {
		v := int(bw)
		net.Bandwidth = &v
	}
	net.Channel = firstInt(netMap, "nr_channel", "channel")
	net.PCI = firstInt(netMap, "nr_pci", "lte_pci")
	net.CellID = firstInt(netMap, "nr_cell_id", "cell_id", "lte_cell_id")
	net.RSRP = firstdBm(netMap, "nr_rsrp", "lte_rsrp")
	net.RSRQ = firstdB(netMap, "nr_rsrq", "lte_rsrq")
	net.SINR = firstdB(netMap, "nr_snr", "lte_snr")
	net.RSSI = firstdBm(netMap, "nr_rssi", "lte_rssi")
	return net
}

// mergeNetFor5G 只对 x75 合并顶层 net：9460 的每卡 net 里 x75 没有 nr_rssi，
// 而顶层 net 就是 x75 的状态，可以补。4G 卡绝不合并顶层数据。
func mergeNetFor5G(id string, modemNet, topNet map[string]interface{}) map[string]interface{} {
	if id != "x75" || len(topNet) == 0 {
		return modemNet
	}
	merged := make(map[string]interface{}, len(topNet)+len(modemNet))
	for k, v := range topNet {
		merged[k] = v
	}
	for k, v := range modemNet {
		if s, ok := v.(string); ok && s == "" {
			continue // 空串不覆盖顶层有效值
		}
		merged[k] = v
	}
	return merged
}

func modemIPv4(modem map[string]interface{}, id string, cellular map[string]interface{}) ModemIP {
	block := mapAt(modem, "interfaces", "ipv4")
	out := ModemIP{Up: boolean(block, "up"), DNS: stringList(block, "dns")}
	if list, ok := block["ipv4"].([]interface{}); ok && len(list) > 0 {
		if first, ok := list[0].(map[string]interface{}); ok {
			out.Address = text(first, "address")
			if mask, ok := floatAt(first, "mask"); ok {
				out.Netmask = strconv.Itoa(int(mask))
			}
		}
	}
	out.Gateway = netdevGateway(text(modem, "ifname"))
	if out.Gateway == "" && id == "x75" {
		out.Gateway = text(cellular, "ipv4_gateway")
	}
	return out
}

func modemIPv6(modem map[string]interface{}, id string, cellular map[string]interface{}) ModemIP {
	block := mapAt(modem, "interfaces", "ipv6")
	out := ModemIP{Up: boolean(block, "up"), DNS: stringList(block, "dns")}
	if list, ok := block["ipv6"].([]interface{}); ok && len(list) > 0 {
		if first, ok := list[0].(map[string]interface{}); ok {
			out.Address = text(first, "address")
			if mask, ok := floatAt(first, "mask"); ok {
				out.Netmask = strconv.Itoa(int(mask))
			}
		}
	}
	if id == "x75" {
		out.Gateway = text(cellular, "ipv6_gateway")
	}
	return out
}

func modemTraffic(modem map[string]interface{}, netdevs []string) ModemTraffic {
	rxBytes, txBytes, rxSpeed, txSpeed, ok := netdevTraffic(netdevs)
	if ok {
		return ModemTraffic{
			RxSpeed: rxSpeed, TxSpeed: txSpeed,
			RxBytes: rxBytes, TxBytes: txBytes,
			SessionTime: int64(integer(mapAt(modem, "traffic"), "session_time")),
			Source:      "netdev",
		}
	}
	// 兜底：9460 的逐卡计数（x75 那份有 QCMAP ipv6 会计污染，仅作参照）
	traffic := mapAt(modem, "traffic")
	return ModemTraffic{
		RxSpeed:     uint64(integer(traffic, "rx_speed")),
		TxSpeed:     uint64(integer(traffic, "tx_speed")),
		RxBytes:     uint64(integer(traffic, "rx_bytes")),
		TxBytes:     uint64(integer(traffic, "tx_bytes")),
		SessionTime: int64(integer(traffic, "session_time")),
		Source:      "datad",
	}
}

func aggregationPaths(snap *datadSnapshot) map[string]map[string]interface{} {
	out := map[string]map[string]interface{}{}
	agg := snap.block("aggregation")
	raw, ok := agg["paths"].([]interface{})
	if !ok {
		return out
	}
	for _, item := range raw {
		path, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		if id := text(path, "id"); id != "" {
			out[id] = path
		}
	}
	return out
}

func cardsFromUbus(identities []modemIdentity) []ModemCard {
	byID := make(map[string]modemIdentity, len(identities))
	for _, identity := range identities {
		byID[identity.id] = identity
	}
	cards := make([]ModemCard, 0, len(modemLayouts))
	for _, layout := range modemLayouts {
		identity, ok := byID[layout.id]
		if !ok {
			cards = append(cards, absentModemCard(layout))
			continue
		}
		card := cardFromUbus(identity, layout)
		cards = append(cards, card)
	}
	return cards
}

// cardFromUbus 是 9460 不可用时的降级路径：只用逐 subid 的 ubus 数据。
// 拿不到信号/频段（那部分只有 9460 有），对应字段留空，前端显示 '-'。
func cardFromUbus(identity modemIdentity, layout modemLayout) ModemCard {
	card := ModemCard{
		ID:           layout.id,
		Slot:         layout.slot,
		SlotNum:      layout.slotNo,
		Role:         identity.role,
		IfName:       identity.ifname,
		WanInterface: identity.wan,
		SubID:        identity.subid,
		Present:      netdevPresent(identity.ifname),
		Enabled:      true,
	}
	if card.Role == "" {
		card.Role = roleOf(layout.id)
	}

	base := map[string]interface{}{
		"cid":   json.Number("1"),
		"subid": json.Number(strconv.Itoa(identity.subid)),
		"type":  json.Number("4"),
	}
	if data, err := callUbusRaw("zwrt_data", "get_wwandst", base); err == nil {
		card.Traffic = ModemTraffic{
			RxSpeed:     uint64(integer(data, "real_rx_speed")),
			TxSpeed:     uint64(integer(data, "real_tx_speed")),
			RxBytes:     uint64(integer(data, "real_rx_bytes")),
			TxBytes:     uint64(integer(data, "real_tx_bytes")),
			SessionTime: int64(integer(data, "real_time")),
			Source:      "datad",
		}
	} else {
		card.Error = "get_wwandst: " + err.Error()
	}

	ifaceParams := map[string]interface{}{
		"cid":   json.Number("1"),
		"subid": json.Number(strconv.Itoa(identity.subid)),
	}
	if data, err := callUbusRaw("zwrt_data", "get_wwaniface", ifaceParams); err == nil {
		card.Wwan.Status = text(data, "connect_status")
		card.IPv4 = ModemIP{
			Up:      strings.Contains(card.Wwan.Status, "ipv4"),
			Address: text(data, "ipv4_address"),
			Netmask: text(data, "ipv4_netmask"),
			Gateway: text(data, "ipv4_gateway"),
			DNS:     nonEmpty(text(data, "ipv4_dns_prefer"), text(data, "ipv4_dns_standby")),
		}
		card.IPv6 = ModemIP{
			Up:      strings.Contains(card.Wwan.Status, "ipv6"),
			Address: text(data, "ipv6_address"),
			Gateway: text(data, "ipv6_gateway"),
			DNS:     nonEmpty(text(data, "ipv6_dns_prefer"), text(data, "ipv6_dns_standby")),
		}
	} else if card.Error == "" {
		card.Error = "get_wwaniface: " + err.Error()
	}

	card.Online = modemOnline(card.Net, card.Wwan.Status, card.OperateMode)
	card.State = modemState(card.Present, card.Enabled, card.Online, card.Wwan.Status)
	return card
}

func nonEmpty(values ...string) []string {
	out := make([]string, 0, len(values))
	for _, v := range values {
		if v != "" {
			out = append(out, v)
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// modemOnline 沿用触屏口径：operate_mode 含 online、或 wwan.status 已连接、
// 或有制式且信号格 > 0。注意 "disconnected" 里也有 "connect"，必须先排除。
func modemOnline(net ModemNet, wwanStatus, operateMode string) bool {
	if strings.Contains(strings.ToUpper(operateMode), "ONLINE") {
		return true
	}
	if wwanConnected(wwanStatus) {
		return true
	}
	return net.Type != "" && net.Bars > 0
}

func wwanConnected(status string) bool {
	s := strings.ToLower(status)
	return strings.Contains(s, "connect") && !strings.Contains(s, "disconnect")
}

// modemState 给前端一个直接可用的状态：absent/disabled/offline/online/connected。
func modemState(present, enabled, online bool, wwanStatus string) string {
	switch {
	case !present:
		return "absent"
	case !enabled:
		return "disabled"
	case !online:
		return "offline"
	case wwanConnected(wwanStatus):
		return "connected"
	default:
		return "online"
	}
}

// absentModemCard 是"卡不在"时的占位：字段一律零值/空数组，前端按 state=absent 置灰。
func absentModemCard(layout modemLayout) ModemCard {
	return ModemCard{
		ID: layout.id, Slot: layout.slot, SlotNum: layout.slotNo,
		Role: roleOf(layout.id), State: "absent",
		IPv4: ModemIP{DNS: []string{}},
		IPv6: ModemIP{DNS: []string{}},
	}
}

func roleOf(id string) string {
	if id == "x75" {
		return "integrated_5g"
	}
	return "external_4g"
}

func ratLabel(netType string) string {
	switch upper := strings.ToUpper(netType); {
	case strings.Contains(upper, "SA"), strings.Contains(upper, "NR"):
		return "5G NR"
	case strings.Contains(upper, "LTE"), strings.Contains(upper, "4G"):
		return "4G LTE"
	case upper == "":
		return ""
	default:
		return netType
	}
}

// bandLabel 把 "n78" / "LTE BAND 5" / "3" 统一成 "N78" / "B5" / "B3"。
func bandLabel(band string) string {
	trimmed := strings.TrimSpace(band)
	if trimmed == "" {
		return ""
	}
	upper := strings.ToUpper(trimmed)
	if strings.HasPrefix(upper, "N") {
		return upper
	}
	if idx := strings.Index(upper, "BAND"); idx >= 0 {
		return "B" + strings.TrimSpace(upper[idx+len("BAND"):])
	}
	if _, err := strconv.Atoi(upper); err == nil {
		return "B" + upper
	}
	return trimmed
}

func firstInt(m map[string]interface{}, keys ...string) *int64 {
	for _, key := range keys {
		if v, ok := floatAt(m, key); ok && v != 0 {
			n := int64(v)
			return &n
		}
	}
	return nil
}

// firstdBm 取 dBm 类字段；设备在"该制式未激活"时报 0，物理上不可能是 0 dBm，按缺失处理。
func firstdBm(m map[string]interface{}, keys ...string) *float64 {
	for _, key := range keys {
		if v, ok := floatAt(m, key); ok && v != 0 {
			return &v
		}
	}
	return nil
}

// firstdB 取 RSRQ/SINR：0 是可能的合法值（SINR），只有缺失/不可解析才算 null。
func firstdB(m map[string]interface{}, keys ...string) *float64 {
	for _, key := range keys {
		if _, exists := m[key]; !exists {
			continue
		}
		if v, ok := floatAt(m, key); ok {
			return &v
		}
	}
	return nil
}

var errNoModems = errors.New("zwrt-datad 快照缺少 modems")
