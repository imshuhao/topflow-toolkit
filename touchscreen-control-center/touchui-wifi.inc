/* 无线 tab（设备页第 4 个 tab）：Wi-Fi 功率调整。
 *
 * 内容区 320×232（x 相对 device_tab_content）：
 *   频段两段控件  y=0..42     2.4G / 5G（card-2 容器）
 *   功率卡        y=50..224   当前功率 + 上限两行，各自「- / 值 / +」
 *                              底部「还原」ghost + 「应用」primary
 * 所有回调与 ACTION_WIFI_APPLY 不变。 */

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
    if (!label) return;
    if (lv_label_get_text_p && !strcmp(lv_label_get_text_p(label), text)) return;
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
    for (int i = 0; i < 2; i++)
        if (device_wifi_band_labels[i])
            set_text_color(device_wifi_band_labels[i],
                           i == device_wifi_band ? COLOR_TEXT : COLOR_MUTED);
    band = selected_wifi_power_band();
    set_label_text_if_changed(device_wifi_header, device_wifi_band ? "5 GHz" : "2.4 GHz");
    set_label_text_if_changed(device_wifi_state, "功率设置");
    set_text_color(device_wifi_state, COLOR_MUTED);
    if (!band || !band->valid || !device_wifi_draft_valid[device_wifi_band]) {
        set_centered_wifi_value(device_wifi_percent_value, "--");
        set_centered_wifi_value(device_wifi_limit_value, "--");
        set_device_checked(device_wifi_apply_button, 0);
        return;
    }
    snprintf(text, sizeof(text), "%d%%", device_wifi_draft_percent[device_wifi_band]);
    set_centered_wifi_value(device_wifi_percent_value, text);
    snprintf(text, sizeof(text), "%d dBm", device_wifi_draft_limit[device_wifi_band]);
    set_centered_wifi_value(device_wifi_limit_value, text);
    /* 「应用」始终是 primary；有改动时置 checked（accent 浅底 + accent 边）作为可提交提示 */
    set_device_checked(device_wifi_apply_button,
                       device_wifi_draft_dirty[device_wifi_band]);
}

static int create_device_wifi_tab(void)
{
    lv_obj_t *band_card, *card, *button;
    if (!device_create_tab_container()) return 0;

    /* 频段两段控件：容器 card-2，内按钮 148×34 */
    band_card = make_card_alt(device_tab_content, 8, 0, 304, 42);
    if (!band_card) return 0;
    device_wifi_band_buttons[0] = make_button(band_card, "2.4G", 4, 4, 146, 34,
                                              wifi_2g_clicked,
                                              &device_wifi_band_labels[0]);
    device_wifi_band_buttons[1] = make_button(band_card, "5G", 154, 4, 146, 34,
                                              wifi_5g_clicked,
                                              &device_wifi_band_labels[1]);
    style_device_tab_button(device_wifi_band_buttons[0]);
    style_device_tab_button(device_wifi_band_buttons[1]);

    /* 功率卡：两行（日常功率 / 上限）+ 还原/应用；底外 hint 跟原型 */
    card = make_card(device_tab_content, 8, 50, 304, 158);
    if (!card) return 0;
    device_wifi_header = make_text(card, "2.4 GHz", 12, 4, 90, 20,
                                   ui_font_small, COLOR_TEXT);
    device_wifi_state = make_caption(card, "功率设置", 200, 6, 92, 16);
    right_align_label_text(device_wifi_state);

    /* 行 1：日常功率 */
    make_caption(card, "日常功率", 12, 36, 100, 16);
    button = make_button(card, "-", 148, 30, 44, 28,
                         wifi_percent_minus_clicked, NULL);
    style_ghost_button(button);
    device_wifi_percent_value = make_centered_wifi_value(card, 194, 30, 56, 28,
                                                          COLOR_ACCENT);
    button = make_button(card, "+", 252, 30, 44, 28,
                         wifi_percent_plus_clicked, NULL);
    style_ghost_button(button);

    /* 行 2：上限（原型文案） */
    make_caption(card, "上限", 12, 72, 100, 16);
    button = make_button(card, "-", 148, 66, 44, 28,
                         wifi_limit_minus_clicked, NULL);
    style_ghost_button(button);
    device_wifi_limit_value = make_centered_wifi_value(card, 194, 66, 56, 28,
                                                        COLOR_TEXT);
    button = make_button(card, "+", 252, 66, 44, 28,
                         wifi_limit_plus_clicked, NULL);
    style_ghost_button(button);

    device_wifi_restore_button = make_button(card, "还原", 12, 108, 136, 36,
                                             wifi_limit_restore_clicked, NULL);
    style_ghost_button(device_wifi_restore_button);
    device_wifi_apply_button = make_button(card, "应用", 156, 108, 136, 36,
                                           wifi_apply_clicked, NULL);
    style_primary_button(device_wifi_apply_button);

    make_caption(device_tab_content,
                 "应用后 Wi-Fi 会重载，已连接设备将短暂断线。",
                 12, 216, 296, 28);
    refresh_wifi_power_ui();
    return device_wifi_header && device_wifi_state && device_wifi_percent_value &&
           device_wifi_limit_value && device_wifi_restore_button &&
           device_wifi_apply_button;
}
