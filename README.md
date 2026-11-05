# TopFlow Toolkit — `feat/touchui-singbox-wanbal`

## 出处（原作者）

本仓库是 **[@imshuhao](https://github.com/imshuhao)** 的  
**[`imshuhao/topflow-toolkit`](https://github.com/imshuhao/topflow-toolkit)** 的 fork（MIT，`Copyright (c) 2026 imshuhao contributors`，见 [`LICENSE`](LICENSE)）。

- **原作完整说明、截图、Mihomo/LuCI/netns 安装：** 请先看上游  
  [main README](https://github.com/imshuhao/topflow-toolkit/blob/main/README.md)  
- **本分支额外致谢与第三方清单：** [`NOTICE.md`](NOTICE.md)

本分支只额外记录 **B20 现场自研改动**；未改动的上游模块版权与行为仍归原作。

---

> 分支主题：UTC 墙钟、Sing-box、分流触控、无线 ADB、WebSSH、弱网黑匣子、OTA 冻结、聚合切回恢复等。

<p align="center">
  <img src="https://img.shields.io/badge/based%20on-imshuhao%2Ftopflow--toolkit-238636?style=flat-square&labelColor=0b0f0d" alt="Based on imshuhao/topflow-toolkit">
  <img src="https://img.shields.io/badge/author-imshuhao-238636?style=flat-square&labelColor=0b0f0d" alt="Original author imshuhao">
  <img src="https://img.shields.io/badge/branch-feat%2Ftouchui--singbox--wanbal-238636?style=flat-square&labelColor=0b0f0d" alt="feat/touchui-singbox-wanbal">
  <img src="https://img.shields.io/badge/target-TopFlow%20MU5252%20B20-238636?style=flat-square&labelColor=0b0f0d" alt="Target MU5252 B20">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-238636?style=flat-square&labelColor=0b0f0d" alt="MIT License"></a>
</p>

## 本分支改了什么（总览）

| 主题 | 一句话 |
| --- | --- |
| [墙钟与时区](#1-utc-墙钟--utc8-显示) | 系统时钟必须是真实 UTC；北京时间只用 `CST-8` 显示 |
| [Sing-box](#2-sing-box-宿主栈) | Clash→sing-box 转换、eBPF/`socket_assign`、零直连档、部署与自愈脚本 |
| [触控](#3-sing-box-触控页) | 控制中心原 Mihomo 页换成 Sing-box 启停/数据面 |
| [分流](#4-分流质量感知三卡选卡) | 自动·质量 / 三卡共池；弱网可溢出，不做协议硬绑死 |
| [无线 ADB](#5-无线-adb-wrapper-v5) | TCP `15555` + USB 三合一；**永不隐藏 functionfs** |
| [WebSSH](#6-webssh-局域网终端) | `8899` + 内置 sshd `22622`；B20 ubus/三卡补丁 |
| [弱网黑匣子](#7-弱网黑匣子) | 设备自记 JSONL，手机经 WebSSH 出报告 |
| [OTA 冻结](#8-ota-冻结) | hosts + iptables 双保险，挡官方强推 |
| [mwan3 恢复](#9-聚合切回恢复) | `recover.sh` + cron：切回普通模式后把调优/分流拉回 |

**明确未改上游逻辑：** `mihomo-netns`、`mihomo-manager`、`luci-admin`、`web-full-menu`、`vendor-control`、`zwrt-datad-tools` 等——介绍与安装以上游为准。  
`mwan3-tuning/` 在上游基础上**追加**了 `recover.sh` / `install-mode-guard.sh`。

---

## 1. UTC 墙钟 / UTC+8 显示

B20 原厂 NTP/NITZ 路径会把「本地 UTC+8」写进 Unix 墙钟 → TLS/代理集体失败。  
显示用 `TZ=CST-8`，墙钟必须是真实 UTC epoch。纪要：[`docs/TIMEZONE-FIX-2026-09-08.md`](docs/TIMEZONE-FIX-2026-09-08.md)。

| 层 | 落点 |
| --- | --- |
| UTC 兼容补丁（bind-mount，不分发原厂二进制） | [`timekeeper/`](timekeeper/) |
| HTTP Date 校时守卫 | [`timekeeper/fix-time-http.sh`](timekeeper/fix-time-http.sh) |
| 触屏注入 `TZ=CST-8` | [`touchscreen-control-center/start.sh`](touchscreen-control-center/start.sh) |

---

## 2. Sing-box 宿主栈

从 Clash Meta 生成 sing-box 配置、部署、看门狗、DHCP 守卫、eBPF 探测/回滚、三卡 `tf-sbwan` 选卡。

| 路径 | 作用 |
| --- | --- |
| [`singbox/convert.py`](singbox/convert.py) | Clash → sing-box（含 all-proxy / eBPF profile） |
| [`singbox/sing-box.sh`](singbox/sing-box.sh) | 启停 / switchover / rollback |
| [`singbox/singbox-wan-balance.sh`](singbox/singbox-wan-balance.sh) | 三卡 jhash + 质量降权 + 软偏置 |
| [`singbox/deploy.sh`](singbox/deploy.sh) | 相位备份 → check → 原子落盘 |
| [`singbox-manager/`](singbox-manager/) | Web/触屏管理入口与 `wan-mode-*` |

面板惯例：**不设** `clash_api.secret`（空字符串）。  
`NAS_DDNS_SUFFIX` 在公开分支已换成 `example.invalid`，请按自家 DDNS 改。  
**不提交** `singbox/generated/`、订阅、UUID。

相关公开纪要：[`docs/SINGBOX-MIGRATION-PLAN-2026-10-27.md`](docs/SINGBOX-MIGRATION-PLAN-2026-10-27.md)、[`docs/WAN-BALANCE-EBPF-COMPAT-2026-10-31.md`](docs/WAN-BALANCE-EBPF-COMPAT-2026-10-31.md)、[`docs/IPV6-DUALSTACK-FIX-2026-10-31.md`](docs/IPV6-DUALSTACK-FIX-2026-10-31.md)、[`docs/EBPF-MIGRATION-ROLLBACK-2026-10-31.md`](docs/EBPF-MIGRATION-ROLLBACK-2026-10-31.md)。

---

## 3. Sing-box 触控页

菜单：**网络仪表 → Sing-box → 分流 → 设备状态**。  
详见 [`touchscreen-control-center/README.md`](touchscreen-control-center/README.md)。  
eBPF `socket_assign` 下无 `sbtun0` 为正常。

---

## 4. 分流：质量感知三卡选卡

宿主出站 `SO_MARK 0x2024` 后 mwan3 会跳过这些包；`singbox-wan-balance.sh` 按权重把**代理出站**分到在线蜂窝卡。

| 预设 | 行为 |
| --- | --- |
| **自动·质量** | 共池 + 质量降权（mwan3 延迟/丢包，可选 5G `radio.snap`）+ TCP/UDP 软偏置；弱网可溢出 |
| **三卡共池** | 强制共池；仍质量降权；无软偏置 |

```sh
sh /data/sing-box/singbox-wan-balance.sh preset-set auto
sh singbox/tests/test_wan_balance_render.sh
```

---

## 5. 无线 ADB（wrapper v5）

[`adb-wifi/`](adb-wifi/)：端口 **15555**，iptables 只放行 `lo`/`br-lan`。  
**永不重启 adbd、永不隐藏 `/dev/usb-ffs/adb`**。

USB 排障：[`docs/USB-ADB-DIAG-2026-10-30.md`](docs/USB-ADB-DIAG-2026-10-30.md)。

---

## 6. WebSSH（局域网终端）

[`webssh/`](webssh/)：浏览器终端 `http://192.168.0.1:8899/app` + 内置 sshd `192.168.0.1:22622`。

**出处：** [`o8oo8o/WebSSH`](https://github.com/o8oo8o/WebSSH) → [`kanoqwq/WebSSH-u60pro`](https://github.com/kanoqwq/WebSSH-u60pro)；本目录只放 B20 补丁与安装脚本，**不附带**完整源码树与 arm64 二进制（见 [`webssh/BUILD.md`](webssh/BUILD.md)、[`NOTICE.md`](NOTICE.md)）。

本机补丁要点：ubus `subid` 兼容、`GET /api/modems` 三卡、`start.sh` 强制 `-ConfigDir /data/webssh`。  
实机纪要：[`docs/WEBSSH-DEPLOY-2026-10-27.md`](docs/WEBSSH-DEPLOY-2026-10-27.md)。

---

## 7. 弱网黑匣子

[`weaknet/`](weaknet/)：设备自采 JSONL；手机连设备 Wi-Fi → WebSSH → `sh /data/local/weaknet/weaknet-report.sh`。

---

## 8. OTA 冻结

[`ota-block/`](ota-block/)：hosts + `TOPFLOW_OTA_BLOCK4/6` + rc.local 钩子。  
恢复官方升级：`ota-block.sh revert`。

---

## 9. 聚合切回恢复

[`mwan3-tuning/recover.sh`](mwan3-tuning/recover.sh) + [`install-mode-guard.sh`](mwan3-tuning/install-mode-guard.sh)：  
`SMULTIWAN`→`MULTIWAN` 后幂等重载调优与 wan-balance。

---

## 本分支路径一览

| 路径 | 角色 |
| --- | --- |
| `timekeeper/` | UTC 墙钟 + HTTP Date 守卫 |
| `touchscreen-control-center/` | Sing-box / 分流触控 |
| `singbox/`、`singbox-manager/` | 宿主栈与管理入口 |
| `adb-wifi/` | 无线 ADB wrapper v5 |
| `webssh/` | WebSSH 部署包装 + B20 补丁（第三方见 NOTICE） |
| `weaknet/` | 弱网自记录 |
| `ota-block/` | OTA / 上报域名冻结 |
| `mwan3-tuning/recover.sh` 等 | 聚合切回恢复 |
| `docs/*2026-*.md` | 公开技术纪要 |
| [`NOTICE.md`](NOTICE.md) | 原作者与第三方出处 |

## 脱敏 / 不推送

- 无订阅、UUID、个人域名、设备口令、真实 SSID、WebSSH 数据库。  
- 不分发厂商二进制、`touchui-hook.so`、私人交接全文、`singbox/generated/`、WebSSH arm64 成品。  
- `convert.py` 里 NAS DDNS 占位为 `example.invalid`。

## 建议验证

```sh
date -u
sh singbox/tests/test_wan_balance_render.sh
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.0.1:8899/app/   # 若已部署 WebSSH → 200
sh /data/local/weaknet/weaknet-report.sh                                 # 若已部署
sh /data/local/mwan3-tuning/recover.sh --verify                          # 若已部署
```

## 与上游

| | |
| --- | --- |
| **原作者 / 上游** | [@imshuhao](https://github.com/imshuhao) · [imshuhao/topflow-toolkit](https://github.com/imshuhao/topflow-toolkit) |
| 本 fork | [shizongrengkou/topflow-toolkit](https://github.com/shizongrengkou/topflow-toolkit) |
| PR | [#2](https://github.com/imshuhao/topflow-toolkit/pull/2) |
| 出处清单 | [`NOTICE.md`](NOTICE.md) |
