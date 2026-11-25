#pragma once

#include <stdint.h>

void tab5_lan_setup(void);
int32_t tab5_lan_pair(uint32_t address, const uint8_t *key);
int32_t tab5_lan_ready(void);
uint32_t tab5_lan_discoveries(void);
void tab5_lan_rediscover(void);
int32_t tab5_lan_send(const uint8_t *bytes, uint32_t length);
int32_t tab5_lan_receive(uint8_t *bytes, uint32_t capacity);
int32_t tab5_video_start(const uint8_t *ticket, uint32_t length, int32_t prefer_udp, int32_t portrait);
void tab5_video_stop(void);
enum { TAB5_VIDEO_WIDTH = 480, TAB5_VIDEO_HEIGHT = 272 };
enum { TAB5_VIDEO_DMA_WIDTH = 304, TAB5_VIDEO_DMA_HEIGHT = 544 };
int32_t tab5_video_take(void);
const uint16_t *tab5_video_pixels(void);
int32_t tab5_video_status(void);

typedef struct {
    uint32_t authenticated;
    uint32_t decoded;
    uint32_t header_errors;
    uint32_t invalid_lengths;
    uint32_t incomplete_records;
    uint32_t auth_errors;
    uint32_t jpeg_errors;
    uint32_t udp_packets;
    uint32_t udp_frames;
    uint32_t udp_lost_frames;
    uint32_t tcp_fallbacks;
    uint32_t decode_us;
    uint32_t overwritten;
} tab5_video_metrics_t;

void tab5_video_metrics(tab5_video_metrics_t *out);
int32_t tab5_screen_capture(const uint16_t *front, const uint8_t *id, uint32_t length);
int32_t tab5_screen_status(void);
