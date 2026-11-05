static void format_bytes(unsigned long long bytes, char *out, size_t size)
{
    static const char *const units[] = {"B", "KB", "MB", "GB", "TB", "PB", "EB"};
    double value = (double)bytes;
    size_t unit = 0;
    while (value >= 1024.0 && unit + 1 < sizeof(units) / sizeof(units[0])) {
        value /= 1024.0;
        unit++;
    }
    if (unit == 0) snprintf(out, size, "%lluB", bytes);
    else if (value < 10.0) snprintf(out, size, "%.2f%s", value, units[unit]);
    else if (value < 100.0) snprintf(out, size, "%.1f%s", value, units[unit]);
    else snprintf(out, size, "%.0f%s", value, units[unit]);
}

static void set_checked(lv_obj_t *button, int checked)
{
    if (!button) return;
    if (checked) lv_obj_add_state_p(button, LV_STATE_CHECKED);
    else lv_obj_clear_state_p(button, LV_STATE_CHECKED);
}

static void set_status_color(uint32_t color)
{
    set_bg_color(status_indicator, color, 0);
    set_border_color(status_indicator, color, 0);
    set_shadow_color(status_indicator, color);
}

static void refresh_ui(void)
{
    struct singbox_status status;
    char message[160], text[192], rr[32], tr[32], rt[32], tt[32];
    int generation, action_running;
    uint32_t status_color;
    if (!manager_page) return;
    pthread_mutex_lock(&shared_lock);
    generation = shared_generation;
    if (generation == ui_generation) { pthread_mutex_unlock(&shared_lock); return; }
    status = shared_status;
    safe_copy(message, sizeof(message),
              shared_message_page == PAGE_SINGBOX ? shared_message : "");
    action_running = action_is_singbox(shared_action_running ?
                                       shared_running_action : shared_action);
    pthread_mutex_unlock(&shared_lock);
    ui_generation = generation; ui_status = status;
    if (!status.valid) {
        set_text_color(status_label, COLOR_MUTED);
        set_status_color(COLOR_MUTED);
        /* set_label_text_if_changed already NULL-guards labels */
        set_label_text_if_changed(status_label, "状态读取中…");
        set_label_text_if_changed(status_mode_label, "等待数据");
        set_label_text_if_changed(version_label, "未知");
        set_label_text_if_changed(memory_label, "--");
        set_label_text_if_changed(tun_value_label, "未知");
        set_label_text_if_changed(dhcp_value_label, "未知");
        set_label_text_if_changed(providers_label, "--");
        set_label_text_if_changed(watchdog_label, "--");
        set_label_text_if_changed(keeper_label, "--");
        set_traffic_value(&traffic_rate_down, "--");
        set_traffic_value(&traffic_rate_up, "--");
        set_traffic_value(&traffic_total_down, "--");
        set_traffic_value(&traffic_total_up, "--");
        set_label_text_if_changed(updated_label, "--:--:--");
        return;
    }
    if (status.stale) {
        status_color = COLOR_AMBER;
        snprintf(text, sizeof(text), "数据延迟");
        set_label_text_if_changed(status_mode_label, "数据延迟");
    } else if (status.mihomo_running && !status.service_running) {
        status_color = COLOR_AMBER;
        snprintf(text, sizeof(text), "mihomo 回滚态");
        set_label_text_if_changed(status_mode_label, "回滚态");
    } else if (!status.service_running) {
        status_color = COLOR_RED;
        snprintf(text, sizeof(text), "服务已停止");
        set_label_text_if_changed(status_mode_label,
                                  status.manual_stop ? "手动停止" : "未运行");
    } else if (!status.api_ok) {
        status_color = COLOR_AMBER;
        snprintf(text, sizeof(text), "核心启动中");
        set_label_text_if_changed(status_mode_label, "启动中");
    } else if (!status.capture_ok) {
        status_color = COLOR_AMBER;
        snprintf(text, sizeof(text), "数据面未就绪");
        set_label_text_if_changed(status_mode_label, "数据面异常");
    } else if (!status.dhcp_ok) {
        status_color = COLOR_AMBER;
        snprintf(text, sizeof(text), "DHCP 未指向");
        set_label_text_if_changed(status_mode_label, "DHCP 异常");
    } else {
        status_color = COLOR_GREEN;
        snprintf(text, sizeof(text), "运行正常");
        set_label_text_if_changed(status_mode_label,
                                  !strcmp(status.inbound_mode, "ebpf") ?
                                  "eBPF 模式" : "TUN 模式");
    }
    set_text_color(status_label, COLOR_TEXT);
    set_status_color(status_color);
    set_label_text_if_changed(status_label, text);
    set_label_text_if_changed(version_label, status.version);
    set_label_text_if_changed(tun_value_label,
                        status.capture_ok ? "已接管" : "未就绪");
    set_label_text_if_changed(dhcp_value_label,
                        status.dhcp_ok ? "0.1 已下发" : "未下发");
    snprintf(text, sizeof(text), "%d 个", status.providers);
    set_label_text_if_changed(providers_label, text);
    set_label_text_if_changed(watchdog_label,
                        status.watchdog_running ? "运行中" : "未运行");
    set_label_text_if_changed(keeper_label,
                        status.keeper_running ? "运行中" : "未运行");
    if (status.service_running && status.rss_kb > 0) {
        snprintf(text, sizeof(text), "%.1f MB", (double)status.rss_kb/1024.0);
        set_label_text_if_changed(memory_label, text);
        format_bytes(status.rx_rate, rr, sizeof(rr)); format_bytes(status.tx_rate, tr, sizeof(tr));
        format_bytes(status.rx_bytes, rt, sizeof(rt)); format_bytes(status.tx_bytes, tt, sizeof(tt));
        snprintf(text, sizeof(text), "%s/s", rr);
        set_traffic_value(&traffic_rate_down, text);
        snprintf(text, sizeof(text), "%s/s", tr);
        set_traffic_value(&traffic_rate_up, text);
        set_traffic_value(&traffic_total_down, rt);
        set_traffic_value(&traffic_total_up, tt);
    } else {
        set_label_text_if_changed(memory_label, "--");
        set_traffic_value(&traffic_rate_down, "--");
        set_traffic_value(&traffic_rate_up, "--");
        set_traffic_value(&traffic_total_down, "--");
        set_traffic_value(&traffic_total_up, "--");
    }
    set_label_text_if_changed(service_button_label,
                              status.service_running ? "停止服务" : "启动服务");
    center_button_label(service_button_label);
    center_button_label(restart_button_label);
    set_checked(service_button, status.service_running);
    set_label_text_if_changed(message_label, message[0] ? message : (action_running ? "正在执行，请稍候…" : ""));
    set_label_text_if_changed(updated_label, status.updated);
}
