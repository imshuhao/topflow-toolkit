#!/usr/bin/env python3
"""Interactively rotate only the independent LuCI login on the connected B22."""
import argparse
import getpass
import json
import os
import shlex
import subprocess
import sys
import tempfile

import manage


def main():
    parser = argparse.ArgumentParser(description='交互式修改独立 LuCI 账号密码，输入隐藏；不会修改 root 密码。')
    parser.parse_args()
    if not sys.stdin.isatty():
        raise RuntimeError('请直接在终端运行此命令，不能通过管道传入密码。')
    if manage.shell('uci -q get zwrt_common_info.common_config.wa_inner_version') != 'BD_ENCNMU5252V1.0.0B22':
        raise RuntimeError('设备固件不匹配。')
    if manage.shell('uci -q get rpcd.luci_readonly.username') != 'luci':
        raise RuntimeError('没有找到预期的独立 LuCI 账号。')
    secret = getpass.getpass('新的 LuCI 密码：')
    if not 8 <= len(secret.encode()) <= 128 or any(ord(c) < 32 or ord(c) == 127 for c in secret):
        raise RuntimeError('密码须为 8–128 字节，且不能含控制字符。')
    if secret != getpass.getpass('再次输入：'):
        raise RuntimeError('两次输入不一致，未修改密码。')
    # Password goes to openssl via stdin, never argv, the shell or a log.
    digest = subprocess.run(['openssl', 'passwd', '-6', '-stdin'],
        input=secret + '\n', text=True, capture_output=True, check=True).stdout.strip()
    if not digest.startswith('$6$'):
        raise RuntimeError('生成密码哈希失败，未修改密码。')
    credential_file = manage.PRIVATE / 'credentials.json'
    manage.ensure_private()
    # Prepare and sync the local copy before changing the device. Preserve it on
    # an ambiguous device error, so the user can recover without disclosing it.
    fd, pending = tempfile.mkstemp(prefix='credentials-pending-', suffix='.json', dir=manage.PRIVATE)
    with os.fdopen(fd, 'w') as stream:
        json.dump({'username': 'luci', 'password': secret}, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    command = 'uci set ' + shlex.quote('rpcd.luci_readonly.password=' + digest) + '\nuci commit rpcd'
    try:
        manage.shell(command)
        if manage.shell('uci -q get rpcd.luci_readonly.password') != digest:
            raise RuntimeError('设备密码哈希校验失败。')
    except Exception:
        print('未能确认设备修改结果；新凭据的本地恢复文件：' + pending, file=sys.stderr)
        raise
    os.replace(pending, credential_file)
    # Only invalidate this account's sessions, leaving stock/root sessions alone.
    try:
        manage.destroy_sessions('luci')
    except Exception:
        print('密码已更新，但旧会话清理失败；请在旧浏览器中退出登录。')
    else:
        print('密码已更新，旧 LuCI 会话已退出。请用新密码重新登录。')
    print('本地凭据已同步：' + str(credential_file))


if __name__ == '__main__':
    try:
        main()
    except (KeyboardInterrupt, EOFError):
        raise SystemExit('\n已取消。')
    except Exception as exc:
        # Avoid dumping subprocess arguments or credential-bearing tracebacks.
        print('改密未完成：' + (str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__), file=sys.stderr)
        raise SystemExit(1)
