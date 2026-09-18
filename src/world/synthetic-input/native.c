/* Concrete wlroots input objects; registration and policy remain in Lisp. */
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <wlr/interfaces/wlr_keyboard.h>
#include <wlr/interfaces/wlr_pointer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_seat.h>
#include <xkbcommon/xkbcommon.h>
#define API __attribute__((visibility("default")))
static const struct wlr_keyboard_impl keyboard_impl = {.name =
                                                           "ataxia-synthetic"};
static const struct wlr_pointer_impl pointer_impl = {.name =
                                                         "ataxia-synthetic"};
API struct wlr_input_device *ataxia_synthetic_create(bool keyboard,
                                                     const char *name) {
  if (keyboard) {
    struct wlr_keyboard *k = calloc(1, sizeof(*k));
    if (!k)
      return NULL;
    wlr_keyboard_init(k, &keyboard_impl, name);
    return &k->base;
  }
  struct wlr_pointer *p = calloc(1, sizeof(*p));
  if (!p)
    return NULL;
  wlr_pointer_init(p, &pointer_impl, name);
  return &p->base;
}
API void ataxia_synthetic_destroy(void *object, bool keyboard) {
  if (keyboard)
    wlr_keyboard_finish(object);
  else
    wlr_pointer_finish(object);
  free(object);
}
API void ataxia_synthetic_key(struct wlr_keyboard *keyboard, uint32_t code,
                              bool pressed, uint32_t time) {
  struct wlr_keyboard_key_event event = {
      .time_msec = time,
      .keycode = code,
      .update_state = true,
      .state = pressed ? WL_KEYBOARD_KEY_STATE_PRESSED
                       : WL_KEYBOARD_KEY_STATE_RELEASED,
  };
  wlr_keyboard_notify_key(keyboard, &event);
}
/* A physical key for a base-level XKB symbol. Chords express modifiers
 * separately. */
API int ataxia_synthetic_keycode(struct wlr_keyboard *keyboard,
                                 const char *name) {
  xkb_keysym_t symbol = xkb_keysym_from_name(name, XKB_KEYSYM_NO_FLAGS);
  if (!symbol || !keyboard->keymap)
    return -1;
  for (xkb_keycode_t code = xkb_keymap_min_keycode(keyboard->keymap);
       code <= xkb_keymap_max_keycode(keyboard->keymap); code++) {
    const xkb_keysym_t *symbols;
    int count = xkb_keymap_key_get_syms_by_level(keyboard->keymap, code, 0, 0,
                                                 &symbols);
    for (int i = 0; i < count; i++)
      if (symbols[i] == symbol && code >= 8)
        return (int)code - 8;
  }
  return -1;
}
API bool ataxia_synthetic_keymap(struct wlr_keyboard *keyboard,
                                 const char *text) {
  struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  if (!context)
    return false;
  struct xkb_keymap *map = xkb_keymap_new_from_string(
      context, text, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
  bool ok = map && wlr_keyboard_set_keymap(keyboard, map);
  xkb_keymap_unref(map);
  xkb_context_unref(context);
  return ok;
}
