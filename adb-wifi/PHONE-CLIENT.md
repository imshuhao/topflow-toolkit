# PHONE-CLIENT — 手机端连无线 ADB

> 2026-10-27 实机口径。设备：ZTE TopFlow MU5252 / OpenWrt 23.05.4 / aarch64_cortex-a53。
> 目标：手机不插 USB 也能拿到 root shell。

## 结论

手机端能连的**唯一**前提：客户端走 **ADB 协议**。

本机没有 sshd，也没有 dropbear（`/usr/sbin/sshd`、`/usr/sbin/dropbear`、`/etc/dropbear` 均不存在），
所以任何要填「用户名 / 密码 / 端口 22」的 App 都是 SSH/SFTP 类，**永远连不上**。

ADB 侧没有认证：`ro.adb.secure` 未设置，`/data/misc/adb` 不存在，没有 `adb_keys`。
空密钥库的客户端直接拿到 `uid=0(root)` —— ADB 协议里**没有用户名、没有密码**这两个字段。

## 头号原因：adbd 只服务一个客户端

adbd **同一时刻只服务一个 ADB 客户端**（2026-10-27 实机复现）。槽位被占时，不同客户端症状不同：

| 抢占方 → 受害者 | 症状 |
|---|---|
| 另一个标准 `adb` 客户端 | TCP 连得上，transport 停在 `offline`；`adb -s 192.168.0.1:15555 shell` → `device offline` |
| 手写 / 手机端 ADB 客户端 | 服务端**一个字节都不回**，表现为「像连上了但没反应」或直接超时 |

槽位空出来后，同一端口立即完成握手并返回 `uid=0(root)`。单个 transport 支持并行 shell（两个 `adb shell` 重叠执行都 rc=0）——「一条连接开多个 shell」没问题，**多一条 transport 才是问题**。

手机连之前先在 PC 上放槽位：

```sh
adb disconnect 192.168.0.1:15555     # 必要时 adb kill-server
```

并关掉其它手机 / 平板 / 上次没退干净的 App 会话；手机连上后不要在别处再抢同一台设备。

## App 类型对照

| App 类型 | 是否可行 | 要填什么 |
|---|---|---|
| **ADB 类**客户端<br>示例：甲壳虫ADB助手、ADB WiFi / 无线ADB、Bugjaeger、Termux + `pkg install android-tools` 后 `adb connect` | 可行 | 主机 `192.168.0.1`，端口 `15555`；**账号/密码留空**。App 若强制非空（保存校验），随便填 `root` / `root` 或 `root` / `9999999999@` —— ADB 协议不读这两个字段，填什么都被忽略 |
| **SSH 类**客户端<br>示例：Termius、JuiceSSH、ServerBox、ES 文件浏览器的 SFTP，以及任何出现「用户名 / 密码 / 端口 22」表单的 App | 不可行 | 目标没有 SSH 服务。填 `root` 只会得到端口 22 的 `connection refused` / `no route`。用户名密码填什么都无所谓——没有服务在听 |
| **端口写死**的 App（只能填 IP，默认 5555） | 可行（先开端口别名） | 设备只监听 `15555`（`adbd` 监听 `0.0.0.0:15555`）。在设备上执行 `sh /data/adb-wifi/adb-wifi-portalias.sh on`（另有 `off` / `status`）：LAN 内把 `5555` REDIRECT 到 `15555`。**已验证**：别名开启且无其它客户端时 `adb connect 192.168.0.1:5555` → `device` → `uid=0(root)`；`off` 后 5555 恢复拒绝、15555 不受影响。一次性，重启或重载防火墙后失效需重跑；不碰 adbd / `service.adb.tcp.port` / config / rc.local / 看门狗 |

App 内的菜单名称、按钮文案随版本变化，本文一律不写；上表 App 名称仅作**示例**，不代表已验证其 UI 流程（未验证）。

> **协议证据（SSH 为什么不可能）**：adbd **不先发 banner**，等客户端先说话。客户端 CNXN（310 B，`version=0x01000001`，banner `host::features=shell_v2,cmd`）→ 服务端 CNXN 87 B → **完全没有 A_AUTH** → 直接 OPEN。SSH 客户端只会等 banner，一直等到超时。

## 排障顺序（按命中率）

| # | 检查 | 说明 |
|---|---|---|
| 1 | 是否有别的 ADB 客户端占着槽位 | adbd 单客户端。PC 上 `adb disconnect 192.168.0.1:15555`（必要时 `adb kill-server`），并退出其它手机 / 平板 / 上次没退干净的 App 会话，再连。标准 `adb` 抢槽表现是 `offline`，手写/手机客户端表现是一个字节都不回 |
| 2 | 端口是不是 `1455` / `5555` | 正确值 **`15555`**。写成 1455 或 5555 一律连不上（5555 需先开端口别名） |
| 3 | 手机连的是不是主 SSID `ZTE_TOPFLOW_xxxx` | 必须是主 SSID（2.4G ch6 / 5G ch36 同名，WPA3-SAE-mixed）；不是访客 SSID，也不能是别的 WiFi 或移动数据 |
| 4 | App 是不是 SSH 类 | 出现「用户名 / 密码 / 端口 22」就是 SSH 类，本机无服务，换 ADB 类客户端 |
| 5 | 设备是否刚重启 | 重启后 60–90 秒内 adbd 还没起，等够再连 |
| 6 | 端口是否被封 | 有人跑过 `adb-wifi.sh stop` 会把 `ADB_WIFI` 链改成 REJECT（立即 RST）；`start` 即恢复 |

访客 SSID `ZTE_TOPFLOW_xxxx_Guest` 是**关闭**状态：`wireless.guest_2g.disabled='1'`、`wireless.guest_5g.disabled='1'`；`iw dev` 只有 `wlan0` / `wlan2`，两个主 BSS 都广播 `ZTE_TOPFLOW_xxxx`（2.4 GHz ch6 / 5 GHz ch36，同名，无 `_5G` 后缀）。所以**不要连、也不要推荐**访客 SSID——它根本没广播。而且即使打开它也不隔离：guest 网络挂在 `br-lan`（`network='lan'`，无独立网桥，`isolate=0`，两个 hostapd conf 都没有 `ap_isolate`），因此**隔离不是**连不上的原因。

## USB 不能兜底

本机 `br-lan` 只含 `wlan0` + `wlan2`，没有 `rndis0`；当前 USB gadget 是 **HID-only**（无 RNDIS、无 ADB 接口）。当前 gadget 配置下 USB 不提供 ADB/RNDIS，插 PC 也拿不到 adb；重启后是否重新枚举**未验证**。

## 一行验证

手机端连上后执行：

```sh
id
```

应返回 `uid=0(root)`。PC 侧对照（同一时刻）：

```sh
adb -s 192.168.0.1:15555 shell id
```

两边输出一致即链路与权限都正常。若手机侧连不上而 PC 侧正常，先查是不是 PC 自己的 `adb` 占着槽位（见「头号原因」），再查手机所在 SSID 与 App 类型——都不在设备侧。

## 禁止事项

- **不要**对 WAN 放行 15555，也不要把端口改回 5555 监听；防火墙 `ADB_WIFI` 链只放行 `lo` 与 `br-lan`，其余 DROP 是有意设计。
- **不要**让多个客户端同时连 15555：adbd 只有一个槽位，后来者会把先到者挤成 `offline`，双方都以为「设备坏了」。
- **不要**在运行时重启 adbd：会拆掉 functionfs，USB gadget（含 RNDIS）整体消失，只能整机重启恢复。
- 同一 WiFi 下**任何**设备都能免密 root —— WiFi 密码是唯一门槛，主 SSID 的 key 等同于 root 口令，不要外传。
- 不要把该端口经端口映射、内网穿透或 DMZ 暴露到公网。
