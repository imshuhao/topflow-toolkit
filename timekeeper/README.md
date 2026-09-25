# Timekeeper

在原厂网络校时完成后，通过设备已有的 Qualcomm time_genoff 基准 12 保存可信时间
偏移。下次开机时，原厂 time_daemon 可以在联网前恢复合理的系统时间，避免 RTC
停在 1970 年时 TLS 服务和 Mihomo 无法启动。

它不修改物理 RTC。对已审核的 B22 NTP、NITZ 程序应用 UTC 兼容补丁，
保留原厂网络授时协议。procd watcher 每 30 秒检查实际成功写入系统时钟的事件，
只保存本次开机 120 秒以内的 NITZ/SNTP 事件，并用单调时钟核对系统时间未被再次改写。
旧的同步标志不能触发保存；持续离线不会超时退出，同一事件不会因 watcher 重启而重复保存。

## UTC 校时与本地显示

B22 原厂 ntpclient 会在 NTP UTC 秒数上叠加时区和夏令时，再写系统时钟。仅安装
UTC+8 TZif 会让联网后的本地显示重复加 8 小时，并把错误 Unix 时间保存到 base 12。

安装器通过 ADB 私下读取设备自己的 ntpclient，先核对完整 SHA-256，再生成兼容副本。
补丁只将 `0x4d44` 改为跳转到 `0x4e88`，绕过时区/DST 算术；NTP 秒与小数转换、
包校验、clock_settime 和后续通知不变。原厂二进制不进入仓库或发布包。未知固件拒绝安装。

通过 bind mount 加载副本，原厂只读分区不变。组件注册 `S10timekeeper`，并在
原厂 `/etc/init.d/zte_topsw_ntp` 的 `start_service` 开头加入可撤销的前置步骤；
实机没有标准 `rcS` 脚本，不能只依赖 S10/S49 的编号保证先后。首次启用会丢弃旧同步标志，通过原厂启动脚本重新启动 NTP 客户端；只有
新的成功结果才能保存偏移。已有客户端仍映射未修复程序时禁止保存。

组件将原厂保存的固定偏移转换为
POSIX TZ（UTC+8 为 `CST-8`），同步到系统 UCI 和 `/tmp/TZ`。实机还确认 B22 的
libc 不使用 `/etc/TZ` 文本，因此生成固定偏移 TZif v2 文件
`/data/timekeeper/localtime`，让 `/etc/localtime` 持久指向它，供进程从启动时读取。
时区显示本身不调整 Unix 时间；真实 NTP 同步负责把系统时钟恢复为 UTC。升级后
如果持续离线，已有的错误系统时钟和偏移不会被盲目减 8 小时，必须等待新鲜同步。

支持 -12 至 +14 小时、整分钟的固定偏移。原厂启用夏令时或网络自动时区时，释放
组件管理的固定时区和 NTP/NITZ 挂载，交给原厂处理，且停止保存可信偏移；这些模式尚未
实现标准 UTC 兼容，安装器要求关闭它们。遇到未提交的系统 UCI 编辑时暂缓应用，避免
提交其他设置。设置变化每 30 秒检查一次，但已缓存时区的原厂进程需要重启才能
更新显示；首次安装或变更时区后建议重启设备。

## NITZ 运营商授时

B22 的 `zte_topsw_nwinfo` 另有运营商授时路径，会把 QMI UTC 日历转换为 Unix 秒后，
再加上带符号的时区值 × 900 秒。此设备的时区值 32 导致 Unix 时间再次快 8 小时，
所以只修复 ntpclient 不足以防止 NITZ 切换后的回退。

`patch-nwinfo.py` 对已审核的完整固件哈希，将 `0x31bb0` 的时区加法替换为普通寄存器
复制；UTC 日历转换、有效性检查、时区元数据、成功标志和通知不变。安装器私下读取
设备原程序，生成 `/data/timekeeper/nwinfo.utc` 并 bind mount；不分发厂商二进制。
`zte_topsw_nwinfo` 的实际启动入口增加 `prepare-nitz` 前置步骤。升级时仅重启仍映射
旧二进制的 nwinfo 进程，触发重新获取运营商时间。保存可信偏移前同时检查 NTP 和
NITZ 程序及运行进程的哈希，避免旧进程仍写入偏移时间。

`clock-observer.so` 通过两个原厂服务的 procd 环境加载，只观察审核过的调用位置。
NITZ 与 SNTP 的 `clock_settime` 成功后生成 root 专用事件，记录来源、内核启动标识、
UTC 与启动时间；失败调用不产生成功事件，其他写钟位置会使旧事件失效。
保存前还检查 NTP/NITZ 程序及运行进程的完整哈希、事件年龄和当前时钟连续性，
避免旧标志、旧进程、上一轮开机或后续手动改钟被当作新鲜网络授时。

## 重启恢复与基带时间

保留原厂 `time_daemon` 的恢复顺序：优先 base 1（基带 TOD），缺失时回退
base 12（应用侧保存的偏移）。这是一项来源选择策略；没有证据证明它本身导致了
历史约 19 秒偏差。组件不修改 time_daemon、它的服务入口或基带时间处理路径。

原厂随后仍可根据 modem 返回的 TOD 改写系统时间。因此保存 base 12 并不意味着
每次开机都会优先使用它，也不保证此后系统时间不会变化。当前时钟连续性检查只用于
拒绝保存已经被后续改钟覆盖的旧授时事件，不阻止原厂写钟。秒级漂移根因仍未确定。

## 兼容性

当前安装器默认且仅接受以下 B22 二进制；历史 B20 记录见后文：

- MU5252_HW1.0；
- BD_ENCNMU5252V1.0.0B22；
- /usr/lib/libtime_genoff.so.1 和应用基准 12；
- /etc/init.d/zte_ubus_bsp_rtc.init。

安装器会检查这些运行依赖。固件升级后必须重新验证，不能假设其他 ZTE/Qualcomm
设备使用相同基准或服务路径。

## 构建

需要 Docker、Python 3 和 root ADB：

    ./timekeeper/build.sh

脚本固定构建 Linux/arm64 musl 的 time-genoff、clock-event 和 clock-observer.so，
输出到 timekeeper/build/。仓库不分发预编译 helper 或原厂二进制。

## 安装与检查

    ./timekeeper/install.sh
    adb shell '/data/timekeeper/timekeeper.sh status'
    adb shell 'cat /tmp/timekeeper.log'

只有 UTC 兼容路径有效、系统时间位于 2026-01-01 至 2100-01-01，且收到新鲜的
成功 NITZ/SNTP 写钟事件时才保存偏移。写入期间会暂时停止占用 /dev/rtc0 的原厂
RTC 服务，并在退出时恢复；读回验证成功后标记该事件已保存。

`last_saved_epoch=none_this_boot` 表示本轮开机尚未成功保存，`last_saved_event`
显示保存来源及对应启动时间。`local_time`、`configured_timezone`、`effective_timezone`
和 `libc_timezone_file` 用于核对显示。离线等待只记录状态变化，日志超过 64 KiB
后轮转一份；procd 为异常退出提供有界重启。

## 卸载

    ./timekeeper/uninstall.sh --check
    ./timekeeper/uninstall.sh

卸载只在组件所有权标记存在时删除 `/data/time/ats_12`。如果首次安装前该偏移已经
存在，安装器不会取得其所有权，卸载时也不会删除。卸载撤销 NTP/NITZ 兼容挂载和事件观察环境，并重新启动对应原厂服务；后续原厂校时恢复固件原有的时间语义。

安装前的 timezone/zonename 单独备份，卸载时仅在系统仍使用本组件最后写入的配置时
恢复，保留用户后续自行修改的配置；组件拥有的 `/etc/localtime` 链接恢复到原厂
`/tmp/localtime`。重启可清除原厂长驻进程的时区缓存。

## 验证

    python3 timekeeper/test_timekeeper.py
    make check

### 历史 B20 实机记录

2026-09-13 在 B20 上离线重启后，系统与原厂 `get_systime` 均返回 UTC+8，原厂
RTC 服务和 watcher 正常，未同步期间可信偏移的校验值保持不变。隔离测试覆盖晚于
10 分钟才联网、再次同步、服务重启、时区正负偏移及非整小时偏移、TZif 解析至
2099 年、幂等应用与回退、用户设置保护和夏令时切换。上次验证未覆盖真实联网成功，未发现原厂会再次叠加时区的问题。

2026-09-24 UTC 兼容修复已执行提取二进制的 AArch64 指令仿真，覆盖 UTC、+8、
-5、+5.5、+12.75，写时钟参数均保持 UTC。实机先阻断 NTP 验证旧偏移不被保存，
恢复后原厂服务器真实同步成功：Unix 时间与主机相差不足 1 秒，`date` 和原厂
`get_systime` 均显示 UTC+8，base 12 更新为正确时间。

暂停 NTP 自启后实机重启，未同步阶段未复现 8 小时偏移，base 12 校验值保持不变。
该次离线恢复比电脑快约 19 秒；后续隔离审计未复现，旧样本没有同时记录两份基准，
因此不能把这 19 秒的历史误差确定归因于某一条路径，也不能宣称离线精确校时。
恢复 NTP 后再次真实同步、自动保存成功，Unix 秒与主机相差约 1 秒。重复安装及
watcher 重启未重复写入已保存的偏移。加上原厂 NTP 启动前置步骤后，第二次正常
自动重启中，原厂客户端直接加载 UTC 副本，约 50 秒时已经同步成功。手动设置时间尚未完成 UTC 兼容验证，
未在实机切换手动模式；DST/网络自动时区不在 UTC 兼容支持范围。

实机验证边界和统一恢复顺序见 [RECOVERY.md](../docs/RECOVERY.md)。

2026-09-24 补齐 NITZ 后，原始与修补后的 AArch64 指令分别通过 81 组日历/时区/DST
输入验证（含负时区、半小时、四十五分钟、闰日和 2040 年）。实机临时阻断 NTP 后，
重启 nwinfo 重新获取 NITZ，UTC 与电脑相差约 2 秒，三网地址与 DNS 正常；
当时的旧 watcher 只接受 SNTP，因此该轮没有更新 base 12；本次已改为验证真实写钟事件。

补齐后正常重启，NTP 和 NITZ 的 UTC 副本均自动加载；SNTP 同步与 base-12 保存成功，
最终实测 UTC 与电脑相差约 0.3 秒，原厂 get_systime 显示正确 UTC+8，三网地址与 DNS 正常。

当前 22 项 shell/Python 回归、原生事件校验测试与 `make check` 通过，覆盖新鲜事件、
过期事件、上一次开机的事件、后续改钟及重复保存。真实 SNTP 写钟事件已被观察、
自动写入 base 12 并读回成功。

NITZ 的 UTC 写钟已在前一轮实机验证，但本轮重新启动 nwinfo 后没有收到新鲜的
NITZ 写钟事件，因此本次 NITZ 事件到持久化的全链路仅通过隔离回归测试，尚缺新的
真实运营商事件验证。卸载全链路也未在当前设备上执行；安装前原件与偏移已保留备份。

恢复原厂启动优先级后，已核对 time_daemon 文件和运行进程均为原厂完整哈希，
服务入口无组件前置步骤，RTC 服务正常；保留 NTP/NITZ UTC 修复和事件保存。

### 当前 B22 验证

2026-09-25 在 B22 完成安装及重启验证：新 SNTP 写钟事件成功经 base 12 保存，
UTC 与电脑相差不到 1 秒；B22 NITZ 的补丁和观察器地址通过静态核对与指令模拟，
本次没有重做全部运营商 NITZ/离线场景。完整记录见 [升级记录](../docs/OTA-B20-TO-B22.md)。
