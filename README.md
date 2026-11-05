# TopFlow Toolkit — `feat/touchui-singbox-wanbal`

> Fork of [`imshuhao/topflow-toolkit`](https://github.com/imshuhao/topflow-toolkit)  
> 本分支主讲 **两块自研改动**：① **UTC 墙钟 / UTC+8 显示** ② **Sing-box 触控 + 质量感知三卡分流**  
> 上游 README 里的 Mihomo netns、LuCI、聚合、完整截图集等——**本分支未改其逻辑**，请看 [上游 main](https://github.com/imshuhao/topflow-toolkit/blob/main/README.md)。

<p align="center">
  <img src="https://img.shields.io/badge/fork-imshuhao%2Ftopflow--toolkit-238636?style=flat-square&labelColor=0b0f0d" alt="Fork of imshuhao/topflow-toolkit">
  <img src="https://img.shields.io/badge/branch-feat%2Ftouchui--singbox--wanbal-238636?style=flat-square&labelColor=0b0f0d" alt="feat/touchui-singbox-wanbal">
  <img src="https://img.shields.io/badge/target-TopFlow%20MU5252%20B20-238636?style=flat-square&labelColor=0b0f0d" alt="Target MU5252 B20">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-238636?style=flat-square&labelColor=0b0f0d" alt="MIT License"></a>
</p>

## 本分支改了什么（总览）

| 主题 | 一句话 |
| --- | --- |
| [墙钟与时区](#1-utc-墙钟--utc8-显示) | 系统时钟必须是真实 UTC；北京时间只用 `CST-8` 显示。修掉「UTC+8 写进 epoch」导致代理全挂 |
| [Sing-box 触控](#2-sing-box-触控页) | 控制中心原 Mihomo 页换成 Sing-box 启停/数据面 |
| [分流](#3-分流质量感知三卡选卡) | 新增「分流」横条：自动·质量 / 三卡共池；弱网可溢出，不做协议硬绑死 |

**明确未改：** `mihomo-netns`、`mihomo-manager`、`luci-admin`、`mwan3-tuning`、`web-full-menu`、`vendor-control`、`zwrt-datad-tools` 等原作模块——介绍与安装以上游为准。

---

## 1. UTC 墙钟 / UTC+8 显示

### 问题

B20 上原厂 `ntpclient` / `zte_topsw_ntp`（以及未打补丁的 NITZ 路径）会把 **「本地 UTC+8」当成 Unix 时间写进系统时钟**。  
表现：`date -u` 比真实 UTC 快约 8 小时 → TLS/VMess 等集体失败。  
这和「界面显示北京时间」不是一回事：**显示用 TZ，墙钟必须是 UTC epoch**。

现场纪要：[`docs/TIMEZONE-FIX-2026-09-08.md`](docs/TIMEZONE-FIX-2026-09-08.md)。

### 做法（分层）

| 层 | 作用 | 落点 |
| --- | --- | --- |
| 源头止血 | 对已审核哈希的 ntpclient / nwinfo 做 UTC 兼容补丁（设备上 bind-mount，**不分发原厂二进制**） | [`timekeeper/`](timekeeper/) |
| 显示 | `apply-timezone` → POSIX `CST-8` + TZif；**只改显示，不改 epoch** | `timekeeper.sh` |
| 触屏 | 启动 `zte_topsw_devui` 时注入 `TZ=CST-8` | [`touchscreen-control-center/start.sh`](touchscreen-control-center/start.sh) |
| 安全网 | HTTP Date 校时 + 持续守卫；直连失败可走 `127.0.0.1:7890` 取 Date，打破「钟偏 → 代理挂 → 取不到时间」死锁 | [`timekeeper/fix-time-http.sh`](timekeeper/fix-time-http.sh) |

`fix-time-http.sh` 内部强制 `TZ=UTC` 再解析 HTTP `Date`，避免系统已是 `CST-8` 时 busybox 把 GMT 头再减 8 小时。

### 不要做的事

- 只装 UTC+8 时区文件、不修 ntpclient → 显示再 +8h，错误 epoch 还会进 time base。  
- 仓库不提交厂商 NTP/NITZ 二进制或订阅/节点信息。

---

## 2. Sing-box 触控页

- 控制中心菜单：**网络仪表 → Sing-box → 分流 → 设备状态**（Sing-box 替换原 Mihomo 项）。  
- 启停/状态/数据面走 [`singbox-manager/`](singbox-manager/) 固定子命令。  
- eBPF `socket_assign` 下无 `sbtun0` 为正常（角标「eBPF 模式」）。

详见 [`touchscreen-control-center/README.md`](touchscreen-control-center/README.md)。

---

## 3. 分流：质量感知三卡选卡

宿主 sing-box 出站带 `SO_MARK 0x2024` 后，mwan3 会跳过这些包；[`singbox/singbox-wan-balance.sh`](singbox/singbox-wan-balance.sh) 用 `tf-sbwan` jhash 按权重把**代理出站**分到在线蜂窝卡。

| 预设 | 行为 |
| --- | --- |
| **自动·质量** | 三卡共池 + 质量降权（mwan3 `LATENCY_*`/`LOSS_*`，可选 5G `radio.snap` RSRP）+ TCP 偏 5G / UDP 偏 4G **软偏置**；弱网可溢出 |
| **三卡共池** | 强制共池；仍质量降权；无软偏置 |

粘连接只影响**新连接**；约 15s 重算。示例配置：[`singbox/wan-balance.conf.example`](singbox/wan-balance.conf.example)。

```sh
sh /data/sing-box/singbox-wan-balance.sh preset-set auto
sh /data/sing-box/singbox-wan-balance.sh preset-get
sh singbox/tests/test_wan_balance_render.sh
```

---

## 本分支新增 / 改动的路径

| 路径 | 角色 |
| --- | --- |
| [`docs/TIMEZONE-FIX-2026-09-08.md`](docs/TIMEZONE-FIX-2026-09-08.md) | UTC+8 写钟问题实机纪要 |
| [`timekeeper/fix-time-http.*`](timekeeper/) | HTTP Date 校时守卫 |
| [`timekeeper/`](timekeeper/)（README 等） | UTC 补丁 + `CST-8` 显示口径（B20） |
| [`touchscreen-control-center/`](touchscreen-control-center/) | Sing-box / 分流页；`TZ=CST-8` |
| [`singbox/`](singbox/) | WAN 均衡脚本 + 示例 + 测试 |
| [`singbox-manager/`](singbox-manager/) | 管理脚本与 `wan-mode-*` |

## 脱敏

- 只留 `.example` 与公开脚本；无订阅、UUID、个人域名、设备口令。  
- 不分发厂商二进制、`touchui-hook.so`、HANDOVER/抓包取证、generated 生产配置。

## 建议验证

```sh
# 墙钟
date -u   # 应接近真实 UTC，而不是「本地北京时间的数字」
# 触屏环境应含 TZ=CST-8（显示北京时间）

# 分流 / 触控
sh singbox/tests/test_wan_balance_render.sh
# 部署 touchui-hook.so 后菜单：网络仪表 / Sing-box / 分流 / 设备状态
sh /data/singbox-manager/singbox-manager.sh wan-mode-set auto
```

## 与上游

| | |
| --- | --- |
| 上游 | [imshuhao/topflow-toolkit](https://github.com/imshuhao/topflow-toolkit) |
| 本 fork | [shizongrengkou/topflow-toolkit](https://github.com/shizongrengkou/topflow-toolkit) |
| PR | [#2](https://github.com/imshuhao/topflow-toolkit/pull/2) |
| 原作完整介绍 | 上游 `main` README（本分支不重复展开） |

本项目不是 ZTE、sing-box、Mihomo 或任何运营商的官方项目。
