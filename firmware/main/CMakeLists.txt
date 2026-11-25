idf_component_register(SRCS "board.c" "wifi.c" "lan.c"
    PRIV_REQUIRES esp_driver_gpio esp_driver_i2c esp_driver_jpeg esp_driver_ledc esp_driver_ppa esp_driver_usb_serial_jtag esp_lcd esp_timer esp_event esp_mm esp_netif esp_wifi nvs_flash mbedtls bootloader_support
        espressif__esp_io_expander_pi4ioe5v6408 espressif__esp_lcd_st7123 espressif__esp_lcd_touch_st7123 espressif__mdns)

# The pinned SDK's DSI driver uses this rectangular DMA2D copy helper internally.
idf_component_get_property(esp_lcd_directory esp_lcd COMPONENT_DIR)
if(EXISTS "${esp_lcd_directory}/priv_include/esp_async_fbcpy.h")
    target_include_directories(${COMPONENT_LIB} PRIVATE "${esp_lcd_directory}/priv_include")
    target_compile_definitions(${COMPONENT_LIB} PRIVATE TAB5_HAVE_FRAMEBUFFER_DMA)
endif()

find_program(CARGO_EXECUTABLE cargo HINTS "$ENV{HOME}/.cargo/bin" REQUIRED)
set(RUST_PROJECT "${CMAKE_CURRENT_LIST_DIR}/../..")
set(RUST_TARGET "riscv32imafc-unknown-none-elf")
set(RUST_BUILD "${RUST_PROJECT}/target")
set(RUST_LIBRARY "${RUST_BUILD}/${RUST_TARGET}/release/libtab5_slint_smoke.a")

add_custom_target(tab5_rust_build
    COMMAND "${CARGO_EXECUTABLE}" rustc --locked --target "${RUST_TARGET}"
            --target-dir "${RUST_BUILD}" --release --lib --crate-type staticlib
    WORKING_DIRECTORY "${RUST_PROJECT}"
    BYPRODUCTS "${RUST_LIBRARY}"
    USES_TERMINAL
    VERBATIM)

add_prebuilt_library(tab5_rust "${RUST_LIBRARY}")
add_dependencies(tab5_rust tab5_rust_build)
target_link_libraries(${COMPONENT_LIB} PRIVATE tab5_rust)
