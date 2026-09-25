// Only selected, non-secret fields leave the local telemetry service.
methods.getTopflowStatus = {
    call: function(request) {
        let p = popen('/usr/bin/curl --noproxy "*" -fsS --max-time 2 http://127.0.0.1:9460/state 2>/dev/null', 'r');
        let raw = p?.read('all');
        let rc = p?.close();
        let state;
        try { state = raw ? json(raw) : null; } catch (e) { state = null; }
        if (rc != 0 || type(state) != 'object')
            return { available: false, error: '设备状态暂时不可用' };
        let mp = popen('/bin/ubus -t 2 call mwan3 status 2>/dev/null', 'r');
        let mr = mp?.read('all');
        let mc = mp?.close();
        let mwan;
        try { mwan = mc == 0 && mr ? json(mr) : null; } catch (e) { mwan = null; }
        let modems = [];
        let wp = popen('/usr/sbin/iw dev 2>/dev/null', 'r');
        let wr = wp?.read('all');
        let wc = wp?.close();
        let radios = [], radio;
        for (let line in split(wr ?? '', '\n')) {
            let m = match(line, /^\s*Interface (.+)$/);
            if (m) { radio = { ifname: m[1] }; push(radios, radio); }
            if (!radio) continue;
            m = match(line, /^\s*ssid (.+)$/);
            if (m) radio.ssid = m[1];
            m = match(line, /^\s*type (.+)$/);
            if (m) radio.type = m[1];
            m = match(line, /^\s*channel ([0-9]+)/);
            if (m) radio.channel = m[1];
        }
        radios = filter(radios, r => r.type == 'AP');
        for (let m in state.modems ?? []) {
            let health = mwan?.interfaces?.[m.wan_interface];
            push(modems, {
                id: m.id, ifname: m.ifname, wan_interface: m.wan_interface,
                connection: m.wwan?.status, operator: m.net?.operator,
                network: m.net?.type, band: m.net?.band, bars: m.net?.bars,
                health: health?.status, tracking: health?.tracking
            });
        }
        return {
            available: true, ts: state.ts,
            device: { model: state.device?.model_name, hardware: state.device?.hardware_version },
            system: { firmware: state.system?.sw_version, openwrt: state.system?.fw,
                uptime: state.system?.uptime, cpu_temp: state.system?.cpu_temp,
                cpu_usage: state.system?.cpu_usage, memory_used: state.system?.mem_used_pct },
            wlan: { enabled: wc == 0 ? length(radios) > 0 : null,
                ssid: wc == 0 ? join(' / ', map(radios, r => r.ssid ?? '未知')) : null,
                interfaces: radios },
            multiwan: { active: state.multiwan?.active, mode: state.multiwan?.mode,
                service_running: state.multiwan?.service_running, health_available: mwan != null },
            aggregation: { enabled: state.aggregation?.enabled, online: state.aggregation?.online },
            modems
        };
    }
};
