static int collect_wanbal_status(struct wanbal_status *status)
{
    char json[2048];
    struct tm local;
    time_t wall;
    memset(status, 0, sizeof(*status));
    safe_copy(status->preset, sizeof(status->preset), "unknown");
    safe_copy(status->mode, sizeof(status->mode), "unknown");
    if (run_singbox_manager(json, sizeof(json), "wan-mode-status", NULL) != 0 ||
        !json_bool(json, "ok", 0))
        return 0;
    json_string(json, "preset", status->preset, sizeof(status->preset));
    json_string(json, "mode", status->mode, sizeof(status->mode));
    json_string(json, "tcp_pool", status->tcp_pool, sizeof(status->tcp_pool));
    json_string(json, "udp_pool", status->udp_pool, sizeof(status->udp_pool));
    json_string(json, "tcp_weights", status->tcp_weights, sizeof(status->tcp_weights));
    json_string(json, "udp_weights", status->udp_weights, sizeof(status->udp_weights));
    json_string(json, "degraded", status->degraded, sizeof(status->degraded));
    json_string(json, "quality", status->quality, sizeof(status->quality));
    json_string(json, "bias", status->bias, sizeof(status->bias));
    if (!status->preset[0])
        safe_copy(status->preset, sizeof(status->preset), "unknown");
    wall = time(NULL);
    localtime_r(&wall, &local);
    snprintf(status->updated, sizeof(status->updated), "%02d:%02d:%02d",
             local.tm_hour, local.tm_min, local.tm_sec);
    status->valid = 1;
    return 1;
}
