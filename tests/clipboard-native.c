#define _GNU_SOURCE
#include "native/ataxia-wlr-glue.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_seat.h>
static void transfer(struct wl_event_loop *loop, struct wlr_seat *seat, const char *text, size_t size) {
    int fds[2]; assert(pipe2(fds, O_CLOEXEC | O_NONBLOCK) == 0);
    assert(ataxia_seat_selection_receive(seat, "text/plain;charset=utf-8", fds[1]));
    /* Replacing the selection must not free bytes used by a pending transfer. */
    assert(ataxia_seat_set_clipboard_text(seat, "replacement", 11));
    char buffer[8192]; size_t offset = 0;
    for (unsigned i = 0; i < 10000; i++) {
        assert(wl_event_loop_dispatch(loop, 0) == 0);
        ssize_t count = read(fds[0], buffer, sizeof(buffer));
        if (count == 0) break;
        if (count < 0) { assert(errno == EAGAIN); continue; }
        assert(offset + (size_t)count <= size);
        assert(memcmp(text + offset, buffer, (size_t)count) == 0);
        offset += (size_t)count;
    }
    assert(offset == size); close(fds[0]);
}
int main(void) {
    struct wl_display *display = wl_display_create(); assert(display);
    struct wl_event_loop *loop = wl_display_get_event_loop(display);
    struct wlr_seat *a = wlr_seat_create(display, "a"), *b = wlr_seat_create(display, "b"); assert(a && b);
    const char *text = "Unicode · λ🙂";
    assert(ataxia_seat_set_clipboard_text(a, text, strlen(text)));
    assert(ataxia_seat_clipboard_owned(a)); assert(!ataxia_seat_clipboard_owned(b));
    assert(ataxia_seat_selection_mime_count(a) == 3);
    transfer(loop, a, text, strlen(text));
    size_t size = 1024 * 1024; char *large = malloc(size); assert(large); memset(large, 'x', size);
    assert(ataxia_seat_set_clipboard_text(a, large, size)); transfer(loop, a, large, size);
    assert(!ataxia_seat_set_clipboard_text(a, large, 4 * 1024 * 1024 + 1));
    assert(ataxia_seat_set_clipboard_text(a, "", 0)); transfer(loop, a, "", 0);
    /* Closed readers must neither raise SIGPIPE nor strand a transfer. */
    for (int i = 0; i < 64; i++) {
        int fds[2]; assert(pipe2(fds, O_CLOEXEC) == 0); close(fds[0]);
        assert(ataxia_seat_selection_receive(a, "text/plain", fds[1]));
        assert(wl_event_loop_dispatch(loop, 0) == 0);
    }
    /* Saturated pipes time out and teardown cancels remaining writes. */
    int fds[2]; assert(pipe2(fds, O_CLOEXEC) == 0);
    assert(ataxia_seat_set_clipboard_text(a, large, size));
    assert(ataxia_seat_selection_receive(a, "text/plain", fds[1]));
    assert(wl_event_loop_dispatch(loop, 0) == 0);
    assert(wl_event_loop_dispatch(loop, 2100) == 0);
    wl_display_destroy(display); close(fds[0]); free(large);
    puts("PASS: native clipboard Unicode, large/empty transfers, source replacement, independent seats, closed reader, size cap, timeout and teardown.");
}
