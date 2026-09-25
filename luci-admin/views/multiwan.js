'use strict';
'require view';
'require topflow.admin as admin';
return view.extend({ load: admin.network, render: function(data) {
    const save = admin.call('setMultiwanMember',['section','metric','weight']);
    return E('div', {}, [E('h2',{},'MultiWAN'), E('p',{},'当前模式：' + (data.mode || '未知') + '。优先级数字越小越优先；同优先级按权重分配新连接。IPv4 与 IPv6 分别设置。')].concat((data.members || []).map(function(m) {
        const metric=admin.input(m.metric,'number'), weight=admin.input(m.weight,'number');metric.min=weight.min=1;metric.max=256;weight.max=1000;
        const id={zte_mwan2:'x75',zte_mwan3:'v3e1',zte_mwan4:'v3e2'}[m.interface.replace(/_6$/,'')];
        return admin.section((admin.names[id] || m.interface) + (/_6$/.test(m.interface)?' · IPv6':' · IPv4'),[
            admin.row('优先级',metric),admin.row('权重',weight),admin.button('应用设置',async function(){
                const r=await admin.apply(save(m.section,Number(metric.value),Number(weight.value)));
                if(r.result && r.result.applied===false) throw new Error('已保存；当前模式不使用 MultiWAN，运行状态未改变');
            },true)]);
    })));
}, handleSaveApply: null, handleSave: null, handleReset: null });
