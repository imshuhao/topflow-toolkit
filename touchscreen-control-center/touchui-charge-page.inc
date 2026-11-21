/* 「充电」页（原型 page-charge）：只读展示充电功率 / 电流 / 电压 / 电池温度。
 * 数据来自 ui_network_status.device（zwrt-datad /state 的 battery 段）：
 *   charger_uv / charger_ua —— 充电器电压、电流（µV / µA；未插电时 ua=0）
 *   battery_uv / battery_ua —— 电池电压、电流（放电为负）
 *   battery_percent / battery_temp / battery_charging / charger_connected
 * 功率 W = charger_uv × charger_ua / 1e12。
 *
 * 几何（page root 320×440，内容 x=8 宽 304）：
 *   charge-hero  y=52..172   44px 圆底闪电 + 功率大字「17.4 W」+ 「充电中 · 输入 8.96 V」
 *   电量条卡     y=180..232  10px 进度条 + 左「电量 82%」右「距满 18%」
 *   明细卡       y=240..420  六行 stat-row（输入电压 / 充电电流 / 充电功率 /
 *                            电池电压 / 电池电流 / 电池温度）
 *   底部 hint    y=426..440  「功率随电量与温度变化；数值为只读采样。」 */

/* ---- 本包四个文件共用的小工具 -------------------------------------------
 * touchui-hook.c 的 include 顺序是 charge-page → network → device（device 再
 * 引入 wifi / cooling），因此「设备 + 充电」工作包的公共 helper 放在最早被
 * include 的这个文件里，后面三个文件都能直接用。 */

/* 右贴齐动态值：文本未变时不动布局，避免每秒 update_layout。 */
TOUCHUI_HELPER void set_device_row_value(lv_obj_t *label, const char *text)
{
    const char *current;
    if (!label) return;
    current = lv_label_get_text_p ? lv_label_get_text_p(label) : NULL;
    if (current && text && !strcmp(current, text)) return;
    set_right_value(label, text);
}

/* 原型 btn-ghost：card 底 + border 边 + text 字；选中 = accent 浅底 + accent 边。 */
TOUCHUI_HELPER void style_ghost_button(lv_obj_t *button)
{
    if (!button) return;
    style_button(button, COLOR_CARD, COLOR_BUTTON_PRESSED,
                 COLOR_ACCENT_SOFT, COLOR_ACCENT);
    set_border_color(button, COLOR_BORDER, 0);
}

/* 原型 btn-primary：accent 实底 + accent-ink 字。
 * 按钮文字是子 label，LVGL 状态不会把字色传给子对象，这里显式刷一次。 */
TOUCHUI_HELPER void style_primary_button(lv_obj_t *button)
{
    lv_obj_t *label;
    if (!button) return;
    style_button(button, COLOR_ACCENT, COLOR_ACCENT_DARK,
                 COLOR_ACCENT, COLOR_ACCENT);
    set_border_color(button, COLOR_ACCENT, 0);
    label = lv_obj_get_child_cnt_p && lv_obj_get_child_p ?
            lv_obj_get_child_p(button, 0) : NULL;
    if (label) set_text_color(label, touchui_theme.accent_ink);
}

/* ---- 本页新增静态（destroy_charge_page 里全部归零） -------------------- */
static lv_obj_t *charge_hero;             /* hero 卡（居中计算的参照框） */
static lv_obj_t *charge_power_label;      /* 「17.4 W」大号功率（含单位，避免双 label 错位） */
static lv_obj_t *charge_state_dot;        /* 状态行圆点 */
static lv_obj_t *charge_state_label;      /* 「充电中 · 输入 8.96 V」/「未充电 · …」 */
static struct hbar_component charge_bar;  /* 电量进度条 */
static lv_obj_t *charge_percent_label;    /* 左「电量 82%」 */
static lv_obj_t *charge_remaining_label;  /* 右「距满 18%」 */
static lv_obj_t *charge_row_values[6];    /* 六行明细值 */
static int charge_bar_percent = -1;       /* 上次绘制的电量，避免每 tick 重设 hbar */

/* 闪电 glyph（24×24，原型 charge-glyph 的 ASCII 近似：上斜 + 横杠 + 下斜）。 */
static const char *const charge_bolt_rows[] = {
    "........................",
    "........................",
    "........................",
    "........................",
    "..........####..........",
    ".........####...........",
    "........####............",
    ".......####.............",
    "......####..............",
    ".....####...............",
    "....#############.......",
    "..........####..........",
    ".........####...........",
    "........####............",
    ".......####.............",
    "......####..............",
    ".....####...............",
    "........................",
    "........................",
    "........................",
    "........................",
    "........................",
    "........................",
    "........................",
    NULL
};

/* 闪电图标私有缓存。
 * 不用 make_glyph_icon()：它把像素塞进 48 槽的全局池，池只在主题重建时重置，
 * 而充电页每次进入都重建 —— 进出 48 次后图标就再也画不出来。这里自己持有一份
 * 描述符 + 像素，页面销毁时释放，与进出次数无关。
 * lv_img 只持有描述符指针，所以描述符必须是 static 常驻对象。 */
static struct glyph_image charge_bolt_image;
static unsigned char *charge_bolt_pixels;

static lv_obj_t *charge_make_bolt_icon(lv_obj_t *parent, int x, int y,
                                       uint32_t color)
{
    int w = 0, h = 0;
    lv_obj_t *image;
    if (!parent || !lv_img_create_p || !lv_img_set_src_p) return NULL;
    if (charge_bolt_pixels) {          /* 已渲染过（同主题同色）直接复用 */
        image = lv_img_create_p(parent);
    } else {
        charge_bolt_pixels = glyph_render(charge_bolt_rows, &w, &h, color);
        if (!charge_bolt_pixels) return NULL;
        charge_bolt_image.header = 5u | ((uint32_t)w << 10) | ((uint32_t)h << 21);
        charge_bolt_image.data_size = (uint32_t)(w * h * 3);
        charge_bolt_image.data = charge_bolt_pixels;
        image = lv_img_create_p(parent);
    }
    if (!image) return NULL;
    lv_img_set_src_p(image, &charge_bolt_image);
    lv_obj_set_pos_p(image, x, y);
    return image;
}

/* 充电是否生效：插着充电器或充电电流非零（真机未插电 chg_ua=0）。 */
static int charge_is_active(const struct device_status *device)
{
    return device->charger_connected || device->charger_ua > 0;
}

/* 功率 W = uv × ua / 1e12；未充电直接归零，避免用残留采样算出假功率。 */
static double charge_power_watts(const struct device_status *device)
{
    if (!charge_is_active(device)) return 0.0;
    return (double)device->charger_uv * (double)device->charger_ua / 1e12;
}

/* tiny 字宽粗估（勿用 lv_obj_get_coords：本机 lv_area_t 是 4×int16，
 * ABI 头却是 4×int32，量宽会算出飞出屏幕的 start——§41.12/§42.6）。
 * CJK 三字节按 12px，ASCII 按 7px，与 12px tiny 实测接近。 */
static int charge_estimate_tiny_width(const char *text)
{
    int w = 0;
    const unsigned char *p = (const unsigned char *)(text ? text : "");
    while (*p) {
        if (*p < 0x80) {
            w += 7;
            p++;
        } else if ((*p & 0xE0) == 0xC0) {
            w += 12;
            p += 2;
        } else if ((*p & 0xF0) == 0xE0) {
            w += 12;
            p += 3;
        } else if ((*p & 0xF8) == 0xF0) {
            w += 12;
            p += 4;
        } else {
            p++;
        }
    }
    return w;
}

/* 圆点 + 文案按估算宽度在 hero 卡内横向居中；只在文案变化后调用。 */
static void charge_align_centered(lv_obj_t *anchor, lv_obj_t *left_obj,
                                  int gap, int left_y, lv_obj_t *right_obj,
                                  int right_y, const char *text)
{
    int left_w = left_obj ? 6 : 0;
    int right_w = charge_estimate_tiny_width(text);
    int total = right_w + (left_obj ? left_w + gap : 0);
    int start;
    (void)anchor;
    if (!right_obj) return;
    start = (TOUCHUI_CONTENT_W - total) / 2;
    if (start < 8) start = 8;
    if (left_obj) lv_obj_set_pos_p(left_obj, start, left_y);
    lv_obj_set_pos_p(right_obj, start + (left_obj ? left_w + gap : 0), right_y);
}

/* 把瓦特数格式成「12.3 W」；用整数十分位，避开 vendor printf 浮点偶发乱码。 */
static void format_charge_watts(char *buf, size_t size, double watts)
{
    int x10;
    if (!buf || size < 4) return;
    if (watts < 0) watts = 0;
    if (watts > 999.9) watts = 999.9;
    x10 = (int)(watts * 10.0 + 0.5);
    snprintf(buf, size, "%d.%d W", x10 / 10, x10 % 10);
}

/* hero 功率行：单 label「17.4 W」水平居中（不再拆数字/单位，避免量宽错位成乱码）。 */
static void update_charge_power(const char *value)
{
    const char *current;
    if (!charge_power_label) return;
    current = lv_label_get_text_p ? lv_label_get_text_p(charge_power_label) : NULL;
    if (current && value && !strcmp(current, value)) return;
    lv_label_set_text_p(charge_power_label, value ? value : "--");
    if (lv_obj_update_layout_p) lv_obj_update_layout_p(charge_power_label);
    lv_obj_align_p(charge_power_label, LV_ALIGN_TOP_MID, 0, 48);
}

/* hero 状态行：圆点 + 文案整体居中；文案变化时才重排。
 * 圆点 y=97（相对 6px 圆点与 14px 文案的视觉中线），文案 y=94。 */
static void update_charge_state(const char *text)
{
    const char *current;
    if (!charge_state_label) return;
    current = lv_label_get_text_p ? lv_label_get_text_p(charge_state_label) : NULL;
    if (current && text && !strcmp(current, text)) return;
    lv_label_set_text_p(charge_state_label, text ? text : "");
    charge_align_centered(charge_hero, charge_state_dot, 6, 97,
                          charge_state_label, 94, text);
}

static int create_charge_page(lv_obj_t *top)
{
    lv_obj_t *bar_card, *list, *icon_bg;
    if (!page_shell_init(&charge_shell, top, PAGE_CHARGE, "充电",
                         feature_back_clicked)) return 0;
    charge_page = charge_shell.root;
    charge_bar_percent = -1;

    /* charge-hero：圆底闪电 + 功率大字 + 状态行 */
    charge_hero = make_card(charge_page, TOUCHUI_CONTENT_X, TOUCHUI_CONTENT_Y,
                            TOUCHUI_CONTENT_W, 120);
    if (charge_hero) {
        icon_bg = make_dot(charge_hero, 130, 2, 44, COLOR_ACCENT_SOFT);
        if (icon_bg)
            charge_make_bolt_icon(icon_bg, 10, 10, COLOR_ACCENT);
        charge_power_label = make_single_line_label(charge_hero, "0.0 W", 0, 0, 0, 0);
        if (charge_power_label && ui_font_xlarge && real_obj_set_style_text_font)
            real_obj_set_style_text_font(charge_power_label, ui_font_xlarge, 0);
        set_text_color(charge_power_label, COLOR_TEXT);
        charge_state_dot = make_dot(charge_hero, 72, 95, 6, COLOR_MUTED);
        charge_state_label = make_caption(charge_hero, "读取中…", 84, 94, 0, 0);
    }

    /* 电量条卡：10px 进度条 + 左右两行小字 */
    bar_card = make_card(charge_page, TOUCHUI_CONTENT_X, 180,
                         TOUCHUI_CONTENT_W, 52);
    if (bar_card) {
        charge_bar = make_hbar(bar_card, 12, 10, 280, 10, COLOR_ACCENT);
        charge_percent_label = make_caption(bar_card, "电量 --", 12, 28, 120, 16);
        charge_remaining_label = make_caption(bar_card, "距满 --", 184, 28, 108, 16);
        right_align_label_text(charge_remaining_label);
    }

    /* 明细卡：六行 stat-row */
    list = make_card(charge_page, TOUCHUI_CONTENT_X, 240, TOUCHUI_CONTENT_W, 180);
    if (list) {
        static const char *names[6] = {
            "输入电压", "充电电流", "充电功率",
            "电池电压", "电池电流", "电池温度"
        };
        for (int i = 0; i < 6; i++)
            charge_row_values[i] = make_stat_row(list, 12, 8 + i * 28, 280, 28,
                                                 names[i], ui_font_small);
    }

    make_caption(charge_page, "功率随电量与温度变化；数值为只读采样。",
                 12, 426, 296, 14);

    if (!charge_hero || !bar_card || !list || !charge_power_label ||
        !charge_state_dot || !charge_state_label ||
        !charge_bar.track || !charge_bar.fill || !charge_percent_label ||
        !charge_remaining_label) {
        trace_ui_create("charge-allocation-failed");
        destroy_charge_page();
        return 0;
    }
    for (int i = 0; i < 6; i++) {
        if (charge_row_values[i]) continue;
        trace_ui_create("charge-rows-failed");
        destroy_charge_page();
        return 0;
    }
    update_charge_power("0.0 W");
    update_charge_state("读取中…");
    return 1;
}

static void refresh_charge_ui(void)
{
    const struct device_status *device = &ui_network_status.device;
    char text[96];
    int ready, charging, percent;
    if (!charge_page) return;

    ready = ui_network_status.valid && device->valid;
    if (!ready) {
        update_charge_power("-- W");
        update_charge_state("读取中…");
        set_dot_color(charge_state_dot, COLOR_MUTED);
        set_label_text_if_changed(charge_percent_label, "电量 --");
        set_label_text_if_changed(charge_remaining_label, "距满 --");
        for (int i = 0; i < 6; i++)
            set_device_row_value(charge_row_values[i], "--");
        return;
    }

    charging = charge_is_active(device);
    percent = device->battery_percent;
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;

    /* hero：功率 + 状态行 */
    if (charging) {
        format_charge_watts(text, sizeof(text), charge_power_watts(device));
        update_charge_power(text);
        {
            int mv = (int)((device->charger_uv + 5000) / 10000); /* 0.01 V */
            snprintf(text, sizeof(text), "充电中 · 输入 %d.%02d V",
                     mv / 100, mv % 100);
        }
        update_charge_state(text);
        set_dot_color(charge_state_dot, COLOR_ACCENT);
    } else {
        update_charge_power("0.0 W");
        {
            long long ua = device->battery_ua;
            int ma;
            if (ua < 0) ua = -ua;
            ma = (int)((ua + 5000) / 10000); /* 0.01 A */
            snprintf(text, sizeof(text), "未充电 · 电池放电 %d.%02d A",
                     ma / 100, ma % 100);
        }
        update_charge_state(text);
        set_dot_color(charge_state_dot, COLOR_MUTED);
    }

    /* 电量条：只在百分比变化时重设填充与配色 */
    if (charge_bar.fill && charge_bar_percent != percent) {
        charge_bar_percent = percent;
        set_hbar(&charge_bar, percent);
        set_hbar_color(&charge_bar,
                       charging ? COLOR_ACCENT :
                       (percent <= 20 ? COLOR_RED : COLOR_GREEN));
    }
    snprintf(text, sizeof(text), "电量 %d%%", percent);
    set_label_text_if_changed(charge_percent_label, text);
    snprintf(text, sizeof(text), "距满 %d%%", 100 - percent);
    set_label_text_if_changed(charge_remaining_label, text);

    /* 明细六行：未插电时前导三项显示 --；电池电流带符号（放电为负） */
    if (charging) {
        int mv = (int)((device->charger_uv + 5000) / 10000);
        int ma = (int)((device->charger_ua + 5000) / 10000);
        snprintf(text, sizeof(text), "%d.%02d V", mv / 100, mv % 100);
        set_device_row_value(charge_row_values[0], text);
        snprintf(text, sizeof(text), "%d.%02d A", ma / 100, ma % 100);
        set_device_row_value(charge_row_values[1], text);
        format_charge_watts(text, sizeof(text), charge_power_watts(device));
        set_device_row_value(charge_row_values[2], text);
    } else {
        for (int i = 0; i < 3; i++)
            set_device_row_value(charge_row_values[i], "--");
    }
    {
        int mv = (int)((device->battery_uv + 5000) / 10000);
        snprintf(text, sizeof(text), "%d.%02d V", mv / 100, mv % 100);
    }
    set_device_row_value(charge_row_values[3], text);
    {
        long long ua = device->battery_ua;
        int ma, neg = 0;
        if (ua < 0) { neg = 1; ua = -ua; }
        ma = (int)((ua + 5000) / 10000);
        snprintf(text, sizeof(text), "%s%d.%02d A", neg ? "-" : "+", ma / 100, ma % 100);
    }
    set_device_row_value(charge_row_values[4], text);
    snprintf(text, sizeof(text), "%d °C", device->battery_temp);
    set_device_row_value(charge_row_values[5], text);
}

static void request_charge_page(void)
{
    pending_charge_open = 1;
}

static void destroy_charge_page(void)
{
    if (charge_page && lv_obj_del_p) lv_obj_del_p(charge_page);
    charge_page = NULL;
    memset(&charge_shell, 0, sizeof(charge_shell));
    /* 图标像素必须在 lv_img 删除之后释放；页面重建时按当前主题重渲染 */
    free(charge_bolt_pixels);
    charge_bolt_pixels = NULL;
    memset(&charge_bolt_image, 0, sizeof(charge_bolt_image));
    charge_hero = NULL;
    charge_power_label = NULL;
    charge_state_dot = NULL;
    charge_state_label = NULL;
    memset(&charge_bar, 0, sizeof(charge_bar));
    charge_percent_label = NULL;
    charge_remaining_label = NULL;
    memset(charge_row_values, 0, sizeof(charge_row_values));
    charge_bar_percent = -1;
}
