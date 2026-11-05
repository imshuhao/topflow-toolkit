# adb-wifi — TopFlow MU5252 无线 ADB

> 2026-10-27 实机上线。目标：不插 USB 也能拿到 root shell。本机没有 dropbear / sshd，
> ADB 是唯一远程入口；组件不装二进制，不写 boot/system/MTD。
>
> **2026-10-31 更新（wrapper v5，现行）**：v4 的「按充电器类型隐藏 functionfs」分支
> 在真机把 USB 通道全灭了（`g1/UDC` 空、`udc state=not attached`，USB ADB + RNDIS 一起消失）。
> v5 **永不隐藏 functionfs**，启动时清掉 v4 遗留的 tmpfs；root cause 见
> 本 README「v5」说明。设备 = 仓库 md5 `300cc5fc…`，
> v4 原件保留为 `/data/adb-wifi/adbd-wrapper.sh.bak-v4`（`eb249d48…`）。
>
> **2026-10-30 记录（v4）**：修掉「每次开机 gadget 被拆」的时序问题，
> 现在 **USB ADB + 网络 ADB + USB RNDIS 网络三者可同时存在**（前提：**USB2 口**；
> USB3 口只保证 WiFi 侧通道，见本模块说明与 USB-ADB-DIAG 文档 +
> [USB-ADB-DIAG-2026-10-30.md](../docs/USB-ADB-DIAG-2026-10-30.md)）。

## 实测结论（决定实现方式）

| 项 | 结论 |
|---|---|
| 属性可用时机 | **2026-10-30 更正**：本机实测**开机 +1s** 即可 `setprop` 并 `getprop` 读回（旧结论「~40 秒前假成功」不成立）；本机**无 `/data/property/`**，`persist.*` 不持久 |
| adbd 读属性 | 只在进程启动时读 `service.adb.tcp.port`；AOSP 10 双模（USB + TCP） |
| 运行时重启 adbd | **禁止**：会拆 functionfs，USB gadget（含 RNDIS）整体消失，只能重启设备恢复 |
| 无 USB 主机启动 | **2026-10-31 更正**：隐藏 functionfs **不是**解法 —— 没有进程持有 ep0，复合设备永远绑不上，USB 全灭；v5 保留 ffs，TCP 侧照常工作 |
| 认证 | `ro.adb.secure` 未设置 = 无认证，连上即 root |

## 工作原理

1. `/etc/init.d/adbd.init` 两处带 marker 的改动（安装前备份，可一键还原）：
   - `start_service()` 开头调用 `adbd-preset.sh`
   - `procd_set_param command` 换成 `/bin/sh -c` 包装 → `adbd-wrapper.sh`
2. `adbd-wrapper.sh`（**v5，2026-10-31**）按固定时序起 adbd，不再等 rc.local：
   - `+1s` 起循环 `setprop service.adb.tcp.port` 直到 `getprop` 读回；
   - 探测 `usb/online`、`charger_zte/type_mbb` **只写日志**（只读，不驱动任何动作）；
   - **永不隐藏 functionfs**（v4 的 `mount -t tmpfs` 分支会在充电器/瞬态类型下把
     `/dev/usb-ffs/adb` 盖掉 → adbd 打不开 ep0 → gadget 永远绑不上 → USB 全灭，见 现场纪要（私人交接未公开发布））；
   - 启动时若发现 v4 遗留的 tmpfs，`umount /dev/usb-ffs/adb` 后继续；
   - 强制模式：`/data/adb-wifi/wrapper.forcemode` 写 `host` / `tcp` / `auto`；最后 `exec /sbin/adbd`。
3. `adb-wifi.sh apply`（rc.local）：`setprop` → 建 `/tmp/adb-wifi-rc-done` 放行 adbd → 等监听 ≤15 秒 → 建 `ADB_WIFI` 链
4. 看门狗每 30 秒巡检，只补属性 / 防火墙 / 日志，**永不重启 adbd**
5. `stop` 把链改成 `REJECT --reject-with tcp-reset`，立即封端口但不动 adbd；`start` 瞬间恢复

## 组件

| 文件 | 设备路径 | 作用 |
|---|---|---|
| `adb-wifi.sh` | `/data/adb-wifi/adb-wifi.sh` | `start` / `stop` / `apply` / `status` / `help` |
| `adb-wifi-watchdog.sh` | `/data/adb-wifi/adb-wifi-watchdog.sh` | 30 秒巡检，日志 `/tmp/adb-wifi-watchdog.log`（1 MB 轮转） |
| `adbd-preset.sh` | `/data/adb-wifi/adbd-preset.sh` | 读配置后 `setprop service.adb.tcp.port` |
| `adbd-wrapper.sh` | `/data/adb-wifi/adbd-wrapper.sh` | v5：+1s 设端口 → 只读探测记日志 → **保持 functionfs 可见**（清理 v4 遗留 tmpfs）→ `exec adbd` |
| `install-adbd-preset.sh` / `remove-adbd-preset.sh` | 同左 | adbd.init 两处改动 / 还原 |
| `install-boot-hook.sh` / `remove-boot-hook.sh` | 同左 | rc.local 钩子块（幂等、原子写、带备份） |
| `install.sh` | 同左 | 设备侧一键安装 |
| `deploy.sh` | PC 侧 | 一键推送 + 安装（仿 `singbox/deploy.sh`） |
| `config.example` | `/data/adb-wifi/config` | `ADB_WIFI_PORT=15555` / `ADB_WIFI_ENABLED=1` |
| `connect.cmd` / `disconnect.cmd` | PC 侧 | Windows 连接 / 断开助手 |
| `adb-wifi-portalias.sh` | `/data/adb-wifi/adb-wifi-portalias.sh` | `on` / `off` / `status`：LAN 侧 `5555 → 15555` 端口别名，opt-in、一次性、不进 rc.local |

rc.local 标记：`# Start the TopFlow wireless ADB service.` / `# End the TopFlow wireless ADB service.`

## 部署

```sh
# 一条命令：push → 去 CR → chmod → sh -n → install.sh
sh adb-wifi/deploy.sh

# 只推送不安装
sh adb-wifi/deploy.sh --no-install

# 多设备时指定 serial（USB: 0123456789ABCDEF / 无线: 192.168.0.1:15555）
ADB_SERIAL=192.168.0.1:15555 sh adb-wifi/deploy.sh

# 安装后必须重启：adbd 只在启动时读端口
adb shell reboot
```

## 使用

```sh
adb connect 192.168.0.1:15555
adb -s 192.168.0.1:15555 shell
# 或双击 connect.cmd
```

端口别名（只给只能填 5555 的客户端，opt-in；一次性，重启或重载防火墙后失效需重跑）：

```sh
adb shell 'sh /data/adb-wifi/adb-wifi-portalias.sh on'      # off / status
adb connect 192.168.0.1:5555                                 # on 后 5555 → 15555
```

手机端见 [PHONE-CLIENT.md](PHONE-CLIENT.md)：必须用 ADB 协议客户端，账号/密码字段可随意填（ADB 无认证）；SSH 类 App 无服务可用。adbd 同一时刻只服务一个客户端——手机连之前先 `adb disconnect 192.168.0.1:15555`。

USB 与无线同时在线时 `adb devices` 有两条同 serial transport，裸命令会报
`more than one device`，必须 `adb -s 192.168.0.1:15555` 或 `set ANDROID_SERIAL`。

## 验收（2026-10-27 实机，已通过）

| 场景 | 结果 |
|---|---|
| 纯无线（充电器供电、无 USB 数据） | `adb -s 192.168.0.1:15555 shell id` = `uid=0(root)`；push/pull 正常 |
| 双模（USB 接 PC） | USB `0123456789ABCDEF` + `192.168.0.1:15555` 同时 `device` |
| **三合一（2026-10-30）** | USB ADB + 无线 ADB + **USB RNDIS `192.168.0.200/24`** 同时在线。端口类型非决定因素（2026-10-30 白天修订：xHCI 口上实测 HS 480M 且零掉线；故障来自 `pnputil` 强删后的半死 PnP 实例，见 [USB-ADB-DIAG-2026-10-30.md](../docs/USB-ADB-DIAG-2026-10-30.md)） |
| 纯无线 reboot | 60–90 秒自动恢复（wrapper 日志 `v5: functionfs kept visible (online=1 type=4)`；v4 的 `functionfs hidden -> tcp-only` 行已作废） |
| `stop` / `start` | 立即拒绝 / 立即恢复，USB 不受影响 |
| 看门狗 | 每 5 分钟 `watch: port=15555 listener=up adbd=...` |
| 端口别名 | 5555 → 拒绝；`on` 后 5555 → `uid=0(root)`；`off` 后复原 |

## 排障

| 现象 | 处理 |
|---|---|
| `cannot connect` / `actively refused` | 设备刚重启或 adbd 正在重启，等 10–30 秒重试 |
| `offline` | 看 `/tmp/adb-wifi-watchdog.log` 是否有 `wrapper:` 行；必要时重启 |
| 想恢复 USB ADB | 先**物理拔插 ≥3 秒**（真复位；别用 pnputil 强删/重扫）→ 仍无再 `reboot`；USB2 口是已知全通的口。**2026-10-31 实测补充**：端口类型不是决定因素 —— 当前工作端口挂在 `USB 根集线器(USB 3.0)`（`1022:43FC` / ACPI `XH00`）下、`Port_#0015`、HS 480M，USB ADB + RNDIS + MSC 全通；尚未解释的是「另几个 USB3 口首轮 CNXN 后 bulk `Error 31`」这一按控制器分化的故障，待定位（现场纪要（私人交接未公开发布）.2 / §33） |
| **USB ADB + RNDIS 一起消失**（主机零到达、`g1/UDC` 空、`udc state=not attached`） | v4 隐藏分支遗留的 tmpfs：`umount /dev/usb-ffs/adb` → 重启 adbd → 必要时 `echo a600000.dwc3 > /sys/kernel/config/usb_gadget/g1/UDC`。这是紧急抢修，正常运维仍「永不重启 adbd」；长期修复是 v5（现场纪要（私人交接未公开发布）） |
| 改端口 | 改 `/data/adb-wifi/config` 后 `reboot` |
| `adb usb` 清属性 | 看门狗会补回属性，但要下次 adbd 启动才生效；停用请用 `adb-wifi.sh stop` |
| `第二个 ADB 客户端 offline` | adbd 单客户端；先断开其它 adb 会话（见 [PHONE-CLIENT.md](PHONE-CLIENT.md)） |
| 手机 App 连不上 | 先看是否有别的 ADB 客户端占着槽位（断开后重试），再查端口须 15555、必须主 SSID、SSH 类 App 不可能成功（见 [PHONE-CLIENT.md](PHONE-CLIENT.md)） |

## 回滚

```sh
adb shell '/data/adb-wifi/adb-wifi.sh stop'
adb shell 'sh /data/adb-wifi/remove-boot-hook.sh'
adb shell 'sh /data/adb-wifi/remove-adbd-preset.sh'
adb shell 'kill "$(cat /data/adb-wifi/state/watchdog.pid)" 2>/dev/null'
adb shell 'reboot'      # 回到原厂 USB-only

# 只回退 wrapper 版本（v4 = 事故版本，仅供取证；回完装回 v5）
adb shell 'cp -p /data/adb-wifi/adbd-wrapper.sh.bak-v4 /data/adb-wifi/adbd-wrapper.sh'

# 彻底移除
adb shell 'rm -rf /data/adb-wifi; rm -f /tmp/adb-wifi-*'
```

## 安全

- 无 ADB 认证，端口 15555 只对 `br-lan` 放行；**不要**改回 5555，不要对 WAN 放行。
- 任何连上热点 WiFi 的客户端都能拿 root shell；WiFi 密码就是唯一门槛。
- 控制台严禁暴露到公网；设备上其他免密服务（9999 等）同理。
