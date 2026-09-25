'use strict';
'require view';
'require topflow.admin as admin';
return view.extend({ render: function() {
    const host = admin.input('www.baidu.com'), output = E('pre', { style: 'white-space:pre-wrap;overflow-wrap:anywhere;min-height:10em' });
    const run = admin.call('runDiagnostic', ['kind','host']);
    return E('div', {}, [E('h2', {}, '网络诊断'), admin.row('域名或 IP 地址', host),
        E('div', {}, [['ping','Ping'],['traceroute','路由追踪'],['nslookup','DNS 查询']].map(function(item) {
            return admin.button(item[1], async function() { output.textContent = '正在运行…'; const r = await run(item[0],host.value.trim()); output.textContent = r.output || r.error || '无输出'; });
        })), output]);
}, handleSaveApply: null, handleSave: null, handleReset: null });
