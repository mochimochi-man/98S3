// Board wiring for the ESP32-S3 build (ESP32-S3 N16R8 DevKit, the same wiring as np2 espresso).
//
//   LCD  ST7789 240x320 / ST7796 320x480, SPI3: MOSI 11, SCLK 12, CS 10, DC 9, RST 13 (ST7796 only; -1 = none)
//   SD   microSD over SPI2: CS 4, SCK 5, MISO 6, MOSI 7 (FAT32, 32GB or less)
//   I2S  MAX98357A: BCLK 38, LRCLK 39, DOUT 40
//   USB  the S3's own USB OTG port as host (keyboard / mouse through a self-powered hub)
//   BT   the S3's own BLE (keyboard / mouse)
#pragma once

// ---- LCD (lcd_spi.cpp) ------------------------------------------------------
#define BRD_LCD_HOST        SPI3_HOST
#define BRD_LCD_MOSI        11
#define BRD_LCD_SCLK        12
#define BRD_LCD_CS          10
#define BRD_LCD_DC          9
#define BRD_LCD_RST         13

// ---- microSD (sd_spi.cpp) ---------------------------------------------------
#define BRD_SD_HOST         SPI2_HOST
#define BRD_SD_CS           4
#define BRD_SD_SCK          5
#define BRD_SD_MISO         6
#define BRD_SD_MOSI         7

// ---- I2S amplifier (audio_i2s.cpp) ------------------------------------------
#define BRD_I2S_BCLK        38
#define BRD_I2S_LRCLK       39
#define BRD_I2S_DOUT        40

// ---- PC-98 screen -------------------------------------------------------------
#define BRD_PC98_W          640
#define BRD_PC98_H          400

// ---- Audio --------------------------------------------------------------------
#define BRD_AUDIO_RATE      22050

// ---- Emulated CPU speed --------------------------------------------------------
// The machine multiplies the base clock by g_settings.clock_mul. The S3 is far slower than the P4 the ladder was
// measured on; the steps are kept, and what it sustains in real time is to be measured on the board.
#define BRD_CPU_MULT_LADDER 1, 2, 3, 4, 5, 6, 8, 10
#define CPU_MULT_MAX        10
