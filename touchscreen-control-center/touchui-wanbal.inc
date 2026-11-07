/* 分流页：分段控件 + 有效权重 + 底部 toast 的数据整理与刷新。
 *
 * 数据只来自 `ui_wanbal_status`（`struct wanbal_status`）：
 *   preset / mode / tcp_weights / udp_weights / degraded / updated / valid / stale
 * 权重串格式："5G:1,4G#1:2,4G#2:2"（singbox-manager 已把 zte_mwan* 美化成 5G/4G#N）。
 *
 * 布局由 touchui-wanbal-page.inc 建立；本文件只负责「把状态写进控件」。
 */
static lv_obj_t *wanbal_auto_button, *wanbal_shared_button;
static lv_obj_t *wanbal_auto_label, *wanbal_shared_label;
static lv_obj_t *wanbal_hint_label;
static lv_obj_t *wanbal_tcp_note_label, *wanbal_udp_note_label;
static lv_obj_t *wanbal_tcp_value[3], *wanbal_udp_value[3];
static struct hbar_component wanbal_tcp_bar[3], wanbal_udp_bar[3];
static struct badge_component wanbal_toast;
static lv_obj_t *wanbal_updated_label;
/* 进度条上次画的百分比：-1 表示还没画过（首帧必刷） */
static int wanbal_tcp_pct[3] = {-1, -1, -1};
static int wanbal_udp_pct[3] = {-1, -1, -1};
/* 右侧数值上次显示的值（-2 = 未定；-1 = "--"） */
static int wanbal_tcp_val[3] = {-2, -2, -2};
static int wanbal_udp_val[3] = {-2, -2, -2};
/* toast 上次文案；空串 = 当前隐藏 */
static char wanbal_toast_text[56];
/* 已上色的「降权」卡位掩码（bit0=5G bit1=4G#1 bit2=4G#2）；-1 = 未定 */
static int wanbal_bar_mask = -1;
/* hint 当前是否为 warn 色；-1 = 未定 */
static int wanbal_hint_warn = -1;
/* 分段控件上次涂的字色状态：位掩码 1=auto 2=shared 4=custom；-1=未定 */
static int wanbal_seg_selected = -1;
static struct page_shell wanbal_shell;

/* ---- 「自定义」手动选池（排期第 6 天） --------------------------------
 * 视图与草稿只活在 UI 线程：
 *   wanbal_view_custom  0=权重卡（auto/shared） 1=自定义卡
 *   wanbal_view_pinned  1=用户点了「自定义」，视图不再跟随 preset 回落
 *   wanbal_draft_*      待下发池掩码（bit0=5G bit1=4G#1 bit2=4G#2）+ 溢出开关
 * 点分段只切视图/播种草稿；只有「应用分流」才入队 ACTION_WAN_MODE_CUSTOM。 */
static lv_obj_t *wanbal_custom_button, *wanbal_custom_label;
static lv_obj_t *wanbal_weight_card, *wanbal_custom_card;
static lv_obj_t *wanbal_tcp_chip[3], *wanbal_udp_chip[3];
static lv_obj_t *wanbal_tcp_chip_label[3], *wanbal_udp_chip_label[3];
static lv_obj_t *wanbal_tcp_summary_label, *wanbal_udp_summary_label;
static lv_obj_t *wanbal_overflow_button, *wanbal_overflow_label;
static lv_obj_t *wanbal_custom_state_label;
static lv_obj_t *wanbal_apply_button, *wanbal_apply_label;
static int wanbal_view_custom, wanbal_view_pinned;
static int wanbal_draft_tcp, wanbal_draft_udp, wanbal_draft_overflow;
static int wanbal_draft_seeded;
/* 上次涂过的 chip 状态（overflow<<6 | udp<<3 | tcp）；-1 = 未涂 */
static int wanbal_chip_painted = -1;
/* 状态行上次用的色号；-1 = 未定 */
static int wanbal_state_tone = -1;

/* 权重行的卡片标签，顺序与 wanbal_parse_weights() 的输出数组一致。 */
static const char *const wanbal_card_labels[3] = {"5G", "4G#1", "4G#2"};

static void wanbal_mode_label(const char *preset, char *out, size_t size)
{
    if (!strcmp(preset, "auto"))
        safe_copy(out, size, "自动·质量");
    else if (!strcmp(preset, "shared"))
        safe_copy(out, size, "三卡共池");
    else if (!strcmp(preset, "game"))
        safe_copy(out, size, "游戏硬绑");
    else if (!strcmp(preset, "custom"))
        safe_copy(out, size, "自定义");
    else
        safe_copy(out, size, "未知");
}

/* Vendor iface → panel label (zte_mwan4 is 4G#2, not a 4th modem).
 * 幂等：已经美化过的串（4G#1 …）原样复制。 */
static void wanbal_pretty_ifaces(const char *in, char *out, size_t size)
{
    const char *s;
    size_t o = 0;
    out[0] = '\0';
    if (!in) return;
    for (s = in; *s && o + 1 < size; ) {
        if (!strncmp(s, "zte_mwan2", 9)) {
            if (o + 2 >= size) break;
            out[o++] = '5'; out[o++] = 'G';
            s += 9;
        } else if (!strncmp(s, "zte_mwan3", 9)) {
            if (o + 4 >= size) break;
            out[o++] = '4'; out[o++] = 'G'; out[o++] = '#'; out[o++] = '1';
            s += 9;
        } else if (!strncmp(s, "zte_mwan4", 9)) {
            if (o + 4 >= size) break;
            out[o++] = '4'; out[o++] = 'G'; out[o++] = '#'; out[o++] = '2';
            s += 9;
        } else {
            out[o++] = *s++;
        }
    }
    out[o] = '\0';
}

/* 逗号分隔的标签列表里是否有完整的一项（degraded = "4G#1,4G#2"）。 */
static int wanbal_label_listed(const char *list, const char *label)
{
    const char *p = list;
    size_t len = strlen(label);
    if (!list || !list[0]) return 0;
    while (*p) {
        const char *end = strchr(p, ',');
        size_t seg;
        if (!end) end = p + strlen(p);
        seg = (size_t)(end - p);
        while (seg && *p == ' ') { p++; seg--; }
        while (seg && p[seg - 1] == ' ') seg--;
        if (seg == len && !strncmp(p, label, len)) return 1;
        p = (*end) ? end + 1 : end;
    }
    return 0;
}

/* 池掩码 → "5G · 4G#1"；sep 由调用方给（chip 汇总 " · "，hint 用 ","）。 */
static void wanbal_mask_labels(int mask, const char *sep, char *out, size_t size)
{
    size_t used = 0;
    int i;
    if (!out || !size) return;
    out[0] = '\0';
    for (i = 0; i < 3; i++) {
        int written;
        if (!((mask >> i) & 1)) continue;
        written = snprintf(out + used, size - used, "%s%s",
                           used ? sep : "", wanbal_card_labels[i]);
        if (written < 0 || (size_t)written >= size - used) break;
        used += (size_t)written;
    }
}

/* 池串（管理端已美化的 "5G,4G#1"，或原样 zte_mwan*）→ 掩码。 */
static int wanbal_pool_mask(const char *list)
{
    int mask = 0, i;
    char pretty[96];
    if (!list || !list[0]) return 0;
    wanbal_pretty_ifaces(list, pretty, sizeof(pretty));
    for (i = 0; i < 3; i++)
        if (wanbal_label_listed(pretty, wanbal_card_labels[i]))
            mask |= 1 << i;
    return mask;
}

/* 播种草稿：当前已是 custom 就照状态回填，否则给默认（TCP=5G / UDP=双4G / 不溢出）。
 * 解析失败（空池）也落回默认，保证 raw chip 永远有选中项。 */
static void wanbal_seed_custom(const struct wanbal_status *st)
{
    int tcp = 0, udp = 0, overflow = 0;
    if (st && st->valid && !strcmp(st->preset, "custom")) {
        tcp = wanbal_pool_mask(st->tcp_pool) & 7;
        udp = wanbal_pool_mask(st->udp_pool) & 7;
        overflow = st->overflow[0] == '1';
    }
    wanbal_draft_tcp = tcp ? tcp : 1;
    wanbal_draft_udp = udp ? udp : 6;
    wanbal_draft_overflow = overflow ? 1 : 0;
    wanbal_draft_seeded = 1;
    wanbal_chip_painted = -1;
}

/* chip / 溢出开关 / 行头汇总：只在草稿变化时重涂，避免每 5s 重排布局。 */
static void wanbal_paint_chips(void)
{
    char tcp_sum[40], udp_sum[40];
    int key, i;
    key = (wanbal_draft_overflow << 6) | ((wanbal_draft_udp & 7) << 3) |
          (wanbal_draft_tcp & 7);
    if (key == wanbal_chip_painted) return;
    wanbal_chip_painted = key;
    for (i = 0; i < 3; i++) {
        int tcp_on = (wanbal_draft_tcp >> i) & 1;
        int udp_on = (wanbal_draft_udp >> i) & 1;
        set_checked(wanbal_tcp_chip[i], tcp_on);
        set_checked(wanbal_udp_chip[i], udp_on);
        set_text_color(wanbal_tcp_chip_label[i], tcp_on ? COLOR_ACCENT : COLOR_MUTED);
        set_text_color(wanbal_udp_chip_label[i], udp_on ? COLOR_ACCENT : COLOR_MUTED);
    }
    set_checked(wanbal_overflow_button, wanbal_draft_overflow);
    set_text_color(wanbal_overflow_label,
                   wanbal_draft_overflow ? COLOR_ACCENT : COLOR_MUTED);
    wanbal_mask_labels(wanbal_draft_tcp, " · ", tcp_sum, sizeof(tcp_sum));
    wanbal_mask_labels(wanbal_draft_udp, " · ", udp_sum, sizeof(udp_sum));
    set_right_value(wanbal_tcp_summary_label, tcp_sum);
    set_right_value(wanbal_udp_summary_label, udp_sum);
}

/* 显隐（LVGL 没有 set_hidden，统一走 flag）。 */
static void wanbal_show(lv_obj_t *obj, int visible)
{
    if (!obj) return;
    if (visible) lv_obj_clear_flag_p(obj, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag_p(obj, LV_OBJ_FLAG_HIDDEN);
}

/* 分段选中态 + 两张卡的显隐（点分段和 refresh 都走这里）。 */
static void wanbal_paint_segments(void)
{
    int is_custom = wanbal_view_custom;
    int is_auto = !is_custom && !strcmp(ui_wanbal_status.preset, "auto");
    int is_shared = !is_custom && !strcmp(ui_wanbal_status.preset, "shared");
    int seg_state = (is_auto ? 1 : 0) | (is_shared ? 2 : 0) | (is_custom ? 4 : 0);
    if (seg_state != wanbal_seg_selected) {
        set_checked(wanbal_auto_button, is_auto);
        set_checked(wanbal_shared_button, is_shared);
        set_checked(wanbal_custom_button, is_custom);
        set_text_color(wanbal_auto_label, is_auto ? COLOR_TEXT : COLOR_MUTED);
        set_text_color(wanbal_shared_label, is_shared ? COLOR_TEXT : COLOR_MUTED);
        set_text_color(wanbal_custom_label, is_custom ? COLOR_TEXT : COLOR_MUTED);
        wanbal_seg_selected = seg_state;
    }
    wanbal_show(wanbal_weight_card, !is_custom);
    wanbal_show(wanbal_custom_card, is_custom);
}

/* 一侧可用性文案；返回 1 表示要用 warn 色（blocked / spill）。 */
static int wanbal_pool_word(const char *proto, const char *state, const char *live,
                            char *out, size_t size)
{
    if (!strcmp(state, "ok")) {
        snprintf(out, size, "%s 就绪", proto);
        return 0;
    }
    if (!strcmp(state, "partial")) {
        int count = (live && live[0]) ? atoi(live) : 0;
        snprintf(out, size, "%s 仅%d张可用", proto, count);
        return 0;
    }
    if (!strcmp(state, "blocked")) {
        snprintf(out, size, "%s 已阻断", proto);
        return 1;
    }
    if (!strcmp(state, "spill")) {
        snprintf(out, size, "%s 溢出共用", proto);
        return 1;
    }
    snprintf(out, size, "%s 待生效", proto);
    return 0;
}

/* 自定义卡底部状态行：只有 preset=custom 才有快照可用。 */
static void wanbal_paint_custom_state(const struct wanbal_status *st)
{
    char left[48], right[48], text[96];
    int warn = 0, tone;
    if (!st->valid || strcmp(st->preset, "custom") != 0) {
        safe_copy(text, sizeof(text), "应用后显示可用性");
        tone = COLOR_MUTED;
    } else {
        int ok;
        warn |= wanbal_pool_word("TCP", st->tcp_state, st->tcp_live,
                                 left, sizeof(left));
        warn |= wanbal_pool_word("UDP", st->udp_state, st->udp_live,
                                 right, sizeof(right));
        ok = !warn && !strcmp(st->tcp_state, "ok") && !strcmp(st->udp_state, "ok");
        snprintf(text, sizeof(text), "%s · %s", left, right);
        tone = warn ? COLOR_AMBER : (ok ? COLOR_GREEN : COLOR_MUTED);
    }
    set_label_text_if_changed(wanbal_custom_state_label, text);
    if (tone != wanbal_state_tone) {
        set_text_color(wanbal_custom_state_label, tone);
        wanbal_state_tone = tone;
    }
}

static void wanbal_parse_weights(const char *text, int out[3])
{
    const char *p;
    out[0] = out[1] = out[2] = -1;
    if (!text || !text[0]) return;
    p = text;
    while (*p) {
        const char *end = strchr(p, ',');
        const char *colon;
        size_t label_len;
        int index = -1;
        if (!end) end = p + strlen(p);
        colon = memchr(p, ':', (size_t)(end - p));
        if (colon) {
            label_len = (size_t)(colon - p);
            if (label_len == 2 && !strncmp(p, "5G", 2)) index = 0;
            else if (label_len == 4 && !strncmp(p, "4G#1", 4)) index = 1;
            else if (label_len == 4 && !strncmp(p, "4G#2", 4)) index = 2;
            if (index >= 0) {
                char *num_end = NULL;
                long value = strtol(colon + 1, &num_end, 10);
                if (num_end != colon + 1 && value > 0) {
                    if (value > 999) value = 999;
                    out[index] = (int)value;
                } else if (num_end != colon + 1) {
                    out[index] = 0;
                }
            }
        }
        p = (*end) ? end + 1 : end;
    }
}

static int wanbal_max_weight(const int weights[3])
{
    int max = -1, i;
    for (i = 0; i < 3; i++)
        if (weights[i] > max) max = weights[i];
    return max;
}

/* 条长 = 值 / 组内最大值 ×100（原型 renderWeights 的归一方式）。 */
static int wanbal_scale_weight(int value, int max)
{
    if (value <= 0 || max <= 0) return 0;
    if (value >= max) return 100;
    return value * 100 / max;
}

/* 当前哪些卡被降权：bit0=5G bit1=4G#1 bit2=4G#2。 */
static int wanbal_degraded_mask(const struct wanbal_status *st)
{
    int mask = 0, i;
    char pretty[96];
    if (!st || !st->valid) return 0;
    wanbal_pretty_ifaces(st->degraded, pretty, sizeof(pretty));
    for (i = 0; i < 3; i++)
        if (wanbal_label_listed(pretty[0] ? pretty : st->degraded,
                               wanbal_card_labels[i]))
            mask |= 1 << i;
    return mask;
}

/* 组头右侧文案：质量加权 / 均分 / 硬绑。 */
static const char *wanbal_group_note(const struct wanbal_status *st)
{
    if (!st->valid) return "--";
    if (!strcmp(st->preset, "auto")) return "质量加权";
    if (!strcmp(st->preset, "shared")) return "均分";
    if (!strcmp(st->preset, "game")) return "硬绑";
    return "--";
}

/* hint 一行文案；返回 1 表示这是「降权」提示（要用 warn 色）。 */
static int wanbal_hint_text(const struct wanbal_status *st, char *out, size_t size)
{
    char pretty[96], label[24];
    if (wanbal_view_custom) {
        /* 自定义视图：hint 只报草稿摘要，可用性放卡内状态行 */
        char tcp[40], udp[40];
        wanbal_mask_labels(wanbal_draft_tcp, ",", tcp, sizeof(tcp));
        wanbal_mask_labels(wanbal_draft_udp, ",", udp, sizeof(udp));
        snprintf(out, size, "自定义：TCP=%s · UDP=%s", tcp, udp);
        return 0;
    }
    if (!st->valid) {
        safe_copy(out, size, "读取中…");
        return 0;
    }
    if (st->degraded[0]) {
        wanbal_pretty_ifaces(st->degraded, pretty, sizeof(pretty));
        snprintf(out, size, "降权：%s", pretty[0] ? pretty : st->degraded);
        return 1;
    }
    if (!strcmp(st->preset, "auto")) {
        safe_copy(out, size, "质量加权共池；TCP 偏 5G，UDP 偏 4G。");
        return 0;
    }
    if (!strcmp(st->preset, "shared")) {
        safe_copy(out, size, "三卡共池；按连接在三张卡之间分配。");
        return 0;
    }
    if (!strcmp(st->preset, "game")) {
        safe_copy(out, size, "硬绑 TCP→5G · UDP→双4G");
        return 0;
    }
    wanbal_mode_label(st->preset, label, sizeof(label));
    snprintf(out, size, "当前预设：%s", label);
    return 0;
}

/* 刷 hint（降权提示 warn 色；其余 muted）。点 chip 后立即调用，不必等轮询。 */
static void wanbal_paint_hint(void)
{
    char hint[128];
    int warn = wanbal_hint_text(&ui_wanbal_status, hint, sizeof(hint));
    set_label_text_if_changed(wanbal_hint_label, hint);
    if (warn != wanbal_hint_warn) {
        set_text_color(wanbal_hint_label, warn ? COLOR_AMBER : COLOR_MUTED);
        wanbal_hint_warn = warn;
    }
}

/* toast 是定宽胶囊（280px）；过长消息按 UTF-8 边界截断并补省略号。 */
static const char *wanbal_clip_toast(const char *in, char *buf, size_t size)
{
    size_t limit = 45, n; /* 45 字节 ≈ 15 个汉字，再留 3 字节给「…」 */
    if (!in || !in[0] || !size) return "";
    n = strlen(in);
    if (n <= 48) return in;
    if (limit + 4 > size) limit = size > 4 ? size - 4 : 0;
    while (limit > 0 && ((unsigned char)in[limit] & 0xc0u) == 0x80u) limit--;
    memcpy(buf, in, limit);
    memcpy(buf + limit, "…", 4); /* 含结尾 NUL */
    return buf;
}

/* 单行：标签 / 条 / 右侧数值。值缺失（-1）显示 "--"、条留空。
 * 数值与条长都只在变化时写，避免每帧触发布局重算。
 * 注意：条长同时取决于值和组内最大值，所以两者都要进缓存比较。 */
static void wanbal_set_weight_row(struct hbar_component *bar, lv_obj_t *value_label,
                                  int weight, int max, int *cached_pct, int *cached_val)
{
    char text[16];
    int pct = (weight < 0) ? 0 : wanbal_scale_weight(weight, max);
    if (pct == *cached_pct && weight == *cached_val) return;
    if (weight < 0)
        safe_copy(text, sizeof(text), "--");
    else
        snprintf(text, sizeof(text), "%d", weight);
    if (pct != *cached_pct) {
        set_hbar(bar, pct);
        *cached_pct = pct;
    }
    set_right_value(value_label, text);
    *cached_val = weight;
}

/* toast 只在文案变化时写入（set_toast 每次都会重设样式）。 */
static void wanbal_set_toast(struct badge_component *toast, const char *text)
{
    if (!text) text = "";
    if (!strcmp(wanbal_toast_text, text)) return;
    safe_copy(wanbal_toast_text, sizeof(wanbal_toast_text), text);
    set_toast(toast, text);
}

static int action_is_wanbal(int action)
{
    return action == ACTION_WAN_MODE_AUTO || action == ACTION_WAN_MODE_SHARED ||
           action == ACTION_WAN_MODE_CUSTOM;
}

static void refresh_wanbal_ui(void)
{
    struct wanbal_status status;
    char message[160], text[48], clip[56];
    const char *note;
    int tcp[3], udp[3], tcp_max, udp_max, mask, i;
    int generation, action_running;
    if (!wanbal_page) return;
    pthread_mutex_lock(&shared_lock);
    generation = shared_wanbal_generation + shared_generation;
    if (generation == ui_wanbal_generation) {
        pthread_mutex_unlock(&shared_lock);
        return;
    }
    status = shared_wanbal_status;
    safe_copy(message, sizeof(message),
              shared_message_page == PAGE_WANBAL ? shared_message : "");
    action_running = action_is_wanbal(shared_action_running ?
                                      shared_running_action : shared_action);
    pthread_mutex_unlock(&shared_lock);
    ui_wanbal_generation = generation;
    ui_wanbal_status = status;

    /* 视图：没点过分段时跟随 preset；点过分段后停在用户选的那一屏
     * （自定义草稿视图 / 权重视图），等动作盖章 */
    if (!wanbal_view_pinned)
        wanbal_view_custom = (status.valid && !strcmp(status.preset, "custom")) ?
                             1 : 0;
    if (wanbal_view_custom && !wanbal_draft_seeded && status.valid)
        wanbal_seed_custom(&status);
    wanbal_paint_segments();
    wanbal_paint_chips();
    wanbal_paint_custom_state(&status);
    wanbal_paint_hint();

    /* 权重卡两组 */
    note = wanbal_group_note(&status);
    set_right_value(wanbal_tcp_note_label, note);
    set_right_value(wanbal_udp_note_label, note);
    wanbal_parse_weights(status.valid ? status.tcp_weights : "", tcp);
    wanbal_parse_weights(status.valid ? status.udp_weights : "", udp);
    tcp_max = wanbal_max_weight(tcp);
    udp_max = wanbal_max_weight(udp);
    mask = wanbal_degraded_mask(&status);
    if (mask != wanbal_bar_mask) {
        for (i = 0; i < 3; i++) {
            uint32_t color = (mask & (1 << i)) ? COLOR_AMBER : COLOR_ACCENT;
            set_hbar_color(&wanbal_tcp_bar[i], color);
            set_hbar_color(&wanbal_udp_bar[i], color);
        }
        wanbal_bar_mask = mask;
    }
    for (i = 0; i < 3; i++) {
        wanbal_set_weight_row(&wanbal_tcp_bar[i], wanbal_tcp_value[i],
                              tcp[i], tcp_max, &wanbal_tcp_pct[i],
                              &wanbal_tcp_val[i]);
        wanbal_set_weight_row(&wanbal_udp_bar[i], wanbal_udp_value[i],
                              udp[i], udp_max, &wanbal_udp_pct[i],
                              &wanbal_udp_val[i]);
    }

    /* 底部：更新时刻 + toast（空串即隐藏） */
    if (status.valid)
        snprintf(text, sizeof(text), "更新于 %s", status.updated);
    else
        safe_copy(text, sizeof(text), "更新于 --:--:--");
    set_label_text_if_changed(wanbal_updated_label, text);

    if (action_running)
        wanbal_set_toast(&wanbal_toast, "正在切换…");
    else if (message[0])
        wanbal_set_toast(&wanbal_toast, wanbal_clip_toast(message, clip, sizeof(clip)));
    else if (status.stale)
        wanbal_set_toast(&wanbal_toast, "状态可能过期");
    else
        wanbal_set_toast(&wanbal_toast, "");
}

static void wanbal_auto_clicked(void *event)
{
    (void)event;
    /* 离开自定义草稿视图：停在权重视图，不再被 refresh 按 preset 拉回 */
    wanbal_view_pinned = 1;
    wanbal_view_custom = 0;
    wanbal_paint_segments();
    wanbal_paint_hint();
    show_confirm(ACTION_WAN_MODE_AUTO,
                 "切换为自动质量分流（弱网可溢出）？");
}

static void wanbal_shared_clicked(void *event)
{
    (void)event;
    wanbal_view_pinned = 1;
    wanbal_view_custom = 0;
    wanbal_paint_segments();
    wanbal_paint_hint();
    show_confirm(ACTION_WAN_MODE_SHARED,
                 "切换为三卡共池（无协议软偏置）？");
}

/* 点「自定义」只切视图 + 播种草稿，不下发（原型 data-preset 行为）。 */
static void wanbal_custom_clicked(void *event)
{
    (void)event;
    wanbal_view_pinned = 1;
    wanbal_view_custom = 1;
    wanbal_seed_custom(&ui_wanbal_status);
    wanbal_paint_segments();
    wanbal_paint_chips();
    wanbal_paint_hint();
}

/* 一行至少留一张：点最后一张被选中时忽略并提示。 */
static void wanbal_toggle_pool(int proto, int card)
{
    int *mask = proto ? &wanbal_draft_udp : &wanbal_draft_tcp;
    int bit = 1 << card;
    if (*mask & bit) {
        if ((*mask & 7) == bit) {
            wanbal_set_toast(&wanbal_toast, "至少保留一张卡");
            return;
        }
        *mask &= ~bit;
    } else {
        *mask |= bit;
    }
    wanbal_paint_chips();
    wanbal_paint_hint();
}

static void wanbal_tcp_chip0_clicked(void *event) { (void)event; wanbal_toggle_pool(0, 0); }
static void wanbal_tcp_chip1_clicked(void *event) { (void)event; wanbal_toggle_pool(0, 1); }
static void wanbal_tcp_chip2_clicked(void *event) { (void)event; wanbal_toggle_pool(0, 2); }
static void wanbal_udp_chip0_clicked(void *event) { (void)event; wanbal_toggle_pool(1, 0); }
static void wanbal_udp_chip1_clicked(void *event) { (void)event; wanbal_toggle_pool(1, 1); }
static void wanbal_udp_chip2_clicked(void *event) { (void)event; wanbal_toggle_pool(1, 2); }

static void wanbal_overflow_clicked(void *event)
{
    (void)event;
    wanbal_draft_overflow = !wanbal_draft_overflow;
    wanbal_paint_chips();
}

/* 「应用分流」：掩码按 5G,4G#1,4G#2 顺序由 worker 拼 csv。 */
static void wanbal_apply_custom_clicked(void *event)
{
    (void)event;
    if (!(wanbal_draft_tcp & 7) || !(wanbal_draft_udp & 7)) {
        wanbal_set_toast(&wanbal_toast, "至少保留一张卡");
        return;
    }
    queue_action_with_params(ACTION_WAN_MODE_CUSTOM,
                             wanbal_draft_overflow ? 1 : 0,
                             wanbal_draft_tcp & 7, wanbal_draft_udp & 7);
}
