# Touchscreen control center

该组件通过 `LD_PRELOAD` 扩展原厂 `zte_topsw_devui` 的 LVGL 界面，不替换原厂程序。首页增加一个“控制中心”入口：

```text
控制中心
├── 网络仪表
│   └── 三基带详情、趋势、流量、SIM 与模块
├── Mihomo
└── 设备状态
    ├── 系统与全局流量
    ├── 散热与风扇曲线
    ├── Wi-Fi 功率
    └── 一键诊断
```

状态数据每秒从本机 `zwrt-datad /state` 读取；散热、Wi-Fi 和刷新操作只向 `/control`
发送固定 action 与受约束参数。Mihomo 操作只调用
`/data/mihomo-manager/mihomo-manager.sh` 的固定子命令。大陆四家运营商统一显示为完整中文名；
其余超出可用宽度的运营商、地址和身份字段使用仅溢出时启用的循环滚动标签。

## 兼容性

当前只支持 root README 所列 B22 固件。原厂 UI 是固定地址、非 PIE 程序；导航按钮引用该进程中已加载的对象，安装器因此会严格核对：

```text
zte_topsw_devui SHA-256:
781e3c6ffa2a9db4d61a3cf1bb38461131dc3faed07499a2c9360bc582040dd2
```

哈希不匹配时不要修改安装器跳过保护。新固件需要重新审计 LVGL ABI、对象地址、生命周期和恢复路径。

仓库不含任何 ZTE 二进制、共享库、字体或可复用原厂图像资源。上传/下载箭头由本项目运行时生成；信号图标只引用设备已有 `/usr/ui/skin` 路径。文档中的脱敏实机截图只用于功能展示。

## 依赖

- root ADB；
- AArch64 musl 交叉编译器；
- 设备端 `zwrt-datad`；
- Mihomo 页面功能需要 `mihomo-manager`，其他页面可独立使用。

## 编译

```sh
CC=aarch64-linux-musl-gcc ./build.sh
```

也可使用自备容器中的 musl 工具链。输出为 `touchui-hook.so`。

所有 `.inc` 都属于同一个 C translation unit，最终仍只有一个注入库和一个原厂 UI 进程。

## 安装

```sh
./install.sh
```

如果目录中没有 `touchui-hook.so`，安装器会先调用 `build.sh`。安装过程会：

1. 核对原厂 UI 哈希；
2. 部署注入库、监督脚本和 init 服务；
3. 写入可重复安装、可完整删除的 `rc.local` 兜底块；
4. 验证只有一个 UI 进程、注入库已映射且监督进程存活；
5. 注入失败时恢复原厂 procd 服务。

## 验证

设备端状态：

```sh
/etc/init.d/touchscreen-control-center status
```

一次性全页面自检：

```sh
adb shell 'touch /tmp/touchui-selftest'
```

自检通常约 20 秒；锁屏或 LCD 关闭时原厂会降低 LVGL timer 频率，最长可能接近 60 秒。完成标记写入 `/tmp/touchui-create.log`。

仓库根目录的 `make touchui-check` 会执行 JSON 字段顺序、数组顺序及嵌套同名字段回归测试，并编译 `build/state-compat-test`。该工具复用触屏采样代码，可用本地私有 `/state` JSON 文件作为参数验证解析。用 AArch64 musl 工具链编译 `tests/state-compat.c`（链接 `-ldl -pthread`）并放到设备后，传入 `--live` 可直接检查本机后端；输出仅包含解析数量和检查结果，不输出设备身份。设备快照不要提交到仓库。

已在 zwrt-datad v0.10.18 上验证状态解析及两个页面的实际显示。检查数据兼容性时，应同时验证触屏解析与页面，不能仅以 `/healthz`、`/state` 返回成功作为依据。

## 截图

设备不提供 Android `screencap` 或传统 framebuffer。宿主机脚本会通过 root ADB
只读抓取 QPIC DRM 当前帧，并将 `320×480` RGB565 数据转换为 PNG：

```sh
./capture-screen.sh
./capture-screen.sh /path/to/screen.png
```

需要宿主机安装 `adb` 和 `ffmpeg`。脚本会核对单一 UI 进程、DRM 格式、双缓冲映射、
完整帧长度以及抓取前后的活动 framebuffer；不会写显存或改变屏幕状态。

[查看全部脱敏实机截图](../docs/SCREENSHOTS.md)。

## 卸载

```sh
./uninstall.sh --check
./uninstall.sh
```

卸载会移除本组件的服务、启动块和数据目录，并恢复原厂 UI；不会停止 Mihomo、修改网络配置或删除 `zwrt-datad`。

## 实现说明

- UI 对象只在原厂 UI 线程创建、更新和延迟删除；
- 网络、Mihomo 和设备状态页面互斥加载，避免耗尽原厂 LVGL 对象池；
- `/state` 使用一个 64 KiB 缓冲区，工作线程显式使用 256 KiB 栈；
- 切页和锁屏会清理对象指针、页面状态和刷新 generation，避免访问已释放对象；
- 三基带槽位编号只在展示层转换，不改写 `zwrt-datad` 原始值。

### 地址诊断兼容性

地址从 `interfaces.ipv4.ipv4[]` 和 `interfaces.ipv6.ipv6[]` 的首个非空条目读取，
掩码与地址来自同一条目；DNS 仍从接口的 `dns[]` 读取。仅在地址数组字段不存在时
兼容旧的扁平 `address`/`mask`。空数组不会回退到其他地址族或旧地址。

`make touchui-check` 的状态兼容性测试覆盖实际采样函数到诊断文案的 6 个用例：
数组结构与字段重排、旧结构、空数组、多个地址、DNS 缺失、接口断开。
`state-compat-test --live` 在设备上输出每路地址/DNS 是否读到及实际诊断文案，不输出地址或设备标识。
