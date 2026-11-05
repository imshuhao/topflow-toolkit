# weaknet — 弱网黑匣子（设备自记录，现场无需电脑）

弱网现场（例如单位）通常没有电脑可调试。这套东西让**设备自己记录证据**，回家或事后
用一条命令/手机就能看报告，再据此调 mwan3 阈值。

## 组件

| 文件 | 作用 |
|---|---|
| `weaknet-watch.sh` | 常驻采集：~30–50s 一行 JSON（5G 主卡射频：制式/频段/RSRP/Rsrq/SNR；各卡 mwan3 状态、ICMP 丢包/延迟、代理 204 与耗时、DNS 解析耗时、规则/池形态、异常事件） |
| `weaknet-report.sh` | 汇总某天数据，输出中文报告（在线率、延迟分布、丢包、代理可用率、事件） |
| `install-weaknet.sh` | 设备侧安装器：写 `rc.local` 开机自启标记块、启动/停止采集器 |

数据落在 `/data/local/weaknet/<YYYYMMDD>.jsonl`（持久分区，保留 7 天，单文件 ~8MB 上限），
事件另存 `events.log`。

## 部署（PC 侧，经 adb 或 ssh）

```sh
adb push weaknet/weaknet-watch.sh  /tmp/w.sh
adb push weaknet/weaknet-report.sh /tmp/r.sh
adb push weaknet/install-weaknet.sh /tmp/i.sh
adb shell "mkdir -p /data/local/weaknet; for f in w r i; do tr -d '\r' < /tmp/\$f.sh > /data/local/weaknet/\$f.sh; done"
```

更直接的方式（设备侧已放好文件后）：

```sh
sh /data/local/weaknet/install-weaknet.sh              # 安装 + 启动
sh /data/local/weaknet/install-weaknet.sh --uninstall  # 停止 + 移除自启（日志保留）
```

## 现场怎么用（只有手机）

1. 手机连设备 WiFi `ZTE_TOPFLOW_xxxx`；
2. 浏览器打开 WebSSH：`http://192.168.0.1:8899/app`（root）；
3. 执行：
   ```sh
   sh /data/local/weaknet/weaknet-report.sh          # 今天的报告
   sh /data/local/weaknet/weaknet-report.sh 20261030 # 指定某天
   sh /data/local/weaknet/weaknet-report.sh --events # 只看切换/守护事件
   ```
4. 感觉卡的时候记一下时间点，回家后看该时段的采样即可。

## 判读要点

- **射频快照（给 wan-balance 质量加权）**：每轮写入 `/data/local/weaknet/radio.snap`
  （`rsrp=` / `snr=` / `band=`）。`singbox-wan-balance.sh` 在 `QUALITY=1` 时把
  `rsrp <= -105` 当作 5G 辅助弱网信号（滞后退出 `-95`）；主信号仍是 mwan3
  `LATENCY_*` / `LOSS_*`。
- **射频层（5G 主卡，弱网根因）**：`band` 从 `n78` 掉到 `n1`（或 `type` 从 `SA` 变 `LTE`）、`rsrp` 低于
  **-105 dBm**、`snr` 低于 **0 dB** 就是典型弱覆盖。报告会统计频段分布、RSRP/SNR 的 min/avg，
  以及「RSRP<-105 的采样里代理失败几次」——这是判断“是不是 5G 信号差导致卡顿”的直接证据。
- **在线率 <100% / 丢包 >20% / 延迟 >300ms**：说明弱网已经在恶化，且当前阈值
  （丢包 60%、延迟 1000/2000ms 才判死）下这些卡仍会继续分流量 → 对应 HANDOVER §11.4
  之后的「弱网调优」建议（收紧 failure_loss / failure_latency、HTTPS sticky 600→120s）。
- **proxy 失败码**：`204` 正常；`000` 表示 8s 内没连上/超时；`5xx` 多为节点侧。
- **dns_ms 偏大（>100ms）或持续 `dns_err` 增长**：DoH 弱网握手慢/被限流，考虑加 UDP 兜底。
- **events 里 `zte_mwanX_up=0`**：该卡掉线；`guard=...`：自动恢复链动作；`mode=...`：模式切换。

## 注意

- 采集器是纯 sh 循环，开销很低（每 30s 三次 ping 各 5 包 + 一次 curl）；不需要时用
  `--uninstall` 停掉即可。
- `/tmp/weaknet-watch.pid` 是运行中的 PID；`kill $(cat /tmp/weaknet-watch.pid)` 可临时停。
