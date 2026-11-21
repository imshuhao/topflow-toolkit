/* 锁屏/原厂三卡页 5G 速率改写（2026-09-18，根因与方案评审见 HANDOVER §18/§19）。
 *
 * 背景：原厂三卡页与锁屏速度 widget 的 5G 上行取自 QCMAP modem 侧 per-PDN
 * 计数，LAN/WAN 同 /64（ndp relay）hairpin 与历史累计使其常年 ≈下行；
 * QCMAP 无干净口径配置、改二进制与重启 QCMAP 均为红线（§18/§19 五路排查）。
 * 这里在 stock 渲染之后按拍把 5G 卡的 ↑/↓ 速率改写为 netdev 干净速率
 * （ui_network_status.modems[0]，已是 rmnet_data0+rmnet_ipa0 口径）。
 *
 * stock 的速率由两个 label 组成：数值 label（"266.5"/"--"）+ 单位 label
 * （"Mb/s"/"Kb/s"），↑/↓ 是独立图形对象；walk 顺序里每张卡依次出现
 * ↑对、↓对（帧抓取+转储标定：首个 quad = 5G 卡，对内前者为 ↑）。
 * 隐藏页面对象（祖先 HIDDEN 链）一律跳过，只处理当前可见页。
 *
 * 安全设计（fail-closed）：
 * - 符号缺失 / 非 stock 页 / 可见速率对数量不符 → 本拍不写任何对象；
 * - 对象指针零缓存，每拍从 scr_act 重新遍历（stock 页销毁重建无野指针）；
 * - 只写 5G 卡（首个 quad）的两个 label 或锁屏 widget 的两个 label；
 *   4G 卡与其它页面一律不碰；set-if-changed 避免多余 invalidate。
 */

#define STOCK_SPEED_INTERVAL_MS 400LL
#define STOCK_SPEED_MAX_DEPTH 12
#define STOCK_SPEED_MAX_NODES 1000
#define STOCK_SPEED_MAX_PAIRS 12
#define STOCK_SPEED_PARENT_HOPS 12

struct stock_speed_pair {
    lv_obj_t *num;
    lv_obj_t *unit;
};

static int stock_speed_is_number(const char *text)
{
    const char *p = text;
    int digits = 0;
    if (!p || !*p) return 0;
    if (!strcmp(p, "--")) return 1;
    while (*p >= '0' && *p <= '9') { p++; digits++; }
    if (!digits || *p != '.') return 0;
    p++;
    if (*p < '0' || *p > '9') return 0;
    p++;
    return *p == '\0';
}

static int stock_speed_is_unit(const char *text)
{
    return text && (!strcmp(text, "Mb/s") || !strcmp(text, "Kb/s"));
}

/* 祖先链含 HIDDEN 即不可见（stock 把所有页面对象常驻在同一 scr_act 树下） */
static int stock_speed_hidden(lv_obj_t *obj)
{
    int hops = 0;
    while (obj && hops++ < STOCK_SPEED_PARENT_HOPS) {
        if (lv_obj_has_flag_p(obj, LV_OBJ_FLAG_HIDDEN)) return 1;
        obj = lv_obj_get_parent_p(obj);
    }
    return 0;
}

static void stock_speed_walk(lv_obj_t *parent, int depth,
                             struct stock_speed_pair *pairs, int *count,
                             int *visited)
{
    uint32_t i, total;
    if (!parent || depth > STOCK_SPEED_MAX_DEPTH) return;
    if (*visited >= STOCK_SPEED_MAX_NODES || *count >= STOCK_SPEED_MAX_PAIRS)
        return;
    total = lv_obj_get_child_cnt_p(parent);
    for (i = 0; i < total; i++) {
        lv_obj_t *child = lv_obj_get_child_p(parent, (int32_t)i);
        const char *text;
        if (!child) continue;
        if (++(*visited) > STOCK_SPEED_MAX_NODES) return;
        if (lv_obj_check_type_p(child, lv_label_class_p) &&
            !stock_speed_hidden(child)) {
            text = lv_label_get_text_p(child);
            if (stock_speed_is_number(text)) {
                pairs[*count].num = child;
                pairs[*count].unit = NULL;
            } else if (stock_speed_is_unit(text) &&
                       *count < STOCK_SPEED_MAX_PAIRS &&
                       pairs[*count].num && !pairs[*count].unit) {
                pairs[*count].unit = child;
                (*count)++;
            }
        }
        stock_speed_walk(child, depth + 1, pairs, count, visited);
    }
}

static void format_stock_speed(unsigned long long bytes_per_s, char *num_out,
                               size_t num_size, const char **unit)
{
    double bits = (double)bytes_per_s * 8.0;
    if (bits >= 1000000.0) {
        snprintf(num_out, num_size, "%.1f", bits / 1000000.0);
        *unit = "Mb/s";
    } else {
        snprintf(num_out, num_size, "%.1f", bits / 1000.0);
        *unit = "Kb/s";
    }
}

/* stock 速率 label 角色映射（仅指针值比较，从不解引用；失效即清空） */
static lv_obj_t *stock_speed_num_up, *stock_speed_num_down;
static lv_obj_t *stock_speed_unit_up, *stock_speed_unit_down;
static int stock_speed_map_is_lockscreen; /* 映射来自锁屏 widget：显示三网合计 */

static void stock_speed_clear_map(void)
{
    stock_speed_num_up = stock_speed_num_down = NULL;
    stock_speed_unit_up = stock_speed_unit_down = NULL;
    stock_speed_map_is_lockscreen = 0;
}

/* 锁屏 widget 是全网合计口径：三张卡速率求和；三卡页只换 5G 卡 */
static void stock_speed_rates(unsigned long long *rx, unsigned long long *tx)
{
    if (stock_speed_map_is_lockscreen) {
        int i;
        *rx = *tx = 0;
        for (i = 0; i < NETWORK_MODEM_COUNT; i++) {
            *rx += ui_network_status.modems[i].rx_rate;
            *tx += ui_network_status.modems[i].tx_rate;
        }
    } else {
        *rx = ui_network_status.modems[0].rx_rate;
        *tx = ui_network_status.modems[0].tx_rate;
    }
}

static void patch_stock_speed_page(void)
{
    static long long last_run_ms;
    static int last_reported_count = -1;
    struct stock_speed_pair pairs[STOCK_SPEED_MAX_PAIRS];
    lv_disp_t *disp;
    lv_obj_t *screen;
    long long now;
    int count = 0, visited = 0, locked, ok = 0;

    if (!lv_obj_check_type_p || !lv_obj_get_coords_p || !lv_label_class_p ||
        !lv_obj_get_parent_p || !lv_disp_get_default_p ||
        !lv_disp_get_scr_act_p || !lv_obj_get_child_cnt_p ||
        !lv_obj_get_child_p || !lv_obj_has_flag_p ||
        !lv_label_get_text_p || !lv_label_set_text_p)
        return;
    if (current_page != PAGE_STOCK || !ui_network_status.valid) {
        stock_speed_clear_map();
        return;
    }
    now = monotonic_millis();
    if (last_run_ms && now - last_run_ms < STOCK_SPEED_INTERVAL_MS)
        return;
    last_run_ms = now;
    disp = lv_disp_get_default_p();
    screen = disp ? lv_disp_get_scr_act_p(disp) : NULL;
    if (!screen) { stock_speed_clear_map(); return; }
    memset(pairs, 0, sizeof(pairs));
    stock_speed_walk(screen, 0, pairs, &count, &visited);
    if (count != last_reported_count) {
        char stage[48];
        snprintf(stage, sizeof(stage), "stock-speed-pairs=%d", count);
        trace_ui_create(stage);
        last_reported_count = count;
    }
    locked = native_lock_screen_visible();
    if (locked == 1) {
        /* 锁屏 widget：可见速率对应恰好 2（↑/↓ 各一） */
        ok = count == 2;
    } else {
        /* 三卡页：≥6 对（3 卡 × ↑/↓，可能有第 4 有线卡）；
         * 首个 quad 的两对 = 5G 卡（顺序固定 5G 在上、对内先 ↑ 后 ↓） */
        ok = count >= 6;
    }
    if (!ok) { stock_speed_clear_map(); return; }
    stock_speed_num_up = pairs[0].num;
    stock_speed_unit_up = pairs[0].unit;
    stock_speed_num_down = pairs[1].num;
    stock_speed_unit_down = pairs[1].unit;
    stock_speed_map_is_lockscreen = locked == 1;
}

/* LVGL 文本写入拦截（备选2 方案）：stock 每次写速率 label 必经此函数，
 * 把 5G 卡四个 label 的写入文本替换为 netdev 干净值后转交真身——
 * 文本经由 stock 自己的写入+布局路径，宽度/折行由 stock 处理。 */
void lv_label_set_text(lv_obj_t *obj, const char *text)
{
    static label_set_text_fn real_set_text;
    char num[24];
    const char *unit, *substitute = NULL;
    unsigned long long rx, tx;
    if (!real_set_text)
        real_set_text = (label_set_text_fn)dlsym(RTLD_NEXT, "lv_label_set_text");
    if (obj && text && ui_network_status.valid &&
        (obj == stock_speed_num_up || obj == stock_speed_num_down ||
         obj == stock_speed_unit_up || obj == stock_speed_unit_down)) {
        stock_speed_rates(&rx, &tx);
        if (obj == stock_speed_num_up || obj == stock_speed_num_down) {
            format_stock_speed(obj == stock_speed_num_up ? tx : rx,
                               num, sizeof(num), &unit);
            substitute = num;
        } else {
            format_stock_speed(obj == stock_speed_unit_up ? tx : rx,
                               num, sizeof(num), &unit);
            substitute = unit;
        }
    }
    real_set_text(obj, substitute ? substitute : text);
}
