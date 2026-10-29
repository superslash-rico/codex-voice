#include "companion_model.h"
#include <string.h>

void cp_model_init(cp_model_t *m)
{
    memset(m, 0, sizeof(*m));
    m->usage = -1;
    strcpy(m->pet_name,CP_DEFAULT_PET_NAME);
}

bool cp_token_valid(const char *s)
{
    if (!s) return false;
    for (int i = 0; i < 16; ++i)
        if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return false;
    return s[16] == 0;
}

bool cp_text_valid(const char *s, size_t max_bytes)
{
    if (!s) return false;
    size_t length = 0;
    while (length < max_bytes && s[length]) ++length;
    if (length >= max_bytes) return false;
    const unsigned char *p = (const unsigned char *)s;
    for (size_t i = 0; i < length;) {
        unsigned c = p[i++];
        if (c < 0x20 || c == 0x7f) return false;
        if (c < 0x80) continue;
        int n;
        unsigned code;
        if (c >= 0xc2 && c <= 0xdf) { n = 1; code = c & 31; }
        else if (c >= 0xe0 && c <= 0xef) { n = 2; code = c & 15; }
        else if (c >= 0xf0 && c <= 0xf4) { n = 3; code = c & 7; }
        else return false;
        if (i + (size_t)n > length) return false;
        for (int j = 0; j < n; ++j) {
            if ((p[i] & 0xc0) != 0x80) return false;
            code = (code << 6) | (p[i++] & 63);
        }
        if ((n == 1 && code < 0x80) || (n == 2 && code < 0x800) ||
            (n == 3 && code < 0x10000) || code > 0x10ffff ||
            (code >= 0xd800 && code <= 0xdfff)) return false;
    }
    return true;
}

int cp_phrase(const char *s)
{
    static const char *names[] = {"result", "question", "approval", "blocked",
                                  "test", "usage-low", "usage-reset"};
    if (!s) return -1;
    for (int i = 0; i < CP_PHRASE_COUNT; ++i) if (!strcmp(s, names[i])) return i;
    return -1;
}

bool cp_model_apply(cp_model_t *m, const cp_model_t *in, uint64_t now)
{
    if (in->presenter_status<0 || in->presenter_status>3 || in->presenter_target<0 || in->presenter_target>3 ||
        (in->presenter_supported && !cp_token_valid(in->presenter_lease)) ||
        (in->presenting && !in->presenter_supported) || (in->presenter_ready && !in->presenting)) return false;
    if (!cp_token_valid(in->epoch) || in->count < 0 || in->count > CP_ALERTS ||
        in->total < in->count || in->total > 10000 ||
        in->quota_count < 0 || in->quota_count > 2 || in->usage_age < 0 ||
        in->usage < -1 || in->usage > 100 || in->running < 0 || in->running > 200) return false;
    if (in->pet_name[0] && !cp_text_valid(in->pet_name,CP_PET_NAME_MAX)) return false;
    for (int i = 0; i < in->quota_count; ++i) {
        const cp_quota_t *q = &in->quotas[i];
        if (q->remaining < 0 || q->remaining > 100 || q->minutes < 0 ||
            q->minutes > 525600 || q->reset_seconds < -1 || q->reset_seconds > 31536000) return false;
    }
    for (int i = 0; i < in->count; ++i) {
        if (!cp_token_valid(in->alerts[i].id) || !cp_text_valid(in->alerts[i].title, CP_TITLE_MAX) ||
            in->alerts[i].kind < 0 || in->alerts[i].kind > CP_TEST) return false;
        for (int j = 0; j < i; ++j) if (!strcmp(in->alerts[i].id, in->alerts[j].id)) return false;
    }
    int selected = 0;
    if (!strcmp(m->epoch, in->epoch) && m->selected >= 0 && m->selected < m->count) {
        for (int i = 0; i < in->count; ++i)
            if (!strcmp(m->alerts[m->selected].id, in->alerts[i].id)) selected = i;
    }
    *m = *in;
    if (!m->pet_name[0]) strcpy(m->pet_name,CP_DEFAULT_PET_NAME);
    m->selected = selected;
    m->online = true;
    m->updated_ms = now;
    return true;
}

bool cp_model_expire(cp_model_t *m, uint64_t now)
{
    if (m->online && (now < m->updated_ms || now - m->updated_ms > 10000)) {
        cp_model_init(m);
        return true;
    }
    return false;
}

void cp_model_select(cp_model_t *m, int delta)
{
    if (!m->count) { m->selected = 0; return; }
    m->selected = (m->selected + delta) % m->count;
    if (m->selected < 0) m->selected += m->count;
}

bool cp_can_play(const cp_model_t *m, const char *epoch, uint64_t now)
{
    return m->online && m->enabled && !m->muted && !m->presenting && epoch &&
           !strcmp(m->epoch, epoch) && now >= m->updated_ms && now - m->updated_ms <= 10000;
}

void cp_line_feed(cp_line_t *line, const uint8_t *data, size_t length,
                  cp_line_callback callback, void *context)
{
    for (size_t i = 0; i < length; ++i) {
        if (data[i] == '\n') {
            if (!line->dropping && line->used) {
                line->data[line->used] = 0;
                callback(line->data, context);
            }
            line->used = 0; line->dropping = false;
        } else if (!data[i] || line->used >= sizeof(line->data) - 1) {
            line->dropping = true;
        } else if (!line->dropping) {
            line->data[line->used++] = (char)data[i];
        }
    }
}
