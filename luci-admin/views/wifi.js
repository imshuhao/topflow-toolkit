'use strict';
'require view';
'require topflow.admin as admin';
return view.extend({ load: admin.network, render: function(data) {
    const save = admin.call('setWifi', ['section','ssid','key','enabled','hidden']);
    return E('div', {}, [E('h2', {}, '无线网络'), E('p', {}, '分别设置 2.4 GHz 和 5 GHz。密码留空表示保留原密码；应用设置时无线连接可能暂时断开。')].concat((data.wifi || []).map(function(w) {
        const ssid = admin.input(w.ssid), key = admin.input('', 'password'), enabled = admin.check(w.enabled), hidden = admin.check(w.hidden);
        key.autocomplete = 'new-password';
        return admin.section(w.section === 'main_2g' ? '2.4 GHz' : '5 GHz', [admin.row('频段状态',E('span',{},w.radio_enabled?'已开启':'未开启')),
            admin.row('启用此网络',enabled,w.radio_enabled?'':'此频段当前未开启；保存名称和密码不会自动开启频段。'), admin.row('无线名称',ssid), admin.row('无线密码',key,'留空保留，修改时为 8–63 字节'),
            admin.row('隐藏网络',hidden), admin.row('加密方式',E('span',{},w.encryption || '未知')),
            admin.button('应用设置', function() { admin.confirm('应用无线设置', '当前无线连接可能断开。更改名称或密码后，请用新设置重新连接。', async function() {
                await admin.apply(save(w.section,ssid.value,key.value,enabled.checked,hidden.checked)); key.value = '';
            }); }, true)]);
    })));
}, handleSaveApply: null, handleSave: null, handleReset: null });
