/* 分流页（原型 page-wanbal）的控件搭建。
 *
 * 几何：page root 320×440，内容 x=8 宽 304，从 y=52（TOUCHUI_CONTENT_Y）起：
 *   y  52..104  分段控件（原型 .seg：card-2 容器 52 高 + 内嵌三个 44 高、96 宽按钮）
 *   y 112..132  hint 一行（tiny muted；降权时换 warn 色）
 *   y 140..353  权重卡（原型 .panel，auto/shared）或自定义卡（custom，同区域）
 *   y 361..379  「更新于 HH:MM:SS」
 *   y 396..428  toast（make_toast 固定贴底，空串即隐藏）
 * 一屏放得下，不做滚动区。
 *
 * 自定义卡（排期第 6 天·手动选池）总高 213px，卡内相对坐标：
 *   6..26   TCP 组头（左「TCP 走卡」+ 右汇总）
 *   27..59  TCP 三 chip（86 宽 / 7 gap）
 *   63      分隔线
 *   67..87  UDP 组头
 *   88..120 UDP 三 chip
 *   122..148「允许溢出」+ 关/开 开关
 *   153..169 可用性状态行（tcp_state/udp_state/live）
 *   174..206「应用分流」按钮（272 = 304-32）
 */
#define WANBAL_SEG_Y 52
#define WANBAL_SEG_H 52
#define WANBAL_HINT_Y 112
#define WANBAL_CARD_Y 140
#define WANBAL_UPDATED_Y 361
/* 行高：tiny 字体是 14px（原型 9.5px）、small 是 16px，按实测留足余量防裁字。 */
#define WANBAL_ROW_H 20
#define WANBAL_GROUP_HEAD_H 22

/* 自定义卡几何（相对卡） */
#define WANBAL_CUSTOM_H 213
#define WANBAL_CUSTOM_PAD 16
#define WANBAL_CHIP_W 86
#define WANBAL_CHIP_H 32
#define WANBAL_CHIP_GAP 7

static void destroy_wanbal_page(void);

/* 原型 .seg button：未选中 = card-2 底 / 无可见描边 / muted 字；
 * 选中 = card 底 + border + 正文色（选中态由 style_button 的 CHECKED 选择器渲染）。 */
static void wanbal_style_segment_button(lv_obj_t *button, lv_obj_t *label)
{
    if (!button) return;
    style_button(button, COLOR_CARD_ALT, COLOR_CARD_ALT, COLOR_CARD, COLOR_BORDER);
    set_border_color(button, COLOR_CARD_ALT, 0);
    set_border_color(button, COLOR_CARD_ALT, LV_STATE_PRESSED);
    if (lv_obj_set_style_radius_p)
        lv_obj_set_style_radius_p(button, 8, 0);
    if (label && real_obj_set_style_text_font && ui_font_small)
        real_obj_set_style_text_font(label, ui_font_small, 0);
    center_button_label(label);
    set_text_color(label, COLOR_MUTED);
}

/* 原型 .chip：card 底 + border；选中 = accent-soft 底 + accent 边 + accent 字
 * （选中态由 style_button 的 CHECKED 选择器渲染，字色在 wanbal_paint_chips 里刷）。 */
static lv_obj_t *wanbal_make_chip(lv_obj_t *card, const char *text, const void *font,
                                  int x, int y, int w, int h,
                                  void (*callback)(void *event), lv_obj_t **label_out)
{
    lv_obj_t *chip = make_button(card, text, x, y, w, h, callback, label_out);
    if (!chip) return NULL;
    style_button(chip, COLOR_CARD, COLOR_BUTTON_PRESSED,
                 COLOR_ACCENT_SOFT, COLOR_ACCENT);
    set_border_color(chip, COLOR_BORDER, 0);
    if (lv_obj_set_style_radius_p) lv_obj_set_style_radius_p(chip, 9, 0);
    if (label_out && *label_out) {
        if (font && real_obj_set_style_text_font)
            real_obj_set_style_text_font(*label_out, font, 0);
        set_text_color(*label_out, COLOR_MUTED);
        center_button_label(*label_out);
    }
    return chip;
}

static void (*const wanbal_tcp_chip_clicked_fn[3])(void *) = {
    wanbal_tcp_chip0_clicked, wanbal_tcp_chip1_clicked, wanbal_tcp_chip2_clicked
};
static void (*const wanbal_udp_chip_clicked_fn[3])(void *) = {
    wanbal_udp_chip0_clicked, wanbal_udp_chip1_clicked, wanbal_udp_chip2_clicked
};

/* 自定义卡：TCP/UDP 各三 chip + 允许溢出 + 可用性状态行 + 应用分流。 */
static int wanbal_build_custom_card(void)
{
    int i;
    wanbal_custom_card = make_card(wanbal_page, 8, WANBAL_CARD_Y, 304,
                                   WANBAL_CUSTOM_H);
    if (!wanbal_custom_card) return 0;

    make_text(wanbal_custom_card, "TCP 走卡", WANBAL_CUSTOM_PAD, 6, 120, 20,
              ui_font_small, COLOR_TEXT);
    wanbal_tcp_summary_label = make_value_right(wanbal_custom_card, 144, 6, 144, 20,
                                                ui_font_tiny, COLOR_MUTED);
    for (i = 0; i < 3; i++)
        wanbal_tcp_chip[i] = wanbal_make_chip(
            wanbal_custom_card, wanbal_card_labels[i], ui_font_small,
            WANBAL_CUSTOM_PAD + i * (WANBAL_CHIP_W + WANBAL_CHIP_GAP), 27,
            WANBAL_CHIP_W, WANBAL_CHIP_H, wanbal_tcp_chip_clicked_fn[i],
            &wanbal_tcp_chip_label[i]);

    make_divider(wanbal_custom_card, WANBAL_CUSTOM_PAD, 63, 272);

    make_text(wanbal_custom_card, "UDP 走卡", WANBAL_CUSTOM_PAD, 67, 120, 20,
              ui_font_small, COLOR_TEXT);
    wanbal_udp_summary_label = make_value_right(wanbal_custom_card, 144, 67, 144, 20,
                                                ui_font_tiny, COLOR_MUTED);
    for (i = 0; i < 3; i++)
        wanbal_udp_chip[i] = wanbal_make_chip(
            wanbal_custom_card, wanbal_card_labels[i], ui_font_small,
            WANBAL_CUSTOM_PAD + i * (WANBAL_CHIP_W + WANBAL_CHIP_GAP), 88,
            WANBAL_CHIP_W, WANBAL_CHIP_H, wanbal_udp_chip_clicked_fn[i],
            &wanbal_udp_chip_label[i]);

    make_text(wanbal_custom_card, "允许溢出", WANBAL_CUSTOM_PAD, 122, 140, 26,
              ui_font_small, COLOR_TEXT);
    wanbal_overflow_button = wanbal_make_chip(wanbal_custom_card, "关", ui_font_tiny,
                                              224, 123, 64, 24,
                                              wanbal_overflow_clicked,
                                              &wanbal_overflow_label);

    wanbal_custom_state_label = make_text(wanbal_custom_card, "", WANBAL_CUSTOM_PAD,
                                          153, 272, 16, ui_font_tiny, COLOR_MUTED);
    wanbal_apply_button = make_button(wanbal_custom_card, "应用分流",
                                      WANBAL_CUSTOM_PAD, 174, 272, 32,
                                      wanbal_apply_custom_clicked,
                                      &wanbal_apply_label);
    if (wanbal_apply_button) {
        style_button(wanbal_apply_button, COLOR_ACCENT, COLOR_ACCENT_DARK,
                     COLOR_ACCENT, COLOR_ACCENT);
        set_border_color(wanbal_apply_button, COLOR_ACCENT, 0);
        if (wanbal_apply_label)
            set_text_color(wanbal_apply_label, touchui_theme.accent_ink);
    }
    wanbal_show(wanbal_custom_card, 0);
    return 1;
}

/* 一组权重：组头（左 small「TCP/UDP」+ 右 tiny muted 说明）+ 三行 w-item。
 * 行内：标签 34px（tiny muted）+ 条（4 高）+ 右侧数值（tiny，右贴齐）。
 * 返回下一组的起始 y（卡内相对坐标）。 */
static int wanbal_build_weight_group(lv_obj_t *card, int y, const char *name,
                                     struct hbar_component bars[3],
                                     lv_obj_t **values, lv_obj_t **note_out)
{
    int i;
    make_text(card, name, 16, y, 44, WANBAL_GROUP_HEAD_H,
              ui_font_small, COLOR_MUTED);
    if (note_out)
        *note_out = make_value_right(card, 192, y, 96, WANBAL_GROUP_HEAD_H,
                                     ui_font_tiny, COLOR_MUTED);
    y += WANBAL_GROUP_HEAD_H;
    for (i = 0; i < 3; i++) {
        make_caption(card, wanbal_card_labels[i], 16, y, 34, WANBAL_ROW_H);
        bars[i] = make_hbar(card, 56, y + (WANBAL_ROW_H - 4) / 2, 182, 4,
                            COLOR_ACCENT);
        values[i] = make_value_right(card, 242, y, 46, WANBAL_ROW_H,
                                     ui_font_tiny, COLOR_TEXT);
        y += WANBAL_ROW_H;
    }
    return y;
}

/* 三行是否都建好了（条 / 值各 3 个）。 */
static int wanbal_weight_rows_ready(void)
{
    int i;
    for (i = 0; i < 3; i++) {
        if (!wanbal_tcp_bar[i].fill || !wanbal_udp_bar[i].fill) return 0;
        if (!wanbal_tcp_value[i] || !wanbal_udp_value[i]) return 0;
    }
    return 1;
}

static int create_wanbal_page(lv_obj_t *top)
{
    lv_obj_t *card;
    int y, card_h, i, custom_ready;
    if (!page_shell_init(&wanbal_shell, top, PAGE_WANBAL, "分流",
                         feature_back_clicked)) return 0;
    wanbal_page = wanbal_shell.root;

    /* 分段控件：容器只负责 card-2 底 + 圆角 12 + 描边，按钮叠在上面。
     * 三段各 96 宽、gap 4（原型 .seg grid 3 等分）。 */
    make_card_alt(wanbal_page, 8, WANBAL_SEG_Y, 304, WANBAL_SEG_H);
    wanbal_auto_button = make_button(wanbal_page, "自动·质量",
                                     12, WANBAL_SEG_Y + 4, 96, 44,
                                     wanbal_auto_clicked, &wanbal_auto_label);
    wanbal_shared_button = make_button(wanbal_page, "三卡共池",
                                       112, WANBAL_SEG_Y + 4, 96, 44,
                                       wanbal_shared_clicked,
                                       &wanbal_shared_label);
    wanbal_custom_button = make_button(wanbal_page, "自定义",
                                       212, WANBAL_SEG_Y + 4, 96, 44,
                                       wanbal_custom_clicked,
                                       &wanbal_custom_label);
    wanbal_style_segment_button(wanbal_auto_button, wanbal_auto_label);
    wanbal_style_segment_button(wanbal_shared_button, wanbal_shared_label);
    wanbal_style_segment_button(wanbal_custom_button, wanbal_custom_label);

    /* hint：选中预设一句话 / 自定义草稿摘要；degraded 非空时改显示降权名单（warn 色） */
    wanbal_hint_label = make_caption(wanbal_page, "", 8, WANBAL_HINT_Y, 304, 20);

    /* 权重卡：先算高度（标题 8+16 → 24，组 y 从 28 起，两组之间 4+1+8） */
    card_h = 28 + WANBAL_GROUP_HEAD_H + 3 * WANBAL_ROW_H;           /* TCP 结束 */
    card_h += 13 + WANBAL_GROUP_HEAD_H + 3 * WANBAL_ROW_H + 8;      /* 分隔 + UDP + 底部留白 */
    card = make_card(wanbal_page, 8, WANBAL_CARD_Y, 304, card_h);
    wanbal_weight_card = card;
    if (card) {
        make_caption(card, "有效权重", 16, 8, 140, 16);
        y = wanbal_build_weight_group(card, 28, "TCP", wanbal_tcp_bar,
                                      wanbal_tcp_value, &wanbal_tcp_note_label);
        /* TCP 结束与 UDP 组头之间：4px 空 + 1px 分隔线 + 8px 空 */
        make_divider(card, 16, y + 4, 280);
        wanbal_build_weight_group(card, y + 13, "UDP", wanbal_udp_bar,
                                  wanbal_udp_value, &wanbal_udp_note_label);
    }

    custom_ready = wanbal_build_custom_card();

    wanbal_updated_label = make_caption(wanbal_page, "更新于 --:--:--",
                                        8, WANBAL_UPDATED_Y, 304, 18);
    wanbal_toast = make_toast(wanbal_page);

    if (!wanbal_auto_button || !wanbal_shared_button || !wanbal_custom_button ||
        !wanbal_auto_label || !wanbal_shared_label || !wanbal_custom_label ||
        !wanbal_hint_label || !wanbal_tcp_note_label || !custom_ready ||
        !wanbal_udp_note_label || !wanbal_updated_label ||
        !wanbal_toast.panel || !wanbal_toast.label ||
        !wanbal_weight_rows_ready()) {
        trace_ui_create("wanbal-allocation-failed");
        destroy_wanbal_page();
        return 0;
    }
    for (i = 0; i < 3; i++) {
        if (!wanbal_tcp_chip[i] || !wanbal_udp_chip[i] ||
            !wanbal_tcp_chip_label[i] || !wanbal_udp_chip_label[i]) {
            trace_ui_create("wanbal-custom-chip-failed");
            destroy_wanbal_page();
            return 0;
        }
    }
    if (!wanbal_tcp_summary_label || !wanbal_udp_summary_label ||
        !wanbal_overflow_button || !wanbal_overflow_label ||
        !wanbal_custom_state_label || !wanbal_apply_button ||
        !wanbal_apply_label) {
        trace_ui_create("wanbal-custom-control-failed");
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
    int i;
    if (wanbal_page && lv_obj_del_p) lv_obj_del_p(wanbal_page);
    wanbal_page = NULL;
    memset(&wanbal_shell, 0, sizeof(wanbal_shell));
    wanbal_auto_button = wanbal_shared_button = wanbal_custom_button = NULL;
    wanbal_auto_label = wanbal_shared_label = wanbal_custom_label = NULL;
    wanbal_hint_label = NULL;
    wanbal_tcp_note_label = wanbal_udp_note_label = NULL;
    wanbal_weight_card = wanbal_custom_card = NULL;
    wanbal_tcp_summary_label = wanbal_udp_summary_label = NULL;
    wanbal_overflow_button = wanbal_overflow_label = NULL;
    wanbal_custom_state_label = NULL;
    wanbal_apply_button = wanbal_apply_label = NULL;
    wanbal_view_custom = wanbal_view_pinned = 0;
    wanbal_draft_tcp = wanbal_draft_udp = wanbal_draft_overflow = 0;
    wanbal_draft_seeded = 0;
    wanbal_chip_painted = -1;
    wanbal_state_tone = -1;
    for (i = 0; i < 3; i++) {
        wanbal_tcp_chip[i] = wanbal_udp_chip[i] = NULL;
        wanbal_tcp_chip_label[i] = wanbal_udp_chip_label[i] = NULL;
        wanbal_tcp_value[i] = wanbal_udp_value[i] = NULL;
        memset(&wanbal_tcp_bar[i], 0, sizeof(wanbal_tcp_bar[i]));
        memset(&wanbal_udp_bar[i], 0, sizeof(wanbal_udp_bar[i]));
        wanbal_tcp_pct[i] = -1;
        wanbal_udp_pct[i] = -1;
        wanbal_tcp_val[i] = -2;
        wanbal_udp_val[i] = -2;
    }
    memset(&wanbal_toast, 0, sizeof(wanbal_toast));
    memset(wanbal_toast_text, 0, sizeof(wanbal_toast_text));
    wanbal_updated_label = NULL;
    wanbal_bar_mask = -1;
    wanbal_hint_warn = -1;
    wanbal_seg_selected = -1;
    /* Confirmation widgets are children of wanbal_page; clear dangling ptrs. */
    if (current_page == PAGE_WANBAL) {
        confirm_scrim = NULL;
        confirm_panel = NULL;
        confirm_text_label = NULL;
        confirm_action = ACTION_NONE;
    }
}
