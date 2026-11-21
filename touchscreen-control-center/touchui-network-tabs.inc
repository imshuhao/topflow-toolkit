static void show_network_detail_tab(int tab)
{
    if (tab < 0 || tab > 3) tab = 0;
    if ((tab == 0 && !network_detail_radio_page) ||
        (tab == 1 && !network_detail_network_page) ||
        (tab == 2 && !network_detail_traffic_page) ||
        (tab == 3 && !network_detail_trend_page)) {
        destroy_network_detail_tab_content();
        if (!create_network_detail_tab_content(tab)) return;
        refresh_network_detail_ui();
    }
    network_detail_tab = tab;
    /* buttons may be NULL after a failed create; never deref blindly */
    if (network_detail_radio_button && lv_obj_add_state_p &&
        lv_obj_clear_state_p) {
        if (tab == 0) lv_obj_add_state_p(network_detail_radio_button, LV_STATE_CHECKED);
        else lv_obj_clear_state_p(network_detail_radio_button, LV_STATE_CHECKED);
    }
    if (network_detail_network_button && lv_obj_add_state_p &&
        lv_obj_clear_state_p) {
        if (tab == 1) lv_obj_add_state_p(network_detail_network_button, LV_STATE_CHECKED);
        else lv_obj_clear_state_p(network_detail_network_button, LV_STATE_CHECKED);
    }
    if (network_detail_traffic_button && lv_obj_add_state_p &&
        lv_obj_clear_state_p) {
        if (tab == 2) lv_obj_add_state_p(network_detail_traffic_button, LV_STATE_CHECKED);
        else lv_obj_clear_state_p(network_detail_traffic_button, LV_STATE_CHECKED);
    }
    if (network_detail_trend_button && lv_obj_add_state_p &&
        lv_obj_clear_state_p) {
        if (tab == 3) lv_obj_add_state_p(network_detail_trend_button, LV_STATE_CHECKED);
        else lv_obj_clear_state_p(network_detail_trend_button, LV_STATE_CHECKED);
    }
}

static void network_radio_tab_clicked(void *event)
{
    (void)event;
    show_network_detail_tab(0);
}

static void network_network_tab_clicked(void *event)
{
    (void)event;
    show_network_detail_tab(1);
}

static void network_traffic_tab_clicked(void *event)
{
    (void)event;
    show_network_detail_tab(2);
}

static void network_trend_tab_clicked(void *event)
{
    (void)event;
    show_network_detail_tab(3);
}

static void open_network_identity(void *event)
{
    (void)event;
    pending_network_view = 3;
}

static void open_network_detail(int display_index)
{
    if (display_index < 0 || display_index >= NETWORK_MODEM_COUNT)
        display_index = 0;
    network_detail_index = display_index;
    network_detail_tab = 0;
    pending_network_view = 2;
}

static void open_network_detail_5g(void *event) { (void)event; open_network_detail(0); }
static void open_network_detail_4g1(void *event) { (void)event; open_network_detail(1); }
static void open_network_detail_4g2(void *event) { (void)event; open_network_detail(2); }
