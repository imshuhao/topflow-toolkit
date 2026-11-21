static int create_network_detail_tab_content(int tab)
{
    if (!network_detail_page) return 0;
    if (tab == 0) {
        static const char *captions[4] = {
            "RSRP · dBm", "RSRQ · dB", "SNR · dB", "RSSI · dBm"
        };
        static const int x_positions[4] = {18, 171, 18, 171};
        static const int value_y[4] = {31, 31, 77, 77};
        static const int caption_y[4] = {58, 58, 104, 104};
        network_detail_radio_page = make_transparent_container(network_detail_page,
                                                                0, 136, 320, 306);
        if (!network_detail_radio_page) return 0;
        make_panel(network_detail_radio_page, 8, 0, 304, 126, COLOR_CARD);
        make_detail_label(network_detail_radio_page, "信号质量", 20, 8, 100, 17,
                          ui_font_tiny, COLOR_MUTED);
        for (int i = 0; i < 4; i++) {
            network_detail_signal_values[i] = make_detail_label(
                network_detail_radio_page, "--", x_positions[i], value_y[i],
                126, 28, ui_font_large, COLOR_TEXT);
            network_detail_signal_captions[i] = make_detail_label(
                network_detail_radio_page, captions[i], x_positions[i],
                caption_y[i], 126, 17, ui_font_tiny, COLOR_MUTED);
        }
        make_panel(network_detail_radio_page, 8, 132, 304, 161, COLOR_CARD);
        make_detail_label(network_detail_radio_page, "无线参数", 20, 140, 100, 17,
                          ui_font_tiny, COLOR_MUTED);
        make_detail_block(network_detail_radio_page,
                          "带宽\n\n信道\n\n小区\n\n选网",
                          18, 166, 38, 120, ui_font_tiny, COLOR_MUTED, 0);
        network_detail_radio_values[0] = make_detail_block(
                          network_detail_radio_page, "--\n\n--\n\n--\n\n--",
                          58, 166, 92, 120, ui_font_tiny, COLOR_TEXT, 1);
        make_detail_block(network_detail_radio_page,
                          "PCI\n\nPLMN\n\n温度\n\nCA",
                          170, 166, 42, 120, ui_font_tiny, COLOR_MUTED, 0);
        network_detail_radio_values[1] = make_detail_block(
                          network_detail_radio_page, "--\n\n--\n\n--\n\n--",
                          214, 166, 88, 120, ui_font_tiny, COLOR_TEXT, 1);
        for (int i = 0; i < 4; i++) {
            if (!network_detail_signal_values[i] ||
                !network_detail_signal_captions[i]) {
                trace_ui_create("detail-radio-allocation-failed");
                destroy_network_detail_tab_content();
                return 0;
            }
        }
        if (!network_detail_radio_values[0] ||
            !network_detail_radio_values[1]) {
            trace_ui_create("detail-radio-allocation-failed");
            destroy_network_detail_tab_content();
            return 0;
        }
        trace_ui_create("detail-radio");
        return 1;
    }
    if (tab == 1) {
        network_detail_network_page = make_transparent_container(network_detail_page,
                                                                  0, 136, 320, 306);
        if (!network_detail_network_page) return 0;
        make_panel(network_detail_network_page, 8, 0, 304, 130, COLOR_CARD);
        make_detail_label(network_detail_network_page, "地址与接口", 20, 8, 100, 17,
                          ui_font_tiny, COLOR_MUTED);
        {
            static const char *keys[5] = {"IPv4", "IPv6", "接口", "DNS4", "DNS6"};
            for (int i = 0; i < 5; i++) {
                make_detail_label(network_detail_network_page, keys[i],
                                  18, 31 + i * 18, 42, 17,
                                  ui_font_tiny, COLOR_MUTED);
                network_detail_address_values[i] = make_scrolling_detail_label(
                                  network_detail_network_page, "--",
                                  62, 31 + i * 18, 240, 17,
                                  ui_font_tiny, COLOR_TEXT, 1);
            }
        }
        make_panel(network_detail_network_page, 8, 136, 304, 157, COLOR_CARD);
        make_detail_label(network_detail_network_page, "注册与承载", 20, 144, 100, 17,
                          ui_font_tiny, COLOR_MUTED);
        {
            static const char *keys[6] = {
                "注册", "在线", "质量", "QCI", "AMBR", "采样"
            };
            for (int i = 0; i < 6; i++) {
                make_detail_label(network_detail_network_page, keys[i],
                                  18, 167 + i * 19, 64, 17,
                                  ui_font_tiny, COLOR_MUTED);
                network_detail_path_values[i] = make_scrolling_detail_label(
                                  network_detail_network_page, "--",
                                  84, 167 + i * 19, 218, 17,
                                  ui_font_tiny, COLOR_TEXT, 1);
            }
        }
        for (int i = 0; i < 5; i++) {
            if (!network_detail_address_values[i]) {
                trace_ui_create("detail-network-allocation-failed");
                destroy_network_detail_tab_content();
                return 0;
            }
        }
        for (int i = 0; i < 6; i++) {
            if (!network_detail_path_values[i]) {
                trace_ui_create("detail-network-allocation-failed");
                destroy_network_detail_tab_content();
                return 0;
            }
        }
        trace_ui_create("detail-network");
        return 1;
    }
    if (tab == 3) {
        int backend = network_backend_index(network_detail_index);
        struct modem_history *history = &network_history[backend];
        network_detail_trend_page = make_transparent_container(network_detail_page,
                                                                0, 136, 320, 306);
        if (!network_detail_trend_page) return 0;
        make_panel(network_detail_trend_page, 8, 0, 304, 105, COLOR_CARD);
        make_detail_label(network_detail_trend_page, "信号 · 60秒", 20, 8, 104, 18,
                          ui_font_tiny, COLOR_MUTED);
        network_trend_signal_summary = make_detail_label(
            network_detail_trend_page, "正在采样…", 120, 8, 184, 18,
            ui_font_tiny, COLOR_TEXT);
        right_align_label_text(network_trend_signal_summary);
        make_panel(network_detail_trend_page, 8, 111, 304, 105, COLOR_CARD);
        make_detail_label(network_detail_trend_page, "速率 · 60秒", 20, 119, 104, 18,
                          ui_font_tiny, COLOR_MUTED);
        network_trend_rate_summary = make_detail_label(
            network_detail_trend_page, "正在采样…", 120, 119, 184, 18,
            ui_font_tiny, COLOR_TEXT);
        right_align_label_text(network_trend_rate_summary);
        make_panel(network_detail_trend_page, 8, 222, 304, 71, COLOR_CARD);
        make_detail_label(network_detail_trend_page, "最近变化", 20, 230, 80, 18,
                          ui_font_tiny, COLOR_MUTED);
        network_trend_event_labels[0] = make_detail_label(
            network_detail_trend_page, "暂无切换事件", 102, 230, 202, 18,
            ui_font_tiny, COLOR_TEXT);
        network_trend_event_labels[1] = make_detail_label(
            network_detail_trend_page, "", 20, 257, 284, 18,
            ui_font_tiny, COLOR_MUTED);
        if (lv_chart_create_p && lv_chart_add_series_p &&
            lv_chart_set_next_value_p) {
            network_trend_rsrp_chart = lv_chart_create_p(network_detail_trend_page);
            network_trend_traffic_chart = lv_chart_create_p(network_detail_trend_page);
            if (network_trend_rsrp_chart && network_trend_traffic_chart) {
                lv_obj_set_size_p(network_trend_rsrp_chart, 288, 65);
                lv_obj_set_pos_p(network_trend_rsrp_chart, 16, 34);
                lv_obj_set_size_p(network_trend_traffic_chart, 288, 65);
                lv_obj_set_pos_p(network_trend_traffic_chart, 16, 145);
                style_surface(network_trend_rsrp_chart, COLOR_CARD, COLOR_CARD, 0, 0);
                style_surface(network_trend_traffic_chart, COLOR_CARD, COLOR_CARD, 0, 0);
                if (lv_chart_set_type_p) {
                    lv_chart_set_type_p(network_trend_rsrp_chart, LV_CHART_TYPE_LINE);
                    lv_chart_set_type_p(network_trend_traffic_chart, LV_CHART_TYPE_LINE);
                }
                if (lv_chart_set_point_count_p) {
                    lv_chart_set_point_count_p(network_trend_rsrp_chart,
                                               NETWORK_TREND_POINTS);
                    lv_chart_set_point_count_p(network_trend_traffic_chart,
                                               NETWORK_TREND_POINTS);
                }
                if (lv_chart_set_range_p) {
                    lv_chart_set_range_p(network_trend_rsrp_chart,
                        LV_CHART_AXIS_PRIMARY_Y, -140, -50);
                    lv_chart_set_range_p(network_trend_traffic_chart,
                        LV_CHART_AXIS_PRIMARY_Y, 0, 1);
                }
                network_trend_rsrp_series = lv_chart_add_series_p(
                    network_trend_rsrp_chart, color_hex(COLOR_GREEN),
                    LV_CHART_AXIS_PRIMARY_Y);
                network_trend_rx_series = lv_chart_add_series_p(
                    network_trend_traffic_chart, color_hex(COLOR_TRAFFIC_DOWN),
                    LV_CHART_AXIS_PRIMARY_Y);
                network_trend_tx_series = lv_chart_add_series_p(
                    network_trend_traffic_chart, color_hex(COLOR_TRAFFIC_UP),
                    LV_CHART_AXIS_PRIMARY_Y);
                for (int i = 0; i < history->count; i++) {
                    int index = history_value_index(history, i);
                    lv_chart_set_next_value_p(network_trend_rsrp_chart,
                        network_trend_rsrp_series,
                        history->rsrp[index] ? history->rsrp[index] : -140);
                    lv_chart_set_next_value_p(network_trend_traffic_chart,
                        network_trend_rx_series,
                        (int32_t)(history->rx_rate[index] / 1024ULL));
                    lv_chart_set_next_value_p(network_trend_traffic_chart,
                        network_trend_tx_series,
                        (int32_t)(history->tx_rate[index] / 1024ULL));
                }
            }
        } else {
            make_detail_label(network_detail_trend_page,
                "图形接口不可用，数值与事件仍会每秒更新", 20, 54, 284, 20,
                ui_font_tiny, COLOR_MUTED);
        }
        refresh_network_trend_ui();
        trace_ui_create("detail-trend");
        return 1;
    }
    network_detail_traffic_page = make_transparent_container(network_detail_page,
                                                              0, 136, 320, 306);
    if (!network_detail_traffic_page) return 0;
#define TRAFFIC_PANEL(y, title, down_target, up_target) do { \
    make_panel(network_detail_traffic_page, 8, y, 304, 80, COLOR_CARD); \
    make_detail_label(network_detail_traffic_page, title, 20, y + 8, 80, 20, \
                      ui_font_small, COLOR_MUTED); \
    down_target = make_download_value(network_detail_traffic_page, 18, y + 32, \
                                      108, ui_font_xlarge); \
    up_target = make_upload_value(network_detail_traffic_page, 164, y + 32, \
                                  108, ui_font_xlarge); \
    if (lv_img_set_zoom_p) { \
        if (down_target.icon) lv_img_set_zoom_p(down_target.icon, 384); \
        if (up_target.icon) lv_img_set_zoom_p(up_target.icon, 384); \
    } \
    if (down_target.label) lv_obj_set_pos_p(down_target.label, 46, y + 32); \
    if (up_target.label) lv_obj_set_pos_p(up_target.label, 192, y + 32); \
} while (0)
    TRAFFIC_PANEL(0, "实时", network_detail_rate_down, network_detail_rate_up);
    TRAFFIC_PANEL(87, "峰值", network_detail_peak_down, network_detail_peak_up);
    TRAFFIC_PANEL(174, "累计", network_detail_total_down, network_detail_total_up);
#undef TRAFFIC_PANEL
    make_panel(network_detail_traffic_page, 8, 261, 304, 32, COLOR_CARD);
    make_detail_label(network_detail_traffic_page, "本次联网", 20, 268, 88, 18,
                      ui_font_tiny, COLOR_MUTED);
    network_detail_session_value = make_detail_label(network_detail_traffic_page, "--",
        108, 267, 194, 19, ui_font_small, COLOR_TEXT);
    right_align_label_text(network_detail_session_value);
    trace_ui_create("detail-traffic");
    return 1;
}

static int create_network_detail_page(lv_obj_t *top)
{
    trace_ui_create("detail-begin");
    if (!page_shell_init(&network_detail_shell, top, PAGE_NETWORK_DETAIL,
                         "X75(5G)", network_detail_back_clicked)) return 0;
    trace_ui_create("detail-shell");
    network_detail_page = network_detail_shell.root;
    make_network_rule(network_detail_page, 8, 87, 304, 1);
    network_detail_dot = lv_obj_create_p(network_detail_page);
    if (network_detail_dot) {
        lv_obj_set_size_p(network_detail_dot, 8, 8);
        lv_obj_set_pos_p(network_detail_dot, 18,
                         center_marker_on_text_line(60, ui_font_tiny, 8));
        lv_obj_clear_flag_p(network_detail_dot, LV_OBJ_FLAG_SCROLLABLE);
        style_surface(network_detail_dot, COLOR_MUTED, COLOR_MUTED, 8, 0);
    }
    network_detail_status_label = make_detail_label(network_detail_page, "--",
        34, 60, 42, 17, ui_font_tiny, COLOR_TEXT);
    network_detail_band_label = make_scrolling_detail_label(
        network_detail_page, "-- · -- · --", 82, 60, 136, 17,
        ui_font_tiny, COLOR_MUTED, 0);
    network_detail_sim_label = make_detail_label(network_detail_page, "SIM -- >",
        226, 60, 76, 17, ui_font_tiny, COLOR_MUTED);
    right_align_label_text(network_detail_sim_label);
    make_click_layer(network_detail_page, 220, 48, 92, 40, open_network_identity);
    network_detail_radio_button = make_button(network_detail_page, "无线",
        8, 94, 74, 36, network_radio_tab_clicked, NULL);
    network_detail_network_button = make_button(network_detail_page, "网络",
        84, 94, 74, 36, network_network_tab_clicked, NULL);
    network_detail_traffic_button = make_button(network_detail_page, "流量",
        160, 94, 74, 36, network_traffic_tab_clicked, NULL);
    network_detail_trend_button = make_button(network_detail_page, "趋势",
        236, 94, 74, 36, network_trend_tab_clicked, NULL);
    style_segment_button(network_detail_radio_button);
    style_segment_button(network_detail_network_button);
    style_segment_button(network_detail_traffic_button);
    style_segment_button(network_detail_trend_button);
    if (!network_detail_dot || !network_detail_status_label ||
        !network_detail_band_label || !network_detail_sim_label ||
        !network_detail_radio_button || !network_detail_network_button ||
        !network_detail_traffic_button || !network_detail_trend_button) {
        trace_ui_create("detail-header-allocation-failed");
        if (network_detail_page && lv_obj_del_p) lv_obj_del_p(network_detail_page);
        network_detail_page = NULL;
        memset(&network_detail_shell, 0, sizeof(network_detail_shell));
        network_detail_dot = network_detail_status_label = NULL;
        network_detail_band_label = network_detail_sim_label = NULL;
        network_detail_radio_button = network_detail_network_button = NULL;
        network_detail_traffic_button = network_detail_trend_button = NULL;
        return 0;
    }
    trace_ui_create("detail-header");
    return 1;
}
