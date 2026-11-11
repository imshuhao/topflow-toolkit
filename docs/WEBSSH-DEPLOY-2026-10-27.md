# WebSSH 部署记录（2026-10-27）

> **出处**：原作 [`o8oo8o/WebSSH`](https://github.com/o8oo8o/WebSSH)（MIT）→ 面板 MOD [`kanoqwq/WebSSH-u60pro`](https://github.com/kanoqwq/WebSSH-u60pro)；本仓库部署包装见 [`webssh/`](../webssh/)。TopFlow 工具包原作者 [`imshuhao/topflow-toolkit`](https://github.com/imshuhao/topflow-toolkit)。

> 设备：ZTE TopFlow MU5252 B20 · OpenWrt 23.05.4 `sdx75/generic` · aarch64/musl · root（ADB 15555）
> 来源：`kanoqwq/WebSSH-u60pro`（GoWebSSH-MOD，Go 1.23，`CGO_ENABLED=0` 静态）
> 性质：已实机部署并验证；未 reboot（避免打断现网 sing-box），rc.local 在 overlay 持久，下次重启自动生效
> 口令：2026-10-27 Web 管理员与内置 sshd root 两处密码已按用户要求改为同一弱口令（用户知情，仅 LAN 可达；公开文档不写明文）；改法与验证见 §8

> **2026-10-30 补（USB 下也能用，不需要 WiFi）**：`8899`（Web UI）与 `22622`（内置 sshd）都绑
> `192.168.0.1`；设备 `rndis0` 已桥接进 `br-lan`，所以插 **USB2 口**时 PC 从 RNDIS 拿到
> `192.168.0.200/24` 后，浏览器 `http://192.168.0.1:8899/app` 与
> `ssh -p 22622 root@192.168.0.1` 都可直接用——**走的是 USB RNDIS 网卡，不是 ADB 通道**。
> USB3 口 RNDIS `code 10`，USB 侧不可用。四种通道的完整矩阵见
> HANDOVER §28（私人交接未公开发布）。

---

## 1. 组件画像

| 项 | 值 |
|---|---|
| 二进制 | `gossh/webssh`，5,119,828 B，**UPX 5.0.2 压缩的 linux/arm64 静态 ELF**（解压 15,138,968 B），Go 1.23.2 编译 —— **2026-10-28 凌晨（设备时钟为 UTC，日志显示 10-27 16:00）已替换为未压缩整合版 16,253,090 B（含新前端 + ubus 兼容层），见 §10；旧包备份在 `/data/webssh/webssh.bak-20261027b`** |
| 依赖 | 无 libc 依赖（无 `PT_INTERP`）、无 Node/Python/nginx/ttyd；SQLite 为纯 Go 实现 |
| 前端 | 完整内嵌于二进制（现行 `assets/index-B5DoUXZY.js` / `index-CwhN0Bf-.css` + Manage / SysInit / NotFound / About，见 §10），**不需要在设备上构建** |
| 运行时数据 | `<ConfigDir>/.GoWebSSH/GoWebSSH.toml`（配置与密钥）+ `gowebssh.db`（SQLite，约 64 KB） |
| 内存/句柄 | 实测 VmRSS **20.2 MB**（VmHWM 20.5 MB）、10 fd、7 线程 |
| 需要 pty | 是；设备 `/dev/ptmx`(5,2) + `/dev/pts` 已就绪，登录 shell 为 `/bin/bash` 5.2.15 |

## 2. 落点 / 端口 / 路径

| 角色 | 值 |
|---|---|
| 安装目录 | `/data/webssh/`（`webssh` 755、`start.sh` 755、`rc.local.bak-20261027`、`.GoWebSSH/`） |
| Web | `http://192.168.0.1:8899/app/`（**仅绑 LAN IP**，非 0.0.0.0） |
| 内置 sshd | `192.168.0.1:22622`（root + 密码认证，pty 会话，SFTP 子系统） |
| 配置 | `/data/webssh/.GoWebSSH/GoWebSSH.toml`（600）；DB `/data/webssh/.GoWebSSH/gowebssh.db` |
| 日志 | `/tmp/webssh.log`（tmpfs；rc.local 块内 1 MiB 守卫清空） |
| 占用避让 | 未触碰 80/443/8880/9460/9461/9999/7890/15555；防火墙零改动 |

## 3. 部署步骤（可复现）

```sh
# 主机侧
md5sum .tmp-webssh-u60pro/gossh/webssh          # d4b8c0d95fe6ccb075d6c84fcb8c69ae
adb -s 192.168.0.1:15555 shell 'mkdir -p /data/webssh'
adb -s 192.168.0.1:15555 push .tmp-webssh-u60pro/gossh/webssh /data/webssh/webssh
adb -s 192.168.0.1:15555 shell 'chmod 755 /data/webssh/webssh; md5sum /data/webssh/webssh'

# 预置配置（address 固定 LAN IP；首次启动前写，避免默认 0.0.0.0）
#   address = '192.168.0.1'; port = '8899'; is_init = false; db_type = 'sqlite'
adb -s 192.168.0.1:15555 shell 'mkdir -p /data/webssh/.GoWebSSH'
adb -s 192.168.0.1:15555 push GoWebSSH.toml /data/webssh/.GoWebSSH/GoWebSSH.toml

# 启动器（busybox start-stop-daemon 无 -d，chdir + ConfigDir 都写在这里）
#   /data/webssh/start.sh
#     #!/bin/sh
#     cd /data/webssh || exit 1
#     exec /data/webssh/webssh -ConfigDir /data/webssh >>/tmp/webssh.log 2>&1
```

初始化（HTTP，无浏览器）：

```sh
curl -s -X POST http://192.168.0.1:8899/api/sys/init -H "Content-Type: application/json" --data-binary @init.json
# -> {"code":0,"msg":"系统初始化完成"}
```

`init.json` 字段（对应 `app/service/sys_init.go` 的 `InitConfig` + `app/service/db_conn.go` 的 `DbConnConf`）：

| 字段 | 值 |
|---|---|
| `db_type` | `sqlite` |
| `db_dsn` | `gowebssh.db` |
| `username` / `password` | `admin` / `<REDACTED>`（24 位随机） |
| `sshd_host` / `sshd_port` | `192.168.0.1` / `22622` |
| `sshd_user` / `sshd_pwd` | `root` / `<REDACTED>`（24 位随机，与 admin 不同） |
| `jwt_secret` / `session_secret` | 各 64 位随机串 |

初始化同时写入：管理员账号、`sshd_conf`（host/port/shell=bash/主机密钥）、默认连接 `127.0.0.1:22622`，并立即拉起内置 sshd。

## 4. 自启块（`/etc/rc.local`，`exit 0` 之前）

```sh
# >>> webssh >>>
if [ -x /data/webssh/webssh ]; then
    ulimit -n 4096 2>/dev/null
    if [ -f /tmp/webssh.log ] && [ "$(wc -c < /tmp/webssh.log)" -gt 1048576 ]; then : > /tmp/webssh.log; fi
    start-stop-daemon -S -b -x /data/webssh/start.sh -m -p /tmp/webssh.pid >/dev/null 2>&1
fi
# <<< webssh <<<
```

- 备份：`/data/webssh/rc.local.bak-20261027`（5049 B，`cp -p` 原文件）
- 安装方式：awk 在文件**最后一个** `exit 0` 之前插入，`sh -n` 校验后整文件覆盖（保留原权限）
- 开机路径已演练：`sed -n '/# >>> webssh >>>/,/# <<< webssh <<</p' /etc/rc.local > /tmp/blk.sh && sh /tmp/blk.sh` → 正常起进程、双端口监听
- 注意：**不要**改用 `/etc/init.d`（rcS 不执行 overlay 新增的 init.d 服务，见 私人交接 §21）

## 5. 实机验证（原始输出）

```text
$ md5sum /data/webssh/webssh        # 与 PC 侧 d4b8c0d95fe6ccb075d6c84fcb8c69ae 一致
d4b8c0d95fe6ccb075d6c84fcb8c69ae  /data/webssh/webssh

$ ls -l /data/webssh
-rwxr-xr-x 1 root root    5049 Oct 27 09:29 rc.local.bak-20261027
-rwxr-xr-x 1 root root     108 Oct 27 15:26 start.sh
-rwxr-xr-x 1 root root 5119828 Oct 27 15:02 webssh

$ head -20 /tmp/webssh.log          # 首次前台试跑
2026/10/27 15:24:00 INFO use-config-file path=/data/webssh/.GoWebSSH/GoWebSSH.toml
2026/10/27 15:24:00 WARN 系统未初始化,跳过DbMigrate
2026/10/27 15:24:00 INFO exec sshd init func
WebBaseDir:[]
2026/10/27 15:24:00 INFO http_server_start address=192.168.0.1:8899

$ netstat -ltnp | grep -E '8899|22622'
tcp 0 0 192.168.0.1:8899   0.0.0.0:* LISTEN 24516/webssh
tcp 0 0 192.168.0.1:22622  0.0.0.0:* LISTEN 24516/webssh

$ curl -s -o /dev/null -w '%{http_code}' http://192.168.0.1:8899/app        -> 301（gin 静态目录补斜杠，正常）
$ curl -s -o /dev/null -w '%{http_code}' http://192.168.0.1:8899/app/       -> 200
$ curl -s -o /dev/null -w '%{http_code}' http://192.168.0.1:8899/app/assets/index-BB7BlFfI.js -> 200
$ curl -s http://192.168.0.1:8899/api/sys/is_init
{"code":0,"data":{"is_init":true},"msg":"ok"}

$ # paramiko 密码登录 root@192.168.0.1:22622 + invoke_shell(term=xterm-256color, 120x40)
AUTH_OK SSH-2.0-OpenSSH
bash-5.2# id; echo PTY_OK; readlink /proc/self/fd/0; stty size
uid=0(root) gid=0(root) groups=1004(input),1007,1011,1015(sdcard),1028,3001,3002,3003(inet),3006
PTY_OK
/dev/pts/0        # 每次会话递增（复测时见过 /dev/pts/1）
40 120

$ grep -E 'VmRSS|VmHWM' /proc/$(pidof webssh)/status
VmHWM: 20564 kB
VmRSS: 20164 kB
$ ls /proc/$(pidof webssh)/fd | wc -l        -> 10
$ df -h /data   -> 1.8G 总 / 483.9M 用 / 1.3G 可用 (26%)
```

## 6. 已知降级（不影响 SSH/SFTP）

| 现象 | 原因 | 影响 |
|---|---|---|
| ~~仪表盘整页「请求失败」~~ **已修复（2026-10-28 凌晨，见 §10）** | 真因：B20 三卡固件的 `zwrt_data.get_wwandst` 要求 `cid`+`type`+`subid` 齐全、`get_wwaniface` 要求 `cid`+`subid`，缺 `subid` 才返回 `Invalid argument`（不是方法消失）。旧前端 `fetchAllData` 用 `Promise.all`，一个失败整页报错 | 现已全页正常；终端、连接管理、SFTP、账户功能不受影响 |
| 「一键 ADB」按钮必失败 | `zwrt_bsp.usb` 只有 `list`，无 `set`（B20 早已移除）；zwrt-datad 的 `/control usb.set` 同样报 `zwrt_bsp.usb.set failed`，无法旁路 | 无关紧要，无线 ADB 走 `/data/adb-wifi`（15555） |
| 无 HTTPS | 未放 `cert.pem`/`key.key` | 局域网明文；如需 TLS 把证书放进 `.GoWebSSH/` 后重启 |

## 7. 坑位与安全（本次实机踩到）

1. **`GetExecDir()` 实为 `os.Getwd()`**（`app/utils/utils.go:35-44`）。经 `start-stop-daemon` 启动时 cwd 可能是 `/`，工作目录退化为 `/.GoWebSSH`（只读根）→ `创建工作目录失败` → 静默回落默认配置并 **bind `:8899`（全接口）**。必须 `-ConfigDir /data/webssh`（`start.sh` 内已固定），并在启动后核对日志里的 `use-config-file path=` 与 `address=`。
2. **busybox `start-stop-daemon` 不支持 `-d`**（`unrecognized option: d`），`-b` 还会丢弃子进程 stdout/stderr → 直接用 `-x /data/webssh/webssh` 时 `/tmp/webssh.log` 为空。改用 `start.sh` 包装（`cd` + `exec ... >>log`）。
3. 用 `-x /bin/sh -- -c ...` 包装会撞上 busybox 的「/bin/sh is already running」判定，必须用独立脚本文件。
4. `/app` 返回 301 是 gin 静态目录行为，`/app/` 才是 200；健康检查请用 `/app/`。
5. UPX 二进制运行时自解压（~15 MB），启动比未压缩版略慢，属正常。
6. 设备 busybox **没有 `tty` applet**（`bash: tty: command not found`），pty 证据改用 `readlink /proc/self/fd/0`（→ `/dev/pts/N`）与 `stty size`（→ `40 120`）。
7. 首次误启动曾尝试创建 `/.GoWebSSH`（只读根，创建失败、未落盘）；已核实 `/.GoWebSSH` **不存在**，正主是 `/data/webssh/.GoWebSSH/`。
8. **配置与 DB 必须收紧到 600/700**：程序初始化时用 `os.WriteFile(..., 0777)` 落盘（`app/config/config.go` `write()`/`RewriteConfig`），实测初始为 `-rwxrwxrwx`。部署后执行：

   ```sh
   chmod 600 /data/webssh/.GoWebSSH/GoWebSSH.toml /data/webssh/.GoWebSSH/gowebssh.db
   chmod 700 /data/webssh/.GoWebSSH
   ls -ld /data/webssh/.GoWebSSH            # drwx------ 2 root root
   ls -l  /data/webssh/.GoWebSSH/           # -rw------- GoWebSSH.toml / gowebssh.db
   ```

9. **首次初始化用的 `init.json` 用完即删**：里面是 `password` / `sshd_pwd` / `jwt_secret` / `session_secret` 明文。PC 侧不要留存，推送/curl 完立即 `rm -f init.json`，并自查：

   ```sh
   grep -rl "<密码片段>" . --exclude-dir=.git     # 必须为空
   ```

## 8. 改密码（API 步骤，2026-10-27 实机执行）

**结果**：Web 管理员与内置 sshd root 已改为**同一个 6 位弱口令**（用户明确要求、知情，仅 LAN 可达；口令本身不入库、不入仓库）。进程未重启（PID 未变），改完双端口监听不变。

### 8.1 存储与鉴权（读源码确认，勿猜字段）

| 项 | 结论 |
|---|---|
| 存储 | 两张表：`web_user.pwd`、`sshd_user.pwd`；均为 `utils.EncryptString(pwd, config.AesSecret)` 的 AES 密文。模型 hook：`BeforeCreate`/`BeforeUpdate` 加密、`AfterFind` 解密 → **API 进出的都是明文** |
| 登录字段 | `POST /api/login` 收 `name` / `pwd`（**不是** `username` / `password`），成功返回 `token` |
| JWT 头 | `Authorization: <token>`，原样放 token，**无 `Bearer ` 前缀**（`middleware/jwt_auth.go`） |
| 中间件 | 认证组统一 `SysInit()` + `JWTAuth()` + `PremCheck(engine)`；`GET/PUT /api/sshd_user` 在 `checkRoute` 白名单 → 要求当前用户 `is_admin = Y`（admin 满足）。`PATCH /api/user/pwd` 不在白名单，仅需 JWT |
| 改 Web 密码 | `PATCH /api/user/pwd` → `service.ModifyPasswd`，body 仅 `{"pwd": ...}`（`min=1,max=64`）；**不校验旧密码**；内部先 `FindByID(uid)` 再整条回写（`UpdatePassword` 用 `Select("*").Omit("id")`），故不会把别的字段抹空 |
| 改 sshd 账号 | `PUT /api/sshd_user` → `service.SshdUserUpdateById`；body 必须**回传整条记录**：`id`、`name`、`pwd`、`desc_info`、`is_enable`、`expiry_at` 都是 `binding:"required"`，且 `UpdateById` 用 `Select("*")` 全字段更新 → 先 GET 现状再只替换 `pwd` |
| 只动账号表 | `sshd_user`（登录账号）与 `sshd_conf`（监听 host/port/shell/主机密钥）是两张表；本次只改 `sshd_user`，**22622 监听配置未触碰** |
| 是否需重启 | **不需要**。`sshd_server.go` 的 `computeSSHConfig` 只在 `NewServer` 时构建一次（shell 路径、主机密钥、回调注册）；`PasswordCallback` 每次连接都调 `model.SshdUser.FindByNameAndPwd(...)` 实时查库 → 改库即生效 |

### 8.2 curl 模板

```sh
BASE=http://192.168.0.1:8899

# 1) 用当前密码换 JWT（字段是 name/pwd）
TOKEN=$(curl -s -X POST "$BASE/api/login" -H 'Content-Type: application/json' \
  -d '{"name":"admin","pwd":"<OLD_PWD>"}' | jq -r .token)

# 2) 改 Web 管理员密码（不需要旧密码，不要求整条记录）
curl -s -X PATCH "$BASE/api/user/pwd" -H "Authorization: $TOKEN" \
  -H 'Content-Type: application/json' -d '{"pwd":"<NEW_PWD>"}'

# 3) 改内置 sshd root 密码：先取整条记录，只替换 pwd 再整条 PUT
curl -s "$BASE/api/sshd_user" -H "Authorization: $TOKEN" | jq '.data[0]'
curl -s -X PUT "$BASE/api/sshd_user" -H "Authorization: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"id":1,"name":"root","pwd":"<NEW_PWD>","desc_info":"<DESC>","is_enable":"Y","work_dir":"","expiry_at":"2099-12-31 00:00:00"}'
# 成功回 {"code":0,"data":[{"id":1,...,"pwd":"<NEW_PWD>"}],"msg":"ok"}
```

改动前把 DB 拷一份到 tmpfs 便于回退：`cp -p /data/webssh/.GoWebSSH/gowebssh.db /tmp/gowebssh.db.bak-pwd`（回退：`kill $(cat /tmp/webssh.pid)` → 覆盖 DB → 用 §4 的 `start-stop-daemon` 命令拉起）。

### 8.3 验证（新密码必须通，旧密码必须被拒）

```sh
# Web：新密码 200 + token；旧密码必须 401 {"code":2,"msg":"账号密码错误"}
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$BASE/api/login" \
  -H 'Content-Type: application/json' -d '{"name":"admin","pwd":"<NEW_PWD>"}'      # -> 200
curl -s -X POST "$BASE/api/login" -H 'Content-Type: application/json' \
  -d '{"name":"admin","pwd":"<OLD_PWD>"}'                                          # -> 401 code 2
```

```python
# sshd：新密码 AUTH_OK + invoke_shell 里 id 为 root；旧密码必须 AuthenticationException
import paramiko
def probe(pwd):
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        c.connect("192.168.0.1", port=22622, username="root", password=pwd,
                  look_for_keys=False, allow_agent=False, timeout=8)
        return c
    except paramiko.AuthenticationException:
        return None
c = probe("<NEW_PWD>"); assert c, "new pwd rejected"
sh = c.invoke_shell(term="xterm-256color", width=120, height=40); sh.send("id\n")  # uid=0(root)
c.close()
assert probe("<OLD_PWD>") is None, "old pwd still accepted"
```

### 8.4 实机记录（2026-10-27）

| 检查 | 结果 |
|---|---|
| 登录（新） | `HTTP=200`，`{"code":0,...,"token":"…"}` |
| 登录（旧） | `HTTP=401`，`{"code":2,"msg":"账号密码错误"}` |
| paramiko 新密码 | `AUTH_OK`，`SSH-2.0-OpenSSH`，pty `/dev/pts/2`，`stty size` = `40 120`，`id` → `uid=0(root)` |
| paramiko 旧密码 | `REJECTED AuthenticationException`（无需重启即失效，印证 §8.1 末行） |
| 进程 / 端口 | `pidof webssh` = `24516`（未重启）；`192.168.0.1:8899` 与 `192.168.0.1:22622` 双 LISTEN |
| 权限 | `.GoWebSSH/` = `drwx------`；`GoWebSSH.toml` / `gowebssh.db` = `-rw-------` |

未改动：adbd/adb-wifi、sing-box/mihomo、iptables、OTA 冻结链、boot/system/MTD、8899/22622 监听地址。

## 9. 回滚（约 10 秒，无防火墙/无系统层改动）

```sh
kill $(cat /tmp/webssh.pid)                     # 或 pkill -f /data/webssh/webssh
# 删 /etc/rc.local 中 '# >>> webssh >>>' 到 '# <<< webssh <<<' 之间的块
#   备份在 /data/webssh/rc.local.bak-20261027，可直接 cp 回去
rm -rf /data/webssh
```

未改动：adbd/adb-wifi、sing-box/mihomo、iptables、OTA 冻结链、boot/system/MTD。

**只回退二进制（保留数据/配置，约 5 秒）**：

```sh
kill $(cat /tmp/webssh.pid); sleep 1
cp -p /data/webssh/webssh.bak-20261027b /data/webssh/webssh
start-stop-daemon -S -b -x /data/webssh/start.sh -m -p /tmp/webssh.pid
# 旧包 md5 = d4b8c0d95fe6ccb075d6c84fcb8c69ae（UPX 5,119,828 B，旧前端 + 无兼容层）
```

## 10. 重新构建（前端 + 后端）与 2026-10-28 凌晨的修复

### 10.1 修的是什么

仪表盘「加载失败 / ubus 调用失败」的**真因**不是方法不存在，而是 B20 三卡固件的参数校验：

| 方法 | B20 实测要求 | 旧前端发的参数 | 结果 |
|---|---|---|---|
| `zwrt_data.get_wwandst` | `cid` + `type` + `subid`（`source_module` 可省） | `{source_module,cid,type}` | `Command failed: Invalid argument` |
| `zwrt_data.get_wwaniface` | `cid` + `subid` | `{source_module,cid,connect_status}` | `Command failed: Invalid argument` |

`subid` 不是卡槽号：本机 `modems` = `x75:1`（integrated_5g，在线）/ `v3e1:3` / `v3e2:5`。`subid=0` 报错，`subid=2`（不存在的 modem）会返回全 0 的成功响应，**不能盲试 1..N**。正确来源是 zwrt-datad 的 `interfaces.cellular.subid`。

两侧都改了：

1. **后端（`gossh/app/service/ubus_compat.go`，新增）**——`/api/ubus` 的白名单兼容层，只接管上面两个 `service.method`：
   - 先按调用方原始参数调 ubus（参数本来正确的机型零改动）；
   - 失败且不是「ubus 缺失/超时」时，用**缓存的 subid**（30s 窗口，来自 9460 `interfaces.cellular.subid`）补齐参数重试一次；
   - 仍失败才从 `http://127.0.0.1:9460/state` 取数，重排成前端 `TrafficData` / `WwanInfo` 字段返回 `code:0`（不透传 9460 原始结构）；
   - `ubus` 不存在/超时保持原错误语义；白名单外的一切调用行为不变。
   - 加固依据：9460 `/state` 在 daemon 重采样时会到 **2.85s**（p50 2ms），最初 1.5s 超时 + 每次实时取 subid 导致 60s 内漏 3 次；改为 subid 30s 缓存 + 3s 超时 + 5s 内旧快照复用后，150 次请求 0 失败（p95 71ms）。
   - 附带 `tolerant:true` 可选参数：失败时返回 `{code:0,result:{}}`。**前端不传该参数**（`webssh/src` 全库无 `tolerant`），仅作备用。
2. **前端（`webssh/src/views/Empty.vue`）**——`fetchAllData` 的 `Promise.all` 改为 `Promise.allSettled`，单请求失败只让对应面板显示 `-`，11/11 全失败才显示「加载失败」。

### 10.2 构建配方

```sh
cd .tmp-webssh-u60pro

# 1) 前端（Node/pnpm 在 PC 侧；设备上不需要）
cd webssh
pnpm install            # 或 npm install
npm run buildOnly       # 产物在 webssh/dist/
cd ..

# 2) 用 dist 覆盖内嵌静态资源（必须整目录替换，旧的 hashed 文件名会残留）
rm -rf gossh/webroot/*
cp -r webssh/dist/. gossh/webroot/

# 3) 后端交叉编译（不要 UPX：省掉自解压这个不确定因素）
cd gossh
# go.sum 缺失时先跑一次（离线即可，走本机 module cache）
GOPROXY=off GOSUMDB=off GOFLAGS=-mod=mod go mod tidy
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o webssh-patched .
md5sum webssh-patched          # 现行 = d4254bbc790006adb8d520c828d8791f（16,253,090 B）
```

**构建后必须核对前端确实换了**（embed 是编译期快照，拷错目录就会白发一版）：

```sh
python -c "d=open('webssh-patched','rb').read(); print(d.count(b'index-B5DoUXZY.js'), d.count(b'index-YarRM2Ci.js'))"
# 期望 "6 0"：新 js 名出现、旧 js 名为 0
```

### 10.3 上线（约 30 秒，无重启、无防火墙改动）

```sh
adb -s 192.168.0.1:15555 shell 'cp -p /data/webssh/webssh /data/webssh/webssh.bak-20261027b'
adb -s 192.168.0.1:15555 push gossh/webssh-patched /data/webssh/webssh.new
adb -s 192.168.0.1:15555 shell 'md5sum /data/webssh/webssh.new'      # 必须与 PC 侧一致
adb -s 192.168.0.1:15555 shell 'kill $(cat /tmp/webssh.pid); sleep 1; \
  chmod 755 /data/webssh/webssh.new; mv /data/webssh/webssh.new /data/webssh/webssh; \
  start-stop-daemon -S -b -x /data/webssh/start.sh -m -p /tmp/webssh.pid'
```

启动日志必须同时出现（缺一即回滚）：`use-config-file path=/data/webssh/.GoWebSSH/GoWebSSH.toml`、`http_server_start address=192.168.0.1:8899`、`Listening on host=192.168.0.1 port=22622`。

### 10.4 2026-10-28 凌晨整合部署实测（原始输出；日志时间为设备 UTC）

```text
$ md5sum /data/webssh/webssh.bak-20261027b /data/webssh/webssh
d4b8c0d95fe6ccb075d6c84fcb8c69ae  /data/webssh/webssh.bak-20261027b   # 旧 UPX 包
d4254bbc790006adb8d520c828d8791f  /data/webssh/webssh                  # 新整合版

$ netstat -ltnp | grep -E '8899|22622'
tcp 0 0 192.168.0.1:8899   0.0.0.0:* LISTEN 11143/webssh
tcp 0 0 192.168.0.1:22622  0.0.0.0:* LISTEN 11143/webssh

$ ls -l /data/webssh/
-rwxr-xr-x 1 root root    5049 Oct 27 09:29 rc.local.bak-20261027
-rwxr-xr-x 1 root root     108 Oct 27 15:26 start.sh
-rwxr-xr-x 1 root root 5119828 Oct 27 15:02 webssh.bak-20261027b
-rwxr-xr-x 1 root root 16253090 Oct 27 15:59 webssh

$ grep -E 'VmRSS|VmHWM' /proc/11143/status
VmHWM: 30168 kB
VmRSS: 30164 kB
$ ls /proc/11143/fd | wc -l -> 17     ; 线程 11；df -h /data -> 1.8G 总 / 503.2M 用 / 1.3G 可用 (27%)

$ # /api/ubus 11 条（登录后逐条 POST）
netInfo  zte_nwinfo_api.nwinfo_get_netinfo          code=0   type=SA band=n78 bars=5
lan      network.interface.lan.status               code=0   up=true 192.168.0.1/24
wan      network.interface.zte_wan.status           code=0
wan6     network.interface.zte_wan6.status          code=0
traffic  zwrt_data.get_wwandst                      code=0   rx_speed=2096557 tx_speed=26208 total_rx=268023761861
device   zwrt_mc.device.manager.get_device_info     code=0
cpuTemp  zwrt_bsp.thermal.get_cpu_temp              code=0   cpuss_temp=49
simInfo  uci.get                                     code=0
simInfo2 zwrt_zte_mdm.api.get_sim_info              code=0
wwan     zwrt_data.get_wwaniface                    code=0   ipv4_ipv6_connected 10.70.159.61
lanUser  zwrt_router.api.router_get_user_list_num   code=0   access_total=3
-> 11/11 code=0

$ # 稳定性：连续 150 次请求（两方法各 75 次，约 0.55s 间隔，含 9460 重采样慢点）
requests: 150  fails: 0   latency p50=0.049 p95=0.071 max=1.335

$ curl -s -o /dev/null -w '%{http_code}' http://192.168.0.1:8899/app/                       -> 200 (815 B)
$ curl -s -o /dev/null -w '%{http_code}' http://192.168.0.1:8899/app/assets/index-B5DoUXZY.js -> 200 (1,502,285 B)
$ tail -c +980898 /tmp/webssh.log | grep -c 'Ubus 调用失败'                                   -> 0
```

headless Chromium（登录 `admin` + 自设口令，12s 观察 6 次采样）：URL 落到 `#/app`，`加载失败`/`ubus 调用失败` 均不出现，console error 0，流量统计持续刷新（45 KB/s ↗ / 3.0 MB/s ↘，当日 425.7 MB、本月 8.3 GB、总下载 249.7 GB），网络接口状态显示 WAN IPv4 `10.70.159.61` / 网关 `10.70.159.62` / WAN IPv6 `2408:842c:...`。

SSH 回归：paramiko `root@192.168.0.1:22622` → `AUTH_OK SSH-2.0-OpenSSH`，pty `/dev/pts/0`，`id` = `uid=0(root)`。

已知残留（前端展示层面，与本轮故障无关）：LAN 接口一栏的 IP/网关/DNS 显示 `-`——网卡状态返回的是 `ipv4-address`（连字符），前端 `NetworkInterface` 接口里写的是 `ipv4_address`（下划线），属旧前端字段名不匹配；WAN IPv4/IPv6 区块取的是 `wwanInfo`，显示正常。

### 10.5 跑测试/回归时不要做的事

- 不要在设备上跑 `go build`（无工具链，且 14 MB 产物不必上机编译）。
- 不要 `kill` 后忘记 `start-stop-daemon`；也不要改用 `/etc/init.d`（rcS 不执行 overlay 新增服务，见 HANDOVER §21）。
- 不要用 `docker`/`upx` 复核二进制：`-trimpath -ldflags="-s -w"` 的未压缩产物就是现行形态。
- 兼容层里的 Debug 日志默认不输出（slog 默认 INFO），所以 `/tmp/webssh.log` 平时不会因 1Hz 刷新刷屏；排查时把日志级别调低才会看到「参数兼容重试成功」。

---

## 11. 三卡读取（5G 主卡 + 2×4G 模块，2026-10-28 上线）

> 需求：面板原来只显示 5G 主卡，用户要求把两张 4G 模块（V3E1/V3E2）也读出来。本节取代 §10.4 里「只有主卡」的描述；§10.4 的 `index-B5DoUXZY.js` 是加三卡之前的版本。

### 11.1 数据源与口径

| 项 | 结论 |
|---|---|
| 权威来源 | `zwrt-datad` 的 `GET http://127.0.0.1:9460/state` → **`modems[0..2]`**（每项含 `id/role/transport/subid/ifname/wan_interface/net/sim/wwan/interfaces/traffic/qos`，4G 另有 `usb/debug`）。顶层 `net`/`traffic`/`interfaces.cellular` **只代表 X75**，不能拿来冒充 4G |
| 三卡身份 | `x75`（integrated_5g，`rmnet_data0`/`zte_mwan2`，subid 1/2）· `v3e1`（外挂 4G，`V3E1net0`/`zte_mwan3`，subid 3/4）· `v3e2`（外挂 4G，`V3E2net0`/`zte_mwan4`，subid 5/6） |
| 槽位顺序 | 面板顺序固定 `x75 → v3e2 → v3e1`，对应物理槽 1/2/3（`slot_num`）。注意槽 2 是 V3E2、槽 3 是 V3E1，与 subid 升序不同 |
| 在线判据 | 沿用触屏口径：`operate_mode` 含 `online` **或** `wwan.status` 含 `connect` **或**（`net.type` 非空且 `bars>0`）。另用 `aggregation.paths[].enabled/up` 与 `interfaces.ipv4.up` 区分 `disabled` / `offline` / `absent` |
| 流量口径 | **netdev 差分**（`/proc/net/dev`，1s 采样）：x75 = `rmnet_data0` + `rmnet_ipa0`，v3e1 = `V3E1net0`，v3e2 = `V3E2net0`。与触屏三卡页一致；`traffic.source` 标 `netdev`，退化路径标 `datad` |
| 为什么不直接用 `traffic.*` | x75 的 `get_wwandst` 受 QCMAP ipv6 会计污染（HANDOVER §18/§11 历史结论），netdev 差分不会。9460 的 `modems[].traffic` 仅作兜底 |
| subid 禁忌 | `subid=0` 报错、`subid=2`（不存在的 modem）返回全 0 的「成功」——**禁止盲试 1..N**；枚举只来自 9460（`knownSubid` 缓存 30s） |
| 9460 不可用时 | 按缓存 subid 逐卡调 `zwrt_data.get_wwandst` + `get_wwaniface`；从未读到过三卡身份则返回 `code:2`，不猜 subid |

### 11.2 API 契约（`GET /api/modems`）

- 鉴权：`Authorization: <JWT>`（无 Bearer 前缀，与其它接口一致），**在 auth 组、不在 PremCheck 白名单** → 只要求登录，不要求 `is_admin`
- HTTP 恒 200，业务码看 `body.code`：`0` 成功；`2` = 9460 不可用且无缓存卡信息
- 卡片顺序 `x75, v3e2, v3e1`；每张卡字段（缺值为 `null`）：
  `id / slot / slot_num / role / ifname / wan_interface / subid / present / enabled / online / state / operate_mode`，
  `net{type,rat,operator,band,band_label,bandwidth,channel,pci,cell_id,rsrp,rsrq,sinr,rssi,bars,roaming}`，
  `wwan{status}`，`ipv4{up,address,netmask,gateway,dns[]}`，`ipv6{...}`，
  `traffic{rx_speed,tx_speed,rx_bytes,tx_bytes,session_time,source}`
- `state` 五态：`connected | offline | disabled | absent | unknown`（`present:false` → `absent`）

### 11.3 UI

`Empty.vue` 仪表盘**最顶部**（紧贴页头，第一屏可见）新增「三卡状态」卡片区（`el-row/el-col`，窄屏纵向）：槽位标签 + 状态徽标（在线绿/已停用灰/未连接橙/未检测到红）+ 运营商 + 制式 + 频段/带宽 + RSRP/RSRQ/SINR + 信号格 + 实时上下行 + 会话累计 + IPv4；缺字段统一 `-`，未在线卡片降透明度。请求与仪表盘同一刷新节奏，失败静默保留上次值（不影响主数据，也不影响 §10 的 `allSettled` 兜底）。

### 11.3.1 旧的四张卡片已删除（2026-10-28 第三版）

三卡区上线后，原来的 `5G 载波信息` / `4G 载波信息`（PCC/SCC 表）、`NR 5G 信号` / `LTE 信号` 四张卡被取代（后两张长期显示「未激活 / 0 dBm」）。已从 `Empty.vue` 模板整块删除，并把仅存的有价值字段并入三卡卡片的一行小字：

```text
频点 633984 · PCI 450 · Cell 16578081104
```

（数据取 `net.channel / net.pci / net.cell_id`，`null` 时整行不渲染。这样删卡不丢排障信息。）

删除后 `.content` 的卡片顺序：`三卡状态 → 设备信息 → 网络信息 → 流量统计 → 频段与锁定 → 网络接口状态 → 标识信息`。

对应二进制 md5 `51188057ad9d97b53c4ad8be0a60d9be`（`index-DGyVa-PU.js`），备份链：`webssh.bak-20261028`（三卡之前）← `6f58ed08…`（三卡在顶部）← 现行。

### 11.3.3 点「连接」后主机管理弹窗自动关闭（2026-10-28）

现象：在「主机管理」里点「连接」，终端已经在背后打开，但弹窗不消失，得手动点右上角 ×。

根因：`Home.vue::connectHost()` 只关了编辑弹窗 `data.host_dialog_visible`，没关列表弹窗 `data.modify_devices_dialog_visible`；另外列表底部「关闭」按钮绑的是不存在的 `dialogVisible`（点了没反应）。

修法（`src/views/Home.vue`）：
- `connectHost()` 开头同时置 `data.modify_devices_dialog_visible = false`
- footer 的「关闭」改为 `@click="data.modify_devices_dialog_visible = false"`

验证（headless，脚本点击而非人眼）：
```text
打开「主机管理」 -> visibleDialogs=["主机管理"]
点行内「连接」    -> visibleDialogs=[]            （自动关闭）
终端文本          -> "# https://github.com/o8oo8o/WebSSH  bash-5.2# "
```

对应二进制 md5 `7232f6f7e5811b6419203f16d96e155c`（`index-BtH49saf.js`）。

### 11.3.2 连接条目（主机）必须写 192.168.0.1:22622（2026-10-28 排障）

用户反馈「无论端口填 22622 还是 15555 都连不上」。实测根因是**连接条目的主机地址**，不是端口：

```text
POST /api/ssh/create_session  （应用自身从设备侧发起 SSH，与网页终端同一路径）
127.0.0.1:22622  -> code=1  dial tcp4 127.0.0.1:22622: connect: connection refused
192.168.0.1:22622 -> code=0  ok
127.0.0.1:15555  -> 15s 超时（adbd 说 adb 协议，不是 SSH，握手永远不返回）
```

原因：
- 内置 sshd 只绑 **`192.168.0.1:22622`**（`netstat -ltn` 实测），**不监听 127.0.0.1**；初始化时生成的默认连接却写 `127.0.0.1`（上游 u60pro 的 sshd 绑 0.0.0.0，所以那边没事）。
- `15555` 是无线 ADB（adbd），不是 SSH。

处理：
1. 现有条目用 `PUT /api/conn_conf` 修正为 `address=192.168.0.1 / port=22622`（同时把 `pwd` 回填）。
2. 源码修正 `app/service/sys_init.go`：默认连接的 `Address` 跟随初始化时填的 `sshd_host`（只有为空/`0.0.0.0` 时才退回 `127.0.0.1`），避免重装后再次踩坑。
3. 面板上「更新主机」对话框：主机 `192.168.0.1`、端口 `22622`、用户 `root`、SSH 密码见 §8，认证方式「密码」。

对应二进制 md5 `fab31420da3aacb7e3a5f4e7169b3a71`。

### 11.4 2026-10-28 实机结果（原始输出）

```text
$ GET /api/modems   -> code=0
x75   slot=5G 主卡    num=1 present=True enabled=True online=True state=connected type=SA  band=N78 rsrp=-87 bars=5 ipv4=10.70.159.61   src=netdev
v3e2  slot=4G 模块 1  num=2 present=True enabled=True online=True state=connected type=LTE band=B5  rsrp=-69 bars=5 ipv4=10.64.54.77    src=netdev
v3e1  slot=4G 模块 2  num=3 present=True enabled=True online=True state=connected type=LTE band=B5  rsrp=-72 bars=5 ipv4=10.80.111.174  src=netdev

$ 两次采样（间隔 3s，证明每卡独立计数）
sample1 x75  rx=43     tx=43     rx_bytes=4972531658 tx_bytes=445523100
sample1 v3e2 rx=692    tx=151    rx_bytes=830024     tx_bytes=402996
sample1 v3e1 rx=339    tx=2545   rx_bytes=496125     tx_bytes=364314
sample2 x75  rx=59076  tx=63820  rx_bytes=4972602003 tx_bytes=445598190
sample2 v3e2 rx=19330  tx=11305  rx_bytes=853941     tx_bytes=416575
sample2 v3e1 rx=187    tx=8023   rx_bytes=501827     tx_bytes=373913
```

**事实更新**：2026-10-01 记录的「4G 双卡用户有意关闭」在本次实测中**已不成立**——两个 4G 模块都已 `connected` 且有独立 IPv4（10.64.54.77 / 10.80.111.174）。文档其它地方仍写「仅 5G online」属历史态，以本节实测为准（勿据此排查 4G）。

二进制与部署：`/data/webssh/webssh` = 16,318,626 B / md5 `51188057ad9d97b53c4ad8be0a60d9be`（三卡区置于顶部的最终版，含 `index-jF0AbIL1.js`）；上一版备份 `/data/webssh/webssh.bak-20261028`（md5 `d4254bbc790006adb8d520c828d8791f`）。更早的 `dd154638…`（三卡区在页底）已被替换。进程由 `start-stop-daemon` 拉起，8899/22622 双监听不变。

### 11.5 已知限制

- `modems[].traffic` 没有日/月累计与套餐会计（那些只在顶层 `traffic.*`，且是主卡口径）；面板三卡只展示会话实时速率与累计字节（netdev）
- `9460` 没有 per-modem 启停动作（`cellular.*` 只作用主卡），4G 被停用时面板只能如实显示「已停用」，**不能**从面板启用
- 4G 信号来自 `nwinfo_get_msim_netinfo`（主机侧），不依赖 ADB；只有 QoS 采样的 `adc2_temp`/`key.log` 依赖 ADB
- 4G 只发布活动槽字段：`lte_bandwidth` 非法值会被上游省略，UI 必须容忍 `null`

### 11.6 回归验证（可重复执行）

`.tmp-webssh-u60pro/e2e/verify.py`（不入库，`/.tmp-webssh-u60pro/` 已被 gitignore；夹具 `state_mu5252.json` 为脱敏快照）：

```sh
cd .tmp-webssh-u60pro/e2e
WEBSSH_USER=admin WEBSSH_PWD=<PWD> WEBSSH_SSH_PWD=<PWD> python verify.py --fixture state_mu5252.json
# PASS FX/A/B/C/D/E/F -> RESULT: PASS
#  E 步骤用 headless Edge(CDP) 真渲染，断言「加载失败」=0 且三张卡 3/3
```

脚本步骤：A 登录 → B 静态资源 → C 11 条 `/api/ubus` 全 `code:0` → D `/api/modems` 三卡 → E 浏览器渲染三卡 → F SSH `root@22622` 能进。

### 11.7 index.html 必须 no-store（2026-10-28 二次上线教训）

首次上线时三卡区放在页面底部（`标识信息` 之后，约 2050px 处），且 `index.html` 没有 `Cache-Control`（gin 静态托管默认只给 `Accept-Ranges`/`Content-Length`）——浏览器对无缓存头的 HTML 会**启发式缓存**，换版后刷新仍加载旧 `index.html`（引用已删除的旧 asset），表现就是「刷新了但看不到新功能」。

处理：
- 三卡区前移到 `.content` 的第一张卡（页头下方第一屏）。
- `main.go` 增加中间件：对以 `/` 结尾、`.html`、`/app` 的请求下发 `Cache-Control: no-cache, no-store, must-revalidate` + `Pragma` + `Expires: 0`；带 hash 的 `assets/*` 仍走默认缓存。
- 已在旧缓存上翻不过来的浏览器**一次 Ctrl+F5 硬刷新**即可，之后普通刷新都会拿到新版。

验证：`curl -s -i http://192.168.0.1:8899/app/ | head -8` 应出现 `Cache-Control: no-cache, no-store, must-revalidate`；页面 `.content > .card` 顺序首项为「三卡状态」。

**Windows 坑**：用 `python -c` 从 `curl` 取 token 时行尾是 `\r\n`，直接拼进 `Authorization` header 会被 Go 判成非法请求返回 `400 Bad Request`；取值时加 `| tr -d '\r\n'`。
