/* ABI accessors only; X11 window placement and focus remain World policy. */
#include <wlr/xwayland.h>
#include <wlr/types/wlr_compositor.h>
#define API __attribute__((visibility("default")))
API struct wl_signal *ataxia_xwayland_signal(struct wlr_xwayland *x, int event) {
 switch (event) { case 0: return &x->events.new_surface;
 case 1: return &x->events.ready; case 2: return &x->events.destroy; }
 return NULL;
}
API const char *ataxia_xwayland_display(struct wlr_xwayland *x) { return x->display_name; }
API struct wl_signal *ataxia_xsurface_signal(struct wlr_xwayland_surface *s, int event) {
 switch (event) {
 case 0: return &s->events.associate; case 1: return &s->events.dissociate;
 case 2: return &s->events.destroy; case 3: return &s->events.request_configure;
 case 4: return &s->events.set_title; case 5: return &s->events.set_class;
 case 6: return &s->events.set_geometry; case 7: return &s->events.request_fullscreen;
 case 8: return &s->events.request_maximize; case 9: return &s->events.request_minimize;
 case 10: return &s->events.request_move; case 11: return &s->events.request_resize;
 case 12: return &s->events.request_activate;
 }
 return NULL;
}
API struct wlr_surface *ataxia_xsurface_surface(struct wlr_xwayland_surface *s) { return s->surface; }
API void ataxia_xsurface_consider_map(struct wlr_xwayland_surface *s) {
 /* X11 association can arrive after the first wl_surface buffer commit. */
 if (s->surface && wlr_surface_has_buffer(s->surface)) wlr_surface_map(s->surface);
}
API struct wlr_xwayland_surface *ataxia_xsurface_parent(struct wlr_xwayland_surface *s) { return s->parent; }
API const char *ataxia_xsurface_text(struct wlr_xwayland_surface *s, int field) { return field == 0 ? s->title : s->class; }
API int ataxia_xsurface_value(struct wlr_xwayland_surface *s, int field) {
 switch (field) { case 0: return s->x; case 1: return s->y; case 2: return s->width;
 case 3: return s->height; case 4: return s->override_redirect; case 5: return s->fullscreen;
 case 6: return s->maximized_horz && s->maximized_vert; }
 return 0;
}
API int ataxia_xconfigure_value(struct wlr_xwayland_surface_configure_event *e, int field) {
 switch (field) { case 0: return e->x; case 1: return e->y; case 2: return e->width;
 case 3: return e->height; case 4: return e->mask; } return 0;
}
API bool ataxia_xminimize_value(struct wlr_xwayland_minimize_event *e) { return e->minimize; }
API uint32_t ataxia_xresize_edges(struct wlr_xwayland_resize_event *e) { return e->edges; }
