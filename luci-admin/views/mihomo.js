'use strict';
'require view';
'require topflow.admin as admin';
return view.extend({ load: admin.call('status',[],'mihomo.api'), render: function(data) {
    const enabled=admin.check(data.autostart_enabled),mode=E('select',{'class':'cbi-input-select'},[['rule','规则'],['global','全局'],['direct','直连']].map(function(v){return E('option',{value:v[0],selected:data.proxy_mode===v[0]},v[1]);}));
    return E('div',{},[E('h2',{},'Mihomo'),admin.section('代理服务',[
        admin.row('运行状态',E('span',{},data.service_running?'运行中':'已停止')),admin.row('核心版本',E('span',{},data.version || '未知')),
        admin.row('开机启动',enabled),admin.button('保存自启设置',function(){return admin.apply(admin.call('setAdminService',['name','action'])('mihomo-netns',enabled.checked?'enable':'disable'));}),
        admin.row('代理模式',mode),admin.button('应用代理模式',function(){return admin.apply(admin.call('proxy_mode_set',['mode'],'mihomo.api')(mode.value));},true),
        E('p',{},'启动会同时启用开机启动；停止会同时取消开机启动。重启或停止代理可能中断正在使用代理的连接。'),
        E('div',{},[['start','启动'],['restart','重启'],['stop','停止']].map(function(v){return admin.button(v[1],function(){admin.confirm(v[1]+' Mihomo','确认'+v[1]+'代理服务？',function(){return admin.apply(admin.call('setMihomoService',['action'])(v[0]),true);});});})),
        admin.button('刷新状态',function(){window.location.reload();})])]);
},handleSaveApply:null,handleSave:null,handleReset:null});
