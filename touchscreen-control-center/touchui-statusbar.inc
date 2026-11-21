/* 控制中心顶部状态栏：时间 / 三卡信号 / 电量。
 *
 * 对齐原型 docs/design/touchui-prototype-2026-11-07/index.html 的 .statusbar：
 *   高 40、底边 1px --border、底色 --bg；左侧 HH:MM（原型 15px，设备取
 *   ui_font_small 16px）；中间三组「5G / 4G¹ / 4G² + 4 根竖条」整簇居中
 *   （组距 9；竖条 3px、间距 1px、高 4/7/10/13；亮条 accent、暗条 --track）；
 *   右侧电池壳 44×20 + 右侧 1px 间隙的 3×8 凸起，百分比画在壳内
 *   （原型 .battery-shell/.battery-fill/.battery-readout/.battery-tip）。
 *
 * 对象只在 create_statusbar（及主题重建）时创建，refresh_statusbar 每 tick
 * 只改变量与颜色；颜色/进度都有缓存，避免每帧重设样式。 */

#define STATUSBAR_CLOCK_X 8
#define STATUSBAR_CLOCK_W 48       /* ui_font_small 16px 的「HH:MM」实测约 35px，留足余量 */
#define STATUSBAR_LABEL_GAP 4      /* 原型 .sig { gap: 4px }：标签右缘 → 首条竖条 */
#define STATUSBAR_BARS_W 15        /* 4 条 ×3 + 3 个间距 ×1（原型 2.5/1.5 取整） */
#define STATUSBAR_GROUP_GAP 9      /* 原型 .sigs { gap: 9px }：组与组之间 */
#define STATUSBAR_BAR_W 3          /* 原型 2.5px 取整 */
#define STATUSBAR_BAR_PITCH 4      /* 条宽 3 + 间距 1（原型 1.5px 取整） */
#define STATUSBAR_BAR_BOTTOM 27    /* 竖条底边：最矮 4px → 23..27，最高 13px → 14..27 */
#define STATUSBAR_MID_Y 20         /* 状态栏竖向中线（时钟/标签/电池都按它居中） */
/* 三组信号整簇左缘：区间 56（时钟右缘）..262（电池左缘）。
 * 14px tiny 字体实测标签字宽 17 / 22 / 22 → 内容 136，居中后 (262-56-136)/2 = 35，
 * 即 56+35 = 91。固定几何，不调 lv_obj_get_coords（lv_area 位宽不一致）。 */
#define STATUSBAR_SIG_X 91

/* 电池（原型 .battery）：壳 44×20 @(262,10)、圆角 6、2px 描边；
 * tip 3×8 @(307,16)（壳内相对 y=6，竖向居中）；组右缘 310 = 320 - padding 10。
 * 壳内容区（LVGL 子对象坐标从 border+pad 内侧起算）40×16，读数/填充/闪电都在壳内。 */
#define STATUSBAR_BATTERY_X 262
#define STATUSBAR_BATTERY_Y 10
#define STATUSBAR_BATTERY_W 44
#define STATUSBAR_BATTERY_H 20
#define STATUSBAR_BATTERY_BORDER 2 /* 原型 1.5px 取整 */
#define STATUSBAR_BATTERY_RADIUS 6
#define STATUSBAR_BATTERY_TIP_X 307
#define STATUSBAR_BATTERY_TIP_Y (STATUSBAR_BATTERY_Y + 6) /* 壳内垂直居中：10+6 */
#define STATUSBAR_BATTERY_TIP_W 3  /* 原型 2.5px 取整 */
#define STATUSBAR_BATTERY_TIP_H 8
#define STATUSBAR_BATT_INNER_W 40  /* 44 - 2×2 */
#define STATUSBAR_BATT_INNER_H 16  /* 20 - 2×2 */
#define STATUSBAR_BATT_BOLT_X 1    /* 壳内左侧，闪电 5×9 在内容区 y=3 → 竖向居中 */
#define STATUSBAR_BATT_BOLT_Y 3
#define STATUSBAR_BATT_LABEL_DX_CHARGING 2 /* 充电时文字右移 2px：读数首列落在
                                            * 内容区 x=8；5px 闪电(1..5) 与数字
                                            * 之间留 2px 空隙(6..7)，「100%」到
                                            * x=38 收尾、右缘留 1px 不裁切 */

static lv_obj_t *statusbar_divider;
static lv_obj_t *statusbar_battery_shell;
static lv_obj_t *statusbar_battery_fill;
static lv_obj_t *statusbar_battery_bolt;    /* 充电闪电 5×9 位图 */
static lv_obj_t *statusbar_battery_tip;     /* 壳右侧 3×8 凸起 */
static int statusbar_battery_level = -1;    /* 上次填充的电量；<0 表示无数据 */
static int statusbar_battery_charging = -1; /* 上次充电状态；-1 表示无数据 */
static uint32_t statusbar_batt_fill_color = 0xFFFFFFFFu;
static uint32_t statusbar_batt_label_color = 0xFFFFFFFFu;
static int statusbar_batt_label_dx = -1000; /* 上次读数对齐偏移（充电时右移） */
static int statusbar_bars_applied[NETWORK_MODEM_COUNT]; /* -1 = 未知，见 restyle */

/* 充电闪电 5×9：原型 .battery-bolt 的 6×10 viewBox 由无头 Edge 直接光栅化到
 * 5×9（fill 白 → 存 alpha），路径加 0.65 单位同色描边补一格厚度，否则 5px 宽
 * 只剩一格折线、糊成一撮斜点。
 * 尺寸选型（都有实拍 / 逐像素对照）：
 *   4×7   与原型同尺寸，但实机 8× 下像一小撮折线，笔画只剩 1px；
 *   5×8   比 5×9 少一行，底部尖角被压平，斜收尾更弱；
 *   5×9   本版：多一行给斜尾，1..5 列 + 2px 空隙，读数仍留 1px 右缘；
 *   6×10  剪影最清楚，但只剩 1px 空隙，实拍里闪电右缘和数字「1」连成一体。 */
static const char *const statusbar_batt_bolt_rows[] = {
    "009d2",
    "04ec2",
    "0cfb0",
    "7ff95",
    "dfffd",
    "3afd2",
    "0be50",
    "1c800",
    "29000",
    NULL
};

/* 电池：percent < 0 表示无数据（隐藏填充/闪电）；填充宽度只在这里改，
 * 颜色/宽度/闪电/文字偏移都走缓存，避免每帧重设样式。 */
static void statusbar_apply_battery(int percent, int charging)
{
    int width, dx;
    uint32_t fill_color, label_color;
    if (!statusbar_battery_shell) return;

    if (percent > 100) percent = 100;
    /* 读数颜色按 fill 覆盖率切换（对原型的安全偏离）：壳内读数默认取
     * accent_ink 才压得住整条 accent 填充；但 fill 不足半宽时读数大部分落在
     * --bg 上，深底深字/浅底浅字几乎不可读，改用 COLOR_TEXT。充电不特殊处理，
     * 只看 percent。percent < 0（无数据）同样落到 COLOR_TEXT。 */
    label_color = percent >= 50 ? touchui_theme.accent_ink : COLOR_TEXT;
    if (statusbar_battery_label && statusbar_batt_label_color != label_color) {
        statusbar_batt_label_color = label_color;
        set_text_color(statusbar_battery_label, label_color);
    }

    if (percent < 0) {
        if (statusbar_battery_fill) {
            lv_obj_add_flag_p(statusbar_battery_fill, LV_OBJ_FLAG_HIDDEN);
            lv_obj_set_size_p(statusbar_battery_fill, 0, STATUSBAR_BATT_INNER_H);
        }
        if (statusbar_battery_bolt)
            lv_obj_add_flag_p(statusbar_battery_bolt, LV_OBJ_FLAG_HIDDEN);
        if (statusbar_battery_label && statusbar_batt_label_dx != 0 && lv_obj_align_p) {
            statusbar_batt_label_dx = 0;
            lv_obj_align_p(statusbar_battery_label, LV_ALIGN_CENTER, 0, 0);
        }
        statusbar_battery_level = -1;
        statusbar_battery_charging = -1;
        return;
    }

    width = STATUSBAR_BATT_INNER_W * percent / 100;
    if (width < 0) width = 0;
    if (width > STATUSBAR_BATT_INNER_W) width = STATUSBAR_BATT_INNER_W;
    if (statusbar_battery_fill) {
        if (width > 0) {
            lv_obj_clear_flag_p(statusbar_battery_fill, LV_OBJ_FLAG_HIDDEN);
            lv_obj_set_size_p(statusbar_battery_fill, width, STATUSBAR_BATT_INNER_H);
        } else {
            lv_obj_add_flag_p(statusbar_battery_fill, LV_OBJ_FLAG_HIDDEN);
            lv_obj_set_size_p(statusbar_battery_fill, 0, STATUSBAR_BATT_INNER_H);
        }
        /* 常规 accent；≤20% 保留红色安全口径；充电也走 accent */
        fill_color = (percent <= 20 && !charging) ? COLOR_RED : COLOR_ACCENT;
        if (fill_color != statusbar_batt_fill_color) {
            statusbar_batt_fill_color = fill_color;
            set_bg_color(statusbar_battery_fill, fill_color, 0);
        }
    }
    if (statusbar_battery_bolt) {
        if (charging)
            lv_obj_clear_flag_p(statusbar_battery_bolt, LV_OBJ_FLAG_HIDDEN);
        else
            lv_obj_add_flag_p(statusbar_battery_bolt, LV_OBJ_FLAG_HIDDEN);
    }
    dx = charging ? STATUSBAR_BATT_LABEL_DX_CHARGING : 0;
    if (statusbar_battery_label && statusbar_batt_label_dx != dx && lv_obj_align_p) {
        statusbar_batt_label_dx = dx;
        lv_obj_align_p(statusbar_battery_label, LV_ALIGN_CENTER, dx, 0);
    }
    statusbar_battery_level = percent;
    statusbar_battery_charging = charging ? 1 : 0;
}

static void statusbar_set_bars(int modem, int bars)
{
    int i;
    if (modem < 0 || modem >= NETWORK_MODEM_COUNT) return;
    if (bars < 0) bars = 0;
    if (bars > 4) bars = 4;
    for (i = 0; i < 4; i++) {
        lv_obj_t *bar = statusbar_sig_bar[modem][i];
        if (!bar) continue;
        set_bg_color(bar, i < bars ? COLOR_ACCENT : touchui_theme.track, 0);
        if (lv_obj_set_style_border_width_p)
            lv_obj_set_style_border_width_p(bar, 0, 0);
    }
}

static void restyle_statusbar(void)
{
    int m, i;
    if (!statusbar_root) return;
    style_surface(statusbar_root, COLOR_BG, COLOR_BORDER, 0, 0);
    if (lv_obj_set_style_border_width_p)
        lv_obj_set_style_border_width_p(statusbar_root, 0, 0);
    if (statusbar_divider)
        style_surface(statusbar_divider, COLOR_BORDER, COLOR_BORDER, 0, 0);
    set_text_color(statusbar_clock, COLOR_TEXT);
    for (m = 0; m < NETWORK_MODEM_COUNT; m++) {
        set_text_color(statusbar_sig_label[m], COLOR_MUTED);
        for (i = 0; i < 4; i++) {
            if (statusbar_sig_bar[m][i]) {
                set_bg_color(statusbar_sig_bar[m][i], touchui_theme.track, 0);
                if (lv_obj_set_style_border_width_p)
                    lv_obj_set_style_border_width_p(statusbar_sig_bar[m][i], 0, 0);
            }
        }
        statusbar_bars_applied[m] = -1;
    }
    /* 外壳描边/tip 随主题取 COLOR_TEXT；填充色/文字色缓存复位后由 refresh 重画 */
    if (statusbar_battery_shell)
        style_surface(statusbar_battery_shell, COLOR_BG, COLOR_TEXT,
                      STATUSBAR_BATTERY_RADIUS, STATUSBAR_BATTERY_BORDER);
    if (statusbar_battery_tip) {
        set_bg_color(statusbar_battery_tip, COLOR_TEXT, 0);
        if (lv_obj_set_style_border_width_p)
            lv_obj_set_style_border_width_p(statusbar_battery_tip, 0, 0);
        if (lv_obj_set_style_radius_p)
            lv_obj_set_style_radius_p(statusbar_battery_tip, 1, 0);
    }
    statusbar_battery_level = -1;
    statusbar_battery_charging = -1;
    statusbar_batt_fill_color = 0xFFFFFFFFu;
    statusbar_batt_label_color = 0xFFFFFFFFu;
    statusbar_batt_label_dx = -1000;
    statusbar_apply_battery(-1, 0);
}

static int create_statusbar(lv_obj_t *top)
{
    static const char *sig_names[NETWORK_MODEM_COUNT] = {"5G", "4G¹", "4G²"};
    /* 14px tiny 字体实测字宽（固定几何，不量 lv_obj_get_coords）：5G=17、4G¹=22、4G²=22 */
    static const int sig_w[NETWORK_MODEM_COUNT] = {17, 22, 22};
    int m, i, clock_h, clock_y, label_h, label_y, cursor;

    if (!top) return 0;
    statusbar_root = make_panel(top, 0, 0, 320, TOUCHUI_SB_H, COLOR_BG);
    if (!statusbar_root) return 0;
    if (lv_obj_set_style_radius_p)
        lv_obj_set_style_radius_p(statusbar_root, 0, 0);

    /* 底边 1px 分隔线（原型 border-bottom），不用四边描边 */
    statusbar_divider = make_divider(statusbar_root, 0, TOUCHUI_SB_H - 1, 320);

    clock_h = font_line_height(ui_font_small);
    if (clock_h <= 0) clock_h = 22;
    clock_y = STATUSBAR_MID_Y - clock_h / 2;
    if (clock_y < 2) clock_y = 2;
    statusbar_clock = make_single_line_label(statusbar_root, "--:--",
                                             STATUSBAR_CLOCK_X, clock_y,
                                             STATUSBAR_CLOCK_W, clock_h);
    if (statusbar_clock && ui_font_small && real_obj_set_style_text_font)
        real_obj_set_style_text_font(statusbar_clock, ui_font_small, 0);
    set_text_color(statusbar_clock, COLOR_TEXT);

    label_h = font_line_height(ui_font_tiny);
    if (label_h <= 0) label_h = 18;
    label_y = STATUSBAR_MID_Y - label_h / 2;
    if (label_y < 2) label_y = 2;

    /* 三组信号：照原型 .sigs/.sig 的 flex 规则排「label →4→ 4 条竖条(15) →9→
     * 下一组」，整簇在时钟右缘(56)..电池左缘(262)之间居中 */
    cursor = STATUSBAR_SIG_X;
    for (m = 0; m < NETWORK_MODEM_COUNT; m++) {
        int bars_x = cursor + sig_w[m] + STATUSBAR_LABEL_GAP;
        statusbar_sig_label[m] = make_label(statusbar_root, sig_names[m], cursor, label_y, 0, 0);
        if (statusbar_sig_label[m] && ui_font_tiny && real_obj_set_style_text_font)
            real_obj_set_style_text_font(statusbar_sig_label[m], ui_font_tiny, 0);
        set_text_color(statusbar_sig_label[m], COLOR_MUTED);
        for (i = 0; i < 4; i++) {
            int h = 4 + i * 3;
            statusbar_sig_bar[m][i] = make_panel(statusbar_root,
                                                 bars_x + i * STATUSBAR_BAR_PITCH,
                                                 STATUSBAR_BAR_BOTTOM - h, STATUSBAR_BAR_W, h,
                                                 touchui_theme.track);
            if (statusbar_sig_bar[m][i] && lv_obj_set_style_radius_p)
                lv_obj_set_style_radius_p(statusbar_sig_bar[m][i], 1, 0);
            if (statusbar_sig_bar[m][i] && lv_obj_set_style_border_width_p)
                lv_obj_set_style_border_width_p(statusbar_sig_bar[m][i], 0, 0);
        }
        cursor = bars_x + STATUSBAR_BARS_W + STATUSBAR_GROUP_GAP;
    }

    /* 电池壳 44×20 @262,10：2px 描边 + 圆角 6 + 0 padding；子对象默认被壳裁剪 */
    statusbar_battery_shell = make_panel(statusbar_root,
                                         STATUSBAR_BATTERY_X, STATUSBAR_BATTERY_Y,
                                         STATUSBAR_BATTERY_W, STATUSBAR_BATTERY_H, COLOR_BG);
    if (statusbar_battery_shell) {
        style_surface(statusbar_battery_shell, COLOR_BG, COLOR_TEXT,
                      STATUSBAR_BATTERY_RADIUS, STATUSBAR_BATTERY_BORDER);
        /* 填充：子坐标从内容区（边框内沿）起算，0,0 即贴着 2px 边框内侧；
         * 100% 时 40 正好填满内宽，绝不越过壳 */
        statusbar_battery_fill = make_panel(statusbar_battery_shell, 0, 0, 0,
                                            STATUSBAR_BATT_INNER_H, COLOR_ACCENT);
        if (statusbar_battery_fill) {
            if (lv_obj_set_style_radius_p)
                lv_obj_set_style_radius_p(statusbar_battery_fill, 4, 0);
            if (lv_obj_set_style_border_width_p)
                lv_obj_set_style_border_width_p(statusbar_battery_fill, 0, 0);
            set_bg_color(statusbar_battery_fill, COLOR_ACCENT, 0);
            lv_obj_add_flag_p(statusbar_battery_fill, LV_OBJ_FLAG_HIDDEN);
        }
        statusbar_battery_bolt = make_glyph_icon(statusbar_battery_shell,
                                                 STATUSBAR_BATT_BOLT_X, STATUSBAR_BATT_BOLT_Y,
                                                 statusbar_batt_bolt_rows,
                                                 touchui_theme.accent_ink);
        if (statusbar_battery_bolt)
            lv_obj_add_flag_p(statusbar_battery_bolt, LV_OBJ_FLAG_HIDDEN);
        /* 读数：壳内 label（auto 宽），对象整体对齐壳内容区中心；充电时右移让出闪电。
         * 厂商 FreeType label 不认 text-align，所以用 align 而不是定宽居中。 */
        statusbar_battery_label = make_label(statusbar_battery_shell, "--%", 0, 0, 0, 0);
        if (statusbar_battery_label && ui_font_tiny && real_obj_set_style_text_font)
            real_obj_set_style_text_font(statusbar_battery_label, ui_font_tiny, 0);
        /* 颜色由 statusbar_apply_battery 按 fill 覆盖率决定（缓存见 batt_label_color） */
        if (statusbar_battery_label && lv_obj_update_layout_p)
            lv_obj_update_layout_p(statusbar_battery_label);
        if (statusbar_battery_label && lv_obj_align_p)
            lv_obj_align_p(statusbar_battery_label, LV_ALIGN_CENTER, 0, 0);
    }
    /* tip：壳右缘 306 留 1px 间隙，307..309；右缘 310 对齐右侧 padding 10 */
    statusbar_battery_tip = make_panel(statusbar_root,
                                       STATUSBAR_BATTERY_TIP_X, STATUSBAR_BATTERY_TIP_Y,
                                       STATUSBAR_BATTERY_TIP_W, STATUSBAR_BATTERY_TIP_H,
                                       COLOR_TEXT);
    if (statusbar_battery_tip) {
        if (lv_obj_set_style_radius_p)
            lv_obj_set_style_radius_p(statusbar_battery_tip, 1, 0);
        if (lv_obj_set_style_border_width_p)
            lv_obj_set_style_border_width_p(statusbar_battery_tip, 0, 0);
    }

    /* 子控件都建好后再统一过一次配色（restyle 也会把进度/电量缓存复位） */
    restyle_statusbar();

    lv_obj_add_flag_p(statusbar_root, LV_OBJ_FLAG_HIDDEN);
    return 1;
}

/* 主题重建会先 destroy 再 create，所以这里必须把所有静态指针清零。 */
static void destroy_statusbar(void)
{
    if (statusbar_root && lv_obj_del_p) lv_obj_del_p(statusbar_root);
    statusbar_root = NULL;
    statusbar_clock = NULL;
    statusbar_battery_label = NULL;
    statusbar_divider = NULL;
    statusbar_battery_shell = NULL;
    statusbar_battery_fill = NULL;
    statusbar_battery_bolt = NULL;
    statusbar_battery_tip = NULL;
    statusbar_battery_level = -1;
    statusbar_battery_charging = -1;
    statusbar_batt_fill_color = 0xFFFFFFFFu;
    statusbar_batt_label_color = 0xFFFFFFFFu;
    statusbar_batt_label_dx = -1000;
    memset(statusbar_sig_label, 0, sizeof(statusbar_sig_label));
    memset(statusbar_sig_bar, 0, sizeof(statusbar_sig_bar));
    statusbar_bars_applied[0] = -1;
    statusbar_bars_applied[1] = -1;
    statusbar_bars_applied[2] = -1;
}

static void statusbar_set_visible(int visible)
{
    if (!statusbar_root) return;
    if (visible) {
        lv_obj_clear_flag_p(statusbar_root, LV_OBJ_FLAG_HIDDEN);
        /* 全屏子页后创建，会盖住状态栏；每次显示时提到 layer_top 最前 */
        if (lv_obj_move_foreground_p)
            lv_obj_move_foreground_p(statusbar_root);
    } else {
        lv_obj_add_flag_p(statusbar_root, LV_OBJ_FLAG_HIDDEN);
    }
}

static void refresh_statusbar(void)
{
    time_t now = time(NULL);
    struct tm tm_value;
    char clock[8];
    char battery[16];
    int m, percent = -1, charging = 0, valid = 0;

    if (!statusbar_root) return;
    localtime_r(&now, &tm_value);
    strftime(clock, sizeof(clock), "%H:%M", &tm_value);
    set_label_text_if_changed(statusbar_clock, clock);

    if (ui_network_status.valid && ui_network_status.device.valid) {
        const struct device_status *device = &ui_network_status.device;
        valid = 1;
        percent = device->battery_percent;
        if (percent < 0) percent = 0;
        if (percent > 100) percent = 100;
        /* 充电判断：插着充电器或充电电流为正（真机未插电时 charger_ua = 0） */
        charging = device->charger_connected || device->charger_ua > 0;
        snprintf(battery, sizeof(battery), "%d%%", percent);
    } else {
        snprintf(battery, sizeof(battery), "--%%");
    }
    set_label_text_if_changed(statusbar_battery_label, battery);

    if (!valid) {
        if (statusbar_battery_level != -1 || statusbar_battery_charging != -1)
            statusbar_apply_battery(-1, 0);
    } else if (statusbar_battery_level != percent ||
               statusbar_battery_charging != (charging ? 1 : 0)) {
        statusbar_apply_battery(percent, charging);
    }

    for (m = 0; m < NETWORK_MODEM_COUNT; m++) {
        const struct modem_status *modem = &ui_network_status.modems[m];
        int bars = 0;
        if (ui_network_status.valid && modem->valid && modem->online)
            bars = modem->bars;
        /* bars 字段原厂 0–5；状态栏只画 4 格（5→4） */
        if (bars > 4) bars = 4;
        if (bars < 0) bars = 0;
        if (statusbar_bars_applied[m] == bars) continue;
        statusbar_bars_applied[m] = bars;
        statusbar_set_bars(m, bars);
    }
}
