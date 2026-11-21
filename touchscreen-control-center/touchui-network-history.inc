static void add_network_event(struct modem_history *history,
                              const char *at, const char *text)
{
    struct network_event *event;
    if (!history || !text || !*text) return;
    event = &history->events[history->event_next];
    safe_copy(event->time, sizeof(event->time), at && *at ? at : "--:--:--");
    safe_copy(event->text, sizeof(event->text), text);
    history->event_next = (history->event_next + 1) % NETWORK_EVENT_COUNT;
    if (history->event_count < NETWORK_EVENT_COUNT) history->event_count++;
}

static void update_network_history(const struct network_status *status)
{
    for (int i = 0; i < NETWORK_MODEM_COUNT; i++) {
        const struct modem_status *modem = &status->modems[i];
        struct modem_history *history = &network_history[i];
        char text[72], old_band[32], new_band[32];
        int point = history->next;
        history->rsrp[point] = modem->rsrp;
        history->snr_tenths[point] = (int)(modem->snr * 10.0);
        history->rx_rate[point] = modem->rx_rate;
        history->tx_rate[point] = modem->tx_rate;
        history->next = (point + 1) % NETWORK_TREND_POINTS;
        if (history->count < NETWORK_TREND_POINTS) history->count++;
        if (!history->initialized) {
            history->initialized = 1;
        } else if (history->last_online != modem->online) {
            add_network_event(history, status->updated,
                              modem->online ? "网络恢复" : "网络离线");
        } else if (strcmp(history->last_type, modem->type) ||
                   strcmp(history->last_band, modem->band)) {
            short_band_name(history->last_band, old_band, sizeof(old_band));
            short_band_name(modem->band, new_band, sizeof(new_band));
            snprintf(text, sizeof(text), "%.15s %.15s → %.15s %.15s",
                     history->last_type[0] ? history->last_type : "--", old_band,
                     modem->type[0] ? modem->type : "--", new_band);
            add_network_event(history, status->updated, text);
        } else if (history->last_cell_id && modem->cell_id &&
                   history->last_cell_id != modem->cell_id) {
            snprintf(text, sizeof(text), "小区切换 0x%llX", modem->cell_id);
            add_network_event(history, status->updated, text);
        } else if (strcmp(history->last_operator, modem->operator_name)) {
            snprintf(text, sizeof(text), "运营商变更为 %s",
                     display_operator_name(modem->operator_name));
            add_network_event(history, status->updated, text);
        }
        history->last_online = modem->online;
        history->last_cell_id = modem->cell_id;
        safe_copy(history->last_type, sizeof(history->last_type), modem->type);
        safe_copy(history->last_band, sizeof(history->last_band), modem->band);
        safe_copy(history->last_operator, sizeof(history->last_operator),
                  modem->operator_name);
    }
}

static int history_value_index(const struct modem_history *history, int ordinal)
{
    int first;
    if (!history || ordinal < 0 || ordinal >= history->count) return 0;
    first = history->count == NETWORK_TREND_POINTS ? history->next : 0;
    return (first + ordinal) % NETWORK_TREND_POINTS;
}

static const struct network_event *history_event_at(
        const struct modem_history *history, int newest_offset)
{
    int index;
    if (!history || newest_offset < 0 || newest_offset >= history->event_count)
        return NULL;
    index = history->event_next - 1 - newest_offset;
    while (index < 0) index += NETWORK_EVENT_COUNT;
    return &history->events[index];
}

static void refresh_network_trend_ui(void)
{
    int backend, max_kib = 1;
    struct modem_history *history;
    struct modem_status *modem;
    char rsrp[24], snr[24], down[24], up[24], text[112];
    if (!network_detail_trend_page) return;
    backend = network_backend_index(network_detail_index);
    history = &network_history[backend];
    modem = &ui_network_status.modems[backend];
    format_metric_int(modem->rsrp, rsrp, sizeof(rsrp));
    format_metric_double(modem->snr, snr, sizeof(snr));
    snprintf(text, sizeof(text), "RSRP %s dBm · SNR %s dB", rsrp, snr);
    set_label_text_if_changed(network_trend_signal_summary, text);
    format_rate_compact(modem->rx_rate, down, sizeof(down));
    format_rate_compact(modem->tx_rate, up, sizeof(up));
    snprintf(text, sizeof(text), "↓ %s · ↑ %s", down, up);
    set_label_text_if_changed(network_trend_rate_summary, text);
    if (lv_chart_set_next_value_p && network_trend_rsrp_chart &&
        network_trend_rsrp_series) {
        lv_chart_set_next_value_p(network_trend_rsrp_chart,
            network_trend_rsrp_series, modem->rsrp ? modem->rsrp : -140);
        if (lv_chart_refresh_p) lv_chart_refresh_p(network_trend_rsrp_chart);
    }
    for (int i = 0; i < history->count; i++) {
        int index = history_value_index(history, i);
        int rx = (int)(history->rx_rate[index] / 1024ULL);
        int tx = (int)(history->tx_rate[index] / 1024ULL);
        if (rx > max_kib) max_kib = rx;
        if (tx > max_kib) max_kib = tx;
    }
    if (lv_chart_set_next_value_p && network_trend_traffic_chart &&
        network_trend_rx_series && network_trend_tx_series) {
        if (lv_chart_set_range_p)
            lv_chart_set_range_p(network_trend_traffic_chart,
                LV_CHART_AXIS_PRIMARY_Y, 0, max_kib + max_kib / 5 + 1);
        lv_chart_set_next_value_p(network_trend_traffic_chart,
            network_trend_rx_series, (int32_t)(modem->rx_rate / 1024ULL));
        lv_chart_set_next_value_p(network_trend_traffic_chart,
            network_trend_tx_series, (int32_t)(modem->tx_rate / 1024ULL));
        if (lv_chart_refresh_p) lv_chart_refresh_p(network_trend_traffic_chart);
    }
    for (int i = 0; i < 2; i++) {
        const struct network_event *event = history_event_at(history, i);
        if (event) snprintf(text, sizeof(text), "%s  %s", event->time, event->text);
        else safe_copy(text, sizeof(text), i ? "" : "暂无切换事件");
        set_label_text_if_changed(network_trend_event_labels[i], text);
    }
}
