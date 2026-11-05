static int resolve_lvgl(void)
{
#define RESOLVE(name) name##_p = (void *)dlsym(RTLD_NEXT, #name)
    RESOLVE(lv_disp_get_default); RESOLVE(lv_disp_get_layer_top); RESOLVE(lv_disp_get_scr_act);
    RESOLVE(lv_obj_create); RESOLVE(lv_obj_del); RESOLVE(lv_obj_get_child_cnt); RESOLVE(lv_obj_get_child);
    RESOLVE(lv_obj_has_flag);
    RESOLVE(lv_btn_create); RESOLVE(lv_label_create); RESOLVE(lv_label_set_text);
    RESOLVE(lv_label_get_text);
    RESOLVE(lv_img_create); RESOLVE(lv_img_set_src); RESOLVE(lv_img_set_zoom);
    RESOLVE(lv_imgbtn_create); RESOLVE(lv_imgbtn_set_src);
    RESOLVE(lv_label_set_long_mode); RESOLVE(lv_obj_set_size); RESOLVE(lv_obj_set_pos);
    RESOLVE(lv_obj_align); RESOLVE(lv_obj_update_layout); RESOLVE(lv_obj_add_event_cb); RESOLVE(lv_obj_add_flag);
    RESOLVE(lv_obj_clear_flag); RESOLVE(lv_obj_add_state); RESOLVE(lv_obj_clear_state);
    RESOLVE(lv_obj_set_style_radius); RESOLVE(lv_obj_set_style_border_width);
    RESOLVE(lv_obj_set_style_shadow_width);
    RESOLVE(lv_obj_set_style_pad_left); RESOLVE(lv_obj_set_style_pad_right);
    RESOLVE(lv_obj_set_style_pad_top); RESOLVE(lv_obj_set_style_pad_bottom);
    RESOLVE(lv_obj_set_style_text_align);
    RESOLVE(lv_obj_set_style_bg_color); RESOLVE(lv_obj_set_style_bg_opa);
    RESOLVE(lv_obj_set_style_border_color); RESOLVE(lv_obj_set_style_shadow_color);
    RESOLVE(lv_obj_set_style_shadow_opa); RESOLVE(lv_obj_set_style_text_color);
    RESOLVE(lv_chart_create); RESOLVE(lv_chart_set_type);
    RESOLVE(lv_chart_set_point_count); RESOLVE(lv_chart_set_range);
    RESOLVE(lv_chart_add_series); RESOLVE(lv_chart_set_next_value);
    RESOLVE(lv_chart_refresh);
    RESOLVE(lv_obj_check_type); RESOLVE(lv_obj_get_coords);
    RESOLVE(lv_obj_get_parent);
    lv_label_class_p = dlsym(RTLD_NEXT, "lv_label_class");
    real_obj_set_style_text_font = (obj_set_style_text_font_fn)
        dlsym(RTLD_NEXT, "lv_obj_set_style_text_font");
    lv_ft_font_init_p = (ft_font_init_fn)dlsym(RTLD_NEXT, "lv_ft_font_init");
#undef RESOLVE
    return lv_disp_get_default_p && lv_disp_get_layer_top_p && lv_obj_create_p && lv_obj_del_p && lv_btn_create_p &&
           lv_label_create_p && lv_label_set_text_p && lv_img_create_p && lv_img_set_src_p &&
           lv_obj_set_size_p && lv_obj_set_pos_p &&
           lv_obj_align_p && lv_obj_add_event_cb_p && lv_obj_add_flag_p && lv_obj_clear_flag_p &&
           lv_obj_add_state_p && lv_obj_clear_state_p && lv_obj_set_style_bg_color_p &&
           lv_obj_set_style_bg_opa_p && lv_obj_set_style_border_color_p &&
           lv_obj_set_style_text_color_p;
}

static void trace_ui_create(const char *stage)
{
    FILE *log = fopen("/tmp/touchui-create.log", "a");
    if (!log) return;
    fprintf(log, "%s\n", stage);
    fclose(log);
}

static int create_menu_page(lv_obj_t *top)
{
    static const struct menu_module modules[] = {
        {"网络仪表", "三卡信号、QCI、AMBR 与实时速率", open_network_clicked},
        {"Sing-box", "服务、数据面、流量与启停", open_singbox_clicked},
        {"分流", "自动质量或三卡共池", open_wanbal_clicked},
        {"设备状态", "系统、流量、散热、无线与诊断", open_device_clicked}
    };
    if (!page_shell_init(&menu_shell, top, PAGE_MENU, "控制中心",
                         close_menu_clicked)) return 0;
    menu_page = menu_shell.root;
    /* 4 rows on 320x480: tighter pitch than the old 3-row layout. */
    for (size_t i = 0; i < sizeof(modules) / sizeof(modules[0]); i++) {
        int y = 56 + (int)i * 98;
        lv_obj_t *button, *label, *description;
        button = make_button(menu_page, modules[i].title, 8, y, 304, 58,
                             modules[i].open, &label);
        if (!button) return 0;
        style_button(button, COLOR_CARD, COLOR_BUTTON_PRESSED,
                     COLOR_CARD, COLOR_ACCENT_SOFT);
        set_text_color(label, COLOR_TEXT);
        description = make_single_line_label(menu_page, modules[i].description,
                                             24, y + 62, 280, 22);
        set_text_color(description, COLOR_MUTED);
        if (i == 3) {
            menu_device_alert_badge = make_panel(button, 238, 8, 54, 22,
                                                 0x15231Cu);
            if (menu_device_alert_badge)
                style_surface(menu_device_alert_badge, 0x15231Cu,
                              COLOR_GREEN, 11, 1);
            menu_device_alert_label = menu_device_alert_badge ?
                make_single_line_label(menu_device_alert_badge,
                                       "读取中", 0, 0, 0, 0) : NULL;
            if (menu_device_alert_label && ui_font_tiny &&
                real_obj_set_style_text_font)
                real_obj_set_style_text_font(menu_device_alert_label,
                                             ui_font_tiny, 0);
            if (menu_device_alert_label) {
                if (lv_obj_update_layout_p)
                    lv_obj_update_layout_p(menu_device_alert_label);
                lv_obj_align_p(menu_device_alert_label, LV_ALIGN_CENTER, 0, 0);
            }
            set_text_color(menu_device_alert_label, COLOR_MUTED);
        }
    }
    return 1;
}

static void add_control_center_ui(void)
{
    lv_obj_t *top, *unused;
    pthread_t worker;
    pthread_attr_t worker_attr;
    FILE *font_log;
    overlay_state = -1;
    unlink("/tmp/touchui-create.log");
    trace_ui_create("begin");
    if (!resolve_lvgl() || !(top = lv_disp_get_layer_top_p(lv_disp_get_default_p()))) return;
    trace_ui_create("lvgl-ready");
    if (!ui_font) {
        /* 字体只初始化一次：失败重试路径不重复 init，防泄漏（M18） */
        ui_font_info.font = NULL;
        if (lv_ft_font_init_p && lv_ft_font_init_p(&ui_font_info))
            ui_font = ui_font_info.font;
        else
            ui_font = dlsym(RTLD_NEXT, "lv_font_simsun_16_cjk");
        ui_font_tiny_info.font = NULL;
        if (lv_ft_font_init_p && lv_ft_font_init_p(&ui_font_tiny_info))
            ui_font_tiny = ui_font_tiny_info.font;
        else
            ui_font_tiny = ui_font;
        ui_font_small_info.font = NULL;
        if (lv_ft_font_init_p && lv_ft_font_init_p(&ui_font_small_info))
            ui_font_small = ui_font_small_info.font;
        else
            ui_font_small = ui_font;
        ui_font_large_info.font = NULL;
        if (lv_ft_font_init_p && lv_ft_font_init_p(&ui_font_large_info))
            ui_font_large = ui_font_large_info.font;
        else
            ui_font_large = ui_font;
        ui_font_xlarge_info.font = NULL;
        if (lv_ft_font_init_p && lv_ft_font_init_p(&ui_font_xlarge_info))
            ui_font_xlarge = ui_font_xlarge_info.font;
        else
            ui_font_xlarge = ui_font_large;
    }
    font_log = fopen("/tmp/touchui-font.log", "w");
    if (font_log) {
        fprintf(font_log, "source=%s line_height=%d tiny_line_height=%d small_line_height=%d large_line_height=%d xlarge_line_height=%d theme=dark\n",
                ui_font_info.font ? "zte-freetype" : "simsun-fallback",
                ui_font ? font_line_height(ui_font) : 0,
                ui_font_tiny ? font_line_height(ui_font_tiny) : 0,
                ui_font_small ? font_line_height(ui_font_small) : 0,
                ui_font_large ? font_line_height(ui_font_large) : 0,
                ui_font_xlarge ? font_line_height(ui_font_xlarge) : 0);
        fclose(font_log);
    }
    if (!control_center_button) {
        /* 按钮只创建一次：失败重试路径不重复创建（M18） */
        control_center_button = make_button(top, "控制中心", 204, 424, 104, 42,
                                            open_menu_clicked, &unused);
        if (!control_center_button) return;
    }
    trace_ui_create("launcher-ready");
    style_button(control_center_button, COLOR_ACCENT_DARK, COLOR_ACCENT,
                 COLOR_ACCENT_DARK, COLOR_ACCENT_SOFT);
    if (!create_menu_page(top)) return;
    trace_ui_create("menu-ready");
    network_parent = top;
    trace_ui_create("network-deferred");
    /* The hook is already mapped. Do not preload it into manager commands or
     * the many UCI, ubus, curl and jsonfilter processes they launch. */
    unsetenv("LD_PRELOAD");
    if (!worker_started) {
        pthread_attr_init(&worker_attr);
        pthread_attr_setstacksize(&worker_attr, STATUS_WORKER_STACK_SIZE);
        if (pthread_create(&worker, &worker_attr, status_worker, NULL) == 0) {
            pthread_detach(worker);
            worker_started = 1;
        }
        pthread_attr_destroy(&worker_attr);
    }
    current_page = PAGE_STOCK;
    overlay_state = 1;
    trace_ui_create("complete");
    native_lock_state = -1;
    sync_native_lock_visibility();
}

uint32_t lv_timer_handler(void)
{
    uint32_t wait_ms = 5;
    if (!real_timer_handler) real_timer_handler = (timer_handler_fn)dlsym(RTLD_NEXT, "lv_timer_handler");
    if (real_timer_handler) wait_ms = real_timer_handler();
    if (overlay_state == 0 && ++timer_calls >= 20) add_control_center_ui();
    else if (overlay_state == -1 && ++timer_calls >= 2000) {
        /* 注入失败：低频退避重试（M18 复核——原实现失败后永不重试，UI 静默缺失；
         * 2000 tick ≈ 10s 有界退避，成功即置 1 停止，非每 tick 自旋） */
        timer_calls = 0;
        add_control_center_ui();
    }
    if (overlay_state == 1) {
        process_network_navigation();
        process_device_navigation();
        refresh_ui();
        refresh_wanbal_ui();
        refresh_network_ui();
        refresh_wifi_power_ui();
        refresh_page_clocks();
        sync_native_lock_visibility();
        patch_stock_speed_page();
    }
    return wait_ms;
}

int mu5252_touchui_overlay_state(void) { return overlay_state; }
