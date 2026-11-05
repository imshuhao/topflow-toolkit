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

再分发时请同时保留本文件、根目录 `LICENSE`，以及各第三方要求的版权声明。
