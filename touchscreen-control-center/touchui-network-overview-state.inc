static void refresh_network_ui(void)
{
    struct network_status status;
    int generation;
    pthread_mutex_lock(&shared_lock);
    generation = shared_network_generation;
    if (generation == ui_network_generation) {
        pthread_mutex_unlock(&shared_lock);
        return;
    }
    status = shared_network_status;
    pthread_mutex_unlock(&shared_lock);
    ui_network_generation = generation;
    ui_network_status = status;
    update_network_history(&status);

    if (network_page) for (int i = 0; i < NETWORK_MODEM_COUNT; i++) {
        struct modem_status *modem = &status.modems[network_backend_index(i)];
        char text[96], band[32], rsrp[16], snr[16], down[24], up[24];
        uint32_t dot_color = status.stale ? COLOR_AMBER :
                             (modem->online ? COLOR_GREEN : COLOR_RED);
        set_network_dot_color(i, modem->valid ? dot_color : COLOR_MUTED);
        set_stock_signal_icon(&network_signal_icon[i], modem->valid,
                              modem->online, modem->bars, modem->roaming);
        set_operator_label_text(network_summary_label[i], status.valid ?
                                display_operator_name(modem->operator_name) : "读取中…");
        short_band_name(modem->band, band, sizeof(band));
        snprintf(text, sizeof(text), "%s · %s", modem->type[0] ? modem->type : "离线", band);
        set_label_text_if_changed(network_signal_label[i], status.valid ? text : "-- · --");
        format_metric_int(modem->rsrp, rsrp, sizeof(rsrp));
        if (status.valid && strcmp(rsrp, "--") != 0)
            snprintf(text, sizeof(text), "%s dBm", rsrp);
        else safe_copy(text, sizeof(text), "-- dBm");
        set_label_text_if_changed(network_traffic_label[i], text);
        format_metric_double(modem->snr, snr, sizeof(snr));
        if (status.valid && strcmp(snr, "--") != 0)
            snprintf(text, sizeof(text), "%s dB", snr);
        else safe_copy(text, sizeof(text), "-- dB");
        set_label_text_if_changed(network_snr_label[i], text);
        format_rate_compact(modem->rx_rate, down, sizeof(down));
        format_rate_compact(modem->tx_rate, up, sizeof(up));
        set_traffic_value(&network_down[i], status.valid ? down : "--");
        set_traffic_value(&network_up[i], status.valid ? up : "--");
    }
    if (network_detail_page) refresh_network_detail_ui();
    refresh_device_ui();
}
