#include "wifi.h"

#include <stdatomic.h>
#include <string.h>
#include "esp_check.h"
#include "esp_event.h"
#include "esp_io_expander_pi4ioe5v6408.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "lwip/def.h"
#include "nvs_flash.h"

enum { WAITING = 0, CONNECTING, CONNECTED, RETRYING, UNAVAILABLE };
enum { GOT_IP = BIT0, SETTINGS_CHANGED = BIT1 };
enum { RADIO_DEFAULT, RADIO_AWAKE, RADIO_COMPATIBLE };

typedef struct {
    uint8_t ssid[32];
    uint8_t password[64];
    uint8_t ssid_len;
    uint8_t password_len;
} credentials_t;

static const char *TAG = "tab5_wifi";
static QueueHandle_t requests;
static EventGroupHandle_t events;
static atomic_int status;
static atomic_uint ipv4;
static atomic_int requested_radio, active_radio;
static atomic_bool video_active;
static atomic_int power_save_enabled = -1;

static void wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *event = data;
        atomic_store(&ipv4, lwip_ntohl(event->ip_info.ip.addr));
        xEventGroupSetBits(events, GOT_IP);
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        xEventGroupClearBits(events, GOT_IP);
        atomic_store(&ipv4, 0);
        xEventGroupSetBits(events, SETTINGS_CHANGED);
    }
}

static esp_err_t start_radio(i2c_master_bus_handle_t bus)
{
    esp_io_expander_handle_t expander;
    ESP_RETURN_ON_ERROR(esp_io_expander_new_i2c_pi4ioe5v6408(bus, ESP_IO_EXPANDER_I2C_PI4IOE5V6408_ADDRESS_HIGH, &expander), TAG, "WLAN expander");
    ESP_RETURN_ON_ERROR(esp_io_expander_set_level(expander, IO_EXPANDER_PIN_NUM_0, 1), TAG, "WLAN power");
    ESP_RETURN_ON_ERROR(esp_io_expander_set_output_mode(expander, IO_EXPANDER_PIN_NUM_0, IO_EXPANDER_OUTPUT_MODE_PUSH_PULL), TAG, "WLAN power mode");
    ESP_RETURN_ON_ERROR(esp_io_expander_set_dir(expander, IO_EXPANDER_PIN_NUM_0, IO_EXPANDER_OUTPUT), TAG, "WLAN power direction");
    vTaskDelay(pdMS_TO_TICKS(200));

    ESP_RETURN_ON_ERROR(esp_netif_init(), TAG, "network init");
    ESP_RETURN_ON_ERROR(esp_event_loop_create_default(), TAG, "network event loop");
    if (!esp_netif_create_default_wifi_sta()) { return ESP_ERR_NO_MEM; }
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_RETURN_ON_ERROR(esp_wifi_init(&init), TAG, "Wi-Fi remote init");
    ESP_RETURN_ON_ERROR(esp_wifi_set_storage(WIFI_STORAGE_RAM), TAG, "Wi-Fi storage");
    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(WIFI_MODE_STA), TAG, "Wi-Fi station");
    ESP_RETURN_ON_ERROR(esp_event_handler_register(WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED, wifi_event, NULL), TAG, "Wi-Fi events");
    ESP_RETURN_ON_ERROR(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, wifi_event, NULL), TAG, "IP events");
    return esp_wifi_start();
}

static esp_err_t connect_to(const credentials_t *credentials)
{
    (void)esp_wifi_disconnect();
    xEventGroupClearBits(events, GOT_IP);
    atomic_store(&ipv4, 0);
    wifi_config_t config = {0};
    memcpy(config.sta.ssid, credentials->ssid, credentials->ssid_len);
    memcpy(config.sta.password, credentials->password, credentials->password_len);
    config.sta.threshold.authmode = credentials->password_len ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;
    config.sta.pmf_cfg.capable = true;
    esp_err_t result = esp_wifi_set_config(WIFI_IF_STA, &config);
    if (result == ESP_OK) { result = esp_wifi_connect(); }
    return result;
}

static esp_err_t update_power_save(int radio_mode, wifi_ps_type_t default_mode, wifi_ps_type_t *applied)
{
    wifi_ps_type_t desired = radio_mode != RADIO_DEFAULT || atomic_load(&video_active) ? WIFI_PS_NONE : default_mode;
    if (desired == *applied) { return ESP_OK; }
    esp_err_t result = esp_wifi_set_ps(desired);
    if (result == ESP_OK) {
        *applied = desired;
        atomic_store(&power_save_enabled, desired != WIFI_PS_NONE);
    }
    return result;
}

static void wifi_task(void *arg)
{
    nvs_handle_t nvs;
    esp_err_t rc = nvs_flash_init();
    if (rc != ESP_OK || nvs_open("tab5_wifi", NVS_READWRITE, &nvs) != ESP_OK) {
        atomic_store(&status, UNAVAILABLE);
        vTaskDelete(NULL);
        return;
    }
    credentials_t credentials = {0};
    size_t length = sizeof(credentials);
    if (nvs_get_blob(nvs, "station", &credentials, &length) != ESP_OK || length != sizeof(credentials) ||
        credentials.ssid_len > sizeof(credentials.ssid) || credentials.password_len > sizeof(credentials.password)) {
        memset(&credentials, 0, sizeof(credentials));
    }
    bool needs_save = credentials.ssid_len == 0;
    if (needs_save) { xQueueReceive(requests, &credentials, portMAX_DELAY); }
    atomic_store(&status, CONNECTING);
    rc = start_radio(arg);
    if (rc != ESP_OK) {
        ESP_LOGE(TAG, "Wi-Fi initialization failed: %s", esp_err_to_name(rc));
        atomic_store(&status, UNAVAILABLE);
        nvs_close(nvs);
        vTaskDelete(NULL);
        return;
    }

    uint8_t default_protocol = WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G | WIFI_PROTOCOL_11N | WIFI_PROTOCOL_11AX;
    wifi_ps_type_t default_power_save = WIFI_PS_MIN_MODEM;
    (void)esp_wifi_get_protocol(WIFI_IF_STA, &default_protocol);
    (void)esp_wifi_get_ps(&default_power_save);
    wifi_ps_type_t applied_power_save = default_power_save;
    atomic_store(&power_save_enabled, applied_power_save != WIFI_PS_NONE);
    int radio_mode = RADIO_DEFAULT;
    TickType_t radio_mode_since = 0;
    for (;;) {
        atomic_store(&status, CONNECTING);
        int requested = atomic_load(&requested_radio);
        if (requested != radio_mode) {
            (void)esp_wifi_disconnect();
            uint8_t protocol = requested == RADIO_COMPATIBLE ? default_protocol & ~WIFI_PROTOCOL_11AX : default_protocol;
            esp_err_t protocol_result = esp_wifi_set_protocol(WIFI_IF_STA, protocol);
            esp_err_t power_result = update_power_save(requested, default_power_save, &applied_power_save);
            if (protocol_result != ESP_OK || power_result != ESP_OK) {
                ESP_LOGW(TAG, "WLAN test mode %d unavailable (%s, %s)", requested,
                         esp_err_to_name(protocol_result), esp_err_to_name(power_result));
                (void)esp_wifi_set_protocol(WIFI_IF_STA, default_protocol);
                (void)update_power_save(RADIO_DEFAULT, default_power_save, &applied_power_save);
                requested = RADIO_DEFAULT;
                atomic_store(&requested_radio, requested);
            }
            radio_mode = requested;
            radio_mode_since = xTaskGetTickCount();
            atomic_store(&active_radio, radio_mode);
        }
        esp_err_t power_result = update_power_save(radio_mode, default_power_save, &applied_power_save);
        if (power_result != ESP_OK) { ESP_LOGW(TAG, "WLAN power save: %s", esp_err_to_name(power_result)); }
        rc = connect_to(&credentials);
        EventBits_t ready = rc == ESP_OK ? xEventGroupWaitBits(events, GOT_IP, pdFALSE, pdTRUE, pdMS_TO_TICKS(12000)) : 0;
        if (ready & GOT_IP) {
            atomic_store(&status, CONNECTED);
            if (needs_save) {
                if (nvs_set_blob(nvs, "station", &credentials, sizeof(credentials)) == ESP_OK && nvs_commit(nvs) == ESP_OK) {
                    needs_save = false;
                } else {
                    ESP_LOGW(TAG, "Wi-Fi credentials could not be saved");
                }
            }
            while ((xEventGroupGetBits(events) & GOT_IP) && radio_mode == atomic_load(&requested_radio)) {
                if (xQueueReceive(requests, &credentials, 0)) { needs_save = true; break; }
                if (radio_mode != RADIO_DEFAULT && xTaskGetTickCount() - radio_mode_since >= pdMS_TO_TICKS(120000)) {
                    atomic_store(&requested_radio, RADIO_DEFAULT);
                    break;
                }
                esp_err_t power_result = update_power_save(radio_mode, default_power_save, &applied_power_save);
                if (power_result != ESP_OK) { ESP_LOGW(TAG, "WLAN power save: %s", esp_err_to_name(power_result)); }
                xEventGroupWaitBits(events, SETTINGS_CHANGED, pdTRUE, pdFALSE, pdMS_TO_TICKS(1000));
            }
        } else {
            atomic_store(&status, RETRYING);
            if (radio_mode != RADIO_DEFAULT) {
                atomic_store(&requested_radio, RADIO_DEFAULT);
                continue;
            }
            if (xQueueReceive(requests, &credentials, pdMS_TO_TICKS(6000))) { needs_save = true; }
        }
    }
}

void tab5_wifi_setup(i2c_master_bus_handle_t bus)
{
    requests = xQueueCreate(1, sizeof(credentials_t));
    events = xEventGroupCreate();
    if (!requests || !events || xTaskCreate(wifi_task, "tab5_wifi", 6144, bus, 4, NULL) != pdPASS) {
        atomic_store(&status, UNAVAILABLE);
    }
}

int32_t tab5_wifi_configure(const uint8_t *ssid, uint32_t ssid_len, const uint8_t *password, uint32_t password_len)
{
    if (!requests || atomic_load(&status) == UNAVAILABLE || ssid_len == 0 || ssid_len > 32 ||
        password_len > 64 || (password_len > 0 && password_len < 8) ||
        memchr(ssid, 0, ssid_len) || memchr(password, 0, password_len)) { return 0; }
    credentials_t credentials = {.ssid_len = ssid_len, .password_len = password_len};
    memcpy(credentials.ssid, ssid, ssid_len);
    memcpy(credentials.password, password, password_len);
    if (xQueueOverwrite(requests, &credentials) != pdPASS) { return 0; }
    xEventGroupSetBits(events, SETTINGS_CHANGED);
    return 1;
}

int32_t tab5_wifi_status(uint32_t *address)
{
    *address = atomic_load(&ipv4);
    return atomic_load(&status);
}

void tab5_wifi_request_test_mode(int32_t mode)
{
    if (events && mode >= RADIO_DEFAULT && mode <= RADIO_COMPATIBLE) {
        atomic_store(&requested_radio, mode);
        xEventGroupSetBits(events, SETTINGS_CHANGED);
    }
}

int32_t tab5_wifi_test_mode(void) { return atomic_load(&active_radio); }

void tab5_wifi_set_video_active(int32_t active)
{
    bool awake = active != 0;
    if (atomic_exchange(&video_active, awake) != awake && events) {
        xEventGroupSetBits(events, SETTINGS_CHANGED);
    }
}

int32_t tab5_wifi_power_save(void) { return atomic_load(&power_save_enabled); }
