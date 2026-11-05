# TopFlow Toolkit — `feat/touchui-singbox-wanbal`

> Fork of [`imshuhao/topflow-toolkit`](https://github.com/imshuhao/topflow-toolkit)  
> Branch focus: **touchscreen Sing-box controls + quality-aware three-card WAN balance**  
> Upstream README still describes Mihomo / LuCI / netns 等原作能力；**那些模块本分支未改逻辑**，请以上游 `main` 为准。

<p align="center">
  <img src="https://img.shields.io/badge/fork-imshuhao%2Ftopflow--toolkit-238636?style=flat-square&labelColor=0b0f0d" alt="Fork of imshuhao/topflow-toolkit">
  <img src="https://img.shields.io/badge/branch-feat%2Ftouchui--singbox--wanbal-238636?style=flat-square&labelColor=0b0f0d" alt="feat/touchui-singbox-wanbal">
  <img src="https://img.shields.io/badge/target-TopFlow%20MU5252-238636?style=flat-square&labelColor=0b0f0d" alt="Target MU5252">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-238636?style=flat-square&labelColor=0b0f0d" alt="MIT License"></a>
</p>

## 本分支改了什么

在原作触屏控制中心（`LD_PRELOAD` 扩展 `zte_topsw_devui`）上，把代理触控从 **Mihomo 换成 Sing-box**，并增加三卡 **质量感知分流**：

| 改动 | 说明 |
| --- | --- |
| 触屏 **Sing-box** 页 | 替换原「Mihomo」菜单项；启停 / 状态 / 数据面（TUN 或 eBPF `socket_assign`） |
| 触屏 **分流** 页（新） | 控制中心里新增横条；两档可切，不做「TCP 只 5G / UDP 只 4G」硬绑为唯一模式 |
| [`singbox/`](singbox/) | 宿主模式 `singbox-wan-balance.sh`：jhash 选卡、质量降权、软偏置、离线测试 |
| [`singbox-manager/`](singbox-manager/) | WebUI `#singbox_manager` + 触屏调用的固定子命令（含 `wan-mode-*`） |

**没有改、也不在本分支介绍范围内的原作内容：**  
`mihomo-netns`、`mihomo-manager`、`luci-admin`、`mwan3-tuning`、`web-full-menu`、`vendor-control`、`timekeeper`、`zwrt-datad-tools` 等——请直接看 [上游 README](https://github.com/imshuhao/topflow-toolkit/blob/main/README.md)。

## 分流功能（本分支重点）

控制中心菜单顺序（本分支）：

```text
控制中心
├── 网络仪表          ← 原作（本分支未改其数据源口径）
├── Sing-box          ← 本分支：替换 Mihomo 页
├── 分流              ← 本分支新增
│   ├── 自动·质量
│   └── 三卡共池
└── 设备状态          ← 原作能力保留
```

### 自动·质量（推荐）

1. **共池**：5G + 双 4G 都在 TCP/UDP 候选里（弱网时可互相溢出）。  
2. **质量降权**：读 mwan3track 最大 `LATENCY_*` / `LOSS_*`；可选 `/data/local/weaknet/radio.snap` 的 5G `rsrp=`。  
   - 进弱：延迟 ≥600 ms 或丢包 ≥30%（滞后退出更松）。  
   - 弱卡权重 ×15%（至少 1）；极差可暂时出池。  
3. **软偏置**：健康时 TCP 偏 5G、UDP 偏 4G——用权重表达「偏爱」，不用空池表达「禁止」。  
4. **粘连接**：只影响**新连接**；约 15 s 看门狗重算。

### 三卡共池

强制 TCP+UDP 同一套三卡池；**仍做质量降权**，但关闭协议软偏置。

### CLI

```sh
sh /data/sing-box/singbox-wan-balance.sh preset-set auto
sh /data/sing-box/singbox-wan-balance.sh preset-set shared
sh /data/sing-box/singbox-wan-balance.sh preset-get   # weights / degraded
sh singbox/tests/test_wan_balance_render.sh           # 离线
```

示例配置：[`singbox/wan-balance.conf.example`](singbox/wan-balance.conf.example)（无订阅、无节点密钥）。

## Sing-box 触控页

- 调用 [`singbox-manager/singbox-manager.sh`](singbox-manager/singbox-manager.sh) 固定子命令：`status` / `service-start|stop|restart` 等。  
- 展示数据面：`capture_ok`、`inbound_mode`（eBPF 下无 `sbtun0` 为正常）。  
- 「分流」另调 `wan-mode-status` / `wan-mode-set`。

详见 [`touchscreen-control-center/README.md`](touchscreen-control-center/README.md)、[`singbox/README.md`](singbox/README.md)、[`singbox-manager/README.md`](singbox-manager/README.md)。

## 本分支新增 / 改动的组件

| 路径 | 本分支角色 |
| --- | --- |
| [`touchscreen-control-center/`](touchscreen-control-center/) | Sing-box 页 + 分流页；去掉 Mihomo 触控页 |
| [`singbox/`](singbox/) | WAN 均衡脚本 + 示例 + 测试 |
| [`singbox-manager/`](singbox-manager/) | 管理脚本 / WebUI 挂载 / `wan-mode-*` |

## 脱敏与不收录

- 只提交 `.example` 与公开脚本；**无**订阅 URL、节点 UUID、个人域名、设备口令。  
- **不**收录 HANDOVER、抓包取证、`singbox/generated/config.*.json`、真实 `wan-balance.conf`。  
- 不提交 `touchui-hook.so`（自行交叉编译）。

## 建议验证

```sh
sh singbox/tests/test_wan_balance_render.sh
# 设备：编译 touchui-hook.so 后部署
# 控制中心应见：网络仪表 / Sing-box / 分流 / 设备状态
sh /data/singbox-manager/singbox-manager.sh wan-mode-set auto
sh /data/sing-box/singbox-wan-balance.sh status
```

大流量时 `nft list chain ip tf-sbwan out` 的 4G 桶应上涨，且仅匹配 `mark 0x2024`（代理出站）。

## 与上游的关系

| | |
| --- | --- |
| 上游 | [imshuhao/topflow-toolkit](https://github.com/imshuhao/topflow-toolkit)（MIT，作者 Shuhao Dong） |
| 本 fork | [shizongrengkou/topflow-toolkit](https://github.com/shizongrengkou/topflow-toolkit) |
| PR | [#2](https://github.com/imshuhao/topflow-toolkit/pull/2) |
| 上游完整介绍 | 请打开上游 `main` 的 README（Mihomo netns、LuCI、聚合、截图集等） |

本项目不是 ZTE、sing-box、Mihomo 或任何运营商的官方项目。
