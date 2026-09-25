<p align="center">
  <img src="docs/assets/readme-hero-v2.svg" alt="ZTE TopFlow Toolkit：三路蜂窝、Mihomo、原生 WebUI、LVGL 触屏与可恢复设备改造" width="100%">
</p>

<p align="center">
  <strong>把一台三路蜂窝随身路由器，改造成可观测、可控制、可回退的边缘网络平台。</strong>
</p>

<p align="center">
  <a href="https://github.com/imshuhao/topflow-toolkit/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/imshuhao/topflow-toolkit/ci.yml?branch=main&amp;style=flat-square&amp;label=CI&amp;labelColor=0b0f0d&amp;color=238636" alt="CI"></a>
  <a href="https://github.com/imshuhao/topflow-toolkit/releases"><img src="https://img.shields.io/github/v/release/imshuhao/topflow-toolkit?style=flat-square&amp;labelColor=0b0f0d&amp;color=238636" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/target-TopFlow%20B22-238636?style=flat-square&amp;labelColor=0b0f0d" alt="Target: ZTE TopFlow B22">
  <img src="https://img.shields.io/badge/arch-AArch64-238636?style=flat-square&amp;labelColor=0b0f0d" alt="Architecture: AArch64">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-238636?style=flat-square&amp;labelColor=0b0f0d" alt="MIT License"></a>
</p>

<p align="center">
  <a href="#它能做什么">能力</a> ·
  <a href="#实机界面">实机界面</a> ·
  <a href="#开始使用">开始使用</a> ·
  <a href="docs/COMPATIBILITY.md">兼容性</a> ·
  <a href="docs/NETWORK-ARCHITECTURE.md">网络架构</a> ·
  <a href="docs/RECOVERY.md">恢复</a> ·
  <a href="docs/SCREENSHOTS.md">完整截图</a>
</p>

## 它能做什么

<table>
  <tr>
    <td width="33%" valign="top">
      <strong>蜂窝网络可观测</strong><br><br>
      同时查看 X75、V3E2、V3E1 三路基带的信号、注册、QCI、AMBR、地址、实时流量与趋势。
    </td>
    <td width="33%" valign="top">
      <strong>独立透明网关</strong><br><br>
      Mihomo 运行在独立 network namespace 中；宿主保留原厂路由，DHCP 客户端按需接入 IPv4 透明代理。
    </td>
    <td width="33%" valign="top">
      <strong>双模式链路治理</strong><br><br>
      普通模式优化 mwan3 质量与粘性；聚合模式沿用厂商 ICG，并处理与 Mihomo 串联的边界。
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <strong>双端原生控制</strong><br><br>
      Mihomo 管理能力接入厂商 WebUI；同一套状态与控制延伸到设备原生 LVGL 触摸屏。
    </td>
    <td width="33%" valign="top">
      <strong>设备级运维</strong><br><br>
      覆盖核心与配置更新、散热曲线、Wi-Fi 功率、运行诊断、屏幕抓取、启动恢复与完整卸载。
    </td>
    <td width="33%" valign="top">
      <strong>固件资源再利用</strong><br><br>
      从设备当前 WebUI 生成完整菜单补丁；不打包或分发厂商页面、二进制、字体和图片。
    </td>
  </tr>
</table>

它不是一个悬浮在设备外面的 Dashboard：网络数据面、Web 管理面和触屏设备面都在同一台 TopFlow 上运行，并尽量沿用原厂服务边界。

## 实机界面

以下均为 B20 实机画面，不是设计稿。公开图片已永久遮挡设备身份、号码和网络标识。

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/touchscreen/02-network-overview.png" alt="三卡网络概览" width="250"></td>
    <td align="center"><img src="docs/screenshots/touchscreen/12-mihomo.png" alt="Mihomo 触屏管理" width="250"></td>
    <td align="center"><img src="docs/screenshots/touchscreen/16-device-cooling-curve.png" alt="设备风扇曲线" width="250"></td>
  </tr>
  <tr>
    <td align="center"><sub>三卡网络仪表</sub></td>
    <td align="center"><sub>Mihomo 状态与模式</sub></td>
    <td align="center"><sub>原厂 / 自定义风扇曲线</sub></td>
  </tr>
</table>

<p align="center"><a href="docs/SCREENSHOTS.md"><strong>查看 18 张脱敏实机截图 →</strong></a></p>

## 组件地图

| 组件 | 职责 | 状态边界 |
| --- | --- | --- |
| [`mihomo-netns`](mihomo-netns/) | 隔离运行 Mihomo，提供 IPv4 透明网关、DHCP 网关/DNS 下发和故障恢复 | 实机运行 |
| [`mihomo-manager`](mihomo-manager/) | 将状态、模式、配置、核心更新和网络开关接入设备原生 WebUI | 实机运行 |
| [`touchscreen-control-center`](touchscreen-control-center/) | 通过 `LD_PRELOAD` 扩展原厂 LVGL，管理三基带、Mihomo、系统、散热和 Wi-Fi | 实机运行 |
| [`timekeeper`](timekeeper/) | 用 Qualcomm `time_genoff` 在联网前恢复可信时间，避免 1970 年阻断 TLS | 实机验证 |
| [`mwan3-tuning`](mwan3-tuning/) | 配置普通模式 Mihomo/HTTPS 分流，改善质量探测并按故障线路清理连接 | 公开安装器迁移及重启实机验证 |
| [`web-full-menu`](web-full-menu/) | 从目标设备当前文件生成完整隐藏菜单，保持登录与后端权限边界 | 公开安装器部署及重启实机验证 |
| [`zwrt-datad-tools`](zwrt-datad-tools/) | 检查、更新、健康验证并回滚触屏所依赖的上游数据服务 | v0.9.21 实机验证 |
| [`vendor-control`](vendor-control/) | 停用原厂 MQTT 并关闭三路二次认证，检查配置和实际拦截状态 | B22 实机验证 |

各组件可以分别阅读和部署。触屏网络页面依赖本机 `zwrt-datad /state`，Mihomo 触屏页面依赖 `mihomo-manager`；完整菜单应安装在 Manager 之后。

## 设计边界

- **隔离而非替换：** Mihomo 留在独立 namespace，宿主继续负责厂商蜂窝与路由逻辑。
- **可恢复：** 安装脚本保存必要状态，服务停止撤销当前 DHCP 下发，卸载器移除本组件的挂载、服务和规则。
- **固件锁定：** 触屏安装前核对原厂 `zte_topsw_devui` 的 SHA-256；不匹配就停止。
- **不搬运厂商资源：** WebUI 在本地补丁当前文件；仓库不分发 ZTE 二进制、固件、字体或可复用图片资源。
- **不伪造通用性：** 实测、公开包装器测试和仍待验证的部分分别标注，不把“配置存在”写成“业务在线”。

## 开始使用

当前默认面向 B22，已验证环境如下；B20 代码保留在 Git 历史：

| 项目 | 已验证环境 |
| --- | --- |
| 商品名 | ZTE TopFlow |
| 硬件标识 | MU5252 / `MU5252_HW1.0` |
| 固件 | `BD_ENCNMU5252V1.0.0B22` |
| 架构 | AArch64 / musl |

核心界面的建议部署顺序：

1. 准备 [Root ADB](docs/ROOT-ADB.md)，并核对 [兼容性边界](docs/COMPATIBILITY.md)；
2. 安装上游 [`zwrt-datad` v0.9.21+](https://github.com/33333s/zwrt-datad)，或用[维护工具](zwrt-datad-tools/)检查已有版本；
3. [部署 Mihomo 透明网关](mihomo-netns/README.md)；
4. [安装设备 Web 管理页](mihomo-manager/README.md)；
5. 按需安装[完整 WebUI 菜单](web-full-menu/README.md)；
6. [编译和安装触屏控制中心](touchscreen-control-center/README.md)。

[`timekeeper`](timekeeper/) 与 [`mwan3-tuning`](mwan3-tuning/) 是独立增强项。前者解决开机
时间可信度，后者只影响普通 `MULTIWAN`；先理解[网络架构](docs/NETWORK-ARCHITECTURE.md)
再部署。卸载前阅读[统一恢复顺序](docs/RECOVERY.md)。

> [!WARNING]
> 脚本会以 root 权限修改 network namespace、DHCP、init 服务、`rc.local` 和只读 WebUI 的 bind mount。它们不是通用 OpenWrt 软件包，也没有在其他硬件或固件上验证。开始前请准备 root ADB、当前配置备份，以及不依赖被改 DHCP 路径的恢复入口。

更精确的前置条件与固件边界见 [Compatibility boundary](docs/COMPATIBILITY.md)。ICG 的
机制、自建服务端边界与判断在线的方法见 [聚合技术说明](docs/AGGREGATION.md)。

## 本地验证

```sh
make check
```

该命令检查 POSIX Shell/Bash/Node 语法、ShellCheck、WebUI 补丁器单元测试、Timekeeper
helper 严格宿主编译，以及触屏注入库的严格宿主编译。面向设备的正式产物仍应使用
AArch64 musl 环境构建。

2026-09-25 已通过原厂本地 OTA 从 B20 升至 B22，并通过 uci-defaults 迁移保留 root。
时间、触屏和服务已适配，修复停用 OTA 服务后遗漏的开机等待项；最终重新启动后，
三网 IPv4/IPv6、Wi-Fi、Mihomo、数据服务、触屏及新 SNTP 事件保存均通过验证。
完整步骤、变更、故障原因和未验证范围见 [B20 → B22 升级记录](docs/OTA-B20-TO-B22.md)。
未在另一台干净设备上重跑全部安装—重启—卸载流程，仍需遵守兼容性边界。

<details>
<summary><strong>仓库不包含什么</strong></summary>

- 订阅地址、代理节点、控制器密钥或真实 `config.yaml`；
- 设备抓取、日志、Cookie、序列号或配置备份；
- ZTE 固件、二进制、共享库、字体、可复用原厂图片资源或完整 WebUI 文件；
- Mihomo、Zashboard、GeoIP/GeoSite 或第三方规则缓存。

安装者需自行从各上游获取相关组件并遵守其许可证。文档中的脱敏实机截图只用于展示功能，不作为可复用固件素材。
</details>

## 安全与许可

敏感信息报告方式见 [Security policy](SECURITY.md)。原创代码采用 [MIT License](LICENSE)；第三方项目和设备固件仍受各自许可证约束。

本项目不是 ZTE、Mihomo 或任何运营商的官方项目。
