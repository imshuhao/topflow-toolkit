static const struct wifi_power_band_status *selected_wifi_power_band(void)
{
    if (!ui_wifi_power_status.valid || device_wifi_band < 0 || device_wifi_band > 1)
        return NULL;
    return &ui_wifi_power_status.bands[device_wifi_band];
}

static void update_wifi_draft_dirty(int index)
{
    const struct wifi_power_band_status *band;
    if (index < 0 || index > 1 || !device_wifi_draft_valid[index] ||
        !ui_wifi_power_status.valid) return;
    band = &ui_wifi_power_status.bands[index];
    device_wifi_draft_dirty[index] = band->valid &&
        (device_wifi_draft_percent[index] != band->percent ||
         device_wifi_draft_limit[index] != band->limit_dbm);
}

static void reset_wifi_drafts(void)
{
    memset(device_wifi_draft_percent, 0, sizeof(device_wifi_draft_percent));
    memset(device_wifi_draft_limit, 0, sizeof(device_wifi_draft_limit));
    memset(device_wifi_draft_valid, 0, sizeof(device_wifi_draft_valid));
    memset(device_wifi_draft_dirty, 0, sizeof(device_wifi_draft_dirty));
}

static void set_centered_wifi_value(lv_obj_t *label, const char *text)
{
    set_centered_dynamic_value(label, text);
}

static lv_obj_t *make_centered_wifi_value(lv_obj_t *parent, int x, int y,
                                           int w, int h, uint32_t color)
{
    return make_centered_dynamic_value(parent, x, y, w, h,
                                       ui_font_large, color);
}

static void wifi_2g_clicked(void *event)
{
    (void)event;
    reset_wifi_drafts();
    device_wifi_band = 0;
    refresh_wifi_power_ui();
}

static void wifi_5g_clicked(void *event)
{
    (void)event;
    reset_wifi_drafts();
    device_wifi_band = 1;
    refresh_wifi_power_ui();
}

static void wifi_percent_minus_clicked(void *event)
{
    (void)event;
    if (!device_wifi_draft_valid[device_wifi_band] ||
        device_wifi_draft_percent[device_wifi_band] <= 10) return;
    device_wifi_draft_percent[device_wifi_band] -= 10;
    update_wifi_draft_dirty(device_wifi_band);
    refresh_wifi_power_ui();
}

static void wifi_percent_plus_clicked(void *event)
{
    (void)event;
    if (!device_wifi_draft_valid[device_wifi_band] ||
        device_wifi_draft_percent[device_wifi_band] >= 100) return;
    device_wifi_draft_percent[device_wifi_band] += 10;
    update_wifi_draft_dirty(device_wifi_band);
    refresh_wifi_power_ui();
}

static void wifi_limit_minus_clicked(void *event)
{
    (void)event;
    if (!device_wifi_draft_valid[device_wifi_band] ||
        device_wifi_draft_limit[device_wifi_band] <= 1) return;
    device_wifi_draft_limit[device_wifi_band]--;
    update_wifi_draft_dirty(device_wifi_band);
    refresh_wifi_power_ui();
}

static void wifi_limit_plus_clicked(void *event)
{
    (void)event;
    if (!device_wifi_draft_valid[device_wifi_band] ||
        device_wifi_draft_limit[device_wifi_band] >= 30) return;
    device_wifi_draft_limit[device_wifi_band]++;
    update_wifi_draft_dirty(device_wifi_band);
    refresh_wifi_power_ui();
}

static void wifi_limit_restore_clicked(void *event)
{
    const struct wifi_power_band_status *band = selected_wifi_power_band();
    (void)event;
    if (!band || !device_wifi_draft_valid[device_wifi_band]) return;
    device_wifi_draft_limit[device_wifi_band] = band->factory_limit_dbm;
    update_wifi_draft_dirty(device_wifi_band);
    refresh_wifi_power_ui();
}

static void wifi_apply_clicked(void *event)
{
    char text[180];
    const char *band = device_wifi_band ? "5 GHz" : "2.4 GHz";
    (void)event;
    if (!device_wifi_draft_valid[device_wifi_band] ||
        !device_wifi_draft_dirty[device_wifi_band]) return;
    pending_wifi_band = device_wifi_band;
    pending_wifi_value = device_wifi_draft_percent[device_wifi_band];
    pending_wifi_value2 = device_wifi_draft_limit[device_wifi_band];
    snprintf(text, sizeof(text),
             "%s 将应用日常功率 %d%%、上限 %d dBm。Wi-Fi 会重载，已连接设备将短暂断线。",
             band, pending_wifi_value, pending_wifi_value2);
    show_confirm(ACTION_WIFI_APPLY, text);
}

static void refresh_wifi_power_ui(void)
{
    const struct wifi_power_band_status *band;
    char text[64];
    pthread_mutex_lock(&shared_lock);
    if (ui_wifi_generation != shared_wifi_generation) {
        ui_wifi_power_status = shared_wifi_power_status;
        ui_wifi_generation = shared_wifi_generation;
    }
    pthread_mutex_unlock(&shared_lock);
    for (int i = 0; i < 2; i++) {
        const struct wifi_power_band_status *item = &ui_wifi_power_status.bands[i];
        if (!ui_wifi_power_status.valid || !item->valid) continue;
        if (device_wifi_draft_dirty[i] &&
            device_wifi_draft_percent[i] == item->percent &&
            device_wifi_draft_limit[i] == item->limit_dbm)
            device_wifi_draft_dirty[i] = 0;
        if (!device_wifi_draft_valid[i] || !device_wifi_draft_dirty[i]) {
            device_wifi_draft_percent[i] = item->percent;
            device_wifi_draft_limit[i] = item->limit_dbm;
            device_wifi_draft_valid[i] = 1;
        }
    }
    if (!device_wifi_header) return;
    set_device_checked(device_wifi_band_buttons[0], device_wifi_band == 0);
    set_device_checked(device_wifi_band_buttons[1], device_wifi_band == 1);
    band = selected_wifi_power_band();
    if (lv_label_set_text_p)
        lv_label_set_text_p(device_wifi_header, device_wifi_band ? "5 GHz" : "2.4 GHz");
    if (!band || !band->valid || !device_wifi_draft_valid[device_wifi_band]) {
        set_label_text_if_changed(device_wifi_state, "读取中");
        set_centered_wifi_value(device_wifi_percent_value, "--");
        set_centered_wifi_value(device_wifi_limit_value, "--");
        set_device_checked(device_wifi_apply_button, 0);
        return;
    }
    set_label_text_if_changed(device_wifi_state, band->enabled ? "已开启" : "已关闭");
    set_text_color(device_wifi_state, band->enabled ? COLOR_GREEN : COLOR_MUTED);
    snprintf(text, sizeof(text), "%d%%", device_wifi_draft_percent[device_wifi_band]);
    set_centered_wifi_value(device_wifi_percent_value, text);
    snprintf(text, sizeof(text), "%d dBm", device_wifi_draft_limit[device_wifi_band]);
    set_centered_wifi_value(device_wifi_limit_value, text);
    set_device_checked(device_wifi_apply_button,
                       device_wifi_draft_dirty[device_wifi_band]);
}

static int create_device_wifi_tab(void)
{
    lv_obj_t *button;
    reset_wifi_drafts();
    device_tab_content = make_transparent_container(device_page, 0, 132, 320, 284);
    if (!device_tab_content) return 0;
    device_wifi_band_buttons[0] = make_button(device_tab_content, "2.4G", 8, 0, 148, 36,
                                              wifi_2g_clicked, NULL);
    device_wifi_band_buttons[1] = make_button(device_tab_content, "5G", 164, 0, 148, 36,
                                              wifi_5g_clicked, NULL);
    style_segment_button(device_wifi_band_buttons[0]);
    style_segment_button(device_wifi_band_buttons[1]);
    make_panel(device_tab_content, 8, 44, 304, 240, COLOR_CARD);
    device_wifi_header = make_detail_label(device_tab_content, "--", 20, 55, 120, 22,
                                           ui_font_small, COLOR_TEXT);
    device_wifi_state = make_detail_label(device_tab_content, "读取中", 180, 55, 120, 22,
                                          ui_font_small, COLOR_MUTED);
    right_align_label_text(device_wifi_state);

    make_detail_label(device_tab_content, "日常功率", 20, 87, 100, 20,
                      ui_font_tiny, COLOR_MUTED);
    button = make_button(device_tab_content, "-", 20, 109, 58, 40,
                         wifi_percent_minus_clicked, NULL);
    style_segment_button(button);
    device_wifi_percent_value = make_centered_wifi_value(device_tab_content,
                                                          88, 109, 144, 40,
                                                          COLOR_WIFI);
    button = make_button(device_tab_content, "+", 242, 109, 58, 40,
                         wifi_percent_plus_clicked, NULL);
    style_segment_button(button);

    make_detail_label(device_tab_content, "功率上限", 20, 157, 100, 20,
                      ui_font_tiny, COLOR_MUTED);
    button = make_button(device_tab_content, "-", 20, 179, 58, 40,
                         wifi_limit_minus_clicked, NULL);
    style_segment_button(button);
    device_wifi_limit_value = make_centered_wifi_value(device_tab_content,
                                                        82, 179, 156, 40,
                                                        COLOR_TEXT);
    button = make_button(device_tab_content, "+", 242, 179, 58, 40,
                         wifi_limit_plus_clicked, NULL);
    style_segment_button(button);

    device_wifi_restore_button = make_button(device_tab_content, "恢复原厂上限",
                                             20, 231, 132, 40,
                                             wifi_limit_restore_clicked, NULL);
    device_wifi_apply_button = make_button(device_tab_content, "应用",
                                           162, 231, 138, 40,
                                           wifi_apply_clicked, NULL);
    style_segment_button(device_wifi_apply_button);
    refresh_wifi_power_ui();
    return device_wifi_header && device_wifi_state && device_wifi_percent_value &&
           device_wifi_limit_value && device_wifi_restore_button &&
           device_wifi_apply_button;
}
