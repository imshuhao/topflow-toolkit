#!/usr/bin/env python3
"""Build pinned official OpenWrt packages plus the original B22 integration."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

SOURCE = Path(__file__).resolve().parent
DEFAULT_OUT = SOURCE.parent / 'build/luci-admin'


def checked_replace(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError('Pinned upstream patch context changed')
    return text.replace(old, new, 1)


def fetch_package(record, cache, offline=False):
    path = cache / record['Filename']
    if not path.exists():
        if offline:
            raise RuntimeError('Missing cached package: ' + record['Package'])
        cache.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(record['url'], timeout=40) as response:
            blob = response.read()
        if hashlib.sha256(blob).hexdigest() != record['SHA256sum']:
            raise RuntimeError('Package checksum mismatch: ' + record['Package'])
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as file:
            file.write(blob)
            pending = Path(file.name)
        pending.replace(path)
    blob = path.read_bytes()
    if hashlib.sha256(blob).hexdigest() != record['SHA256sum']:
        raise RuntimeError('Package checksum mismatch: ' + record['Package'])
    return blob


def unpack(blob, destination):
    with tarfile.open(fileobj=io.BytesIO(blob), mode='r:*') as package:
        data = package.extractfile(next(m for m in package.getmembers() if m.name.lstrip('./') == 'data.tar.gz')).read()
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as data:
        data.extractall(destination, filter='data')


def tar_bundle(bundle, archive):
    # Stable metadata keeps clean builds reproducible; packages remain local only.
    with archive.open('wb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', filename='', mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode='w') as tar:
            for path in sorted(bundle.rglob('*')):
                entry = tar.gettarinfo(path, arcname=str(path.relative_to(bundle)))
                entry.uid = entry.gid = 0
                entry.uname = entry.gname = 'root'
                entry.mtime = 0
                if entry.isfile():
                    with path.open('rb') as data:
                        tar.addfile(entry, data)
                else:
                    tar.addfile(entry)


def build(output, cache, offline=False):
    records = json.loads((SOURCE / 'packages.lock.json').read_text())
    # Verify all packages before replacing any previous build.
    blobs = [(record, fetch_package(record, cache, offline)) for record in records]
    BUNDLE = output / 'bundle'
    if BUNDLE.exists():
        shutil.rmtree(BUNDLE)
    stage = BUNDLE / 'stage'
    stage.mkdir(parents=True)
    for record, blob in blobs:
        unpack(blob, stage)
    config = stage / 'etc/config/luci'
    config.write_text(config.read_text().replace('option lang auto', 'option lang zh_cn')
        .replace('config internal themes', "config internal themes\n\toption Bootstrap '/luci-static/bootstrap'")
        .replace('config internal languages', "config internal languages\n\toption zh_cn '简体中文'"))
    base_menu = stage / 'usr/share/luci/menu.d/luci-base.json'
    data = json.loads(base_menu.read_text())
    base_menu.write_text(json.dumps({k:v for k,v in data.items() if not k.startswith('admin/uci')}, indent=2)+'\n')
    upstream = (stage / 'usr/share/rpcd/ucode/luci').read_text()
    upstream = checked_replace(upstream, "'use strict';", "'use strict';\nimport { connect } from 'ubus';\nimport * as uloop from 'uloop';")
    upstream = checked_replace(upstream, 'return { luci: methods };', """
uloop.init();
const bus = connect();
const reads = {};
for (let name, method in methods)
    if (substr(name, 0, 3) == 'get') {
        method.args ??= {};
        method.args.ubus_rpc_session = '';
        reads[name] = method;
    }
const published = bus.publish('luci', reads);
if (!published) die('Unable to register the trial luci object');
uloop.run();
""")
    # Preserve the existing deployed read ACL names when upgrading.
    trial_acl = {}
    for path in sorted((stage / 'usr/share/rpcd/acl.d').glob('*.json')):
        data = json.loads(path.read_text())
        data.pop('unauthenticated', None)
        for group in data.values(): group.pop('write', None)
        trial_acl['luci-trial-' + path.name] = data
    trial_acl['luci-trial-read.json'] = {'luci-trial-read': {
        'description': 'LuCI device status', 'read': {
            'ubus': {'luci':['getFeatures'], 'session':['access'], 'mwan3':['status'], 'file':['exec']},
            'file': {'/usr/bin/tail -n 100 /logfs/syslog':['exec']}}}}
    syslog = stage / 'www/luci-static/resources/view/status/syslog.js'
    text = syslog.read_text()
    start, end = text.index('load:function()'), text.index(',render:function')
    text = text[:start] + "load:function(){return fs.exec_direct('/usr/bin/tail',['-n','100','/logfs/syslog']);}" + text[end:]
    text = checked_replace(text, "E('h2',{},[_('System Log')])", "E('h2',{},[_('System Log')]),E('p',{},'原厂系统日志，显示最近 100 行。')")
    syslog.write_text(text)
    stage = BUNDLE / 'stage'
    menu = stage / 'usr/share/luci/menu.d/luci-mod-status.json'
    data = json.loads(menu.read_text())
    hidden = ['iptables', 'nftables', 'channel_analysis', 'realtime/wireless', 'realtime/connections', 'logs/dmesg']
    data = {k: v for k, v in data.items() if not any(k == 'admin/status/' + h or k.startswith('admin/status/' + h + '/') for h in hidden)}
    data['admin/status/overview']['action'] = {'type': 'view', 'path': 'status/topflow'}
    menu.write_text(json.dumps(data, indent=2) + '\n')
    # The separate helper publishes native reads and an explicit set of management APIs.
    helper = upstream
    helper = helper.replace('uloop.init();', (SOURCE / 'topflow.uc').read_text() + '\n' + (SOURCE / 'admin.uc').read_text() + '\nuloop.init();')
    writes = ['setWifi', 'setMultiwanMember', 'setCellularLink', 'setAdminService', 'setMihomoService', 'runDiagnostic', 'setLoginPassword']
    helper = helper.replace("if (substr(name, 0, 3) == 'get')", "if (substr(name, 0, 3) == 'get' || index(" + json.dumps(writes) + ", name) >= 0)")
    (BUNDLE / 'luci-readonly.uc').write_text(helper)
    shutil.copy2(SOURCE / 'topflow.js', stage / 'www/luci-static/resources/view/status/topflow.js')
    resources = stage / 'www/luci-static/resources'
    (resources / 'topflow').mkdir(exist_ok=True)
    shutil.copy2(SOURCE / 'admin.js', resources / 'topflow/admin.js')
    shutil.copytree(SOURCE / 'views', resources / 'view/mu5252')
    admin_menu = {}
    for parent, title, order, pages in [
        ('system', '系统', 20, [('password', '登录密码'), ('services', '服务管理'), ('reboot', '重启')]),
        ('network', '网络', 30, [('wifi', '无线网络'), ('cellular', '移动网络'), ('multiwan', 'MultiWAN'), ('diagnostics', '网络诊断')]),
        ('services', '服务', 40, [('mihomo', 'Mihomo')])]:
        root = 'admin/' + parent
        admin_menu[root] = {'title': title, 'order': order, 'action': {'type': 'firstchild'}, 'depends': {'acl': ['luci-device-admin']}}
        for index, (page, label) in enumerate(pages):
            admin_menu[root + '/' + page] = {'title': label, 'order': (index + 1) * 10, 'action': {'type': 'view', 'path': 'mu5252/' + page}, 'depends': {'acl': ['luci-device-admin']}}
    (stage / 'usr/share/luci/menu.d/luci-device-admin.json').write_text(json.dumps(admin_menu, ensure_ascii=False, indent=2) + '\n')
    # The isolated docroot intentionally has no stock cgi-exec endpoint.
    # Use the existing authenticated, command-scoped ubus file.exec instead.
    syslog = stage / 'www/luci-static/resources/view/status/syslog.js'
    syslog.write_text(syslog.read_text().replace(
        "fs.exec_direct('/usr/bin/tail',['-n','100','/logfs/syslog'])",
        "fs.exec('/usr/bin/tail',['-n','100','/logfs/syslog']).then(function(r){if(r.code!==0)throw new Error('无法读取系统日志');return r.stdout||'';})"))
    # LuCI uses this resource version for every dynamically loaded JS module.
    # Give local changes their own version so a normal refresh gets the new view.
    resources_for_hash = [SOURCE / 'admin.js', SOURCE / 'topflow.js', *sorted((SOURCE / 'views').glob('*.js'))]
    resource_hash = hashlib.sha256(b''.join(p.read_bytes() for p in resources_for_hash) + syslog.read_bytes()).hexdigest()[:12]
    header = stage / 'usr/share/ucode/luci/template/header.ut'
    header.write_text(header.read_text().replace('git-25.222.75657-7ce34fe',
        'git-25.222.75657-7ce34fe-mu5252-' + resource_hash))
    acl_dir = BUNDLE / 'acl'
    acl_dir.mkdir()
    for filename, data in trial_acl.items():
        data = {k: v for k, v in data.items() if k not in ['luci-mod-status-channel_analysis', 'luci-mod-status-firewall']}
        if filename == 'luci-trial-read.json':
            data['luci-trial-read']['read']['ubus']['luci'].append('getTopflowStatus')
        name = filename.replace('luci-trial-', 'luci-readonly-')
        if name == 'luci-readonly-luci-mod-status.json': name = 'luci-readonly-status.json'
        (acl_dir / name).write_text(json.dumps(data, indent=2) + '\n')
    admin_acl = {'luci-device-admin': {'description': 'MU5252 administrator',
        'read': {'ubus': {'luci': ['getAdminNetwork', 'getAdminServices', 'getAdminJob'], 'mihomo.api': ['status']}},
        'write': {'ubus': {'luci': writes, 'system': ['reboot'], 'mihomo.api': ['proxy_mode_set']}}}}
    (acl_dir / 'luci-readonly-admin.json').write_text(json.dumps(admin_acl, indent=2) + '\n')
    for name in ['run-namespace.sh', 'firewall.sh', 'luci-readonly.init', 'diagnostic.sh', 'service-action.sh']:
        shutil.copy2(SOURCE / name, BUNDLE / name)
        (BUNDLE / name).chmod(0o755)
    tar_bundle(BUNDLE, output / 'bundle.tar.gz')
    files = sorted(p for p in BUNDLE.rglob('*') if p.is_file() and not p.is_symlink())
    (output / 'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + str(p.relative_to(BUNDLE)) + '\n' for p in files))
    print('Built administrator bundle: ' + str(output / 'bundle.tar.gz'))
    return BUNDLE


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=DEFAULT_OUT)
    parser.add_argument('--cache', type=Path, default=DEFAULT_OUT / 'packages')
    parser.add_argument('--offline', action='store_true')
    options = parser.parse_args()
    build(options.output.resolve(), options.cache.resolve(), options.offline)
