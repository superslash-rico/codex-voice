#include "companion_presenter.h"
#include "companion_model.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(void)
{
    cp_presenter_hold_t hold={0};
    cp_presenter_press(&hold,1000);
    assert(!cp_presenter_hold(&hold,true,true,1499));
    assert(!cp_presenter_hold(&hold,true,true,2499));
    assert(cp_presenter_hold(&hold,true,true,2500));
    assert(!cp_presenter_hold(&hold,true,true,5000));
    assert(!cp_presenter_hold(&hold,false,true,5100));
    cp_presenter_press(&hold,6000);
    assert(!cp_presenter_hold(&hold,true,false,7000));
    assert(!cp_presenter_hold(&hold,true,true,8000));
    cp_presenter_press(&hold,9000);
    assert(!cp_presenter_hold(&hold,true,true,8000));
    assert(!cp_presenter_page_key(false,0,true,0));
    assert(cp_presenter_page_key(true,0,true,0));
    assert(cp_presenter_page_key(true,0,true,1));
    assert(!cp_presenter_page_key(true,0,true,2));
    assert(!cp_presenter_page_key(true,1,true,0));
    assert(!cp_presenter_page_key(true,0,false,0));
    cp_model_t model,incoming;
    cp_model_init(&model); cp_model_init(&incoming);
    strcpy(incoming.epoch,"0123456789abcdef"); incoming.enabled=true;
    assert(cp_model_apply(&model,&incoming,1000));
    assert(cp_can_play(&model,model.epoch,1000));
    incoming.presenting=true;
    assert(!cp_model_apply(&model,&incoming,1001));
    incoming.presenter_supported=true;
    strcpy(incoming.presenter_lease,"abcdef0123456789");
    assert(cp_model_apply(&model,&incoming,1002));
    assert(!cp_can_play(&model,model.epoch,1002));
    incoming.presenter_target=4;
    assert(!cp_model_apply(&model,&incoming,1003));
    assert(cp_model_expire(&model,11003));
    assert(!model.presenting && !model.presenter_ready);
    puts("Presentation hold, wake routing, local menus and audio exclusion: PASS");
}
