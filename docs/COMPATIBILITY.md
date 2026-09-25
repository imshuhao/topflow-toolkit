# Compatibility boundary

## 版本提示

`v1.0.0` 起默认固件从 B20 改为 B22。这是兼容性变化：当前时间和触屏安装器会拒绝
B20；工具包 release 不包含 B22 固件，也不会自动升级设备。B20 用户应保留经过验证的
B20 代码，先阅读 [B20 → B22 升级记录](OTA-B20-TO-B22.md)，确认升级与恢复条件后
再使用本版本对应组件。主版本号不代表所有设备和生命周期场景均已验证。

不要部署 `v0.1.0` 中的 `web-full-menu` 或 `mwan3-tuning`：该版本错误地把
`/proc/mounts` 的 source 字段当作单文件 bind mount 的原始路径，在 B20 上会造成重复
挂载，并可能让停止或卸载遗漏自身挂载。请使用 `v0.1.1` 或更新版本；新版通过
source/target 的 device:inode 判断所有权，并在升级、停止和卸载时清理连续的自身挂载。

当前主分支默认面向商品名 ZTE TopFlow、硬件 `MU5252_HW1.0`、固件
`BD_ENCNMU5252V1.0.0B22`。B20 的源码和验证记录保留在 Git 历史，当前时间和触屏安装器会拒绝 B20。
MU5252 是内部硬件标识，不是项目名，也不代表其他
同名外观或其他地区固件自动兼容。

## 固件相关接口

| 范围 | 当前依赖 |
| --- | --- |
| WebUI | `/usr/zte_web/web` 目录、U60Pro 菜单格式、`requireLogin` 路由和 RPC/ACL |
| 网络 | `br-lan`、`zte_wan`/`zte_mwan*`、`mwan3`、`mmx_mask`、`iptables`、`ebtables`、`ip netns` |
| 普通模式 | `/sbin/sdx75_set_mwan3.sh` 的已知 B20/B22 相同 SHA-256 与原厂调用路径 |
| 聚合模式 | `SMULTIWAN`、厂商 ICG 透明代理、`tun0` 和模式切换服务 |
| 时间 | `/usr/lib/libtime_genoff.so.1`、基准 12、原厂 RTC/SNTP UBus 对象 |
| 触屏 | 非 PIE `zte_topsw_devui`、LVGL ABI、进程内函数/素材地址和启动顺序 |
| 持久化 | `/data`、procd/OpenWrt init，以及 `/etc/rc.local` fallback |

`zwrt-datad` 要求上游 v0.9.21 或更新版本；更高版本仍需通过健康检查和界面实测，不能
仅凭版本号推断所有 schema/控制能力不变。

## 新固件验证门槛

不要只因为型号相同就把新固件 SHA 加入 allowlist。至少要验证：

1. 安装前检查会拒绝不匹配的厂商文件；
2. 安装、正常运行、停止和重复启动；
3. 锁屏、熄屏、页面切换与每秒状态刷新；
4. DHCP 接管和撤销后的客户端恢复；
5. 普通/聚合模式切换以及 Mihomo 串联；
6. 故障启动、服务崩溃、回退和完整卸载；
7. 重启持久化与 FOTA 后的恢复边界。

FOTA 可能替换 `rc.local`，但保留 `/data`。升级后从新固件重新取得基线，不要把旧
固件整份 `rc.local` 覆盖回来。恢复策略见 [RECOVERY.md](RECOVERY.md)。

## B22 已完成的验证

2026-09-25 完成原厂 OTA、root 迁移、时间/触屏适配、服务恢复及修复后的重启验收。
这不代表上面所有生命周期场景都已在 B22 重跑；详细范围见 [升级记录](OTA-B20-TO-B22.md)。
