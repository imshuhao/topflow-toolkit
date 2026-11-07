/* 「代理」页（原型 #page-proxy）：摘要卡 / 流量卡 / 动作行 / 次级三格 /
 * 核心切换 / 底部提示与消息。
 *
 * 本文件只负责几何与控件创建；所有文案与配色由 touchui-singbox.inc 的
 * refresh_ui() 每 tick 写入（set_label_text_if_changed + 样式缓存）。
 *
 * 几何（page root 320×440，内容 x=8 宽 304，从 TOUCHUI_CONTENT_Y=52 起）：
 *   摘要卡   52..162   6px 圆点 + 状态大字 + 模式徽标 / 小字 / 2×2 字段
 *   流量卡  166..218   实时 ↓↑ / 累计 ↓↑（中间 1px 分隔在 y=189）
 *   动作行  222..266   停止|启动 148×44 ＋ 重启 148×44（间距 8）
 *   次级格  270..298   订阅 / 看门狗 / 保活（高 28，卡内两条 1px 竖分隔）
 *   切换标题 302..320 「核心切换（二次确认）」+ 右侧小字
 *   切换按键 321..361 切到 sing-box / 切回 mihomo（各 148×40）
 *   提示行  365..383  hint（tiny muted，单行）
 *   底部行  387..407 「更新于 HH:MM:SS」… 消息
 * 结束于 407，页面 440 —— 底部留 33px，与原型 content 到 ~409 后留白的观感一致。
 * 一屏放下，不做滚动（滚动会与点卡片抢手势）。卡片高度按原型收口：
 * 原型 .proxy-summary 111 / .proxy-traffic 52 / .sub-stats 28，这里 110 / 52 / 28。
 */

/* 「核心切换」区块（原型 .engine-switch）拆到 touchui-engine-page.inc，
 * 与点击回调（touchui-engine.inc）同属核心切换功能。 */
#include "touchui-engine-page.inc"

static void destroy_singbox_page(void);

/* 1px 竖分隔线：make_divider 只画横线，次级三格要竖线
 * （原型 .sub-stats > div + div 的 border-left）。 */
static lv_obj_t *proxy_make_vrule(lv_obj_t *parent, int x, int y, int h)
{
    lv_obj_t *rule = make_panel(parent, x, y, 1, h, COLOR_BORDER);
    if (!rule) return NULL;
    if (lv_obj_set_style_radius_p) lv_obj_set_style_radius_p(rule, 0, 0);
    if (lv_obj_set_style_border_width_p)
        lv_obj_set_style_border_width_p(rule, 0, 0);
    return rule;
}

static int create_singbox_page(lv_obj_t *top)
{
    if (!page_shell_init(&singbox_shell, top, PAGE_SINGBOX, "代理",
                         feature_back_clicked)) return 0;
    manager_page = singbox_shell.root;

    /* 底部「更新于 / 消息」占用 y=407 一行，旧 footer_label（y=410）会与它压字；
     * refresh_page_clocks 仍会往它写「数据延迟」，这里直接隐藏。 */
    if (singbox_shell.footer_label)
        lv_obj_add_flag_p(singbox_shell.footer_label, LV_OBJ_FLAG_HIDDEN);

    /* ---- 1. 摘要卡 .proxy-summary (52..162) --------------------------- */
    make_card(manager_page, 8, 52, 304, 110);

    /* 行 1：6px 圆点 + 状态大字 + 右侧模式徽标（原型 .hero-top）
     * 原型 .hero-state 是 15px；这里用 ui_font_small（16px，行高 19），
     * 圆点与徽标都按同一行高居中，避免 18px 大字把行撑高、徽标下沉。 */
    status_indicator = make_dot(manager_page, 19,
                                center_marker_on_text_line(55, ui_font_small,
                                                           6),
                                6, COLOR_MUTED);
    status_label = make_text(manager_page, "状态读取中…", 33, 55, 180, 20,
                             ui_font_small, COLOR_TEXT);
    /* 徽标右端贴到卡片内边距（312 内缩 11 = 301），宽 84 可容纳「eBPF 模式」；
     * 高度 18 + y=56 与 16px 状态字的视觉中线对齐（原型徽标同样是 18px）。 */
    proxy_mode_badge = make_badge(manager_page, 217, 56, 84, 18, "读取中",
                                  COLOR_MUTED, COLOR_CARD_ALT, ui_font_tiny);
    /* 行 2：小字。原型是「PID 7822 · 自动拉起」——我们没有 PID 字段，
     * 改写成真实守护状态（看门狗 / 保活 / 手动停止 / 数据面未接管）。 */
    status_mode_label = make_caption(manager_page, "等待状态采集",
                                     33, 80, 258, 20);
    make_divider(manager_page, 19, 101, 282);

    /* 2×2 字段：核心 / 内存 · 数据面 / DHCP
     * 标签与值共用同一 top-y（按 small 行高居中），避免上下错位；
     * 右列标签→值拉开间距，避免「DHCP」「0.1」横向叠字。 */
    {
        int small_h = font_line_height(ui_font_small);
        int row0 = 103, row1 = 125, row_h = 22;
        int y0, y1;
        if (small_h <= 0) small_h = 19;
        y0 = row0 + (row_h - small_h) / 2;
        y1 = row1 + (row_h - small_h) / 2;
        make_caption(manager_page, "核心", 19, y0, 30, small_h);
        version_label = make_text(manager_page, "未知", 54, y0, 108, small_h,
                                  ui_font_small, COLOR_TEXT);
        make_caption(manager_page, "内存", 168, y0, 36, small_h);
        memory_label = make_text(manager_page, "--", 212, y0, 90, small_h,
                                 ui_font_small, COLOR_TEXT);
        make_caption(manager_page, "数据面", 19, y1, 42, small_h);
        tun_value_label = make_text(manager_page, "未知", 66, y1, 90, small_h,
                                    ui_font_small, COLOR_TEXT);
        make_caption(manager_page, "DHCP", 168, y1, 40, small_h);
        dhcp_value_label = make_text(manager_page, "未知", 216, y1, 86, small_h,
                                     ui_font_small, COLOR_TEXT);
    }

    /* ---- 2. 流量卡 .proxy-traffic (166..218，高 52) -------------------- */
    make_card(manager_page, 8, 166, 304, 52);
    make_caption(manager_page, "实时", 19, 171, 32, 20);
    traffic_rate_down = make_download_value(manager_page, 55, 168, 92,
                                            ui_font_small);
    traffic_rate_up = make_upload_value(manager_page, 171, 168, 110,
                                        ui_font_small);
    make_divider(manager_page, 19, 189, 282);
    make_caption(manager_page, "累计", 19, 195, 32, 20);
    traffic_total_down = make_download_value(manager_page, 55, 192, 92,
                                             ui_font_small);
    traffic_total_up = make_upload_value(manager_page, 171, 192, 110,
                                         ui_font_small);
    /* 原型 .traffic-value：下载用正文色，上传用 muted（.traffic-value.up
     * 覆盖为 --muted）。make_traffic_value 默认按方向着色（蓝/绿），本页按
     * 原型覆盖这四个数值；箭头是静态位图（无 recolor ABI），保持方向色。 */
    set_text_color(traffic_rate_down.label, COLOR_TEXT);
    set_text_color(traffic_rate_up.label, COLOR_MUTED);
    set_text_color(traffic_total_down.label, COLOR_TEXT);
    set_text_color(traffic_total_up.label, COLOR_MUTED);

    /* ---- 3. 动作行 .action-row (222..266) ----------------------------- */
    service_button = make_button(manager_page, "启动服务", 8, 222, 148, 44,
                                 service_clicked, &service_button_label);
    restart_button = make_button(manager_page, "重启服务", 164, 222, 148, 44,
                                 restart_clicked, &restart_button_label);
    if (service_button_label && ui_font_small && real_obj_set_style_text_font)
        real_obj_set_style_text_font(service_button_label, ui_font_small, 0);
    if (restart_button_label && ui_font_small && real_obj_set_style_text_font)
        real_obj_set_style_text_font(restart_button_label, ui_font_small, 0);
    proxy_apply_button(service_button, service_button_label,
                       PROXY_BTN_PRIMARY, 0);
    proxy_apply_button(restart_button, restart_button_label,
                       PROXY_BTN_GHOST, 0);
    /* make_button 已居中过一次；改字体后行高变了，再居中一次 */
    center_button_label(service_button_label);
    center_button_label(restart_button_label);

    /* ---- 4. 次级三格 .sub-stats (270..298，高 28) --------------------- */
    make_card(manager_page, 8, 270, 304, 28);
    /* 28px 卡内只有 18px 内容带：竖线 h=18、标签/数值按卡中线（284）居中，
     * 两者行底都落在 293，保持基线对齐。 */
    proxy_make_vrule(manager_page, 112, 275, 18);
    proxy_make_vrule(manager_page, 208, 275, 18);
    make_caption(manager_page, "订阅", 22, 277, 30, 18);
    providers_label = make_text(manager_page, "--", 54, 274, 52, 20,
                                ui_font_small, COLOR_TEXT);
    make_caption(manager_page, "看门狗", 121, 277, 46, 18);
    watchdog_label = make_text(manager_page, "--", 171, 274, 30, 20,
                               ui_font_small, COLOR_TEXT);
    make_caption(manager_page, "保活", 219, 277, 30, 18);
    keeper_label = make_text(manager_page, "--", 251, 274, 46, 20,
                             ui_font_small, COLOR_TEXT);

    /* ---- 5. 核心切换 .engine-switch (302..361) ------------------------ */
    make_text(manager_page, "核心切换（二次确认）", 8, 302, 150, 18,
              ui_font_tiny, COLOR_TEXT);
    /* 右侧小字：切换约 3 秒 / 正在切换，请稍候 / 进程缺失，可重试 */
    proxy_engine_note_label = make_value_right(manager_page, 158, 302, 154, 18,
                                               ui_font_tiny, COLOR_MUTED);
    if (!create_engine_switch_section(manager_page, 321)) {
        trace_ui_create("engine-switch-failed");
        destroy_singbox_page();
        return 0;
    }

    /* ---- 6. hint (365..383) ------------------------------------------- */
    proxy_hint_label = make_caption(
        manager_page, "切回 mihomo 会暂停服务；二次确认后执行。",
        8, 365, 304, 18);

    /* ---- 7. 底部 .proxy-updated (387..407) ---------------------------- */
    updated_label = make_text(manager_page, "更新于 --:--:--", 8, 387, 124, 20,
                              ui_font_tiny, COLOR_MUTED);
    /* message_label 右贴齐：holder 136..312；超宽由 proxy_short_text 截断 */
    message_label = make_value_right(manager_page, 136, 387, 176, 20,
                                     ui_font_tiny, COLOR_MUTED);

    if (!status_indicator || !status_label || !status_mode_label ||
        !proxy_mode_badge.panel || !proxy_mode_badge.label ||
        !version_label || !memory_label || !tun_value_label ||
        !dhcp_value_label || !providers_label || !watchdog_label ||
        !keeper_label || !traffic_rate_down.label || !traffic_rate_up.label ||
        !traffic_total_down.label || !traffic_total_up.label ||
        !service_button || !restart_button ||
        !engine_to_singbox_button || !engine_to_mihomo_button ||
        !proxy_engine_note_label || !proxy_hint_label ||
        !updated_label || !message_label) {
        trace_ui_create("singbox-allocation-failed");
        destroy_singbox_page();
        return 0;
    }
    if (!create_confirmation_overlay(manager_page)) {
        trace_ui_create("singbox-overlay-failed");
        destroy_singbox_page();
        return 0;
    }
    /* 首次刷新必须落一次样式：清掉缓存键，refresh_ui() 会重设全部控件 */
    proxy_style_key = -1;
    proxy_badge_text_cache[0] = '\0';
    return 1;
}

static void request_singbox_page(void)
{
    pending_singbox_open = 1;
}

static void destroy_singbox_page(void)
{
    if (manager_page && lv_obj_del_p) lv_obj_del_p(manager_page);
    manager_page = NULL;
    memset(&singbox_shell, 0, sizeof(singbox_shell));
    /* 确认弹层是本页子对象，随 manager_page 一起销毁 */
    confirm_scrim = NULL;
    confirm_panel = NULL;
    confirm_text_label = NULL;
    confirm_action = ACTION_NONE;
    confirm_step = 0;

    /* refresh_ui() 用到的所有指针都在这里清零，避免主题重建后悬空 */
    status_indicator = NULL;
    status_label = NULL;
    status_mode_label = NULL;
    version_label = NULL;
    memory_label = NULL;
    tun_value_label = NULL;
    dhcp_value_label = NULL;
    providers_label = NULL;
    watchdog_label = NULL;
    keeper_label = NULL;
    updated_label = NULL;
    message_label = NULL;
    service_button = NULL;
    service_button_label = NULL;
    restart_button = NULL;
    restart_button_label = NULL;
    engine_to_singbox_button = NULL;
    engine_to_singbox_label = NULL;
    engine_to_mihomo_button = NULL;
    engine_to_mihomo_label = NULL;
    proxy_engine_note_label = NULL;
    proxy_hint_label = NULL;
    memset(&proxy_mode_badge, 0, sizeof(proxy_mode_badge));
    memset(&traffic_rate_down, 0, sizeof(traffic_rate_down));
    memset(&traffic_rate_up, 0, sizeof(traffic_rate_up));
    memset(&traffic_total_down, 0, sizeof(traffic_total_down));
    memset(&traffic_total_up, 0, sizeof(traffic_total_up));
    proxy_style_key = -1;
    proxy_badge_text_cache[0] = '\0';
}
