#ifndef MU5252_TOUCHUI_MODEL_H
#define MU5252_TOUCHUI_MODEL_H

#define TOUCHUI_FAN_CURVE_MAX 8

enum action_id {
    ACTION_NONE = 0,
    ACTION_SERVICE_START,
    ACTION_SERVICE_STOP,
    ACTION_SERVICE_RESTART,
    ACTION_FAN_FACTORY,
    ACTION_FAN_CUSTOM,
    ACTION_FAN_ALWAYS,
    ACTION_FAN_OFF,
    ACTION_FAN_CURVE_APPLY,
    ACTION_LIQUID_AUTO,
    ACTION_LIQUID_LOW,
    ACTION_LIQUID_HIGH,
    ACTION_WIFI_APPLY,
    ACTION_STATE_REFRESH,
    ACTION_WAN_MODE_AUTO,
    ACTION_WAN_MODE_SHARED,
    ACTION_WAN_MODE_CUSTOM,
    ACTION_BALANCE_REFRESH,
    ACTION_ENGINE_SWITCHOVER,
    ACTION_ENGINE_ROLLBACK
};

enum page_id {
    PAGE_STOCK = 0,
    PAGE_MENU,
    PAGE_NETWORK,
    PAGE_NETWORK_DETAIL,
    PAGE_NETWORK_IDENTITY,
    PAGE_SINGBOX,
    PAGE_WANBAL,
    PAGE_BALANCE,
    PAGE_DEVICE,
    PAGE_COOLING_CURVE,
    PAGE_DIAGNOSTICS,
    PAGE_CHARGE
};

enum traffic_direction {
    TRAFFIC_DOWN = 0,
    TRAFFIC_UP = 1
};

struct traffic_value_component {
    lv_obj_t *icon;
    lv_obj_t *label;
};

struct signal_icon_component {
    lv_obj_t *image;
    int state;
};

struct fan_curve_point_status {
    int temperature;
    int hysteresis;
    int pwm;
    int speed_percent;
};

struct singbox_status {
    int valid;
    int stale;
    int service_running;
    int api_ok;
    int tun_up;
    int capture_ok;
    int dhcp_ok;
    int providers;
    int watchdog_running;
    int keeper_running;
    int manual_stop;
    int mihomo_running;
    int dhcp_points_to_mihomo;
    long rss_kb;
    unsigned long long rx_bytes;
    unsigned long long tx_bytes;
    unsigned long long rx_rate;
    unsigned long long tx_rate;
    char service_state[20];
    char version[32];
    char tun_addr[40];
    char inbound_mode[8];
    char capture_plane[24];
    char engine[16];
    char updated[16];
};

/* WAN balance preset shown on the 分流 page (auto | shared | custom). */
struct wanbal_status {
    int valid;
    int stale;
    char preset[16];
    char mode[16];
    char tcp_pool[64];
    char udp_pool[64];
    char tcp_weights[96];
    char udp_weights[96];
    char degraded[64];
    char quality[4];
    char bias[4];
    /* 手动选池（preset=custom）：overflow 为 0/1；tcp_state/udp_state 是
     * ok|partial|blocked|spill|unknown；tcp_live/udp_live 是选中池里在线卡数。 */
    char overflow[8];
    char tcp_state[12];
    char udp_state[12];
    char tcp_live[8];
    char udp_live[8];
    char updated[16];
};

#define BALANCE_CARD_COUNT 2

struct balance_card_status {
    int ok;
    char id[40];
    char operator_name[16];
    char label[40];
    char phone_tail[8];
    char error[96];
    long general_remain_kb;
    long general_total_kb;
    long general_used_kb;
    long directed_remain_kb;
    long directed_total_kb;
    long directed_used_kb;
    int directed_unlimited;
    long directed_unlimit_used_kb;
    long jump_delta_kb;
    long free_delta_kb;
    long jump_today_kb;
};

/* Carrier package remain / jump-point snapshot from /data/local/balance. */
struct balance_status {
    int valid;
    int stale;
    int ok;
    int card_count;
    int interval_sec;
    char updated[16];   /* 本次查询 HH:MM:SS */
    char next[16];      /* 下次查询 HH:MM:SS */
    char error[96];
    struct balance_card_status cards[BALANCE_CARD_COUNT];
};

struct modem_status {
    int valid;
    int online;
    int ipv4_up;
    int ipv6_up;
    int sim_slot;
    char sim_type[8];
    int sim_ready;
    int temperature;
    int temperature_valid;
    int path_valid;
    int path_online;
    int path_loss_valid;
    int path_latency_valid;
    int rssi;
    int bars;
    int roaming;
    int rsrp;
    int rsrq;
    double snr;
    int pci;
    long channel;
    int qci;
    double ambr_dl;
    double ambr_ul;
    int ambr_dl_valid;
    int ambr_ul_valid;
    int usb_present;
    int usb_carrier;
    int debug_available;
    int ca_carriers;
    long ipv4_mask;
    long ipv6_mask;
    unsigned long long qos_sampled_at;
    unsigned long long rx_rate;
    unsigned long long tx_rate;
    unsigned long long max_rx_rate;
    unsigned long long max_tx_rate;
    unsigned long long rx_bytes;
    unsigned long long tx_bytes;
    unsigned long long cell_id;
    unsigned long long session_time;
    unsigned long long path_uptime;
    double path_loss;
    double path_latency;
    char type[16];
    char operator_name[48];
    char band[24];
    char bandwidth[16];
    char plmn[32];
    char net_select[32];
    char sim_state[40];
    char ifname[32];
    char wan_interface[32];
    char transport[16];
    char ipv4_address[64];
    char ipv6_address[80];
    char ipv4_device[32];
    char ipv6_device[32];
    char ipv4_dns[96];
    char ipv6_dns[128];
    char target_status[3][16];
    char ca_type[8];
    char iccid[32];
    char imsi[32];
    char msisdn[64];
    char imei[32];
    char usb_path[16];
    char usb_id[20];
    char debug_transport[16];
    char debug_serial[32];
};

struct device_status {
    int valid;
    char kernel_release[48];
    char os_release[48];
    long uptime;
    int cpu_usage;
    int cpu_temp;
    int mem_used_pct;
    unsigned long long mem_total;
    unsigned long long mem_avail;
    unsigned long long storage_total;
    unsigned long long storage_used;
    unsigned long long storage_avail;
    int battery_percent;
    int battery_temp;
    int battery_online;
    int battery_health;
    int battery_charging;
    int charger_connected;
    long charger_uv;
    long charger_ua;
    long battery_uv;
    long battery_ua;
    unsigned long long traffic_rx_rate;
    unsigned long long traffic_tx_rate;
    unsigned long long traffic_day_rx;
    unsigned long long traffic_day_tx;
    unsigned long long traffic_month_rx;
    unsigned long long traffic_month_tx;
    unsigned long long traffic_total_rx;
    unsigned long long traffic_total_tx;
    int traffic_limit_enabled;
    int traffic_limit_type;
    unsigned long long traffic_limit_value;
    int traffic_limit_ratio;
    int traffic_limit_overflow;
    int traffic_clear_enabled;
    int traffic_clear_day;
    int fan_enabled;
    int fan_always_on;
    int fan_thermal_enabled;
    int fan_kernel_zone_enabled;
    int fan_pwm;
    int fan_speed_percent;
    int fan_temperature;
    int fan_hard_full_speed_temperature;
    char fan_mode[16];
    int fan_factory_curve_count;
    int fan_custom_curve_count;
    struct fan_curve_point_status fan_factory_curve[TOUCHUI_FAN_CURVE_MAX];
    struct fan_curve_point_status fan_custom_curve[TOUCHUI_FAN_CURVE_MAX];
    int liquid_enabled;
    int liquid_always_on;
    int liquid_thermal_enabled;
    int liquid_level;
    int liquid_speed_percent;
    int liquid_amplitude;
    char liquid_mode[16];
    int sms_unread;
    int nfc_enabled;
};

static inline int fan_custom_curve_is_off(const struct device_status *device)
{
    int i;
    if (!device || strcmp(device->fan_mode, "custom")) return 0;
    if (device->fan_custom_curve_count < 1) return 1;
    for (i = 0; i < device->fan_custom_curve_count; i++) {
        if (device->fan_custom_curve[i].pwm > 0) return 0;
    }
    return 1;
}

struct wifi_power_band_status {
    int valid;
    int enabled;
    int percent;
    int txpower_dbm;
    int limit_dbm;
    int factory_limit_dbm;
};

struct wifi_power_status {
    int valid;
    struct wifi_power_band_status bands[2];
};

struct network_event {
    char time[12];
    char text[72];
};

struct modem_history {
    int count;
    int next;
    int initialized;
    int rsrp[NETWORK_TREND_POINTS];
    int snr_tenths[NETWORK_TREND_POINTS];
    unsigned long long rx_rate[NETWORK_TREND_POINTS];
    unsigned long long tx_rate[NETWORK_TREND_POINTS];
    int last_online;
    unsigned long long last_cell_id;
    char last_type[16];
    char last_band[24];
    char last_operator[48];
    struct network_event events[NETWORK_EVENT_COUNT];
    int event_count;
    int event_next;
};

struct network_status {
    int valid;
    int stale;
    struct modem_status modems[NETWORK_MODEM_COUNT];
    struct device_status device;
    char updated[16];
};

struct page_shell {
    lv_obj_t *root;
    lv_obj_t *title_label;
    lv_obj_t *footer_label;
    lv_obj_t *clock_label;
    enum page_id id;
};

/* 原型里的「徽标 / 胶囊」：圆角底 + 居中文字（badge.ok / warn / soft …）。 */
struct badge_component {
    lv_obj_t *panel;
    lv_obj_t *label;
};

/* 原型里的水平进度条（有效权重、电量条）：轨道 + 填充。 */
struct hbar_component {
    lv_obj_t *track;
    lv_obj_t *fill;
    int width;
    int height;
};

/* 运行时位图图标（原型 SVG 线稿的替代）：ASCII 行阵 → RGB565+alpha。 */
#define TOUCHUI_GLYPH_MAX_SIDE 32
struct glyph_image {
    uint32_t header;
    uint32_t data_size;
    const unsigned char *data;
};

struct menu_module {
    const char *title;
    const char *description;
    void (*open)(void *event);
};

#endif
