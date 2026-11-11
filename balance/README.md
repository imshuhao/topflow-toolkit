# 余量查询（联通 / 电信）

在随身 WiFi 本机查运营商套餐余量，算出「跳点 / 免流」增量，给触屏「余量」页用。

触屏只读 `/data/local/balance/status.json`；本目录负责定时查询与写快照。  
**不要**把真实 `accounts.json`、token、服务密码提交进 git。

## 一句话原理

| | 联通 | 电信 |
|---|---|---|
| 你要准备的 | `token_online`（短信登录或抓包） | 手机号 + 6 位服务密码 + 短信授权 `device_uid` |
| 查询做什么 | 拉流量包剩余/已用 | 拉重要数据余量 |
| 跳点怎么来 | 对比两次快照里「通用已用」的增量 | 同左；定向增量记成免流增量 |

按号码配置，不绑死 5G/4G 槽位。

## 上游出处与许可

本目录是**自行重写**的查询与展示逻辑，对齐下列开源项目公开的登录/查询流程，  
**不是**对其脚本的直接拷贝。公开仓因此仍可与工具包主体一样按 MIT 分发；上游许可如下：

| 用途 | 上游 | 许可 |
|---|---|---|
| 联通短信登录 / `token_online`、流量包查询 | [ChinaTelecomOperators/ChinaUnicom](https://github.com/ChinaTelecomOperators/ChinaUnicom) | GPL-3.0 |
| 电信登录与余量查询 | [ChinaTelecomOperators/ChinaTelecom](https://github.com/ChinaTelecomOperators/ChinaTelecom) | GPL-3.0 |
| 电信 DeviceId 短信授权（解「设备未信任」3006） | [margrop/telecom-phone-device-id-tools](https://github.com/margrop/telecom-phone-device-id-tools) | MIT（Copyright © 2026 margrop） |

完整说明见仓库根目录 [`NOTICE.md`](../NOTICE.md)。

## 目录里有什么

| 路径 | 作用 |
|---|---|
| `balance-query/` | Go 查询器源码（`build.sh` 交叉编译 arm64） |
| `balance-watch.sh` | 定时 / 单次采样 |
| `install.sh` | 设备端 cron + `rc.local` 钩子 |
| `accounts.json.example` | 凭证模板 → 复制为 `accounts.json`（chmod 600） |
| `status.json.example` | 触屏契约示例 |
| `unicom-sms-login.py` | PC 侧联通短信换 `token_online`（备用） |
| `balance-auth/` | **已退役**：授信已并进 WebSSH `:8899`；这里只留源码与卸载脚本 |

设备落点：`/data/local/balance/`。二进制请自行编译，仓库**不分发** `*.arm64` / `*.exe`。

## 凭证

```sh
cp accounts.json.example accounts.json
# 联通填 token_online；电信填 phone + password + device_uid
```

- **联通**：抓 `onLine.htm` 的 `token_online`，或：
  ```sh
  python balance/unicom-sms-login.py send 18600000000
  python balance/unicom-sms-login.py login 18600000000 <验证码>
  ```
- **电信**：营业厅 6 位**服务密码**（不是短信码）+ `device_uid`（短信授权 DeviceId）。  
  密码错常见 `3001`；设备未信任常见 `3006`。
- `limit_re` / `unlimit_re`：可选包名正则，纠正通用/定向归类。

## 构建与安装

```sh
sh balance/build.sh

adb shell 'mkdir -p /data/local/balance'
adb push balance/balance-query.arm64 /tmp/bq
adb push balance/balance-watch.sh /tmp/bw.sh
adb push balance/install.sh /tmp/bi.sh
adb push balance/accounts.json.example /tmp/acc.example
adb shell 'tr -d "\r" < /tmp/bw.sh > /data/local/balance/balance-watch.sh
  tr -d "\r" < /tmp/bi.sh > /data/local/balance/install.sh
  cp /tmp/bq /data/local/balance/balance-query
  cp /tmp/acc.example /data/local/balance/accounts.json.example
  chmod 755 /data/local/balance/balance-query /data/local/balance/*.sh
  sh /data/local/balance/install.sh'
# 再 push 填好凭证的 accounts.json → chmod 600
adb shell 'sh /data/local/balance/balance-watch.sh once'
```

查询默认走本机代理 `http://127.0.0.1:7890`，避免查余量本身计成跳点。

## 触屏怎么显示

固定五行，大字是主数值，小字是补充说明：

| 行 | 含义 |
|---|---|
| 通用余 | 现在还剩多少通用流量 |
| 已跳 | 通用一共用了多少 |
| 已免 | 相对上次采样，定向又免了多少 |
| 共免 | 定向（有限+无限）已用合计 |
| 跳点 | 相对上次采样，通用又少了多少（括号里是今日累计） |

底栏「更新于 / 下次」；点「立即刷新」会跑  
`/data/local/balance/balance-watch.sh once`（固定路径，凭证不上 argv）。  
默认定时约 15 分钟。

## 授信 / 凭证从哪来

推荐：WebSSH 仪表盘 `http://192.168.0.1:8899/app/` →「余量查询」→「授信」
（联通短信 / 电信滑块+短信）。后端补丁在 [`webssh/patches/`](../webssh/patches/)，
按 [`webssh/BUILD.md`](../webssh/BUILD.md) 重编后才有 `/api/balance/*`。

也可以：

- 联通：抓包 `token_online`，或跑 `unicom-sms-login.py`
- 电信：营业厅服务密码 + 短信授权 `device_uid`

**不要**再启退役的 `balance-auth` / `:8898`。
