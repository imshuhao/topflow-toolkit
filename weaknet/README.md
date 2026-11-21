# weaknet — 弱网黑匣子（与现行分流同信号）

设备自记证据，现场可用 WebSSH 出报告。采集口径与
`singbox/singbox-wan-balance.sh` 的 **QUALITY / BIAS** 对齐，**不再**自跑
三卡×5 包 ICMP（那会和 mwan3track 数字对不上）。

## 记什么

每 ~30s 一行 JSON：

| 字段 | 来源 | 用途 |
| --- | --- | --- |
| `preset` / `pool_mode` / `quality` / `bias` | `wan-balance.conf` + state | 现行分流预设 |
| `q` | `state/wan-balance.quality` | 与分流相同的 `ok/weak/drop:lat:loss` |
| `w_tcp` / `w_udp` | `state/wan-balance.weights.*` | 质量降权 + 软偏置后的有效权重 |
| `cards.*.lat/loss` | `/var/run/mwan3track`（或 `/tmp/run/mwan3track`） | 与 `iface_track_metrics` 相同：取 max |
| `cards.*.cls/w_*` | 上表解析 | 每卡质量档与权重 |
| `radio` + `radio.snap` | 9460 `/state` | 5G RSRP 辅助（分流读 snap） |
| `proxy` / `dns_ms` | 7890 / 本机解析 | 用户面是否真卡 |

阈值对照（分流默认）：enter `lat≥600` 或 `loss≥30` → weak；drop `1500/70`；
5G `rsrp≤-105` 辅助 weak；TCP/UDP 软偏置仅 `PRESET=auto`。

## 组件

| 文件 | 作用 |
| --- | --- |
| `weaknet-watch.sh` | 常驻采集 |
| `weaknet-report.sh` | 中文报告；`--live` 只看当前分流 |
| `install-weaknet.sh` | rc.local 自启 / `--uninstall` |

数据：`/data/local/weaknet/<YYYYMMDD>.jsonl`（保留 7 天），事件 `events.log`。

## 安装

```sh
adb push weaknet/weaknet-watch.sh /tmp/w.sh
adb push weaknet/weaknet-report.sh /tmp/r.sh
adb push weaknet/install-weaknet.sh /tmp/i.sh
adb shell 'mkdir -p /data/local/weaknet
  tr -d "\r" < /tmp/w.sh > /data/local/weaknet/weaknet-watch.sh
  tr -d "\r" < /tmp/r.sh > /data/local/weaknet/weaknet-report.sh
  tr -d "\r" < /tmp/i.sh > /data/local/weaknet/install-weaknet.sh
  chmod 755 /data/local/weaknet/*.sh
  sh /data/local/weaknet/install-weaknet.sh'
```

## 现场

```sh
sh /data/local/weaknet/weaknet-report.sh          # 今天
sh /data/local/weaknet/weaknet-report.sh --live   # 当前分流快照
sh /data/local/weaknet/weaknet-report.sh --events
```

## 判读

- `cls=weak/drop` 且 `w_tcp`/`w_udp` 被压到 1：分流已降权，对照 `lat` 是否卡在 enter 附近抖动  
- 5G `rsrp≤-105`：射频辅助触发；看 `band` 是否 n78→n1  
- `proxy` 非 204：用户面失败（节点/捕获），不要只怪选卡  
- 调参必须按本报告的 **track lat/loss**（不是旧版自 ping）
