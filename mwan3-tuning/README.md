# mwan3 tuning

为普通 MULTIWAN 模式配置定制分流，并改善链路质量检测和故障连接清理：

1. 明确 Mihomo 非 sticky HTTPS、普通 LAN sticky HTTPS、IPv4 默认规则的匹配顺序；
2. 将原厂单次极小 Ping、关闭质量判断的配置改为延迟/丢包采样及多轮防抖；
3. 将原厂 WAN 上下线事件的全局 conntrack 清理改为按故障线路清理。

这里的 HTTPS 规则限定为 IPv4 TCP/443：Mihomo 虚拟网关使用非 sticky 分流，普通 LAN
保持 600 秒 sticky；不包括 UDP/443 QUIC。线路失败时只删除对应 fwmark 的 IPv4
conntrack，恢复事件不清理健康连接。

## B22 核对结论

2026-09-25 对比 B20/B22 原厂文件并只读检查 B22 实机后，确认：

| 项目 | B22 原厂行为 | 本组件的作用 |
| --- | --- | --- |
| HTTPS 顺序 | `etc/config/mwan3` 中 `https` 已在 `default_rule_v4` 前；生成器设置规则但不纠正已有错序 | 安装 Mihomo 与普通 LAN 的定制分流及明确顺序，不再称为修复原厂 HTTPS 错序 |
| 质量检测 | 生成器仍设置 `count=1`、`size=2`、`check_quality=0` | 启用延迟/丢包采样及防抖，仍有必要 |
| 连接清理 | `ifup`、`ifdown`、`connected`、`disconnected` 仍可触发全局清理 | 仅在失败事件按线路 IPv4 mark 删除连接，仍有必要 |

B20 的出厂规则顺序也正确。此前设备保存配置中出现过的错序，不能泛化为 B20/B22
出厂配置的必然缺陷；保留定制规则安装也不代表 B22 必须修复 HTTPS 顺序。

`sdx75_set_mwan3.sh`、`lib/mwan3/mwan3.sh`、`mwan3track`、`15-mwan3` 和
`etc/config/mwan3` 在两个固件中逐字节相同。B22 修改了另一份 `mwan_monitor.sh`
的探测周期及 SMULTIWAN 活动出口管理，未替代上述普通 MULTIWAN 调整。

当次实机三路蜂窝 IPv4 均在线，质量采样已启用，`flush_conntrack` 已移除，定制规则
顺序正确且有实际命中。这次未注入断线或切换聚合模式；具体探测目标和阈值仍需按网络
环境评估，不能据此认定为所有地区的最优参数。

## 不分发厂商脚本

仓库不包含 sdx75_set_mwan3.sh。安装器从目标设备读取当前原厂脚本，要求其 SHA-256
与已验证 B22 文件完全一致（该文件与 B20 同哈希），并保存到 /data。运行时 bind mount 的是一个很小的原创
wrapper：先执行设备自己的原厂副本，再应用本项目规则。

摘要不匹配时安装必须停止，不能跳过。

## 配置

默认配置见 config.example：

    TRACK_IPS='199.7.83.42 180.76.76.76 192.58.128.30'
    MIHOMO_SOURCE='192.168.11.11'

这些探测目标和阈值来自一次真实三 WAN 验证，不保证适合其他地区。安装前应从三条
活动线路分别测试。设备端配置位于 /data/local/mwan3-tuning/config。

## 安装

    ./mwan3-tuning/install.sh

如果设备已存在其他 /sbin/sdx75_set_mwan3.sh bind mount，安装器会拒绝覆盖。当前为
MULTIWAN 时，安装会重启 mwan3 并短暂影响新连接；不会切换普通/聚合模式。

挂载所有权通过 source/target 的 device:inode 判断；`/proc/mounts` 在本机只显示
userdata 块设备，不能用其 source 字段反推 `/data` 中的原始文件。重复 start 不会叠加
挂载，卸载会清理本组件意外留下的连续顶层挂载。

选择性清理映射可以只读检查：

    adb shell 'INTERFACE=zte_mwan4 /etc/hotplug.d/iface/90-mwan3-selective-conntrack --inspect'

## 卸载

    ./mwan3-tuning/uninstall.sh --check
    ./mwan3-tuning/uninstall.sh

卸载会移除 wrapper bind mount 和 hotplug 链接，恢复安装前的探测目标；若当前处于
MULTIWAN，则使用安装时保存的原厂脚本重新生成配置并重启 mwan3。它不会切换模式，
也不会改 Mihomo、DHCP 或 IPv6。

2026-09-24 已将现有 B20 设备从旧 sticky-fix 目录迁移到公开安装器的
“设备本地复制 + wrapper”方式，并验证重启后的 wrapper 和 hotplug 链接。
迁移前后的 mwan3 配置语义一致。另一台干净设备的完整安装—重启—卸载流程仍未验证；
底层规则、质量退出和单 WAN 故障清理已在 B20 实机验证。

2026-09-25 B22 上恢复现有规则并验证最终重启后 MULTIWAN 服务正常；
本次没有重做所有单 WAN 故障与模式切换测试，见 [升级记录](../docs/OTA-B20-TO-B22.md)。
