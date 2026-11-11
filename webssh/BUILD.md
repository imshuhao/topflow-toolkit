# 交叉编译（B20 / linux arm64）

本目录**不附带**上游完整源码树与 arm64 二进制。请自行 clone 上游后套用 `patches/`。

## 上游

1. [`o8oo8o/WebSSH`](https://github.com/o8oo8o/WebSSH) — 原作（GoWebSSH）
2. [`kanoqwq/WebSSH-u60pro`](https://github.com/kanoqwq/WebSSH-u60pro) — U60Pro / TopFlow 面板 MOD（本机基于此）

## 步骤摘要

```sh
# 1) clone kanoqwq/WebSSH-u60pro（或等价 fork）
# 2) 复制本仓库 patches/gossh/app/service/*.go 到 gossh/app/service/
#    （含 ubus_compat / modems / balance_*）
# 3) 在 gossh/main.go 的 JWT 认证组挂上余量路由：
#    参考 patches/gossh/main.go.balance-routes.diff
# 4) 前端 Empty.vue：
#    - 先套 patches/Empty.vue.diff（三卡仪表盘）
#    - 再按 patches/Empty.balance.vue.fragment 粘贴余量+授信 TEMPLATE/SCRIPT/STYLE，
#      并在仪表盘刷新成功后调用 fetchBalance()
# 5) 前端构建
cd webssh && npm ci && npm run build
rm -rf ../gossh/webroot/* && cp -r dist/. ../gossh/webroot/
# 6) 后端（不要 UPX）
cd ../gossh
# 若缺 go.sum：go mod tidy
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o webssh .
```

### 余量 API（并进本进程）

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| GET | `/api/balance/status` | 直读 `/data/local/balance/status.json` |
| GET | `/api/balance/accounts` | 授信摘要（不回显密钥） |
| POST | `/api/balance/unicom/send` / `login` | 联通短信换 `token_online` |
| POST | `/api/balance/telecom/*` | 电信滑块 + 短信 + 服务密码写 `device_uid` |

全部挂在 WebSSH JWT 组内（`Authorization: <JWT>`，无 Bearer 前缀）。  
**不要**再启退役的 `balance-auth` / `:8898`。

细节与实机验证见 [`docs/WEBSSH-DEPLOY-2026-10-27.md`](../docs/WEBSSH-DEPLOY-2026-10-27.md)。
