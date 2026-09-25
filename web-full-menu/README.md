# Full WebUI menu

将 B22 固件中已经存在、但没有加入侧栏或路由白名单的页面开放到厂商管理后台，包括
高级网络设置、双卡、Mesh、VoIP、NCK、日志和诊断工具。

该组件不包含完整 WebUI 文件。安装器通过 root ADB 从目标设备读取当前四个入口文件，
在宿主机上生成补丁副本，再放入 /data 并 bind mount 回只读 Web 根目录。

## 安全边界

- 所有新增路由继续 requireLogin；
- 只移除三个诊断页面的前端许可证跳转，后端原有 debug/license/UCI 检查不变；
- NCK 页面不再无条件显示“网络被锁”，只有后端报告可用尝试次数时才允许输入；
- 安装前逐项确认每个页面的 HTML 和 JS 都存在；
- 通过 source/target 的 device:inode 判断挂载所有权，不依赖本机只显示块设备的
  `/proc/mounts` source 字段；
- 固件结构或补丁锚点不匹配时停止。

## 安装

需要宿主机 Node.js 和 root ADB：

    ./web-full-menu/install.sh

建议先安装 mihomo-manager，再安装本组件。安装器检测到 Mihomo 页面资源后才加入
对应入口。完整菜单的 init 顺序晚于 Mihomo Manager，可以在其 bind mount 上再叠一层，
卸载后仍会露出原有 Manager 页面。

## 卸载

    ./web-full-menu/uninstall.sh --check
    ./web-full-menu/uninstall.sh

卸载只移除本组件自己的 mount、启动块和 /data/local/webui-full-menu，不删除原厂
资源、不删除 Mihomo Manager，也不修改后端配置。

公开补丁器已使用合成 B20 结构测试幂等性。2026-09-24 已在现有 B20 设备上用公开
安装器替换旧归档版本，并验证重启后菜单挂载及 Mihomo RPC 自动恢复。
`tests/device-web-menu-mount.sh` 在设备临时文件上验证原厂底层、Manager 底层、重复
启动、卸载恢复和拒绝未知挂载；以本组件 init 文件路径作为参数运行。
另一台干净设备的完整安装—卸载流程仍未验证。

2026-09-25 核对 B22 的四个被覆盖 Web 文件与 B20 逐字节一致，恢复现有菜单并
通过重启后的后台 HTTP 检查；本次未逐项重跑登录及菜单交互，见 [升级记录](../docs/OTA-B20-TO-B22.md)。
