static void extract_version(const char *line, char *out, size_t size)
{
    const char *start = line;
    size_t length = 0;
    if (!strncmp(start, "sing-box ", 9)) start += 9;
    else if (!strncmp(start, "mihomo ", 7)) start += 7;
    while (start[length] && start[length] != ' ' && length + 1 < size) length++;
    if (!length) { safe_copy(out, size, "未知"); return; }
    /* Keep engine tag in the short label: "1.14.4-reF1nd" / "v1.19.27". */
    memcpy(out, start, length);
    out[length] = '\0';
}

static int collect_singbox_status(struct singbox_status *status)
{
    char json[4096], version_line[192];
    memset(status, 0, sizeof(*status));
    safe_copy(status->version, sizeof(status->version), "未知");
    if (run_singbox_manager(json, sizeof(json), "status", NULL) != 0 ||
        !json_bool(json, "ok", 0)) return 0;
    status->service_running = json_bool(json, "service_running", 0);
    status->api_ok = json_bool(json, "api_ok", 0);
    status->tun_up = json_bool(json, "tun_up", 0);
    status->dhcp_ok = json_bool(json, "dhcp_gateway_ok", 0) &&
                      json_bool(json, "dhcp_dns_ok", 0);
    status->providers = (int)json_long(json, "providers", 0);
    status->watchdog_running = json_bool(json, "watchdog_running", 0);
    status->keeper_running = json_bool(json, "keeper_running", 0);
    status->manual_stop = json_bool(json, "manual_stop", 0);
    status->mihomo_running = json_bool(json, "mihomo_running", 0);
    status->dhcp_points_to_mihomo =
        json_bool(json, "dhcp_points_to_mihomo", 0);
    if (!json_string(json, "engine", status->engine, sizeof(status->engine)) ||
        !status->engine[0]) {
        if (status->service_running)
            safe_copy(status->engine, sizeof(status->engine), "sing-box");
        else if (status->mihomo_running || status->dhcp_points_to_mihomo)
            safe_copy(status->engine, sizeof(status->engine), "mihomo");
        else
            safe_copy(status->engine, sizeof(status->engine), "none");
    }
    /* DHCP already on 0.254 with no process → still mihomo context (broken). */
    if (!status->service_running && status->dhcp_points_to_mihomo &&
        strcmp(status->engine, "sing-box") != 0)
        safe_copy(status->engine, sizeof(status->engine), "mihomo");
    if (!json_string(json, "capture_plane", status->capture_plane,
                     sizeof(status->capture_plane)))
        status->capture_plane[0] = '\0';
    status->rss_kb = json_long(json, "rss_kb", 0);
    status->rx_bytes = (unsigned long long)json_ull(json, "download_total", 0);
    status->tx_bytes = (unsigned long long)json_ull(json, "upload_total", 0);
    json_string(json, "service_state", status->service_state,
                sizeof(status->service_state));
    json_string(json, "tun_addr", status->tun_addr, sizeof(status->tun_addr));
    if (!json_string(json, "inbound_mode", status->inbound_mode,
                     sizeof(status->inbound_mode)) ||
        !status->inbound_mode[0])
        safe_copy(status->inbound_mode, sizeof(status->inbound_mode), "tun");
    /* Prefer capture_ok; if absent, derive from mode so eBPF (!sbtun0) is not
     * false-alarmed as TUN-down. Pure TUN-era managers lack both fields and
     * keep the historical tun_up gate. */
    {
        const char *capture_probe;
        if (json_value(json, "capture_ok", &capture_probe))
            status->capture_ok = json_bool(json, "capture_ok", 0);
        else if (!strcmp(status->inbound_mode, "ebpf"))
            status->capture_ok = status->service_running && status->api_ok &&
                                 !status->tun_up;
        else
            status->capture_ok = status->tun_up;
    }
    if (json_string(json, "version", version_line, sizeof(version_line)))
        extract_version(version_line, status->version, sizeof(status->version));
    status->valid = 1;
    return 1;
}
