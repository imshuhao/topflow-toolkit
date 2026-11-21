static int font_line_height(const void *font)
{
    const uint16_t *line_height;
    if (!font) return 0;
    line_height = (const uint16_t *)((const unsigned char *)font + 16);
    return (int)*line_height;
}

static int center_marker_on_text_line(int text_y, const void *font,
                                      int marker_size)
{
    int line_height = font_line_height(font);
    if (line_height <= 0) line_height = marker_size;
    return text_y + (line_height - marker_size) / 2;
}

/* 标准 RGB565：R 高 5 / G 中 6 / B 低 5。
 * 2026-11-07 曾按「厂商 lv_color_t 字段 red 低」改成 BGR 打包，抓帧脚本
 * 也按 R-low 解码，两边自洽但和玻璃相反：蓝 #31B6FF 实机变黄橙 #FFB631，
 * 红变蓝紫。以双路解码对照玻璃为准，改回 (red<<11)。 */
static lv_color_compat_t color_hex(uint32_t hex)
{
    uint16_t red = (uint16_t)((hex >> 16) & 0xffu);
    uint16_t green = (uint16_t)((hex >> 8) & 0xffu);
    uint16_t blue = (uint16_t)(hex & 0xffu);
    return (lv_color_compat_t)(((red >> 3) << 11) |
                               ((green >> 2) << 5) |
                               (blue >> 3));
}

static void set_text_color(lv_obj_t *obj, uint32_t hex)
{
    if (obj && lv_obj_set_style_text_color_p)
        lv_obj_set_style_text_color_p(obj, color_hex(hex), 0);
}

static void set_bg_color(lv_obj_t *obj, uint32_t hex, uint32_t selector)
{
    if (obj && lv_obj_set_style_bg_color_p)
        lv_obj_set_style_bg_color_p(obj, color_hex(hex), selector);
    if (obj && lv_obj_set_style_bg_opa_p)
        lv_obj_set_style_bg_opa_p(obj, LV_OPA_COVER, selector);
}

static void set_border_color(lv_obj_t *obj, uint32_t hex, uint32_t selector)
{
    if (obj && lv_obj_set_style_border_color_p)
        lv_obj_set_style_border_color_p(obj, color_hex(hex), selector);
}

static void set_shadow_color(lv_obj_t *obj, uint32_t hex)
{
    if (obj && lv_obj_set_style_shadow_color_p)
        lv_obj_set_style_shadow_color_p(obj, color_hex(hex), 0);
}

static void style_surface(lv_obj_t *obj, uint32_t background, uint32_t border,
                          int radius, int border_width)
{
    if (!obj) return;
    set_bg_color(obj, background, 0);
    set_border_color(obj, border, 0);
    if (lv_obj_set_style_radius_p) lv_obj_set_style_radius_p(obj, radius, 0);
    if (lv_obj_set_style_border_width_p)
        lv_obj_set_style_border_width_p(obj, border_width, 0);
}

static void style_button(lv_obj_t *button, uint32_t normal, uint32_t pressed,
                         uint32_t checked, uint32_t checked_border)
{
    if (!button) return;
    style_surface(button, normal, COLOR_BORDER, 10, 1);
    set_bg_color(button, pressed, LV_STATE_PRESSED);
    set_border_color(button, COLOR_ACCENT_SOFT, LV_STATE_PRESSED);
    set_bg_color(button, checked, LV_STATE_CHECKED);
    set_border_color(button, checked_border, LV_STATE_CHECKED);
    set_bg_color(button, checked, LV_STATE_CHECKED | LV_STATE_PRESSED);
    set_border_color(button, checked_border, LV_STATE_CHECKED | LV_STATE_PRESSED);
}

static void style_segment_button(lv_obj_t *button)
{
    if (!button) return;
    style_button(button, COLOR_SEGMENT, COLOR_BUTTON_PRESSED,
                 COLOR_ACCENT, COLOR_ACCENT_SOFT);
    set_border_color(button, COLOR_SEGMENT, 0);
}

static lv_obj_t *make_panel(lv_obj_t *parent, int x, int y, int w, int h,
                            uint32_t background)
{
    lv_obj_t *panel = lv_obj_create_p(parent);
    if (!panel) return NULL;
    lv_obj_set_size_p(panel, w, h);
    lv_obj_set_pos_p(panel, x, y);
    lv_obj_clear_flag_p(panel, LV_OBJ_FLAG_SCROLLABLE);
    style_surface(panel, background, COLOR_BORDER, 12, 1);
    if (lv_obj_set_style_pad_left_p) lv_obj_set_style_pad_left_p(panel, 0, 0);
    if (lv_obj_set_style_pad_right_p) lv_obj_set_style_pad_right_p(panel, 0, 0);
    if (lv_obj_set_style_pad_top_p) lv_obj_set_style_pad_top_p(panel, 0, 0);
    if (lv_obj_set_style_pad_bottom_p) lv_obj_set_style_pad_bottom_p(panel, 0, 0);
    return panel;
}

static lv_obj_t *make_transparent_container(lv_obj_t *parent,
                                             int x, int y, int w, int h)
{
    lv_obj_t *container = lv_obj_create_p(parent);
    if (!container) return NULL;
    lv_obj_set_size_p(container, w, h);
    lv_obj_set_pos_p(container, x, y);
    lv_obj_clear_flag_p(container, LV_OBJ_FLAG_SCROLLABLE);
    if (lv_obj_set_style_bg_opa_p)
        lv_obj_set_style_bg_opa_p(container, LV_OPA_TRANSP, 0);
    if (lv_obj_set_style_border_width_p)
        lv_obj_set_style_border_width_p(container, 0, 0);
    if (lv_obj_set_style_pad_left_p) lv_obj_set_style_pad_left_p(container, 0, 0);
    if (lv_obj_set_style_pad_right_p) lv_obj_set_style_pad_right_p(container, 0, 0);
    if (lv_obj_set_style_pad_top_p) lv_obj_set_style_pad_top_p(container, 0, 0);
    if (lv_obj_set_style_pad_bottom_p) lv_obj_set_style_pad_bottom_p(container, 0, 0);
    return container;
}
