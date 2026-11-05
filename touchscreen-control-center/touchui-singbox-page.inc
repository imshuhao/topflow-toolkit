static void destroy_singbox_page(void);

static int create_singbox_page(lv_obj_t *top)
{
    lv_obj_t *title_label;
    lv_obj_t *divider;
    if (!page_shell_init(&singbox_shell, top, PAGE_SINGBOX, "Sing-box",
                         feature_back_clicked)) return 0;
    manager_page = singbox_shell.root;

    make_panel(manager_page, 8, 48, 304, 117, COLOR_CARD);
    make_panel(manager_page, 8, 168, 304, 59, COLOR_CARD_ALT);
    make_panel(manager_page, 8, 284, 304, 82, COLOR_CARD);

    status_indicator = lv_obj_create_p(manager_page);
    if (status_indicator) {
        lv_obj_set_size_p(status_indicator, 9, 9);
        lv_obj_set_pos_p(status_indicator, 16,
                         center_marker_on_text_line(58, ui_font, 9));
        lv_obj_clear_flag_p(status_indicator, LV_OBJ_FLAG_SCROLLABLE);
        style_surface(status_indicator, COLOR_MUTED, COLOR_MUTED, 9, 0);
        if (lv_obj_set_style_shadow_width_p)
            lv_obj_set_style_shadow_width_p(status_indicator, 8, 0);
        set_shadow_color(status_indicator, COLOR_MUTED);
        if (lv_obj_set_style_shadow_opa_p)
            lv_obj_set_style_shadow_opa_p(status_indicator, 31, 0);
    }
    status_label = make_single_line_label(manager_page, "状态读取中…", 32, 58, 168, 25);
    set_text_color(status_label, COLOR_MUTED);
    status_mode_label = make_single_line_label(manager_page, "等待数据", 228, 58, 76, 25);
    set_text_color(status_mode_label, COLOR_MUTED);
    divider = lv_obj_create_p(manager_page);
    if (divider) {
        lv_obj_set_size_p(divider, 288, 1);
        lv_obj_set_pos_p(divider, 16, 88);
        lv_obj_clear_flag_p(divider, LV_OBJ_FLAG_SCROLLABLE);
        style_surface(divider, COLOR_BORDER, COLOR_BORDER, 0, 0);
    }
    title_label = make_single_line_label(manager_page, "核心", 16, 97, 42, 24);
    set_text_color(title_label, COLOR_MUTED);
    version_label = make_single_line_label(manager_page, "未知", 62, 97, 84, 24);
    title_label = make_single_line_label(manager_page, "内存", 164, 97, 42, 24);
    set_text_color(title_label, COLOR_MUTED);
    memory_label = make_single_line_label(manager_page, "--", 208, 97, 96, 24);
    title_label = make_single_line_label(manager_page, "数据面", 16, 128, 54, 24);
    set_text_color(title_label, COLOR_MUTED);
    tun_value_label = make_single_line_label(manager_page, "未知", 74, 128, 74, 24);
    title_label = make_single_line_label(manager_page, "DHCP", 164, 128, 50, 24);
    set_text_color(title_label, COLOR_MUTED);
    dhcp_value_label = make_single_line_label(manager_page, "未知", 217, 128, 87, 24);

    title_label = make_single_line_label(manager_page, "流量", 16, 184, 42, 24);
    set_text_color(title_label, COLOR_TEXT);
    title_label = make_single_line_label(manager_page, "实时", 65, 171, 42, 24);
    set_text_color(title_label, COLOR_MUTED);
    traffic_rate_down = make_download_value(manager_page, 108, 171,
                                            69, ui_font_small);
    traffic_rate_up = make_upload_value(manager_page, 198, 171,
                                        89, ui_font_small);
    title_label = make_single_line_label(manager_page, "累计", 65, 198, 42, 24);
    set_text_color(title_label, COLOR_MUTED);
    traffic_total_down = make_download_value(manager_page, 108, 198,
                                             69, ui_font_small);
    traffic_total_up = make_upload_value(manager_page, 198, 198,
                                          89, ui_font_small);
    service_button = make_button(manager_page, "启动服务", 14, 235, 142, 44,
                                 service_clicked, &service_button_label);
    restart_button = make_button(manager_page, "重启服务", 164, 235, 142, 44,
                                 restart_clicked, &restart_button_label);
    style_button(service_button, COLOR_BUTTON, COLOR_BUTTON_PRESSED,
                 COLOR_BUTTON_PRESSED, COLOR_ACCENT_SOFT);
    style_button(restart_button, COLOR_BUTTON, COLOR_BUTTON_PRESSED,
                 COLOR_BUTTON_PRESSED, COLOR_ACCENT_SOFT);

    title_label = make_single_line_label(manager_page, "订阅", 16, 292, 60, 22);
    set_text_color(title_label, COLOR_MUTED);
    providers_label = make_single_line_label(manager_page, "--", 86, 292, 70, 22);
    title_label = make_single_line_label(manager_page, "看门狗", 176, 292, 70, 22);
    set_text_color(title_label, COLOR_MUTED);
    watchdog_label = make_single_line_label(manager_page, "--", 248, 292, 56, 22);
    title_label = make_single_line_label(manager_page, "DHCP keeper", 16, 320, 110, 22);
    set_text_color(title_label, COLOR_MUTED);
    keeper_label = make_single_line_label(manager_page, "--", 132, 320, 120, 22);

    message_label = make_label(manager_page, "", 14, 376, 292, 48);
    set_text_color(message_label, COLOR_MESSAGE);
    updated_label = singbox_shell.clock_label;

    /* Critical controls missing → fail whole page (avoid half-init UI). */
    if (!status_label || !status_mode_label || !version_label ||
        !memory_label || !tun_value_label || !dhcp_value_label ||
        !providers_label || !watchdog_label || !keeper_label ||
        !service_button || !restart_button || !message_label) {
        trace_ui_create("singbox-allocation-failed");
        destroy_singbox_page();
        return 0;
    }
    if (!create_confirmation_overlay(manager_page)) {
        trace_ui_create("singbox-overlay-failed");
        destroy_singbox_page();
        return 0;
    }
    return 1;
}

static void request_singbox_page(void)
{
    pending_singbox_open = 1;
}

static void destroy_singbox_page(void)
{
    if (manager_page && lv_obj_del_p) lv_obj_del_p(manager_page);
    manager_page = NULL;
    memset(&singbox_shell, 0, sizeof(singbox_shell));
    confirm_scrim = NULL;
    confirm_panel = NULL;
    confirm_text_label = NULL;
    confirm_action = ACTION_NONE;
    status_indicator = NULL;
    status_label = NULL;
    status_mode_label = NULL;
    version_label = NULL;
    memory_label = NULL;
    tun_value_label = NULL;
    dhcp_value_label = NULL;
    providers_label = NULL;
    watchdog_label = NULL;
    keeper_label = NULL;
    message_label = NULL;
    updated_label = NULL;
    service_button = NULL;
    service_button_label = NULL;
    restart_button = NULL;
    restart_button_label = NULL;
    memset(&traffic_rate_down, 0, sizeof(traffic_rate_down));
    memset(&traffic_rate_up, 0, sizeof(traffic_rate_up));
    memset(&traffic_total_down, 0, sizeof(traffic_total_down));
    memset(&traffic_total_up, 0, sizeof(traffic_total_up));
}
