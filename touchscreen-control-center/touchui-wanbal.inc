static lv_obj_t *wanbal_summary_label;
static lv_obj_t *wanbal_detail_label;
static lv_obj_t *wanbal_auto_button, *wanbal_shared_button;
static lv_obj_t *wanbal_auto_label, *wanbal_shared_label;
static lv_obj_t *wanbal_message_label;
static struct page_shell wanbal_shell;

static void wanbal_mode_label(const char *preset, char *out, size_t size)
{
    if (!strcmp(preset, "auto"))
        safe_copy(out, size, "自动·质量");
    else if (!strcmp(preset, "shared"))
        safe_copy(out, size, "三卡共池");
    else if (!strcmp(preset, "game"))
        safe_copy(out, size, "游戏硬绑");
    else if (!strcmp(preset, "custom"))
        safe_copy(out, size, "自定义");
    else
        safe_copy(out, size, "未知");
}

static void wanbal_detail_text(const struct wanbal_status *st, char *out, size_t size)
{
    if (!st->valid) {
        safe_copy(out, size, "读取中…");
        return;
    }
    if (st->degraded[0]) {
        snprintf(out, size, "降权:%s", st->degraded);
        return;
    }
    if (!strcmp(st->preset, "auto")) {
        if (st->tcp_weights[0])
            snprintf(out, size, "TCP %s", st->tcp_weights);
        else
            safe_copy(out, size, "质量加权·弱网可溢出");
        return;
    }
    if (!strcmp(st->preset, "shared") || !strcmp(st->mode, "shared")) {
        if (st->tcp_weights[0])
            snprintf(out, size, "权重 %s", st->tcp_weights);
        else
            safe_copy(out, size, "TCP+UDP 共池：5G+双4G");
        return;
    }
    if (!strcmp(st->preset, "game")) {
        safe_copy(out, size, "硬绑 TCP→5G · UDP→双4G");
        return;
    }
    snprintf(out, size, "MODE=%s", st->mode[0] ? st->mode : "-");
}

static int action_is_wanbal(int action)
{
    return action == ACTION_WAN_MODE_AUTO || action == ACTION_WAN_MODE_SHARED;
}

static void refresh_wanbal_ui(void)
{
    struct wanbal_status status;
    char message[160], title[48], detail[96];
    int generation, action_running;
    int is_auto, is_shared;
    if (!wanbal_page) return;
    pthread_mutex_lock(&shared_lock);
    generation = shared_wanbal_generation + shared_generation;
    if (generation == ui_wanbal_generation) {
        pthread_mutex_unlock(&shared_lock);
        return;
    }
    status = shared_wanbal_status;
    safe_copy(message, sizeof(message),
              shared_message_page == PAGE_WANBAL ? shared_message : "");
    action_running = action_is_wanbal(shared_action_running ?
                                      shared_running_action : shared_action);
    pthread_mutex_unlock(&shared_lock);
    ui_wanbal_generation = generation;
    ui_wanbal_status = status;

    wanbal_mode_label(status.valid ? status.preset : "", title, sizeof(title));
    wanbal_detail_text(&status, detail, sizeof(detail));
    set_label_text_if_changed(wanbal_summary_label,
                              status.valid ? title : "读取中…");
    set_label_text_if_changed(wanbal_detail_label, detail);
    if (wanbal_shell.clock_label)
        set_label_text_if_changed(wanbal_shell.clock_label,
                                  status.valid ? status.updated : "--:--:--");

    is_auto = status.valid && !strcmp(status.preset, "auto");
    is_shared = status.valid && !strcmp(status.preset, "shared");
    set_checked(wanbal_auto_button, is_auto);
    set_checked(wanbal_shared_button, is_shared);

    if (action_running)
        set_label_text_if_changed(wanbal_message_label, "正在切换…");
    else if (message[0])
        set_label_text_if_changed(wanbal_message_label, message);
    else if (status.stale)
        set_label_text_if_changed(wanbal_message_label, "状态可能过期");
    else
        set_label_text_if_changed(wanbal_message_label, "");
}

static void wanbal_auto_clicked(void *event)
{
    (void)event;
    show_confirm(ACTION_WAN_MODE_AUTO,
                 "切换为自动质量分流（弱网可溢出）？");
}

static void wanbal_shared_clicked(void *event)
{
    (void)event;
    show_confirm(ACTION_WAN_MODE_SHARED,
                 "切换为三卡共池（无协议软偏置）？");
}
