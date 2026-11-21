/* 日夜主题：对齐 OpenDesign colors.md，持久化到 TOUCHUI_THEME_PATH。
 * color_hex 已用标准 RGB565（R 高），玻璃上 accent 即为青绿/日间墨绿。 */

static void touchui_palette_night(struct touchui_palette *p)
{
    if (!p) return;
    p->bg = 0x07090Au;
    p->card = 0x12171Au;
    p->card_2 = 0x1A2124u;
    p->border = 0x293336u;
    p->text = 0xF2F6F5u;
    p->muted = 0x9BA9AAu;
    p->message = 0x9BA9AAu;
    p->accent = 0x35E0B0u;
    p->accent_ink = 0x06201Au;
    p->accent_dark = 0x0E2A25u;
    p->accent_soft = 0x0E2A25u;
    p->segment = 0x1A2124u;
    p->ok = 0x4ADE80u;
    p->warn = 0xF5C451u;
    p->danger = 0xFF7B72u;
    p->ok_soft = 0x10281Du;
    p->warn_soft = 0x2A2310u;
    p->danger_soft = 0x2C1414u;
    p->button = 0x12171Au;
    p->button_pressed = 0x1A2124u;
    p->traffic_up = 0x31B6FFu;
    p->traffic_down = 0x6BF700u;
    p->wifi = 0x67E8F9u;
    p->track = 0x334044u;
    p->toast_bg = 0x1A2124u;
    p->toast_text = 0xF2F6F5u;
}

static void touchui_palette_day(struct touchui_palette *p)
{
    if (!p) return;
    p->bg = 0xE9EEF0u;
    p->card = 0xF7FAFAu;
    p->card_2 = 0xDDE5E6u;
    p->border = 0xC6D2D3u;
    p->text = 0x0C1416u;
    p->muted = 0x4E5F62u;
    p->message = 0x4E5F62u;
    p->accent = 0x0B6E63u;
    p->accent_ink = 0xF7FAFAu;
    p->accent_dark = 0x0B6E63u;
    p->accent_soft = 0xD2E7E2u;
    p->segment = 0xDDE5E6u;
    p->ok = 0x0B6B45u;
    p->warn = 0x7A4F00u;
    p->danger = 0xB3261Eu;
    p->ok_soft = 0xDDEEE5u;
    p->warn_soft = 0xF3E7C8u;
    p->danger_soft = 0xF6DEDBu;
    p->button = 0xF7FAFAu;
    p->button_pressed = 0xDDE5E6u;
    p->traffic_up = 0x0369A1u;
    p->traffic_down = 0x15803Du;
    p->wifi = 0x0E7490u;
    p->track = 0xC6D2D3u;
    p->toast_bg = 0x0C1416u;
    p->toast_text = 0xF7FAFAu;
}

static void touchui_theme_apply_palette(void)
{
    if (touchui_theme_is_day)
        touchui_palette_day(&touchui_theme);
    else
        touchui_palette_night(&touchui_theme);
}

static void touchui_theme_load(void)
{
    FILE *fp;
    char buf[16];
    size_t n;

    touchui_theme_is_day = 0;
    fp = fopen(TOUCHUI_THEME_PATH, "r");
    if (fp) {
        n = fread(buf, 1, sizeof(buf) - 1, fp);
        fclose(fp);
        buf[n] = '\0';
        if (strncmp(buf, "day", 3) == 0)
            touchui_theme_is_day = 1;
    }
    touchui_theme_apply_palette();
}

static void touchui_theme_save(void)
{
    FILE *fp = fopen(TOUCHUI_THEME_PATH, "w");
    if (!fp) return;
    fputs(touchui_theme_is_day ? "day\n" : "night\n", fp);
    fclose(fp);
}

static void touchui_theme_set_day(int is_day)
{
    touchui_theme_is_day = is_day ? 1 : 0;
    touchui_theme_apply_palette();
    touchui_theme_save();
}

static void touchui_theme_toggle(void)
{
    touchui_theme_set_day(!touchui_theme_is_day);
}
