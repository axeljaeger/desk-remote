#pragma once

#include <stdint.h>
#include "driver/i2c_master.h"

void tab5_wifi_setup(i2c_master_bus_handle_t bus);
int32_t tab5_wifi_configure(const uint8_t *ssid, uint32_t ssid_len, const uint8_t *password, uint32_t password_len);
int32_t tab5_wifi_status(uint32_t *ipv4);
void tab5_wifi_set_video_active(int32_t active);
int32_t tab5_wifi_power_save(void);
void tab5_wifi_request_test_mode(int32_t mode);
int32_t tab5_wifi_test_mode(void);
