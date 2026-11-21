# sing-box 整体迁移方案（MU5252 / B20）

> **日期**：2026-10-27  
> **输入配置**：`config.production-adapted.yaml`（Clash Meta / mihomo，1747 行）  
> **目标内核**：reF1nd sing-box 1.14.4 `linux-arm64-musl`（静态，AArch64）  
> **目标路径**：`/data/sing-box/`  
> **前置研究**：[SINGBOX-BARE-CORE-PLAN-2026-10-27.md](SINGBOX-BARE-CORE-PLAN-2026-10-27.md)  
> **本文性质**：整体迁移方案 + 已完成转换的实测记录。  
> **当前运行态（2026-10-27 05:20 UTC）**：已执行 `sing-box.sh switchover` + `install-boot.sh`；sing-box 接管，`sbtun0` UP，DHCP 3/6=`192.168.0.1`，mihomo-netns 已停且 init 已 disable；**reboot 终验通过**（watchdog → core → TUN → DHCP → 面板 → 代理自动恢复）。

---

## 0. 结论先行

1. **Clash 配置已完成到 sing-box 的机械转换**，产物在 `singbox/generated/`，设备上 `sing-box check` 返回 **0**。
2. **转换保真度**：26 个内联代理、50 个策略组、114 条规则、39 个 rule-provider、7 个 proxy-provider 全部有对应物；`select/url-test/fallback/load-balance` 分别映射为 `selector/urltest/urltest/loadbalance`。
3. **订阅改为本地 provider + 定时更新**：不再让 sing-box 在启动时直接拉远程订阅（任一订阅 4xx/5xx 会 **FATAL 启动失败**，实测）。**全部 7 个 provider 都保留在配置中**；`1.中国国际机场`（500）、`7.奶昔机场`（空响应）当前以占位节点 `订阅暂不可用` 存在（选中会失败，属于可见的“待恢复”标记）；`3.桃花源` 最近一次生成已恢复（42 节点）；更新器会持续重试并替换。
4. **lab + 生产均已验证**：lab 的 `google 204 / youtube 200 / taobao 200 / jd 200 / example 200 / gstatic 204`；生产切换后同样通过，且 TUN `sbtun0` UP、DNS/TUN 有流量。
5. **已验证**：客户端 v6 TCP（05:21 日志：`[2408:842c...]` → 免流节点）、fake-ip（DNS 返回 `198.18.0.13` / `fdfe:dcba:9876::2`）、IPv6 字面量代理（200/302）、`kill -9` 自愈、reboot 持久化。mwan3 三口分流已于 2026-10-27 晚补齐（见 §10）；尚余：UDP 非 DNS 业务、`rollback` 演练。

---

## 1. 输入与现状

### 1.1 Clash 配置盘点

| 项 | 数量 | 说明 |
|---|---:|---|
| 内联 `proxies` | 26 | 23×vmess（ws/http）+ direct + reject + dns |
| `proxy-groups` | 50 | select 37 / url-test 9 / load-balance 2 / fallback 2 |
| `rules` | 114 | 65 DOMAIN-SUFFIX / 34 RULE-SET / 9 AND / 2 DST-PORT / 1 KEYWORD / 1 GEOSITE / 1 GEOIP / 1 MATCH |
| `proxy-providers` | 7 | 6 个 sub.example.invalid + 1 个 metaglide CDN |
| `rule-providers` | 39 | 38×mrs + 1×Clash text list |
| DNS | fake-ip | `198.18.0.1/16` + `fdfe:dcba:9876::1/64`，DoH + TLS fallback |
| TUN | `utun` | mixed / auto-route / auto-redirect / mtu 1400 / v6 |
| 控制器 | `0.0.0.0:9999` | secret 空（用户知情） |

### 1.2 现网 mihomo

- 现网 = netns 经典栈，`192.168.0.254:9999`，mixed/redir `7890/7892`。
- 客户端 DHCP 网关/DNS = `192.168.0.254`。
- mwan3 三口 50/25/25；`routing-mark 0x1ed6`；table 100/101 已有占用。
- §20.8 已记录：客户端 v6 TCP 首数据段在 RNDIS/USB 或厂商 IPA 层消失，换内核不一定解决。

---

## 2. 目标架构

### 2.1 数据面

```text
LAN 客户端 (网关/DNS = 192.168.0.1)
        │
        ▼
br-lan ── TUN sbtun0 ── sing-box (host mode)
        │                    ├─ DNS: DoH ali / fake-ip
        │                    ├─ route: rule_set (本地 .json/.srs)
        │                    └─ outbounds: selector/urltest/loadbalance
        ▼
mwan3 (rmnet_data0 / V3E1net0 / V3E2net0)
```

- **host mode**，不新建 netns；沿用 `mihomo-smart` 的宿主直跑思路。
- TUN 名 `sbtun0`，地址 `172.19.0.1/30` + `fdfe:dcba:9877::1/126`；`route_address` 另含 `fdfe:dcba:9876::/64`（fake-ip v6，避免与 TUN 地址同 /126）。
- 入口：`mixed 0.0.0.0:7890`；生产 clash_api `0.0.0.0:9999`；lab 用 `127.0.0.1:7891/9095`。
- **不与 mihomo 同时运行**；切换脚本互斥。

### 2.2 文件布局

| 路径 | 内容 |
|---|---|
| `/data/sing-box/sing-box` | reF1nd 1.14.4 musl 静态内核（sha256 `fc5e3ba4…`） |
| `/data/sing-box/config.json` | 生产配置（`config.device.json`） |
| `/data/sing-box/rules/` | 36 个本地规则集（34 JSON + 2 SRS） |
| `/data/sing-box/providers/` | 4 个本地订阅快照（p2/p4/p5/p7.json） |
| `/data/sing-box/providers.conf` | 订阅更新清单（tag / idx / url / UA） |
| `/data/sing-box/update-providers.sh` | 订阅更新器（原子替换，本地 provider 热重载） |
| `/data/sing-box/ui/` | Zashboard 面板（已实测 200；旧 YACD 备份 `ui-yacd-bak`） |
| `/data/sing-box/state/` | 锁/状态 |
| `/data/sing-box/cache.db` | fake-ip / DNS 缓存 |
| `/tmp/sing-box.log` | 内核日志（1 MB 截断） |
| `/tmp/sing-box-providers.log` | 订阅更新日志（1 MB 截断） |

### 2.3 冻结值（建议）

| 项 | 生产 | lab |
|---|---|---|
| mixed | `7890` | `127.0.0.1:7891` |
| clash_api | `0.0.0.0:9999` | `127.0.0.1:9095` |
| TUN | `sbtun0` / `172.19.0.1/30` / `fdfe:dcba:9877::1/126` | 不启用 |
| fake-ip v4 | `198.18.0.0/16` | 同 |
| fake-ip v6 | `fdfe:dcba:9876::/64` | 同 |
| route mark | **不设置**（先让 mwan3 工作） | 无关 |
| 控制器 secret | 空（沿用用户现状） | 空 |

> 不要复用 mihomo 的 `0x1ed4/0x1ed5/0x1ed6`、table 100/101、pref 32762；任何新 mark 先查双方脚本（§20.8 教训）。

### 2.4 控制面板（Clash / Zashboard）

设备 `/data/sing-box/ui` 已替换为 **Zashboard**（Clash 面板）；旧 YACD 备份在
`/data/sing-box/ui-yacd-bak`。Zashboard 默认同源请求 API，无需手工改地址。

| 入口 | 地址 |
|---|---|
| 生产 Clash API | `http://192.168.0.1:9999/version` |
| 生产 Zashboard | `http://192.168.0.1:9999/ui/` |
| lab Zashboard（adb forward） | `http://127.0.0.1:9095/ui/` |

实测（lab）：`/ui/` 返回 200，显示 **50 个组 / 7 个 provider**，可查看
Proxies / Connections / Logs / Rules / Settings。

> Zashboard 静态文件来自 `Zephyruso/zashboard`（gh-pages）；更换 UI 时直接
> 覆盖 `/data/sing-box/ui`，旧目录已备份为 `ui-yacd-bak`。

---

## 3. 转换方案（已实现）

转换器：`singbox/convert.py`（PyYAML，Python 3.12）。

### 3.1 代理与策略组

| Clash | sing-box | 备注 |
|---|---|---|
| `type: select` | `selector` | `outbounds` + `providers` + `include/exclude` |
| `type: url-test` | `urltest` | `url/interval/tolerance` |
| `type: fallback` | `urltest` | 无 fallback 类型；行为差异见 §3.7 |
| `type: load-balance` | `loadbalance`（fork） | `strategy` 原样（`consistent-hashing`） |
| `filter`（PCRE lookahead） | `include` + `exclude` | 拆成正/负向 RE2 正则 |
| `use: [provider]` | `providers: [tag]` | 订阅节点 tag = `provider/node` |
| `proxies: [..]` | `outbounds: [..]` | direct/reject 移到末尾；仅 direct/reject 的组改用 provider 默认 |
| `DIRECT` | `🌐 本机·本地直连` | 加 `domain_resolver` + `tcp_fast_open`，避免“空 direct”无法作为 detour |
| `REJECT` / `REJECT-DROP` | `action: reject` / `method: drop` | 规则动作 |
| `type: reject` | `block` outbound | 组内仍可选择 |
| `type: dns` | 丢弃 | 由 `hijack-dns` 规则接管 |

**默认值调整**（保证开箱可用，可在面板手改）：

- `🌍 国外总模式` → `⚡ ALL·国外延迟最低`
- `🎯 国内总模式` → `⚡ ALL·国内延迟最低`
- `🚀 专线机场` → `🌐 本机·本地直连`（7.奶昔订阅当前不可用，避免默认落 block）
- `🌍 国外手动选择` 仅保留 provider 成员，默认第一个 provider 节点（不再默认 DIRECT）

### 3.2 路由规则

114 条 Clash 规则 → 115 条 sing-box 规则（含 2 条前置动作）：

1. `action: sniff`（http/tls/quic/stun/dns，300ms）
2. `protocol: dns → hijack-dns`
3. 原规则顺序映射：
   - `AND` → `type: logical, mode: and, rules: [...]`
   - `RULE-SET` → `rule_set`
   - `GEOSITE,cn` → `rule_set: geosite-cn`
   - `GEOIP,CN` → `rule_set: geoip-cn`
   - `DST-PORT,53,🌐 DNS_Hijack` → `port: 53, action: hijack-dns`
   - `MATCH` → `route.final`
   - `no-resolve` 丢弃（sing-box 的 IP 规则天然只匹配 IP）
   - `PROCESS-NAME` 无（本项目也禁止）

### 3.3 规则集（39 → 36）

| 类型 | 处理 |
|---|---|
| `CN_域` / `cn` | SagerNet `geosite-cn.srs`（本地） |
| `CN_IP` | SagerNet `geoip-cn.srs`（本地） |
| GitMetaio `*.mrs` | 改取其 `*_OCD_Domain.txt` / `*_OCD_IP.txt` 源文件，转 sing-box source JSON |
| `No-ads-all_域` | anti-ad `domains.txt`（112,823 条，本地 JSON） |
| `WebRTC_端/域` | `WebRTC.list` → source JSON（domain/domain-suffix/IP） |

- 规则集全部**本地化**，启动不依赖远程 `.srs` 下载。
- 36 个文件：34 个 `.json` + `geosite-cn.srs` + `geoip-cn.srs`，合计约 3.3 MB。
- 原始 GitMetaio `.mrs` 不解析；直接使用其同目录 `.txt` 源，规则内容与 Clash 端一致。

### 3.4 DNS

| Clash | sing-box |
|---|---|
| `nameserver` DoH ali | `ali` = `https://doh.pub`，`bootstrap` = UDP 223.5.5.5 |
| `nameserver-policy geosite:cn` | `dns.rules: rule_set geosite-cn → ali` |
| `fallback tls 8.8.8.8` | `google` = `tls 8.8.8.8`，`detour: 🌍 国外总模式`（当前无规则引用，保留作备用） |
| `fake-ip-range 198.18.0.1/16` | `fakeip.inet4_range: 198.18.0.0/16` |
| `fake-ip-range6 fdfe:...::1/64` | `fakeip.inet6_range: fdfe:dcba:9876::/64` |
| `fake-ip-filter` | 第一条 DNS 规则：命中域名的 A/AAAA → `ali`（真实 IP） |
| `enhanced-mode: fake-ip` | 其余 A/AAAA → `fakeip`，`rewrite_ttl: 1` |
| `ipv6: true` | `strategy: prefer_ipv6` |
| `cache-algorithm: arc` | `cache_capacity: 8192` + `optimistic` |

**行为差异**：Clash 对所有非 fake-ip-filter 域名都发 fake-ip，即使上游是 ali；本方案对 `geosite-cn` 及 fake-ip-filter 返回真实 IP，其余返回 fake-ip。这是 sing-box 常用写法，CN 直连更干净；若严格复刻 Clash，可把 `geosite-cn` 规则移到 fakeip 之后（待 P2 实测再定）。

### 3.5 TUN / 路由

| 项 | 值 |
|---|---|
| TUN | `sbtun0`，`172.19.0.1/30` + `fdfe:dcba:9877::1/126`，`route_address: fdfe:dcba:9876::/64`，mtu 1400，stack mixed |
| auto_route | `true` |
| auto_redirect | `true`（nftables；P2 首测可临时改 false + 手工规则） |
| route_exclude | `192.168.0.0/16`、`10/8`、`172.16/12`、`169.254/16`、`fd00:5252:0:1::/64`、`fe80::/10` |
| auto_detect_interface | **false**（避免绑死 `rmnet_data0`，让 mwan3 分担） |
| default_mark | **不设置**（设了会让 mwan3 跳过；如必须设，先加清 mark 规则） |
| default_domain_resolver | `ali` |

> 原 Clash `route-exclude-address` 含 `fc00::/7`，会覆盖 fake-ip v6 段 `fdfe:.../64`；本方案改为只排除实际 LAN ULA `fd00:5252:0:1::/64`，否则 v6 fake-ip 可能进不了 TUN。

### 3.6 订阅 / provider

**为什么不用 remote provider**：fork 的 `provider/remote` 在启动时任一下载失败会 **FATAL**（实测 1.中国国际机场 500 → 进程退出）。生产不可接受。

**本方案**：

- `providers` 全部 `type: local`，文件 `/data/sing-box/providers/pN.json`。
- 生成时用 `?target=singbox` 拉取；失败则写入占位 server（tag `订阅暂不可用`），provider **不删除**；`update-providers.sh` 恢复后原子替换。
- 设备侧 `update-providers.sh` 按 `providers.conf` 重拉，**原子替换**；本地 provider 文件变更会自动热重载。
- 当前 7 个 provider 全部存在：`2.快跑`、`5.一元机场`（仅信息节点）、`6.果冻`、`8.良心云` 为实时快照；`1.中国国际机场`、`7.奶昔机场` 为占位（pending）；`3.桃花源` 最近一次生成已恢复。
- `5.一元机场` 目前只有“请前往官网重新获取订阅”等信息节点，过滤器会排除；不影响其它 provider。
- 更新失败保留旧文件（实测 2.快跑 一次 DNS 解析失败，旧文件未丢）。

**注意**：`providers.conf` 与 `providers/*.json` 含订阅地址/节点凭据，勿公开仓库。

### 3.7 行为差异清单

| 项 | Clash | sing-box | 影响 |
|---|---|---|---|
| `fallback` | 故障转移 | `urltest`（最低延迟） | 语义接近，非严格 fallback |
| `load-balance` | 连接级策略 | `loadbalance`（round-robin / consistent-hashing / sticky-sessions） | 一致 |
| `filter` | PCRE lookahead | `include`/`exclude` RE2 | 已拆分；实际选点验证通过 |
| `no-resolve` | 显式 | 无（IP 规则天然不解析） | 等价 |
| `sniffer.skip-domain: Mijia Cloud` | 跳过嗅探 | 未映射 | 仅影响嗅探，不影响分流 |
| `fallback-filter` | 污染判定 | 未映射 | 用 fake-ip + geosite-cn 规则替代 |
| `store-selected` | 持久化手选 | 未启用 | 重启后回到默认组 |
| `5.一元机场` | 有订阅 | 仅信息节点 | 组内其它 provider 兜底 |
| `7.奶昔机场` | 空/失败 | 占位 `订阅暂不可用` | `🚀 专线机场` 默认改 DIRECT，避免落占位 |

### 3.8 免流 / IPv4+IPv6 / TCP+UDP / 直连

- **免流**：新增 `🚀 免流模式`（selector，13 个内联免流节点 + `⚡ 免流·自动选择`），默认固定 `国内-8080-联通免流-v2`（实测可通国内/Google/YouTube）；`🎯 国内总模式` 默认指向它。`🌍 国外总模式` 默认仍走 `⚡ ALL·国外延迟最低`（正常国外节点，可靠）；需要“全免流”时在面板把它或 `🐟 漏网之鱼` 切到 `🚀 免流模式`。
- **IPv4/IPv6**：TUN 同时下发 `172.19.0.1/30` 与 `fdfe:dcba:9877::1/126`，并显式路由 `fdfe:dcba:9876::/64` 到 TUN；DNS `strategy: prefer_ipv6`、fakeip 同时有 `inet4_range`/`inet6_range`；路由规则不写 `ip_version`，v4/v6 都按同一套 GEOSITE/GEOIP/RULE-SET 匹配；本地 IP 规则集含 v6 CIDR（如 `private-ip`、Netflix/Telegram 等）。
- **IPv6 字面量兜底**：`ip_version: 6` 规则把未被 CN/域名规则命中的 v6 目标交给 `🌐 nasipv6`；该组默认 `⚡ IPv6·自动选择`（urltest，仅 v6 节点，health URL `https://[2606:4700:4700::1111]/cdn-cgi/trace`）。实测 v6 字面量 200/302。
- **TCP/UDP**：TUN/auto_redirect 同时接管 TCP 与 UDP；原 Clash 的 9 条 `AND(...NETWORK,UDP...)` 规则完整保留，CN UDP 走 `🇨🇳 国内udp`，DouYin/Tencent UDP 443 保持 REJECT，WebRTC 走 `🔌 WebRTC`。
- **直连**：新增 `🟢 直连模式`（selector：`🌐 本机·本地直连` / `⛔️ 禁止·拒绝连接`），已加入 `🎯 国内总模式`、`🌍 国外总模式`、`🐟 漏网之鱼`；选它即该路径直连。面板还支持全局 `Direct` 模式。
- 当前统计：116 条路由规则（含 v6 字面量兜底），其中 9 条 UDP 逻辑规则；34 个本地 JSON 规则集合计 17 条 v6 CIDR；TUN 双栈地址与 DNS `prefer_ipv6` 已启用；fake-ip v4/v6 均实测 204。

---

## 4. 已生成产物

| 文件 | 用途 |
|---|---|
| `singbox/convert.py` | Clash → sing-box 转换器（可重复运行） |
| `singbox/generated/config.device.json` | 生产配置（绝对路径 `/data/sing-box`） |
| `singbox/generated/config.lab.json` | lab 配置（mixed 7891 / api 9095 / 无 TUN） |
| `singbox/generated/config.local.json` | 本机相对路径版本（用于 `sing-box check`） |
| `singbox/generated/rules/` | 36 个本地规则集 |
| `singbox/generated/providers/` | 4 个订阅快照（不提交） |
| `singbox/generated/providers.conf` | 更新清单 |
| `singbox/update-providers.sh` | 设备侧订阅更新器 |
| `singbox/deploy.sh` | 推送配置/规则/provider/更新器并跑 `check` |

**统计**：80 个 outbound（23 代理 + 3 特殊 + 50 组 + 4 合成组）、7 个 provider、116 条路由规则、36 个规则集。

---

## 5. 分阶段迁移

### P0 构建与静态校验（完成）

- [x] musl 静态内核在设备运行（`1.14.4-reF1nd`）。
- [x] `sing-box check -c config.json` → 0。
- [x] 36 个规则集本地加载。
- [x] provider 本地文件加载。
- [x] 设备侧 `sing-box check` 通过。

### P1 lab（完成）

- 配置：`config.lab.json`，仅 `mixed 127.0.0.1:7891` + `clash_api 127.0.0.1:9095`，无 TUN。
- 结果：

| 目标 | 结果 |
|---|---|
| `google.com/generate_204` | 204 |
| `youtube.com` | 200 |
| `taobao.com` | 200 |
| `jd.com` | 200 |
| `example.com` | 200 |
| `gstatic.com/generate_204` | 204 |
| `loadbalance` 组切换后 google/youtube | 204 / 200 |

- 日志无 FATAL/ERROR（除一次 provider 更新 DNS 解析失败，已重试机制覆盖）。

### P2 TUN / 客户端闸门（已完成）

已执行 switchover，`auto_redirect:true` 直接启动成功；实测：

- v4：gstatic/google 204、taobao 200、jd 200；主机 fake-ip `198.18.0.13` → 204。
- v6：客户端 `[2408:...]` → 免流节点 TCP 通；fake-ip v6 `fdfe:dcba:9876::2` → Google 204；v6 字面量代理 200/302。
- DNS：客户端/设备查询 0.1 与 8.8.8.8 均命中 fake-ip / CN 真实 IP；UDP 53 经 TUN。
- DHCP：3/6=`192.168.0.1`，主机租约正常（192.168.0.200）。
- mwan3：仅 5G online（4G 用户关闭），符合预期。
- 回环：OTA 阻断、LAN、9999 面板正常。

### P3 生产切换（已执行）

- `sing-box.sh switchover`（已执行一次，2026-10-27 04:47 UTC）：
  1. 杀 mihomo 看门狗；
  2. `mihomo-smart.sh stop` 或 `mihomo-netns.sh stop`；
  3. 校验无 netns/0.254/utun/9999/table 100/101；
  4. DHCP 3/6 → `192.168.0.1`；
  5. `sing-box check` → start → verify；
  6. 失败自动回滚（停 sing-box、DHCP 0.254、`mihomo-netns.sh start`）。
- rc.local 加 watchdog 块（awk 原子写 + `sh -n`），不碰 OTA 阻断块。
- 看门狗 `singbox-watchdog.sh` 已实现（lock 目录、15s、`SINGBOX_NO_WATCHDOG=1` 防递归、日志截断），待演练。
- 面板先验证 clash_api 与 manager/触屏兼容；不兼容则保留 9999 仅作 API。

### P4 运维固化

- `update-providers.sh` 加入 cron：`0 4 * * * /data/sing-box/update-providers.sh`。
- 规则集更新：重跑 `convert.py` + `deploy.sh`（规则源变化不频繁）。
- 监控：`sing-box.sh status`、`tail /tmp/sing-box.log`、`curl 9999/version`。
- 文档：上线后更新 私人工作笔记（未公开发布） / 私人交接文档（未公开发布），未上线不写“现行”。

---

## 6. 切换 / 回滚操作

### 6.1 生成与部署（PC → 设备）

```sh
# 1) 重新生成（订阅不可用时写占位，恢复后更新器替换）
python singbox/convert.py

# 2) 推送配置/规则/provider/更新器（不启动）
sh singbox/deploy.sh

# 3) 设备侧静态校验
adb shell 'cd /data/sing-box && ./sing-box check -c config.json'
```

### 6.2 lab（不影响现网）

```sh
adb push singbox/generated/config.lab.json /data/sing-box/lab.json
adb shell 'cd /data/sing-box && ./sing-box run -c lab.json > /tmp/sing-box.log 2>&1 & echo $! > lab.pid'
adb shell 'curl -x http://127.0.0.1:7891 -o /dev/null -w "%{http_code}\n" https://www.gstatic.com/generate_204'
adb shell 'kill $(cat /data/sing-box/lab.pid)'
```

### 6.3 生产切换（已执行一次，待补测）

```sh
# 2026-10-27 04:47 UTC 已执行；输出 switchover OK，TUN/v4/CN/foreign 通过。
/data/sing-box/sing-box.sh switchover
# 脚本内含：杀 mihomo 看门狗/内核 → disable mihomo-netns → DHCP 3/6=0.1
# → start-stop-daemon 启动 core → wait_api + sbtun0 + google 204；失败自动 rollback。
```

### 6.4 回滚

```sh
kill $(cat /data/sing-box/watchdog.pid) 2>/dev/null
kill $(cat /data/sing-box/pid) 2>/dev/null
# 恢复 DHCP 0.254
/data/mihomo/mihomo-netns.sh start
/etc/init.d/mihomo-netns enable
```

> 未写 `sing-box.sh` 前，生产切换必须手工执行并在维护窗内完成；不要把上述命令直接跑在现网。

### 6.5 订阅更新

```sh
/data/sing-box/update-providers.sh
tail -20 /tmp/sing-box-providers.log
```

cron（确认 `/etc/crontabs/root` 与 cron 服务存在后再加）：

```cron
0 4 * * * /data/sing-box/update-providers.sh
```

---

## 7. 验收矩阵

| 项 | 通过标准 | 状态 |
|---|---|---|
| 内核 | `1.14.4-reF1nd`，sha256 匹配 | ✅ |
| 配置 | `check` 0 error | ✅ |
| 规则集 | 36 个本地文件加载 | ✅ |
| provider | 4 个本地文件加载，节点可见 | ✅ |
| lab 代理 | gstatic 204 / google 204 | ✅ |
| lab 分流 | youtube 200 / taobao 200 / jd 200 / example 200 | ✅ |
| loadbalance | 切换后 google 204 / youtube 200 | ✅ |
| 面板 | Zashboard `/ui/` 200，50 组 / 7 provider | ✅ lab；生产待上电 |
| 订阅更新 | 原子替换，失败保留旧文件 | ✅ |
| TUN 创建 | `sbtun0` UP，路由/规则无残留 | ✅ 生产 |
| 客户端 v4 | 网页/视频正常 | ✅ 设备侧 |
| **客户端 v6 TCP** | **国内 v6 站点通** | ✅ 05:21 免流节点；05:25 fake-ip v6 `::2` → Google |
| IPv6 字面量 | 代理到 v6 目标 200/302 | ✅ auto 组 |
| fake-ip | 客户端拿到 198.18/fdfe 并可回映射 | ✅ 主机 fake-ip 204 / v6 fake 204 |
| mwan3 | 三口 online，连接分摊 | ✅ 2026-10-27 晚（§10）：并发下载 57/23/24% |
| 自愈 | `kill -9` 内核 ≤30s 拉起 | ✅ 10s 检出 / 约 15s 恢复 |
| 持久化 | reboot 全绿 | ✅ 05:20 终验 |
| 回滚 | ≤2 min 恢复 netns | ⏳ 待演练（脚本就绪） |
| UDP | DNS 走 TUN；QUIC 规则保留 | ✅ DNS；其他 UDP 待测 |

---

## 8. 风险清单

| # | 风险 | 影响 | 处置 |
|---|---|---|---|
| 1 | 客户端 v6 TCP 首数据段消失（§20.8） | v6 站点挂，重演回滚 | P2 单客户端闸门；不通不上生产 |
| 2 | `auto_redirect` 与厂商 iptables-legacy/mwan3 冲突 | 整网中断 | 已以 `auto_redirect:true` 启动成功；v6/自愈/reboot 已过，UDP 非 DNS 待测 |
| 3 | `auto_detect_interface` 绑死 `rmnet_data0` | mwan3 失效，只走 5G | 已设 false；P2 用 conntrack/mwan3 实测 |
| 4 | DHCP 仍指 `0.254` | 切换后客户端全断 | switchover 强制改 3/6，客户端续租 |
| 5 | fake-ip v6 与 LAN ULA 冲突 | v6 直连/代理异常 | 已从 exclude 移除 `fc00::/7`，只排除 `fd00:5252:0:1::/64`；P2 验证 |
| 6 | 订阅 1/7 不可用（3 已恢复） | 对应 provider 暂无真实节点 | 保留 provider + 占位节点；更新器恢复后替换，不缩小 provider 列表 |
| 7 | `5.一元机场` 仅信息节点 | 该 provider 无实际节点 | 组内其它 provider 兜底 |
| 8 | `fallback` 行为差异 | 故障转移不如 Clash | 用 `urltest`；如需严格，后续写自定义脚本/多组 |
| 9 | `filter` 语义差异 | 选点范围略有偏差 | 已用实际节点选点验证；上线前抽查淘宝/国内组 |
| 10 | 控制器免密 | 同网段可改节点 | 沿用现状；如加 secret 先改 manager/触屏 |
| 11 | 规则集本地化占空间 | `/data` 约 3.3 MB | 可接受；后续可换 `.srs` |
| 12 | 订阅/节点凭据泄露 | 安全 | `providers/*.json`、`providers.conf` 不入公开仓库 |
| 13 | 面板 UI 兼容性 | 面板可能不兼容 | Zashboard 已实测 `/ui/` 200；旧 YACD 备份 `ui-yacd-bak` |
| 14 | `store-selected` 未启用 | 重启回默认组 | 如需要，后续加 `cache_file.store_selected`（fork 支持） |
| 15 | 三卡/多卡分工靠「上游连接」粒度 | 单节点 mux/长连接会把流量压在一张卡上 | 已按上游连接做 jhash 选卡（§10）；同一节点多连接会分散，mux 多路复用则只能跟随该连接所在卡 |
| 16 | 出站节点强制 IPv4（`ipv4_only`） | 节点若只有 AAAA 会连不上 | 现有 7 家 provider 均为 A/AAAA 双栈或仅 A（实测 20 连接全部 IPv4 成功）；恢复 v6 拨号 = 把 `strategy` 改回 |

---

## 9. 下一步（按顺序）

1. **待补测**：UDP 非 DNS 业务、rollback 演练；客户端 v6 TCP、mwan3 三口（§10）已通过。
2. `sing-box.sh` + `singbox-watchdog.sh` 已实测（switchover/start/stop/restart/status；`kill -9` 自愈）；后续维护按脚本执行。
3. 记录生产切换/回滚耗时；`rollback` 尚未演练。
4. 面板：Zashboard `/ui/` 已验证；再确认现有 manager/触屏对 9999 的兼容性。
5. 订阅续期：1/7 恢复后重跑 `python singbox/convert.py`，`sh singbox/deploy.sh`。
6. 上线后更新 私人工作笔记（未公开发布） / 私人交接文档（未公开发布），写清“现网 = sing-box”及回滚路径。

---

## 10. 三卡分流（2026-10-27 晚补）

宿主模式 sing-box 的出站属于本机 OUTPUT，mwan3 只能均衡转发流量；且出站 socket
带 `SO_MARK 0x2024`（自身 TUN 旁路），`0x2024 & 0x3f00 = 0x2000` 让 `mwan3_hook`
的 `-m mark --mark 0x0/0x3f00` 规则全部跳过 → 代理流量只能走 main 表默认的
`rmnet_data0`。补齐方式：

- `/data/sing-box/singbox-wan-balance.sh`：nft `table ip tf-sbwan` 在
  `output priority mangle+3`（晚于 sing-box 的 `mangle+1/+2`）按五元组 jhash 置
  `0x0f000000` 选卡位，`ip rule 1990-1992 fwmark 0xX000000/0x0f000000 lookup 12/13/14`
  落到 mwan3 自己的接口表；权重取 `mwan3.balanced`，tracker 非 online 自动出池。
- `route.default_domain_resolver.strategy = ipv4_only`：只有 5G 有 IPv6，节点若走
  AAAA 会把代理流量钉死在 5G。客户端 DNS 仍 `prefer_ipv6`。
- watchdog 15s 幂等刷新；`sing-box.sh start` 立即调用，`stop`/`rollback` 清空。

实测：9 × 3 MB 并发下载 `rmnet_data0`/`V3E1net0`/`V3E2net0` = 15.3/6.4/6.3 MB
（57/23/24%，目标 50/25/25）；故障出池与启停联动用独立表/rule pref 演练通过。
细节见 私人交接文档（未公开发布） §22.5。

## 附录 A：命令速查

```sh
# 生成
python singbox/convert.py

# 部署（不启动）
sh singbox/deploy.sh
sh singbox/deploy.sh --binary /path/to/sing-box   # 同时推内核

# 设备静态校验
adb shell 'cd /data/sing-box && ./sing-box check -c config.json'

# lab
adb push singbox/generated/config.lab.json /data/sing-box/lab.json
adb shell 'cd /data/sing-box && ./sing-box run -c lab.json > /tmp/sing-box.log 2>&1 & echo $! > lab.pid'
adb shell 'curl -x http://127.0.0.1:7891 -o /dev/null -w "%{http_code}\n" https://www.google.com/generate_204'

# 订阅更新
adb shell '/data/sing-box/update-providers.sh; tail -20 /tmp/sing-box-providers.log'
```

## 附录 B：固定哈希

```text
reF1nd 1.14.4 musl tar.gz
  0a0828c76a9c7561825b1873f8029b8b3b8cb414bdc3d68b953c5c8da40962df
sing-box（musl 静态）
  fc5e3ba4a1c6d6bbbcdd738c5f65c26720133ea12d53752c3d87e7d634becd12
```

## 附录 C：本次实测的边界

- lab 只验证 **mixed 入站**，未启用 TUN；TUN/DNS/路由/客户端行为均未验证。
- `auto_redirect` 未启用过；`nft list ruleset` 当前为空，权限可用。
- `mwan3` 未在 sing-box 出站下验证；`auto_detect_interface:false` 是预防性设置。
- 设备当前仍运行 mihomo netns；`/data/sing-box` 只是**已部署未启动**状态。


