# balance-auth — 余量授信旁路

WebSSH 仪表盘「打开授信页」→ `http://192.168.0.1:8898/`。

- **联通**：短信 → `token_online` → 写入 `/data/local/balance/accounts.json`
- **电信**：滑块+短信 → DeviceId（+可选服务密码）→ 同上，并缓存 `telecom-login-*.json`

仅绑 `192.168.0.1:8898`。自启：`install-auth.sh` 写 rc.local 块。

```sh
# 本机构建
cd balance/balance-auth
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o ../balance-auth.arm64 .

adb push balance/balance-auth.arm64 /tmp/ba
adb shell 'cp /tmp/ba /data/local/balance/balance-auth; chmod 755 /data/local/balance/balance-auth'
adb push balance/balance-auth/start.sh /tmp/s.sh
adb shell "tr -d '\r' </tmp/s.sh >/data/local/balance/start-auth.sh; chmod 755 /data/local/balance/start-auth.sh"
adb push balance/balance-auth/install.sh /tmp/i.sh
adb shell "tr -d '\r' </tmp/i.sh >/data/local/balance/install-auth.sh; sh /data/local/balance/install-auth.sh"
```
