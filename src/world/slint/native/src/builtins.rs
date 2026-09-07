//! Fixed controls are compiled by build.rs. Arbitrary agent widgets still use
//! the interpreter. Both remain owned by the compositor thread.
use slint::{ComponentHandle, PlatformError};
use slint_interpreter::{ComponentInstance, Value};

mod ui {
    slint::include_modules!();
}

pub enum Instance {
    Dynamic(ComponentInstance),
    Header(ui::SubworldHeader),
    Toolbar(ui::MetaworldToolbar),
    GroupControls(ui::SubworldControls),
    CanvasMenu(ui::CanvasCreation),
    WindowControls(ui::ObjectControls),
    Note(ui::MetaworldNote),
}

impl Instance {
    pub fn builtin(path: &str, name: Option<&str>) -> Result<Self, String> {
        match path {
            "ataxia-builtin:header" if name.is_none() || name == Some("SubworldHeader") => {
                ui::SubworldHeader::new()
                    .map(Self::Header)
                    .map_err(|e| e.to_string())
            }
            "ataxia-builtin:toolbar" if name.is_none() || name == Some("MetaworldToolbar") => {
                ui::MetaworldToolbar::new()
                    .map(Self::Toolbar)
                    .map_err(|e| e.to_string())
            }
            "ataxia-builtin:group-controls"
                if name.is_none() || name == Some("SubworldControls") =>
            {
                ui::SubworldControls::new()
                    .map(Self::GroupControls)
                    .map_err(|e| e.to_string())
            }
            "ataxia-builtin:canvas-menu" if name.is_none() || name == Some("CanvasCreation") => {
                ui::CanvasCreation::new()
                    .map(Self::CanvasMenu)
                    .map_err(|e| e.to_string())
            }
            "ataxia-builtin:window-controls"
                if name.is_none() || name == Some("ObjectControls") =>
            {
                ui::ObjectControls::new()
                    .map(Self::WindowControls)
                    .map_err(|e| e.to_string())
            }
            "ataxia-builtin:note" if name.is_none() || name == Some("MetaworldNote") => {
                ui::MetaworldNote::new()
                    .map(Self::Note)
                    .map_err(|e| e.to_string())
            }
            _ => Err(format!("Unknown built-in component: {path} {name:?}")),
        }
    }

    pub fn show(&self) -> Result<(), PlatformError> {
        match self {
            Self::Dynamic(ui) => ui.show(),
            Self::Header(ui) => ui.show(),
            Self::Toolbar(ui) => ui.show(),
            Self::GroupControls(ui) => ui.show(),
            Self::CanvasMenu(ui) => ui.show(),
            Self::WindowControls(ui) => ui.show(),
            Self::Note(ui) => ui.show(),
        }
    }

    pub fn set_property(&self, name: &str, value: Value) -> Result<(), String> {
        match (self, name, value) {
            (Self::Dynamic(ui), name, value) => {
                return ui.set_property(name, value).map_err(|e| e.to_string())
            }
            (Self::Header(ui), "caption", Value::String(value)) => ui.set_caption(value),
            (Self::Header(ui), "active", Value::Bool(value)) => ui.set_active(value),
            (Self::Toolbar(ui), "caption", Value::String(value)) => ui.set_caption(value),
            (Self::Toolbar(ui), "active", Value::Bool(value)) => ui.set_active(value),
            (Self::Toolbar(ui), "standalone", Value::Bool(value)) => ui.set_standalone(value),
            (Self::Toolbar(ui), "workspace", Value::Number(value))
                if value.is_finite()
                    && value.fract() == 0.0
                    && value >= i32::MIN as f64
                    && value <= i32::MAX as f64 =>
            {
                ui.set_workspace(value as i32)
            }
            (Self::GroupControls(ui), "world-name", Value::String(value)) => {
                ui.set_world_name(value)
            }
            (Self::GroupControls(ui), "policy", Value::String(value)) => ui.set_policy(value),
            (Self::GroupControls(ui), "confirming", Value::Bool(value)) => ui.set_confirming(value),
            (Self::GroupControls(ui), "standalone", Value::Bool(value)) => ui.set_standalone(value),
            (Self::WindowControls(ui), "expanded", Value::Bool(value)) => ui.set_expanded(value),
            (Self::WindowControls(ui), "owned", Value::Bool(value)) => ui.set_owned(value),
            (Self::WindowControls(ui), "detachable", Value::Bool(value)) => {
                ui.set_detachable(value)
            }
            (Self::WindowControls(ui), "niri", Value::Bool(value)) => ui.set_niri(value),
            (Self::WindowControls(ui), "floating", Value::Bool(value)) => ui.set_floating(value),
            (Self::Note(ui), "content", Value::String(value)) => ui.set_content(value),
            _ => {
                return Err(format!(
                    "Unknown built-in property or incorrect type: {name}"
                ))
            }
        }
        Ok(())
    }

    pub fn set_callback(
        &self,
        name: &str,
        callback: impl Fn(&[Value]) -> Value + 'static,
    ) -> Result<(), String> {
        match (self, name) {
            (Self::Dynamic(ui), name) => {
                return ui.set_callback(name, callback).map_err(|e| e.to_string())
            }
            (Self::Header(ui), "enter") => ui.on_enter(move || {
                callback(&[]);
            }),
            (Self::Toolbar(ui), "action") => ui.on_action(move |value| {
                callback(&[Value::String(value)]);
            }),
            (Self::GroupControls(ui), "action") => ui.on_action(move |value| {
                callback(&[Value::String(value)]);
            }),
            (Self::GroupControls(ui), "rename") => ui.on_rename(move |value| {
                callback(&[Value::String(value)]);
            }),
            (Self::CanvasMenu(ui), "action") => ui.on_action(move |value| {
                callback(&[Value::String(value)]);
            }),
            (Self::WindowControls(ui), "action") => ui.on_action(move |value| {
                callback(&[Value::String(value)]);
            }),
            (Self::Note(ui), "edited") => ui.on_edited(move |value| {
                callback(&[Value::String(value)]);
            }),
            (Self::Note(ui), "close") => ui.on_close(move || {
                callback(&[]);
            }),
            _ => return Err(format!("Unknown built-in callback: {name}")),
        }
        Ok(())
    }
}
