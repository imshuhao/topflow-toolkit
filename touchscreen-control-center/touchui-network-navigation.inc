static void request_network_overview(void)
{
    pending_network_view = 1;
}

static void request_network_detail(void)
{
    pending_network_view = 2;
}

static void destroy_network_overview(void)
{
    if (network_page && lv_obj_del_p) lv_obj_del_p(network_page);
    network_page = NULL;
    memset(&network_shell, 0, sizeof(network_shell));
    memset(network_dot, 0, sizeof(network_dot));
    memset(network_header_label, 0, sizeof(network_header_label));
    memset(network_summary_label, 0, sizeof(network_summary_label));
    memset(network_signal_label, 0, sizeof(network_signal_label));
    memset(network_signal_icon, 0, sizeof(network_signal_icon));
    memset(network_traffic_label, 0, sizeof(network_traffic_label));
    memset(network_snr_label, 0, sizeof(network_snr_label));
    memset(network_rsrp_caption, 0, sizeof(network_rsrp_caption));
    memset(network_snr_caption, 0, sizeof(network_snr_caption));
    memset(network_down, 0, sizeof(network_down));
    memset(network_up, 0, sizeof(network_up));
    network_updated_label = NULL;
}

static void destroy_network_detail(void)
{
    if (network_detail_page && lv_obj_del_p) lv_obj_del_p(network_detail_page);
    network_detail_page = NULL;
    memset(&network_detail_shell, 0, sizeof(network_detail_shell));
    network_detail_dot = NULL;
    network_detail_status_label = NULL;
    network_detail_sim_label = NULL;
    network_detail_band_label = NULL;
    network_detail_radio_button = NULL;
    network_detail_network_button = NULL;
    network_detail_traffic_button = NULL;
    network_detail_trend_button = NULL;
    network_detail_radio_page = NULL;
    network_detail_network_page = NULL;
    network_detail_traffic_page = NULL;
    network_detail_trend_page = NULL;
    network_trend_rsrp_chart = NULL;
    network_trend_traffic_chart = NULL;
    network_trend_rsrp_series = NULL;
    network_trend_rx_series = NULL;
    network_trend_tx_series = NULL;
    network_trend_signal_summary = NULL;
    network_trend_rate_summary = NULL;
    memset(network_trend_event_labels, 0, sizeof(network_trend_event_labels));
    memset(network_detail_signal_values, 0, sizeof(network_detail_signal_values));
    memset(network_detail_signal_captions, 0, sizeof(network_detail_signal_captions));
    memset(network_detail_radio_values, 0, sizeof(network_detail_radio_values));
    network_detail_session_value = NULL;
    memset(network_detail_address_values, 0, sizeof(network_detail_address_values));
    memset(network_detail_path_values, 0, sizeof(network_detail_path_values));
    memset(&network_detail_rate_down, 0, sizeof(network_detail_rate_down));
    memset(&network_detail_rate_up, 0, sizeof(network_detail_rate_up));
    memset(&network_detail_peak_down, 0, sizeof(network_detail_peak_down));
    memset(&network_detail_peak_up, 0, sizeof(network_detail_peak_up));
    memset(&network_detail_total_down, 0, sizeof(network_detail_total_down));
    memset(&network_detail_total_up, 0, sizeof(network_detail_total_up));
}

static void destroy_network_identity(void)
{
    if (network_identity_page && lv_obj_del_p) lv_obj_del_p(network_identity_page);
    network_identity_page = NULL;
    memset(&network_identity_shell, 0, sizeof(network_identity_shell));
    memset(network_identity_sim_values, 0, sizeof(network_identity_sim_values));
    memset(network_identity_module_values, 0, sizeof(network_identity_module_values));
}

static void process_network_navigation(void)
{
    static long long next_selftest_poll;
    static int selftest_step;
    long long now = monotonic_millis();
    int view;
    if (pending_extension_cleanup) {
        pending_extension_cleanup = 0;
        destroy_singbox_page();
        destroy_wanbal_page();
        destroy_charge_page();
        destroy_network_identity();
        destroy_network_detail();
        destroy_network_overview();
        destroy_device_pages();
    }
    if (now >= next_selftest_poll) {
        next_selftest_poll = now + 1000;
        if (access("/tmp/touchui-selftest", F_OK) == 0) {
            selftest_step++;
            if (selftest_step == 1) {
                pending_network_view = 1;
                trace_ui_create("selftest-overview");
            } else if (selftest_step == 2) {
                network_detail_index = 0;
                network_detail_tab = 0;
                pending_network_view = 2;
                trace_ui_create("selftest-x75-radio");
            } else if (selftest_step == 3 && network_detail_page) {
                show_network_detail_tab(1);
                trace_ui_create("selftest-x75-network");
            } else if (selftest_step == 4 && network_detail_page) {
                show_network_detail_tab(2);
                trace_ui_create("selftest-x75-traffic");
            } else if (selftest_step == 5 && network_detail_page) {
                show_network_detail_tab(3);
                trace_ui_create("selftest-x75-trend");
            } else if (selftest_step == 6) {
                pending_network_view = 3;
                trace_ui_create("selftest-x75-identity");
            } else if (selftest_step == 7) {
                network_detail_index = 1;
                network_detail_tab = 0;
                pending_network_view = 2;
                trace_ui_create("selftest-v3e2-radio");
            } else if (selftest_step == 8) {
                pending_network_view = 3;
                trace_ui_create("selftest-v3e2-identity");
            } else if (selftest_step == 9) {
                network_detail_index = 2;
                network_detail_tab = 1;
                pending_network_view = 2;
                trace_ui_create("selftest-v3e1-network");
            } else if (selftest_step == 10) {
                pending_network_view = 3;
                trace_ui_create("selftest-v3e1-identity");
            } else if (selftest_step == 11) {
                pending_network_view = 1;
                trace_ui_create("selftest-return-overview");
            } else if (selftest_step == 12) {
                pending_singbox_open = 1;
                trace_ui_create("selftest-proxy");
            } else if (selftest_step == 13) {
                pending_wanbal_open = 1;
                trace_ui_create("selftest-wanbal");
            } else if (selftest_step == 14) {
                device_tab = 0;
                pending_device_view = 1;
                trace_ui_create("selftest-device-system");
            } else if (selftest_step == 15 && device_page) {
                show_device_tab(1);
                trace_ui_create("selftest-device-traffic");
            } else if (selftest_step == 16 && device_page) {
                show_device_tab(2);
                trace_ui_create("selftest-device-cooling");
            } else if (selftest_step == 17) {
                pending_device_view = 3;
                trace_ui_create("selftest-device-cooling-curve");
            } else if (selftest_step == 18) {
                device_tab = 3;
                pending_device_view = 1;
                trace_ui_create("selftest-device-wifi");
            } else if (selftest_step == 19) {
                pending_device_view = 2;
                trace_ui_create("selftest-diagnostics");
            } else if (selftest_step >= 20) {
                show_stock_page();
                unlink("/tmp/touchui-selftest");
                trace_ui_create("selftest-complete");
                selftest_step = 0;
            }
        } else {
            selftest_step = 0;
        }
    }
    if (pending_singbox_open && network_parent) {
        pending_singbox_open = 0;
        pending_wanbal_open = 0;
        pending_network_view = 0;
        destroy_wanbal_page();
        destroy_charge_page();
        destroy_network_identity();
        destroy_network_detail();
        destroy_network_overview();
        destroy_device_pages();
        if (!manager_page && !create_singbox_page(network_parent)) return;
        show_page(PAGE_SINGBOX);
        ui_generation = -1;
        refresh_ui();
        return;
    }
    if (pending_wanbal_open && network_parent) {
        pending_wanbal_open = 0;
        pending_singbox_open = 0;
        pending_network_view = 0;
        destroy_singbox_page();
        destroy_charge_page();
        destroy_network_identity();
        destroy_network_detail();
        destroy_network_overview();
        destroy_device_pages();
        if (!wanbal_page && !create_wanbal_page(network_parent)) return;
        show_page(PAGE_WANBAL);
        ui_wanbal_generation = -1;
        refresh_wanbal_ui();
        return;
    }
    if (pending_charge_open && network_parent) {
        pending_charge_open = 0;
        pending_singbox_open = 0;
        pending_wanbal_open = 0;
        pending_network_view = 0;
        destroy_singbox_page();
        destroy_wanbal_page();
        destroy_network_identity();
        destroy_network_detail();
        destroy_network_overview();
        destroy_device_pages();
        if (!charge_page && !create_charge_page(network_parent)) return;
        show_page(PAGE_CHARGE);
        refresh_charge_ui();
        return;
    }
    view = pending_network_view;
    if (!view || !network_parent) return;
    pending_network_view = 0;
    destroy_singbox_page();
    destroy_wanbal_page();
    destroy_charge_page();
    destroy_device_pages();
    if (view == 1) {
        destroy_network_identity();
        destroy_network_detail();
        if (!network_page && !create_network_page(network_parent)) return;
        show_page(PAGE_NETWORK);
        ui_network_generation = -1;
        refresh_network_ui();
    } else if (view == 2) {
        destroy_network_identity();
        destroy_network_overview();
        if (!network_detail_page && !create_network_detail_page(network_parent)) return;
        refresh_network_detail_ui();
        show_network_detail_tab(network_detail_tab);
        show_page(PAGE_NETWORK_DETAIL);
    } else if (view == 3) {
        if (!network_detail_page && !create_network_detail_page(network_parent)) return;
        destroy_network_detail_tab_content();
        if (!network_identity_page && !create_network_identity_page(network_parent)) return;
        refresh_network_detail_ui();
        show_page(PAGE_NETWORK_IDENTITY);
    }
}
