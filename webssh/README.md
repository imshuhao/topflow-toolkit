# webssh — B20 局域网 Web 终端

在设备 LAN 上提供浏览器终端与简易仪表盘：`http://192.168.0.1:8899/app`，内置 sshd `192.168.0.1:22622`。  
本目录是 **TopFlow MU5252 B20 的部署包装 + 设备补丁**，**不是** WebSSH 完整上游源码树，也**不附带** arm64 二进制。

## 出处（请保留）

| 层级 | 项目 | 说明 |
| --- | --- | --- |
| WebSSH 原作 | [`o8oo8o/WebSSH`](https://github.com/o8oo8o/WebSSH) | GoWebSSH（MIT，Copyright © 2021 o8oo8o） |
| 面板 MOD | [`kanoqwq/WebSSH-u60pro`](https://github.com/kanoqwq/WebSSH-u60pro) | U60Pro / TopFlow 向改版；本机交叉编译基于此 |
| 设备工具包上游 | [`imshuhao/topflow-toolkit`](https://github.com/imshuhao/topflow-toolkit) | 本 fork 所基于的 TopFlow 改机工具包（MIT） |
| 本目录 | 本分支 `webssh/` | B20：ubus 兼容、三卡 `/api/modems`、余量授信 `/api/balance/*`、`start.sh` / rc.local |

二进制与前端构建步骤见 [`BUILD.md`](BUILD.md)。实机纪要见 [`docs/WEBSSH-DEPLOY-2026-10-27.md`](../docs/WEBSSH-DEPLOY-2026-10-27.md)。

## 本分支相对上游 WebSSH 的改动

- `patches/gossh/app/service/ubus_compat.go`：B20 上 `get_wwandst` / `get_wwaniface` 缺 `subid` 会失败 → 白名单兼容 + 9460 兜底  
- `patches/gossh/app/service/modems.go`（及测试）：`GET /api/modems` 三卡（x75 / v3e2 / v3e1）  
- `patches/gossh/app/service/balance_*.go` + `main.go.balance-routes.diff`：余量 status + 联通/电信授信（JWT 组）  
- `patches/Empty.vue.diff`：仪表盘三卡；`Empty.balance.vue.fragment`：余量五行 + 授信面板  
- `start.sh` + `install-rc-local.sh`：busybox 无 `-d`、必须 `-ConfigDir /data/webssh`，只绑 `192.168.0.1`

## 设备落点

| 项 | 值 |
| --- | --- |
| 目录 | `/data/webssh/` |
| Web | `http://192.168.0.1:8899/app`（仅 LAN） |
| sshd | `192.168.0.1:22622`（连接条目也必须写这个地址，不要 `127.0.0.1`） |
| 配置 | `/data/webssh/.GoWebSSH/GoWebSSH.toml` |

## 安装（已有二进制时）

```sh
adb shell 'mkdir -p /data/webssh /data/webssh/.GoWebSSH'
adb push webssh/start.sh /tmp/start.sh
adb shell "tr -d '\r' < /tmp/start.sh > /data/webssh/start.sh; chmod 755 /data/webssh/start.sh"
# 自行推送交叉编译产物到 /data/webssh/webssh 并 chmod 755
adb push webssh/GoWebSSH.toml.example /tmp/gowebssh.toml
adb shell "tr -d '\r' < /tmp/gowebssh.toml > /data/webssh/.GoWebSSH/GoWebSSH.toml; chmod 600 /data/webssh/.GoWebSSH/GoWebSSH.toml"
adb push webssh/install-rc-local.sh /tmp/i.sh
adb shell "tr -d '\r' < /tmp/i.sh > /data/webssh/install-rc-local.sh; chmod 755 /data/webssh/install-rc-local.sh; sh /data/webssh/install-rc-local.sh"
adb shell 'start-stop-daemon -S -b -x /data/webssh/start.sh -m -p /tmp/webssh.pid'
```

首次初始化用 [`init.json.example`](init.json.example) 改口令后：

```sh
curl -s -X POST http://192.168.0.1:8899/api/sys/init \
  -H 'Content-Type: application/json' --data-binary @init.json
```

## 不要做的事

- 不要把二进制默认绑 `0.0.0.0`  
- 不要用 `/etc/init.d` 自启（B20 overlay 上 rcS 不跑新增 init）  
- 不要提交真实口令、`gowebssh.db`、JWT/session secret、UPX/未 strip 取证包  

## 许可

- 部署脚本与本目录补丁：随本仓库 MIT（见根目录 [`LICENSE`](../LICENSE)，版权归属上游 **imshuhao contributors**）  
- 套用的 WebSSH 源码 / 二进制：遵循 [`o8oo8o/WebSSH`](https://github.com/o8oo8o/WebSSH) MIT 与 [`kanoqwq/WebSSH-u60pro`](https://github.com/kanoqwq/WebSSH-u60pro) 其仓库声明  
