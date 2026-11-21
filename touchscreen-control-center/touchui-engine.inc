/* 核心切换的点击入口（按钮已并入「代理」页，见 touchui-engine-page.inc）。
 *
 * 只做两件事：过滤不可用状态 + 弹出二次确认。真正的切换由 worker 执行
 * （ACTION_ENGINE_SWITCHOVER / ACTION_ENGINE_ROLLBACK），本文件不排队、
 * 不起线程、不写文件。
 *
 * 锁定条件与改造前逐条一致，不要放宽：
 *   - 有动作在跑或已排队 → 直接返回
 *   - 切到 sing-box：服务已在跑、或引擎已是 sing-box → 返回
 *   - 切回 mihomo：服务在跑但引擎不是 sing-box → 返回；
 *     例外是「DHCP 已指向 0.254 但 mihomo 进程缺失」，允许重试回滚
 */

static void engine_to_singbox_clicked(void *event)
{
    (void)event;
    if (shared_action_running || shared_action != ACTION_NONE) return;
    if (ui_status.service_running || !strcmp(ui_status.engine, "sing-box"))
        return;
    confirm_step = 1;
    show_confirm(ACTION_ENGINE_SWITCHOVER,
                 "将停用 mihomo，DHCP 改 192.168.0.1，并启动 sing-box。"
                 "期间客户端会短暂断网。继续？");
}

static void engine_to_mihomo_clicked(void *event)
{
    (void)event;
    if (shared_action_running || shared_action != ACTION_NONE) return;
    /* Allow retry when DHCP already on 0.254 but mihomo process is missing. */
    if (!ui_status.service_running &&
        strcmp(ui_status.engine, "sing-box") != 0 &&
        !(ui_status.dhcp_points_to_mihomo && !ui_status.mihomo_running))
        return;
    confirm_step = 1;
    if (ui_status.dhcp_points_to_mihomo && !ui_status.mihomo_running)
        show_confirm(ACTION_ENGINE_ROLLBACK,
                     "mihomo 未起来。重新执行回滚（DHCP 已是 0.254）？"
                     "请保留 USB ADB。继续？");
    else
        show_confirm(ACTION_ENGINE_ROLLBACK,
                     "将停止 sing-box，DHCP 改 192.168.0.254，并启动 mihomo。"
                     "请保留 USB ADB。继续？");
}
