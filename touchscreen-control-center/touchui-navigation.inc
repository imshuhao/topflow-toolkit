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
    confirm_step = 0;
}

static void hide_extension_pages(void)
{
    if (menu_page) lv_obj_add_flag_p(menu_page, LV_OBJ_FLAG_HIDDEN);
    if (manager_page) lv_obj_add_flag_p(manager_page, LV_OBJ_FLAG_HIDDEN);
    if (wanbal_page) lv_obj_add_flag_p(wanbal_page, LV_OBJ_FLAG_HIDDEN);
    if (balance_page) lv_obj_add_flag_p(balance_page, LV_OBJ_FLAG_HIDDEN);
    if (network_page) lv_obj_add_flag_p(network_page, LV_OBJ_FLAG_HIDDEN);
    if (network_detail_page)
        lv_obj_add_flag_p(network_detail_page, LV_OBJ_FLAG_HIDDEN);
    if (network_identity_page)
        lv_obj_add_flag_p(network_identity_page, LV_OBJ_FLAG_HIDDEN);
    if (device_page) lv_obj_add_flag_p(device_page, LV_OBJ_FLAG_HIDDEN);
    if (cooling_curve_page)
        lv_obj_add_flag_p(cooling_curve_page, LV_OBJ_FLAG_HIDDEN);
    if (diagnostics_page) lv_obj_add_flag_p(diagnostics_page, LV_OBJ_FLAG_HIDDEN);
    if (charge_page) lv_obj_add_flag_p(charge_page, LV_OBJ_FLAG_HIDDEN);
}

static void show_page(enum page_id page)
{
    hide_confirm();
    hide_extension_pages();
    if (page != current_page &&
        (current_page == PAGE_SINGBOX ||
         current_page == PAGE_WANBAL ||
         current_page == PAGE_BALANCE ||
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
    } else if (page == PAGE_BALANCE && balance_page) {
        lv_obj_clear_flag_p(balance_page, LV_OBJ_FLAG_HIDDEN);
        pthread_mutex_lock(&shared_lock);
        force_balance_refresh = 1;
        pthread_mutex_unlock(&shared_lock);
    } else if (page == PAGE_DEVICE && device_page)
        lv_obj_clear_flag_p(device_page, LV_OBJ_FLAG_HIDDEN);
    else if (page == PAGE_COOLING_CURVE && cooling_curve_page)
        lv_obj_clear_flag_p(cooling_curve_page, LV_OBJ_FLAG_HIDDEN);
    else if (page == PAGE_DIAGNOSTICS && diagnostics_page)
        lv_obj_clear_flag_p(diagnostics_page, LV_OBJ_FLAG_HIDDEN);
    else if (page == PAGE_CHARGE && charge_page)
        lv_obj_clear_flag_p(charge_page, LV_OBJ_FLAG_HIDDEN);
    statusbar_set_visible(page != PAGE_STOCK);
}

static void open_menu_clicked(void *event) { (void)event; show_page(PAGE_MENU); }
static void open_charge_clicked(void *event) { (void)event; request_charge_page(); }
static void open_theme_clicked(void *event);
static void show_stock_page(void)
{
    show_page(PAGE_STOCK);
    pending_network_view = 0;
    pending_singbox_open = 0;
    pending_wanbal_open = 0;
    pending_balance_open = 0;
    pending_charge_open = 0;
    pending_device_view = 0;
    pending_extension_cleanup = 1;
}

static void close_menu_clicked(void *event) { (void)event; show_stock_page(); }
static void open_network_clicked(void *event) { (void)event; request_network_overview(); }
static void open_singbox_clicked(void *event) { (void)event; request_singbox_page(); }
static void open_wanbal_clicked(void *event) { (void)event; request_wanbal_page(); }
static void open_balance_clicked(void *event) { (void)event; request_balance_page(); }
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
    /* 整页下移，顶部留给共用状态栏，避免被全屏 root 盖住 */
    lv_obj_set_size_p(shell->root, 320, 480 - TOUCHUI_SB_H);
    lv_obj_set_pos_p(shell->root, 0, TOUCHUI_SB_H);
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
                                                 14, 410, 200, 22);
    set_text_color(shell->footer_label, COLOR_MUTED);
    /* 时钟改到顶部状态栏；保留占位以免旧刷新路径空指针 */
    shell->clock_label = make_single_line_label(shell->root, "",
                                                230, 410, 78, 22);
    if (shell->clock_label)
        lv_obj_add_flag_p(shell->clock_label, LV_OBJ_FLAG_HIDDEN);
    set_text_color(shell->clock_label, COLOR_MUTED);
    lv_obj_add_flag_p(shell->root, LV_OBJ_FLAG_HIDDEN);
    return 1;
}

static void refresh_page_clocks(void)
{
    refresh_statusbar();
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
    if (shared_action_running || shared_action != ACTION_NONE) return;
    /* mihomo 回滚态用底部「核心切换」，不走 sing-box 启停. */
    if (!strcmp(ui_status.engine, "mihomo") ||
        ui_status.dhcp_points_to_mihomo ||
        (ui_status.mihomo_running && !ui_status.service_running))
        return;
    if (ui_status.service_running)
        show_confirm(ACTION_SERVICE_STOP,
                     "停止代理核心后客户端将直连，确认继续？");
    else
        show_confirm(ACTION_SERVICE_START, "启动 sing-box 代理服务？");
}

static void restart_clicked(void *event)
{
    (void)event;
    if (shared_action_running || shared_action != ACTION_NONE) return;
    if (!strcmp(ui_status.engine, "mihomo") ||
        ui_status.dhcp_points_to_mihomo ||
        (ui_status.mihomo_running && !ui_status.service_running))
        return;
    show_confirm(ACTION_SERVICE_RESTART,
                 "重启期间代理会中断约 5–15 秒，确认继续？");
}
static void confirm_clicked(void *event)
{
    int action = confirm_action;
    (void)event;
    /* Engine switch requires a second confirm (HANDOVER / schedule). */
    if (action_is_engine(action) && confirm_step < 2) {
        confirm_step = 2;
        if (action == ACTION_ENGINE_SWITCHOVER)
            show_confirm(action, "二次确认：确定切换到 sing-box？");
        else
            show_confirm(action, "二次确认：确定切回 mihomo？");
        return;
    }
    hide_confirm();
    if (action == ACTION_WIFI_APPLY)
        queue_action_with_params(action, pending_wifi_band,
                                 pending_wifi_value, pending_wifi_value2);
    else if (action == ACTION_FAN_CURVE_APPLY)
        queue_fan_curve_action();
    else if (action) queue_action(action);
}
static void cancel_clicked(void *event) { (void)event; hide_confirm(); }

/* 原型 .confirm：全页遮罩 + 贴底弹层（标题 / 正文 / 取消·确认）。
 * parent 为 page_shell root（320×440），坐标相对该 root。 */
static int create_confirmation_overlay(lv_obj_t *parent)
{
    lv_obj_t *title, *cancel_button, *accept_button, *cancel_label, *accept_label;
    const int sheet_h = 172;
    const int sheet_y = TOUCHUI_PAGE_H - sheet_h - 10;
    confirm_scrim = lv_obj_create_p(parent);
    if (!confirm_scrim) return 0;
    lv_obj_set_size_p(confirm_scrim, 320, TOUCHUI_PAGE_H);
    lv_obj_set_pos_p(confirm_scrim, 0, 0);
    lv_obj_clear_flag_p(confirm_scrim, LV_OBJ_FLAG_SCROLLABLE);
    style_surface(confirm_scrim, touchui_theme_is_day ? 0x0C1416u : 0x000000u,
                  0x000000u, 0, 0);
    if (lv_obj_set_style_bg_opa_p)
        lv_obj_set_style_bg_opa_p(confirm_scrim, touchui_theme_is_day ? 82 : 148, 0);
    lv_obj_add_event_cb_p(confirm_scrim, cancel_clicked, LV_EVENT_CLICKED, NULL);
    confirm_panel = lv_obj_create_p(parent);
    if (!confirm_panel) return 0;
    lv_obj_set_size_p(confirm_panel, 300, sheet_h);
    lv_obj_set_pos_p(confirm_panel, 10, sheet_y);
    lv_obj_clear_flag_p(confirm_panel, LV_OBJ_FLAG_SCROLLABLE);
    style_surface(confirm_panel, COLOR_CARD, COLOR_BORDER, 14, 1);
    if (lv_obj_set_style_pad_left_p) lv_obj_set_style_pad_left_p(confirm_panel, 0, 0);
    if (lv_obj_set_style_pad_right_p) lv_obj_set_style_pad_right_p(confirm_panel, 0, 0);
    if (lv_obj_set_style_pad_top_p) lv_obj_set_style_pad_top_p(confirm_panel, 0, 0);
    if (lv_obj_set_style_pad_bottom_p) lv_obj_set_style_pad_bottom_p(confirm_panel, 0, 0);
    if (lv_obj_set_style_shadow_width_p)
        lv_obj_set_style_shadow_width_p(confirm_panel, 32, 0);
    set_shadow_color(confirm_panel, 0x000000u);
    if (lv_obj_set_style_shadow_opa_p)
        lv_obj_set_style_shadow_opa_p(confirm_panel, 90, 0);
    title = make_single_line_label(confirm_panel, "确认操作", 14, 14, 272, 24);
    set_text_color(title, COLOR_TEXT);
    confirm_text_label = make_label(confirm_panel, "", 14, 44, 272, 58);
    if (confirm_text_label && ui_font_small && real_obj_set_style_text_font)
        real_obj_set_style_text_font(confirm_text_label, ui_font_small, 0);
    set_text_color(confirm_text_label, COLOR_MUTED);
    cancel_button = make_button(confirm_panel, "取消", 14, sheet_h - 58, 132, 44,
                                cancel_clicked, &cancel_label);
    accept_button = make_button(confirm_panel, "确认", 154, sheet_h - 58, 132, 44,
                                confirm_clicked, &accept_label);
    /* 取消 = ghost；确认 = 危险色浅底（原型 btn-danger） */
    style_button(cancel_button, COLOR_CARD, COLOR_BUTTON_PRESSED,
                 COLOR_BUTTON_PRESSED, COLOR_BORDER);
    set_text_color(cancel_label, COLOR_TEXT);
    style_button(accept_button, touchui_theme.danger_soft, touchui_theme.danger_soft,
                 touchui_theme.danger_soft, COLOR_RED);
    set_border_color(accept_button, COLOR_RED, 0);
    set_text_color(accept_label, COLOR_RED);
    lv_obj_add_flag_p(confirm_scrim, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag_p(confirm_panel, LV_OBJ_FLAG_HIDDEN);
    return 1;
}
