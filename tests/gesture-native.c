#include <assert.h>
#include <math.h>
#include <wlr/types/wlr_pointer.h>
#include "native/ataxia-wlr-glue.h"
int main(void) {
 struct ataxia_gesture_sample sample;
 struct wlr_pointer pointer = {0};
 assert(ataxia_pointer_gesture_signal(&pointer, 0, 0) == &pointer.events.swipe_begin);
 assert(ataxia_pointer_gesture_signal(&pointer, 1, 1) == &pointer.events.pinch_update);
 assert(ataxia_pointer_gesture_signal(&pointer, 2, 1) == NULL);
 struct wlr_pointer_swipe_begin_event begin = {.time_msec=42, .fingers=3};
 ataxia_pointer_gesture_read(&begin, 0, 0, &sample);
 assert(sample.time_msec==42 && sample.fingers==3 && sample.scale==1 && sample.dx==0);
 struct wlr_pointer_swipe_update_event swipe = {.time_msec=52, .fingers=3, .dx=-2.5, .dy=8};
 ataxia_pointer_gesture_read(&swipe, 0, 1, &sample);
 assert(sample.fingers==3 && sample.dx==-2.5 && sample.dy==8 && sample.cancelled==0);
 struct wlr_pointer_pinch_update_event pinch = {.time_msec=62, .fingers=2, .dx=3, .dy=-7, .scale=1.25, .rotation=-4};
 ataxia_pointer_gesture_read(&pinch, 1, 1, &sample);
 assert(sample.fingers==2 && sample.scale==1.25 && sample.rotation==-4 && sample.dy==-7);
 struct wlr_pointer_pinch_end_event end = {.time_msec=72, .cancelled=true};
 ataxia_pointer_gesture_read(&end, 1, 2, &sample);
 assert(sample.time_msec==72 && sample.cancelled==1 && sample.fingers==0 && sample.dx==0 && sample.scale==1);
 struct wlr_pointer_hold_begin_event hold = {.fingers=3};
 ataxia_pointer_gesture_read(&hold, 2, 0, &sample);
 assert(sample.fingers==3 && sample.cancelled==0);
 return 0;
}
