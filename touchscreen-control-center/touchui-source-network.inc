static int contains_text_ci(const char *text, const char *needle)
{
    size_t length;
    if (!text || !needle || !*needle) return 0;
    length = strlen(needle);
    for (; *text; text++)
        if (!strncasecmp(text, needle, length)) return 1;
    return 0;
}

static int collect_modem_status(const char *state, int index,
                                struct modem_status *status)
{
    static const char *ids[NETWORK_MODEM_COUNT] = {"x75", "v3e1", "v3e2"};
    char modem[16384], net[4096], traffic[2048], qos[1024], wwan[1024];
    char sim[2048], interfaces[8192], interface[4096], root_net[4096];
    char usb[1024], debug[1024], ca[1024];
    char thermal[8192], thermal_modem[1024], aggregation[16384], path[8192];
    char roaming[24] = "";
    char operate_mode[32] = "", wwan_status[32] = "";
    long nr_rsrp, nr_rsrq, nr_pci, mcc, mnc;
    int snr_valid = 0;

    memset(status, 0, sizeof(*status));
    if (index < 0 || index >= NETWORK_MODEM_COUNT) return 0;
    if (!modem_json_object(state, index, modem, sizeof(modem)) ||
        !json_object(modem, "net", net, sizeof(net))) return 0;
    json_string(modem, "ifname", status->ifname, sizeof(status->ifname));
    json_string(modem, "wan_interface", status->wan_interface,
                sizeof(status->wan_interface));
    json_string(modem, "transport", status->transport, sizeof(status->transport));
    json_string(net, "type", status->type, sizeof(status->type));
    json_string(net, "operator", status->operator_name, sizeof(status->operator_name));
    json_string(net, "band", status->band, sizeof(status->band));
    json_string(net, "bandwidth", status->bandwidth, sizeof(status->bandwidth));
    json_string(net, "plmn", status->plmn, sizeof(status->plmn));
    json_string(net, "mode", status->net_select, sizeof(status->net_select));
    json_string(net, "operate_mode", operate_mode, sizeof(operate_mode));
    status->bars = (int)json_long(net, "bars", 0);
    json_string(net, "roaming", roaming, sizeof(roaming));
    status->roaming = !strcasecmp(roaming, "roaming") ||
                      !strcasecmp(roaming, "roam") ||
                      !strcasecmp(roaming, "yes") ||
                      !strcmp(roaming, "1");
    nr_rsrp = json_long(net, "nr_rsrp", 0);
    nr_rsrq = json_long(net, "nr_rsrq", 0);
    nr_pci = json_long(net, "nr_pci", 0);
    if (nr_rsrp != 0) {
        status->rsrp = (int)nr_rsrp;
        status->rsrq = (int)nr_rsrq;
        status->pci = (int)nr_pci;
        status->channel = json_long(net, "nr_channel", 0);
        status->cell_id = json_ull(net, "nr_cell_id", 0);
        status->snr = json_double(net, "nr_snr", 0.0, &snr_valid);
    } else {
        status->rsrp = (int)json_long(net, "lte_rsrp", 0);
        status->rsrq = (int)json_long(net, "lte_rsrq", 0);
        status->rssi = (int)json_long(net, "lte_rssi", 0);
        status->pci = (int)json_long(net, "lte_pci", 0);
        status->channel = json_long(net, "channel", 0);
        status->cell_id = json_ull(net, "cell_id", 0);
        status->snr = json_double(net, "lte_snr", 0.0, &snr_valid);
    }
    if (!snr_valid) status->snr = 0.0;

    if (index == 0 && json_object(state, "net", root_net, sizeof(root_net))) {
        status->rssi = (int)json_long(root_net, "nr_rssi",
                                     json_long(root_net, "rssi", 0));
        if (!status->bandwidth[0])
            json_string(root_net, "nr_bw", status->bandwidth,
                        sizeof(status->bandwidth));
        mcc = json_long(root_net, "mcc", 0);
        mnc = json_long(root_net, "mnc", -1);
        if (mcc > 0 && mnc >= 0)
            snprintf(status->plmn, sizeof(status->plmn), "%03u-%02u",
                     (unsigned int)mcc, (unsigned int)mnc);
        json_string(root_net, "net_select", status->net_select,
                    sizeof(status->net_select));
        if (json_string(root_net, "nrca", ca, sizeof(ca)) && ca[0]) {
            safe_copy(status->ca_type, sizeof(status->ca_type), "NR");
            status->ca_carriers = ca_carrier_count(ca);
        } else if (json_string(root_net, "lteca", ca, sizeof(ca)) && ca[0]) {
            safe_copy(status->ca_type, sizeof(status->ca_type), "LTE");
            status->ca_carriers = ca_carrier_count(ca);
        }
    }

    if (json_object(modem, "sim", sim, sizeof(sim))) {
        status->sim_slot = (int)json_long(sim, "slot", 0);
        /* X75 numbers pSIM/eSIM as 1/2; both V3E modems use 0/1. */
        if ((index == 0 && status->sim_slot == 2) ||
            (index > 0 && status->sim_slot == 1))
            safe_copy(status->sim_type, sizeof(status->sim_type), "esim");
        else if ((index == 0 && status->sim_slot == 1) ||
                 (index > 0 && status->sim_slot == 0))
            safe_copy(status->sim_type, sizeof(status->sim_type), "psim");
        json_string(sim, "state", status->sim_state, sizeof(status->sim_state));
        json_string(sim, "iccid", status->iccid, sizeof(status->iccid));
        json_string(sim, "imsi", status->imsi, sizeof(status->imsi));
        json_string(sim, "msisdn", status->msisdn, sizeof(status->msisdn));
        json_string(sim, "imei", status->imei, sizeof(status->imei));
        status->sim_ready = contains_text_ci(status->sim_state, "ready") ||
                            contains_text_ci(status->sim_state, "complete");
    }
    if (json_object(modem, "interfaces", interfaces, sizeof(interfaces))) {
        if (json_object(interfaces, "ipv4", interface, sizeof(interface))) {
            status->ipv4_up = json_bool(interface, "up", 0);
            json_string(interface, "device", status->ipv4_device,
                        sizeof(status->ipv4_device));
            json_string(interface, "address", status->ipv4_address,
                        sizeof(status->ipv4_address));
            status->ipv4_mask = json_long(interface, "mask", 0);
            json_string_array_join(interface, "dns", status->ipv4_dns,
                                   sizeof(status->ipv4_dns));
        }
        if (json_object(interfaces, "ipv6", interface, sizeof(interface))) {
            status->ipv6_up = json_bool(interface, "up", 0);
            json_string(interface, "device", status->ipv6_device,
                        sizeof(status->ipv6_device));
            json_string(interface, "address", status->ipv6_address,
                        sizeof(status->ipv6_address));
            status->ipv6_mask = json_long(interface, "mask", 0);
            json_string_array_join(interface, "dns", status->ipv6_dns,
                                   sizeof(status->ipv6_dns));
        }
    }
    if (json_object(modem, "traffic", traffic, sizeof(traffic))) {
        status->rx_rate = json_ull(traffic, "rx_speed", 0);
        status->tx_rate = json_ull(traffic, "tx_speed", 0);
        status->max_rx_rate = json_ull(traffic, "max_rx_speed", 0);
        status->max_tx_rate = json_ull(traffic, "max_tx_speed", 0);
        status->rx_bytes = json_ull(traffic, "rx_bytes", 0);
        status->tx_bytes = json_ull(traffic, "tx_bytes", 0);
        status->session_time = json_ull(traffic, "session_time", 0);
    }
    if (json_object(modem, "qos", qos, sizeof(qos))) {
        status->qci = (int)json_long(qos, "qci", 0);
        status->ambr_dl = json_double(qos, "ambr_dl", 0.0, &status->ambr_dl_valid);
        status->ambr_ul = json_double(qos, "ambr_ul", 0.0, &status->ambr_ul_valid);
        status->qos_sampled_at = json_ull(qos, "sampled_at", 0);
    }
    if (json_object(modem, "wwan", wwan, sizeof(wwan)))
        json_string(wwan, "status", wwan_status, sizeof(wwan_status));

    if (json_object(state, "thermal", thermal, sizeof(thermal)) &&
        json_object_by_id(thermal, ids[index], thermal_modem,
                          sizeof(thermal_modem)) &&
        json_bool(thermal_modem, "available", 0)) {
        status->temperature = (int)json_long(thermal_modem, "celsius", 0);
        status->temperature_valid = 1;
    }
    if (json_object(state, "aggregation", aggregation, sizeof(aggregation)) &&
        json_object_by_id(aggregation, ids[index], path, sizeof(path))) {
        status->path_valid = 1;
        status->path_online = json_bool(path, "online", 0);
        status->path_latency = json_double(path, "latency_ms", 0.0,
                                           &status->path_latency_valid);
        status->path_loss = json_double(path, "packet_loss_percent", 0.0,
                                        &status->path_loss_valid);
        status->path_uptime = json_ull(path, "uptime_seconds", 0);
        parse_path_targets(path, status);
    }
    if (json_object(modem, "usb", usb, sizeof(usb))) {
        status->usb_present = json_bool(usb, "present", 0);
        status->usb_carrier = (int)json_long(usb, "carrier", 0);
        json_string(usb, "path", status->usb_path, sizeof(status->usb_path));
        json_string(usb, "id", status->usb_id, sizeof(status->usb_id));
    }
    if (json_object(modem, "debug", debug, sizeof(debug))) {
        status->debug_available = json_bool(debug, "available", 0);
        json_string(debug, "transport", status->debug_transport,
                    sizeof(status->debug_transport));
        json_string(debug, "serial", status->debug_serial,
                    sizeof(status->debug_serial));
    }
    status->online = contains_text_ci(operate_mode, "online") ||
                     contains_text_ci(wwan_status, "connect") ||
                     (status->type[0] && status->bars > 0);
    status->valid = status->type[0] || status->operator_name[0] || status->band[0];
    return status->valid;
}

static void update_network_clock(struct network_status *status)
{
    struct tm local;
    time_t wall = time(NULL);
    localtime_r(&wall, &local);
    snprintf(status->updated, sizeof(status->updated), "%02d:%02d:%02d",
             local.tm_hour, local.tm_min, local.tm_sec);
}

static int parse_fan_curve(const char *cooling, const char *key,
                           struct fan_curve_point_status *points, int capacity)
{
    char array[2048], point[256];
    const char *cursor, *start;
    int count = 0;
    if (!points || capacity < 1 || !json_array(cooling, key, array, sizeof(array)))
        return 0;
    cursor = array + 1;
    while (count < capacity && (start = strchr(cursor, '{')) != NULL &&
           copy_json_object(start, point, sizeof(point))) {
        points[count].temperature = (int)json_long(point, "temperature_celsius", 0);
        points[count].hysteresis = (int)json_long(point, "hysteresis_celsius", 0);
        points[count].pwm = (int)json_long(point, "pwm", 0);
        points[count].speed_percent = (int)json_long(point, "speed_percent", 0);
        if (count > 0 && points[count].temperature <= points[count - 1].temperature)
            return 0; /* 脏曲线（同温/非单调）整条弃用，调用方回退默认（H3） */
        count++;
        cursor = start + strlen(point);
    }
    return count;
}

static int collect_device_status(const char *state, struct device_status *status)
{
    char system[2048], runtime[8192], storage[1024], battery[2048];
    char cooling[8192], fan[2048], liquid[2048], traffic[4096];
    char limit[1024], clear_day[1024], sms[2048], nfc[512];
    int found = 0;

    memset(status, 0, sizeof(*status));
    if (json_object(state, "system", system, sizeof(system))) {
        status->uptime = json_long(system, "uptime", 0);
        status->cpu_usage = (int)json_long(system, "cpu_usage", 0);
        status->cpu_temp = (int)json_long(system, "cpu_temp", 0);
        status->mem_used_pct = (int)json_long(system, "mem_used_pct", 0);
        status->mem_total = json_ull(system, "mem_total", 0);
        status->mem_avail = json_ull(system, "mem_avail", 0);
        found++;
    }
    if (json_object(state, "runtime", runtime, sizeof(runtime)) &&
        json_object(runtime, "storage", storage, sizeof(storage))) {
        status->storage_total = json_ull(storage, "total", 0);
        status->storage_used = json_ull(storage, "used", 0);
        status->storage_avail = json_ull(storage, "available", 0);
    }
    if (json_object(state, "battery", battery, sizeof(battery))) {
        status->battery_percent = (int)json_long(battery, "percent", 0);
        status->battery_temp = (int)json_long(battery, "temp", 0);
        status->battery_online = json_bool(battery, "online", 0);
        status->battery_health = (int)json_long(battery, "health", 0);
        status->battery_charging = (int)json_long(battery, "charging", 0);
        status->charger_connected = json_bool(battery, "charger_connect", 0);
        status->charger_uv = json_long(battery, "chg_uv", 0);
        status->charger_ua = json_long(battery, "chg_ua", 0);
        status->battery_uv = json_long(battery, "bat_uv", 0);
        status->battery_ua = json_long(battery, "bat_ua", 0);
    }
    if (json_object(state, "traffic", traffic, sizeof(traffic))) {
        status->traffic_rx_rate = json_ull(traffic, "rx_speed", 0);
        status->traffic_tx_rate = json_ull(traffic, "tx_speed", 0);
        status->traffic_day_rx = json_ull(traffic, "day_rx_bytes", 0);
        status->traffic_day_tx = json_ull(traffic, "day_tx_bytes", 0);
        status->traffic_month_rx = json_ull(traffic, "month_rx_bytes", 0);
        status->traffic_month_tx = json_ull(traffic, "month_tx_bytes", 0);
        status->traffic_total_rx = json_ull(traffic, "total_rx_bytes", 0);
        status->traffic_total_tx = json_ull(traffic, "total_tx_bytes", 0);
        if (json_object(traffic, "limit", limit, sizeof(limit))) {
            status->traffic_limit_enabled = json_bool(limit, "enable", 0);
            status->traffic_limit_type = (int)json_long(limit, "type", 0);
            status->traffic_limit_value = json_ull(limit, "value", 0);
            status->traffic_limit_ratio = (int)json_long(limit, "ratio", 0);
            status->traffic_limit_overflow = json_bool(limit, "overflow", 0);
        }
        if (json_object(traffic, "clear_day", clear_day, sizeof(clear_day))) {
            status->traffic_clear_enabled = json_bool(clear_day, "enable", 0);
            status->traffic_clear_day = (int)json_long(clear_day, "clearday", 0);
        }
    }
    if (json_object(state, "cooling", cooling, sizeof(cooling))) {
        if (json_object(cooling, "fan", fan, sizeof(fan))) {
            status->fan_enabled = json_bool(fan, "enabled", 0);
            status->fan_always_on = json_bool(fan, "always_on", 0);
            status->fan_thermal_enabled = json_bool(fan, "thermal_enabled", 0);
            status->fan_kernel_zone_enabled = json_bool(fan, "kernel_zone_enabled", 0);
            status->fan_pwm = (int)json_long(fan, "pwm", 0);
            status->fan_speed_percent = (int)json_long(fan, "speed_percent", 0);
            status->fan_temperature = (int)json_long(fan, "temperature_celsius", 0);
            status->fan_hard_full_speed_temperature =
                (int)json_long(fan, "hard_full_speed_celsius", 80);
            json_string(fan, "mode", status->fan_mode, sizeof(status->fan_mode));
        }
        status->fan_factory_curve_count = parse_fan_curve(
            cooling, "factory_curve", status->fan_factory_curve,
            TOUCHUI_FAN_CURVE_MAX);
        status->fan_custom_curve_count = parse_fan_curve(
            cooling, "custom_curve", status->fan_custom_curve,
            TOUCHUI_FAN_CURVE_MAX);
        if (!status->fan_custom_curve_count)
            status->fan_custom_curve_count = parse_fan_curve(
                cooling, "curve", status->fan_custom_curve,
                TOUCHUI_FAN_CURVE_MAX);
        if (json_object(cooling, "liquid", liquid, sizeof(liquid))) {
            status->liquid_enabled = json_bool(liquid, "enabled", 0);
            status->liquid_always_on = json_bool(liquid, "always_on", 0);
            status->liquid_thermal_enabled = json_bool(liquid, "thermal_enabled", 0);
            status->liquid_level = (int)json_long(liquid, "level", 0);
            status->liquid_speed_percent = (int)json_long(liquid, "speed_percent", 0);
            status->liquid_amplitude = (int)json_long(liquid, "amplitude", 0);
            json_string(liquid, "mode", status->liquid_mode,
                        sizeof(status->liquid_mode));
        }
    }
    if (json_object(state, "sms", sms, sizeof(sms)))
        status->sms_unread = (int)json_long(sms, "unread", 0);
    if (json_object(state, "nfc", nfc, sizeof(nfc)))
        status->nfc_enabled = json_bool(nfc, "switch", 0);
    status->valid = found > 0;
    return status->valid;
}
/* --- netdev 实时流量口径（2026-09-18，替代 QCMAP 污染计数） ---
 * zwrt-datad 的 x75 traffic 来自 ZTE `zwrt_data` → `zwrt_qcmap_cli`
 * get_qclidst：QCMAP 的 ipv6_tx 把 LAN 侧 v6 下行回显计入上行
 * （实机 ipv6_tx≈ipv6_rx≈下行流，而 rmnet_data0 真实上行极小），
 * 导致锁屏/三卡页面 5G 卡「上行≈下行」。V3E 两路 ZTE 直接读 sysfs，
 * 本就干净；三路统一改由 netdev 计数自算，口径一致：
 * x75 = rmnet_data0 + rmnet_ipa0（IPA 卸载路径），v3e* = 各自 netdev。 */
#define IFSTATS_INTERVAL_MIN_MS 500LL
#define IFSTATS_INTERVAL_MAX_MS 60000LL

struct ifstats_sample {
    unsigned long long rx;
    unsigned long long tx;
    long long at_ms;
    int valid;
};

static struct ifstats_sample ifstats_prev[NETWORK_MODEM_COUNT];
static unsigned long long ifstats_max_rx[NETWORK_MODEM_COUNT];
static unsigned long long ifstats_max_tx[NETWORK_MODEM_COUNT];

static int read_netdev_bytes(const char *ifname, unsigned long long *rx,
                             unsigned long long *tx)
{
    char path[128];
    FILE *file;
    int ok = 0;
    *rx = *tx = 0;
    snprintf(path, sizeof(path), "/sys/class/net/%s/statistics/rx_bytes", ifname);
    file = fopen(path, "r");
    if (!file) return 0;
    if (fscanf(file, "%llu", rx) == 1) ok = 1;
    fclose(file);
    if (!ok) return 0;
    ok = 0;
    snprintf(path, sizeof(path), "/sys/class/net/%s/statistics/tx_bytes", ifname);
    file = fopen(path, "r");
    if (!file) return 0;
    if (fscanf(file, "%llu", tx) == 1) ok = 1;
    fclose(file);
    return ok;
}

static void override_modem_traffic_with_netdev(struct network_status *status)
{
    static const char *const x75_ifaces[] = {"rmnet_data0", "rmnet_ipa0"};
    static const char *const v3e1_ifaces[] = {"V3E1net0"};
    static const char *const v3e2_ifaces[] = {"V3E2net0"};
    static const char *const *const names[NETWORK_MODEM_COUNT] = {
        x75_ifaces, v3e1_ifaces, v3e2_ifaces
    };
    static const int counts[NETWORK_MODEM_COUNT] = {2, 1, 1};
    unsigned long long device_rx_rate = 0, device_tx_rate = 0;
    long long now = monotonic_millis();
    if (!status || !status->valid) return;
    for (int i = 0; i < NETWORK_MODEM_COUNT; i++) {
        struct modem_status *modem = &status->modems[i];
        struct ifstats_sample *prev = &ifstats_prev[i];
        unsigned long long rx = 0, tx = 0;
        int readable = 0;
        modem->rx_rate = 0;
        modem->tx_rate = 0;
        for (int n = 0; n < counts[i]; n++) {
            unsigned long long if_rx, if_tx;
            if (read_netdev_bytes(names[i][n], &if_rx, &if_tx)) {
                rx += if_rx;
                tx += if_tx;
                readable = 1;
            }
        }
        if (!readable) {
            /* 接口整体不可读（数据通话断开等）：复位基线，
             * 避免恢复后把断档累计成一个尖峰 */
            prev->valid = 0;
            modem->rx_bytes = 0;
            modem->tx_bytes = 0;
            continue;
        }
        if (prev->valid && rx >= prev->rx && tx >= prev->tx) {
            long long dt = now - prev->at_ms;
            if (dt >= IFSTATS_INTERVAL_MIN_MS && dt <= IFSTATS_INTERVAL_MAX_MS) {
                modem->rx_rate = (rx - prev->rx) * 1000ULL / (unsigned long long)dt;
                modem->tx_rate = (tx - prev->tx) * 1000ULL / (unsigned long long)dt;
            }
        } /* 计数回退（数据通话重建归零）：本拍速率取 0，基线换新 */
        if (modem->rx_rate > ifstats_max_rx[i]) ifstats_max_rx[i] = modem->rx_rate;
        if (modem->tx_rate > ifstats_max_tx[i]) ifstats_max_tx[i] = modem->tx_rate;
        modem->max_rx_rate = ifstats_max_rx[i];
        modem->max_tx_rate = ifstats_max_tx[i];
        modem->rx_bytes = rx;
        modem->tx_bytes = tx;
        prev->rx = rx;
        prev->tx = tx;
        prev->at_ms = now;
        prev->valid = 1;
        device_rx_rate += modem->rx_rate;
        device_tx_rate += modem->tx_rate;
    }
    /* 设备页“全局流量”实时速率：三路 netdev 之和（原为被污染的 x75 单路） */
    status->device.traffic_rx_rate = device_rx_rate;
    status->device.traffic_tx_rate = device_tx_rate;
}


static int collect_network_status(struct network_status *status,
                                  char *state, size_t state_size)
{
    static int probe_logged;
    int found = 0;
    memset(status, 0, sizeof(*status));
    if (!state || state_size < 3 || !fetch_datad_state(state, state_size))
        return 0;
    collect_device_status(state, &status->device);
    for (int i = 0; i < NETWORK_MODEM_COUNT; i++)
        if (collect_modem_status(state, i, &status->modems[i])) found++;
    status->valid = found > 0;
    override_modem_traffic_with_netdev(status);
    update_network_clock(status);
    if (status->valid && !probe_logged) {
        FILE *probe = fopen("/tmp/touchui-network.log", "w");
        if (probe) {
            fprintf(probe, "modems=%d x75_qci=%d v3e1_qci=%d v3e2_qci=%d\n",
                    found, status->modems[0].qci,
                    status->modems[1].qci, status->modems[2].qci);
            fclose(probe);
            probe_logged = 1;
        }
    }
    return status->valid;
}
