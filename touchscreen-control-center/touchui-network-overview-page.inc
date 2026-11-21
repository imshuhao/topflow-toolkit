/* 「网络」总览页（原型 page-network）。
 *
 * 布局（page root 320×440，内容 x=8 宽 304，全部放进滚动区）：
 *   摘要卡      y   0 ..  56    「三卡在线」+ 大数字总速率 + 单位 + 「总速率」徽标
 *   图表块      y  64 .. 120    「近 60 秒总速率」「峰值 X」+ 40px 折线
 *   5G  卡      y 128 .. 228
 *   4G#1 卡     y 236 .. 336
 *   4G#2 卡     y 344 .. 444
 * 内容总高 444，可见高（footer 之上）= 358，所以按计划用 make_scroll_area 做滚动区：
 * 一屏能看到摘要 + 图表 + 两张整卡 + 第三张卡的标题行（天然滚动提示）。
 * 三张卡 + 图表按原样排版最小需要 ~420px，压不进 358，故不做「去掉图表换一屏」的降级。
 *
 * 卡片与点按层都在滚动区内：点按层最后创建、压在卡片之上，整卡进现有详情页。
 * 控件句柄与纯数据 helper 在 touchui-network-overview-state.inc（包含顺序在前）。 */

#define NETWORK_OVERVIEW_SUMMARY_H 56
#define NETWORK_OVERVIEW_CHART_H 56
#define NETWORK_OVERVIEW_CHART_LINE_H 40
#define NETWORK_OVERVIEW_CARD_H 100
#define NETWORK_OVERVIEW_GAP 8

/* 旧总览页是这三个 helper 的唯一调用者：原厂信号 PNG 图标（新布局改用状态徽标）
 * 与运营商名滚动标签（新布局不显示运营商）。它们的定义在只读的
 * touchui-icons.inc / touchui-network-format.inc 里，本包不能改，所以保留一次
 * 取址引用避免 -Wunused-function 打断 -Werror 构建。
 * 集成者若把这些 helper 标成 TOUCHUI_HELPER、删除或改由他处使用，可整段去掉。 */
static void network_overview_keep_legacy_helpers(void)
{
    (void)make_stock_signal_icon;
    (void)set_stock_signal_icon;
    (void)set_operator_label_text;
}

/* 建页开头清零本页私有句柄（destroy_network_overview 在只读文件里，
 * 只清 touchui-state.h 的旧指针；页面只会在销毁后重建，故开头清零等价）。 */
static void network_overview_reset_locals(void)
{
    memset(&network_overview_ui, 0, sizeof(network_overview_ui));
    for (int i = 0; i < NETWORK_MODEM_COUNT; i++) {
        network_overview_ui.badge_tone[i] = NETWORK_TONE_NONE;
        network_overview_ui.weight_visible[i] = -1;
    }
}

/* 一张模块卡：状态点 + 名称 + 状态徽标 + 2×2 指标 + 有效权重行。
 *
 * 指标用「标签在左、值右贴齐」的单行单元格：按任务给的 ~100px 卡高，
 * 原型那种「标签在上、值在下」的堆叠式 2×2 放不下（原型 .net-card 实测
 * 内边距 10 + 标题行 22 + 2×(9+1+12) + 权重行 ≈ 124px）。 */
static int network_overview_create_card(lv_obj_t *parent, int index, int y,
                                        void (*open_callback)(void *event))
{
    static const char *const captions[4] = {"信号", "延迟", "下行", "上行"};
    static const int caption_x[4] = {12, 144, 12, 144};
    static const int value_x[4] = {50, 182, 50, 182};
    static const int value_w[4] = {84, 110, 84, 110};
    static const int row_y[4] = {29, 29, 51, 51};
    lv_obj_t *card = make_card(parent, TOUCHUI_CONTENT_X, y, TOUCHUI_CONTENT_W,
                               NETWORK_OVERVIEW_CARD_H);
    lv_obj_t **slots[4];
    int ok = 1;

    slots[0] = &network_overview_ui.signal[index];
    slots[1] = &network_overview_ui.latency[index];
    slots[2] = &network_overview_ui.down[index];
    slots[3] = &network_overview_ui.up[index];

    if (!card) return 0;

    network_dot[index] = make_dot(card, 12, center_marker_on_text_line(6, ui_font, 6),
                                  6, COLOR_MUTED);
    network_overview_ui.name[index] = make_text(card,
        network_overview_titles[index], 22, 6, 150, 20, ui_font, COLOR_TEXT);
    network_overview_ui.badge[index] = make_badge(card, 244, 6, 48, 20, "--",
                                                  COLOR_MUTED, COLOR_CARD_ALT,
                                                  ui_font_tiny);
    for (int i = 0; i < 4; i++) {
        /* tiny 标签与 small 值同基线：值框 20 高，标签在值框内下移 2px */
        make_caption(card, captions[i], caption_x[i], row_y[i] + 2, 36, 17);
        *slots[i] = make_value_right(card, value_x[i], row_y[i], value_w[i], 20,
                                     ui_font_small, COLOR_TEXT);
        if (!*slots[i]) ok = 0;
    }
    network_overview_ui.weight_rule[index] = make_divider(card, 12, 77, 280);
    network_overview_ui.weight_caption[index] = make_caption(card, "有效权重",
                                                            12, 81, 72, 17);
    network_overview_ui.weight_value[index] = make_value_right(card, 88, 80, 204, 18,
                                                               ui_font_tiny, COLOR_MUTED);

    if (!network_overview_ui.name[index] ||
        !network_overview_ui.badge[index].panel ||
        !network_overview_ui.badge[index].label ||
        !network_overview_ui.weight_rule[index] ||
        !network_overview_ui.weight_caption[index] ||
        !network_overview_ui.weight_value[index]) ok = 0;
    if (!ok) return 0;

    /* 权重行首帧先隐藏（没有分流数据时不该出现空行），由刷新决定是否显示。 */
    network_overview_set_weight_visible(index, 0);

    /* 点按层最后创建，压在卡片之上：整卡进入现有详情页（必须保留）。 */
    make_click_layer(parent, TOUCHUI_CONTENT_X, y, TOUCHUI_CONTENT_W,
                     NETWORK_OVERVIEW_CARD_H, open_callback);
    return 1;
}

static int create_network_page(lv_obj_t *top)
{
    static void (*open_callbacks[NETWORK_MODEM_COUNT])(void *) = {
        open_network_detail_5g, open_network_detail_4g1, open_network_detail_4g2
    };
    lv_obj_t *scroll, *summary;
    int y;

    network_overview_reset_locals();
    /* 旧总览页是信号 PNG 图标 / 运营商名标签的唯一调用者；新布局不用它们，
     * 这里保留一次引用防止只读文件里的 static helper 变成 unused（见上方注释）。
     * (void) 取址不产生任何代码。 */
    network_overview_keep_legacy_helpers();
    network_parent = top;
    if (!page_shell_init(&network_shell, top, PAGE_NETWORK, "网络",
                         feature_back_clicked)) return 0;
    network_page = network_shell.root;

    /* 滚动区止于 footer 之上（footer 在 y=410 显示「数据延迟」）。 */
    scroll = make_scroll_area(network_page, 0, TOUCHUI_CONTENT_Y, 320,
                              TOUCHUI_FOOTER_Y - TOUCHUI_CONTENT_Y);
    if (!scroll) {
        trace_ui_create("network-scroll-failed");
        destroy_network_overview();
        return 0;
    }
    network_overview_ui.scroll = scroll;

    /* ---- 摘要卡：在线卡数 + 三卡下行合计 ---- */
    y = 0;
    summary = make_card(scroll, TOUCHUI_CONTENT_X, y, TOUCHUI_CONTENT_W,
                        NETWORK_OVERVIEW_SUMMARY_H);
    if (!summary) {
        trace_ui_create("network-summary-failed");
        destroy_network_overview();
        return 0;
    }
    /* 摘要卡两行：kicker（14px 行高 ~17）+ 大数字（24px 行高 ~31） */
    network_overview_ui.kicker = make_caption(summary, "读取中…", 12, 4, 150, 17);
    /* 大数字左对齐（原型 .big 在 kicker 之下左对齐），单位随数字右贴 */
    network_overview_ui.value = make_text(summary, "--", 12, 20, 0, 0,
                                          ui_font_large, COLOR_TEXT);
    network_overview_ui.unit = make_text(summary, "", 0, 0, 0, 0,
                                         ui_font_small, COLOR_MUTED);
    /* 单位初始位置：数字文本变化时由 network_overview_set_summary_value 右贴重排 */
    if (network_overview_ui.unit) lv_obj_set_pos_p(network_overview_ui.unit, 50, 25);
    /* 原型 .badge.ok = ok 字 / ok-soft 底；不是 accent（那是 .badge.soft）。 */
    network_overview_ui.total_badge = make_badge(summary, 240, 26, 52, 20,
                                                 "总速率", COLOR_GREEN,
                                                 touchui_theme.ok_soft, ui_font_tiny);
    /* 页头右侧「实时」胶囊被原厂主页按钮占位，按 §41.1 改放进第一张卡右上。 */
    make_badge(summary, 252, 4, 40, 16, "实时", COLOR_MUTED, COLOR_CARD_ALT,
               ui_font_tiny);
    if (!network_overview_ui.kicker || !network_overview_ui.value ||
        !network_overview_ui.unit || !network_overview_ui.total_badge.panel) {
        trace_ui_create("network-summary-failed");
        destroy_network_overview();
        return 0;
    }

    /* ---- 图表块：标题行 + 近 60 秒总速率折线（不套卡片，与原型一致） ---- */
    y += NETWORK_OVERVIEW_SUMMARY_H + NETWORK_OVERVIEW_GAP;
    network_overview_ui.chart_caption = make_caption(scroll, "近 60 秒总速率",
                                                     TOUCHUI_CONTENT_X, y, 140, 16);
    network_overview_ui.chart_peak = make_value_right(scroll, 150, y, 162, 18,
                                                      ui_font_tiny, COLOR_MUTED);
    if (!network_overview_ui.chart_caption || !network_overview_ui.chart_peak) {
        trace_ui_create("network-chart-caption-failed");
        destroy_network_overview();
        return 0;
    }
    if (lv_chart_create_p && lv_chart_add_series_p && lv_chart_set_next_value_p) {
        network_overview_ui.chart = lv_chart_create_p(scroll);
        if (network_overview_ui.chart) {
            lv_obj_set_size_p(network_overview_ui.chart, TOUCHUI_CONTENT_W,
                              NETWORK_OVERVIEW_CHART_LINE_H);
            lv_obj_set_pos_p(network_overview_ui.chart, TOUCHUI_CONTENT_X, y + 16);
            /* 图表自身不滚动，拖动事件交给外层滚动区 */
            lv_obj_clear_flag_p(network_overview_ui.chart, LV_OBJ_FLAG_SCROLLABLE);
            style_surface(network_overview_ui.chart, COLOR_BG, COLOR_BG, 0, 0);
            if (lv_chart_set_type_p)
                lv_chart_set_type_p(network_overview_ui.chart, LV_CHART_TYPE_LINE);
            if (lv_chart_set_point_count_p)
                lv_chart_set_point_count_p(network_overview_ui.chart,
                                           NETWORK_TREND_POINTS);
            if (lv_chart_set_range_p)
                lv_chart_set_range_p(network_overview_ui.chart,
                                     LV_CHART_AXIS_PRIMARY_Y, 0, 1);
            network_overview_ui.chart_series = lv_chart_add_series_p(
                network_overview_ui.chart, color_hex(COLOR_ACCENT),
                LV_CHART_AXIS_PRIMARY_Y);
            /* 用已有历史补点，打开页面立刻就有趋势而不是一条零线。
             * 补到 count-1：建页后紧接着的第一次 refresh 会推进最新一点。 */
            for (int i = 0; i + 1 < network_history[0].count; i++)
                lv_chart_set_next_value_p(
                    network_overview_ui.chart, network_overview_ui.chart_series,
                    (int32_t)(network_overview_point_bytes(i) / 1024ULL));
        }
    }

    /* ---- 三张模块卡 ---- */
    y += NETWORK_OVERVIEW_CHART_H + NETWORK_OVERVIEW_GAP;
    for (int i = 0; i < NETWORK_MODEM_COUNT; i++) {
        if (!network_overview_create_card(scroll, i, y, open_callbacks[i])) {
            trace_ui_create("network-card-failed");
            destroy_network_overview();
            return 0;
        }
        y += NETWORK_OVERVIEW_CARD_H + NETWORK_OVERVIEW_GAP;
    }

    /* shell 时钟标签已隐藏（状态栏接管），保留指向以免旧刷新路径空指针。 */
    network_updated_label = network_shell.clock_label;
    return 1;
}
