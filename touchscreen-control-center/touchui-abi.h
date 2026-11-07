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
typedef void (*obj_move_foreground_fn)(lv_obj_t *obj);
typedef void (*obj_invalidate_fn)(lv_obj_t *obj);
typedef void (*obj_set_scrollbar_mode_fn)(lv_obj_t *obj, uint8_t mode);
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
#define BALANCE_STATUS_PATH "/data/local/balance/status.json"
#define BALANCE_WATCH_SH "/data/local/balance/balance-watch.sh"
#define FAST_STATUS_INTERVAL_MS 1000LL
#define FULL_STATUS_INTERVAL_MS 5000LL
#define NETWORK_STATUS_INTERVAL_MS 1000LL
#define WIFI_STATUS_INTERVAL_MS 5000LL
#define BALANCE_STATUS_INTERVAL_MS 15000LL
#define STATUS_STALE_FAILURES 3
#define NETWORK_MODEM_COUNT 3
#define NETWORK_HTTP_MAX 65536
#define NETWORK_TREND_POINTS 60
#define NETWORK_EVENT_COUNT 6
#define STATUS_WORKER_STACK_SIZE (256u * 1024u)
#define DATAD_PORT 9460
#define LV_ALIGN_TOP_LEFT 1
#define LV_ALIGN_TOP_MID 2
#define LV_ALIGN_TOP_RIGHT 3
#define LV_ALIGN_BOTTOM_MID 5
#define LV_ALIGN_LEFT_MID 7
#define LV_ALIGN_RIGHT_MID 8
#define LV_ALIGN_CENTER 9
#define LV_SCROLLBAR_MODE_OFF 0
#define LV_OBJ_FLAG_SCROLL_ONE (1u << 8)
#define LV_OBJ_FLAG_CLICKABLE (1u << 1)
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

/* 日夜调色板（OpenDesign colors.md）。创建/刷新时读当前主题，勿写死旧常量。 */
struct touchui_palette {
    uint32_t bg;
    uint32_t card;
    uint32_t card_2;
    uint32_t border;
    uint32_t text;
    uint32_t muted;
    uint32_t message;
    uint32_t accent;
    uint32_t accent_ink;
    uint32_t accent_dark;
    uint32_t accent_soft;
    uint32_t segment;
    uint32_t ok;
    uint32_t warn;
    uint32_t danger;
    uint32_t ok_soft;
    uint32_t warn_soft;
    uint32_t danger_soft;
    uint32_t button;
    uint32_t button_pressed;
    uint32_t traffic_up;
    uint32_t traffic_down;
    uint32_t wifi;
    uint32_t track;
    uint32_t toast_bg;
    uint32_t toast_text;
};

static struct touchui_palette touchui_theme;
static int touchui_theme_is_day; /* 0=夜间（默认），1=日间 */

#define COLOR_BG (touchui_theme.bg)
#define COLOR_CARD (touchui_theme.card)
#define COLOR_CARD_ALT (touchui_theme.card_2)
#define COLOR_BORDER (touchui_theme.border)
#define COLOR_TEXT (touchui_theme.text)
#define COLOR_MUTED (touchui_theme.muted)
#define COLOR_MESSAGE (touchui_theme.message)
#define COLOR_ACCENT (touchui_theme.accent)
#define COLOR_ACCENT_DARK (touchui_theme.accent_dark)
#define COLOR_ACCENT_SOFT (touchui_theme.accent_soft)
#define COLOR_SEGMENT (touchui_theme.segment)
#define COLOR_GREEN (touchui_theme.ok)
#define COLOR_AMBER (touchui_theme.warn)
#define COLOR_RED (touchui_theme.danger)
#define COLOR_BUTTON (touchui_theme.button)
#define COLOR_BUTTON_PRESSED (touchui_theme.button_pressed)
#define COLOR_TRAFFIC_UP (touchui_theme.traffic_up)
#define COLOR_TRAFFIC_DOWN (touchui_theme.traffic_down)
#define COLOR_WIFI (touchui_theme.wifi)

/* 共享控件库里暂未被任何页面引用的工厂函数，用它避免 -Werror=unused-function */
#define TOUCHUI_HELPER static __attribute__((unused))

#define TOUCHUI_THEME_PATH "/data/touchscreen-control-center/theme"
/* 叠层几何：顶部 40px 共用状态栏；每个 page_shell root 是 320×440、位于 y=40；
 * root 内 0..44 为页头（返回 / 标题 / 主页），内容从 TOUCHUI_CONTENT_Y 起。 */
#define TOUCHUI_SB_H 40
#define TOUCHUI_HEAD_H 44
#define TOUCHUI_PAGE_H (480 - TOUCHUI_SB_H)
#define TOUCHUI_CONTENT_Y (TOUCHUI_HEAD_H + 8)
#define TOUCHUI_CONTENT_X 8
#define TOUCHUI_CONTENT_W 304
#define TOUCHUI_FOOTER_Y (TOUCHUI_PAGE_H - 30)

#endif
