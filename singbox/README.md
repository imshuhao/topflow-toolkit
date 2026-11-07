# sing-box 迁移工具（Clash Meta → sing-box 1.14 fork）

把仓库根目录的 `config.production-adapted.yaml` 转成可部署到
`/data/sing-box/` 的 sing-box 配置。目标内核是 reF1nd 1.14.4
`linux-arm64-musl`（静态），设备为 ZTE TopFlow MU5252（AArch64/musl）。

## 用法

```sh
# 1) 生成（--refresh 强制重拉规则源/订阅缓存）
python singbox/convert.py
python singbox/convert.py --refresh

# 1b) 其它 profile（见下方「eBPF 入站」）
#     用户规则（HANDOVER §29）：控制面板不设密码，secret 保持空。
#     --clash-secret 只用于临时实验，不是必需。
python singbox/convert.py --profile observability
python singbox/convert.py --profile ebpf-local
python singbox/convert.py --profile ebpf-full  --ebpf-interface br-lan
python singbox/convert.py --profile ebpf-local-only   --ebpf-interface br-lan
#      ↑ 迁移 phase 1：只接管设备本机（无 shared），全代理路由；LAN 不被捕获＝真实流量，
#        只允许几分钟测试窗口，不是可停留状态
python singbox/convert.py --profile ebpf-local-shared --ebpf-interface br-lan
#      ↑ 迁移 phase 2：local + shared 接管 LAN，`bypass_port: []`（零直连），
#        与 ebpf-allproxy 生成物逐字节相同
python singbox/convert.py --profile ebpf-allproxy --ebpf-interface br-lan
#      ↑ 全代理（免流）档：全部公网 TCP/UDP、IPv4/IPv6 流量都走代理（DNS 也是流量），
#        只有 LAN/私网、管理面 192.168.0.1 与 DNS 的 bootstrap 解析器例外；
#        eBPF 档带 route.default_mark=8228
python singbox/convert.py --profile tun-allproxy
#      ↑ 同一套零直连路由，但走生产 TUN 栈（eBPF `shared.packet_rewrite` 卡 LAN TCP 时的落地档；
#        `shared.socket_assign` 已于 2026-10-31 A/B 通过，但生产未切换，见 HANDOVER §35.6）；
#        TUN 档不能写 default_mark（SO_MARK 由 auto_redirect/auto_route 自己打）

# 2) 部署到设备（不启动内核）
sh singbox/deploy.sh
sh singbox/deploy.sh --config config.ebpf-local.json   # 部署指定 profile
sh singbox/deploy.sh --binary /path/to/sing-box        # 可选：同时推内核
#    安全顺序（脚本内置，无开关）：先推脚本/规则/provider → backup-config.sh save auto
#    （相位备份 + md5 清单，失败即中止）→ 新配置落 config.json.new → 设备侧
#    `sing-box check` → 通过后才原子 mv 覆盖 config.json。坏的配置永远压不掉线上配置。
#    --verify 只跑配置面（verify-ebpf.sh --static）；运行时（/observability、wan-balance、
#    三卡分布）必须在 `sing-box.sh restart` 之后单独跑 `sh /data/sing-box/verify-ebpf.sh`。
sh singbox/deploy.sh --config config.ebpf-local-shared.json --verify
ANDROID_SERIAL=<serial> sh singbox/deploy.sh --config ...   # 多设备时指定序列号

# 3) 静态校验
adb shell 'cd /data/sing-box && ./sing-box check -c config.json'
adb shell 'sh /data/sing-box/verify-ebpf.sh --static'   # 配置面：入站/local/shared/bypass

# 3b) eBPF 能力探测（只读，不挂载、不改流量；产物在 diagnostics/ebpf-probe-<utc>/）
adb shell 'sh /data/sing-box/ebpf-probe.sh'
adb shell 'sh /data/sing-box/sing-box.sh ebpf --local-only'

# 转换器自测
python -m unittest discover -s singbox/tests -v

# 4) 设备上电后一键恢复（部署 + boot hook + 启动 + 校验）
sh singbox/resume-after-power.sh

# 5) lab（mixed 7891 / api 9095，无 TUN）
adb push singbox/generated/config.lab.json /data/sing-box/lab.json
adb shell 'cd /data/sing-box && ./sing-box run -c lab.json > /tmp/sing-box.log 2>&1 & echo $! > lab.pid'
```

## 产物

| 文件 | 说明 |
|---|---|
| `generated/config.device.json` | 生产配置（`/data/sing-box` 绝对路径，TUN 栈） |
| `generated/config.observability.json` | TUN 栈 + `experimental.observability`（Prometheus / 近期连接 / Top-K） |
| `generated/config.ebpf-local.json` | eBPF 入站，仅 local（cgroup v2，本机流量），无 TUN |
| `generated/config.ebpf-full.json` | eBPF 入站，local + shared `packet_rewrite`（br-lan 下游） |
| `generated/config.ebpf-local-only.json` | 迁移 phase 1：eBPF local only + 显式 `ipv6` + 全代理路由；LAN 客户端**不**被接管（仅测试窗口） |
| `generated/config.ebpf-local-shared.json` | 迁移 phase 2：local + shared，`bypass_port: []`，两面 `ipv6`（与 `ebpf-allproxy` 逐字节相同） |
| `generated/config.ebpf-allproxy.json` | 同上 + 全代理（免流）：`bypass_port: []`、DIRECT 只剩 private 规则集、`final` 走免流、`route.default_mark: 8228` |
| `generated/config.tun-allproxy.json` | TUN 栈 + 同一套零直连路由（**现网 2026-10-30 晚起**；零直连收口见 HANDOVER §32） |
| `generated/config.lab.json` | lab 配置（mixed 7891 + api 9095，无 TUN） |
| `generated/config.local.json` | 本机相对路径版本，供 `sing-box check` |
| `generated/rules/` | 36 个本地规则集（34 JSON + 2 SRS） |
| `generated/providers/` | 订阅快照（含节点凭据，**不要提交**） |
| `generated/providers.conf` | 订阅更新清单 |
| `update-providers.sh` | 设备侧订阅更新器（原子替换，热重载） |
| `sing-box.sh` | 设备侧 start/stop/status/switchover/rollback/ebpf（自动识别 TUN/eBPF 模式） |
| `ebpf-probe.sh` | eBPF 内核能力只读探测 + 环境取证（`diagnostics/ebpf-probe-<utc>/`） |
| `singbox-watchdog.sh` | 15s 看门狗（lock 目录、防递归 restart） |
| `install-boot.sh` | rc.local 启动块 + provider cron + 禁用 mihomo-netns |
| `deploy.sh` | 暂存+校验+原子替换（`--config` 选 profile；`save auto` 相位备份；`--verify` 配置面验证；`ANDROID_SERIAL`） |
| `verify-ebpf.sh` | 部署后验证：入站类型 / local+shared / 零公网直连 / DNS detour / `/observability/v1` / wan-balance / 三卡并发分布（`--static` 只查配置；local-only 直接 FAIL） |
| `resume-after-power.sh` | 上电后：deploy + install-boot + start + status |
| `install-ui.sh` | 下载并安装 Zashboard（备份旧 UI） |

## 关键设计

- **provider 全部 local**：fork 的 remote provider 在启动时任一下载失败会
  FATAL（实测 1.中国国际机场 500）。生成时只纳入 `outbounds` 非空的订阅；
  设备侧用 `update-providers.sh` 定时刷新。
- **规则集全部 local**：GitMetaio 的 `.mrs` 不解析，改取其同目录
  `*_OCD_Domain.txt` / `*_OCD_IP.txt` 源；CN 用 SagerNet `.srs`。
  启动不依赖远程规则集。
- **Clash filter → include/exclude**：PCRE lookahead 在 Go RE2 不合法，转换器
  拆成正/负向正则。
- **fallback → urltest**：sing-box 没有 fallback 类型，行为是“最低延迟”而非
  严格故障转移。
- **load-balance → loadbalance**（fork）：Clash 的 `strategy` 原样保留
  （`round-robin` / `consistent-hashing` / `sticky-sessions` 三者实测均过
  `sing-box check`）；源码没写 `strategy` 时按 Clash 默认取 `consistent-hashing`。
  **弱网（2026-11-02）**：`interval`/`ttl` 强制 `1m`（不再跟 Clash 源的 5m/10m），
  尽快把坏节点踢出哈希池；strategy 仍默认 `consistent-hashing` 以照顾 CDN 粘性。
- **TUN**：`sbtun0`，`auto_route`/`auto_redirect`，`auto_detect_interface:false`
  以保留 mwan3；`route_address: ["::/0"]` 捕获全部 v6，`route_exclude_address` 只放
  LAN/私网/ULA/link-local/组播（`ff00::/8`），fake-ip v6 段在捕获内。
- **DNS（all-proxy 档，2026-10-31 零直连）**：`ali`/`ali2` 两条 DoH 带
  `detour: 🚀 免流模式`；`bootstrap` 保持 `{"type":"udp","server":"223.5.5.5"}`、
  **无 detour** —— 它要解析节点域名，不能搭自己要连的代理，是 DNS 全代理的**唯一结构性例外**。
  曾经把它改成 `type=tcp` + `detour: ⚡ 引导·DNS`（某个 IP 字面量免流节点的克隆，
  只换 tag、保留 Host/SNI），**真机失败已回滚**：`gstatic` 502、日志
  `lookup node.example.invalid: read response: v2ray-http: unexpected status: 400 Bad Request`
  —— 免流节点是 Host 白名单 CDN 前端，不转发任意 TCP 负载。`⚡ 引导·DNS` 与克隆代码已删除。
  `route.default_domain_resolver = bootstrap`（`strategy: ipv4_only`：节点侧只能靠 v4，
  三卡才均衡得起来）。
- **DNS 规则顺序（all-proxy 档）**：`{"domain_suffix":[".lan",".local"]} → ali` →
  `AAAA → fakeip` → `geosite-cn → ali` → `A → fakeip`。filter 由 `local_only_filter()`
  **收窄成 LAN 专用**（Clash 原表里的 `.cn` / `.taobao.com` 等全剔除），所以 **CN 域名的
  AAAA 也拿 fake-ip**（真机实测 `www.wikipedia.org`/`www.qq.com`/`example.org` AAAA →
  `fdfe:dcba:9876::5e/5d/5f`）。`AAAA` 必须排在 `geosite-cn` 之前：真实 AAAA 会把客户端
  送到一个免流节点没有 v6 出口的地址，表现为双栈站点 000；给 fake-ip v6 后出站拿域名、
  节点用 v4 解析，**v6 客户端也被代理**。
- 非 all-proxy 档（`base` / `observability` / `ebpf-local` / `ebpf-full`）没有这套 DNS delta
  （DoH 无 `detour`、没有 AAAA 前置规则、filter 仍是完整表），仅用于历史 profile，
  **不要**把它当作可接受的生产口径。`bootstrap` 两档相同（udp `223.5.5.5`，无 detour）。

## 已验证 / 未验证

已验证（lab + 生产 switchover）：

- `sing-box check` 0 error；
- google 204 / youtube 200 / taobao 200 / jd 200 / example 200 / gstatic 204；
- `loadbalance` 组切换后 google 204 / youtube 200；
- 8 个本地 provider 加载（1/7 为占位；3 已恢复），订阅更新器原子替换、失败保留旧文件；
- Zashboard 面板：`/ui/` 200，显示 50 个组 / 8 个 provider；
- 生产 `switchover` 返回 0：`sbtun0` UP、DHCP 0.1、gstatic/google 204、taobao/jd 200。
- 已验证：客户端 v6 TCP、IPv6 字面量代理、fake-ip、`kill -9` 自愈、reboot 持久化、三卡分流（见下）；待测：UDP 非 DNS、rollback。
- **shared eBPF 单变量 A/B（2026-10-31，B20 上机）**：`packet_rewrite` 控制组 LAN TCP 卡死；
  `socket_assign` 通过 attach=1 + LAN HTTPS 204 + 代理连接对象 + 300 s 内 3 次重启 + 18/18 并发。
  **生产仍 TUN、未切换**（HANDOVER §35.6）。local `socket_assign` 仅过静态门禁，未做流量。

仍待补测：

- UDP 非 DNS 业务、`rollback` 演练。
- 已过：TUN / `auto_redirect` / 客户端 v6 TCP / fake-ip / 自愈 / reboot。
- 详见 `docs/SINGBOX-MIGRATION-PLAN-2026-10-27.md`。

2026-10-30 新增（host 侧验证，设备侧未跑）：

- `--profile base` 重新生成与仓库内 `config.device.json` **字节一致**（sha256 相同），
  说明 profile 改造没有回归；
- 4 个旧 profile（`base` / `observability` / `ebpf-local` / `ebpf-full`）全部通过
  **与设备同 commit（732618a）的 `docs/schema.json`** 校验，
  并用自测用例确认 schema 真的会拒绝错误的 `ebpf.local.data_plane` /
  `ebpf.network` / `observability.recent_connections`；
- `config.device.json` / `config.observability.json` 用官方 windows/amd64 1.14.4-reF1nd
  跑 `sing-box check` 通过（Linux-only 的 `auto_redirect`/`interface_name` 在校验时临时置空）；
- `ebpf-*` 无法在本机用 `check` 验证（windows 构建没有 `with_ebpf`，报
  “eBPF inbound is not included in this build”），**以设备侧 `deploy.sh` 里的
  `./sing-box check -c config.json` 为准**；
- 未验证：eBPF 内核能力（要设备）、eBPF 下的三卡分流（见上）、observability 在设备上的
  实际抓取。

2026-10-30 新增 `ebpf-allproxy` / `tun-allproxy`（全代理/免流档）—— **`tun-allproxy` 已上机**
（见下方「线上状态」，当前状态以 HANDOVER §35.1 为准），`ebpf-allproxy` 仅 host 侧验证 +
设备实验（实测卡点是 shared `packet_rewrite`；`socket_assign` 已于 2026-10-31 A/B 通过但未切换）：

- `base` / `observability` / `ebpf-local` / `ebpf-full` 重新生成后与改动前**逐字节相同**
  （`cmp` 全部 IDENTICAL，`config.ebpf-full.json` 与仓库内那份 sha256 相同）；
- `config.ebpf-allproxy.json` 通过 `docs/schema.json` 校验（含 `bypass_port: []`
  与显式 `ipv6`），自测确认 schema 拒绝越界 `bypass_port` / 非布尔 `ipv6` / 错 `data_plane`；
  再用 windows 1.14.4-reF1nd 跑 `sing-box check` 通过 —— 仅把 eBPF 入站临时换成
  `mixed`（该构建无 `with_ebpf`），DNS / 113 条路由规则 / 规则集 / provider 全部真实解析；
- `config.tun-allproxy.json` 同样过 schema；`sing-box check` 直接解析通过（TUN 档不需要换
  入站，只需像 `base` 一样把 Linux-only 的 `auto_redirect`/`interface_name` 临时置空）；
- `ebpf-allproxy` 仍是 eBPF 档：**设备侧 `./sing-box check -c config.json` 才是最终判据**；
  且设备侧已实测 eBPF `shared.packet_rewrite` 卡 LAN TCP（`socket_assign` 的本轮 A/B 通过不改变
  生产口径），运维上优先用 `tun-allproxy`；
- 细节与命令见 `tmp/huya-ebpf/generator-change.md`、`tmp/huya-ebpf/tun-allproxy.md`；
  上机记录见 `tmp/huya-ebpf/tun-allproxy-deploy.md`、`tmp/huya-ebpf/all-proxy-fix.md`
  （eBPF 卡顿取证）与 `私人交接文档（未公开发布）` §31。

## 三卡分流（`singbox-wan-balance.sh`）

宿主模式（无 netns）下 mwan3 只能均衡**转发**流量，sing-box 的出站是本机
OUTPUT：它给 socket 打 `SO_MARK 0x2024` 用于自身 TUN 旁路，而
`0x2024 & mwan3 mmx_mask 0x3f00 = 0x2000`，`mwan3_hook` 的每条
`-m mark --mark 0x0/0x3f00` 都跳过它 —— 结果代理流量全部落到 main 表默认路由
（`rmnet_data0`，5G），两张 4G 卡只剩 mwan3 探测包。

`singbox-wan-balance.sh` 把这个缺口补上，且不破坏 sing-box 的自我识别：

```
nft ip tf-sbwan/out   type route hook output priority mangle + 3
  meta mark == 0x2024  →  jhash(ip daddr . th sport . th dport) mod 100 → 置 0x0f000000 中的一位
ip rule 1990/1991/1992 fwmark 0x1000000|0x2000000|0x4000000 / 0x0f000000 lookup 12/13/14
```

- 选卡点在 sing-box 自己的 `mangle+1 / mangle+2` 钩子**之后**，标记值 `0x2024`
  对它保持精确可见；新增位段 `0x0f000000` 与 mwan3 的 `0x3f00` 不重叠。
- 落 mwan3 自己的接口表（12/13/14），网关/源地址由 mwan3、netifd 维护。
- 桶按 `mwan3.balanced` 的 member 权重切分（当前 6/3/3 = 50/25/25），改权重只改 mwan3。
- 分流粒度是「上游连接」：同节点多条连接会分散；mux 复用成一条 TCP 的业务流只能跟随该连接所在卡。
- **可选协议分池**（默认关闭，与现网共池行为一致）：`/data/sing-box/wan-balance.conf`
  （样例 `singbox/wan-balance.conf.example`）设 `MODE=proto` 后，`TCP_POOL` /
  `UDP_POOL` 用逗号分隔的 mwan3 接口名（如 `zte_mwan2,zte_mwan3`）各切一套 jhash。
  B20 仍只有三张物理卡，不能扩到「四五张 4G」；空/离线侧回退共池。可行性与
  现场样本见 [docs/WAN-TCP-UDP-POOL-FEASIBILITY-2026-11-05.md](../docs/WAN-TCP-UDP-POOL-FEASIBILITY-2026-11-05.md)。
  离线回归：`sh singbox/tests/test_wan_balance_render.sh`。
- 健康：`/tmp/run/mwan3/iface_state/<iface>` 非 `online` 或该表无默认路由 → 出池重切；
  卡全掉则删规则清表，退回单卡 5G 行为。
- `singbox-watchdog.sh` 每 15s 幂等刷新；`sing-box.sh start` 后立即执行，
  `stop`/`rollback` 清空；`sing-box.sh status` 多一行 `wan:`。
- `status` 现在会打印 `bypass mark (source: default|rule|ebpf|fallback)` 和完整 nft 链
  （含 `counter packets/bytes`）。`MARK_SOURCE` 的识别顺序：config 里的
  `route.default_mark` → TUN 的 `auto_route` fwmark 规则 → `ebpf` / `fallback` 兜底。
- **eBPF 档的三卡分流（2026-10-31 契约）**：`convert.py` 给 eBPF 全代理档写
  `route.default_mark = 8228`（`0x2024`），core 自己给每个代理出站包打标，于是
  `tf-sbwan` 的 jhash 链重新匹配得到 → `status` 显示 `source: default`，不再是 no-op
  （旧的"eBPF 下必然 fallback、分流失效"口径作废）。TUN 档**不能**写
  `default_mark`：它和 `tun.auto_redirect` 自己打的 `SO_MARK` 是同一个位段，写了会打架；
  TUN 下 `source: rule` 来自读 `auto_route` 的 fwmark 规则。
  仅当配置里既无 `default_mark`、又无 auto_route 规则时才显示 `ebpf` / `fallback`
  —— 那时 jhash 链匹配不到，代理才会回落 5G 单卡，日志有 WARN。
- 但 mark 只是一半：`shared.packet_rewrite` 仍卡 LAN TCP（HANDOVER §31.1、§35.6 复现），
  所以**带 `packet_rewrite` 的** eBPF 全代理档不是生产态，只允许隔离实验；`socket_assign`
  虽已在 2026-10-31 A/B 通过（attach + LAN TCP + 并发 + 重启稳定），**生产仍是 `tun-allproxy`，
  未切换**。

配套配置：`route.default_domain_resolver.strategy = ipv4_only`（`convert.py` 已改）。
只有 5G 卡有 IPv6，节点若解析到 AAAA，代理流量会重新钉死在 5G；客户端 DNS 仍是
`prefer_ipv6`，fake-ip v6 不受影响。all-proxy 档的 `ipv4_only` 特指 `bootstrap`
（解析节点域名那个解析器），不限制客户端拿 AAAA。

排查用：

```sh
/data/sing-box/singbox-wan-balance.sh status   # 池 + ip rule + nft 桶计数
/data/sing-box/sing-box.sh status              # 含 wan: 一行
tail /data/sing-box/state/wan-balance.log      # 只在池变化时写
grep -E "rmnet_data0|V3E1net0|V3E2net0" /proc/net/dev
```

## eBPF 入站（实验，2026-10-30 加入）

来源：Telegram 频道 @e58695（CHIZI-0618 / reF1nd 线）的 eBPF 入站 + 可观测性两条线，
整理见 [docs/TELEGRAM-E58695-SINGBOX-DIGEST-2026-10-30.md](../docs/TELEGRAM-E58695-SINGBOX-DIGEST-2026-10-30.md)。

**设备二进制已经具备**：下载同版本 `linux-arm64-musl` 包静态取证，buildinfo 的 `-tags`
行含 `with_ebpf`，符号里有 `protocol/ebpf/*`、`cmd_tools_ebpf.go`、`cmd_api_ebpf.go`，
配置字段串与新版 `local{}`/`shared{}` schema 一致 —— **不需要重新编译**。
（注意 `sing-box version` 打印的 `Tags:` 行不含 `with_ebpf`，那是 feature tags。）

| profile | 入站 | 用途 |
|---|---|---|
| `base`（默认） | `tun sbtun0` + `mixed:7890` | 现行生产 |
| `observability` | 同上 + `experimental.observability` | 只开指标，不动流量路径 |
| `ebpf-local` | `ebpf`(local `cgroup`) + `mixed:7890` | 先只接管本机流量 |
| `ebpf-full` | `ebpf`(local + shared `packet_rewrite` on `br-lan`) + `mixed:7890` | 同时接管 LAN 客户端 |
| `ebpf-local-only` | `ebpf`(local `cgroup`，`ipv6: true`) + `mixed:7890`，全代理路由 | **迁移 phase 1（仅测试窗口）**：只接管设备本机；LAN 未被捕获=直连真实流量 |
| `ebpf-local-shared` | `ebpf`(local + shared `packet_rewrite`，两面 `ipv6: true`，`bypass_port: []`) + `mixed:7890`，全代理路由 | **迁移 phase 2**：接管 LAN，零直连（与 `ebpf-allproxy` 同栈） |
| `ebpf-allproxy` | 同 `ebpf-full`，但 `bypass_port: []`、无直连规则、`final` 走免流 | 全代理（免流）：所有公网流量走代理 |
| `tun-allproxy` | `tun sbtun0` + `mixed:7890`（同 `base`），路由同 `ebpf-allproxy` | **现网（2026-10-30 晚上线，2026-10-31 零直连版已部署）**：同一套全代理路由的 TUN 版；`shared.packet_rewrite` 卡 LAN TCP，故生产用它（`socket_assign` A/B 通过但未切换） |

要点：

- **迁移分档（`ebpf-local-only` → `ebpf-local-shared`）**：两档都带全代理路由 delta
  （`final = 🚀 免流模式`、无直连规则），区别只在捕获平面。零直连是硬约束：本机是免流卡，
  任何绕过代理的字节都是真实流量。
  - phase 1 没有 shared：设备本机被 `local` cgroup 钩子接管并走免流路由，**LAN 客户端
    完全不被捕获**（br-lan→mwan3 普通路由直出＝烧真实流量）。因此 phase 1 **只能当几分钟
    的测试窗口**，不是可停留状态；也不会有 `redirect` inbound 兜底——那会是第二套与 eBPF
    抢捕获面的东西。
  - phase 2 的 `bypass_port: []`，LAN 每个目标端口都进数据面；管理面（`192.168.0.1` 的
    WebUI/WebSSH/Zashboard/sshd）靠 `bypass_private_address` 放行，属允许的例外。
    生成物与 `ebpf-allproxy` **逐字节相同**（同一套栈，phase 命名只用于迁移记录）。
  - 两档都把 `local.ipv6` / `shared.ipv6` 显式写 `true`：TUN 档捕获 `::/0`，eBPF 档若依赖
    构建默认值，v6 流会绕过代理。IPv6 也必须被代理（fake-ip v6 → 域名交给节点解析 + 具备
    v6 出口的 outbound），**不允许**用"屏蔽 AAAA / ipv4_only DNS"来规避。
- `shared.bypass_port`：**零直连约束下所有上机档都是 `[]`**（`ebpf-allproxy` /
  `ebpf-local-shared`）。那份管理端口列表（80 / 7890 / 8899 / 9999 / 22622）
  只保留在实验性、非全代理的 `ebpf-full` 里：它是按**目标端口**放行，放行 80/443
  就等于让 LAN 的 HTTP(S) 全部直出烧流量。管理面本来就靠
  `bypass_private_address`（目的地址 `192.168.0.1` ∈ 私网）放行；53 由
  `dns_mode: hijack` 优先接管。
- eBPF profile 用独立缓存 `cache.ebpf.db`，不污染生产 `cache.db` 的 fake-ip 记录。
- **控制面板不设密码（用户拍板，HANDOVER §29）**：`experimental.clash_api.secret` 保持 `""`，
  Zashboard 直接打开；`--clash-secret` 不是必需，只在临时实验时用。`/observability/v1`
  与 Clash API 同挂 `0.0.0.0:9999`，仅 `br-lan` 可达（用户接受该 LAN 内暴露；**不要**用
  “设 secret / 绑 127.0.0.1” 去改他的习惯）。
- 如果临时设了 secret：Zashboard 要填、`sing-box.sh` 的健康检查（`curl /version` 不带
  Authorization）会 401 并打印 `clash_api did not come up`；用完必须清回 `""` 并重启。

### 数据面 A/B（`--ebpf-local-data-plane` / `--ebpf-shared-data-plane`）

两个 eBPF 钩子各有自己的数据面：生成期选择，运行期回读（`sing-box.sh status`、
`ebpf-snapshot.sh` 的 `local_data_plane` / `shared_enabled` / `shared_data_plane`、
`api ebpf --deep` 的 `localDataPlane` / `sharedDataPlane` / `state`）。

| 钩子 | 允许值 | 默认 | 说明 |
|---|---|---|---|
| `local`（设备本机） | `cgroup` / `socket_assign` | `cgroup` | `tc` **不是**本 build 的 local 平面：按名字拒绝，不做别名 |
| `shared`（LAN，TC 钩子） | `packet_rewrite` / `socket_assign` | `packet_rewrite` | 两面均已在 B20 上机 A/B（2026-10-31）：`packet_rewrite` 复现 LAN TCP 卡死，`socket_assign` 通过本轮 attach + LAN TCP；生产仍 TUN，是否切换需另行批准（HANDOVER §35.6） |

```sh
python singbox/convert.py --profile ebpf-allproxy          # 默认：shared packet_rewrite
# 单变量候选：--out 是**目录**，生成物固定叫 config.<profile>.json
python singbox/convert.py --profile ebpf-allproxy \
    --out singbox/generated/ab-shared-sockassign \
    --ebpf-shared-data-plane socket_assign                 # → ab-shared-sockassign/config.ebpf-allproxy.json
python singbox/convert.py --profile ebpf-allproxy \
    --out singbox/generated/ab-local-sockassign \
    --ebpf-local-data-plane socket_assign                  # → ab-local-sockassign/config.ebpf-allproxy.json
# 上机时按 trial 另存命中文件（本轮实测名：config.ab-A-packetrewrite.json / config.ab-B-sockassign.json）
```

- 两个参数各改各的钩子，同一 profile 其余字节不变（`test_local_data_plane_*` /
  `test_shared_data_plane_*` 断言「只改对应 plane」）；TUN profile 不带任何 eBPF plane 字段。
- 试验入口只有 `ebpf-trial.sh`：TUN 基线快照 → `sing-box check` → `verify-ebpf.sh --static`
  → 关 watchdog 重启（`SINGBOX_NO_WATCHDOG=1`，两个 start 分支都遵守）→ 用 `api ebpf`
  核对**实际** plane → 计时 → 无论信号、deadline 还是失败，都按精确 md5 恢复 TUN。
  plane 无法确认（无 attachment 报告、config/attached 与候选不符）时打印 `TRIAL_INVALID`
  且非零退出，不记为通过。
- shared 平面开着就要求 `ebpf-fragment-guard.sh status` 返回 0：pre-defrag 钩子
  priority `-450`、每个配置接口各三条 fragment DROP（IPv4 frag-off / IPv6 frag-off /
  IPv6 more-fragments）、`iifname` 集合与配置**完全一致**、接口真实存在；任一条不满足即
  INCOMPLETE（`verify-ebpf.sh` 与 `backup-config.sh` 都按这个判定，不看 nft 表是否存在）。
- 判读口径：能力 probe PASS、`state=normal`、attachment 存在、mixed 代理 204 —— 都不是
  LAN 转发证据；A/B 结论只写进 `私人交接文档（未公开发布）` 检查点。本轮结果
  （2026-10-31 10:00–10:40 UTC）：`packet_rewrite` LAN TCP 失败、`socket_assign` 通过，
  见 HANDOVER §35.6；生产未切换。

### 全代理（`ebpf-allproxy` / `tun-allproxy`）

静态审计 `tmp/huya-ebpf/all-proxy-delta.md` 的 G1–G5 + G8，只有这两档生效，
`base` / `observability` / `ebpf-local` / `ebpf-full` 的输出保持字节一致：

| 项 | 内容 |
|---|---|
| G1 | `inbounds[0].shared.bypass_port = []`（80/443 曾让全部 LAN HTTP(S) 在内核直出）——**仅 `ebpf-allproxy`**，TUN 档没有 `shared` |
| K4 | `local.ipv6 = true` + `shared.ipv6 = true` 显式写出，不依赖默认值——**仅 `ebpf-allproxy`**（TUN 无这两个字段） |
| G2 | `🚀 专线机场.default = "⚡ 专线机场·自动选择"`；`🌍 国外总模式` / `🐟 漏网之鱼` 默认 `🚀 免流模式` |
| G3 | `route.final = "🚀 免流模式"` |
| G4 | 跳过 `{"ip_version": 6, "outbound": "🌐 nasipv6"}`（v6 目的地址跟 `final`） |
| G5 | 源规则里 `DIRECT` 目标重映射为 `🚀 免流模式`（5 条连通性探测 + `AND udp/53`）。**唯一例外是 LAN/管理面**：`private-domain` / `private-ip` 规则集，以及 `.lan` / `.local` / `.localdomain` / `.in-addr.arpa` / `.ip6.arpa` 后缀。2026-10-31 起**旧审计 §4.2 的「14 个 PT/BT 站分享率例外」作废**（用户拍板：免流 = 全部公网流量走代理），生成物里 `DIRECT` 规则只剩 2 条 |
| G6 | DNS 也是流量：`ali`/`ali2` 两条 DoH 加 `detour: 🚀 免流模式`，`route.default_domain_resolver = bootstrap`（`strategy: ipv4_only`）。`bootstrap` 自身**不加 detour**（唯一结构性例外，§32.3）；曾试过用免流节点克隆中转，真机 400 已回滚 |
| G7 | `fake-ip-filter` 收窄为 LAN 专用（`local_only_filter()`），且 `AAAA → fakeip`（`rewrite_ttl: 1`）排在 `geosite-cn` **之前**：CN 域名与非 CN 域名的 AAAA 都拿 fake-ip v6，出站带域名、由节点用 v4 解析，所以不需要节点有 v6 出口。不写 `ipv4_only`，不屏蔽 AAAA |
| G9 | selector 不再提供直连出口：`🚀 免流模式` 成员剔除 `🌐 本机·本地直连`，`🟢 直连模式` 组在 all-proxy 档**不生成** —— 面板上点不出直连。生成器 `validate_zero_direct()` fail-closed：非 private 的 `DIRECT` 规则、或任何组仍挂 `DIRECT`，直接拒绝生成 |
| G8 | 删除 douyin / tencent 的两条 `AND,((RULE-SET,x),(NETWORK,UDP),(DST-PORT,443)),REJECT`，QUIC 交给 `🇨🇳 国内udp` 代理 |

G2/G3/G4/G5/G8 是**共用的路由 delta**（`ALL_PROXY_PROFILES`），两档只差入站与缓存：

| | `ebpf-allproxy` | `tun-allproxy` |
|---|---|---|
| 入站 | `ebpf`（local cgroup + shared `packet_rewrite`） | `tun sbtun0` + `mixed:7890`（与 `base` 相同） |
| `bypass_port` / `ipv6` 显式化 | `[]` / `true` | 不适用 |
| `cache_file.path` | `/data/sing-box/cache.ebpf.db` | `/data/sing-box/cache.db` |

**为什么要有 TUN 档**（设备侧实测，2026-10-30）：eBPF `shared.packet_rewrite` 会**间歇性卡住
LAN TCP** —— TLS ClientHello 连发重传、之后只有 SYN-ACK 重传、收不到 ServerHello，抓包里服务端
从未 ACK 任何数据字节；同期 `/observability/v1/connections/active` 连续为空（sing-box 里根本没有
这条连接）；把 `local` 关掉无效，重启只是偶尔恢复。设备本机与 `mixed:7890` 入站始终正常，
故障只在 shared 客户端路径。因此带 `packet_rewrite` 的 `ebpf-allproxy` **不作为生产 LAN 档**，
`tun-allproxy` 是保住"全免流"目标、又绕开该缺陷的落地档（TUN 是既有生产路径，`auto_redirect` 依赖 nft）。

> **2026-10-31 A/B 补充**：同一设备、同一套配置只换 `shared.data_plane` 的单变量 A/B 已完成——
> `packet_rewrite` 控制组 LAN TCP 仍失败（`000` / 0 连接对象），`socket_assign` 通过
> attach=1、LAN HTTPS 204、代理连接对象出现、300 s 内 3 次重启与 18/18 并发。
> **生产仍是 TUN，未切换**；切换是独立决定，需另行批准（HANDOVER §35.6）。

**线上状态（2026-10-30 06:01–06:13 UTC，设备当时的部署）—— 历史，已被 HANDOVER §35.1 当前 TUN 状态（`7cee37d3…`，68465 B）取代**：

| 项 | 值 |
|---|---|
| 生成物 | `config.tun-allproxy.json` 70567 B，md5 `d0d9e63c78e2497b0b0cc86ba495419d`（本地 = 设备，逐字节一致，未手改） |
| 备份 | `/data/sing-box/config.json.bak-tunallproxy-20261030T060135Z`（`5288a884…`，旧 eBPF allproxy2） |
| 校验/生效 | 设备 `./sing-box check -c config.json` **rc=0**；`sbtun0` UP（mtu 1400、`172.19.0.1/30`），单 core |
| 实测 | 设备与 PC：`curl -4` 的 `baidu`/`huya` **200**、`gstatic` **204**；管理面 `192.168.0.1` / `:9999/ui/` 200、SSH 22622 通 |
| 代理证据 | `connections/recent` 为 `redirect/tun-in` → `⚖️ ALL·国内负载均衡` / `🎯 国内总模式` / `🚀 免流模式`，无 `🌐 本机·本地直连` |
| IPv6/双栈（当时未决，2026-10-31 已收口） | 不带 `-4` 的 `baidu`/`huya` 当时 = **000**（`-4` = 200）；v6 流量**确实进 TUN 并送到代理**，失败在**节点侧无 v6 出口**，不是泄漏；`dns.strategy=prefer_ipv4` 当时实测**无效已回滚**。**收口方式**：`AAAA → fake-ip` 前置于 `geosite-cn`（G7 / HANDOVER §32.3），客户端拿 fake-ip v6 即被代理，不需要节点有 v6 出口；纯 v6 **字面量**仍会失败（没有 v6 出口节点，不是直连泄漏）。`ipv4_only` DNS / 封禁 v6 的旧选项**不再采纳** |
| 回滚 | `cp /data/sing-box/config.json.bak-tunallproxy-20261030T060135Z /data/sing-box/config.json && sh /data/sing-box/sing-box.sh restart` |

回滚到 eBPF allproxy2 会重新出现上面那段 LAN TCP 卡顿，所以 eBPF 档只用于复现/取证。
完整记录见 `私人交接文档（未公开发布）` §31 与 `tmp/huya-ebpf/tun-allproxy-deploy.md`。

**零直连收口（2026-10-31，用户拍板）**：G6/G7/G9 已实现，旧的"PT 域与 DoH 直连"
口径作废。生成器对 all-proxy 档做 fail-closed 校验（`validate_zero_direct()`）：
任何**非** `private-domain`/`private-ip` 的 `DIRECT` 规则、或任何 selector/urltest/
loadbalance 仍把 `DIRECT` 当成员，生成直接失败。当前生成器产出的 all-proxy 档里 `DIRECT` 只剩
`private-domain` / `private-ip` 两条，`ali`/`ali2` 带 `detour: 🚀 免流模式`，
`bootstrap` 无 detour（唯一例外），没有 `AND udp/53` 直连规则，也没有 `⚡ 引导·DNS` outbound。

> **PT/BT 副作用（用户已知情）**：14 个 tracker 域改走代理后，tracker 看到的源 IP 是
> 节点出口，同一账号可能被站方判为**多 IP / 盒子**。这是"全部公网流量走代理"的必然代价，
> 不是回归；不要再为此把域加回 `DIRECT`。

**仓库配置与设备状态**：2026-10-31 的零直连生成物**已部署**——设备 `config.json` 为
**68465 B / md5 `7cee37d3c0ab8eb9390f9d25c41d5249`**，TUN `sbtun0` UP、DHCP 3/6 `192.168.0.1`、
guard `not required`（HANDOVER §35.1/§35.6）。2026-10-30 的 `d0d9e63c…` 只作为
`state/feature-original.json` 紧急原状快照保留，不再是线上配置。重部署走
`python singbox/convert.py --profile tun-allproxy` → `sh singbox/deploy.sh --config
config.tun-allproxy.json`（`deploy.sh` 内置 `backup-config.sh save auto` + 设备侧
`sing-box check`），回滚见下。

落地顺序（**不要跳步**）：

1. `sh /data/sing-box/ebpf-probe.sh`（只读）→ 看 `diagnostics/ebpf-probe-<utc>/`，
   任一项 `FAIL/UNKNOWN` 就停；
2. `--profile observability` 上线，确认 `/observability/v1/status` 与 `/metrics`；
3. 窗口期推 `config.ebpf-local.json`，`sing-box.sh restart`，验证本机 204 / DNS / IPv6 字面量；
4. 稳定后再推 `config.ebpf-full.json`（同时删 nft `auto_redirect` 依赖，无需手动清）。

> **2026-10-30 晚更新：第 3/4 步的"shared `packet_rewrite` 接管 LAN"路线已作废** —— 该平面
> 会卡 LAN TCP（§「为什么要有 TUN 档」），现网走 `tun-allproxy`（TUN 全代理），
> `ebpf-local` 仍可单独用来只接管设备本机流量，带 `packet_rewrite` 的
> `ebpf-full`/`ebpf-allproxy` 只作实验。shared `socket_assign` 已于 2026-10-31 A/B 通过
> （HANDOVER §35.6），但生产未切换，是否切换需另行批准。

`sing-box.sh` 已按配置内容自动识别模式：`grep '"type": "ebpf"'`。
eBPF 模式下 `verify_core` 不再要求 `sbtun0`（反而要求它不存在，避免双捕获），
`start` 跳过 `singbox-capture-flush.sh`（无 TUN 重定向，无需清 conntrack），
`status` 多一行 `in: ebpf (...)`。

**eBPF 下三卡分流（2026-10-31 起不再是降级）**：`singbox-wan-balance.sh` 先读 config 里的
`route.default_mark`。eBPF 全代理档由 `convert.py` 写 `8228`（`0x2024`），core 给每个代理
出站包打标 → nft `meta mark == 0x2024` 命中 → jhash 选卡链生效，`status` 显示
`source: default`。TUN 档**不能**写 `default_mark`（与 `auto_redirect` 自己打的标记冲突），
它读 `auto_route` 的 fwmark 规则（`source: rule`）。只有配置里既没有 `default_mark`、
也读不到 auto_route 规则时才会 `source: ebpf|fallback` 并告警 —— 那时才是 no-op。
**但这不等于 eBPF 已上生产**：`shared.packet_rewrite` 仍卡 LAN TCP（HANDOVER §31.1、§35.6），
带该平面的 eBPF 全代理档只用于隔离实验；`socket_assign` 已通过本轮 A/B，但**生产仍未切换**，
当前生产口径是 `tun-allproxy`。

回滚（两条路，**都要先过 `sing-box check`**；`backup-config.sh restore` 自己也跑 check，
失败会把 pre-restore 配置放回）：

```sh
# 首选：相位备份 + md5 校验 + 原子替换 + check
sh /data/sing-box/backup-config.sh list
sh /data/sing-box/backup-config.sh restore tun        # 回生产 TUN all-proxy 档
sh /data/sing-box/backup-config.sh rescue             # 不确定时：tun → phase0 → original

# 手工：deploy 的相位备份
cp /data/sing-box/config.json.bak-<utc> /data/sing-box/config.json
cd /data/sing-box && ./sing-box check -c config.json && sh /data/sing-box/sing-box.sh restart
# 确认 sbtun0 重新出现、status 回到 tun:
```

## 捕获覆盖（谁走代理、谁不走）

| 流量 | 是否进内核 |
|---|---|
| IPv4 TCP / UDP（公网） | 是（`nft ... redirect` / `queue`，LAN/私网除外） |
| DNS（UDP/TCP 53、DoH） | 是：`hijack-dns` 接管查询，`ali`/`ali2` 带 `detour: 🚀 免流模式`；唯一例外是 `bootstrap`（udp `223.5.5.5`，解析节点域名，见 §32.3） |
| IPv6 任意真实地址 | 是（`route_address: ["::/0"]`；LAN 前缀由 `inet6_local_address_set` return，`ff00::/8` 显式排除） |
| IPv6 fake-ip 段 | 是 |
| 目的为 LAN / 私网 / ULA / link-local / 组播 | 否（有意，管理面 `192.168.0.1` 也在这一档） |
| ICMP / MPTCP / 非 TCP-UDP | 否（ICMP 内核应答，MPTCP 显式 drop） |
| `DIRECT` 规则 | all-proxy 档只剩 2 条（`private-domain` / `private-ip`）。**旧档的 21 条**（PT tracker 11 / 连通性探测 5 / UDP:53 / private 等）已于 2026-10-31 取消（HANDOVER §32） |

**停机期间的连接**：透明代理是 NAT 型捕获，NAT 只在建连时生效。代理停着时建立的
连接在重开后仍会直连（面板无速度），所以 `sing-box.sh start` 会调用
`singbox-capture-flush.sh`，删除「公网目的且 ct mark 未带 0x2000 位」的 conntrack
条目，让它们失败重连并重新进代理。只在冷启动执行，`start` 时 core 已在跑则跳过。

## 控制面板

设备 `/data/sing-box/ui` 已替换为 **Zashboard**（Clash 面板），旧 YACD
备份在 `/data/sing-box/ui-yacd-bak`。Zashboard 默认同源请求 API：

- 生产：`http://192.168.0.1:9999/ui/`
- lab：`adb forward tcp:9095 tcp:9095` 后 `http://127.0.0.1:9095/ui/`
- 重装：`sh singbox/install-ui.sh`（旧 UI 备份为 `ui-backup-*`）

原生 WebUI 里另有服务启停页 **`#singbox_manager`**（
`http://192.168.0.1/#singbox_manager`）：状态、启动/停止/重启、配置检查、
日志、sing-box ↔ mihomo 引擎切换。Zashboard 管节点/分流，该页管进程与
TUN/DHCP，二者不重叠。安装与卸载见
[`../singbox-manager/README.md`](../singbox-manager/README.md)。

## 免流 / 分流 / 直连

**all-proxy（免流）档 = `tun-allproxy` / `ebpf-allproxy` / `ebpf-local-*`（2026-10-31 零直连口径）**：

- `route.final = 🚀 免流模式`；`🎯 国内总模式`、`🌍 国外总模式`、`🐟 漏网之鱼` 默认都是
  `🚀 免流模式`，`🚀 专线机场` 默认 `⚡ 专线机场·自动选择`。
- **没有任何直连出口**：`🚀 免流模式` 的成员里没有 `DIRECT`，`🟢 直连模式` 组在 all-proxy
  档**不生成**、也不在 `🎯/🌍/🐟` 的成员列表里 —— 面板上点不出直连。
- **允许离开数据面的只有 LAN/私网与管理面**：`private-domain` / `private-ip` 规则集、
  `route_exclude_address`（`192.168.0.0/16`、`10.0.0.0/8`、`172.16.0.0/12`、
  `169.254.0.0/16`、`fd00:5252:0:1::/64`、`fe80::/10`、`ff00::/8`）与管理面
  `192.168.0.1`（WebUI/WebSSH/Zashboard/sshd，靠 `bypass_private_address`）。
- DNS 也是流量：DoH 走 `detour`；`bootstrap`（解析节点域名那一跳）是唯一结构性例外，
  保持 udp `223.5.5.5` 直连（中转方案真机 400 已回滚，见上）。
- 规则保留 `GEOIP/GEOSITE`、IPv4+IPv6、TCP+UDP；国内 UDP 走 `🇨🇳 国内udp`。
  **不要**用 `ipv4_only` DNS / 屏蔽 AAAA 来"解决" IPv6（见下「IPv6」）。

历史档（`base` / `observability` / `ebpf-local` / `ebpf-full`）**不满足**这套口径：
`🌍 国外总模式` 默认 `⚡ ALL·国外延迟最低`，`🟢 直连模式` 仍在组里，`bootstrap` 仍是
udp 直连 `223.5.5.5`。只用于回滚/取证，不要当生产。

**IPv6**：域名流量靠 `AAAA → fake-ip`（前排规则）拿 fake-ip v6 出站，出站带域名、
节点用自己的 v4 出口解析 → v6 客户端也被代理，不需要节点有 v6 出口。
**纯 v6 字面量**（`[2606:...]` 这种 IP 直连）没有任何 v6 出口节点，会失败 ——
那是"没有可用出口"，不是直连泄漏。`⚡ IPv6·自动选择` 仍为空（机场 v6 节点不稳）。
禁止写 `ipv4_only`、禁止封禁 v6。

## 注意

- `generated/providers/`、`generated/providers.conf`、`.cache/` 含订阅地址或
  节点凭据，已被 `.gitignore` 忽略，勿公开。
- 全部 8 个订阅都保留在配置中；`1.中国国际机场`、`7.奶昔机场` 当前是占位节点 `订阅暂不可用`（选中会失败）；`3.桃花源` 最近一次生成已恢复；
  `update-providers.sh` 会在订阅恢复后自动替换。
- **provider 9 = `9.CG`（原 `9.新订阅`/`9.mly`；快照仍为 `providers/p8.json`，索引 8），
  按用户决定进入所有带 `use:` 的组（39 个）**。fork 的 `include`/`exclude` 匹配
  `provider/node` 组合 tag，所以 tag 本身不能带地区/垃圾词：`9.CG` 对全部正则零碰撞，
  成员只由节点名决定 → `⚖️ ALL·国外负载均衡` 129 人（20 个国外节点、0 CN、0 占位）、
  `⚖️ ALL·国内负载均衡` 30 人（17 + 13 个 `CN-` 免流节点）、21 个 service/manual selector
  各 +33（20 国外 + 13 CN）、`🛒 淘宝` +8、`🇨🇳 国内节点·手动` +13、`🌍 ALL·其它地区` 47
  （其 url-test 当前选中 `2.快跑/CN北京LTˇ⁴A-x1`，属既有 CN 污染）。**分隔符守卫**：两个
  `-----VIP…-----` 占位不匹配任何黑名单，因此在会接纳它们的 29 个组的 filter 负向前瞻末尾
  追加 `|-----`（顺带滤掉 `3.桃花源/-----以下为国际区-----` 等同类分隔符）；信息节点本身
  含 `剩余/到期/官网/群/订阅` 已被各 filter 排除，实测全组 0 分隔符、0 信息节点。
  **`x` 误挡已修**：`⚡ ALL·国内延迟最低`/`🔀 ALL·国内故障转移`/`🇨🇳 国内udp` 的 exclude
  里那个裸 `x` 只挡住了合法 CN 节点（6 个 `2.快跑/*-x1|-x0.8` + 13 个 p9 `CN-*`，
  实测无垃圾/境外节点），与同族 `⚖️ ALL·国内负载均衡` 本已收录的行为矛盾，故直接删除该
  token：三组 10/10/14 → **29/29/33**，各含 13 个 p9 CN 节点，0 分隔符。
  `🌐 nasipv6` 只要 v6 节点，p9 无 v6 → 仍为 0。
- 生产已 switchover + install-boot + reboot 终验；UDP 非 DNS、mwan3、rollback 仍待补测。
