'use strict';
'require view';
'require topflow.admin as admin';
return view.extend({
    load: admin.call('getAdminServices'),
    render: function(data) {
        const action = admin.call('setAdminService', ['name', 'action']);
        const rows = (data.services || []).sort(function(a,b) { return a.name.localeCompare(b.name); }).map(function(s) {
            return E('tr', { 'class': 'tr' }, [E('td', { 'class': 'td' }, s.name), E('td', { 'class': 'td' }, s.enabled ? '已启用' : '未启用'),
                E('td', { 'class': 'td' }, s.running == null ? '未提供进程状态' : s.running ? '运行中' : '已停止'),
                E('td', { 'class': 'td' }, [['start','启动'],['stop','停止'],['restart','重启'],[s.enabled?'disable':'enable',s.enabled?'取消自启':'启用自启']].map(function(item) {
                    return admin.button(item[1], function() { admin.confirm(item[1] + ' ' + s.name,
                        '此操作会改变服务状态；操作网络或管理服务时可能暂时断开连接。', function() { return admin.apply(action(s.name, item[0]), true); }); });
                }))]);
        });
        const filter = admin.input(''); filter.placeholder = '筛选服务名称';
        filter.addEventListener('input', function() { rows.forEach(function(r) { r.style.display = r.firstChild.textContent.indexOf(filter.value) >= 0 ? '' : 'none'; }); });
        return E('div', {}, [E('h2', {}, '服务管理'), E('p', {}, '管理设备现有服务。自启列表示服务启动标志；部分厂商服务由固件另行启动。'), filter,
            E('table', { 'class': 'table' }, [E('tr', { 'class': 'tr table-titles' }, ['服务','开机自启','进程状态','操作'].map(function(t) { return E('th', { 'class': 'th' }, t); }))].concat(rows))]);
    }, handleSaveApply: null, handleSave: null, handleReset: null
});
