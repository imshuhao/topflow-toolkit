# USB ADB 不通定性（2026-10-30 白天）——「USB 3.0 口」不是主因

> **结论先行**：设备现在插在 PC 的 xHCI 口上，**以 High Speed 480M 稳定枚举**（60 秒 546 次端口轮询
> 0 掉线、0 重枚举），所以「USB 3.0 口物理层不行」不成立。真正的问题是：**01:03:47 执行了
> `pnputil /remove-device`（项目明令禁止的操作），在没拔线的情况下 Windows 立刻软重建了设备实例，
> 之后除"枚举"以外所有数据功能都处于半死状态** —— ADB bulk 传输第一次就返回
> `Win32 433 ERROR_NO_SUCH_DEVICE`，RNDIS / USB 大容量存储同时 `Problem 0xA`。
> 恢复手段：**物理拔插 ≥3 秒**（真实 USB 复位），不行就重启设备，兜底走无线 ADB。
>
> **2026-10-30 下午修订（见 §6）**：本节「USB 3.0 口不是主因」只对 433 / pnputil 半死实例成立；
> 干净启动下 USB3 口仍复现「首轮 CNXN 后 bulk 读 `Error 31`」。**现行口径：
> USB2 口四条通道全通；USB3 口只保证 WiFi 侧通道**（HANDOVER §28）。

- 时间：2026-10-30 10:28–11:00（Asia/Shanghai）
- 主机：Windows 10.0.26300 / AMD USB 3.10 xHCI（`PCI\VEN_1022&DESC_43FC`）/ platform-tools 37.0.1
- 设备：`USB\VID_19D2&PID_1404` serial `0123456789ABCDEF`（ZTE TopFlow MU5252 B20）
- 取证脚本：`tmp/tg-e58695/usbspeed.ps1`（hub IOCTL 查协商速率）、`tmp/tg-e58695/portpoll.ps1`（端口稳定性轮询）
- 关联文档：私人交接文档（未公开发布） §27（私人交接未公开发布）、私人工作笔记（未公开发布）（私人交接未公开发布） 禁止事项

---

## 1. 现场状态（全部为实测）

### 1.1 枚举正常、驱动正常

| 设备节点 | 状态 | 驱动 / 问题码 |
|---|---|---|
| `USB\VID_19D2&PID_1404\0123456789ABCDEF`（复合设备） | OK | `usbccgp` / 0 |
| `…&MI_06` **ADB Interface** | **OK** | `WINUSB` / **0**；`DeviceDesc=@winusb.inf,…`、`DeviceInterfaceGUIDs={F72FE0D4-CBCB-407D-8814-9ED673D0DD6B}`、`CompatibleIDs=USB\COMPAT_VID_19d2&Class_ff&SubClass_42&Prot_01` |
| `…&MI_00` Remote NDIS | **Error** | `usbrndis6` / **10 = CM_PROB_FAILED_START** |
| `…&MI_05` USB 大容量存储 | **Error** | `USBSTOR` / **10**（对应 ZTE CD-ROM 已不在系统里） |
| `…&MI_02/03/04/07/08`（ZTE 私有功能） | Error | 无驱动 / **28**（未装厂商驱动，属正常） |

即：**Windows 侧 ADB 驱动栈完全正常**（不是"设备管理器黄叹号"那种问题）。

### 1.2 链路是 USB 2.0 速率，而且非常稳定（本次新测）

用 SetupAPI + 根集线器 IOCTL（`IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX`）直接读协商速率：

```text
hub=usb#root_hub30#7&243c17fc&0&0   port=7  addr=12  vid=0x19D2 pid=0x1404  speed=High(480M)
polls=546  ioctl_failures=0  state_changes=0        # 60 秒 @100ms 连续轮询
```

- 设备**实际是 High Speed 480M**，不是 SuperSpeed 5G —— 也就是说这条 USB 3.0 口对它是按 USB2 跑的；
- 60 秒内 **零掉线、零速率变化、零重枚举**，链路本身完全健康。

### 1.3 adb 侧的真实报错：第一次 bulk 传输就 433

`ADB_TRACE=all adb -P 5061 nodaemon server` 抓到的完整链路：

```text
windows.cpp:592 Processing USB device: \\?\USB#VID_19D2&PID_1404&MI_06#9&67f5192&1&0006#{f72fe0d4-…}
windows.cpp:717 Found ADB interface (bInterfaceNumber=6, bAlternateSetting=0, bNumEndpoints=2,
                                   bInterfaceClass=255, bInterfaceSubClass=66, bInterfaceProtocol=1)
windows.cpp:765   bulk_in_pipe: 137
windows.cpp:766   bulk_out_pipe: 6
transport.cpp:806 registering: 0123456789ABCDEF state=offline
transport.cpp:615 packet --> CNXN
windows.cpp:323 usb_write failed: Error [433]: 指定的设备不存在。(433)
windows.cpp:340 usb_read  failed: Error [433]: 指定的设备不存在。(433)
transport.cpp:1222 0123456789ABCDEF: connection terminated: write failed
windows.cpp:353 Kicking USB device
```

- 能找到 ADB 接口（class ff/42/01、2 个 bulk 端点）→ 能打开 → 能查到 pipe → 能发 CNXN；
- **CNXN 的第一个 bulk 读/写立刻返回 `433 = ERROR_NO_SUCH_DEVICE`**；
- `adb kill-server` + `start-server` 连续 **10 次，0/10 枚举到设备**（每次都同样的 433）。

`ERROR_NO_SUCH_DEVICE` 的含义是"这个设备对象已经不存在了"——不是超时、不是拒绝、不是没权限。

### 1.4 决定性证据：PnP 时间线（Kernel-PnP + setupapi.dev.log）

| 时间（今天） | 事件 ID | 内容 |
|---|---|---|
| 01:03:47 | 420 | **已删除设备** `USB\VID_19D2&PID_1404\0123456789ABCDEF`；`setupapi.dev.log` 里对应一条 `cmd: "pnputil.exe" /remove-device USB\VID_19D2&PID_1404\0123456789ABCDEF`（SUCCESS） |
| 01:03:52 | 400/410 | Windows **在没有物理拔插的情况下**立刻重新配置整台复合设备，并逐个启动子功能；实例从 `9&67f5192&**0**&0006` 变成 `9&67f5192&**1**&0006`（旧实例 `&0&` 留在注册表但不再 present） |
| 01:03:53 | 410 | `MI_06`（ADB）用 `winusb.inf` 启动成功 |
| 01:04:03 | 411 | `MI_00`（RNDIS）**启动失败：Problem 0xA** |
| 01:04 之后到现在 | — | 无任何 remove / re-configure 事件 → 一直停在这个"半死实例"上 |

### 1.5 被推翻的旧口径

私人工作笔记（未公开发布） 旧结论是「**必须插 USB 2.0 口**：USB3 口表现为 adb 能枚举/发 CNXN 但 bulk 读 `Error 31`
（`max_speed 5000 / negotiated 0`）、RNDIS `CM_PROB_FAILED_START`，换 USB2 口即好」。

本次实测与之不符的地方：

1. 同一条"USB3 口"上设备**只有 480M（HS）**，从未 SuperSpeed；链路 60 秒零抖动；
2. RNDIS 的 `0xA` 与 ADB 的 `433` 都发生在 **01:03:47 的强制移除之后**，时间上高度相关；
3. 若是端口本身不兼容，不该出现"同一端口上一段时间能枚举、能开 pipe、能发 CNXN"这种细节。

因此更合理的解释是：**当时"换 USB2 口就好"真正起作用的动作是"拔插"**（物理复位会重建两端 USB 状态），
端口类型只是被连带观察到。**本次故障的直接诱因是 `pnputil /remove-device`。**

---

## 2. 根因判断（按置信度排序）

| # | 假设 | 置信度 | 依据 |
|---|---|---|---|
| H1 | **强制移除后"软重建"的实例是半死的**：PDO 被删除但线没拔，Windows 用缓存/重新枚举拼出一个实例；设备侧在这种 surprise removal 之后没有恢复数据端点 | 高 | 时间线（1.4）+ 所有数据功能同时坏（RNDIS 0xA、MSC 0xA、ADB 433）+ 链路却正常（1.2） |
| H2 | **设备侧 adbd / functionfs 没被重新拉起**：surprise removal 让 adbd 退出，`/data/adb-wifi` wrapper 只在特定事件启动 adbd，之后没人重启 → 主机侧描述符还在、端点不服务 | 中 | `&1&` 实例里 ADB 接口有 2 个端点（说明 ffs 描述符写过），但传输出 433 |
| H3 | USB3 / SuperSpeed 链路训练问题 | **已排除** | 实测只有 HS 480M，60s 546 次轮询 0 掉线 |
| H4 | 主机 WinUSB 驱动问题 | **已排除** | MI_06 绑 `winusb.inf`、问题码 0、接口 GUID 正确、pipe 枚举成功 |
| H5 | 设备 USB 供电不足 | 低 | 复合设备 + 5 个功能能被枚举；且此前同一端口工作过 |

---

## 3. 恢复步骤（按代价从低到高，**不要跳**）

```sh
# 1) 物理复位：拔掉 USB 线，等 ≥3 秒，插回（换不换口都行，换口更好排除单口问题）
adb devices -l
#    期望：0123456789ABCDEF   device

# 2) 仍无 → 设备断电重启（长按电源/重新上电），再插线
#    设备侧 adbd 与 USB gadget 依赖开机流程重建

# 3) 仍无 → 无线 ADB 兜底（设备热点的 15555 端口，开机自启）
#    先让 PC 连上设备 WiFi（SSID 形如 ZTE_TOPFLOW_xxxx，见 HANDOVER §26）
adb connect 192.168.0.1:15555
adb devices -l
```

**明确不做**：

- ❌ `pnputil /remove-device` + `/scan-devices`、`devcon restart`、设备管理器"卸载设备"——
  **本次故障就是它引起的**（HANDOVER §25.7② 已有同款警告）；
- ❌ 重启 adbd（会拆 USB gadget，只能重启设备恢复）；
- ❌ 反复 `adb kill-server`（10 次已证明无效，只会刷日志）。

---

## 4. 复现 / 取证命令集

```powershell
# 协商速率 + 端口稳定性（本机脚本）
powershell -File tmp\tg-e58695\usbspeed.ps1
powershell -File tmp\tg-e58695\portpoll.ps1 -Port 7 -Seconds 60 -IntervalMs 100

# adb 的 USB 后端日志（nodaemon 才拿得到）
$env:ADB_TRACE='all'
adb -P 5061 nodaemon server   # 另一个窗口跑 adb -P 5061 devices，然后 Ctrl+C

# Windows 侧设备/PnP 证据
Get-PnpDevice -PresentOnly | ? InstanceId -match 'VID_19D2&PID_1404' |
  % { $_.Status, $_.InstanceId }
Select-String 'C:\Windows\INF\setupapi.dev.log' -Pattern '19D2&PID_1404'
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Kernel-PnP/Configuration'; StartTime=(Get-Date).Date} |
  ? Message -match '19D2'
```

本机留存的原始日志：

| 文件 | 内容 |
|---|---|
| `tmp/tg-e58695/adb-server.err.log` | 第一次 `ADB_TRACE=all` server 日志（含 433） |
| `tmp/tg-e58695/adb2.err` | 第二次复测日志（同样 433） |
| `tmp/tg-e58695/usbspeed.ps1` / `portpoll.ps1` | 速率与稳定性取证脚本 |

---

## 5. 对既有文档的修订

1. 私人工作笔记（未公开发布）「USB 三合一」条目：把「必须插 USB 2.0 口」改为
   **「端口类型不是决定因素；关键是插拔后两端 USB 状态是否干净；禁止 pnputil 强制重枚举」**，
   并指向本文档。
2. 私人交接文档（未公开发布） 新增 §27（本文档摘要 + 时间线 + 恢复步骤）。
3. 未完成的设备侧任务（observability 部署 + eBPF 探测）不变，等 USB/无线 ADB 恢复后按
   `docs/TELEGRAM-E58695-SINGBOX-DIGEST-2026-10-30.md` §8.3 执行。

---

## 6. 2026-10-30 下午复测修订（干净启动 + A/B）

> 本节补充/修正 §2 的 H3 与 §5 第 1 条。通道矩阵与操作口径见
> HANDOVER §28（私人交接未公开发布）。

1. **干净启动（未执行 pnputil、设备 reboot 后、wrapper v4 正常、USB3 口）**：
   设备仍按 HS 枚举（`current_speed=high-speed`，SS 伴随口空），ADB 接口 OK；
   host 发 CNXN 后设备回 `24+63` 字节，下一次 bulk 读 **`Error [31]`**，transport 被丢弃，
   `adb devices` 空。设备侧 adbd 存活、ffs `ep0/ep1/ep2` 打开、`ep6out` 有 TRB；
   `No resource for ep6out` = **0 条**（880 条只出现在 11:16 的 `pnputil` 强删 churn）。
   → §2 H3「SuperSpeed/端口问题已排除」**不成立**：本次只是没训练到 SS，不等于 USB3 口对 ADB 无害；
   USB3 口有一套可复现的 ADB bulk 故障。
2. **A/B**：还原原厂 `adbd.init`（`remove-adbd-preset.sh`）→ reboot，设备只到
   `udc state=addressed`，主机**没有复合设备节点**；装回 wrapper v4 → reboot 恢复。
   → **wrapper v4 是这台机器 USB 能枚举的必要条件**，不是破坏者。
3. **§1.3 的 433** 是 pnputil 半死实例的特征；干净启动下是 **31（`ERROR_GEN_FAILURE`）**，
   两者不要混为一谈。
4. `max_speed` 在 5.15 **只读**：`echo high-speed > .../max_speed` 被忽略，不能用 configfs 降速。
5. **现行口径**：USB2 口 = USB ADB + 网络 ADB + USB RNDIS + WebSSH 四条全通；
   USB3 口 = 仅 WiFi 侧 `15555`/`8899`/`22622`。
