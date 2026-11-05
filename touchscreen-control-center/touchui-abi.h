#ifndef MU5252_TOUCHUI_ABI_H
#define MU5252_TOUCHUI_ABI_H

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

typedef struct _lv_obj_t lv_obj_t;
typedef struct _lv_disp_t lv_disp_t;
typedef uint16_t lv_color_compat_t;
typedef struct { int32_t x1, y1, x2, y2; } lv_area_compat_t;
typedef int (*obj_check_type_fn)(const lv_obj_t *obj, const void *class_p);
typedef lv_obj_t *(*obj_get_parent_fn)(const lv_obj_t *obj);
typedef void (*obj_get_coords_fn)(const lv_obj_t *obj, lv_area_compat_t *area);

typedef uint32_t (*timer_handler_fn)(void);
typedef lv_disp_t *(*disp_get_default_fn)(void);
typedef lv_obj_t *(*disp_get_layer_top_fn)(lv_disp_t *disp);
typedef lv_obj_t *(*disp_get_scr_act_fn)(lv_disp_t *disp);
typedef lv_obj_t *(*obj_create_fn)(lv_obj_t *parent);
typedef void (*img_set_src_fn)(lv_obj_t *obj, const void *src);
typedef void (*img_set_zoom_fn)(lv_obj_t *obj, uint16_t zoom);
typedef void (*imgbtn_set_src_fn)(lv_obj_t *obj, int state,
                                  const void *left, const void *middle,
                                  const void *right);
typedef uint32_t (*obj_get_child_cnt_fn)(const lv_obj_t *obj);
typedef lv_obj_t *(*obj_get_child_fn)(const lv_obj_t *obj, int32_t id);
typedef int (*obj_has_flag_query_fn)(const lv_obj_t *obj, uint32_t flag);
typedef void (*label_set_text_fn)(lv_obj_t *obj, const char *text);
typedef const char *(*label_get_text_fn)(const lv_obj_t *obj);
typedef void (*label_set_long_mode_fn)(lv_obj_t *obj, int mode);
typedef void (*obj_set_size_fn)(lv_obj_t *obj, int32_t w, int32_t h);
typedef void (*obj_set_pos_fn)(lv_obj_t *obj, int32_t x, int32_t y);
typedef void (*obj_align_fn)(lv_obj_t *obj, int align, int32_t x, int32_t y);
typedef void (*obj_update_layout_fn)(lv_obj_t *obj);
typedef void *(*obj_add_event_cb_fn)(lv_obj_t *obj, void (*cb)(void *event),
                                    int event_code, void *user_data);
typedef void (*obj_flag_fn)(lv_obj_t *obj, uint32_t flag);
typedef void (*obj_state_fn)(lv_obj_t *obj, uint16_t state);
typedef void (*obj_del_fn)(lv_obj_t *obj);
typedef void (*obj_style_coord_fn)(lv_obj_t *obj, int32_t value, uint32_t selector);
typedef void (*obj_style_color_fn)(lv_obj_t *obj, lv_color_compat_t value,
                                   uint32_t selector);
typedef void (*obj_style_opa_fn)(lv_obj_t *obj, uint8_t value, uint32_t selector);
typedef void (*obj_set_style_text_font_fn)(lv_obj_t *obj, const void *font,
                                           uint32_t selector);
typedef struct {
    const char *name;
    const void *mem;
    size_t mem_size;
    void *font;
    uint16_t weight;
    uint16_t style;
} lv_ft_info_compat_t;
typedef int (*ft_font_init_fn)(lv_ft_info_compat_t *info);
typedef lv_obj_t *(*chart_create_fn)(lv_obj_t *parent);
typedef void (*chart_set_type_fn)(lv_obj_t *chart, int type);
typedef void (*chart_set_point_count_fn)(lv_obj_t *chart, uint16_t count);
typedef void (*chart_set_range_fn)(lv_obj_t *chart, int axis,
                                   int32_t minimum, int32_t maximum);
typedef void *(*chart_add_series_fn)(lv_obj_t *chart, lv_color_compat_t color,
                                     int axis);
typedef void (*chart_set_next_value_fn)(lv_obj_t *chart, void *series,
                                        int32_t value);
typedef void (*chart_refresh_fn)(lv_obj_t *chart);

#define SINGBOX_MANAGER "/data/singbox-manager/singbox-manager.sh"
#define SINGBOX_PIDFILE "/data/sing-box/state/sing-box.pid"
#define FAST_STATUS_INTERVAL_MS 1000LL
#define FULL_STATUS_INTERVAL_MS 5000LL
#define NETWORK_STATUS_INTERVAL_MS 1000LL
#define WIFI_STATUS_INTERVAL_MS 5000LL
#define STATUS_STALE_FAILURES 3
#define NETWORK_MODEM_COUNT 3
#define NETWORK_HTTP_MAX 65536
#define NETWORK_TREND_POINTS 60
#define NETWORK_EVENT_COUNT 6
#define STATUS_WORKER_STACK_SIZE (256u * 1024u)
#define DATAD_PORT 9460
#define LV_ALIGN_TOP_MID 2
#define LV_ALIGN_CENTER 9
#define LV_EVENT_CLICKED 7
#define LV_LABEL_LONG_WRAP 0
#define LV_LABEL_LONG_SCROLL_CIRCULAR 3
#define LV_LABEL_LONG_CLIP 4
#define LV_TEXT_ALIGN_CENTER 1
#define LV_TEXT_ALIGN_RIGHT 2
#define LV_OBJ_FLAG_HIDDEN (1u << 0)
#define LV_OBJ_FLAG_SCROLLABLE (1u << 4)
#define LV_STATE_CHECKED 0x0001u
#define LV_STATE_PRESSED 0x0020u
#define LV_OPA_TRANSP 0u
#define LV_OPA_COVER 255u
#define LV_CHART_TYPE_LINE 1
#define LV_CHART_AXIS_PRIMARY_Y 0

#define COLOR_BG 0x000000u
#define COLOR_CARD 0x121316u
#define COLOR_CARD_ALT 0x121316u
#define COLOR_BORDER 0x24262Bu
#define COLOR_TEXT 0xF7F8FAu
#define COLOR_MUTED 0xB7BDC8u
#define COLOR_MESSAGE 0xC7CBD3u
#define COLOR_ACCENT 0x292B30u
#define COLOR_ACCENT_DARK 0x202226u
#define COLOR_ACCENT_SOFT 0x3D4047u
#define COLOR_SEGMENT 0x0B0C0Eu
#define COLOR_GREEN 0x32D583u
#define COLOR_AMBER 0xFBBF24u
#define COLOR_RED 0xF97066u
#define COLOR_BUTTON 0x1A1B1Fu
#define COLOR_BUTTON_PRESSED 0x24262Bu
#define COLOR_TRAFFIC_UP 0x31B6FFu
#define COLOR_TRAFFIC_DOWN 0x6BF700u
#define COLOR_WIFI 0x67E8F9u

#endif
