# 网络架构

ZTE TopFlow 不是“一张卡加两个备用口”的普通路由器。X75 主系统承载 WebUI、路由、
策略和触屏进程，同时管理三路独立蜂窝基带：X75、V3E2、V3E1。实体 Switch 决定原厂
普通多 WAN 与厂商 ICG 聚合两条互斥的数据面。

```text
LAN / Wi-Fi client
        |
        +-- 设备默认网关 192.168.11.1 -----------------------+
        |                                                     |
        +-- 可选 Mihomo 网关 192.168.11.11                    |
             -> network namespace -> TUN -> 192.168.11.1      |
                                                              v
                                    MULTIWAN: mwan3 按连接选路
                                    SMULTIWAN: ICG 透明代理/隧道
                                                              |
                                      X75 + V3E2 + V3E1 三路蜂窝
```

## 普通 `MULTIWAN`

普通模式由 Linux `mwan3` 对新连接做策略选路。已验证配置的三路权重是 `12:1:1`，约为
85.7% / 7.1% / 7.1%；这是跨连接分布，不会把单个 TCP 连接的报文拆到三张卡。

`mwan3-tuning` 为 Mihomo 的 IPv4 TCP/443 配置非 sticky 分流，为普通 LAN 的
IPv4 TCP/443 保留 600 秒 sticky，并让这两条规则先于 IPv4 默认规则匹配。
B20/B22 的出厂配置本来就是 HTTPS 在默认规则前；这里安装的是定制分流规则，
不能将历史设备配置中曾出现的错序概括成原厂固件必然存在的问题。

组件还增加可用的丢包/延迟采样，并把“WAN 上下线事件清空整个 conntrack”改成
“仅在线路失败时删除该 fwmark 的 IPv4 连接”。B22 仍保留这两项原厂行为，因此仍需
这些调整；参见 [B22 核对结论](../mwan3-tuning/README.md#b22-核对结论)。
这些 mwan3 规则用于普通模式，不替代 ICG 的聚合调度。

## 聚合 `SMULTIWAN`

聚合模式停止 `mwan3`，启动厂商 ICG 客户端。它创建 `tun0`、透明代理/策略规则和绑定
到三路物理链路的外层隧道；同一个 TCP 业务流的封装数据可以同时出现在三张卡上，由
远端 ICG 服务器重排、重组并统一出网。

`tun0` 是覆盖网络接口，不是第四张物理网卡。部分 TCP 数据由用户态透明代理和 socket
处理，因此仅凭 `tun0` 计数不能判断聚合是否工作。更完整的技术边界见
[AGGREGATION.md](AGGREGATION.md)。

## Mihomo 的位置

`mihomo-netns` 不替换宿主路由。它在独立 namespace 中使用 `.11` 作为 LAN 侧虚拟
网关，DHCP Option 3 和 6 可选择性把 IPv4 客户端导向它。Mihomo 创建的真实外连再回到
宿主，由当前的 `MULTIWAN` 或 `SMULTIWAN` 继续处理。

聚合模式的厂商透明规则可能在二层提前捕获发往 `.11` 的客户端帧。组件使用一条精确
的 bridge bypass 标记，让“客户端到 Mihomo”先进入 namespace；Mihomo 的外连仍可由
ICG 聚合。服务停止时对应规则会删除。

当前方案只接管 IPv4。LAN IPv6 若开启，客户端可能绕过 Mihomo；工具包没有声称对
IPv6 做透明代理。

## 状态与控制面

触屏控制中心不让每个页面各自高频调用 `ubus` 或扫描日志，而是通过
[`zwrt-datad`](https://github.com/33333s/zwrt-datad) 的 `/state`、`/events` 和受约束
`/control` 接口读取统一状态。Mihomo Manager 则通过厂商 WebUI 的登录边界和 RPC ACL
控制本机脚本。

必须区分四类结论：配置中存在、服务已启动、路径当前在线、真实业务已命中。界面展示
应尽量基于后两类实时状态，而不是仅凭保存配置推断。
