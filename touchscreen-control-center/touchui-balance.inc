/* 「余量」页数据与展示（工作包 E，文件归属见实施计划 §6）。
 *
 * 五行口径（权威，与 /data/local/balance/status.json 一致）：
 *   通用余 = general_remain_kb（sub: 总 general_total_kb）
 *   已跳   = general_used_kb   （sub: 通用已用）
 *   已免   = free_delta_kb     （sub: 本期免费）
 *   共免   = directed_used_kb  （sub: 定向已用 · 不限量 / 定向已用 · 剩 <directed_remain_kb>）
 *   跳点   = jump_delta_kb     （sub: 今日 jump_today_kb）
 * 单位换算沿用数据源里的 format_kb_human()（KB / MB / GB，按量级降精度）。
 *
 * 页面只建一套五行控件；切 tab（联通 / 电信）只把对应卡的数据填进去，
 * 省掉两套重复控件，也避免两份 label 指针要同步销毁。 */

#define BALANCE_ROW_COUNT 5
/* 行高 44（原型 48 压到 44，卡 = 5×44+16 = 236），整页一屏放下、不滚动 */
#define BALANCE_ROW_H 44
/* 卡高 = 5 行 + 上下各 8 的内边距 */
#define BALANCE_PANEL_H (BALANCE_ROW_COUNT * BALANCE_ROW_H + 16)

/* 五行行首标签（顺序即行序，勿与数据字段错位） */
static const char *const balance_row_titles[BALANCE_ROW_COUNT] = {
    "通用余", "已跳", "已免", "共免", "跳点"
};

/* 控件指针：在 touchui-balance-page.inc 创建，填值与刷新在本文件。
 * 这两个文件同属一个翻译单元（hook.c 依次包含），static 可跨文件共享。 */
static lv_obj_t *balance_tabs_panel;
static lv_obj_t *balance_tab_buttons[BALANCE_CARD_COUNT];
static lv_obj_t *balance_tab_labels[BALANCE_CARD_COUNT];
static lv_obj_t *balance_panel;
static lv_obj_t *balance_row_value[BALANCE_ROW_COUNT];
static lv_obj_t *balance_row_sub[BALANCE_ROW_COUNT];
static lv_obj_t *balance_updated_label;
static lv_obj_t *balance_next_label;
static struct badge_component balance_toast;
static lv_obj_t *balance_refresh_button, *balance_refresh_label;
static int balance_tab;          /* 当前卡片：0=联通 1=电信 */
static int balance_refresh_busy; /* 「刷新中…」禁用态 */
static struct page_shell balance_shell;

/* 刷新按钮两态：闲 = ghost（card 底 / border 边 / text 字）；
 * 忙 = 禁用观感（card-2 底 / muted 字 + 摘掉 CLICKABLE），文案「刷新中…」 */
static void balance_set_refresh_state(int busy)
{
    if (!balance_refresh_button || !balance_refresh_label) return;
    balance_refresh_busy = busy ? 1 : 0;
    set_label_text_if_changed(balance_refresh_label,
                              busy ? "刷新中…" : "立即刷新");
    set_bg_color(balance_refresh_button, busy ? COLOR_CARD_ALT : COLOR_CARD, 0);
    set_border_color(balance_refresh_button, COLOR_BORDER, 0);
    set_text_color(balance_refresh_label, busy ? COLOR_MUTED : COLOR_TEXT);
    /* 真禁用：忙时摘掉 CLICKABLE，闲时补回来（与样式双保险） */
    if (busy) lv_obj_clear_flag_p(balance_refresh_button, LV_OBJ_FLAG_CLICKABLE);
    else lv_obj_add_flag_p(balance_refresh_button, LV_OBJ_FLAG_CLICKABLE);
    center_button_label(balance_refresh_label);
}

static void balance_refresh_clicked(void *event)
{
    int accepted;
    (void)event;
    /* 忙时按钮已是禁用观感，不再接受点击（动作本身也会被队列挡住） */
    if (balance_refresh_busy) return;
    queue_action(ACTION_BALANCE_REFRESH);
    /* 队列里可能已有别的动作，本次动作会被静默丢弃：确认真的排上了再进
     * 禁用态，否则按钮会一直卡在「刷新中…」而没有任何代次变化来复位。 */
    pthread_mutex_lock(&shared_lock);
    accepted = (shared_action_running ? shared_running_action : shared_action)
               == ACTION_BALANCE_REFRESH;
    pthread_mutex_unlock(&shared_lock);
    if (accepted) balance_set_refresh_state(1);
}

static void balance_set_value(int row, const char *text)
{
    if (row < 0 || row >= BALANCE_ROW_COUNT) return;
    set_right_value(balance_row_value[row], text && text[0] ? text : "--");
}

static void balance_set_sub(int row, const char *text, uint32_t color)
{
    if (row < 0 || row >= BALANCE_ROW_COUNT) return;
    set_label_text_if_changed(balance_row_sub[row], text ? text : "");
    set_text_color(balance_row_sub[row], color);
}

/* 复用数据源的 format_kb_human()，只在数字与单位之间补一个空格，
 * 让「41.30 GB / 940.8 MB」与原型 bal-value / bal-sub 的写法一致。 */
static void balance_format_kb(long kb, char *out, size_t size)
{
    size_t i, len;
    if (!out || size < 2) return;
    format_kb_human(kb, out, size);
    len = strlen(out);
    for (i = 0; i < len; i++) {
        if (out[i] >= 'A' && out[i] <= 'Z') break;
    }
    if (i == 0 || i >= len) return;      /* 空串或没有单位：原样 */
    if (len + 2 > size) return;          /* 放不下空格 + 结尾：原样 */
    memmove(out + i + 1, out + i, len - i + 1);
    out[i] = ' ';
}

/* 选中 = card 底 + border 边 + text 字；未选 = 透明底 + muted 字（原型 .tabs） */
static void balance_style_tab(int index, int active)
{
    lv_obj_t *button, *label;
    if (index < 0 || index >= BALANCE_CARD_COUNT) return;
    button = balance_tab_buttons[index];
    label = balance_tab_labels[index];
    if (!button) return;
    /* 先铺三个状态的底色，再按选中与否收口描边 / 不透明度 */
    style_button(button, active ? COLOR_CARD : COLOR_CARD_ALT,
                 COLOR_CARD_ALT, COLOR_CARD, COLOR_BORDER);
    if (lv_obj_set_style_radius_p) lv_obj_set_style_radius_p(button, 8, 0);
    if (active) {
        set_bg_color(button, COLOR_CARD, 0);
        set_border_color(button, COLOR_BORDER, 0);
        if (lv_obj_set_style_border_width_p)
            lv_obj_set_style_border_width_p(button, 1, 0);
    } else {
        /* 透明底：set_bg_color 会顺带置 COVER，所以最后再压不透明度 */
        if (lv_obj_set_style_border_width_p)
            lv_obj_set_style_border_width_p(button, 0, 0);
        if (lv_obj_set_style_bg_opa_p)
            lv_obj_set_style_bg_opa_p(button, LV_OPA_TRANSP, 0);
    }
    set_text_color(label, active ? COLOR_TEXT : COLOR_MUTED);
}

/* 「联通免流」→「联通」：tab 上只要运营商名，尾号另拼 */
static void balance_carrier_name(const char *label, char *out, size_t size)
{
    const char *cut;
    size_t n;
    if (!out || !size) return;
    out[0] = '\0';
    if (!label || !label[0]) return;
    cut = strstr(label, "免流");
    n = cut ? (size_t)(cut - label) : strlen(label);
    if (n >= size) n = size - 1;
    memcpy(out, label, n);
    out[n] = '\0';
}

/* tab 文案：「联通 ·****」；数据未到时回落成固定运营商名 */
static void balance_tab_text(const struct balance_status *status, int index,
                             char *out, size_t size)
{
    const struct balance_card_status *card;
    char name[40];
    if (!out || !size) return;
    name[0] = '\0';
    if (status && status->valid && index >= 0 && index < status->card_count) {
        card = &status->cards[index];
        balance_carrier_name(card->label, name, sizeof(name));
        if (name[0] && card->phone_tail[0]) {
            snprintf(out, size, "%s ·%s", name, card->phone_tail);
            return;
        }
        if (name[0]) {
            snprintf(out, size, "%s", name);
            return;
        }
    }
    snprintf(out, size, "%s", index == 1 ? "电信" : "联通");
}

/* 用当前 ui_balance_status 填这一套五行控件；index 越界按第 0 张处理。
 * 失败 / 未配置 / 读取中统一：值区「--」，第 1 行副行写原因（warn 色）。 */
static void balance_fill_card(int index)
{
    const struct balance_status *status = &ui_balance_status;
    const struct balance_card_status *card;
    char value[48], sub[96], aux[40];
    int i, ok;

    if (!balance_page) return;
    if (index < 0 || index >= BALANCE_CARD_COUNT) index = 0;
    card = &status->cards[index];
    ok = status->valid && index < status->card_count && card->ok;

    if (ok) {
        balance_format_kb(card->general_remain_kb, value, sizeof(value));
        balance_set_value(0, value);
        balance_format_kb(card->general_total_kb, aux, sizeof(aux));
        snprintf(sub, sizeof(sub), "总 %s", aux);
        balance_set_sub(0, sub, COLOR_MUTED);

        balance_format_kb(card->general_used_kb, value, sizeof(value));
        balance_set_value(1, value);
        balance_set_sub(1, "通用已用", COLOR_MUTED);

        balance_format_kb(card->free_delta_kb, value, sizeof(value));
        balance_set_value(2, value);
        balance_set_sub(2, "本期免费", COLOR_MUTED);

        /* 共免 = 定向已用；有无限包注「不限量」，否则注剩余（口径见文件头） */
        balance_format_kb(card->directed_used_kb, value, sizeof(value));
        balance_set_value(3, value);
        if (card->directed_unlimited) {
            balance_set_sub(3, "定向已用 · 不限量", COLOR_MUTED);
        } else if (card->directed_remain_kb > 0) {
            balance_format_kb(card->directed_remain_kb, aux, sizeof(aux));
            snprintf(sub, sizeof(sub), "定向已用 · 剩 %s", aux);
            balance_set_sub(3, sub, COLOR_MUTED);
        } else {
            balance_set_sub(3, "定向已用", COLOR_MUTED);
        }

        balance_format_kb(card->jump_delta_kb, value, sizeof(value));
        balance_set_value(4, value);
        balance_format_kb(card->jump_today_kb, aux, sizeof(aux));
        snprintf(sub, sizeof(sub), "今日 %s", aux);
        balance_set_sub(4, sub, COLOR_MUTED);
        return;
    }

    for (i = 1; i < BALANCE_ROW_COUNT; i++)
        balance_set_sub(i, "", COLOR_MUTED);
    for (i = 0; i < BALANCE_ROW_COUNT; i++)
        balance_set_value(i, "--");
    if (!status->valid || status->card_count <= 0) {
        balance_set_sub(0, "读取中…", COLOR_MUTED);
    } else if (index >= status->card_count) {
        balance_set_sub(0, status->error[0] ? status->error : "未配置此卡",
                        COLOR_AMBER);
    } else {
        balance_set_sub(0, card->error[0] ? card->error : "查询失败", COLOR_AMBER);
    }
}

/* 切换 tab：刷选中态 + 立刻用当前快照填值（不等下一轮采集）。
 * 数据刷新只调 balance_fill_card()，不走这里 —— 重复刷 tab 样式会改
 * PRESSED 态底色，让按钮在触摸后闪一下。 */
static void balance_apply_tab(int index)
{
    int i;
    if (index < 0 || index >= BALANCE_CARD_COUNT) index = 0;
    balance_tab = index;
    for (i = 0; i < BALANCE_CARD_COUNT; i++)
        balance_style_tab(i, i == index);
    balance_fill_card(index);
}

static void refresh_balance_ui(void)
{
    struct balance_status status;
    char message[160], text[96];
    int generation, action_running, i;
    if (!balance_page) return;
    /* generation 合并了数据集代次与全局代次；force 刷新由 worker 置位后自增代次 */
    pthread_mutex_lock(&shared_lock);
    generation = shared_balance_generation + shared_generation;
    if (generation == ui_balance_generation) {
        pthread_mutex_unlock(&shared_lock);
        return;
    }
    status = shared_balance_status;
    safe_copy(message, sizeof(message),
              shared_message_page == PAGE_BALANCE ? shared_message : "");
    action_running = (shared_action_running ?
                      shared_running_action : shared_action) == ACTION_BALANCE_REFRESH;
    pthread_mutex_unlock(&shared_lock);
    ui_balance_generation = generation;
    ui_balance_status = status;

    /* tab 文案带尾号；数据未到时回落成「联通 / 电信」 */
    for (i = 0; i < BALANCE_CARD_COUNT; i++) {
        if (!balance_tab_labels[i]) continue;
        balance_tab_text(&status, i, text, sizeof(text));
        set_label_text_if_changed(balance_tab_labels[i], text);
        center_button_label(balance_tab_labels[i]);
    }

    /* 只填当前 tab 的那张卡（样式已在切 tab 时刷过，这里只动文字/颜色） */
    balance_fill_card(balance_tab);

    if (balance_updated_label) {
        snprintf(text, sizeof(text), "更新于 %s",
                 status.valid && status.updated[0] ? status.updated : "--:--:--");
        set_label_text_if_changed(balance_updated_label, text);
    }
    if (balance_next_label) {
        snprintf(text, sizeof(text), "下次 %s · 只读快照",
                 status.valid && status.next[0] ? status.next : "--:--:--");
        set_right_value(balance_next_label, text);
    }

    /* 底部 toast：动作消息 / 数据可能过期，都没有就隐藏（与页头 meta 的只读口径一致） */
    if (message[0])
        set_toast(&balance_toast, message);
    else if (status.stale)
        set_toast(&balance_toast, "状态可能过期");
    else
        set_toast(&balance_toast, "");

    /* 刷新按钮：闲时 ghost（card 底 + text 字），刷新中禁用（card-2 底 + muted 字）。
     * 只在状态变化时动样式，避免每秒重建排版（center_button_label 会 update_layout）。 */
    if (action_running != balance_refresh_busy)
        balance_set_refresh_state(action_running);
}
