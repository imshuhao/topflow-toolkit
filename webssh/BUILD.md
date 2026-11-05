# 交叉编译（B20 / linux arm64）

本目录**不附带**上游完整源码树与 arm64 二进制。请自行 clone 上游后套用 `patches/`。

## 上游

1. [`o8oo8o/WebSSH`](https://github.com/o8oo8o/WebSSH) — 原作（GoWebSSH）
2. [`kanoqwq/WebSSH-u60pro`](https://github.com/kanoqwq/WebSSH-u60pro) — U60Pro / TopFlow 面板 MOD（本机基于此）

## 步骤摘要

```sh
# 1) clone kanoqwq/WebSSH-u60pro（或等价 fork）
# 2) 复制本仓库 patches/gossh/app/service/*.go 到 gossh/app/service/
# 3) 按需应用 patches/Empty.vue.diff（或直接对照改 webssh/src/views/Empty.vue / Home.vue）
# 4) 前端
cd webssh && npm ci && npm run build
rm -rf ../gossh/webroot/* && cp -r dist/. ../gossh/webroot/
# 5) 后端（不要 UPX）
cd ../gossh
# 若缺 go.sum：go mod tidy
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o webssh .
```

细节与实机验证见 [`docs/WEBSSH-DEPLOY-2026-10-27.md`](../docs/WEBSSH-DEPLOY-2026-10-27.md)。