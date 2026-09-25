'use strict';
'require view';
'require topflow.admin as admin';
return view.extend({
    render: function() {
        const current = admin.input('', 'password'), password = admin.input('', 'password'), repeat = admin.input('', 'password');
        current.autocomplete = 'current-password'; password.autocomplete = repeat.autocomplete = 'new-password';
        const save = admin.call('setLoginPassword', ['current', 'password']);
        return E('div', {}, [E('h2', {}, '登录密码'), E('p', {}, '修改 luci 管理员的登录密码。保存后需要重新登录。设备 root 密码保持不变。'),
            admin.section('luci 管理员', [admin.row('当前密码', current), admin.row('新密码', password, '8–128 字节'), admin.row('确认新密码', repeat),
                admin.button('保存密码', async function() {
                    if (password.value !== repeat.value) throw new Error('两次输入的新密码不一致');
                    if (new TextEncoder().encode(password.value).length < 8) throw new Error('新密码至少需要 8 字节');
                    await admin.apply(save(current.value, password.value));
                    current.value = password.value = repeat.value = '';
                    window.location.href = L.url('admin', 'logout');
                }, true)])]);
    }, handleSaveApply: null, handleSave: null, handleReset: null
});
