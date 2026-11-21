static const int network_display_order[NETWORK_MODEM_COUNT] = {0, 2, 1};
static const char *network_slot_titles[NETWORK_MODEM_COUNT] = {"5G", "4G1", "4G2"};
static const char *network_module_titles[NETWORK_MODEM_COUNT] = {
    "X75(5G)", "V3E2(4G1)", "V3E1(4G2)"
};
static const char *network_module_ids[NETWORK_MODEM_COUNT] = {"X75", "V3E2", "V3E1"};

/* Clamp display index before indexing network_display_order[]. */
static int network_backend_index(int display_index)
{
    if (display_index < 0 || display_index >= NETWORK_MODEM_COUNT)
        display_index = 0;
    return network_display_order[display_index];
}

static const char *display_operator_name(const char *name)
{
    if (contains_text_ci(name, "unicom")) return "中国联通";
    if (contains_text_ci(name, "mobile") || contains_text_ci(name, "cmcc")) return "中国移动";
    if (contains_text_ci(name, "telecom") || contains_text_ci(name, "chn-ct")) return "中国电信";
    if (contains_text_ci(name, "broadnet") || contains_text_ci(name, "cbn")) return "中国广电";
    return name && *name ? name : "未知运营商";
}

static int operator_name_should_scroll(const char *name)
{
    return strcmp(name, "中国联通") && strcmp(name, "中国移动") &&
           strcmp(name, "中国电信") && strcmp(name, "中国广电") &&
           strcmp(name, "未知运营商") && strcmp(name, "读取中…");
}

static void set_operator_label_text(lv_obj_t *label, const char *text)
{
    const char *current;
    if (!label || !lv_label_set_text_p) return;
    if (!text) text = "未知运营商";
    current = lv_label_get_text_p ? lv_label_get_text_p(label) : NULL;
    if (current && !strcmp(current, text)) return;
    if (lv_label_set_long_mode_p)
        lv_label_set_long_mode_p(label, operator_name_should_scroll(text) ?
                                LV_LABEL_LONG_SCROLL_CIRCULAR :
                                LV_LABEL_LONG_CLIP);
    lv_label_set_text_p(label, text);
}

static void short_band_name(const char *band, char *out, size_t size)
{
    const char *number;
    if (!band || !*band) { safe_copy(out, size, "--"); return; }
    number = strstr(band, "BAND ");
    if (number) snprintf(out, size, "B%s", number + 5);
    else safe_copy(out, size, band);
}

static void format_metric_int(int value, char *out, size_t size)
{
    if (value) snprintf(out, size, "%d", value);
    else safe_copy(out, size, "--");
}

static void format_metric_double(double value, char *out, size_t size)
{
    if (value == 0.0) safe_copy(out, size, "--");
    else if (value == (double)(long)value) snprintf(out, size, "%.0f", value);
    else snprintf(out, size, "%.1f", value);
}

static void format_scaled_bytes(unsigned long long bytes, int rate,
                                char *out, size_t size)
{
    static const char units[] = {'B', 'K', 'M', 'G', 'T', 'P', 'E'};
    double value = (double)bytes;
    size_t unit = 0;
    while (value >= 1024.0 && unit + 1 < sizeof(units)) {
        value /= 1024.0;
        unit++;
    }
    if (unit == 0) snprintf(out, size, "%lluB%s", bytes, rate ? "/s" : "");
    else if (value < 10.0)
        snprintf(out, size, "%.1f%c%s", value, units[unit], rate ? "/s" : "");
    else snprintf(out, size, "%.0f%c%s", value, units[unit], rate ? "/s" : "");
}

static void format_rate_compact(unsigned long long bytes, char *out, size_t size)
{
    format_scaled_bytes(bytes, 1, out, size);
}

static void format_bytes_compact(unsigned long long bytes, char *out, size_t size)
{
    format_scaled_bytes(bytes, 0, out, size);
}

static void format_duration_compact(unsigned long long seconds,
                                    char *out, size_t size)
{
    unsigned long long hours = seconds / 3600;
    unsigned long long minutes = (seconds % 3600) / 60;
    if (hours) snprintf(out, size, "%llu时%02llu分", hours, minutes);
    else snprintf(out, size, "%llu分", minutes);
}

static void set_network_dot(lv_obj_t *dot, uint32_t color)
{
    if (!dot) return;
    set_bg_color(dot, color, 0);
    set_border_color(dot, color, 0);
}

static void set_network_dot_color(int index, uint32_t color)
{
    if (index < 0 || index >= NETWORK_MODEM_COUNT) return;
    set_network_dot(network_dot[index], color);
}

static lv_obj_t *make_click_layer(lv_obj_t *parent, int x, int y, int w, int h,
                                  void (*callback)(void *event))
{
    lv_obj_t *button = lv_btn_create_p(parent);
    if (!button) return NULL;
    lv_obj_set_size_p(button, w, h);
    lv_obj_set_pos_p(button, x, y);
    lv_obj_clear_flag_p(button, LV_OBJ_FLAG_SCROLLABLE);
    if (lv_obj_set_style_radius_p) lv_obj_set_style_radius_p(button, 12, 0);
    if (lv_obj_set_style_border_width_p) lv_obj_set_style_border_width_p(button, 0, 0);
    if (lv_obj_set_style_shadow_width_p) lv_obj_set_style_shadow_width_p(button, 0, 0);
    if (lv_obj_set_style_bg_opa_p) {
        lv_obj_set_style_bg_opa_p(button, LV_OPA_TRANSP, 0);
        lv_obj_set_style_bg_opa_p(button, 36, LV_STATE_PRESSED);
    }
    if (lv_obj_set_style_bg_color_p)
        lv_obj_set_style_bg_color_p(button, color_hex(COLOR_TEXT), LV_STATE_PRESSED);
    lv_obj_add_event_cb_p(button, callback, LV_EVENT_CLICKED, NULL);
    return button;
}

static lv_obj_t *make_network_rule(lv_obj_t *parent, int x, int y, int w, int h)
{
    lv_obj_t *rule = lv_obj_create_p(parent);
    if (!rule) return NULL;
    lv_obj_set_size_p(rule, w, h);
    lv_obj_set_pos_p(rule, x, y);
    lv_obj_clear_flag_p(rule, LV_OBJ_FLAG_SCROLLABLE);
    style_surface(rule, COLOR_BORDER, COLOR_BORDER, 0, 0);
    return rule;
}

static lv_obj_t *make_detail_label(lv_obj_t *parent, const char *text,
                                   int x, int y, int w, int h,
                                   const void *font, uint32_t color)
{
    lv_obj_t *label = make_single_line_label(parent, text, x, y, w, h);
    if (label && font && real_obj_set_style_text_font)
        real_obj_set_style_text_font(label, font, 0);
    set_text_color(label, color);
    return label;
}

static lv_obj_t *make_scrolling_detail_label(lv_obj_t *parent, const char *text,
                                             int x, int y, int w, int h,
                                             const void *font, uint32_t color,
                                             int align_right)
{
    lv_obj_t *label = make_detail_label(parent, text, x, y, w, h, font, color);
    if (!label) return NULL;
    if (lv_label_set_long_mode_p)
        lv_label_set_long_mode_p(label, LV_LABEL_LONG_SCROLL_CIRCULAR);
    if (align_right) right_align_label_text(label);
    return label;
}

static lv_obj_t *make_detail_block(lv_obj_t *parent, const char *text,
                                   int x, int y, int w, int h,
                                   const void *font, uint32_t color,
                                   int align_right)
{
    lv_obj_t *label = make_label(parent, text, x, y, w, h);
    if (!label) return NULL;
    if (font && real_obj_set_style_text_font)
        real_obj_set_style_text_font(label, font, 0);
    if (lv_label_set_long_mode_p)
        lv_label_set_long_mode_p(label, LV_LABEL_LONG_CLIP);
    set_text_color(label, color);
    if (align_right) right_align_label_text(label);
    return label;
}

static const char *sim_type_text(const struct modem_status *modem)
{
    if (modem && !strcmp(modem->sim_type, "esim")) return "内置卡";
    if (modem && !strcmp(modem->sim_type, "psim")) return "插拔卡";
    return "SIM";
}

static void format_address(const char *address, long mask, char *out, size_t size)
{
    if (!address || !*address) safe_copy(out, size, "--");
    else if (mask > 0) snprintf(out, size, "%s/%ld", address, mask);
    else safe_copy(out, size, address);
}

static void format_qos_sample(unsigned long long sampled_at,
                              char *out, size_t size)
{
    time_t value;
    struct tm local;
    if (!sampled_at) { safe_copy(out, size, "--"); return; }
    value = (time_t)sampled_at;
    localtime_r(&value, &local);
    snprintf(out, size, "%02d:%02d:%02d", local.tm_hour, local.tm_min, local.tm_sec);
}
