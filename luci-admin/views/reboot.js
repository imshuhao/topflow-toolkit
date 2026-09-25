'use strict';
'require view';
'require ui';
'require topflow.admin as admin';
return view.extend({ render: function() {
    const reboot = admin.call('reboot', [], 'system');
    return E('div', {}, [E('h2', {}, '重启设备'), E('p', {}, '重启期间无线网络和三路移动网络会暂时断开，设备启动后自动恢复。'),
        admin.button('重启设备', function() { admin.confirm('重启设备', '现在重启 MU5252？', async function() {
            await reboot(); ui.showModal('正在重启', [E('p', { 'class': 'spinning' }, '请等待设备重新连接。')]);
            ui.awaitReconnect(window.location.host);
        }); }, true)]);
}, handleSaveApply: null, handleSave: null, handleReset: null });
