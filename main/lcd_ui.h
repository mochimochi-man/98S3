// The display backend's interface (lcd_spi.cpp), as main.cpp and menu_disk.cpp see it.
//
// The ESP32-S3 build drives a small SPI panel (ST7789 320x240 or ST7796 480x320, landscape). The emulated
// 640x400 screen is reduced onto it; the menu is NOT reduced: it is drawn on a canvas of the panel's own size
// (lcd_ui_w() x lcd_ui_h(), pixels of the panel) with the 8x16 CG ROM font, so its text stays readable.
#pragma once
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PRODUCT_NAME "98S3"

// ---- the emulated screen ----
bool lcd_init(void);
void lcd_blit(const uint8_t *fb);              // 640x480 RGB565 surface, 640x400 used
bool lcd_blit_busy(void);
int  lcd_post_composite(void (*fn)(const void *), const void *arg);   // composite + blit on core 0
bool lcd_comp_busy(void);
int  lcd_take_job_flag(void);
int  lcd_pending(void);
const void *lcd_last_frame(int *w, int *h, int *stride);

// How the 640x400 screen is reduced: 0 Max (brightest of the block), 1 Average (default), 2 Mid, 3 1:1 (no
// reduction, the top-left part of the screen).
int  lcd_get_scale_mode(void);
void lcd_set_scale_mode(int m);
int  lcd_scale_mode_count(void);
const char *lcd_scale_mode_name(int m);

// Drive lamps (FDD1 FDD2 HDD) under the picture.
void lcd_lamps_enable(bool on);
bool lcd_lamps_enabled(void);
void lcd_lamps_tick(void);

// ---- the menu canvas: panel pixels, (0,0) top left, lcd_ui_w() x lcd_ui_h() ----
int  lcd_ui_w(void);
int  lcd_ui_h(void);
void lcd_menu_set_bg(uint16_t c);
void lcd_menu_clear(void);                     // the whole canvas in the page colour
void lcd_menu_flush(void);                     // send what changed to the panel
void lcd_ui_fill(int x0, int y0, int x1, int y1, uint16_t c, int r);   // [x0,x1) x [y0,y1), r>0 rounds corners
int  lcd_ui_text(int x, int y, const char *s, uint16_t c);              // 8x16 cells (Shift-JIS pairs 16x16); returns x after
void lcd_ui_chev(int x, int y, uint16_t c, int dir);                    // chevron 4x7, dir 1 right / -1 left
void lcd_ui_tri(int x, int y, uint16_t c, int dir);                     // triangle 7x4, dir -1 up / 1 down
void lcd_ui_dot(int x, int y, uint16_t c);                              // dot, radius 2
// Text rows of 16 pixels (lcd_ui_h()/16 rows, lcd_ui_w()/8 columns), for the plain full-screen messages.
void lcd_menu_line_ex(int row, const char *s, uint16_t fg, uint16_t fg2, int split,
                      uint16_t bg, uint16_t bar, int c0, int c1, uint16_t stripe);
void lcd_menu_line(int row, const char *s, uint16_t fg, uint16_t bg);
void lcd_menu_rule(int y, int x0, int x1, uint16_t color);
void lcd_menu_blank_rows(int first, int last);
int  lcd_menu_rows(void);
int  lcd_menu_cols(void);

#ifdef __cplusplus
}
#endif
