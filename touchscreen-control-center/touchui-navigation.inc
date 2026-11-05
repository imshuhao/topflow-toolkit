static void queue_action_with_params(int action, int band, int value, int value2)
{
    pthread_mutex_lock(&shared_lock);
    if (!shared_action_running && shared_action == ACTION_NONE) {
        shared_action = action;
        shared_action_band = band;
        shared_action_value = value;
        shared_action_value2 = value2;
        /* FAN_CUSTOM 的 need_default 在 UI 线程入队时快照（M17）：
         * ui_network_status 为 UI 线程私有，worker 线程读取会撕裂 */
        if (action == ACTION_FAN_CUSTOM) {
            const struct device_status *device = &ui_network_status.device;
            shared_action_fan_need_default =
                fan_custom_curve_is_off(device) || device->fan_custom_curve_count < 2;
        } else {
            shared_action_fan_need_default = 0;
        }
        safe_copy(shared_message, sizeof(shared_message), "操作已提交…");
        shared_message_page = message_page_for_action(action);
        shared_generation++;
    }
    pthread_mutex_unlock(&shared_lock);
}

static void queue_action(int action)
{
    queue_action_with_params(action, -1, 0, 0);
}

static void queue_fan_curve_action(void)
{
    pthread_mutex_lock(&shared_lock);
    if (!shared_action_running && shared_action == ACTION_NONE &&
        cooling_curve_draft_valid && cooling_curve_draft_count >= 2 &&
        cooling_curve_draft_count <= TOUCHUI_FAN_CURVE_MAX) {
        shared_action = ACTION_FAN_CURVE_APPLY;
        shared_action_curve_count = cooling_curve_draft_count;
        memcpy(shared_action_curve, cooling_curve_draft,
               sizeof(shared_action_curve));
        safe_copy(shared_message, sizeof(shared_message), "操作已提交…");
        shared_message_page = PAGE_DEVICE;
        shared_generation++;
    }
    pthread_mutex_unlock(&shared_lock);
}

static void hide_confirm(void)
{
    if (confirm_scrim) lv_obj_add_flag_p(confirm_scrim, LV_OBJ_FLAG_HIDDEN);
    if (confirm_panel) lv_obj_add_flag_p(confirm_panel, LV_OBJ_FLAG_HIDDEN);
    confirm_action = ACTION_NONE;
}

static void hide_extension_pages(void)
{
    if (menu_page) lv_obj_add_flag_p(menu_page, LV_OBJ_FLAG_HIDDEN);
    if (manager_page) lv_obj_add_flag_p(manager_page, LV_OBJ_FLAG_HIDDEN);
    if (wanbal_page) lv_obj_add_flag_p(wanbal_page, LV_OBJ_FLAG_HIDDEN);
    if (network_page) lv_obj_add_flag_p(network_page, LV_OBJ_FLAG_HIDDEN);
    if (network_detail_page)
        lv_obj_add_flag_p(network_detail_page, LV_OBJ_FLAG_HIDDEN);
    if (network_identity_page)
        lv_obj_add_flag_p(network_identity_page, LV_OBJ_FLAG_HIDDEN);
    if (device_page) lv_obj_add_flag_p(device_page, LV_OBJ_FLAG_HIDDEN);
    if (cooling_curve_page)
        lv_obj_add_flag_p(cooling_curve_page, LV_OBJ_FLAG_HIDDEN);
    if (diagnostics_page) lv_obj_add_flag_p(diagnostics_page, LV_OBJ_FLAG_HIDDEN);
}

static void show_page(enum page_id page)
{
    hide_confirm();
    hide_extension_pages();
    if (page != current_page &&
        (current_page == PAGE_SINGBOX || current_page == PAGE_WANBAL ||
         current_page == PAGE_DEVICE ||
         current_page == PAGE_COOLING_CURVE ||
         current_page == PAGE_DIAGNOSTICS)) {
        pthread_mutex_lock(&shared_lock);
        if (shared_message_page == message_page_for_page(current_page)) {
            shared_message[0] = '\0';
            shared_message_page = PAGE_STOCK;
        }
        shared_generation++;
        pthread_mutex_unlock(&shared_lock);
    }
    current_page = page;
    if (page == PAGE_MENU && menu_page)
        lv_obj_clear_flag_p(menu_page, LV_OBJ_FLAG_HIDDEN);
    else if (page == PAGE_NETWORK && network_page)
        lv_obj_clear_flag_p(network_page, LV_OBJ_FLAG_HIDDEN);
    else if (page == PAGE_NETWORK_DETAIL && network_detail_page)
        lv_obj_clear_flag_p(network_detail_page, LV_OBJ_FLAG_HIDDEN);
    else if (page == PAGE_NETWORK_IDENTITY && network_identity_page)
        lv_obj_clear_flag_p(network_identity_page, LV_OBJ_FLAG_HIDDEN);
    else if (page == PAGE_SINGBOX && manager_page) {
        lv_obj_clear_flag_p(manager_page, LV_OBJ_FLAG_HIDDEN);
        pthread_mutex_lock(&shared_lock);
        force_refresh = 1;
        pthread_mutex_unlock(&shared_lock);
    } else if (page == PAGE_WANBAL && wanbal_page) {
        lv_obj_clear_flag_p(wanbal_page, LV_OBJ_FLAG_HIDDEN);
        pthread_mutex_lock(&shared_lock);
        force_wanbal_refresh = 1;
        pthread_mutex_unlock(&shared_lock);
    } else if (page == PAGE_DEVICE && device_page)
        lv_obj_clear_flag_p(device_page, LV_OBJ_FLAG_HIDDEN);
    else if (page == PAGE_COOLING_CURVE && cooling_curve_page)
        lv_obj_clear_flag_p(cooling_curve_page, LV_OBJ_FLAG_HIDDEN);
    else if (page == PAGE_DIAGNOSTICS && diagnostics_page)
        lv_obj_clear_flag_p(diagnostics_page, LV_OBJ_FLAG_HIDDEN);
}

static void open_menu_clicked(void *event) { (void)event; show_page(PAGE_MENU); }
static void show_stock_page(void)
{
    show_page(PAGE_STOCK);
    pending_network_view = 0;
    pending_singbox_open = 0;
    pending_wanbal_open = 0;
    pending_device_view = 0;
    pending_extension_cleanup = 1;
}

static void close_menu_clicked(void *event) { (void)event; show_stock_page(); }
static void open_network_clicked(void *event) { (void)event; request_network_overview(); }
static void open_singbox_clicked(void *event) { (void)event; request_singbox_page(); }
static void open_wanbal_clicked(void *event) { (void)event; request_wanbal_page(); }
static void feature_back_clicked(void *event) { (void)event; show_page(PAGE_MENU); }
static void network_detail_back_clicked(void *event) { (void)event; request_network_overview(); }
static void network_identity_back_clicked(void *event) { (void)event; request_network_detail(); }

static void center_page_title(lv_obj_t *label)
{
    if (!label) return;
    if (lv_obj_update_layout_p) lv_obj_update_layout_p(label);
    lv_obj_align_p(label, LV_ALIGN_TOP_MID, 0, 13);
}

static int page_shell_init(struct page_shell *shell, lv_obj_t *top,
                           enum page_id id, const char *title,
                           void (*back_callback)(void *event))
{
    if (!shell) return 0;
    memset(shell, 0, sizeof(*shell));
    shell->id = id;
    shell->root = lv_obj_create_p(top);
    if (!shell->root) return 0;
    lv_obj_set_size_p(shell->root, 320, 480);
    lv_obj_set_pos_p(shell->root, 0, 0);
    lv_obj_clear_flag_p(shell->root, LV_OBJ_FLAG_SCROLLABLE);
    style_surface(shell->root, COLOR_BG, COLOR_BG, 0, 0);
    set_text_color(shell->root, COLOR_TEXT);
    if (lv_obj_set_style_pad_left_p) lv_obj_set_style_pad_left_p(shell->root, 0, 0);
    if (lv_obj_set_style_pad_right_p) lv_obj_set_style_pad_right_p(shell->root, 0, 0);
    if (lv_obj_set_style_pad_top_p) lv_obj_set_style_pad_top_p(shell->root, 0, 0);
    if (lv_obj_set_style_pad_bottom_p) lv_obj_set_style_pad_bottom_p(shell->root, 0, 0);

    /* Auto-size the label, then center the label object itself.  Fixed-width
     * text alignment is unreliable with this vendor FreeType/LVGL build. */
    shell->title_label = make_single_line_label(shell->root, title, 0, 0, 0, 0);
    center_page_title(shell->title_label);
    if (!make_back_button(shell->root, 0, 0, back_callback))
        make_button(shell->root, "<", 6, 4, 40, 40, back_callback, NULL);
    if (!make_home_button(shell->root, 220, 0, close_menu_clicked))
        make_button(shell->root, "主页", 270, 4, 44, 36,
                    close_menu_clicked, NULL);
    shell->footer_label = make_single_line_label(shell->root, "",
                                                 14, 450, 200, 22);
    set_text_color(shell->footer_label, COLOR_MUTED);
    shell->clock_label = make_single_line_label(shell->root, "--:--:--",
                                                230, 450, 78, 22);
    set_text_color(shell->clock_label, COLOR_MUTED);
    lv_obj_add_flag_p(shell->root, LV_OBJ_FLAG_HIDDEN);
    return 1;
}

static void refresh_page_clocks(void)
{
    static time_t last_second;
    time_t now = time(NULL);
    struct tm tm_value;
    char clock[16];
    if (now == last_second) return;
    last_second = now;
    localtime_r(&now, &tm_value);
    strftime(clock, sizeof(clock), "%H:%M:%S", &tm_value);
    if (menu_shell.clock_label) lv_label_set_text_p(menu_shell.clock_label, clock);
    if (singbox_shell.clock_label) lv_label_set_text_p(singbox_shell.clock_label, clock);
    if (network_shell.clock_label) lv_label_set_text_p(network_shell.clock_label, clock);
    if (network_detail_shell.clock_label)
        lv_label_set_text_p(network_detail_shell.clock_label, clock);
    if (network_identity_shell.clock_label)
        lv_label_set_text_p(network_identity_shell.clock_label, clock);
    if (device_shell.clock_label)
        lv_label_set_text_p(device_shell.clock_label, clock);
    if (cooling_curve_shell.clock_label)
        lv_label_set_text_p(cooling_curve_shell.clock_label, clock);
    if (diagnostics_shell.clock_label)
        lv_label_set_text_p(diagnostics_shell.clock_label, clock);
    if (singbox_shell.footer_label)
        lv_label_set_text_p(singbox_shell.footer_label,
                            ui_status.stale ? "数据延迟" : "");
    if (network_shell.footer_label)
        lv_label_set_text_p(network_shell.footer_label,
                            ui_network_status.stale ? "数据延迟" : "");
    if (network_detail_shell.footer_label)
        lv_label_set_text_p(network_detail_shell.footer_label,
                            ui_network_status.stale ? "数据延迟" : "");
    if (network_identity_shell.footer_label)
        lv_label_set_text_p(network_identity_shell.footer_label,
                            ui_network_status.stale ? "数据延迟" : "");
    if (device_shell.footer_label)
        lv_label_set_text_p(device_shell.footer_label,
                            ui_network_status.stale ? "数据延迟" : "");
    if (cooling_curve_shell.footer_label)
        lv_label_set_text_p(cooling_curve_shell.footer_label,
                            ui_network_status.stale ? "数据延迟" : "");
    if (diagnostics_shell.footer_label)
        lv_label_set_text_p(diagnostics_shell.footer_label,
                            ui_network_status.stale ? "数据延迟" : "");
}

static int native_lock_screen_visible(void)
{
    lv_disp_t *disp;
    lv_obj_t *screen, *lock_layer;
    if (!lv_disp_get_default_p || !lv_disp_get_scr_act_p ||
        !lv_obj_get_child_cnt_p || !lv_obj_get_child_p || !lv_obj_has_flag_p)
        return 0;
    disp = lv_disp_get_default_p();
    screen = disp ? lv_disp_get_scr_act_p(disp) : NULL;
    if (!screen || lv_obj_get_child_cnt_p(screen) < 3) return 0;
    lock_layer = lv_obj_get_child_p(screen, 2);
    return lock_layer && !lv_obj_has_flag_p(lock_layer, LV_OBJ_FLAG_HIDDEN);
}

static void sync_native_lock_visibility(void)
{
    int locked = native_lock_screen_visible();
    if (locked == native_lock_state) return;
    native_lock_state = locked;
    if (locked) {
        show_stock_page();
        if (control_center_button)
            lv_obj_add_flag_p(control_center_button, LV_OBJ_FLAG_HIDDEN);
    } else if (control_center_button) {
        lv_obj_clear_flag_p(control_center_button, LV_OBJ_FLAG_HIDDEN);
    }
}

static void show_confirm(int action, const char *text)
{
    confirm_action = action;
    if (confirm_text_label) lv_label_set_text_p(confirm_text_label, text);
    if (confirm_scrim) lv_obj_clear_flag_p(confirm_scrim, LV_OBJ_FLAG_HIDDEN);
    if (confirm_panel) lv_obj_clear_flag_p(confirm_panel, LV_OBJ_FLAG_HIDDEN);
}

static void service_clicked(void *event)
{
    (void)event;
    if (ui_status.service_running)
        show_confirm(ACTION_SERVICE_STOP,
                     "停止 Sing-box 后客户端将直连（不再经过代理），确认继续？");
    else
        show_confirm(ACTION_SERVICE_START, "启动 Sing-box 服务？");
}

static void restart_clicked(void *event)
{
    (void)event;
    show_confirm(ACTION_SERVICE_RESTART,
                 "重启期间代理会中断约 5–15 秒，确认继续？");
}
static void confirm_clicked(void *event)
{
    int action = confirm_action;
    (void)event;
    hide_confirm();
    if (action == ACTION_WIFI_APPLY)
        queue_action_with_params(action, pending_wifi_band,
                                 pending_wifi_value, pending_wifi_value2);
    else if (action == ACTION_FAN_CURVE_APPLY)
        queue_fan_curve_action();
    else if (action) queue_action(action);
}
static void cancel_clicked(void *event) { (void)event; hide_confirm(); }

static int create_confirmation_overlay(lv_obj_t *parent)
{
    lv_obj_t *title, *cancel_button, *accept_button;
    confirm_scrim = lv_obj_create_p(parent);
    if (!confirm_scrim) return 0;
    lv_obj_set_size_p(confirm_scrim, 320, 480);
    lv_obj_set_pos_p(confirm_scrim, 0, 0);
    lv_obj_clear_flag_p(confirm_scrim, LV_OBJ_FLAG_SCROLLABLE);
    style_surface(confirm_scrim, 0x000000u, 0x000000u, 0, 0);
    if (lv_obj_set_style_bg_opa_p)
        lv_obj_set_style_bg_opa_p(confirm_scrim, 178, 0);
    confirm_panel = lv_obj_create_p(parent);
    if (!confirm_panel) return 0;
    lv_obj_set_size_p(confirm_panel, 290, 190);
    lv_obj_set_pos_p(confirm_panel, 15, 145);
    lv_obj_clear_flag_p(confirm_panel, LV_OBJ_FLAG_SCROLLABLE);
    style_surface(confirm_panel, COLOR_CARD, COLOR_BORDER, 16, 1);
    if (lv_obj_set_style_pad_left_p) lv_obj_set_style_pad_left_p(confirm_panel, 0, 0);
    if (lv_obj_set_style_pad_right_p) lv_obj_set_style_pad_right_p(confirm_panel, 0, 0);
    if (lv_obj_set_style_pad_top_p) lv_obj_set_style_pad_top_p(confirm_panel, 0, 0);
    if (lv_obj_set_style_pad_bottom_p) lv_obj_set_style_pad_bottom_p(confirm_panel, 0, 0);
    if (lv_obj_set_style_shadow_width_p)
        lv_obj_set_style_shadow_width_p(confirm_panel, 24, 0);
    set_shadow_color(confirm_panel, 0x000000u);
    if (lv_obj_set_style_shadow_opa_p)
        lv_obj_set_style_shadow_opa_p(confirm_panel, 153, 0);
    title = make_single_line_label(confirm_panel, "确认操作", 14, 12, 250, 25);
    set_text_color(title, COLOR_TEXT);
    confirm_text_label = make_label(confirm_panel, "", 14, 45, 250, 72);
    set_text_color(confirm_text_label, COLOR_MUTED);
    cancel_button = make_button(confirm_panel, "取消", 18, 132, 110, 42,
                                cancel_clicked, NULL);
    accept_button = make_button(confirm_panel, "确认", 146, 132, 110, 42,
                                confirm_clicked, NULL);
    style_button(cancel_button, COLOR_BUTTON, COLOR_BUTTON_PRESSED,
                 COLOR_BUTTON_PRESSED, COLOR_BORDER);
    style_button(accept_button, COLOR_ACCENT_DARK, COLOR_ACCENT,
                 COLOR_ACCENT_DARK, COLOR_ACCENT_SOFT);
    lv_obj_add_flag_p(confirm_scrim, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag_p(confirm_panel, LV_OBJ_FLAG_HIDDEN);
    return 1;
}
