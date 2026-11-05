# sing-box 裸核落地规划（ZTE TopFlow MU5252 / B20）

> **日期**：2026-10-27  
> **后续整体迁移方案**：[SINGBOX-MIGRATION-PLAN-2026-10-27.md](SINGBOX-MIGRATION-PLAN-2026-10-27.md)（含实际转换产物与 lab 实测）  
> **来源文章**：七尺宇《sing-box 裸核运行：OpenWrt 与 Debian（官方内核 + Fork 订阅内核）》  
> <https://www.qichiyu.com/1124.html>（发布 2026-10-13，更新 2026-10-14）  
> **设备实测**：OpenWrt 23.05.4 / `sdx75/generic` / `aarch64_cortex-a53` / musl / kernel 5.15.194  
> **现网**：mihomo netns v1.19.27，`192.168.0.254:9999`，mixed/redir `7890/7892`（见 私人交接文档（未公开发布） §20.8）  
> **本文性质**：原文摘要 + 本机适配实测 + 迁移规划；不是可直接执行的最终配置。

---

## 0. 结论先行

1. **裸核可行，已在本机跑通**：`reF1nd 1.14.4 linux-arm64-musl` 静态内核在设备上正常启动；mixed 入站经 `direct` 出站访问 `gstatic.com/generate_204` 返回 **204**；TUN 能创建 `tun0`（`172.19.0.1/30`）并在退出后清理干净。
2. **官方 `linux-arm64` 不能直接用**：官方 1.14.4 的 arm64 包是 **glibc 动态链接**（`PT_INTERP=/lib/ld-linux-aarch64.so.1`），本机只有 musl loader（`/lib/ld-musl-aarch64.so.1`），执行会报 “not found”。这不是架构不匹配，是 C 库不匹配。
3. **两条可选内核路线**：
   - **A（默认）**：reF1nd `linux-arm64-musl` 静态包。开箱即用，且带 `providers`（远程订阅）——与本项目 `proxy-providers` 的使用方式最接近。
   - **B**：官方源码 `CGO_ENABLED=0` 自编译静态 aarch64。控制力最强、无第三方 fork，但需要 Go 工具链和后续自维护。
4. **不建议直接替换现网**：先在宿主并行跑 lab（不同端口 / 不同 fake-ip / 不同 mark，不动 mihomo），通过 **客户端 IPv6 TCP 闸门** 后再进维护窗切换。§20.8 的 v6 首数据段消失问题仍未定位到 mihomo 层，换内核不一定解决。
5. **最大未知项**（按风险排序）：
   1. 客户端 v6 TCP 在 TUN 数据面是否正常（§20.8 的 RNDIS/USB 疑点）；
   2. `route.auto_detect_interface: true` 会把出站绑到默认口 `rmnet_data0`，**绕开 mwan3 三口负载均衡**；
   3. `auto_redirect` 依赖 nftables，与厂商 iptables-legacy/mwan3 规则共存是否干净；
   4. 订阅是 Clash YAML，sing-box `providers` 要 sing-box 格式 JSON——中间需要 Sub-Store 或转换器。

---

## 1. 原文内容摘要

### 1.1 原文链接清单

| 用途 | 链接 |
|---|---|
| sing-box 官方 Releases | <https://github.com/SagerNet/sing-box/releases> |
| 官方安装脚本出处 | <https://sing-box.sagernet.org/zh/installation/package-manager/> |
| reF1nd Fork 内核 | <https://github.com/reF1nd/sing-box-releases/releases> |
| Fork 订阅文档 | <https://sing-boxr.dustinwin.cc.cd/zh/configuration/provider/> |
| Fork 通知频道 | <https://t.me/sing_box_reF1nd> |
| 1.14 配置模板 | <https://github.com/qichiyuhub/rule/tree/main/config/singbox/1.14X> |
| Momo 插件 | <https://github.com/nikkinikki-org/OpenWrt-momo> |
| Sub-Store 教程 | <https://youtu.be/Qtf6U8Rx95o> |

### 1.2 OpenWrt 命令（原文）

```sh
# 安装/升级官方内核（有科学环境）
curl -fsSL https://sing-box.app/install.sh | sh

# 安装/升级官方内核（直连环境）
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/SagerNet/sing-box/stable/docs/installation/tools/install.sh \
  | sed 's#https://github.com/#https://gh-proxy.com/https://github.com/#' | sh

# 设置开机自启
uci set sing-box.main.enabled=1 && uci commit sing-box && /etc/init.d/sing-box enable

# 下载配置并启动（以后更新配置也用这条）
curl -fsSL -o /tmp/sb.json "你的配置链接" \
  && sing-box check -c /tmp/sb.json \
  && mv /tmp/sb.json /etc/sing-box/config.json \
  && /etc/init.d/sing-box restart

# 重启 / 停止 / 看日志
/etc/init.d/sing-box restart
/etc/init.d/sing-box stop
logread -e sing-box
```

原文说明：`API rate limit exceeded` 就换节点再跑；`你的配置链接` 换成 Sub-Store 生成的 sing-box 配置链接，引号保留。

### 1.3 Debian / Ubuntu 命令（原文）

```sh
# 切 root（已 root 可跳过）
su -            # 装 Debian 时设了 root 密码
sudo -i         # Ubuntu / 未设 root 密码的 Debian

# 没有 curl 时
apt update && apt install -y curl

# 安装/升级官方内核（有科学环境）
curl -fsSL https://sing-box.app/install.sh | sh

# 安装/升级官方内核（直连环境）
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/SagerNet/sing-box/stable/docs/installation/tools/install.sh \
  | sed 's#https://github.com/#https://gh-proxy.com/https://github.com/#' | sh

# 开机自启
systemctl enable sing-box

# 给局域网设备当网关时开启转发
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-sing-box.conf && sysctl --system

# 下载配置并启动
curl -fsSL -o /tmp/sb.json "你的配置链接" \
  && sing-box check -c /tmp/sb.json \
  && mv /tmp/sb.json /etc/sing-box/config.json \
  && chown -R sing-box:sing-box /etc/sing-box \
  && systemctl restart sing-box

# 重启 / 停止 / 状态 / 日志
chown -R sing-box:sing-box /etc/sing-box && systemctl restart sing-box
systemctl stop sing-box
systemctl status sing-box
journalctl -u sing-box --output cat -f
```

### 1.4 面板地址（原文）

| 面板 | 地址 | 密码 |
|---|---|---|
| Clash API 面板 | `http://设备IP:9095/ui` | 配置里 `clash_api.secret` |
| sing-box 官方面板 | `http://设备IP:9090/dashboard/` | 配置里 `services.secret` |

### 1.5 Momo 相关（原文）

```sh
# 仅核心：关掉 sing-box 自己的开机自启并停止服务
/etc/init.d/sing-box disable && /etc/init.d/sing-box stop

# Momo 定时重启：每天凌晨 4 点（填「插件配置 → 定时重启 → Cron 表达式」）
0 4 * * *
```

### 1.6 换 reF1nd Fork 内核（原文）

OpenWrt（x86_64 示例；ARM64 把 `amd64` 换成 `arm64`，版本号整体替换）：

```sh
# 下载（有科学环境）
cd /tmp && curl -fsSL -o sb.tar.gz \
  https://github.com/reF1nd/sing-box-releases/releases/download/v1.14.3-reF1nd/sing-box-1.14.3-reF1nd-linux-amd64-musl.tar.gz \
  && tar -xzf sb.tar.gz

# 替换内核
/etc/init.d/sing-box stop \
  && cp /tmp/sing-box-1.14.3-reF1nd-linux-amd64-musl/sing-box /usr/bin/sing-box \
  && /etc/init.d/sing-box start \
  && sing-box version
```

直连环境只把下载地址前加 `https://gh-proxy.com/`；Momo 用户先取消「启用」并保存应用，替换后从「配置文件」页上传配置，再勾「启用」。

Debian / Ubuntu 用 `-linux-amd64-glibc.tar.gz`（ARM64 用 `arm64`），替换后：

```sh
systemctl stop sing-box \
  && cp /tmp/sing-box-1.14.3-reF1nd-linux-amd64-glibc/sing-box /usr/bin/sing-box \
  && chown -R sing-box:sing-box /etc/sing-box \
  && systemctl start sing-box \
  && sing-box version
```

### 1.7 换回官方内核（原文）

```sh
# 有科学环境
curl -fsSL https://sing-box.app/install.sh \
  | sed 's#apk add --allow-untrusted#& --force-reinstall#' | sh

# 直连环境
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/SagerNet/sing-box/stable/docs/installation/tools/install.sh \
  | sed -e 's#https://github.com/#https://gh-proxy.com/https://github.com/#' \
        -e 's#apk add --allow-untrusted#& --force-reinstall#' | sh
```

换完重启一次 sing-box 生效；Momo 用户点「重启服务」。

### 1.8 OpenWrt 装 SFTP 服务（原文，仅传文件工具连不上时需要）

```sh
apk add openssh-sftp-server
```

### 1.9 reF1nd 订阅配置（providers）

填在 `/etc/sing-box/config.json` 顶层，`url` 换成订阅链接：

```json
"providers": [
  {
    "tag": "JC1",
    "type": "remote",
    "url": "此处填入订阅链接",
    "health_check": {
      "enabled": true,
      "url": "https://www.gstatic.com/generate_204",
      "interval": "10m",
      "timeout": "3s"
    },
    "exclude": "官网|剩余|流量|套餐|免费|订阅|全球直连|到期时间|GB|Expire Date|Traffic|ExpireDate",
    "http_client": "直连下载",
    "update_interval": "12h"
  }
]
```

### 1.10 原文的两段 AI 提示词（摘要）

原文给 OpenWrt 与 Debian 各一段“生成 sing-box 管理脚本”的提示词，要求 `sh`、数字菜单、5 个功能：

1. 安装/升级：原样跑官方 gh-proxy 安装脚本；OpenWrt 再 `uci set sing-box.main.enabled=1` + `init.d enable`；Debian 再 `systemctl enable` + 写 `ip_forward`。
2. 更新配置：首次输入 Sub-Store 链接存 `/etc/sing-box/config.url`；下载到临时文件 → `sing-box check` → 通过才覆盖并重启，失败保留旧配置。
3. 重启服务。
4. 看日志（OpenWrt `logread`，Debian `journalctl`）。
5. 每天 4 点自动更新（OpenWrt 写 `/etc/crontabs/root` + `init.d cron restart`；Debian 写 `/etc/cron.d/sing-box`）。

快捷命令：脚本把自己复制到 `/usr/bin/sb`（Debian 为 `/usr/local/bin/sb`）并 `chmod +x`。

### 1.11 原文配置模板的结构（linux.json）

原文指向的 `qichiyuhub/rule` 1.14X 模板包含 `linux.json` / `linux_mini.json` / `momo.json` / `reF1nd.json` / `windows.json` / `iphone.json`。`linux.json` 的关键结构：

- `dns`：`local` + DoH（阿里/腾讯）+ `google`（走代理）+ `fakeip`（`198.19.0.0/16`），`strategy: ipv4_only`；
- `outbounds`：按业务分组的 `selector` + `urltest`，`final` 为「漏网之鱼」；
- `route`：`sniff` / `resolve` / `hijack-dns`，`rule_set` 远程 `.srs`（geosite/geoip），CN 直连、非 CN 走默认代理；
- `inbounds`：`tun`（`172.19.0.1/30` + `fdfe:dcba:9876::1/126`，`auto_route: true`，`auto_redirect: true`）+ `mixed 0.0.0.0:7890`；
- `services.api`：`0.0.0.0:9090`，dashboard 自动下载；
- `experimental.clash_api`：`0.0.0.0:9095`，`secret: passwd`；
- `certificate.store: chrome`、`ntp.enabled: true`。

> **注意**：该模板是 IPv4-only（`dns.strategy: ipv4_only`），与本项目「IPv6 全量代理」的冻结策略冲突；迁移时必须改。

---

## 2. 本机实测（2026-10-27）

### 2.1 设备事实（只读探测）

| 项 | 实测值 | 说明 |
|---|---|---|
| 系统 | OpenWrt 23.05.4 `r24012-d8dd03c46f` | `/etc/openwrt_release` |
| target | `sdx75/generic` | 厂商固件 |
| 架构 | `aarch64_cortex-a53` | opkg 架构 |
| 内核 | `5.15.194-perf` | 不需要 legacy 构建 |
| libc | musl：`/lib/ld-musl-aarch64.so.1 -> libc.so` | **无 glibc loader** |
| 包管理 | opkg，已装 848 包，**无 `sing-box` 包** | 原文的 `curl \| sh` 依赖官方 feed，本机不适用 |
| 防火墙 | iptables 1.8.8 legacy；nftables 1.0.8 | `nft list ruleset` 可读，当前为空 |
| TUN | `/dev/net/tun` 存在 | 已实测创建 `tun0` |
| 内存 | 1.63 GB 总，约 1.07 GB available | 空闲 RSS 约 53 MB |
| `/data` | 1.3 GB 可用（放完 88 MB 内核后） | 够放内核 + 规则 + cache |
| shell | `/bin/sh -> busybox`；`/bin/bash` 存在 | 脚本仍按 busybox sh 写 |
| init | `/etc/init.d/` 有厂商服务，无 `sing-box` | 不能照搬原文 `uci`/`init.d` 流程 |

### 2.2 关键发现：官方 arm64 是 glibc 动态链接

```text
官方 sing-box-1.14.4-linux-arm64.tar.gz
  ELF machine 183 (AArch64)
  PT_INTERP = /lib/ld-linux-aarch64.so.1     ← glibc
设备
  /lib/ld-linux-aarch64.so.1: No such file or directory
  /lib/ld-musl-aarch64.so.1 -> libc.so
```

因此：

- 官方 `linux-arm64` 包在本机**不能直接执行**；
- 原文的 OpenWrt 安装脚本之所以能跑，是因为它安装的是 OpenWrt feed 里针对 musl 编译的包，而本机厂商 feed 没有 `sing-box`；
- **reF1nd `linux-arm64-musl` 是静态 ELF（无 `PT_INTERP`）**，可直接运行。

### 2.3 裸核实跑证据

下载并推送：

```text
https://github.com/reF1nd/sing-box-releases/releases/download/v1.14.4-reF1nd/sing-box-1.14.4-reF1nd-linux-arm64-musl.tar.gz
sha256(tar.gz) = 0a0828c76a9c7561825b1873f8029b8b3b8cb414bdc3d68b953c5c8da40962df
sha256(binary) = fc5e3ba4a1c6d6bbbcdd738c5f65c26720133ea12d53752c3d87e7d634becd12
```

设备输出：

```text
sing-box version 1.14.4-reF1nd
Environment: go1.26.10 linux/arm64
Tags: with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,
      with_clash_api,with_tailscale,...,with_ebpf,with_musl
CGO: enabled
```

最小配置（仅 mixed 入站 + direct 出站）：

```json
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 7891 }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
```

结果：

```text
sing-box check → OK
curl -x http://127.0.0.1:7891 https://www.gstatic.com/generate_204 → 204
sing-box 启动 0.01s；默认接口识别为 rmnet_data0
VmRSS 53.7 MB（空闲）→ 56.8 MB（5 次请求后）
```

### 2.4 TUN 实测

```json
{ "type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"],
  "auto_route": false, "auto_redirect": false, "stack": "mixed" }
```

结果：

```text
inbound/tun[tun-in]: started at tun0
33: tun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 65535
    inet 172.19.0.1/30
杀掉进程后 tun0 消失，无残留
```

结论：TUN 设备面可用；`auto_route`/`auto_redirect` 尚未在生产路由上验证（本次故意关闭，避免影响现网）。

---

## 3. 与现网 mihomo 的关系

| 项 | 现网 mihomo netns（回滚态） | sing-box 规划 |
|---|---|---|
| 运行位置 | netns `mihomo`，`192.168.0.254` | 宿主直跑（TUN） |
| 客户端网关/DNS | DHCP 下发 `0.254` | 必须改回 `192.168.0.1`（否则切换后客户端 ARP 不到网关） |
| 入口 | REDIRECT `7892` + mixed `7890` | TUN + mixed（lab 用 7891） |
| 控制器 | `9999` | 生产建议仍 `9999`（面板/触屏兼容），lab 用 `9095` |
| fake-ip | `198.18.0.0/16`（+ v6） | 生产 `198.18.0.0/16` 保持客户端缓存连续；lab 用 `198.19.0.0/16` |
| mark/table | `0x1ed4` / table 100；`0x1ed5` table 101；出站 mark `0x1ed6` | **全部错开**：暂定 `0x1ed7`/102（v4）、`0x1ed8`/103（v6），动前先查双方脚本（§20.8 教训） |
| 出站选路 | mwan3 三口 50/25/25 | 必须验证不被 `auto_detect_interface` 绑死单口 |

**互斥**：sing-box 与 mihomo 任何形态都不得同时接管生产流量。lab 阶段只开 mixed 端口，不开 `auto_route`/`auto_redirect`。

---

## 4. 落地方案（默认方案 A）

### 4.1 目录与命名（建议冻结）

| 项 | 值 |
|---|---|
| 根目录 | `/data/sing-box/` |
| 内核 | `/data/sing-box/sing-box`（reF1nd musl 静态，pin sha256） |
| 配置 | `/data/sing-box/config.json` |
| 规则缓存 | `/data/sing-box/rules/` |
| 面板 | `/data/sing-box/ui/` |
| 状态 | `/data/sing-box/state/` |
| 备份 | `/data/sing-box/backup/` |
| 主脚本 | `/data/sing-box/sing-box.sh`（start/stop/status/check/switchover/rollback） |
| 看门狗 | `/data/sing-box/watchdog.sh`（15s，flock 单实例） |
| 日志 | `/tmp/sing-box.log`、`/tmp/sing-box-watchdog.log`（1 MB 截断） |
| TUN 名 | `sbtun0`（避免与 `utun`/`tun0` 混淆） |
| lab 端口 | mixed `7891`、clash_api `9095`、api `9096` |
| 生产端口 | mixed `7890`、clash_api `9999`、api `9090`（可关） |

### 4.2 阶段

#### P0 内核与最小面（已完成大部分）

- [x] 确认 musl/glibc 差异，选定 reF1nd musl 静态包
- [x] `sing-box version` / `check` / mixed 204
- [x] TUN 创建与清理
- [x] 内存基线（~57 MB RSS）
- [ ] 记录 CPU 空闲/转发基线（`top -b -n1`、单流 iperf3/curl 大文件）
- [ ] 确认 `nft` 写权限与 `auto_redirect` 所需内核能力（只读检查，不启用）

#### P1 最小可用配置（lab，不影响现网）

目标：在宿主用 7891/9095 跑一份 sing-box，验证 DNS、规则、代理组、clash_api。

- 配置：`tun` 关闭或 `auto_route:false`；`mixed 127.0.0.1:7891`；`clash_api 127.0.0.1:9095`。
- DNS：DoH（`doh.pub`/`alidns`）+ `direct` 域名解析；先不做 fake-ip，确认解析链。
- 出站：`direct` + 一个手工节点（或一个订阅 provider），验证 TCP/UDP。
- 验收：`check` 通过；`curl -x` 204；`/version`、`/proxies` 可读；日志无 error。

#### P2 透明代理 lab（关键闸门）

在维护窗内、只对一台测试客户端开放，验证数据面：

1. 停 mihomo 看门狗与内核（见 §4.6 顺序），保留回滚路径。
2. 恢复 DHCP option 3/6 = `192.168.0.1`（或手工给测试机静态网关）。
3. 启动 sing-box：`tun` + `auto_route:true`，先 `auto_redirect:false`，用手工 `iptables`/`nft` 规则只重定向测试机流量（按源 IP 限定）。
4. 验证：
   - v4：`baidu/taobao` 200；`gstatic` 204；
   - **v6：客户端到 `baidu/qq/taobao` 的 TCP 必须通**（§20.8 闸门）；不通就停，不上生产；
   - DNS：客户端 `dig @192.168.0.1` 命中 fake-ip/预期上游；
   - 三口：`mwan3 status` + conntrack 看 v4/v6 是否仍分摊，确认没有被 `auto_detect_interface` 绑死 5G；
   - 回环：设备自身访问 `192.168.0.1:9999`、LAN、OTA 阻断链不受影响。
5. 任一失败：立即 `sing-box.sh stop` + 恢复 mihomo + DHCP 0.254。

#### P3 生产切换

- 写 `sing-box.sh switchover`：
  1. `kill $(cat /data/mihomo/smart/mihomo-smart-watchdog.pid)`（若 smart 在跑）；
  2. `mihomo-smart.sh stop` 或 `mihomo-netns.sh stop`；
  3. 校验：无 netns、无 `0.254` 地址、无 `utun`、无 9999 监听、无 table 100/101 规则；
  4. DHCP 3/6 → `192.168.0.1`；
  5. `sing-box check` → 启动 → verify（API/存活/代理 204/直连/v4v6/DNS/三口）；
  6. 失败自动回滚：停 sing-box、恢复 DHCP `0.254`、`mihomo-netns.sh start` + `init.d enable`。
- 开机：`/etc/rc.local` 加 sing-box watchdog 块（awk 原子写 + `sh -n`），不要动 OTA 阻断块。
- 看门狗：移植 `mihomo-smart-watchdog.sh` 的有界重启/flock/argv[0] 判活/日志截断逻辑。
- 面板：先验证 clash_api 与现有 manager/触屏页的兼容性；不兼容就保留 9999 但只作 API，不改 UI。

#### P4 规则与订阅迁移

- `proxy-providers`（Clash YAML）→ sing-box `providers`（需 sing-box 格式 JSON）。若只有 Clash 订阅，需：
  - 用 Sub-Store 生成 sing-box 配置/订阅；或
  - 自建转换器（Clash YAML → sing-box outbounds）。
- `rule-providers` → `route.rule_set` 远程 `.srs`；国内/国外/淘宝/测速等策略逐条映射。
- 保留冻结策略：IPv6 全量代理；禁测速域 DIRECT；禁 `PROCESS-NAME`；淘宝组排除 BGP/境外；DNS DoH 组合。
- 模板里的 `dns.strategy: ipv4_only` 必须改（建议 `prefer_ipv6` 或删除，按实测）。
- `certificate.store: chrome`、`ntp.enabled: true` 删除（本机无 chrome store；时间由厂商/timekeeper 管）。
- `services.api.dashboard.download_url` 不在启动时联网下载；面板文件预置到 `/data/sing-box/ui/`。

### 4.3 配置骨架（草案，字段以 1.14 文档为准）

```jsonc
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "local", "type": "local" },
      { "tag": "doh", "type": "https", "server": "doh.pub", "domain_resolver": "local" }
      // + fakeip（生产 198.18.0.0/16；v6 段待确认字段 inet6_range）
    ],
    "final": "doh"
  },
  "inbounds": [
    { "type": "tun", "tag": "tun-in", "interface_name": "sbtun0",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "auto_route": true, "auto_redirect": false, "stack": "mixed" },
    { "type": "mixed", "tag": "mixed-in", "listen": "0.0.0.0", "listen_port": 7890 }
  ],
  "outbounds": [
    { "type": "selector", "tag": "PROXY", "outbounds": ["TARGET"] },
    { "type": "direct", "tag": "DIRECT" }
  ],
  "route": {
    "auto_detect_interface": false,          // 关键：不要绑死 rmnet_data0，交给 mwan3
    "default_domain_resolver": { "server": "local" },
    "rules": [
      { "ip_is_private": true, "outbound": "DIRECT" }
      // + CN 直连 / 其余走 PROXY；DNS hijack；v6 规则
    ],
    "final": "PROXY"
  },
  "experimental": {
    "cache_file": { "enabled": true, "path": "/data/sing-box/cache.db" },
    "clash_api": {
      "external_controller": "0.0.0.0:9999",
      "external_ui": "/data/sing-box/ui",
      "secret": ""
    }
  }
}
```

> `auto_detect_interface` 默认值需按 1.14 schema 核实；原则是**不能让 sing-box 把出站绑到单口**，否则 mwan3 失效。

### 4.4 启动/看门狗/切换脚本职责

| 命令 | 行为 |
|---|---|
| `sing-box.sh check` | `sing-box check -c config.json`，不启动 |
| `sing-box.sh start` | 互斥检查（mihomo 在跑则拒绝）→ 启动 → verify → 写 pid |
| `sing-box.sh stop` | 停看门狗 → TERM 内核 → 收子进程 → 清 tun/规则 |
| `sing-box.sh status` | 内核/pid/tun/端口/规则/最近日志 五行 |
| `sing-box.sh switchover` | 按 §4.2 P3 顺序原子切换，失败回滚 |
| `sing-box.sh rollback` | 停 sing-box → 恢复 DHCP 0.254 → 启 mihomo-netns |
| `watchdog.sh` | 15s 巡检；内核死 → 有界 restart（120s，TERM→KILL）；flock 单实例 |

维护顺序（沿用 §20.4）：**先杀看门狗，再 stop/rollback**；否则 15s 内被拉回。

### 4.5 验收清单

| 项 | 通过标准 |
|---|---|
| 内核 | `sing-box version` 为 `1.14.4-reF1nd`，sha256 匹配 |
| 配置 | `sing-box check` 0 error |
| 代理 | `curl -x http://192.168.0.1:7890 https://www.gstatic.com/generate_204` = 204 |
| 直连 | 设备直连国内站 200/正常 |
| DNS | 客户端 `dig` 命中预期；无泄漏/超时 |
| v4 客户端 | 网页/视频正常，conntrack 有 fake-ip 或 tun 记录 |
| **v6 客户端** | **国内 v6 TCP 通**（§20.8 闸门）；v6 全双工 |
| 三口 | `mwan3 status` 三口 online；新连接分布符合 50/25/25 |
| 资源 | 空闲 RSS < 120 MB；CPU 空闲与 mihomo 基线差 < 5% |
| 自愈 | `kill -9` 内核 ≤ 30s 拉起 |
| 持久化 | reboot 后自动起，全绿 |
| 回滚 | `rollback` ≤ 2 min 恢复现网 |

### 4.6 回滚路径

| 场景 | 操作 |
|---|---|
| lab 失败 | `sing-box.sh stop`；mihomo 未动，零影响 |
| 生产切换失败 | `sing-box.sh rollback` → 恢复 DHCP 0.254 → `mihomo-netns.sh start` → `init.d/mihomo-netns enable` |
| 配置坏 | `cp /data/sing-box/backup/config.json.bak /data/sing-box/config.json` + restart |
| 内核坏 | `cp /data/sing-box/backup/sing-box.bak /data/sing-box/sing-box` + restart |
| rc.local 坏 | 恢复 `/etc/rc.local.bak-pre-singbox-*` |

---

## 5. 风险清单

| # | 风险 | 影响 | 处置 |
|---|---|---|---|
| 1 | 客户端 v6 TCP 首数据段消失（§20.8 未定位） | v6 站点挂，可能重演回滚 | P2 单客户端闸门；不通不上生产 |
| 2 | `auto_detect_interface` 绑死 `rmnet_data0` | mwan3 失效，只走 5G | 配置关闭；conntrack/mwan3 实测 |
| 3 | `auto_redirect` 与厂商 iptables-legacy/mwan3 冲突 | 整网中断 | 先 `false` + 按源 IP 手工规则；nft 规则单独验证 |
| 4 | DHCP 网关仍指 `0.254` | 切换后客户端全断 | switchover 强制改 3/6 并让客户端续租 |
| 5 | fake-ip 段冲突/客户端 DNS 缓存 | 部分站点异常 | lab 用 198.19/16；生产沿用 198.18/16 |
| 6 | 订阅是 Clash YAML，sing-box 不认 | 节点池为空 | Sub-Store 生成 sing-box 格式；或自建转换器 |
| 7 | reF1nd fork 供应链/更新节奏 | 内核来源风险 | pin 版本 + sha256；保留官方自编译路线 B |
| 8 | 92 MB 内核 + 规则占 `/data` | 空间紧张 | 当前 1.3 GB 可用；规则用 `.srs` 本地缓存并定期清理 |
| 9 | 控制器免密 | LAN 内可改节点 | 沿用用户现状；如要加 secret，先改 manager/触屏 |
| 10 | 与 OTA 阻断/mwan3-tuning 相互影响 | 升级/多 WAN 异常 | 不碰 `TOPFLOW_OTA_BLOCK4/6`、hosts 托管块、mwan3 配置 |

---

## 6. 待办（下一班）

1. 在 lab 写第一份可 `check` 的配置（mixed + direct + 一个节点 + clash_api），跑通 P1。
2. 查 1.14 schema：`route.auto_detect_interface`、`route.default_mark`、`dns.servers[].inet6_range`、`tun.auto_redirect` 的准确字段与默认值。
3. 确认订阅源：能否拿到 Sub-Store 的 sing-box 格式链接；不能则评估转换器。
4. P2 单客户端 v6 闸门（最重要）。
5. 设计 `sing-box.sh` 与 `watchdog.sh`（复用 `mihomo-smart` 的有界重启/flock 逻辑）。
6. 决定生产控制器端口：9999（兼容现有面板）或 9095（sing-box 默认）。
7. 更新 私人工作笔记（未公开发布） / 私人交接文档（未公开发布） 前先完成 P3，未上线不写「现行」。

---

## 附录 A：原文命令与本机适配对照

| 原文命令/做法 | 本机是否适用 | 替代 |
|---|---|---|
| `curl -fsSL https://sing-box.app/install.sh \| sh` | 否（依赖官方 feed） | 手动下载 musl 静态包到 `/data/sing-box/` |
| `uci set sing-box.main.enabled=1` | 否（无该 UCI 配置/服务） | 自写 `sing-box.sh` + rc.local |
| `/etc/init.d/sing-box restart` | 否（无 init 脚本） | `sing-box.sh restart` |
| `logread -e sing-box` | 否（本机 logd 不存在，永远空） | `tail /tmp/sing-box.log` / `tail /logfs/syslog` |
| `apk add openssh-sftp-server` | 否（23.05 用 opkg） | `opkg install openssh-sftp-server`（如需要） |
| `chown -R sing-box:sing-box` | 否（无 sing-box 用户） | root 运行，`/data/sing-box` 属 root |
| `systemctl` / `journalctl` | 否 | 本机无 systemd |
| `providers` | 是（fork 内核） | 需 sing-box 格式订阅 |
| `clash_api 9095` | 是 | lab 9095；生产可 9999 |
| `services.api 9090` | 可 | 可关，避免多一个面板 |
| `auto_redirect: true` | 待验证 | 先 `false` + 手工规则 |
| `dns.strategy: ipv4_only` | **禁止** | 改 `prefer_ipv6`/删除，保持 v6 全量 |
| `certificate.store: chrome` | 否 | 删除 |
| `ntp.enabled: true` | 不建议 | 删除，沿用厂商校时/timekeeper |

## 附录 B：本次实测的固定哈希

```text
# 官方 1.14.4（仅作对照，本机不可直接运行）
sing-box-1.14.4-linux-arm64.tar.gz
  436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26
sing-box（官方 arm64，glibc）
  d953af885f11d6b547c21a3c0ffe70796963afc802fab959d548311002b4908a

# reF1nd 1.14.4（本机选用）
sing-box-1.14.4-reF1nd-linux-arm64-musl.tar.gz
  0a0828c76a9c7561825b1873f8029b8b3b8cb414bdc3d68b953c5c8da40962df
sing-box（musl 静态）
  fc5e3ba4a1c6d6bbbcdd738c5f65c26720133ea12d53752c3d87e7d634becd12
```
