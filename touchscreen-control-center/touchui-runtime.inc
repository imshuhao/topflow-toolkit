static int resolve_lvgl(void)
{
#define RESOLVE(name) name##_p = (void *)dlsym(RTLD_NEXT, #name)
    RESOLVE(lv_disp_get_default); RESOLVE(lv_disp_get_layer_top); RESOLVE(lv_disp_get_scr_act);
    RESOLVE(lv_obj_create); RESOLVE(lv_obj_del); RESOLVE(lv_obj_get_child_cnt); RESOLVE(lv_obj_get_child);
    RESOLVE(lv_obj_has_flag);
    RESOLVE(lv_btn_create); RESOLVE(lv_label_create); RESOLVE(lv_label_set_text);
    RESOLVE(lv_label_get_text);
    RESOLVE(lv_img_create); RESOLVE(lv_img_set_src); RESOLVE(lv_img_set_zoom);
    RESOLVE(lv_imgbtn_create); RESOLVE(lv_imgbtn_set_src);
    RESOLVE(lv_label_set_long_mode); RESOLVE(lv_obj_set_size); RESOLVE(lv_obj_set_pos);
    RESOLVE(lv_obj_align); RESOLVE(lv_obj_update_layout); RESOLVE(lv_obj_add_event_cb); RESOLVE(lv_obj_add_flag);
    RESOLVE(lv_obj_clear_flag); RESOLVE(lv_obj_add_state); RESOLVE(lv_obj_clear_state);
    RESOLVE(lv_obj_move_foreground); RESOLVE(lv_obj_invalidate);
    RESOLVE(lv_obj_set_scrollbar_mode);
    RESOLVE(lv_obj_set_style_radius); RESOLVE(lv_obj_set_style_border_width);
    RESOLVE(lv_obj_set_style_shadow_width);
    RESOLVE(lv_obj_set_style_pad_left); RESOLVE(lv_obj_set_style_pad_right);
    RESOLVE(lv_obj_set_style_pad_top); RESOLVE(lv_obj_set_style_pad_bottom);
    RESOLVE(lv_obj_set_style_text_align);
    RESOLVE(lv_obj_set_style_bg_color); RESOLVE(lv_obj_set_style_bg_opa);
    RESOLVE(lv_obj_set_style_border_color); RESOLVE(lv_obj_set_style_shadow_color);
    RESOLVE(lv_obj_set_style_shadow_opa); RESOLVE(lv_obj_set_style_text_color);
    RESOLVE(lv_chart_create); RESOLVE(lv_chart_set_type);
    RESOLVE(lv_chart_set_point_count); RESOLVE(lv_chart_set_range);
    RESOLVE(lv_chart_add_series); RESOLVE(lv_chart_set_next_value);
    RESOLVE(lv_chart_refresh);
    RESOLVE(lv_obj_check_type); RESOLVE(lv_obj_get_coords);
    RESOLVE(lv_obj_get_parent);
    lv_label_class_p = dlsym(RTLD_NEXT, "lv_label_class");
    real_obj_set_style_text_font = (obj_set_style_text_font_fn)
        dlsym(RTLD_NEXT, "lv_obj_set_style_text_font");
    lv_ft_font_init_p = (ft_font_init_fn)dlsym(RTLD_NEXT, "lv_ft_font_init");
#undef RESOLVE
    return lv_disp_get_default_p && lv_disp_get_layer_top_p && lv_obj_create_p && lv_obj_del_p && lv_btn_create_p &&
           lv_label_create_p && lv_label_set_text_p && lv_img_create_p && lv_img_set_src_p &&
           lv_obj_set_size_p && lv_obj_set_pos_p &&
           lv_obj_align_p && lv_obj_add_event_cb_p && lv_obj_add_flag_p && lv_obj_clear_flag_p &&
           lv_obj_add_state_p && lv_obj_clear_state_p && lv_obj_set_style_bg_color_p &&
           lv_obj_set_style_bg_opa_p && lv_obj_set_style_border_color_p &&
           lv_obj_set_style_text_color_p;
}

static void trace_ui_create(const char *stage)
{
    FILE *log = fopen("/tmp/touchui-create.log", "a");
    if (!log) return;
    fprintf(log, "%s\n", stage);
    fclose(log);
}

static void refresh_menu_home_status(void);
static int create_menu_page(lv_obj_t *top);
static void destroy_menu_page(void);
static int pending_theme_rebuild;

/* 悬浮入口配色：浅强调底 + 强调边 + 强调字。原来的 accent_dark 实底在日间
 * 与背景几乎同色，按钮会"消失"在壁纸里。label 通过子对象取，不改 make_button。 */
static void style_launcher_button(void)
{
    lv_obj_t *label;
    if (!control_center_button) return;
    style_button(control_center_button, COLOR_ACCENT_SOFT, COLOR_BUTTON_PRESSED,
                 COLOR_ACCENT_SOFT, COLOR_ACCENT);
    label = lv_obj_get_child_p ? lv_obj_get_child_p(control_center_button, 0) : NULL;
    if (label) set_text_color(label, COLOR_ACCENT);
}

/* 主题切换：不在按钮回调里删对象（LVGL 事件链仍持有它），置标记后由
 * lv_timer_handler 重建状态栏 + 首页，并让所有子页在下次打开时按新配色重建。 */
static void open_theme_clicked(void *event)
{
    (void)event;
    pending_theme_rebuild = 1;
}

static void process_theme_rebuild(void)
{
    lv_obj_t *top;
    if (!pending_theme_rebuild) return;
    pending_theme_rebuild = 0;
    if (!lv_disp_get_default_p || !lv_disp_get_layer_top_p) return;
    top = lv_disp_get_layer_top_p(lv_disp_get_default_p());
    if (!top) return;
    touchui_theme_toggle();
    destroy_menu_page();
    destroy_statusbar();
    glyph_pool_reset();
    /* 流量箭头是静态位图：主题变了必须重画，否则日/夜切换后仍是旧颜色 */
    reset_traffic_icons();
    style_launcher_button();
    if (!create_statusbar(top) || !create_menu_page(top)) return;
    /* 子页（含其确认弹层）全部按新配色重建 */
    destroy_singbox_page();
    destroy_wanbal_page();
    destroy_balance_page();
    destroy_charge_page();
    destroy_network_identity();
    destroy_network_detail();
    destroy_network_overview();
    destroy_device_pages();
    show_page(PAGE_MENU);
    pthread_mutex_lock(&shared_lock);
    force_refresh = 1;
    force_network_refresh = 1;
    force_wanbal_refresh = 1;
    force_balance_refresh = 1;
    shared_generation++;
    pthread_mutex_unlock(&shared_lock);
}

static void menu_empty_clicked(void *event) { (void)event; }

/* ---- 首页九宫格几何（对齐原型 .grid / .tile） -------------------------
 * 格子 96×96、圆角 12、间距 8；九宫格从页头下 36px 起（原型 margin-top: 36）。
 * root 内首行 y=80，三行结束于 384；底部状态行 408..428（root 高 440），一屏放得下。 */
#define MENU_GRID_X 8
#define MENU_GRID_Y (TOUCHUI_HEAD_H + 36)
#define MENU_TILE_PITCH 104
#define MENU_TILE_ICON_Y 18      /* 图标 24px：18..42 */
#define MENU_TILE_NAME_Y 54      /* 名称 16px：54 起，与图标间距 12（原型 gap 7 + 字体行高留白） */

/* 状态行：圆点 + 加重文案 + 「· 模式 · 卡数」；格底 root y=384，状态行 408..428 */
#define MENU_STATUS_Y 408
#define MENU_STATUS_LINE_H 20
#define MENU_STATUS_DOT_X 9
#define MENU_STATUS_TEXT_X 19
#define MENU_STATUS_GAP 6

/* 首页状态行 / 代理格圆点的配色口径（文案见 refresh_menu_home_status）：
 *   未读到数据 → muted「代理未知」；stale → warn「数据延迟」；
 *   mihomo 回滚 → warn「mihomo 回滚态 · netns · DHCP 0.254」；
 *   sing-box 运行且 api/capture/dhcp 都就绪 → ok「代理运行中 · eBPF|TUN · DHCP 0.1」；
 *   未运行 → muted「代理已停止 · 直连」；其余（启动中 / 数据面未就绪）→ warn。 */

static lv_obj_t *menu_home_dot;          /* 状态行圆点（新增） */
static lv_obj_t *menu_home_detail_label; /* 状态行「· eBPF · DHCP 0.1 · 三卡在线」（新增） */
static uint32_t menu_home_tone_cached;   /* 上次圆点色，避免每帧重设样式 */
static int menu_home_tone_valid;
static char menu_home_service_cached[64]; /* 上次加重文案，用于判断是否需要重排 */
static char menu_home_detail_cached[96];  /* 上次 detail 文案 */
static uint32_t menu_home_strong_cached;  /* 上次加重文案颜色 */
static int menu_home_strong_valid;

/* 取 label 的像素宽度（Vendor FreeType 下 label 自适应，只能靠 coords 量）。
 * 量不到时按字符数估算（CJK 按 14px、ASCII 按 7px），保证排版不会挤成一团。 */
static int menu_label_width(lv_obj_t *label)
{
    lv_area_compat_t area;
    const char *text;
    int width = 0;
    if (!label) return 0;
    if (lv_obj_get_coords_p && lv_obj_update_layout_p) {
        lv_obj_update_layout_p(label);
        memset(&area, 0, sizeof(area));
        lv_obj_get_coords_p(label, &area);
        if (area.x2 >= area.x1) return area.x2 - area.x1 + 1;
    }
    text = lv_label_get_text_p ? lv_label_get_text_p(label) : NULL;
    while (text && *text) {
        unsigned char c = (unsigned char)*text;
        if (c < 0x80) { width += 7; text++; }
        else { width += 14; text++; while ((*text & 0xc0) == 0x80) text++; }
    }
    return width;
}

/* 把一个名称 label 摆到格子里「图标下方、水平居中」（原型 .tile 的 column 布局）。 */
static void place_menu_tile_label(lv_obj_t *label, int y, const void *font)
{
    if (!label) return;
    if (font && real_obj_set_style_text_font)
        real_obj_set_style_text_font(label, font, 0);
    if (lv_obj_update_layout_p) lv_obj_update_layout_p(label);
    lv_obj_align_p(label, LV_ALIGN_TOP_MID, 0, y);
}

/* 图标：24px 水平居中、y=18（原型图标 26px 居中、与名称 gap 7）。
 * 按钮/面板都有 1px 描边，用 align 让 LVGL 按内容区居中，比硬算 x 更准。 */
static void place_menu_tile_icon(lv_obj_t *tile, const char *const *glyph,
                                 uint32_t color)
{
    lv_obj_t *icon;
    if (!tile || !glyph) return;
    icon = make_glyph_icon(tile, 0, 0, glyph, color);
    if (!icon) return;
    lv_obj_align_p(icon, LV_ALIGN_TOP_MID, 0, MENU_TILE_ICON_Y);
}

static lv_obj_t *make_menu_tile(lv_obj_t *parent, const char *name,
                                const char *const *glyph, int col, int row,
                                void (*open)(void *event), int is_empty,
                                lv_obj_t **name_out)
{
    int x = MENU_GRID_X + col * MENU_TILE_PITCH;
    int y = MENU_GRID_Y + row * MENU_TILE_PITCH;
    lv_obj_t *tile, *label;

    if (is_empty) {
        /* 空位：透明底 + 1px 边框（本 LVGL 无虚线，用细边框表示） + muted 图标/名称 */
        tile = make_panel(parent, x, y, 96, 96, COLOR_BG);
        if (!tile) return NULL;
        style_surface(tile, COLOR_BG, COLOR_BORDER, 12, 1);
        if (lv_obj_set_style_bg_opa_p)
            lv_obj_set_style_bg_opa_p(tile, LV_OPA_TRANSP, 0);
        label = make_single_line_label(tile, name, 0, 0, 0, 0);
        set_text_color(label, COLOR_MUTED);
        place_menu_tile_label(label, MENU_TILE_NAME_Y, ui_font_small);
        place_menu_tile_icon(tile, glyph, COLOR_MUTED);
        if (name_out) *name_out = label;
        return tile;
    }

    tile = make_button(parent, name, x, y, 96, 96, open ? open : menu_empty_clicked,
                       &label);
    if (!tile) return NULL;
    style_button(tile, COLOR_CARD, COLOR_BUTTON_PRESSED, COLOR_CARD, COLOR_ACCENT);
    /* 原型 .tile 圆角 12（style_button 默认 10） */
    if (lv_obj_set_style_radius_p)
        lv_obj_set_style_radius_p(tile, 12, 0);
    set_text_color(label, COLOR_TEXT);
    place_menu_tile_label(label, MENU_TILE_NAME_Y, ui_font_small);
    place_menu_tile_icon(tile, glyph, COLOR_ACCENT);
    if (name_out) *name_out = label;
    return tile;
}

/* 首页整页销毁（主题重建用）；所有首页静态指针在这里归零。 */
static void destroy_menu_page(void)
{
    if (menu_page && lv_obj_del_p) lv_obj_del_p(menu_page);
    menu_page = NULL;
    memset(&menu_shell, 0, sizeof(menu_shell));
    memset(menu_tiles, 0, sizeof(menu_tiles));
    memset(menu_tile_empty, 0, sizeof(menu_tile_empty));
    menu_proxy_dot = NULL;
    menu_home_status_label = NULL;
    menu_home_detail_label = NULL;
    menu_home_dot = NULL;
    menu_theme_tile_label = NULL;
    menu_device_alert_badge = NULL;
    menu_device_alert_label = NULL;
    menu_home_tone_cached = 0;
    menu_home_tone_valid = 0;
    menu_home_service_cached[0] = '\0';
    menu_home_detail_cached[0] = '\0';
    menu_home_strong_cached = 0;
    menu_home_strong_valid = 0;
}

/* 首页状态行：圆点 + 加重文案 + 「· 模式 · 卡数」。
 * ui_status 只在代理页打开时才刷新，所以这里自己加锁拷贝 shared_status；
 * 每 tick 都会调用，因此文案用 set_label_text_if_changed、颜色用缓存比较。 */
static void refresh_menu_home_status(void)
{
    struct singbox_status status;
    char service[64], detail[96], cards[24];
    const char *mode = NULL;
    uint32_t tone, strong;
    int online = -1, i;

    if (!menu_home_status_label) return;

    pthread_mutex_lock(&shared_lock);
    status = shared_status;
    pthread_mutex_unlock(&shared_lock);

    /* 在线卡数：ui_network_status 由网络 worker 每秒刷新，首页直接读 */
    if (ui_network_status.valid) {
        online = 0;
        for (i = 0; i < NETWORK_MODEM_COUNT; i++) {
            const struct modem_status *modem = &ui_network_status.modems[i];
            if (modem->valid && modem->online) online++;
        }
    }
    if (online == NETWORK_MODEM_COUNT) safe_copy(cards, sizeof(cards), "三卡在线");
    else if (online == 2) safe_copy(cards, sizeof(cards), "两卡在线");
    else if (online == 1) safe_copy(cards, sizeof(cards), "一卡在线");
    else if (online == 0) safe_copy(cards, sizeof(cards), "无卡在线");
    else safe_copy(cards, sizeof(cards), "卡状态读取中");

    /* 状态 → 文案 / 圆点配色，映射口径与 touchui-singbox.inc 的 refresh_ui 一致；
     * 只有「模式」有明确值时才放进 detail（异常态的中文已经在加重文案里）。
     * strong 决定加重文案的颜色：正常 = 正文色，停止/未知 = muted，其余 = warn。 */
    strong = COLOR_AMBER;
    if (!status.valid) {
        tone = COLOR_MUTED;
        strong = COLOR_MUTED;
        safe_copy(service, sizeof(service), "代理未知");
    } else if (status.stale) {
        tone = COLOR_AMBER;
        safe_copy(service, sizeof(service), "数据延迟");
    } else if (!strcmp(status.engine, "mihomo") || status.mihomo_running) {
        tone = COLOR_AMBER;
        safe_copy(service, sizeof(service),
                  status.service_running ? "mihomo 回滚态" : "mihomo 未启动");
        mode = "netns · DHCP 0.254";
    } else if (!status.service_running) {
        tone = COLOR_MUTED;
        strong = COLOR_MUTED;
        safe_copy(service, sizeof(service), "代理已停止");
        mode = "直连";
    } else if (!status.api_ok) {
        tone = COLOR_AMBER;
        safe_copy(service, sizeof(service), "核心启动中");
    } else if (!status.capture_ok) {
        tone = COLOR_AMBER;
        safe_copy(service, sizeof(service), "数据面未就绪");
    } else if (!status.dhcp_ok) {
        tone = COLOR_AMBER;
        safe_copy(service, sizeof(service), "DHCP 未指向");
    } else {
        tone = COLOR_GREEN;
        strong = COLOR_TEXT;
        safe_copy(service, sizeof(service), "代理运行中");
        mode = !strcmp(status.inbound_mode, "ebpf") ||
               strstr(status.capture_plane, "ebpf") ||
               strstr(status.capture_plane, "eBPF") ? "eBPF · DHCP 0.1" :
               status.tun_up ? "TUN · DHCP 0.1" : "DHCP 0.1";
    }

    /* 代理格圆点与状态行圆点同色；只在 tone 变化时重设（每 tick 调用） */
    if (!menu_home_tone_valid || menu_home_tone_cached != tone) {
        menu_home_tone_cached = tone;
        menu_home_tone_valid = 1;
        if (menu_proxy_dot) set_dot_color(menu_proxy_dot, tone);
        if (menu_home_dot) set_dot_color(menu_home_dot, tone);
    }

    /* detail = 「· 模式 · 卡数」；异常态没有明确模式时只留卡数，避免「· -- ·」。 */
    if (mode)
        snprintf(detail, sizeof(detail), "· %s · %s", mode, cards);
    else
        snprintf(detail, sizeof(detail), "· %s", cards);

    /* 文案没变就只更新圆点，不做重排（每 tick 都会进来）。 */
    if (menu_home_strong_valid &&
        strong == menu_home_strong_cached &&
        !strcmp(service, menu_home_service_cached) &&
        !strcmp(detail, menu_home_detail_cached))
        return;
    safe_copy(menu_home_service_cached, sizeof(menu_home_service_cached), service);
    safe_copy(menu_home_detail_cached, sizeof(menu_home_detail_cached), detail);
    menu_home_strong_cached = strong;
    menu_home_strong_valid = 1;

    set_label_text_if_changed(menu_home_status_label, service);
    set_text_color(menu_home_status_label, strong);

    /* 两个 label 都是自适应宽度，量出来顺排（原型 .home-status 是 flex 排列）。
     * label 不设固定宽度（vendor FreeType 下 CLIP 会裁字），先按完整文案量，
     * 超出右边界就退一步只留卡数。 */
    if (menu_home_status_label && menu_home_detail_label) {
        int line_h = font_line_height(ui_font_tiny);
        int text_y, shift, detail_x, avail;
        if (line_h <= 0) line_h = MENU_STATUS_LINE_H;
        text_y = MENU_STATUS_Y + (MENU_STATUS_LINE_H - line_h) / 2;
        if (text_y < MENU_STATUS_Y) text_y = MENU_STATUS_Y;
        lv_obj_set_pos_p(menu_home_status_label, MENU_STATUS_TEXT_X, text_y);

        shift = menu_label_width(menu_home_status_label);
        if (shift < 1) shift = 1;
        detail_x = MENU_STATUS_TEXT_X + shift + MENU_STATUS_GAP;
        avail = 320 - 8 - detail_x;
        set_label_text_if_changed(menu_home_detail_label, detail);
        if (avail >= 24 && menu_label_width(menu_home_detail_label) > avail) {
            /* 放不下就只留卡数；缓存仍保留完整模板，避免每帧重排 */
            snprintf(detail, sizeof(detail), "· %s", cards);
            set_label_text_if_changed(menu_home_detail_label, detail);
        }
        set_text_color(menu_home_detail_label, COLOR_MUTED);
        lv_obj_set_pos_p(menu_home_detail_label, detail_x, text_y);
    }
}

static int create_menu_page(lv_obj_t *top)
{
    lv_obj_t *tile, *name_label;
    struct badge_component alert_badge;
    int idx = 0;

    if (!page_shell_init(&menu_shell, top, PAGE_MENU, "控制中心",
                         close_menu_clicked)) return 0;
    menu_page = menu_shell.root;
    memset(menu_tiles, 0, sizeof(menu_tiles));
    memset(menu_tile_empty, 0, sizeof(menu_tile_empty));
    menu_proxy_dot = NULL;
    menu_home_status_label = NULL;
    menu_home_detail_label = NULL;
    menu_home_dot = NULL;
    menu_theme_tile_label = NULL;
    menu_device_alert_badge = NULL;
    menu_device_alert_label = NULL;
    menu_home_tone_cached = 0;
    menu_home_tone_valid = 0;
    menu_home_service_cached[0] = '\0';
    menu_home_detail_cached[0] = '\0';
    menu_home_strong_cached = 0;
    menu_home_strong_valid = 0;

    /* 九宫格：网络/代理/分流 · 余量/设备/充电 · 主题/空位/空位
     * 每格 = 24px accent 线稿图标（y 18）+ 16px 名称（y 54）。 */
    tile = make_menu_tile(menu_page, "网络", glyph_network_24, 0, 0,
                          open_network_clicked, 0, NULL);
    if (!tile) return 0;
    menu_tiles[idx++] = tile;

    tile = make_menu_tile(menu_page, "代理", glyph_proxy_24, 1, 0,
                          open_singbox_clicked, 0, NULL);
    if (!tile) return 0;
    menu_tiles[idx++] = tile;
    /* 右上角 6px 圆点（原型 .tile-dot 的 top:8 / right:8）：颜色由
     * refresh_menu_home_status 按状态机涂 */
    menu_proxy_dot = make_dot(tile, 96 - 8 - 6, 8, 6, COLOR_GREEN);

    tile = make_menu_tile(menu_page, "分流", glyph_wanbal_24, 2, 0,
                          open_wanbal_clicked, 0, NULL);
    if (!tile) return 0;
    menu_tiles[idx++] = tile;

    tile = make_menu_tile(menu_page, "余量", glyph_balance_24, 0, 1,
                          open_balance_clicked, 0, NULL);
    if (!tile) return 0;
    menu_tiles[idx++] = tile;

    tile = make_menu_tile(menu_page, "设备", glyph_device_24, 1, 1,
                          open_device_clicked, 0, NULL);
    if (!tile) return 0;
    menu_tiles[idx++] = tile;
    /* 「N项」小徽标：右上角、右边距 8（与代理圆点右缘对齐；原型 .tile-tag）。
     * 指针名被 touchui-device.inc 的 refresh_device_ui 使用，必须继续指向
     * badge 的 panel/label（它自己会改文字与描边）。 */
    alert_badge = make_badge(tile, 96 - 8 - 30, 6, 30, 16, "正常", COLOR_GREEN,
                             touchui_theme.ok_soft, ui_font_tiny);
    menu_device_alert_badge = alert_badge.panel;
    menu_device_alert_label = alert_badge.label;

    tile = make_menu_tile(menu_page, "充电", glyph_charge_24, 2, 1,
                          open_charge_clicked, 0, NULL);
    if (!tile) return 0;
    menu_tiles[idx++] = tile;

    /* 主题格：名称固定「主题」，图标按当前主题选太阳 / 月亮（原型如此） */
    tile = make_menu_tile(menu_page, "主题",
                          touchui_theme_is_day ? glyph_sun_24 : glyph_moon_24,
                          0, 2, open_theme_clicked, 0, &name_label);
    if (!tile) return 0;
    menu_tiles[idx++] = tile;
    menu_theme_tile_label = name_label;

    tile = make_menu_tile(menu_page, "空位", glyph_plus_24, 1, 2, NULL, 1, NULL);
    if (!tile) return 0;
    menu_tile_empty[idx] = 1;
    menu_tiles[idx++] = tile;

    tile = make_menu_tile(menu_page, "空位", glyph_plus_24, 2, 2, NULL, 1, NULL);
    if (!tile) return 0;
    menu_tile_empty[idx] = 1;
    menu_tiles[idx++] = tile;

    /* 底部状态行（原型 .home-status）：圆点 + 加重文案，右侧 detail 由
     * refresh_menu_home_status 按实测宽度顺排。 */
    menu_home_dot = make_dot(menu_page, MENU_STATUS_DOT_X,
                             MENU_STATUS_Y + 7, 6, COLOR_MUTED);
    menu_home_status_label = make_single_line_label(menu_page, "代理未知",
                                                    MENU_STATUS_TEXT_X,
                                                    MENU_STATUS_Y, 0,
                                                    MENU_STATUS_LINE_H);
    if (menu_home_status_label && ui_font_tiny && real_obj_set_style_text_font)
        real_obj_set_style_text_font(menu_home_status_label, ui_font_tiny, 0);
    set_text_color(menu_home_status_label, COLOR_MUTED);
    menu_home_detail_label = make_single_line_label(menu_page, "", 0,
                                                    MENU_STATUS_Y, 0,
                                                    MENU_STATUS_LINE_H);
    if (menu_home_detail_label && ui_font_tiny && real_obj_set_style_text_font)
        real_obj_set_style_text_font(menu_home_detail_label, ui_font_tiny, 0);
    set_text_color(menu_home_detail_label, COLOR_MUTED);
    return 1;
}

static void add_control_center_ui(void)
{
    lv_obj_t *top;
    pthread_t worker;
    pthread_attr_t worker_attr;
    FILE *font_log;
    overlay_state = -1;
    unlink("/tmp/touchui-create.log");
    trace_ui_create("begin");
    touchui_theme_load();
    if (!resolve_lvgl() || !(top = lv_disp_get_layer_top_p(lv_disp_get_default_p()))) return;
    trace_ui_create("lvgl-ready");
    if (!ui_font) {
        /* 字体只初始化一次：失败重试路径不重复 init，防泄漏（M18） */
        ui_font_info.font = NULL;
        if (lv_ft_font_init_p && lv_ft_font_init_p(&ui_font_info))
            ui_font = ui_font_info.font;
        else
            ui_font = dlsym(RTLD_NEXT, "lv_font_simsun_16_cjk");
        ui_font_tiny_info.font = NULL;
        if (lv_ft_font_init_p && lv_ft_font_init_p(&ui_font_tiny_info))
            ui_font_tiny = ui_font_tiny_info.font;
        else
            ui_font_tiny = ui_font;
        ui_font_small_info.font = NULL;
        if (lv_ft_font_init_p && lv_ft_font_init_p(&ui_font_small_info))
            ui_font_small = ui_font_small_info.font;
        else
            ui_font_small = ui_font;
        ui_font_large_info.font = NULL;
        if (lv_ft_font_init_p && lv_ft_font_init_p(&ui_font_large_info))
            ui_font_large = ui_font_large_info.font;
        else
            ui_font_large = ui_font;
        ui_font_xlarge_info.font = NULL;
        if (lv_ft_font_init_p && lv_ft_font_init_p(&ui_font_xlarge_info))
            ui_font_xlarge = ui_font_xlarge_info.font;
        else
            ui_font_xlarge = ui_font_large;
    }
    font_log = fopen("/tmp/touchui-font.log", "w");
    if (font_log) {
        fprintf(font_log, "source=%s line_height=%d tiny_line_height=%d small_line_height=%d large_line_height=%d xlarge_line_height=%d theme=%s\n",
                ui_font_info.font ? "zte-freetype" : "simsun-fallback",
                ui_font ? font_line_height(ui_font) : 0,
                ui_font_tiny ? font_line_height(ui_font_tiny) : 0,
                ui_font_small ? font_line_height(ui_font_small) : 0,
                ui_font_large ? font_line_height(ui_font_large) : 0,
                ui_font_xlarge ? font_line_height(ui_font_xlarge) : 0,
                touchui_theme_is_day ? "day" : "night");
        fclose(font_log);
    }
    if (!control_center_button) {
        /* 按钮只创建一次：失败重试路径不重复创建（M18） */
        control_center_button = make_button(top, "控制中心", 204, 424, 104, 42,
                                            open_menu_clicked, NULL);
        if (!control_center_button) return;
    }
    trace_ui_create("launcher-ready");
    style_launcher_button();
    if (!statusbar_root && !create_statusbar(top)) return;
    trace_ui_create("statusbar-ready");
    if (!menu_page && !create_menu_page(top)) return;
    trace_ui_create("menu-ready");
    network_parent = top;
    trace_ui_create("network-deferred");
    /* The hook is already mapped. Do not preload it into manager commands or
     * the many UCI, ubus, curl and jsonfilter processes they launch. */
    unsetenv("LD_PRELOAD");
    if (!worker_started) {
        pthread_attr_init(&worker_attr);
        pthread_attr_setstacksize(&worker_attr, STATUS_WORKER_STACK_SIZE);
        if (pthread_create(&worker, &worker_attr, status_worker, NULL) == 0) {
            pthread_detach(worker);
            worker_started = 1;
        }
        pthread_attr_destroy(&worker_attr);
    }
    current_page = PAGE_STOCK;
    overlay_state = 1;
    trace_ui_create("complete");
    native_lock_state = -1;
    sync_native_lock_visibility();
}

uint32_t lv_timer_handler(void)
{
    uint32_t wait_ms = 5;
    if (!real_timer_handler) real_timer_handler = (timer_handler_fn)dlsym(RTLD_NEXT, "lv_timer_handler");
    if (real_timer_handler) wait_ms = real_timer_handler();
    if (overlay_state == 0 && ++timer_calls >= 20) add_control_center_ui();
    else if (overlay_state == -1 && ++timer_calls >= 2000) {
        /* 注入失败：低频退避重试（M18 复核——原实现失败后永不重试，UI 静默缺失；
         * 2000 tick ≈ 10s 有界退避，成功即置 1 停止，非每 tick 自旋） */
        timer_calls = 0;
        add_control_center_ui();
    }
    if (overlay_state == 1) {
        process_theme_rebuild();
        process_network_navigation();
        process_device_navigation();
        refresh_ui();
        refresh_wanbal_ui();
        refresh_balance_ui();
        refresh_charge_ui();
        refresh_network_ui();
        refresh_wifi_power_ui();
        refresh_page_clocks();
        refresh_menu_home_status();
        sync_native_lock_visibility();
        patch_stock_speed_page();
    }
    return wait_ms;
}

int mu5252_touchui_overlay_state(void) { return overlay_state; }
