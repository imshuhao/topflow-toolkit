static lv_obj_t *make_label(lv_obj_t *parent, const char *text, int x, int y, int w, int h)
{
    lv_obj_t *label = lv_label_create_p(parent);
    if (!label) return NULL;
    if (real_obj_set_style_text_font && ui_font)
        real_obj_set_style_text_font(label, ui_font, 0);
    set_text_color(label, COLOR_TEXT);
    lv_label_set_text_p(label, text); lv_obj_set_pos_p(label, x, y);
    if (w > 0 && h > 0) {
        lv_obj_set_size_p(label, w, h);
        if (lv_label_set_long_mode_p) lv_label_set_long_mode_p(label, LV_LABEL_LONG_WRAP);
    }
    return label;
}

static lv_obj_t *make_single_line_label(lv_obj_t *parent, const char *text,
                                        int x, int y, int w, int h)
{
    lv_obj_t *label = make_label(parent, text, x, y, w, h);
    if (label && lv_label_set_long_mode_p)
        lv_label_set_long_mode_p(label, LV_LABEL_LONG_CLIP);
    return label;
}

static void set_label_text_if_changed(lv_obj_t *label, const char *text)
{
    const char *current;
    if (!label || !lv_label_set_text_p) return;
    if (!text) text = "";
    current = lv_label_get_text_p ? lv_label_get_text_p(label) : NULL;
    if (current && !strcmp(current, text)) return;
    lv_label_set_text_p(label, text);
}

static void center_button_label(lv_obj_t *label)
{
    if (!label) return; /* 分配失败时 label 为 NULL，防解引用崩触屏（H4） */
    if (lv_obj_update_layout_p)
        lv_obj_update_layout_p(label);
    lv_obj_align_p(label, LV_ALIGN_CENTER, 0, 0);
}

static void right_align_label_text(lv_obj_t *label)
{
    if (label && lv_obj_set_style_text_align_p)
        lv_obj_set_style_text_align_p(label, LV_TEXT_ALIGN_RIGHT, 0);
}

/* Vendor FreeType labels do not reliably honor text-align inside a fixed-size
 * label.  Keep the label auto-sized and center the object in a fixed holder. */
static void set_centered_dynamic_value(lv_obj_t *label, const char *text)
{
    if (!label) return;
    lv_label_set_text_p(label, text);
    if (lv_obj_update_layout_p) lv_obj_update_layout_p(label);
    lv_obj_align_p(label, LV_ALIGN_CENTER, 0, 0);
}

static lv_obj_t *make_centered_dynamic_value(lv_obj_t *parent,
                                              int x, int y, int w, int h,
                                              const void *font, uint32_t color)
{
    lv_obj_t *holder = make_transparent_container(parent, x, y, w, h);
    lv_obj_t *label;
    if (!holder) return NULL;
    label = make_single_line_label(holder, "--", 0, 0, 0, 0);
    if (label && real_obj_set_style_text_font && font)
        real_obj_set_style_text_font(label, font, 0);
    set_text_color(label, color);
    set_centered_dynamic_value(label, "--");
    return label;
}

static lv_obj_t *make_button(lv_obj_t *parent, const char *text, int x, int y, int w, int h,
                             void (*callback)(void *event), lv_obj_t **label_out)
{
    lv_obj_t *button = lv_btn_create_p(parent), *label;
    if (!button) return NULL;
    lv_obj_set_size_p(button, w, h); lv_obj_set_pos_p(button, x, y);
    style_button(button, COLOR_BUTTON, COLOR_BUTTON_PRESSED,
                 COLOR_ACCENT_DARK, COLOR_ACCENT_SOFT);
    if (lv_obj_set_style_pad_left_p) lv_obj_set_style_pad_left_p(button, 0, 0);
    if (lv_obj_set_style_pad_right_p) lv_obj_set_style_pad_right_p(button, 0, 0);
    if (lv_obj_set_style_pad_top_p) lv_obj_set_style_pad_top_p(button, 0, 0);
    if (lv_obj_set_style_pad_bottom_p) lv_obj_set_style_pad_bottom_p(button, 0, 0);
    label = lv_label_create_p(button);
    if (!label) {
        /* label 失败时删掉 button，避免半初始化按钮与泄漏 */
        if (lv_obj_del_p) lv_obj_del_p(button);
        return NULL;
    }
    if (real_obj_set_style_text_font && ui_font)
        real_obj_set_style_text_font(label, ui_font, 0);
    set_text_color(label, COLOR_TEXT);
    lv_label_set_text_p(label, text); center_button_label(label);
    lv_obj_add_event_cb_p(button, callback, LV_EVENT_CLICKED, NULL);
    if (label_out) *label_out = label;
    return button;
}
