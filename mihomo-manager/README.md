# Mihomo WebUI manager

把 Mihomo 状态和受约束的管理操作接入 MU5252 原生 WebUI：

- 运行状态、核心版本、内存和 network namespace；
- 规则/全局/直连模式切换；
- 服务、透明代理、DHCP 网关和 LAN IPv6 开关；
- YAML 读取、检查和原子应用；
- 官方稳定版 arm64 核心检查、摘要校验、更新和失败回滚；
- 日志和 Zashboard 入口。

页面路由为 `requireLogin: true`。前端只调用固定的 `mihomo.api` 方法，后端不接受任意 Shell 命令或任意文件路径。

官方版本查询在设备侧最多等待 20 秒，页面请求在 25 秒后超时并恢复“检查更新”按钮。
管理操作锁记录持有进程；进程退出后可安全回收，有操作正在执行时立即返回忙碌结果。
锁回收通过设备自带的 BusyBox `flock` 串行处理，保护锁的文件描述符不会传给服务进程。
旧版本遗留的无进程记录锁不会自动删除，须先核实不存在仍在执行的管理操作。

## 前提

1. root ADB 已可用；
2. [`../mihomo-netns`](../mihomo-netns/) 已部署；
3. 当前固件与仓库兼容边界相符；
4. 主机安装了 Node.js，用于在本地为当前设备文件增加路由和菜单项。

## 安装

```sh
./install.sh
```

安装器会：

1. 从设备读取当前 `index.html` 和型号路由表；
2. 只添加 `#mihomo_manager` 菜单和登录保护路由；
3. 把补丁后的副本保存到 `/data/mihomo-manager/web-root`；
4. 通过目录/文件 bind mount 添加 RPC、ACL、页面和路由；
5. 在 `rc.local` 写入带边界标记的启动块；
6. 保留 Mihomo 服务安装前的启用状态。

仓库不包含也不会下载完整的原厂 WebUI。重复执行安装器是幂等的。

安装后登录设备管理页并打开：

```text
http://192.168.11.1/#mihomo_manager
```

## 卸载

只读检查：

```sh
./uninstall.sh --check
```

卸载管理页：

```sh
./uninstall.sh
```

卸载只移除管理页自己的文件、挂载和启动块，不删除 Mihomo、配置、namespace 或 DHCP 期望状态。

## 安全边界

- 配置正文固定操作 `/data/mihomo/config.yaml`，权限应保持 `0600`；
- 控制器 secret 从配置中读取，仅在设备本机请求中使用；
- 核心更新只接受 MetaCubeX 官方稳定版 arm64 资产，并校验 GitHub 摘要、大小、版本和配置；
- 页面会显示完整配置和日志，因此设备 WebUI 账号本身必须妥善保护。
