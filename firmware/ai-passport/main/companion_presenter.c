#include "companion_presenter.h"
void cp_presenter_press(cp_presenter_hold_t *hold, uint64_t now)
{
    *hold=(cp_presenter_hold_t){.pressed_ms=now,.tracking=true};
}
bool cp_presenter_hold(cp_presenter_hold_t *hold, bool down, bool available, uint64_t now)
{
    if (!down || !available || now<hold->pressed_ms) { hold->tracking=false; return false; }
    if (!hold->tracking || hold->fired || now-hold->pressed_ms<1500) return false;
    hold->fired=true;
    return true;
}
bool cp_presenter_page_key(bool presenting, int menu, bool voice_idle, int button)
{
    return presenting && !menu && voice_idle && (button==0 || button==1);
}
