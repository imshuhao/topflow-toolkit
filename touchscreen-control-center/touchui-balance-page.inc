/* 「余量」页结构（原型 #page-balance）：tabs（联通 / 电信）+ 五行余量卡 + meta 行
 * + 全宽 ghost「立即刷新」按钮 + 底部 toast。数据填充与刷新逻辑在 touchui-balance.inc
 * （本文件之后包含：控件指针、static 状态、balance_apply_tab 都在那里，销毁时统一清零）。
 *
 * 页头右侧被原厂主页按钮占用，原型里的「刷新」文字按钮下移成 meta 行下方的全宽按钮。
 * 一屏放下、不滚动（page root 高 440）。行高压到 44（卡 236）后各段 y：
 *    52..104  tabs（容器 card-2 高 52，内边距 4）
 *   108..344  五行卡（5×44 + 上下各 8 内边距 = 236）
 *   348..366  meta 行（左「更新于」/ 右「下次 … · 只读快照」）
 *   370..414  立即刷新（304×44 ghost）
 *   416..438  toast（原型贴底 14px；这里让出按钮，改成按钮下方一条细胶囊） */

static void destroy_balance_page(void);

static void balance_tab_unicom_clicked(void *event)
{
    (void)event;
    balance_apply_tab(0);
}

static void balance_tab_telecom_clicked(void *event)
{
    (void)event;
    balance_apply_tab(1);
}

static int create_balance_page(lv_obj_t *top)
{
    int i;
    int card_y = TOUCHUI_CONTENT_Y + 52 + 4;              /* 108 */
    int meta_y = card_y + BALANCE_PANEL_H + 4;            /* 348 */
    int button_y = meta_y + 18 + 4;                       /* 370 */
    int toast_y = button_y + 44 + 2;                      /* 416 */

    if (!page_shell_init(&balance_shell, top, PAGE_BALANCE, "余量",
                         feature_back_clicked)) return 0;
    balance_page = balance_shell.root;

    /* ---- tabs：容器 card-2 高 52，内边距 4，两个 44 高按钮（原型 .tabs） ---- */
    balance_tabs_panel = make_card_alt(balance_page, TOUCHUI_CONTENT_X,
                                       TOUCHUI_CONTENT_Y, TOUCHUI_CONTENT_W, 52);
    if (!balance_tabs_panel) {
        trace_ui_create("balance-tabs-failed");
        destroy_balance_page();
        return 0;
    }
    balance_tab_buttons[0] = make_button(balance_tabs_panel, "联通", 4, 4, 146, 44,
                                         balance_tab_unicom_clicked,
                                         &balance_tab_labels[0]);
    balance_tab_buttons[1] = make_button(balance_tabs_panel, "电信", 154, 4, 146, 44,
                                         balance_tab_telecom_clicked,
                                         &balance_tab_labels[1]);
    if (!balance_tab_buttons[0] || !balance_tab_buttons[1] ||
        !balance_tab_labels[0] || !balance_tab_labels[1]) {
        trace_ui_create("balance-tabs-allocation-failed");
        destroy_balance_page();
        return 0;
    }
    /* tab 要放「联通 ·2603」，18px 会挤，降到 16px（换字体后要重新居中） */
    for (i = 0; i < BALANCE_CARD_COUNT; i++) {
        if (balance_tab_labels[i] && ui_font_small &&
            real_obj_set_style_text_font)
            real_obj_set_style_text_font(balance_tab_labels[i], ui_font_small, 0);
        center_button_label(balance_tab_labels[i]);
    }

    /* ---- 五行余量卡（行高 44：上行 label + 大值，下行 sub；行间 1px 分隔） ---- */
    balance_panel = make_card(balance_page, TOUCHUI_CONTENT_X, card_y,
                              TOUCHUI_CONTENT_W, BALANCE_PANEL_H);
    if (!balance_panel) {
        trace_ui_create("balance-panel-failed");
        destroy_balance_page();
        return 0;
    }
    for (i = 0; i < BALANCE_ROW_COUNT; i++) {
        int row_y = 8 + i * BALANCE_ROW_H;
        /* 上行左侧：行名（tiny muted），与右侧大值同一行 */
        make_caption(balance_panel, balance_row_titles[i], 12, row_y + 2,
                     120, 20);
        /* 上行右侧：大值（18px，右贴齐；tabular 由字体本身保证） */
        balance_row_value[i] = make_value_right(balance_panel, 132, row_y + 1,
                                                160, 22, ui_font, COLOR_TEXT);
        /* 下行：副行（tiny muted；失败时改 warn 色写原因） */
        balance_row_sub[i] = make_caption(balance_panel, "", 12, row_y + 22,
                                          280, 20);
        /* 行间分隔线（第一行上方不画） */
        if (i > 0) make_divider(balance_panel, 12, row_y, 280);
        if (!balance_row_value[i] || !balance_row_sub[i]) {
            trace_ui_create("balance-row-failed");
            destroy_balance_page();
            return 0;
        }
    }

    /* ---- meta 行：左「更新于 HH:MM:SS」，右「下次 HH:MM:SS · 只读快照」 ----
     * 两侧都给足宽度：14px 下「更新于 21:15:00」约 112，「下次 21:15:00 · 只读快照」
     * 约 154，304 总宽装得下。 */
    balance_updated_label = make_caption(balance_page, "更新于 --:--:--",
                                         TOUCHUI_CONTENT_X, meta_y, 118, 18);
    balance_next_label = make_value_right(balance_page, TOUCHUI_CONTENT_X + 122,
                                          meta_y, 182, 18, ui_font_tiny,
                                          COLOR_MUTED);
    if (!balance_updated_label || !balance_next_label) {
        trace_ui_create("balance-meta-failed");
        destroy_balance_page();
        return 0;
    }
    set_right_value(balance_next_label, "下次 --:--:-- · 只读快照");

    /* ---- 刷新按钮：全宽 ghost（card 底 / border 边 / text 字） ---- */
    balance_refresh_button = make_button(balance_page, "立即刷新",
                                         TOUCHUI_CONTENT_X, button_y,
                                         TOUCHUI_CONTENT_W, 44,
                                         balance_refresh_clicked,
                                         &balance_refresh_label);
    if (!balance_refresh_button || !balance_refresh_label) {
        trace_ui_create("balance-refresh-failed");
        destroy_balance_page();
        return 0;
    }
    style_button(balance_refresh_button, COLOR_CARD, COLOR_CARD_ALT,
                 COLOR_CARD, COLOR_BORDER);
    set_text_color(balance_refresh_label, COLOR_TEXT);
    set_checked(balance_refresh_button, 0);

    /* ---- 底部 toast：make_toast 默认贴 396 会压住刷新按钮，改到按钮下方 ---- */
    balance_toast = make_toast(balance_page);
    if (!balance_toast.panel || !balance_toast.label) {
        trace_ui_create("balance-toast-failed");
        destroy_balance_page();
        return 0;
    }
    lv_obj_set_size_p(balance_toast.panel, 280, 22);
    lv_obj_set_pos_p(balance_toast.panel, 20, toast_y);

    /* 初始选中态（数值由集成层调用 refresh_balance_ui 首填） */
    balance_apply_tab(balance_tab);
    return 1;
}

static void request_balance_page(void)
{
    pending_balance_open = 1;
}

static void destroy_balance_page(void)
{
    int i;
    if (balance_page && lv_obj_del_p) lv_obj_del_p(balance_page);
    balance_page = NULL;
    memset(&balance_shell, 0, sizeof(balance_shell));
    /* 以下 static 都定义在 touchui-balance.inc，必须随页面一起清空，
     * 否则下次重建时旧指针会在刷新里被写（use-after-free）。 */
    balance_tabs_panel = NULL;
    memset(balance_tab_buttons, 0, sizeof(balance_tab_buttons));
    memset(balance_tab_labels, 0, sizeof(balance_tab_labels));
    balance_panel = NULL;
    for (i = 0; i < BALANCE_ROW_COUNT; i++) {
        balance_row_value[i] = NULL;
        balance_row_sub[i] = NULL;
    }
    balance_updated_label = NULL;
    balance_next_label = NULL;
    memset(&balance_toast, 0, sizeof(balance_toast));
    balance_refresh_button = NULL;
    balance_refresh_label = NULL;
    balance_tab = 0;
    balance_refresh_busy = 0;
}
