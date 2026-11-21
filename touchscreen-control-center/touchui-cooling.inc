/* 散热 tab（设备页第 3 个 tab）+ 风扇曲线页。所有 LVGL 操作都在 UI 线程。
 *
 * 散热 tab（x 相对 device_tab_content，视口 320×234；三块卡共 288px 需下拉）：
 *   散热卡   y=0..78    两行 stat-row：CPU 温度 / 风扇状态·档位
 *   风扇卡   y=84..210  标题 + 「编辑曲线」ghost + 2×2 四键（原厂/自定义/常开/常闭）
 *   液冷卡   y=216..288 标题行（右对齐状态）+ 一键三档（自动/低/高）+ 详情小字
 * 8 个控件要保住 34px 以上的触控高度，一屏放不下 → 用可滚动区（原型 .page-scroll）。
 *
 * 所有按钮回调与 ACTION_* 与改造前完全一致。 */

static const char *fan_mode_text(const struct device_status *device)
{
    if (!device) return "读取中";
    if (fan_custom_curve_is_off(device)) return "常闭";
    if (!strcmp(device->fan_mode, "automatic")) return "原厂自动";
    if (!strcmp(device->fan_mode, "custom")) return "自定义";
    if (!strcmp(device->fan_mode, "always_on")) return "常开";
    return "未知模式";
}

static void fan_factory_clicked(void *event)
{
    (void)event;
    if (!fan_custom_curve_is_off(&ui_network_status.device) &&
        !strcmp(ui_network_status.device.fan_mode, "automatic")) return;
    show_confirm(ACTION_FAN_FACTORY,
                 "交还原厂内核温控？风扇将按 44/48/53°C 三档自动调节。");
}

static void fan_custom_clicked(void *event)
{
    (void)event;
    if (!fan_custom_curve_is_off(&ui_network_status.device) &&
        !strcmp(ui_network_status.device.fan_mode, "custom")) return;
    show_confirm(ACTION_FAN_CUSTOM, "启用已保存的自定义温控曲线？");
}

static void fan_always_clicked(void *event)
{
    (void)event;
    if (!strcmp(ui_network_status.device.fan_mode, "always_on")) return;
    show_confirm(ACTION_FAN_ALWAYS,
                 "将风扇持续保持在 50%？80°C 满速保护仍然有效。");
}

static void fan_off_clicked(void *event)
{
    (void)event;
    if (fan_custom_curve_is_off(&ui_network_status.device)) return;
    show_confirm(ACTION_FAN_OFF,
                 "关闭风扇？将写入零转速曲线，温控不再自动拉起。");
}

static void liquid_auto_clicked(void *event)
{
    (void)event;
    if (!strcmp(ui_network_status.device.liquid_mode, "automatic")) return;
    show_confirm(ACTION_LIQUID_AUTO, "交还原厂液冷温控，由设备按需启动？");
}

static void liquid_low_clicked(void *event)
{
    (void)event;
    if (!strcmp(ui_network_status.device.liquid_mode, "low")) return;
    show_confirm(ACTION_LIQUID_LOW, "将液冷持续切换为低档？");
}

static void liquid_high_clicked(void *event)
{
    (void)event;
    if (!strcmp(ui_network_status.device.liquid_mode, "high")) return;
    show_confirm(ACTION_LIQUID_HIGH, "将液冷持续切换为高档？");
}

static void open_cooling_curve_clicked(void *event)
{
    (void)event;
    pending_device_view = 3;
}

static int create_device_cooling_tab(void)
{
    lv_obj_t *card, *curve_button;
    if (!device_create_tab_container()) return 0;

    /* 组「散热」：CPU 温度 / 风扇状态·档位 */
    card = make_card(device_tab_content, 8, 0, 304, 78);
    if (!card) return 0;
    make_caption(card, "散热", 12, 2, 100, 15);
    device_cooling_cpu_value = make_stat_row(card, 12, 18, 280, DEVICE_ROW_H,
                                             "CPU 温度", ui_font_small);
    device_fan_status = make_stat_row(card, 12, 46, 280, DEVICE_ROW_H,
                                      "风扇状态", ui_font_small);

    /* 组「风扇」：四键 2×2 + 曲线页入口 */
    card = make_card(device_tab_content, 8, 84, 304, 126);
    if (!card) return 0;
    make_caption(card, "风扇", 12, 4, 60, 15);
    device_fan_detail = make_caption(card, "--", 76, 4, 104, 15);
    curve_button = make_button(card, "编辑曲线", 190, 2, 102, 26,
                               open_cooling_curve_clicked, NULL);
    style_ghost_button(curve_button);
    device_fan_buttons[0] = make_button(card, "原厂", 12, 36, 136, 36,
                                        fan_factory_clicked,
                                        &device_fan_button_labels[0]);
    device_fan_buttons[1] = make_button(card, "自定义", 156, 36, 136, 36,
                                        fan_custom_clicked,
                                        &device_fan_button_labels[1]);
    device_fan_buttons[2] = make_button(card, "常开", 12, 78, 136, 36,
                                        fan_always_clicked,
                                        &device_fan_button_labels[2]);
    device_fan_buttons[3] = make_button(card, "常闭", 156, 78, 136, 36,
                                        fan_off_clicked,
                                        &device_fan_button_labels[3]);
    for (int i = 0; i < 4; i++) style_ghost_button(device_fan_buttons[i]);

    /* 组「液冷」：一键三档 + 详情小字 */
    card = make_card(device_tab_content, 8, 216, 304, 78);
    if (!card) return 0;
    make_caption(card, "液冷", 12, 4, 48, 15);
    device_liquid_status = make_caption(card, "读取中", 64, 4, 228, 15);
    right_align_label_text(device_liquid_status);
    device_liquid_buttons[0] = make_button(card, "自动", 12, 22, 88, 36,
                                           liquid_auto_clicked,
                                           &device_liquid_button_labels[0]);
    device_liquid_buttons[1] = make_button(card, "低档", 108, 22, 88, 36,
                                           liquid_low_clicked,
                                           &device_liquid_button_labels[1]);
    device_liquid_buttons[2] = make_button(card, "高档", 204, 22, 88, 36,
                                           liquid_high_clicked,
                                           &device_liquid_button_labels[2]);
    for (int i = 0; i < 3; i++) style_ghost_button(device_liquid_buttons[i]);
    device_liquid_detail = make_caption(card, "--", 12, 62, 280, 14);
    return 1;
}

/* 幽灵按钮的文字配色：选中 accent，未选 text（LVGL 状态不向子 label 传播）。 */
static void set_ghost_label_checked(lv_obj_t *label, int checked)
{
    if (label) set_text_color(label, checked ? COLOR_ACCENT : COLOR_TEXT);
}

static void refresh_cooling_overview_ui(void)
{
    const struct device_status *device = &ui_network_status.device;
    char text[128];
    int fan_is_off;
    int ready = ui_network_status.valid && device->valid;
    if (!device_fan_status) return;

    fan_is_off = fan_custom_curve_is_off(device);

    /* 组「散热」：CPU 温度 + 风扇状态·档位 */
    if (device_cooling_cpu_value) {
        snprintf(text, sizeof(text), "%d °C", device->cpu_temp);
        set_device_row_value(device_cooling_cpu_value, ready ? text : "--");
    }

    if (!ready || !device->fan_mode[0]) {
        set_device_row_value(device_fan_status, "--");
        if (device_fan_detail) set_label_text_if_changed(device_fan_detail, "等待散热状态");
    } else if (fan_is_off) {
        set_device_row_value(device_fan_status, "0% · 常闭");
        snprintf(text, sizeof(text), "%d °C · PWM %d", device->fan_temperature,
                 device->fan_pwm);
        if (device_fan_detail) set_label_text_if_changed(device_fan_detail, text);
    } else {
        /* 原型：20% · 自定义 */
        snprintf(text, sizeof(text), "%d%% · %s", device->fan_speed_percent,
                 fan_mode_text(device));
        set_device_row_value(device_fan_status, text);
        snprintf(text, sizeof(text), "%d °C · PWM %d", device->fan_temperature,
                 device->fan_pwm);
        if (device_fan_detail) set_label_text_if_changed(device_fan_detail, text);
    }

    set_device_checked(device_fan_buttons[0],
                       !fan_is_off && !strcmp(device->fan_mode, "automatic"));
    set_device_checked(device_fan_buttons[1],
                       !fan_is_off && !strcmp(device->fan_mode, "custom"));
    set_device_checked(device_fan_buttons[2],
                       !fan_is_off && !strcmp(device->fan_mode, "always_on"));
    set_device_checked(device_fan_buttons[3], fan_is_off);
    set_ghost_label_checked(device_fan_button_labels[0],
                            !fan_is_off && !strcmp(device->fan_mode, "automatic"));
    set_ghost_label_checked(device_fan_button_labels[1],
                            !fan_is_off && !strcmp(device->fan_mode, "custom"));
    set_ghost_label_checked(device_fan_button_labels[2],
                            !fan_is_off && !strcmp(device->fan_mode, "always_on"));
    set_ghost_label_checked(device_fan_button_labels[3], fan_is_off);

    if (!device_liquid_status) return;
    /* 原型：右上短状态 + 底行固定 hint */
    if (device_liquid_detail)
        set_label_text_if_changed(device_liquid_detail,
                                  "温控保护仍生效；危险操作需二次确认。");
    if (!ready || !device->liquid_mode[0]) {
        set_label_text_if_changed(device_liquid_status, "读取中");
    } else if (!strcmp(device->liquid_mode, "automatic")) {
        set_label_text_if_changed(device_liquid_status, "自动");
    } else {
        set_label_text_if_changed(device_liquid_status,
                                  !strcmp(device->liquid_mode, "high") ? "高档" : "低档");
    }
    set_device_checked(device_liquid_buttons[0],
                       !strcmp(device->liquid_mode, "automatic"));
    set_device_checked(device_liquid_buttons[1],
                       !strcmp(device->liquid_mode, "low"));
    set_device_checked(device_liquid_buttons[2],
                       !strcmp(device->liquid_mode, "high"));
    set_ghost_label_checked(device_liquid_button_labels[0],
                            !strcmp(device->liquid_mode, "automatic"));
    set_ghost_label_checked(device_liquid_button_labels[1],
                            !strcmp(device->liquid_mode, "low"));
    set_ghost_label_checked(device_liquid_button_labels[2],
                            !strcmp(device->liquid_mode, "high"));
}

/* ---------- 曲线页（图表与交互不动，仅换卡片 / 按钮皮） ---------- */

static void cooling_curve_defaults(void)
{
    /* 8 点低转速平滑曲线：44-50°C 每 1°C 一点，峰值压至 70% */
    static const int temperatures[] = {40, 44, 45, 46, 47, 48, 50, 70};
    static const int pwms[] = {0, 0, 13, 20, 28, 36, 51, 179};
    cooling_curve_draft_count = 8;
    for (int i = 0; i < cooling_curve_draft_count; i++) {
        cooling_curve_draft[i].temperature = temperatures[i];
        cooling_curve_draft[i].hysteresis = 0;
        cooling_curve_draft[i].pwm = pwms[i];
        cooling_curve_draft[i].speed_percent = (pwms[i] * 100 + 127) / 255;
    }
    cooling_curve_active_point = 2;
    cooling_curve_draft_valid = 1;
    cooling_curve_draft_dirty = 1;
}

static void cooling_curve_load_draft(void)
{
    const struct device_status *device = &ui_network_status.device;
    if (device->fan_custom_curve_count >= 2 &&
        device->fan_custom_curve_count <= TOUCHUI_FAN_CURVE_MAX) {
        cooling_curve_draft_count = device->fan_custom_curve_count;
        memcpy(cooling_curve_draft, device->fan_custom_curve,
               sizeof(cooling_curve_draft));
        cooling_curve_active_point = cooling_curve_draft_count > 2 ? 2 : 0;
        cooling_curve_draft_valid = 1;
        cooling_curve_draft_dirty = 0;
    } else {
        cooling_curve_defaults();
        cooling_curve_draft_dirty = 0;
    }
}

static int interpolate_custom_pwm(const struct fan_curve_point_status *points,
                                  int count, int temperature)
{
    if (!points || count < 2) return 0;
    if (temperature <= points[0].temperature) return points[0].pwm;
    for (int i = 1; i < count; i++) {
        int x0 = points[i - 1].temperature;
        int x1 = points[i].temperature;
        int y0 = points[i - 1].pwm;
        int y1 = points[i].pwm;
        if (x1 <= x0)
            continue; /* 脏曲线（同温/非单调）防除零 SIGFPE（H3） */
        if (temperature <= x1)
            return y0 + ((temperature - x0) * (y1 - y0) + (x1 - x0) / 2) /
                        (x1 - x0);
    }
    return points[count - 1].pwm;
}

static int factory_curve_percent(const struct device_status *device, int temperature)
{
    int percent = 0;
    for (int i = 0; i < device->fan_factory_curve_count; i++)
        if (temperature >= device->fan_factory_curve[i].temperature)
            percent = device->fan_factory_curve[i].speed_percent;
    return percent;
}

static void refresh_cooling_curve_chart(void)
{
    const struct device_status *device = &ui_network_status.device;
    if (!cooling_curve_chart || !cooling_curve_series || !lv_chart_set_next_value_p)
        return;
    for (int temperature = 20; temperature <= 80; temperature++) {
        int percent;
        if (cooling_curve_profile == 0)
            percent = factory_curve_percent(device, temperature);
        else {
            int pwm = temperature >= device->fan_hard_full_speed_temperature ? 255 :
                interpolate_custom_pwm(cooling_curve_draft,
                                       cooling_curve_draft_count, temperature);
            percent = (pwm * 100 + 127) / 255;
        }
        lv_chart_set_next_value_p(cooling_curve_chart, cooling_curve_series, percent);
    }
    if (lv_chart_refresh_p) lv_chart_refresh_p(cooling_curve_chart);
}

static void cooling_curve_show_profile(int profile)
{
    cooling_curve_profile = profile ? 1 : 0;
    set_device_checked(cooling_curve_profile_buttons[0], cooling_curve_profile == 0);
    set_device_checked(cooling_curve_profile_buttons[1], cooling_curve_profile == 1);
    if (cooling_curve_factory_content) {
        if (cooling_curve_profile == 0)
            lv_obj_clear_flag_p(cooling_curve_factory_content, LV_OBJ_FLAG_HIDDEN);
        else
            lv_obj_add_flag_p(cooling_curve_factory_content, LV_OBJ_FLAG_HIDDEN);
    }
    if (cooling_curve_custom_content) {
        if (cooling_curve_profile == 1)
            lv_obj_clear_flag_p(cooling_curve_custom_content, LV_OBJ_FLAG_HIDDEN);
        else
            lv_obj_add_flag_p(cooling_curve_custom_content, LV_OBJ_FLAG_HIDDEN);
    }
    refresh_cooling_curve_chart();
    refresh_cooling_curve_ui();
}

static void cooling_factory_profile_clicked(void *event)
{
    (void)event;
    cooling_curve_show_profile(0);
}

static void cooling_custom_profile_clicked(void *event)
{
    (void)event;
    cooling_curve_show_profile(1);
}

static void cooling_curve_select_delta(int delta)
{
    int next = cooling_curve_active_point + delta;
    if (next < 0 || next >= cooling_curve_draft_count) return;
    cooling_curve_active_point = next;
    refresh_cooling_curve_ui();
}

static void cooling_curve_previous_clicked(void *event)
{
    (void)event;
    cooling_curve_select_delta(-1);
}

static void cooling_curve_next_clicked(void *event)
{
    (void)event;
    cooling_curve_select_delta(1);
}

static void cooling_curve_temperature_delta(int delta)
{
    int index = cooling_curve_active_point;
    int minimum = index ? cooling_curve_draft[index - 1].temperature + 1 : 20;
    int hard_limit = ui_network_status.device.fan_hard_full_speed_temperature;
    int maximum = index + 1 < cooling_curve_draft_count ?
        cooling_curve_draft[index + 1].temperature - 1 :
        ((hard_limit > 20 ? hard_limit : 80) - 1);
    int value = cooling_curve_draft[index].temperature + delta;
    if (value < minimum || value > maximum) return;
    cooling_curve_draft[index].temperature = value;
    cooling_curve_draft_dirty = 1;
    refresh_cooling_curve_chart();
    refresh_cooling_curve_ui();
}

static void cooling_curve_temperature_down(void *event)
{
    (void)event;
    cooling_curve_temperature_delta(-1);
}

static void cooling_curve_temperature_up(void *event)
{
    (void)event;
    cooling_curve_temperature_delta(1);
}

static void cooling_curve_speed_delta(int delta)
{
    int index = cooling_curve_active_point;
    int minimum = index ? cooling_curve_draft[index - 1].speed_percent : 0;
    int maximum = index + 1 < cooling_curve_draft_count ?
        cooling_curve_draft[index + 1].speed_percent : 100;
    int percent = cooling_curve_draft[index].speed_percent + delta;
    if (percent < minimum || percent > maximum) return;
    cooling_curve_draft[index].speed_percent = percent;
    cooling_curve_draft[index].pwm = (percent * 255 + 50) / 100;
    cooling_curve_draft_dirty = 1;
    refresh_cooling_curve_chart();
    refresh_cooling_curve_ui();
}

static void cooling_curve_speed_down(void *event)
{
    (void)event;
    cooling_curve_speed_delta(-5);
}

static void cooling_curve_speed_up(void *event)
{
    (void)event;
    cooling_curve_speed_delta(5);
}

static void cooling_curve_delete_clicked(void *event)
{
    int index = cooling_curve_active_point;
    (void)event;
    if (cooling_curve_draft_count <= 2) return;
    memmove(&cooling_curve_draft[index], &cooling_curve_draft[index + 1],
            (size_t)(cooling_curve_draft_count - index - 1) *
            sizeof(cooling_curve_draft[0]));
    cooling_curve_draft_count--;
    if (cooling_curve_active_point >= cooling_curve_draft_count)
        cooling_curve_active_point = cooling_curve_draft_count - 1;
    cooling_curve_draft_dirty = 1;
    refresh_cooling_curve_chart();
    refresh_cooling_curve_ui();
}

static void cooling_curve_add_clicked(void *event)
{
    int index = cooling_curve_active_point;
    int insert = index + 1;
    int next_temperature, next_pwm, next_percent;
    int hard_limit = ui_network_status.device.fan_hard_full_speed_temperature;
    (void)event;
    if (cooling_curve_draft_count >= TOUCHUI_FAN_CURVE_MAX) return;
    if (insert < cooling_curve_draft_count) {
        if (cooling_curve_draft[insert].temperature -
            cooling_curve_draft[index].temperature < 2) return;
        next_temperature = (cooling_curve_draft[index].temperature +
                            cooling_curve_draft[insert].temperature) / 2;
        next_pwm = (cooling_curve_draft[index].pwm +
                    cooling_curve_draft[insert].pwm) / 2;
        next_percent = (next_pwm * 100 + 127) / 255;
    } else {
        int maximum = (hard_limit > 20 ? hard_limit : 80) - 1;
        next_temperature = cooling_curve_draft[index].temperature + 5;
        if (next_temperature > maximum) next_temperature = maximum;
        if (next_temperature <= cooling_curve_draft[index].temperature) return;
        next_percent = (cooling_curve_draft[index].speed_percent + 100) / 2;
        next_pwm = (next_percent * 255 + 50) / 100;
    }
    memmove(&cooling_curve_draft[insert + 1], &cooling_curve_draft[insert],
            (size_t)(cooling_curve_draft_count - insert) *
            sizeof(cooling_curve_draft[0]));
    cooling_curve_draft[insert].temperature = next_temperature;
    cooling_curve_draft[insert].hysteresis = 0;
    cooling_curve_draft[insert].pwm = next_pwm;
    cooling_curve_draft[insert].speed_percent = next_percent;
    cooling_curve_draft_count++;
    cooling_curve_active_point = insert;
    cooling_curve_draft_dirty = 1;
    refresh_cooling_curve_chart();
    refresh_cooling_curve_ui();
}

static void cooling_curve_reset_clicked(void *event)
{
    (void)event;
    cooling_curve_defaults();
    refresh_cooling_curve_chart();
    refresh_cooling_curve_ui();
}

static void cooling_curve_apply_clicked(void *event)
{
    char text[128];
    const struct device_status *device = &ui_network_status.device;
    int pwm = device->fan_temperature >= device->fan_hard_full_speed_temperature ? 255 :
        interpolate_custom_pwm(cooling_curve_draft,
                               cooling_curve_draft_count,
                               device->fan_temperature);
    int percent = (pwm * 100 + 127) / 255;
    (void)event;
    /* 原型 confirm：标题句 + 正文「当前温度预计输出 N%。」 */
    snprintf(text, sizeof(text),
             !strcmp(device->fan_mode, "custom") ?
             "保存并应用这条曲线？\n当前温度预计输出 %d%%。" :
             "保存曲线并切换至自定义模式？\n当前温度预计输出 %d%%。",
             percent);
    show_confirm(ACTION_FAN_CURVE_APPLY, text);
}

static void cooling_curve_back_clicked(void *event)
{
    (void)event;
    device_tab = 2;
    pending_device_view = 1;
}

static int create_cooling_curve_page(lv_obj_t *top)
{
    lv_obj_t *card, *button, *profile_card;
    if (!page_shell_init(&cooling_curve_shell, top, PAGE_COOLING_CURVE,
                         "风扇曲线", cooling_curve_back_clicked)) return 0;
    cooling_curve_page = cooling_curve_shell.root;
    cooling_curve_load_draft();

    /* 曲线来源两段控件 */
    profile_card = make_card_alt(cooling_curve_page, 8, 52, 304, 44);
    if (profile_card) {
        cooling_curve_profile_buttons[0] = make_button(profile_card, "原厂曲线",
                                                       4, 4, 146, 36,
                                                       cooling_factory_profile_clicked,
                                                       NULL);
        cooling_curve_profile_buttons[1] = make_button(profile_card, "自定义曲线",
                                                       154, 4, 146, 36,
                                                       cooling_custom_profile_clicked,
                                                       NULL);
        style_device_tab_button(cooling_curve_profile_buttons[0]);
        style_device_tab_button(cooling_curve_profile_buttons[1]);
    }

    /* 图表卡：图形与 61 点序列完全沿用原实现 */
    card = make_card(cooling_curve_page, 8, 104, 304, 148);
    if (card && lv_chart_create_p && lv_chart_add_series_p &&
        lv_chart_set_next_value_p) {
        cooling_curve_chart = lv_chart_create_p(card);
        if (cooling_curve_chart) {
            lv_obj_set_size_p(cooling_curve_chart, 280, 92);
            lv_obj_set_pos_p(cooling_curve_chart, 12, 8);
            lv_obj_clear_flag_p(cooling_curve_chart, LV_OBJ_FLAG_SCROLLABLE);
            style_surface(cooling_curve_chart, COLOR_CARD, COLOR_CARD, 0, 0);
            lv_chart_set_type_p(cooling_curve_chart, LV_CHART_TYPE_LINE);
            lv_chart_set_point_count_p(cooling_curve_chart, 61);
            lv_chart_set_range_p(cooling_curve_chart, LV_CHART_AXIS_PRIMARY_Y, 0, 100);
            cooling_curve_series = lv_chart_add_series_p(
                cooling_curve_chart, color_hex(COLOR_TEXT), LV_CHART_AXIS_PRIMARY_Y);
        }
    }
    make_caption(card, "20°", 12, 104, 40, 14);
    make_caption(card, "50°", 132, 104, 40, 14);
    make_caption(card, "80°", 252, 104, 40, 14);
    cooling_curve_summary = make_caption(card, "--", 12, 124, 280, 14);

    /* 原厂曲线明细 */
    cooling_curve_factory_content = make_transparent_container(cooling_curve_page,
                                                               0, 258, 320, 168);
    if (cooling_curve_factory_content) {
        card = make_card(cooling_curve_factory_content, 8, 0, 304, 150);
        if (card) {
            make_caption(card, "触发温度", 12, 8, 100, 14);
            make_caption(card, "风扇输出", 192, 8, 100, 14);
            for (int i = 0; i < 3; i++) {
                cooling_curve_factory_temperature[i] = make_text(
                    card, "--", 12, 26 + i * 30, 100, 20,
                    ui_font_small, COLOR_TEXT);
                cooling_curve_factory_speed[i] = make_text(
                    card, "--", 192, 26 + i * 30, 100, 20,
                    ui_font_small, COLOR_TEXT);
            }
            make_caption(card, "降至触发温度 - 4°C 才退档", 12, 122, 280, 14);
        }
    }

    /* 自定义曲线编辑 */
    cooling_curve_custom_content = make_transparent_container(cooling_curve_page,
                                                              0, 258, 320, 168);
    if (cooling_curve_custom_content) {
        card = make_card(cooling_curve_custom_content, 8, 0, 304, 164);
        if (card) {
            cooling_curve_point_label = make_caption(card, "控制点", 12, 8, 68, 18);
            button = make_button(card, "‹", 84, 4, 38, 28,
                                 cooling_curve_previous_clicked, NULL);
            style_ghost_button(button);
            button = make_button(card, "›", 126, 4, 38, 28,
                                 cooling_curve_next_clicked, NULL);
            style_ghost_button(button);
            button = make_button(card, "删除", 168, 4, 54, 28,
                                 cooling_curve_delete_clicked, NULL);
            style_ghost_button(button);
            button = make_button(card, "新增", 226, 4, 66, 28,
                                 cooling_curve_add_clicked, NULL);
            style_ghost_button(button);

            make_caption(card, "温度", 12, 42, 44, 18);
            button = make_button(card, "-", 60, 38, 46, 32,
                                 cooling_curve_temperature_down, NULL);
            style_ghost_button(button);
            cooling_curve_temperature_value = make_centered_dynamic_value(
                card, 110, 38, 80, 32, ui_font_large, COLOR_TEXT);
            button = make_button(card, "+", 194, 38, 98, 32,
                                 cooling_curve_temperature_up, NULL);
            style_ghost_button(button);

            make_caption(card, "转速", 12, 80, 44, 18);
            button = make_button(card, "-", 60, 76, 46, 32,
                                 cooling_curve_speed_down, NULL);
            style_ghost_button(button);
            cooling_curve_speed_value = make_centered_dynamic_value(
                card, 110, 76, 80, 32, ui_font_large, COLOR_TEXT);
            button = make_button(card, "+", 194, 76, 98, 32,
                                 cooling_curve_speed_up, NULL);
            style_ghost_button(button);

            button = make_button(card, "恢复默认", 12, 120, 136, 36,
                                 cooling_curve_reset_clicked, NULL);
            style_ghost_button(button);
            button = make_button(card, "应用", 152, 120, 140, 36,
                                 cooling_curve_apply_clicked, NULL);
            style_primary_button(button);
        }
    }
    cooling_curve_message_label = make_caption(cooling_curve_page, "", 12, 428, 296, 12);
    set_text_color(cooling_curve_message_label, COLOR_MESSAGE);
    create_confirmation_overlay(cooling_curve_page);
    cooling_curve_show_profile(1);
    return 1;
}

static void refresh_cooling_curve_ui(void)
{
    const struct device_status *device = &ui_network_status.device;
    char text[128], message[160];
    int index, pwm, percent;
    if (!cooling_curve_page) return;
    if (!cooling_curve_draft_valid || cooling_curve_draft_count < 2) return;
    index = cooling_curve_active_point;
    if (index < 0 || index >= cooling_curve_draft_count) index = 0;
    cooling_curve_active_point = index;
    if (cooling_curve_profile == 0) {
        snprintf(text, sizeof(text), "原厂阶梯 · %d°C 当前输出 %d%%",
                 device->fan_temperature,
                 factory_curve_percent(device, device->fan_temperature));
    } else {
        pwm = device->fan_temperature >= device->fan_hard_full_speed_temperature ? 255 :
            interpolate_custom_pwm(cooling_curve_draft,
                                   cooling_curve_draft_count,
                                   device->fan_temperature);
        percent = (pwm * 100 + 127) / 255;
        snprintf(text, sizeof(text), "%d°C · 预计 %d%% · %d°C 满速",
                 device->fan_temperature, percent,
                 device->fan_hard_full_speed_temperature > 0 ?
                 device->fan_hard_full_speed_temperature : 80);
    }
    if (cooling_curve_summary) set_label_text_if_changed(cooling_curve_summary, text);
    for (int i = 0; i < 3; i++) {
        if (i < device->fan_factory_curve_count) {
            snprintf(text, sizeof(text), "%d°C",
                     device->fan_factory_curve[i].temperature);
            if (cooling_curve_factory_temperature[i])
                set_label_text_if_changed(cooling_curve_factory_temperature[i], text);
            snprintf(text, sizeof(text), "%d%%",
                     device->fan_factory_curve[i].speed_percent);
            if (cooling_curve_factory_speed[i])
                set_label_text_if_changed(cooling_curve_factory_speed[i], text);
        } else {
            if (cooling_curve_factory_temperature[i])
                set_label_text_if_changed(cooling_curve_factory_temperature[i], "--");
            if (cooling_curve_factory_speed[i])
                set_label_text_if_changed(cooling_curve_factory_speed[i], "--");
        }
    }
    if (cooling_curve_point_label) {
        snprintf(text, sizeof(text), "控制点 %d/%d", index + 1,
                 cooling_curve_draft_count);
        set_label_text_if_changed(cooling_curve_point_label, text);
    }
    if (cooling_curve_temperature_value) {
        snprintf(text, sizeof(text), "%d°C", cooling_curve_draft[index].temperature);
        set_centered_dynamic_value(cooling_curve_temperature_value, text);
    }
    if (cooling_curve_speed_value) {
        snprintf(text, sizeof(text), "%d%%", cooling_curve_draft[index].speed_percent);
        set_centered_dynamic_value(cooling_curve_speed_value, text);
    }
    pthread_mutex_lock(&shared_lock);
    /* 曲线应用回执挂 PAGE_DEVICE；无回执时用原型固定 hint */
    if ((shared_message_page == PAGE_DEVICE ||
         shared_message_page == PAGE_COOLING_CURVE) &&
        shared_message[0])
        safe_copy(message, sizeof(message), shared_message);
    else if (cooling_curve_profile == 1)
        safe_copy(message, sizeof(message),
                  "2–8 个控制点；温度须严格递增。");
    else
        message[0] = '\0';
    pthread_mutex_unlock(&shared_lock);
    if (cooling_curve_message_label)
        set_label_text_if_changed(cooling_curve_message_label, message);
}
