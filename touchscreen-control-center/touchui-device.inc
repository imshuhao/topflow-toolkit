static int device_alert_count(void)
{
    const struct device_status *device = &ui_network_status.device;
    int alerts = 0, thermal_alert = 0;
    if (!ui_network_status.valid || !device->valid || ui_network_status.stale)
        alerts++;
    for (int i = 0; i < NETWORK_MODEM_COUNT; i++) {
        const struct modem_status *modem = &ui_network_status.modems[i];
        if (!modem->valid || !modem->online || !modem->sim_ready) alerts++;
        if (modem->temperature_valid && modem->temperature >= 70)
            thermal_alert = 1;
    }
    if (device->cpu_temp >= 75 || device->battery_temp >= 45 || thermal_alert)
        alerts++;
    if (ui_status.valid && !ui_status.service_running && !ui_status.manual_stop)
        alerts++;
    if (device->traffic_limit_overflow ||
        (device->traffic_limit_enabled && device->traffic_limit_ratio >= 90))
        alerts++;
    if ((device->fan_mode[0] && !device->fan_thermal_enabled) ||
        (!strcmp(device->fan_mode, "automatic") &&
         !device->fan_kernel_zone_enabled) ||
        (device->liquid_mode[0] && !device->liquid_thermal_enabled)) alerts++;
    if (device->sms_unread > 0) alerts++;
    return alerts;
}

static void set_device_checked(lv_obj_t *button, int checked)
{
    if (!button) return;
    if (checked) lv_obj_add_state_p(button, LV_STATE_CHECKED);
    else lv_obj_clear_state_p(button, LV_STATE_CHECKED);
}

#include "touchui-wifi.inc"
#include "touchui-cooling.inc"

static void make_key_value(lv_obj_t *parent, const char *key, lv_obj_t **value,
                           int y)
{
    make_detail_label(parent, key, 20, y, 106, 20, ui_font_small, COLOR_MUTED);
    *value = make_detail_label(parent, "--", 132, y, 168, 20,
                               ui_font_small, COLOR_TEXT);
    right_align_label_text(*value);
}

static void destroy_device_tab_content(void)
{
    if (device_tab_content && lv_obj_del_p) lv_obj_del_p(device_tab_content);
    device_tab_content = NULL;
    memset(device_system_values, 0, sizeof(device_system_values));
    memset(device_traffic_values, 0, sizeof(device_traffic_values));
    device_fan_status = NULL;
    device_fan_detail = NULL;
    device_liquid_status = NULL;
    device_liquid_detail = NULL;
    memset(device_fan_buttons, 0, sizeof(device_fan_buttons));
    memset(device_liquid_buttons, 0, sizeof(device_liquid_buttons));
    memset(device_wifi_band_buttons, 0, sizeof(device_wifi_band_buttons));
    device_wifi_header = device_wifi_state = NULL;
    device_wifi_percent_value = device_wifi_limit_value = NULL;
    device_wifi_restore_button = device_wifi_apply_button = NULL;
}

static int create_device_system_tab(void)
{
    device_tab_content = make_transparent_container(device_page, 0, 132, 320, 284);
    if (!device_tab_content) return 0;
    make_panel(device_tab_content, 8, 0, 304, 83, COLOR_CARD);
    make_detail_label(device_tab_content, "电池与供电", 20, 8, 110, 18,
                      ui_font_tiny, COLOR_MUTED);
    make_key_value(device_tab_content, "电量", &device_system_values[0], 31);
    make_key_value(device_tab_content, "状态", &device_system_values[1], 55);
    make_panel(device_tab_content, 8, 89, 304, 83, COLOR_CARD);
    make_detail_label(device_tab_content, "处理器", 20, 97, 90, 18,
                      ui_font_tiny, COLOR_MUTED);
    make_key_value(device_tab_content, "占用", &device_system_values[2], 120);
    make_key_value(device_tab_content, "温度", &device_system_values[3], 144);
    make_panel(device_tab_content, 8, 178, 304, 106, COLOR_CARD);
    make_detail_label(device_tab_content, "资源", 20, 186, 90, 18,
                      ui_font_tiny, COLOR_MUTED);
    make_key_value(device_tab_content, "内存", &device_system_values[4], 209);
    make_key_value(device_tab_content, "存储", &device_system_values[5], 233);
    make_key_value(device_tab_content, "运行时间", &device_system_values[6], 257);
    return 1;
}

static void make_traffic_card(lv_obj_t *parent, const char *title, int y,
                              struct traffic_value_component *down,
                              struct traffic_value_component *up)
{
    make_panel(parent, 8, y, 304, 64, COLOR_CARD);
    make_detail_label(parent, title, 20, y + 5, 64, 19, ui_font_tiny, COLOR_MUTED);
    *down = make_download_value(parent, 72, y + 25, 90, ui_font_xlarge);
    *up = make_upload_value(parent, 190, y + 25, 82, ui_font_xlarge);
    if (lv_img_set_zoom_p) {
        if (down->icon) lv_img_set_zoom_p(down->icon, 384);
        if (up->icon) lv_img_set_zoom_p(up->icon, 384);
    }
    if (down->label) lv_obj_set_pos_p(down->label, 100, y + 25);
    if (up->label) lv_obj_set_pos_p(up->label, 218, y + 25);
}

static int create_device_traffic_tab(void)
{
    device_tab_content = make_transparent_container(device_page, 0, 132, 320, 284);
    if (!device_tab_content) return 0;
    make_traffic_card(device_tab_content, "实时", 0,
                      &device_traffic_values[0], &device_traffic_values[1]);
    make_traffic_card(device_tab_content, "今日", 70,
                      &device_traffic_values[2], &device_traffic_values[3]);
    make_traffic_card(device_tab_content, "本月", 140,
                      &device_traffic_values[4], &device_traffic_values[5]);
    make_traffic_card(device_tab_content, "累计", 210,
                      &device_traffic_values[6], &device_traffic_values[7]);
    return 1;
}

static void show_device_tab(int tab)
{
    if (tab < 0 || tab > 3 || !device_page) tab = 0;
    hide_confirm();
    if (confirm_scrim && lv_obj_del_p) lv_obj_del_p(confirm_scrim);
    if (confirm_panel && lv_obj_del_p) lv_obj_del_p(confirm_panel);
    confirm_scrim = confirm_panel = confirm_text_label = NULL;
    destroy_device_tab_content();
    device_tab = tab;
    if (tab == 0) create_device_system_tab();
    else if (tab == 1) create_device_traffic_tab();
    else if (tab == 2) create_device_cooling_tab();
    else create_device_wifi_tab();
    for (int i = 0; i < 4; i++) set_device_checked(device_tab_buttons[i], i == tab);
    create_confirmation_overlay(device_page);
    refresh_device_ui();
}

static void device_system_tab_clicked(void *event) { (void)event; show_device_tab(0); }
static void device_traffic_tab_clicked(void *event) { (void)event; show_device_tab(1); }
static void device_cooling_tab_clicked(void *event) { (void)event; show_device_tab(2); }
static void device_wifi_tab_clicked(void *event) { (void)event; show_device_tab(3); }

static void open_diagnostics_clicked(void *event)
{
    (void)event;
    pending_device_view = 2;
}

static int create_device_page(lv_obj_t *top)
{
    if (!page_shell_init(&device_shell, top, PAGE_DEVICE, "设备状态",
                         feature_back_clicked)) return 0;
    device_page = device_shell.root;
    device_alert_dot = lv_obj_create_p(device_page);
    if (device_alert_dot) {
        lv_obj_set_size_p(device_alert_dot, 8, 8);
        lv_obj_set_pos_p(device_alert_dot, 18,
                         center_marker_on_text_line(58, ui_font_small, 8));
        lv_obj_clear_flag_p(device_alert_dot, LV_OBJ_FLAG_SCROLLABLE);
        style_surface(device_alert_dot, COLOR_MUTED, COLOR_MUTED, 8, 0);
    }
    device_alert_label = make_detail_label(device_page, "状态读取中…", 34, 58, 166, 21,
                                           ui_font_small, COLOR_MUTED);
    make_button(device_page, "一键诊断", 208, 50, 104, 34,
                open_diagnostics_clicked, NULL);
    device_tab_buttons[0] = make_button(device_page, "系统", 8, 92, 73, 34,
                                        device_system_tab_clicked, NULL);
    device_tab_buttons[1] = make_button(device_page, "流量", 85, 92, 73, 34,
                                        device_traffic_tab_clicked, NULL);
    device_tab_buttons[2] = make_button(device_page, "散热", 162, 92, 73, 34,
                                        device_cooling_tab_clicked, NULL);
    device_tab_buttons[3] = make_button(device_page, "无线", 239, 92, 73, 34,
                                        device_wifi_tab_clicked, NULL);
    for (int i = 0; i < 4; i++) style_segment_button(device_tab_buttons[i]);
    device_message_label = make_single_line_label(device_page, "", 14, 420, 292, 22);
    set_text_color(device_message_label, COLOR_MESSAGE);
    if (!device_tab_buttons[0] || !device_tab_buttons[1] ||
        !device_tab_buttons[2] || !device_tab_buttons[3]) {
        trace_ui_create("device-tab-buttons-failed");
        if (device_page && lv_obj_del_p) lv_obj_del_p(device_page);
        device_page = NULL;
        memset(&device_shell, 0, sizeof(device_shell));
        memset(device_tab_buttons, 0, sizeof(device_tab_buttons));
        device_alert_dot = device_alert_label = device_message_label = NULL;
        return 0;
    }
    show_device_tab(device_tab);
    return 1;
}

static const char *diagnostic_result(int ok, const char *ok_text,
                                     const char *bad_text)
{
    return ok ? ok_text : bad_text;
}

static int create_diagnostics_page(lv_obj_t *top)
{
    static const char *names[6] = {
        "数据服务", "蜂窝链路", "地址与 DNS", "三路路径", "Sing-box", "温控保护"
    };
    lv_obj_t *refresh_button;
    trace_ui_create("diagnostics-begin");
    if (!page_shell_init(&diagnostics_shell, top, PAGE_DIAGNOSTICS, "一键诊断",
                         open_device_clicked)) return 0;
    diagnostics_page = diagnostics_shell.root;
    make_panel(diagnostics_page, 8, 50, 304, 52, COLOR_CARD);
    diagnostic_overall_label = make_detail_label(diagnostics_page, "检测中…",
        20, 65, 280, 22, ui_font_small, COLOR_MUTED);
    for (int i = 0; i < 6; i++) {
        int y = 109 + i * 49;
        make_panel(diagnostics_page, 8, y, 304, 43, COLOR_CARD);
        make_detail_label(diagnostics_page, names[i], 20, y + 11, 100, 20,
                          ui_font_small, COLOR_MUTED);
        diagnostic_values[i] = make_detail_label(diagnostics_page, "--",
            122, y + 11, 178, 20, ui_font_small, COLOR_TEXT);
        right_align_label_text(diagnostic_values[i]);
    }
    refresh_button = make_button(diagnostics_page, "重新检测", 92, 412, 136, 34,
                                 device_refresh_clicked, NULL);
    if (!diagnostic_overall_label || !refresh_button) goto failed;
    for (int i = 0; i < 6; i++)
        if (!diagnostic_values[i]) goto failed;
    trace_ui_create("diagnostics-complete");
    return 1;
failed:
    trace_ui_create("diagnostics-allocation-failed");
    if (diagnostics_page && lv_obj_del_p) lv_obj_del_p(diagnostics_page);
    diagnostics_page = NULL;
    memset(&diagnostics_shell, 0, sizeof(diagnostics_shell));
    diagnostic_overall_label = NULL;
    memset(diagnostic_values, 0, sizeof(diagnostic_values));
    return 0;
}

static void refresh_diagnostics_ui(void)
{
    const struct device_status *device = &ui_network_status.device;
    int modems_ok = 1, address_ok = 1, paths_ok = 1, thermal_ok = 1;
    int data_ok, singbox_ok, row_fails = 0, alerts;
    char text[96];
    if (!diagnostics_page) return;
    for (int i = 0; i < NETWORK_MODEM_COUNT; i++) {
        const struct modem_status *modem = &ui_network_status.modems[i];
        if (!modem->valid || !modem->online || !modem->sim_ready) modems_ok = 0;
        if (!modem->ipv4_up || !modem->ipv4_address[0] || !modem->ipv4_dns[0])
            address_ok = 0;
        if (!modem->path_valid || !modem->path_online) paths_ok = 0;
        if (modem->temperature_valid && modem->temperature >= 70) thermal_ok = 0;
    }
    if (device->cpu_temp >= 75 || device->battery_temp >= 45 ||
        !device->fan_thermal_enabled ||
        (!strcmp(device->fan_mode, "automatic") &&
         !device->fan_kernel_zone_enabled) ||
        !device->liquid_thermal_enabled)
        thermal_ok = 0;
    data_ok = ui_network_status.valid && device->valid && !ui_network_status.stale;
    singbox_ok = !ui_status.valid || ui_status.service_running;
    if (!data_ok) row_fails++;
    if (!modems_ok) row_fails++;
    if (!address_ok) row_fails++;
    if (!paths_ok) row_fails++;
    if (!singbox_ok) row_fails++;
    if (!thermal_ok) row_fails++;
    /* 总计必须可解释：未读短信/流量限额没有对应明细行，计入并点名。
     * 原实现直接套 device_alert_count()，导致“6 行全绿却显示 1 项需要关注”。 */
    alerts = row_fails;
    if (device->sms_unread > 0) alerts++;
    if (device->traffic_limit_overflow ||
        (device->traffic_limit_enabled && device->traffic_limit_ratio >= 90))
        alerts++;
    if (!alerts) {
        snprintf(text, sizeof(text), "全部检查通过");
    } else if (device->sms_unread > 0) {
        snprintf(text, sizeof(text), "%d 项需要关注 · 未读短信 %d 条",
                 alerts, device->sms_unread);
    } else if (device->traffic_limit_overflow ||
               (device->traffic_limit_enabled && device->traffic_limit_ratio >= 90)) {
        snprintf(text, sizeof(text), "%d 项需要关注 · 流量达限额", alerts);
    } else {
        snprintf(text, sizeof(text), "%d 项需要关注", alerts);
    }
    set_label_text_if_changed(diagnostic_overall_label, text);
    set_text_color(diagnostic_overall_label, alerts ? COLOR_AMBER : COLOR_GREEN);
    set_label_text_if_changed(diagnostic_values[0], diagnostic_result(
        data_ok, "正常 · 每秒更新", "不可用或数据延迟"));
    set_label_text_if_changed(diagnostic_values[1], diagnostic_result(
        modems_ok, "3/3 在线", "检查离线卡或 SIM"));
    set_label_text_if_changed(diagnostic_values[2], diagnostic_result(
        address_ok, "IPv4 与 DNS 正常", "地址或 DNS 缺失"));
    set_label_text_if_changed(diagnostic_values[3], diagnostic_result(
        paths_ok, "3/3 路径在线", "路径探测异常"));
    set_label_text_if_changed(diagnostic_values[4], diagnostic_result(
        singbox_ok, ui_status.service_running ? "运行正常" : "未启用",
        "服务未运行"));
    set_label_text_if_changed(diagnostic_values[5], diagnostic_result(
        thermal_ok, "温度与保护正常", "高温或温控被关闭"));
}

static void device_refresh_clicked(void *event)
{
    (void)event;
    queue_action(ACTION_STATE_REFRESH);
}

static void refresh_device_ui(void)
{
    const struct device_status *device = &ui_network_status.device;
    char text[160], a[32], b[32], message[160];
    int alerts = device_alert_count();
    if (menu_device_alert_label) {
        snprintf(text, sizeof(text), alerts ? "%d项" : "正常", alerts);
        set_label_text_if_changed(menu_device_alert_label, text);
        if (lv_obj_update_layout_p)
            lv_obj_update_layout_p(menu_device_alert_label);
        lv_obj_align_p(menu_device_alert_label, LV_ALIGN_CENTER, 0, 0);
        set_text_color(menu_device_alert_label, alerts ? COLOR_AMBER : COLOR_GREEN);
        if (menu_device_alert_badge)
            style_surface(menu_device_alert_badge,
                          alerts ? 0x2B2412u : 0x15231Cu,
                          alerts ? COLOR_AMBER : COLOR_GREEN, 11, 1);
    }
    if (!device_page && !cooling_curve_page && !diagnostics_page) return;
    if (device_alert_dot)
        set_network_dot(device_alert_dot, alerts ? COLOR_AMBER : COLOR_GREEN);
    if (device_alert_label) {
        snprintf(text, sizeof(text), alerts ? "%d 项需要关注" : "设备状态正常", alerts);
        set_label_text_if_changed(device_alert_label, text);
        set_text_color(device_alert_label, alerts ? COLOR_AMBER : COLOR_GREEN);
    }
    pthread_mutex_lock(&shared_lock);
    safe_copy(message, sizeof(message),
              shared_message_page == PAGE_DEVICE ? shared_message : "");
    pthread_mutex_unlock(&shared_lock);
    if (device_message_label) set_label_text_if_changed(device_message_label, message);
    if (device_system_values[0]) {
        snprintf(text, sizeof(text), "%d%% · %d°C", device->battery_percent,
                 device->battery_temp);
        set_label_text_if_changed(device_system_values[0], text);
        snprintf(text, sizeof(text), "%s · %.2fV",
                 device->charger_connected ?
                 (device->battery_percent >= 100 ? "已充满" : "充电中") : "电池供电",
                 device->battery_uv / 1000000.0);
        set_label_text_if_changed(device_system_values[1], text);
        snprintf(text, sizeof(text), "%d%%", device->cpu_usage);
        set_label_text_if_changed(device_system_values[2], text);
        snprintf(text, sizeof(text), "%d°C", device->cpu_temp);
        set_label_text_if_changed(device_system_values[3], text);
        format_bytes_compact(device->mem_total - device->mem_avail, a, sizeof(a));
        format_bytes_compact(device->mem_total, b, sizeof(b));
        snprintf(text, sizeof(text), "%s / %s · %d%%", a, b, device->mem_used_pct);
        set_label_text_if_changed(device_system_values[4], text);
        format_bytes_compact(device->storage_used, a, sizeof(a));
        format_bytes_compact(device->storage_total, b, sizeof(b));
        snprintf(text, sizeof(text), "%s / %s", a, b);
        set_label_text_if_changed(device_system_values[5], text);
        format_duration_compact((unsigned long long)device->uptime, text, sizeof(text));
        set_label_text_if_changed(device_system_values[6], text);
    }
    if (device_traffic_values[0].label) {
        unsigned long long values[8] = {
            device->traffic_rx_rate, device->traffic_tx_rate,
            device->traffic_day_rx, device->traffic_day_tx,
            device->traffic_month_rx, device->traffic_month_tx,
            device->traffic_total_rx, device->traffic_total_tx
        };
        for (int i = 0; i < 8; i++) {
            if (i < 2) format_rate_compact(values[i], text, sizeof(text));
            else format_bytes_compact(values[i], text, sizeof(text));
            set_traffic_value(&device_traffic_values[i], text);
        }
    }
    refresh_cooling_overview_ui();
    refresh_cooling_curve_ui();
    refresh_wifi_power_ui();
    refresh_diagnostics_ui();
}

static void open_device_clicked(void *event)
{
    (void)event;
    pending_device_view = 1;
}

static void destroy_device_pages(void)
{
    if (device_page && lv_obj_del_p) lv_obj_del_p(device_page);
    if (cooling_curve_page && lv_obj_del_p) lv_obj_del_p(cooling_curve_page);
    if (diagnostics_page && lv_obj_del_p) lv_obj_del_p(diagnostics_page);
    device_page = cooling_curve_page = diagnostics_page = NULL;
    memset(&device_shell, 0, sizeof(device_shell));
    memset(&cooling_curve_shell, 0, sizeof(cooling_curve_shell));
    memset(&diagnostics_shell, 0, sizeof(diagnostics_shell));
    confirm_scrim = confirm_panel = confirm_text_label = NULL;
    device_alert_dot = device_alert_label = device_message_label = NULL;
    memset(device_tab_buttons, 0, sizeof(device_tab_buttons));
    device_tab_content = NULL;
    memset(device_system_values, 0, sizeof(device_system_values));
    memset(device_traffic_values, 0, sizeof(device_traffic_values));
    device_fan_status = NULL;
    device_fan_detail = NULL;
    device_liquid_status = NULL;
    device_liquid_detail = NULL;
    memset(device_fan_buttons, 0, sizeof(device_fan_buttons));
    memset(device_liquid_buttons, 0, sizeof(device_liquid_buttons));
    cooling_curve_summary = cooling_curve_point_label = NULL;
    cooling_curve_temperature_value = cooling_curve_speed_value = NULL;
    cooling_curve_message_label = cooling_curve_chart = NULL;
    memset(cooling_curve_profile_buttons, 0,
           sizeof(cooling_curve_profile_buttons));
    cooling_curve_factory_content = cooling_curve_custom_content = NULL;
    memset(cooling_curve_factory_temperature, 0,
           sizeof(cooling_curve_factory_temperature));
    memset(cooling_curve_factory_speed, 0,
           sizeof(cooling_curve_factory_speed));
    cooling_curve_series = NULL;
    cooling_curve_draft_valid = 0;
    cooling_curve_draft_dirty = 0;
    cooling_curve_draft_count = 0;
    cooling_curve_active_point = 0;
    memset(device_wifi_band_buttons, 0, sizeof(device_wifi_band_buttons));
    device_wifi_header = device_wifi_state = NULL;
    device_wifi_percent_value = device_wifi_limit_value = NULL;
    device_wifi_restore_button = device_wifi_apply_button = NULL;
    diagnostic_overall_label = NULL;
    memset(diagnostic_values, 0, sizeof(diagnostic_values));
}

static void process_device_navigation(void)
{
    int view = pending_device_view;
    if (!view || !network_parent) return;
    pending_device_view = 0;
    destroy_singbox_page();
    destroy_wanbal_page();
    destroy_network_identity();
    destroy_network_detail();
    destroy_network_overview();
    destroy_device_pages();
    trace_ui_create(view == 1 ? "device-create-page" :
                    (view == 2 ? "device-create-diagnostics" :
                     "device-create-cooling-curve"));
    if (view == 1) {
        if (!create_device_page(network_parent)) return;
        show_page(PAGE_DEVICE);
    } else if (view == 2) {
        if (!create_diagnostics_page(network_parent)) return;
        show_page(PAGE_DIAGNOSTICS);
    } else {
        if (!create_cooling_curve_page(network_parent)) return;
        show_page(PAGE_COOLING_CURVE);
    }
    pthread_mutex_lock(&shared_lock);
    force_refresh = 1;
    force_network_refresh = 1;
    pthread_mutex_unlock(&shared_lock);
    refresh_device_ui();
}
