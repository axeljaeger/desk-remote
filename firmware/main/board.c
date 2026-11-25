#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "driver/ledc.h"
#include "driver/ppa.h"
#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "esp_attr.h"
#include "esp_cache.h"
#include "esp_heap_caps.h"
#include "esp_io_expander_pi4ioe5v6408.h"
#include "esp_lcd_mipi_dsi.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_st7123.h"
#include "esp_lcd_touch_st7123.h"
#include "esp_ldo_regulator.h"
#include "esp_log.h"
#include "esp_private/esp_cache_private.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "st7123_tab5_init.h"
#include "wifi.h"
#include "lan.h"

#ifdef TAB5_HAVE_FRAMEBUFFER_DMA
#include "esp_async_fbcpy.h"
#endif

enum {
    LCD_WIDTH = 720,
    LCD_HEIGHT = 1280,
    LCD_BACKLIGHT = GPIO_NUM_22,
    LCD_TOUCH_INTERRUPT = GPIO_NUM_23,
    LCD_RESET = IO_EXPANDER_PIN_NUM_4,
    TOUCH_RESET = IO_EXPANDER_PIN_NUM_5,
};

static const char *TAG = "tab5_slint";
static esp_lcd_touch_handle_t touchscreen;
static esp_lcd_panel_handle_t display_panel;
static StaticSemaphore_t refresh_semaphore_storage;
static SemaphoreHandle_t refresh_semaphore;
static bool first_frame = true;

extern _Noreturn void tab5_run_slint(uint16_t *front_buffer, uint16_t *back_buffer);

// Supply the integer popcount helper with ESP-IDF's ABI. The Rust target's
// fallback object for this symbol is tagged as soft-float.
int __popcountsi2(uint32_t value)
{
    value -= (value >> 1) & UINT32_C(0x55555555);
    value = (value & UINT32_C(0x33333333)) + ((value >> 2) & UINT32_C(0x33333333));
    value = (value + (value >> 4)) & UINT32_C(0x0f0f0f0f);
    return (int)((value * UINT32_C(0x01010101)) >> 24);
}

// Keep Rust's IPv4 byte-order helper in the same ABI as the ESP-IDF objects.
__attribute__((optimize("O0"))) uint32_t __bswapsi2(uint32_t value)
{
    return (value << 24) | ((value & 0xff00) << 8) |
           ((value >> 8) & 0xff00) | (value >> 24);
}

void *tab5_allocate(size_t size, size_t alignment)
{
    if (alignment < sizeof(void *)) {
        alignment = sizeof(void *);
    }
    return heap_caps_aligned_alloc(alignment, size, MALLOC_CAP_8BIT);
}

void tab5_free(void *ptr)
{
    heap_caps_free(ptr);
}

_Noreturn void tab5_abort(void)
{
    ESP_LOGE(TAG, "Slint runtime panicked");
    abort();
}

uint64_t tab5_time_us(void)
{
    return esp_timer_get_time();
}

void tab5_wait(void)
{
    vTaskDelay(pdMS_TO_TICKS(12));
}

static bool IRAM_ATTR display_refresh_done(esp_lcd_panel_handle_t panel,
                                           esp_lcd_dpi_panel_event_data_t *event,
                                           void *context)
{
    BaseType_t task_woken = pdFALSE;
    xSemaphoreGiveFromISR(context, &task_woken);
    return task_woken == pdTRUE;
}

void tab5_present(const uint16_t *framebuffer, int32_t first_row, int32_t end_row)
{
    // A driver-owned framebuffer is handed to scanout at the next frame boundary.
    ESP_ERROR_CHECK(esp_lcd_panel_draw_bitmap(display_panel, 0, first_row, LCD_WIDTH, end_row, framebuffer));
    // Discard any notification already queued. The next refresh guarantees that
    // DMA has switched to this framebuffer and Slint can reuse the old front buffer.
    xSemaphoreTake(refresh_semaphore, 0);
    ESP_ERROR_CHECK(xSemaphoreTake(refresh_semaphore, pdMS_TO_TICKS(100)) == pdTRUE
                    ? ESP_OK : ESP_ERR_TIMEOUT);
    if (first_frame) {
        ESP_ERROR_CHECK(ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, 665));
        ESP_ERROR_CHECK(ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0));
        first_frame = false;
        ESP_LOGI(TAG, "Tab5 Companion ready");
    }
}

uint16_t *tab5_allocate_page_cache(size_t bytes)
{
    const uint32_t caps = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT;
    size_t alignment;
    if (esp_cache_get_alignment(caps, &alignment) != ESP_OK) { return NULL; }
    return heap_caps_aligned_alloc(alignment, bytes, caps);
}

int32_t tab5_sync_page_cache(const uint16_t *pixels)
{
#ifdef TAB5_HAVE_FRAMEBUFFER_DMA
    const size_t size = LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t);
    return esp_cache_msync((void *)pixels, size, ESP_CACHE_MSYNC_FLAG_DIR_C2M) == ESP_OK;
#else
    return false;
#endif
}

#ifdef TAB5_HAVE_FRAMEBUFFER_DMA
static bool IRAM_ATTR framebuffer_copy_done(esp_async_fbcpy_handle_t copy, esp_async_fbcpy_event_data_t *event, void *ctx)
{
    BaseType_t wake = pdFALSE;
    xSemaphoreGiveFromISR(ctx, &wake);
    return wake == pdTRUE;
}

static bool dma_copy(esp_async_fbcpy_trans_desc_t *job, uint16_t *dest, uint32_t first_row, uint32_t row_count)
{
    static esp_async_fbcpy_handle_t copy;
    static StaticSemaphore_t semaphore_storage;
    static SemaphoreHandle_t done;
    static size_t cache_alignment;
    static bool initialized;
    if (!initialized) {
        initialized = true;
        const esp_async_fbcpy_config_t config = {};
        esp_err_t status = esp_cache_get_alignment(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT, &cache_alignment);
        if (status == ESP_OK) { status = esp_async_fbcpy_install(&config, &copy); }
        if (status == ESP_OK) { done = xSemaphoreCreateBinaryStatic(&semaphore_storage); }
        else { ESP_LOGW(TAG, "Framebuffer DMA init: %s", esp_err_to_name(status)); }
    }
    if (!done) { return false; }
    // Invalidation requires whole cache lines, including at both edges of the copy.
    uintptr_t mask = cache_alignment - 1;
    uintptr_t start = (uintptr_t)(dest + first_row * LCD_WIDTH) & ~mask;
    uintptr_t end = ((uintptr_t)(dest + (first_row + row_count) * LCD_WIDTH) + mask) & ~mask;
    if (esp_cache_msync((void *)start, end - start, ESP_CACHE_MSYNC_FLAG_DIR_M2C) != ESP_OK) {
        return false;
    }
    esp_err_t status = esp_async_fbcpy(copy, job, framebuffer_copy_done, done);
    if (status != ESP_OK) { return false; }
    // A submitted destination can't be used by scanout until the copy has completed.
    ESP_ERROR_CHECK(xSemaphoreTake(done, pdMS_TO_TICKS(200)) == pdTRUE ? ESP_OK : ESP_ERR_TIMEOUT);
    return true;
}

static bool dma_copy_pages(uint16_t *dest, const uint16_t *strip, uint32_t strip_height,
                           uint32_t source_row, uint32_t top, uint32_t bottom)
{
    esp_async_fbcpy_trans_desc_t job = {
        .src_buffer = strip, .dst_buffer = dest,
        .src_buffer_size_x = LCD_WIDTH, .src_buffer_size_y = strip_height,
        .dst_buffer_size_x = LCD_WIDTH, .dst_buffer_size_y = LCD_HEIGHT,
        .src_offset_x = top, .src_offset_y = source_row, .dst_offset_x = top,
        .copy_size_x = bottom - top, .copy_size_y = LCD_HEIGHT,
        .pixel_format_unique_id = { .color_type_id = COLOR_TYPE_ID(COLOR_SPACE_RGB, COLOR_PIXEL_RGB565) },
    };
    return dma_copy(&job, dest, 0, LCD_HEIGHT);
}
#endif

static esp_err_t blit_pages(ppa_client_handle_t ppa, uint16_t *dest, const uint16_t *strip,
                           uint32_t strip_height, uint32_t source_row, uint32_t top, uint32_t bottom)
{
    const ppa_srm_oper_config_t copy = {
        .in = { .buffer = strip, .pic_w = LCD_WIDTH, .pic_h = strip_height,
                .block_w = bottom - top, .block_h = LCD_HEIGHT, .block_offset_x = top,
                .block_offset_y = source_row, .srm_cm = PPA_SRM_COLOR_MODE_RGB565 },
        .out = { .buffer = dest, .buffer_size = LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t),
                 .pic_w = LCD_WIDTH, .pic_h = LCD_HEIGHT, .block_offset_x = top,
                 .srm_cm = PPA_SRM_COLOR_MODE_RGB565 },
        .scale_x = 1.0f, .scale_y = 1.0f, .mode = PPA_TRANS_MODE_BLOCKING,
    };
    return ppa_do_scale_rotate_mirror(ppa, &copy);
}

static ppa_client_handle_t display_ppa(void)
{
    static ppa_client_handle_t ppa;
    static bool initialized;
    if (!initialized) {
        initialized = true;
        const ppa_client_config_t config = {
            .oper_type = PPA_OPERATION_SRM, .data_burst_length = PPA_DATA_BURST_LENGTH_64,
        };
        esp_err_t result = ppa_register_client(&config, &ppa);
        if (result != ESP_OK) { ESP_LOGW(TAG, "Display PPA init: %s", esp_err_to_name(result)); }
    }
    return ppa;
}

int32_t tab5_camera_blit(uint16_t *dest, const uint16_t *source, uint32_t left, uint32_t top,
                         uint32_t width, uint32_t height, uint32_t dirty_first, uint32_t dirty_end,
                         int32_t portrait)
{
    if (!source || left >= LCD_HEIGHT || top >= LCD_WIDTH ||
        width > LCD_HEIGHT - left || height > LCD_WIDTH - top) { return false; }

    // Preserve Slint pixels outside the video when the hardware invalidates destination rows.
    if (dirty_end > dirty_first &&
        esp_cache_msync(dest + dirty_first * LCD_WIDTH, (dirty_end - dirty_first) * LCD_WIDTH * sizeof(uint16_t),
                        ESP_CACHE_MSYNC_FLAG_DIR_C2M | ESP_CACHE_MSYNC_FLAG_UNALIGNED) != ESP_OK) { return false; }

    if (portrait) {
#ifdef TAB5_HAVE_FRAMEBUFFER_DMA
        if (width < TAB5_VIDEO_DMA_HEIGHT || height < TAB5_VIDEO_DMA_WIDTH) { return false; }
        uint32_t image_left = left + (width - TAB5_VIDEO_DMA_HEIGHT) / 2;
        uint32_t image_top = top + (height - TAB5_VIDEO_DMA_WIDTH) / 2;
        uint32_t first_row = LCD_HEIGHT - image_left - TAB5_VIDEO_DMA_HEIGHT;
        esp_async_fbcpy_trans_desc_t job = {
            .src_buffer = source, .dst_buffer = dest,
            .src_buffer_size_x = TAB5_VIDEO_DMA_WIDTH, .src_buffer_size_y = TAB5_VIDEO_DMA_HEIGHT,
            .dst_buffer_size_x = LCD_WIDTH, .dst_buffer_size_y = LCD_HEIGHT,
            .dst_offset_x = image_top, .dst_offset_y = first_row,
            .copy_size_x = TAB5_VIDEO_DMA_WIDTH, .copy_size_y = TAB5_VIDEO_DMA_HEIGHT,
            .pixel_format_unique_id = { .color_type_id = COLOR_TYPE_ID(COLOR_SPACE_RGB, COLOR_PIXEL_RGB565) },
        };
        return dma_copy(&job, dest, first_row, TAB5_VIDEO_DMA_HEIGHT);
#else
        return false;
#endif
    }

    ppa_client_handle_t ppa = display_ppa();
    if (!ppa) { return false; }
    // The scaler accepts eight fractional bits. Round down before centering the picture.
    uint32_t scale_q8 = MIN(width * 256 / TAB5_VIDEO_WIDTH, height * 256 / TAB5_VIDEO_HEIGHT);
    if (!scale_q8) { return false; }
    uint32_t scaled_w = TAB5_VIDEO_WIDTH * scale_q8 / 256;
    uint32_t scaled_h = TAB5_VIDEO_HEIGHT * scale_q8 / 256;
    uint32_t image_left = left + (width - scaled_w) / 2;
    uint32_t image_top = top + (height - scaled_h) / 2;

    const ppa_srm_oper_config_t job = {
        .in = { .buffer = source, .pic_w = TAB5_VIDEO_WIDTH, .pic_h = TAB5_VIDEO_HEIGHT,
                .block_w = TAB5_VIDEO_WIDTH, .block_h = TAB5_VIDEO_HEIGHT, .srm_cm = PPA_SRM_COLOR_MODE_RGB565 },
        .out = { .buffer = dest, .buffer_size = LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t),
                 .pic_w = LCD_WIDTH, .pic_h = LCD_HEIGHT, .block_offset_x = image_top,
                 .block_offset_y = LCD_HEIGHT - image_left - scaled_w, .srm_cm = PPA_SRM_COLOR_MODE_RGB565 },
        .rotation_angle = PPA_SRM_ROTATION_ANGLE_90,
        .scale_x = (float)scale_q8 / 256, .scale_y = (float)scale_q8 / 256,
        .mode = PPA_TRANS_MODE_BLOCKING,
    };
    esp_err_t result = ppa_do_scale_rotate_mirror(ppa, &job);
    if (result != ESP_OK) { ESP_LOGW(TAG, "Camera PPA blit: %s", esp_err_to_name(result)); }
    return result == ESP_OK;
}

int32_t tab5_compose_pages(uint16_t *dest, const uint16_t *chrome, const uint16_t *strip,
                          uint32_t strip_height, uint32_t source_row, uint32_t top, uint32_t bottom, int32_t allow_dma)
{
    // In portrait scanout order, logical horizontal motion shifts full physical rows.
    static bool ppa_failed;
    int32_t backend = 0;
#ifdef TAB5_HAVE_FRAMEBUFFER_DMA
    if (allow_dma && dma_copy_pages(dest, strip, strip_height, source_row, top, bottom)) { backend = 2; }
#endif
    ppa_client_handle_t ppa = backend == 0 && !ppa_failed ? display_ppa() : NULL;
    if (backend == 0 && ppa) {
        esp_err_t result = blit_pages(ppa, dest, strip, strip_height, source_row, top, bottom);
        if (result == ESP_OK) {
            backend = 1;
        } else {
            ESP_LOGW(TAG, "Swipe PPA blit: %s", esp_err_to_name(result));
            ppa_failed = true;
        }
    }

    if (backend && !chrome) { return backend; }
    // Write the fixed header and footer after the destination cache has been invalidated.
    for (uint32_t row = 0; row < LCD_HEIGHT; row++) {
        uint16_t *out = dest + row * LCD_WIDTH;
        if (chrome) {
            const uint16_t *header_footer = chrome + row * LCD_WIDTH;
            memcpy(out, header_footer, top * sizeof(uint16_t));
            memcpy(out + bottom, header_footer + bottom, (LCD_WIDTH - bottom) * sizeof(uint16_t));
        }
        if (!backend) {
            const uint16_t *body = strip + (source_row + row) * LCD_WIDTH;
            memcpy(out + top, body + top, (bottom - top) * sizeof(uint16_t));
        }
    }
    return backend;
}

int32_t tab5_touch(uint16_t *x, uint16_t *y)
{
    if (esp_lcd_touch_read_data(touchscreen) != ESP_OK) {
        return -1;
    }
    esp_lcd_touch_point_data_t point;
    uint8_t count = 0;
    if (esp_lcd_touch_get_data(touchscreen, &point, &count, 1) != ESP_OK) {
        return -1;
    }
    if (count == 0) {
        return 0;
    }
    *x = point.x;
    *y = point.y;
    return 1;
}

int32_t tab5_serial_read(uint8_t *bytes, uint32_t capacity)
{
    return usb_serial_jtag_read_bytes(bytes, capacity, 0);
}

int32_t tab5_serial_write(const uint8_t *bytes, size_t length)
{
    if (!usb_serial_jtag_is_connected()) {
        return 0;
    }
    return usb_serial_jtag_write_bytes(bytes, length, 0);
}

static i2c_master_bus_handle_t setup_touch(void)
{
    const i2c_master_bus_config_t bus_config = {
        .i2c_port = I2C_NUM_1,
        .sda_io_num = GPIO_NUM_31,
        .scl_io_num = GPIO_NUM_32,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .flags.enable_internal_pullup = true,
    };
    i2c_master_bus_handle_t bus;
    ESP_ERROR_CHECK(i2c_new_master_bus(&bus_config, &bus));

    esp_io_expander_handle_t expander;
    ESP_ERROR_CHECK(esp_io_expander_new_i2c_pi4ioe5v6408(
        bus, ESP_IO_EXPANDER_I2C_PI4IOE5V6408_ADDRESS_LOW, &expander));
    // The ST7123 LCD reset line must be released as an input with pull-up.
    ESP_ERROR_CHECK(esp_io_expander_set_pullupdown(expander, LCD_RESET, IO_EXPANDER_PULL_UP));
    ESP_ERROR_CHECK(esp_io_expander_set_dir(expander, LCD_RESET, IO_EXPANDER_INPUT));
    ESP_ERROR_CHECK(esp_io_expander_set_output_mode(expander, LCD_RESET, IO_EXPANDER_OUTPUT_MODE_OPEN_DRAIN));
    ESP_ERROR_CHECK(esp_io_expander_set_level(expander, TOUCH_RESET, 1));
    ESP_ERROR_CHECK(esp_io_expander_set_output_mode(expander, TOUCH_RESET, IO_EXPANDER_OUTPUT_MODE_PUSH_PULL));
    ESP_ERROR_CHECK(esp_io_expander_set_dir(expander, TOUCH_RESET, IO_EXPANDER_OUTPUT));
    vTaskDelay(pdMS_TO_TICKS(500));

    const esp_lcd_panel_io_i2c_config_t io_config = ESP_LCD_TOUCH_IO_I2C_ST7123_CONFIG();
    esp_lcd_panel_io_handle_t io;
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_i2c(bus, &io_config, &io));
    const esp_lcd_touch_config_t touch_config = {
        .x_max = LCD_WIDTH,
        .y_max = LCD_HEIGHT,
        .rst_gpio_num = GPIO_NUM_NC,
        .int_gpio_num = LCD_TOUCH_INTERRUPT,
    };
    ESP_ERROR_CHECK(esp_lcd_touch_new_i2c_st7123(io, &touch_config, &touchscreen));
    return bus;
}

static esp_lcd_panel_handle_t setup_display(void)
{
    const ledc_timer_config_t backlight_timer = {
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .duty_resolution = LEDC_TIMER_10_BIT,
        .timer_num = LEDC_TIMER_0,
        .freq_hz = 5000,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    const ledc_channel_config_t backlight_channel = {
        .gpio_num = LCD_BACKLIGHT,
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .channel = LEDC_CHANNEL_0,
        .timer_sel = LEDC_TIMER_0,
    };
    ESP_ERROR_CHECK(ledc_timer_config(&backlight_timer));
    ESP_ERROR_CHECK(ledc_channel_config(&backlight_channel));

    const esp_ldo_channel_config_t dsi_power = {.chan_id = 3, .voltage_mv = 2500};
    esp_ldo_channel_handle_t power;
    ESP_ERROR_CHECK(esp_ldo_acquire_channel(&dsi_power, &power));

    const esp_lcd_dsi_bus_config_t dsi_config = {
        .bus_id = 0,
        .num_data_lanes = 2,
        .phy_clk_src = MIPI_DSI_PHY_CLK_SRC_DEFAULT,
        .lane_bit_rate_mbps = 1000,
    };
    esp_lcd_dsi_bus_handle_t dsi;
    ESP_ERROR_CHECK(esp_lcd_new_dsi_bus(&dsi_config, &dsi));
    const esp_lcd_dbi_io_config_t io_config = {.lcd_cmd_bits = 8, .lcd_param_bits = 8};
    esp_lcd_panel_io_handle_t io;
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_dbi(dsi, &io_config, &io));

    const esp_lcd_dpi_panel_config_t timing = {
        .dpi_clk_src = MIPI_DSI_DPI_CLK_SRC_DEFAULT,
        .dpi_clock_freq_mhz = 70,
        .in_color_format = LCD_COLOR_FMT_RGB565,
        .num_fbs = 2,
        .video_timing = {
            .h_size = LCD_WIDTH, .v_size = LCD_HEIGHT,
            .hsync_back_porch = 40, .hsync_pulse_width = 2, .hsync_front_porch = 40,
            .vsync_back_porch = 8, .vsync_pulse_width = 2, .vsync_front_porch = 220,
        },
    };
    st7123_vendor_config_t vendor = {
        .init_cmds = disp_init_data_st7123,
        .init_cmds_size = sizeof(disp_init_data_st7123) / sizeof(disp_init_data_st7123[0]),
        .mipi_config = {.dsi_bus = dsi, .dpi_config = &timing},
    };
    const esp_lcd_panel_dev_config_t panel_config = {
        .reset_gpio_num = GPIO_NUM_NC,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16,
        .vendor_config = &vendor,
    };
    esp_lcd_panel_handle_t panel;
    ESP_ERROR_CHECK(esp_lcd_new_panel_st7123(io, &panel_config, &panel));
    refresh_semaphore = xSemaphoreCreateBinaryStatic(&refresh_semaphore_storage);
    const esp_lcd_dpi_panel_event_callbacks_t callbacks = {.on_refresh_done = display_refresh_done};
    ESP_ERROR_CHECK(esp_lcd_dpi_panel_register_event_callbacks(panel, &callbacks, refresh_semaphore));
    ESP_ERROR_CHECK(esp_lcd_panel_reset(panel));
    ESP_ERROR_CHECK(esp_lcd_panel_init(panel));
    ESP_ERROR_CHECK(esp_lcd_panel_invert_color(panel, false));
    ESP_ERROR_CHECK(esp_lcd_panel_mirror(panel, false, false));
    ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(panel, true));
    return panel;
}

void app_main(void)
{
    usb_serial_jtag_driver_config_t serial = {.rx_buffer_size = 4096, .tx_buffer_size = 4096};
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&serial));
    usb_serial_jtag_vfs_use_driver();
    i2c_master_bus_handle_t bus = setup_touch();
    display_panel = setup_display();
    void *front_buffer = NULL;
    void *back_buffer = NULL;
    ESP_ERROR_CHECK(esp_lcd_dpi_panel_get_frame_buffer(display_panel, 2, &front_buffer, &back_buffer));
    tab5_lan_setup();
    tab5_wifi_setup(bus);
    tab5_run_slint(front_buffer, back_buffer);
}
