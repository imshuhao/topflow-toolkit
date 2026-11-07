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

## 余量查询：协议参考（必须标明）

触屏「余量」页与设备侧联通/电信查询、授信流程，**协议与请求流程参考**下列开源项目；
本仓库的触屏展示、本地快照与跳点差分是另行实现，**不是**对其脚本的直接拷贝分发。

| 用途 | 上游 | 说明 | 许可 |
| --- | --- | --- | --- |
| 联通短信登录 / `token_online`、余量查询协议 | [`ChinaTelecomOperators/ChinaUnicom`](https://github.com/ChinaTelecomOperators/ChinaUnicom) | 对齐其 `10010_send_sms` / `10010_sms_sign` 一类流程 | GPL-3.0 |
| 电信余量 / 登录查询协议 | [`ChinaTelecomOperators/ChinaTelecom`](https://github.com/ChinaTelecomOperators/ChinaTelecom) | 查询与登录字段口径对齐 | GPL-3.0 |
| 电信短信授权 DeviceId（解 3006） | [`margrop/telecom-phone-device-id-tools`](https://github.com/margrop/telecom-phone-device-id-tools) | 对齐其 v1 校验（`androidId` 凯撒 / `deviceUid`） | MIT |

公开分支只含触屏读取 `status.json` 的展示逻辑；采集脚本与账号凭证**不**随本 fork 分发。
再使用上述协议时，请自行遵守各上游许可与运营商接口条款。

再分发时请同时保留本文件、根目录 `LICENSE`，以及各第三方要求的版权声明。

## 设计稿

触屏控制中心的界面原型（320×480 九宫格 / 共用状态栏 / 日夜令牌）使用 OpenDesign
在本地设计与走查；仓库只保留移植所需的口径、几何常量与色值，**不含**设计工具的导出快照。
界面的实现、设备侧适配与全部 LVGL 代码均为本分支原创。
