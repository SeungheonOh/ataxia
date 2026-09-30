#pragma once
#include <stdint.h>
#include <pthread.h>
#include <errno.h>
#include <sys/socket.h>
#include <unistd.h>
#include <string.h>

// Private, same-build local IPC. No network listener or browser engine in Lisp.
#define WEB_ABI 2
#define WEB_MAX_SIDE 4096
#define WEB_PIXELS ((size_t)WEB_MAX_SIDE * WEB_MAX_SIDE * 4)
#define WEB_TEXT 60000
#define WEB_EVENTS 32
struct WebEvent { char name[80]; char value[8192]; };
struct WebShared {
    pthread_mutex_t mutex;
    uint64_t revision, paints, gpu_paints, skipped;
    int accelerated, popup_visible, popup_x, popup_y;
    int width, height, x, y, right, bottom, dirty;
    unsigned event_read, event_write, dropped;
    struct WebEvent events[WEB_EVENTS];
    unsigned char pixels[];
};
#define WEB_MAP_SIZE (sizeof(struct WebShared) + WEB_PIXELS)
enum WebOp { WEB_CREATE=1, WEB_CLOSE, WEB_RESIZE, WEB_VISIBLE, WEB_FOCUS,
             WEB_MOVE, WEB_BUTTON, WEB_SCROLL, WEB_KEY, WEB_TEXT_INPUT,
             WEB_EVAL, WEB_LOAD, WEB_STOP, WEB_MODIFIERS, WEB_RELEASE };
struct WebCommand { int op, id, a, b, c, d; double scale; char text[WEB_TEXT]; };
static inline int web_lock(struct WebShared *s, int try_only) {
    int e = try_only ? pthread_mutex_trylock(&s->mutex) : pthread_mutex_lock(&s->mutex);
    if (e == EOWNERDEAD) { pthread_mutex_consistent(&s->mutex); return 0; }
    return e;
}
static inline void web_signal(int fd) { uint64_t n=1; (void)!write(fd,&n,sizeof n); }
static inline int web_send(int socket, const struct WebCommand *cmd, int fd) {
    struct iovec io = { (void*)cmd, sizeof(*cmd) - WEB_TEXT + strlen(cmd->text)+1 };
    char control[CMSG_SPACE(sizeof(int))] = {0};
    struct msghdr msg = {0}; msg.msg_iov=&io; msg.msg_iovlen=1;
    if (fd>=0) {
        msg.msg_control=control; msg.msg_controllen=sizeof control;
        struct cmsghdr *c=CMSG_FIRSTHDR(&msg); c->cmsg_level=SOL_SOCKET; c->cmsg_type=SCM_RIGHTS;
        c->cmsg_len=CMSG_LEN(sizeof(int)); memcpy(CMSG_DATA(c),&fd,sizeof fd);
    }
    return sendmsg(socket,&msg,MSG_NOSIGNAL|MSG_DONTWAIT)==(ssize_t)io.iov_len;
}
