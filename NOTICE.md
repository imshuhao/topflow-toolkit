# 出处与致谢 / Attribution

本仓库是 [`imshuhao/topflow-toolkit`](https://github.com/imshuhao/topflow-toolkit) 的 **fork**。

## 原作者（必须保留）

| 项目 | 作者 / 维护 | 许可 |
| --- | --- | --- |
| **[topflow-toolkit](https://github.com/imshuhao/topflow-toolkit)** | **[@imshuhao](https://github.com/imshuhao)** 及 contributors | MIT（见 [`LICENSE`](LICENSE)，`Copyright (c) 2026 imshuhao contributors`） |

本分支在原作之上增加 B20 现场改动（Sing-box、触控、分流、无线 ADB、弱网黑匣子、OTA 冻结、WebSSH 部署包装、余量查询等）。  
**未改动的模块**（如 `mihomo-netns`、`luci-admin`、`web-full-menu` 等）版权与说明仍以上游为准；请优先阅读上游 README：  
https://github.com/imshuhao/topflow-toolkit/blob/main/README.md

## 本分支额外引入的第三方

| 组件 | 上游 | 本仓库落点 | 许可 |
| --- | --- | --- | --- |
| GoWebSSH | [`o8oo8o/WebSSH`](https://github.com/o8oo8o/WebSSH) | 不内嵌完整源码；见 `webssh/` | MIT（Copyright © 2021 o8oo8o） |
| WebSSH-u60pro MOD | [`kanoqwq/WebSSH-u60pro`](https://github.com/kanoqwq/WebSSH-u60pro) | B20 补丁在 `webssh/patches/` | 从其仓库 |
| sing-box | [`SagerNet/sing-box`](https://github.com/SagerNet/sing-box) 等 | 设备侧二进制不随本 fork 分发；配置生成见 `singbox/` | 从其上游 |

## 余量查询：协议参考与本仓库实现

本分支公开 [`balance/`](balance/)（查询器 / 采样脚本）与触屏「余量」页展示逻辑。  
实现为**自行重写**，对齐下列项目公开的登录/查询流程，**不是**对其脚本的直接拷贝分发；  
因此本 MIT fork **不必**因引用这些上游而整仓改成 GPL。凭证与真实号码**不**随仓库分发。

| 用途 | 上游 | 许可 | 对本仓库的要求 |
| --- | --- | --- | --- |
| 联通短信登录 / `token_online`、流量包查询 | [`ChinaTelecomOperators/ChinaUnicom`](https://github.com/ChinaTelecomOperators/ChinaUnicom) | **GPL-3.0** | 未拷贝其源码时，GPL 不传染本仓；仍应标明出处。若日后并入其衍生代码，对应部分须按 GPL 提供源码与声明。 |
| 电信登录与余量查询 | [`ChinaTelecomOperators/ChinaTelecom`](https://github.com/ChinaTelecomOperators/ChinaTelecom) | **GPL-3.0** | 同上。该仓现网公开树多为 `LICENSE` + `README`（维护说明称原作者失联）；`README` 另有「24 小时学习后删除」等免责文案，出处标注以 SPDX / `LICENSE` 为准。 |
| 电信 DeviceId 短信授权（解 3006） | [`margrop/telecom-phone-device-id-tools`](https://github.com/margrop/telecom-phone-device-id-tools) | **MIT** | 字段口径对齐其公开说明；若拷贝其「实质性部分」源码，须保留 Copyright © 2026 margrop 与 MIT 许可声明。本仓实现为自行重写并在源码注释中标明。 |

触屏五行展示与跳点差分属本分支原创。细节见 [`balance/README.md`](balance/README.md)。

再分发时请同时保留本文件、根目录 `LICENSE`，以及各第三方要求的版权声明。

## 设计稿

触屏控制中心的界面原型（320×480 九宫格 / 共用状态栏 / 日夜令牌）使用 OpenDesign
在本地设计与走查；仓库只保留移植所需的口径、几何常量与色值，**不含**设计工具的导出快照。
界面的实现、设备侧适配与全部 LVGL 代码均为本分支原创。
