/* Owned Wayland text sources and nonblocking transfers; all policy lives in Lisp. */
#define _POSIX_C_SOURCE 200809L
#include "ataxia-wlr-glue.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_seat.h>

struct text_source {
	struct wlr_data_source base;
	struct wl_event_loop *loop;
	unsigned references;
	size_t length;
	char *text;
};
struct text_transfer {
	struct text_source *source;
	struct wl_event_source *writable, *timer;
	struct wl_listener loop_destroy;
	size_t offset;
	int fd;
};
static unsigned transfer_count;
static void text_release(struct text_source *source) {
	if (--source->references == 0) { free(source->text); free(source); }
}
static void transfer_finish(struct text_transfer *transfer) {
	wl_list_remove(&transfer->loop_destroy.link);
	if (transfer->writable) wl_event_source_remove(transfer->writable);
	if (transfer->timer) wl_event_source_remove(transfer->timer);
	close(transfer->fd);
	text_release(transfer->source);
	transfer_count--;
	free(transfer);
}
static void transfer_loop_destroy(struct wl_listener *listener, void *data) {
	(void)data;
	struct text_transfer *transfer = wl_container_of(listener, transfer, loop_destroy);
	transfer_finish(transfer);
}
static int transfer_timeout(void *data) { transfer_finish(data); return 0; }
static ssize_t write_without_sigpipe(int fd, const void *data, size_t length) {
	sigset_t blocked, previous, pending;
	sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE);
	pthread_sigmask(SIG_BLOCK, &blocked, &previous);
	sigpending(&pending);
	ssize_t result = write(fd, data, length);
	int saved_errno = errno;
	if (result < 0 && saved_errno == EPIPE && !sigismember(&pending, SIGPIPE)) {
		struct timespec zero = {0};
		while (sigtimedwait(&blocked, NULL, &zero) < 0 && errno == EINTR) {}
	}
	pthread_sigmask(SIG_SETMASK, &previous, NULL);
	errno = saved_errno;
	return result;
}
static int transfer_write(int fd, uint32_t mask, void *data) {
	struct text_transfer *transfer = data;
	if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) { transfer_finish(transfer); return 0; }
	size_t remaining = transfer->source->length - transfer->offset;
	if (remaining > 65536) remaining = 65536;
	ssize_t written = write_without_sigpipe(fd, transfer->source->text + transfer->offset, remaining);
	if (written > 0) transfer->offset += (size_t)written;
	if (transfer->offset == transfer->source->length ||
		(written < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
		transfer_finish(transfer);
	}
	return 0;
}
static void text_send(struct wlr_data_source *base, const char *mime, int32_t fd) {
	(void)mime;
	struct text_source *source = wl_container_of(base, source, base);
	if (transfer_count >= 32 || fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0) { close(fd); return; }
	struct text_transfer *transfer = calloc(1, sizeof(*transfer));
	if (!transfer) { close(fd); return; }
	transfer->source = source; transfer->fd = fd;
	source->references++; transfer_count++;
	transfer->loop_destroy.notify = transfer_loop_destroy;
	wl_event_loop_add_destroy_listener(source->loop, &transfer->loop_destroy);
	transfer->writable = wl_event_loop_add_fd(source->loop, fd, WL_EVENT_WRITABLE, transfer_write, transfer);
	transfer->timer = wl_event_loop_add_timer(source->loop, transfer_timeout, transfer);
	if (!transfer->writable || !transfer->timer) { transfer_finish(transfer); return; }
	wl_event_source_timer_update(transfer->timer, 2000);
}
static void text_destroy(struct wlr_data_source *base) {
	struct text_source *source = wl_container_of(base, source, base);
	text_release(source);
}
static const struct wlr_data_source_impl text_impl = {.send = text_send, .destroy = text_destroy};

struct wl_signal *ataxia_seat_event_set_selection(struct wlr_seat *seat) { return seat ? &seat->events.set_selection : NULL; }
uint32_t ataxia_seat_selection_mime_count(struct wlr_seat *seat) {
	return seat && seat->selection_source ? seat->selection_source->mime_types.size / sizeof(char *) : 0;
}
const char *ataxia_seat_selection_mime(struct wlr_seat *seat, uint32_t index) {
	if (index >= ataxia_seat_selection_mime_count(seat)) return NULL;
	return ((char **)seat->selection_source->mime_types.data)[index];
}
bool ataxia_seat_selection_receive(struct wlr_seat *seat, const char *mime, int fd) {
	for (uint32_t i = 0; mime && i < ataxia_seat_selection_mime_count(seat); i++) {
		if (strcmp(mime, ataxia_seat_selection_mime(seat, i)) == 0) {
			wlr_data_source_send(seat->selection_source, mime, fd);
			return true;
		}
	}
	close(fd);
	return false;
}
bool ataxia_seat_clipboard_owned(struct wlr_seat *seat) {
	return seat && seat->selection_source && seat->selection_source->impl == &text_impl;
}
bool ataxia_seat_set_clipboard_text(struct wlr_seat *seat, const char *text, size_t length) {
	if (!seat || !text || length > 4 * 1024 * 1024) return false;
	struct text_source *source = calloc(1, sizeof(*source));
	if (!source) return false;
	source->text = malloc(length + 1);
	if (!source->text) { free(source); return false; }
	memcpy(source->text, text, length); source->text[length] = '\0'; source->length = length;
	source->references = 1; source->loop = wl_display_get_event_loop(seat->display);
	wlr_data_source_init(&source->base, &text_impl);
	const char *mimes[] = {"text/plain;charset=utf-8", "text/plain", "UTF8_STRING"};
	for (size_t i = 0; i < sizeof(mimes) / sizeof(mimes[0]); i++) {
		char **entry = wl_array_add(&source->base.mime_types, sizeof(char *));
		if (!entry) { wlr_data_source_destroy(&source->base); return false; }
		*entry = strdup(mimes[i]);
		if (!*entry) { wlr_data_source_destroy(&source->base); return false; }
	}
	wlr_seat_set_selection(seat, &source->base, wl_display_next_serial(seat->display));
	return true;
}
