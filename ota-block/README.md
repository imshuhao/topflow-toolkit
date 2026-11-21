# ota-block — 冻结官方 OTA 升级 + 上报域名屏蔽

> 2026-10-14 上线。目标：阻止中兴云（`*.ztems.com`）向本机推送/安装固件更新；
> 并按用户 2026-10-10 清单屏蔽 `seecom` / `nubia` 相关上报域名。
> 本仓库公开分支不附私人交接文档；组件说明以本 README 为准。

## 为什么需要

- 本机 OTA 走 `zte_dm` 守护进程：HTTPS 443 → `dmas/dms/dmin/dmeu/dmcan/dmcn(.ztems.com)/zxmdmp/dm`，
  包从 `dl*.ztems.com` 下载，写入非当前 A/B 槽位后重启切换。
- **服务器标记为 Critical 的版本全流程自动（不弹确认）**：2026-09-07 本机被
  `Critical;Auto` 从 B16 自动升级到 B20（`/etc_rw/ztembb/dm/UpdateHistroy.txt`）。
- 单靠"自动更新开关"不可靠（开关可被 App/流程改回；任何触发成功会话后都可能被强推）。

## 组件

| 文件 | 设备路径 | 作用 |
|---|---|---|
| `ota-block.sh` | `/data/topflow-ota-block/ota-block.sh` | `apply` / `keeper` / `status` / `revert` |
| `topflow-ota-block` | `/etc/init.d/topflow-ota-block` | procd 常驻 keeper（30s）+ apply |
| `install-rc-local-hook.sh` | `/data/topflow-ota-block/install-rc-local-hook.sh` | 给 `/etc/rc.local` 加开机拉起钩子（幂等/原子/带备份） |

**⚠ 本设备的开机拉起必须走 rc.local**：实测 rcS **不会执行 overlay 新增的 init.d 服务**
（本项目 netns / manager-web / touchscreen / timekeeper 全部由 rc.local 拉起）——
`S96topflow-ota-block` 链接保留（供 `enabled` 查询），但真正生效的是 rc.local 钩子块。

## 屏蔽清单

- **hosts → 127.0.0.1**（设备自身解析失败；LAN 客户端经 dnsmasq 同样拿到 127.0.0.1）：
  `ztems.com` 全家族（dmcn/dms/dms6/dmas/dmas6/dmin/dmeu/dmeu6/dmcan/dmcan6/dl14/upgrade）、
  `seecom.com.cn`、`ufi.seecom.com.cn`、`uapp.seecom.com.cn`、`report.server.nubia.cn`、`api-data.nubia.com`
- **防火墙**（iptables/ip6tables OUTPUT 首链 `TOPFLOW_OTA_BLOCK4/6`，TLS SNI/payload 匹配，
  端口 443+8883，不依赖 DNS）：`ztems.com`、`seecom.com.cn`、`nubia.cn`、`nubia.com`
- **IP 直连丢弃**：`36.133.8.210`、`61.145.136.87`
  （用户清单；无 PTR、未验证归属，如怀疑误伤从 `IPS4` 删除后重新 apply）
- **uci 软开关**：`zwrt_zte_dm.dm_update.dm_startup_no_check=1`（开机免检）
  （`TURNOFFPOLLING=1`、`dm_update_mode=0` 现状已安全，脚本不擅动，`status` 中展示）

> 注：本机 `0.0.0.0:443` 有本机 Web 服务监听，hosts 撞上它是 TLS 证书不符的必然失败（实测 DM 卡在
> `SSL_connect` 后超时中止）；且 SNI 规则在 OUTPUT 链上对**该路径同样生效**（ClientHello 直接被丢）。

## 部署 / 更新脚本

```sh
adb push ota-block/ota-block.sh /tmp/ob.sh
adb shell "mkdir -p /data/topflow-ota-block; tr -d '\r' < /tmp/ob.sh > /data/topflow-ota-block/ota-block.sh; chmod 755 /data/topflow-ota-block/ota-block.sh; sh -n /data/topflow-ota-block/ota-block.sh && echo ok"

adb push ota-block/topflow-ota-block /tmp/ob.init
adb shell "tr -d '\r' < /tmp/ob.init > /etc/init.d/topflow-ota-block; chmod 755 /etc/init.d/topflow-ota-block; sh -n /etc/init.d/topflow-ota-block && echo ok"

# 【必须】rc.local 开机钩子（幂等，可重复执行）
adb push ota-block/install-rc-local-hook.sh /tmp/inst.sh
adb shell "tr -d '\r' < /tmp/inst.sh > /data/topflow-ota-block/install-rc-local-hook.sh; chmod 755 /data/topflow-ota-block/install-rc-local-hook.sh; sh /data/topflow-ota-block/install-rc-local-hook.sh"

adb shell "/etc/init.d/topflow-ota-block enable; /etc/init.d/topflow-ota-block start"
adb shell "/data/topflow-ota-block/ota-block.sh status"
```

## 实测验证（2026-10-14）

- 计数器 A/B：百度 200 且 SNI 规则计数为 0；`curl https://dmcn.ztems.com/` 超时且计数 +n（规则命中）。
- 实弹：`ubus call zwrt_zte_dm check_new_version` → `DM_ConnectToServer ... OK` → 卡在
  `SSL_connect start` → 重试累计被规则丢 **225 包/64.5KB** → `DM_DmSessionAborted` → 回 `version_idle`；
  `/cache` 无任何下载物。
- 开机终验：reboot 后 keeper(PID 新)+两链+hosts+uci 全自动恢复；`ping dmcn.ztems.com` → `127.0.0.1`。
- 自愈：手动删 jump+hosts 行，30s 内 keeper 自动修复（日志 `(re)added / (re)written`）。

## 影响面与回滚

- Web / 触屏"系统升级"入口将永远检查失败（预期）。
- `seecom` 被屏蔽后：**中兴 App 的绑定 / 远程功能、打点上报会失效**（MQTT 通道走 `ufi.seecom.com.cn`）。
  不想要就从 `DOMAINS` / `SNIS` 删除对应项后重新 `apply`。
- 注意 `nubia.cn`/`nubia.com` SNI 匹配为全族屏蔽（打点端点 `api-data.nubia.com` 属之）。
- 回滚（恢复官方更新能力）：
  1. `/data/topflow-ota-block/ota-block.sh revert`
  2. `/etc/init.d/topflow-ota-block stop; /etc/init.d/topflow-ota-block disable`
  3. （可选）还原 rc.local：`cp /data/topflow-ota-block/backup/rc.local.bak-pre-otablock /etc/rc.local`
- 恢复出厂 / 重刷固件会清 rc.d 链接与 `/data`（届时重新部署；阻断不写 boot/system/MTD，无变砖风险）。
