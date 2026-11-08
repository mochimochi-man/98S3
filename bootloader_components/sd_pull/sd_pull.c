// Pull the SD card's CS, MISO and MOSI up as early as the chip can. Powered from the S3's USB port alone, a card
// left with these lines floating at power-up answers with another identity and blank sectors until its power goes
// off, whatever the firmware sends it afterwards.
#include "esp_rom_gpio.h"

void bootloader_hooks_include(void) {}

void bootloader_before_init(void) {
    esp_rom_gpio_pad_pullup_only(4);    // CS
    esp_rom_gpio_pad_pullup_only(6);    // MISO
    esp_rom_gpio_pad_pullup_only(7);    // MOSI
}
