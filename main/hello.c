#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_heap_caps.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_vendor.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "fonts.h"
#include "photo.h"

static const char *TAG = "hello_lcd";

// Waveshare ESP32-S3-LCD-1.47B (ST7789, no touch)
#define PIN_MOSI  45
#define PIN_SCK   40
#define PIN_CS    42
#define PIN_DC    41
#define PIN_RST   39
#define PIN_BL    46

// Landscape: the 172x320 panel is used rotated, so 320 wide by 172 tall
#define W         320
#define H         172
#define GAP_X     0
#define GAP_Y     34    // the 172-px axis sits at offset 34 in the controller's 240-px RAM

_Static_assert(PHOTO_W == W && PHOTO_H == H, "photo.h must match the screen size");

// ------------------------------------------------------------------------------
// Frame buffer: RGB565, stored byte-swapped because the SPI bus sends the high byte first
// ------------------------------------------------------------------------------
static uint16_t *fb;

static inline uint16_t pack(float r, float g, float b)
{
    r = fminf(fmaxf(r, 0.0f), 255.0f);
    g = fminf(fmaxf(g, 0.0f), 255.0f);
    b = fminf(fmaxf(b, 0.0f), 255.0f);
    uint16_t c = (uint16_t)((((int)(r + 0.5f) >> 3) << 11) | (((int)(g + 0.5f) >> 2) << 5) | ((int)(b + 0.5f) >> 3));
    return (uint16_t)((c >> 8) | (c << 8));
}

static inline void unpack(uint16_t v, float *r, float *g, float *b)
{
    uint16_t c = (uint16_t)((v >> 8) | (v << 8));
    *r = ((c >> 11) & 31) * (255.0f / 31.0f);
    *g = ((c >> 5) & 63) * (255.0f / 63.0f);
    *b = (c & 31) * (255.0f / 31.0f);
}

// Blend a color over the pixel with coverage a (0..1)
static inline void blend(int x, int y, float a, float r, float g, float b)
{
    if (x < 0 || y < 0 || x >= W || y >= H || a <= 0.0f) return;
    if (a > 1.0f) a = 1.0f;
    float orr, og, ob;
    unpack(fb[y * W + x], &orr, &og, &ob);
    fb[y * W + x] = pack(orr + (r - orr) * a, og + (g - og) * a, ob + (b - ob) * a);
}

static inline float clamp01(float v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

// ------------------------------------------------------------------------------
// Colors: a metallic gold that shimmers along the frame
// ------------------------------------------------------------------------------
static void gold(float t, float *r, float *g, float *b)
{
    float k = 0.5f + 0.5f * sinf(t * 7.0f);        // 0..1 sheen
    *r = 150.0f + (255.0f - 150.0f) * k;
    *g = 108.0f + (232.0f - 108.0f) * k;
    *b = 32.0f + (150.0f - 32.0f) * k;
}

// ------------------------------------------------------------------------------
// Shapes (anti-aliased using distance fields)
// ------------------------------------------------------------------------------
static float sd_rrect(float px, float py, float inset, float radius)
{
    float cx = W / 2.0f, cy = H / 2.0f;
    float hx = W / 2.0f - inset, hy = H / 2.0f - inset;
    float qx = fabsf(px - cx) - (hx - radius);
    float qy = fabsf(py - cy) - (hy - radius);
    float ox = qx > 0 ? qx : 0, oy = qy > 0 ? qy : 0;
    float inner = qx > qy ? qx : qy;
    return sqrtf(ox * ox + oy * oy) + (inner < 0 ? inner : 0) - radius;
}

static void stroke_rrect(float inset, float radius, float width)
{
    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            float d = sd_rrect(x + 0.5f, y + 0.5f, inset, radius);
            float a = 0.5f + width * 0.5f - fabsf(d);
            if (a <= 0) continue;
            float r, g, b;
            gold((x / (float)W + y / (float)H) * 0.5f, &r, &g, &b);
            blend(x, y, a, r, g, b);
        }
    }
}

static void dot(float cx, float cy, float rad)
{
    for (int y = (int)(cy - rad - 2); y <= (int)(cy + rad + 2); y++)
        for (int x = (int)(cx - rad - 2); x <= (int)(cx + rad + 2); x++) {
            float d = sqrtf((x + 0.5f - cx) * (x + 0.5f - cx) + (y + 0.5f - cy) * (y + 0.5f - cy));
            float r, g, b;
            gold(x / (float)W, &r, &g, &b);
            blend(x, y, clamp01(0.5f + rad - d), r, g, b);
        }
}

// Thin ring, only drawn inside the inner border so it never crosses the frame
static void ring_inside(float cx, float cy, float rad, float width, float inner_inset, float inner_r)
{
    for (int y = (int)(cy - rad - 2); y <= (int)(cy + rad + 2); y++)
        for (int x = (int)(cx - rad - 2); x <= (int)(cx + rad + 2); x++) {
            if (sd_rrect(x + 0.5f, y + 0.5f, inner_inset, inner_r) > -2.5f) continue;
            float d = sqrtf((x + 0.5f - cx) * (x + 0.5f - cx) + (y + 0.5f - cy) * (y + 0.5f - cy));
            float r, g, b;
            gold(x / (float)W + 0.3f, &r, &g, &b);
            blend(x, y, clamp01(0.5f + width * 0.5f - fabsf(d - rad)), r, g, b);
        }
}

static void diamond(float cx, float cy, float half)
{
    for (int y = (int)(cy - half - 2); y <= (int)(cy + half + 2); y++)
        for (int x = (int)(cx - half - 2); x <= (int)(cx + half + 2); x++) {
            float d = fabsf(x + 0.5f - cx) + fabsf(y + 0.5f - cy);
            float r, g, b;
            gold(x / (float)W + 0.6f, &r, &g, &b);
            blend(x, y, clamp01(0.5f + (half - d) * 0.7071f), r, g, b);
        }
}

// A thin horizontal line that fades out towards both ends
static void fading_line(float x0, float x1, float y, float thick, bool fade_left, bool fade_right)
{
    float len = x1 - x0;
    for (int x = (int)x0; x <= (int)x1; x++) {
        float t = (x - x0) / len;                               // 0..1 along the line
        float fade = 1.0f;
        if (fade_left) fade *= clamp01(t * 2.2f);
        if (fade_right) fade *= clamp01((1.0f - t) * 2.2f);
        for (int yy = (int)(y - 2); yy <= (int)(y + 2); yy++) {
            float r, g, b;
            gold(x / (float)W + 0.2f, &r, &g, &b);
            blend(x, yy, clamp01(0.5f + thick * 0.5f - fabsf(yy + 0.5f - y)) * fade, r, g, b);
        }
    }
}

// A centered ornament: diamond with tapering lines on both sides
static void ornament(float cx, float y, float half_len, float dia)
{
    fading_line(cx - dia - 8 - half_len, cx - dia - 8, y, 1.3f, true, false);
    fading_line(cx + dia + 8, cx + dia + 8 + half_len, y, 1.3f, false, true);
    diamond(cx, y, dia);
    dot(cx - dia - 5, y, 1.3f);
    dot(cx + dia + 5, y, 1.3f);
}

// ------------------------------------------------------------------------------
// Text with anti-aliased bitmap fonts
// ------------------------------------------------------------------------------
static float text_width(const font_t *f, const char *s)
{
    float w = 0;
    for (; *s; s++) {
        int c = (unsigned char)*s;
        if (c < f->first || c > f->last) c = '?';
        w += f->glyphs[c - f->first].adv16 / 16.0f;
    }
    return w;
}

static void draw_text(const font_t *f, const char *s, float x, int baseline, float r, float g, float b, float alpha)
{
    for (; *s; s++) {
        int c = (unsigned char)*s;
        if (c < f->first || c > f->last) c = '?';
        const glyph_t *gl = &f->glyphs[c - f->first];
        int gx = (int)lrintf(x) + gl->xoff, gy = baseline + gl->yoff;
        for (int j = 0; j < gl->h; j++)
            for (int i = 0; i < gl->w; i++)
                blend(gx + i, gy + j, f->bitmap[gl->off + j * gl->w + i] * (alpha / 255.0f), r, g, b);
        x += gl->adv16 / 16.0f;
    }
}

static void draw_text_centered(const font_t *f, const char *s, int baseline, float r, float g, float b)
{
    float x = (W - text_width(f, s)) / 2.0f;
    draw_text(f, s, x + 1.5f, baseline + 1, 8, 4, 18, 0.55f);   // soft shadow
    draw_text(f, s, x, baseline, r, g, b, 1.0f);
}

// ------------------------------------------------------------------------------
// The picture
// ------------------------------------------------------------------------------
static void render_scene(void)
{
    // Deep midnight-blue gradient with a faint glow in the middle
    for (int y = 0; y < H; y++) {
        float v = y / (float)(H - 1);
        for (int x = 0; x < W; x++) {
            float dx = (x - W / 2.0f) / (W / 2.0f), dy = (y - H / 2.0f) / (H / 2.0f);
            float glow = expf(-(dx * dx * 1.2f + dy * dy * 2.0f)) * 22.0f;
            fb[y * W + x] = pack(9 + 14 * v + glow * 0.6f, 12 + 0 * v + glow * 0.7f, 36 + 12 * v + glow);
        }
    }

    // Double frame: a bold outer line and a fine inner line
    stroke_rrect(3.0f, 18.0f, 2.6f);
    stroke_rrect(9.0f, 12.0f, 1.0f);

    // Corner flourishes
    const float cx[4] = {20.0f, W - 20.0f, 20.0f, W - 20.0f};
    const float cy[4] = {20.0f, 20.0f, H - 20.0f, H - 20.0f};
    for (int i = 0; i < 4; i++) {
        dot(cx[i], cy[i], 2.3f);
        ring_inside(cx[i], cy[i], 6.0f, 1.0f, 9.0f, 12.0f);
        ring_inside(cx[i], cy[i], 10.0f, 0.8f, 9.0f, 12.0f);
    }

    // Ornaments top and bottom, diamonds on both sides
    ornament(W / 2.0f, 24.0f, 70.0f, 4.5f);
    ornament(W / 2.0f, H - 24.0f, 70.0f, 4.5f);
    diamond(17.0f, H / 2.0f, 4.0f);
    diamond(W - 17.0f, H / 2.0f, 4.0f);

    // Title, divider and subtitle
    draw_text_centered(&font_title, "ImsaiGuy", 92, 255, 241, 208);
    fading_line(60.0f, W - 60.0f, 106.0f, 1.0f, true, true);
    diamond(W / 2.0f, 106.0f, 3.2f);
    draw_text_centered(&font_sub, "ESP32-S3  -  Waveshare 1.47B", 134, 214, 176, 96);
}

void app_main(void)
{
    fb = heap_caps_malloc(W * H * sizeof(uint16_t), MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    if (!fb) {
        ESP_LOGE(TAG, "Out of memory for the frame buffer");
        return;
    }

    // Backlight on (active level HIGH on this board)
    gpio_config_t bl = { .pin_bit_mask = 1ULL << PIN_BL, .mode = GPIO_MODE_OUTPUT };
    ESP_ERROR_CHECK(gpio_config(&bl));
    gpio_set_level(PIN_BL, 1);

    spi_bus_config_t bus = {
        .sclk_io_num = PIN_SCK,
        .mosi_io_num = PIN_MOSI,
        .miso_io_num = -1,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = W * H * sizeof(uint16_t),
    };
    ESP_ERROR_CHECK(spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_CH_AUTO));

    esp_lcd_panel_io_handle_t io;
    esp_lcd_panel_io_spi_config_t io_cfg = {
        .dc_gpio_num = PIN_DC,
        .cs_gpio_num = PIN_CS,
        .pclk_hz = 40 * 1000 * 1000,
        .lcd_cmd_bits = 8,
        .lcd_param_bits = 8,
        .spi_mode = 0,
        .trans_queue_depth = 10,
    };
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)SPI2_HOST, &io_cfg, &io));

    esp_lcd_panel_handle_t panel;
    esp_lcd_panel_dev_config_t panel_cfg = {
        .reset_gpio_num = PIN_RST,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16,
    };
    ESP_ERROR_CHECK(esp_lcd_new_panel_st7789(io, &panel_cfg, &panel));
    ESP_ERROR_CHECK(esp_lcd_panel_reset(panel));
    ESP_ERROR_CHECK(esp_lcd_panel_init(panel));
    ESP_ERROR_CHECK(esp_lcd_panel_invert_color(panel, true));
    ESP_ERROR_CHECK(esp_lcd_panel_swap_xy(panel, true));          // landscape
    ESP_ERROR_CHECK(esp_lcd_panel_mirror(panel, false, true));    // if upside down, use (true, false)
    ESP_ERROR_CHECK(esp_lcd_panel_set_gap(panel, GAP_X, GAP_Y));
    ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(panel, true));

    // Alternate: photo for 5 s, then the "ImsaiGuy" scene for 5 s, forever.
    // While one picture is on the screen, the next one is prepared in the frame buffer.
    memcpy(fb, photo_rgb565, sizeof(photo_rgb565));
    while (true) {
        // --- photo ---
        TickType_t t0 = xTaskGetTickCount();
        ESP_ERROR_CHECK(esp_lcd_panel_draw_bitmap(panel, 0, 0, W, H, fb));
        ESP_LOGI(TAG, "Showing photo");
        vTaskDelay(pdMS_TO_TICKS(150));        // let the transfer finish before reusing the buffer
        render_scene();                        // prepare the ImsaiGuy scene while the photo is shown
        vTaskDelayUntil(&t0, pdMS_TO_TICKS(5000));

        // --- ImsaiGuy scene ---
        t0 = xTaskGetTickCount();
        ESP_ERROR_CHECK(esp_lcd_panel_draw_bitmap(panel, 0, 0, W, H, fb));
        ESP_LOGI(TAG, "Showing ImsaiGuy scene");
        vTaskDelay(pdMS_TO_TICKS(150));
        memcpy(fb, photo_rgb565, sizeof(photo_rgb565));   // prepare the photo while the scene is shown
        vTaskDelayUntil(&t0, pdMS_TO_TICKS(5000));
    }
}
