/* 「核心切换」区块（原型 .engine-switch）：标题行 + 两枚 ghost 按钮。
 *
 * 布局：标题行与按钮行由本文件创建，挂在「代理」页 root 上（y 由调用方给），
 * 文字与配色统一由 touchui-singbox.inc 的 refresh_ui() 刷新。
 * 点击回调在 touchui-engine.inc（engine_to_singbox_clicked /
 * engine_to_mihomo_clicked），二次确认由 touchui-navigation.inc 的贴底
 * sheet 完成，本文件不碰动作队列。
 *
 * 历史说明：改造前这里是一张独立的「核心切换」子页（create_engine_page），
 * 但 PAGE_ENGINE 从未进入 page_id 枚举、也无人调用，属于死代码；原型把核心
 * 切换并入代理页，故整页实现替换为下面的区块构造函数。 */

static int create_engine_switch_section(lv_obj_t *parent, int y)
{
    engine_to_singbox_button = make_button(
        parent, "切到 sing-box", 8, y, 148, 40,
        engine_to_singbox_clicked, &engine_to_singbox_label);
    engine_to_mihomo_button = make_button(
        parent, "切回 mihomo", 164, y, 148, 40,
        engine_to_mihomo_clicked, &engine_to_mihomo_label);
    if (!engine_to_singbox_button || !engine_to_mihomo_button)
        return 0;
    if (engine_to_singbox_label && ui_font_tiny && real_obj_set_style_text_font)
        real_obj_set_style_text_font(engine_to_singbox_label, ui_font_tiny, 0);
    if (engine_to_mihomo_label && ui_font_tiny && real_obj_set_style_text_font)
        real_obj_set_style_text_font(engine_to_mihomo_label, ui_font_tiny, 0);
    proxy_apply_button(engine_to_singbox_button, engine_to_singbox_label,
                       PROXY_BTN_GHOST_ACCENT, 0);
    proxy_apply_button(engine_to_mihomo_button, engine_to_mihomo_label,
                       PROXY_BTN_GHOST_ACCENT, 0);
    center_button_label(engine_to_singbox_label);
    center_button_label(engine_to_mihomo_label);
    return 1;
}
