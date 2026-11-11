# Telegram 频道 @e58695（𝐄𝟓 𝟖𝟔 𝟗𝟓）sing-box / Clash 内容整理 —— 以及对 B20 随身 WiFi 的借鉴清单

> **抓取时间**：2026-10-30 · **抓取方式**：`t.me/s/e58695` 公开预览页逐页回溯（116 条，id 1–271，时间跨度 2022-01-28 → 2026-09-30）
> **整理目的**：把频道里与 sing-box / Clash / 透明代理有关的技术内容提炼成「我们这台 ZTE TopFlow MU5252 B20（OpenWrt 23.05.4 / sdx75 / kernel 5.15.194 / sing-box 1.14.4-reF1nd）能借鉴的清单」
> **配套文件**：原始转录 `docs/assets/telegram-e58695-transcript-2026-10-30.md`、结构化 `tmp/tg-e58695/messages.jsonl`、抓取脚本 `tmp/tg-e58695/crawl.py`
> 消息时间戳为 UTC，本文按日期引用；`t.me/e58695/<id>` 可直接跳转原帖。

---

## 0. 一页结论（TL;DR）

| # | 结论 | 对你的意义 |
|---|---|---|
| 1 | 频道主推项目（Box4Magisk、sing-box 分支、`sing-ebpf`、配置 gist）都指向 **CHIZI-0618 / reF1nd 这条构建线**；你的设备现在跑的就是这条线的 `1.14.4-reF1nd` | 不用换源、不用换生态，频道内容对你**是同一套技术栈的“上游剧透”** |
| 2 | **现网二进制已经带 `with_ebpf` 编译标签 + 可观测性 API**（§2 有静态取证） | eBPF 入站和 `/observability/v1` **不需要重新编译、不需要等发版**，今天就能探测/试用 |
| 3 | 频道今年最大的两件事就是 **eBPF 入站**（取代 TUN / REDIRECT）和 **observability API**（Prometheus + 近期连接/Top-K） | 正好打在你现在 TUN 栈的几个痛点上（conntrack flush、fake-ip v6、MTU 1400、用户态栈内存） |
| 4 | eBPF 的能力门槛是**内核能力探测**，不是版本号；5.15.194 在“兼容路径”范围内，但 vendor 内核可能裁掉 BPF/TC | 先跑 `sing-box tools ebpf status`（只读、不挂载、不改流量），再谈替换 |
| 5 | 频道历史里藏着两条**针对 ZTE 固件**的经验：`zte_fw_gms` / `fw_INPUT`·`fw_OUTPUT` 链会拦截 GMS | B20 也是 ZTE 固件，值得花 5 分钟查一下有没有同名链 |
| 6 | 作者自用配置里有 6 处结构性写法可以“抄作业” | 见 §5 的 delta 表（低风险的 observability / dashboard / .srs 规则集先上） |

**不建议采纳**：`ipv6disabler` 模块（第 252 条）—— 与本仓库“禁止把 IPv6 改回 false / IPv4-only”的红线冲突。

---

## 1. 频道画像与主线时间线

| 项目 | 内容 |
|---|---|
| 名称 / 链接 | 𝐄𝟓 𝟖𝟔 𝟗𝟓 · <https://t.me/e58695> |
| 规模 | 3.58K 订阅 · 19 张图 · 32 个文件 · 72 条链接 |
| 可抓取消息 | **116 条**（id 1–271，中间大量删除/跳号），2022-01-28 → 2026-09-30 |
| 作者身份线索 | 频道内反复出现 `github.com/CHIZI-0618/box4magisk`、`CHIZI-0618/sing-box`、`CHIZI-0618/AndroidTProxyShell`、`CHIZI-0618/ipv6disabler`；配置 gist 的 `$schema` 指向 `reF1nd/sing-box/reF1nd-testing-next`；我们设备二进制里同时有 `github.com/CHIZI-0618/sing-ebpf` 和 reF1nd 的 schema 字段 —— **频道主 = CHIZI-0618，其分支即 reF1nd 发行线的上游** |

主线时间线（只列技术节点）：

| 时间 | 节点 | 代表消息 |
|---|---|---|
| 2022-02 ~ 04 | Clash 时代：UID 黑名单 + fake-ip-filter 抓 Captive Portal、REDIRECT/TPROXY 透明代理脚本 | [12](https://t.me/e58695/12) [22](https://t.me/e58695/22) [59](https://t.me/e58695/59) [60](https://t.me/e58695/60) |
| 2022-05 ~ 10 | 规则源（Loyalsoldier / Country.mmdb / APNIC CN 段）、Termux 小技巧、B 站 UDP/STUN 打满 CPU 的排查 | [63](https://t.me/e58695/63) [70](https://t.me/e58695/70) [95](https://t.me/e58695/95) |
| 2022-10 ~ 2023 | **Box4Magisk/KernelSU 模块** + sing-box `provider` 下游（qjebbs / yaotthaha / yelnoo）编译与配置示例 | [96](https://t.me/e58695/96) [114](https://t.me/e58695/114) [147](https://t.me/e58695/147) [211](https://t.me/e58695/211) |
| 2024-06 | sing-box 1.10：**nftables 侧按规则集 CIDR 绕过**，“路由器上性能最好也最简单的透明代理” | [195](https://t.me/e58695/195) [196](https://t.me/e58695/196) |
| 2024-2025 | Box4Magisk v4.8→v5.1（热点分享、USB 网络共享、mrs 降内存、fakeip ICMP、防回环） | [193](https://t.me/e58695/193) [199](https://t.me/e58695/199) [201](https://t.me/e58695/201) |
| 2025-02 ~ 2025-12 | Sub-Store 自建教程、Zashboard、**AndroidTProxyShell**（root 安卓 tproxy.sh） | [205](https://t.me/e58695/205) [208](https://t.me/e58695/208) [240](https://t.me/e58695/240) |
| 2026-06 ~ 09 | `1.14.0-alpha.32-reF1nd` 自用配置、**eBPF 入站（两代）**、**observability**、sing-box-dashboard | [249](https://t.me/e58695/249) [253](https://t.me/e58695/253) [256](https://t.me/e58695/256) [258](https://t.me/e58695/258) [260](https://t.me/e58695/260) [270](https://t.me/e58695/270) |

> 最新一条 [271](https://t.me/e58695/271) 是作者对“催更”的态度说明（缓更/慢更/一条主干分支），无技术内容。

---

## 2. 关键核实：你的设备二进制里**已经**有什么（静态取证）

**设备现状**（来自 私人交接文档（未公开发布） §22 / `SINGBOX-BARE-CORE-PLAN-2026-10-27.md`）：
`/data/sing-box/sing-box` = `sing-box version 1.14.4-reF1nd`（aarch64 musl 静态），来自 `reF1nd/sing-box-releases` 的 `v1.14.4-reF1nd`（commit `732618a5989cd2566f072c374fe2f619200f33f9`，构建于 2026-10-26）。

**取证方法**：下载同版本 `sing-box-1.14.4-reF1nd-linux-arm64-musl.tar.gz`（31.7 MB，与设备同一 release / commit `732618a`；设备侧可 `md5sum` 复核），arm64 ELF 无法在 PC 上运行，因此改读 **Go buildinfo + 符号表 + 字符串**（脚本 `tmp/tg-e58695/scan_bin.py`）。

| 证据 | 内容 | 结论 |
|---|---|---|
| buildinfo `-tags` 行 | `...,badlinkname,tfogo_checklinkname0,`**`with_ebpf`**`,with_musl`；`CGO_ENABLED=1 GOOS=linux GOARCH=arm64` | **eBPF 入站已编译进去** |
| 符号 | `sing-box/protocol/ebpf/{inbound,inbound_lifecycle,inbound_policy,inbound_connection,diagnostics}.go` | eBPF 入站代码在（不是空壳） |
| 符号 | `cmd/sing-box/cmd_tools_ebpf.go`、`cmd/sing-box/cmd_api_ebpf.go` | **`sing-box tools ebpf status` 和 `sing-box api ebpf` 两个命令都在** |
| 依赖 | `github.com/CHIZI-0618/sing-ebpf@v0.1.0-alpha.13.0.20261020173703-baddc865aa11` | 用的是频道作者的 eBPF 库（Cilium 重构版） |
| 配置字段串 | `data_plane` / `socket_assign` / `packet_rewrite` / `respect_policy` / `cgroup_path` / `fakeip_icmp` / `tc_priority` / `bypass_rule_set` | 支持**新版** `local{}` / `shared{}` schema（不是 8 月那份旧写法） |
| 可观测性 | `/observability/v1/`、`recent_connections`、`top_k_size` | **observability API 也在**（`experimental.observability`） |
| 面板 | `dashboard`、`download_url`、`external_ui_download` | `services.api.dashboard` 有可能可用（需 `sing-box check` 复核） |

> ⚠️ 坑：`sing-box version` 打印的 `Tags:` 行**不含** `with_ebpf`（那行是 feature tags，不是 build tags）。别据此判断“没有 eBPF”。设备上的判据只有一条：**`sing-box tools ebpf status` 能不能跑起来**。

**所以：频道里 8 月/9 月反复说的“需要带 `with_ebpf` 重新编译”，对你不成立——你手上的 1.14.4-reF1nd 就是那个构建。**

---

## 3. eBPF 入站（本频道最值得借鉴的一项）

### 3.1 它替掉了现在 TUN 栈的哪些部件

| 现在（`sbtun0` + auto_route/auto_redirect） | eBPF 入站 |
|---|---|
| 虚拟网卡 + 用户态 IP 栈（`stack: mixed`），MTU 1400 | local `cgroup`：socket-address hook 改写目标，**不建网卡、不走用户态 IP 栈** |
| nft REDIRECT/TPROXY 整套规则（auto_redirect） | 内核 hook 直接接管，**不维护防火墙规则** |
| 开着 TUN 才有 fake-ip，v6 真实地址要 `route_address ["::/0"]` 才不漏 | 按 scope/地址族独立接管，规则集 CIDR 可在内核直接放行 |
| 停机期间建立的连接要 `singbox-capture-flush.sh` 清 conntrack | **不需要**清系统 conntrack（返回 socket 在专用 netns 内） |
| 代理自身流量靠 `SO_MARK 0x2024` 旁路 | 靠 **socket-cookie map** 自绕过（不再写 SO_MARK） |
| 下游客户端靠“路由进 `sbtun0` + auto_redirect(nft)” | shared `packet_rewrite`：TC ingress/egress 改写以太网帧 |

### 3.2 两代 schema，别照抄旧帖

| | 旧版（[253](https://t.me/e58695/253)，2026-08-01） | 新版（[256](https://t.me/e58695/256) / [270](https://t.me/e58695/270) + 作者 gist + 设备内字段） |
|---|---|---|
| 顶层 | `mode: local/shared/hybrid`，`network`、`udp_timeout`、`dns_mode`、`cgroup_path`、`redirect_address`、`bypass_rule_set`、`include_uid`…、`shared_network{enabled,include_interface}` | 没有 `mode`，改为 **`local{...}` / `shared{...}` 两个对象**，各自 `enabled`、`data_plane`、`dns_mode`、`bypass_*`、筛选器；顶层有 `network`、`udp_timeout`、`tc_priority`、`fakeip_icmp` |
| 数据面 | 未拆 | `local.data_plane = cgroup（默认）\| socket_assign`；`shared.data_plane = packet_rewrite（默认）\| socket_assign` |
| DNS | `hijack / off` | `hijack / respect_policy（默认）/ off` |

> 设备二进制里的字段串与**新版**一致（`data_plane`、`packet_rewrite`、`socket_assign`、`respect_policy` 都在），落地时按新版写。权威文档：`docs/configuration/inbound/ebpf.zh.md` @ commit `732618a`（已存 `tmp/tg-e58695/ebpf-doc-1.14.4.md`）。

### 3.3 内核要求 × B20（kernel `5.15.194-perf`）

| 要求 | 出处 | 你的设备 |
|---|---|---|
| `CONFIG_BPF` / `CONFIG_BPF_SYSCALL` | 全部路径 | 需探测（OpenWrt 23.05 一般有） |
| `CONFIG_CGROUP_BPF` + **cgroup v2 挂载且可写** | local `cgroup`（默认路径） | 需探测；OpenWrt procd 通常挂 `/sys/fs/cgroup` |
| `CONFIG_NET_CLS_BPF`、`NET_SCH_INGRESS`、`NET_CLS_ACT` | shared `packet_rewrite` / 所有 TC 路径 | 需探测（对应 kmod `kmod-sched-core`/`cls_bpf`） |
| `CONFIG_BPF_JIT`（强烈建议） | 报文路径性能 | 需探测 |
| `CONFIG_NET_NS` + `CONFIG_VETH` + `bpf_sk_assign`(5.7+) | `socket_assign` 两条路径 | 5.15 版本够；但 netns/veth 能力需实测 |
| LPM trie 缺陷（Linux 6.6.0–6.6.46 会 panic） | 仅影响 6.6 段 | **5.15 不受影响** ✅ |
| 运行时依赖 | 不需要 `bpftool` / `tc` / `ip` / libbpf / clang | 纯 Go + BPF syscall + netlink ✅ |

> 文档明确：**“是否支持由实际 map、程序加载、helper 与挂载结果决定，不使用最低 Linux 版本号判断”**。所以我们只看探测结果。

### 3.4 P0：探测命令（只读、不挂载、不改流量）

在设备上（`adb shell` 或 WebSSH `http://192.168.0.1:8899/app`）：

```sh
cd /data/sing-box

# 0) 先采集环境（排障要用的最小材料）
uname -a; cat /proc/version
mount | grep -E 'cgroup|bpf'
ls -l /sys/fs/bpf 2>/dev/null; ls /sys/fs/cgroup | head
tc qdisc show; ip -details link show | head -40
cat /etc/openwrt_release 2>/dev/null; ubus call system board 2>/dev/null

# 1) local cgroup 路径（本机流量，最想要的）
./sing-box tools ebpf status --mode local --json

# 2) shared packet_rewrite 路径（LAN 客户端流量；br-lan 是以太网帧，符合要求）
./sing-box tools ebpf status --shared-data-plane packet_rewrite --interface br-lan --json

# 3) 想同时试 socket_assign（需 netns/veth，门槛更高）
./sing-box tools ebpf status --local-data-plane socket_assign --network tcp,udp --json

# 4) 两条一起
./sing-box tools ebpf status --local-data-plane cgroup --shared-data-plane packet_rewrite --interface br-lan --json
```

判读：
- **退出码非 0 = 有必需项 `FAIL`/`UNKNOWN`**，先别动现网配置；
- 探测通过 ≠ 真实启动能挂上（权限、qdisc 冲突、sysctl、LSM 只在真实启动时验证）——文档原话，照做。

### 3.5 建议的落地形态（分三步，不一次到位）

```
客户端 ──► br-lan ──TC ingress(packet_rewrite)──┐
                                              ├─► sing-box 路由 ──► 出站 ──► mwan3 三卡
本机进程 ──► cgroup socket-addr(cgroup)───────┘
                     （旧的 sbtun0 / nft redirect / conntrack flush 全部退场）
```

**步骤 1（今天，零风险）**：只加可观测性（§4），不动流量路径。
**步骤 2（窗口期，可回滚）**：`local` only —— 把 config 复制一份，`inbounds` 里把 `tun` 换成：

```json
{
  "type": "ebpf",
  "tag": "ebpf-in",
  "network": ["tcp", "udp"],
  "local": {
    "enabled": true,
    "data_plane": "cgroup",
    "dns_mode": "respect_policy",
    "bypass_private_address": true
  }
}
```

`mixed-in 7890` 保留给 PC 侧显式代理。这一步只接管**设备自身**的流量，LAN 客户端仍走旧的 nft redirect → 可以先验证“本机代理是否正常、三卡分流是否还准”。

**步骤 3（可选，确认步骤 2 稳定后）**：加 `shared` 接管 LAN 客户端：

```json
"shared": {
  "enabled": true,
  "data_plane": "packet_rewrite",
  "interface": ["br-lan"],
  "dns_mode": "hijack",
  "bypass_private_address": true,
  "bypass_port": [22, 80, 443, 7890, 8899, 9999, 22622]
}
```

要点：
- `local` 接管本机进程，`bypass_private_address` 已覆盖 LAN/私网目标，无需逐个写管理端口；
- `shared` 接管 LAN 客户端，**必须把管理端口放进 `shared.bypass_port`**（WebUI 80、Zashboard 9999、WebSSH 8899、sshd 22622），否则 TC ingress 会把发往 `192.168.0.1` 的管理流量也改写掉；
- 端口 53 由 `dns_mode: hijack` 优先接管（**优先级高于 `bypass_port`**），这正是“客户端 DNS 指向 192.168.0.1”要的效果；
- 加 shared 之后再决定是否删掉 nft `auto_redirect` 与 TUN。

### 3.6 必须复核的耦合点（别直接照抄频道示例）

| 现有资产 | 与 eBPF 的冲突/依赖 | 处理 |
|---|---|---|
| `singbox-wan-balance.sh`（三卡分流，nft `mangle+3` 按 jhash 置 `0x0f000000`，靠 **`SO_MARK 0x2024`** 跳过代理自身流量） | eBPF 的自绕过用的是 socket-cookie map，**很可能不再给代理 socket 打 `0x2024`** → 分流的“旁路前提”失效，代理出站流量可能被 mwan3 表接管 | 切换后必须 `singbox-wan-balance.sh status` + 并发下载实测；必要时把旁路判据改为 `meta skuid` / cgroup v2 路径匹配 |
| `singbox-capture-flush.sh`（删“公网目的 + ct mark 无 0x2000”的 conntrack） | eBPF local 路径不依赖系统 NAT，理论上不再需要 | 保留脚本但不再挂到 start 流程 |
| nft `auto_redirect` 规则 | eBPF shared 不需要 | 切 shared 后一并清理 |
| `singbox-dhcp-keeper.sh`（DHCP 3/6 推 192.168.0.1） | shared 模式**不提供**转发/NAT/DHCP/RA | 保留，不动 |
| `sbtun0` / fake-ip v6 段 | local `cgroup` 不建网卡；fake-ip 仍可用，但 `fakeip_icmp` 在 local cgroup 下不能回 ICMP | 客户端 ping 假 IP 的场景会变；按需评估 |

### 3.7 风险清单

- **同一实例只能有一个 eBPF 入站开 local**；其余 eBPF 入站只能 shared。
- **不能与 TUN 同时开**（双捕获会互抢），切换必须停旧起新（`sing-box.sh` 现有 start/stop 流程就能覆盖）。
- 分片：IPv4 分片、非 atomic IPv6 分片会绕过接管；IPv6 最多解析 4 个扩展头。
- `packet_rewrite` 要求**以太网帧**：`br-lan` OK；将来若走 USB RNDIS/PPP 类链路要用 `socket_assign`。
- vendor 内核裁掉 BPF/TC 时探测直接报 `FAIL`——这就是我们花 5 分钟先探测的价值。
- 回滚：只改配置不改二进制；保留 `/data/sing-box/config.json` 备份 + `sing-box.sh restart` 即可回到 TUN。

---

## 4. 可观测性 + 面板（低风险，建议先上）

频道 [258](https://t.me/e58695/258) 与文档 `docs/configuration/experimental/observability.zh.md`：

- **开关**：`experimental.observability.enabled`，**普通构建即含，不需要 build tag**（我们二进制里有 `/observability/v1/` 字符串）。
- **字段**：`recent_connections`（默认 1000，>100000 拒绝）、`recent_ttl`（默认 30m）、`top_k_size`（默认 100）、`expose_sensitive`（默认 false；开了才会返回域名/IP/进程/规则）。
- **挂载点**：同一个 API 同时挂到 Clash Controller（`clash_api`）和原生 `services.api`，不用另开监听。
- **接口**（`GET`，前缀 `/observability/v1`）：`/`、`/capabilities`、`/metrics`（Prometheus）、`/status`、`/connections/active`、`/connections/recent`、`/top?dimension=outbound|inbound|rule|domain|process|user…`、`/events`（SSE）。
- **长期数据**：交给 Prometheus 抓 `/observability/v1/metrics`；Grafana 11.6+ + Infinity 插件 4.0+ 才能同时看 JSON 快照；官方 Dashboard JSON 在 fork 的 `docs/assets/observability/` 下。
- **认证**：绑定非回环地址时**必须设 `secret`**，用 `Authorization: Bearer <secret>`。

**现网适配建议**（低成本、可立即做）：

```json
"experimental": {
  "clash_api": { "external_controller": "0.0.0.0:9999", "external_ui": "/data/sing-box/ui", "secret": "<换成长随机串>", "default_mode": "Rule" },
  "observability": { "enabled": true, "recent_connections": 2000, "recent_ttl": "1h", "top_k_size": 100, "expose_sensitive": false }
}
```

> ⚠️ 现在 `secret` 是空的（AGENTS 里写明“用户知情”）。一旦开 observability 且 `external_controller` 仍是 `0.0.0.0:9999`，LAN 内任何人都能读近期连接/域名（若再开 `expose_sensitive` 就是隐私泄漏）。**要么设 secret，要么把 controller 绑回 127.0.0.1**。
>
> **2026-10-30 用户拍板（HANDOVER §29，优先于上面这条）**：本项目**不设 panel secret**，
> 保持 `clash_api.secret=""`；不要用“设 secret / 绑 127.0.0.1”去改这个习惯。
> `convert.py` 已不再强制 secret；临时实验设了也要清回并重启。

**与面板的关系**：
- 现有 Zashboard `http://192.168.0.1:9999/ui/` 继续用（它走 Clash API）；
- 频道 [260](https://t.me/e58695/260) 推荐的官方 `SagerNet/sing-box-dashboard` 可以用 `services.api.dashboard` 一行配置内建托管（`path`、`download_url`），适合当“第二块面板”，不影响 Zashboard；
- 设备二进制有 `dashboard` / `download_url` 字符串，但**上机前先 `sing-box check -c` 验证**该字段被接受。

**与弱网黑匣子的关系**：`/metrics` 可被家里 NAS 的 Prometheus 直接抓（走设备三卡出站或 LAN），`singbox_traffic_*`、`singbox_outbound_*`、URLTest 延迟能补上 `weaknet-watch.sh` 的“长期趋势”空白 —— 弱网判读（RSRP/SNR + 代理失败率）可以和指标对齐时间轴。

---

## 5. 作者自用配置 vs 我们现网 config：可抄的 delta

作者最新自用配置：<https://gist.github.com/CHIZI-0618/35f59df7b17bf66ea988d775aaf76152>（`1.14.x-reF1nd`，含 eBPF + dashboard + providers）。我们现网：`singbox/generated/config.device.json`。

| # | 项 | 作者 gist | 我们现网 | 建议 |
|---|---|---|---|---|
| 1 | 入站 | `ebpf`(local+shared) + `mixed:7080` | `tun sbtun0` + `mixed:7890` | 见 §3，分步替换 |
| 2 | 原生 API + 面板 | `services.api` 9999 + `dashboard{enabled,path}` | 无 `services` | **P1 可加**（低风险，需 check） |
| 3 | observability | 有 | 无 | **P0 可加**（§4） |
| 4 | 订阅下载 `http_clients` | `s-download`：UA 伪装 `clash.meta/mihomo/alpha` + `detour: Proxy` | 无（`update-providers.sh` 走 shell） | P2：UA 影响订阅站返回格式，值得加 |
| 5 | providers `health_check` | 开（`cp.cloudflare.com/generate_204`，30m） | 8 个 provider **全关** | 只给“专线/主用”开，避免三卡白跑探测流量 |
| 6 | 规则集格式 | 全 `.srs`（binary） | 34 个 `source` JSON + 2 个 `.srs`（`no-ads-all.json` 就 **3.0 MB**） | **P1**：转 `.srs`，启动更快、内存更省 |
| 7 | `route.rules` 的 `resolve match_only` | 在 geoip 规则前 | 无 | P2：减少重复解析（注意与 `default_domain_resolver` 的配合） |
| 8 | DNS 结构 | `group` + `hosts`(bootstrap 固定 IP) + `optimistic` | 有 `optimistic`，无 `hosts` | P2：把 DoH 域名钉到 IP，断网自愈更稳 |
| 9 | `clash_api.secret` | 有 | **空** | 与 §4 一起改 |
| 10 | selector 行为 | `use_all_providers` + `interrupt_exist_connections` | 无 | 可选：切换节点即时生效 |

> 原则：**2/3/6 是纯粹收益，先做；1 需要窗口期；4/5/7/8/10 收益小、按需。**

---

## 6. 历史帖里“能直接用”的经验

### 6.1 ★ ZTE 固件的 GMS 拦截链（对你最“同源”的一条）

- [222](https://t.me/e58695/222) / [224](https://t.me/e58695/224)：ColorOS16 后 Google Play/服务无法联网，真因是厂商 `fw_INPUT` / `fw_OUTPUT` 里有 `rmnet+` / `wlan+` 关键字的规则；解法是 `iptables -t filter -nvL fw_INPUT --line-numbers` 找到行号后 `-D` 删除。
- [243](https://t.me/e58695/243)：红魔手机同样问题，ZTE 系链名 **`zte_fw_gms`**，解法 `su -c "iptables -F zte_fw_gms && ip6tables -F zte_fw_gms"`。
- **我们可以做什么**：B20 是 ZTE 固件，大概率有同名/同族链。上机 `iptables -S | grep -Ei 'zte|gms|fw_IN'` 看一眼；如果存在且规则可疑，记录下来（先只读，不要在生产上随手 `-F`；`-F` 会改变厂商意图，需要先备份 `iptables-save`）。

### 6.2 B 站/斗鱼 UDP 把 CPU 打满

- [95](https://t.me/e58695/95)：UDP（尤其是 STUN / P2P mcdn）会把 CPU 拉满，Meta 里的写法是两条规则 reject：
  `AND,((NETWORK,UDP),(OR,((DST-PORT,12345),(DST-PORT,443),(DOMAIN-KEYWORD,bilibili),(DOMAIN-KEYWORD,mcdn)))),REJECT`
  `AND,((NETWORK,TCP),(DOMAIN-KEYWORD,stun),(OR,((DOMAIN-KEYWORD,douyu),(DOMAIN-KEYWORD,bilibili)))),REJECT`
- **我们可以做什么**：我们现在 `sniffer` 已含 `stun`；如果三卡模式下 B 站/直播场景出现 sing-box CPU 飙高，按上面思路加 reject（sing-box 写法用 `network: udp` + `port_range` + `domain_keyword`）。

### 6.3 TPROXY 内核能力自检

- [59](https://t.me/e58695/59)：`su -c 'zcat /proc/config.gz | grep TPROXY'` → `CONFIG_NETFILTER_XT_TARGET_TPROXY=y`。
- **我们可以做什么**：这是 eBPF 探测前的“老派”检查；`/proc/config.gz` 在 B20 上不一定有，可作为 quick check 之一。

### 6.4 fake-ip + 客户端 Captive Portal

- [12](https://t.me/e58695/12)：Clash 安卓透明代理把 UID 1000 加入黑名单后，fake-ip 会让系统提示“无法连接网络”（实际能上网），解法是把 ROM 的 Captive Portal Server 加进 `fake-ip-filter`。
- **我们可以做什么**：我们已经在 rules 里把 `connectivitycheck.gstatic.com` 等直连，效果等价；若以后客户端的探测域名换新，按这条思路加进直连/`fake_ip_filter`。

### 6.5 规则源与 CN IP 段

- [63](https://t.me/e58695/63)：`Loyalsoldier/v2ray-rules-dat` 的 `geosite.dat`/`geoip.dat` + `Loyalsoldier/geoip` 的 `Country.mmdb`（永久指向 latest）。
- [70](https://t.me/e58695/70)：APNIC 官方拿 CN IPv4/IPv6 段的 awk 一行（生成 `CN_ipv4.txt` / `CN_ipv6.txt`）。
- **我们可以做什么**：备用规则源；我们的 `.srs` 目前来自 MetaCubeX/meta-rules-dat，两者可互为兜底。

### 6.6 Sub-Store 自建（订阅合成）

- [205](https://t.me/e58695/205)：Termux 里 `node sub-store.bundle.js` + 前端，`pkg i nodejs-lts`。
- [266](https://t.me/e58695/266)：新版前端要加环境变量 `SUB_STORE_CORS_ALLOWED_ORIGINS="*"`、`SUB_STORE_FRONTEND_BACKEND_PATH="/"`，否则打不开。
- **我们可以做什么**：设备上已用 `providers` + `update-providers.sh` 直连机场订阅；若要做“多机场合并/改名/过滤”，Sub-Store 是现成方案（B20 上有 Node 吗？没有则跑在 NAS 上更合适）。

### 6.7 静态二进制与内核模块（真要造轮子时的工具）

- [216](https://t.me/e58695/216) / [220](https://t.me/e58695/220)：`android-arm64-libcap-static`；[221](https://t.me/e58695/221)：`android-aarch64-ipset-static`（NDK r27d，sha256 附在帖内）。
- [242](https://t.me/e58695/242)：KSU LKM 模式加载 ipset 内核模块（`TanakaLun/IPSET_LKM`）。
- **我们可以做什么**：B20 是 musl，这些 Android/bionic 静态包**不能直接用**；但同类思路（musl 静态交叉编译 libcap/ipset）可参考。

### 6.8 透明代理脚本与模块（了解即可）

- [22](https://t.me/e58695/22)（REDIRECT 仅 TCP）、[59](https://t.me/e58695/59)（`clash_tproxy_android.sh`，含 UID 黑名单）、[226](https://t.me/e58695/226)/[240](https://t.me/e58695/240)（`AndroidTProxyShell` + telegra.ph 教程）、[244](https://t.me/e58695/244)（NetProxy，广告）。
- [193](https://t.me/e58695/193)~[201](https://t.me/e58695/201) 的 Box4Magisk 更新日志里，和我们的场景直接同源的两条：**“默认透明代理 USB 网络共享”**（我们的 USB RNDIS 正是此形态）、**“修复 sing-box Tun 热点分享”**（我们的 WiFi AP + TUN）。
- **我们可以做什么**：`AndroidTProxyShell/tproxy.sh` 的 iptables/策略路由写法可作为 eBPF 失败时的 Plan B 参考（B20 是 OpenWrt，nft 更合适）。

### 6.9 不采纳

- [252](https://t.me/e58695/252) `ipv6disabler` 模块：与本仓库“**不要**把 IPv6 改回 false / IPv4-only”红线冲突，明确不采用。
- [250](https://t.me/e58695/250) AsteriskNG / AsteriskMETA：Android GUI 客户端，与 B20 无关（手机端可玩）。

---

## 7. 行动清单

> **2026-10-30 更新（已落地，见 §8）**：P0 的脚本、P1 的 observability / dashboard /
> 规则集演进路线已经在仓库里实现并通过 host 侧校验；设备在线后只剩“跑探测 + 窗口期切换”。
>
> **2026-10-30 晚（设备在线后）**：P0 已跑，三条 eBPF 路径全过；P1 observability 已上线
> （**无密码**，见 HANDOVER §29/§30）。
>
> **P2 结论（2026-10-30 深夜更新）**：**eBPF `shared.packet_rewrite` 会卡 LAN TCP**
> （TLS ClientHello 重传、只有 SYN-ACK 重传、observability 里没有连接对象；关 `local` 无效；
> 设备本机正常），已**改用 TUN all-proxy**（`--profile tun-allproxy`，现网，见 HANDOVER §31）；
> `ebpf-allproxy` **仅实验**，不进生产。P2 第 9/10 条（用 shared 替代 nft redirect、
> 删 TUN/auto_redirect/capture-flush）**不执行**。

### P0（只读，今天就能做，不动流量）

1. 设备上跑 §3.4 的四条 `tools ebpf status`，把 `--json` 输出存 `docs/diagnostics/`。
2. 采集 `uname -a` / `mount | grep cgroup` / `ls /sys/fs/bpf` / `tc qdisc show` / `/etc/openwrt_release`。
3. `iptables -S | grep -Ei 'zte|gms|fw_IN|fw_OUT'`（§6.1，只读）。
4. 决定 observability 的 secret 方案（设 secret 或 controller 绑 127.0.0.1）。

> 1-3 已经打包成一条命令：`sh /data/sing-box/ebpf-probe.sh`（脚本随 `deploy.sh` 上机，
> 全只读、不挂载；产物在 `/data/sing-box/diagnostics/ebpf-probe-<utc>/`）。

### P1（窗口期，可回滚）

5. 打开 `experimental.observability` + `clash_api.secret`，`sing-box check` → `restart`，本地 `curl /observability/v1/status` 与 `/metrics` 验证。
6. 大规则集转 `.srs`（至少 `no-ads-all.json` 3.0 MB → binary），对比启动耗时与 RSS。
7. `services.api` + `dashboard` 试挂（可选，第二块面板）。

### P2（试验性）

8. eBPF `local` only 试跑（新 config 副本 + 窗口期），验证：本机 `curl gstatic 204`、`/data/sing-box/sing-box.sh status`、DNS、IPv6 字面量。
9. 加 `shared`（br-lan）替代 nft redirect；**同时**复核 `singbox-wan-balance.sh` 的 `SO_MARK 0x2024` 前提与三卡并发下载比例。
10. 通过后：删 TUN / nft auto_redirect / capture-flush 挂载；更新 私人工作笔记（未公开发布） 与 私人交接文档（未公开发布）（新增“eBPF 入站”一节）。

---

## 8. 落地记录（2026-10-30 当天已完成的部分）

按 §7 直接开干，仓库侧（不可逆风险为 0 的部分）已经落地；**设备侧未执行**（抓取当时
PC 在 `192.168.2.101`，设备 `192.168.0.1` 不可达，`adb devices` 为空）。

### 8.1 代码改动

| 文件 | 改动 |
|---|---|
| `singbox/convert.py` | 新增 `--profile {base,observability,ebpf-local,ebpf-full}`、`--clash-secret`（或 `SINGBOX_CLASH_SECRET`）、`--ebpf-interface`；`build_inbounds()` 按 profile 产出 TUN 或 eBPF 入站；非 base profile 自动加 `experimental.observability` 并要求 secret；eBPF profile 用独立 `cache.ebpf.db`；**所有生成物强制 LF**（此前在 Windows 上重生成会变 CRLF，导致 md5 不一致） |
| `singbox/ebpf-probe.sh` | **新增**：设备侧只读探测。环境取证 + 4 条 `tools ebpf status`（local cgroup / local socket_assign / shared packet_rewrite / 组合）+ iptables `zte/gms/fw_*` 只读检查；产物按 UTC 时间戳落 `diagnostics/ebpf-probe-<utc>/`；退出码 0/1/2 分别表示全过/有 FAIL/二进制无 eBPF |
| `singbox/deploy.sh` | 新增 `--config <file>`（选 profile）与 `--binary`；覆盖前自动备份远端 `config.json.bak-<utc>`；推送 `ebpf-probe.sh`；部署 eBPF profile 时打印三卡分流复核提示 |
| `singbox/sing-box.sh` | 新增 `inbound_mode()`（按配置内容识别 tun/ebpf）、`ebpf_shared_enabled()`；`verify_core` 在 eBPF 模式下改为“要求 `sbtun0` 不存在”而不是要求存在；`start` 在 eBPF 模式下跳过 conntrack 清洗；`status` 增加 `in: ebpf (...)`；新增 `ebpf` 子命令转发到探测脚本 |
| `singbox/singbox-wan-balance.sh` | `singbox_mark()` 记录 `MARK_SOURCE`（`rule`/`fallback`）；eBPF 模式下告警“分流是 no-op”；`status` 打印 bypass mark 来源 + 完整 nft 链（含计数器） |
| `singbox/tests/test_convert.py` | 新增 5 个用例：base 仍是 TUN、observability 保留 TUN、ebpf-local 结构、ebpf-full 管理端口放行、非 base 必须 secret |
| `singbox/README.md` | 新增「eBPF 入站（实验）」一节（profile 表、落地顺序、回滚、三卡分流降级说明）+ 产物表更新 |

### 8.2 已验证（host 侧，可复现）

```sh
# 1) base profile 无回归：重新生成与仓库内配置逐字节一致
python singbox/convert.py --profile base --out /tmp/gen-base
sha256sum singbox/generated/config.device.json /tmp/gen-base/config.device.json
#   两者均为 27afac6c9eca792f...b2ef（相同）

# 2) 生成三个新 profile
python singbox/convert.py --profile observability --clash-secret <secret>
python singbox/convert.py --profile ebpf-local    --clash-secret <secret>
python singbox/convert.py --profile ebpf-full     --clash-secret <secret>

# 3) 用与设备同 commit 的 schema + 官方 windows 1.14.4 二进制校验
#    config.device.json            schema=OK parser=OK
#    config.observability.json     schema=OK parser=OK
#    config.ebpf-local.json        schema=OK parser=N/A (windows 构建无 with_ebpf)
#    config.ebpf-full.json         schema=OK parser=N/A
#    + 3 个自测用例证明 schema 真的会拒绝错误的
#      ebpf.local.data_plane / ebpf.network / observability.recent_connections

# 4) 单元测试
python -m unittest discover -s singbox/tests -v     # 11 passed

# 5) 脚本语法
sh -n singbox/{deploy.sh,ebpf-probe.sh,sing-box.sh,singbox-wan-balance.sh}   # 全 0
```

（本机没有 shellcheck，`make shellcheck` 这一步需在 CI/Ubuntu 上跑。）

### 8.3 设备在线后按顺序做

> **当前阻塞（2026-10-30 白天）**：PC 侧 USB ADB 不通 —— `adb devices` 为空。已定性为
> **01:03:47 `pnputil /remove-device` 强删后、未拔线软重建实例留下的半死 PnP 状态**
> （ADB bulk 首发 `Win32 433`、RNDIS/MSD `Problem 0xA`、链路本身是 HS 480M 且零掉线），
> 不是 USB 3.0 口问题。恢复：**物理拔插 ≥3 秒**（或设备重启），不行则连设备 WiFi 走
> 无线 ADB `adb connect 192.168.0.1:15555`。完整取证：
> [USB-ADB-DIAG-2026-10-30.md](USB-ADB-DIAG-2026-10-30.md) / HANDOVER §27（私人交接未公开发布）。

```sh
# 0) 生成 + 部署（PC 侧，设备连上后）
python singbox/convert.py --profile observability --clash-secret "$(openssl rand -hex 24)"
sh singbox/deploy.sh --config config.observability.json
adb shell 'sh /data/sing-box/sing-box.sh restart && /data/sing-box/sing-box.sh status'

# 1) 只读探测（P0）
adb shell 'sh /data/sing-box/ebpf-probe.sh'
adb pull /data/sing-box/diagnostics/ <本地备份>

# 2) 确认 observability
adb shell 'curl -s -H "Authorization: Bearer <secret>" http://127.0.0.1:9999/observability/v1/status'

# 3) 窗口期试 eBPF local（P2 第一步）
sh singbox/deploy.sh --config config.ebpf-local.json
adb shell 'sh /data/sing-box/sing-box.sh restart && /data/sing-box/sing-box.sh status'
#   验证：本机 curl gstatic 204、DNS、IPv6 字面量、sbtun0 应消失
#   回滚：cp /data/sing-box/config.json.bak-<utc> /data/sing-box/config.json && restart
```

---

## 附录 A：技术消息索引（按主题）

| 主题 | 消息 |
|---|---|
| Clash 透明代理 / 内核检查 / UID 黑名单 | [12](https://t.me/e58695/12) [22](https://t.me/e58695/22) [59](https://t.me/e58695/59) [60](https://t.me/e58695/60) |
| 规则源 / CN IP 段 | [63](https://t.me/e58695/63) [70](https://t.me/e58695/70) |
| UDP/STUN CPU 问题 + Meta 规则 | [95](https://t.me/e58695/95) |
| sing-box provider 下游（历史） | [96](https://t.me/e58695/96) [97](https://t.me/e58695/97) [147](https://t.me/e58695/147) [163](https://t.me/e58695/163) [167](https://t.me/e58695/167) [211](https://t.me/e58695/211) [215](https://t.me/e58695/215) |
| Box4Magisk 更新（热点/USB 共享/防回环/mrs） | [114](https://t.me/e58695/114) [146](https://t.me/e58695/146) [161](https://t.me/e58695/161) [193](https://t.me/e58695/193) [197](https://t.me/e58695/197) [199](https://t.me/e58695/199) [201](https://t.me/e58695/201) |
| 自用配置 gist（1.8 → 1.12 → 1.14-reF1nd） | [153](https://t.me/e58695/153) [183](https://t.me/e58695/183) [217](https://t.me/e58695/217) [249](https://t.me/e58695/249) [254](https://t.me/e58695/254) [259](https://t.me/e58695/259) |
| sing-box 1.10 nftables 规则集绕过 | [195](https://t.me/e58695/195) [196](https://t.me/e58695/196) |
| Sub-Store | [205](https://t.me/e58695/205) [207](https://t.me/e58695/207) [212](https://t.me/e58695/212) [266](https://t.me/e58695/266) |
| Zashboard / 面板 | [208](https://t.me/e58695/208) [260](https://t.me/e58695/260) |
| AndroidTProxyShell | [226](https://t.me/e58695/226) [228](https://t.me/e58695/228) [235](https://t.me/e58695/235) [240](https://t.me/e58695/240) |
| 静态库/内核模块 | [216](https://t.me/e58695/216) [220](https://t.me/e58695/220) [221](https://t.me/e58695/221) [242](https://t.me/e58695/242) |
| ZTE / ColorOS GMS 拦截 | [222](https://t.me/e58695/222) [223](https://t.me/e58695/223) [224](https://t.me/e58695/224) [239](https://t.me/e58695/239) [243](https://t.me/e58695/243) |
| eBPF 入站（旧→新→文档） | [253](https://t.me/e58695/253) [256](https://t.me/e58695/256) [257](https://t.me/e58695/257) [270](https://t.me/e58695/270) |
| observability | [258](https://t.me/e58695/258) |
| 其它（Android 客户端、模块、影视音频） | [87](https://t.me/e58695/87) [91](https://t.me/e58695/91) [156](https://t.me/e58695/156) [173](https://t.me/e58695/173) [231](https://t.me/e58695/231) [250](https://t.me/e58695/250) [252](https://t.me/e58695/252) [244](https://t.me/e58695/244) |

## 附录 B：证据文件与复现

| 文件 | 内容 |
|---|---|
| `docs/assets/telegram-e58695-transcript-2026-10-30.md` | 116 条消息的完整可读转录（含文件/图片/链接标记） |
| `tmp/tg-e58695/messages.jsonl` | 结构化消息（id、UTC 时间、正文、附件、链接、浏览量） |
| `tmp/tg-e58695/crawl.py` | 抓取脚本（`t.me/s/` 分页回溯 + 重试 + 断点续爬） |
| `tmp/tg-e58695/raw/page*.html` | 原始 HTML（7 页） |
| `tmp/tg-e58695/gist-config.json` | 作者 1.14-reF1nd 自用配置原文 |
| `tmp/tg-e58695/ebpf-doc-1.14.4.md`、`ebpf-kernel-req-1.14.4.md`、`ebpf-troubleshoot-1.14.4.md`、`observability.zh.md` | 与设备同 commit 的官方文档快照 |
| `tmp/tg-e58695/scan_bin.py` / `scan2.py` / `scan3.py` / `scan4.py` | 对 1.14.4-reF1nd 二进制的取证脚本（buildinfo/符号/字段串） |
| `tmp/tg-e58695/ref1nd-releases.json` | reF1nd 发行线近 6 个版本的元数据与资产列表 |
| `tmp/tg-e58695/schema.json` | **设备同 commit（732618a）的 `docs/schema.json`**（510 KB），用于离线校验生成配置 |
| `tmp/tg-e58695/check_configs.py` | 校验脚本：schema 校验 + 官方 windows 1.14.4 `check` + 3 条负向自测 |
| `tmp/tg-e58695/test_inbound_mode.sh` | `sing-box.sh` 的 tun/ebpf 模式识别 smoke test（4 个 profile） |
| `tmp/tg-e58695/bin/win/…` | 官方 `sing-box-1.14.4-reF1nd-windows-amd64`（校验用，非部署对象） |
| `tmp/tg-e58695/bin/extract-1.14.4/…` | 与设备同款的 `linux-arm64-musl` 二进制（取证用） |
| `tmp/tg-e58695/gen-base/` | `--profile base` 重生成结果，用于证明“无回归”（sha256 与 `singbox/generated/config.device.json` 相同） |

> 生成物 `singbox/generated/config.*.json` 与 `providers.conf` 均在 `.gitignore` 内，
> 其中的 `clash_api.secret` 不会被提交；secret 明文只存在于本机 `tmp/tg-e58695/clash-secret.txt`
> （用完可删，改 secret 后重新生成 + 重新在 Zashboard 里填一次即可）。

**一句话总结**：这个频道不是“资讯搬运”，而是**你这台设备现在所用内核的作者本人的工作台**。今年真正值得抄的只有两件：**eBPF 入站（替 TUN）**和**可观测性（看清流量）**；前者要探测、要窗口期、要复核三卡分流的 SO_MARK；后者今天就能开。
