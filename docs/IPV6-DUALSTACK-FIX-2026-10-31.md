# IPv6 双栈修复方案（免流全代理约束）— 2026-10-31

> **状态**：设计稿，**未推送设备**（按 Main 指令，线上仍为 `config.json` md5 `d0d9e63c…`）。
> **适用范围**：`tun-allproxy`（现网）→ 之后迁移到 `ebpf-local-shared`；DNS/路由补丁与数据面无关。
> **前置阅读**：私人交接文档（未公开发布） §31.4、§22.2；私人工作笔记（未公开发布）「不要把 IPv6 改回 `false`」。
>
> **新约束（用户 2026-10-31，覆盖此前一切假设）**
> 1. 所有公网流量——TCP/UDP、IPv4/IPv6、国内/国外、以及 DNS 与选择器的间接出口——**必须经代理**；
> 2. 只有 LAN / 私网 / 设备管理面可以绕过；
> 3. **不允许**用 IPv4-only、关 fake-ip v6、或 `ip_version:6 -> reject/block` 来"修复"；
> 4. IPv6 必须被代理：走 **fake-ip v6（域名交给节点，节点用 v4 解析）** + 一个**具备 v6 出口**的节点组。

---

## 0. 结论（TL;DR）

1. **真因不是"客户端优先 v6"**，而是：v6 请求确实进了 TUN，但出站拿到的是**真实 v6 字面量**，而免流节点没有 v6 出口 → 对端 FIN / TLS EOF。
   本地实测证明 sing-box 的 sniff **不会**把目的地址替换成 SNI 域名：`sniffed protocol: tls` 之后出站仍然是 `1.1.1.1:443`（§1.3）。
2. **唯一同时满足「v6 可用 + 免流 + 零直连」的机制是 fake-ip v6**：
   `AAAA → fdfe:dcba:9876::/64 → TUN → reverse_mapping 还原域名 → 出站把域名交给节点 → 节点用自己的 v4 解析`。
   实测：fake-ip v6 目的进入出站后是 `outbound connection to example.org:80`（§1.4）。
3. **修复 = 两个补丁（V1，最小改动）**
   - **DNS**：AAAA 查询整体路由到 `fakeip`（`.lan/.local` 除外），A 维持现状（CN/过滤域真实 A、其余 fake-ip）。
   - **Route**：末尾加 `{"ip_version":6,"ip_is_private":false,"outbound":"⚡ IPv6·自动选择"}`，只接住"真 v6"（字面量 / App 自带 DNS / IP 规则）；fake-ip v6 是 ULA（`ip_is_private=true`）**不会**命中它。实测：真 v6 命中该规则，fake-ip v6 不命中（§1.4）。
4. **HANDOVER §31.4 的 a/b/c 三条路径在新约束下全部作废**（a、c 直接违反"v6 必须被代理"；b 只覆盖一半且制造直连）。实测证据保留在附录 A，防止以后回退到错误方案。
5. **残余直连只有一处结构性依赖**：`bootstrap` UDP `223.5.5.5`（21 个出站节点用域名，必须先解析才能连代理）。其余直连项见 §4 审计表。

---

## 1. 证据（本机复现，sing-box 1.14.4 windows-amd64）

> 复现配置是用生产 DNS/路由片段裁剪出的最小配置；为在 Windows 上 `check`，仅替换了 fork 专有项：
> `loadbalance/provider/include/ttl/url/selector 上的 strategy` 与 `experimental.observability`，并把 TUN inbound
> 换成 `mixed`（`auto_redirect` 仅 Linux）。**被验证的 DNS/路由字段一字未改。**

### 1.1 现网事实（HANDOVER §31.4）

- 客户端双栈站点（`www.baidu.com` / `www.huya.com`）不带 `-4` = **000**，带 `-4` = **200**；
- 日志 `inbound/tun[tun-in]: inbound connection to [2408:…]:443 → outbound/vmess[…]` —— 进 TUN 了，但目的是**真 v6**；
- 设备本机 `curl -6` 同样 000；
- `dns.strategy = prefer_ipv4` 已试过并回滚：`sing-box check` rc=0，但 `dns/query` 仍返回两条真实 AAAA。

### 1.2 为什么 `dns.strategy` 无效（源码级）

`dns.strategy` 只影响 **sing-box 自身**的地址选择，不裁剪客户端应答：

- `dns/router.go`（v1.14.4）`resolveLookupStrategy()` / `lookupWithRules()`：strategy 只在内部 lookup（`resolve` 动作、出站域名解析）里决定查 A 还是 AAAA；
- 客户端发来的 AAAA 查询由 `exchangeWithRules()` 原样转发给命中的 server，应答不改写。

所以"客户端仍收到真实 AAAA"是预期行为，不是配置写错。

### 1.3 为什么"sniff 出域名"救不了真 v6

实测（socks 入站 → 直连出站，`sniff(http,tls,quic)`）：

```
inbound connection to 1.1.1.1:443
router: match[0] => sniff(http,tls,quic,300ms)
router: sniffed protocol: tls                 ← 没有 domain
outbound/direct[direct]: outbound connection to 1.1.1.1:443   ← 仍是 IP，不是 SNI
```

结论：sniff 只服务**路由匹配**，不会把目的地改写成域名。真实 v6 目的 → 节点收到 v6 字面量 → 节点无 v6 出口 = 000。

### 1.4 为什么 fake-ip v6 能救（同一台机器）

实测（域名 `example.org` 查 AAAA 得到 `fdfe:dcba:9876::2`，再连该地址）：

```
router: found fakeip domain: example.org
outbound/direct[direct]: outbound connection to example.org:80      ← 出站拿到域名
```

真实 v6 字面量 `[2606:4700:4700::1111]:80` 的对照：

```
inbound connection to [2606:4700:4700::1111]:80
router: match[2] ip_version=6 => route(v6grp)                        ← 只有真 v6 命中
outbound/direct[v6grp]: outbound connection to [2606:4700:4700::1111]:80
```

即：**域名类目标 = fake-ip v6 → 出站是域名（节点 v4 解析即可，免流成立）；真 v6 = 必须交给有 v6 出口的组。**
本机同时验证了 `ip_is_private:false` 能精确区分二者（`fdfe::/64` 是 ULA → private → 不命中）。

### 1.5 两个否定性结论（避免再次踩坑）

- `ip_cidr` **不支持** `!` 前缀取反：`netip.ParsePrefix("!fdfe:dcba:9876::/64")` → `check` 失败（实测）；
- 规则级 `invert` 会连 IPv4 一起命中（`not v6 OR not in cidr`），不能用。
  → 用 `ip_version:6 + ip_is_private:false` 表达"真 v6"。

---

## 2. 方案 V1（推荐）

### 2.1 DNS 补丁

在 `dns.rules` **最前面**插入两条（`fake-ip-filter` 那条大列表不动，被 LAN 规则遮蔽即可）：

```diff
   "rules": [
+    {
+      "domain_suffix": [".lan", ".local"],
+      "server": "ali"
+    },
+    {
+      "query_type": ["AAAA"],
+      "server": "fakeip",
+      "rewrite_ttl": 1
+    },
     {
       "domain_suffix": [".lan", ".local", ".cn", ".doubao…（原 34 项过滤列表）],
       "server": "ali"
     },
     {
       "rule_set": ["geosite-cn"],
       "server": "ali"
     },
     {
       "query_type": ["A", "AAAA"],
       "server": "fakeip",
       "rewrite_ttl": 1
     }
   ],
```

为什么必须这样排：

| 位置 | 作用 | 不这样会怎样 |
|---|---|---|
| `0.` LAN 规则 | `.lan/.local` 必须拿真实答案（NAS/路由器） | 若 AAAA 规则在最前，`nas.lan` 会拿到 fake-ip v6，客户端优先 v6 → 节点解析不了内网域名 |
| `1.` AAAA→fakeip | **所有**域名（含 `.cn` / `geosite-cn` / 过滤列表）的 v6 都变成 fake-ip | 放在 ali 规则之后 → CN 域仍返回真实 AAAA（当前 baidu 的 3 条 `2408:…` 就是这条路径） |
| `2..` 原规则 | A 的行为完全不变（CN 真实 A、其余 fake-ip） | 改动 A 会牵动 geo/CDN 与免流域名规则，不必要 |

`rewrite_ttl: 1` 与现有 fake-ip 规则一致，便于快速失效。`reverse_mapping: true` 与 `cache_file.store_fakeip: true` 已开启，是 domain 还原的前提。

### 2.2 Route 补丁

在 `route.rules` **末尾**（`private-ip` 之后）追加一条：

```diff
     { "rule_set": ["private-domain"], "outbound": "🌐 本机·本地直连" },
     { "rule_set": ["private-ip"], "outbound": "🌐 本机·本地直连" },
+    { "ip_version": 6, "ip_is_private": false, "outbound": "⚡ IPv6·自动选择" }
   ],
   "final": "🚀 免流模式"
```

- 组选择：`⚡ IPv6·自动选择`（urltest，`include` 正则只挑 `[v6]/⁶/| ipv6` 节点，健康检查 URL 就是 `https://[2606:4700:4700::1111]/cdn-cgi/trace`）——**测的就是 v6 出口**，且成员里没有直连。
  `🌐 nasipv6` 默认指向它，但多一层 selector，直接用 urltest 更少变数。
- 为什么放末尾：域名规则（含 fake-ip 反解出的域名）优先，只有"没有域名可匹配的真 v6"才落到这里；fake-ip v6 因 `ip_is_private=true` 不会命中，继续走域名规则或 `final` 免流。
- 为什么不是 `outbound: block` / `action: reject`：新约束明确不允许阻断 v6；且 `reject` 在 `sniff` 之后只会"直接关闭"，不保证快速失败。

### 2.3 语义对照（V1 生效后）

| 客户端目标 | DNS 应答 | 进 TUN 后目的地 | 出站拿到的目的 | 走的组 | 免流 |
|---|---|---|---|---|---|
| 任意域名的 AAAA（`.lan/.local` 除外） | `fdfe:dcba:9876::N`（fake-ip v6） | fake-ip v6 | **域名** | 域名规则 → 免流 / 对应分组 | ✅ |
| 任意域名的 A（CN/过滤域） | 真实 A | 真实 v4 | 真实 v4 | 域名/IP 规则 → 免流 | ✅（现状不变） |
| 任意域名的 A（其余） | `198.18.0.N`（fake-ip v4） | fake-ip v4 | 域名 | 域名规则 → 免流 | ✅（现状不变） |
| 真 v6 字面量 / App 自带 DNS 返回的真 AAAA | 不经 sing-box DNS | 真 v6 | v6 字面量 | `⚡ IPv6·自动选择` | ❌ **计费**（机场节点） |
| LAN / 私网 / 管理面 | — | 被 `route_exclude_address` / private 规则排除 | — | 直连 | 允许 |

### 2.4 风险与残余

1. **节点侧解析策略不可控**：域名交给节点后，节点若自己优先 AAAA 且无 v6，仍会失败。V1 把"客户端侧 100% 失败"收敛成"节点侧偶发失败"，需实测各免流节点的解析行为。
2. **真 v6 走机场节点 = 不免流**，按流量计费；只应作为字面量/自带 DNS 的兜底。若完全不能接受计费，唯一替代是把这类流量也挡掉——但那违反新约束，需用户改口径。
3. **App 自带 DoH/HTTPDNS**（Chrome/Firefox DoH、iOS 私有中继、部分国产 App 的 HTTPDNS）绕过 sing-box DNS，会拿到真 AAAA → 走 v6 组（可用但计费）。无法在 DNS 层修。
4. **DNS 缓存**：`cache_file.store_dns: true`，旧的真实 AAAA 会跨重启复用；切换时必须清 `cache.db`，PC 侧 `ipconfig /flushdns`，并确认浏览器安全 DNS 关闭。
5. **fake-ip v6 依赖 TUN/路由捕获**：`fdfe:dcba:9876::/64` 已在 `::/0` 与 TUN 地址覆盖内；迁到 eBPF 后需确认 `shared`/`local` 对 ULA 目的同样捕获（见 §6）。
6. **`⚡ IPv6·自动选择` 可能为空**：无健康 v6 节点时 urltest 无成员 → 连接失败（快速失败，不会直连）。

### 2.5 可选强化（不属于 V1，需单独授权）

- **DNS 上游也走代理**：现仓库重生成版已给 `ali/ali2` 加 `detour: 🚀 免流模式`（设备旧版还没有）；但 `bootstrap` UDP `223.5.5.5` 仍是直连，因为出站节点多用域名（如 `node.example.invalid`），连代理前必须先解析（鸡生蛋）。
  真正去掉它需把 DoH 写成 **IP + `tls.server_name`** 并 `detour`，同时把节点域名固定成 IP（会牺牲机场换 IP 的能力）。建议**接受**这条 DNS 元数据直连，并在报告中写明。
- **`.lan/.local` 用 `local` server**（`{"tag":"lan","type":"local"}`）替代 `ali`，减少一次外网查询；与本次问题无关。

---

## 3. 方案 V2（彻底 fake-ip 化，可选）

若要求"客户端永远拿不到真实公网 IP、所有域名都由节点解析"：

```diff
   "dns": {
     "servers": [
       { "tag": "bootstrap", "type": "udp", "server": "223.5.5.5" },
       { "tag": "ali",  "type": "https", "server": "doh.pub", "domain_resolver": "bootstrap", "detour": "🚀 免流模式" },
       { "tag": "ali2", "type": "https", "server": "dns.alidns.com", "domain_resolver": "bootstrap", "detour": "🚀 免流模式" },
+      { "tag": "lan", "type": "local" },
       { "tag": "fakeip", "type": "fakeip", "inet4_range": "198.18.0.0/16", "inet6_range": "fdfe:dcba:9876::/64" }
     ],
     "rules": [
+      { "domain_suffix": [".lan", ".local"], "server": "lan" },
+      { "query_type": ["A", "AAAA"], "server": "fakeip", "rewrite_ttl": 1 }
     ],
-    "final": "ali"
+    "final": "fakeip"
   }
```

| 维度 | V1（推荐） | V2 |
|---|---|---|
| 客户端得到的地址 | A 真实（CN）/ fake（其余），AAAA 全 fake | A/AAAA 全 fake |
| 免流契合度 | 高（CN A 直连 IP 由节点拨号，仍经代理） | 更高（全域名，节点解析） |
| geoip/IP 类规则 | 现状可用 | **失效**（目的全是 fake-ip） |
| IP 敏感业务（游戏/测速/P2P） | 影响小 | 可能异常 |
| 改动面 | 2 条 DNS + 1 条 route | DNS 规则重排 + final 改 fakeip + 加 lan server |
| 回滚 | 删 2 条规则 | 恢复 final/规则，清 cache |

结论：先落 V1；V2 只在 V1 实测仍有"真实 IP 直连/免流失效"时再评估。

---

## 4. 零直连审计（用户要求逐项 flag）

> 设备现网 = md5 `d0d9e63c…`；仓库在 2026-10-31 12:49 已被重新生成（md5 `05a5e33c…`，**未部署**），部分项已改善。下表分列两态。

| # | 项目 | 设备现网 `d0d9e63c` | 仓库 `05a5e33c` | 是否直连 | 建议 |
|---|---|---|---|---|---|
| 1 | 14 个 PT/BT 域（hdhome/tracker.m-team/rousi/…） | `🌐 本机·本地直连` | **`🚀 免流模式`** | 设备侧**是** | 部署新版即消除；否则违反零直连 |
| 2 | `private-domain` / `private-ip` | 直连 | 直连 | 允许（LAN/私网） | 保持 |
| 3 | LAN / `192.168/10/172.16/169.254`、`fd00:5252:0:1::/64`、`fe80::/10`、`ff00::/8` | `route_exclude_address` + 内核本地 | 同 | 允许 | 保持 |
| 4 | 管理面 `192.168.0.1:80/443/9999/22622` | 本机监听 | 同 | 允许 | 保持 |
| 5 | DNS: `ali` / `ali2`（DoH） | **直连（无 detour）** | **`detour: 🚀 免流模式`** | 设备侧**是** | 部署新版即消除 |
| 6 | DNS: `google` TLS `8.8.8.8` | `detour: 🌍 国外总模式` | 同 | 否 | 保持 |
| 7 | DNS: `bootstrap` UDP `223.5.5.5` | 直连 | 直连 | **是（结构性）** | 21 个节点用域名，必须先解析；接受或改 IP 化（§2.5） |
| 8 | `dns.final = ali` | 未命中查询 → 直连 DoH | 同（DoH 经免流） | 设备侧是 | 新版经代理 |
| 9 | UDP:53 | `hijack-dns` + `logical(udp,53) → 免流` | 同 | 否 | 保持 |
| 10 | MPTCP | 默认 reject（不可代理） | 同 | 否（直接失败） | Apple 设备可能异常；需告知 |
| 11 | ICMP | 进 TUN，sing-box 不代理 | 同 | **需取证** | `auto_redirect` 下 ICMP 进 TUN；建议 nft 计数器 + 抓包确认无 WAN 直出 |
| 12 | `🚀 免流模式` 组内含 `🌐 本机·本地直连` + `⛔️ 禁止·拒绝连接` | 是 | 是 | **控制面风险** | 手选/记忆成"直连"即全量直连；建议移除该成员或锁死 `default` |
| 13 | sing-box 出站自身（`SO_MARK 0x2024`） | 走 WAN | 同 | 否（这就是代理流量） | 保持 |

> 第 11/12 项是本方案之外的两处真实风险，需在授权时一并向用户说明。

---

## 5. 落地步骤（等授权；本轮不执行）

### 5.1 备份契约

- RollbackStrategy 的 `singbox/backup-config.sh`：`config.json.bak-{tun,phase0-observability,phase1-ebpf-local,phase2-ebpf-shared}-<UTC>` + md5 manifest，保留 5 份；
- 历史已知良好备份：`/data/sing-box/config.json.bak-tunallproxy-20261030T060135Z`（= md5 `d0d9e63c…`）；
- 本次补丁另存 `config.json.bak-ipv6-v1-<UTC>`（由 §5.3 脚本自动生成）。

### 5.2 顺序

```sh
# 0) 生成当前档（Main 拥有 convert.py；此处只消费产物）
python singbox/convert.py --profile tun-allproxy

# 1) 打补丁（host 侧，幂等；dry-run 先看）
python singbox/patch-ipv6-dualstack.py --config singbox/generated/config.tun-allproxy.json
python singbox/patch-ipv6-dualstack.py --config singbox/generated/config.tun-allproxy.json --write

# 2) 部署（含设备侧 backup + sing-box check）
sh singbox/deploy.sh --config config.tun-allproxy.json --backup

# 3) 清缓存 + 重启（store_dns/store_fakeip 会跨重启复用旧 AAAA）
adb shell 'sh /data/sing-box/sing-box.sh stop'
adb shell 'cp /data/sing-box/cache.db /data/sing-box/cache.db.bak-ipv6 && rm -f /data/sing-box/cache.db'
adb shell 'cd /data/sing-box && ./sing-box check -c config.json && sh /data/sing-box/sing-box.sh start'

# 4) PC 侧
ipconfig /flushdns      # Windows
# 关闭浏览器/系统的安全 DNS（DoH），否则绕过设备 DNS
```

### 5.3 补丁脚本（host 侧，幂等，写入用 bytes 避免 Windows CRLF）

```python
#!/usr/bin/env python3
"""V1: AAAA -> fake-ip v6; route real IPv6 to the v6-capable group.

  python singbox/patch-ipv6-dualstack.py --config singbox/generated/config.tun-allproxy.json
  python singbox/patch-ipv6-dualstack.py --config ... --write
  python singbox/patch-ipv6-dualstack.py --config ... --revert --write
"""
import argparse, hashlib, json, pathlib, shutil, sys, time

LAN = [".lan", ".local"]
LAN_RULE = {"domain_suffix": LAN, "server": "ali"}
AAAA_RULE = {"query_type": ["AAAA"], "server": "fakeip", "rewrite_ttl": 1}
V6_ROUTE = {"ip_version": 6, "ip_is_private": False, "outbound": "⚡ IPv6·自动选择"}


def load(path):
    return json.loads(path.read_bytes().decode("utf-8"))


def dump(path, cfg):
    path.write_bytes((json.dumps(cfg, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))


def patch(cfg):
    rules = cfg["dns"]["rules"]
    rules[:] = [r for r in rules if r != AAAA_RULE]
    if LAN_RULE not in rules:
        rules.insert(0, LAN_RULE)
    rules.insert(rules.index(LAN_RULE) + 1, AAAA_RULE)
    route = cfg["route"]["rules"]
    route[:] = [r for r in route if r != V6_ROUTE]
    route.append(V6_ROUTE)


def revert(cfg):
    rules = cfg["dns"]["rules"]
    rules[:] = [r for r in rules if r != AAAA_RULE]
    route = cfg["route"]["rules"]
    route[:] = [r for r in route if r != V6_ROUTE]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--revert", action="store_true")
    args = ap.parse_args()

    path = pathlib.Path(args.config)
    cfg = load(path)
    before = hashlib.md5(path.read_bytes()).hexdigest()
    (revert if args.revert else patch)(cfg)
    payload = (json.dumps(cfg, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    print(f"config : {path}")
    print(f"action : {'revert' if args.revert else 'patch'}")
    print(f"md5    : {before} -> {hashlib.md5(payload).hexdigest()}")
    if not args.write:
        print("dry run; pass --write to apply")
        return 0
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    backup = path.with_name(path.name + f".bak-ipv6-{stamp}")
    shutil.copy2(path, backup)
    dump(path, cfg)
    print(f"written; backup {backup}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

（幂等性已实测：重复 `patch` 不产生重复规则；`patch` 后再 `revert` 可回到仅多一条 LAN 规则的状态——LAN 规则本身不改变行为。）

### 5.4 生成器等价改动（**Main 拥有 `convert.py`，本轮未落**）

```python
# build_dns()，在现有 rules.append(...) 之前插入：
rules.append({"domain_suffix": [".lan", ".local"], "server": "ali"})
rules.append({"query_type": ["AAAA"], "server": "fakeip", "rewrite_ttl": 1})
fw = fakeip_dns_rule(dns.get("fake-ip-filter") or [])
if fw:
    rules.append(fw)
...

# build_route()，在 rule_sets / 末尾：
if all_proxy:
    route_rules.append({"ip_version": 6, "ip_is_private": False, "outbound": "⚡ IPv6·自动选择"})
```

建议加开关（如 `build_dns(..., v6_fakeip=True)`），保证 `base/observability/ebpf-*` 其余档逐字节不变。

### 5.5 回滚

```sh
sh singbox/patch-ipv6-dualstack.py --config singbox/generated/config.tun-allproxy.json --revert --write
sh singbox/deploy.sh --config config.tun-allproxy.json --backup
adb shell 'sh /data/sing-box/sing-box.sh restart'
```
或整体回滚：`cp /data/sing-box/config.json.bak-ipv6-<UTC> /data/sing-box/config.json && ./sing-box check -c config.json && sh sing-box.sh restart`（并再清一次 `cache.db`）。

---

## 6. 与 eBPF 迁移的关系

- 仓库现有 `config.ebpf-local-only.json` / `config.ebpf-local-shared.json` 的 **DNS 块与 TUN 档相同**（`fakeip` 含 `inet6_range`，无 AAAA 规则，`strategy` 仍 `prefer_ipv6`），`ebpf` inbound 保留 `local/shared.ipv6: true`。
- 因此 **V1 的 DNS 补丁与 route 补丁对 eBPF 档同样适用**（不依赖 `tun.route_address`，§2.2 的 route 规则是数据面无关的）。
- 差异：V1 的 `route_address` 相关讨论只属于 TUN；eBPF 档没有 TUN，捕获由 cgroup/packet_rewrite 完成，需验证 **`fdfe:dcba:9876::/64`（fake-ip v6）确实被 ebpf 捕获**；`dns_mode: respect_policy`（local）对 LAN 客户端可能不劫持 DNS，需靠现网 LAN DNS DNAT 保证查询进 sing-box。
- 结论：**先按 V1 修好 v6 语义，再迁移平面**；迁移时不需要再改 DNS/路由。

---

## 7. 验证命令清单

### 7.1 设备侧（授权后）

```sh
# 语法
cd /data/sing-box && ./sing-box check -c config.json; echo rc=$?

# DNS：AAAA 必须是 fake-ip v6（期望 fdfe:dcba:9876::N，TTL 1）
curl -s 'http://127.0.0.1:9999/dns/query?name=www.baidu.com&type=AAAA'
curl -s 'http://127.0.0.1:9999/dns/query?name=www.huya.com&type=AAAA'
# 反例：.lan 仍应是真实/NXDOMAIN，不能是 fdfe::

# iperf/连通性（设备本机）
curl -s -o /dev/null -w '%{http_code}\n' http://www.baidu.com        # 200
curl -s -o /dev/null -w '%{http_code}\n' https://www.huya.com        # 200
curl -s -6 -o /dev/null -w '%{http_code}\n' https://ipv6.baidu.com   # 200（真 v6 → ⚡ IPv6·自动选择）
curl -s -o /dev/null -w '%{http_code}\n' https://[2606:4700:4700::1111]/cdn-cgi/trace  # 200 = v6 组有出口

# 连接面：fake-ip v6 目的的出站应是域名，不是 fdfe::
curl -s http://127.0.0.1:9999/observability/v1/connections/recent \
  | jq -r '.data[]? | (.metadata // .) | [.network, .destinationIP, .domain, .outbound] | @tsv' | tail -20
# 若 fork 的 recent 不做 Clash 兼容，退化用：
#   jq -r '.. | objects | (.destinationIP? // empty)' 并人工看是否有 fdfe: 目的 + 出站为代理组
```

### 7.2 PC 侧（真实验收）

```powershell
curl.exe -s -o NUL -w "dual %{http_code}`n" https://www.baidu.com   # 期望 200（修复前 000）
curl.exe -s -o NUL -w "v4   %{http_code}`n" -4 https://www.baidu.com
curl.exe -s -o NUL -w "v6   %{http_code}`n" -6 https://ipv6.baidu.com
Resolve-DnsName www.baidu.com -Type AAAA                            # 期望 fdfe:dcba:9876::N（或空）
Resolve-DnsName www.baidu.com -Type A                               # 期望真实 A（现状不变）
ipconfig /flushdns
```

预期：

- 不带 `-4` 的双栈 `200`（本次修复的核心验收）；
- `-6 ipv6.baidu.com` 只有在 v6 组节点健康时才是 `200`，否则 000/超时 —— 这是**节点侧**问题，不是本补丁；
- `connections/recent` 中不应再有"真 v6 目的 → `⚡ IPv6·自动选择`"以外的路径，也不应出现 `🌐 本机·本地直连`（PT 域除外，见审计表）。

### 7.3 本机复现（无需设备）

见 §1 的日志；可用官方 sing-box 1.14.4 二进制 + 最小配置重跑（`check` + `dns` 查询 + socks 连接）。

---

## 8. 用户授权话术

> 中文，可直接转给用户；三项分开确认。

**A. V1 主方案（推荐，需授权）**

> 修复思路：把客户端的 IPv6 查询全部改成 fake-ip v6（域名照旧交给节点，由节点用自己的 v4 解析），同时给"真实 IPv6 地址/自带 DNS 的 App"留一个具备 v6 出口的机场节点组。这样双栈站点恢复正常，绝大多数流量仍然走免流。
> 需要你确认两点：
> 1) 真实 IPv6 目标（IPv6 字面量、App 自带 DNS 返回的真 AAAA）会走 `⚡ IPv6·自动选择`，**这部分是机场节点、不免流、按流量计费**；量通常很小，但无法为零。是否接受？
> 2) 切换瞬间会清空 DNS 缓存（`cache.db`）并重启 sing-box，约 10–20 秒断网；PC 需 `ipconfig /flushdns` 并关闭浏览器"安全 DNS"。
> 回复「同意 V1」即执行；执行前会自动备份（`config.json.bak-ipv6-<UTC>`），一条命令可回滚。

**B. V2 彻底 fake-ip 化（可选，需单独授权）**

> 若还要求"客户端永远拿不到真实公网 IP、所有域名都由节点解析"，需要把 A 查询也改成 fake-ip（`dns.final = fakeip`）。代价：部分依赖真实 IP 的功能（游戏、测速、P2P、部分银行/流媒体风控）可能异常，且 geoip 类规则失效。默认**不做**，除非 V1 实测仍有真实 IP 直连。

**C. 明确告知（无需授权，但需知情）**

> 1) 审计发现 `🚀 免流模式` 组里含 `🌐 本机·本地直连` 成员：一旦在面板手选/记忆成直连，**所有流量会直连**。建议移除该成员或锁死默认值（需另一次变更）。
> 2) 唯一保留的直连是 `bootstrap` 向 `223.5.5.5` 的 DNS 查询（21 个节点用域名，连代理前必须先解析），无法在不牺牲机场换 IP 能力的前提下消除。
> 3) ICMP（ping）不被代理，MPTCP 被拒绝；如需"零直连"字面意义上的严格保证，需再确认这两项的处置（阻断或接受）。

---

## 9. 未落项 / 依赖

| 项 | 归属 | 状态 |
|---|---|---|
| `docs/IPV6-DUALSTACK-FIX-2026-10-31.md`（本文） | Ipv6DualStackFix | 已落盘 |
| `singbox/patch-ipv6-dualstack.py`（§5.3） | 待 Main 决定是否落文件 | 本轮未创建 |
| `convert.py` 生成器改动（§5.4） | **Main** | 未落（Main 接管） |
| `test_convert.py` | **Main** | 不动 |
| 设备部署 / 重启 / 清缓存 | 用户授权后 | 未执行（严禁动线上） |
| 节点侧 v6 出口实测 | 需设备 + 机场节点 | 未验证 |
| `backup-config.sh` 命名契约 | RollbackStrategy | 引用其 `config.json.bak-<phase>-<UTC>` |
| 监控指标（v6 连接占比、fake-ip 命中） | MonitoringMetrics | 引用其脚本，不重复实现 |

---

## 附录 A：a/b/c 三条旧路径实测证据（作废留档）

| 路径 | 实测做法 | 实测结果 | 为什么作废 |
|---|---|---|---|
| **a. DNS 强制 v4** | ① `dns.strategy = ipv4_only`；② `dns.rules[0] = {"query_type":["AAAA"],"action":"predefined","rcode":"NOERROR"}` | ① 无效（源码：strategy 只影响内部 lookup）；② **有效**：`www.baidu.com` AAAA → `rcode=0, answers=0`，A → 3 条真实 A；`www.huya.com` AAAA → 0 | AAAA 被抑制 = v6 不可用，违反新约束 |
| **b. 关 fake-ip v6 + 撤 v6 路由** | `fakeip.inet6_range` 删除（保留 `query_type:["A","AAAA"]→fakeip`）；`tun.route_address` 由 `["::/0"]` 改 `["0.0.0.0/0"]` | fakeip 域（huya/example.org）AAAA → 0；**CN 域 baidu AAAA 仍 3 条真实 `2409:8c00:…`** | 只覆盖一半：真实 AAAA 会直连（若撤路由）或继续失败（若保留 `::/0`）；且撤路由会制造直连 |
| **c. route 丢弃 v6** | `route.rules[0] = {"ip_version":6,"action":"reject","no_drop":true}`（`check` rc=0） | 未上线 | 直接断 v6，违反新约束与 私人工作笔记（未公开发布）；`sniff` 之后 reject 只是"关闭连接"，失败可能变慢 |

补充事实：

- `predefined` 是 DNS 规则动作，**不是** route 规则动作（写成 route 规则会报 `unknown rule action: predefined`）；
- `predefined` 空 `answer` + 默认 `NOERROR` = 权威 NODATA，客户端立即回落 A（本机 `rcode=0 / answers=0` 已证）；
- fake-ip 服务器在对应地址族未配置时对查询返回 `RcodeSuccess` 空应答（`dns/transport/fakeip/fakeip.go`），这解释了 b 的一半效果；
- `ip_cidr` 取反 `!prefix` 不被接受（§1.5）。

## 附录 B：本次涉及的关键 md5 / 时间

| 对象 | md5 / 值 | 说明 |
|---|---|---|
| 设备现网 `config.json` | `d0d9e63c78e2497b0b0cc86ba495419d`（70567 B） | 线上，**未动** |
| 仓库 `singbox/generated/config.tun-allproxy.json` | `05a5e33cdd7278bbecdd79e54c500da2`（70539 B，2026-10-31 12:49:31） | 同事重生成：PT→免流、DoH→detour，**未部署** |
| 历史良好备份 | `/data/sing-box/config.json.bak-tunallproxy-20261030T060135Z` | 回滚点 |
| 本次补丁备份 | `config.json.bak-ipv6-<UTC>`（生成时确定） | §5.3 脚本自动创建 |
