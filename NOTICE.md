# 出处与致谢 / Attribution

本仓库是 [`imshuhao/topflow-toolkit`](https://github.com/imshuhao/topflow-toolkit) 的 **fork**。

## 原作者（必须保留）

| 项目 | 作者 / 维护 | 许可 |
| --- | --- | --- |
| **[topflow-toolkit](https://github.com/imshuhao/topflow-toolkit)** | **[@imshuhao](https://github.com/imshuhao)** 及 contributors | MIT（见 [`LICENSE`](LICENSE)，`Copyright (c) 2026 imshuhao contributors`） |

本分支在原作之上增加 B20 现场改动（Sing-box、触控、分流、无线 ADB、弱网黑匣子、OTA 冻结、WebSSH 部署包装等）。  
**未改动的模块**（如 `mihomo-netns`、`luci-admin`、`web-full-menu` 等）版权与说明仍以上游为准；请优先阅读上游 README：  
https://github.com/imshuhao/topflow-toolkit/blob/main/README.md

## 本分支额外引入的第三方

| 组件 | 上游 | 本仓库落点 | 许可 |
| --- | --- | --- | --- |
| GoWebSSH | [`o8oo8o/WebSSH`](https://github.com/o8oo8o/WebSSH) | 不内嵌完整源码；见 `webssh/` | MIT（Copyright © 2021 o8oo8o） |
| WebSSH-u60pro MOD | [`kanoqwq/WebSSH-u60pro`](https://github.com/kanoqwq/WebSSH-u60pro) | B20 补丁在 `webssh/patches/` | 从其仓库 |
| sing-box | [`SagerNet/sing-box`](https://github.com/SagerNet/sing-box) 等 | 设备侧二进制不随本 fork 分发；配置生成见 `singbox/` | 从其上游 |

## 余量查询相关上游（协议说明）

现场曾参考下列项目的**登录/查询流程说明**做联通·电信余量能力；本公开分支**不包含**
其余量采集源码、凭证或触屏「余量」页，也**没有**拷贝下列仓库中的脚本。

| 上游 | SPDX | 对本公开分支的含义 |
| --- | --- | --- |
| [`ChinaTelecomOperators/ChinaUnicom`](https://github.com/ChinaTelecomOperators/ChinaUnicom) | **GPL-3.0** | 仓库根目录 `LICENSE` 为 GPLv3。GPL 约束的是**发行其衍生作品**时须以兼容条款提供对应源码并保留声明；仅参考其公开协议/流程、自行重写，**不**要求把本 MIT fork 整仓改成 GPL。当前公开仓未分发其代码或衍生件。 |
| [`ChinaTelecomOperators/ChinaTelecom`](https://github.com/ChinaTelecomOperators/ChinaTelecom) | **GPL-3.0** | 同上。另：该仓现网公开树基本只有 `LICENSE` + `README`（维护说明称原作者失联），`README` 另有「24 小时学习后删除」等免责文案，与 GPLv3 再分发条款并存时以 SPDX/`LICENSE` 文件为准做出处标注。 |
| [`margrop/telecom-phone-device-id-tools`](https://github.com/margrop/telecom-phone-device-id-tools) | **MIT** | 若拷贝或发行其「实质性部分」，须在副本中保留其版权与许可声明（Copyright © 2026 margrop）。本公开分支未纳入该工具源码。 |

再分发时请同时保留本文件、根目录 `LICENSE`，以及各第三方要求的版权声明。

## 设计稿

触屏控制中心的界面原型（320×480 九宫格 / 共用状态栏 / 日夜令牌）使用 OpenDesign
在本地设计与走查；仓库只保留移植所需的口径、几何常量与色值，**不含**设计工具的导出快照。
界面的实现、设备侧适配与全部 LVGL 代码均为本分支原创。
