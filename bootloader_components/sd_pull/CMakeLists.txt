idf_component_register(SRCS "sd_pull.c")
target_link_libraries(${COMPONENT_LIB} INTERFACE "-u bootloader_hooks_include")
