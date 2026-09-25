# B22 升级材料

**当前主分支默认 B22**。时间与触屏适配直接位于根目录 `timekeeper/` 和
`touchscreen-control-center/`，按各组件说明编译安装，无需选择覆盖层。
B20 代码与历史验证保留在 Git 历史；不要用当前 B22 构建覆盖 B20。

完整执行过程和验证边界见 [B20 → B22 升级记录](../../docs/OTA-B20-TO-B22.md)。

- `root-migration/`：这次跨升级保留 root 的原创脚本。`prepare.py` 从私有、已审核的
  B22 `rc.local` 生成迁移文件及 SHA256SUMS；不连接设备，也不触发 OTA。
- `root-migration/boot-services.sh`：本次已有组件的 B22 启动恢复入口；不是全新安装器。
- `manual-ota.patch`：停用 `zte_dm` 时同步去掉原厂开机等待项，避免卡住初始化。

原厂 `rc.local`、OTA、修补后的厂商二进制、私有配置与抓包不随仓库分发。
