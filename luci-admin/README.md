# B22 LuCI 管理

为已解锁的 MU5252 B22 增加独立 LuCI，入口为
`http://192.168.11.1:8080/cgi-bin/luci/`，账号 `luci`。
原厂 Web 服务继续使用原端口；本组件只监听 LAN IPv4 和本机回环地址，使用 HTTP。

## 功能

| 菜单 | 功能 |
| --- | --- |
| 状态 | 系统、内存、交换空间、存储、路由、日志、进程和实时流量；三路基带与实际 AP 状态 |
| 系统 | 独立登录密码、服务启停和自启标志、整机重启 |
| 网络 | 无线名称/密码/隐藏和 SSID 开关，三路 IPv4/IPv6 联网接口连接/断开，MultiWAN 成员优先级/权重，Ping/DNS/路由追踪 |
| 服务 | Mihomo 启停、重启、开机启动和规则/全局/直连模式 |

账号只获得上述方法需要的权限，不开放任意 UCI 写入、文件写入或 Shell。
网页改密校验旧密码、保存 SHA-512 crypt 哈希，并注销该账号所有旧会话；不改变 root 密码。

## 前置条件

- 本机 Python 3.12+、ADB、支持 `passwd -6` 的 OpenSSL；设备已具备 root ADB。
- 固件严格匹配 `BD_ENCNMU5252V1.0.0B22`，LAN 为 `192.168.11.1` / `br-lan`。
- 先安装仓库的 `mihomo-netns` 和 `mihomo-manager`。管理器提供可写 RPC ACL 挂载及 `mihomo.api`。
- 本机 `127.0.0.1:9460` 已运行带 `/state`、`/capabilities`、`wifi.configure` 的
  `zwrt-datad`。本次运行验证使用 Rust 版 v0.10.18；不同版本需检查接口兼容性。
- 固件提供 ucode、UCI、UBus、OpenSSL、curl、iptables 和对应 ABI 的基础库；本组件不升级基础系统包。
- 首次安装不能与另一套 LuCI、同名账号或占用 8080 / 18080 的服务共存。

只读检查：

```sh
python3 luci-admin/manage.py preflight
```

有多台 ADB 设备时先设置 `ADB_SERIAL`。恢复命令不要求 Mihomo 或数据服务保持健康。

## 构建

```sh
python3 luci-admin/build.py
```

`packages.lock.json` 固定 9 个官方 OpenWrt 23.05.4 包的 URL、版本和 SHA-256。
构建器先校验全部下载，再安全解包，应用本仓库的页面、ACL 和 RPC 适配。
下载缓存和产物位于忽略的 `build/luci-admin/`，不提交包、上游提取内容或生成的完整 LuCI。
归档元数据固定，可以重复构建；不会调用 opkg 或连接设备。

```sh
python3 luci-admin/build.py --offline
# 使用另一个已下载缓存：
python3 luci-admin/build.py --offline --cache /path/to/packages
```

产物是 `build/luci-admin/bundle.tar.gz`，文件校验表为同目录 `SHA256SUMS`。
默认固定使用已验证版本；上游不再提供该文件时构建会失败，不会自动换成未验证版本。
更换包版本必须重新检查补丁上下文、ABI、权限和设备行为。

## 已安装设备升级

```sh
python3 luci-admin/manage.py upgrade
python3 luci-admin/manage.py status
```

升级前备份当前组件，保留设备当前密码，更新后注销旧 LuCI 会话。
启动失败会尝试恢复旧组件及升级前配置；备份继续保留。
如果 init 文件被独立修改，升级检查会停止，需先审阅修改。

为兼容已有安装，设备目录、服务名、启动标记、账号配置节继续使用
`/data/local/luci-readonly`、`luci-readonly` 和 `LUCI_READONLY`。
这些是历史名称，当前账号已经具有表中列出的管理权限。

## 首次安装与改密

首次安装包装器尚未在另一台干净 B22 上完成完整生命周期验证，参见 [验证记录](VALIDATION.md)。

```sh
python3 luci-admin/manage.py install
python3 luci-admin/change-password.py
```

安装时在终端隐藏输入两次密码，不提供默认密码。账号和配置备份保留在设备私有目录；
本机恢复凭据存入忽略的 `private/luci-admin/credentials.json`，目录 0700、文件 0600。
已有恢复凭据或旧安装备份时，安装器停止，避免覆盖；需要重新安装时先归档保留这些材料。

网页“系统 → 登录密码”只更新设备密码，不同步本机凭据文件。
`change-password.py` 通过 USB 设置新密码并同步本机文件；升级命令始终保留设备当前密码。

可选环境变量：`LUCI_BUILD_DIR` 指向构建输出，`LUCI_PRIVATE_DIR` 指向本机私有恢复目录。
使用 `--output` 构建到别处时，管理命令需设置相应的 `LUCI_BUILD_DIR`。

## 启动和卸载

```sh
python3 luci-admin/manage.py stop
python3 luci-admin/manage.py start
python3 luci-admin/manage.py uninstall
```

procd 监控独立挂载命名空间中的 uhttpd 与 LuCI RPC helper，异常退出时重新启动。
B22 不执行新增的常规 rc.d 项，因此另外使用 `rc.local` 的精确标记块登记服务。
启动脚本等待 LAN、rpcd 和 ACL 就绪，并维护只允许 LAN / loopback 的管理端口规则。

卸载停止服务，清除自己的账号、会话、ACL、端口规则和启动标记。
未被后续修改的配置按备份恢复；已变化的配置只移除自己的节。
设备文件、备份和本机凭据保留供排查。卸载 LuCI 后再移除它依赖的管理器或数据服务。

安装中断时，先保留 `/data/local/luci-readonly/backups/`，检查 init 和账号的创建进度；
如果安装尚未完成而卸载器拒绝操作，用 root ADB 依据同一次备份逐项恢复，不能混用别的设备备份。

## 已知边界

- 无线频段状态与 SSID 开关分开显示。保存未启用频段的名称/密码不会自动开启该频段。
- 频段切换、SIM/APN/锁频仍由原厂页面管理。移动网络按钮控制联网接口，保留基带供电和 SIM 选择。
- 服务自启列表示 init 启动标志；厂商独立启动机制可能不受此标志控制。
- MultiWAN 设置等待后台服务操作完成；在聚合模式下只保存配置，不切换工作模式。
- Mihomo 的“开机启动”仅修改自启标志；“启动/停止”沿用管理器的启用/禁用语义，同时改变自启。
- 未验证的通用无线扫描、无线图表和防火墙页面未开放。没有加入刷机、恢复出厂或固件升级功能。
- 改 LAN 地址或升级固件后需要重新适配；FOTA 可能替换 `rc.local`。

## 检查与来源

```sh
make luci-check
```

该命令仅做本机静态检查与打包/管理工具单元测试，不修改设备。
实际设备测试需人工安排，范围见 [VALIDATION.md](VALIDATION.md)。

本目录原创集成代码按仓库 MIT 许可证发布。构建时取得的 LuCI、uhttpd、ucode 和 util-linux
属于各自上游，许可证记录在锁文件中。LuCI helper 在构建时从官方包生成并保留其原许可证头。
第三方包和完整生成产物不随本仓库分发。上游：
[OpenWrt downloads](https://downloads.openwrt.org/releases/23.05.4/packages/aarch64_cortex-a53/)、
[LuCI](https://github.com/openwrt/luci)。
