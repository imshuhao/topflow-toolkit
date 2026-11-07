#ifndef MU5252_TOUCHUI_STATE_H
#define MU5252_TOUCHUI_STATE_H

static void trace_ui_create(const char *stage);

static timer_handler_fn real_timer_handler;
static disp_get_default_fn lv_disp_get_default_p;
static disp_get_layer_top_fn lv_disp_get_layer_top_p;
static disp_get_scr_act_fn lv_disp_get_scr_act_p;
static obj_create_fn lv_obj_create_p, lv_btn_create_p, lv_label_create_p, lv_img_create_p;
static obj_create_fn lv_imgbtn_create_p;
static obj_del_fn lv_obj_del_p;
static img_set_src_fn lv_img_set_src_p;
static img_set_zoom_fn lv_img_set_zoom_p;
static imgbtn_set_src_fn lv_imgbtn_set_src_p;
static obj_get_child_cnt_fn lv_obj_get_child_cnt_p;
static obj_get_child_fn lv_obj_get_child_p;
static obj_has_flag_query_fn lv_obj_has_flag_p;
static label_set_text_fn lv_label_set_text_p;
static label_get_text_fn lv_label_get_text_p;
static label_set_long_mode_fn lv_label_set_long_mode_p;
static obj_set_size_fn lv_obj_set_size_p;
static obj_set_pos_fn lv_obj_set_pos_p;
static obj_align_fn lv_obj_align_p;
static obj_update_layout_fn lv_obj_update_layout_p;
static obj_add_event_cb_fn lv_obj_add_event_cb_p;
static obj_flag_fn lv_obj_add_flag_p, lv_obj_clear_flag_p;
static obj_state_fn lv_obj_add_state_p, lv_obj_clear_state_p;
static obj_move_foreground_fn lv_obj_move_foreground_p;
static obj_invalidate_fn lv_obj_invalidate_p;
static obj_set_scrollbar_mode_fn lv_obj_set_scrollbar_mode_p;
static obj_style_coord_fn lv_obj_set_style_radius_p;
static obj_style_coord_fn lv_obj_set_style_border_width_p;
static obj_style_coord_fn lv_obj_set_style_shadow_width_p;
static obj_style_coord_fn lv_obj_set_style_pad_left_p;
static obj_style_coord_fn lv_obj_set_style_pad_right_p;
static obj_style_coord_fn lv_obj_set_style_pad_top_p;
static obj_style_coord_fn lv_obj_set_style_pad_bottom_p;
static obj_style_coord_fn lv_obj_set_style_text_align_p;
static obj_style_color_fn lv_obj_set_style_bg_color_p;
static obj_style_color_fn lv_obj_set_style_border_color_p;
static obj_style_color_fn lv_obj_set_style_shadow_color_p;
static obj_style_color_fn lv_obj_set_style_text_color_p;
static obj_style_opa_fn lv_obj_set_style_bg_opa_p;
static obj_style_opa_fn lv_obj_set_style_shadow_opa_p;
static obj_set_style_text_font_fn real_obj_set_style_text_font;
static ft_font_init_fn lv_ft_font_init_p;
static chart_create_fn lv_chart_create_p;
static chart_set_type_fn lv_chart_set_type_p;
static chart_set_point_count_fn lv_chart_set_point_count_p;
static chart_set_range_fn lv_chart_set_range_p;
static chart_add_series_fn lv_chart_add_series_p;
static chart_set_next_value_fn lv_chart_set_next_value_p;
static chart_refresh_fn lv_chart_refresh_p;
static obj_check_type_fn lv_obj_check_type_p;
static obj_get_coords_fn lv_obj_get_coords_p;
static const void *lv_label_class_p;
static obj_get_parent_fn lv_obj_get_parent_p;
static const void *ui_font, *ui_font_tiny, *ui_font_small, *ui_font_large;
static const void *ui_font_xlarge;
static lv_ft_info_compat_t ui_font_info = {
    .name = "/usr/ui/fonts/ZTEZhengYuan.ttf",
    .weight = 18,
    .style = 0
};
static lv_ft_info_compat_t ui_font_tiny_info = {
    .name = "/usr/ui/fonts/ZTEZhengYuan.ttf",
    .weight = 14,
    .style = 0
};
static lv_ft_info_compat_t ui_font_small_info = {
    .name = "/usr/ui/fonts/ZTEZhengYuan.ttf",
    .weight = 16,
    .style = 0
};
static lv_ft_info_compat_t ui_font_large_info = {
    .name = "/usr/ui/fonts/ZTEZhengYuan.ttf",
    .weight = 24,
    .style = 0
};
static lv_ft_info_compat_t ui_font_xlarge_info = {
    .name = "/usr/ui/fonts/ZTEZhengYuan.ttf",
    .weight = 28,
    .style = 0
};

static lv_obj_t *control_center_button, *menu_page, *manager_page;
static lv_obj_t *wanbal_page, *network_page;
static lv_obj_t *network_detail_page, *network_identity_page;
static lv_obj_t *device_page, *cooling_curve_page, *diagnostics_page;
static lv_obj_t *charge_page;
static struct page_shell menu_shell, singbox_shell, network_shell, network_detail_shell;
static struct page_shell network_identity_shell;
static struct page_shell device_shell, cooling_curve_shell, diagnostics_shell;
static struct page_shell charge_shell;
static enum page_id current_page = PAGE_STOCK;
static lv_obj_t *confirm_scrim, *confirm_panel, *status_indicator;
static lv_obj_t *status_label, *status_mode_label, *version_label, *memory_label;
static lv_obj_t *tun_value_label, *dhcp_value_label;
static lv_obj_t *providers_label, *watchdog_label, *keeper_label;
static struct traffic_value_component traffic_rate_down, traffic_rate_up;
static struct traffic_value_component traffic_total_down, traffic_total_up;
static lv_obj_t *message_label, *updated_label;
static lv_obj_t *service_button, *service_button_label;
static lv_obj_t *restart_button, *restart_button_label;
static lv_obj_t *engine_to_singbox_button, *engine_to_singbox_label;
static lv_obj_t *engine_to_mihomo_button, *engine_to_mihomo_label;
static lv_obj_t *confirm_text_label;
static int confirm_step;
static lv_obj_t *network_dot[NETWORK_MODEM_COUNT];
static lv_obj_t *network_header_label[NETWORK_MODEM_COUNT];
static lv_obj_t *network_summary_label[NETWORK_MODEM_COUNT];
static lv_obj_t *network_signal_label[NETWORK_MODEM_COUNT];
static struct signal_icon_component network_signal_icon[NETWORK_MODEM_COUNT];
static lv_obj_t *network_traffic_label[NETWORK_MODEM_COUNT];
static lv_obj_t *network_snr_label[NETWORK_MODEM_COUNT];
static lv_obj_t *network_rsrp_caption[NETWORK_MODEM_COUNT];
static lv_obj_t *network_snr_caption[NETWORK_MODEM_COUNT];
static struct traffic_value_component network_down[NETWORK_MODEM_COUNT];
static struct traffic_value_component network_up[NETWORK_MODEM_COUNT];
static lv_obj_t *network_updated_label;
static lv_obj_t *network_detail_dot, *network_detail_status_label;
static lv_obj_t *network_detail_sim_label, *network_detail_band_label;
static lv_obj_t *network_detail_radio_button, *network_detail_network_button;
static lv_obj_t *network_detail_traffic_button;
static lv_obj_t *network_detail_trend_button;
static lv_obj_t *network_detail_radio_page, *network_detail_network_page;
static lv_obj_t *network_detail_traffic_page;
static lv_obj_t *network_detail_trend_page;
static lv_obj_t *network_trend_rsrp_chart, *network_trend_traffic_chart;
static void *network_trend_rsrp_series, *network_trend_rx_series;
static void *network_trend_tx_series;
static lv_obj_t *network_trend_signal_summary, *network_trend_rate_summary;
static lv_obj_t *network_trend_event_labels[2];
static lv_obj_t *network_detail_signal_values[4];
static lv_obj_t *network_detail_signal_captions[4];
static lv_obj_t *network_detail_radio_values[2];
static lv_obj_t *network_detail_session_value;
static lv_obj_t *network_detail_address_values[5];
static lv_obj_t *network_detail_path_values[6];
static struct traffic_value_component network_detail_rate_down, network_detail_rate_up;
static struct traffic_value_component network_detail_peak_down, network_detail_peak_up;
static struct traffic_value_component network_detail_total_down, network_detail_total_up;
static lv_obj_t *network_identity_sim_values[6];
static lv_obj_t *network_identity_module_values[7];
static lv_obj_t *menu_device_alert_badge, *menu_device_alert_label;
static lv_obj_t *menu_proxy_dot;
static lv_obj_t *menu_home_status_label;
static lv_obj_t *menu_theme_tile_label;
static lv_obj_t *menu_tiles[9];
static int menu_tile_empty[9];
static lv_obj_t *statusbar_root;
static lv_obj_t *statusbar_clock;
static lv_obj_t *statusbar_battery_label;
static lv_obj_t *statusbar_sig_label[NETWORK_MODEM_COUNT];
static lv_obj_t *statusbar_sig_bar[NETWORK_MODEM_COUNT][4];
static lv_obj_t *device_alert_dot, *device_alert_label, *device_message_label;
static lv_obj_t *device_tab_buttons[4], *device_tab_content;
static lv_obj_t *device_system_values[9];
static struct traffic_value_component device_traffic_values[8];
static lv_obj_t *device_fan_status, *device_fan_detail;
static lv_obj_t *device_liquid_status, *device_liquid_detail;
static lv_obj_t *device_fan_buttons[4], *device_liquid_buttons[3];
static lv_obj_t *cooling_curve_summary, *cooling_curve_point_label;
static lv_obj_t *cooling_curve_temperature_value, *cooling_curve_speed_value;
static lv_obj_t *cooling_curve_message_label, *cooling_curve_chart;
static lv_obj_t *cooling_curve_profile_buttons[2];
static lv_obj_t *cooling_curve_factory_content, *cooling_curve_custom_content;
static lv_obj_t *cooling_curve_factory_temperature[3];
static lv_obj_t *cooling_curve_factory_speed[3];
static void *cooling_curve_series;
static lv_obj_t *device_wifi_band_buttons[2];
static lv_obj_t *device_wifi_header, *device_wifi_state;
static lv_obj_t *device_wifi_percent_value, *device_wifi_limit_value;
static lv_obj_t *device_wifi_restore_button, *device_wifi_apply_button;
static lv_obj_t *diagnostic_overall_label;
static lv_obj_t *diagnostic_values[6];
static struct modem_history network_history[NETWORK_MODEM_COUNT];

static pthread_mutex_t shared_lock = PTHREAD_MUTEX_INITIALIZER;
static struct singbox_status shared_status, ui_status;
static struct wanbal_status shared_wanbal_status, ui_wanbal_status;
static struct network_status shared_network_status, ui_network_status;
static struct wifi_power_status shared_wifi_power_status, ui_wifi_power_status;
static char shared_message[160];
static enum page_id shared_message_page = PAGE_STOCK;
static int shared_generation, shared_action, shared_action_running, force_refresh;
static int shared_running_action;
static int shared_action_band, shared_action_value, shared_action_value2;
static int shared_action_curve_count;
static struct fan_curve_point_status shared_action_curve[TOUCHUI_FAN_CURVE_MAX];
static int shared_action_fan_need_default;
static int force_network_refresh;
static int force_wanbal_refresh;
static int shared_network_generation;
static int shared_wifi_generation;
static int shared_wanbal_generation;
static int ui_generation = -1;
static int confirm_action, overlay_state, worker_started;
static int ui_network_generation = -1;
static int ui_wifi_generation = -1;
static int ui_wanbal_generation = -1;
static int network_detail_index;
static int network_detail_tab;
static int pending_network_view;
static int pending_singbox_open;
static int pending_wanbal_open;
static int pending_charge_open;
static int pending_device_view;
static int pending_extension_cleanup;
static int device_tab;
static int device_wifi_band = 1;
static int device_wifi_draft_percent[2], device_wifi_draft_limit[2];
static int device_wifi_draft_valid[2], device_wifi_draft_dirty[2];
static int pending_wifi_band, pending_wifi_value, pending_wifi_value2;
static int cooling_curve_draft_count, cooling_curve_active_point;
static int cooling_curve_draft_valid, cooling_curve_draft_dirty;
static int cooling_curve_profile;
static struct fan_curve_point_status cooling_curve_draft[TOUCHUI_FAN_CURVE_MAX];
static lv_obj_t *network_parent;
static int native_lock_state = -1;
static unsigned int timer_calls;

static void request_network_overview(void);
static void request_network_detail(void);
static void request_singbox_page(void);
static void request_wanbal_page(void);
static void request_charge_page(void);
static void destroy_singbox_page(void);
static void destroy_wanbal_page(void);
static void destroy_charge_page(void);
static void refresh_charge_ui(void);
static int create_charge_page(lv_obj_t *top);
static void destroy_network_overview(void);
static void destroy_network_detail(void);
static void destroy_network_identity(void);
static void process_network_navigation(void);
static void process_device_navigation(void);
static void refresh_device_ui(void);
static void refresh_wanbal_ui(void);
static void destroy_device_pages(void);
static void open_device_clicked(void *event);
static void device_refresh_clicked(void *event);
static void show_device_tab(int tab);
static void refresh_wifi_power_ui(void);
static void refresh_cooling_curve_ui(void);

#endif
