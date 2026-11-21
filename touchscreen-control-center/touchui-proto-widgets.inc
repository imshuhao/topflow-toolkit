/* 原型（OpenDesign 320×480 控制中心）通用控件。
 *
 * 所有页面统一用这些工厂函数搭界面，保证圆角 / 描边 / 配色与原型一致：
 *   make_card        —— 卡片（--card 底、1px --border、12px 圆角）
 *   make_dot         —— 状态圆点
 *   make_badge       —— 胶囊徽标（文字 + 浅底），set_badge 改文字/配色
 *   make_hbar        —— 水平进度条（轨道 + 填充），set_hbar 改百分比
 *   make_divider     —— 1px 分隔线
 *   make_caption     —— 次要小字（tiny 字体、--muted）
 *   make_value_right —— 右对齐动态值（holder + 右贴齐 label）
 *   make_stat_row    —— 「标签 … 值」一行（原型 .stat-row）
 *   make_toast       —— 底部轻提示，set_toast 为空时自动隐藏
 *   make_glyph_icon  —— ASCII 行阵位图图标（替代原型 SVG 线稿）
 *   make_scroll_area —— 可纵向滚动的内容容器（原型 .page-scroll）
 */

TOUCHUI_HELPER lv_obj_t *make_card(lv_obj_t *parent, int x, int y, int w, int h)
{
    lv_obj_t *card = make_panel(parent, x, y, w, h, COLOR_CARD);
    if (card) style_surface(card, COLOR_CARD, COLOR_BORDER, 12, 1);
    return card;
}

TOUCHUI_HELPER lv_obj_t *make_card_alt(lv_obj_t *parent, int x, int y, int w, int h)
{
    lv_obj_t *card = make_panel(parent, x, y, w, h, COLOR_CARD_ALT);
    if (card) style_surface(card, COLOR_CARD_ALT, COLOR_BORDER, 12, 1);
    return card;
}

TOUCHUI_HELPER lv_obj_t *make_dot(lv_obj_t *parent, int x, int y, int size, uint32_t color)
{
    lv_obj_t *dot = make_panel(parent, x, y, size, size, color);
    if (!dot) return NULL;
    style_surface(dot, color, color, size / 2 + 1, 0);
    return dot;
}

TOUCHUI_HELPER void set_dot_color(lv_obj_t *dot, uint32_t color)
{
    if (!dot) return;
    set_bg_color(dot, color, 0);
    set_border_color(dot, color, 0);
}

TOUCHUI_HELPER void set_badge(struct badge_component *badge, const char *text,
                      uint32_t fg, uint32_t bg)
{
    if (!badge || !badge->panel) return;
    style_surface(badge->panel, bg, bg, 9, 0);
    if (badge->label) {
        set_text_color(badge->label, fg);
        set_label_text_if_changed(badge->label, text ? text : "");
        if (lv_obj_update_layout_p) lv_obj_update_layout_p(badge->label);
        lv_obj_align_p(badge->label, LV_ALIGN_CENTER, 0, 0);
    }
}

TOUCHUI_HELPER struct badge_component make_badge(lv_obj_t *parent, int x, int y,
                                         int w, int h, const char *text,
                                         uint32_t fg, uint32_t bg,
                                         const void *font)
{
    struct badge_component badge = {0};
    badge.panel = make_panel(parent, x, y, w, h, bg);
    if (!badge.panel) return badge;
    style_surface(badge.panel, bg, bg, h / 2, 0);
    badge.label = make_single_line_label(badge.panel, text ? text : "", 0, 0, 0, 0);
    if (badge.label && font && real_obj_set_style_text_font)
        real_obj_set_style_text_font(badge.label, font, 0);
    set_badge(&badge, text, fg, bg);
    return badge;
}

TOUCHUI_HELPER void set_hbar(struct hbar_component *bar, int percent)
{
    int width;
    if (!bar || !bar->fill) return;
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;
    width = bar->width * percent / 100;
    if (width < 2 && percent > 0) width = 2;
    lv_obj_set_size_p(bar->fill, width, bar->height);
}

TOUCHUI_HELPER struct hbar_component make_hbar(lv_obj_t *parent, int x, int y,
                                       int w, int h, uint32_t color)
{
    struct hbar_component bar = {0};
    bar.width = w;
    bar.height = h;
    bar.track = make_panel(parent, x, y, w, h, touchui_theme.track);
    if (!bar.track) return bar;
    style_surface(bar.track, touchui_theme.track, touchui_theme.track, h / 2, 0);
    bar.fill = make_panel(bar.track, 0, 0, 2, h, color);
    if (bar.fill) style_surface(bar.fill, color, color, h / 2, 0);
    return bar;
}

TOUCHUI_HELPER void set_hbar_color(struct hbar_component *bar, uint32_t color)
{
    if (!bar || !bar->fill) return;
    set_bg_color(bar->fill, color, 0);
    set_border_color(bar->fill, color, 0);
}

TOUCHUI_HELPER lv_obj_t *make_divider(lv_obj_t *parent, int x, int y, int w)
{
    lv_obj_t *rule = lv_obj_create_p(parent);
    if (!rule) return NULL;
    lv_obj_set_size_p(rule, w, 1);
    lv_obj_set_pos_p(rule, x, y);
    lv_obj_clear_flag_p(rule, LV_OBJ_FLAG_SCROLLABLE);
    style_surface(rule, COLOR_BORDER, COLOR_BORDER, 0, 0);
    return rule;
}

TOUCHUI_HELPER lv_obj_t *make_caption(lv_obj_t *parent, const char *text,
                              int x, int y, int w, int h)
{
    lv_obj_t *label = make_single_line_label(parent, text, x, y, w, h);
    if (label && ui_font_tiny && real_obj_set_style_text_font)
        real_obj_set_style_text_font(label, ui_font_tiny, 0);
    set_text_color(label, COLOR_MUTED);
    return label;
}

TOUCHUI_HELPER lv_obj_t *make_text(lv_obj_t *parent, const char *text,
                           int x, int y, int w, int h,
                           const void *font, uint32_t color)
{
    lv_obj_t *label = make_single_line_label(parent, text, x, y, w, h);
    if (label && font && real_obj_set_style_text_font)
        real_obj_set_style_text_font(label, font, 0);
    set_text_color(label, color);
    return label;
}

/* 右对齐动态值：holder 固定宽度，label 自适应后贴右。 */
TOUCHUI_HELPER void set_right_value(lv_obj_t *label, const char *text)
{
    if (!label) return;
    set_label_text_if_changed(label, text ? text : "--");
    if (lv_obj_update_layout_p) lv_obj_update_layout_p(label);
    lv_obj_align_p(label, LV_ALIGN_RIGHT_MID, 0, 0);
}

TOUCHUI_HELPER lv_obj_t *make_value_right(lv_obj_t *parent, int x, int y, int w, int h,
                                  const void *font, uint32_t color)
{
    lv_obj_t *holder = make_transparent_container(parent, x, y, w, h);
    lv_obj_t *label;
    if (!holder) return NULL;
    label = make_single_line_label(holder, "--", 0, 0, 0, 0);
    if (label && font && real_obj_set_style_text_font)
        real_obj_set_style_text_font(label, font, 0);
    set_text_color(label, color);
    set_right_value(label, "--");
    return label;
}

/* 原型 .stat-row：左 muted 标签 + 右对齐值，行高 row_h（默认 32）。 */
TOUCHUI_HELPER lv_obj_t *make_stat_row(lv_obj_t *parent, int x, int y, int w, int row_h,
                               const char *label_text, const void *value_font)
{
    int text_h = font_line_height(ui_font_tiny) + 4;
    int ty = y + (row_h - text_h) / 2;
    make_caption(parent, label_text, x, ty, w / 2, text_h);
    return make_value_right(parent, x + w / 2, y, w / 2, row_h,
                            value_font ? value_font : ui_font_small, COLOR_TEXT);
}

/* 原型 .toast：底部居中胶囊；文字为空时隐藏。 */
TOUCHUI_HELPER struct badge_component make_toast(lv_obj_t *parent)
{
    struct badge_component toast = make_badge(parent, 20, TOUCHUI_PAGE_H - 44,
                                              280, 32, "", touchui_theme.toast_text,
                                              touchui_theme.toast_bg, ui_font_tiny);
    if (toast.panel) {
        style_surface(toast.panel, touchui_theme.toast_bg, COLOR_BORDER, 10, 1);
        lv_obj_add_flag_p(toast.panel, LV_OBJ_FLAG_HIDDEN);
    }
    return toast;
}

TOUCHUI_HELPER void set_toast(struct badge_component *toast, const char *text)
{
    if (!toast || !toast->panel) return;
    if (!text || !*text) {
        lv_obj_add_flag_p(toast->panel, LV_OBJ_FLAG_HIDDEN);
        return;
    }
    set_badge(toast, text, touchui_theme.toast_text, touchui_theme.toast_bg);
    style_surface(toast->panel, touchui_theme.toast_bg, COLOR_BORDER, 10, 1);
    lv_obj_clear_flag_p(toast->panel, LV_OBJ_FLAG_HIDDEN);
}

/* 可滚动内容区（原型 .page-scroll）：子控件按绝对坐标放，超出高度即可拖动。 */
TOUCHUI_HELPER lv_obj_t *make_scroll_area(lv_obj_t *parent, int x, int y, int w, int h)
{
    lv_obj_t *area = make_transparent_container(parent, x, y, w, h);
    if (!area) return NULL;
    lv_obj_add_flag_p(area, LV_OBJ_FLAG_SCROLLABLE);
    if (lv_obj_set_scrollbar_mode_p)
        lv_obj_set_scrollbar_mode_p(area, LV_SCROLLBAR_MODE_OFF);
    return area;
}

/* ---- 位图图标 ------------------------------------------------------------
 * rows[] 每行一个字符串，每字符一位 alpha：
 *   '0'-'9' / 'a'-'f' → 0,17,34,…,255（16 级，用于从 SVG 渲染出来的抗锯齿蒙版）
 *   '#' 实心（255）、'+' 半透明（128）、'.' 或其它 → 透明（旧图标的写法保留）
 * 宽度取第一行长度，高度取行数；最大 32×32。
 * 像素缓冲按图标分配，页面销毁时随 lv_img 一起作废；主题切换时整页重建。 */
TOUCHUI_HELPER unsigned char *glyph_render(const char *const *rows, int *w_out,
                                   int *h_out, uint32_t color)
{
    int w, h, x, y;
    unsigned char *pixels;
    lv_color_compat_t rgb565 = color_hex(color);
    if (!rows || !rows[0]) return NULL;
    w = (int)strlen(rows[0]);
    for (h = 0; rows[h]; h++) {}
    if (w <= 0 || h <= 0 || w > TOUCHUI_GLYPH_MAX_SIDE || h > TOUCHUI_GLYPH_MAX_SIDE)
        return NULL;
    pixels = calloc((size_t)w * (size_t)h, 3u);
    if (!pixels) return NULL;
    for (y = 0; y < h; y++) {
        const char *row = rows[y];
        for (x = 0; x < w && row[x]; x++) {
            size_t off = ((size_t)y * (size_t)w + (size_t)x) * 3u;
            unsigned char alpha;
            char c = row[x];
            if (c >= '0' && c <= '9') alpha = (unsigned char)((c - '0') * 17);
            else if (c >= 'a' && c <= 'f') alpha = (unsigned char)((c - 'a' + 10) * 17);
            else if (c == '#') alpha = 0xffu;
            else if (c == '+') alpha = 0x80u;
            else continue;
            if (!alpha) continue;
            pixels[off] = (unsigned char)(rgb565 & 0xffu);
            pixels[off + 1] = (unsigned char)(rgb565 >> 8);
            pixels[off + 2] = alpha;
        }
    }
    *w_out = w;
    *h_out = h;
    return pixels;
}

/* 图标描述符池：lv_img 只持有指针，描述符必须常驻。 */
#define TOUCHUI_GLYPH_POOL 48
static struct glyph_image glyph_pool[TOUCHUI_GLYPH_POOL];
static unsigned char *glyph_pool_pixels[TOUCHUI_GLYPH_POOL];
static int glyph_pool_used;

TOUCHUI_HELPER void glyph_pool_reset(void)
{
    int i;
    for (i = 0; i < glyph_pool_used; i++) {
        free(glyph_pool_pixels[i]);
        glyph_pool_pixels[i] = NULL;
    }
    memset(glyph_pool, 0, sizeof(glyph_pool));
    glyph_pool_used = 0;
}

TOUCHUI_HELPER lv_obj_t *make_glyph_icon(lv_obj_t *parent, int x, int y,
                                 const char *const *rows, uint32_t color)
{
    int w = 0, h = 0;
    unsigned char *pixels;
    struct glyph_image *dsc;
    lv_obj_t *image;
    if (!parent || !lv_img_create_p || !lv_img_set_src_p) return NULL;
    if (glyph_pool_used >= TOUCHUI_GLYPH_POOL) return NULL;
    pixels = glyph_render(rows, &w, &h, color);
    if (!pixels) return NULL;
    dsc = &glyph_pool[glyph_pool_used];
    glyph_pool_pixels[glyph_pool_used] = pixels;
    glyph_pool_used++;
    dsc->header = 5u | ((uint32_t)w << 10) | ((uint32_t)h << 21);
    dsc->data_size = (uint32_t)(w * h * 3);
    dsc->data = pixels;
    image = lv_img_create_p(parent);
    if (!image) return NULL;
    lv_img_set_src_p(image, dsc);
    lv_obj_set_pos_p(image, x, y);
    return image;
}
