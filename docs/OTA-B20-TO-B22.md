# MU5252 B20 → B22：升级、保留 root 与定制恢复记录

日期：2026-09-25。设备为 `MU5252_HW1.0`。本文记录这一次实际执行的过程、发现的问题及验证边界；当前主分支默认支持 B22。原厂固件、配置备份、抓包、日志、设备标识和密钥不入库。

## 结果与样本

已通过原厂本地更新流程升级到 `BD_ENCNMU5252V1.0.0B22`，跨升级保留 root，无需重新上传配置恢复包。升级后修复时间、触屏及启动配套配置，并再次重启验证。

| 项目 | 本次记录 |
| --- | --- |
| 原始包 | `EN_CN_MU5252V1.0.0B20-EN_CN_MU5252V1.0.0B22.upc` |
| 大小 | 209,899,720 字节 |
| SHA-256 | `e3e8a7b7103f5212aa75bd623948a0c25a8ea643671899ecbfc16ab0a5c80a2a` |
| 安装方法 | 原包校验 → `zte_topsw_dua` / `upd_util` 原厂状态机 |
| root 迁移 | 原厂 FOTA 保留 `uci-defaults` → 首次 B22 启动接入最小 root 钩子 |
| 原有 toolkit 基线 | `d04179165b7fcad05a014d60b3eb9f7ca70e67e2`；随后菜单样式修复已在仓库保留 |
| 数据服务 | `zwrt-datad` v0.10.18 |

先前只抓包和分析的阶段没有触发安装；本次是在明确授权升级后执行。电脑独立模拟 OTA 查询遇到鉴权失败，最终在设备内触发检测/下载并取回原包；本文不把主机独立鉴权模拟列为已解决，也不公开请求中的认证参数。

## 1. 升级前取证与备份

1. 通过 USB ADB 确认 B20、`uid=0`、活动槽和挂载布局，记录关键文件哈希及原有服务。
2. 从后台新导出官方配置备份，私下解包并核对内层 MD5、归档成员。未将旧 B20 配置包作为 B22 的整包恢复输入。
3. 创建 `/etc /etc_rw /zteoverlay /persist /data` 的文件级归档，拉取到电脑并复核大小、SHA-256 和 tar 可读性。归档 60,280,998 字节、2,769 条目；忽略运行时 socket。它不是整机分区镜像，也不保证跨固件整包回灌安全。
4. 保存原有 init、`rc.local`、组件源码/构建、部署清单及升级前服务状态，供逐组件恢复。
5. 保存原始 OTA 到电脑并确认上述哈希。离线解码、比较包内 B22 与原厂 B20；不在主机执行包内升级脚本。

私有文件级备份 SHA-256：`9d0043f3baef3a3f84df3f70a1401e67d1c989fa197512898b44fb09f107812f`。备份、解密材料和原始日志只保存在本机受限目录。

## 2. 确认升级通道与 root 迁移

静态核对的原厂路径：

- 默认 FOTA 保存列表不包含 `rc.local`，仅保留 `/data` 不足以保留 root 启动调用。
- `backup_config.sh` 的 FOTA 分支额外保存活动 overlay 的 `uci-defaults/` 至 `/zteoverlay/uci-defaults`。
- B22 `etc/scripts/mounts-ab.sh` 将其恢复到新槽 overlay，`etc/init.d/boot` 执行 `/etc/uci-defaults`；返回成功后删除脚本。
- 升级前实际 `/etc` upperdir 为 `/zteoverlay/etc-upper_b`，不能套用通用 Qualcomm `/overlay/etc-upper_b` 路径。

本次部署到 `/data/local/root-b22` 的原创文件在 [root-migration](../firmware/b22/root-migration/)：

| 文件 | 作用 |
| --- | --- |
| `adb_shell` | root shell 包装器；供 bind mount 到 `/bin/adb_shell` |
| `boot-root.sh` | 严格检查 B22，挂载包装器、核对哈希，再开启 USB ADB；记录本次 boot ID |
| `90-mu5252-b22-root` | 首次 B22 启动校验全部迁移文件；仅接受原厂或已知已修补的 `rc.local` |
| `rc.local.b22-root` | 从私有 B22 原件生成；只在原厂 shebang 后插入 root 钩子，不公开原文件 |
| `SHA256SUMS` | 迁移文件完整性检查；在设备内执行 `sha256sum -c` |

可以用本地原厂文件复现准备步骤（只生成文件，不访问设备）：

```sh
python3 firmware/b22/root-migration/prepare.py \
  /private/path/b22/etc/rc.local /private/path/b22-root-staging
```

准备器核对原件哈希 `21ab5b3c49c4b9b96e6fb69f5e73ea6dcd6ceb840ea5a2bf34d8da5570bc0280`，生成结果必须为 `ff99d5f4468c6d18b76d63176b07fca557a0865f76fe27c41922454256d1d350`。

实际布置步骤：将生成的文件复制到 `/data/local/root-b22`（目录 root/0700、脚本 root/0755），将一次性脚本放入当前 `/etc/uci-defaults/` 和 `/zteoverlay/uci-defaults/`。在 B20 上它返回非零，不提前改写 `rc.local`；在 B22 上才执行。隔离验证覆盖 B20 跳过、B22 安装、重复执行和未知 `rc.local` 拒绝。

## 3. 使用原厂更新器安装整包

以下是本次执行记录，不是面向任意版本的一键刷机脚本。前提是原包、备份、迁移脚本及实际启动链已逐一验证。

1. 将原包传到 `/cache/b22-staged.upc`，在设备核对 SHA-256 后改名为 `/cache/delta.package`。
2. 执行 `/usr/bin/zte_topsw_dua validate`；确认是本次新生成的 `validate_ok.flg`，没有失败标记。不能只看到以前遗留的成功标记就继续。
3. 静态确认原厂库调用顺序后，执行以下本地安装入口：

   ```sh
   touch /cache/fota_start_flag && sync
   mv /cache/delta.package /cache/delta.bin
   upd_util update
   ```

4. 由现有 `zte_topsw_dua standalone` 处理升级状态机。监控日志、阶段和进度；外置 V3T 更新阶段出现过短暂 AT 超时/CME 8012，但之后自行推进，未手工中断或跳过分区。
5. 等待主系统/基带阶段完成、进度 100%、ADB 断开再出现；最终 `/cache/update.rt` 为 `0`，更新器结果成功。

没有对解出的 boot/system/modem 镜像执行 `dd`，没有修改原 OTA 包，也没有直接修改槽选择或 bootloader。

## 4. 首次 B22 启动确认 root

首次启动后确认版本为 B22、ADB `uid=0`、包装器 bind mount 和哈希匹配；迁移日志成功，`migrated` 文件存在，一次性 uci-defaults 脚本按预期消失。

`boot-root.sh` 写入的 boot ID 必须与当前 `/proc/sys/kernel/random/boot_id` 一致，以证明本次开机确实执行，而非读取旧成功日志。此次没有重新执行 Web 配置恢复 root。

原厂 B22 配置恢复实现及 suffix 的兼容性曾做静态比对，但“在 B22 上重新 root”这条回退路径并未实际执行；不能与本次已验证的“跨升级保留 root”混为一谈。

## 5. 恢复服务与 B22 适配

### 原有服务

保留 `/data` 中已有配置，恢复 `mihomo-netns`、`mihomo-manager-web`、`web-full-menu` 的 init/自启，接回 `zwrt-datad` 和 mwan3 调整。

本次实际使用的 [boot-services.sh](../firmware/b22/root-migration/boot-services.sh) 从新 B22 `rc.local` 的 `exit 0` 前调用；随后由 timekeeper 和触屏各自安装器追加自己的启动块。该脚本只适用于这些组件已安装、配置已保留的设备，不负责全新安装依赖。

四份被覆盖的 Web 文件（index、menu、router、network_lock）及 mwan3 原厂包装目标在 B20/B22 间逐字节一致，因此沿用现有定制。没有把整份旧 `/etc` 或 B20 `rc.local` 覆盖到新系统。

### 时间

首次 B22 联网后复现原厂 NTP 将 UTC 多加 8 小时。修复仍保留原厂 SNTP/NITZ 协议、校验、通知以及 `time_daemon` 的 base 1 优先、base 1 缺失才使用 base 12 的恢复逻辑。

| 程序 | B22 原件 SHA-256 | 修补后 SHA-256 |
| --- | --- | --- |
| ntpclient | `81807b2d742bd14749fcfb2a198ad7e44246dfa6ee91907f1c7152a0d4f0f4f1` | `e994927b2a7ca4fe96b87ce5d89caa1cb8e9af608c2d88908c055da8741da9b8` |
| zte_topsw_nwinfo | `55dbb174dd8549410de9e37ae3e8bbef08abb8816789a83e1fbc24b87b5ea5af` | `29c3c7145f52b9e16f63b368e7a22587674f137c8725a582a852fa0ef4e8fdd2` |

- NTP：`0x4d44` 的 `000340bd` → `51000014`，跳过时区/DST 加算，保留 UTC 转换和写钟。观察器返回地址仍为 `0x4eb4`。
- NITZ：B20 的 `0x31a68` 移到 B22 `0x31bb0`；`20c0208b` → `e00301aa`，去掉 UTC 后再次叠加时区。观察器返回地址由 `0x31b64` 移到 `0x31cac`。
- 对齐的 NITZ 代码区有 144 条指令，10 处差异均解析为相同字符串的地址变化；并非仅按偏移差盲改。
- 每个补丁通过完整哈希、幂等、只改目标指令和 6 个 AArch64 模拟场景；22 项既有 timekeeper 回归通过。
- 编译 AArch64 musl helper，安装时从设备私下取得原件生成 UTC 副本，以 bind mount 接入并检查实际进程及观察器。
- 等待新的真实 SNTP 修正系统时间；观察并通过 `time_genoff` base 12 保存新事件。没有盲目手工减 8 小时或写物理 RTC。

源码入口：[timekeeper](../timekeeper/)。仓库保留标准 `build/` 产物布局；不复制升级现场临时脚本使用的扁平构建目录。

### 触屏

B22 `zte_topsw_devui` SHA-256 为 `781e3c6ffa2a9db4d61a3cf1bb38461131dc3faed07499a2c9360bc582040dd2`。LVGL 库与 B20 完全一致；四个按钮图片内容和描述符已匹配，地址变化如下：

| 图片 | B20 | B22 |
| --- | --- | --- |
| 返回普通态 | `0xeefbb8` | `0xeefb58` |
| 返回按下态 | `0xeefbe8` | `0xeefb88` |
| 首页普通态 | `0xef0258` | `0xef01f8` |
| 首页按下态 | `0xef0268` | `0xef0208` |

更新资源引用和安装器完整哈希，严格编译后安装。JSON 匹配与 6 个采集到诊断的契约场景通过；确认单个 UI 进程、hook 映射和监护进程。没有把 B20 编译的 hook 直接用于 B22。

### 手动 OTA 的启动配套修复

第一次验证重启时，恢复配置遗漏了一个配套项：停用 `zte_dm` 后，原厂 `zte_topsw_daemon.conf` 仍将它列为必需就绪服务。实测 `get_sync_info` 返回 `noSyncModuleName: zte_dm`；MC 缺少开机状态，devui 等待后退出，触屏驱动未加载，三网状态读取异常。

这是本次恢复配置的遗漏，不是 B22 触屏驱动坏了。诊断时暂时追踪/重启过 devui 和 MC；这些临时进程在最终重启时清除，恢复正常启动链。

最终保持 `zte_dm` 停止/禁用，同时只移除同步列表中的对应行。补丁见 [manual-ota.patch](../firmware/b22/manual-ota.patch)。其他服务仍参与就绪检查，不伪造“所有服务已就绪”。将来恢复自动 OTA 时，必须将同步项和 `zte_dm` 自启一起恢复。

## 6. 最终重启验收

修复上述等待项后，再次执行 `sync; reboot`，用新 boot ID 确认发生了真实重启，再等待原厂及自定义服务启动。

| 检查 | 最终结果 |
| --- | --- |
| B22 / ADB root / 本次 root 开机钩子 | 通过 |
| 原厂同步与注册 | `sync success` / `register success` |
| x75 / v3e1 / v3e2 | SA / LTE / LTE；均 `ipv4_ipv6_connected` |
| Wi-Fi / MULTIWAN | 启用 / 服务运行 |
| zwrt-datad | v0.10.18；`/healthz` 为 ok，`/state` 三网数据可读 |
| Mihomo | 进程及 namespace 运行 |
| LAN DNS / 外网 HTTPS / 后台 HTTP | 通过 / 200 / 200 |
| 触屏 | hook 与监护进程运行；截屏确认三网卡片及控制中心入口显示正常 |
| 时钟 | 最终 UTC 与电脑相差 -0.29 秒 |
| 本次新 SNTP | 成功，观察到新事件并经 base 12 保存、读回 |
| OTA | 本次安装成功，自动 OTA 保持停用 |

部署记录核对了 32 对源码/设备文件，并另记 17 个生成/外部文件的当前哈希。实际备份和含设备状态的原始清单保存在本机；设备清单位于 `/data/local/topflow-toolkit-deployment.json`。同步仓库前曾明确标记“本地未发布”，发布后再更新提交来源，不能用旧 Git 提交冒充 B22 部署版本。

本次未重做所有离线/NITZ、触屏设置、浏览器登录、聚合切换、全新设备安装和完整卸载场景；未验证降级 B20，也不据此声称 B22 性能或续航提升。

## 7. 同步到当前仓库

当前主分支直接采用 B22 的时间与触屏代码，不设置 B20 默认或额外覆盖层。
保留了仓库已有的标准构建目录和最新菜单修复；B20 代码留在 Git 历史。
`make check`、B22 补丁的完整哈希/幂等/修改范围检查、B20/未知输入拒绝均通过。
迁移准备器使用私有原件复现了完全相同的 payload，并确认未知原件在写入输出前被拒绝。

Alpine 在线下载依赖一度失败，随后使用本机已缓存的 AArch64 Alpine 构建环境成功编译。
重新构建的四个 helper/hook 及 31 个其他受管文件（合计 35 对）与当前设备逐文件 SHA-256 相同。
未重新刷写固件；发布后仅更新设备部署清单的 Git 来源与发布状态。
