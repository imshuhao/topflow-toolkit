# 触屏控制中心实机截图

以下画面于 2026-08-29 从一台运行 B20 固件的 MU5252 实机只读抓取；「OpenDesign 还原页」
一节为 2026-11 整页还原后的补充抓图。实时数值只代表抓取时状态，不是示例配置或固定默认值。

公开图片使用不透明遮挡永久移除了号码、ICCID、IMSI、IMEI、模块序列号、IP、DNS、
信道、PCI、PLMN 和小区标识。仓库不包含未遮挡原图。

## 入口与网络概览

| 控制中心 | 三卡网络概览 |
| --- | --- |
| ![控制中心](screenshots/touchscreen/01-control-center-menu.png) | ![三卡网络概览](screenshots/touchscreen/02-network-overview.png) |

## 蜂窝网络详情

| X75 无线参数 | X75 网络与承载 |
| --- | --- |
| ![X75 无线参数](screenshots/touchscreen/03-network-x75-radio.png) | ![X75 网络与承载](screenshots/touchscreen/04-network-x75-network.png) |

| X75 流量 | X75 趋势 |
| --- | --- |
| ![X75 流量](screenshots/touchscreen/05-network-x75-traffic.png) | ![X75 趋势](screenshots/touchscreen/06-network-x75-trend.png) |

| X75 SIM 与模块 | V3E2 无线参数 |
| --- | --- |
| ![X75 SIM 与模块](screenshots/touchscreen/07-network-x75-identity.png) | ![V3E2 无线参数](screenshots/touchscreen/08-network-v3e2-radio.png) |

| V3E2 SIM 与模块 | V3E1 网络与承载 |
| --- | --- |
| ![V3E2 SIM 与模块](screenshots/touchscreen/09-network-v3e2-identity.png) | ![V3E1 网络与承载](screenshots/touchscreen/10-network-v3e1-network.png) |

| V3E1 SIM 与模块 | Mihomo |
| --- | --- |
| ![V3E1 SIM 与模块](screenshots/touchscreen/11-network-v3e1-identity.png) | ![Mihomo](screenshots/touchscreen/12-mihomo.png) |

## 设备状态与控制

| 系统 | 全局流量 |
| --- | --- |
| ![系统](screenshots/touchscreen/13-device-system.png) | ![全局流量](screenshots/touchscreen/14-device-traffic.png) |

| 散热 | 风扇曲线 |
| --- | --- |
| ![散热](screenshots/touchscreen/15-device-cooling.png) | ![风扇曲线](screenshots/touchscreen/16-device-cooling-curve.png) |

| Wi-Fi 功率 | 一键诊断 |
| --- | --- |
| ![Wi-Fi 功率](screenshots/touchscreen/17-device-wifi.png) | ![一键诊断](screenshots/touchscreen/18-device-diagnostics.png) |

## OpenDesign 还原页（2026-11）

按 OpenDesign 原型整页还原的触屏页：九宫格控制中心、余量、充电、分流、风扇曲线。

| 九宫格控制中心 | 余量（运营商标签已遮挡） |
| --- | --- |
| ![九宫格控制中心](screenshots/touchscreen/34-cc-mint.png) | ![余量](screenshots/touchscreen/29-balance.png) |

| 充电 | 分流 · 自动·质量 |
| --- | --- |
| ![充电](screenshots/touchscreen/30-charge.png) | ![分流自动质量](screenshots/touchscreen/29-wanbal.png) |

| 分流 · 自定义 | 风扇曲线 · 原厂阶梯 |
| --- | --- |
| ![分流自定义](screenshots/touchscreen/24-wanbal-custom.png) | ![风扇原厂曲线](screenshots/touchscreen/33-cooling-factory.png) |

| 风扇曲线 · 自定义 | 风扇曲线 · 应用确认 |
| --- | --- |
| ![风扇自定义曲线](screenshots/touchscreen/33-cooling-custom.png) | ![风扇曲线确认](screenshots/touchscreen/33-cooling-confirm.png) |

> 余量页顶部两个运营商标签只保留「联通」「电信」，其后的号码后四位已用不透明色块盖成
> `联通 · ****` / `电信 · ****`。
>
> **出处**：余量查询的运营商协议参考
> [`ChinaTelecomOperators/ChinaUnicom`](https://github.com/ChinaTelecomOperators/ChinaUnicom)、
> [`ChinaTelecomOperators/ChinaTelecom`](https://github.com/ChinaTelecomOperators/ChinaTelecom)、
> [`margrop/telecom-phone-device-id-tools`](https://github.com/margrop/telecom-phone-device-id-tools)；
> 见仓库根目录 [`NOTICE.md`](../NOTICE.md)。
