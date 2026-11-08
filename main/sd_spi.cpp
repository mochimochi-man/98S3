// microSD over SPI (ESP32-S3 DevKit wiring, board_pins.h), mounted at /sd.
//
// The mount point has to be "/sd" because hostfile_sd.cpp opens every image through that prefix.

#include <string.h>

#include "driver/gpio.h"
#include "driver/sdspi_host.h"
#include "driver/spi_common.h"
#include "esp_vfs_fat.h"
#include "sdmmc_cmd.h"
#include "sd_protocol_defs.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "board_pins.h"

extern "C" int ets_printf(const char *fmt, ...);
extern "C" void hf_term(void);
extern "C" void fdd_media_flush_all(void);   // pc98core/media/drives.c: write back dirty track data

#define SD_MOUNT_POINT "/sd"

static sdmmc_card_t *s_card = nullptr;
static bool s_bus = false;
static sdmmc_host_t s_host = SDSPI_HOST_DEFAULT();

// Give up the card cleanly before any reboot: a card left in the middle of a multi-block transfer does not answer
// the initialisation sequence afterwards. A D88 image keeps the track last written in memory, so that goes back
// to the card first.
extern "C" void fdd_ext_shutdown(void);

extern "C" void sd_unmount(void) {
    fdd_ext_shutdown();
    fdd_media_flush_all();
    hf_term();
    if (s_card) {
        esp_vfs_fat_sdcard_unmount(SD_MOUNT_POINT, s_card);
        s_card = nullptr;
    }
}

// Some cards answer CMD59 (CRC_ON_OFF) as an illegal command, and the IDF gives up on the card when that fails.
// The np2 espresso build never sent it (the Arduino SD library runs with CRC off); here it is answered as done,
// so such a card runs with CRC checking off, as it did there.
// Such a card also stops answering after a multi-block read (CMD18 and its stop), while single-block reads work,
// so multi-block reads and writes go to it one block at a time.
static esp_err_t sd_do_transaction(int slot, sdmmc_command_t *cmd) {
    if (cmd->opcode == 59) return ESP_OK;
    if ((cmd->opcode == 18 || cmd->opcode == 25) && cmd->blklen && cmd->datalen > cmd->blklen) {
        // SDHC/SDXC address blocks, standard-capacity cards bytes
        const bool block_addr = !s_card || (s_card->ocr & SD_OCR_SDHC_CAP);
        const size_t n = cmd->datalen / cmd->blklen;
        for (size_t i = 0; i < n; i++) {
            sdmmc_command_t c = *cmd;
            c.opcode = cmd->opcode == 18 ? 17 : 24;
            c.arg = cmd->arg + (uint32_t)(block_addr ? i : i * cmd->blklen);
            c.data = (uint8_t *)cmd->data + i * cmd->blklen;
            c.datalen = cmd->blklen;
            const esp_err_t e = sdspi_host_do_transaction(slot, &c);
            memcpy(cmd->response, c.response, sizeof cmd->response);
            cmd->error = c.error;
            if (e != ESP_OK || c.error != ESP_OK) return e != ESP_OK ? e : ESP_OK;
        }
        return ESP_OK;
    }
    return sdspi_host_do_transaction(slot, cmd);
}

static esp_err_t mount_card(int freq_khz) {
    if (!s_bus) {
        // SPI-mode cards want pull-ups on their lines; module boards often have none on MISO.
        gpio_set_pull_mode((gpio_num_t)BRD_SD_MISO, GPIO_PULLUP_ONLY);
        gpio_set_pull_mode((gpio_num_t)BRD_SD_MOSI, GPIO_PULLUP_ONLY);
        gpio_set_pull_mode((gpio_num_t)BRD_SD_CS, GPIO_PULLUP_ONLY);
        spi_bus_config_t bus = {};
        bus.mosi_io_num = BRD_SD_MOSI;
        bus.miso_io_num = BRD_SD_MISO;
        bus.sclk_io_num = BRD_SD_SCK;
        bus.quadwp_io_num = -1;
        bus.quadhd_io_num = -1;
        bus.max_transfer_sz = 4096;
        const esp_err_t e = spi_bus_initialize((spi_host_device_t)BRD_SD_HOST, &bus, SPI_DMA_CH_AUTO);
        if (e != ESP_OK) return e;
        s_bus = true;
    }
    s_host.slot = BRD_SD_HOST;
    s_host.do_transaction = &sd_do_transaction;
    s_host.max_freq_khz = freq_khz;
    sdspi_device_config_t slot = SDSPI_DEVICE_CONFIG_DEFAULT();
    slot.gpio_cs = (gpio_num_t)BRD_SD_CS;
    slot.host_id = (spi_host_device_t)BRD_SD_HOST;
    // A running machine holds most of the files at once: the hard disk image, the ROMs, a file per floppy drive.
    esp_vfs_fat_sdmmc_mount_config_t mount = {};
    mount.format_if_mount_failed = false;
    mount.max_files = 12;
    mount.allocation_unit_size = 16 * 1024;
    return esp_vfs_fat_sdspi_mount(SD_MOUNT_POINT, &s_host, &slot, &mount, &s_card);
}

extern "C" bool sd_mount(void) {
    // 20MHz is what SPI-mode cards and module wiring take as a rule, but the reads can come back garbled - most
    // often right after power-up and with a PC on the USB port as well - and the volume then looks unformatted.
    // Each speed gets two goes (a card left busy by a previous life does not answer the first time), then the
    // next slower one.
    static const int freq_khz[] = { SDMMC_FREQ_DEFAULT, 10000, 4000 };
    esp_err_t err = ESP_FAIL;
    for (unsigned f = 0; f < sizeof freq_khz / sizeof freq_khz[0] && err != ESP_OK; f++) {
        for (int go = 0; go < 2 && err != ESP_OK; go++) {
            if (f || go) {
                ets_printf("sd: mount failed: 0x%x, retrying\n", (unsigned)err);
                vTaskDelay(pdMS_TO_TICKS(150));
            }
            err = mount_card(freq_khz[f]);
        }
    }
    if (err != ESP_OK) {
        ets_printf("sd: mount failed: 0x%x\n", (unsigned)err);
        return false;
    }
    if (s_card) {
        const uint64_t mb = ((uint64_t)s_card->csd.capacity * s_card->csd.sector_size) / (1024ULL * 1024ULL);
        ets_printf("sd: %s %u MB, SPI @ %d kHz\n", s_card->cid.name, (unsigned)mb, s_card->max_freq_khz);
    }
    return true;
}

extern "C" sdmmc_card_t *sd_get_card(void) {
    return s_card;
}
