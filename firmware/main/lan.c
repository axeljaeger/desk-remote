#include "lan.h"
#include "wifi.h"

#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>
#include "bootloader_random.h"
#include "driver/jpeg_decode.h"
#include "driver/jpeg_encode.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_private/esp_cache_private.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "mbedtls/gcm.h"
#include "mbedtls/md.h"
#include "mdns.h"
#include "nvs.h"

enum { LAN_PORT = 5176, LAN_KEY_BYTES = 32, LAN_CHALLENGE = 16, LAN_NONCE = 12, LAN_TAG_BYTES = 16, LAN_MAX_REQUEST = 1024, LAN_MAX_REPLY = 16384 };
enum { VIDEO_JPEG_MAX = 131072, VIDEO_BYTES = TAB5_VIDEO_DMA_WIDTH * TAB5_VIDEO_DMA_HEIGHT * 2, VIDEO_TICKET_LENGTH = 36 };
enum { VIDEO_UDP_HEADER = 8, VIDEO_UDP_CHUNK = 1024, VIDEO_UDP_MAX = 32768 };
enum { SCREEN_WIDTH = 640, SCREEN_HEIGHT = 360, SCREEN_JPEG_MAX = 131072 };
typedef enum {
    VIDEO_OK,
    VIDEO_INIT_FAILED,
    VIDEO_CONNECT_FAILED,
    VIDEO_REQUEST_FAILED,
    VIDEO_HEADER_MISSING,
    VIDEO_RECORD_INVALID,
    VIDEO_RECORD_INCOMPLETE,
    VIDEO_AUTH_FAILED,
    VIDEO_JPEG_INVALID,
    VIDEO_DECODE_FAILED,
} video_status_t;

typedef struct { uint32_t address; uint8_t key[LAN_KEY_BYTES]; } pair_t;
typedef struct { uint32_t length; uint8_t bytes[LAN_MAX_REQUEST]; } request_t;

static QueueHandle_t pairs, requests;
static SemaphoreHandle_t reply_lock;
static atomic_bool ready;
static atomic_bool rediscover;
static atomic_uint discoveries;
static uint8_t *latest_reply;
static uint32_t latest_length;
static uint8_t nonce_prefix[8];
static atomic_uint nonce_sequence;
static atomic_uint video_generation;
static atomic_int video_status;
static atomic_uint video_authenticated, video_decoded;
static atomic_uint video_decode_us, video_overwritten;
static atomic_uint video_udp_packets, video_udp_frames, video_udp_lost_frames, video_tcp_fallbacks;
static atomic_uint video_errors[VIDEO_DECODE_FAILED + 1];
static atomic_int screen_status = 1;
static QueueHandle_t active_pair, video_requests;
static SemaphoreHandle_t video_lock;
static uint8_t *video_frame, *video_display;
static bool video_frame_ready;
typedef struct { uint32_t generation; char ticket[VIDEO_TICKET_LENGTH]; bool prefer_udp, portrait; } video_request_t;
typedef struct {
    uint32_t sequence;
    uint32_t received;
    uint32_t size;
    bool started;
    bool complete;
} udp_frame_t;
typedef struct {
    uint16_t *pixels;
    size_t capacity;
    char id[36];
} screen_job_t;

static bool transfer(int socket_fd, uint8_t *bytes, size_t length, bool writing)
{
    TickType_t start = xTaskGetTickCount();
    while (length && xTaskGetTickCount() - start < pdMS_TO_TICKS(1600)) {
        int count = writing ? send(socket_fd, bytes, length, 0) : recv(socket_fd, bytes, length, 0);
        if (count <= 0) { return false; }
        bytes += count;
        length -= count;
    }
    return length == 0;
}

static int connect_mac(uint32_t address)
{
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) { return -1; }
    struct sockaddr_in endpoint = { .sin_family = AF_INET, .sin_port = htons(LAN_PORT), .sin_addr.s_addr = htonl(address) };
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) { close(fd); return -1; }
    if (connect(fd, (const struct sockaddr *)&endpoint, sizeof(endpoint)) != 0) {
        fd_set sockets;
        FD_ZERO(&sockets);
        FD_SET(fd, &sockets);
        struct timeval timeout = { .tv_sec = 0, .tv_usec = 700000 };
        int error = 0;
        socklen_t size = sizeof(error);
        if (errno != EINPROGRESS || select(fd + 1, NULL, &sockets, NULL, &timeout) != 1 ||
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) != 0 || error) { close(fd); return -1; }
    }
    struct timeval timeout = { .tv_sec = 0, .tv_usec = 750000 };
    fcntl(fd, F_SETFL, flags);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    return fd;
}

static bool send_record(int fd, mbedtls_gcm_context *aes, const uint8_t *plain, uint32_t length,
                        uint8_t *record, const uint8_t *aad, size_t aad_length)
{
    unsigned sequence = atomic_load(&nonce_sequence);
    do {
        if (sequence == UINT32_MAX) { return false; }
    } while (!atomic_compare_exchange_weak(&nonce_sequence, &sequence, sequence + 1));
    uint32_t counter = htonl(sequence + 1);
    uint32_t size = htonl(length + LAN_NONCE + LAN_TAG_BYTES);
    memcpy(record, nonce_prefix, sizeof(nonce_prefix));
    memcpy(record + sizeof(nonce_prefix), &counter, sizeof(counter));
    return mbedtls_gcm_crypt_and_tag(aes, MBEDTLS_GCM_ENCRYPT, length, record, LAN_NONCE, aad, aad_length,
                                    plain, record + LAN_NONCE, LAN_TAG_BYTES, record + LAN_NONCE + length) == 0 &&
           transfer(fd, (uint8_t *)&size, sizeof(size), true) && transfer(fd, record, length + LAN_NONCE + LAN_TAG_BYTES, true);
}

static bool send_request(int fd, mbedtls_gcm_context *aes, const pair_t *pair,
                         const uint8_t *request, uint32_t request_size, uint8_t *record, uint8_t *challenge)
{
    uint8_t aad[LAN_CHALLENGE + 1] = {0};
    if (mbedtls_gcm_setkey(aes, MBEDTLS_CIPHER_ID_AES, pair->key, LAN_KEY_BYTES * 8) != 0 ||
        !transfer(fd, aad, LAN_CHALLENGE, false)) { return false; }
    memcpy(challenge, aad, LAN_CHALLENGE);
    return send_record(fd, aes, request, request_size, record, aad, sizeof(aad));
}

static int32_t receive_record(int fd, mbedtls_gcm_context *aes, uint8_t *record, uint8_t *plain,
                              uint32_t limit, const uint8_t *aad, size_t aad_length)
{
    uint32_t size;
    if (!transfer(fd, (uint8_t *)&size, sizeof(size), false)) { return -VIDEO_HEADER_MISSING; }
    size = ntohl(size);
    if (size <= LAN_NONCE + LAN_TAG_BYTES || size > limit + LAN_NONCE + LAN_TAG_BYTES) { return -VIDEO_RECORD_INVALID; }
    if (!transfer(fd, record, size, false)) { return -VIDEO_RECORD_INCOMPLETE; }
    uint32_t length = size - LAN_NONCE - LAN_TAG_BYTES;
    return mbedtls_gcm_auth_decrypt(aes, length, record, LAN_NONCE, aad, aad_length,
                                    record + size - LAN_TAG_BYTES, LAN_TAG_BYTES, record + LAN_NONCE, plain) == 0 ? (int32_t)length : -VIDEO_AUTH_FAILED;
}

static bool exchange(const pair_t *pair, const uint8_t *request, uint32_t request_size, uint8_t *record, uint8_t *plain)
{
    int fd = connect_mac(pair->address);
    if (fd < 0) { return false; }
    mbedtls_gcm_context aes;
    mbedtls_gcm_init(&aes);
    uint8_t aad[LAN_CHALLENGE + 1] = {0};
    int32_t length = 0;
    if (send_request(fd, &aes, pair, request, request_size, record, aad)) {
        aad[LAN_CHALLENGE] = 1;
        length = receive_record(fd, &aes, record, plain, LAN_MAX_REPLY, aad, sizeof(aad));
        if (length > 0) {
            xSemaphoreTake(reply_lock, portMAX_DELAY);
            latest_length = length;
            memcpy(latest_reply, plain, latest_length);
            xSemaphoreGive(reply_lock);
        }
    }
    mbedtls_gcm_free(&aes);
    close(fd);
    return length > 0;
}

static bool discovery_match(const mdns_result_t *result, const char *identity)
{
    if (result->port != LAN_PORT) { return false; }
    for (size_t i = 0; i < result->txt_count; i++) {
        const mdns_txt_item_t *item = &result->txt[i];
        if (result->txt_value_len && item->key && item->value && strcmp(item->key, "pair") == 0 &&
            result->txt_value_len[i] == 32 && memcmp(item->value, identity, 32) == 0) { return true; }
    }
    return false;
}

static bool discover_mac(pair_t *pair, const uint8_t *request, uint32_t length, uint8_t *record, uint8_t *plain)
{
    static const uint8_t context[] = "pro-remote-bonjour-v1";
    static const char hex[] = "0123456789abcdef";
    uint8_t digest[32];
    if (mbedtls_md_hmac(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), pair->key, sizeof(pair->key),
                        context, sizeof(context) - 1, digest) != 0) { return false; }
    char identity[32];
    for (size_t i = 0; i < sizeof(identity) / 2; i++) {
        identity[i * 2] = hex[digest[i] >> 4];
        identity[i * 2 + 1] = hex[digest[i] & 0xf];
    }
    mdns_result_t *results = NULL;
    if (mdns_query_ptr("_proremote", "_tcp", 1300, 8, &results) != ESP_OK) { return false; }
    pair_t candidate = *pair;
    bool found = false;
    unsigned attempts = 0;
    for (mdns_result_t *entry = results; entry && !found && attempts < 4; entry = entry->next) {
        if (!discovery_match(entry, identity)) { continue; }
        unsigned previous_attempts = attempts;
        for (mdns_ip_addr_t *ip = entry->addr; ip && !found && attempts < 4; ip = ip->next) {
            if (ip->addr.type != ESP_IPADDR_TYPE_V4 || ip->addr.u_addr.ip4.addr == 0) { continue; }
            candidate.address = ntohl(ip->addr.u_addr.ip4.addr);
            attempts++;
            found = exchange(&candidate, request, length, record, plain);
        }
        if (!found && attempts == previous_attempts && entry->hostname && attempts < 4) {
            esp_ip4_addr_t ip;
            if (mdns_query_a(entry->hostname, 650, &ip) == ESP_OK && ip.addr != 0) {
                candidate.address = ntohl(ip.addr);
                attempts++;
                found = exchange(&candidate, request, length, record, plain);
            }
        }
    }
    mdns_query_results_free(results);
    if (found) {
        pair->address = candidate.address;
        atomic_fetch_add(&discoveries, 1);
    }
    return found;
}

static void lan_task(void *arg)
{
    uint8_t *record = heap_caps_malloc(LAN_MAX_REPLY + LAN_NONCE + LAN_TAG_BYTES, MALLOC_CAP_8BIT | MALLOC_CAP_SPIRAM);
    uint8_t *plain = heap_caps_malloc(LAN_MAX_REPLY, MALLOC_CAP_8BIT | MALLOC_CAP_SPIRAM);
    if (!record || !plain) { heap_caps_free(record); heap_caps_free(plain); vTaskDelete(NULL); return; }
    static const uint8_t snapshot[] = "{\"type\":\"get_audio\",\"version\":1}";
    pair_t pair = {0};
    nvs_handle_t nvs = 0;
    TickType_t next_snapshot = xTaskGetTickCount();
    TickType_t next_discovery = next_snapshot;
    bool mdns_started = false;
    for (;;) {
        uint32_t address = 0;
        if (tab5_wifi_status(&address) != 2 || !address) {
            atomic_store(&ready, false);
            xQueueReset(requests);
            vTaskDelay(pdMS_TO_TICKS(250));
            continue;
        }
        if (!nvs && nvs_open("tab5_lan", NVS_READWRITE, &nvs) == ESP_OK) {
            size_t length = sizeof(pair);
            if (nvs_get_blob(nvs, "pair", &pair, &length) != ESP_OK || length != sizeof(pair)) { pair.address = 0; }
        }
        if (xQueueReceive(pairs, &pair, 0) && nvs) {
            if (nvs_set_blob(nvs, "pair", &pair, sizeof(pair)) == ESP_OK) { nvs_commit(nvs); }
        }
        if (!pair.address) { vTaskDelay(pdMS_TO_TICKS(200)); continue; }
        if (active_pair) { xQueueOverwrite(active_pair, &pair); }
        request_t request;
        int32_t until_snapshot = (int32_t)(next_snapshot - xTaskGetTickCount());
        bool command = until_snapshot > 0 && xQueueReceive(requests, &request, (TickType_t)until_snapshot);
        if (!command) { next_snapshot = xTaskGetTickCount() + pdMS_TO_TICKS(700); }
        bool forced = atomic_exchange(&rediscover, false);
        bool success = !forced && exchange(&pair, command ? request.bytes : snapshot,
                                           command ? request.length : sizeof(snapshot) - 1, record, plain);
        if (!success) { atomic_store(&ready, false); }
        if (!success && (forced || (int32_t)(xTaskGetTickCount() - next_discovery) >= 0)) {
            if (!mdns_started) { mdns_started = mdns_init() == ESP_OK; }
            uint32_t previous = pair.address;
            success = mdns_started && discover_mac(&pair, snapshot, sizeof(snapshot) - 1, record, plain);
            if (success && active_pair) { xQueueOverwrite(active_pair, &pair); }
            if (success && nvs && pair.address != previous &&
                nvs_set_blob(nvs, "pair", &pair, sizeof(pair)) == ESP_OK) { nvs_commit(nvs); }
            next_discovery = xTaskGetTickCount() + pdMS_TO_TICKS(4000);
        }
        if (!success) { xQueueReset(requests); }
        atomic_store(&ready, success);
        // Give Slint a chance to consume the reply before sending the next command.
        vTaskDelay(pdMS_TO_TICKS(30));
    }
}

static void report_video_status(video_status_t status, int detail)
{
    if (status != VIDEO_OK) { atomic_fetch_add(&video_errors[status], 1); }
    int previous = atomic_load(&video_status);
    // Keep the most specific error across reconnect attempts until a frame succeeds.
    if (status == VIDEO_OK || (int)status > previous) {
        atomic_store(&video_status, status);
        if (status != VIDEO_OK) { ESP_LOGW("tab5_video", "Stream status %d (%d)", status, detail); }
    }
}

static int open_video_udp(uint16_t *port)
{
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) { return -1; }
    struct sockaddr_in local = { .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_ANY) };
    socklen_t length = sizeof(local);
    struct timeval timeout = { .tv_sec = 0, .tv_usec = 250000 };
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0 ||
        bind(fd, (const struct sockaddr *)&local, sizeof(local)) != 0 ||
        getsockname(fd, (struct sockaddr *)&local, &length) != 0) {
        close(fd);
        return -1;
    }
    *port = ntohs(local.sin_port);
    return fd;
}

static int32_t receive_video_udp(int fd, mbedtls_gcm_context *aes, uint8_t *packet, uint8_t *jpeg,
                                 uint8_t *aad, udp_frame_t *frame, uint32_t mac_address, uint32_t generation)
{
    const unsigned wire_overhead = VIDEO_UDP_HEADER + LAN_NONCE + LAN_TAG_BYTES;
    const TickType_t started = xTaskGetTickCount();
    // Keep unauthenticated fragments away from any partially assembled frame.
    uint8_t *plain = jpeg + VIDEO_UDP_MAX;
    while (generation == atomic_load(&video_generation) &&
           xTaskGetTickCount() - started < pdMS_TO_TICKS(1800)) {
        struct sockaddr_in origin;
        socklen_t origin_size = sizeof(origin);
        int length = recvfrom(fd, packet, wire_overhead + VIDEO_UDP_CHUNK + 1, 0,
                              (struct sockaddr *)&origin, &origin_size);
        if (length < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) { continue; }
        if (length < 0) { break; }
        if (origin.sin_addr.s_addr != htonl(mac_address) || length <= (int)wire_overhead ||
            length > (int)(wire_overhead + VIDEO_UDP_CHUNK)) { continue; }

        uint32_t wire_sequence;
        memcpy(&wire_sequence, packet, sizeof(wire_sequence));
        uint32_t sequence = ntohl(wire_sequence);
        uint32_t size = (uint32_t)packet[4] << 8 | packet[5];
        uint32_t part = (uint32_t)packet[6] << 8 | packet[7];
        uint32_t count = (size + VIDEO_UDP_CHUNK - 1) / VIDEO_UDP_CHUNK;
        if (size == 0 || size > VIDEO_UDP_MAX || part >= count) { continue; }
        uint32_t offset = part * VIDEO_UDP_CHUNK;
        uint32_t payload = size - offset < VIDEO_UDP_CHUNK ? size - offset : VIDEO_UDP_CHUNK;
        if ((uint32_t)length != wire_overhead + payload) { continue; }
        uint32_t bit = UINT32_C(1) << part;
        if (frame->started && (sequence < frame->sequence ||
            (sequence == frame->sequence && (size != frame->size || (frame->received & bit))))) { continue; }

        memcpy(aad + LAN_CHALLENGE + 1, packet, VIDEO_UDP_HEADER);
        const uint8_t *nonce = packet + VIDEO_UDP_HEADER;
        const uint8_t *ciphertext = nonce + LAN_NONCE;
        if (mbedtls_gcm_auth_decrypt(aes, payload, nonce, LAN_NONCE, aad, LAN_CHALLENGE + 1 + VIDEO_UDP_HEADER,
                                    ciphertext + payload, LAN_TAG_BYTES, ciphertext, plain) != 0) {
            report_video_status(VIDEO_AUTH_FAILED, 0);
            continue;
        }
        atomic_fetch_add(&video_udp_packets, 1);
        if (!frame->started || sequence > frame->sequence) {
            if (frame->started && !frame->complete) { atomic_fetch_add(&video_udp_lost_frames, 1); }
            *frame = (udp_frame_t){ .sequence = sequence, .size = size, .started = true };
        }
        memcpy(jpeg + offset, plain, payload);
        frame->received |= bit;
        if (frame->received == (UINT32_MAX >> (32 - count))) {
            frame->complete = true;
            atomic_fetch_add(&video_udp_frames, 1);
            return (int32_t)size;
        }
    }
    if (generation == atomic_load(&video_generation) && frame->started && !frame->complete) {
        atomic_fetch_add(&video_udp_lost_frames, 1);
    }
    return frame->started ? -VIDEO_RECORD_INCOMPLETE : -VIDEO_HEADER_MISSING;
}

static void video_task(void *arg)
{
    uint8_t *record = NULL, *jpeg = NULL, *decoded = NULL;
    size_t decoded_capacity;
    jpeg_decoder_handle_t decoder = NULL;
    const jpeg_decode_engine_cfg_t engine = { .timeout_ms = 150 };
    // ESP-IDF 5.4 swaps the two RGB565 bytes for the RGB option. The PPA and
    // Slint expect the decoder's native little-endian words, without that swap.
    const jpeg_decode_cfg_t format = { .output_format = JPEG_DECODE_OUT_FORMAT_RGB565,
                                      .rgb_order = JPEG_DEC_RGB_ELEMENT_ORDER_BGR, .conv_std = JPEG_YUV_RGB_CONV_STD_BT601 };
    const jpeg_decode_memory_alloc_cfg_t output = { .buffer_direction = JPEG_DEC_ALLOC_OUTPUT_BUFFER };
    video_request_t job;
    for (;;) {
        xQueueReceive(video_requests, &job, portMAX_DELAY);
        if (job.generation != atomic_load(&video_generation)) { continue; }
        uint32_t width = job.portrait ? TAB5_VIDEO_DMA_WIDTH : TAB5_VIDEO_WIDTH;
        uint32_t height = job.portrait ? TAB5_VIDEO_DMA_HEIGHT : TAB5_VIDEO_HEIGHT;
        report_video_status(VIDEO_OK, 0);
        const uint32_t caps = MALLOC_CAP_8BIT | MALLOC_CAP_SPIRAM;
        size_t alignment;
        if (esp_cache_get_alignment(caps, &alignment) != ESP_OK || alignment < LAN_NONCE + VIDEO_UDP_HEADER) {
            report_video_status(VIDEO_INIT_FAILED, 0);
            continue;
        }
        if (!record) {
            // The ciphertext starts after the nonce. Align that address for AES DMA.
            uint8_t *allocation = heap_caps_aligned_alloc(alignment, alignment + VIDEO_JPEG_MAX + LAN_TAG_BYTES, caps);
            if (allocation) { record = allocation + alignment - LAN_NONCE; }
        }
        if (!jpeg) { jpeg = heap_caps_aligned_alloc(alignment, VIDEO_JPEG_MAX, caps); }
        if (!decoded) { decoded = jpeg_alloc_decoder_mem(VIDEO_BYTES, &output, &decoded_capacity); }
        esp_err_t result = decoder ? ESP_OK : jpeg_new_decoder_engine(&engine, &decoder);
        if (!record || !jpeg || !decoded || !decoder) {
            report_video_status(VIDEO_INIT_FAILED, result);
            continue;
        }
        bool use_udp = job.prefer_udp;
        while (job.generation == atomic_load(&video_generation)) {
            pair_t pair;
            int fd = atomic_load(&ready) && xQueuePeek(active_pair, &pair, 0) ? connect_mac(pair.address) : -1;
            if (fd < 0) {
                report_video_status(VIDEO_CONNECT_FAILED, 0);
                vTaskDelay(pdMS_TO_TICKS(250));
                continue;
            }
            mbedtls_gcm_context aes;
            mbedtls_gcm_init(&aes);
            uint8_t aad[LAN_CHALLENGE + 1 + VIDEO_UDP_HEADER];
            uint16_t udp_port = 0;
            int udp = use_udp ? open_video_udp(&udp_port) : -1;
            if (use_udp && udp < 0) {
                use_udp = false;
                atomic_fetch_add(&video_tcp_fallbacks, 1);
            }
            char request[128];
            int size = udp >= 0 ? snprintf(request, sizeof(request), "{\"type\":\"camera_stream_udp\",\"version\":1,\"id\":\"%.*s\",\"udp_port\":%u}", VIDEO_TICKET_LENGTH, job.ticket, (unsigned)udp_port)
                                : snprintf(request, sizeof(request), "{\"type\":\"camera_stream\",\"version\":1,\"id\":\"%.*s\"}", VIDEO_TICKET_LENGTH, job.ticket);
            bool accepted = send_request(fd, &aes, &pair, (const uint8_t *)request, size, record, aad);
            if (accepted && udp >= 0) {
                aad[LAN_CHALLENGE] = 1;
                accepted = receive_record(fd, &aes, record, jpeg, 1, aad, LAN_CHALLENGE + 1) == 1 && jpeg[0] == 1;
                close(fd);
                fd = -1;
            }
            if (accepted) {
                aad[LAN_CHALLENGE] = udp >= 0 ? 4 : 2;
                udp_frame_t frame = {0};
                for (uint32_t sequence = 0; job.generation == atomic_load(&video_generation) && sequence < UINT32_MAX; sequence++) {
                    int32_t length;
                    if (udp >= 0) {
                        length = receive_video_udp(udp, &aes, record - VIDEO_UDP_HEADER, jpeg, aad, &frame, pair.address, job.generation);
                    } else {
                        uint32_t index = htonl(sequence);
                        memcpy(aad + LAN_CHALLENGE + 1, &index, sizeof(index));
                        length = receive_record(fd, &aes, record, jpeg, VIDEO_JPEG_MAX, aad, LAN_CHALLENGE + 5);
                    }
                    if (length < 0) {
                        if (job.generation == atomic_load(&video_generation)) { report_video_status((video_status_t)-length, 0); }
                        break;
                    }
                    atomic_fetch_add(&video_authenticated, 1);
                    jpeg_decode_picture_info_t info;
                    uint32_t out_size;
                    int64_t decode_start = esp_timer_get_time();
                    result = jpeg_decoder_get_info(jpeg, length, &info);
                    if (result != ESP_OK || info.width != width || info.height != height) {
                        report_video_status(VIDEO_JPEG_INVALID, result);
                        continue;
                    }
                    result = jpeg_decoder_process(decoder, &format, jpeg, length, decoded, decoded_capacity, &out_size);
                    if (result != ESP_OK || out_size != width * height * sizeof(uint16_t)) {
                        report_video_status(VIDEO_DECODE_FAILED, result);
                        continue;
                    }
                    atomic_fetch_add(&video_decode_us, (uint32_t)(esp_timer_get_time() - decode_start));
                    atomic_fetch_add(&video_decoded, 1);
                    xSemaphoreTake(video_lock, portMAX_DELAY);
                    if (job.generation == atomic_load(&video_generation)) {
                        uint8_t *previous = video_frame;
                        if (video_frame_ready) { atomic_fetch_add(&video_overwritten, 1); }
                        video_frame = decoded;
                        decoded = previous;
                        video_frame_ready = true;
                        report_video_status(VIDEO_OK, 0);
                    }
                    xSemaphoreGive(video_lock);
                }
            } else { report_video_status(VIDEO_REQUEST_FAILED, 0); }
            mbedtls_gcm_free(&aes);
            if (fd >= 0) { close(fd); }
            if (udp >= 0) { close(udp); }
            if (use_udp && job.generation == atomic_load(&video_generation)) {
                use_udp = false;
                atomic_fetch_add(&video_tcp_fallbacks, 1);
            }
            vTaskDelay(pdMS_TO_TICKS(150));
        }
    }
}

void tab5_lan_setup(void)
{
    // Sample the P4's main entropy source before starting the network task.
    bootloader_random_enable();
    esp_fill_random(nonce_prefix, sizeof(nonce_prefix));
    bootloader_random_disable();
    nonce_prefix[0] &= 0x7f; // Keep the client and Mac nonce spaces separate.
    pairs = xQueueCreate(1, sizeof(pair_t));
    requests = xQueueCreate(4, sizeof(request_t));
    reply_lock = xSemaphoreCreateMutex();
    latest_reply = heap_caps_malloc(LAN_MAX_REPLY, MALLOC_CAP_8BIT | MALLOC_CAP_SPIRAM);
    if (pairs && requests && reply_lock && latest_reply) { xTaskCreate(lan_task, "tab5_lan", 6144, NULL, 4, NULL); }
    active_pair = xQueueCreate(1, sizeof(pair_t));
    video_requests = xQueueCreate(1, sizeof(video_request_t));
    video_lock = xSemaphoreCreateMutex();
    const jpeg_decode_memory_alloc_cfg_t output = { .buffer_direction = JPEG_DEC_ALLOC_OUTPUT_BUFFER };
    size_t capacity;
    video_frame = jpeg_alloc_decoder_mem(VIDEO_BYTES, &output, &capacity);
    video_display = jpeg_alloc_decoder_mem(VIDEO_BYTES, &output, &capacity);
    if (active_pair && video_requests && video_lock && video_frame && video_display) {
        if (xTaskCreate(video_task, "tab5_video", 9216, NULL, 3, NULL) != pdPASS) { video_requests = NULL; }
    } else { video_requests = NULL; }
}

static void reset_video_frames(void)
{
    atomic_fetch_add(&video_generation, 1);
    if (video_lock) {
        xSemaphoreTake(video_lock, portMAX_DELAY);
        video_frame_ready = false;
        xSemaphoreGive(video_lock);
    }
}

int32_t tab5_video_start(const uint8_t *ticket, uint32_t length, int32_t prefer_udp, int32_t portrait)
{
    if (!video_requests || length != VIDEO_TICKET_LENGTH) { return 0; }
    for (uint32_t i = 0; i < length; i++) {
        uint8_t c = ticket[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c == '-')) { return 0; }
    }
    reset_video_frames();
    atomic_store(&video_status, VIDEO_OK);
    video_request_t request = { .generation = atomic_load(&video_generation),
                                .prefer_udp = prefer_udp != 0, .portrait = portrait != 0 };
    memcpy(request.ticket, ticket, sizeof(request.ticket));
    tab5_wifi_set_video_active(1);
    if (xQueueOverwrite(video_requests, &request) == pdPASS) { return 1; }
    tab5_wifi_set_video_active(0);
    return 0;
}

void tab5_video_stop(void)
{
    reset_video_frames();
    tab5_wifi_set_video_active(0);
}

int32_t tab5_video_take(void)
{
    if (!video_lock || !xSemaphoreTake(video_lock, 0)) { return 0; }
    bool available = video_frame_ready;
    if (available) {
        // Only the UI task uses video_display, until the next successful take.
        uint8_t *previous = video_display;
        video_display = video_frame;
        video_frame = previous;
        video_frame_ready = false;
    }
    xSemaphoreGive(video_lock);
    return available;
}

const uint16_t *tab5_video_pixels(void) { return (const uint16_t *)video_display; }

int32_t tab5_video_status(void) { return atomic_load(&video_status); }

void tab5_video_metrics(tab5_video_metrics_t *out)
{
    *out = (tab5_video_metrics_t) {
        .authenticated = atomic_load(&video_authenticated),
        .decoded = atomic_load(&video_decoded),
        .header_errors = atomic_load(&video_errors[VIDEO_HEADER_MISSING]),
        .invalid_lengths = atomic_load(&video_errors[VIDEO_RECORD_INVALID]),
        .incomplete_records = atomic_load(&video_errors[VIDEO_RECORD_INCOMPLETE]),
        .auth_errors = atomic_load(&video_errors[VIDEO_AUTH_FAILED]),
        .jpeg_errors = atomic_load(&video_errors[VIDEO_JPEG_INVALID]) + atomic_load(&video_errors[VIDEO_DECODE_FAILED]),
        .udp_packets = atomic_load(&video_udp_packets),
        .udp_frames = atomic_load(&video_udp_frames),
        .udp_lost_frames = atomic_load(&video_udp_lost_frames),
        .tcp_fallbacks = atomic_load(&video_tcp_fallbacks),
        .decode_us = atomic_load(&video_decode_us),
        .overwritten = atomic_load(&video_overwritten),
    };
}

static bool upload_screen(const char *id, const uint8_t *jpeg, uint32_t length)
{
    pair_t pair;
    if (!active_pair || !xQueuePeek(active_pair, &pair, 0)) { return false; }
    const uint32_t caps = MALLOC_CAP_8BIT | MALLOC_CAP_SPIRAM;
    size_t alignment;
    if (esp_cache_get_alignment(caps, &alignment) != ESP_OK || alignment < LAN_NONCE) { return false; }
    uint8_t *allocation = heap_caps_aligned_alloc(alignment, alignment + length + LAN_TAG_BYTES, caps);
    if (!allocation) { return false; }
    uint8_t *record = allocation + alignment - LAN_NONCE;
    int fd = connect_mac(pair.address);
    bool sent = false;
    if (fd >= 0) {
        char request[96];
        int size = snprintf(request, sizeof(request), "{\"type\":\"ui_test_upload\",\"version\":1,\"id\":\"%.36s\"}", id);
        uint8_t aad[LAN_CHALLENGE + 1];
        mbedtls_gcm_context aes;
        mbedtls_gcm_init(&aes);
        if (send_request(fd, &aes, &pair, (const uint8_t *)request, size, record, aad)) {
            aad[LAN_CHALLENGE] = 3;
            sent = send_record(fd, &aes, jpeg, length, record, aad, sizeof(aad));
        }
        mbedtls_gcm_free(&aes);
        if (sent) { shutdown(fd, SHUT_WR); }
        close(fd);
    }
    heap_caps_free(allocation);
    return sent;
}

static void screen_task(void *arg)
{
    screen_job_t *job = arg;
    const jpeg_encode_memory_alloc_cfg_t output = { .buffer_direction = JPEG_ENC_ALLOC_OUTPUT_BUFFER };
    size_t capacity;
    uint8_t *jpeg = jpeg_alloc_encoder_mem(SCREEN_JPEG_MAX, &output, &capacity);
    const jpeg_encode_engine_cfg_t engine = { .timeout_ms = 250 };
    const jpeg_encode_cfg_t format = { .width = SCREEN_WIDTH, .height = SCREEN_HEIGHT,
        .src_type = JPEG_ENCODE_IN_FORMAT_RGB565, .sub_sample = JPEG_DOWN_SAMPLING_YUV444, .image_quality = 85 };
    jpeg_encoder_handle_t encoder = NULL;
    uint32_t length;
    bool sent = jpeg && jpeg_new_encoder_engine(&engine, &encoder) == ESP_OK &&
        jpeg_encoder_process(encoder, &format, (const uint8_t *)job->pixels, job->capacity, jpeg, capacity, &length) == ESP_OK &&
        length >= 128 && upload_screen(job->id, jpeg, length);
    if (encoder) { jpeg_del_encoder_engine(encoder); }
    heap_caps_free(jpeg);
    heap_caps_free(job->pixels);
    free(job);
    atomic_store(&screen_status, sent ? 1 : -1);
    vTaskDelete(NULL);
}

int32_t tab5_screen_capture(const uint16_t *front, const uint8_t *id, uint32_t length)
{
    if (length != sizeof(((screen_job_t *)0)->id) || !atomic_load(&screen_status)) { return 0; }
    for (uint32_t i = 0; i < length; i++) {
        uint8_t c = id[i];
        if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || c == '-')) { return 0; }
    }
    screen_job_t *job = malloc(sizeof(*job));
    if (!job) { return 0; }
    const jpeg_encode_memory_alloc_cfg_t input = { .buffer_direction = JPEG_ENC_ALLOC_INPUT_BUFFER };
    job->pixels = jpeg_alloc_encoder_mem(SCREEN_WIDTH * SCREEN_HEIGHT * sizeof(uint16_t), &input, &job->capacity);
    if (!job->pixels) { free(job); return 0; }
    memcpy(job->id, id, sizeof(job->id));
    // Undo the renderer's rotation while reducing each dimension by half.
    for (int y = 0; y < SCREEN_HEIGHT; y++) {
        for (int x = 0; x < SCREEN_WIDTH; x++) {
            job->pixels[y * SCREEN_WIDTH + x] = front[(2 * SCREEN_WIDTH - 1 - 2 * x) * (2 * SCREEN_HEIGHT) + 2 * y];
        }
    }
    atomic_store(&screen_status, 0);
    if (xTaskCreate(screen_task, "tab5_screen", 8192, job, 3, NULL) == pdPASS) { return 1; }
    atomic_store(&screen_status, -1);
    heap_caps_free(job->pixels);
    free(job);
    return 0;
}

int32_t tab5_screen_status(void) { return atomic_load(&screen_status); }

int32_t tab5_lan_pair(uint32_t address, const uint8_t *key)
{
    if (!pairs || !address) { return 0; }
    pair_t pair = { .address = address };
    memcpy(pair.key, key, LAN_KEY_BYTES);
    return xQueueOverwrite(pairs, &pair) == pdPASS;
}

int32_t tab5_lan_ready(void) { return atomic_load(&ready); }
uint32_t tab5_lan_discoveries(void) { return atomic_load(&discoveries); }
void tab5_lan_rediscover(void) { atomic_store(&rediscover, true); }

int32_t tab5_lan_send(const uint8_t *bytes, uint32_t length)
{
    if (!atomic_load(&ready) || !length || length > LAN_MAX_REQUEST) { return 0; }
    request_t request = { .length = length };
    memcpy(request.bytes, bytes, length);
    return xQueueSend(requests, &request, 0) == pdPASS;
}

int32_t tab5_lan_receive(uint8_t *bytes, uint32_t capacity)
{
    if (!reply_lock || !xSemaphoreTake(reply_lock, 0)) { return 0; }
    uint32_t length = latest_length <= capacity ? latest_length : 0;
    if (length) { memcpy(bytes, latest_reply, length); }
    latest_length = 0;
    xSemaphoreGive(reply_lock);
    return length;
}
