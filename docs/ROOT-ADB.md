# Root ADB 边界

本项目需要 USB root ADB，但不把“开启 root”混进组件安装脚本。当前默认固件为
`BD_ENCNMU5252V1.0.0B22`，硬件为 ZTE TopFlow MU5252 / `MU5252_HW1.0`。

B20 → B22 的 uci-defaults 迁移已实机保留 root，并通过重启验证，见
[完整升级记录](OTA-B20-TO-B22.md)。以下初始 root 流程是在 B20 上验证的；
B22 配置恢复路径仅做静态兼容分析，尚未以该方法在 B22 重新 root。

## B20 已验证的初始 root 方法

B20 上，登录后台后直接调用 USB debug RPC 会被拒绝。实机可行路径是：

1. 从当前设备导出一份新的官方配置备份；
2. 使用兼容工具解包，在备份内加入 root shell 包装器及对应 `rc.local` 启动项；
3. 完成内外层完整性校验后重新打包；
4. 通过原厂配置恢复入口上传并重启；
5. 通过 USB 验证 `adb shell id`、包装器权限和 bind mount。

这是一条配置恢复路径，不写 boot、system、MTD、启动槽或 bootloader。不要把分区写入、
EDL 或其他机型的镜像作为“更彻底”的替代方案。

可参考 [dklasens/MU5250-OpenUI](https://github.com/dklasens/MU5250-OpenUI)
的备份处理与安全说明，但 MU5252 B20 需要机型适配，不能直接照搬旧机型命令。管理员
密码、备份解密信息、IMEI、原始/解密备份和 `/etc/shadow` 都不应进入命令行日志、Issue
或本仓库。

## 成功标准

重启完成后至少确认：

```sh
adb devices -l
adb shell 'id'
adb shell 'mount | grep "on /bin/adb_shell "'
```

- 目标设备状态为 `device`；多台设备在线时显式选择 serial；
- shell 返回 `uid=0(root)`；
- root shell 覆盖来自预期的 `/data` 路径；
- 原厂 `rc.local` 的其他逻辑仍在，文件可被 `/bin/sh` 解析。

如果设备已经有 root ADB，不要为了“确认流程”再次恢复备份。只读验证比重复改写安全。

## 固件升级

FOTA 可能替换 `rc.local`，从而关闭 root ADB；`/data` 中旧包装器仍可能保留。本次 B20 → B22 可使用已验证的
[迁移脚本](../firmware/b22/root-migration/)保留启动钩子；没有预先迁移而丢失 root 时，应
从新固件导出一份新备份并重新适配恢复流程，不能把旧固件的完整备份或旧 `rc.local` 直接灌
回去。组件恢复层级见 [RECOVERY.md](RECOVERY.md)。
