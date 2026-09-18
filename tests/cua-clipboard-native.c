#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_data_device.h>
extern bool ataxia_cua_set_clipboard(struct wlr_seat *, const char *, size_t, const char *);
static bool offers(struct wlr_seat *seat, const char *mime) {
    char **item;
    wl_array_for_each(item, &seat->selection_source->mime_types) if (!strcmp(*item, mime)) return true;
    return false;
}
static void transfer(struct wl_event_loop *loop, struct wlr_seat *seat, const char *mime, const char *text, size_t length) {
    int fds[2]; assert(pipe2(fds, O_CLOEXEC | O_NONBLOCK) == 0);
    assert(offers(seat, mime)); wlr_data_source_send(seat->selection_source, mime, fds[1]);
    assert(ataxia_cua_set_clipboard(seat, "replacement", 11, "text"));
    char buffer[8192]; size_t offset = 0;
    for (unsigned i = 0; i < 10000; i++) {
        assert(wl_event_loop_dispatch(loop, 0) == 0);
        ssize_t count = read(fds[0], buffer, sizeof(buffer));
        if (!count) break;
        if (count < 0) { assert(errno == EAGAIN); continue; }
        assert(offset + (size_t)count <= length); assert(!memcmp(text + offset, buffer, count)); offset += count;
    }
    assert(offset == length); close(fds[0]);
}
int main(void) {
    struct wl_display *display = wl_display_create(); assert(display);
    struct wl_event_loop *loop = wl_display_get_event_loop(display);
    struct wlr_seat *human = wlr_seat_create(display, "human"), *agent = wlr_seat_create(display, "agent");
    assert(human && agent);
    assert(ataxia_cua_set_clipboard(human, "human data", 10, "text"));
    struct wlr_data_source *original = human->selection_source;
    const char *text = "Unicode · λ🙂\nsecond line";
    assert(ataxia_cua_set_clipboard(agent, text, strlen(text), "text"));
    assert(offers(agent, "text/plain;charset=utf-8")); assert(offers(agent, "UTF8_STRING")); assert(!offers(agent, "text/html"));
    transfer(loop, agent, "text/plain", text, strlen(text));
    assert(ataxia_cua_set_clipboard(agent, "**md**", 6, "md"));
    assert(offers(agent, "text/markdown")); assert(offers(agent, "text/plain")); transfer(loop, agent, "text/markdown", "**md**", 6);
    assert(ataxia_cua_set_clipboard(agent, "<b>html</b>", 11, "html"));
    assert(offers(agent, "text/html")); assert(!offers(agent, "text/plain")); transfer(loop, agent, "text/html", "<b>html</b>", 11);
    assert(!ataxia_cua_set_clipboard(agent, text, strlen(text), "unknown"));
    size_t length = 1024 * 1024; char *large = malloc(length); assert(large); memset(large, 'x', length);
    assert(!ataxia_cua_set_clipboard(agent, large, 4 * 1024 * 1024 + 1, "text"));
    assert(ataxia_cua_set_clipboard(agent, large, length, "text")); transfer(loop, agent, "text/plain", large, length);
    assert(ataxia_cua_set_clipboard(agent, "", 0, "text")); transfer(loop, agent, "text/plain", "", 0);
    for (int i = 0; i < 64; i++) {
        int fds[2]; assert(pipe2(fds, O_CLOEXEC) == 0); close(fds[0]);
        wlr_data_source_send(agent->selection_source, "text/plain", fds[1]); assert(wl_event_loop_dispatch(loop, 0) == 0);
    }
    assert(human->selection_source == original); transfer(loop, human, "text/plain", "human data", 10);
    int fds[2]; assert(pipe2(fds, O_CLOEXEC) == 0);
    assert(ataxia_cua_set_clipboard(agent, large, length, "text"));
    wlr_data_source_send(agent->selection_source, "text/plain", fds[1]);
    assert(wl_event_loop_dispatch(loop, 0) == 0); assert(wl_event_loop_dispatch(loop, 2100) == 0);
    wl_display_destroy(display); close(fds[0]); free(large);
    puts("PASS: CUA paste MIME formats, Unicode, empty/large content, human clipboard preservation, source replacement, closed readers, timeouts and teardown.");
}
