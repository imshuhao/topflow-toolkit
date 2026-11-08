# Touchscreen control center

该组件通过 `LD_PRELOAD` 扩展原厂 `zte_topsw_devui` 的 LVGL 界面，不替换原厂程序。

**相对上游原作的本分支变化：**

- 控制中心里原「Mihomo」入口改为 **Sing-box**（启停 / 数据面 / 流量）；
- 九宫格：网络 / 代理 / 分流 / 余量 / 设备 / 充电 / 主题 + 空位（见根 README §3）；
- 分流触屏含「自动·质量」「三卡共池」与「自定义」草稿视图——**本公开支线后端暂未放行 `custom`**；
- `start.sh` 注入 **`TZ=CST-8`**（只影响触屏显示；墙钟须真实 UTC，见根 README）。

```text
控制中心（3×3）
├── 网络 / 代理 / 分流
├── 余量 / 设备 / 充电
└── 主题 / 空位 / 空位
```

网络·设备·充电·散热·Wi-Fi 读 `zwrt-datad /state`；代理读 `singbox-manager.sh`；
分流读 `wan-mode-status`；余量读 `/data/local/balance/status.json`。
写操作：`POST /control`（风扇/液冷/Wi-Fi）或固定 `singbox-manager` / `balance-watch` 子命令。
Sing-box 页展示数据面（eBPF 下无 `sbtun0` 为正常）。细节以根 README 为准。

## 兼容性

当前只支持 root README 所列 B20 固件。原厂 UI 是固定地址、非 PIE 程序；导航按钮引用该进程中已加载的对象，安装器因此会严格核对：

```text
zte_topsw_devui SHA-256:
a5d40b1c65acd5fb74f207d4d0a37b879a36073dcff9b1a33fb2a3b08d7a66a5
```

哈希不匹配时不要修改安装器跳过保护。新固件需要重新审计 LVGL ABI、对象地址、生命周期和恢复路径。

仓库不含任何 ZTE 二进制、共享库、字体或可复用原厂图像资源。上传/下载箭头由本项目运行时生成；信号图标只引用设备已有 `/usr/ui/skin` 路径。文档中的脱敏实机截图只用于功能展示。

## 依赖

- root ADB；
- AArch64 musl 交叉编译器；
- 设备端 `zwrt-datad`；
- Sing-box 页面功能需要 `singbox-manager`（脚本 `/data/singbox-manager/singbox-manager.sh`）；
- 「分流」页还需要设备上的 `singbox-wan-balance.sh`（见仓库 `singbox/`）并响应
  `wan-mode-status` / `wan-mode-set`；其他页面可独立使用。

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

卸载会移除本组件的服务、启动块和数据目录，并恢复原厂 UI；不会停止 sing-box、修改网络配置或删除 `zwrt-datad`。

## 实现说明

- UI 对象只在原厂 UI 线程创建、更新和延迟删除；
- 网络、Sing-box 和设备状态页面互斥加载，避免耗尽原厂 LVGL 对象池；
- `/state` 使用一个 64 KiB 缓冲区，工作线程显式使用 256 KiB 栈；
- 切页和锁屏会清理对象指针、页面状态和刷新 generation，避免访问已释放对象；
- 三基带槽位编号只在展示层转换，不改写 `zwrt-datad` 原始值。
