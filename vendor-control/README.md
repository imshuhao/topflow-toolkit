# B22：停用原厂 MQTT 与三路二次认证

`disable-mqtt-auth.sh` 是在设备 root shell 内运行的一次性配置工具，默认只检查状态。
它停用并停止 `zte_mqtt_sdk_st`，将以下三个开关保存为 `0`，通过原厂
`zwrt_redirect.msg / second_auth_close` 通知刷新，让原厂服务撤销认证拦截：

- `zwrt_zte_mdm.sim_info.seecom_card_flag`
- `zwrt_zte_mdm.sim_info.sub_1_seecom_card_flag`
- `zwrt_zte_mdm.sim_info.sub_2_seecom_card_flag`

## 使用

已取得 root 的 MU5252 B22，通过唯一一台 USB ADB 设备执行：

```sh
adb -d push vendor-control/disable-mqtt-auth.sh /data/local/disable-mqtt-auth.sh
adb -d shell 'chmod 700 /data/local/disable-mqtt-auth.sh'
adb -d shell '/data/local/disable-mqtt-auth.sh apply'
adb -d shell '/data/local/disable-mqtt-auth.sh check'
```

`status` 和 `check` 都是只读检查，不达标返回非零。`apply` 可重复执行；没有配置变化时
不重复提交 UCI。脚本不会自动重启。初次执行前的三个开关及 MQTT 自启/运行状态仅保存在
设备 `/data/local/vendor-control/before.txt`（目录 0700、文件 0600），重复执行不覆盖。

检查包括：MQTT 自启关闭、进程消失、三个开关为 0、IPv4/IPv6 二次认证链无规则、
未认证客户端计数为 0、原厂启动同步及注册完成。空认证链和其他链对它的跳转可以保留。
输出不包含客户端 MAC、SIM 或设备身份。

## 边界与恢复

- 仅接受 `BD_ENCNMU5252V1.0.0B22` 和已审计的 redirect 二进制完整哈希。
- 检测到 `zwrt_zte_mdm` 存在未提交修改时先停止，避免顺便提交其他修改。
- 若 MQTT 出现在必需启动同步列表中，先停止并要求重新审计，避免卡住开机。
- 不修改认证级别、白名单、认证成功记录或 `all_second_auth_state`；后者由原厂重算。
- 不停用 ICG 聚合服务，不修改 TR069、自动 OTA、蜂窝连接、Wi-Fi 或整个防火墙。
  因此不能将本工具描述为“关闭全部遥测/远程接口”。
- 通过移除 MQTT 自启链接和 UCI 持久化跨普通重启生效；不安装定时器或后台守护。
  后续 OTA 可能恢复厂商服务和配置，升级后应重新核对，不能保证跨版本保持禁用。
- 恢复时先查看 `before.txt`，逐项恢复三个原值并提交 `zwrt_zte_mdm`，根据记录恢复
  MQTT 的 enable/start 状态，再重启使原厂重新计算认证和规则。不要直接 `source` 状态文件。
- 执行中出错会返回非零，已经成功的步骤不会自动反向撤销；查明原因后重试。
  若中断留下 `apply.lock`，确认没有脚本运行后才删除该空目录。

## 本次验证（2026-09-25）

升级后实测开关为 `0/1/0`、MQTT 自启且连接厂商端点，认证链存在阻断规则。
执行后为 `0/0/0`，MQTT 进程与自启关闭，IPv4/IPv6 认证链规则数及未认证客户端数均为 0。
本次清理通过原厂消息完成，没有直接 flush 防火墙或重启数据服务。
重复执行验证通过，原值备份保持不变；三个出口逐一访问 HTTPS 均成功（一路首次超时，重试两个站点均成功）。
`make check` 和脚本 shellcheck/语法检查通过。
真实重启后再次通过 `check`：MQTT 未自启、三个开关仍为 0、认证链和未认证计数为 0；
原厂同步/注册正常，datad 健康检查通过，ICG、Mihomo 和触屏进程均运行。

B22 静态定位：`zte_topsw_redirect` SHA-256 为
`d88f431f34177c52fc65af9ca870ea20fef54bb2e8997bb7cc5acfa9f0d9f584`。
消息分支 `0x1f108` 调用 `0x1d040`，经 `0x17958` / `0x11a0c` 重新读取三路开关；
关闭时由原厂调用自己的 `del_second_redirect` 等清理路径。原厂消息的 SIM 索引为 1、2、3。
这些地址只用于说明分析依据，脚本没有二进制补丁或内存写入。
