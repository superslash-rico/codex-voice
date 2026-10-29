#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CP_ALERTS 8
#define CP_FRAME_MAX 4096
#define CP_TITLE_MAX 97
#define CP_PET_NAME_MAX 33
#define CP_DEFAULT_PET_NAME "那个谁"

typedef enum { CP_RESULT, CP_QUESTION, CP_APPROVAL, CP_BLOCKED, CP_TEST,
               CP_USAGE_LOW, CP_USAGE_RESET, CP_PHRASE_COUNT } cp_phrase_t;
typedef struct {
    char id[17];
    char title[CP_TITLE_MAX];
    cp_phrase_t kind;
    bool snoozed;
    bool verify;
} cp_alert_t;
typedef struct { int remaining, minutes, reset_seconds; } cp_quota_t;
typedef struct {
    char epoch[17];
    char pet_name[CP_PET_NAME_MAX];
    bool online, enabled, muted, quiet, monitor;
    bool presenter_supported, presenting, presenter_ready;
    int presenter_status, presenter_target;
    char presenter_lease[17];
    int usage, running, total, count, selected;
    cp_quota_t quotas[2];
    int quota_count, usage_age;
    uint64_t updated_ms;
    cp_alert_t alerts[CP_ALERTS];
} cp_model_t;
typedef struct {
    char data[CP_FRAME_MAX];
    size_t used;
    bool dropping;
} cp_line_t;
typedef void (*cp_line_callback)(const char *line, void *context);

void cp_model_init(cp_model_t *model);
bool cp_model_apply(cp_model_t *model, const cp_model_t *incoming, uint64_t now);
bool cp_model_expire(cp_model_t *model, uint64_t now);
void cp_model_select(cp_model_t *model, int delta);
bool cp_can_play(const cp_model_t *model, const char *epoch, uint64_t now);
bool cp_token_valid(const char *token);
bool cp_text_valid(const char *text, size_t max_bytes);
int cp_phrase(const char *name);
void cp_line_feed(cp_line_t *line, const uint8_t *data, size_t length,
                  cp_line_callback callback, void *context);
