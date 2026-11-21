# B20 三卡结构与 TCP/UDP 分池可行性（2026-11-05）

## 决策

**留在本机 MU5252 B20，做 3 卡内优化**（权重 / 可选 TCP·UDP 协议分池）。  
不评估、不采购「四五张 4G + 两张 UDP」多模组硬件——本机硬件上限就是三路蜂窝 WAN。

## 硬件上限（为什么原文方案做不到）

| 槽 | 基带 | 接口 | mwan3 |
|---|---|---|---|
| 1 | X75 5G | `rmnet_data0` | `zte_mwan2` |
| 2 | V3E2 4G | `V3E2net0` | `zte_mwan4` |
| 3 | V3E1 4G | `V3E1net0` | `zte_mwan3` |

- 官方：3 个 nano-SIM 槽 + 每槽可贴片 SIM → **最多 6 个 SIM 身份**，但只有 **3 路基带可同时上网**（见 `docs/RESEARCH.md` §2.1）。
- `singbox-wan-balance.sh` 的 `MAX_WAN=4` 是脚本预留，**不是**第四张物理 4G。
- 机内 V3E 是焊死的 USB CDC-ECM 模块，不是可再插的 USB 4G 棒。

因此「4–5 张 4G 做 TCP + 2 张 4G 做 UDP」在 B20 上**按字面不可实现**。

## 现网数据面

```text
LAN → sing-box (eBPF socket_assign, mark 0x2024)
    → mwan3_hook 跳过
    → nft tf-sbwan jhash（默认 TCP+UDP 共池）
    → ip rule 1990–1992 → mwan3 表 12/13/14
```

- 分流粒度 = **上游连接**；单条 TCP/UDP 不拆卡；mux 单隧道更差。
- IPv6 代理只会出 5G（4G 无可用 v6）。
- 权重与 `mwan3.balanced` 同源（现网 6/3/3 ≈ 50/25/25）。

## 现场量化（2026-11-05，USB ADB）

设备：`sing-box 1.14.4-reF1nd`，eBPF `socket_assign`，三卡均 `online`，池  
`zte_mwan2(w6,12) zte_mwan3(w3,13) zte_mwan4(w3,14)`，`bypass mark 0x2024 source=default`。

累计 RX（采样前大致）：

| 口 | RX bytes |
|---|---|
| `rmnet_data0` | ~235 MB |
| `V3E1net0` | ~15 MB |
| `V3E2net0` | ~38 MB |

短样本：经 `127.0.0.1:7890` 并发 6×2 MB Cloudflare 下载（~3 s）：

| 口 | ΔRX | 约占 |
|---|---|---|
| `rmnet_data0` | 6.10 MB | ~74% |
| `V3E1net0` | 2.13 MB | ~26% |
| `V3E2net0` | 0.02 MB | ~0% |

结论：jhash 在跑，但 **V3E2 本轮几乎没吃到下行**；4G 绝对带宽仍明显低于 5G。  
「再抬 4G 权重」解决不了单连接慢与模块/覆盖天花板；更合理的是 **降权 / 踢出慢卡**，或 **按协议把 UDP 挪到指定卡**。

## 软件：协议分池（已落地，默认关闭）

仓库改动：

- [`singbox/singbox-wan-balance.sh`](../singbox/singbox-wan-balance.sh) — `MODE=shared|proto`，`TCP_POOL` / `UDP_POOL`
- [`singbox/wan-balance.conf.example`](../singbox/wan-balance.conf.example) — 配置样例
- [`singbox/tests/test_wan_balance_render.sh`](../singbox/tests/test_wan_balance_render.sh) — 离线 `render` 回归

启用（设备，**不会**随本仓库自动上机）：

```sh
cp /data/sing-box/wan-balance.conf.example /data/sing-box/wan-balance.conf
# 编辑：MODE=proto
# TCP_POOL=zte_mwan2,zte_mwan3
# UDP_POOL=zte_mwan4
sh /data/sing-box/singbox-wan-balance.sh apply
sh /data/sing-box/singbox-wan-balance.sh status
```

推荐起点（结合本次样本）：TCP → 5G+V3E1；UDP → V3E2。  
缺卡 / 离线侧会回退到共池，避免该协议黑洞。

**不会**把单条 TCP 叠到多卡；包级聚合仍只有厂商 `SMULTIWAN`/ICG，与现网 mwan3+sing-box 互斥。

## 本地检查

```sh
sh singbox/tests/test_wan_balance_render.sh
```

## 上机（2026-11-05 12:47）

已启用 `MODE=proto`（TCP=`zte_mwan2,zte_mwan3`，UDP=`zte_mwan4`）。

| 项 | 值 |
|---|---|
| 现网脚本 md5 | `0ff6122201a7a85f561525e76a3d69a6` |
| 回滚备份目录 | `/data/sing-box/backup/wan-balance-pre-proto-20261105/` |
| 旧脚本 md5 | `d999fc31a2dfc927ec6e6110bca1192f` |
| PC 副本 | `tmp/singbox-wan-balance.sh.bak-pre-proto-20261105` |

回滚一键：

```sh
sh /data/sing-box/backup/wan-balance-pre-proto-20261105/restore.sh
```

`status` 确认：`pool-mode=proto`，TCP 池两行、UDP 池一行；nft 见 `tcp sport/dport` 双桶 + `meta l4proto udp` 单桶（kernel 会把 `th` 折叠成 `tcp`）。
