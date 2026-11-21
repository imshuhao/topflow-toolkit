# mwan3 tuning

修复普通 MULTIWAN 模式下三个相互关联的问题：

1. 原厂全流量规则排在 HTTPS sticky 前面，导致 sticky 实际不命中；
2. 蜂窝链路只做单次极小 Ping，不生成可用延迟/丢包质量；
3. 任一 WAN 事件会清空整个 conntrack 表。

组件为 Mihomo 虚拟网关单独保留非 sticky HTTPS 分流，普通 LAN HTTPS 保持 600 秒
sticky；三路蜂窝采用短采样、多轮防抖；线路失败时只删除对应 fwmark 的 IPv4
conntrack，恢复事件不清理健康连接。

## 不分发厂商脚本

仓库不包含 sdx75_set_mwan3.sh。安装器从目标设备读取当前原厂脚本，要求其 SHA-256
与已验证 B20 文件完全一致，并保存到 /data。运行时 bind mount 的是一个很小的原创
wrapper：先执行设备自己的原厂副本，再应用本项目规则。

摘要不匹配时安装必须停止，不能跳过。

## 配置

默认配置见 config.example：

    TRACK_IPS='199.7.83.42 180.76.76.76 192.58.128.30'
    MIHOMO_SOURCE='192.168.0.254'

> `192.168.11.11` 为历史示例；**本机 Mihomo 网关为 `192.168.0.254`**  
> （本机 Mihomo 网关仍是 `192.168.0.254`；sing-box 宿主态网关是 `192.168.0.1`）。

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

## 聚合模式切回普通模式（2026-10-30 补）

聚合 `SMULTIWAN` 下 mwan3 由厂商 ICG 接管，本调优**不生效**；切回 `MULTIWAN` 时没有任何组件
把调优配置重新加载进运行态——wrapper 调 `apply-rules.sh --no-reload` 只写 uci、不重载 mwan3，
切回后也没人重新 `apply` sing-box wan-balance、没人校验，表现就是「聚合关了但代理没恢复」。

恢复脚本补齐这条链（幂等，仅在 `opms_wan_mode=MULTIWAN` 动作，`SMULTIWAN` 下直接退出）：

    /data/local/mwan3-tuning/recover.sh            # 完整恢复：apply-rules + mwan3 restart + wan-balance apply
    /data/local/mwan3-tuning/recover.sh --verify   # 只读校验（七项 OK/FAIL/SKIP）
    /data/local/mwan3-tuning/recover.sh --check    # 仅状态不一致时才动作（守护用）

    /data/local/mwan3-tuning/install-mode-guard.sh             # 装 cron 守护 */2 * * * * recover.sh --check
    /data/local/mwan3-tuning/install-mode-guard.sh --uninstall # 卸载

`--check` 静默只读：mwan3 未运行、权重漂移（≠6/3/3）、wan-balance ip rules 缺失、或 sing-box
在跑但 `nft ip tf-sbwan` 缺失时才触发恢复；开机 180s 内不动作，`mkdir` 锁防并发，日志
`/tmp/topflow-mode-recover.log` 超 256KB 自动截断。

## 卸载

    ./mwan3-tuning/uninstall.sh --check
    ./mwan3-tuning/uninstall.sh

卸载会移除 wrapper bind mount 和 hotplug 链接，恢复安装前的探测目标；若当前处于
MULTIWAN，则使用安装时保存的原厂脚本重新生成配置并重启 mwan3。它不会切换模式，
也不会改 Mihomo、DHCP 或 IPv6。

公开安装器的“设备本地复制 + wrapper”打包方式尚未在另一台干净设备上完成端到端
安装—重启—卸载验证；底层规则、质量退出和单 WAN 故障清理已在 B20 实机验证。
