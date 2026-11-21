static void refresh_network_detail_ui(void)
{
    struct modem_status *modem;
    char text[1024], band[32], value[128], second[128];
    char ipv4[128], ipv6[160], interfaces_text[128];
    char qos_qci[16], qos_ambr[96], qos_sample[32];
    char module_text[64], usb_text[96], debug_text[64];
    char rsrp[24], rsrq[24], snr[24], rssi[24];
    char bandwidth[32], pci[24], channel[32], cell[48];
    char temperature[24], ca[64];
    char registration[32], path_status[64], path_quality[64];
    char path_duration[32], path_latency[24], path_loss[24];
    int backend_index;
    uint32_t dot_color;

    if (network_detail_index < 0 || network_detail_index >= NETWORK_MODEM_COUNT)
        network_detail_index = 0;
    backend_index = network_backend_index(network_detail_index);
    modem = &ui_network_status.modems[backend_index];

    if (network_detail_shell.title_label && lv_label_set_text_p) {
        lv_label_set_text_p(network_detail_shell.title_label,
                            network_module_titles[network_detail_index]);
        center_page_title(network_detail_shell.title_label);
    }
    if (network_identity_page && network_identity_shell.title_label &&
        lv_label_set_text_p) {
        lv_label_set_text_p(network_identity_shell.title_label,
                            network_module_titles[network_detail_index]);
        center_page_title(network_identity_shell.title_label);
    }
    dot_color = ui_network_status.stale ? COLOR_AMBER :
                (modem->online ? COLOR_GREEN : COLOR_RED);
    set_network_dot(network_detail_dot, modem->valid ? dot_color : COLOR_MUTED);
    set_label_text_if_changed(network_detail_status_label,
                        modem->online ? "在线" : "离线");
    snprintf(text, sizeof(text), "%s >", sim_type_text(modem));
    set_label_text_if_changed(network_detail_sim_label, text);
    short_band_name(modem->band, band, sizeof(band));
    snprintf(text, sizeof(text), "%s · %s · %s",
             display_operator_name(modem->operator_name),
             modem->type[0] ? modem->type : "--", band);
    set_label_text_if_changed(network_detail_band_label, text);

    if (network_detail_radio_page) {
    format_metric_int(modem->rsrp, rsrp, sizeof(rsrp));
    format_metric_int(modem->rsrq, rsrq, sizeof(rsrq));
    format_metric_double(modem->snr, snr, sizeof(snr));
    format_metric_int(modem->rssi, rssi, sizeof(rssi));
    set_label_text_if_changed(network_detail_signal_values[0], rsrp);
    set_label_text_if_changed(network_detail_signal_values[1], rsrq);
    set_label_text_if_changed(network_detail_signal_values[2], snr);
    set_label_text_if_changed(network_detail_signal_values[3], rssi);
    if (modem->bandwidth[0]) {
        if (contains_text_ci(modem->bandwidth, "mhz"))
            safe_copy(bandwidth, sizeof(bandwidth), modem->bandwidth);
        else snprintf(bandwidth, sizeof(bandwidth), "%sMHz", modem->bandwidth);
    } else safe_copy(bandwidth, sizeof(bandwidth), "--");
    format_metric_int(modem->pci, pci, sizeof(pci));
    if (modem->channel > 0) snprintf(channel, sizeof(channel), "%ld", modem->channel);
    else safe_copy(channel, sizeof(channel), "--");
    if (modem->cell_id)
        snprintf(cell, sizeof(cell), "0x%llX", modem->cell_id);
    else safe_copy(cell, sizeof(cell), "--");
    if (modem->temperature_valid)
        snprintf(temperature, sizeof(temperature), "%d°C", modem->temperature);
    else safe_copy(temperature, sizeof(temperature), "--");
    if (modem->ca_carriers > 0) {
        snprintf(ca, sizeof(ca), "%s %dCC",
                 modem->ca_type, modem->ca_carriers);
    } else safe_copy(ca, sizeof(ca), "--");
    snprintf(text, sizeof(text), "%s\n\n%s\n\n%s\n\n%s",
             bandwidth, channel, cell,
             modem->net_select[0] ? modem->net_select : "--");
    set_label_text_if_changed(network_detail_radio_values[0], text);
    snprintf(text, sizeof(text), "%s\n\n%s\n\n%s\n\n%s",
             pci, modem->plmn[0] ? modem->plmn : "--", temperature, ca);
    set_label_text_if_changed(network_detail_radio_values[1], text);
    }

    if (network_detail_trend_page) refresh_network_trend_ui();
    if (network_detail_traffic_page) {
        format_duration_compact(modem->session_time, text, sizeof(text));
        set_label_text_if_changed(network_detail_session_value, text);
    }

    if (network_detail_network_page) {
    format_address(modem->ipv4_address, modem->ipv4_mask, ipv4, sizeof(ipv4));
    format_address(modem->ipv6_address, modem->ipv6_mask, ipv6, sizeof(ipv6));
    snprintf(interfaces_text, sizeof(interfaces_text), "v4 %s · v6 %s",
             modem->ipv4_device[0] ? modem->ipv4_device : "--",
             modem->ipv6_device[0] ? modem->ipv6_device : "--");
    set_label_text_if_changed(network_detail_address_values[0], ipv4);
    set_label_text_if_changed(network_detail_address_values[1], ipv6);
    set_label_text_if_changed(network_detail_address_values[2], interfaces_text);
    set_label_text_if_changed(network_detail_address_values[3],
                              modem->ipv4_dns[0] ? modem->ipv4_dns : "--");
    set_label_text_if_changed(network_detail_address_values[4],
                              modem->ipv6_dns[0] ? modem->ipv6_dns : "--");

    if (!modem->online) safe_copy(registration, sizeof(registration), "未注册");
    else safe_copy(registration, sizeof(registration),
                   modem->roaming ? "漫游网络" : "本地网络");
    if (modem->path_valid) {
        format_duration_compact(modem->path_uptime, path_duration,
                                sizeof(path_duration));
        snprintf(path_status, sizeof(path_status), "%s · %s",
                 modem->path_online ? "在线" : "离线", path_duration);
        if (modem->path_latency_valid && modem->path_latency > 0.0)
            snprintf(path_latency, sizeof(path_latency), "%.0fms",
                     modem->path_latency);
        else safe_copy(path_latency, sizeof(path_latency), "--ms");
        if (modem->path_loss_valid)
            snprintf(path_loss, sizeof(path_loss), "%.0f%%丢包", modem->path_loss);
        else safe_copy(path_loss, sizeof(path_loss), "--%丢包");
        snprintf(path_quality, sizeof(path_quality), "%s · %s",
                 path_latency, path_loss);
    } else {
        safe_copy(path_status, sizeof(path_status), "未探测");
        safe_copy(path_quality, sizeof(path_quality), "--");
    }
    }
    if (network_detail_traffic_page) {
    format_rate_compact(modem->rx_rate, value, sizeof(value));
    format_rate_compact(modem->max_rx_rate, second, sizeof(second));
    set_traffic_value(&network_detail_rate_down, value);
    set_traffic_value(&network_detail_peak_down, second);
    format_bytes_compact(modem->rx_bytes, value, sizeof(value));
    set_traffic_value(&network_detail_total_down, value);
    format_rate_compact(modem->tx_rate, value, sizeof(value));
    format_rate_compact(modem->max_tx_rate, second, sizeof(second));
    set_traffic_value(&network_detail_rate_up, value);
    set_traffic_value(&network_detail_peak_up, second);
    format_bytes_compact(modem->tx_bytes, value, sizeof(value));
    set_traffic_value(&network_detail_total_up, value);
    }
    if (network_detail_network_page) {
    format_metric_int(modem->qci, qos_qci, sizeof(qos_qci));
    if (modem->ambr_dl_valid && modem->ambr_ul_valid)
        snprintf(qos_ambr, sizeof(qos_ambr), "%.0f/%.0f Mbps",
                 modem->ambr_dl, modem->ambr_ul);
    else safe_copy(qos_ambr, sizeof(qos_ambr), "--");
    format_qos_sample(modem->qos_sampled_at, qos_sample, sizeof(qos_sample));
    set_label_text_if_changed(network_detail_path_values[0], registration);
    set_label_text_if_changed(network_detail_path_values[1], path_status);
    set_label_text_if_changed(network_detail_path_values[2], path_quality);
    set_label_text_if_changed(network_detail_path_values[3], qos_qci);
    set_label_text_if_changed(network_detail_path_values[4], qos_ambr);
    set_label_text_if_changed(network_detail_path_values[5], qos_sample);
    }

    if (network_identity_page) {
    set_label_text_if_changed(network_identity_sim_values[0], sim_type_text(modem));
    set_label_text_if_changed(network_identity_sim_values[1],
                              modem->sim_ready ? "已就绪" : "未就绪");
    set_label_text_if_changed(network_identity_sim_values[2],
                              modem->msisdn[0] ? modem->msisdn : "--");
    set_label_text_if_changed(network_identity_sim_values[3],
                              modem->iccid[0] ? modem->iccid : "--");
    set_label_text_if_changed(network_identity_sim_values[4],
                              modem->imsi[0] ? modem->imsi : "--");
    set_label_text_if_changed(network_identity_sim_values[5],
                              modem->imei[0] ? modem->imei : "--");
    snprintf(module_text, sizeof(module_text), "%s · %s",
             network_module_ids[network_detail_index],
             network_slot_titles[network_detail_index]);
    if (backend_index == 0) safe_copy(usb_text, sizeof(usb_text), "内置");
    else snprintf(usb_text, sizeof(usb_text), "%s · %s · %s",
                  modem->usb_id[0] ? modem->usb_id : "--",
                  modem->usb_present ? "在线" : "离线",
                  modem->usb_carrier ? "载波正常" : "无载波");
    if (backend_index == 0) safe_copy(debug_text, sizeof(debug_text), "不适用");
    else snprintf(debug_text, sizeof(debug_text), "%s · %s",
                  modem->debug_transport[0] ? modem->debug_transport : "ADB",
                  modem->debug_available ? "可用" : "不可用");
    set_label_text_if_changed(network_identity_module_values[0], module_text);
    set_label_text_if_changed(network_identity_module_values[1],
                              modem->ifname[0] ? modem->ifname : "--");
    set_label_text_if_changed(network_identity_module_values[2],
                              modem->wan_interface[0] ? modem->wan_interface : "--");
    set_label_text_if_changed(network_identity_module_values[3],
                              modem->transport[0] ? modem->transport : "--");
    set_label_text_if_changed(network_identity_module_values[4], usb_text);
    set_label_text_if_changed(network_identity_module_values[5], debug_text);
    set_label_text_if_changed(network_identity_module_values[6],
                              modem->debug_serial[0] ? modem->debug_serial : "--");
    }
}

static int create_network_detail_tab_content(int tab);

static void destroy_network_detail_tab_content(void)
{
    lv_obj_t *content = network_detail_radio_page ? network_detail_radio_page :
                        (network_detail_network_page ? network_detail_network_page :
                         (network_detail_traffic_page ? network_detail_traffic_page :
                          network_detail_trend_page));
    if (content && lv_obj_del_p) lv_obj_del_p(content);
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
