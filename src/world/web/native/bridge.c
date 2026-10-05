#define _GNU_SOURCE
#include "protocol.h"
#include "dmabuf.h"
#include <GLES3/gl3.h>
#include <sys/mman.h>
#include <sys/eventfd.h>
#include <sys/wait.h>
#include <spawn.h>
#include <stdlib.h>
#include <stdio.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <ftw.h>
extern char **environ;
#define API __attribute__((visibility("default")))
struct Component;
struct Engine { struct Component *components; int failed; int socket, wake; pid_t pid; unsigned next; char cache[128]; };
struct Frame { struct WebBuffer buffer; int fds[WEB_PLANES],valid,fence; GLuint texture; EGLImageKHR image; EGLDisplay display; };
struct Imported { int token,width,height; GLuint texture; EGLImageKHR image; EGLDisplay display; };
struct Layer { struct Frame front,pending; struct Imported cache[3]; };
struct Component { struct Engine *engine; struct Component *next; struct WebShared *shared; int id; GLuint texture; int width,height; uint64_t uploads,bytes,imports; struct Layer layers[2]; };
static int receive_frames(struct Engine *e);
static _Thread_local char error_text[256];
static void fail(const char *what) { snprintf(error_text,sizeof error_text,"%s: %s",what,strerror(errno)); }
API const char *ataxia_web_error(void) { return error_text; }
API int ataxia_web_abi(void) { return WEB_ABI; }
API struct Engine *ataxia_web_engine_create_for_display(const char *helper,const char *display) {
    struct Engine *e=calloc(1,sizeof *e); int sv[2];
    if (!e) return NULL;
    if (socketpair(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC,0,sv)<0) { fail("socketpair"); free(e); return NULL; }
    e->socket=sv[0]; e->wake=eventfd(0,EFD_CLOEXEC|EFD_NONBLOCK);
    if (e->wake<0) { fail("eventfd"); close(sv[0]); close(sv[1]); free(e); return NULL; }
    posix_spawn_file_actions_t acts; posix_spawn_file_actions_init(&acts);
    // POSIX spawn dup2(fd, fd) clears CLOEXEC in the child. Keeping the original
    // numbers avoids collisions when the compositor already owns hundreds of FDs.
    posix_spawn_file_actions_adddup2(&acts,sv[1],sv[1]);
    posix_spawn_file_actions_adddup2(&acts,e->wake,e->wake);
    strcpy(e->cache,"/tmp/ataxia-web-engine-XXXXXX");
    if(!mkdtemp(e->cache)) { fail("browser cache directory"); posix_spawn_file_actions_destroy(&acts); close(sv[0]); close(sv[1]); close(e->wake); free(e); return NULL; }
    char cache_arg[160]; snprintf(cache_arg,sizeof cache_arg,"--ataxia-cache-dir=%s",e->cache);
    char command_arg[48],wake_arg[48];
    snprintf(command_arg,sizeof command_arg,"--ataxia-command-fd=%d",sv[1]);
    snprintf(wake_arg,sizeof wake_arg,"--ataxia-wake-fd=%d",e->wake);
    char display_arg[256];
    if(display && strlen(display)>=sizeof display_arg-26) {
        snprintf(error_text,sizeof error_text,"Wayland display name is too long");
        posix_spawn_file_actions_destroy(&acts); close(sv[0]); close(sv[1]); close(e->wake); rmdir(e->cache); free(e); return NULL;
    }
    snprintf(display_arg,sizeof display_arg,"--ataxia-wayland-display=%s",display?display:"");
    char *argv[]={(char*)helper,command_arg,wake_arg,cache_arg,display_arg,NULL};
    posix_spawnattr_t attrs; posix_spawnattr_init(&attrs);
    posix_spawnattr_setflags(&attrs,POSIX_SPAWN_SETPGROUP); posix_spawnattr_setpgroup(&attrs,0);
    int result=posix_spawn(&e->pid,helper,&acts,&attrs,argv,environ); posix_spawnattr_destroy(&attrs);
    posix_spawn_file_actions_destroy(&acts); close(sv[1]);
    if (result) { errno=result; fail("start web helper"); close(e->socket); close(e->wake); rmdir(e->cache); free(e); return NULL; }
    return e;
}
API int ataxia_web_engine_fd(struct Engine *e) { return e->wake; }
API int ataxia_web_engine_socket(struct Engine *e) { return e->socket; }
API int ataxia_web_engine_pid(struct Engine *e) { return e->pid; }
API void ataxia_web_engine_drain(struct Engine *e) { uint64_t n; (void)!read(e->wake,&n,sizeof n); receive_frames(e); }
API int ataxia_web_engine_receive(struct Engine *e) { return receive_frames(e); }
static int remove_cache_entry(const char *path,const struct stat *st,int type,struct FTW *entry) {
    (void)st; (void)type; (void)entry; return remove(path);
}
static void *reap(void *p) {
    // Shutdown-only deadline, never an idle browser timer or an owner-thread wait.
    struct Engine *e=p; pid_t pid=e->pid; struct timespec delay={.tv_nsec=50000000}; int finished=0;
    for(int n=0;n<100;n++) {
        int status=0; int result=waitpid(pid,&status,WNOHANG);
        if(result==pid && WIFSIGNALED(status))fprintf(stderr,"Ataxia browser helper %d exited with signal %d\n",pid,WTERMSIG(status));
        else if(result==pid && WIFEXITED(status)&&WEXITSTATUS(status))fprintf(stderr,"Ataxia browser helper %d exited with status %d\n",pid,WEXITSTATUS(status));
        if(result==pid || (result<0 && errno!=EINTR)) { finished=1; break; }
        if(n==40) kill(-pid,SIGTERM);
        nanosleep(&delay,NULL);
    }
    if(!finished) { kill(-pid,SIGKILL); while(waitpid(pid,NULL,0)<0 && errno==EINTR) {} }
    nftw(e->cache,remove_cache_entry,16,FTW_DEPTH|FTW_PHYS); free(e); return NULL;
}
API void ataxia_web_engine_destroy(struct Engine *e) {
    if (!e) return;
    for(struct Component *c=e->components;c;c=c->next)c->engine=NULL;
    struct WebCommand cmd={.op=WEB_STOP}; web_send(e->socket,&cmd,-1);
    shutdown(e->socket,SHUT_RDWR); close(e->socket); close(e->wake);
    pthread_t thread;
    if (!pthread_create(&thread,NULL,reap,e)) pthread_detach(thread);
    else { kill(-e->pid,SIGTERM); free(e); }
}
API int ataxia_web_command(struct Component *c,int op,int a,int b,int d,int f,double scale,const char *text) {
    if (strlen(text)>=WEB_TEXT) { snprintf(error_text,sizeof error_text,"Web command exceeds %d UTF-8 bytes",WEB_TEXT-1); return 0; }
    struct WebCommand cmd={.op=op,.id=c->id,.a=a,.b=b,.c=d,.d=f,.scale=scale};
    strcpy(cmd.text,text);
    if (!web_send(c->engine->socket,&cmd,-1)) { fail("web command queue"); return 0; }
    return 1;
}
API struct Component *ataxia_web_create(struct Engine *e,int width,int height,double scale,const char *url) {
    if (width<1 || height<1 || width*scale>WEB_MAX_SIDE || height*scale>WEB_MAX_SIDE || strlen(url)>=WEB_TEXT) {
        snprintf(error_text,sizeof error_text,"Web view size or URL exceeds adapter limits"); return NULL;
    }
    struct Component *c=calloc(1,sizeof *c); if(!c) return NULL;
    int fd=memfd_create("ataxia-web-view",MFD_CLOEXEC);
    if(fd<0 || ftruncate(fd,WEB_MAP_SIZE)<0) { fail("web view memory"); if(fd>=0)close(fd); free(c); return NULL; }
    c->shared=mmap(NULL,WEB_MAP_SIZE,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if(c->shared==MAP_FAILED) { fail("map web view"); close(fd); free(c); return NULL; }
    pthread_mutexattr_t attr; pthread_mutexattr_init(&attr);
    pthread_mutexattr_setpshared(&attr,PTHREAD_PROCESS_SHARED); pthread_mutexattr_setrobust(&attr,PTHREAD_MUTEX_ROBUST);
    pthread_mutex_init(&c->shared->mutex,&attr); pthread_mutexattr_destroy(&attr);
    c->engine=e; c->id=++e->next;
    struct WebCommand cmd={.op=WEB_CREATE,.id=c->id,.a=width,.b=height,.scale=scale}; strcpy(cmd.text,url);
    if(!web_send(e->socket,&cmd,fd)) { fail("create web view"); munmap(c->shared,WEB_MAP_SIZE); free(c); c=NULL; }
    if(c){c->next=e->components;e->components=c;}
    close(fd); return c;
}
static int release_frame(struct Component *c,struct Frame *f,int sampled) {
    if(!f->valid)return 1;
    if(sampled && f->texture){
        if(f->fence>=0)close(f->fence);
        f->fence=web_export_fence();
        if(f->fence<0){snprintf(error_text,sizeof error_text,"Cannot export consumer DMA-BUF fence");if(c->engine)c->engine->failed=1;return 0;}
    }
    struct WebCommand cmd={.op=WEB_RELEASE,.id=c->id,.a=f->buffer.layer,.b=f->buffer.token};
    int ok=!c->engine||c->engine->failed||web_send(c->engine->socket,&cmd,f->fence);
    if(!ok){fail("release browser DMA-BUF");c->engine->failed=1;}
    if(f->fence>=0)close(f->fence);
    for(int p=0;p<f->buffer.planes;p++)close(f->fds[p]);
    memset(f,0,sizeof *f);return ok;
}
static int receive_frames(struct Engine *e) {
    if(e->failed)return -1;
    for(;;){
        struct Frame frame={.fence=-1};char control[CMSG_SPACE(sizeof(int)*WEB_PLANES)]={0};
        struct iovec io={&frame.buffer,sizeof frame.buffer};struct msghdr msg={0};msg.msg_iov=&io;msg.msg_iovlen=1;msg.msg_control=control;msg.msg_controllen=sizeof control;
        ssize_t size=recvmsg(e->socket,&msg,MSG_DONTWAIT|MSG_CMSG_CLOEXEC);
        if(size<0&&errno==EINTR)continue;
        if(size<0&&(errno==EAGAIN||errno==EWOULDBLOCK))return 0;
        if(size<=0){if(size==0)snprintf(error_text,sizeof error_text,"Browser command channel closed");else fail("receive browser frame");return -1;}
        int count=0;for(struct cmsghdr *h=CMSG_FIRSTHDR(&msg);h;h=CMSG_NXTHDR(&msg,h))if(h->cmsg_level==SOL_SOCKET&&h->cmsg_type==SCM_RIGHTS){int n=(h->cmsg_len-CMSG_LEN(0))/sizeof(int);for(int p=0;p<n;p++){int fd;memcpy(&fd,(int*)CMSG_DATA(h)+p,sizeof fd);if(count<WEB_PLANES)frame.fds[count++]=fd;else close(fd);}}
        struct WebBuffer *b=&frame.buffer;
        if(size!=sizeof *b||(msg.msg_flags&(MSG_TRUNC|MSG_CTRUNC))||b->planes!=count||count<1||b->layer<0||b->layer>1||b->width<1||b->height<1||b->width>WEB_MAX_SIDE||b->height>WEB_MAX_SIDE){for(int p=0;p<count;p++)close(frame.fds[p]);snprintf(error_text,sizeof error_text,"Invalid browser DMA-BUF packet");return -1;}
        frame.valid=1;struct Component *c=e->components;while(c&&c->id!=b->id)c=c->next;
        if(!c){for(int p=0;p<count;p++)close(frame.fds[p]);continue;}
        if(!release_frame(c,&c->layers[b->layer].pending,0))return -1;
        c->layers[b->layer].pending=frame;
    }
}
API void ataxia_web_destroy(struct Component *c,int notify) {
    if (!c) return;
    if(notify) ataxia_web_command(c,WEB_CLOSE,0,0,0,0,0,"");
    for(int p=0;p<2;p++){release_frame(c,&c->layers[p].pending,0);release_frame(c,&c->layers[p].front,0);}
    if(c->engine){struct Component **at=&c->engine->components;while(*at&&*at!=c)at=&(*at)->next;if(*at)*at=c->next;}
    munmap(c->shared,WEB_MAP_SIZE); free(c);
}
API int ataxia_web_dirty(struct Component *c) { return c->layers[0].pending.valid||c->layers[1].pending.valid||__atomic_load_n(&c->shared->dirty,__ATOMIC_ACQUIRE); }
API uint64_t ataxia_web_paints(struct Component *c) { return __atomic_load_n(&c->shared->paints,__ATOMIC_RELAXED); }
API unsigned ataxia_web_dropped(struct Component *c) { return __atomic_load_n(&c->shared->dropped,__ATOMIC_RELAXED); }
API uint64_t ataxia_web_uploads(struct Component *c) { return c->uploads; }
API uint64_t ataxia_web_uploaded_bytes(struct Component *c) { return c->bytes; }
API int ataxia_web_event(struct Component *c,char *name,char *value) {
    struct WebShared *s=c->shared;
    if(web_lock(s,1)) { web_signal(c->engine->wake); return 0; }
    int found=s->event_read!=s->event_write;
    if(found) { struct WebEvent *ev=&s->events[s->event_read++ % WEB_EVENTS]; strcpy(name,ev->name); strcpy(value,ev->value); }
    pthread_mutex_unlock(&s->mutex); return found;
}
API int ataxia_web_transport(struct Component *c) {return __atomic_load_n(&c->shared->accelerated,__ATOMIC_ACQUIRE);}
API uint64_t ataxia_web_gpu_copies(struct Component *c) {return __atomic_load_n(&c->shared->gpu_paints,__ATOMIC_RELAXED);}
API uint64_t ataxia_web_gpu_imports(struct Component *c) {return c->imports;}
API uint64_t ataxia_web_skipped(struct Component *c) {return __atomic_load_n(&c->shared->skipped,__ATOMIC_RELAXED);}
// The only GL work happens under the existing drawable graphics scope.
// A clean component exits before even querying GL state.
static int upload_bitmap(struct Component *c,int *rect) {
    struct WebShared *s=c->shared;
    if(c->texture && !ataxia_web_dirty(c)) return 0;
    if(web_lock(s,1)) return 0;
    if(s->width<=0 || s->height<=0) { pthread_mutex_unlock(&s->mutex); return 0; }
    GLint texture,unpack,row,pbo,skip_pixels,skip_rows; glGetIntegerv(GL_TEXTURE_BINDING_2D,&texture);
    glGetIntegerv(GL_UNPACK_ALIGNMENT,&unpack); glGetIntegerv(GL_UNPACK_ROW_LENGTH,&row);
    glGetIntegerv(GL_UNPACK_SKIP_PIXELS,&skip_pixels); glGetIntegerv(GL_UNPACK_SKIP_ROWS,&skip_rows);
    glPixelStorei(GL_UNPACK_SKIP_PIXELS,0); glPixelStorei(GL_UNPACK_SKIP_ROWS,0);
    glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING,&pbo); glBindBuffer(GL_PIXEL_UNPACK_BUFFER,0);
    glPixelStorei(GL_UNPACK_ALIGNMENT,1); glPixelStorei(GL_UNPACK_ROW_LENGTH,s->width);
    if(!c->texture) glGenTextures(1,&c->texture);
    glBindTexture(GL_TEXTURE_2D,c->texture);
    int x=s->x,y=s->y,w=s->right-x,h=s->bottom-y;
    if(c->width!=s->width || c->height!=s->height) {
        c->width=s->width; c->height=s->height; x=y=0; w=s->width; h=s->height;
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,w,h,0,GL_RGBA,GL_UNSIGNED_BYTE,s->pixels);
    } else glTexSubImage2D(GL_TEXTURE_2D,0,x,y,w,h,GL_RGBA,GL_UNSIGNED_BYTE,s->pixels+((size_t)y*s->width+x)*4);
    c->uploads++; c->bytes+=(uint64_t)w*h*4;
    __atomic_store_n(&s->dirty,0,__ATOMIC_RELEASE);
    pthread_mutex_unlock(&s->mutex);
    glBindTexture(GL_TEXTURE_2D,texture); glPixelStorei(GL_UNPACK_ALIGNMENT,unpack);
    glPixelStorei(GL_UNPACK_ROW_LENGTH,row); glBindBuffer(GL_PIXEL_UNPACK_BUFFER,pbo);
    glPixelStorei(GL_UNPACK_SKIP_PIXELS,skip_pixels); glPixelStorei(GL_UNPACK_SKIP_ROWS,skip_rows);
    rect[0]=x;rect[1]=y;rect[2]=w;rect[3]=h; return 1;
}
static int import_frame(struct Component *c,struct Frame *f,GLint *binding) {
    struct Layer *l=&c->layers[f->buffer.layer];struct Imported *slot=NULL;
    for(int i=0;i<3;i++){
        struct Imported *old=&l->cache[i];
        if(old->texture&&(old->width!=f->buffer.width||old->height!=f->buffer.height)){
            if((GLuint)*binding==old->texture)*binding=0;
            glDeleteTextures(1,&old->texture);web_destroy_image(old->display,old->image);memset(old,0,sizeof *old);
        }
    }
    for(int i=0;i<3;i++)if(l->cache[i].token==f->buffer.token){f->texture=l->cache[i].texture;return 1;}
    for(int i=0;i<3;i++)if(!l->cache[i].texture){slot=&l->cache[i];break;}
    if(!slot)slot=&l->cache[f->buffer.token%3];
    if(slot->texture){if((GLuint)*binding==slot->texture)*binding=0;glDeleteTextures(1,&slot->texture);}
    web_destroy_image(slot->display,slot->image);memset(slot,0,sizeof *slot);
    slot->display=eglGetCurrentDisplay();slot->image=web_import(slot->display,&f->buffer,f->fds);
    if(!slot->image){snprintf(error_text,sizeof error_text,"Cannot import browser DMA-BUF into compositor EGL display (0x%x)",eglGetError());return 0;}
    glGenTextures(1,&slot->texture);glBindTexture(GL_TEXTURE_2D,slot->texture);web_bind_image(slot->image);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
    slot->token=f->buffer.token;slot->width=f->buffer.width;slot->height=f->buffer.height;f->texture=slot->texture;c->imports++;return 1;
}
API int ataxia_web_upload(struct Component *c,int *rect) {
    if(!ataxia_web_transport(c))return upload_bitmap(c,rect);
    if(c->engine&&c->engine->failed)return -1;
    int changed=ataxia_web_dirty(c);
    if(!changed&&c->layers[0].front.texture)return 0;
    GLint binding;glGetIntegerv(GL_TEXTURE_BINDING_2D,&binding);
    for(int p=0;p<2;p++){
        struct Layer *l=&c->layers[p];
        if(l->pending.valid){
            if(!release_frame(c,&l->front,1)){glBindTexture(GL_TEXTURE_2D,binding);return -1;}
            l->front=l->pending;memset(&l->pending,0,sizeof l->pending);
        }
        if(l->front.valid&&!l->front.texture){if(!import_frame(c,&l->front,&binding)){glBindTexture(GL_TEXTURE_2D,binding);return -1;}changed=1;}
    }
    glBindTexture(GL_TEXTURE_2D,binding);
    struct Frame *f=&c->layers[0].front;c->width=f->buffer.width;c->height=f->buffer.height;
    __atomic_store_n(&c->shared->dirty,0,__ATOMIC_RELEASE);
    rect[0]=rect[1]=0;rect[2]=c->width;rect[3]=c->height;return changed&&f->valid;
}
API unsigned ataxia_web_texture(struct Component *c) { return ataxia_web_transport(c)?c->layers[0].front.texture:c->texture; }
API unsigned ataxia_web_popup_texture(struct Component *c) { return __atomic_load_n(&c->shared->popup_visible,__ATOMIC_ACQUIRE)?c->layers[1].front.texture:0; }
API int ataxia_web_popup_x(struct Component *c) {return __atomic_load_n(&c->shared->popup_x,__ATOMIC_ACQUIRE);}
API int ataxia_web_popup_y(struct Component *c) {return __atomic_load_n(&c->shared->popup_y,__ATOMIC_ACQUIRE);}
API int ataxia_web_popup_width(struct Component *c) {return c->layers[1].front.buffer.width;}
API int ataxia_web_popup_height(struct Component *c) {return c->layers[1].front.buffer.height;}
API int ataxia_web_width(struct Component *c) { return c->width; }
API int ataxia_web_height(struct Component *c) { return c->height; }
API void ataxia_web_detach(struct Component *c) {
    for(int p=0;p<2;p++){
        struct Frame *f=&c->layers[p].front;
        if(f->texture){if(f->fence>=0)close(f->fence);f->fence=web_export_fence();
            if(f->fence<0){snprintf(error_text,sizeof error_text,"Cannot export detached browser fence");if(c->engine)c->engine->failed=1;}
            f->texture=0;}
        for(int i=0;i<3;i++){
            struct Imported *cached=&c->layers[p].cache[i];
            if(cached->texture)glDeleteTextures(1,&cached->texture);
            web_destroy_image(cached->display,cached->image);memset(cached,0,sizeof *cached);
        }
    }
    if(c->texture) glDeleteTextures(1,&c->texture);
    c->texture=0; c->width=c->height=0;
}
