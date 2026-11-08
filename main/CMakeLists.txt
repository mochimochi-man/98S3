idf_component_register(
    SRCS "main.cpp" "hostfile_sd.cpp" "platform_stubs.cpp" "lcd_spi.cpp" "usb_kbd.cpp" "audio_codec.cpp" "menu_disk.cpp" "fdd_ext.cpp" "screenshot.cpp" "bt_hid.cpp" "usb_msc.cpp" "usb_image.cpp" "sd_spi.cpp" "s3_stubs.cpp"
    INCLUDE_DIRS "."
    # The compatible BIOS and font, built into the image rather than read off
    # the SD card. The card is still searched first when the menu names a file.
    EMBED_FILES "rom/PC98N.ROM" "rom/FONT_ESP.ROM" "rom/HDDROM.BIN"
    REQUIRES pc98core fatfs sdmmc esp_lcd usb driver nvs_flash esp_app_format esp_driver_i2s esp_driver_spi
             esp_driver_uart esp_driver_gpio esp_psram esp_timer bt esp_hid
             espressif__usb_host_hid espressif__tinyusb
)

target_compile_options(${COMPONENT_LIB} PRIVATE
    -Wno-error=incompatible-pointer-types -Wno-incompatible-pointer-types
    -Wno-error=int-conversion -Wno-error=implicit-function-declaration
    -Wno-error=format -Wno-error=format-truncation -Wno-error=return-type -fno-strict-aliasing)
if(PC98_NEWCPU)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE PC98_NEWCPU=${PC98_NEWCPU})
endif()

