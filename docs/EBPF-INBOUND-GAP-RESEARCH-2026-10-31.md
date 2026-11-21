# sing-box eBPF 入站实现与 B20 项目差距调研

> 调研日期：2026-10-31  
> 范围：只读对照新 eBPF 入站说明、CHIZI-0618/sing-box 分支文档、本仓库代码和已有 B20 设备记录。此报告与原文快照不代表对功能实现、设备配置或生产切换的授权。
>
> 原文快照：[ebpf-inbound-2026-10-31.md](assets/ebpf-inbound-2026-10-31.md)。

## 结论

项目已经把 eBPF 接入配置生成、只读预检、运行态诊断和回滚工具；`local cgroup` 在设备上通过过预检，`shared packet_rewrite` 也曾真实挂载。但 B20 上的 `shared.packet_rewrite` 曾间歇性卡住 LAN TCP，表现为 PC 侧访问全失败、ClientHello 重传、sing-box 没有对应连接对象。eBPF 因此仍是实验配置，生产路径保持 TUN all-proxy。`socket_assign` 是值得优先核实的备选路径，目前没有 B20 shared 实际流量结果。

新文档应作为功能盘点入口，不应直接替代本仓库的设备证据。尤其要区分“内核能力预检通过”“运行时 attachment 已建立”和“LAN 客户端流量完整代理成功”，三者不是同一验收结论。

## 资料与证据口径

- **原文**：用户提供的 `ebpf-inbound.md`，见原文快照。本文提到的功能是该说明对测试分支的描述。
- **上游分支文档**：[eBPF inbound 配置说明](https://github.com/CHIZI-0618/sing-box/blob/ebpf-inbound/docs/configuration/inbound/ebpf.zh.md)、[内核要求](https://github.com/CHIZI-0618/sing-box/blob/ebpf-inbound/docs/manual/misc/ebpf-kernel-requirements.md)、[问题排查](https://github.com/CHIZI-0618/sing-box/blob/ebpf-inbound/docs/manual/misc/ebpf-troubleshooting.md)。链接指向可变分支，报告日期之后内容可能变化。
- **设备事实**：私人交接文档（未公开发布） §30–§32、`docs/diagnostics/ebpf-probe-20261030T041538Z/`、`tmp/huya-ebpf/ebpf-diag.json`。一次性快照不能代表持续运行或现网状态。
- **仓库实现**：`singbox/convert.py`、`singbox/verify-ebpf.sh`、`singbox/ebpf-probe.sh`、`singbox/sing-box.sh`、`singbox/ebpf-fragment-guard.sh`、相关测试与生成配置。

## 上游说明的实现面

说明把入站分为本机 `local` 与下游 `shared` 两个 scope，可独立或组合启用。核心数据面是 local `cgroup`/`tc`，shared `packet_rewrite`/`socket_assign`。其余主要能力包括 TCP/UDP 和双栈、UID/Android 用户/包名策略、shared 来源 CIDR/MAC 筛选、端口与地址/规则集绕过、DNS 模式、FakeIP ICMP 回复、socket cookie 自绕过、owner tracker、接口和 attachment 自动恢复、`bypass_rule_set` 事务更新、TCX/clsact 选择、cgroup 多程序挂载及按实例资源清理。

这些能力不是一个单一开关。配置字段存在不等于当前生成器使用它们；内核对象能加载也不等于真实 attach；运行状态显示 attachment 也不等于用户流量经过代理。

## 项目差距矩阵

| 领域 | 项目现状与证据 | 差距/判断 |
|---|---|---|
| 生产状态 | 私人工作笔记（未公开发布） 和 HANDOVER §31–§32 记载生产使用 `tun-allproxy`；eBPF shared 仅供隔离实验。 | eBPF 全代理路径尚未满足 B20 的生产验收条件。 |
| local/shared 组合 | `convert.py:1100-1204` 生成 local `cgroup` 与 shared `br-lan`；all-proxy 档明确开启两者。 | 本地生成器没有 local 数据面选择；`verify-ebpf.sh` 也要求 local 为 `cgroup`。 |
| local 数据面命名 | 设备版本记录为 sing-box `1.14.4-reF1nd` / commit `732618a`。对应 schema 快照 `tmp/tg-e58695/schema.json` 接受 `cgroup`、`socket_assign`，不含 `tc`；该版本文档明确旧 local `tc` 必须改用 `socket_assign`。 | 用户提供的说明写 `local.data_plane: tc`，与同分支详细文档及设备版本 schema 有差异。新分支文档也把本轮变化标为 1.15.0；需先对齐 commit、schema、二进制再讨论该字段。 |
| `local cgroup` | 2026-10-30 设备预检通过；一次真实运行态快照报告 cgroup attachment `link_create`。 | 已有本机路径证据，但无法替代 shared LAN 转发验收，也未覆盖长期恢复和资源回收。 |
| `shared.packet_rewrite` | `br-lan` 预检通过，探测记录接口帧为 Ethernet；真实运行曾建立 `clsact` attachment。HANDOVER §31.1 记录 LAN TCP 间歇失败、ClientHello 重传和 sing-box active/recent 无连接。 | 当前首要阻塞。上游通用能力说明未提及这次 B20 实测故障，必须以 B20 复现和对照结果为准。 |
| `shared.socket_assign` | 转换器允许 `--ebpf-shared-data-plane socket_assign`，生成器测试只比较输出结构；预检脚本有该模式探测。归档设备探测结果只有 local socket_assign，没有 shared socket_assign 结果。 | 尚无 shared socket_assign 的设备预检、真实挂载和 TCP/UDP 用户流量证明。不能把配置可生成视为方案可用。 |
| local `socket_assign` | 归档预检 `local-socket-assign.json` 显示对象预检通过；脚本明确预检只加载并关闭对象，不挂载程序。 | 只证实该次预检的内核对象加载，不证实服务 attach 或流量行为。 |
| TCP/UDP、IPv6 | eBPF 配置声明 TCP/UDP；local/shared 均显式 `ipv6: true`。历史 eBPF-full 曾观察到 PC IPv6 网站成功，随后 shared 路径出现不稳定。 | IPv6 一次成功观察不是持续验收。需要按 TCP、UDP、IPv4、IPv6 和 LAN/本机 scope 分开记录。纯 IPv6 字面量出口限制及 fake-ip AAAA 顺序仍按 HANDOVER §32.4 评估。 |
| 用户/来源筛选 | 生成配置未设置 UID、UID range、Android 用户/包名、来源 CIDR 或 MAC 条件。项目目标为路由器全局流量代理。 | 上游提供的选择能力目前未被项目配置使用；这是未采用的能力，不应误报为设备故障。若后续有隔离需求，再单独验证字段语义。 |
| DNS 模式 | 生成器对 local 使用 `respect_policy`，对 shared 使用 `hijack`；all-proxy 的 DNS detour、bootstrap 例外与 AAAA fake-ip 由配置层处理。 | 入站 DNS 模式只针对普通 TCP/UDP 53，不代表 DoH/DoT 已被识别；需保持和 §32 的 DNS 全代理口径分开验收。 |
| 地址/规则集绕过 | 当前使用 `bypass_private_address`；all-proxy shared `bypass_port` 为空。配置中没有 `bypass_exclude` 或 `bypass_rule_set`。运行态快照的 shared rule-set 状态为 `known: false`。 | 上游规则集运行时事务更新能力尚未被本项目实际使用或验证。项目的 `ebpf-fragment-guard.sh` 是独立 nft 防泄漏守卫，不等同于 eBPF `bypass_rule_set`。 |
| FakeIP ICMP | 生成配置不写 `fakeip_icmp`；运行态快照 `fakeIPICMPReply=false`。 | 未启用/未验收。FakeIP ping 是否需要回复与目标业务分开确认；ICMP Echo 回复不证明映射目标连通。 |
| 分片处理 | 上游说明指出 IPv4 分片和非 atomic IPv6 分片绕过 eBPF 接管。项目自有 fragment guard 在 shared 模式下对公网分片 fail-closed 丢弃，`sing-box.sh` 启动和 `verify-ebpf.sh` 检查该表。 | 这是项目对“绕过会形成公网直连”的额外防护，不是上游入站已代理分片。需区分守卫规则存在与真实分片端到端行为；当前资料未给出完整真机分片验收。 |
| 默认接口/恢复 | 生成配置固定 `br-lan`；项目有 15 秒 sing-box watchdog、API 快照和异常诊断。 | watchdog 重启 core 不等于上游运行时对接口新建/删除、TC attachment 丢失和策略热更新的自动协调。B20 对这些状态变化的行为尚缺对照记录。 |
| TCX、clsact、cgroup attach | 一次运行态快照见 shared `br-lan` 使用 `clsact`，local cgroup 为 `link_create`。上游说明称 TCX 可用时优先，否则 clsact。 | 已知实际选择的是 clsact；现有证据没有解释 TCX 是否被内核拒绝/不支持，也没有独立验证 multi-attach 与后来者 netd/其他 hook 竞争。 |
| API 与诊断端点 | 项目配置 `services.api` loopback `127.0.0.1:8088`，脚本调用 `sing-box api ebpf --url ...`；Clash API/observability 在 9999。运行态快照 `schemaVersion: 18`。 | 用户提供文档的 `curl http://127.0.0.1:9090/ebpf` HTTP 示例，不是本仓库当前采用的诊断调用方式。不要照搬端口或把 Clash API 与 gRPC 诊断 API 混为一谈。 |
| 内核 LPM 风险 | B20 记录内核 `5.15.194-perf`，不是上游说明的 6.6.0–6.6.46 区间。现存探测报告的 LPM 项注明“当前没有需更新的 UID/应用/CIDR 策略”。 | 该 6.6 缺陷按版本区间不适用于已记录 B20 内核；当前空策略预检也没有实测非空 LPM 更新。后续若新增 UID/CIDR/规则集策略，应重新查目标二进制保护逻辑和具体内核。 |
| 三卡分流 | 生成器对 eBPF 档写 `route.default_mark = 8228`，`singbox-wan-balance.sh` 以此接入 jhash；TUN 档不写该字段。 | 这是代码/生成配置层的现行契约。此前 eBPF-full 实测时期未带该字段；尚无当前 eBPF 配置、实际 mark 和三卡计数完整闭环的新运行记录。 |
| 停止与资源归属 | 项目 `sing-box.sh` 管理 guard、core 和 WAN balance；上游声称只清理自身持有资源。 | 现有记录证明启动和 attachment，不足以证明多实例/接口重建/异常退出后只清除本实例资源。维护窗口内需要收集 stop 前后 TC、路由、veth 和 map 归属证据。 |

## 优先级调研分题

这些是后续按关键词分派的研究任务，不是本次代码改动清单。

| 顺序 | 主题关键词 | 要回答的问题 | 现有证据入口 |
|---|---|---|---|
| P0 | `packet_rewrite`, `ClientHello retransmission`, `rewriteFailures`, `tcAssignmentSweep`, `checksum/offload` | B20 LAN TCP 卡死发生在哪个阶段？重启漂移与 TC ingress/egress、回复地址恢复、校验和/offload、conntrack 或资源回收是否相关？如何构造能区分它们的单变量复现？ | HANDOVER §31.1；`tmp/huya-ebpf/ebpf-diag.json`；`singbox/diagnose-stall.sh`；`singbox/ebpf-snapshot.sh` |
| P1 | `socket_assign`, `shared socket assignment`, `bpf_sk_assign`, `raw-IP` | B20 的 shared socket_assign 能否通过预检、真实 attach，并在相同 br-lan 客户端流量下稳定代理 TCP 与 UDP？它是否消除 packet_rewrite 卡顿？ | `singbox/convert.py --ebpf-shared-data-plane`；`singbox/ebpf-probe.sh`；现有归档只有 local socket_assign 预检 |
| P1 | `732618a`, `1.14.4`, `1.15.0`, `local tc`, `schemaVersion`, `diagnostics API` | 用户提供的 local `tc` 和 HTTP `:9090/ebpf` 与当前分支详细文档、设备 schema、项目 `127.0.0.1:8088` API 的差异分别来自版本、文档快照还是实现变更？哪些配置字段能被设备二进制接受？ | `tmp/tg-e58695/ebpf-inbound-doc.md`；`tmp/tg-e58695/schema.json`；上游分支 eBPF 配置文档；`singbox/convert.py:1471-1481` |
| P1 | `fragment`, `IPv4 MF`, `IPv6 atomic`, `fragment guard` | 当前 nft 守卫能否覆盖所有实际下游入口和分片类型？规则启停窗口、IPv6 扩展头和 guard 失败路径是否保持 fail-closed？ | `singbox/ebpf-fragment-guard.sh`；`singbox/verify-ebpf.sh`；`docs/WAN-BALANCE-EBPF-COMPAT-2026-10-31.md` |
| P2 | `bypass_rule_set`, `LPM trie`, `transactional update`, `rollback` | 当前设备版本的规则集更新是否具备与新分支说明相同的事务/回滚语义？非空 CIDR policy 更新在 5.15 B20 上如何安全验证？ | `tmp/huya-ebpf/ebpf-diag.json` 的 `sharedBypassRuleSet.known=false`；`docs/diagnostics/ebpf-probe-20261030T041538Z/` |
| P2 | `TCX`, `clsact`, `BPF_F_ALLOW_MULTI`, `netd`, `attachment recovery` | B20 实际 attach 选择为何为 clsact/link_create？TCX、multi-attach 和并发 hook 的可用性是什么？接口消失/重建后 core 内部恢复与外部 watchdog 各负责哪一层？ | `tmp/huya-ebpf/ebpf-diag.json`；`singbox/ebpf-probe.sh`；上游内核要求与问题排查文档 |
| P2 | `fakeip_icmp`, `UID/package`, `source CIDR/MAC`, `DNS precedence` | 项目是否确实需要这些上游能力？若需要，设备上的配置 schema、筛选优先级、共享 UID 局限和零公网直连约束如何影响行为？ | `tmp/tg-e58695/schema.json`；`singbox/convert.py:1167-1204`；上游 eBPF 字段说明 |
| P2 | `default_mark`, `mwan3`, `eBPF all-proxy`, `IPv6 WAN` | 新生成配置的 mark 是否在设备 eBPF 运行态被 core 施加并命中 jhash？IPv4 三卡比例、IPv6 仅 5G 的出口限制、DNS bootstrap 例外是否分别有证据？ | 私人交接文档（未公开发布） §32.3–§32.5；`docs/WAN-BALANCE-EBPF-COMPAT-2026-10-31.md`；`singbox/verify-ebpf.sh` |

## 后续证据要求

后续调研应对每个主张标明证据属于配置/schema、对象预检、真实 attachment、单流行为、并发/长稳或重启恢复哪一层。涉及 LAN 的行为必须由 `br-lan` 客户端实测；本机 `curl`、`sing-box check`、对象加载预检、API attachment 列表都不能单独证明 LAN 转发成功。任何实验记录需保留当前 TUN all-proxy 基线、前后配置校验值、复现的 TCP/UDP 与 IPv4/IPv6 结果、诊断 API 快照和三卡接口计数。

## 本次边界

本次只新增了原文快照与调研报告。没有改动已有项目文档、代码、生成配置或设备；没有部署 eBPF、执行设备流量实验或运行测试套件。
