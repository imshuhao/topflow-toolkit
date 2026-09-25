// B22-specific administration. Only these semantic operations are exported.
import { mkstemp } from 'fs';
const adminBus = connect();

function actionLock() {
    return system('mkdir -p /tmp/luci-admin-action; chmod 700 /tmp/luci-admin-action; mkdir /tmp/luci-admin-action/lock 2>/dev/null') == 0;
}
function startAction(name, action) {
    const f = open('/tmp/luci-admin-action/state.json', 'w');
    f.write(sprintf('%J', { state: 'running', started: time() })); f.close();
    if (system('/sbin/start-stop-daemon -S -b -x /data/local/luci-readonly/service-action.sh -- ' + shellquote(name) + ' ' + shellquote(action)) != 0) {
        system('rmdir /tmp/luci-admin-action/lock');
        return { ok: false, error: '无法启动服务操作' };
    }
    return { ok: true, pending: true };
}
methods.getAdminJob = { call: function() {
    const raw = readfile('/tmp/luci-admin-action/state.json');
    try { return raw ? json(raw) : { state: 'idle' }; }
    catch (e) { return { state: 'running' }; }
}};

function inputCommand(command, content) {
    const f = mkstemp('/tmp/luci-admin');
    if (!f) return null;
    f.write(content); f.flush();
    const path = `/proc/${readlink('/proc/self')}/fd/${f.fileno()}`;
    const p = popen(command + ' < ' + shellquote(path) + ' 2>/dev/null', 'r');
    const output = p?.read('all');
    const code = p?.close(); f.close();
    return code == 0 ? output : null;
}

function control(action, params) {
    const raw = inputCommand('/usr/bin/curl --noproxy "*" -sS --max-time 18 -H "Content-Type: application/json" --data-binary @- http://127.0.0.1:9460/control', sprintf('%J', { action, params }));
    try {
        const result = raw ? json(raw) : { ok: false, error: '设备控制接口未响应，请刷新检查当前状态' };
        if (type(result.error) == 'object') result.error = result.error.message ?? '设备操作失败';
        return result;
    }
    catch (e) { return { ok: false, error: '设备返回了无效响应' }; }
}

function telemetry() {
    const p = popen('/usr/bin/curl --noproxy "*" -fsS --max-time 3 http://127.0.0.1:9460/state 2>/dev/null', 'r');
    const raw = p?.read('all'); const rc = p?.close();
    try { return rc == 0 ? json(raw) : null; } catch (e) { return null; }
}

methods.getAdminNetwork = { call: function() {
    const u = cursor(), wifi = [];
    for (let name in ['main_2g', 'main_5g']) {
        const s = u.get_all('wireless', name);
        if (s) push(wifi, { section: name, ssid: s.ssid, enabled: s.disabled != '1', radio_enabled: u.get('wireless', s.device, 'disabled') != '1',
            encryption: s.encryption, hidden: s.hidden == '1', has_key: length(s.key ?? '') > 0 });
    }
    const state = telemetry();
    const members = [];
    u.foreach('mwan3', 'member', s => {
        if (match(s.interface ?? '', /^zte_mwan[234](_6)?$/))
            push(members, { section: s['.name'], interface: s.interface,
                metric: +(s.metric ?? 1), weight: +(s.weight ?? 1) });
    });
    const modems = [];
    for (let m in state?.modems ?? []) {
        const s = adminBus.call('network.interface.' + m.wan_interface, 'status', {});
        const s6 = adminBus.call('network.interface.' + m.wan_interface + '_6', 'status', {});
        push(modems, { id: m.id, wan_interface: m.wan_interface, up: s?.up,
            ipv6_up: s6?.up, pending: s?.pending, status: m.wwan?.status, operator: m.net?.operator,
            network: m.net?.type, band: m.net?.band, bars: m.net?.bars });
    }
    return { wifi, members, modems, mode: state?.multiwan?.mode, available: state != null };
}};

methods.setWifi = { args: { section: '', ssid: '', key: '', enabled: true, hidden: false }, call: function(r) {
    const a = r.args;
    if (index(['main_2g', 'main_5g'], a.section) < 0 || length(a.ssid) < 1 || length(a.ssid) > 32 || match(a.ssid, /[[:cntrl:]]/))
        return { ok: false, error: '无线名称须为 1–32 字节，且不能含控制字符' };
    if (length(a.key) && (length(a.key) < 8 || length(a.key) > 63 || match(a.key, /[[:cntrl:]]/)))
        return { ok: false, error: '无线密码须为 8–63 字节' };
    const params = { section: a.section, ssid: a.ssid, enabled: a.enabled ? 1 : 0, hidden: a.hidden ? '1' : '0' };
    if (length(a.key)) params.key = a.key;
    return control('wifi.configure', params);
}};

methods.setMultiwanMember = { args: { section: '', metric: 0, weight: 0 }, call: function(r) {
    const a = r.args, u = cursor(), s = u.get_all('mwan3', a.section);
    if (s?.['.type'] != 'member' || !match(s.interface ?? '', /^zte_mwan[234](_6)?$/) || a.metric < 1 || a.metric > 256 || a.weight < 1 || a.weight > 1000)
        return { ok: false, error: '无效的线路、优先级或权重' };
    if (!actionLock()) return { ok: false, error: '上一个服务操作尚未结束，请稍后再试' };
    if (!u.set('mwan3', a.section, 'metric', '' + a.metric) || !u.set('mwan3', a.section, 'weight', '' + a.weight) || !u.commit('mwan3')) {
        system('rmdir /tmp/luci-admin-action/lock');
        return { ok: false, error: '保存 MultiWAN 设置失败' };
    }
    if (u.get('zwrt_router', 'network', 'opms_wan_mode') != 'MULTIWAN') {
        system('rmdir /tmp/luci-admin-action/lock');
        return { ok: true, result: { applied: false } };
    }
    // The datad restart deadline is too short for B22. Track the full init action.
    return startAction('mwan3', 'restart');
}};

methods.setCellularLink = { args: { modem: '', enabled: true }, call: function(r) {
    const interfaces = { x75: 'zte_mwan2', v3e1: 'zte_mwan3', v3e2: 'zte_mwan4' };
    const iface = interfaces[r.args.modem];
    if (!iface) return { ok: false, error: '未知基带' };
    const action = r.args.enabled ? 'up' : 'down';
    adminBus.call('network.interface.' + iface, action, {});
    const a = adminBus.error(true);
    adminBus.call('network.interface.' + iface + '_6', action, {});
    const b = adminBus.error(true);
    // netifd intentionally returns no body on successful up/down operations.
    return { ok: !a && !b, error: a || b ? '部分接口操作失败，请刷新状态' : null };
}};

methods.getAdminServices = { call: function() {
    const running = adminBus.call('service', 'list', {}) ?? {}, services = [];
    for (let name in init_list()) {
        const instances = running[name]?.instances ?? {};
        const known = length(instances) > 0;
        push(services, { name, enabled: init_enabled(name),
            running: known ? length(filter(values(instances), i => i.running)) > 0 : null });
    }
    return { services };
}};

methods.setAdminService = { args: { name: '', action: '' }, call: function(r) {
    const a = r.args;
    if (!match(a.name, /^[A-Za-z0-9_.-]+$/) || index(init_list(), a.name) < 0 || index(['start', 'stop', 'restart', 'reload', 'enable', 'disable'], a.action) < 0)
        return { ok: false, error: '无效的服务操作' };
    if (!actionLock()) return { ok: false, error: '上一个服务操作尚未结束，请稍后再试' };
    return startAction(a.name, a.action);
}};

methods.setMihomoService = { args: { action: '' }, call: function(r) {
    if (index(['start', 'stop', 'restart'], r.args.action) < 0) return { ok: false, error: '未知代理操作' };
    if (!actionLock()) return { ok: false, error: '上一个服务操作尚未结束，请稍后再试' };
    return startAction('mihomo-manager', 'service-' + r.args.action);
}};

methods.runDiagnostic = { args: { kind: '', host: '' }, call: function(r) {
    const a = r.args;
    if (length(a.host) < 1 || length(a.host) > 253 || !match(a.host, /^[A-Za-z0-9][A-Za-z0-9.:-]*$/))
        return { ok: false, error: '请输入域名或 IP 地址' };
    if (index(['ping', 'traceroute', 'nslookup'], a.kind) < 0) return { ok: false, error: '未知诊断工具' };
    const p = popen('/data/local/luci-readonly/diagnostic.sh ' + shellquote(a.kind) + ' ' + shellquote(a.host) + ' 2>&1', 'r');
    const output = p?.read('all'), code = p?.close();
    return { ok: code == 0, code, output: substr(output ?? '', 0, 24000) };
}};

methods.setLoginPassword = { args: { current: '', password: '' }, call: function(r) {
    const a = r.args;
    const session = adminBus.call('session', 'get', { ubus_rpc_session: a.ubus_rpc_session });
    if (session?.values?.username != 'luci') return { ok: false, error: '请使用 luci 管理员登录' };
    if (length(a.password) < 8 || length(a.password) > 128 || match(a.password, /[[:cntrl:]]/))
        return { ok: false, error: '密码须为 8–128 字节，且不能含控制字符' };
    const auth = adminBus.call('session', 'login', { username: 'luci', password: a.current, timeout: 10 });
    if (!auth?.ubus_rpc_session) return { ok: false, error: '当前密码不正确' };
    adminBus.call('session', 'destroy', { ubus_rpc_session: auth.ubus_rpc_session });
    const hash = trim(inputCommand('/usr/bin/openssl passwd -6 -stdin', a.password + '\n') ?? '');
    if (!match(hash, /^\$6\$/)) return { ok: false, error: '密码加密失败' };
    const u = cursor();
    if (u.get('rpcd', 'luci_readonly', 'username') != 'luci' || !u.set('rpcd', 'luci_readonly', 'password', hash) || !u.commit('rpcd'))
        return { ok: false, error: '保存密码失败' };
    // Password rotation invalidates every existing login for this account.
    // The B22 ucode binding uses boolean true for multiple replies.
    const sessions = adminBus.call('session', 'list', {}, true) ?? [];
    for (let s in sessions)
        if (s.data?.username == 'luci') adminBus.call('session', 'destroy', { ubus_rpc_session: s.ubus_rpc_session });
    return { ok: true };
}};
