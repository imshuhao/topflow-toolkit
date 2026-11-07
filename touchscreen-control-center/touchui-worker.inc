static long long monotonic_millis(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long long)now.tv_sec * 1000LL + now.tv_nsec / 1000000LL;
}

static int read_pidfile_rss(const char *pidfile, long *rss_kb)
{
    FILE *file;
    char path[64], line[160];
    long pid, value;
    if (!rss_kb || !pidfile) return 0;
    file = fopen(pidfile, "r");
    if (!file) return 0;
    if (fscanf(file, "%ld", &pid) != 1 || pid <= 1) {
        fclose(file);
        return 0;
    }
    fclose(file);
    snprintf(path, sizeof(path), "/proc/%ld/status", pid);
    file = fopen(path, "r");
    if (!file) return 0;
    while (fgets(line, sizeof(line), file)) {
        if (sscanf(line, "VmRSS: %ld kB", &value) == 1) {
            fclose(file);
            *rss_kb = value;
            return 1;
        }
    }
    fclose(file);
    return 0;
}

static int read_singbox_rss(long *rss_kb)
{
    return read_pidfile_rss(SINGBOX_PIDFILE, rss_kb);
}

static int read_mihomo_rss(long *rss_kb)
{
    return read_pidfile_rss("/data/mihomo/run/mihomo.pid", rss_kb);
}

static void update_fast_status(struct singbox_status *status)
{
    struct tm local;
    time_t wall;
    long rss_kb;
    int on_mihomo;
    /* 流量总量/速率由全量轮询经 manager（/connections 口径）提供；
     * 快路径只刷 RSS 与时钟（mh-host veth 双向镜像口径已废弃） */
    if (!status || !status->valid) return;
    on_mihomo = !strcmp(status->engine, "mihomo") ||
                status->mihomo_running ||
                status->dhcp_points_to_mihomo;
    if (status->service_running) {
        if (read_singbox_rss(&rss_kb)) status->rss_kb = rss_kb;
    } else if (on_mihomo) {
        /* Do NOT zero manager RSS: service_running is sing-box-only. */
        if (read_mihomo_rss(&rss_kb)) status->rss_kb = rss_kb;
    } else {
        status->rss_kb = 0;
    }
    wall = time(NULL);
    localtime_r(&wall, &local);
    snprintf(status->updated, sizeof(status->updated), "%02d:%02d:%02d",
             local.tm_hour, local.tm_min, local.tm_sec);
}

static int action_is_singbox(int action)
{
    return action >= ACTION_SERVICE_START && action <= ACTION_SERVICE_RESTART;
}

static int action_is_engine(int action)
{
    return action == ACTION_ENGINE_SWITCHOVER ||
           action == ACTION_ENGINE_ROLLBACK;
}

static enum page_id message_page_for_action(int action)
{
    if (action_is_singbox(action) || action_is_engine(action)) return PAGE_SINGBOX;
    if (action == ACTION_WAN_MODE_AUTO || action == ACTION_WAN_MODE_SHARED ||
        action == ACTION_WAN_MODE_CUSTOM)
        return PAGE_WANBAL;
    return PAGE_DEVICE;
}

static enum page_id message_page_for_page(enum page_id page)
{
    if (page == PAGE_SINGBOX) return PAGE_SINGBOX;
    if (page == PAGE_WANBAL) return PAGE_WANBAL;
    if (page == PAGE_DEVICE || page == PAGE_COOLING_CURVE ||
        page == PAGE_DIAGNOSTICS) return PAGE_DEVICE;
    return PAGE_STOCK;
}

static void publish_message(int action, int ok, const char *message)
{
    pthread_mutex_lock(&shared_lock);
    safe_copy(shared_message, sizeof(shared_message), message);
    shared_message_page = message_page_for_action(action);
    shared_generation++;
    pthread_mutex_unlock(&shared_lock);
    (void)ok;
}

static void execute_action(int action, int action_band,
                           int action_value, int action_value2,
                           const struct fan_curve_point_status *curve,
                           int curve_count, int fan_need_default)
{
    const char *arg1 = NULL, *arg2 = NULL;
    const char *control = NULL;
    char output[4096], message[160], control_buffer[1024];
    int ok;
    switch (action) {
    case ACTION_SERVICE_START: arg1 = "service-start"; break;
    case ACTION_SERVICE_STOP: arg1 = "service-stop"; break;
    case ACTION_SERVICE_RESTART: arg1 = "service-restart"; break;
    case ACTION_ENGINE_SWITCHOVER: arg1 = "switchover"; break;
    case ACTION_ENGINE_ROLLBACK: arg1 = "rollback"; break;
    case ACTION_WAN_MODE_AUTO: arg1 = "wan-mode-set"; arg2 = "auto"; break;
    case ACTION_WAN_MODE_SHARED: arg1 = "wan-mode-set"; arg2 = "shared"; break;
    case ACTION_WAN_MODE_CUSTOM: {
        /* 手动选池：wan-mode-set custom <tcp_csv> <udp_csv> <overflow>
         * 入队参数 = (overflow, tcp 掩码, udp 掩码)，
         * 掩码 bit0=5G bit1=4G#1 bit2=4G#2。 */
        char tcp_csv[32], udp_csv[32], overflow[4];
        const char *args[5];
        wanbal_pool_csv(action_value & 7, tcp_csv, sizeof(tcp_csv));
        wanbal_pool_csv(action_value2 & 7, udp_csv, sizeof(udp_csv));
        safe_copy(overflow, sizeof(overflow), action_band ? "1" : "0");
        args[0] = "wan-mode-set";
        args[1] = "custom";
        args[2] = tcp_csv;
        args[3] = udp_csv;
        args[4] = overflow;
        publish_message(action, 1, "正在执行，请稍候…");
        if (run_singbox_manager_args(output, sizeof(output), args, 5) != 0) {
            publish_message(action, 0, "管理后端执行失败");
            return;
        }
        ok = json_bool(output, "ok", 0);
        if (!json_string(output, "message", message, sizeof(message)))
            safe_copy(message, sizeof(message), ok ? "分流已应用" : "操作失败");
        publish_message(action, ok, message);
        return;
    }
    case ACTION_FAN_FACTORY:
        /* 原厂：恢复原厂 44/48/53°C 曲线后切 automatic
         * datad 的 automatic 仍使用当前曲线，必须从常闭/自定义恢复 */
        if (!post_datad_control(
                "{\"action\":\"cooling.fan.set_curve\",\"params\":{\"points\":["
                "{\"temperature\":20,\"pwm\":0},"
                "{\"temperature\":44,\"pwm\":76},"
                "{\"temperature\":48,\"pwm\":128},"
                "{\"temperature\":53,\"pwm\":179},"
                "{\"temperature\":80,\"pwm\":255}]}}",
                output, sizeof(output)) ||
            !post_datad_control(
                "{\"action\":\"cooling.fan.set_mode\",\"params\":{\"mode\":\"automatic\"}}",
                output, sizeof(output))) {
            publish_message(action, 0, "设备控制接口执行失败");
            return;
        }
        publish_message(action, 1, "已切换至原厂自动模式");
        return;
    case ACTION_FAN_CUSTOM: {
        /* need_default 以入队时 UI 线程快照为准（M17）：worker 不得无锁读 ui_network_status */
        int need_default = fan_need_default;
        if (need_default) {
            if (!post_datad_control(
                    "{\"action\":\"cooling.fan.set_curve\",\"params\":{\"points\":["
                    "{\"temperature\":40,\"pwm\":0},"
                    "{\"temperature\":44,\"pwm\":0},"
                    "{\"temperature\":45,\"pwm\":13},"
                    "{\"temperature\":46,\"pwm\":20},"
                    "{\"temperature\":47,\"pwm\":28},"
                    "{\"temperature\":48,\"pwm\":36},"
                    "{\"temperature\":50,\"pwm\":51},"
                    "{\"temperature\":70,\"pwm\":179}]}}",
                    output, sizeof(output))) {
                publish_message(action, 0, "设备控制接口执行失败");
                return;
            }
        }
        if (!post_datad_control(
                "{\"action\":\"cooling.fan.set_mode\",\"params\":{\"mode\":\"custom\"}}",
                output, sizeof(output))) {
            publish_message(action, 0, "设备控制接口执行失败");
            return;
        }
        publish_message(action, 1, need_default ?
                        "已恢复默认自定义曲线" : "已切换至自定义模式");
        return;
    }
    case ACTION_FAN_ALWAYS:
        if (!post_datad_control(
                "{\"action\":\"cooling.fan.set_mode\",\"params\":{\"mode\":\"always_on\"}}",
                output, sizeof(output))) {
            publish_message(action, 0, "设备控制接口执行失败");
            return;
        }
        publish_message(action, 1, "已切换至常开模式");
        return;
    case ACTION_FAN_OFF:
        /* 常闭：零曲线 + custom，datad 即使 enabled=false 也会按曲线写 pwm */
        if (!post_datad_control(
                "{\"action\":\"cooling.fan.set_curve\",\"params\":{\"points\":["
                "{\"temperature\":20,\"pwm\":0},{\"temperature\":80,\"pwm\":0}]}}",
                output, sizeof(output))) {
            publish_message(action, 0, "设备控制接口执行失败");
            return;
        }
        if (!post_datad_control(
                "{\"action\":\"cooling.fan.set_mode\",\"params\":{\"mode\":\"custom\"}}",
                output, sizeof(output))) {
            publish_message(action, 0, "设备控制接口执行失败");
            return;
        }
        if (!post_datad_control(
                "{\"action\":\"cooling.fan.set_enabled\",\"params\":{\"enabled\":false}}",
                output, sizeof(output))) {
            publish_message(action, 0, "设备控制接口执行失败");
            return;
        }
        publish_message(action, 1, "风扇已常闭");
        return;
    case ACTION_FAN_CURVE_APPLY: {
        size_t used = 0;
        int written;
        if (!curve || curve_count < 2 || curve_count > TOUCHUI_FAN_CURVE_MAX) return;
        written = snprintf(control_buffer, sizeof(control_buffer),
                           "{\"action\":\"cooling.fan.set_curve\",\"params\":{\"points\":[");
        if (written < 0 || (size_t)written >= sizeof(control_buffer)) return;
        used = (size_t)written;
        for (int i = 0; i < curve_count; i++) {
            written = snprintf(control_buffer + used, sizeof(control_buffer) - used,
                               "%s{\"temperature\":%d,\"pwm\":%d}", i ? "," : "",
                               curve[i].temperature, curve[i].pwm);
            if (written < 0 || (size_t)written >= sizeof(control_buffer) - used) return;
            used += (size_t)written;
        }
        written = snprintf(control_buffer + used, sizeof(control_buffer) - used, "]}}");
        if (written < 0 || (size_t)written >= sizeof(control_buffer) - used) return;
        control = control_buffer;
        break;
    }
    case ACTION_LIQUID_AUTO:
        control = "{\"action\":\"cooling.liquid.set_mode\",\"params\":{\"mode\":\"automatic\"}}";
        break;
    case ACTION_LIQUID_LOW:
        control = "{\"action\":\"cooling.liquid.set_mode\",\"params\":{\"mode\":\"low\"}}";
        break;
    case ACTION_LIQUID_HIGH:
        control = "{\"action\":\"cooling.liquid.set_mode\",\"params\":{\"mode\":\"high\"}}";
        break;
    case ACTION_WIFI_APPLY:
        if (action_band < 0 || action_band > 1 || action_value < 10 ||
            action_value > 100 || action_value % 10 ||
            action_value2 < 1 || action_value2 > 30) return;
        snprintf(control_buffer, sizeof(control_buffer),
                 "{\"action\":\"wifi.txpower.apply\",\"params\":{"
                 "\"band\":\"%s\",\"percent\":%d,\"limit_dbm\":%d}}",
                 action_band ? "5g" : "2g", action_value, action_value2);
        control = control_buffer;
        break;
    case ACTION_STATE_REFRESH:
        control = "{\"action\":\"state.refresh\",\"params\":{}}";
        break;
    default: return;
    }
    publish_message(action, 1, "正在执行，请稍候…");
    if (control) {
        if (!post_datad_control(control, output, sizeof(output))) {
            publish_message(action, 0, "设备控制接口执行失败"); return;
        }
    } else if (run_singbox_manager(output, sizeof(output), arg1, arg2) != 0) {
        publish_message(action, 0, "管理后端执行失败"); return;
    }
    ok = json_bool(output, "ok", 0);
    if (!json_string(output, "message", message, sizeof(message)))
        safe_copy(message, sizeof(message), ok ?
                  (action == ACTION_WIFI_APPLY ? "Wi-Fi 设置已应用" :
                   (action == ACTION_FAN_CURVE_APPLY ? "自定义曲线已应用" : "操作完成")) :
                  "操作失败");
    publish_message(action, ok, message);
}

static void *status_worker(void *unused)
{
    unsigned long long old_rx = 0, old_tx = 0;
    struct singbox_status cached;
    struct network_status network_cached;
    char *network_state = NULL;
    int old_valid = 0, cached_valid = 0, consecutive_failures = 0;
    int network_cached_valid = 0, network_failures = 0;
    long long next_fast_poll = 0, next_full_poll = 0, next_network_poll = 0;
    long long next_wifi_poll = 0;
    long long last_full_sample_ms = 0;
    memset(&cached, 0, sizeof(cached));
    memset(&network_cached, 0, sizeof(network_cached));
    (void)unused;
    for (;;) {
        int action = ACTION_NONE, action_band = -1;
        int action_value = 0, action_value2 = 0, refresh = 0;
        int action_curve_count = 0, action_fan_need_default = 0;
        struct fan_curve_point_status action_curve[TOUCHUI_FAN_CURVE_MAX];
        long long now;
        pthread_mutex_lock(&shared_lock);
        if (!shared_action_running && shared_action != ACTION_NONE) {
            action = shared_action; shared_action = ACTION_NONE;
            action_band = shared_action_band;
            action_value = shared_action_value;
            action_value2 = shared_action_value2;
            action_curve_count = shared_action_curve_count;
            memcpy(action_curve, shared_action_curve, sizeof(action_curve));
            action_fan_need_default = shared_action_fan_need_default;
            shared_action_curve_count = 0;
            shared_action_running = 1;
            shared_running_action = action;
            shared_generation++;
        }
        if (force_refresh) { refresh = 1; force_refresh = 0; }
        if (force_network_refresh) { next_network_poll = 0; force_network_refresh = 0; }
        pthread_mutex_unlock(&shared_lock);
        if (action != ACTION_NONE) {
            execute_action(action, action_band, action_value, action_value2,
                           action_curve, action_curve_count, action_fan_need_default);
            pthread_mutex_lock(&shared_lock);
            shared_action_running = 0;
            shared_running_action = ACTION_NONE;
            shared_generation++;
            pthread_mutex_unlock(&shared_lock);
            next_full_poll = 0;
            next_network_poll = 0;
            next_wifi_poll = 0;
            force_wanbal_refresh = 1;
        }
        now = monotonic_millis();
        if (refresh) next_full_poll = 0;
        if (force_wanbal_refresh || now >= next_full_poll) {
            struct wanbal_status wanbal_fresh;
            static struct wanbal_status wanbal_cached;
            static int wanbal_cached_valid, wanbal_failures;
            if (collect_wanbal_status(&wanbal_fresh)) {
                wanbal_cached = wanbal_fresh;
                wanbal_cached_valid = 1;
                wanbal_failures = 0;
            } else if (wanbal_cached_valid) {
                wanbal_failures++;
                if (wanbal_failures >= STATUS_STALE_FAILURES)
                    wanbal_cached.stale = 1;
            }
            pthread_mutex_lock(&shared_lock);
            if (wanbal_cached_valid) shared_wanbal_status = wanbal_cached;
            else memset(&shared_wanbal_status, 0, sizeof(shared_wanbal_status));
            shared_wanbal_generation++;
            force_wanbal_refresh = 0;
            pthread_mutex_unlock(&shared_lock);
        }
        if (now >= next_full_poll) {
            struct singbox_status fresh;
            if (collect_singbox_status(&fresh)) {
                /* 速率用“距上次全量采样的实际间隔”，避免 action 后
                 * next_full_poll=0 立刻采样时仍按固定 5s 估算。
                 * 过短间隔回退名义 5s，防止 force-poll 抖动尖峰。 */
                long long sample_now = monotonic_millis();
                long long elapsed = FULL_STATUS_INTERVAL_MS;
                if (last_full_sample_ms > 0 && sample_now > last_full_sample_ms) {
                    long long delta = sample_now - last_full_sample_ms;
                    if (delta >= 500 && delta <= 60000)
                        elapsed = delta;
                }
                consecutive_failures = 0; /* like network_failures on success */
                if (old_valid && fresh.rx_bytes >= old_rx && fresh.tx_bytes >= old_tx) {
                    fresh.rx_rate = (unsigned long long)
                        (((long long)(fresh.rx_bytes - old_rx) * 1000LL) / elapsed);
                    fresh.tx_rate = (unsigned long long)
                        (((long long)(fresh.tx_bytes - old_tx) * 1000LL) / elapsed);
                }
                old_rx = fresh.rx_bytes; old_tx = fresh.tx_bytes; old_valid = 1;
                last_full_sample_ms = sample_now;
                cached = fresh;
                cached_valid = 1;
            } else if (cached_valid) {
                consecutive_failures++;
                if (consecutive_failures >= STATUS_STALE_FAILURES) cached.stale = 1;
            } else {
                consecutive_failures++;
            }
            next_full_poll = monotonic_millis() + FULL_STATUS_INTERVAL_MS;
            now = monotonic_millis();
        }
        if (now >= next_fast_poll) {
            if (cached_valid)
                update_fast_status(&cached);
            pthread_mutex_lock(&shared_lock);
            if (cached_valid) shared_status = cached;
            else memset(&shared_status, 0, sizeof(shared_status));
            shared_generation++;
            pthread_mutex_unlock(&shared_lock);
            next_fast_poll = monotonic_millis() + FAST_STATUS_INTERVAL_MS;
        }
        if (now >= next_network_poll) {
            struct network_status fresh;
            if (!network_state) network_state = malloc(NETWORK_HTTP_MAX);
            if (network_state &&
                collect_network_status(&fresh, network_state, NETWORK_HTTP_MAX)) {
                network_cached = fresh;
                network_cached_valid = 1;
                network_failures = 0;
            } else if (network_cached_valid) {
                network_failures++;
                if (network_failures >= STATUS_STALE_FAILURES)
                    network_cached.stale = 1;
                update_network_clock(&network_cached);
            } else {
                network_failures++;
            }
            pthread_mutex_lock(&shared_lock);
            if (network_cached_valid) shared_network_status = network_cached;
            else memset(&shared_network_status, 0, sizeof(shared_network_status));
            shared_network_generation++;
            pthread_mutex_unlock(&shared_lock);
            next_network_poll = monotonic_millis() + NETWORK_STATUS_INTERVAL_MS;
        }
        if (now >= next_wifi_poll) {
            struct wifi_power_status fresh;
            if (collect_wifi_power_status(&fresh)) {
                pthread_mutex_lock(&shared_lock);
                shared_wifi_power_status = fresh;
                shared_wifi_generation++;
                pthread_mutex_unlock(&shared_lock);
            }
            next_wifi_poll = monotonic_millis() + WIFI_STATUS_INTERVAL_MS;
        }
        usleep(50000);
    }
    return NULL;
}
