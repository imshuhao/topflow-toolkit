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
    json_string(json, "overflow", status->overflow, sizeof(status->overflow));
    json_string(json, "tcp_state", status->tcp_state, sizeof(status->tcp_state));
    json_string(json, "udp_state", status->udp_state, sizeof(status->udp_state));
    json_string(json, "tcp_live", status->tcp_live, sizeof(status->tcp_live));
    json_string(json, "udp_live", status->udp_live, sizeof(status->udp_live));
    if (!status->preset[0])
        safe_copy(status->preset, sizeof(status->preset), "unknown");
    wall = time(NULL);
    localtime_r(&wall, &local);
    snprintf(status->updated, sizeof(status->updated), "%02d:%02d:%02d",
             local.tm_hour, local.tm_min, local.tm_sec);
    status->valid = 1;
    return 1;
}

/* 池掩码（bit0=5G bit1=4G#1 bit2=4G#2）→ 管理端 CSV，顺序固定
 * zte_mwan2,zte_mwan3,zte_mwan4。空掩码写空串，由管理端报错。 */
static void wanbal_pool_csv(int mask, char *out, size_t size)
{
    static const char *const ifaces[3] = {"zte_mwan2", "zte_mwan3", "zte_mwan4"};
    size_t used = 0;
    int i;
    if (!out || !size) return;
    out[0] = '\0';
    for (i = 0; i < 3; i++) {
        int written;
        if (!((mask >> i) & 1)) continue;
        written = snprintf(out + used, size - used, "%s%s", used ? "," : "",
                           ifaces[i]);
        if (written < 0 || (size_t)written >= size - used) break;
        used += (size_t)written;
    }
}
