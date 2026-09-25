'use strict';
'require view';
'require topflow.admin as admin';
return view.extend({ load: admin.network, render: function(data) {
    const set = admin.call('setCellularLink', ['modem','enabled']);
    return E('div', {}, [E('h2', {}, '移动网络'), E('p', {}, '分别连接或断开三路基带的 IPv4 / IPv6 联网接口。操作后稍等片刻，再刷新查看状态。'),
        admin.button('刷新状态',function(){window.location.reload();})].concat((data.modems || []).map(function(m) {
        return admin.section(admin.names[m.id] || m.id, [admin.row('联网接口',E('span',{},m.wan_interface)), admin.row('IPv4',E('span',{},m.up ? '已连接' : m.pending ? '正在连接' : '已断开')),
            admin.row('IPv6',E('span',{},m.ipv6_up?'已连接':'未连接')),
            admin.row('运营商',E('span',{},m.operator || '未知')), admin.row('网络 / 频段',E('span',{},(m.network || '—') + ' / ' + (m.band || '—'))),
            admin.button('连接',function(){return admin.apply(set(m.id,true));},true), ' ',
            admin.button('断开',function(){admin.confirm('断开 ' + (admin.names[m.id] || m.id), '该线路承载的连接可能中断，其他线路继续工作。',function(){return admin.apply(set(m.id,false));});})]);
    })));
}, handleSaveApply: null, handleSave: null, handleReset: null });
