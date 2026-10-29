#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct { uint64_t pressed_ms; bool tracking, fired; } cp_presenter_hold_t;
void cp_presenter_press(cp_presenter_hold_t *hold, uint64_t now);
/* Poll actual DOWN state; the shared BSP's 500 ms LONG event is not sufficient. */
bool cp_presenter_hold(cp_presenter_hold_t *hold, bool down, bool available, uint64_t now);
/* Presentation clicks bypass screensaver wake consumption, never local menus. */
bool cp_presenter_page_key(bool presenting, int menu, bool voice_idle, int button);
