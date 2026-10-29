#include "lvgl.h"
#include "companion_ui.h"
#include "companion_pet_store.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static uint16_t screen[240*320], draw[240*40];
static uint8_t *preview_pet;
const uint8_t *cp_pet_current(void) {return preview_pet;}
bool bsp_lvgl_lock(int timeout) { (void)timeout; return true; }
void bsp_lvgl_unlock(void) {}
static void flush(lv_display_t *display,const lv_area_t *area,uint8_t *pixels)
{
    int w=area->x2-area->x1+1;
    for (int y=area->y1;y<=area->y2;++y)
        memcpy(screen+y*240+area->x1,pixels+(y-area->y1)*w*2,(size_t)w*2);
    lv_display_flush_ready(display);
}
static void save(const char *folder,const char *name)
{
    lv_obj_invalidate(lv_screen_active()); lv_tick_inc(50); lv_refr_now(NULL);
    char path[1024]; snprintf(path,sizeof(path),"%s/%s.ppm",folder,name);
    FILE *file=fopen(path,"wb"); assert(file); fprintf(file,"P6\n240 320\n255\n");
    for (int y=0;y<320;++y) for (int x=0;x<240;++x) {
        int cx=x<30 ? 30 : x>=210 ? 209 : x;
        int cy=y<30 ? 30 : y>=290 ? 289 : y;
        uint16_t p=(x-cx)*(x-cx)+(y-cy)*(y-cy)>900 ? 0 : screen[y*240+x];
        uint8_t rgb[3]={(uint8_t)(((p>>11)&31)*255/31),(uint8_t)(((p>>5)&63)*255/63),(uint8_t)((p&31)*255/31)};
        fwrite(rgb,1,3,file);
    }
    fclose(file);
}
int main(int argc,char **argv)
{
    assert(argc==2 || argc==3);
    if (argc==3) {
        FILE *input=fopen(argv[2],"rb");assert(input);preview_pet=malloc(CP_PET_BYTES);assert(preview_pet);
        assert(fread(preview_pet,1,CP_PET_BYTES,input)==CP_PET_BYTES);assert(fgetc(input)==EOF);fclose(input);
    }
    lv_init();
    lv_display_t *display=lv_display_create(240,320);
    lv_display_set_color_format(display,LV_COLOR_FORMAT_RGB565);
    lv_display_set_buffers(display,draw,NULL,sizeof(draw),LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(display,flush); cp_ui_init();
    cp_model_t m; cp_model_init(&m); m.online=true; m.monitor=true; m.enabled=true;
    m.updated_ms=10000; m.usage=92; m.quota_count=2; m.usage_age=30;
    m.quotas[0]=(cp_quota_t){92,300,12600}; m.quotas[1]=(cp_quota_t){98,10080,183600};
    cp_voice_view_t voice={0};
    cp_ui_render(&m,0,82,true,0,0,"",true,0,&voice,10000); save(argv[1],"01-pet");
    cp_ui_render(&m,0,82,true,0,0,"",false,0,&voice,10000); save(argv[1],"02-quota");
    m.count=1; m.total=3; m.alerts[0].kind=CP_QUESTION;
    snprintf(m.alerts[0].title,sizeof(m.alerts[0].title),"工牌配件开发：需要你确认输入方式");
    cp_ui_render(&m,0,82,true,0,0,"",false,0,&voice,10000); save(argv[1],"03-reminder");
    voice.phase=CP_VOICE_RECORDING; voice.since_ms=3000; voice.level=60; snprintf(voice.target,sizeof(voice.target),"Codex");
    cp_ui_render(&m,0,82,true,0,0,"",false,0,&voice,10000); save(argv[1],"04-dictation");
    voice.phase=CP_VOICE_DONE; snprintf(voice.message,sizeof(voice.message),"已输入到电脑，尚未发送");
    cp_ui_render(&m,0,82,true,0,0,"",false,0,&voice,10000); save(argv[1],"05-done");
    voice.phase=CP_VOICE_IDLE; cp_model_init(&m);
    cp_ui_render(&m,0,82,true,0,0,"",false,0,&voice,10000); save(argv[1],"06-offline");
    m.online=true; m.enabled=true; m.presenting=true; m.presenter_supported=true; m.presenter_ready=true;
    m.presenter_target=1; m.total=3;
    cp_ui_render(&m,0,82,true,0,0,"",true,0,&voice,10000); save(argv[1],"07-presenter");
    m.presenter_ready=false; m.presenter_status=1;
    cp_ui_render(&m,0,82,true,0,0,"",false,0,&voice,10000); save(argv[1],"08-presenter-paused");
    m.presenter_status=2;
    cp_ui_render(&m,0,82,true,0,0,"",false,0,&voice,10000); save(argv[1],"09-presenter-permission");
    m.presenting=false; m.count=1; m.total=1; m.alerts[0].kind=CP_APPROVAL;
    snprintf(m.alerts[0].title,sizeof(m.alerts[0].title),"退出演示后：提醒页面恢复");
    cp_ui_render(&m,0,82,true,0,0,"",false,0,&voice,10000); save(argv[1],"10-reminder-restored");
    /* Exercise the shared widgets and dark/light transitions repeatedly. */
    for (int i=0;i<100;++i) {
        m.presenting=(i%2)==0; m.presenter_ready=(i%4)==0;
        m.presenter_status=m.presenter_ready ? 0:1;
        cp_ui_render(&m,0,82,true,0,0,"",false,0,&voice,10000+(uint64_t)i*50);
        lv_tick_inc(50); lv_refr_now(NULL);
    }
    lv_mem_monitor_t mem; lv_mem_monitor(&mem);
    assert(mem.free_biggest_size>=2048);
    printf("Actual LVGL render: PASS; pool used %zu / %zu bytes\n",mem.total_size-mem.free_size,mem.total_size);
    return 0;
}
