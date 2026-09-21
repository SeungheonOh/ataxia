/* Minimal real Wayland client that records seat, pointer, keymap and key
 * events. */
#define _POSIX_C_SOURCE 200809L
#include "xdg-shell-client.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_subcompositor *subcompositor;
static struct wl_data_device_manager *data_manager;
static struct xdg_wm_base *shell;
static struct wl_surface *surface;
static struct wl_surface *drag_preview;
static struct wl_callback *drag_frame;
static int drag_dx, drag_dy;
static void start_test_drag(void *seat_data, uint32_t serial);
static struct xdg_toplevel *toplevel;
static struct xdg_surface *root_xdg;
static FILE *logfile;
struct popup_window {
  struct wl_surface *surface;
  struct xdg_surface *xdg;
  struct xdg_popup *popup;
  uint32_t color;
};
static struct popup_window menu_popup, nested_popup;
static double delayed_at, animation_at;
static int delayed_step, animating, animation_frame;
static int running = 1;
static volatile sig_atomic_t repaint_requested;
static void request_repaint(int signal_number) {
  (void)signal_number;
  repaint_requested = 1;
}
static double monotonic_seconds(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return now.tv_sec + now.tv_nsec / 1000000000.0;
}
static void paint(struct wl_surface *target, int width, int height,
                  uint32_t color);
static void show_popup(void);
static void reposition_popup(void);
static void show_nested_popup(void);
static void close_popups(void);
static void frame_paint(void *data, struct wl_callback *callback,
                        uint32_t time) {
  (void)data;
  (void)time;
  wl_callback_destroy(callback);
  paint(surface, 600, 360, 0xff48cf60);
  fprintf(logfile, "frame-painted\n");
  fflush(logfile);
}
static const struct wl_callback_listener frame_listener = {frame_paint};
struct seat {
  struct wl_seat *seat;
  struct wl_keyboard *keyboard;
  struct wl_pointer *pointer;
  struct xkb_context *context;
  struct xkb_keymap *map;
  struct xkb_state *state;
  struct wl_surface *pointer_surface;
  struct wl_data_device *data_device;
  struct wl_data_offer *selection;
  struct wl_data_offer *drag_offer;
  int receive_fd;
  size_t received;
  char received_text[1024];
  uint32_t pending_capabilities;
  double bind_at;
  struct seat *next;
  char name[128];
};
static struct seat *seats;
static void source_target(void *data, struct wl_data_source *source, const char *mime) {
  (void)data; (void)source; (void)mime;
}
static void source_send(void *data, struct wl_data_source *source, const char *mime, int fd) {
  (void)source; (void)mime;
  const char *text = data;
  if (write(fd, text, strlen(text)) < 0)
    perror("clipboard write");
  close(fd);
}
static void source_cancel(void *data, struct wl_data_source *source) {
  free(data);
  wl_data_source_destroy(source);
}
static void source_finished(void *data, struct wl_data_source *source) {
  (void)data; (void)source;
}
static void source_action(void *data, struct wl_data_source *source, uint32_t action) {
  (void)data; (void)source; (void)action;
}
static const struct wl_data_source_listener source_listener = {
  .target = source_target, .send = source_send, .cancelled = source_cancel,
  .dnd_drop_performed = source_finished, .dnd_finished = source_finished, .action = source_action
};
static void offer_mime(void *data, struct wl_data_offer *offer, const char *mime) {
  (void)data; (void)offer; (void)mime;
}
static void offer_actions(void *data, struct wl_data_offer *offer, uint32_t actions) {
  (void)data; (void)offer; (void)actions;
}
static const struct wl_data_offer_listener offer_listener = {
  .offer = offer_mime, .source_actions = offer_actions, .action = offer_actions
};
static void data_offer(void *data, struct wl_data_device *device, struct wl_data_offer *offer) {
  (void)device;
  wl_data_offer_add_listener(offer, &offer_listener, data);
}
static void data_enter(void *data, struct wl_data_device *device, uint32_t serial,
                       struct wl_surface *target, wl_fixed_t x, wl_fixed_t y, struct wl_data_offer *offer) {
  (void)device; (void)target;
  struct seat *s = data;
  s->drag_offer = offer;
  fprintf(logfile, "drag-enter %s %.1f %.1f\n", s->name, wl_fixed_to_double(x), wl_fixed_to_double(y));
  fflush(logfile);
  if (offer) {
    wl_data_offer_accept(offer, serial, "text/plain;charset=utf-8");
    wl_data_offer_set_actions(offer, WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY,
                             WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
  }
}
static void data_leave(void *data, struct wl_data_device *device) {
  (void)data; (void)device;
}
static void data_motion(void *data, struct wl_data_device *device, uint32_t time, wl_fixed_t x, wl_fixed_t y) {
  (void)data; (void)device; (void)time; (void)x; (void)y;
}
static void data_drop(void *data, struct wl_data_device *device) {
  (void)device;
  struct seat *s = data;
  fprintf(logfile, "drag-drop %s\n", s->name);
  fflush(logfile);
  if (s->drag_offer) {
    wl_data_offer_finish(s->drag_offer);
    wl_data_offer_destroy(s->drag_offer);
    s->drag_offer = NULL;
  }
}
static void data_selection(void *data, struct wl_data_device *device, struct wl_data_offer *offer) {
  (void)device;
  struct seat *s = data;
  if (s->selection && s->selection != offer)
    wl_data_offer_destroy(s->selection);
  s->selection = offer;
  fprintf(logfile, "selection %s %s\n", s->name, offer ? "offered" : "empty");
  fflush(logfile);
}
static const struct wl_data_device_listener data_listener = {
  .data_offer = data_offer, .enter = data_enter, .leave = data_leave,
  .motion = data_motion, .drop = data_drop, .selection = data_selection
};
static void bind_data_devices(void) {
  if (data_manager)
    for (struct seat *s = seats; s; s = s->next)
      if (!s->data_device) {
        s->data_device = wl_data_device_manager_get_data_device(data_manager, s->seat);
        wl_data_device_add_listener(s->data_device, &data_listener, s);
      }
}
static void clipboard_copy(struct seat *s, uint32_t serial) {
  if (!s->data_device)
    return;
  const char *override = getenv("ATAXIA_TEST_CLIPBOARD_SEAT");
  struct seat *destination = s;
  if (override)
    for (struct seat *candidate = seats; candidate; candidate = candidate->next)
      if (!strcmp(candidate->name, override))
        destination = candidate;
  char text[512];
  snprintf(text, sizeof(text), "Clipboard from %s on %s · λ🙂",
           getenv("ATAXIA_TEST_TITLE") ? getenv("ATAXIA_TEST_TITLE") : "test", s->name);
  struct wl_data_source *source = wl_data_device_manager_create_data_source(data_manager);
  wl_data_source_add_listener(source, &source_listener, strdup(text));
  wl_data_source_offer(source, "text/plain;charset=utf-8");
  wl_data_device_set_selection(destination->data_device, source, serial);
  snprintf(text, sizeof(text), "Clipboard offered on %s", s->name);
  xdg_toplevel_set_title(toplevel, text);
}
static void clipboard_paste(struct seat *s) {
  if (!s->selection) {
    char title[180];
    snprintf(title, sizeof(title), "Clipboard empty on %s", s->name);
    xdg_toplevel_set_title(toplevel, title);
    return;
  }
  int fds[2];
  if (pipe(fds) < 0)
    exit(7);
  fcntl(fds[0], F_SETFL, O_NONBLOCK);
  if (s->receive_fd >= 0)
    close(s->receive_fd);
  s->receive_fd = fds[0];
  s->received = 0;
  wl_data_offer_receive(s->selection, "text/plain;charset=utf-8", fds[1]);
  close(fds[1]);
}
static void clipboard_read(struct seat *s) {
  if (s->receive_fd < 0)
    return;
  ssize_t n = read(s->receive_fd, s->received_text + s->received,
                   sizeof(s->received_text) - 1 - s->received);
  if (n > 0) {
    s->received += (size_t)n;
  } else if (n == 0) {
    s->received_text[s->received] = 0;
    fprintf(logfile, "clipboard %s %s\n", s->name, s->received_text);
    fflush(logfile);
    char title[180];
    snprintf(title, sizeof(title), "Clipboard received on %s", s->name);
    xdg_toplevel_set_title(toplevel, title);
    close(s->receive_fd);
    s->receive_fd = -1;
  } else if (errno != EAGAIN && errno != EINTR) {
    exit(8);
  }
}
static void keyboard_map(void *data, struct wl_keyboard *k, uint32_t format,
                         int fd, uint32_t size) {
  (void)k;
  struct seat *s = data;
  if (format == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
    char *text = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (text != MAP_FAILED) {
      xkb_state_unref(s->state);
      xkb_keymap_unref(s->map);
      s->map = xkb_keymap_new_from_string(s->context, text,
                                          XKB_KEYMAP_FORMAT_TEXT_V1, 0);
      s->state = s->map ? xkb_state_new(s->map) : NULL;
      munmap(text, size);
    }
  }
  close(fd);
  fprintf(logfile, "keymap %s\n", s->name);
  fflush(logfile);
}
static void keyboard_enter(void *data, struct wl_keyboard *k, uint32_t serial,
                           struct wl_surface *surf, struct wl_array *keys) {
  (void)k;
  (void)serial;
  (void)surf;
  (void)keys;
  fprintf(logfile, "focus %s\n", ((struct seat *)data)->name);
  fflush(logfile);
}
static void keyboard_leave(void *data, struct wl_keyboard *k, uint32_t serial,
                           struct wl_surface *surf) {
  (void)k;
  (void)serial;
  (void)surf;
  fprintf(logfile, "leave %s\n", ((struct seat *)data)->name);
  fflush(logfile);
}
static void keyboard_key(void *data, struct wl_keyboard *k, uint32_t serial,
                         uint32_t time, uint32_t key, uint32_t state) {
  (void)k;
  (void)serial;
  (void)time;
  struct seat *s = data;
  char text[64] = {0};
  uint32_t sym = 0;
  if (s->state) {
    sym = xkb_state_key_get_one_sym(s->state, key + 8);
    xkb_keysym_to_utf8(sym, text, sizeof(text));
  }
  fprintf(logfile, "key %s %u %u %u %s\n", s->name, key, state, sym, text);
  fflush(logfile);
  if (state == WL_KEYBOARD_KEY_STATE_PRESSED && sym == XKB_KEY_F1)
    clipboard_copy(s, serial);
  if (state == WL_KEYBOARD_KEY_STATE_PRESSED && sym == XKB_KEY_F3)
    clipboard_paste(s);
  if (state == WL_KEYBOARD_KEY_STATE_PRESSED && sym == XKB_KEY_Return)
    xdg_toplevel_set_title(toplevel, "Batch complete");
  if (state == WL_KEYBOARD_KEY_STATE_PRESSED && sym == XKB_KEY_F2)
    running = 0;
  if (state == WL_KEYBOARD_KEY_STATE_PRESSED && sym == XKB_KEY_F4) {
    animating = !animating;
    animation_at = monotonic_seconds();
  }
  if (state == WL_KEYBOARD_KEY_STATE_PRESSED && sym == XKB_KEY_F5) {
    wl_callback_add_listener(wl_surface_frame(surface), &frame_listener, NULL);
    wl_surface_commit(surface);
  }
  if (state == WL_KEYBOARD_KEY_STATE_PRESSED && sym == XKB_KEY_F6)
    paint(surface, 640, 400, 0xffef6048);
  if (state == WL_KEYBOARD_KEY_STATE_PRESSED && sym == XKB_KEY_F7) {
    struct wl_surface *child = wl_compositor_create_surface(compositor);
    struct wl_subsurface *sub =
        wl_subcompositor_get_subsurface(subcompositor, child, surface);
    wl_subsurface_set_position(sub, -30, 40);
    paint(child, 80, 80, 0xffffd040);
    wl_surface_commit(surface);
  }
  if (state == WL_KEYBOARD_KEY_STATE_PRESSED && sym == XKB_KEY_F8)
    show_popup();
  if (state == WL_KEYBOARD_KEY_STATE_PRESSED && sym == XKB_KEY_F9)
    reposition_popup();
  if (state == WL_KEYBOARD_KEY_STATE_PRESSED && sym == XKB_KEY_F10)
    show_nested_popup();
  if (state == WL_KEYBOARD_KEY_STATE_PRESSED && sym == XKB_KEY_F11)
    close_popups();
  if (state == WL_KEYBOARD_KEY_STATE_PRESSED && sym == XKB_KEY_F12) {
    paint(surface, 600, 360, 0xffef6048);
    xdg_toplevel_set_title(toplevel, "Async pending");
    delayed_step = 1;
    delayed_at = monotonic_seconds() + 0.08;
  }
}
static void keyboard_modifiers(void *data, struct wl_keyboard *k,
                               uint32_t serial, uint32_t depressed,
                               uint32_t latched, uint32_t locked,
                               uint32_t group) {
  (void)k;
  (void)serial;
  struct seat *s = data;
  if (s->state)
    xkb_state_update_mask(s->state, depressed, latched, locked, 0, 0, group);
  fprintf(logfile, "mods %s %u\n", s->name, depressed);
  fflush(logfile);
}
static void keyboard_repeat(void *d, struct wl_keyboard *k, int32_t rate,
                            int32_t delay) {
  (void)d;
  (void)k;
  (void)rate;
  (void)delay;
}
static const struct wl_keyboard_listener keyboard_listener = {
    keyboard_map, keyboard_enter,     keyboard_leave,
    keyboard_key, keyboard_modifiers, keyboard_repeat};
static void pointer_enter(void *d, struct wl_pointer *p, uint32_t serial,
                          struct wl_surface *s, wl_fixed_t x, wl_fixed_t y) {
  (void)p;
  (void)serial;
  ((struct seat *)d)->pointer_surface = s;
  fprintf(logfile, "pointer-enter %s %.1f %.1f\n", ((struct seat *)d)->name,
          wl_fixed_to_double(x), wl_fixed_to_double(y));
  fprintf(logfile, "pointer-surface %s %s\n", ((struct seat *)d)->name,
          wl_surface_get_user_data(s) ? (char *)wl_surface_get_user_data(s)
                                      : "subsurface");
  fflush(logfile);
}
static void pointer_leave(void *d, struct wl_pointer *p, uint32_t serial,
                          struct wl_surface *s) {
  ((struct seat *)d)->pointer_surface = NULL;
  (void)p;
  (void)serial;
  (void)s;
}
static void pointer_motion(void *d, struct wl_pointer *p, uint32_t t,
                           wl_fixed_t x, wl_fixed_t y) {
  (void)p;
  (void)t;
  fprintf(logfile, "motion %s %.1f %.1f\n", ((struct seat *)d)->name,
          wl_fixed_to_double(x), wl_fixed_to_double(y));
  fflush(logfile);
}
static void pointer_button(void *d, struct wl_pointer *p, uint32_t serial,
                           uint32_t t, uint32_t button, uint32_t state) {
  (void)p;
  (void)serial;
  (void)t;
  fprintf(logfile, "button %s %u %u\n", ((struct seat *)d)->name, button,
          state);
  struct wl_surface *target = ((struct seat *)d)->pointer_surface;
  if (target && wl_surface_get_user_data(target))
    fprintf(logfile, "button-surface %s %s %u\n", ((struct seat *)d)->name,
            (char *)wl_surface_get_user_data(target), state);
  fflush(logfile);
  if (getenv("ATAXIA_TEST_DRAG") && button == 272 && state == WL_POINTER_BUTTON_STATE_PRESSED)
    start_test_drag(d, serial);
}
static void pointer_axis(void *d, struct wl_pointer *p, uint32_t t,
                         uint32_t axis, wl_fixed_t value) {
  (void)p;
  (void)t;
  fprintf(logfile, "axis %s %u %.1f\n", ((struct seat *)d)->name, axis,
          wl_fixed_to_double(value));
  fflush(logfile);
}
static void pointer_frame(void *d, struct wl_pointer *p) {
  (void)p;
  fprintf(logfile, "frame %s\n", ((struct seat *)d)->name);
  fflush(logfile);
}
static void pointer_source(void *d, struct wl_pointer *p, uint32_t s) {
  (void)d;
  (void)p;
  (void)s;
}
static void pointer_stop(void *d, struct wl_pointer *p, uint32_t t,
                         uint32_t a) {
  (void)d;
  (void)p;
  (void)t;
  (void)a;
}
static void pointer_discrete(void *d, struct wl_pointer *p, uint32_t a,
                             int32_t v) {
  (void)d;
  (void)p;
  (void)a;
  (void)v;
}
static const struct wl_pointer_listener pointer_listener = {
    .enter = pointer_enter,
    .leave = pointer_leave,
    .motion = pointer_motion,
    .button = pointer_button,
    .axis = pointer_axis,
    .frame = pointer_frame,
    .axis_source = pointer_source,
    .axis_stop = pointer_stop,
    .axis_discrete = pointer_discrete};
static void seat_caps(void *data, struct wl_seat *seat, uint32_t caps) {
  struct seat *s = data;
  fprintf(logfile, "caps %s %u\n", s->name, caps);
  fflush(logfile);
  if (getenv("ATAXIA_TEST_IGNORE_INPUT"))
    return;
  const char *delay = getenv("ATAXIA_TEST_BIND_DELAY_MS");
  if (delay && !s->bind_at) {
    s->pending_capabilities = caps;
    s->bind_at = monotonic_seconds() + strtod(delay, NULL) / 1000.0;
    return;
  }
  if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !s->keyboard) {
    s->keyboard = wl_seat_get_keyboard(seat);
    wl_keyboard_add_listener(s->keyboard, &keyboard_listener, s);
  }
  if ((caps & WL_SEAT_CAPABILITY_POINTER) && !s->pointer) {
    s->pointer = wl_seat_get_pointer(seat);
    wl_pointer_add_listener(s->pointer, &pointer_listener, s);
  }
}
static void seat_name(void *data, struct wl_seat *seat, const char *name) {
  (void)seat;
  struct seat *s = data;
  snprintf(s->name, sizeof(s->name), "%s", name);
  fprintf(logfile, "seat %s\n", name);
  fflush(logfile);
}
static const struct wl_seat_listener seat_listener = {seat_caps, seat_name};
static void ping(void *d, struct xdg_wm_base *b, uint32_t serial) {
  (void)d;
  xdg_wm_base_pong(b, serial);
}
static const struct xdg_wm_base_listener shell_listener = {ping};
static void global(void *d, struct wl_registry *r, uint32_t id,
                   const char *interface, uint32_t version) {
  (void)d;
  if (!strcmp(interface, "wl_compositor"))
    compositor = wl_registry_bind(r, id, &wl_compositor_interface, 4);
  else if (!strcmp(interface, "wl_shm"))
    shm = wl_registry_bind(r, id, &wl_shm_interface, 1);
  else if (!strcmp(interface, "wl_subcompositor"))
    subcompositor = wl_registry_bind(r, id, &wl_subcompositor_interface, 1);
  else if (!strcmp(interface, "wl_data_device_manager")) {
    data_manager = wl_registry_bind(r, id, &wl_data_device_manager_interface, version < 3 ? version : 3);
    bind_data_devices();
  }
  else if (!strcmp(interface, "xdg_wm_base")) {
    shell = wl_registry_bind(r, id, &xdg_wm_base_interface,
                             version < 3 ? version : 3);
    xdg_wm_base_add_listener(shell, &shell_listener, NULL);
  } else if (!strcmp(interface, "wl_seat")) {
    struct seat *s = calloc(1, sizeof(*s));
    s->receive_fd = -1;
    s->next = seats;
    seats = s;
    s->context = xkb_context_new(0);
    s->seat =
        wl_registry_bind(r, id, &wl_seat_interface, version < 5 ? version : 5);
    wl_seat_add_listener(s->seat, &seat_listener, s);
    bind_data_devices();
  }
}
static void remove_global(void *d, struct wl_registry *r, uint32_t id) {
  (void)d;
  (void)r;
  (void)id;
}
static const struct wl_registry_listener registry_listener = {global,
                                                              remove_global};
static void paint(struct wl_surface *target, int width, int height,
                  uint32_t color) {
  int size = width * height * 4;
  char path[] = "/tmp/ataxia-test-buffer-XXXXXX";
  int fd = mkstemp(path);
  unlink(path);
  if (fd < 0 || ftruncate(fd, size) < 0)
    exit(5);
  uint32_t *pixels =
      mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (pixels == MAP_FAILED)
    exit(6);
  for (int y = 0; y < height; y++)
    for (int x = 0; x < width; x++)
      pixels[y * width + x] = (x < 100 && y < 100)
                                  ? color
                                  : (y < height / 2 ? 0xff377b99 : 0xff22415b);
  struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
  struct wl_buffer *buffer = wl_shm_pool_create_buffer(
      pool, 0, width, height, width * 4, WL_SHM_FORMAT_XRGB8888);
  wl_shm_pool_destroy(pool);
  close(fd);
  munmap(pixels, size);
  wl_surface_attach(target, buffer, target == drag_preview ? drag_dx : 0,
                    target == drag_preview ? drag_dy : 0);
  if (target == drag_preview) drag_dx = drag_dy = 0;
  wl_surface_damage(target, 0, 0, width, height);
  wl_surface_commit(target);
  wl_buffer_destroy(buffer);
}
/* Drag fixture uses the same protocol path as a GTK/Firefox tab preview.
 * The first frame callback moves its origin and repaints while the pointer is idle. */
static void drag_cleanup(void *data, struct wl_data_source *source) {
  free(data);
  wl_data_source_destroy(source);
  if (drag_frame) wl_callback_destroy(drag_frame);
  drag_frame = NULL;
  if (drag_preview) wl_surface_destroy(drag_preview);
  drag_preview = NULL;
  fprintf(logfile, "drag-cleanup\n");
  fflush(logfile);
}
static void detached_configure(void *data, struct xdg_surface *xdg, uint32_t serial) {
  xdg_surface_ack_configure(xdg, serial);
  paint(data, 600, 360, 0xff48cf60);
}
static const struct xdg_surface_listener detached_listener = {detached_configure};
static void drag_cancelled(void *data, struct wl_data_source *source) {
  drag_cleanup(data, source);
  if (!getenv("ATAXIA_TEST_TAB_DETACH")) return;
  /* Exercise Firefox's delayed new-toplevel path, including the original
  * surface disappearing while the Wayland connection remains alive. */
  struct timespec delay = {.tv_nsec = 150000000};
  nanosleep(&delay, NULL);
  if (getenv("ATAXIA_TEST_TAB_CLOSE_ORIGIN")) {
    xdg_toplevel_destroy(toplevel);
    xdg_surface_destroy(root_xdg);
    wl_surface_destroy(surface);
    toplevel = NULL; root_xdg = NULL; surface = NULL;
  }
  struct wl_surface *detached = wl_compositor_create_surface(compositor);
  struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(shell, detached);
  xdg_surface_add_listener(xdg, &detached_listener, detached);
  struct xdg_toplevel *top = xdg_surface_get_toplevel(xdg);
  xdg_toplevel_set_app_id(top, "ataxia.agent-test");
  xdg_toplevel_set_title(top, "detached-tab");
  wl_surface_commit(detached);
}
static const struct wl_data_source_listener drag_source_listener = {
  .target = source_target, .send = source_send, .cancelled = drag_cancelled,
  .dnd_drop_performed = source_finished, .dnd_finished = drag_cleanup, .action = source_action
};
static void drag_repaint(void *data, struct wl_callback *callback, uint32_t time) {
  (void)data; (void)time;
  wl_callback_destroy(callback);
  drag_frame = NULL;
  drag_dx = 5; drag_dy = 3;
  paint(drag_preview, 80, 50, 0xff48cf60);
  fprintf(logfile, "drag-frame-painted\n");
  fflush(logfile);
}
static const struct wl_callback_listener drag_frame_listener = {drag_repaint};
static void start_test_drag(void *seat_data, uint32_t serial) {
  struct seat *s = seat_data;
  if (!s->data_device || drag_preview) return;
  struct wl_data_source *source = wl_data_device_manager_create_data_source(data_manager);
  wl_data_source_add_listener(source, &drag_source_listener, strdup("local drag fixture"));
  wl_data_source_offer(source, "text/plain;charset=utf-8");
  if (getenv("ATAXIA_TEST_TAB_DETACH"))
    wl_data_source_offer(source, "application/x-moz-tabbrowser-tab");
  wl_data_source_set_actions(source, WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
  drag_preview = wl_compositor_create_surface(compositor);
  wl_data_device_start_drag(s->data_device, source, surface, drag_preview, serial);
  drag_dx = -12; drag_dy = -8;
  drag_frame = wl_surface_frame(drag_preview);
  wl_callback_add_listener(drag_frame, &drag_frame_listener, NULL);
  paint(drag_preview, 80, 50, 0xffef6048);
  fprintf(logfile, "drag-started\n");
  fflush(logfile);
}
static void configure(void *d, struct xdg_surface *xdg, uint32_t serial) {
  (void)d;
  xdg_surface_ack_configure(xdg, serial);
  static int painted;
  if (!painted) {
    painted = 1;
    const char *color = getenv("ATAXIA_TEST_COLOR");
    paint(surface, 600, 360, color ? (uint32_t)strtoul(color, NULL, 16) : 0xffef6048);
  }
}
static const struct xdg_surface_listener surface_listener = {configure};
static void popup_configure(void *data, struct xdg_surface *xdg,
                            uint32_t serial) {
  struct popup_window *window = data;
  xdg_surface_ack_configure(xdg, serial);
  paint(window->surface, 80, 80, window->color);
}
static const struct xdg_surface_listener popup_surface_listener = {
    popup_configure};
static void popup_geometry(void *data, struct xdg_popup *popup, int32_t x,
                           int32_t y, int32_t width, int32_t height) {
  (void)data;
  (void)popup;
  (void)x;
  (void)y;
  (void)width;
  (void)height;
}
static void popup_done(void *data, struct xdg_popup *popup) {
  (void)data;
  (void)popup;
}
static void popup_repositioned(void *data, struct xdg_popup *popup,
                               uint32_t token) {
  (void)data;
  (void)popup;
  fprintf(logfile, "popup-repositioned %u\n", token);
  fflush(logfile);
}
static const struct xdg_popup_listener popup_listener = {
    .configure = popup_geometry, .popup_done = popup_done,
    .repositioned = popup_repositioned};
static struct xdg_positioner *popup_positioner(int x, int y) {
  struct xdg_positioner *positioner = xdg_wm_base_create_positioner(shell);
  xdg_positioner_set_size(positioner, 80, 80);
  xdg_positioner_set_anchor_rect(positioner, x, y, 1, 1);
  xdg_positioner_set_anchor(positioner, XDG_POSITIONER_ANCHOR_TOP_LEFT);
  xdg_positioner_set_gravity(positioner, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT);
  return positioner;
}
static void make_popup(struct popup_window *window, struct xdg_surface *parent,
                       int x, int y, char *name, uint32_t color) {
  if (window->surface)
    return;
  window->surface = wl_compositor_create_surface(compositor);
  wl_surface_set_user_data(window->surface, name);
  window->xdg = xdg_wm_base_get_xdg_surface(shell, window->surface);
  window->color = color;
  xdg_surface_add_listener(window->xdg, &popup_surface_listener, window);
  struct xdg_positioner *positioner = popup_positioner(x, y);
  window->popup = xdg_surface_get_popup(window->xdg, parent, positioner);
  xdg_popup_add_listener(window->popup, &popup_listener, window);
  xdg_positioner_destroy(positioner);
  wl_surface_commit(window->surface);
}
static void show_popup(void) {
  make_popup(&menu_popup, root_xdg, 25, 30, "popup", 0xffbf60ef);
}
static void reposition_popup(void) {
  if (menu_popup.popup) {
    struct xdg_positioner *positioner = popup_positioner(260, 150);
    xdg_popup_reposition(menu_popup.popup, positioner, 7);
    xdg_positioner_destroy(positioner);
  }
}
static void show_nested_popup(void) {
  if (menu_popup.xdg)
    make_popup(&nested_popup, menu_popup.xdg, 60, 20, "nested-popup",
                0xff40bfff);
}
static void destroy_popup(struct popup_window *window) {
  if (window->surface) {
    for (struct seat *s = seats; s; s = s->next)
      if (s->pointer_surface == window->surface)
        s->pointer_surface = NULL;
    xdg_popup_destroy(window->popup);
    xdg_surface_destroy(window->xdg);
    wl_surface_destroy(window->surface);
    memset(window, 0, sizeof(*window));
  }
}
static void close_popups(void) {
  destroy_popup(&nested_popup);
  destroy_popup(&menu_popup);
}
int main(int argc, char **argv) {
  if (argc != 2)
    return 2;
  long lifetime = 20;
  const char *lifetime_text = getenv("ATAXIA_TEST_SECONDS");
  if (lifetime_text) {
    char *end;
    lifetime = strtol(lifetime_text, &end, 10);
    if (end == lifetime_text || *end || lifetime < 1 || lifetime > 3600)
      return 2;
  }
  logfile = fopen(argv[1], "w");
  if (!logfile)
    return 3;
  if (getenv("ATAXIA_TEST_REPAINT_SIGNAL")) signal(SIGUSR1, request_repaint);
  display = wl_display_connect(NULL);
  if (!display)
    return 4;
  struct wl_registry *r = wl_display_get_registry(display);
  wl_registry_add_listener(r, &registry_listener, NULL);
  wl_display_roundtrip(display);
  surface = wl_compositor_create_surface(compositor);
  wl_surface_set_user_data(surface, "root");
  struct xdg_surface *x = xdg_wm_base_get_xdg_surface(shell, surface);
  root_xdg = x;
  xdg_surface_add_listener(x, &surface_listener, NULL);
  toplevel = xdg_surface_get_toplevel(x);
  xdg_toplevel_set_title(toplevel, getenv("ATAXIA_TEST_TITLE")
                                       ? getenv("ATAXIA_TEST_TITLE")
                                       : "Agent input test");
  xdg_toplevel_set_app_id(toplevel, "ataxia.agent-test");
  wl_surface_commit(surface);
  double stop_at = monotonic_seconds() + lifetime;
  while (running && monotonic_seconds() < stop_at) {
    double now = monotonic_seconds();
    if (repaint_requested) {
      repaint_requested = 0;
      paint(surface, 600, 360, 0xff48cf60);
      fprintf(logfile, "signal-repaint\n");
      fflush(logfile);
    }
    for (struct seat *s = seats; s; s = s->next) {
      clipboard_read(s);
      if (s->bind_at > 0 && now >= s->bind_at) {
        s->bind_at = -1;
        seat_caps(s, s->seat, s->pending_capabilities);
      }
    }
    if (delayed_step && now >= delayed_at) {
      if (delayed_step == 1) {
        paint(surface, 600, 360, 0xffffd040);
        delayed_step = 2;
        delayed_at = now + 0.12;
      } else {
        paint(surface, 600, 360, 0xff48cf60);
        xdg_toplevel_set_title(toplevel, "Async complete");
        delayed_step = 0;
        fprintf(logfile, "async-complete\n");
        fflush(logfile);
      }
    }
    if (animating && now >= animation_at) {
      paint(surface, 600, 360,
            (++animation_frame % 2) ? 0xffbf60ef : 0xff40bfff);
      animation_at = now + 0.04;
    }
    while (wl_display_prepare_read(display) != 0)
      if (wl_display_dispatch_pending(display) < 0)
        return 0;
    wl_display_flush(display);
    struct pollfd p = {wl_display_get_fd(display), POLLIN, 0};
    if (poll(&p, 1, 50) > 0) {
      if (wl_display_read_events(display) < 0)
        break;
      wl_display_dispatch_pending(display);
    } else
      wl_display_cancel_read(display);
  }
  wl_display_disconnect(display);
  fclose(logfile);
  return 0;
}
