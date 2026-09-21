// World-owned RmlUi host. All entry points run on the compositor owner thread.
#include "RmlUi_Renderer_GL3.h"
#include <GLES3/gl3.h>
#include <RmlUi/Core.h>
#include <RmlUi/Core/Elements/ElementFormControl.h>
#include <algorithm>
#include <chrono>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <deque>
#include <limits>
#include <map>
#include <memory>
#include <png.h>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
#include <xkbcommon/xkbcommon-keysyms.h>
#include <xkbcommon/xkbcommon.h>

#define API extern "C" __attribute__((visibility("default")))
static thread_local std::string last_error;
template <class F> static bool checked(F f) noexcept {
    try {
        last_error.clear();
        f();
        return true;
    } catch (const std::exception &e) {
        last_error = e.what();
    } catch (...) {
        last_error = "Unknown native exception";
    }
    return false;
}
static void require(bool condition, const char *message) {
    if (!condition)
        throw std::runtime_error(message);
}
// Enabled only in isolated app-preview processes, before RmlUi initialization.
static std::string asset_root;
static std::string allowed_asset(const std::string &path) {
    if (asset_root.empty()) return path;
    char resolved[PATH_MAX];
    if (!realpath(path.c_str(), resolved)) return {};
    std::string canonical(resolved);
    if (canonical.rfind(asset_root + "/", 0) == 0 ||
        canonical == "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf") return canonical;
    return {};
}
struct PreviewFiles : Rml::FileInterface {
    Rml::FileHandle Open(const Rml::String &path) override {
        auto canonical = allowed_asset(path);
        if (canonical.empty()) return 0;
        auto *file = fopen(canonical.c_str(), "rb");
        if (!file) return 0;
        if (fseek(file, 0, SEEK_END) || ftell(file) < 0 || ftell(file) > 8 * 1024 * 1024) { fclose(file); return 0; }
        rewind(file); return reinterpret_cast<Rml::FileHandle>(file);
    }
    void Close(Rml::FileHandle file) override { fclose(reinterpret_cast<FILE *>(file)); }
    size_t Read(void *buffer, size_t size, Rml::FileHandle file) override { return fread(buffer, 1, size, reinterpret_cast<FILE *>(file)); }
    bool Seek(Rml::FileHandle file, long offset, int origin) override { return fseek(reinterpret_cast<FILE *>(file), offset, origin) == 0; }
    size_t Tell(Rml::FileHandle file) override { return ftell(reinterpret_cast<FILE *>(file)); }
};
static PreviewFiles preview_files;
struct HostSystem : Rml::SystemInterface {
    std::string clipboard;
    uint64_t clipboard_revision = 0;
    double GetElapsedTime() override {
        return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
    }
    bool LogMessage(Rml::Log::Type type, const Rml::String &message) override {
        if (type <= Rml::Log::LT_WARNING)
            last_error = message;
        return true;
    }
    void SetClipboardText(const Rml::String &text) override { clipboard = text; ++clipboard_revision; }
    void GetClipboardText(Rml::String &text) override { text = clipboard; }
};
static HostSystem host;

// Upstream preserves blend/stencil/scissor state during a frame. This guard also
// preserves state across construction, texture upload, deletion, and failed work.
struct GLGuard {
    GLint draw, read, program, vao, array, renderbuffer, active, unpack, pack, unpack_buffer, pack_buffer;
    GLint textures[2], samplers[2], viewport[4], scissor[4], pixel_store[4];
    const GLenum pixel_parameters[4] = {GL_UNPACK_ROW_LENGTH, GL_UNPACK_SKIP_PIXELS, GL_UNPACK_SKIP_ROWS,
                                        GL_UNPACK_IMAGE_HEIGHT};
    GLint eq[2], blend[4], stencil[2][7], clear_stencil;
    GLfloat clear[4];
    GLboolean mask[4];
    GLboolean enables[5];
    const GLenum caps[5] = {GL_BLEND, GL_CULL_FACE, GL_DEPTH_TEST, GL_STENCIL_TEST, GL_SCISSOR_TEST};
    GLGuard() {
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw);
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read);
        glGetIntegerv(GL_CURRENT_PROGRAM, &program);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &array);
        glGetIntegerv(GL_RENDERBUFFER_BINDING, &renderbuffer);
        glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
        glGetIntegerv(GL_UNPACK_ALIGNMENT, &unpack);
        glGetIntegerv(GL_PACK_ALIGNMENT, &pack);
        glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &unpack_buffer);
        glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pack_buffer);
        for (int i = 0; i < 4; i++) {
            glGetIntegerv(pixel_parameters[i], &pixel_store[i]);
            glPixelStorei(pixel_parameters[i], 0);
        }
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        for (int i = 0; i < 2; i++) {
            glActiveTexture(GL_TEXTURE0 + i);
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &textures[i]);
            glGetIntegerv(GL_SAMPLER_BINDING, &samplers[i]);
            glBindSampler(i, 0);
        }
        glGetIntegerv(GL_VIEWPORT, viewport);
        glGetIntegerv(GL_SCISSOR_BOX, scissor);
        glGetFloatv(GL_COLOR_CLEAR_VALUE, clear);
        glGetBooleanv(GL_COLOR_WRITEMASK, mask);
        glGetIntegerv(GL_STENCIL_CLEAR_VALUE, &clear_stencil);
        glGetIntegerv(GL_BLEND_EQUATION_RGB, &eq[0]);
        glGetIntegerv(GL_BLEND_EQUATION_ALPHA, &eq[1]);
        glGetIntegerv(GL_BLEND_SRC_RGB, &blend[0]);
        glGetIntegerv(GL_BLEND_DST_RGB, &blend[1]);
        glGetIntegerv(GL_BLEND_SRC_ALPHA, &blend[2]);
        glGetIntegerv(GL_BLEND_DST_ALPHA, &blend[3]);
        const GLenum front[] = {GL_STENCIL_FUNC,           GL_STENCIL_REF,  GL_STENCIL_VALUE_MASK,
                                GL_STENCIL_WRITEMASK,      GL_STENCIL_FAIL, GL_STENCIL_PASS_DEPTH_FAIL,
                                GL_STENCIL_PASS_DEPTH_PASS};
        const GLenum back[] = {GL_STENCIL_BACK_FUNC,           GL_STENCIL_BACK_REF,
                               GL_STENCIL_BACK_VALUE_MASK,     GL_STENCIL_BACK_WRITEMASK,
                               GL_STENCIL_BACK_FAIL,           GL_STENCIL_BACK_PASS_DEPTH_FAIL,
                               GL_STENCIL_BACK_PASS_DEPTH_PASS};
        for (int i = 0; i < 7; i++) {
            glGetIntegerv(front[i], &stencil[0][i]);
            glGetIntegerv(back[i], &stencil[1][i]);
        }
        for (int i = 0; i < 5; i++)
            enables[i] = glIsEnabled(caps[i]);
    }
    ~GLGuard() {
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, draw);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, read);
        glUseProgram(program);
        glBindVertexArray(vao);
        glBindBuffer(GL_ARRAY_BUFFER, array);
        glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
        for (int i = 0; i < 2; i++) {
            glActiveTexture(GL_TEXTURE0 + i);
            glBindTexture(GL_TEXTURE_2D, textures[i]);
            glBindSampler(i, samplers[i]);
        }
        glActiveTexture(active);
        glPixelStorei(GL_UNPACK_ALIGNMENT, unpack);
        glPixelStorei(GL_PACK_ALIGNMENT, pack);
        for (int i = 0; i < 4; i++)
            glPixelStorei(pixel_parameters[i], pixel_store[i]);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, unpack_buffer);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, pack_buffer);
        glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
        glScissor(scissor[0], scissor[1], scissor[2], scissor[3]);
        glClearColor(clear[0], clear[1], clear[2], clear[3]);
        glColorMask(mask[0], mask[1], mask[2], mask[3]);
        glClearStencil(clear_stencil);
        glBlendEquationSeparate(eq[0], eq[1]);
        glBlendFuncSeparate(blend[0], blend[1], blend[2], blend[3]);
        for (int i = 0; i < 2; i++) {
            auto *s = stencil[i];
            GLenum face = i ? GL_BACK : GL_FRONT;
            glStencilFuncSeparate(face, s[0], s[1], s[2]);
            glStencilMaskSeparate(face, s[3]);
            glStencilOpSeparate(face, s[4], s[5], s[6]);
        }
        for (int i = 0; i < 5; i++) {
            if (enables[i])
                glEnable(caps[i]);
            else
                glDisable(caps[i]);
        }
    }
};

// Contexts and documents may exist without GL. Geometry/texture releases from
// DOM mutations are deferred until the next graphics scope.
void AtaxiaReleaseFilter(Rml::CompiledFilterHandle);
void AtaxiaReleaseShader(Rml::CompiledShaderHandle);
struct Renderer : Rml::RenderInterface {
    std::unique_ptr<RenderInterface_GL3> gpu;
    std::vector<Rml::CompiledGeometryHandle> retired_geometry;
    std::vector<Rml::TextureHandle> retired_textures;
    void flush() {
        if (!gpu)
            return;
        for (auto h : retired_geometry)
            gpu->ReleaseGeometry(h);
        for (auto h : retired_textures)
            gpu->ReleaseTexture(h);
        retired_geometry.clear();
        retired_textures.clear();
    }
    Rml::CompiledGeometryHandle CompileGeometry(Rml::Span<const Rml::Vertex> v,
                                                Rml::Span<const int> i) override {
        require(bool(gpu), "Graphics not attached");
        return gpu->CompileGeometry(v, i);
    }
    void RenderGeometry(Rml::CompiledGeometryHandle h, Rml::Vector2f p, Rml::TextureHandle t) override {
        gpu->RenderGeometry(h, p, t);
    }
    void ReleaseGeometry(Rml::CompiledGeometryHandle h) override { retired_geometry.push_back(h); }
    void ReleaseTexture(Rml::TextureHandle h) override { retired_textures.push_back(h); }
    Rml::TextureHandle GenerateTexture(Rml::Span<const Rml::byte> p, Rml::Vector2i d) override {
        require(bool(gpu), "Graphics not attached");
        return gpu->GenerateTexture(p, d);
    }
    Rml::TextureHandle LoadTexture(Rml::Vector2i &dims, const Rml::String &source) override {
        png_image im{};
        im.version = PNG_IMAGE_VERSION;
        auto path = allowed_asset(source);
        if (path.empty() || !png_image_begin_read_from_file(&im, path.c_str()))
            return 0;
        if (!asset_root.empty() && (im.width > 4096 || im.height > 4096)) {
            png_image_free(&im); return 0;
        }
        im.format = PNG_FORMAT_RGBA;
        std::vector<Rml::byte> pixels(PNG_IMAGE_SIZE(im));
        if (!png_image_finish_read(&im, nullptr, pixels.data(), 0, nullptr)) {
            png_image_free(&im);
            return 0;
        }
        dims = {int(im.width), int(im.height)};
        png_image_free(&im);
        for (size_t i = 0; i < pixels.size(); i += 4)
            for (int c = 0; c < 3; c++)
                pixels[i + c] = (unsigned(pixels[i + c]) * pixels[i + 3] + 127) / 255;
        return GenerateTexture(pixels, dims);
    }
    void EnableScissorRegion(bool b) override { gpu->EnableScissorRegion(b); }
    void SetScissorRegion(Rml::Rectanglei r) override { gpu->SetScissorRegion(r); }
    void EnableClipMask(bool b) override { gpu->EnableClipMask(b); }
    void RenderToClipMask(Rml::ClipMaskOperation o, Rml::CompiledGeometryHandle h, Rml::Vector2f p) override {
        gpu->RenderToClipMask(o, h, p);
    }
    void SetTransform(const Rml::Matrix4f *m) override { gpu->SetTransform(m); }
    Rml::LayerHandle PushLayer() override { return gpu->PushLayer(); }
    void CompositeLayers(Rml::LayerHandle a, Rml::LayerHandle b, Rml::BlendMode m,
                         Rml::Span<const Rml::CompiledFilterHandle> f) override {
        gpu->CompositeLayers(a, b, m, f);
    }
    void PopLayer() override { gpu->PopLayer(); }
    Rml::TextureHandle SaveLayerAsTexture() override { return gpu->SaveLayerAsTexture(); }
    Rml::CompiledFilterHandle SaveLayerAsMaskImage() override { return gpu->SaveLayerAsMaskImage(); }
    Rml::CompiledFilterHandle CompileFilter(const Rml::String &s, const Rml::Dictionary &d) override {
        return gpu->CompileFilter(s, d);
    }
    void ReleaseFilter(Rml::CompiledFilterHandle h) override { AtaxiaReleaseFilter(h); }
    Rml::CompiledShaderHandle CompileShader(const Rml::String &s, const Rml::Dictionary &d) override {
        return gpu->CompileShader(s, d);
    }
    void RenderShader(Rml::CompiledShaderHandle h, Rml::CompiledGeometryHandle g, Rml::Vector2f p,
                      Rml::TextureHandle t) override {
        gpu->RenderShader(h, g, p, t);
    }
    void ReleaseShader(Rml::CompiledShaderHandle h) override { AtaxiaReleaseShader(h); }
};
static bool initialized = false;
static uint64_t next_id = 0;
struct Component;
struct Listener : Rml::EventListener {
    Component *owner;
    std::string name;
    Listener(Component *o, std::string n) : owner(o), name(std::move(n)) {}
    void ProcessEvent(Rml::Event &) override;
};
struct Component {
    Renderer renderer;
    Rml::Context *context = nullptr;
    Rml::ElementDocument *doc = nullptr;
    std::string context_name, source_path;
    std::map<std::string, std::unique_ptr<Listener>> listeners;
    std::deque<std::pair<std::string, std::string>> events;
    std::map<std::string, Rml::Variant> model_values;
    std::set<std::string> model_events;
    Rml::DataModelHandle model;
    std::string model_string;
    void queue(const std::string &name, const std::string &value) {
        if (events.size() == 64)
            events.pop_front();
        events.emplace_back(name, value);
        invalidate();
    }
    uint32_t width, height, framebuffer = 0;
    float scale;
    uint64_t revision = 0;
    bool dirty = true;
    double deadline = std::numeric_limits<double>::infinity();
    int modifiers = 0;
    Component(uint32_t w, uint32_t h, float s) : width(w), height(h), scale(s) {}
    void invalidate() { dirty = true; }
    ~Component() {
        if (context) {
            Rml::RemoveContext(context_name);
            Rml::ReleaseRenderManagers();
        }
    }
};
void Listener::ProcessEvent(Rml::Event &event) {
    auto *target = event.GetTargetElement();
    std::string value = event.GetParameter<Rml::String>("value", "");
    if (auto *control = dynamic_cast<Rml::ElementFormControl *>(target))
        value = control->GetValue();
    owner->queue(name, value);
}
static Component &component(void *p) {
    require(p, "Null component");
    return *static_cast<Component *>(p);
}
static std::pair<std::string, std::string> event_parts(const std::string &name) {
    auto colon = name.find(':');
    return colon == std::string::npos ? std::make_pair(name, std::string("click"))
                                      : std::make_pair(name.substr(0, colon), name.substr(colon + 1));
}
static void bind_listener(Component &c, const std::string &name) {
    if (name.rfind("model:", 0) == 0) {
        c.model_events.insert(name.substr(6));
        return;
    }
    auto parts = event_parts(name);
    auto *e = c.doc->GetElementById(parts.first);
    require(e, "Callback element id does not exist");
    auto old = c.listeners.find(name);
    if (old != c.listeners.end())
        e->RemoveEventListener(parts.second, old->second.get());
    auto listener = std::make_unique<Listener>(&c, name);
    e->AddEventListener(parts.second, listener.get());
    c.listeners[name] = std::move(listener);
}
static std::string escaped(const std::string &text) {
    std::string result;
    for (char c : text) {
        if (c == '&')
            result += "&amp;";
        else if (c == '<')
            result += "&lt;";
        else if (c == '>')
            result += "&gt;";
        else
            result += c;
    }
    return result;
}
API uint32_t ataxia_rmlui_abi_version() { return 2; }
API const char *ataxia_rmlui_clipboard_text() { return host.clipboard.c_str(); }
API uint64_t ataxia_rmlui_clipboard_revision() { return host.clipboard_revision; }
API bool ataxia_rmlui_clipboard_set(const char *text) {
    return checked([&] { host.clipboard = text ? text : ""; });
}
API const char *ataxia_rmlui_last_error() { return last_error.c_str(); }
API bool ataxia_rmlui_set_asset_root(const char *path) {
    return checked([&] {
        require(!initialized, "Set the preview root before initialization");
        char resolved[PATH_MAX];
        require(path && realpath(path, resolved), "Invalid preview asset root");
        asset_root = resolved;
        Rml::SetFileInterface(&preview_files);
    });
}
API bool ataxia_rmlui_initialize() {
    return checked([] {
        if (initialized)
            return;
        Rml::SetSystemInterface(&host);
        require(Rml::Initialise(), "RmlUi initialization failed");
        initialized = true;
        // Optional fallback; applications may load their own font before creating UI.
        Rml::LoadFontFace("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf");
    });
}
API bool ataxia_rmlui_load_font(const char *path) {
    return checked([&] { require(Rml::LoadFontFace(path), "Cannot load font"); });
}
API void *ataxia_rmlui_component_create(const char *source, const char *path, const char *, uint32_t w,
                                        uint32_t h, float scale) {
    Component *result = nullptr;
    checked([&] {
        require(w && h && std::isfinite(scale) && scale > 0, "Invalid component dimensions");
        auto c = std::make_unique<Component>(w, h, scale);
        c->context_name = "ataxia-rmlui-" + std::to_string(++next_id);
        c->source_path = path;
        c->context = Rml::CreateContext(c->context_name, {int(w), int(h)}, &c->renderer);
        require(c->context, "Cannot create RmlUi context");
        c->context->SetDensityIndependentPixelRatio(scale);
        auto model = c->context->CreateDataModel("state", nullptr, true);
        require(bool(model), "Cannot create component data model");
        c->model = model.GetModelHandle();
        c->doc = c->context->LoadDocumentFromMemory(source, path);
        require(c->doc, "Cannot parse RML document");
        c->doc->Show();
        result = c.release();
    });
    return result;
}
API void ataxia_rmlui_component_destroy(void *p) {
    checked([&] {
        auto &c = component(p);
        require(!c.renderer.gpu, "Detach graphics before destruction");
        delete &c;
    });
}
API bool ataxia_rmlui_component_resize(void *p, uint32_t w, uint32_t h, float s) {
    return checked([&] {
        auto &c = component(p);
        require(w && h && std::isfinite(s) && s > 0, "Invalid dimensions");
        c.width = w;
        c.height = h;
        c.scale = s;
        c.context->SetDimensions({int(w), int(h)});
        c.context->SetDensityIndependentPixelRatio(s);
        c.invalidate();
    });
}
API bool ataxia_rmlui_component_attach_graphics(void *p, uint32_t fbo) {
    return checked([&] {
        auto &c = component(p);
        require(!c.renderer.gpu, "Graphics already attached");
        auto *version = reinterpret_cast<const char *>(glGetString(GL_VERSION));
        require(version && std::string(version).find("OpenGL ES 3.") != std::string::npos,
                "RmlUi effects renderer requires OpenGL ES 3.0 or later");
        GLGuard guard;
        c.renderer.gpu = std::make_unique<RenderInterface_GL3>();
        if (!*c.renderer.gpu) {
            c.renderer.gpu.reset();
            throw std::runtime_error("Cannot initialize RmlUi GLES shaders");
        }
        c.framebuffer = fbo;
        c.invalidate();
    });
}
API bool ataxia_rmlui_component_detach_graphics(void *p) {
    return checked([&] {
        auto &c = component(p);
        if (!c.renderer.gpu)
            return;
        GLGuard guard;
        Rml::ReleaseCompiledGeometry(&c.renderer);
        Rml::ReleaseTextures(&c.renderer);
        c.renderer.flush();
        c.renderer.gpu.reset();
        c.framebuffer = 0;
        c.invalidate();
    });
}
API bool ataxia_rmlui_component_render(void *p) {
    return checked([&] {
        auto &c = component(p);
        require(bool(c.renderer.gpu), "Graphics not attached");
        if (!c.dirty && host.GetElapsedTime() < c.deadline)
            return;
        GLGuard guard;
        c.renderer.flush();
        c.context->Update();
        c.renderer.gpu->SetViewport(c.width, c.height);
        c.renderer.gpu->SetDestination(c.framebuffer);
        c.renderer.gpu->BeginFrame();
        c.context->Render();
        c.renderer.gpu->EndFrame();
        c.renderer.flush();
        c.dirty = false;
        c.deadline = host.GetElapsedTime() + c.context->GetNextUpdateDelay();
        ++c.revision;
    });
}
API uint32_t ataxia_rmlui_component_width(void *p) { return static_cast<Component *>(p)->width; }
API uint32_t ataxia_rmlui_component_height(void *p) { return static_cast<Component *>(p)->height; }
API uint64_t ataxia_rmlui_component_revision(void *p) { return static_cast<Component *>(p)->revision; }
API double ataxia_rmlui_component_next_update(void *p) {
    auto &c = *static_cast<Component *>(p);
    if (c.dirty)
        return 0;
    if (!std::isfinite(c.deadline))
        return -1;
    return std::max(0.0, (c.deadline - host.GetElapsedTime()) * 1000);
}
API bool ataxia_rmlui_component_has_active_animations(void *p) {
    return ataxia_rmlui_component_next_update(p) == 0;
}
API bool ataxia_rmlui_component_set_string(void *p, const char *name, const char *value) {
    return checked([&] {
        auto &c = component(p);
        auto *e = c.doc->GetElementById(name);
        require(e, "Property element id does not exist");
        if (auto *control = dynamic_cast<Rml::ElementFormControl *>(e))
            control->SetValue(value);
        else
            e->SetInnerRML(escaped(value));
        c.invalidate();
    });
}
API bool ataxia_rmlui_component_set_number(void *p, const char *n, double v) {
    auto s = std::to_string(v);
    return ataxia_rmlui_component_set_string(p, n, s.c_str());
}
API bool ataxia_rmlui_component_set_boolean(void *p, const char *n, bool v) {
    return ataxia_rmlui_component_set_string(p, n, v ? "true" : "false");
}
API bool ataxia_rmlui_component_set_attribute(void *p, const char *id, const char *name, const char *value, bool present) {
    return checked([&] {
        auto &c = component(p);
        auto *e = c.doc->GetElementById(id);
        require(e, "Element id does not exist");
        if (present) e->SetAttribute(name, Rml::String(value));
        else e->RemoveAttribute(name);
        c.invalidate();
    });
}
API bool ataxia_rmlui_component_set_class(void *p, const char *id, const char *name, bool enabled) {
    return checked([&] {
        auto &c = component(p);
        auto *e = c.doc->GetElementById(id);
        require(e, "Element id does not exist");
        e->SetClass(name, enabled);
        c.invalidate();
    });
}
API bool ataxia_rmlui_component_set_style(void *p, const char *id, const char *name, const char *value) {
    return checked([&] {
        auto &c = component(p);
        auto *e = *id ? c.doc->GetElementById(id) : c.doc;
        require(e, "Element id does not exist");
        require(e->SetProperty(name, value), "Invalid RCSS property");
        c.invalidate();
    });
}
API bool ataxia_rmlui_component_register_callback(void *p, const char *name) {
    return checked([&] { bind_listener(component(p), name); });
}
API bool ataxia_rmlui_component_unregister_callback(void *p, const char *name) {
    return checked([&] {
        auto &c = component(p);
        if (std::string(name).rfind("model:", 0) == 0) {
            c.model_events.erase(std::string(name).substr(6));
            return;
        }
        auto it = c.listeners.find(name);
        if (it == c.listeners.end())
            return;
        auto parts = event_parts(name);
        if (auto *e = c.doc->GetElementById(parts.first))
            e->RemoveEventListener(parts.second, it->second.get());
        c.listeners.erase(it);
    });
}
API size_t ataxia_rmlui_component_callback_count(void *p) {
    return static_cast<Component *>(p)->events.size();
}
API const char *ataxia_rmlui_component_callback_name(void *p, size_t i) {
    auto &q = static_cast<Component *>(p)->events;
    return i < q.size() ? q[i].first.c_str() : "";
}
API const char *ataxia_rmlui_component_callback_value(void *p, size_t i) {
    auto &q = static_cast<Component *>(p)->events;
    return i < q.size() ? q[i].second.c_str() : "";
}
API void ataxia_rmlui_component_clear_callbacks(void *p) { static_cast<Component *>(p)->events.clear(); }
API bool ataxia_rmlui_component_pointer_motion(void *p, float x, float y) {
    return checked([&] {
        auto &c = component(p);
        c.context->ProcessMouseMove(std::lround(x * c.scale), std::lround(y * c.scale), c.modifiers);
        c.invalidate();
    });
}
API bool ataxia_rmlui_component_pointer_button(void *p, float x, float y, uint32_t b, bool pressed) {
    return checked([&] {
        auto &c = component(p);
        c.context->ProcessMouseMove(std::lround(x * c.scale), std::lround(y * c.scale), c.modifiers);
        if (b) {
            if (pressed)
                c.context->ProcessMouseButtonDown(b - 1, c.modifiers);
            else
                c.context->ProcessMouseButtonUp(b - 1, c.modifiers);
        }
        c.invalidate();
    });
}
API bool ataxia_rmlui_component_pointer_scroll(void *p, float x, float y, float dx, float dy) {
    return checked([&] {
        auto &c = component(p);
        c.context->ProcessMouseMove(std::lround(x * c.scale), std::lround(y * c.scale), c.modifiers);
        c.context->ProcessMouseWheel(Rml::Vector2f(dx / 15.f, dy / 15.f), c.modifiers);
        c.invalidate();
    });
}
API bool ataxia_rmlui_component_pointer_exit(void *p) {
    return checked([&] {
        auto &c = component(p);
        c.context->ProcessMouseLeave();
        c.invalidate();
    });
}
API bool ataxia_rmlui_component_focus(void *p, bool focus) {
    return checked([&] {
        auto &c = component(p);
        if (!focus) {
            if (auto *e = c.context->GetFocusElement())
                e->Blur();
            c.modifiers = 0;
        }
        c.invalidate();
    });
}
static Rml::Input::KeyIdentifier key_identifier(uint32_t sym) {
    using namespace Rml::Input;
    sym = xkb_keysym_to_lower(sym);
    if (sym >= XKB_KEY_a && sym <= XKB_KEY_z)
        return KeyIdentifier(KI_A + sym - XKB_KEY_a);
    if (sym >= XKB_KEY_0 && sym <= XKB_KEY_9)
        return KeyIdentifier(KI_0 + sym - XKB_KEY_0);
    if (sym >= XKB_KEY_F1 && sym <= XKB_KEY_F24)
        return KeyIdentifier(KI_F1 + sym - XKB_KEY_F1);
    switch (sym) {
    case XKB_KEY_space:
        return KI_SPACE;
    case XKB_KEY_BackSpace:
        return KI_BACK;
    case XKB_KEY_Tab:
    case XKB_KEY_ISO_Left_Tab:
        return KI_TAB;
    case XKB_KEY_Return:
        return KI_RETURN;
    case XKB_KEY_KP_Enter:
        return KI_NUMPADENTER;
    case XKB_KEY_Escape:
        return KI_ESCAPE;
    case XKB_KEY_Left:
        return KI_LEFT;
    case XKB_KEY_Right:
        return KI_RIGHT;
    case XKB_KEY_Up:
        return KI_UP;
    case XKB_KEY_Down:
        return KI_DOWN;
    case XKB_KEY_Home:
        return KI_HOME;
    case XKB_KEY_End:
        return KI_END;
    case XKB_KEY_Page_Up:
        return KI_PRIOR;
    case XKB_KEY_Page_Down:
        return KI_NEXT;
    case XKB_KEY_Delete:
        return KI_DELETE;
    case XKB_KEY_Insert:
        return KI_INSERT;
    default:
        return KI_UNKNOWN;
    }
}
API bool ataxia_rmlui_component_key_symbol(void *p, uint32_t sym, bool pressed, int modifiers) {
    return checked([&] {
        auto &c = component(p);
        c.modifiers = modifiers;
        auto id = key_identifier(sym);
        if (pressed) {
            c.context->ProcessKeyDown(id, modifiers);
            uint32_t ch = xkb_keysym_to_utf32(sym);
            // RmlUi's multiline editor receives line breaks as text input.
            // KeyDown handles navigation and single-line submit, not insertion.
            if (sym == XKB_KEY_Return || sym == XKB_KEY_KP_Enter)
                ch = '\n';
            if ((ch == '\n' || (ch >= 32 && ch != 127)) && !(modifiers & (Rml::Input::KM_CTRL | Rml::Input::KM_META)))
                c.context->ProcessTextInput(Rml::Character(ch));
        } else
            c.context->ProcessKeyUp(id, modifiers);
        c.invalidate();
    });
}
API bool ataxia_rmlui_component_reload(void *p, const char *source, const char *path) {
    return checked([&] {
        auto &c = component(p);
        // Existing documents retain their stylesheet references. A replacement
        // must read edited external RCSS files instead of the previous cache.
        Rml::Factory::ClearStyleSheetCache();
        auto *replacement = c.context->LoadDocumentFromMemory(source, path);
        require(replacement, "Cannot parse replacement RML");
        for (const auto &entry : c.listeners) {
            auto parts = event_parts(entry.first);
            if (!replacement->GetElementById(parts.first)) {
                replacement->Close();
                throw std::runtime_error("Replacement is missing a bound callback element");
            }
        }
        auto *previous = c.doc;
        for (const auto &entry : c.listeners) {
            auto parts = event_parts(entry.first);
            if (auto *e = previous->GetElementById(parts.first))
                e->RemoveEventListener(parts.second, entry.second.get());
            replacement->GetElementById(parts.first)->AddEventListener(parts.second, entry.second.get());
        }
        c.doc = replacement;
        previous->Close();
        c.doc->Show();
        c.source_path = path;
        c.events.clear();
        c.invalidate();
    });
}
API void *ataxia_rmlui_gl_save() {
    GLGuard *result = nullptr;
    checked([&] {
        auto *version = reinterpret_cast<const char *>(glGetString(GL_VERSION));
        require(version && std::string(version).find("OpenGL ES 3.") != std::string::npos,
                "RmlUi requires a current OpenGL ES 3.0 or later graphics scope");
        result = new GLGuard;
    });
    return result;
}
API void ataxia_rmlui_gl_restore(void *state) { delete static_cast<GLGuard *>(state); }

static void set_model(Component &c, const std::string &name, const Rml::Variant &value) {
    if (c.model_values.find(name) == c.model_values.end()) {
        auto constructor = c.context->GetDataModel("state");
        require(constructor.BindFunc(
                    name, [&c, name](Rml::Variant &out) { out = c.model_values.at(name); },
                    [&c, name](const Rml::Variant &incoming) {
                        // Range controls emit change while applying model updates.
                        // Do not turn that echo into a second application command.
                        if (c.model_values.at(name).Get<Rml::String>() == incoming.Get<Rml::String>())
                            return;
                        c.model_values[name] = incoming;
                        c.model.DirtyVariable(name);
                        if (c.model_events.count(name))
                            c.queue("model:" + name, incoming.Get<Rml::String>());
                        c.invalidate();
                    }),
                "Cannot bind model variable");
    }
    c.model_values[name] = value;
    c.model.DirtyVariable(name);
    c.invalidate();
}
API bool ataxia_rmlui_model_string(void *p, const char *name, const char *value) {
    return checked([&] { set_model(component(p), name, Rml::Variant(Rml::String(value))); });
}
API bool ataxia_rmlui_model_number(void *p, const char *name, double value) {
    return checked([&] { set_model(component(p), name, Rml::Variant(value)); });
}
API bool ataxia_rmlui_model_boolean(void *p, const char *name, bool value) {
    return checked([&] { set_model(component(p), name, Rml::Variant(value)); });
}
API const char *ataxia_rmlui_model_value(void *p, const char *name) {
    const char *result = nullptr;
    checked([&] {
        auto &c = component(p);
        auto it = c.model_values.find(name);
        require(it != c.model_values.end(), "Unknown model variable");
        c.model_string = it->second.Get<Rml::String>();
        result = c.model_string.c_str();
    });
    return result;
}
API bool ataxia_rmlui_component_modifier_mask(void *p, int mask) {
    return checked([&] { component(p).modifiers = mask; });
}
