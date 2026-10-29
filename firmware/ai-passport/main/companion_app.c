#include "companion_model.h"
#include "companion_presenter.h"
#include "companion_pet.h"
#include "companion_ble.h"
#include "companion_cue.h"
#include "companion_ui.h"
#include "bsp_audio.h"
#include "bsp_battery.h"
#include "bsp_button.h"
#include "bsp_display.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "cJSON.h"
#include "nvs_flash.h"
#include "nvs.h"
#include <stdatomic.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static const char *TAG = "codex_companion";
static QueueHandle_t s_frames, s_keys, s_audio, s_voice_events;
static cp_model_t s_model;
static bool s_audio_ok;
static atomic_uint s_cancel;
static atomic_bool s_audio_busy, s_audio_session;
static char s_active_play[33];
static char s_last_plays[12][33];
static size_t s_play_cursor;
static int s_menu, s_menu_selection;
static char s_toast[80], s_action_id[33];
static uint64_t s_toast_until, s_action_until, s_interaction;
static cp_gesture_t s_gestures[3];
static cp_voice_view_t s_voice;
static int s_quota;
static bool s_asleep=true;
static atomic_bool s_down_down;
static cp_presenter_hold_t s_presenter_hold;
static bool s_page_press[3];
static char s_presenter_session[17];
static uint32_t s_presenter_sequence;
static atomic_bool s_ok_down, s_record_stop, s_record_go;
typedef struct { char id[17]; cp_voice_phase_t phase; int level; } voice_event_t;
static int s_battery = -1;
static char s_pet_name[CP_PET_NAME_MAX]=CP_DEFAULT_PET_NAME;
static bool s_pet_name_dirty;
static uint64_t s_next_pet_name_save;
typedef struct { bsp_btn_t button; bsp_btn_ev_t event; } cp_key_t;
typedef struct { char id[33], epoch[17]; int phrase; unsigned generation; } audio_job_t;
#define PCM_DECL(name) \
    extern const uint8_t pcm_##name##_start[] asm("_binary_pcm_" #name "_start"); \
    extern const uint8_t pcm_##name##_end[] asm("_binary_pcm_" #name "_end")
PCM_DECL(result); PCM_DECL(question); PCM_DECL(approval); PCM_DECL(blocked);
PCM_DECL(test); PCM_DECL(usage_low); PCM_DECL(usage_reset);

static uint64_t now_ms(void) { return (uint64_t)esp_timer_get_time() / 1000; }
static const char *str(cJSON *obj, const char *key)
{
    cJSON *item = cJSON_GetObjectItemCaseSensitive(obj, key);
    return cJSON_IsString(item) ? item->valuestring : NULL;
}
static bool boolean(cJSON *obj, const char *key) { return cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(obj, key)); }
static int number(cJSON *obj, const char *key, int fallback)
{
    cJSON *item = cJSON_GetObjectItemCaseSensitive(obj, key);
    return cJSON_IsNumber(item) && item->valuedouble == item->valueint ? item->valueint : fallback;
}
static void load_pet_name(void)
{
    nvs_handle_t handle;
    if (nvs_open("codex_accessory",NVS_READONLY,&handle)!=ESP_OK) return;
    char name[CP_PET_NAME_MAX]; size_t size=sizeof(name);
    if (nvs_get_str(handle,"pet_name",name,&size)==ESP_OK && name[0] && cp_text_valid(name,sizeof(name)))
        snprintf(s_pet_name,sizeof(s_pet_name),"%s",name);
    nvs_close(handle);
}
static void save_pet_name(void)
{
    if (!s_pet_name_dirty || s_voice.phase!=CP_VOICE_IDLE || atomic_load(&s_audio_busy) || now_ms()<s_next_pet_name_save) return;
    s_next_pet_name_save=now_ms()+5000;
    nvs_handle_t handle;
    if (nvs_open("codex_accessory",NVS_READWRITE,&handle)!=ESP_OK) return;
    esp_err_t result=nvs_set_str(handle,"pet_name",s_pet_name);
    if (result==ESP_OK) result=nvs_commit(handle);
    nvs_close(handle);
    if (result==ESP_OK) s_pet_name_dirty=false;
}
static void offline_model(void)
{
    cp_model_init(&s_model); snprintf(s_model.pet_name,sizeof(s_model.pet_name),"%s",s_pet_name);
}
static void toast(const char *message)
{
    snprintf(s_toast, sizeof(s_toast), "%s", message);
    s_toast_until = now_ms() + 2500;
}
static void send_audio(const char *epoch, const char *id, const char *phase)
{
    char frame[192];
    snprintf(frame, sizeof(frame), "{\"v\":1,\"type\":\"audio\",\"epoch\":\"%s\",\"id\":\"%s\",\"phase\":\"%s\"}", epoch, id, phase);
    (void)cp_ble_send(frame);
}
typedef struct { int64_t last_end; uint32_t gap_us; } cue_feed_t;
static bool cue_write(void *context,const int16_t *pcm,size_t samples)
{
    cue_feed_t *feed=context;
    int64_t start=esp_timer_get_time();
    if (feed->last_end && (uint64_t)(start-feed->last_end)>feed->gap_us)
        feed->gap_us=(uint32_t)(start-feed->last_end);
    bool ok=bsp_audio_write(pcm,samples*sizeof(*pcm))==ESP_OK;
    feed->last_end=esp_timer_get_time(); return ok;
}
static bool cue_mute(void *unused,bool muted)
{
    (void)unused; return bsp_audio_output_mute(muted)==ESP_OK;
}
static bool silence(unsigned blocks)
{
    int16_t zeros[CP_CUE_BLOCK]={0};
    while (blocks--) if (bsp_audio_write(zeros,sizeof(zeros))!=ESP_OK) return false;
    return true;
}
static bool prepare_audio(void)
{
    return bsp_audio_wake()==ESP_OK && bsp_audio_set_format(16000,16,1)==ESP_OK &&
           bsp_audio_output_mute(true)==ESP_OK && bsp_audio_input_enable(false)==ESP_OK;
}
static void sleep_audio(void)
{
    (void)bsp_audio_output_mute(true);
    (void)bsp_audio_sleep();
}
static bool tone(cp_cue_t cue,const audio_job_t *job)
{
    cue_feed_t feed={0};
    cp_cue_output_t out={.context=&feed,.write=cue_write,.mute=cue_mute};
    bsp_audio_set_volume(CP_CUE_VOLUME);
    bool ok=cp_cue_play(cue,&out);
    if (cp_token_valid(job->epoch) && cp_token_valid(job->id)) {
        static const char *names[]={"ready","complete","attention"};
        char frame[240];
        snprintf(frame,sizeof(frame),"{\"v\":1,\"type\":\"cue\",\"epoch\":\"%s\",\"id\":\"%.16s\",\"kind\":\"%s\",\"ok\":%s,\"volume\":%d,\"feedGapUs\":%u}",
                 job->epoch,job->id,names[cue],ok ? "true" : "false",CP_CUE_VOLUME,(unsigned)feed.gap_us);
        (void)cp_ble_send(frame);
    }
    return ok;
}
static void enqueue_cue(bool complete)
{
    audio_job_t cue={.phrase=complete ? -2 : -3};
    memcpy(cue.id,s_voice.id,17); memcpy(cue.epoch,s_model.epoch,17);
    (void)xQueueSend(s_audio,&cue,0);
}
static void voice_event(const char *id, cp_voice_phase_t phase, int level)
{
    voice_event_t event={.phase=phase,.level=level}; memcpy(event.id,id,17);
    (void)xQueueSend(s_voice_events,&event,pdMS_TO_TICKS(20));
}
static void voice_frame(const audio_job_t *job, const char *op, unsigned frames)
{
    char frame[256];
    snprintf(frame,sizeof(frame),"{\"v\":1,\"type\":\"voice\",\"epoch\":\"%s\",\"id\":\"%.16s\",\"op\":\"%s\",\"frames\":%u,\"samples\":%u,\"codec\":\"ima16\"}",
             job->epoch,job->id,op,frames,frames*CP_VOICE_SAMPLES);
    (void)cp_ble_send(frame);
}
static bool capture(const audio_job_t *job)
{
    uint64_t deadline=now_ms()+10000;
    bool failed=!prepare_audio();
    unsigned frames=0;
    if (!failed) voice_frame(job,"begin",0);
    while (!failed && !atomic_load(&s_record_go) && !atomic_load(&s_record_stop) &&
           atomic_load(&s_ok_down) && cp_ble_voice_ready() && now_ms()<deadline) vTaskDelay(pdMS_TO_TICKS(10));
    bool cancelled=atomic_load(&s_record_stop) || !atomic_load(&s_ok_down);
    if (!cancelled && (!atomic_load(&s_record_go) || !cp_ble_voice_ready())) failed=true;
    if (!failed && !cancelled) {
        failed=!tone(CP_CUE_READY,job) || bsp_audio_reset_input()!=ESP_OK;
        cancelled=atomic_load(&s_record_stop) || !atomic_load(&s_ok_down);
    }
    int16_t pcm[CP_VOICE_SAMPLES]; uint8_t packet[CP_VOICE_PACKET];
    if (!failed && !cancelled) {
        voice_event(job->id,CP_VOICE_RECORDING,0); voice_frame(job,"recording",0);
        while (frames<CP_VOICE_MAX_FRAMES && !atomic_load(&s_record_stop) && atomic_load(&s_ok_down)) {
            if (!cp_ble_voice_ready() || bsp_audio_read(pcm,sizeof(pcm))!=ESP_OK) { failed=true; break; }
            // Release is checked again after the blocking read; no tail is transmitted.
            if (atomic_load(&s_record_stop) || !atomic_load(&s_ok_down)) break;
            size_t size=cp_voice_encode(job->id,(uint16_t)frames,pcm,CP_VOICE_SAMPLES,packet,sizeof(packet));
            if (!size || !cp_ble_send_voice(packet,size)) { failed=true; break; }
            ++frames;
            if (frames%5==0) {
                int peak=0;
                for (int i=0;i<CP_VOICE_SAMPLES;++i) { int n=pcm[i]<0 ? -(int)pcm[i] : pcm[i]; if (n>peak) peak=n; }
                voice_event(job->id,CP_VOICE_RECORDING,peak>10000 ? 100 : peak/100);
            }
        }
    }
    // End capture immediately at release. Keep only the muted TX clock ready
    // for the recognition result; no microphone DMA runs during that wait.
    if (bsp_audio_input_enable(false)!=ESP_OK) failed=true;
    (void)bsp_audio_output_mute(true);
    if (failed) { voice_frame(job,"failed",frames); voice_event(job->id,CP_VOICE_ERROR,0); }
    else if (cancelled || !frames) { voice_frame(job,"cancel",frames); voice_event(job->id,CP_VOICE_IDLE,0); }
    else { voice_frame(job,"end",frames); voice_event(job->id,CP_VOICE_PROCESSING,0); }
    return !failed;
}
static void audio_task(void *unused)
{
    (void)unused;
    static const uint8_t *const starts[] = {pcm_result_start, pcm_question_start, pcm_approval_start,
        pcm_blocked_start, pcm_test_start, pcm_usage_low_start, pcm_usage_reset_start};
    static const uint8_t *const ends[] = {pcm_result_end, pcm_question_end, pcm_approval_end,
        pcm_blocked_end, pcm_test_end, pcm_usage_low_end, pcm_usage_reset_end};
    audio_job_t job;
    int16_t chunk[512];
    bool prepared=false;
    for (;;) {
        if (xQueueReceive(s_audio,&job,pdMS_TO_TICKS(1000))!=pdTRUE) {
            bool connected=atomic_load(&s_audio_session);
            if (!connected && prepared) { sleep_audio(); prepared=false; }
            else if (connected && !prepared) prepared=prepare_audio();
            continue;
        }
        if (job.phrase==-4) { prepared=prepare_audio(); continue; }
        if (job.phrase==-5) {
            if (!atomic_load(&s_audio_session)) { sleep_audio(); prepared=false; }
            continue;
        }
        if (job.phrase==-1) {
            prepared=capture(&job);
            if (!atomic_load(&s_audio_session)) { sleep_audio(); prepared=false; }
            atomic_store(&s_audio_busy,false); continue;
        }
        if (job.phrase==-2 || job.phrase==-3) {
            if (prepare_audio()) {
                prepared=true;
                (void)tone(job.phrase==-2 ? CP_CUE_COMPLETE : CP_CUE_ATTENTION,&job);
            }
            if (!atomic_load(&s_audio_session)) { sleep_audio(); prepared=false; }
            atomic_store(&s_audio_busy,false); continue;
        }
        bool stopped = job.generation != atomic_load(&s_cancel) || !cp_ble_ready();
        bool failed = false, announced = false;
        if (!stopped) { prepared=prepare_audio(); failed=!prepared; }
        if (!stopped && !failed) {
            bsp_audio_set_volume(60);
            if (!silence(8) || bsp_audio_output_mute(false)!=ESP_OK || !silence(2)) failed=true;
            const uint8_t *data = starts[job.phrase];
            size_t length = (size_t)(ends[job.phrase] - data);
            for (size_t offset = 0; !failed && offset < length;) {
                if (job.generation != atomic_load(&s_cancel) || !cp_ble_ready()) { stopped = true; break; }
                size_t size = length - offset;
                if (size > sizeof(chunk)) size = sizeof(chunk);
                memcpy(chunk, data + offset, size);
                if (bsp_audio_write(chunk, size) != ESP_OK) { failed = true; break; }
                if (!announced) { send_audio(job.epoch, job.id, "started"); announced = true; }
                offset += size;
            }
        }
        if (stopped || failed) (void)bsp_audio_output_mute(true);
        if (prepared) (void)silence(8);
        (void)bsp_audio_output_mute(true);
        if (!atomic_load(&s_audio_session)) { sleep_audio(); prepared=false; }
        send_audio(job.epoch, job.id, failed ? "failed" : stopped ? "stopped" : "done");
        atomic_store(&s_audio_busy, false);
    }
}
static void hello(void)
{
    char frame[384],sha[65];cp_pet_current_hash(sha);
    snprintf(frame, sizeof(frame), "{\"v\":1,\"type\":\"hello\",\"audio\":%s,\"voice\":true,\"volume\":60,\"firmware\":\"0.4.0-presenter\",\"presenter\":true,\"presenterSession\":\"%s\",\"petNameSupported\":true,\"petSync\":%s,\"petFormat\":1,\"petSha\":\"%s\"}", s_audio_ok ? "true" : "false",s_presenter_session,cp_pet_supported()?"true":"false",sha);
    (void)cp_ble_send(frame);
}
static bool request_id(const char *id)
{
    if (!id || strlen(id) != 32) return false;
    for (int i = 0; i < 32; ++i) if (!((id[i] >= '0' && id[i] <= '9') || (id[i] >= 'a' && id[i] <= 'f'))) return false;
    return true;
}
static void state_frame(cJSON *json)
{
    static cp_model_t incoming;
    cp_model_init(&incoming);
    const char *epoch = str(json, "epoch");
    if (!cp_token_valid(epoch)) return;
    memcpy(incoming.epoch, epoch, 17);
    const char *pet_name=str(json,"petName");
    if (pet_name && (!pet_name[0] || !cp_text_valid(pet_name,CP_PET_NAME_MAX))) return;
    snprintf(incoming.pet_name,sizeof(incoming.pet_name),"%s",pet_name ? pet_name : s_pet_name);
    incoming.enabled = boolean(json, "enabled"); incoming.muted = boolean(json, "muted");
    incoming.quiet = boolean(json, "quiet"); incoming.monitor = boolean(json, "monitor");
    incoming.presenter_supported = boolean(json,"presenterSupported");
    incoming.presenting = boolean(json,"presenter"); incoming.presenter_ready = boolean(json,"presenterReady");
    incoming.presenter_status = number(json,"presenterStatus",3); incoming.presenter_target = number(json,"presenterTarget",0);
    const char *lease = str(json,"presenterLease");
    if (incoming.presenter_supported && !cp_token_valid(lease)) return;
    if (lease) snprintf(incoming.presenter_lease,sizeof(incoming.presenter_lease),"%s",lease);
    incoming.total = number(json, "total", -1); incoming.running = number(json, "running", -1);
    incoming.usage = number(json, "usage", -2);
    incoming.usage_age = number(json,"usageAge",0);
    cJSON *quotas=cJSON_GetObjectItemCaseSensitive(json,"quotas");
    if (cJSON_IsArray(quotas) && cJSON_GetArraySize(quotas)<=2) {
        incoming.quota_count=cJSON_GetArraySize(quotas);
        for (int i=0;i<incoming.quota_count;++i) {
            cJSON *q=cJSON_GetArrayItem(quotas,i);
            incoming.quotas[i]=(cp_quota_t){.remaining=number(q,"remaining",-1),
                .minutes=number(q,"minutes",0),.reset_seconds=number(q,"reset",-1)};
        }
    }
    cJSON *alerts = cJSON_GetObjectItemCaseSensitive(json, "alerts");
    if (!cJSON_IsArray(alerts) || cJSON_GetArraySize(alerts) > CP_ALERTS) return;
    incoming.count = cJSON_GetArraySize(alerts);
    for (int i = 0; i < incoming.count; ++i) {
        cJSON *a = cJSON_GetArrayItem(alerts, i);
        const char *id = str(a, "id"), *title = str(a, "title");
        int kind = cp_phrase(str(a, "kind"));
        if (!cp_token_valid(id) || !cp_text_valid(title, CP_TITLE_MAX) || kind < 0 || kind > CP_TEST) return;
        memcpy(incoming.alerts[i].id, id, 17);
        snprintf(incoming.alerts[i].title, CP_TITLE_MAX, "%s", title);
        incoming.alerts[i].kind = (cp_phrase_t)kind;
        incoming.alerts[i].snoozed = boolean(a, "snoozed"); incoming.alerts[i].verify = boolean(a, "verify");
    }
    bool was_presenting=s_model.presenting;
    bool first_quota=!s_model.quota_count && incoming.quota_count;
    bool new_item = !s_model.online || incoming.count != s_model.count ||
                    strcmp(s_model.epoch, incoming.epoch);
    for (int i = 0; !new_item && i < incoming.count; ++i)
        if (strcmp(incoming.alerts[i].id, s_model.alerts[i].id)) new_item = true;
    if (cp_model_apply(&s_model, &incoming, now_ms())) {
        if (strcmp(s_pet_name,s_model.pet_name)) {
            snprintf(s_pet_name,sizeof(s_pet_name),"%s",s_model.pet_name); s_pet_name_dirty=true;
        }
        if (!atomic_exchange(&s_audio_session,true)) {
            audio_job_t warm={.phrase=-4}; (void)xQueueSend(s_audio,&warm,0);
        }
        if (was_presenting!=s_model.presenting) {
            s_interaction=now_ms(); s_asleep=false; s_menu=0;
            toast(s_model.presenting ? "演示模式已开启" : "已退出演示模式");
        }
        if (new_item) {
            s_interaction = now_ms();
            if (incoming.count) s_asleep=false;
        }
        if (new_item || first_quota) {
            s_quota=0;
            for (int i=1;i<s_model.quota_count;++i)
                if (s_model.quotas[i].remaining<s_model.quotas[s_quota].remaining) s_quota=i;
        }
        if (!s_model.enabled || s_model.muted || s_model.presenting) atomic_fetch_add(&s_cancel, 1);
        (void)cp_ble_send("{\"v\":1,\"type\":\"pong\"}");
    }
}
static void handle_frame(const char *frame)
{
    cJSON *json = cJSON_ParseWithLength(frame, strlen(frame) + 1);
    if (!json || number(json, "v", 0) != 1) { cJSON_Delete(json); return; }
    const char *type = str(json, "type"), *epoch = str(json, "epoch"), *id = str(json, "id");
    if (!type) { cJSON_Delete(json); return; }
    if (!strcmp(type, "hello")) {
        hello();
    } else if (!strcmp(type, "state")) {
        state_frame(json);
    } else if (!strcmp(type,"pet_begin") && epoch && !strcmp(epoch,s_model.epoch)) {
        if (number(json,"format",0)==1 && number(json,"size",0)==CP_PET_BYTES)
            (void)cp_pet_begin(id,str(json,"sha"));
    } else if (!strcmp(type,"pet_commit") && epoch && !strcmp(epoch,s_model.epoch)) {
        (void)cp_pet_commit(id);
    } else if (!strcmp(type, "stop")) {
        if (epoch && !strcmp(epoch, s_model.epoch) && request_id(id) &&
            !strcmp(id, s_active_play)) atomic_fetch_add(&s_cancel, 1);
    } else if (!strcmp(type, "play") && request_id(id)) {
        int phrase = cp_phrase(str(json, "phrase"));
        bool duplicate = false;
        for (size_t i = 0; i < 12; ++i) if (!strcmp(s_last_plays[i], id)) duplicate = true;
        if (duplicate || phrase < 0 || !s_audio_ok || atomic_load(&s_audio_busy) || s_voice.phase!=CP_VOICE_IDLE ||
            !cp_can_play(&s_model, epoch, now_ms())) {
            if (cp_token_valid(epoch)) send_audio(epoch, id, "failed");
        } else {
            audio_job_t job = {.phrase = phrase, .generation = atomic_load(&s_cancel)};
            memcpy(job.id, id, 33); memcpy(job.epoch, epoch, 17);
            memcpy(s_active_play, id, 33);
            atomic_store(&s_audio_busy, true);
            if (xQueueSend(s_audio, &job, 0) != pdTRUE) {
                atomic_store(&s_audio_busy, false); send_audio(epoch, id, "failed");
            } else {
                memcpy(s_last_plays[s_play_cursor++ % 12], id, 33);
                s_interaction = now_ms();
            }
        }
    } else if ((!strcmp(type,"voice_ready") || !strcmp(type,"voice_result")) && epoch &&
               !strcmp(epoch,s_model.epoch) && id && !strcmp(id,s_voice.id)) {
        if (!strcmp(type,"voice_ready") && s_voice.phase==CP_VOICE_PREPARING) {
            if (boolean(json,"ok")) {
                const char *target=str(json,"target");
                if (cp_text_valid(target,sizeof(s_voice.target))) snprintf(s_voice.target,sizeof(s_voice.target),"%s",target);
                atomic_store(&s_record_go,true);
            }
            else {
                atomic_store(&s_record_stop,true); s_voice.phase=CP_VOICE_ERROR;
                const char *message=str(json,"message");
                if (cp_text_valid(message,sizeof(s_voice.message))) snprintf(s_voice.message,sizeof(s_voice.message),"%s",message);
                s_voice.since_ms=now_ms();
                enqueue_cue(false);
            }
        } else if (!strcmp(type,"voice_result") && (s_voice.phase==CP_VOICE_PROCESSING || s_voice.phase==CP_VOICE_RECORDING)) {
            bool ok=boolean(json,"ok");
            s_voice.phase=ok ? CP_VOICE_DONE : boolean(json,"retained") ? CP_VOICE_RETAINED : CP_VOICE_ERROR;
            s_voice.since_ms=now_ms();
            const char *message=str(json,"message");
            if (cp_text_valid(message,sizeof(s_voice.message))) snprintf(s_voice.message,sizeof(s_voice.message),"%s",message);
            enqueue_cue(ok);
        }
    } else if (!strcmp(type, "action_result") && epoch && !strcmp(epoch, s_model.epoch) &&
               id && !strcmp(id, s_action_id)) {
        s_action_until = 0;
        const char *message = str(json, "message");
        if (cp_text_valid(message, sizeof(s_toast))) toast(message);
    }
    cJSON_Delete(json);
}
static void action(const char *name, const char *alert_id)
{
    if (!s_model.online || !cp_ble_ready()) { toast("请先连接电脑"); return; }
    if (s_action_until > now_ms()) { toast("正在同步，请稍候"); return; }
    if (strcmp(name, "pause") && !s_model.count) { toast("暂无待处理提醒"); return; }
    snprintf(s_action_id, sizeof(s_action_id), "%08x%08x%08x%08x",
             (unsigned)esp_random(), (unsigned)esp_random(), (unsigned)esp_random(), (unsigned)esp_random());
    char frame[256];
    snprintf(frame, sizeof(frame), "{\"v\":1,\"type\":\"action\",\"epoch\":\"%s\",\"id\":\"%s\",\"action\":\"%s\",\"alertId\":\"%s\"}",
        s_model.epoch, s_action_id, name, alert_id && alert_id[0] ? alert_id : s_model.count ? s_model.alerts[s_model.selected].id : "");
    atomic_fetch_add(&s_cancel, 1);
    if (cp_ble_send(frame)) {
        s_action_until = now_ms() + 7000; toast("正在同步到电脑");
    } else toast("发送失败，请重试");
}
static void presenter_action(const char *op)
{
    uint64_t now=now_ms();
    if (!s_model.online || !cp_ble_ready()) { toast("请先连接电脑"); return; }
    if (!s_model.presenter_supported) { toast("请更新电脑端软件"); return; }
    if (now<s_model.updated_ms || now-s_model.updated_ms>2500 || s_presenter_sequence>=INT32_MAX) {
        toast("等待电脑就绪，请重试"); return;
    }
    char frame[256];
    snprintf(frame,sizeof(frame),"{\"v\":1,\"type\":\"presenter\",\"epoch\":\"%s\",\"session\":\"%s\",\"lease\":\"%s\",\"seq\":%lu,\"op\":\"%s\"}",
             s_model.epoch,s_presenter_session,s_model.presenter_lease,(unsigned long)++s_presenter_sequence,op);
    if (!cp_ble_send(frame)) toast("发送失败，请重试");
}
static void presenter_page(bsp_btn_t button)
{
    if (s_model.presenter_ready) presenter_action(button==BSP_BTN_UP ? "previous" : "next");
    else toast(s_model.presenter_status==2 ? "请在电脑开启输入权限" : "请返回演示软件放映");
}
static void on_key(bsp_btn_t button, bsp_btn_ev_t event, void *unused)
{
    (void)unused;
    if (button==BSP_BTN_DOWN && event==BSP_BTN_PRESS) atomic_store(&s_down_down,true);
    if (button==BSP_BTN_DOWN && event==BSP_BTN_RELEASE) atomic_store(&s_down_down,false);
    if (button==BSP_BTN_OK && event==BSP_BTN_PRESS) atomic_store(&s_ok_down,true);
    if (button==BSP_BTN_OK && event==BSP_BTN_RELEASE) atomic_store(&s_ok_down,false);
    cp_key_t key = {.button = button, .event = event};
    if (s_keys) (void)xQueueSend(s_keys, &key, 0);
}
static void begin_voice(void)
{
    if (s_model.presenting) { toast("请先退出演示模式"); return; }
    if (!s_model.online || !cp_ble_voice_ready() || !s_audio_ok) { toast("请先连接电脑"); return; }
    if (s_voice.phase==CP_VOICE_PREPARING || s_voice.phase==CP_VOICE_RECORDING || s_voice.phase==CP_VOICE_PROCESSING) return;
    memset(&s_voice,0,sizeof(s_voice));
    snprintf(s_voice.id,sizeof(s_voice.id),"%08x%08x",(unsigned)esp_random(),(unsigned)esp_random());
    s_voice.phase=CP_VOICE_PREPARING; s_voice.since_ms=now_ms(); s_menu=0;
    cp_pet_set_busy(true);
    atomic_fetch_add(&s_cancel,1); atomic_store(&s_record_stop,false); atomic_store(&s_record_go,false);
    audio_job_t job={.phrase=-1}; memcpy(job.id,s_voice.id,17); memcpy(job.epoch,s_model.epoch,17);
    if (xQueueSend(s_audio,&job,0)!=pdTRUE) { s_voice.phase=CP_VOICE_ERROR; toast("音频忙，请重试"); }
}
static void handle_key(cp_key_t key)
{
    uint64_t now=now_ms();
    cp_gesture_t *g=&s_gestures[key.button];
    if (key.event==BSP_BTN_PRESS) {
        if (key.button==BSP_BTN_DOWN) cp_presenter_press(&s_presenter_hold,now);
        bool page_key=cp_presenter_page_key(s_model.presenting,s_menu,s_voice.phase==CP_VOICE_IDLE,key.button);
        s_page_press[key.button]=page_key;
        cp_gesture_press(g,s_asleep && !page_key,s_model.count ? s_model.alerts[s_model.selected].id : NULL);
        s_interaction=now; s_asleep=false; return;
    }
    if (key.event==BSP_BTN_LONG) {
        g->held=true;
        if (key.button==BSP_BTN_OK) begin_voice();
        else if (key.button==BSP_BTN_UP && s_voice.phase==CP_VOICE_IDLE) {
            s_menu=s_menu ? 0 : 1; s_menu_selection=0;
        }
        return;
    }
    if (key.event==BSP_BTN_RELEASE) {
        if (key.button==BSP_BTN_OK && g->held) atomic_store(&s_record_stop,true);
        /* SINGLE_CLICK waits for the double-click window and is absent for a
         * double click. Release emits one page for each physical short press. */
        if (s_page_press[key.button] && !g->held &&
            cp_presenter_page_key(s_model.presenting,s_menu,s_voice.phase==CP_VOICE_IDLE,key.button)) presenter_page(key.button);
        return;
    }
    if (s_page_press[key.button] && (key.event==BSP_BTN_CLICK || key.event==BSP_BTN_DOUBLE)) return;
    if (key.event!=BSP_BTN_CLICK || !cp_gesture_click(g)) return;
    if (s_voice.phase!=CP_VOICE_IDLE) {
        if (s_voice.phase>=CP_VOICE_DONE) s_voice.phase=CP_VOICE_IDLE;
        return;
    }
    if (cp_presenter_page_key(s_model.presenting,s_menu,true,key.button)) {
        /* A mode changed after PRESS; never turn that release into a page. */
        return;
    }
    if (s_model.presenting && key.button==BSP_BTN_OK && !s_menu) { toast("演示中，提醒稍后处理"); return; }
    if (s_menu==2) {
        if (key.button==BSP_BTN_OK) {
            atomic_fetch_add(&s_cancel,1); cp_ble_unpair(); offline_model(); toast("已取消配对");
        }
        s_menu=0; return;
    }
    if (s_menu==1) {
        if (key.button==BSP_BTN_UP) s_menu_selection=(s_menu_selection+4)%5;
        else if (key.button==BSP_BTN_DOWN) s_menu_selection=(s_menu_selection+1)%5;
        else {
            int choice=s_menu_selection; s_menu=choice==4 ? 2 : 0;
            if (s_model.presenting && choice>0 && choice<4) { toast("请先退出演示模式"); return; }
            if (choice==1) action("snooze",NULL);
            if (choice==2) action("replay",NULL);
            if (choice==3) action("pause",NULL);
        }
    } else if (key.button==BSP_BTN_OK) {
        if (g->alert[0]) action("ack",g->alert);
    } else if (s_model.count) cp_model_select(&s_model,key.button==BSP_BTN_UP ? -1 : 1);
    else if (s_model.quota_count>1) s_quota=(s_quota+1)%s_model.quota_count;
}
void app_main(void)
{
    cp_model_init(&s_model);
    snprintf(s_presenter_session,sizeof(s_presenter_session),"%08x%08x",(unsigned)esp_random(),(unsigned)esp_random());
    s_frames = xQueueCreate(2, CP_FRAME_MAX); s_keys = xQueueCreate(12, sizeof(cp_key_t));
    s_audio = xQueueCreate(2, sizeof(audio_job_t));
    s_voice_events=xQueueCreate(8,sizeof(voice_event_t));
    if (!s_frames || !s_keys || !s_audio || !s_voice_events) { ESP_LOGE(TAG, "queue allocation failed"); return; }
    ESP_ERROR_CHECK(nvs_flash_init());
    load_pet_name(); offline_model();
    ESP_ERROR_CHECK(bsp_display_init());
    if (!bsp_lvgl_init()) { ESP_LOGE(TAG, "display initialization failed"); return; }
    (void)cp_pet_init();
    cp_ui_init();
    cp_ui_render(&s_model,0,-1,false,0,0,"",true,0,&s_voice,now_ms());
    bsp_display_backlight(70);
    s_interaction = now_ms();
    s_audio_ok = bsp_audio_init() == ESP_OK;
    if (s_audio_ok) {
        (void)bsp_audio_output_mute(true);
        (void)bsp_audio_sleep();
        s_audio_ok = xTaskCreate(audio_task, "codex_audio", 5120, NULL, 6, NULL) == pdPASS;
    }
    esp_err_t keys = bsp_button_init(on_key, NULL);
    esp_err_t battery = bsp_battery_init_existing();
    esp_err_t ble = cp_ble_init(s_frames);
    ESP_LOGI(TAG, "Codex Pocket 0.4.0; audio=%s keys=%s battery=%s BLE=%s; heap=%u",
        s_audio_ok ? "ready" : "unavailable", esp_err_to_name(keys), esp_err_to_name(battery),
        esp_err_to_name(ble), (unsigned)esp_get_free_heap_size());
    static char frame[CP_FRAME_MAX];
    uint64_t last_battery = 0, last_hello = 0;
    bool was_ready = false;
    for (;;) {
        bool ready = cp_ble_ready();
        uint64_t now = now_ms();
        if ((!ready && was_ready) || cp_model_expire(&s_model, now)) {
            offline_model(); atomic_fetch_add(&s_cancel,1); s_action_until=0;
            atomic_store(&s_audio_session,false);
            audio_job_t cool={.phrase=-5}; (void)xQueueSend(s_audio,&cool,0);
            atomic_store(&s_record_stop,true);
            if (s_voice.phase!=CP_VOICE_IDLE) { s_voice.phase=CP_VOICE_ERROR; s_voice.since_ms=now; snprintf(s_voice.message,sizeof(s_voice.message),"连接已断开，请重试"); }
        }
        was_ready = ready;
        if (ready && !s_model.online && now - last_hello > 2000) { hello(); last_hello = now; }
        voice_event_t event;
        while (xQueueReceive(s_voice_events,&event,0)==pdTRUE) {
            if (strcmp(event.id,s_voice.id) || s_voice.phase>=CP_VOICE_DONE) continue;
            if (s_voice.phase!=event.phase) { s_voice.phase=event.phase; s_voice.since_ms=now; s_voice.message[0]=0; }
            s_voice.level=event.level;
            if (event.phase==CP_VOICE_ERROR) { enqueue_cue(false); }
        }
        for (int n = 0; n < 2 && xQueueReceive(s_frames, frame, 0) == pdTRUE; ++n) {
            if (ready) handle_frame(frame);
        }
        if (s_voice.phase==CP_VOICE_PROCESSING && now-s_voice.since_ms>45000) {
            audio_job_t timeout={.phrase=-3};
            memcpy(timeout.id,s_voice.id,17); memcpy(timeout.epoch,s_model.epoch,17);
            voice_frame(&timeout,"cancel",0); (void)xQueueSend(s_audio,&timeout,0);
            s_voice.phase=CP_VOICE_ERROR; s_voice.since_ms=now; snprintf(s_voice.message,sizeof(s_voice.message),"识别超时，请检查电脑");
        }
        if (s_voice.phase>=CP_VOICE_DONE && now-s_voice.since_ms>3500) s_voice.phase=CP_VOICE_IDLE;
        cp_key_t key;
        while (xQueueReceive(s_keys, &key, 0) == pdTRUE) handle_key(key);
        if (cp_presenter_hold(&s_presenter_hold,atomic_load(&s_down_down),s_voice.phase==CP_VOICE_IDLE,now)) {
            s_menu=0;
            presenter_action(s_model.presenting ? "disable" : "enable");
        }
        if (s_action_until && now > s_action_until) { s_action_until = 0; toast("同步超时，请重试"); }
        if (now - last_battery > 10000) { s_battery = bsp_battery_soc(); last_battery = now; }
        if (s_voice.phase!=CP_VOICE_IDLE) s_interaction=now;
        if (now-s_interaction>30000 && !s_menu) s_asleep=true;
        save_pet_name();
        bool urgent=false;
        for (int i=0;i<s_model.count;++i) if (s_model.alerts[i].kind==CP_APPROVAL || s_model.alerts[i].kind==CP_QUESTION || s_model.alerts[i].kind==CP_BLOCKED) urgent=true;
        cp_pet_set_busy(s_voice.phase!=CP_VOICE_IDLE || atomic_load(&s_audio_busy) || urgent);
        bsp_display_backlight(s_asleep ? 18 : 65);
        cp_ui_render(&s_model, cp_ble_passkey(), s_battery, s_audio_ok, s_menu, s_menu_selection,
                     now < s_toast_until ? s_toast : "",s_asleep,s_quota,&s_voice,now);
        vTaskDelay(pdMS_TO_TICKS(50));
    }
}
