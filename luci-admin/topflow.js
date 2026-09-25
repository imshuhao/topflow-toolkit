'use strict';
'require view';
'require rpc';
'require poll';
'require dom';
'require view.status.include.10_system as systemInfo';
'require view.status.include.20_memory as memoryInfo';
'require view.status.include.25_storage as storageInfo';

var readStatus = rpc.declare({ object: 'luci', method: 'getTopflowStatus', expect: {} });
var known = function(v) { return v == null || v === '' ? '未知' : String(v); };
var boolean = function(v) { return v == null ? '未知' : v ? '已启用' : '未启用'; };
var unit = function(v, u) { return v == null ? '未知' : v + u; };
var labels = { x75: 'X75 · 内置 5G', v3e1: 'V3E1 · 扩展 4G', v3e2: 'V3E2 · 扩展 4G' };
var connection = { ipv4_ipv6_connected: 'IPv4 / IPv6 已连接', ipv4_connected: 'IPv4 已连接',
    ipv6_connected: 'IPv6 已连接', disconnected: '未连接' };
var health = { online: '在线', offline: '离线', disabled: '未启用' };
function table(rows) {
    return E('table', { 'class': 'table' }, rows.map(function(r) {
        return E('tr', { 'class': 'tr' }, [E('td', { 'class': 'td', 'width': '35%' }, r[0]), E('td', { 'class': 'td' }, known(r[1]))]);
    }));
}
function systemContent(data) {
    var nativeData = data.system.slice();
    var board = nativeData[0] || {};
    var s = data.device || {};
    var device = s.device || {}, sys = s.system || {};
    nativeData[0] = Object.assign({}, board);
    if (s.available && device.model)
        nativeData[0].model = device.model;
    var result = systemInfo.render(nativeData);
    if (s.available) {
        var extraRows = table([
            ['硬件版本', device.hardware],
            ['硬件平台', board.model],
            ['厂商固件', sys.firmware],
            ['CPU 使用率', unit(sys.cpu_usage, '%')],
            ['CPU 温度', unit(sys.cpu_temp, ' °C')]
        ]);
        while (extraRows.firstChild)
            result.appendChild(extraRows.firstChild);
    }
    return result;
}
function deviceContent(s) {
    if (!s || !s.available)
        return [E('div', { 'class': 'alert-message warning' }, '设备状态暂时不可用，正在重试。')];
    var mw = s.multiwan || {}, wifi = s.wlan || {}, ag = s.aggregation || {};
    var nodes = [E('h3', {}, '三路蜂窝网络')];
    var rows = [E('tr', { 'class': 'tr table-titles' }, ['基带', '接口', '运营商 / 制式', '连接状态', '频段', 'MultiWAN 健康'].map(function(h) {
        return E('th', { 'class': 'th' }, h);
    }))];
    (s.modems || []).forEach(function(m) {
        rows.push(E('tr', { 'class': 'tr' }, [labels[m.id] || known(m.id), known(m.ifname),
            known(m.operator) + ' / ' + known(m.network), connection[m.connection] || known(m.connection),
            known(m.band), mw.health_available ? (health[m.health] || known(m.health)) : '暂时不可用'
        ].map(function(v) { return E('td', { 'class': 'td' }, v); })));
    });
    nodes.push(E('div', { 'style': 'overflow-x:auto' }, E('table', { 'class': 'table' }, rows)));
    nodes.push(E('h3', {}, 'Wi-Fi 与多线路'), table([
        ['Wi-Fi', boolean(wifi.enabled)], ['网络名称', wifi.ssid],
        ['当前模式', mw.mode === 'MULTIWAN' ? 'MultiWAN 多线路负载均衡' : mw.mode],
        ['MultiWAN 服务', mw.service_running == null ? null : mw.service_running ? '运行中' : '未运行'],
        ['聚合隧道', ag.enabled == null ? null : ag.enabled ? (ag.online ? '在线' : '未连接') : '未启用']
    ]));
    var age = s.ts == null ? null : Math.max(0, Math.floor(Date.now() / 1000 - s.ts));
    nodes.push(E('p', { 'class': age == null || age > 30 ? 'alert-message warning' : '' },
        age == null ? '更新时间未知' : age > 30 ? '设备状态已超过 30 秒未更新，请检查状态服务。' : '每 5 秒刷新 · 最近更新于 ' + new Date(s.ts * 1000).toLocaleTimeString()));
    return nodes;
}
function loadOverview() {
    return Promise.all([
        readStatus().catch(function() { return { available: false }; }),
        systemInfo.load(), memoryInfo.load(), storageInfo.load()
    ]).then(function(data) {
        return { device: data[0], system: data[1], memory: data[2], storage: data[3] };
    });
}
function content(data) {
    // Preserve the native LuCI widgets and their data semantics. Device-specific
    // telemetry is an addition and cannot hide system information if unavailable.
    return [
        E('div', { 'class': 'cbi-section', 'id': 'overview-system' }, [
            E('h3', {}, systemInfo.title), systemContent(data)
        ]),
        E('div', { 'class': 'cbi-section', 'id': 'overview-memory' }, [
            E('h3', {}, memoryInfo.title), memoryInfo.render(data.memory)
        ]),
        E('div', { 'class': 'cbi-section', 'id': 'overview-storage' }, [
            E('h3', {}, storageInfo.title), storageInfo.render(data.storage)
        ]),
        E('div', { 'class': 'cbi-section', 'id': 'overview-device' }, deviceContent(data.device))
    ];
}
return view.extend({
    load: loadOverview,
    render: function(data) {
        var body = E('div', {}, content(data));
        poll.add(function() {
            return loadOverview().then(function(next) { dom.content(body, content(next)); });
        }, 5);
        return E('div', {}, [E('h2', {}, 'MU5252 状态'), E('p', {}, '查看设备状态、日志与实时流量；通过系统、网络和服务菜单管理设备。'), body]);
    },
    handleSaveApply: null, handleSave: null, handleReset: null
});
