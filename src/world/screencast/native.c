/* Desktop portal / PipeWire transport. The compositor owns source selection and
 * pixels. This worker never calls Lisp, touches GL, or decides what to capture. */
#define _GNU_SOURCE
#include <gio/gio.h>
#include <glib-unix.h>
#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <sys/eventfd.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>

#define API __attribute__((visibility("default")))
#define BUS "org.freedesktop.impl.portal.desktop.ataxia"
#define SCREEN "org.freedesktop.impl.portal.ScreenCast"
#define SESSION "org.freedesktop.impl.portal.Session"
#define REQUEST "org.freedesktop.impl.portal.Request"

struct bridge;
struct session {
 struct bridge *bridge;
 struct session *next;
 gint references;
 uint32_t id, types, source_type, width, height;
 int32_t x, y;
 char *path, *sender, *client, *app, *request;
 guint registration, request_registration;
 bool selected, closed, starting, started;
 GDBusMethodInvocation *invocation;
 struct pw_stream *stream;
 struct spa_hook listener;
 uint8_t *pixels;
 uint32_t sequence;
};
struct event { uint32_t kind, id, types; char app[256]; };
struct command { uint32_t kind, id, type, width, height; int32_t x,y; uint8_t *pixels; size_t size; };
struct bridge {
 GMainContext *context;
 GMainLoop *main;
 GThread *thread;
 GDBusConnection *bus;
 GDBusNodeInfo *info;
 GMutex lock;
 GCond initialized;
 GQueue events, commands;
 int event_fd, command_fd, ready;
 guint registration, watch;
 GSource *commands_source, *pipewire_source;
 struct pw_loop *pw_loop;
 struct pw_context *pw_context;
 struct pw_core *core;
 struct session *sessions;
 uint32_t next_id;
};

static const char xml[] =
 "<node><interface name='" SCREEN "'>"
 "<property name='version' type='u' access='read'/>"
 "<property name='AvailableSourceTypes' type='u' access='read'/>"
 "<property name='AvailableCursorModes' type='u' access='read'/>"
 "<method name='CreateSession'><arg type='o' direction='in'/><arg type='o' direction='in'/>"
 "<arg type='s' direction='in'/><arg type='a{sv}' direction='in'/><arg type='u' direction='out'/><arg type='a{sv}' direction='out'/></method>"
 "<method name='SelectSources'><arg type='o' direction='in'/><arg type='o' direction='in'/>"
 "<arg type='s' direction='in'/><arg type='a{sv}' direction='in'/><arg type='u' direction='out'/><arg type='a{sv}' direction='out'/></method>"
 "<method name='Start'><arg type='o' direction='in'/><arg type='o' direction='in'/>"
 "<arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='a{sv}' direction='in'/>"
 "<arg type='u' direction='out'/><arg type='a{sv}' direction='out'/></method></interface>"
 "<interface name='" SESSION "'><property name='version' type='u' access='read'/><method name='Close'/>"
 "<signal name='Closed'/></interface>"
 "<interface name='" REQUEST "'><method name='Close'/></interface></node>";

static void response(GDBusMethodInvocation *inv, uint32_t code) {
 GVariantBuilder b; g_variant_builder_init(&b, G_VARIANT_TYPE_VARDICT);
 g_dbus_method_invocation_return_value(inv, g_variant_new("(ua{sv})", code, &b));
}
static struct session *session_ref(struct session *s) {
 g_atomic_int_inc(&s->references); return s;
}
static void session_unref(void *data) {
 struct session *s=data;
 if(!g_atomic_int_dec_and_test(&s->references)) return;
 g_free(s->path); g_free(s->sender); g_free(s->client); g_free(s->app); g_free(s->request); g_free(s->pixels); g_free(s);
}
static void event(struct bridge *b, struct session *s, uint32_t kind) {
 struct event *e = g_new0(struct event, 1);
 e->kind = kind; e->id = s->id; e->types = s->types;
 g_strlcpy(e->app, s->app, sizeof(e->app));
 g_mutex_lock(&b->lock); g_queue_push_tail(&b->events,e); g_mutex_unlock(&b->lock);
 if(eventfd_write(b->event_fd,1)<0 && errno!=EAGAIN) g_warning("Could not notify compositor of portal event");
}
static struct session *find_id(struct bridge *b, uint32_t id) {
 for(struct session *s=b->sessions;s;s=s->next) if(s->id==id) return s;
 return NULL;
}
static void close_session(struct session *s) {
 if(s->closed) return;
 s->closed=true;
 if(s->invocation) { response(s->invocation,1); g_clear_object(&s->invocation); }
 if(s->stream) { pw_stream_destroy(s->stream); s->stream=NULL; }
 g_clear_pointer(&s->pixels,g_free);
 if(s->request_registration) g_dbus_connection_unregister_object(s->bridge->bus,s->request_registration);
 s->request_registration=0;
 if(s->registration) {
  g_dbus_connection_emit_signal(s->bridge->bus,s->sender,s->path,SESSION,"Closed",NULL,NULL);
  g_dbus_connection_unregister_object(s->bridge->bus,s->registration);
  s->registration=0;
 }
 event(s->bridge,s,2);
 /* Queued GDBus calls retain the session through each registration's destroy
  * notifier. Owner commands carry IDs, so closing can retire list ownership. */
 struct session **link=&s->bridge->sessions;
 while(*link&&*link!=s) link=&(*link)->next;
 if(*link) { *link=s->next; session_unref(s); }
}
static GVariant *property(GDBusConnection *connection,const char *sender,const char *path,
 const char *interface,const char *name,GError **error,void *data) {
 (void)connection;(void)sender;(void)path;(void)error;(void)data;
 return g_variant_new_uint32(!strcmp(name,"version") ? (!strcmp(interface,SCREEN)?3:1) :
                            !strcmp(name,"AvailableSourceTypes") ? 3 : 1);
}
static void close_method(GDBusConnection *connection,const char *sender,const char *path,
 const char *interface,const char *method,GVariant *parameters,GDBusMethodInvocation *inv,void *data) {
 (void)connection;(void)path;(void)interface;(void)method;(void)parameters;
 struct session *s=data;
 if(strcmp(sender,s->sender)) { g_dbus_method_invocation_return_error_literal(inv,G_DBUS_ERROR,G_DBUS_ERROR_ACCESS_DENIED,"Session owner required"); return; }
 close_session(s);
 g_dbus_method_invocation_return_value(inv,NULL);
}
static const GDBusInterfaceVTable close_vtable={.method_call=close_method,.get_property=property};

static bool portal_sender(struct bridge *b,const char *sender) {
 GVariant *r=g_dbus_connection_call_sync(b->bus,"org.freedesktop.DBus","/org/freedesktop/DBus",
  "org.freedesktop.DBus","GetNameOwner",g_variant_new("(s)","org.freedesktop.portal.Desktop"),
  G_VARIANT_TYPE("(s)"),G_DBUS_CALL_FLAGS_NONE,1000,NULL,NULL);
 if(!r) return false;
 const char *owner; g_variant_get(r,"(&s)",&owner); bool ok=!strcmp(sender,owner); g_variant_unref(r); return ok;
}
static char *session_client(const char *handle) {
 /* The trusted frontend embeds the application's unique bus name in the
  * session path. The method sender is the frontend, not that application. */
 const char *prefix="/org/freedesktop/portal/desktop/session/";
 if(!g_str_has_prefix(handle,prefix)) return NULL;
 const char *begin=handle+strlen(prefix),*end=strchr(begin,'/');
 if(!end||end==begin) return NULL;
 char *client=g_strdup_printf(":%.*s",(int)(end-begin),begin);
 for(char *p=client;*p;p++) if(*p=='_') *p='.';
 if(!g_dbus_is_unique_name(client)) { g_free(client); return NULL; }
 return client;
}
static void method(GDBusConnection *connection,const char *sender,const char *path,
 const char *interface,const char *name,GVariant *parameters,GDBusMethodInvocation *inv,void *data) {
 (void)connection;(void)path;(void)interface;
 struct bridge *b=data;
 const char *request,*handle,*app,*parent=NULL; GVariant *options;
 if(!portal_sender(b,sender)) { g_dbus_method_invocation_return_error_literal(inv,G_DBUS_ERROR,G_DBUS_ERROR_ACCESS_DENIED,"Desktop portal required"); return; }
 if(!strcmp(name,"Start")) g_variant_get(parameters,"(&o&o&s&s@a{sv})",&request,&handle,&app,&parent,&options);
 else g_variant_get(parameters,"(&o&o&s@a{sv})",&request,&handle,&app,&options);
 (void)parent;
 struct session *s=NULL; unsigned prepared=0,active=0,client_prepared=0;
 char *client=session_client(handle);
 for(struct session *p=b->sessions;p;p=p->next) {
  if(!p->closed) {
   if(p->starting||p->started) active++;
   else { prepared++; if(client&&!g_strcmp0(client,p->client)) client_prepared++; }
   if(!strcmp(p->path,handle)) s=p;
  }
 }
 if(!strcmp(name,"CreateSession")) {
  /* Browsers can prepare several sessions while enumerating sources. Those
   * hold no pixels or PipeWire streams and must not consume the stream quota
   * or let one application's unused preparations block every other app. */
  if(s||!client||prepared>=128||client_prepared>=32) { response(inv,2); goto done; }
  s=g_new0(struct session,1); s->references=1; s->bridge=b; s->id=++b->next_id; s->types=1;
  s->path=g_strdup(handle); s->sender=g_strdup(sender); s->client=g_strdup(client); s->app=g_strdup(app);
  s->registration=g_dbus_connection_register_object(b->bus,handle,b->info->interfaces[1],&close_vtable,session_ref(s),session_unref,NULL);
  s->next=b->sessions; b->sessions=s;
  if(!s->registration) { session_unref(s); close_session(s); response(inv,2); goto done; }
  GVariantBuilder result; g_variant_builder_init(&result,G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&result,"{sv}","session_id",g_variant_new_string(handle));
  g_dbus_method_invocation_return_value(inv,g_variant_new("(ua{sv})",0,&result));
 } else if(!s||strcmp(s->sender,sender)||strcmp(s->app,app)||s->starting||s->started) response(inv,2);
 else if(!strcmp(name,"SelectSources")) {
  uint32_t types=1,cursor=1; g_variant_lookup(options,"types","u",&types); g_variant_lookup(options,"cursor_mode","u",&cursor);
  if(s->selected||!(types&3)||types&~3u||cursor!=1) { response(inv,2); close_session(s); }
  else { s->types=types; s->selected=true; response(inv,0); }
 } else if(!strcmp(name,"Start")&&s->selected) {
  if(active>=8) { response(inv,2); close_session(s); goto done; }
  s->request=g_strdup(request);
  s->request_registration=g_dbus_connection_register_object(b->bus,request,b->info->interfaces[2],&close_vtable,session_ref(s),session_unref,NULL);
  if(!s->request_registration) { session_unref(s); response(inv,2); goto done; }
  s->starting=true; s->invocation=g_object_ref(inv); event(b,s,1);
 } else response(inv,2);
done:
 g_free(client);
 g_variant_unref(options);
}
static const GDBusInterfaceVTable portal_vtable={.method_call=method,.get_property=property};

static void stream_state(void *data,enum pw_stream_state old,enum pw_stream_state state,const char *error) {
 (void)old;(void)error;
 struct session *s=data;
 if(s->closed) return;
 if(state==PW_STREAM_STATE_ERROR || (state==PW_STREAM_STATE_UNCONNECTED && old!=PW_STREAM_STATE_UNCONNECTED)) { event(s->bridge,s,3); return; }
 if(state==PW_STREAM_STATE_PAUSED&&s->invocation) {
  uint32_t node=pw_stream_get_node_id(s->stream); if(node==PW_ID_ANY) return;
  GVariantBuilder props,streams,result;
  g_variant_builder_init(&props,G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&props,"{sv}","size",g_variant_new("(ii)",s->width,s->height));
  g_variant_builder_add(&props,"{sv}","source_type",g_variant_new_uint32(s->source_type));
  if(s->source_type==1) g_variant_builder_add(&props,"{sv}","position",g_variant_new("(ii)",s->x,s->y));
  g_variant_builder_init(&streams,G_VARIANT_TYPE("a(ua{sv})"));
  g_variant_builder_add(&streams,"(ua{sv})",node,&props);
  g_variant_builder_init(&result,G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&result,"{sv}","streams",g_variant_builder_end(&streams));
  g_dbus_method_invocation_return_value(s->invocation,g_variant_new("(ua{sv})",0,&result));
  g_clear_object(&s->invocation);
  if(s->request_registration) g_dbus_connection_unregister_object(s->bridge->bus,s->request_registration);
  s->request_registration=0; s->started=true;
 }
}
static void stream_param(void *data,uint32_t id,const struct spa_pod *param) {
 struct session *s=data;
 if(!param||id!=SPA_PARAM_Format) return;
 uint8_t storage[256]; struct spa_pod_builder builder=SPA_POD_BUILDER_INIT(storage,sizeof(storage));
 const struct spa_pod *p=spa_pod_builder_add_object(&builder,SPA_TYPE_OBJECT_ParamBuffers,SPA_PARAM_Buffers,
  SPA_PARAM_BUFFERS_buffers,SPA_POD_CHOICE_RANGE_Int(4,2,8),
  SPA_PARAM_BUFFERS_blocks,SPA_POD_Int(1),
  SPA_PARAM_BUFFERS_size,SPA_POD_Int(s->width*s->height*4),
  SPA_PARAM_BUFFERS_stride,SPA_POD_Int(s->width*4),
  SPA_PARAM_BUFFERS_dataType,SPA_POD_CHOICE_FLAGS_Int(1<<SPA_DATA_MemFd));
 pw_stream_update_params(s->stream,&p,1);
}
static void stream_process(void *data) {
 struct session *s=data; struct pw_buffer *b=pw_stream_dequeue_buffer(s->stream);
 if(!b) return;
 struct spa_data *d=b->buffer->n_datas ? &b->buffer->datas[0] : NULL;
 size_t size=(size_t)s->width*s->height*4;
 if(d&&d->data&&d->chunk&&d->maxsize>=size&&s->pixels) {
  memcpy(d->data,s->pixels,size); d->chunk->offset=0; d->chunk->stride=s->width*4; d->chunk->size=size;
 } else if(d&&d->chunk) d->chunk->size=0;
 pw_stream_queue_buffer(s->stream,b);
}
static const struct pw_stream_events stream_events={PW_VERSION_STREAM_EVENTS,
 .state_changed=stream_state,.param_changed=stream_param,.process=stream_process};

static void accept_session(struct session *s,struct command *c) {
 if(!s->starting||s->started||s->stream||s->closed||!(s->types&c->type)||
    (c->type!=1&&c->type!=2)||!c->width||!c->height||c->width>3840||c->height>2160) { close_session(s); return; }
 struct bridge *b=s->bridge;
 if(!b->core) { close_session(s); return; }
 s->source_type=c->type; s->width=c->width; s->height=c->height; s->x=c->x; s->y=c->y;
 s->pixels=g_malloc0((size_t)s->width*s->height*4);
 s->stream=pw_stream_new(b->core,"Ataxia screen sharing",pw_properties_new(
  PW_KEY_MEDIA_TYPE,"Video",PW_KEY_MEDIA_CATEGORY,"Capture",PW_KEY_MEDIA_ROLE,"Screen",
  PW_KEY_MEDIA_CLASS,"Video/Source",PW_KEY_NODE_DESCRIPTION,"Ataxia selected source",NULL));
 if(!s->stream) { close_session(s); return; }
 pw_stream_add_listener(s->stream,&s->listener,&stream_events,s);
 uint8_t storage[512]; struct spa_pod_builder builder=SPA_POD_BUILDER_INIT(storage,sizeof(storage));
 struct spa_video_info_raw video={.format=SPA_VIDEO_FORMAT_RGBA,.size=SPA_RECTANGLE(s->width,s->height),.framerate=SPA_FRACTION(30,1)};
 const struct spa_pod *format=spa_format_video_raw_build(&builder,SPA_PARAM_EnumFormat,&video);
 if(pw_stream_connect(s->stream,PW_DIRECTION_OUTPUT,PW_ID_ANY,
    PW_STREAM_FLAG_DRIVER|PW_STREAM_FLAG_MAP_BUFFERS,&format,1)<0) close_session(s);
}
static void free_command(struct command *c) { g_free(c->pixels); g_free(c); }
static gboolean commands_ready(gint fd,GIOCondition condition,gpointer data) {
 (void)condition; struct bridge *b=data; eventfd_t count;
 if(eventfd_read(fd,&count)<0 && errno!=EAGAIN) return G_SOURCE_REMOVE;
 for(;;) {
  g_mutex_lock(&b->lock); struct command *c=g_queue_pop_head(&b->commands); g_mutex_unlock(&b->lock);
  if(!c) break;
  if(c->kind==4) { free_command(c); g_main_loop_quit(b->main); return G_SOURCE_CONTINUE; }
  struct session *s=find_id(b,c->id);
  if(s&&!s->closed) {
   if(c->kind==1) accept_session(s,c);
   else if(c->kind==2) close_session(s);
   else if(c->kind==3&&s->pixels&&c->size==(size_t)s->width*s->height*4) {
    g_free(s->pixels); s->pixels=c->pixels; c->pixels=NULL;
    if(s->stream) pw_stream_trigger_process(s->stream);
   }
  }
  free_command(c);
 }
 return G_SOURCE_CONTINUE;
}
static gboolean pipewire_ready(gint fd,GIOCondition condition,gpointer data) {
 (void)fd;(void)condition; struct bridge *b=data; pw_loop_iterate(b->pw_loop,0); return G_SOURCE_CONTINUE;
}
static void owner_changed(GDBusConnection *bus,const char *sender,const char *path,const char *interface,
 const char *signal,GVariant *parameters,void *data) {
 (void)bus;(void)sender;(void)path;(void)interface;(void)signal;
 struct bridge *b=data; const char *name,*old,*now; g_variant_get(parameters,"(&s&s&s)",&name,&old,&now);
 if(*old&&!*now) for(struct session *s=b->sessions;s;) {
  struct session *next=s->next;
  if(!strcmp(s->sender,name)||!g_strcmp0(s->client,name)) close_session(s);
  s=next;
 }
}
static gpointer worker(gpointer data) {
 struct bridge *b=data; g_main_context_push_thread_default(b->context);
 b->bus=g_bus_get_sync(G_BUS_TYPE_SESSION,NULL,NULL);
 b->info=g_dbus_node_info_new_for_xml(xml,NULL);
 if(b->bus&&b->info) {
  GVariant *r=g_dbus_connection_call_sync(b->bus,"org.freedesktop.DBus","/org/freedesktop/DBus",
   "org.freedesktop.DBus","RequestName",g_variant_new("(su)",BUS,4u),G_VARIANT_TYPE("(u)"),0,3000,NULL,NULL);
  uint32_t result=0; if(r) { g_variant_get(r,"(u)",&result); g_variant_unref(r); }
  if(result==1) b->registration=g_dbus_connection_register_object(b->bus,"/org/freedesktop/portal/desktop",b->info->interfaces[0],&portal_vtable,b,NULL,NULL);
 }
 if(b->registration) {
  b->watch=g_dbus_connection_signal_subscribe(b->bus,"org.freedesktop.DBus","org.freedesktop.DBus","NameOwnerChanged",NULL,NULL,0,owner_changed,b,NULL);
  b->pw_loop=pw_loop_new(NULL);
  if(b->pw_loop) {
   pw_loop_enter(b->pw_loop); b->pw_context=pw_context_new(b->pw_loop,NULL,0);
   if(b->pw_context) b->core=pw_context_connect(b->pw_context,NULL,0);
   b->pipewire_source=g_unix_fd_source_new(pw_loop_get_fd(b->pw_loop),G_IO_IN);
   g_source_set_callback(b->pipewire_source,G_SOURCE_FUNC(pipewire_ready),b,NULL);
   g_source_attach(b->pipewire_source,b->context);
  }
  b->commands_source=g_unix_fd_source_new(b->command_fd,G_IO_IN);
  g_source_set_callback(b->commands_source,G_SOURCE_FUNC(commands_ready),b,NULL);
  g_source_attach(b->commands_source,b->context);
 }
 g_mutex_lock(&b->lock); b->ready=b->registration?1:-1; g_cond_signal(&b->initialized); g_mutex_unlock(&b->lock);
 if(b->registration) g_main_loop_run(b->main);
 while(b->sessions) close_session(b->sessions);
 if(b->commands_source) {g_source_destroy(b->commands_source);g_source_unref(b->commands_source);}
 if(b->pipewire_source) {g_source_destroy(b->pipewire_source);g_source_unref(b->pipewire_source);}
 if(b->core) pw_core_disconnect(b->core);
 if(b->pw_context) pw_context_destroy(b->pw_context);
 if(b->pw_loop) {pw_loop_leave(b->pw_loop);pw_loop_destroy(b->pw_loop);}
 if(b->bus) {
  if(b->watch) g_dbus_connection_signal_unsubscribe(b->bus,b->watch);
  if(b->registration) {
   g_dbus_connection_unregister_object(b->bus,b->registration);
   GVariant *r=g_dbus_connection_call_sync(b->bus,"org.freedesktop.DBus","/org/freedesktop/DBus","org.freedesktop.DBus","ReleaseName",g_variant_new("(s)",BUS),NULL,0,1000,NULL,NULL); if(r)g_variant_unref(r);
  }
  g_object_unref(b->bus);
 }
 if(b->info) g_dbus_node_info_unref(b->info);
 g_main_context_pop_thread_default(b->context); return NULL;
}
static void enqueue(struct bridge *b,struct command *c) {
 g_mutex_lock(&b->lock);
 /* Replace queued frames from the same session rather than accumulating them. */
 if(c->kind==3) for(GList *p=b->commands.head;p;p=p->next) {
  struct command *old=p->data;
  if(old->kind==3&&old->id==c->id) {p->data=c;free_command(old);g_mutex_unlock(&b->lock);return;}
 }
 g_queue_push_tail(&b->commands,c);g_mutex_unlock(&b->lock);
 if(eventfd_write(b->command_fd,1)<0 && errno!=EAGAIN) g_warning("Could not notify portal worker");
}
API void ataxia_screencast_destroy(struct bridge *b);
API struct bridge *ataxia_screencast_create(void) {
 pw_init(NULL,NULL);
 struct bridge *b=g_new0(struct bridge,1);g_mutex_init(&b->lock);g_cond_init(&b->initialized);
 b->event_fd=eventfd(0,EFD_CLOEXEC|EFD_NONBLOCK);b->command_fd=eventfd(0,EFD_CLOEXEC|EFD_NONBLOCK);
 if(b->event_fd<0 || b->command_fd<0) {
  if(b->event_fd>=0) close(b->event_fd);
  if(b->command_fd>=0) close(b->command_fd);
  g_cond_clear(&b->initialized);g_mutex_clear(&b->lock);g_free(b);return NULL;
 }
 b->context=g_main_context_new();b->main=g_main_loop_new(b->context,FALSE);
 b->thread=g_thread_new("ataxia-portal",worker,b);
 g_mutex_lock(&b->lock);while(!b->ready)g_cond_wait(&b->initialized,&b->lock);g_mutex_unlock(&b->lock);
 if(b->ready<0){ataxia_screencast_destroy(b);return NULL;}return b;
}
API int ataxia_screencast_fd(struct bridge *b){return b->event_fd;}
API int ataxia_screencast_next(struct bridge *b,struct event *result){
 eventfd_t count;
 if(eventfd_read(b->event_fd,&count)<0 && errno!=EAGAIN) return 0;
 g_mutex_lock(&b->lock);struct event *e=g_queue_pop_head(&b->events);g_mutex_unlock(&b->lock);
 if(!e)return 0;
 *result=*e;g_free(e);return 1;
}
API void ataxia_screencast_accept(struct bridge *b,uint32_t id,uint32_t type,int32_t x,int32_t y,uint32_t w,uint32_t h){
 struct command *c=g_new0(struct command,1);c->kind=1;c->id=id;c->type=type;c->x=x;c->y=y;c->width=w;c->height=h;enqueue(b,c);
}
API void ataxia_screencast_close(struct bridge *b,uint32_t id){struct command *c=g_new0(struct command,1);c->kind=2;c->id=id;enqueue(b,c);}
API void ataxia_screencast_submit(struct bridge *b,uint32_t id,const uint8_t *pixels,size_t size){
 if(size>3840u*2160u*4u)return;
 struct command *c=g_new0(struct command,1);c->kind=3;c->id=id;c->size=size;c->pixels=g_memdup2(pixels,size);enqueue(b,c);
}
API void ataxia_screencast_destroy(struct bridge *b){
 if(!b)return;
 if(b->ready>0){struct command *c=g_new0(struct command,1);c->kind=4;enqueue(b,c);}
 g_thread_join(b->thread);
 g_queue_clear_full(&b->commands,(GDestroyNotify)free_command);g_queue_clear_full(&b->events,g_free);
 close(b->event_fd);close(b->command_fd);g_main_loop_unref(b->main);g_main_context_unref(b->context);
 g_cond_clear(&b->initialized);g_mutex_clear(&b->lock);g_free(b);
}
