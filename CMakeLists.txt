# 98S3 - PC-98 emulator (components/pc98core) on an ESP32-S3 N16R8 DevKit with a small SPI panel.
cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# Newer-compiler warnings in dependencies must not break the build.
idf_build_set_property(COMPILE_OPTIONS "-Wno-error;-Wno-stringop-truncation;-Wno-stringop-overflow" APPEND)

set(PROJECT_VER "1.2.0")

# CPU core: 1 = components/pc98core/cpu. Set here so every component sees the same value.
if(NOT DEFINED PC98_NEWCPU)
    set(PC98_NEWCPU 1)
endif()

project(pc98s3)

# The raw tinyusb component finds tusb_config.h through its include path, and
# main/ is not one of its dependencies. Inject it, rather than adding main/ to
# every component's include path globally.
idf_component_get_property(_tusb_lib espressif__tinyusb COMPONENT_LIB)
target_include_directories(${_tusb_lib} PRIVATE "${CMAKE_CURRENT_LIST_DIR}/main")
