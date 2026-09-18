#include <assert.h>
#include <stdio.h>
#include <wlr/types/wlr_compositor.h>
#include "native/ataxia-wlr-glue.h"

int main(void) {
	struct wlr_surface surface = {0};
	pixman_region32_init_rect(&surface.opaque_region, 0, 0, 80, 60);
	pixman_region32_t hole;
	pixman_region32_init_rect(&hole, 20, 15, 40, 30);
	pixman_region32_subtract(&surface.opaque_region, &surface.opaque_region, &hole);
	int32_t rectangles[4 * 8] = {0};
	uint32_t count = ataxia_surface_opaque_rectangles(&surface, rectangles, 8);
	assert(count == 4);
	for (uint32_t i = 0; i < count; i++) {
		int32_t *r = &rectangles[4 * i];
		assert(r[2] > 0 && r[3] > 0);
		assert(r[0] + r[2] <= 20 || r[0] >= 60 || r[1] + r[3] <= 15 || r[1] >= 45);
	}
	int32_t limited[8] = {0, 0, 0, 0, 12345, 12345, 12345, 12345};
	assert(ataxia_surface_opaque_rectangles(&surface, limited, 1) == count);
	assert(limited[4] == 12345 && limited[7] == 12345);
	assert(ataxia_surface_opaque_rectangles(&surface, NULL, 0) == count);
	assert(ataxia_surface_opaque_rectangles(NULL, rectangles, 8) == 0);
	wl_list_init(&surface.current.frame_callback_list);
	assert(!ataxia_surface_has_frame_callbacks(&surface));
	struct wl_list callback;
	wl_list_insert(&surface.current.frame_callback_list, &callback);
	assert(ataxia_surface_has_frame_callbacks(&surface));
	wl_list_remove(&callback);
	assert(!ataxia_surface_has_frame_callbacks(&surface));
	assert(!ataxia_surface_has_frame_callbacks(NULL));
	pixman_region32_fini(&hole);
	pixman_region32_fini(&surface.opaque_region);
	puts("PASS: native opacity preserves holes and capacity; committed frame callback detection.");
}
