#!/usr/bin/env python3
"""B22 deployment and reversible removal; no firmware or package upgrades."""
from pathlib import Path
import argparse
import getpass
import os
import secrets
import json
import hashlib
import re
import shlex
import subprocess
import sys
import time

SOURCE = Path(__file__).resolve().parent
ROOT = SOURCE.parent
OUT = Path(os.environ.get('LUCI_BUILD_DIR', ROOT / 'build/luci-admin')).resolve()
PRIVATE = Path(os.environ.get('LUCI_PRIVATE_DIR', ROOT / 'private/luci-admin')).resolve()
# Preserve the deployed service, account section and paths across the admin upgrade.
BASE = '/data/local/luci-readonly'
FIRMWARE = 'BD_ENCNMU5252V1.0.0B22'


def adb(*args, timeout=30):
    command = ['adb']
    if os.environ.get('ADB_SERIAL'):
        command += ['-s', os.environ['ADB_SERIAL']]
    return subprocess.run(command + list(args), capture_output=True, check=True, timeout=timeout)


def shell(command):
    # This vendor wrapper loses exit codes; require an unpredictable final marker.
    marker = '__LUCI_OK_' + secrets.token_hex(12) + '__'
    proc = adb('shell', 'sh -c ' + shlex.quote('set -e\n' + command + '\nprintf "\\n%s\\n" ' + shlex.quote(marker)))
    output = proc.stdout.decode().replace('\r', '').rstrip()
    if not output.endswith('\n' + marker) and output != marker:
        raise RuntimeError('Device command failed; inspect the device privately')
    return output[:-len(marker)].strip()


def rpc(object_name, method, args=None):
    return shell('ubus call ' + shlex.quote(object_name) + ' ' + shlex.quote(method) + ' ' + shlex.quote(json.dumps(args or {})))


def push(source, target):
    adb('push', str(source), target)


def ensure_private():
    PRIVATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    PRIVATE.chmod(0o700)


def preflight():
    if shell('id -u') != '0':
        raise RuntimeError('Root ADB is required')
    if shell('uci -q get zwrt_common_info.common_config.wa_inner_version') != FIRMWARE:
        raise RuntimeError('This module is restricted to the audited B22 firmware')
    if shell('uci -q get network.lan.ipaddr') != '192.168.11.1':
        raise RuntimeError('This module requires LAN 192.168.11.1')
    shell('test -w /usr/share/rpcd/acl.d; test -w /etc/config; test -x /usr/bin/ucode; test -x /usr/bin/openssl; test -x /usr/bin/curl')
    if not shell('ubus list mihomo.api 2>/dev/null || true'):
        raise RuntimeError('Install mihomo-manager and its writable ACL mount first')
    capabilities = json.loads(shell('curl --noproxy "*" -fsS --max-time 5 http://127.0.0.1:9460/capabilities'))
    if 'wifi.configure' not in json.dumps(capabilities):
        raise RuntimeError('The local zwrt-datad control API is unavailable or incompatible')


def check_installed():
    if shell('uci -q get rpcd.luci_readonly.username') != 'luci':
        raise RuntimeError('Expected LuCI installation not found')
    shell('test -f /etc/init.d/luci-readonly; test -f ' + BASE + '/enabled')


def destroy_sessions(username):
    raw = rpc('session', 'list')
    decoder = json.JSONDecoder()
    while raw.strip():
        entry, used = decoder.raw_decode(raw.lstrip())
        raw = raw.lstrip()[used:]
        if entry.get('data', {}).get('username') == username:
            rpc('session', 'destroy', {'ubus_rpc_session': entry['ubus_rpc_session']})

def wait_stopped():
    for _ in range(40):
        if not shell('ubus list luci 2>/dev/null || true'): return
        time.sleep(.5)
    raise RuntimeError('LuCI helper did not stop')

def start():
    shell('/etc/init.d/luci-readonly start')
    for _ in range(30):
        status = json.loads(rpc('service', 'list', {'name': 'luci-readonly'}))
        running = any(i.get('running') for i in status.get('luci-readonly', {}).get('instances', {}).values())
        if running and shell('ubus list luci 2>/dev/null || true') == 'luci': return
        time.sleep(.5)
    raise RuntimeError('LuCI did not start; inspect runtime logs privately')

def stop():
    shell('/etc/init.d/luci-readonly stop')
    wait_stopped()

def boot_hook(enabled):
    # Vendor B22 retains rc.d links but does not execute newly added entries.
    # Change only our marked block in its actual startup path.
    raw = adb('exec-out', 'cat /etc/rc.local', timeout=15).stdout
    original = raw.decode()
    marker = '# BEGIN LUCI_READONLY\n'
    end = '# END LUCI_READONLY\n'
    if original.count(marker) > 1 or original.count(marker) != original.count(end):
        raise RuntimeError('Unexpected LuCI boot markers; refusing to change rc.local')
    cleaned = re.sub(re.escape(marker) + r'.*?' + re.escape(end), '', original, flags=re.S)
    if enabled:
        exits = list(re.finditer(r'^exit 0\s*$', cleaned, re.M))
        if len(exits) != 1: raise RuntimeError('Expected one final exit in rc.local')
        hook = marker + 'if [ -x /etc/init.d/luci-readonly ] && /etc/init.d/luci-readonly enabled; then\n    /etc/init.d/luci-readonly start\nfi\n' + end
        cleaned = cleaned[:exits[0].start()] + hook + cleaned[exits[0].start():]
    if cleaned == original: return
    ensure_private()
    target = PRIVATE / 'rc.local.generated'
    target.write_text(cleaned)
    target.chmod(0o600)
    digest = hashlib.sha256(raw).hexdigest()
    push(target, BASE + '/runtime/rc.local.new')
    shell(f'''test "$(sha256sum /etc/rc.local | cut -d ' ' -f 1)" = {shlex.quote(digest)}
test -f {BASE}/backups/rc.local.before || cp -p /etc/rc.local {BASE}/backups/rc.local.before
sh -n {BASE}/runtime/rc.local.new
cat {BASE}/runtime/rc.local.new > /etc/rc.local
chmod 755 /etc/rc.local
rm {BASE}/runtime/rc.local.new
''')

def install():
    preflight()
    if not (OUT / 'bundle.tar.gz').is_file():
        raise RuntimeError('Run build.py first')
    if shell('test -e /etc/init.d/luci-readonly && echo exists; true'):
        raise RuntimeError('Already installed; use upgrade to preserve the current password')
    if shell('test -e /etc/config/luci && echo exists; true') or shell('ubus list luci 2>/dev/null || true'):
        raise RuntimeError('An existing LuCI installation must be handled separately')
    if shell("uci -q get rpcd.luci_trial.username || true"):
        raise RuntimeError('Remove the old trial before a fresh installation')
    if any(line.endswith("='luci'") for line in shell("uci show rpcd | grep -F '.username=' || true").splitlines()):
        raise RuntimeError('A luci account already exists')
    if shell('test -d ' + BASE + '/backups && echo exists; true'):
        raise RuntimeError('Existing backups retained: archive the old installation before reinstalling')
    if shell("netstat -lnt | awk '$4 ~ /:8080$|:18080$/ { print $4 }'"):
        raise RuntimeError('A required LuCI port is occupied')
    if not sys.stdin.isatty():
        raise RuntimeError('Run install in a terminal to choose a private login password')
    password = getpass.getpass('New luci password: ')
    if len(password.encode()) < 8 or len(password.encode()) > 128 or any(ord(c) < 32 or ord(c) == 127 for c in password):
        raise RuntimeError('Use 8-128 bytes without control characters')
    if password != getpass.getpass('Repeat password: '):
        raise RuntimeError('Passwords do not match')
    password_hash = subprocess.run(['openssl','passwd','-6','-stdin'], input=password+'\n', text=True, capture_output=True, check=True).stdout.strip()
    if not password_hash.startswith('$6$'):
        raise RuntimeError('Password hashing failed')
    ensure_private()
    credfile = PRIVATE / 'credentials.json'
    if credfile.exists():
        raise RuntimeError('Private credentials already exist; retain them and choose a new LUCI_PRIVATE_DIR')
    # Local recovery credentials are created before the device mutation.
    with credfile.open('w', opener=lambda path, flags: os.open(path, flags, 0o600)) as file:
        json.dump({'username':'luci','password':password}, file, indent=2)
        file.write('\n')
    credfile.chmod(0o600)
    shell(f'mkdir -p {BASE}/backups {BASE}/runtime; chmod 700 {BASE} {BASE}/backups {BASE}/runtime')
    shell(f'cp -p /etc/config/rpcd {BASE}/backups/rpcd.before\ncp -p /etc/config/firewall {BASE}/backups/firewall.before')
    push(OUT / 'bundle.tar.gz', BASE + '/runtime/bundle.tar.gz')
    shell(f'tar -xzf {BASE}/runtime/bundle.tar.gz -C {BASE}')
    setup = PRIVATE / 'account-setup.uci'
    setup.write_text("set rpcd.luci_readonly=login\nset rpcd.luci_readonly.username='luci'\n"
        f"set rpcd.luci_readonly.password='{password_hash}'\n"
        "set rpcd.luci_readonly.timeout='3600'\nadd_list rpcd.luci_readonly.read='luci-*'\nadd_list rpcd.luci_readonly.write='luci-device-admin'\ncommit rpcd\n"
        "set firewall.luci_readonly=include\nset firewall.luci_readonly.path='/data/local/luci-readonly/firewall.sh'\n"
        "set firewall.luci_readonly.reload='1'\nset firewall.luci_readonly.family='ipv4'\ncommit firewall\n")
    setup.chmod(0o600)
    push(setup, BASE + '/runtime/account-setup.uci')
    shell(f"""uci batch < {BASE}/runtime/account-setup.uci
rm {BASE}/runtime/account-setup.uci
cp {BASE}/acl/*.json /usr/share/rpcd/acl.d/
chmod 600 /usr/share/rpcd/acl.d/luci-readonly-*.json
cp {BASE}/stage/etc/config/luci /etc/config/luci
chmod 600 /etc/config/luci
cp {BASE}/luci-readonly.init /etc/init.d/luci-readonly
chmod 755 /etc/init.d/luci-readonly
touch {BASE}/enabled
chmod 600 {BASE}/enabled
sha256sum /etc/config/rpcd > {BASE}/backups/rpcd.installed.sha256
sha256sum /etc/config/firewall > {BASE}/backups/firewall.installed.sha256
/etc/init.d/luci-readonly enable
""")
    boot_hook(True)
    start()
    print('Installed: http://192.168.11.1:8080/cgi-bin/luci/ (luci account).')
    print('Private recovery credentials: ' + str(credfile))


def uninstall():
    shell('/etc/init.d/luci-readonly disable')
    stop()
    boot_hook(False)
    destroy_sessions('luci')
    shell(f'''{BASE}/firewall.sh remove
if sha256sum -c {BASE}/backups/rpcd.installed.sha256 >/dev/null 2>&1; then
 cp -p {BASE}/backups/rpcd.before /etc/config/rpcd
else
 uci -q delete rpcd.luci_readonly || true
 uci commit rpcd
fi
if sha256sum -c {BASE}/backups/firewall.installed.sha256 >/dev/null 2>&1; then
 cp -p {BASE}/backups/firewall.before /etc/config/firewall
else
 uci -q delete firewall.luci_readonly || true
 uci commit firewall
fi
for source in {BASE}/acl/*.json; do
 target=/usr/share/rpcd/acl.d/${{source##*/}}
 if cmp -s "$source" "$target"; then rm "$target"; fi
done
if cmp -s /etc/config/luci {BASE}/stage/etc/config/luci; then rm /etc/config/luci; fi
rm -f /etc/init.d/luci-readonly {BASE}/enabled
ubus call session revoke '{{"ubus_rpc_session":"00000000000000000000000000000000","scope":"ubus","objects":[["luci","getFeatures"],["file","list"]]}}'
ubus call session revoke '{{"ubus_rpc_session":"00000000000000000000000000000000","scope":"file","objects":[["/www/luci-static/resources/preload","list"]]}}'
''')
    print('Uninstalled service/account/ACL/firewall include; backups and bundle retained.')

def upgrade():
    """Update existing LuCI in place, retaining the current on-device password."""
    preflight()
    check_installed()
    if not (OUT / 'bundle.tar.gz').is_file():
        raise RuntimeError('Run build.py first')
    stamp = time.strftime('%Y%m%d-%H%M%S')
    backup = BASE + '/backups/upgrade-' + stamp
    shell('cmp -s /etc/init.d/luci-readonly ' + BASE + '/luci-readonly.init')
    shell(f'''mkdir -m 700 {backup}
set -- stage acl luci-readonly.uc run-namespace.sh firewall.sh luci-readonly.init
for file in diagnostic.sh service-action.sh; do
 [ ! -f {BASE}/"$file" ] || set -- "$@" "$file"
done
tar -czf {backup}/bundle.tar.gz -C {BASE} "$@"
cp -p /etc/config/rpcd {backup}/rpcd.before
cp -p /etc/init.d/luci-readonly {backup}/init.before
''')
    push(OUT / 'bundle.tar.gz', BASE + '/runtime/upgrade.tar.gz')
    stop()
    try:
        shell(f'''tar -xzf {BASE}/runtime/upgrade.tar.gz -C {BASE}
cp {BASE}/acl/*.json /usr/share/rpcd/acl.d/
chmod 600 /usr/share/rpcd/acl.d/luci-readonly-*.json
cp {BASE}/luci-readonly.init /etc/init.d/luci-readonly
chmod 755 /etc/init.d/luci-readonly
uci -q del_list rpcd.luci_readonly.write=luci-device-admin || true
uci add_list rpcd.luci_readonly.write=luci-device-admin
uci commit rpcd
''')
        destroy_sessions('luci')
        start()
    except Exception:
        # Retain the failed bundle for diagnosis, restore only this installation.
        try: stop()
        except Exception: pass
        shell(f'''mv {BASE}/stage {backup}/failed-stage
mv {BASE}/acl {backup}/failed-acl
tar -xzf {backup}/bundle.tar.gz -C {BASE}
for source in {backup}/failed-acl/*.json; do
 target=/usr/share/rpcd/acl.d/${{source##*/}}
 if cmp -s "$source" "$target"; then rm "$target"; fi
done
cp {BASE}/acl/*.json /usr/share/rpcd/acl.d/
cp -p {backup}/rpcd.before /etc/config/rpcd
cp -p {backup}/init.before /etc/init.d/luci-readonly
''')
        destroy_sessions('luci'); start()
        raise
    print('Upgraded LuCI; device password preserved, backup: ' + backup)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', nargs='?', default='status', choices=['preflight','install','upgrade','uninstall','start','stop','status'])
    args = parser.parse_args()
    if args.action in ['install','upgrade']:
        return globals()[args.action]()
    if args.action == 'preflight':
        preflight()
        print('B22, LAN, runtime, Mihomo RPC and datad prerequisites passed (read-only).')
        return
    # Recovery does not depend on Mihomo/datad remaining installed or healthy.
    if shell('id -u') != '0' or shell('uci -q get zwrt_common_info.common_config.wa_inner_version') != FIRMWARE:
        raise RuntimeError('Root ADB on the audited B22 firmware is required')
    if args.action == 'status':
        print(rpc('service', 'list', {'name': 'luci-readonly'}))
    else:
        check_installed()
        globals()[args.action]()


if __name__ == '__main__':
    try:
        main()
    except (KeyboardInterrupt, EOFError):
        raise SystemExit('Cancelled')
    except Exception as error:
        # No credential-bearing subprocess arguments or device output in tracebacks.
        print(str(error) if isinstance(error, RuntimeError) else type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
