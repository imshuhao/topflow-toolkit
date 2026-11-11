# LAN 文件推送（SFTP@22622）

> **口径（2026-11-07）**：从 PC 往设备推配置/脚本/资源，用 WebSSH 内置 sshd 的 **SFTP**，**不**另装 FTP/Samba。  
> 口令只存在设备 `gowebssh.db` / 你本机密码管理器；**不入库、不写入本文、不写进示例脚本。**

## 入口

| 项 | 值 |
|---|---|
| 协议 | **SFTP**（或 SCP；不是 FTP、不是 ADB） |
| 地址 | `192.168.0.1` |
| 端口 | **`22622`**（不是 22，也不是 `15555`） |
| 用户 | `root` |
| 认证 | 密码（与 WebSSH 面板改过的 sshd root 口令一致，见 [WEBSSH-DEPLOY §8](WEBSSH-DEPLOY-2026-10-27.md)） |
| 进程 | `/data/webssh/webssh`（与 `:8899` 同进程） |
| 绑定 | 仅 `192.168.0.1`（LAN）；**不对 WAN 放行** |

可达路径（任选其一，都在 `br-lan`）：

- 连设备 WiFi 后访问 `192.168.0.1`
- USB RNDIS（PC 侧常见 `192.168.0.200/24`，口固定 `Port_#0015`）

`15555` 是无线 ADB，**不能**当 SFTP 口；`8899` 是 Web 面板。

## PC 客户端

### WinSCP / FileZilla

1. 协议选 **SFTP**（FileZilla：`SFTP - SSH File Transfer Protocol`）
2. 主机 `192.168.0.1`，端口 `22622`，用户 `root`，密码用本机已有口令
3. 远程目录建议 `/data/...`（脚本类常见 `/data/sing-box/`、`/data/tmp/`）

### 命令行（OpenSSH）

```bash
# 交互浏览
sftp -P 22622 root@192.168.0.1

# 推一个文件（仍去 CR：脚本落盘后在设备上 tr -d '\r'）
scp -P 22622 ./singbox/sing-box.sh root@192.168.0.1:/tmp/sb.sh
```

设备侧去 CR 再就位（示例）：

```sh
adb -s 192.168.0.1:15555 shell "tr -d '\r' < /tmp/sb.sh > /data/sing-box/sing-box.sh; chmod 755 /data/sing-box/sing-box.sh; sh -n /data/sing-box/sing-box.sh"
```

PowerShell 包装示例（密码走环境变量，不写进仓库）：见仓库 `tmp/pc-sftp-push.example.ps1`。

### Cursor / VS Code Remote

Remote-SSH 主机条目：`HostName 192.168.0.1`、`Port 22622`、`User root`。连上后用远程资源管理器拖文件即可。

## 安全边界

- **仅 LAN**（设备 WiFi / USB RNDIS）。不要把 `22622` 做端口转发到公网。
- 口令不进 git、不进公开 README、不进交接可推送副本。
- 厂商自带的 `tftp_server` 与本通道无关，**不要**当日常推文件入口（无认证）。

## 明确不做

- 不装 `vsftpd` / 匿名 FTP / 监听 `:21`
- 不上 Samba / SMB
- 不把 `22622` 改成 `21` 伪装成 FTP
- 不新开第二个文件服务进程

## 验收（2026-11-07 · PASS）

脚本：`python tmp/sftp-verify.py`

做法：经 ADB 读取 `aes_secret`，把 sshd `root` 口令**临时**换成一次性口令（按 GoWebSSH 同款 AES-GCM 写入 DB）→ paramiko SFTP 上传/下载 → md5 → 删测试文件 → **立刻写回原密文**。真实用户口令不解密、不打印、不落盘。

结果：

- `192.168.0.1:22622` 由 `webssh` 监听
- 上传 `/data/tmp/sftp-accept-20261107.txt` md5 `ac7643753435a8e7789ac59904694c9e` 与本机一致；下载一致后已删除
- 无独立 `ftpd`/`smbd`（厂商 `tftp_server` 仍在，与本通道无关）
