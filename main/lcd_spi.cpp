// Display backend for the ESP32-S3 build: an ST7789 (240x320) or ST7796 (320x480) SPI panel, used landscape.
//
// The transport, the panel bring-up and the reduction follow the author's earlier S3 port (np2 espresso,
// lcd_st7789.cpp): esp_lcd's SPI panel IO only, our own init sequence and pixel push (12-bit RGB444 on the
// ST7789 to cut the wire time by a quarter), and a box filter that reduces the 640x400 screen to 320x200 on the
// ST7789 and 480x300 on the ST7796. The interface is lcd_ui.h.
//
// What is new against that port:
//   - The job queue of the Tab5 build: core 1 posts "composite this frame, then blit it" and goes on emulating;
//     a core-0 task does both (lcd_post_composite).
//   - The menu canvas is the panel's own size, not 640x400: on a 320x240 panel a reduced 8x16 font would be 4x8
//     and unreadable, so the menu is laid out for the panel (menu_disk.cpp) and sent 1:1.
//   - The drive lamps, painted by the blit task in the letterbox under the picture.
//
// Byte order: SPI puts the high byte on the wire first while RGB565 sits in memory little-endian, so pixels are
// swapped as the output band is built; the RGB444 packer produces wire order directly.

#include <string.h>

#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_lcd_panel_io.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include <nvs.h>
#include <nvs_flash.h>

extern "C" {
#include <compiler.h>  // the core's types
#include <memmap.h>
#include <video.h>     // cgrom: the CG ROM the machine loaded (8x16 ANK at 0x80000, kanji)
}

#include "board_pins.h"
#include "lcd_ui.h"

extern "C" int ets_printf(const char *fmt, ...);

#define SRC_W    640                 // the renderer's surface: 640x480, pitch 640
#define PC98_W   BRD_PC98_W
#define PC98_H   BRD_PC98_H
#define DST_W_MAX 480
#define DST_H_MAX 300

// ---- panels -------------------------------------------------------------------------------------------------
#define PANEL_ST7789  0
#define PANEL_ST7796  1
#define PANEL_COUNT   2
static const struct {
    const char *name;
    int  w, h;          // native (portrait); landscape is these swapped
    bool has_rgb444;    // the ST7796's COLMOD offers 65K/262K only - no 12-bit at all
} s_panels[PANEL_COUNT] = {
    { "ST7789 320x240", 240, 320, true  },
    { "ST7796 480x320", 320, 480, false },
};
static int s_panel = PANEL_ST7789;   // the next boot's choice (NVS "panel")
static int s_panel_run = PANEL_ST7789;   // the one brought up now
static int s_pan_w = 320, s_pan_h = 240; // landscape size of the running panel
static int s_dst_w = 320, s_dst_h = 200; // the reduced picture on it

// One SPI transfer per band rather than per row. Bounded by internal DMA memory, which the BLE controller leaves
// little of: 4KB x2, used alternately because esp_lcd_panel_io_tx_color returns before the transfer is done.
#define BAND_BYTES      (4 * 1024)

static esp_lcd_panel_io_handle_t s_io = nullptr;
static uint16_t *s_img = nullptr;    // the reduced frame (PSRAM)
static uint8_t  *s_band[2] = { nullptr, nullptr };
static int       s_band_cur = 0;

// SPI clock: 80MHz is out of spec for the ST7789 and only survives short, clean wiring; 40 is the default.
static const int s_spi_mhz[] = { 80, 40, 20 };
#define SPI_MHZ_COUNT   ((int)(sizeof(s_spi_mhz) / sizeof(s_spi_mhz[0])))
#define SPI_MHZ_DEFAULT 1
static int s_spi_idx = SPI_MHZ_DEFAULT;
static int s_panel12 = 0;            // the COLMOD the panel is in now
static volatile int s_clear_req = 0;
#define RGB444_DEFAULT 1
static volatile int s_rgb444 = RGB444_DEFAULT;

static bool io_create(int mhz) {
    esp_lcd_panel_io_spi_config_t cfg = {};
    cfg.cs_gpio_num       = BRD_LCD_CS;
    cfg.dc_gpio_num       = BRD_LCD_DC;
    cfg.spi_mode          = 0;
    cfg.pclk_hz           = (unsigned)mhz * 1000000u;
    cfg.trans_queue_depth = 1;
    cfg.lcd_cmd_bits      = 8;
    cfg.lcd_param_bits    = 8;
    return esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)BRD_LCD_HOST, &cfg, &s_io) == ESP_OK;
}

static inline void cmd(uint8_t c) { esp_lcd_panel_io_tx_param(s_io, c, NULL, 0); }
static inline void cmd1(uint8_t c, uint8_t a) { esp_lcd_panel_io_tx_param(s_io, c, &a, 1); }

static void panel_init(void) {
    const bool is96 = (s_panel_run == PANEL_ST7796);
#if BRD_LCD_RST >= 0
    // Some ST7796 modules ignore SWRESET until they have seen a real RESET pulse after power-up.
    gpio_set_direction((gpio_num_t)BRD_LCD_RST, GPIO_MODE_OUTPUT);
    gpio_set_level((gpio_num_t)BRD_LCD_RST, 0);
    vTaskDelay(pdMS_TO_TICKS(20));
    gpio_set_level((gpio_num_t)BRD_LCD_RST, 1);
    vTaskDelay(pdMS_TO_TICKS(120));
#endif
    cmd(0x01);                            // SWRESET
    vTaskDelay(pdMS_TO_TICKS(150));
    cmd(0x11);                            // SLPOUT
    vTaskDelay(pdMS_TO_TICKS(120));
    if (is96) {
        // The ST7796 keeps most registers behind a command-set lock; plenty of modules come up blank until it is
        // opened, so unlock, set 1-dot inversion, and lock again.
        cmd1(0xf0, 0xc3);
        cmd1(0xf0, 0x96);
        cmd1(0xb4, 0x01);
        cmd1(0xf0, 0x3c);
        cmd1(0xf0, 0x69);
    }
    // Orientation and colour order differ per module: the ST7789 board wants MV|MX with RGB order, the ST7796
    // one MV|MX|MY with BGR (as found on the np2 espresso boards).
    cmd1(0x36, is96 ? 0xe8 : 0x60);       // MADCTL
    cmd1(0x3A, 0x55);                     // COLMOD: start in 16 bit
    s_panel12 = 0;
    cmd(is96 ? 0x20 : 0x21);              // INVOFF / INVON: the ST7789 module is an inverted panel
    cmd(0x13);                            // NORON
    vTaskDelay(pdMS_TO_TICKS(10));
    cmd(0x29);                            // DISPON
    vTaskDelay(pdMS_TO_TICKS(120));
}

static void lcd_load_nvs(void) {
    if (nvs_flash_init() != ESP_OK) return;
    nvs_handle_t nh;
    if (nvs_open("pc98", NVS_READONLY, &nh) != ESP_OK) return;
    uint8_t v;
    if (nvs_get_u8(nh, "spiidx", &v) == ESP_OK && v < SPI_MHZ_COUNT) s_spi_idx = v;
    if (nvs_get_u8(nh, "panel", &v) == ESP_OK && v < PANEL_COUNT) s_panel = v;
    if (nvs_get_u8(nh, "rgb444", &v) == ESP_OK) s_rgb444 = v ? 1 : 0;
    nvs_close(nh);
}

// ---- address window + band push -------------------------------------------------------------------------------
static void set_window(int x, int y, int w, int h) {
    uint8_t p[4];
    p[0] = (uint8_t)(x >> 8); p[1] = (uint8_t)x;
    p[2] = (uint8_t)((x + w - 1) >> 8); p[3] = (uint8_t)(x + w - 1);
    esp_lcd_panel_io_tx_param(s_io, 0x2A, p, 4);          // CASET
    p[0] = (uint8_t)(y >> 8); p[1] = (uint8_t)y;
    p[2] = (uint8_t)((y + h - 1) >> 8); p[3] = (uint8_t)(y + h - 1);
    esp_lcd_panel_io_tx_param(s_io, 0x2B, p, 4);          // RASET
}

// RAMWR (0x2C) resets the write pointer to the window origin; the bands after it use RAMWR_CONTINUE (0x3C).
static void push_band(const uint8_t *data, size_t bytes, bool first) {
    esp_lcd_panel_io_tx_color(s_io, first ? 0x2C : 0x3C, data, bytes);
}

static void set_colmod(int want12) {
    if (want12 == s_panel12) return;
    cmd1(0x3A, want12 ? 0x53 : 0x55);
    s_panel12 = want12;
}

// Two RGB565 pixels into three bytes of RGB444, RRRRGGGG BBBBRRRR GGGGBBBB. Lossless for the PC-98's 4-bit-per-
// channel palette; only the shades the reduction invents are quantised.
static inline void pack444_row(const uint16_t *src, uint8_t *dst, int npx) {
    for (int i = 0; i < npx; i += 2) {
        const uint16_t a = src[i], b = src[i + 1];
        dst[0] = (uint8_t)(((a >> 8) & 0xf0) | ((a >> 7) & 0x0f));
        dst[1] = (uint8_t)(((a << 3) & 0xf0) | ((b >> 12) & 0x0f));
        dst[2] = (uint8_t)(((b >> 3) & 0xf0) | ((b >> 1) & 0x0f));
        dst += 3;
    }
}

static inline void pack565_row(const uint16_t *src, uint8_t *dst, int npx) {
    for (int i = 0; i < npx; i++) {
        dst[0] = (uint8_t)(src[i] >> 8);
        dst[1] = (uint8_t)(src[i]);
        dst += 2;
    }
}

static bool push_rect(int x, int y, int w, int h, const uint16_t *img, int stride, int use12) {
    if (!s_io || !s_band[0] || w <= 0 || h <= 0) return false;
    if (use12 && (w & 1)) use12 = 0;
    const int rowbytes = use12 ? (w * 3 / 2) : (w * 2);
    if (rowbytes > BAND_BYTES) return false;
    int rows_per_band = BAND_BYTES / rowbytes;
    if (rows_per_band > h) rows_per_band = h;
    set_colmod(use12);
    set_window(x, y, w, h);
    bool first = true;
    for (int r0 = 0; r0 < h; r0 += rows_per_band) {
        int nrows = h - r0;
        if (nrows > rows_per_band) nrows = rows_per_band;
        uint8_t *band = s_band[s_band_cur];
        s_band_cur ^= 1;                     // the other one may still be in flight
        for (int r = 0; r < nrows; r++) {
            const uint16_t *srow = img + (size_t)(r0 + r) * stride;
            uint8_t *drow = band + (size_t)r * rowbytes;
            if (use12) pack444_row(srow, drow, w);
            else       pack565_row(srow, drow, w);
        }
        push_band(band, (size_t)nrows * rowbytes, first);
        first = false;
    }
    return true;
}

static void fill_rect(int x, int y, int w, int h, uint16_t colour) {
    if (!s_io || !s_band[0] || w <= 0 || h <= 0) return;
    const int rowbytes = w * 2;
    if (rowbytes > BAND_BYTES) return;
    int rows_per_band = BAND_BYTES / rowbytes;
    if (rows_per_band > h) rows_per_band = h;
    uint8_t *band = s_band[s_band_cur];
    s_band_cur ^= 1;
    for (int i = 0; i < rows_per_band * w; i++) {
        band[i * 2]     = (uint8_t)(colour >> 8);
        band[i * 2 + 1] = (uint8_t)colour;
    }
    set_colmod(0);
    set_window(x, y, w, h);
    bool first = true;
    for (int r0 = 0; r0 < h; r0 += rows_per_band) {
        int nrows = h - r0;
        if (nrows > rows_per_band) nrows = rows_per_band;
        push_band(band, (size_t)nrows * rowbytes, first);   // the band never changes between pushes
        first = false;
    }
}

// Reduction modes: 0 Max (brightest of the block: white-on-black text kept, black-on-white lost), 1 Average (both
// polarities survive, as grey strokes), 2 Mid (midpoint of the darkest and brightest: more stroke contrast on thin
// text), 3 1:1 (no reduction: the top-left part of the screen at its true resolution).
#define SCALE_MAX   0
#define SCALE_AVG   1
#define SCALE_MID   2
#define SCALE_1X    3
#define SCALE_COUNT 4
static volatile int s_scale_mode = SCALE_AVG;
extern "C" int  lcd_get_scale_mode(void)   { return s_scale_mode; }
extern "C" int  lcd_scale_mode_count(void) { return SCALE_COUNT; }
extern "C" const char *lcd_scale_mode_name(int m) {
    static const char *const n[SCALE_COUNT] = { "Max", "Average", "Mid", "1:1" };
    return (m >= 0 && m < SCALE_COUNT) ? n[m] : "?";
}
extern "C" void lcd_set_scale_mode(int m) {
    if (m < 0 || m >= SCALE_COUNT) return;
    if (m != s_scale_mode) s_clear_req = 1;   // the modes cover different areas: wipe the margins
    s_scale_mode = m;
}

// ---- reduction -----------------------------------------------------------------------------------------------------
// Source spans per destination column / row, worked out once for the panel.
static uint16_t s_sx0[DST_W_MAX + 1];
static uint16_t s_sy0[DST_H_MAX + 1];

static void build_spans(void) {
    for (int dx = 0; dx <= s_dst_w; dx++) s_sx0[dx] = (uint16_t)(dx * PC98_W / s_dst_w);
    for (int dy = 0; dy <= s_dst_h; dy++) s_sy0[dy] = (uint16_t)(dy * PC98_H / s_dst_h);
}

static inline uint16_t avg2(uint16_t a, uint16_t b) {
    const uint32_t r = (((a >> 11) & 31) + ((b >> 11) & 31)) >> 1;
    const uint32_t g = (((a >> 5) & 63) + ((b >> 5) & 63)) >> 1;
    const uint32_t u = ((a & 31) + (b & 31)) >> 1;
    return (uint16_t)((r << 11) | (g << 5) | u);
}

static void reduce(const uint16_t *src, int mode) {
    for (int dy = 0; dy < s_dst_h; dy++) {
        const int sy0 = s_sy0[dy];
        int sy1 = s_sy0[dy + 1];
        if (sy1 <= sy0) sy1 = sy0 + 1;
        uint16_t *d = s_img + dy * s_dst_w;
        for (int dx = 0; dx < s_dst_w; dx++) {
            const int sx0 = s_sx0[dx];
            int sx1 = s_sx0[dx + 1];
            if (sx1 <= sx0) sx1 = sx0 + 1;
            uint32_t rs = 0, gs = 0, bs = 0, cnt = 0;
            uint16_t mn = 0xffff, mx = 0;
            for (int sy = sy0; sy < sy1; sy++) {
                const uint16_t *r = src + sy * SRC_W;
                for (int sx = sx0; sx < sx1; sx++) {
                    const uint16_t p = r[sx];
                    rs += (p >> 11) & 31; gs += (p >> 5) & 63; bs += p & 31;
                    cnt++;
                    if (p < mn) mn = p;
                    if (p > mx) mx = p;
                }
            }
            if (mode == SCALE_AVG) {
                d[dx] = (uint16_t)(((rs / cnt) << 11) | ((gs / cnt) << 5) | (bs / cnt));
            } else if (mode == SCALE_MID) {
                d[dx] = avg2(mn, mx);
            } else {
                d[dx] = mx;
            }
        }
    }
}

// ---- drive lamps ---------------------------------------------------------------------------------------------------
// FDD1, FDD2, CD-ROM and HDD as small bars in the margin under the picture: red for the floppies, yellow for the
// CD-ROM, green for the hard disk. The core reports each access (host_fdd_access / host_cd_access /
// host_hdd_access); a lamp stays lit for a moment after the last.
#define LAMP_HOLD_US 80000
#define LAMPS 4
static volatile int64_t s_lamp_at[LAMPS];   // FDD1, FDD2, CD-ROM, HDD
static int  s_lamp_drawn = -1;
static bool s_lamps_on = true;
static volatile bool s_lamp_force = true;

extern "C" void lamp_fdd(REG8 drv) {
    if (drv < 2) s_lamp_at[drv] = esp_timer_get_time();
}
extern "C" void lamp_cd(void) {
    s_lamp_at[2] = esp_timer_get_time();
}
extern "C" void lamp_hdd(REG8 drv) {
    (void)drv;
    s_lamp_at[3] = esp_timer_get_time();
}
extern "C" void lcd_lamps_enable(bool on) { s_lamps_on = on; s_lamp_force = true; }
extern "C" bool lcd_lamps_enabled(void) { return s_lamps_on; }
extern "C" void lcd_lamps_tick(void) { }   // painted by the blit task (paint_lamps), which owns the SPI bus

static void paint_lamps(void) {
    if (s_scale_mode == SCALE_1X) return;          // no margin to put them in
    const int64_t now = esp_timer_get_time();
    int on = 0;
    for (int i = 0; i < LAMPS; i++)
        if (s_lamp_at[i] && now - s_lamp_at[i] < LAMP_HOLD_US) on |= 1 << i;
    if (!s_lamps_on) on = -2;
    if (on == s_lamp_drawn && !s_lamp_force) return;
    const int lw = s_pan_w / 16, lh = 3, gap = 4;
    const int below = (s_pan_h + s_dst_h) / 2;
    if (below + 2 + lh > s_pan_h) return;
    const int right = (s_pan_w + s_dst_w) / 2;
    const int x0 = right - (LAMPS * lw + (LAMPS - 1) * gap);
    static const uint16_t lit[LAMPS] = { 0xF800, 0xF800, 0xFFE0, 0x07E0 };   // red, red, yellow, green
    static const uint16_t dark[LAMPS] = { 0x3000, 0x3000, 0x3180, 0x0180 };
    for (int i = 0; i < LAMPS; i++) {
        const uint16_t c = (on < 0) ? 0x0000 : (on & (1 << i)) ? lit[i] : dark[i];
        fill_rect(x0 + i * (lw + gap), below + 2, lw, lh, c);
    }
    s_lamp_drawn = on;
    s_lamp_force = false;
}

// ---- blit --------------------------------------------------------------------------------------------------------
static const uint8_t *volatile s_blit_src = nullptr;

static void do_blit(const uint8_t *fb) {
    if (!fb) return;
    if (s_clear_req) {
        s_clear_req = 0;
        fill_rect(0, 0, s_pan_w, s_pan_h, 0x0000);
        s_lamp_force = true;
    }
    const int use12 = s_rgb444;
    if (s_scale_mode == SCALE_1X) {
        const int w = (s_pan_w < PC98_W) ? s_pan_w : PC98_W;
        const int h = (s_pan_h < PC98_H) ? s_pan_h : PC98_H;
        push_rect((s_pan_w - w) / 2, (s_pan_h - h) / 2, w, h, (const uint16_t *)fb, SRC_W, use12);
        return;
    }
    if (!s_img) return;
    reduce((const uint16_t *)fb, s_scale_mode);
    push_rect((s_pan_w - s_dst_w) / 2, (s_pan_h - s_dst_h) / 2, s_dst_w, s_dst_h, s_img, s_dst_w, use12);
    paint_lamps();
}

// Jobs for the core-0 blit task. Core 1 posts, core 0 consumes; s_pend counts posted and unfinished jobs and is
// changed only with atomics (both cores write it).
typedef struct { void (*fn)(const void *); const void *arg; const uint8_t *src; unsigned seq; } BlitJob;
static QueueHandle_t s_blit_q = nullptr;
static volatile unsigned s_post_seq, s_done_seq;
static volatile int s_pend = 0;
static volatile uint8_t s_job_posted;

static void blit_task(void *arg) {
    (void)arg;
    for (;;) {
        BlitJob j;
        xQueueReceive(s_blit_q, &j, portMAX_DELAY);
        if (j.fn) { j.fn(j.arg); s_done_seq = j.seq; }
        if (j.src) {
            do_blit(j.src);
        }
        __atomic_sub_fetch(&s_pend, 1, __ATOMIC_SEQ_CST);
    }
}

extern "C" void lcd_blit(const uint8_t *fb) {
    if (!s_blit_q || !fb || __atomic_load_n(&s_pend, __ATOMIC_SEQ_CST)) {
        return;  // still drawing the previous frame; drop this one
    }
    s_blit_src = fb;
    __atomic_add_fetch(&s_pend, 1, __ATOMIC_SEQ_CST);
    BlitJob j = { nullptr, nullptr, fb, 0 };
    if (xQueueSend(s_blit_q, &j, 0) != pdTRUE) {
        __atomic_sub_fetch(&s_pend, 1, __ATOMIC_SEQ_CST);
    }
}

extern "C" bool lcd_blit_busy(void) {
    return __atomic_load_n(&s_pend, __ATOMIC_SEQ_CST) != 0;
}

extern "C" const void *lcd_last_frame(int *w, int *h, int *stride) {
    if (w) *w = PC98_W;
    if (h) *h = PC98_H;
    if (stride) *stride = SRC_W;
    return (const void *)s_blit_src;
}

// The screen composite (RGB565 from the index planes) runs on core 0 right before the blit, so core 1 only hands
// over the job and goes on emulating. Returns nonzero when the job was taken.
extern "C" uint8_t *pc98_framebuffer(void);
extern "C" int lcd_post_composite(void (*fn)(const void *), const void *arg) {
    uint8_t *fb = pc98_framebuffer();
    if (!s_blit_q || !fb) {
        return 0;
    }
    while (s_pend >= 2) {
        vTaskDelay(1);
    }
    BlitJob j = { fn, arg, fb, ++s_post_seq };
    s_job_posted = 1;
    s_blit_src = fb;
    __atomic_add_fetch(&s_pend, 1, __ATOMIC_SEQ_CST);
    xQueueSend(s_blit_q, &j, portMAX_DELAY);   // at most 2 pending, the queue holds 2
    return 1;
}
extern "C" bool lcd_comp_busy(void) { return s_done_seq != s_post_seq; }
extern "C" int lcd_take_job_flag(void) {
    const int v = s_job_posted;
    s_job_posted = 0;
    return v;
}
extern "C" int lcd_pending(void) { return s_pend; }


// ---- init ----------------------------------------------------------------------------------------------------------
extern "C" bool lcd_init(void) {
    lcd_load_nvs();
    s_panel_run = s_panel;
    if (!s_panels[s_panel_run].has_rgb444) s_rgb444 = 0;

    spi_bus_config_t bus = {};
    bus.mosi_io_num     = BRD_LCD_MOSI;
    bus.miso_io_num     = -1;
    bus.sclk_io_num     = BRD_LCD_SCLK;
    bus.quadwp_io_num   = -1;
    bus.quadhd_io_num   = -1;
    bus.max_transfer_sz = BAND_BYTES + 64;
    if (spi_bus_initialize((spi_host_device_t)BRD_LCD_HOST, &bus, SPI_DMA_CH_AUTO) != ESP_OK) {
        ets_printf("lcd: spi_bus_initialize FAIL\n");
        return false;
    }
    if (!io_create(s_spi_mhz[s_spi_idx])) {
        ets_printf("lcd: esp_lcd_new_panel_io_spi FAIL\n");
        return false;
    }
    // DMA-capable band buffers in internal RAM; PSRAM is the fallback (the GDMA reaches it on this chip, and a
    // slower blit beats a black screen).
    for (int i = 0; i < 2; i++) {
        s_band[i] = (uint8_t *)heap_caps_malloc(BAND_BYTES, MALLOC_CAP_DMA | MALLOC_CAP_8BIT);
        if (!s_band[i]) {
            s_band[i] = (uint8_t *)heap_caps_malloc(BAND_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
            if (s_band[i]) ets_printf("lcd: band buffer %d in PSRAM (internal DMA pool full)\n", i);
        }
    }
    if (!s_band[0] || !s_band[1]) {
        ets_printf("lcd: band buffer alloc FAIL\n");
        return false;
    }
    panel_init();
    s_pan_w = s_panels[s_panel_run].h;
    s_pan_h = s_panels[s_panel_run].w;
    // The largest whole-screen reduction that fits, in quarters: 2:1 on 320x240, 3:4 on 480x320.
    if (s_pan_h >= 300 && s_pan_w >= 480) { s_dst_w = 480; s_dst_h = 300; }
    else                                  { s_dst_w = 320; s_dst_h = 200; }
    build_spans();
    fill_rect(0, 0, s_pan_w, s_pan_h, 0x0000);
    s_img = (uint16_t *)heap_caps_malloc((size_t)DST_W_MAX * DST_H_MAX * 2, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    s_blit_q = xQueueCreate(2, sizeof(BlitJob));
    if (!s_img || !s_blit_q) {
        ets_printf("lcd: buffer alloc FAIL\n");
        return false;
    }
    xTaskCreatePinnedToCore(blit_task, "lcdblit", 4096, nullptr, 4, nullptr, 0);
    ets_printf("lcd: %s, picture %dx%d, spi=%dMHz, %s\n", s_panels[s_panel_run].name, s_dst_w, s_dst_h,
               s_spi_mhz[s_spi_idx], s_rgb444 ? "RGB444" : "RGB565");
    return true;
}

// ---- menu canvas ---------------------------------------------------------------------------------------------------
// The panel's own size, RGB565. Drawn on core 1 while the machine is paused; lcd_menu_flush() sends the rows that
// changed (one band of rows, bounded by the lowest and highest touched).
#define FONT_ANK16 0x80000
#define MENU_CH_W 8
#define MENU_CH_H 16
#define MENU_COLS_MAX (DST_W_MAX / MENU_CH_W)   // 60

static uint16_t *s_ui = nullptr;
static uint16_t s_menu_bg = 0;
static int s_dirty_y0 = 1 << 30, s_dirty_y1 = -1;

static uint16_t *ui_canvas(void) {
    if (!s_ui) s_ui = (uint16_t *)heap_caps_malloc((size_t)DST_W_MAX * 320 * sizeof(uint16_t), MALLOC_CAP_SPIRAM);
    return s_ui;
}
static inline void dirty(int y0, int y1) {
    if (y0 < s_dirty_y0) s_dirty_y0 = y0;
    if (y1 > s_dirty_y1) s_dirty_y1 = y1;
}

extern "C" int lcd_ui_w(void) { return s_pan_w; }
extern "C" int lcd_ui_h(void) { return s_pan_h; }
extern "C" int lcd_menu_rows(void) { return s_pan_h / MENU_CH_H; }
extern "C" int lcd_menu_cols(void) { return s_pan_w / MENU_CH_W; }
extern "C" void lcd_menu_set_bg(uint16_t c) { s_menu_bg = c; }

extern "C" void lcd_ui_fill(int x0, int y0, int x1, int y1, uint16_t c, int r) {
    uint16_t *u = ui_canvas();
    if (!u) return;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > s_pan_w) x1 = s_pan_w;
    if (y1 > s_pan_h) y1 = s_pan_h;
    if (x1 <= x0 || y1 <= y0) return;
    for (int y = y0; y < y1; y++) {
        const int dy = (y - y0 < y1 - 1 - y) ? y - y0 : y1 - 1 - y;
        for (int x = x0; x < x1; x++) {
            if (r) {
                const int dx = (x - x0 < x1 - 1 - x) ? x - x0 : x1 - 1 - x;
                if (dx < r && dy < r && (r - dx - 1) * (r - dx - 1) + (r - dy - 1) * (r - dy - 1) > r * r) continue;
            }
            u[y * s_pan_w + x] = c;
        }
    }
    dirty(y0, y1);
}

static inline void ui_px(int x, int y, uint16_t c) {
    if (s_ui && (unsigned)x < (unsigned)s_pan_w && (unsigned)y < (unsigned)s_pan_h) s_ui[y * s_pan_w + x] = c;
}

// The glyphs of a string: an 8x16 ANK cell per byte, or a 16x16 kanji as two cells for a Shift-JIS pair (the SD
// card's names come through FatFs as CP932), from the CG ROM: kanji left half at (JIS 2nd byte << 12) +
// ((JIS 1st byte - 0x20) << 4), right half 0x800 above it. Returns the number of cells.
static int ui_cells(const char *s, const uint8_t **cell, int max) {
    const uint8_t *blank = cgrom + FONT_ANK16 + (unsigned)' ' * MENU_CH_H;
    int col = 0;
    for (const uint8_t *p = (const uint8_t *)s; *p && col < max; ) {
        const unsigned c = *p;
        if ((c >= 0x81 && c <= 0x9f) || (c >= 0xe0 && c <= 0xfc)) {
            const unsigned t = p[1];
            if (t < 0x40 || t == 0x7f || t > 0xfc || col + 1 >= max) {
                cell[col++] = blank;
                p++;
                continue;
            }
            unsigned j1 = ((c >= 0xe0 ? c - 0x40 : c) - 0x81) * 2 + 0x21;
            unsigned j2;
            if (t >= 0x9f) {
                j1++;
                j2 = t - 0x7e;
            } else {
                j2 = t - (t >= 0x80 ? 0x20 : 0x1f);
            }
            if (j1 > 0x7e) {
                cell[col++] = blank;
                cell[col++] = blank;
            } else {
                const uint8_t *k = cgrom + (j2 << 12) + ((j1 - 0x20) << 4);
                cell[col++] = k;
                cell[col++] = k + 0x800;
            }
            p += 2;
            continue;
        }
        cell[col++] = cgrom + FONT_ANK16 + c * MENU_CH_H;
        p++;
    }
    return col;
}

extern "C" int lcd_ui_text(int x, int y, const char *s, uint16_t c) {
    const uint8_t *cell[MENU_COLS_MAX];
    const int n = ui_cells(s ? s : "", cell, MENU_COLS_MAX);
    if (!ui_canvas()) return x;
    for (int i = 0; i < n; i++) {
        for (int r = 0; r < MENU_CH_H; r++) {
            const uint8_t b = cell[i][r];
            if (!b) continue;
            for (int k = 0; k < 8; k++)
                if (b & (0x80 >> k)) ui_px(x + i * 8 + k, y + r, c);
        }
    }
    dirty(y, y + MENU_CH_H);
    return x + n * 8;
}

extern "C" void lcd_ui_chev(int x, int y, uint16_t c, int dir) {
    if (!ui_canvas()) return;
    for (int i = 0; i < 4; i++) {
        const int xx = dir > 0 ? x + i : x + 3 - i;
        ui_px(xx, y + i, c);
        ui_px(xx, y + 6 - i, c);
    }
    dirty(y, y + 7);
}

extern "C" void lcd_ui_tri(int x, int y, uint16_t c, int dir) {
    if (!ui_canvas()) return;
    for (int i = 0; i < 4; i++)
        for (int k = -i; k <= i; k++) ui_px(x + 3 + k, dir < 0 ? y + i : y + 3 - i, c);
    dirty(y, y + 4);
}

extern "C" void lcd_ui_dot(int x, int y, uint16_t c) {
    if (!ui_canvas()) return;
    for (int dy = -2; dy <= 2; dy++)
        for (int dx = -2; dx <= 2; dx++)
            if (dx * dx + dy * dy <= 5) ui_px(x + dx, y + dy, c);
    dirty(y - 2, y + 3);
}

extern "C" void lcd_menu_clear(void) {
    lcd_ui_fill(0, 0, s_pan_w, s_pan_h, s_menu_bg, 0);
    s_lamp_force = true;             // the panel is painted over: put the lamps back after
    s_clear_req = 1;                 // and the picture's margins
}

extern "C" void lcd_menu_flush(void) {
    if (!s_ui || s_dirty_y1 <= s_dirty_y0) return;
    while (lcd_blit_busy()) vTaskDelay(1);   // the blit task owns the bus while it draws
    int y0 = s_dirty_y0 < 0 ? 0 : s_dirty_y0;
    int y1 = s_dirty_y1 > s_pan_h ? s_pan_h : s_dirty_y1;
    push_rect(0, y0, s_pan_w, y1 - y0, s_ui + (size_t)y0 * s_pan_w, s_pan_w, s_rgb444);
    s_dirty_y0 = 1 << 30;
    s_dirty_y1 = -1;
}

// One text row of the grid. Columns from `split` on are drawn in fg2; columns c0..c1-1 sit on `bar` instead of bg
// (the selected row), and a nonzero `stripe` marks the bar's left edge.
extern "C" void lcd_menu_line_ex(int row, const char *s, uint16_t fg, uint16_t fg2, int split,
                                 uint16_t bg, uint16_t bar, int c0, int c1, uint16_t stripe) {
    if (!s || row < 0 || row >= lcd_menu_rows() || !ui_canvas()) return;
    const int y = row * MENU_CH_H;
    lcd_ui_fill(0, y, s_pan_w, y + MENU_CH_H, bg, 0);
    if (c1 > c0) lcd_ui_fill(c0 * MENU_CH_W, y, c1 * MENU_CH_W, y + MENU_CH_H, bar, 0);
    if (stripe) lcd_ui_fill(c0 * MENU_CH_W, y, c0 * MENU_CH_W + 3, y + MENU_CH_H, stripe, 0);
    const uint8_t *cell[MENU_COLS_MAX];
    const int n = ui_cells(s, cell, lcd_menu_cols());
    for (int i = 0; i < n; i++) {
        const uint16_t f = i >= split ? fg2 : fg;
        for (int r = 0; r < MENU_CH_H; r++) {
            const uint8_t b = cell[i][r];
            for (int k = 0; k < 8; k++)
                if (b & (0x80 >> k)) ui_px(i * 8 + k, y + r, f);
        }
    }
}

extern "C" void lcd_menu_line(int row, const char *s, uint16_t fg, uint16_t bg) {
    lcd_menu_line_ex(row, s, fg, fg, MENU_COLS_MAX, bg, bg, 0, 0, 0);
}

extern "C" void lcd_menu_rule(int y, int x0, int x1, uint16_t color) {
    lcd_ui_fill(x0, y, x1, y + 1, color, 0);
}

extern "C" void lcd_menu_blank_rows(int first, int last) {
    for (int row = first; row <= last; row++) {
        lcd_menu_line(row, "", 0, s_menu_bg);
    }
}
