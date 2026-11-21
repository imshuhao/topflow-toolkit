/* 「代理」页的状态机与展示层（原型 #page-proxy）。
 *
 * 数据面：worker 线程按 FAST/FULL 周期采集 shared_status；本文件只在 UI 线程
 * （lv_timer_handler → refresh_ui）读快照并改写文本，不新开线程、不读设备文件。
 *
 * 状态判定沿用改造前顺序，语义一字不改：
 *   数据无效 → 数据延迟(stale) → mihomo 回滚(on_mihomo) → 服务停止 →
 *   API 未起 → 数据面未接管 → DHCP 未指向 → 正常
 * 禁用/锁定同样保持：回滚态只读；动作进行中全锁；核心按钮按当前核心锁定。
 *
 * 展示层按原型 updateProxyUI() 的口径：
 *   状态大字 = 服务状态（运行正常 / 服务已停止 / 正在启动… / 正在重启… /
 *              mihomo 运行中 / mihomo 未启动 / 切换中…）
 *   模式徽标 = 核心与数据面种类（eBPF 模式 / TUN 模式 / 回滚态 / 回滚中断 /
 *              直连模式 / 切换中 / 数据延迟）
 */

/* 新布局才有的控件：模式徽标 + 核心切换右侧小字 + 底部提示行。
 * 由 touchui-singbox-page.inc 创建，这里只负责刷新。 */
static struct badge_component proxy_mode_badge;
static lv_obj_t *proxy_engine_note_label;
static lv_obj_t *proxy_hint_label;

/* 上一次落样式时的组合键与徽标文字：样式只在状态变化时重设，避免每 tick
 * 触发 layout。页面重建时由 destroy_singbox_page 复位。 */
static int proxy_style_key = -1;
static char proxy_badge_text_cache[24];

static void format_bytes(unsigned long long bytes, char *out, size_t size)
{
    static const char *const units[] = {"B", "KB", "MB", "GB", "TB", "PB", "EB"};
    double value = (double)bytes;
    size_t unit = 0;
    while (value >= 1024.0 && unit + 1 < sizeof(units) / sizeof(units[0])) {
        value /= 1024.0;
        unit++;
    }
    if (unit == 0) snprintf(out, size, "%lluB", bytes);
    else if (value < 10.0) snprintf(out, size, "%.2f%s", value, units[unit]);
    else if (value < 100.0) snprintf(out, size, "%.1f%s", value, units[unit]);
    else snprintf(out, size, "%.0f%s", value, units[unit]);
}

/* 勾选态（分流页的分段按钮仍在用，保留在共享可见处）。 */
static void set_checked(lv_obj_t *button, int checked)
{
    if (!button) return;
    if (checked) lv_obj_add_state_p(button, LV_STATE_CHECKED);
    else lv_obj_clear_state_p(button, LV_STATE_CHECKED);
}

static void set_status_color(uint32_t color)
{
    set_bg_color(status_indicator, color, 0);
    set_border_color(status_indicator, color, 0);
    set_shadow_color(status_indicator, color);
}

static int status_is_mihomo(const struct singbox_status *status)
{
    if (!status) return 0;
    if (!strcmp(status->engine, "mihomo")) return 1;
    if (status->dhcp_points_to_mihomo && !status->service_running) return 1;
    return status->mihomo_running && !status->service_running;
}

/* ---- 原型色调（colors.md） ---------------------------------------------- */

/* 状态圆点 / 状态大字：ok 绿、warn 琥珀、danger 红、muted 灰 */
enum {
    PROXY_TONE_MUTED = 0,
    PROXY_TONE_OK = 1,
    PROXY_TONE_WARN = 2,
    PROXY_TONE_DANGER = 3
};

/* 徽标：.badge.soft / .warn / .danger / .neutral / .ok */
enum {
    PROXY_BADGE_SOFT = 0,
    PROXY_BADGE_WARN = 1,
    PROXY_BADGE_DANGER = 2,
    PROXY_BADGE_NEUTRAL = 3
};

/* 按钮：.btn-danger / .btn-primary / .btn-ghost / .btn-ghost(可用时强调色) */
enum {
    PROXY_BTN_DANGER = 1,
    PROXY_BTN_PRIMARY = 2,
    PROXY_BTN_GHOST = 3,
    PROXY_BTN_GHOST_ACCENT = 4
};

static uint32_t proxy_tone_color(int tone)
{
    switch (tone) {
    case PROXY_TONE_OK: return COLOR_GREEN;
    case PROXY_TONE_WARN: return COLOR_AMBER;
    case PROXY_TONE_DANGER: return COLOR_RED;
    default: return COLOR_MUTED;
    }
}

/* 原型 .hero-state 只在 warn / danger 改字色，其余用正文色。 */
static uint32_t proxy_state_text_color(int tone)
{
    if (tone == PROXY_TONE_WARN) return COLOR_AMBER;
    if (tone == PROXY_TONE_DANGER) return COLOR_RED;
    return COLOR_TEXT;
}

static void proxy_badge_colors(int tone, uint32_t *fg, uint32_t *bg)
{
    switch (tone) {
    case PROXY_BADGE_WARN:
        *fg = COLOR_AMBER; *bg = touchui_theme.warn_soft; break;
    case PROXY_BADGE_DANGER:
        *fg = COLOR_RED; *bg = touchui_theme.danger_soft; break;
    case PROXY_BADGE_NEUTRAL:
        *fg = COLOR_MUTED; *bg = COLOR_CARD_ALT; break;
    default:
        *fg = COLOR_ACCENT; *bg = COLOR_ACCENT_SOFT; break;
    }
}

/* 按钮配色：四种状态选择器（0 / PRESSED / CHECKED / CHECKED|PRESSED）写同一套
 * 颜色。原因有两条：
 *   1. 本页沿用「LV_STATE_PRESSED = 禁用」的旧机制，禁用与按下共用同一个位；
 *   2. LVGL 的状态选择器按匹配优先级排序，CHECKED|PRESSED 比 PRESSED 更具体，
 *      若只给 PRESSED 写禁用色，禁用按钮一旦进入 CHECKED 就会露回「可用」外观。
 * 全态同色可保证禁用态在任何组合下都是 .btn:disabled 的底色 + muted 字。 */
static void proxy_apply_button(lv_obj_t *button, lv_obj_t *label, int tone, int disabled)
{
    uint32_t bg, border, fg;
    if (!button) return;
    switch (tone) {
    case PROXY_BTN_DANGER:
        bg = touchui_theme.danger_soft; border = COLOR_RED; fg = COLOR_RED; break;
    case PROXY_BTN_PRIMARY:
        bg = COLOR_ACCENT; border = COLOR_ACCENT; fg = touchui_theme.accent_ink; break;
    case PROXY_BTN_GHOST_ACCENT:
        bg = COLOR_CARD; border = COLOR_ACCENT; fg = COLOR_ACCENT; break;
    default:
        bg = COLOR_CARD; border = COLOR_BORDER; fg = COLOR_TEXT; break;
    }
    if (disabled) {
        bg = COLOR_CARD_ALT;
        border = COLOR_BORDER;
        fg = COLOR_MUTED;
    }
    style_surface(button, bg, border, 10, 1);
    set_bg_color(button, bg, LV_STATE_PRESSED);
    set_border_color(button, border, LV_STATE_PRESSED);
    set_bg_color(button, bg, LV_STATE_CHECKED);
    set_border_color(button, border, LV_STATE_CHECKED);
    set_bg_color(button, bg, LV_STATE_CHECKED | LV_STATE_PRESSED);
    set_border_color(button, border, LV_STATE_CHECKED | LV_STATE_PRESSED);
    set_text_color(label, fg);
}

/* 右贴齐动态文本：内容没变就不重排（set_right_value 内部会 update_layout）。 */
static void proxy_set_right_text(lv_obj_t *label, const char *text)
{
    const char *current;
    if (!label) return;
    current = lv_label_get_text_p ? lv_label_get_text_p(label) : NULL;
    if (current && text && !strcmp(current, text)) return;
    set_right_value(label, text);
}

/* 按钮文字：只有文案变化才 setText + 重新居中，避免每 tick 触发 layout。 */
static void proxy_set_button_text(lv_obj_t *label, const char *text)
{
    const char *current;
    if (!label || !lv_label_set_text_p || !text) return;
    current = lv_label_get_text_p ? lv_label_get_text_p(label) : NULL;
    if (current && !strcmp(current, text)) return;
    lv_label_set_text_p(label, text);
    center_button_label(label);
}

/* 底部右栏只有约 180px：按估算宽度（汉字 14px、半角 7px）截断并补省略号。
 * 按 UTF-8 起始字节切分，不会切坏多字节字符。 */
static void proxy_short_text(char *out, size_t size, const char *text)
{
    size_t i = 0, written = 0, length;
    int width = 0;
    if (!out || size == 0) return;
    out[0] = '\0';
    if (!text) return;
    length = strlen(text);
    while (i < length && written + 5 < size) {
        unsigned char c = (unsigned char)text[i];
        size_t step = c < 0x80u ? 1u : (c < 0xE0u ? 2u : (c < 0xF0u ? 3u : 4u));
        int px = step == 1u ? 7 : 14;
        if (width + px > 172) break;
        if (i + step > length) break;
        memcpy(out + written, text + i, step);
        written += step;
        i += step;
        width += px;
    }
    out[written] = '\0';
    if (i < length && written + 4 < size) {
        memcpy(out + written, "\xE2\x80\xA6", 3);   /* U+2026 省略号 */
        out[written + 3] = '\0';
    }
}

/* 模式徽标：eBPF / TUN 两种数据面（对应 convert.py 的 ebpf / tun profile）。 */
static const char *proxy_mode_text(const struct singbox_status *status)
{
    if (!strcmp(status->inbound_mode, "ebpf")) return "eBPF 模式";
    return "TUN 模式";
}

/* 数据面字段只有 96px：把 capture_plane 的原始值（socket_assign / cgroup /
 * packet_rewrite / tun）翻成能放下的短词。 */
static const char *proxy_plane_text(const struct singbox_status *status)
{
    if (strstr(status->capture_plane, "socket_assign") ||
        strstr(status->capture_plane, "cgroup"))
        return "eBPF 接管";
    if (strstr(status->capture_plane, "packet_rewrite"))
        return "eBPF 改写";
    if (!strcmp(status->inbound_mode, "ebpf")) return "eBPF 接管";
    return "TUN 接管";
}

static void refresh_ui(void)
{
    struct singbox_status status;
    char message[160], shortmsg[64], text[192], sub[96];
    char rr[32], tr[32], rt[32], tt[32];
    const char *state_text, *badge_text, *hint_text, *note_text;
    const char *service_text, *restart_text, *fallback;
    int generation, running_action, action_running, on_mihomo, on_singbox;
    int state_tone, badge_tone, left_tone, style_key;
    int service_off, restart_off, to_singbox_off, to_mihomo_off;

    if (!manager_page) return;

    pthread_mutex_lock(&shared_lock);
    generation = shared_generation;
    if (generation == ui_generation) { pthread_mutex_unlock(&shared_lock); return; }
    status = shared_status;
    safe_copy(message, sizeof(message),
              shared_message_page == PAGE_SINGBOX ? shared_message : "");
    running_action = shared_action_running ? shared_running_action : shared_action;
    action_running = action_is_singbox(running_action) ||
                     action_is_engine(running_action);
    pthread_mutex_unlock(&shared_lock);
    ui_generation = generation;
    ui_status = status;

    /* 默认档（尚无数据）：与旧实现一样只显示占位，且不加锁 */
    state_text = "状态读取中…"; state_tone = PROXY_TONE_MUTED;
    badge_text = "读取中"; badge_tone = PROXY_BADGE_NEUTRAL;
    safe_copy(sub, sizeof(sub), "等待状态采集");
    hint_text = "正在等待状态采集，请稍候。";
    note_text = "等待状态";
    service_text = "启动服务"; left_tone = PROXY_BTN_GHOST;
    restart_text = "重启服务";
    fallback = "状态读取中";
    service_off = 0; restart_off = 0;
    to_singbox_off = 0; to_mihomo_off = 0;
    on_mihomo = 0; on_singbox = 0;

    if (!status.valid) {
        set_label_text_if_changed(version_label, "未知");
        set_label_text_if_changed(memory_label, "--");
        set_label_text_if_changed(tun_value_label, "未知");
        set_label_text_if_changed(dhcp_value_label, "未知");
        set_label_text_if_changed(providers_label, "--");
        set_label_text_if_changed(watchdog_label, "--");
        set_label_text_if_changed(keeper_label, "--");
        set_traffic_value(&traffic_rate_down, "--");
        set_traffic_value(&traffic_rate_up, "--");
        set_traffic_value(&traffic_total_down, "--");
        set_traffic_value(&traffic_total_up, "--");
        set_label_text_if_changed(updated_label, "更新于 --:--:--");
        proxy_short_text(shortmsg, sizeof(shortmsg),
                         action_running ? "正在执行，请稍候…" : fallback);
        proxy_set_right_text(message_label, shortmsg);
    } else {
        on_mihomo = status_is_mihomo(&status);
        on_singbox = status.service_running || !strcmp(status.engine, "sing-box");

        /* ---- 正常档（原型 ok）---- */
        state_text = "运行正常"; state_tone = PROXY_TONE_OK;
        badge_text = proxy_mode_text(&status); badge_tone = PROXY_BADGE_SOFT;
        snprintf(sub, sizeof(sub), "%s · 保活%s",
                 status.watchdog_running ? "看门狗守护" : "无看门狗",
                 status.keeper_running ? "开" : "关");
        hint_text = "切回 mihomo 会暂停服务；二次确认后执行。";
        note_text = "切换约 3 秒";
        fallback = "sing-box 运行中";

        if (status.stale) {
            /* 数据延迟：只压状态与徽标，字段继续展示上一份快照 */
            state_text = "数据延迟"; state_tone = PROXY_TONE_WARN;
            badge_text = "数据延迟"; badge_tone = PROXY_BADGE_WARN;
            safe_copy(sub, sizeof(sub), "数据未刷新 · 保留上次快照");
            hint_text = "状态数据延迟，操作前请先刷新。";
            note_text = "数据延迟";
            fallback = "数据延迟";
        } else if (on_mihomo) {
            if (!status.mihomo_running && !status.api_ok) {
                state_text = "mihomo 未启动"; state_tone = PROXY_TONE_DANGER;
                badge_text = "回滚中断"; badge_tone = PROXY_BADGE_DANGER;
                safe_copy(sub, sizeof(sub), "进程缺失 · DHCP 0.254 未对齐");
                hint_text = "进程缺失；可重试切回，或切到 sing-box。";
                note_text = "进程缺失，可重试";
                fallback = "mihomo 未启动";
            } else if (status.api_ok && status.capture_ok && status.dhcp_ok) {
                state_text = "mihomo 运行中"; state_tone = PROXY_TONE_OK;
                badge_text = "回滚态"; badge_tone = PROXY_BADGE_WARN;
                safe_copy(sub, sizeof(sub), "init 托管 · DHCP 0.254");
                hint_text = "回滚态只读；切回 sing-box 后恢复启停。";
                fallback = "mihomo 回滚态";
            } else if (status.api_ok) {
                state_text = "mihomo 未就绪"; state_tone = PROXY_TONE_WARN;
                badge_text = "回滚态"; badge_tone = PROXY_BADGE_WARN;
                safe_copy(sub, sizeof(sub), !status.dhcp_ok ?
                          "DHCP 未指向 0.254" : "数据面未接管");
                hint_text = "回滚态只读；切回 sing-box 后恢复启停。";
                note_text = "数据面异常";
                fallback = "mihomo 回滚态";
            } else {
                state_text = "mihomo 启动中"; state_tone = PROXY_TONE_WARN;
                badge_text = "回滚态"; badge_tone = PROXY_BADGE_WARN;
                safe_copy(sub, sizeof(sub), "核心启动中 · init 托管");
                hint_text = "回滚态只读；切回 sing-box 后恢复启停。";
                note_text = "正在启动";
                fallback = "正在启动…";
            }
        } else if (!status.service_running) {
            state_text = "服务已停止"; state_tone = PROXY_TONE_MUTED;
            badge_text = "直连模式"; badge_tone = PROXY_BADGE_NEUTRAL;
            safe_copy(sub, sizeof(sub), status.manual_stop ?
                      "手动停止 · 数据面未接管" : "服务未运行 · 数据面未接管");
            hint_text = !strcmp(status.inbound_mode, "ebpf") ?
                        "启动后恢复 eBPF 数据面与分流。" :
                        "启动后恢复 TUN 数据面与分流。";
            note_text = "可切回 mihomo";
            fallback = "服务已停止";
        } else if (!status.api_ok) {
            state_text = "正在启动…"; state_tone = PROXY_TONE_WARN;
            safe_copy(sub, sizeof(sub), "正在启动服务与数据面");
            hint_text = "正在切换状态，请稍候。";
            note_text = "正在启动";
            fallback = "正在启动…";
        } else if (!status.capture_ok) {
            state_text = "数据面未就绪"; state_tone = PROXY_TONE_WARN;
            safe_copy(sub, sizeof(sub), "数据面未接管 · 分流未生效");
            hint_text = "正在切换状态，请稍候。";
            note_text = "数据面异常";
            fallback = "数据面未就绪";
        } else if (!status.dhcp_ok) {
            state_text = "DHCP 未指向"; state_tone = PROXY_TONE_WARN;
            safe_copy(sub, sizeof(sub), "DHCP 未指向 192.168.0.1");
            hint_text = "正在切换状态，请稍候。";
            note_text = "DHCP 异常";
            fallback = "DHCP 未指向";
        }

        /* 左按钮（停止/启动）的语义与锁定，与改造前逐条一致 */
        if (on_mihomo) {
            service_text = "需先切回";
            restart_text = "需先切回";
            left_tone = PROXY_BTN_GHOST;
        } else {
            service_text = status.service_running ? "停止服务" : "启动服务";
            restart_text = "重启服务";
            left_tone = status.service_running ? PROXY_BTN_DANGER : PROXY_BTN_PRIMARY;
        }
        service_off = on_mihomo || action_running;
        restart_off = on_mihomo || action_running;
        to_singbox_off = action_running || on_singbox;
        to_mihomo_off = action_running ||
                        (on_mihomo && status.mihomo_running) ||
                        (!on_singbox && !on_mihomo);

        /* 动作进行中：状态压成原型的「进行中」档（启动中/重启中/切换中） */
        if (action_running) {
            state_tone = PROXY_TONE_WARN;
            if (action_is_engine(running_action)) {
                state_text = "切换中…";
                badge_text = "切换中"; badge_tone = PROXY_BADGE_WARN;
                safe_copy(sub, sizeof(sub), "正在切换核心与数据面");
                note_text = "正在切换，请稍候";
                service_text = "切换中…";
                restart_text = "切换中…";
                left_tone = PROXY_BTN_GHOST;
            } else if (running_action == ACTION_SERVICE_RESTART) {
                state_text = "正在重启…";
                safe_copy(sub, sizeof(sub), "正在重启服务与数据面");
                note_text = "正在重启";
                restart_text = "重启中…";
            } else if (running_action == ACTION_SERVICE_STOP) {
                state_text = "正在停止…";
                safe_copy(sub, sizeof(sub), "正在停止服务与数据面");
                note_text = "正在停止";
                service_text = "停止中…";
            } else {
                state_text = "正在启动…";
                safe_copy(sub, sizeof(sub), "正在启动服务与数据面");
                note_text = "正在启动";
                service_text = "启动中…";
            }
            hint_text = "正在切换状态，请稍候。";
            fallback = "正在执行，请稍候…";
        }

        /* ---- 2×2 字段：核心 / 内存 / 数据面 / DHCP ---- */
        if (status.version[0] && strcmp(status.version, "未知") != 0)
            set_label_text_if_changed(version_label, status.version);
        else if (on_mihomo)
            set_label_text_if_changed(version_label, "mihomo");
        else if (on_singbox)
            set_label_text_if_changed(version_label, "sing-box");
        else
            set_label_text_if_changed(version_label, "未知");

        if (status.rss_kb > 0) {
            snprintf(text, sizeof(text), "%.1f MB",
                     (double)status.rss_kb / 1024.0);
            set_label_text_if_changed(memory_label, text);
        } else {
            set_label_text_if_changed(memory_label, "--");
        }

        if (on_mihomo) {
            set_label_text_if_changed(tun_value_label,
                                      status.capture_ok ? "netns" :
                                      (status.mihomo_running ? "未就绪" : "无进程"));
            if (status.dhcp_points_to_mihomo || status.dhcp_ok)
                set_label_text_if_changed(dhcp_value_label,
                                          status.dhcp_ok ? "0.254" : "0.254 残缺");
            else
                set_label_text_if_changed(dhcp_value_label, "未对齐");
        } else if (!strcmp(status.inbound_mode, "ebpf")) {
            set_label_text_if_changed(tun_value_label,
                                      status.capture_ok ?
                                      proxy_plane_text(&status) : "未就绪");
            set_label_text_if_changed(dhcp_value_label,
                                      status.dhcp_ok ? "0.1" : "未对齐");
        } else {
            set_label_text_if_changed(tun_value_label,
                                      status.capture_ok ? "TUN 接管" : "未就绪");
            set_label_text_if_changed(dhcp_value_label,
                                      status.dhcp_ok ? "0.1" : "未对齐");
        }

        /* ---- 次级三格：订阅 / 看门狗 / 保活（两核都有对应物） ---- */
        snprintf(text, sizeof(text), "%d", status.providers);
        set_label_text_if_changed(providers_label, text);
        set_label_text_if_changed(watchdog_label,
                                  status.watchdog_running ? "开" : "关");
        set_label_text_if_changed(keeper_label,
                                  status.keeper_running ? "开" : "关");

        /* ---- 流量：实时 / 累计 ---- */
        if ((on_singbox || on_mihomo) && status.api_ok &&
            (status.rx_bytes || status.tx_bytes ||
             status.rx_rate || status.tx_rate)) {
            format_bytes(status.rx_rate, rr, sizeof(rr));
            format_bytes(status.tx_rate, tr, sizeof(tr));
            format_bytes(status.rx_bytes, rt, sizeof(rt));
            format_bytes(status.tx_bytes, tt, sizeof(tt));
            snprintf(text, sizeof(text), "%s/s", rr);
            set_traffic_value(&traffic_rate_down, text);
            snprintf(text, sizeof(text), "%s/s", tr);
            set_traffic_value(&traffic_rate_up, text);
            set_traffic_value(&traffic_total_down, rt);
            set_traffic_value(&traffic_total_up, tt);
        } else {
            set_traffic_value(&traffic_rate_down, "--");
            set_traffic_value(&traffic_rate_up, "--");
            set_traffic_value(&traffic_total_down, "--");
            set_traffic_value(&traffic_total_up, "--");
        }

        snprintf(text, sizeof(text), "更新于 %s",
                 status.updated[0] ? status.updated : "--:--:--");
        set_label_text_if_changed(updated_label, text);
        /* 原型的 pxMessage：执行中优先显示「正在执行，请稍候…」，
         * 结束后再显示 worker 回写的最终消息（shared_message）。 */
        proxy_short_text(shortmsg, sizeof(shortmsg),
                         action_running ? "正在执行，请稍候…" :
                         (message[0] ? message : fallback));
        proxy_set_right_text(message_label, shortmsg);
    }

    /* ---- 样式：只在色调/锁定组合或徽标文字变化时重设 ---- */
    style_key = state_tone | (badge_tone << 2) | (left_tone << 4) |
                (service_off << 8) | (restart_off << 9) |
                (to_singbox_off << 10) | (to_mihomo_off << 11);
    if (style_key != proxy_style_key ||
        strcmp(proxy_badge_text_cache, badge_text)) {
        uint32_t badge_fg, badge_bg;
        proxy_style_key = style_key;
        safe_copy(proxy_badge_text_cache, sizeof(proxy_badge_text_cache),
                  badge_text);
        proxy_badge_colors(badge_tone, &badge_fg, &badge_bg);
        set_badge(&proxy_mode_badge, badge_text, badge_fg, badge_bg);
        set_status_color(proxy_tone_color(state_tone));
        set_text_color(status_label, proxy_state_text_color(state_tone));
        proxy_apply_button(service_button, service_button_label,
                           left_tone, service_off);
        proxy_apply_button(restart_button, restart_button_label,
                           PROXY_BTN_GHOST, restart_off);
        proxy_apply_button(engine_to_singbox_button, engine_to_singbox_label,
                           PROXY_BTN_GHOST_ACCENT, to_singbox_off);
        proxy_apply_button(engine_to_mihomo_button, engine_to_mihomo_label,
                           PROXY_BTN_GHOST_ACCENT, to_mihomo_off);
    }

    /* ---- 锁定态（沿用旧机制：LV_STATE_PRESSED = 禁用；配色已在上方落好）---- */
    if (service_button && lv_obj_add_state_p && lv_obj_clear_state_p) {
        if (service_off) lv_obj_add_state_p(service_button, LV_STATE_PRESSED);
        else lv_obj_clear_state_p(service_button, LV_STATE_PRESSED);
    }
    if (restart_button && lv_obj_add_state_p && lv_obj_clear_state_p) {
        if (restart_off) lv_obj_add_state_p(restart_button, LV_STATE_PRESSED);
        else lv_obj_clear_state_p(restart_button, LV_STATE_PRESSED);
    }
    if (engine_to_singbox_button && lv_obj_add_state_p && lv_obj_clear_state_p) {
        if (to_singbox_off)
            lv_obj_add_state_p(engine_to_singbox_button, LV_STATE_PRESSED);
        else
            lv_obj_clear_state_p(engine_to_singbox_button, LV_STATE_PRESSED);
    }
    if (engine_to_mihomo_button && lv_obj_add_state_p && lv_obj_clear_state_p) {
        if (to_mihomo_off)
            lv_obj_add_state_p(engine_to_mihomo_button, LV_STATE_PRESSED);
        else
            lv_obj_clear_state_p(engine_to_mihomo_button, LV_STATE_PRESSED);
    }

    /* ---- 文本（每 tick 只做字符串比较）---- */
    set_label_text_if_changed(status_label, state_text);
    set_label_text_if_changed(status_mode_label, sub);
    set_label_text_if_changed(proxy_hint_label, hint_text);
    proxy_set_right_text(proxy_engine_note_label, note_text);
    proxy_set_button_text(service_button_label, service_text);
    proxy_set_button_text(restart_button_label, restart_text);
    proxy_set_button_text(engine_to_singbox_label,
                          action_is_engine(running_action) ?
                          "切换中…" : "切到 sing-box");
    proxy_set_button_text(engine_to_mihomo_label,
                          action_is_engine(running_action) ?
                          "切换中…" : "切回 mihomo");
    /* 旧版把 CHECKED 当作「服务运行中」；新皮改为按状态上色，勾选态统一清掉，
     * 免得松手后残留勾选底色。 */
    set_checked(service_button, 0);
}
