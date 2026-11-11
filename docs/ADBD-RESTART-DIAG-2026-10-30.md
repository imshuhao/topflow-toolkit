# adbd 重启节律与退出原因 · 只读实测报告（2026-10-30）

- 窗口：2026-10-30 01:16–01:35 +08（设备 UTC 17:16–17:35）；设备 uptime 991→2087s
- 通道：**仅 SSH** `root@192.168.0.1:22622`（paramiko 5.0.0）；全程未用 adb；未改/未重启/未 setprop/未重挂载任何设备对象
- 采样：45s × 18 次（12m47s），每次取 `date`、`/proc/uptime`、`pidof adbd`、`/proc/<pid>/stat`(starttime)、watchdog 日志行数/增量行、`netstat -tn | grep 15555`、`usb/online`、`charger_zte/type_mbb`、`udc state`
- 设备时钟为 UTC，本地 = UTC+8；watchdog 日志混用本地/UTC 时间戳，下表统一换算成 UTC

## 一、结论先行
1. **本 boot 只重启过 1 次 adbd**：+213.7s（pid 22589），之后 **31 分钟 0 次**（`watch:` 心跳每 5 分钟一条，pid 始终 22589）。文档 §24.9「每 ~5 分钟自愈」在本 boot **未复现** → 它是事件驱动，不是定时器。
2. 那次重启紧跟一次 **USB gadget 断开/重绑**：+208.66s `USB_STATE=DISCONNECTED` → +213.73s 新 adbd → +213.84s 由**新 adbd 自己的线程**执行 `configfs_composite_bind`。procd 只是事后按 respawn 拉起。
3. **退出码/信号仍拿不到**（procd 不暴露），但可**排除** segfault/OOM/coredump/配额/看门狗重启（证据见 §三）。
4. 观测窗内 **TCP 15555 一直 ESTABLISHED**（`192.168.0.200:50839`，连接未重建）、`online=1 type=4 UDC=configured` 全程不变 → 无传输抖动，也无重启。
5. 双 ADB 同序列号：USB 序列号权威来源是 **configfs** `/sys/kernel/config/usb_gadget/g1/strings/0x409/serialnumber`（`0123456789ABCDEF`），不是 `ro.serialno`/`/etc/adb_devid`；改成可区分值**技术上可行但不推荐**（见 §五）。

## 二、时间线（UTC；+08 请自行加 8 小时）
| UTC | uptime | 事件（原样摘录/来源） | adbd pid |
|---|---|---|---|
| 17:00:18 | 0 | 开机（由 `1017.33 uptime @17:17:15` 反算，±1s） | — |
| 17:00:21 | +3s | `wrapper: v4: property ready=1 after 1s (port=15555)`（时间戳仍是 2025-01-01，NTP 未同步） | 首实例，未记录 |
| 17:00:31 | +13s | `wrapper: v4: usb host present (online=1 type=4) -> keep functionfs` → `exec /sbin/adbd` | 首实例 |
| 17:00:52 | +34.6 | dmesg：`configfs_composite_bind register usb/scsi hook`（第 4 次 bind，composition_id 0x81） | 运行中 |
| 17:01:14 | +56 | `watchdog: started (pid 21210)` / `apply: listener tcp:15555 up` | 运行中 |
| 17:03:44.66 | +208.66 | **`android_work: sent uevent USB_STATE=DISCONNECTED`** → `rndis0 entered disabled state` → `QCMAP: Interface Down for rndis0` | 此后退出 |
| 17:03:51.73 | +213.73 | 新 adbd pid **22589**（`/proc/22589/stat` 字段22=21373 ticks，精确吻合；wrapper 日志 17:03:52） | 22589 |
| 17:03:51.84 | +213.84 | 新 adbd 线程 T22600：`read descriptors` / `configfs_composite_bind` / RNDIS 重建 | 22589 |
| 17:03:52.18 | +214.18 | `USB_STATE=CONNECTED` → 随后 12 次 `CONFIGURED`（PC 侧重枚举） | 22589 |
| 17:06:14.8 | +356.8 | **第二次** `USB_STATE=DISCONNECTED` + `[ZTE_USB] role[0]→role[2]`、`restart peripheral OFF/ON`；**adbd 未重启** | 22589 |
| 17:05:46 / 17:10:46 / … / 17:30:50 | — | `watch: port=15555 listener=up adbd=22589`（每 5 分钟，pid 不变） | 22589 |

**轮询 18 次（17:21:16–17:34:03 UTC）恒定项**：`pid=22589`、`starttime=21373`、`usb_online=1`、`type_mbb=4`、`udc=configured`、`android_usb=CONFIGURED`、15555 `ESTABLISHED`；日志只增长 2 行，均为 `watch:` 心跳（17:25:49、17:30:50），**无一条 `wrapper:` 行**。

## 三、关键证据（原样输出）
```
# ubus call service list '{"name":"adbd.init"}'
"instance1": { "running": true, "pid": 22589,
  "command": ["/bin/sh","-c","[ -f /data/adb-wifi/adbd-wrapper.sh ] && exec sh /data/adb-wifi/adbd-wrapper.sh; exec /sbin/adbd"],
  "respawn": { "threshold": 3600, "timeout": 5, "retry": 1000 } }
# 无任何 exit/signal 字段（procd 不暴露退出原因）
```
```
# dmesg | grep -iE 'adbd|segfault|oom|killed|out of memory|lowmem'   → 0 行
# dmesg 覆盖完整：首行 [0.000000] Booting Linux…，共 10642 行（环形缓冲未被冲掉）
[ 208.659104] android_work: sent uevent USB_STATE=DISCONNECTED
[ 208.659739] msm-dwc3 a600000.ssusb: ep [ep11in,23] was not configured as msm endpoint
[ 213.804930][T22600] read descriptors
[ 213.838065][T22600] configfs_composite_bind register usb/scsi hook
[ 214.177560] android_work: sent uevent USB_STATE=CONNECTED
```
```
# ls -la /data/tombstones → 只有 cdsp/lpass/modem/slpi/tn，无 adbd
# ls -la /tmp/*.core /tmp/core* → No such file；core_pattern=/tmp/%e.%t.%p.%s.core
# /proc/<adbd>/limits → "Max core file size  0  unlimited"（即使 crash 也不落 core）
# free → Mem 1.63 GB，MemAvailable 1.05 GB；dmesg 'killed process' 计数 = 0
# /logfs/syslog（6.7 MB / 45460 行） grep -aiE 'adbd|procd|respawn|exited|signal' → 0 行
# /logfs/syslog grep -aiE 'segfault|oom|out of memory|lowmem|killed process|panic' → 0 行
# logread 是空壳：syslogd -O /logfs/syslog，timeout 5 logread | wc -l = 1（不能再用 logread 判读）
```
`/tmp/adb-wifi-watchdog.log` 全 17 行中，`wrapper:` 只有开机 3 行 + 17:03:52 的 3 行（共 2 次 wrapper 执行）；`preset:` 只在开机出现 1 次 → 与「仅 1 次重启」互证。

## 四、关联性检验
- 唯一一次 pid 变化（首实例→22589）落在 USB `DISCONNECTED` 之后 **5.07s**，且新 adbd 在 0.1s 后执行 `configfs_composite_bind`；同一窗口 RNDIS 下线又重建 → 与 **gadget 断开/重绑**强相关，与 TCP 无关（15555 当时无客户端：PC 的 adb TCP 连接 inode 196476 创建于 17:06，见下）。
- 17:06（+356.8s）**第二次** `DISCONNECTED` 只伴随 role switch（peripheral OFF→ON），configfs 未解绑、无 bind 事件，**adbd 未退出** → 「USB 一断就死」不成立；更像是「**gadget 被解绑/ffs 被拆**才致死」（假设，未验证）。
- 观测窗内 15555 连接固定为 `192.168.0.1:15555 ← 192.168.0.200:50839 ESTABLISHED`，对端端口未变（同一连接，未重连）；`adb` 侧主动 connect/disconnect 一次都没有发生 → 无重启符合「传输层事件驱动」模型。

## 五、双 ADB 同序列号：来源与改动评估
**实测来源（全部原样）**
```
/sys/kernel/config/usb_gadget/g1/strings/0x409/serialnumber = 0123456789ABCDEF
  manufacturer = ZTE,Incorporated ; product = ZTE Mobile Broadband
  idVendor=0x19d2 idProduct=0x1404 bcdDevice=0x0515 UDC=a600000.dwc3
/sys/class/android_usb/android0/ 只剩 state/usb_op/usb_test/usbnet_*：**无 iSerial/iProduct**
getprop sys.usb.serialno / ro.serialno / ro.boot.serialno → 全空
/proc/cmdline → androidboot.serialno=7234f407 ；/etc/adb_devid = 7234f407（与 USB 描述符不同）
/sbin/start_usb（QTI 脚本）会从 cmdline 取 serialno 写入 configfs —— 但实际值是 0123456789ABCDEF，
  说明当前 gadget 由 ZTE 内核 zte_usb(genl) + /usr/bin/zte_ubus_bsp_usb 组合，**具体写入者未验证**
  （/etc、/data/adb-wifi 内 grep 无该字面串；二进制 strings 未命中；`/config/usb_gadget/g1` 不存在，真实挂载点 /sys/kernel/config）
```
**评估（只评估，未动手）**
- 机制上可行：serialnumber 是 configfs 运行态属性，可在组合后、UDC bind 前改写；重启即丢，需要开机钩子（rc.local 已有同类钩子）幂等重写。
- 主要牵连：① Windows 会当**新 USB 设备**重新枚举 → RNDIS 网卡重建（网卡名/索引可能变，§25.5/§25.6 的 metric 9000/9998、NRPT 依赖按名配置）、USB ADB transport 重建、现有 `adb -s 0123456789ABCDEF` 全部失效；② 仓库 **42 处**硬编码该序列号：私人工作笔记（未公开发布）、`CHANGELOG.md`、`adb-wifi/deploy.sh`、`adb-wifi/README.md`、私人交接文档（未公开发布）（§24.9/§25.2/§25.4/§25.7/§25.8 等）、`docs/TEST-CONFIG-REVIEW-2026-09-08.md`、`docs/SPEED-100MBPS-*.md`、`topflow-toolkit-20260914/*`；③ ZTE 组合流程可能在每次 bind 时重写该文件（未验证）→ 改动不稳定；④ 收益有限：`adb -s`/`ANDROID_SERIAL` 已能区分两条。
- 建议：**不改设备**，PC 侧用 `adb -s 0123456789ABCDEF`（USB）或 `adb -s 192.168.0.1:15555`（TCP），脚本里用 `ANDROID_SERIAL`。

## 六、根因假设（按可能性）
1. **USB gadget 解绑/重绑导致 adbd 的 functionfs 端点失效而退出**（本次唯一重启 5s 内闭环；新 adbd 自己 bind，说明 bind 权限/职责在 adbd 侧；触发者未验证）
2. **ZTE 改版 adbd 对传输层会话结束敏感**（§24.11 已实测：任何 transport 断开都死）——与 1 同源，属机制层
3. 设备侧 USB 守护/组合切换主动 unbind（dmesg 有 composition_id 多次切换，但 208.66 前后未见新 composition_id）
4. 外部 kill / procd 主动 stop（无任何 kill/signal 日志；respawn 计数正常）
5. segfault / OOM / coredump / respawn 配额 → **已排除**
6. 定时器或看门狗重启 → **已排除**（看门狗脚本明确不重启 adbd；31 分钟 0 次）

## 七、下一步验证建议（均不动设备）
1. PC 侧对齐：Windows 事件查看器 USB 断开时间 + `adb devices -l` transport_id 变化，与设备 dmesg `USB_STATE=DISCONNECTED` 对比，判定主机侧还是设备侧发起。
2. 用 SSH 后台 `cat /dev/kmsg`（只读、不落盘）把下一次重启窗口的原始序列抓到 PC；不要用 strace（会扰动且不一定有权限）。
3. 只做单向被动实验：拔/插 USB 线一次，观察「gadget 解绑型断开」是否必致死（对照 +356.8s 的 role-switch 型不致死）。
4. `ubus listen`（只读）捕捉 procd 服务事件，确认 instance 退出与重启的精确时刻。
5. 若一定要改序列号：先只改 PC 侧（`ANDROID_SERIAL` 脚本），设备侧改动需单独评审并同步更新上述 42 处引用。

## 八、未验证（不要当结论）
- +208.66s 解绑的发起者（主机 VBUS/端口复位 vs 设备 USB 守护 vs 组合切换）
- adbd 退出码/信号（procd 不提供，无 core、无 syslog）
- `0123456789ABCDEF` 的具体写入代码/配置（grep 未命中）
- 两次 `DISCONNECTED`（+208.66 / +356.8）性质差异的确切内核路径
- adbd 是否存在内部定时退出逻辑（本 boot 31 分钟未见）
