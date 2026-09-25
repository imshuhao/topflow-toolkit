# 恢复与卸载

TopFlow Toolkit 的组件主要把原创文件放在 `/data`，再通过 init、`rc.local` 或单文件
bind mount 接入原厂系统。普通重启会保留这些改动；后台的“恢复出厂设置”是否会清理
`/data` 和被改写的 `rc.local`，目前没有做破坏性实测，不能把它当成完整卸载器。

## 开始前

- 保留 USB root ADB，确认 `adb shell id` 返回 `uid=0(root)`；
- 保留同一台设备、同一固件生成的修改前配置备份；
- 在改 DHCP、WebUI 或启动项前，准备一条不依赖当前 Wi-Fi/DHCP 的恢复入口；
- 不使用 `dd`、MTD、EDL 或不匹配的整机镜像处理本项目的文件级改动。

以下命令都在仓库根目录执行。先运行每个卸载器的 `--check`，确认目标仍属于对应
组件，再执行真正卸载。

## 推荐卸载顺序

| 顺序 | 组件 | 检查与卸载 | 恢复结果 |
| --- | --- | --- | --- |
| 1 | 完整 WebUI 菜单 | `./web-full-menu/uninstall.sh --check`<br>`./web-full-menu/uninstall.sh` | 移除最上层 Web 文件挂载，露出 Mihomo Manager 或原厂页面 |
| 2 | 触屏控制中心 | `./touchscreen-control-center/uninstall.sh --check`<br>`./touchscreen-control-center/uninstall.sh` | 停止注入进程并恢复原厂触屏 UI |
| 3 | Mihomo Manager | `./mihomo-manager/uninstall.sh --check`<br>`./mihomo-manager/uninstall.sh` | 移除厂商 WebUI 中的管理页、RPC 与 ACL |
| 4 | Mihomo 网关 | `./mihomo-netns/uninstall.sh --check`<br>`./mihomo-netns/uninstall.sh` | 撤销 DHCP Option 3/6、namespace、虚拟接口和 host 规则 |
| 5 | MULTIWAN 调优 | `./mwan3-tuning/uninstall.sh --check`<br>`./mwan3-tuning/uninstall.sh` | 恢复厂商生成脚本路径、原探测目标与 hotplug 行为 |
| 6 | Timekeeper | `./timekeeper/uninstall.sh --check`<br>`./timekeeper/uninstall.sh` | 按归属标记移除可信时间偏移和 watcher，恢复组件管理的时区配置及链接；下次启动恢复原厂联网校时 |

WebUI 菜单必须先于 Mihomo Manager 卸载，因为它可能叠在 Manager 的 Web 文件
bind mount 上。Mihomo Manager 应先于 Mihomo 网关卸载，避免管理页继续指向已删除的
服务。

Mihomo 默认保留私有配置。确认不再需要后，才使用其 README 中的
`REMOVE_PRIVATE_DATA=1`；不要把这一选项当成普通卸载的默认值。

## `zwrt-datad` 回退与移除

工具包只提供更新器，不接管 `zwrt-datad` 的首次安装或启动块。更新后不正常时优先
交换回上一版：

```sh
./zwrt-datad-tools/update-zwrt-datad.sh rollback
```

彻底移除前，先卸载依赖它的触屏控制中心。随后停止服务，基于设备当前
`/etc/rc.local` 的实际内容删除那一条精确启动命令，再删除目录：

```sh
adb shell 'sh /data/zwrt-datad/service.sh stop'
adb shell 'grep -n "zwrt-datad/service.sh" /etc/rc.local'
```

不要用模糊关键词批量删除整个 `rc.local`。先拉取一份副本、只删确认过的启动行，推回
后检查权限与 `sh -n`，最后才删除 `/data/zwrt-datad`。不同安装来源的启动方式可能
不同，因此仓库不提供一个假装通用的自动卸载命令。

## 三种“恢复”不是一回事

### 只恢复原厂界面

卸载 `web-full-menu`、`mihomo-manager` 和 `touchscreen-control-center`。网络数据面和
Timekeeper 可以继续运行。

### 撤销 TopFlow Toolkit

按上表依次卸载，再根据实际安装来源移除 `zwrt-datad`。最后重启并检查：

```sh
adb shell 'ip netns list; mount | grep -E "webui-full-menu|mihomo-manager|touchui|sdx75-set-mwan3-wrapper" || true'
adb shell 'grep -En "TopFlow|MU5252 Mihomo|zwrt-datad" /etc/rc.local || true'
adb shell 'uci -q get dhcp.lan.dhcp_option || true'
```

预期不再有项目 namespace、项目 bind mount 或项目启动块，DHCP 也不再下发 `.11`
网关/DNS。

### 严格恢复原厂

root ADB 本身来自对配置备份中 `rc.local` 的修改，不属于上述组件。最稳妥的回退是
恢复同一台设备、同一固件、修改前生成的原始配置备份，再验证 ADB 和 `/data` 状态。
如果还要求连 `/data` 中的归档都不存在，应在确认备份可用后逐项删除，不要假定后台
恢复出厂一定会代劳。

FOTA 可能替换 `rc.local`，但未必删除 `/data` 中的组件文件。升级后应基于新固件重新
检查兼容性，不能直接把旧 `rc.local` 整份覆盖回去。

## B22 升级恢复补充

本次 OTA 使用新 B22 `rc.local` 加最小 root/服务钩子，见 [升级记录](OTA-B20-TO-B22.md)。
`boot-services.sh` 还会启动已安装的服务；彻底移除相关组件时，应同时审阅该入口，
不能只删各组件自己的 rc.local 块。停用 `zte_dm` 与移除启动同步项必须配套，
恢复自动 OTA 时也必须一起恢复。
