/* 「网络」总览页的数据与刷新（原型 page-network）。
 *
 * 说明：touchui-network.inc 的包含顺序是 overview-state 在 overview-page 之前，
 * 因此「本页私有句柄」与纯数据 helper 必须定义在本文件，页面文件（后包含）
 * 直接复用；建页函数与 network_overview_reset_locals() 仍在 overview-page.inc。
 *
 * 数据来源只有两个共享结构：
 *   shared_network_status —— 三卡 modem_status + device（本页只用 modems[]）
 *   shared_wanbal_status  —— tcp_weights / udp_weights（"5G:1,4G#1:2,4G#2:2"）
 * 两者在同一把 shared_lock 内一次性拷贝（短持锁）。不读文件、不起线程。 */

/* 卡片名称：与分流页权重串的键名一致（singbox-manager 已把 zte_mwan*
 * 改写成 5G / 4G#1 / 4G#2，所以这里可以直接照抄原型文案）。 */
static const char *const network_overview_titles[NETWORK_MODEM_COUNT] = {
    "5G", "4G#1", "4G#2"
};

/* 徽标语气 */
enum network_overview_tone {
    NETWORK_TONE_NONE = 0,
    NETWORK_TONE_NEUTRAL,
    NETWORK_TONE_OK,
    NETWORK_TONE_WARN,
    NETWORK_TONE_DANGER
};

/* 本页私有控件句柄。destroy_network_overview() 只清 touchui-state.h 里的旧指针，
 * 这份由 network_overview_reset_locals()（页面文件）在建页开头清零。 */
static struct {
    lv_obj_t *scroll;
    lv_obj_t *kicker;
    lv_obj_t *value;
    lv_obj_t *unit;
    struct badge_component total_badge;
    lv_obj_t *chart_caption;
    lv_obj_t *chart_peak;
    lv_obj_t *chart;
    void *chart_series;
    lv_obj_t *name[NETWORK_MODEM_COUNT];
    lv_obj_t *signal[NETWORK_MODEM_COUNT];
    lv_obj_t *latency[NETWORK_MODEM_COUNT];
    lv_obj_t *down[NETWORK_MODEM_COUNT];
    lv_obj_t *up[NETWORK_MODEM_COUNT];
    lv_obj_t *weight_rule[NETWORK_MODEM_COUNT];
    lv_obj_t *weight_caption[NETWORK_MODEM_COUNT];
    lv_obj_t *weight_value[NETWORK_MODEM_COUNT];
    struct badge_component badge[NETWORK_MODEM_COUNT];
    int badge_tone[NETWORK_MODEM_COUNT];
    int weight_visible[NETWORK_MODEM_COUNT]; /* -1 未知 / 0 隐藏 / 1 显示 */
} network_overview_ui;

/* 速率拆成「数值 + 单位」两段，供摘要卡大数字 + 小单位排版（阈值与
 * format_scaled_bytes 一致：1024 进位、小于 10 保留一位小数）。 */
static void network_overview_split_rate(unsigned long long bytes,
                                        char *value, size_t value_size,
                                        char *unit, size_t unit_size)
{
    static const char *const units[] = {"B/s", "KB/s", "MB/s", "GB/s", "TB/s"};
    double scaled = (double)bytes;
    size_t index = 0;
    while (scaled >= 1024.0 && index + 1 < sizeof(units) / sizeof(units[0])) {
        scaled /= 1024.0;
        index++;
    }
    if (index == 0) snprintf(value, value_size, "%llu", bytes);
    else if (scaled < 10.0) snprintf(value, value_size, "%.1f", scaled);
    else snprintf(value, value_size, "%.0f", scaled);
    safe_copy(unit, unit_size, units[index]);
}

/* 第 ordinal 个历史点（0 = 最旧）的三卡下行合计（字节/秒）。
 * 三张卡的历史由 update_network_history 同步推进，这里仍按各自 count 兜底。 */
static unsigned long long network_overview_point_bytes(int ordinal)
{
    unsigned long long bytes = 0;
    for (int i = 0; i < NETWORK_MODEM_COUNT; i++) {
        const struct modem_history *history = &network_history[i];
        if (ordinal < 0 || ordinal >= history->count) continue;
        bytes += history->rx_rate[history_value_index(history, ordinal)];
    }
    return bytes;
}

/* 从 "5G:1,4G#1:2,4G#2:2" 取本卡权重；找不到或非正数返回 -1。 */
static int network_overview_weight_for(const char *weights, const char *name)
{
    const char *cursor = weights;
    size_t name_len;
    if (!weights || !name || !*weights) return -1;
    name_len = strlen(name);
    while (cursor && *cursor) {
        const char *comma = strchr(cursor, ',');
        size_t token_len = comma ? (size_t)(comma - cursor) : strlen(cursor);
        const char *colon = memchr(cursor, ':', token_len);
        if (colon && (size_t)(colon - cursor) == name_len &&
            !strncmp(cursor, name, name_len)) {
            int value = atoi(colon + 1);
            return value > 0 ? value : -1;
        }
        cursor = comma ? comma + 1 : NULL;
    }
    return -1;
}

/* 徽标语气：无数据 = neutral；离线 = danger；在线但 RSRP 收不到 / ≤ -105 dBm
 * 或路径延迟 ≥ 300 ms = warn；其余 = ok。 */
static int network_overview_tone(const struct network_status *status,
                                 const struct modem_status *modem)
{
    if (!status->valid || !modem->valid) return NETWORK_TONE_NEUTRAL;
    if (!modem->online) return NETWORK_TONE_DANGER;
    if (modem->rsrp == 0 || modem->rsrp <= -105) return NETWORK_TONE_WARN;
    if (modem->path_latency_valid && modem->path_latency >= 300.0)
        return NETWORK_TONE_WARN;
    return NETWORK_TONE_OK;
}

static uint32_t network_overview_tone_color(int tone)
{
    if (tone == NETWORK_TONE_OK) return COLOR_GREEN;
    if (tone == NETWORK_TONE_WARN) return COLOR_AMBER;
    if (tone == NETWORK_TONE_DANGER) return COLOR_RED;
    return COLOR_MUTED;
}

/* 右贴齐动态值：只在文本变化时重排，避免每 tick 都跑 lv_obj_update_layout。 */
static void network_overview_set_right(lv_obj_t *label, const char *text)
{
    const char *current;
    if (!label || !lv_label_set_text_p) return;
    if (!text) text = "--";
    current = lv_label_get_text_p ? lv_label_get_text_p(label) : NULL;
    if (current && !strcmp(current, text)) return;
    set_right_value(label, text);
}

/* 摘要卡「大数字 + 单位」：单位紧跟大数字右侧（原型 .big 里 .unit 是行内小字）。
 * 数字宽度随内容变化，所以文本变了才重排一次。 */
static void network_overview_set_summary_value(const char *value,
                                               const char *unit)
{
    const char *current;
    int value_width = 0;
    if (!network_overview_ui.value) return;
    current = lv_label_get_text_p ?
              lv_label_get_text_p(network_overview_ui.value) : NULL;
    if (!current || strcmp(current, value)) {
        lv_label_set_text_p(network_overview_ui.value, value);
        if (lv_obj_update_layout_p)
            lv_obj_update_layout_p(network_overview_ui.value);
        if (lv_obj_get_coords_p) {
            lv_area_compat_t area;
            memset(&area, 0, sizeof(area));
            lv_obj_get_coords_p(network_overview_ui.value, &area);
            value_width = area.x2 - area.x1 + 1;
        }
        /* 拿不到坐标时按字号兜底（"--" / "9.9" / "999" 都放得下） */
        if (value_width <= 0) value_width = font_line_height(ui_font_large) * 2;
        if (value_width <= 0) value_width = 46;
        if (network_overview_ui.unit) {
            int value_line = font_line_height(ui_font_large);
            int unit_line = font_line_height(ui_font_small);
            int unit_y = 20 + (value_line - unit_line) / 2;
            lv_obj_set_pos_p(network_overview_ui.unit, 12 + value_width + 4,
                             unit_y > 20 ? unit_y : 20);
        }
    }
    set_label_text_if_changed(network_overview_ui.unit, unit);
}

/* 有效权重行显示/隐藏（分隔线 + 标签 + 值三件一起）。 */
static void network_overview_set_weight_visible(int index, int visible)
{
    lv_obj_t *targets[3];
    if (index < 0 || index >= NETWORK_MODEM_COUNT) return;
    visible = visible ? 1 : 0;
    if (network_overview_ui.weight_visible[index] == visible) return;
    network_overview_ui.weight_visible[index] = visible;
    targets[0] = network_overview_ui.weight_rule[index];
    targets[1] = network_overview_ui.weight_caption[index];
    targets[2] = network_overview_ui.weight_value[index];
    for (int i = 0; i < 3; i++) {
        if (!targets[i]) continue;
        if (visible) lv_obj_clear_flag_p(targets[i], LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag_p(targets[i], LV_OBJ_FLAG_HIDDEN);
    }
}

/* 本卡有效权重文案："TCP 9 · UDP 4"（只有一边就只写一边）；
 * wanbal 无效或串空 → 返回 0，整行隐藏。 */
static int network_overview_format_weights(const struct wanbal_status *wanbal,
                                           const char *name, char *out,
                                           size_t size)
{
    int tcp, udp;
    out[0] = '\0';
    if (!wanbal->valid) return 0;
    tcp = network_overview_weight_for(wanbal->tcp_weights, name);
    udp = network_overview_weight_for(wanbal->udp_weights, name);
    if (tcp < 0 && udp < 0) return 0;
    if (tcp >= 0 && udp >= 0)
        snprintf(out, size, "TCP %d · UDP %d", tcp, udp);
    else if (tcp >= 0)
        snprintf(out, size, "TCP %d", tcp);
    else
        snprintf(out, size, "UDP %d", udp);
    return 1;
}

/* 摘要卡 + 图表：三卡下行合计、在线卡数、近 60 秒峰值。 */
static void refresh_network_overview_summary(const struct network_status *status)
{
    unsigned long long total = 0, peak_bytes = 0;
    char value[16], unit[16], peak[32], kicker[24], line[48];
    int online = 0, points;
    if (!network_overview_ui.kicker) return;

    for (int i = 0; i < NETWORK_MODEM_COUNT; i++) {
        const struct modem_status *modem = &status->modems[network_backend_index(i)];
        total += modem->rx_rate;
        if (status->valid && modem->valid && modem->online) online++;
    }
    if (status->valid) {
        static const char *const kickers[NETWORK_MODEM_COUNT + 1] = {
            "无卡在线", "一卡在线", "两卡在线", "三卡在线"
        };
        safe_copy(kicker, sizeof(kicker), kickers[online]);
        network_overview_split_rate(total, value, sizeof(value), unit, sizeof(unit));
    } else {
        safe_copy(kicker, sizeof(kicker), "读取中…");
        safe_copy(value, sizeof(value), "--");
        unit[0] = '\0';
    }
    set_label_text_if_changed(network_overview_ui.kicker, kicker);
    network_overview_set_summary_value(value, unit);

    if (!network_overview_ui.chart || !network_overview_ui.chart_series) return;
    /* 量程与峰值都按「三卡逐点求和」算（与 refresh_network_trend_ui 的
     * max_kib 同一口径，只是这里求和再取最大）。 */
    points = network_history[0].count;
    for (int i = 0; i < points; i++) {
        unsigned long long bytes = network_overview_point_bytes(i);
        if (bytes > peak_bytes) peak_bytes = bytes;
    }
    if (total > peak_bytes) peak_bytes = total;
    if (peak_bytes) format_rate_compact(peak_bytes, peak, sizeof(peak));
    else safe_copy(peak, sizeof(peak), "--");
    snprintf(line, sizeof(line), "峰值 %s", peak);
    set_label_text_if_changed(network_overview_ui.chart_peak, line);

    if (lv_chart_set_next_value_p) {
        int max_kib = (int)(peak_bytes / 1024ULL);
        if (max_kib < 1) max_kib = 1;
        if (lv_chart_set_range_p)
            lv_chart_set_range_p(network_overview_ui.chart,
                                 LV_CHART_AXIS_PRIMARY_Y, 0,
                                 max_kib + max_kib / 5 + 1);
        lv_chart_set_next_value_p(network_overview_ui.chart,
                                  network_overview_ui.chart_series,
                                  (int32_t)(total / 1024ULL));
        if (lv_chart_refresh_p) lv_chart_refresh_p(network_overview_ui.chart);
    }
}

/* 单张模块卡：状态点 / 徽标 / 2×2 指标 / 有效权重。 */
static void refresh_network_overview_card(const struct network_status *status,
                                          const struct wanbal_status *wanbal,
                                          int index)
{
    const struct modem_status *modem = &status->modems[network_backend_index(index)];
    static const char *const tone_texts[5] = {"", "--", "正常", "弱", "离线"};
    char text[48], weights[40];
    int tone;

    /* 状态点沿用旧口径：过期=琥珀、在线=绿、离线=红、无数据=灰 */
    set_network_dot_color(index,
        status->stale ? COLOR_AMBER :
        (modem->valid ? (modem->online ? COLOR_GREEN : COLOR_RED) : COLOR_MUTED));

    tone = network_overview_tone(status, modem);
    if (tone != network_overview_ui.badge_tone[index]) {
        uint32_t bg = COLOR_CARD_ALT;
        if (tone == NETWORK_TONE_OK) bg = touchui_theme.ok_soft;
        else if (tone == NETWORK_TONE_WARN) bg = touchui_theme.warn_soft;
        else if (tone == NETWORK_TONE_DANGER) bg = touchui_theme.danger_soft;
        set_badge(&network_overview_ui.badge[index], tone_texts[tone],
                  network_overview_tone_color(tone), bg);
        network_overview_ui.badge_tone[index] = tone;
    }

    if (status->valid && modem->valid && modem->rsrp)
        snprintf(text, sizeof(text), "%d dBm", modem->rsrp);
    else safe_copy(text, sizeof(text), "--");
    network_overview_set_right(network_overview_ui.signal[index], text);

    if (status->valid && modem->valid && modem->path_latency_valid &&
        modem->path_latency > 0.0)
        snprintf(text, sizeof(text), "%.0f ms", modem->path_latency);
    else safe_copy(text, sizeof(text), "--");
    network_overview_set_right(network_overview_ui.latency[index], text);

    if (status->valid) {
        format_rate_compact(modem->rx_rate, text, sizeof(text));
        network_overview_set_right(network_overview_ui.down[index], text);
        format_rate_compact(modem->tx_rate, text, sizeof(text));
        network_overview_set_right(network_overview_ui.up[index], text);
    } else {
        network_overview_set_right(network_overview_ui.down[index], "--");
        network_overview_set_right(network_overview_ui.up[index], "--");
    }

    if (network_overview_format_weights(wanbal, network_overview_titles[index],
                                        weights, sizeof(weights))) {
        set_label_text_if_changed(network_overview_ui.weight_value[index], weights);
        network_overview_set_weight_visible(index, 1);
    } else {
        network_overview_set_weight_visible(index, 0);
    }
}

static void refresh_network_ui(void)
{
    struct network_status status;
    struct wanbal_status wanbal;
    int generation;
    pthread_mutex_lock(&shared_lock);
    generation = shared_network_generation;
    if (generation == ui_network_generation) {
        pthread_mutex_unlock(&shared_lock);
        return;
    }
    status = shared_network_status;
    /* 有效权重同批读出。ui_wanbal_status 只在分流页打开时更新，这里必须读
     * shared_wanbal_status；分流流程从未跑过时它就是空串 → 权重行隐藏。 */
    wanbal = shared_wanbal_status;
    pthread_mutex_unlock(&shared_lock);
    ui_network_generation = generation;
    ui_network_status = status;
    update_network_history(&status);

    if (network_page) {
        refresh_network_overview_summary(&status);
        for (int i = 0; i < NETWORK_MODEM_COUNT; i++)
            refresh_network_overview_card(&status, &wanbal, i);
    }
    if (network_detail_page) refresh_network_detail_ui();
    refresh_device_ui();
}
