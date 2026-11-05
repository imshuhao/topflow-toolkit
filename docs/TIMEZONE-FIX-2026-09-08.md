# TopFlow MU5252 B20 时间修复 · 2026-09-08

> 触发：代理节点（VMess 等）全部不可用，墙钟比真实 UTC **快约 8 小时**（把「本地 UTC+8」写进了 Unix epoch）。  
> 对照过同类随身路由的时区修复思路；B20 污染路径见下，与 modem NITZ 主因不同。

## 实测结论

1. **症状**：修复前 `date -u` 比真实 UTC 快约 8 小时；TLS/VMess 因此集体失败。
2. **污染源（运行中）**：用户态 `zte_topsw_ntp` / `ntpclient`，按 `time_from_utc='8.00'` 一类逻辑把「本地时间」写进系统时钟；孤儿 `ntpclient` 持续运行。当时 `nitz_sync_flag:0`，modem NITZ 并非主因。
3. **time-genoff 在 B20 上可能不可用**：zig/musl 静态产物 `dlopen libtime_genoff.so.1` 失败时，ats_12 持久化不可靠；原厂 `time_daemon` / RTC 路径保留。
4. **显示 vs 墙钟必须拆开**：系统时钟必须是 **真实 UTC epoch**；北京时间只用 `TZ=CST-8` / TZif **显示**，绝不能再给 epoch 加 8 小时。

## 修复分层

| 层 | 做法 | 仓库落点 |
|---|---|---|
| 源头 | ntpclient / nwinfo UTC 兼容补丁（bind-mount，不分发原厂二进制） | [`timekeeper/`](../timekeeper/) |
| 安全网 | HTTP Date 初始同步 + 持续守卫；直连失败可走 `127.0.0.1:7890` | [`timekeeper/fix-time-http.sh`](../timekeeper/fix-time-http.sh) |
| 显示 | 触屏 `start.sh` 启动 devui 时 `TZ=CST-8` | [`touchscreen-control-center/start.sh`](../touchscreen-control-center/start.sh) |
| 开机 | 按需限制 sysfixtime 用污染 mtime 回拨（设备侧 overlay） | 设备 `/etc/init.d/sysfixtime` |

## 验证要点（实机）

- `date -u` 与公网 HTTP `Date` 头相差约 1s（真实 UTC）。
- 代理节点延迟探测恢复可用。
- `zte_topsw_devui` 环境含 `TZ=CST-8`，触屏 hook maps 正常。

## 不要做的事

- 不要只装 UTC+8 TZif 却不修 ntpclient：会 **显示再加 8 小时**，并把错误 epoch 存进 base 12。
- 不要把 HTTP Date 解析跑在 `TZ=CST-8` 下而不 pin `TZ=UTC`：busybox `date -d` 会把 GMT 头再减 8h。
- 仓库不分发厂商 NTP/NITZ 二进制；补丁在设备上对已审核哈希生成。
