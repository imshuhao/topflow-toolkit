# ZTE TopFlow 5G 客户端「每 ~45s 被踢」只读排查（2026-10-30 01:33–01:45 北京 = 设备 UTC 17:33–17:45）

## 0. 结论
1. **本次开机零重连**：PC(STA dc:56:7b:2e:a3:5b) 的 connected time = uptime − 157s，44 分钟内无重置；「45s 踢人」现象**未复现**。
2. **倾向 STA 自发（PC 侧 MT7925/Windows 发起断开后立刻重连）**，不是 AP 主动踢。理由：设备侧唯一可查的掉线帧方向是 `Disassoc RX`（AP *收到* PC 发来的 Disassoc，reason 3=STATION_LEAVING）；本次开机 dmesg `deauth=0 disassoc=0 btm=0`，hostapd 无 low_ack/空闲踢人配置，tx failed=0。
3. 时间基准：设备 `date`=UTC（17:34 UTC=01:34 北京）；dmesg 内嵌时标（01:02:54）与 `wlan_services.log` 部分行是 +8 本地时，与同文件 UTC 行混排，对齐一律按 UTC 换算。

## 1. 与 DHCP 无关（任务1）
- 租期：`dhcp.lan.leasetime='86400'`，`/etc/config/dhcp:10: option leasetime '86400'`；dnsmasq 实际用 `-C /var/etc/dnsmasq.conf.lan_dns`，租约文件 `dhcp.lan_dns.leasefile='/tmp/dhcp.leases'`。
- `/tmp/dhcp.leases`（149B、2 条、mtime 17:06）：
  `86400 88:9e:96:be:7e:7a 192.168.0.200 WIN-A4KL9830HQG 01:88:9e:96:be:7e:7a`
  `86400 dc:56:7b:2e:a3:5b 192.168.0.67 WIN-A4KL9830HQG 01:dc:56:7b:2e:a3:5b`
  首字段恰等于配置租期 86400（→24h），续租在 12h 量级，与 45s 差 3 个数量级；开机至今只有这 2 条租约、无 churn。
- IPv6/RA：`ip -6 route show dev wlan2` 仅 `fe80::/64`；`ip -6 addr show wlan2` 仅 link-local；全局 v6 在 br-lan（`2408:842c:9298:f738::/64` 永久 + `2408:842c:9200:d40::/64`、`240e:419:9212:f5fd::/64` 均为 deprecated、valid_lft 4901/4889s、preferred 0），默认 v6 走 `rmnet_data0`。
  odhcpd(pid 14290) 在跑：`ra='server' ra_slaac='1' ra_preference='high' ndp='relay'`，配置里无 ra_interval/ra_lifetime → 无 45s 级 RA 定时；RA 只影响 v6 地址/路由，不参与 L2 关联。

## 2. STA 重连证据（任务2）——本次开机无重连
- 17:34:11 首采样：`connected time: 1876 seconds` vs `uptime 2033s`，差 157s 正好是「开机→关联」，即只有**一次**关联。
- 7 次采样（17:36:15→17:38:04，每 18s）：connected 2000→2018→2036→2054→2072→2090→2108（线性 +18s，无重置）；inactive 4–12ms；signal −31…−35 dBm；tx failed 0；authorized yes。
- 150s 空闲窗口（17:39:07→17:41:37，期间不再发命令）：2172→2322（+150s）。
- 17:45:17 末次：uptime 2698 / connected 2542（差 156s）。hostapd `all_sta`：`flags=[AUTH][ASSOC][AUTHORIZED][MFP][HT][VHT][HE][EHT]`、`AKMSuiteSelector=00-0f-ac-8`、`hostapdMFPR=1`、`sae_group=19`、`inactive_msec=0`。
- 2.4G `iw dev wlan0 station dump` 为空（无 2.4G 客户端）→ 被踢对象只能是走 5G 的 PC。

## 3. 日志/dmesg 原文（任务3）
- hostapd 日志：`/data/vendor/wifi/hostapd-wlan0.log`、`hostapd-wlan2.log` **仍为 0 字节**（mtime Jan 1 2025），记录后未再读。
- syslog：`syslogd -O /logfs/syslog -l 6 -s 8192`；`/logfs/syslog`(1.6MB) 覆盖 17:21:49–17:39:46 UTC，`deauth=0 disassoc=0 AP-STA=0`；轮转件 `syslog.0`(8.4MB) 同窗口同样 0 命中。hostapd 在 syslog 仅 2 条 SELinux 审计：`avc: denied { write } for pid=11367 comm="hostapd" name="wpa_ctrl_16743-1" ... permissive=1`，与掉线无关。
- `logread` 输出为空（syslogd 写文件不写环形缓冲）。
- `wlan_services.log`（1215 行/101351B，纯 error 级）：关键字计数**全 0** —— deauth=0 disassoc=0 reason=0 kick=0 idle=0 inactiv=0 timeout=0 sae=0 pmk=0 rekey=0 gtk=0 beacon=0 disassoc_low_ack=0。内容只有：`conn_mgr_client_cb_ind: Not implemented!`、`NL group_id 12, cnss_nl.family_id 39`、`Failed to find ind_table for type 10a|103|104`、`wlan_service_update_tcp_rx_params: Unsupported throughput value 0`。
- 本次开机 dmesg（0→2698s，未 wrap）：`disassoc=0 deauth=0 low_ack=0 btm=0 wnm=0 steer=0 roam=0`。关联阶段原文：
  `[  156.482352] wlan: [10075:I:PE] Auth RX: vdev 1 sys role 1 lim_state 4 from dc:56:7b:2e:a3:5b rssi -32 auth_alg 3 seq 24`
  `[  156.482412] wlan: [10075:I:PE] vdev:1 SAE Auth RX type 0 subtype 11 trans_seq_num:1 from dc:56:7b:2e:a3:5b`
  `[  156.538581] wlan: [10075:E:PE] lim_process_assoc_req_frame: Drop duplicate assoc_req before 4-way HS`
  `[  156.544159] wlan: [10075:I:HDD] hdd_hostapd_sap_event_cb: Vdev 1, STA dc:56:7b:2e:a3:5b associated`
  另有每 ~20s 的 `__wlan_hdd_cfg80211_dump_station: peer idx 0|1 NOT FOUND`（上位轮询副作用）与 wpa_cli 每 ~2.7s 写 `/tmp/stainfo`（18 分钟 391 条审计），都是状态轮询，非踢人动作。
- 历史掉线只在上一/更早启动（本 dmesg 不含），仓库 `私人交接文档（未公开发布）:1829` 原文：
  `wlan: Disassoc RX: vdev 1 from dc:56:7b:2e:a3:5b (PC 的 MAC) for 88:9e:96:c6:7c:7a RSSI=-39 reason 3`
  `RX`=AP 收到该帧、`from dc:56…`=发送方是 PC、reason 3=STATION_LEAVING；若 AP 踢人 qcacld 应打 `Disassoc TX ... to <STA>`。文档标题「设备主动踢」与帧方向相反。
- 设备侧旁证：`wlan_services.log` 在 16:29:49 / 16:36:44 / 16:37:38 / 16:40:26 / 16:41:18 / 16:43:46 / 16:51:35 / 16:53:05 / 16:56:23 / 00:59:36 逐条 `Unsupported throughput value 0`，与 Windows 断开/安全停止时刻逐秒对齐 → 设备确实感知到每次重连，但记录的是「吞吐=0」副作用，不含踢人原因码。

## 4. 可疑踢人开关（任务4）
- 原文命令 `grep -rE 'disassoc_low_ack|ap_max_inactivity|skip_inactivity|assoc expire|stay_on|idle' /data/vendor/wifi/ /etc/hostapd* 2>/dev/null` → **0 行输出**。
- `hostapd-wlan2.conf` 实际存在的相关行（wlan0 同）：`send_probe_response=0`、`bss_transition=1`、`ieee80211w=1`、`sae_require_mfp=1`、`sae_pwe=2`、`dtim_period=1`、`wowlan_triggers=magic_pkt`、`macaddr_acl=0`、`deny_mac_file=/data/vendor/wifi/hostapd-wlan2.maclist`（该文件 0 字节）。`send_probe_response=0`（AP 不应答 Probe Request）与 `bss_transition=1` 属非默认可疑项，但本次开机 BTM/STEER 帧计数 0，**无证据**与掉线有关。
- `uci show wireless`：`main_2g/main_5g` 均 `ieee80211w='1' bss_transition='1' sae='1' pmf='0'`，无 inactivity/low_ack 项；`wifi0/wifi1 maxassoc='32'`。
- `iw dev wlan2 info`：`type AP, channel 36 (5180 MHz), width: 80 MHz, txpower 18.00 dBm`；`iw dev wlan2 get power_save` → `Power save: on`（wlan0 同 on）。AP 口开省电反常，但 44 分钟稳定，**无证据**是踢因。
- hostapd 运行态：`status` → `state=ENABLED ... num_sta[0]=1`；`get_config` 只回 `key_mgmt=WPA-PSK SAE`（无 ap_max_inactivity 等）。

## 5. TCP 会话（任务5）
- 设备无 `ss`（`sh: ss: not found`），改用 `netstat -tn`：`:22622`/`:15555` ESTABLISHED 共 **7 条**，采样前后无消失：
  `192.168.0.1:22622 ⇐ 192.168.0.67:52954/52955/52956/52957/52958/52959`（6 条=本次并发 SSH，全存活）
  `192.168.0.1:15555 ⇐ 192.168.0.200:50839`（adb over USB RNDIS，存活）
- PC→192.168.0.1 走 `192.168.0.67 WLAN`（metric 256），所有命令都跑在同一条 WiFi 链路且全部成功。

## 6. 倾向判断与证据边界
- **倾向：STA 自发（PC 侧）**。一句话理由：设备侧唯一可查的掉线帧是 `Disassoc RX ... from PC reason 3`（AP 收到 STA 的「离开」帧），而 AP 本次开机 `deauth/disassoc/BTM TX=0`、无 low_ack/空闲踢人开关、tx failed=0、signal −32dBm；同期 Windows 事件日志把每次断开标注为「网络被驱动程序断开连接 / 用户想要建立新连接」。
- Windows 时间线（本机即该 STA：MT7925 驱动 5.7.0.4669，802.11be/WPA3-Personal H2E，MAC DC:56:7B:2E:A3:5B）：24h 内 `8003` 断开 15 次，全在 23:57–01:00；每次前 0–16s 有 `11004 无线安全功能已停止`；断开间隔 +49/+52/+55/+62/+87/+90/+110/+131/+148/+168/+182s（≈50–180s，非严格 45s）；**01:00:26 之后 0 次**。设备 17:01 UTC 重启、01:02:54 重新 SAE 关联后至今未再断。
- 无证据项：AP 主动踢（无 Deauth/Disassoc TX、无踢人配置）；DHCP/RA 参与（租期 86400s、仅 2 条租约、RA 不碰 L2）；hostapd 0 字节日志（无内容可查）；`send_probe_response=0`、AP 口 power_save=on（仅可疑，未证实）。
- 只读声明：全程仅执行 date/cat/ls/stat/uci show/grep/dmesg/logread/iw/hostapd_cli(status,all_sta,get_config)/netstat + /proc 读取；未写设备任何文件、未 setprop/重启/重挂载/改配置、未 install/remove、未用 adb。
