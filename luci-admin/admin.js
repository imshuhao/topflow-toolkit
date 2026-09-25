'use strict';
'require rpc';
'require ui';
'require baseclass';

function call(method, params, object) {
    return rpc.declare({ object: object || 'luci', method: method, params: params || [], reject: true });
}
function input(value, type) { return E('input', { 'class': 'cbi-input-text', type: type || 'text', value: value == null ? '' : value }); }
function check(value) { return E('input', { type: 'checkbox', checked: !!value }); }
let fieldIndex = 0;
function row(label, control, help) {
    const id = 'mu5252-field-' + (++fieldIndex); control.id = id;
    return E('div', { 'class': 'cbi-value' }, [E('label', { 'class': 'cbi-value-title', 'for': id }, label),
        E('div', { 'class': 'cbi-value-field' }, [control, help ? E('div', { 'class': 'cbi-value-description' }, help) : ''])]);
}
function section(title, children) { return E('div', { 'class': 'cbi-section' }, [E('h3', {}, title)].concat(children)); }
function button(label, action, primary) {
    return E('button', { 'class': 'cbi-button ' + (primary ? 'cbi-button-apply' : 'cbi-button-action'),
        click: ui.createHandlerFn(null, action) }, label);
}
function confirm(title, text, action) {
    ui.showModal(title, [E('p', {}, text), E('div', { 'class': 'right' }, [
        button('取消', function() { ui.hideModal(); }), ' ',
        button('确认', async function() { ui.hideModal(); await action(); }, true)])]);
}
async function apply(promise, refresh) {
    let result = await promise;
    if (result.ok === false || result.error || result.result === false)
        throw new Error(typeof result.error === 'string' ? result.error : '操作失败，请检查设备状态');
    if (result.pending) {
        ui.showModal('正在应用', [E('p', { 'class': 'spinning' }, '正在等待服务完成操作…')]);
        try {
            const job = call('getAdminJob');
            for (let i = 0; i < 90; i++) {
                await new Promise(function(resolve) { window.setTimeout(resolve, 1000); });
                result = await job();
                if (result.state === 'done' || result.state === 'failed') break;
            }
            if (result.state !== 'done') throw new Error(result.error || '服务操作仍在进行，请稍后刷新检查');
        } finally { ui.hideModal(); }
    }
    ui.addNotification(null, E('p', {}, '设置已应用。'), 'info');
    if (refresh) window.location.reload();
    return result;
}
return baseclass.extend({ call: call, input: input, check: check, row: row, section: section, button: button, confirm: confirm, apply: apply,
    network: call('getAdminNetwork'), names: { x75: 'X75 主基带', v3e1: 'V3E 1', v3e2: 'V3E 2' } });
