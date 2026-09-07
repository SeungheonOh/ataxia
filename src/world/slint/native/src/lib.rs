//! Slint interpreter host for World-owned native components.
//!
//! Each component renders through FemtoVG directly into a World-owned GLES
//! framebuffer. The compositor activates the context before entering here;
//! this bridge never creates a display, EGL context, or output surface.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::ffi::{c_void, CStr, CString};
use std::num::NonZeroU32;
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::ptr;
use std::rc::{Rc, Weak};

use i_slint_renderer_femtovg::{
    FemtoVGOpenGLRenderer, FemtoVGOpenGLRendererExt, FemtoVGRendererExt,
};
use slint::platform::femtovg_renderer::OpenGLInterface;
use slint::platform::{
    Key, Platform, PlatformError, PointerEventButton, Renderer, WindowAdapter, WindowEvent,
};
use slint::Window;
use slint::{LogicalPosition, PhysicalSize, SharedString, WindowSize};
use slint_interpreter::{Compiler, Value};
mod builtins;
use xkbcommon::xkb;

const GL_FRAMEBUFFER: u32 = 0x8D40;
const GL_FRAMEBUFFER_BINDING: u32 = 0x8CA6;
const GL_VIEWPORT: u32 = 0x0BA2;

thread_local! {
    static CURRENT_COMPONENT_FRAMEBUFFER: Cell<u32> = const { Cell::new(0) };
}

#[link(name = "GLESv2")]
unsafe extern "C" {
    fn glBindFramebuffer(target: u32, framebuffer: u32);
    fn glGetIntegerv(name: u32, value: *mut i32);
    fn glViewport(x: i32, y: i32, width: i32, height: i32);
}

unsafe extern "system" fn bind_component_framebuffer(target: u32, framebuffer: u32) {
    // FemtoVG targets framebuffer zero for a window; map that surfaceless target
    // to the component FBO while leaving its private layer FBOs untouched.
    let framebuffer = if framebuffer == 0 {
        CURRENT_COMPONENT_FRAMEBUFFER.with(Cell::get)
    } else {
        framebuffer
    };
    unsafe { glBindFramebuffer(target, framebuffer) };
}

#[link(name = "EGL")]
unsafe extern "C" {
    fn eglGetProcAddress(name: *const c_char) -> *const c_void;
}

#[link(name = "dl")]
unsafe extern "C" {
    fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
}

struct RenderTargetState {
    framebuffer: u32,
    width: Cell<u32>,
    height: Cell<u32>,
}

struct ComponentOpenGLTarget {
    state: Rc<RenderTargetState>,
}

unsafe impl OpenGLInterface for ComponentOpenGLTarget {
    fn ensure_current(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        CURRENT_COMPONENT_FRAMEBUFFER.with(|framebuffer| framebuffer.set(self.state.framebuffer));
        unsafe {
            glBindFramebuffer(GL_FRAMEBUFFER, self.state.framebuffer);
            glViewport(
                0,
                0,
                self.state.width.get() as i32,
                self.state.height.get() as i32,
            );
        }
        Ok(())
    }

    fn swap_buffers(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        CURRENT_COMPONENT_FRAMEBUFFER.with(|framebuffer| framebuffer.set(0));
        Ok(())
    }

    fn resize(
        &self,
        width: NonZeroU32,
        height: NonZeroU32,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.state.width.set(width.get());
        self.state.height.set(height.get());
        Ok(())
    }

    fn get_proc_address(&self, name: &CStr) -> *const c_void {
        if name.to_bytes() == b"glBindFramebuffer" {
            return bind_component_framebuffer as *const () as *const c_void;
        }
        let address = unsafe { dlsym(ptr::null_mut(), name.as_ptr()) };
        if address.is_null() {
            unsafe { eglGetProcAddress(name.as_ptr()) }
        } else {
            address.cast_const()
        }
    }
}

struct SavedGlTarget {
    framebuffer: i32,
    viewport: [i32; 4],
}

impl SavedGlTarget {
    fn capture() -> Self {
        let mut state = Self {
            framebuffer: 0,
            viewport: [0; 4],
        };
        unsafe {
            glGetIntegerv(GL_FRAMEBUFFER_BINDING, &mut state.framebuffer);
            glGetIntegerv(GL_VIEWPORT, state.viewport.as_mut_ptr());
        }
        state
    }
}

impl Drop for SavedGlTarget {
    fn drop(&mut self) {
        unsafe {
            glBindFramebuffer(GL_FRAMEBUFFER, self.framebuffer as u32);
            glViewport(
                self.viewport[0],
                self.viewport[1],
                self.viewport[2],
                self.viewport[3],
            );
        }
    }
}

struct AtaxiaWindow {
    window: Window,
    renderer: FemtoVGOpenGLRenderer,
    needs_redraw: Cell<bool>,
    size: Cell<PhysicalSize>,
}

impl AtaxiaWindow {
    fn new() -> Rc<Self> {
        Rc::new_cyclic(|weak: &Weak<Self>| Self {
            window: Window::new(weak.clone()),
            renderer: FemtoVGOpenGLRenderer::new_suspended(),
            needs_redraw: Cell::new(false),
            size: Cell::new(PhysicalSize::default()),
        })
    }

    fn render_if_needed(&self) -> Result<bool, PlatformError> {
        if !self.needs_redraw.replace(false) {
            return Ok(false);
        }
        if let Err(error) = self.renderer.render() {
            self.needs_redraw.set(true);
            return Err(error);
        }
        Ok(true)
    }

    fn set_size(&self, size: impl Into<WindowSize>) {
        self.window.set_size(size);
    }
}

impl WindowAdapter for AtaxiaWindow {
    fn window(&self) -> &Window {
        &self.window
    }

    fn renderer(&self) -> &dyn Renderer {
        &self.renderer
    }

    fn size(&self) -> PhysicalSize {
        self.size.get()
    }

    fn set_size(&self, size: WindowSize) {
        let scale = self.window.scale_factor();
        self.size.set(size.to_physical(scale));
        self.window.dispatch_event(WindowEvent::Resized {
            size: size.to_logical(scale),
        });
    }

    fn request_redraw(&self) {
        self.needs_redraw.set(true);
    }
}

impl std::ops::Deref for AtaxiaWindow {
    type Target = Window;

    fn deref(&self) -> &Self::Target {
        &self.window
    }
}

struct AtaxiaPlatform;

impl Platform for AtaxiaPlatform {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, PlatformError> {
        let window = AtaxiaWindow::new();
        PENDING_WINDOWS.with(|windows| windows.borrow_mut().push_back(window.clone()));
        Ok(window)
    }
}

pub struct NativeComponent {
    _instance: builtins::Instance,
    window: Rc<AtaxiaWindow>,
    callbacks: Rc<RefCell<VecDeque<CallbackEvent>>>,
    render_target: Option<Rc<RenderTargetState>>,
    width: u32,
    height: u32,
    scale: f32,
    revision: u64,
    xkb_state: xkb::State,
    pressed_keys: HashMap<u32, SharedString>,
}

struct CallbackEvent {
    name: CString,
    value: CString,
}

thread_local! {
    static PLATFORM_INSTALLED: Cell<bool> = const { Cell::new(false) };
    static PENDING_WINDOWS: RefCell<VecDeque<Rc<AtaxiaWindow>>> = const { RefCell::new(VecDeque::new()) };
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::new("").unwrap());
}

fn set_error(message: impl Into<String>) {
    let message = message.into().replace('\0', " ");
    LAST_ERROR.with(|error| {
        *error.borrow_mut() = CString::new(message).unwrap_or_default();
    });
}

fn clear_error() {
    set_error("");
}

fn c_string(value: impl Into<String>) -> CString {
    CString::new(value.into().replace('\0', " ")).unwrap_or_default()
}

fn callback_value(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(value)) => value.to_string(),
        Some(Value::Number(value)) => value.to_string(),
        Some(Value::Bool(value)) => value.to_string(),
        _ => String::new(),
    }
}

fn ffi_bool(operation: impl FnOnce() -> Result<(), String>) -> bool {
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(())) => {
            clear_error();
            true
        }
        Ok(Err(error)) => {
            set_error(error);
            false
        }
        Err(_) => {
            set_error("Slint host panicked");
            false
        }
    }
}

unsafe fn required_string(pointer: *const c_char, name: &str) -> Result<String, String> {
    if pointer.is_null() {
        return Err(format!("{name} is null"));
    }
    Ok(unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map_err(|error| format!("{name} is not UTF-8: {error}"))?
        .to_owned())
}

unsafe fn optional_string(pointer: *const c_char) -> Result<Option<String>, String> {
    if pointer.is_null() {
        return Ok(None);
    }
    let value = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map_err(|error| format!("string is not UTF-8: {error}"))?;
    Ok((!value.is_empty()).then(|| value.to_owned()))
}

unsafe fn component_mut<'a>(
    pointer: *mut NativeComponent,
) -> Result<&'a mut NativeComponent, String> {
    unsafe { pointer.as_mut() }.ok_or_else(|| "Slint component is null".to_owned())
}

fn install_platform() -> Result<(), String> {
    PLATFORM_INSTALLED.with(|installed| {
        if installed.get() {
            return Ok(());
        }
        slint::platform::set_platform(Box::new(AtaxiaPlatform))
            .map_err(|_| "another Slint platform is already installed".to_owned())?;
        installed.set(true);
        Ok(())
    })
}

thread_local! {
    static DEFAULT_KEYMAP: RefCell<Option<xkb::Keymap>> = const { RefCell::new(None) };
}

fn make_xkb_state() -> Result<xkb::State, String> {
    DEFAULT_KEYMAP.with(|cached| {
        let mut cached = cached.borrow_mut();
        if cached.is_none() {
            let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
            *cached = Some(
                xkb::Keymap::new_from_names(
                    &context,
                    "",
                    "",
                    "",
                    "",
                    None,
                    xkb::KEYMAP_COMPILE_NO_FLAGS,
                )
                .ok_or_else(|| "xkbcommon could not create the default keymap".to_owned())?,
            );
        }
        Ok(xkb::State::new(cached.as_ref().unwrap()))
    })
}

fn special_key(name: &str) -> Option<Key> {
    Some(match name {
        "BackSpace" => Key::Backspace,
        "Tab" => Key::Tab,
        "ISO_Left_Tab" => Key::Backtab,
        "Return" | "KP_Enter" => Key::Return,
        "Escape" => Key::Escape,
        "Delete" | "KP_Delete" => Key::Delete,
        "Shift_L" => Key::Shift,
        "Shift_R" => Key::ShiftR,
        "Control_L" => Key::Control,
        "Control_R" => Key::ControlR,
        "Alt_L" => Key::Alt,
        "Alt_R" | "ISO_Level3_Shift" => Key::AltGr,
        "Super_L" | "Meta_L" => Key::Meta,
        "Super_R" | "Meta_R" => Key::MetaR,
        "Caps_Lock" => Key::CapsLock,
        "Up" | "KP_Up" => Key::UpArrow,
        "Down" | "KP_Down" => Key::DownArrow,
        "Left" | "KP_Left" => Key::LeftArrow,
        "Right" | "KP_Right" => Key::RightArrow,
        "Insert" | "KP_Insert" => Key::Insert,
        "Home" | "KP_Home" => Key::Home,
        "End" | "KP_End" => Key::End,
        "Page_Up" | "KP_Page_Up" => Key::PageUp,
        "Page_Down" | "KP_Page_Down" => Key::PageDown,
        "F1" => Key::F1,
        "F2" => Key::F2,
        "F3" => Key::F3,
        "F4" => Key::F4,
        "F5" => Key::F5,
        "F6" => Key::F6,
        "F7" => Key::F7,
        "F8" => Key::F8,
        "F9" => Key::F9,
        "F10" => Key::F10,
        "F11" => Key::F11,
        "F12" => Key::F12,
        _ => return None,
    })
}

fn key_text(component: &mut NativeComponent, keycode: u32) -> SharedString {
    let code = xkb::Keycode::new(keycode + 8);
    let symbol = component.xkb_state.key_get_one_sym(code);
    let name = xkb::keysym_get_name(symbol);
    special_key(&name)
        .map(SharedString::from)
        .unwrap_or_else(|| component.xkb_state.key_get_utf8(code).into())
}

fn pointer_button(value: u32) -> PointerEventButton {
    match value {
        1 => PointerEventButton::Left,
        2 => PointerEventButton::Right,
        3 => PointerEventButton::Middle,
        4 => PointerEventButton::Back,
        5 => PointerEventButton::Forward,
        _ => PointerEventButton::Other,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ataxia_slint_abi_version() -> u32 {
    4
}

#[unsafe(no_mangle)]
pub extern "C" fn ataxia_slint_last_error() -> *const c_char {
    LAST_ERROR.with(|error| error.borrow().as_ptr())
}

#[unsafe(no_mangle)]
pub extern "C" fn ataxia_slint_initialize() -> bool {
    ffi_bool(install_platform)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_create(
    source: *const c_char,
    source_path: *const c_char,
    component_name: *const c_char,
    width: u32,
    height: u32,
    scale: f32,
) -> *mut NativeComponent {
    let operation = || -> Result<*mut NativeComponent, String> {
        install_platform()?;
        if width == 0 || height == 0 || !scale.is_finite() || scale <= 0.0 {
            return Err("Slint component size and scale must be positive".to_owned());
        }
        let source = unsafe { required_string(source, "source") }?;
        let source_path = unsafe { optional_string(source_path) }?
            .unwrap_or_else(|| "ataxia-component.slint".to_owned());
        let requested_name = unsafe { optional_string(component_name) }?;
        PENDING_WINDOWS.with(|windows| windows.borrow_mut().clear());
        let instance = if source_path.starts_with("ataxia-builtin:") {
            builtins::Instance::builtin(&source_path, requested_name.as_deref())?
        } else {
            let compiler = Compiler::default();
            let result = futures_lite::future::block_on(
                compiler.build_from_source(source.into(), PathBuf::from(source_path)),
            );
            let diagnostics = result.diagnostics().collect::<Vec<_>>();
            if diagnostics.iter().any(|diagnostic| {
                matches!(
                    diagnostic.level(),
                    slint_interpreter::DiagnosticLevel::Error
                )
            }) {
                return Err(diagnostics
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join("\n"));
            }
            let name = requested_name
                .or_else(|| result.component_names().next().map(str::to_owned))
                .ok_or_else(|| "Slint source exports no component".to_owned())?;
            let definition = result
                .component(&name)
                .ok_or_else(|| format!("Slint component {name:?} was not found"))?;
            builtins::Instance::Dynamic(definition.create().map_err(|error| error.to_string())?)
        };
        // Both generated and interpreted handles create their adapter lazily.
        instance.show().map_err(|error| error.to_string())?;
        let window = PENDING_WINDOWS
            .with(|windows| windows.borrow_mut().pop_front())
            .ok_or_else(|| "Slint did not request a World window adapter".to_owned())?;
        window.dispatch_event(WindowEvent::ScaleFactorChanged {
            scale_factor: scale,
        });
        window.set_size(PhysicalSize::new(width, height));
        window.request_redraw();
        let component = NativeComponent {
            _instance: instance,
            window,
            callbacks: Rc::new(RefCell::new(VecDeque::new())),
            render_target: None,
            width,
            height,
            scale,
            revision: 0,
            xkb_state: make_xkb_state()?,
            pressed_keys: HashMap::new(),
        };
        Ok(Box::into_raw(Box::new(component)))
    };
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(component)) => {
            clear_error();
            component
        }
        Ok(Err(error)) => {
            set_error(error);
            ptr::null_mut()
        }
        Err(_) => {
            set_error("Slint component creation panicked");
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_destroy(component: *mut NativeComponent) {
    if !component.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            drop(unsafe { Box::from_raw(component) })
        }));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_resize(
    component: *mut NativeComponent,
    width: u32,
    height: u32,
    scale: f32,
) -> bool {
    ffi_bool(|| {
        let component = unsafe { component_mut(component) }?;
        if width == 0 || height == 0 || !scale.is_finite() || scale <= 0.0 {
            return Err("Slint component size and scale must be positive".to_owned());
        }
        component.width = width;
        component.height = height;
        component.scale = scale;
        if let Some(target) = &component.render_target {
            target.width.set(width);
            target.height.set(height);
        }
        component
            .window
            .dispatch_event(WindowEvent::ScaleFactorChanged {
                scale_factor: scale,
            });
        component.window.set_size(PhysicalSize::new(width, height));
        component.window.request_redraw();
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_attach_graphics(
    component: *mut NativeComponent,
    framebuffer: u32,
) -> bool {
    ffi_bool(|| {
        let component = unsafe { component_mut(component) }?;
        if framebuffer == 0 {
            return Err("Slint framebuffer is zero".to_owned());
        }
        if component.render_target.is_some() {
            return Err("Slint component graphics are already attached".to_owned());
        }
        let target = Rc::new(RenderTargetState {
            framebuffer,
            width: Cell::new(component.width),
            height: Cell::new(component.height),
        });
        component
            .window
            .renderer
            .set_opengl_context(ComponentOpenGLTarget {
                state: target.clone(),
            })
            .map_err(|error| error.to_string())?;
        component.render_target = Some(target);
        component.window.request_redraw();
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_detach_graphics(
    component: *mut NativeComponent,
) -> bool {
    ffi_bool(|| {
        let component = unsafe { component_mut(component) }?;
        if component.render_target.is_some() {
            let _saved_target = SavedGlTarget::capture();
            let result = component
                .window
                .renderer
                .clear_graphics_context()
                .map_err(|error| error.to_string());
            CURRENT_COMPONENT_FRAMEBUFFER.with(|framebuffer| framebuffer.set(0));
            result?;
            component.render_target = None;
        }
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_render(component: *mut NativeComponent) -> bool {
    ffi_bool(|| {
        let component = unsafe { component_mut(component) }?;
        if component.render_target.is_none() {
            return Err("Slint component graphics are not attached".to_owned());
        }
        let _saved_target = SavedGlTarget::capture();
        let result = component
            .window
            .render_if_needed()
            .map_err(|error| error.to_string());
        CURRENT_COMPONENT_FRAMEBUFFER.with(|framebuffer| framebuffer.set(0));
        if result? {
            component.revision = component.revision.wrapping_add(1);
        }
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_width(component: *mut NativeComponent) -> u32 {
    unsafe { component.as_ref() }.map_or(0, |component| component.width)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_height(component: *mut NativeComponent) -> u32 {
    unsafe { component.as_ref() }.map_or(0, |component| component.height)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_revision(component: *mut NativeComponent) -> u64 {
    unsafe { component.as_ref() }.map_or(0, |component| component.revision)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_has_active_animations(
    component: *mut NativeComponent,
) -> bool {
    unsafe { component.as_ref() }
        .is_some_and(|component| component.window.window.has_active_animations())
}

#[unsafe(no_mangle)]
pub extern "C" fn ataxia_slint_update_timers() {
    let _ = catch_unwind(AssertUnwindSafe(
        slint::platform::update_timers_and_animations,
    ));
}

#[unsafe(no_mangle)]
pub extern "C" fn ataxia_slint_next_timer_milliseconds() -> u64 {
    slint::platform::duration_until_next_timer_update().map_or(u64::MAX, |duration| {
        duration.as_millis().min(u64::MAX as u128) as u64
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_pointer_motion(
    component: *mut NativeComponent,
    x: f32,
    y: f32,
) -> bool {
    ffi_bool(|| {
        let component = unsafe { component_mut(component) }?;
        component
            .window
            .try_dispatch_event(WindowEvent::PointerMoved {
                position: LogicalPosition::new(x, y),
            })
            .map_err(|error| error.to_string())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_pointer_button(
    component: *mut NativeComponent,
    x: f32,
    y: f32,
    button: u32,
    pressed: bool,
) -> bool {
    ffi_bool(|| {
        let component = unsafe { component_mut(component) }?;
        let position = LogicalPosition::new(x, y);
        let button = pointer_button(button);
        let event = if pressed {
            WindowEvent::PointerPressed { position, button }
        } else {
            WindowEvent::PointerReleased { position, button }
        };
        component
            .window
            .try_dispatch_event(event)
            .map_err(|error| error.to_string())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_pointer_scroll(
    component: *mut NativeComponent,
    x: f32,
    y: f32,
    delta_x: f32,
    delta_y: f32,
) -> bool {
    ffi_bool(|| {
        let component = unsafe { component_mut(component) }?;
        component
            .window
            .try_dispatch_event(WindowEvent::PointerScrolled {
                position: LogicalPosition::new(x, y),
                delta_x,
                delta_y,
            })
            .map_err(|error| error.to_string())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_pointer_exit(
    component: *mut NativeComponent,
) -> bool {
    ffi_bool(|| {
        let component = unsafe { component_mut(component) }?;
        component
            .window
            .try_dispatch_event(WindowEvent::PointerExited)
            .map_err(|error| error.to_string())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_focus(
    component: *mut NativeComponent,
    focused: bool,
) -> bool {
    ffi_bool(|| {
        let component = unsafe { component_mut(component) }?;
        if !focused {
            for text in component.pressed_keys.drain().map(|(_, text)| text) {
                component
                    .window
                    .try_dispatch_event(WindowEvent::KeyReleased { text })
                    .map_err(|error| error.to_string())?;
            }
            component.xkb_state.update_mask(0, 0, 0, 0, 0, 0);
        }
        component
            .window
            .try_dispatch_event(WindowEvent::WindowActiveChanged(focused))
            .map_err(|error| error.to_string())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_modifiers(
    component: *mut NativeComponent,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) -> bool {
    ffi_bool(|| {
        let component = unsafe { component_mut(component) }?;
        component
            .xkb_state
            .update_mask(depressed, latched, locked, 0, 0, group);
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_key(
    component: *mut NativeComponent,
    keycode: u32,
    pressed: bool,
    repeated: bool,
) -> bool {
    ffi_bool(|| {
        let component = unsafe { component_mut(component) }?;
        let text = if pressed {
            let text = key_text(component, keycode);
            component.pressed_keys.insert(keycode, text.clone());
            text
        } else {
            component
                .pressed_keys
                .remove(&keycode)
                .unwrap_or_else(|| key_text(component, keycode))
        };
        if text.is_empty() {
            return Ok(());
        }
        let event = if pressed && repeated {
            WindowEvent::KeyPressRepeated { text }
        } else if pressed {
            WindowEvent::KeyPressed { text }
        } else {
            WindowEvent::KeyReleased { text }
        };
        component
            .window
            .try_dispatch_event(event)
            .map_err(|error| error.to_string())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_set_string(
    component: *mut NativeComponent,
    name: *const c_char,
    value: *const c_char,
) -> bool {
    ffi_bool(|| {
        let component = unsafe { component_mut(component) }?;
        let name = unsafe { required_string(name, "property name") }?;
        let value = unsafe { required_string(value, "property value") }?;
        component
            ._instance
            .set_property(&name, SharedString::from(value).into())
            .map_err(|error| error.to_string())?;
        component.window.request_redraw();
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_set_number(
    component: *mut NativeComponent,
    name: *const c_char,
    value: f64,
) -> bool {
    ffi_bool(|| {
        let component = unsafe { component_mut(component) }?;
        let name = unsafe { required_string(name, "property name") }?;
        component
            ._instance
            .set_property(&name, value.into())
            .map_err(|error| error.to_string())?;
        component.window.request_redraw();
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_set_boolean(
    component: *mut NativeComponent,
    name: *const c_char,
    value: bool,
) -> bool {
    ffi_bool(|| {
        let component = unsafe { component_mut(component) }?;
        let name = unsafe { required_string(name, "property name") }?;
        component
            ._instance
            .set_property(&name, value.into())
            .map_err(|error| error.to_string())?;
        component.window.request_redraw();
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_register_callback(
    component: *mut NativeComponent,
    name: *const c_char,
) -> bool {
    ffi_bool(|| {
        let component = unsafe { component_mut(component) }?;
        let name = unsafe { required_string(name, "callback name") }?;
        let event_name = name.clone();
        let callbacks = component.callbacks.clone();
        component
            ._instance
            .set_callback(&name, move |arguments| {
                callbacks.borrow_mut().push_back(CallbackEvent {
                    name: c_string(event_name.clone()),
                    value: c_string(callback_value(arguments.first())),
                });
                Value::Void
            })
            .map_err(|error| error.to_string())?;
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_unregister_callback(
    component: *mut NativeComponent,
    name: *const c_char,
) -> bool {
    ffi_bool(|| {
        let component = unsafe { component_mut(component) }?;
        let name = unsafe { required_string(name, "callback name") }?;
        component
            ._instance
            .set_callback(&name, |_| Value::Void)
            .map_err(|error| error.to_string())?;
        component
            .callbacks
            .borrow_mut()
            .retain(|event| event.name.to_bytes() != name.as_bytes());
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_callback_count(
    component: *mut NativeComponent,
) -> usize {
    unsafe { component.as_ref() }.map_or(0, |component| component.callbacks.borrow().len())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_callback_name(
    component: *mut NativeComponent,
    index: usize,
) -> *const c_char {
    unsafe { component.as_ref() }
        .and_then(|component| {
            component
                .callbacks
                .borrow()
                .get(index)
                .map(|event| event.name.as_ptr())
        })
        .unwrap_or(ptr::null())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_callback_value(
    component: *mut NativeComponent,
    index: usize,
) -> *const c_char {
    unsafe { component.as_ref() }
        .and_then(|component| {
            component
                .callbacks
                .borrow()
                .get(index)
                .map(|event| event.value.as_ptr())
        })
        .unwrap_or(ptr::null())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ataxia_slint_component_clear_callbacks(component: *mut NativeComponent) {
    if let Some(component) = unsafe { component.as_ref() } {
        component.callbacks.borrow_mut().clear();
    }
}
