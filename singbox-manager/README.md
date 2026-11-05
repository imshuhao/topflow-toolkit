# sing-box WebUI 管理页（`#singbox_manager`）

把 sing-box 的服务状态与启停接入 MU5252 原生 WebUI。它与
[`../mihomo-manager`](../mihomo-manager/) 的 Mihomo 页面并存：

- `#singbox_manager`：sing-box 现网控制（状态 / 启动 / 停止 / 重启 / 配置检查 /
  日志 / 引擎切换）；
- `#mihomo_manager`：保留为回滚面板，不做改动。

节点与分流仍在 **Zashboard**（`http://192.168.0.1:9999/ui/`）里操作；本页只管
“进程在不在、TUN/DHCP 对不对”，两者职责不重叠。

## 为什么复用 mihomo-manager 的挂载

`mihomo-manager` 用整目录 bind mount 接管了这四个目标：

```text
/usr/libexec/rpcd
/usr/share/rpcd/acl.d
/usr/zte_web/web/js/auth/adm
/usr/zte_web/web/tmpl/auth/adm
```

同一目标只能有一个 bind mount，所以第二个面板**不能**再装一套独立挂载（会遮盖
`mihomo.api`，`mihomo-manager/install.sh` 也会拒绝“已有无关挂载”）。本页因此把
自己的文件放进现有宿主：

| 仓库文件 | 设备路径（被挂载） |
|---|---|
| `rpcd-singbox.api` | `/data/mihomo-manager/rpcd/singbox.api` |
| `singbox-acl.json` | `/data/mihomo-manager/acl.d/singbox.json` |
| `web/singbox_manager.js` | `/data/mihomo-manager/web/js-auth-adm/singbox_manager.js` |
| `web/singbox_manager.html` | `/data/mihomo-manager/web/tmpl-auth-adm/singbox_manager.html` |
| `singbox-manager.sh` | `/data/singbox-manager/singbox-manager.sh` |

菜单与路由改的是 `/data/mihomo-manager/web-root/{index.html,menu.js}`——这两个文件
就是开机时 `mihomo-manager-web` 挂载的那份，所以改完 **reboot 后仍然存在**，不需要
动 `rc.local`。

安装器用 `cat > 目标` 写入（而不是 `adb push` 覆盖），以保持 inode 不变；否则文件
bind mount 会指向旧 inode，页面和开机挂载都会失效。

## 前提

1. root ADB；
2. `mihomo-manager` 已安装（`sh mihomo-manager/install.sh`）；
3. PC 有 Node.js（本地生成菜单补丁）。

## 安装

```sh
sh singbox-manager/install.sh
```

安装后打开：

```text
http://192.168.0.1/#singbox_manager
```

（浏览器缓存了旧 `menu.js` 时，强制刷新一次。）

## 页面能力

| 区域 | 内容 |
|---|---|
| 概览 | 健康状态、当前引擎（sing-box / mihomo / 无）、代理模式、累计流量 |
| 服务与核心 | 运行状态、PID、内存、版本；启动 / 停止 / 重启 |
| 数据面与校验 | `sbtun0` 状态与 v4/v6 地址、DHCP 3/6、provider 数、看门狗、DHCP keeper、手动停止标记 |
| 引擎切换（危险） | `switchover`（切到 sing-box）/ `rollback`（切回 mihomo），两次确认，执行后显示 TUN/DHCP/API 校验结果 |
| 配置检查 | `sing-box check -c config.json`，只读 |
| 运行日志 | `/data/sing-box/state/sing-box.log` 最近 120 行 |

安全边界：前端只能调用固定的 `singbox.api` 方法，后端只映射到
`/data/sing-box/sing-box.sh` 的固定子命令，不接受任意 Shell 或任意路径。

## 卸载

```sh
sh singbox-manager/uninstall.sh --check
sh singbox-manager/uninstall.sh
```

只删除本页的 `singbox.api`、ACL、页面文件、菜单/路由条目和
`/data/singbox-manager`；不动 sing-box、Mihomo、Zashboard 或网络状态。

## 与 sing-box 脚本的关系

`singbox-manager.sh` 不在 `/data/sing-box` 里，也不修改 `sing-box.sh` 的任何
行为，只在外面加一层 JSON 包装与并发锁（`/tmp/singbox-manager.lock`）。命令行
维护方式保持不变：

```sh
adb shell '/data/sing-box/sing-box.sh status'
adb shell '/data/sing-box/sing-box.sh restart'
```
