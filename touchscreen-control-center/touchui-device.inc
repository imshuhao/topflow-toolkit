/* 「设备」页（原型 page-device）+ 一键诊断页。
 *
 * 几何（page root 320×440，内容 x=8 宽 304）：
 *   hero       y=52..104   圆点 + 「系统运行正常 / N 项需要关注」+ 运行时间 · 在线卡数
 *   tabs       y=110..152  card-2 容器 + 四个等宽 tab（系统 / 流量 / 散热 / 无线）
 *   tab 内容   y=156..390  可滚动区（子控件 x 仍用 8，y 从 0 起算）
 *   一键诊断   y=394..426  ghost 按钮 304×32
 *   操作反馈   y=428..440  shared_message（PAGE_DEVICE）
 *
 * 原型是「hero + 五组只读 status-list」，这里必须保留四个 tab 与其中的控制按钮，
 * 因此只取 hero / tabs / status-list 的视觉口径，内容按 tab 重排。 */

/* ---- 本页新增静态（destroy_device_pages 里全部归零） -------------------- */
static lv_obj_t *device_hero_sub_label;      /* hero 第二行：运行时间 · 在线卡数 */
static lv_obj_t *device_diagnostics_button;  /* 底部「一键诊断」ghost */
static lv_obj_t *device_tab_labels[4];       /* 四个 tab 的文字（配色随选中变） */
static lv_obj_t *device_cooling_cpu_value;   /* 散热 tab：CPU 温度行 */
static lv_obj_t *device_fan_button_labels[4];    /* 风扇四键文字 */
static lv_obj_t *device_liquid_button_labels[3]; /* 液冷三键文字 */
static lv_obj_t *device_wifi_band_labels[2];     /* 无线频段两段文字 */

#define DEVICE_HERO_Y 52
#define DEVICE_HERO_H 52
#define DEVICE_TABS_Y 110
#define DEVICE_TABS_H 42
#define DEVICE_TAB_W 74
#define DEVICE_CONTENT_Y 156
#define DEVICE_CONTENT_H 234   /* 156..390 */
#define DEVICE_ACTION_Y 394    /* 394..426 */
#define DEVICE_ACTION_H 32
#define DEVICE_ROW_H 26        /* status-list 行高（原型 .stat-row min-height 33px 的紧凑版） */

/* ---------- 行值 / 按钮样式（散热、无线 tab 复用；实现见 touchui-charge-page.inc） ---------- */

/* 原型 tabs：未选 = 透明底 muted 字，选中 = card 底 + border 边 + text 字。
 * 文字色由 update_device_tab_labels() 同步（LVGL 状态不向子 label 传播）。 */
static void style_device_tab_button(lv_obj_t *button)
{
    if (!button) return;
    style_button(button, COLOR_CARD, COLOR_BUTTON_PRESSED, COLOR_CARD, COLOR_BORDER);
    if (lv_obj_set_style_bg_opa_p)
        lv_obj_set_style_bg_opa_p(button, LV_OPA_TRANSP, 0);
    if (lv_obj_set_style_border_width_p) {
        lv_obj_set_style_border_width_p(button, 0, 0);
        lv_obj_set_style_border_width_p(button, 1, LV_STATE_CHECKED);
        lv_obj_set_style_border_width_p(button, 1,
                                        LV_STATE_CHECKED | LV_STATE_PRESSED);
    }
    if (lv_obj_set_style_radius_p)
        lv_obj_set_style_radius_p(button, 8, 0);
}

/* ---------- 格式化 ---------- */

/* 原型 hero 副行「已运行 12 天 6 小时」；不足一天退化为小时 / 分钟。 */
static void format_device_uptime(long uptime, char *out, size_t size)
{
    long days, hours;
    if (uptime <= 0) { safe_copy(out, size, "已运行 --"); return; }
    days = uptime / 86400;
    hours = (uptime % 86400) / 3600;
    if (days > 0) snprintf(out, size, "已运行 %ld 天 %ld 小时", days, hours);
    else if (hours > 0) snprintf(out, size, "已运行 %ld 小时", hours);
    else snprintf(out, size, "已运行 %ld 分钟", uptime / 60);
}

static const char *device_online_cards_text(int online)
{
    if (online >= NETWORK_MODEM_COUNT) return "三卡在线";
    if (online == 2) return "两卡在线";
    if (online == 1) return "单卡在线";
    return "三卡离线";
}

/* 原型「158 / 256 MB」；总量 ≥ 1 GB 时改用 GB（本机 256 MB，正常走 MB 分支）。 */
static void format_device_memory(unsigned long long total, unsigned long long avail,
                                 char *out, size_t size)
{
    double total_mb, used_mb;
    if (!total) { safe_copy(out, size, "--"); return; }
    total_mb = (double)total / (1024.0 * 1024.0);
    used_mb = total > avail ? (double)(total - avail) / (1024.0 * 1024.0) : 0.0;
    if (total_mb >= 1024.0)
        snprintf(out, size, "%.2f / %.1f GB", used_mb / 1024.0, total_mb / 1024.0);
    else
        snprintf(out, size, "%d / %d MB", (int)(used_mb + 0.5), (int)(total_mb + 0.5));
}

/* ---------- 状态汇总 ---------- */

static int device_alert_count(void)
{
    const struct device_status *device = &ui_network_status.device;
    int alerts = 0, thermal_alert = 0;
    if (!ui_network_status.valid || !device->valid || ui_network_status.stale)
        alerts++;
    for (int i = 0; i < NETWORK_MODEM_COUNT; i++) {
        const struct modem_status *modem = &ui_network_status.modems[i];
        if (!modem->valid || !modem->online || !modem->sim_ready) alerts++;
        if (modem->temperature_valid && modem->temperature >= 70)
            thermal_alert = 1;
    }
    if (device->cpu_temp >= 75 || device->battery_temp >= 45 || thermal_alert)
        alerts++;
    if (ui_status.valid && !ui_status.service_running && !ui_status.manual_stop)
        alerts++;
    if (device->traffic_limit_overflow ||
        (device->traffic_limit_enabled && device->traffic_limit_ratio >= 90))
        alerts++;
    if ((device->fan_mode[0] && !device->fan_thermal_enabled) ||
        (!strcmp(device->fan_mode, "automatic") &&
         !device->fan_kernel_zone_enabled) ||
        (device->liquid_mode[0] && !device->liquid_thermal_enabled)) alerts++;
    if (device->sms_unread > 0) alerts++;
    return alerts;
}

static void set_device_checked(lv_obj_t *button, int checked)
{
    if (!button) return;
    if (checked) lv_obj_add_state_p(button, LV_STATE_CHECKED);
    else lv_obj_clear_state_p(button, LV_STATE_CHECKED);
}

/* ---------- tab 内容容器 ---------- */

static void destroy_device_tab_content(void)
{
    if (device_tab_content && lv_obj_del_p) lv_obj_del_p(device_tab_content);
    device_tab_content = NULL;
    memset(device_system_values, 0, sizeof(device_system_values));
    memset(device_traffic_values, 0, sizeof(device_traffic_values));
    device_cooling_cpu_value = NULL;
    device_fan_status = NULL;
    device_fan_detail = NULL;
    device_liquid_status = NULL;
    device_liquid_detail = NULL;
    memset(device_fan_buttons, 0, sizeof(device_fan_buttons));
    memset(device_fan_button_labels, 0, sizeof(device_fan_button_labels));
    memset(device_liquid_buttons, 0, sizeof(device_liquid_buttons));
    memset(device_liquid_button_labels, 0, sizeof(device_liquid_button_labels));
    memset(device_wifi_band_buttons, 0, sizeof(device_wifi_band_buttons));
    memset(device_wifi_band_labels, 0, sizeof(device_wifi_band_labels));
    device_wifi_header = device_wifi_state = NULL;
    device_wifi_percent_value = device_wifi_limit_value = NULL;
    device_wifi_restore_button = device_wifi_apply_button = NULL;
}

/* 每个 tab 的内容区（原型 .page-scroll）：能放下就不滚，超出可拖动。 */
static lv_obj_t *device_create_tab_container(void)
{
    destroy_device_tab_content();
    device_tab_content = make_scroll_area(device_page, 0, DEVICE_CONTENT_Y,
                                         320, DEVICE_CONTENT_H);
    return device_tab_content;
}

#include "touchui-wifi.inc"
#include "touchui-cooling.inc"

/* ---------- tab：系统 ---------- */

static int create_device_system_tab(void)
{
    /* 组「系统」：内核 / 系统 / 运行时间 / 负载·CPU / 内存 / 存储 */
    static const char *system_labels[6] = {
        "内核", "系统", "运行时间", "负载 · CPU", "内存", "存储"
    };
    /* 组「电池」：电量 / 电池温度 / 电池电压 */
    static const char *battery_labels[3] = {"电量", "电池温度", "电池电压"};
    lv_obj_t *card;
    if (!device_create_tab_container()) return 0;

    /* 九行 stat-row（行高 26）共 302px，高于 234 视口：本 tab 是纯只读列表
     * （无按钮），整页滚动不会和点按抢手势。 */
    card = make_card(device_tab_content, 8, 0, 304, 186);
    if (!card) return 0;
    make_caption(card, "系统", 12, 4, 120, 15);
    for (int i = 0; i < 6; i++)
        device_system_values[i] = make_stat_row(card, 12, 22 + i * DEVICE_ROW_H,
                                                280, DEVICE_ROW_H,
                                                system_labels[i], ui_font_small);

    card = make_card(device_tab_content, 8, 194, 304, 108);
    if (!card) return 0;
    make_caption(card, "电池", 12, 4, 120, 15);
    for (int i = 0; i < 3; i++)
        device_system_values[6 + i] = make_stat_row(card, 12, 22 + i * DEVICE_ROW_H,
                                                    280, DEVICE_ROW_H,
                                                    battery_labels[i], ui_font_small);
    return 1;
}

/* ---------- tab：流量 ---------- */

static int create_device_traffic_tab(void)
{
    static const char *group_titles[3] = {"今日", "本月", "累计"};
    lv_obj_t *card, *note;
    if (!device_create_tab_container()) return 0;

    /* 组「实时」：标题 + 右注「当前会话」+ 两个大号速率（原型 device-live） */
    card = make_card(device_tab_content, 8, 0, 304, 78);
    if (!card) return 0;
    make_caption(card, "实时", 12, 4, 80, 15);
    note = make_caption(card, "当前会话", 200, 4, 92, 15);
    right_align_label_text(note);
    device_traffic_values[0] = make_download_value(card, 16, 26, 100, ui_font_large);
    device_traffic_values[1] = make_upload_value(card, 164, 26, 100, ui_font_large);
    if (lv_img_set_zoom_p) {
        if (device_traffic_values[0].icon)
            lv_img_set_zoom_p(device_traffic_values[0].icon, 384);
        if (device_traffic_values[1].icon)
            lv_img_set_zoom_p(device_traffic_values[1].icon, 384);
    }
    if (device_traffic_values[0].label)
        lv_obj_set_pos_p(device_traffic_values[0].label, 48, 26);
    if (device_traffic_values[1].label)
        lv_obj_set_pos_p(device_traffic_values[1].label, 196, 26);

    /* 组「今日 / 本月 / 累计」三列（原型 device-sum-grid） */
    card = make_card(device_tab_content, 8, 86, 304, 96);
    if (!card) return 0;
    for (int i = 0; i < 3; i++) {
        int col_x = 12 + i * 96;
        make_caption(card, group_titles[i], col_x, 8, 84, 14);
        device_traffic_values[2 + i * 2] =
            make_download_value(card, col_x, 28, 84, ui_font_small);
        device_traffic_values[3 + i * 2] =
            make_upload_value(card, col_x, 54, 84, ui_font_small);
        if (i < 2) {
            lv_obj_t *div = make_panel(card, col_x + 88, 12, 1, 72, COLOR_BORDER);
            if (div && lv_obj_set_style_border_width_p)
                lv_obj_set_style_border_width_p(div, 0, 0);
        }
    }
    return 1;
}

/* ---------- tab 切换 ---------- */

static void update_device_tab_labels(int tab)
{
    for (int i = 0; i < 4; i++)
        if (device_tab_labels[i])
            set_text_color(device_tab_labels[i],
                           i == tab ? COLOR_TEXT : COLOR_MUTED);
}

static void show_device_tab(int tab)
{
    if (tab < 0 || tab > 3 || !device_page) tab = 0;
    hide_confirm();
    if (confirm_scrim && lv_obj_del_p) lv_obj_del_p(confirm_scrim);
    if (confirm_panel && lv_obj_del_p) lv_obj_del_p(confirm_panel);
    confirm_scrim = confirm_panel = confirm_text_label = NULL;
    device_tab = tab;
    if (tab == 0) create_device_system_tab();
    else if (tab == 1) create_device_traffic_tab();
    else if (tab == 2) create_device_cooling_tab();
    else create_device_wifi_tab();
    for (int i = 0; i < 4; i++) set_device_checked(device_tab_buttons[i], i == tab);
    update_device_tab_labels(tab);
    create_confirmation_overlay(device_page);
    refresh_device_ui();
}

static void device_system_tab_clicked(void *event) { (void)event; show_device_tab(0); }
static void device_traffic_tab_clicked(void *event) { (void)event; show_device_tab(1); }
static void device_cooling_tab_clicked(void *event) { (void)event; show_device_tab(2); }
static void device_wifi_tab_clicked(void *event) { (void)event; show_device_tab(3); }

static void open_diagnostics_clicked(void *event)
{
    (void)event;
    pending_device_view = 2;
}

/* ---------- 设备页骨架 ---------- */

static int create_device_page(lv_obj_t *top)
{
    static const char *tab_titles[4] = {"系统", "流量", "散热", "无线"};
    static void (*tab_callbacks[4])(void *) = {
        device_system_tab_clicked, device_traffic_tab_clicked,
        device_cooling_tab_clicked, device_wifi_tab_clicked
    };
    lv_obj_t *hero, *tabs;
    if (!page_shell_init(&device_shell, top, PAGE_DEVICE, "设备",
                         feature_back_clicked)) return 0;
    device_page = device_shell.root;

    /* hero 卡：圆点 + 状态大字 + 运行时间 / 在线卡数 */
    hero = make_card(device_page, TOUCHUI_CONTENT_X, DEVICE_HERO_Y,
                     TOUCHUI_CONTENT_W, DEVICE_HERO_H);
    if (hero) {
        device_alert_dot = make_dot(hero, 12,
                                    center_marker_on_text_line(8, ui_font, 8),
                                    8, COLOR_MUTED);
        device_alert_label = make_text(hero, "状态读取中…", 26, 8, 262, 22,
                                       ui_font, COLOR_MUTED);
        device_hero_sub_label = make_caption(hero, "正在读取运行状态",
                                             12, 32, 280, 16);
    }

    /* tabs：card-2 容器 + 四个等宽按钮（内边距 4，74×34） */
    tabs = make_card_alt(device_page, TOUCHUI_CONTENT_X, DEVICE_TABS_Y,
                         TOUCHUI_CONTENT_W, DEVICE_TABS_H);
    if (tabs) {
        for (int i = 0; i < 4; i++) {
            device_tab_buttons[i] = make_button(tabs, tab_titles[i],
                                                4 + i * DEVICE_TAB_W, 4,
                                                DEVICE_TAB_W, 34,
                                                tab_callbacks[i],
                                                &device_tab_labels[i]);
            style_device_tab_button(device_tab_buttons[i]);
        }
    }

    /* 底部：一键诊断（ghost）+ 操作反馈 */
    device_diagnostics_button = make_button(device_page, "一键诊断",
                                            8, DEVICE_ACTION_Y,
                                            TOUCHUI_CONTENT_W, DEVICE_ACTION_H,
                                            open_diagnostics_clicked, NULL);
    style_ghost_button(device_diagnostics_button);
    device_message_label = make_caption(device_page, "", 12, 428, 296, 12);
    set_text_color(device_message_label, COLOR_MESSAGE);

    if (!hero || !tabs || !device_alert_dot || !device_alert_label ||
        !device_hero_sub_label || !device_diagnostics_button ||
        !device_message_label || !device_tab_buttons[0] ||
        !device_tab_buttons[1] || !device_tab_buttons[2] ||
        !device_tab_buttons[3]) {
        trace_ui_create("device-page-allocation-failed");
        destroy_device_pages();
        return 0;
    }
    show_device_tab(device_tab);
    return 1;
}

/* ---------- 一键诊断页 ---------- */

static const char *diagnostic_result(int ok, const char *ok_text,
                                     const char *bad_text)
{
    return ok ? ok_text : bad_text;
}

static int create_diagnostics_page(lv_obj_t *top)
{
    static const char *names[6] = {
        "数据服务", "蜂窝链路", "地址与 DNS", "三路路径", "Sing-box", "温控保护"
    };
    lv_obj_t *overall, *list, *refresh_button;
    trace_ui_create("diagnostics-begin");
    if (!page_shell_init(&diagnostics_shell, top, PAGE_DIAGNOSTICS, "一键诊断",
                         open_device_clicked)) return 0;
    diagnostics_page = diagnostics_shell.root;

    overall = make_card(diagnostics_page, TOUCHUI_CONTENT_X, TOUCHUI_CONTENT_Y,
                        TOUCHUI_CONTENT_W, 58);
    if (overall) {
        make_caption(overall, "总体", 12, 6, 80, 15);
        diagnostic_overall_label = make_text(overall, "检测中…", 12, 26, 280, 22,
                                             ui_font_small, COLOR_MUTED);
    }
    list = make_card(diagnostics_page, TOUCHUI_CONTENT_X, 118, TOUCHUI_CONTENT_W, 268);
    if (list) {
        for (int i = 0; i < 6; i++)
            diagnostic_values[i] = make_stat_row(list, 12, 8 + i * 42, 280, 38,
                                                 names[i], ui_font_small);
    }
    refresh_button = make_button(diagnostics_page, "重新检测", 8, 394, 304, 34,
                                 device_refresh_clicked, NULL);
    style_ghost_button(refresh_button);

    if (!overall || !list || !diagnostic_overall_label || !refresh_button)
        goto failed;
    for (int i = 0; i < 6; i++)
        if (!diagnostic_values[i]) goto failed;
    trace_ui_create("diagnostics-complete");
    return 1;
failed:
    trace_ui_create("diagnostics-allocation-failed");
    if (diagnostics_page && lv_obj_del_p) lv_obj_del_p(diagnostics_page);
    diagnostics_page = NULL;
    memset(&diagnostics_shell, 0, sizeof(diagnostics_shell));
    diagnostic_overall_label = NULL;
    memset(diagnostic_values, 0, sizeof(diagnostic_values));
    return 0;
}

static void refresh_diagnostics_ui(void)
{
    const struct device_status *device = &ui_network_status.device;
    int modems_ok = 1, address_ok = 1, paths_ok = 1, thermal_ok = 1;
    int data_ok, singbox_ok, row_fails = 0, alerts;
    char text[96];
    if (!diagnostics_page) return;
    for (int i = 0; i < NETWORK_MODEM_COUNT; i++) {
        const struct modem_status *modem = &ui_network_status.modems[i];
        if (!modem->valid || !modem->online || !modem->sim_ready) modems_ok = 0;
        if (!modem->ipv4_up || !modem->ipv4_address[0] || !modem->ipv4_dns[0])
            address_ok = 0;
        if (!modem->path_valid || !modem->path_online) paths_ok = 0;
        if (modem->temperature_valid && modem->temperature >= 70) thermal_ok = 0;
    }
    if (device->cpu_temp >= 75 || device->battery_temp >= 45 ||
        !device->fan_thermal_enabled ||
        (!strcmp(device->fan_mode, "automatic") &&
         !device->fan_kernel_zone_enabled) ||
        !device->liquid_thermal_enabled)
        thermal_ok = 0;
    data_ok = ui_network_status.valid && device->valid && !ui_network_status.stale;
    singbox_ok = !ui_status.valid || ui_status.service_running;
    if (!data_ok) row_fails++;
    if (!modems_ok) row_fails++;
    if (!address_ok) row_fails++;
    if (!paths_ok) row_fails++;
    if (!singbox_ok) row_fails++;
    if (!thermal_ok) row_fails++;
    /* 总计必须可解释：未读短信/流量限额没有对应明细行，计入并点名。
     * 原实现直接套 device_alert_count()，导致“6 行全绿却显示 1 项需要关注”。 */
    alerts = row_fails;
    if (device->sms_unread > 0) alerts++;
    if (device->traffic_limit_overflow ||
        (device->traffic_limit_enabled && device->traffic_limit_ratio >= 90))
        alerts++;
    if (!alerts) {
        snprintf(text, sizeof(text), "全部检查通过");
    } else if (device->sms_unread > 0) {
        snprintf(text, sizeof(text), "%d 项需要关注 · 未读短信 %d 条",
                 alerts, device->sms_unread);
    } else if (device->traffic_limit_overflow ||
               (device->traffic_limit_enabled && device->traffic_limit_ratio >= 90)) {
        snprintf(text, sizeof(text), "%d 项需要关注 · 流量达限额", alerts);
    } else {
        snprintf(text, sizeof(text), "%d 项需要关注", alerts);
    }
    set_label_text_if_changed(diagnostic_overall_label, text);
    set_text_color(diagnostic_overall_label, alerts ? COLOR_AMBER : COLOR_GREEN);
    set_device_row_value(diagnostic_values[0], diagnostic_result(
        data_ok, "正常 · 每秒更新", "不可用或数据延迟"));
    set_device_row_value(diagnostic_values[1], diagnostic_result(
        modems_ok, "3/3 在线", "检查离线卡或 SIM"));
    set_device_row_value(diagnostic_values[2], diagnostic_result(
        address_ok, "IPv4 与 DNS 正常", "地址或 DNS 缺失"));
    set_device_row_value(diagnostic_values[3], diagnostic_result(
        paths_ok, "3/3 路径在线", "路径探测异常"));
    set_device_row_value(diagnostic_values[4], diagnostic_result(
        singbox_ok, ui_status.service_running ? "运行正常" : "未启用",
        "服务未运行"));
    set_device_row_value(diagnostic_values[5], diagnostic_result(
        thermal_ok, "温度与保护正常", "高温或温控被关闭"));
}

static void device_refresh_clicked(void *event)
{
    (void)event;
    queue_action(ACTION_STATE_REFRESH);
}

/* ---------- 刷新 ---------- */

static void refresh_device_hero(void)
{
    const struct device_status *device = &ui_network_status.device;
    char text[128], uptime[48];
    int alerts = device_alert_count();
    int online = 0;
    int ready = ui_network_status.valid && device->valid;
    for (int i = 0; i < NETWORK_MODEM_COUNT; i++)
        if (ui_network_status.modems[i].online) online++;
    if (device_alert_dot) {
        set_dot_color(device_alert_dot,
                      !ready ? COLOR_MUTED : (alerts ? COLOR_AMBER : COLOR_GREEN));
    }
    if (device_alert_label) {
        if (!ready) {
            set_label_text_if_changed(device_alert_label, "状态读取中…");
            set_text_color(device_alert_label, COLOR_MUTED);
        } else {
            snprintf(text, sizeof(text), alerts ? "%d 项需要关注" : "系统运行正常",
                     alerts);
            set_label_text_if_changed(device_alert_label, text);
            set_text_color(device_alert_label, alerts ? COLOR_AMBER : COLOR_GREEN);
        }
    }
    if (device_hero_sub_label) {
        if (!ready) {
            set_label_text_if_changed(device_hero_sub_label, "正在读取运行状态");
        } else {
            format_device_uptime(device->uptime, uptime, sizeof(uptime));
            snprintf(text, sizeof(text), "%s · %s", uptime,
                     device_online_cards_text(online));
            set_label_text_if_changed(device_hero_sub_label, text);
        }
    }
}

/* 系统 tab 九行：内核 / 系统 / 运行时间 / 负载 · CPU / 内存 / 存储 /
 * 电量 / 电池温度 / 电池电压。内核/发行版由 worker 读 /proc 与 openwrt_release。 */
static void refresh_device_system_values(void)
{
    const struct device_status *device = &ui_network_status.device;
    char text[96], a[32], b[32];
    int ready = ui_network_status.valid && device->valid;
    if (!device_system_values[0]) return;
    if (!ready) {
        for (int i = 0; i < 9; i++)
            set_device_row_value(device_system_values[i], "--");
        return;
    }
    set_device_row_value(device_system_values[0],
                        device->kernel_release[0] ? device->kernel_release : "--");
    set_device_row_value(device_system_values[1],
                        device->os_release[0] ? device->os_release : "--");
    format_device_uptime(device->uptime, text, sizeof(text));
    set_device_row_value(device_system_values[2], text);
    snprintf(text, sizeof(text), "%d%%", device->cpu_usage);
    set_device_row_value(device_system_values[3], text);
    format_device_memory(device->mem_total, device->mem_avail, text, sizeof(text));
    set_device_row_value(device_system_values[4], text);
    format_bytes_compact(device->storage_used, a, sizeof(a));
    format_bytes_compact(device->storage_total, b, sizeof(b));
    snprintf(text, sizeof(text), "%s / %s", a, b);
    set_device_row_value(device_system_values[5], text);
    snprintf(text, sizeof(text), "%d%%", device->battery_percent);
    set_device_row_value(device_system_values[6], text);
    snprintf(text, sizeof(text), "%d °C", device->battery_temp);
    set_device_row_value(device_system_values[7], text);
    snprintf(text, sizeof(text), "%.2f V", (double)device->battery_uv / 1e6);
    set_device_row_value(device_system_values[8], text);
}

static void refresh_device_traffic_values(void)
{
    const struct device_status *device = &ui_network_status.device;
    unsigned long long values[8];
    char text[64];
    if (!device_traffic_values[0].label) return;
    values[0] = device->traffic_rx_rate;
    values[1] = device->traffic_tx_rate;
    values[2] = device->traffic_day_rx;
    values[3] = device->traffic_day_tx;
    values[4] = device->traffic_month_rx;
    values[5] = device->traffic_month_tx;
    values[6] = device->traffic_total_rx;
    values[7] = device->traffic_total_tx;
    for (int i = 0; i < 8; i++) {
        if (!ui_network_status.valid) {
            set_traffic_value(&device_traffic_values[i], "--");
            continue;
        }
        if (i < 2) format_rate_compact(values[i], text, sizeof(text));
        else format_bytes_compact(values[i], text, sizeof(text));
        set_traffic_value(&device_traffic_values[i], text);
    }
}

static void refresh_device_ui(void)
{
    char text[96], message[160];
    int alerts = device_alert_count();

    /* 首页「设备」格的 N 项徽标：底色取主题 soft 色（不写死十六进制） */
    if (menu_device_alert_label) {
        snprintf(text, sizeof(text), alerts ? "%d项" : "正常", alerts);
        set_label_text_if_changed(menu_device_alert_label, text);
        if (lv_obj_update_layout_p)
            lv_obj_update_layout_p(menu_device_alert_label);
        lv_obj_align_p(menu_device_alert_label, LV_ALIGN_CENTER, 0, 0);
        set_text_color(menu_device_alert_label,
                       alerts ? COLOR_AMBER : COLOR_GREEN);
        if (menu_device_alert_badge)
            style_surface(menu_device_alert_badge,
                          alerts ? touchui_theme.warn_soft : touchui_theme.ok_soft,
                          alerts ? COLOR_AMBER : COLOR_GREEN, 8, 1);
    }
    if (!device_page && !cooling_curve_page && !diagnostics_page) return;
    refresh_device_hero();
    pthread_mutex_lock(&shared_lock);
    safe_copy(message, sizeof(message),
              shared_message_page == PAGE_DEVICE ? shared_message : "");
    pthread_mutex_unlock(&shared_lock);
    if (device_message_label) set_label_text_if_changed(device_message_label, message);
    refresh_device_system_values();
    refresh_device_traffic_values();
    refresh_cooling_overview_ui();
    refresh_cooling_curve_ui();
    refresh_wifi_power_ui();
    refresh_diagnostics_ui();
}

static void open_device_clicked(void *event)
{
    (void)event;
    pending_device_view = 1;
}

static void destroy_device_pages(void)
{
    if (device_page && lv_obj_del_p) lv_obj_del_p(device_page);
    if (cooling_curve_page && lv_obj_del_p) lv_obj_del_p(cooling_curve_page);
    if (diagnostics_page && lv_obj_del_p) lv_obj_del_p(diagnostics_page);
    device_page = cooling_curve_page = diagnostics_page = NULL;
    memset(&device_shell, 0, sizeof(device_shell));
    memset(&cooling_curve_shell, 0, sizeof(cooling_curve_shell));
    memset(&diagnostics_shell, 0, sizeof(diagnostics_shell));
    confirm_scrim = confirm_panel = confirm_text_label = NULL;
    device_alert_dot = device_alert_label = device_message_label = NULL;
    device_hero_sub_label = device_diagnostics_button = NULL;
    memset(device_tab_buttons, 0, sizeof(device_tab_buttons));
    memset(device_tab_labels, 0, sizeof(device_tab_labels));
    device_tab_content = NULL;
    memset(device_system_values, 0, sizeof(device_system_values));
    memset(device_traffic_values, 0, sizeof(device_traffic_values));
    device_cooling_cpu_value = NULL;
    device_fan_status = NULL;
    device_fan_detail = NULL;
    device_liquid_status = NULL;
    device_liquid_detail = NULL;
    memset(device_fan_buttons, 0, sizeof(device_fan_buttons));
    memset(device_fan_button_labels, 0, sizeof(device_fan_button_labels));
    memset(device_liquid_buttons, 0, sizeof(device_liquid_buttons));
    memset(device_liquid_button_labels, 0, sizeof(device_liquid_button_labels));
    cooling_curve_summary = cooling_curve_point_label = NULL;
    cooling_curve_temperature_value = cooling_curve_speed_value = NULL;
    cooling_curve_message_label = cooling_curve_chart = NULL;
    memset(cooling_curve_profile_buttons, 0,
           sizeof(cooling_curve_profile_buttons));
    cooling_curve_factory_content = cooling_curve_custom_content = NULL;
    memset(cooling_curve_factory_temperature, 0,
           sizeof(cooling_curve_factory_temperature));
    memset(cooling_curve_factory_speed, 0,
           sizeof(cooling_curve_factory_speed));
    cooling_curve_series = NULL;
    cooling_curve_draft_valid = 0;
    cooling_curve_draft_dirty = 0;
    cooling_curve_draft_count = 0;
    cooling_curve_active_point = 0;
    memset(device_wifi_band_buttons, 0, sizeof(device_wifi_band_buttons));
    memset(device_wifi_band_labels, 0, sizeof(device_wifi_band_labels));
    device_wifi_header = device_wifi_state = NULL;
    device_wifi_percent_value = device_wifi_limit_value = NULL;
    device_wifi_restore_button = device_wifi_apply_button = NULL;
    diagnostic_overall_label = NULL;
    memset(diagnostic_values, 0, sizeof(diagnostic_values));
}

static void process_device_navigation(void)
{
    int view = pending_device_view;
    if (!view || !network_parent) return;
    pending_device_view = 0;
    destroy_singbox_page();
    destroy_wanbal_page();
    destroy_charge_page();
    destroy_network_identity();
    destroy_network_detail();
    destroy_network_overview();
    destroy_device_pages();
    trace_ui_create(view == 1 ? "device-create-page" :
                    (view == 2 ? "device-create-diagnostics" :
                     "device-create-cooling-curve"));
    if (view == 1) {
        if (!create_device_page(network_parent)) return;
        show_page(PAGE_DEVICE);
    } else if (view == 2) {
        if (!create_diagnostics_page(network_parent)) return;
        show_page(PAGE_DIAGNOSTICS);
    } else {
        if (!create_cooling_curve_page(network_parent)) return;
        show_page(PAGE_COOLING_CURVE);
    }
    pthread_mutex_lock(&shared_lock);
    force_refresh = 1;
    force_network_refresh = 1;
    pthread_mutex_unlock(&shared_lock);
    refresh_device_ui();
}
