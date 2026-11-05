static void destroy_wanbal_page(void);

static int create_wanbal_page(lv_obj_t *top)
{
    lv_obj_t *hint;
    if (!page_shell_init(&wanbal_shell, top, PAGE_WANBAL, "分流",
                         feature_back_clicked)) return 0;
    wanbal_page = wanbal_shell.root;

    make_panel(wanbal_page, 8, 48, 304, 72, COLOR_CARD);
    wanbal_summary_label = make_single_line_label(wanbal_page, "读取中…",
                                                  16, 58, 288, 28);
    set_text_color(wanbal_summary_label, COLOR_TEXT);
    wanbal_detail_label = make_single_line_label(wanbal_page, "",
                                                 16, 90, 288, 24);
    set_text_color(wanbal_detail_label, COLOR_MUTED);

    hint = make_single_line_label(wanbal_page, "选择分流模式", 16, 136, 200, 22);
    set_text_color(hint, COLOR_MUTED);

    wanbal_auto_button = make_button(wanbal_page, "自动·质量", 8, 168, 304, 70,
                                     wanbal_auto_clicked, &wanbal_auto_label);
    style_button(wanbal_auto_button, COLOR_CARD, COLOR_BUTTON_PRESSED,
                 COLOR_CARD, COLOR_ACCENT_SOFT);
    set_text_color(wanbal_auto_label, COLOR_TEXT);
    hint = make_single_line_label(wanbal_page, "质量加权；TCP偏5G UDP偏4G；弱网溢出",
                                  20, 242, 288, 22);
    set_text_color(hint, COLOR_MUTED);

    wanbal_shared_button = make_button(wanbal_page, "三卡共池", 8, 276, 304, 70,
                                       wanbal_shared_clicked, &wanbal_shared_label);
    style_button(wanbal_shared_button, COLOR_CARD, COLOR_BUTTON_PRESSED,
                 COLOR_CARD, COLOR_ACCENT_SOFT);
    set_text_color(wanbal_shared_label, COLOR_TEXT);
    hint = make_single_line_label(wanbal_page, "强制共池；仍按质量降权，无软偏置",
                                  20, 350, 288, 22);
    set_text_color(hint, COLOR_MUTED);

    wanbal_message_label = make_label(wanbal_page, "", 14, 388, 292, 40);
    set_text_color(wanbal_message_label, COLOR_MESSAGE);

    if (!wanbal_summary_label || !wanbal_detail_label ||
        !wanbal_auto_button || !wanbal_shared_button || !wanbal_message_label) {
        trace_ui_create("wanbal-allocation-failed");
        destroy_wanbal_page();
        return 0;
    }
    if (!create_confirmation_overlay(wanbal_page)) {
        trace_ui_create("wanbal-overlay-failed");
        destroy_wanbal_page();
        return 0;
    }
    return 1;
}

static void request_wanbal_page(void)
{
    pending_wanbal_open = 1;
}

static void destroy_wanbal_page(void)
{
    if (wanbal_page && lv_obj_del_p) lv_obj_del_p(wanbal_page);
    wanbal_page = NULL;
    memset(&wanbal_shell, 0, sizeof(wanbal_shell));
    wanbal_summary_label = wanbal_detail_label = NULL;
    wanbal_auto_button = wanbal_shared_button = NULL;
    wanbal_auto_label = wanbal_shared_label = NULL;
    wanbal_message_label = NULL;
    /* Confirmation widgets are children of wanbal_page; clear dangling ptrs. */
    if (current_page == PAGE_WANBAL) {
        confirm_scrim = NULL;
        confirm_panel = NULL;
        confirm_text_label = NULL;
        confirm_action = ACTION_NONE;
    }
}
