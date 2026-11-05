/* Original 13x16 upload/download glyphs generated at runtime.
 * LVGL v8 true-color-alpha pixels are RGB565 little-endian plus alpha. */

struct touchui_img_dsc {
    uint32_t header;
    uint32_t data_size;
    const unsigned char *data;
};

#define TRAFFIC_ICON_WIDTH 13
#define TRAFFIC_ICON_HEIGHT 16
#define TRAFFIC_ICON_BYTES (TRAFFIC_ICON_WIDTH * TRAFFIC_ICON_HEIGHT * 3)
#define LV_IMG_TRUE_COLOR_ALPHA_HEADER \
    (5u | (TRAFFIC_ICON_WIDTH << 10) | (TRAFFIC_ICON_HEIGHT << 21))

static unsigned char traffic_up_pixels[TRAFFIC_ICON_BYTES];
static unsigned char traffic_down_pixels[TRAFFIC_ICON_BYTES];
static int traffic_icons_ready;

static const struct touchui_img_dsc traffic_up_image = {
    .header = LV_IMG_TRUE_COLOR_ALPHA_HEADER,
    .data_size = TRAFFIC_ICON_BYTES,
    .data = traffic_up_pixels
};

static const struct touchui_img_dsc traffic_down_image = {
    .header = LV_IMG_TRUE_COLOR_ALPHA_HEADER,
    .data_size = TRAFFIC_ICON_BYTES,
    .data = traffic_down_pixels
};

static void set_traffic_icon_pixel(unsigned char *pixels, int x, int y,
                                   uint32_t color)
{
    size_t offset;
    lv_color_compat_t rgb565;
    if (!pixels || x < 0 || x >= TRAFFIC_ICON_WIDTH ||
        y < 0 || y >= TRAFFIC_ICON_HEIGHT) return;
    offset = (size_t)(y * TRAFFIC_ICON_WIDTH + x) * 3u;
    rgb565 = color_hex(color);
    pixels[offset] = (unsigned char)(rgb565 & 0xffu);
    pixels[offset + 1] = (unsigned char)(rgb565 >> 8);
    pixels[offset + 2] = 0xffu;
}

static void draw_traffic_arrow(unsigned char *pixels, int upward,
                               uint32_t color)
{
    int x, y, logical_y;
    memset(pixels, 0, TRAFFIC_ICON_BYTES);
    for (y = 1; y < TRAFFIC_ICON_HEIGHT - 1; y++) {
        logical_y = upward ? y : TRAFFIC_ICON_HEIGHT - 1 - y;
        for (x = 1; x < TRAFFIC_ICON_WIDTH - 1; x++) {
            int draw = 0;
            if (logical_y <= 6) {
                int half_width = logical_y - 1;
                draw = x >= 6 - half_width && x <= 6 + half_width;
            } else if (x >= 5 && x <= 7) {
                draw = 1;
            }
            if (draw) set_traffic_icon_pixel(pixels, x, y, color);
        }
    }
}

static int init_traffic_icons(void)
{
    if (traffic_icons_ready) return 1;
    draw_traffic_arrow(traffic_up_pixels, 1, COLOR_TRAFFIC_UP);
    draw_traffic_arrow(traffic_down_pixels, 0, COLOR_TRAFFIC_DOWN);
    traffic_icons_ready = 1;
    return 1;
}

static lv_obj_t *make_traffic_icon(lv_obj_t *parent,
                                   enum traffic_direction direction,
                                   int x, int y)
{
    lv_obj_t *image;
    const void *source;
    if (!parent || !lv_img_create_p || !lv_img_set_src_p ||
        !init_traffic_icons()) return NULL;
    image = lv_img_create_p(parent);
    if (!image) return NULL;
    source = direction == TRAFFIC_UP ?
             (const void *)&traffic_up_image :
             (const void *)&traffic_down_image;
    lv_img_set_src_p(image, source);
    lv_obj_set_pos_p(image, x, y);
    return image;
}

static lv_obj_t *make_traffic_icon_aligned(lv_obj_t *parent,
                                           enum traffic_direction direction,
                                           int x, int text_y,
                                           const void *font)
{
    return make_traffic_icon(parent, direction, x,
                             center_marker_on_text_line(text_y, font,
                                                        TRAFFIC_ICON_HEIGHT));
}

static struct traffic_value_component make_traffic_value(
    lv_obj_t *parent, enum traffic_direction direction,
    int x, int y, int label_width, const void *font)
{
    struct traffic_value_component component = {0};
    int label_height = font_line_height(font) + 4;
    if (label_height < 23) label_height = 23;
    component.icon = make_traffic_icon_aligned(parent, direction, x, y, font);
    component.label = make_single_line_label(parent, "--", x + 16, y,
                                             label_width, label_height);
    if (component.label) {
        if (font && real_obj_set_style_text_font)
            real_obj_set_style_text_font(component.label, font, 0);
        set_text_color(component.label,
                       direction == TRAFFIC_UP ?
                       COLOR_TRAFFIC_UP : COLOR_TRAFFIC_DOWN);
    }
    return component;
}

static struct traffic_value_component make_download_value(
    lv_obj_t *parent, int x, int y, int label_width, const void *font)
{
    return make_traffic_value(parent, TRAFFIC_DOWN, x, y, label_width, font);
}

static struct traffic_value_component make_upload_value(
    lv_obj_t *parent, int x, int y, int label_width, const void *font)
{
    return make_traffic_value(parent, TRAFFIC_UP, x, y, label_width, font);
}

static void set_traffic_value(struct traffic_value_component *component,
                              const char *text)
{
    if (component && component->label)
        lv_label_set_text_p(component->label, text ? text : "--");
}

/* Stock cellular signal images. The vendor UI selects the _R set while the
 * registered network is roaming; signal_x is shared by unavailable states. */
static const char *const stock_signal_images[2][6] = {
    {
        "/usr/ui/skin/signal0.png", "/usr/ui/skin/signal1.png",
        "/usr/ui/skin/signal2.png", "/usr/ui/skin/signal3.png",
        "/usr/ui/skin/signal4.png", "/usr/ui/skin/signal5.png"
    },
    {
        "/usr/ui/skin/signal0_R.png", "/usr/ui/skin/signal1_R.png",
        "/usr/ui/skin/signal2_R.png", "/usr/ui/skin/signal3_R.png",
        "/usr/ui/skin/signal4_R.png", "/usr/ui/skin/signal5_R.png"
    }
};

static struct signal_icon_component make_stock_signal_icon(lv_obj_t *parent,
                                                             int x, int y)
{
    struct signal_icon_component component = {0};
    if (!parent || !lv_img_create_p || !lv_img_set_src_p) return component;
    component.image = lv_img_create_p(parent);
    if (!component.image) return component;
    component.state = -1;
    lv_img_set_src_p(component.image, "/usr/ui/skin/signal_x.png");
    lv_obj_set_pos_p(component.image, x, y);
    return component;
}

static void set_stock_signal_icon(struct signal_icon_component *component,
                                  int valid, int online, int bars, int roaming)
{
    const char *source;
    int state;
    if (!component || !component->image || !lv_img_set_src_p) return;
    if (!valid || !online) {
        state = 0;
        source = "/usr/ui/skin/signal_x.png";
    } else {
        if (bars < 0) bars = 0;
        if (bars > 5) bars = 5;
        state = 1 + bars + (roaming ? 6 : 0);
        source = stock_signal_images[roaming ? 1 : 0][bars];
    }
    if (component->state == state) return;
    lv_img_set_src_p(component->image, source);
    component->state = state;
}

/* Stock B20 header buttons. Assets 025/028 are the released/pressed back
 * button; assets 131/132 are the released/pressed home button.
 * zte_topsw_devui is a fixed-address non-PIE executable on this firmware;
 * the install preflight and README bind this hook to its verified binary. */
#define STOCK_BACK_RELEASED ((const void *)(uintptr_t)0x00eefbb8u)
#define STOCK_BACK_PRESSED  ((const void *)(uintptr_t)0x00eefbe8u)
#define STOCK_HOME_RELEASED ((const void *)(uintptr_t)0x00ef0258u)
#define STOCK_HOME_PRESSED  ((const void *)(uintptr_t)0x00ef0268u)
#define LV_IMGBTN_STATE_RELEASED 0
#define LV_IMGBTN_STATE_PRESSED 1

static lv_obj_t *make_stock_header_button(lv_obj_t *parent, int x, int y,
                                          const void *released,
                                          const void *pressed,
                                          void (*callback)(void *event))
{
    lv_obj_t *button;
    if (!parent || !callback || !lv_imgbtn_create_p ||
        !lv_imgbtn_set_src_p) return NULL;
    button = lv_imgbtn_create_p(parent);
    if (!button) return NULL;
    lv_imgbtn_set_src_p(button, LV_IMGBTN_STATE_RELEASED,
                        NULL, released, NULL);
    lv_imgbtn_set_src_p(button, LV_IMGBTN_STATE_PRESSED,
                        NULL, pressed, NULL);
    lv_obj_set_size_p(button, 100, 42);
    lv_obj_set_pos_p(button, x, y);
    lv_obj_add_event_cb_p(button, callback, LV_EVENT_CLICKED, NULL);
    return button;
}

static lv_obj_t *make_back_button(lv_obj_t *parent, int x, int y,
                                  void (*callback)(void *event))
{
    return make_stock_header_button(parent, x, y,
                                    STOCK_BACK_RELEASED, STOCK_BACK_PRESSED,
                                    callback);
}

static lv_obj_t *make_home_button(lv_obj_t *parent, int x, int y,
                                  void (*callback)(void *event))
{
    return make_stock_header_button(parent, x, y,
                                    STOCK_HOME_RELEASED, STOCK_HOME_PRESSED,
                                    callback);
}
