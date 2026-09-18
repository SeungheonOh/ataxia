/* Additive computer-use primitives. No World policy or synthetic input here. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_seat.h>
#define API __attribute__((visibility("default")))

API int32_t ataxia_cua_surface_pid(struct wlr_surface *surface) {
    pid_t pid = 0;
    if (surface && surface->resource)
        wl_client_get_credentials(wl_resource_get_client(surface->resource), &pid, NULL, NULL);
    return (int32_t)pid;
}
struct cua_source {
    struct wlr_data_source base;
    struct wl_event_loop *loop;
    unsigned references;
    size_t length;
    char *content;
};
struct cua_transfer {
    struct cua_source *source;
    struct wl_event_source *writable, *timer;
    struct wl_listener loop_destroy;
    size_t offset;
    int fd;
};
static unsigned transfers;
static void release(struct cua_source *s) {
    if (--s->references == 0) { free(s->content); free(s); }
}
static void finish(struct cua_transfer *t) {
    wl_list_remove(&t->loop_destroy.link);
    if (t->writable) wl_event_source_remove(t->writable);
    if (t->timer) wl_event_source_remove(t->timer);
    close(t->fd); release(t->source); transfers--; free(t);
}
static void loop_destroy(struct wl_listener *listener, void *data) {
    (void)data;
    struct cua_transfer *t = wl_container_of(listener, t, loop_destroy);
    finish(t);
}
static int timeout(void *data) { finish(data); return 0; }
static ssize_t write_safe(int fd, const void *data, size_t length) {
    sigset_t blocked, previous, pending;
    sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &blocked, &previous); sigpending(&pending);
    ssize_t n = write(fd, data, length);
    int e = errno;
    if (n < 0 && e == EPIPE && !sigismember(&pending, SIGPIPE)) {
        struct timespec zero = {0};
        while (sigtimedwait(&blocked, NULL, &zero) < 0 && errno == EINTR) {}
    }
    pthread_sigmask(SIG_SETMASK, &previous, NULL); errno = e; return n;
}
static int writable(int fd, uint32_t mask, void *data) {
    struct cua_transfer *t = data;
    if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) { finish(t); return 0; }
    size_t size = t->source->length - t->offset;
    if (size > 65536) size = 65536;
    ssize_t n = write_safe(fd, t->source->content + t->offset, size);
    if (n > 0) t->offset += n;
    if (t->offset == t->source->length ||
        (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) finish(t);
    return 0;
}
static void send_content(struct wlr_data_source *base, const char *mime, int32_t fd) {
    (void)mime;
    struct cua_source *s = wl_container_of(base, s, base);
    if (transfers >= 32 || fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0) { close(fd); return; }
    struct cua_transfer *t = calloc(1, sizeof(*t));
    if (!t) { close(fd); return; }
    t->source = s; t->fd = fd; s->references++; transfers++;
    t->loop_destroy.notify = loop_destroy;
    wl_event_loop_add_destroy_listener(s->loop, &t->loop_destroy);
    t->writable = wl_event_loop_add_fd(s->loop, fd, WL_EVENT_WRITABLE, writable, t);
    t->timer = wl_event_loop_add_timer(s->loop, timeout, t);
    if (!t->writable || !t->timer) { finish(t); return; }
    wl_event_source_timer_update(t->timer, 2000);
}
static void destroy_content(struct wlr_data_source *base) {
    struct cua_source *s = wl_container_of(base, s, base); release(s);
}
static const struct wlr_data_source_impl impl = {.send = send_content, .destroy = destroy_content};
API bool ataxia_cua_set_clipboard(struct wlr_seat *seat, const char *content, size_t length, const char *format) {
    if (!seat || !content || !format || length > 4 * 1024 * 1024) return false;
    bool html = strcmp(format, "html") == 0, md = strcmp(format, "md") == 0;
    if (!html && !md && strcmp(format, "text") != 0) return false;
    struct cua_source *s = calloc(1, sizeof(*s));
    if (!s) return false;
    s->content = malloc(length + 1);
    if (!s->content) { free(s); return false; }
    memcpy(s->content, content, length); s->content[length] = 0; s->length = length;
    s->references = 1; s->loop = wl_display_get_event_loop(seat->display);
    wlr_data_source_init(&s->base, &impl);
    /* HTML is offered only as HTML: never silently paste markup as plain text.
       Markdown also offers its source as plain text, matching browser paste. */
    const char *mimes[] = {html ? "text/html" : md ? "text/markdown" : "text/plain;charset=utf-8",
                          "text/plain;charset=utf-8", "text/plain", "UTF8_STRING"};
    size_t count = html ? 1 : 4;
    for (size_t i = 0; i < count; i++) {
        if (i == 1 && !md) continue;
        char **slot = wl_array_add(&s->base.mime_types, sizeof(char *));
        if (!slot) { wlr_data_source_destroy(&s->base); return false; }
        *slot = strdup(mimes[i]);
        if (!*slot) { wlr_data_source_destroy(&s->base); return false; }
    }
    wlr_seat_set_selection(seat, &s->base, wl_display_next_serial(seat->display));
    return true;
}

/* Bound client resources are different from the seat's advertised capabilities.
 * A client may ignore a hotplugged seat or bind its devices asynchronously. */
API uint32_t ataxia_seat_surface_input_capabilities(struct wlr_seat *seat,
                                                   struct wlr_surface *surface) {
  if (!seat || !surface)
    return 0;
  struct wlr_seat_client *client = wlr_seat_client_for_wl_client(
      seat, wl_resource_get_client(surface->resource));
  if (!client)
    return 0;
  uint32_t capabilities = 0;
  struct wl_resource *resource;
  wl_resource_for_each(resource, &client->pointers)
    if (wl_resource_get_user_data(resource))
      capabilities |= WL_SEAT_CAPABILITY_POINTER;
  wl_resource_for_each(resource, &client->keyboards)
    if (wl_resource_get_user_data(resource))
      capabilities |= WL_SEAT_CAPABILITY_KEYBOARD;
  wl_resource_for_each(resource, &client->touches)
    if (wl_resource_get_user_data(resource))
      capabilities |= WL_SEAT_CAPABILITY_TOUCH;
  return capabilities & seat->capabilities;
}
