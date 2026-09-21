// An ordinary Wayland client. Generated RML never enters the compositor process.
#include "xdg-shell-client.h"
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <wayland-client.h>
#include <wayland-egl.h>
#include <xkbcommon/xkbcommon.h>
#include <expat.h>
#include <algorithm>
#include <cerrno>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <poll.h>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <sys/resource.h>
#include <unistd.h>
#include <vector>

extern "C" {
bool ataxia_rmlui_initialize();
bool ataxia_rmlui_set_asset_root(const char *);
const char *ataxia_rmlui_last_error();
void *ataxia_rmlui_component_create(const char *, const char *, const char *, uint32_t, uint32_t, float);
void ataxia_rmlui_component_destroy(void *);
bool ataxia_rmlui_component_attach_graphics(void *, uint32_t);
bool ataxia_rmlui_component_detach_graphics(void *);
bool ataxia_rmlui_component_render(void *);
bool ataxia_rmlui_component_resize(void *, uint32_t, uint32_t, float);
double ataxia_rmlui_component_next_update(void *);
bool ataxia_rmlui_component_pointer_motion(void *, float, float);
bool ataxia_rmlui_component_pointer_button(void *, float, float, uint32_t, bool);
bool ataxia_rmlui_component_pointer_scroll(void *, float, float, float, float);
bool ataxia_rmlui_component_focus(void *, bool);
bool ataxia_rmlui_component_key_symbol(void *, uint32_t, bool, int);
bool ataxia_rmlui_component_register_callback(void *, const char *);
size_t ataxia_rmlui_component_callback_count(void *);
const char *ataxia_rmlui_component_callback_name(void *, size_t);
const char *ataxia_rmlui_component_callback_value(void *, size_t);
void ataxia_rmlui_component_clear_callbacks(void *);
bool ataxia_rmlui_component_set_string(void *, const char *, const char *);
}
static wl_display *display;
static wl_compositor *compositor;
static xdg_wm_base *shell;
static wl_surface *surface;
static wl_callback *pending_frame;
static wl_egl_window *egl_window;
static EGLDisplay egl_display;
static EGLSurface egl_surface;
static void *component;
static bool running = true, configured = false, dirty = true;
static int width = 800, height = 600, counter = 0;
static std::string root;
static void trace(const char *name, int a = 0, int b = 0) {
    if (getenv("ATAXIA_PREVIEW_TRACE")) { fprintf(stderr, "%s %d %d\n", name, a, b); fflush(stderr); }
}
struct Seat { wl_seat *seat{}; wl_pointer *pointer{}; wl_keyboard *keyboard{};
    xkb_context *context{}; xkb_keymap *keymap{}; xkb_state *state{}; double x{}, y{}; };
static std::vector<Seat *> seats;
static void require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
static void ping(void *, xdg_wm_base *base, uint32_t serial) { xdg_wm_base_pong(base, serial); }
static const xdg_wm_base_listener shell_listener = {ping};
static void configure_surface(void *, xdg_surface *xdg, uint32_t serial) {
    xdg_surface_ack_configure(xdg, serial); configured = true; dirty = true;
}
static const xdg_surface_listener surface_listener = {configure_surface};
static void configure_top(void *, xdg_toplevel *, int32_t w, int32_t h, wl_array *) {
    if (w > 0 && h > 0) { width = std::clamp(w, 96, 4096); height = std::clamp(h, 64, 4096); }
    if (egl_window) wl_egl_window_resize(egl_window, width, height, 0, 0);
    if (component) ataxia_rmlui_component_resize(component, width, height, 1);
    dirty = true;
}
static void close_top(void *, xdg_toplevel *) { running = false; }
static const xdg_toplevel_listener top_listener = {configure_top, close_top, nullptr, nullptr};
static void frame_done(void *, wl_callback *callback, uint32_t) {
    wl_callback_destroy(callback); pending_frame = nullptr;
}
static const wl_callback_listener frame_listener = {frame_done};
static void pointer_enter(void *data, wl_pointer *, uint32_t, wl_surface *, wl_fixed_t x, wl_fixed_t y) {
    auto *s = static_cast<Seat *>(data); s->x = wl_fixed_to_double(x); s->y = wl_fixed_to_double(y);
    if (component) ataxia_rmlui_component_pointer_motion(component, s->x, s->y);
    dirty = true;
}
static void pointer_leave(void *, wl_pointer *, uint32_t, wl_surface *) {}
static void pointer_motion(void *data, wl_pointer *, uint32_t, wl_fixed_t x, wl_fixed_t y) {
    pointer_enter(data, nullptr, 0, nullptr, x, y);
}
static void pointer_button(void *data, wl_pointer *, uint32_t, uint32_t, uint32_t button, uint32_t state) {
    auto *s = static_cast<Seat *>(data);
    trace("pointer-button", button, state);
    uint32_t index = button == 272 ? 1 : button == 273 ? 2 : button == 274 ? 3 : 0;
    if (component) ataxia_rmlui_component_pointer_button(component, s->x, s->y, index, state == WL_POINTER_BUTTON_STATE_PRESSED);
    dirty = true;
}
static void pointer_axis(void *data, wl_pointer *, uint32_t, uint32_t axis, wl_fixed_t value) {
    auto *s = static_cast<Seat *>(data); float delta = wl_fixed_to_double(value);
    if (component) ataxia_rmlui_component_pointer_scroll(component, s->x, s->y,
        axis == WL_POINTER_AXIS_HORIZONTAL_SCROLL ? delta : 0, axis == WL_POINTER_AXIS_VERTICAL_SCROLL ? delta : 0);
    dirty = true;
}
static void pointer_frame(void *, wl_pointer *) {}
static void axis_source(void *, wl_pointer *, uint32_t) {}
static void axis_stop(void *, wl_pointer *, uint32_t, uint32_t) {}
static void axis_discrete(void *, wl_pointer *, uint32_t, int32_t) {}
static const wl_pointer_listener pointer_listener = {pointer_enter, pointer_leave, pointer_motion, pointer_button, pointer_axis,
    pointer_frame, axis_source, axis_stop, axis_discrete, nullptr, nullptr};
static void keymap(void *data, wl_keyboard *, uint32_t format, int fd, uint32_t size) {
    auto *s = static_cast<Seat *>(data);
    if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 || size == 0 || size > 1024 * 1024) { close(fd); return; }
    void *map = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0); close(fd);
    if (map == MAP_FAILED) return;
    auto *next = xkb_keymap_new_from_string(s->context, static_cast<char *>(map), XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
    munmap(map, size);
    if (!next) return;
    if (s->state) xkb_state_unref(s->state);
    if (s->keymap) xkb_keymap_unref(s->keymap);
    s->keymap = next; s->state = xkb_state_new(next);
}
static void keyboard_enter(void *, wl_keyboard *, uint32_t, wl_surface *, wl_array *) {
    if (component) ataxia_rmlui_component_focus(component, true);
    dirty = true;
}
static void keyboard_leave(void *, wl_keyboard *, uint32_t, wl_surface *) {
    if (component) ataxia_rmlui_component_focus(component, false);
    dirty = true;
}
static void keyboard_key(void *data, wl_keyboard *, uint32_t, uint32_t, uint32_t key, uint32_t state) {
    auto *s = static_cast<Seat *>(data); if (!component || !s->state) return;
    int mask = 0;
    if (xkb_state_mod_name_is_active(s->state, XKB_MOD_NAME_SHIFT, XKB_STATE_MODS_EFFECTIVE)) mask |= 2;
    if (xkb_state_mod_name_is_active(s->state, XKB_MOD_NAME_CTRL, XKB_STATE_MODS_EFFECTIVE)) mask |= 1;
    if (xkb_state_mod_name_is_active(s->state, XKB_MOD_NAME_ALT, XKB_STATE_MODS_EFFECTIVE)) mask |= 4;
    if (xkb_state_mod_name_is_active(s->state, XKB_MOD_NAME_LOGO, XKB_STATE_MODS_EFFECTIVE)) mask |= 8;
    ataxia_rmlui_component_key_symbol(component, xkb_state_key_get_one_sym(s->state, key + 8), state == WL_KEYBOARD_KEY_STATE_PRESSED, mask);
    dirty = true;
}
static void modifiers(void *data, wl_keyboard *, uint32_t, uint32_t depressed, uint32_t latched, uint32_t locked, uint32_t group) {
    auto *s = static_cast<Seat *>(data); if (s->state) xkb_state_update_mask(s->state, depressed, latched, locked, 0, 0, group);
}
static void repeat(void *, wl_keyboard *, int32_t, int32_t) {}
static const wl_keyboard_listener keyboard_listener = {keymap, keyboard_enter, keyboard_leave, keyboard_key, modifiers, repeat};
static void capabilities(void *data, wl_seat *seat, uint32_t caps) {
    auto *s = static_cast<Seat *>(data);
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !s->pointer) {
        s->pointer = wl_seat_get_pointer(seat); wl_pointer_add_listener(s->pointer, &pointer_listener, s);
    }
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !s->keyboard) {
        s->keyboard = wl_seat_get_keyboard(seat); wl_keyboard_add_listener(s->keyboard, &keyboard_listener, s);
    }
}
static void seat_name(void *, wl_seat *, const char *) {}
static const wl_seat_listener seat_listener = {capabilities, seat_name};
static void global(void *, wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    if (!strcmp(interface, wl_compositor_interface.name)) compositor = static_cast<wl_compositor *>(wl_registry_bind(registry, name, &wl_compositor_interface, std::min(version, 4u)));
    else if (!strcmp(interface, xdg_wm_base_interface.name)) {
        shell = static_cast<xdg_wm_base *>(wl_registry_bind(registry, name, &xdg_wm_base_interface, 1)); xdg_wm_base_add_listener(shell, &shell_listener, nullptr);
    } else if (!strcmp(interface, wl_seat_interface.name)) {
        auto *s = new Seat; s->context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
        s->seat = static_cast<wl_seat *>(wl_registry_bind(registry, name, &wl_seat_interface, std::min(version, 5u)));
        wl_seat_add_listener(s->seat, &seat_listener, s); seats.push_back(s);
    }
}
static void global_remove(void *, wl_registry *, uint32_t) {}
static const wl_registry_listener registry_listener = {global, global_remove};
static std::string read_document(const std::string &path) {
    char resolved[PATH_MAX]; require(realpath(path.c_str(), resolved), "RML file does not exist");
    std::string canonical(resolved); require(canonical.rfind(root + "/", 0) == 0, "RML must be inside the selected project");
    std::ifstream stream(canonical, std::ios::binary | std::ios::ate);
    require(bool(stream), "Cannot open RML file"); auto size = stream.tellg();
    require(size > 0 && size <= 1024 * 1024, "RML must be between 1 byte and 1 MiB");
    std::string source(static_cast<size_t>(size), '\0'); stream.seekg(0); stream.read(source.data(), size);
    require(bool(stream), "Incomplete RML file");
    require(source.find("<!DOCTYPE") == std::string::npos && source.find("<!ENTITY") == std::string::npos, "Document types and entities are unsupported");
    auto parser = XML_ParserCreate(nullptr); require(parser, "Cannot create RML validator");
    struct Limits { XML_Parser parser; unsigned depth = 0, nodes = 0; } limits{parser};
    XML_SetUserData(parser, &limits);
    XML_SetElementHandler(parser,
        [](void *data, const XML_Char *, const XML_Char **) {
            auto *l = static_cast<Limits *>(data);
            if (++l->depth > 64 || ++l->nodes > 10000) XML_StopParser(l->parser, XML_FALSE);
        }, [](void *data, const XML_Char *) { --static_cast<Limits *>(data)->depth; });
    bool valid = XML_Parse(parser, source.data(), static_cast<int>(source.size()), XML_TRUE) != XML_STATUS_ERROR;
    std::string error = valid ? "" : std::string(XML_ErrorString(XML_GetErrorCode(parser))) + " at line " + std::to_string(XML_GetCurrentLineNumber(parser));
    XML_ParserFree(parser); if (!valid) throw std::runtime_error(error);
    require(source.find("<rml") != std::string::npos && source.find("<body") != std::string::npos, "Expected rml and body elements");
    return source;
}
static void load_document(const std::string &path) {
    auto source = read_document(path);
    void *next = ataxia_rmlui_component_create(source.c_str(), path.c_str(), "preview", width, height, 1);
    require(next, ataxia_rmlui_last_error());
    if (!ataxia_rmlui_component_attach_graphics(next, 0)) {
        std::string error = ataxia_rmlui_last_error(); ataxia_rmlui_component_destroy(next); throw std::runtime_error(error);
    }
    // Render before publishing. A parse or graphics failure leaves the last good document intact.
    if (!ataxia_rmlui_component_render(next)) {
        std::string error = ataxia_rmlui_last_error(); ataxia_rmlui_component_detach_graphics(next);
        ataxia_rmlui_component_destroy(next); throw std::runtime_error(error);
    }
    if (component) { ataxia_rmlui_component_detach_graphics(component); ataxia_rmlui_component_destroy(component); }
    component = next;
    for (auto name : {"increment", "decrement", "reset", "submit", "input:change"})
        trace(name, ataxia_rmlui_component_register_callback(component, name));
    dirty = true;
}
static void events() {
    if (!component) return;
    auto count = ataxia_rmlui_component_callback_count(component);
    for (size_t i = 0; i < count; ++i) {
        std::string name = ataxia_rmlui_component_callback_name(component, i);
        trace(name.c_str(), counter);
        std::string value = ataxia_rmlui_component_callback_value(component, i);
        if (name == "increment") ++counter;
        else if (name == "decrement") --counter;
        else if (name == "reset") counter = 0;
        else if (name == "input:change") ataxia_rmlui_component_set_string(component, "result", value.c_str());
        else if (name == "submit") ataxia_rmlui_component_set_string(component, "status", "Submitted");
        ataxia_rmlui_component_set_string(component, "counter", std::to_string(counter).c_str());
        dirty = true;
    }
    ataxia_rmlui_component_clear_callbacks(component);
}
static void command(const std::string &line) {
    if (line == "QUIT") { running = false; return; }
    try {
        require(line.rfind("LOAD\t", 0) == 0, "Expected LOAD command");
        load_document(line.substr(5)); puts("OK");
    } catch (const std::exception &e) {
        std::string error(e.what()); for (char &c : error) if (c == '\n' || c == '\r' || c == '\t') c = ' ';
        printf("ERROR\t%.2048s\n", error.c_str());
    }
    fflush(stdout);
}
int main(int argc, char **argv) {
    try {
        require(argc == 5, "Usage: ataxia-rmlui-preview PROJECT APP_ID WIDTH HEIGHT");
        char resolved[PATH_MAX]; require(realpath(argv[1], resolved), "Project does not exist"); root = resolved;
        width = std::clamp(atoi(argv[3]), 96, 1920); height = std::clamp(atoi(argv[4]), 64, 1200);
        rlimit core_limit{0, 0}; setrlimit(RLIMIT_CORE, &core_limit);
        display = wl_display_connect(nullptr); require(display, "Cannot connect to Wayland");
        auto *registry = wl_display_get_registry(display); wl_registry_add_listener(registry, &registry_listener, nullptr);
        require(wl_display_roundtrip(display) >= 0 && compositor && shell, "Wayland compositor is unavailable");
        surface = wl_compositor_create_surface(compositor);
        auto *xdg = xdg_wm_base_get_xdg_surface(shell, surface); xdg_surface_add_listener(xdg, &surface_listener, nullptr);
        auto *top = xdg_surface_get_toplevel(xdg); xdg_toplevel_add_listener(top, &top_listener, nullptr);
        xdg_toplevel_set_title(top, "RmlUi preview"); xdg_toplevel_set_app_id(top, argv[2]); wl_surface_commit(surface);
        while (!configured) require(wl_display_dispatch(display) >= 0, "Wayland disconnected");
        egl_display = eglGetDisplay(reinterpret_cast<EGLNativeDisplayType>(display));
        require(eglInitialize(egl_display, nullptr, nullptr), "EGL initialization failed");
        eglBindAPI(EGL_OPENGL_ES_API);
        EGLint attrs[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_STENCIL_SIZE, 8, EGL_NONE};
        EGLConfig config; EGLint count; require(eglChooseConfig(egl_display, attrs, &config, 1, &count) && count, "No EGL configuration");
        EGLint context_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
        auto context = eglCreateContext(egl_display, config, EGL_NO_CONTEXT, context_attrs); require(context != EGL_NO_CONTEXT, "Cannot create GLES context");
        egl_window = wl_egl_window_create(surface, width, height);
        egl_surface = eglCreateWindowSurface(egl_display, config, reinterpret_cast<EGLNativeWindowType>(egl_window), nullptr);
        require(egl_surface != EGL_NO_SURFACE && eglMakeCurrent(egl_display, egl_surface, egl_surface, context), "Cannot create EGL window");
        // Pace rendering with our own callback, keeping Wayland dispatch live
        // when a monitor pans away and the compositor withholds frame callbacks.
        require(eglSwapInterval(egl_display, 0), "Cannot configure preview frame scheduling");
        require(ataxia_rmlui_set_asset_root(root.c_str()), ataxia_rmlui_last_error());
        require(ataxia_rmlui_initialize(), ataxia_rmlui_last_error());
        std::string input;
        while (running) {
            events();
            if (component && !pending_frame && (dirty || ataxia_rmlui_component_next_update(component) == 0)) {
                require(ataxia_rmlui_component_render(component), ataxia_rmlui_last_error());
                pending_frame = wl_surface_frame(surface);
                wl_callback_add_listener(pending_frame, &frame_listener, nullptr);
                require(eglSwapBuffers(egl_display, egl_surface), "Cannot present preview"); dirty = false;
            }
            while (wl_display_prepare_read(display) != 0) {
                require(wl_display_dispatch_pending(display) >= 0, "Wayland disconnected");
                if (!running) break;
            }
            if (!running) break;
            wl_display_flush(display);
            double next = component && !pending_frame ? ataxia_rmlui_component_next_update(component) : -1;
            // Sleep until the actual UI deadline; input wakes poll independently.
            int timeout = next < 0 ? -1 : static_cast<int>(std::clamp(std::ceil(next), 1.0, double(INT_MAX)));
            pollfd fds[] = {{wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
            int ready = poll(fds, 2, timeout);
            if (ready < 0 && errno != EINTR) throw std::runtime_error("Preview poll failed");
            if (fds[0].revents & POLLIN) require(wl_display_read_events(display) >= 0, "Wayland disconnected");
            else wl_display_cancel_read(display);
            require(wl_display_dispatch_pending(display) >= 0, "Wayland disconnected");
            if (fds[1].revents & (POLLHUP | POLLERR)) break;
            if (fds[1].revents & POLLIN) {
                char bytes[4096]; ssize_t n = read(STDIN_FILENO, bytes, sizeof bytes); if (n <= 0) break;
                input.append(bytes, n); require(input.size() <= 8192, "Preview command exceeds limit");
                for (size_t end; (end = input.find('\n')) != std::string::npos;) {
                    command(input.substr(0, end)); input.erase(0, end + 1);
                }
            }
        }
        if (pending_frame) wl_callback_destroy(pending_frame);
        if (component) { ataxia_rmlui_component_detach_graphics(component); ataxia_rmlui_component_destroy(component); }
        eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroySurface(egl_display, egl_surface); eglDestroyContext(egl_display, context); eglTerminate(egl_display);
        wl_egl_window_destroy(egl_window); wl_display_disconnect(display);
        return 0;
    } catch (const std::exception &e) { fprintf(stderr, "Preview: %s\n", e.what()); return 1; }
}
