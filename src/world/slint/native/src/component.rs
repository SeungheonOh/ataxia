//! Dynamic components are available in every build. Concrete Worlds may opt
//! into compiled controls without making their assets an engine dependency.
use slint::{ComponentHandle, PlatformError};
use slint_interpreter::{ComponentInstance, Value};

#[cfg(feature = "metaworld-controls")]
#[path = "../../../../worlds/metaworld/native/controls.rs"]
mod metaworld;

pub enum Instance {
    Dynamic(ComponentInstance),
    #[cfg(feature = "metaworld-controls")]
    Metaworld(metaworld::Instance),
}

impl Instance {
    pub fn builtin(path: &str, name: Option<&str>) -> Result<Self, String> {
        #[cfg(feature = "metaworld-controls")]
        {
            metaworld::Instance::builtin(path, name).map(Self::Metaworld)
        }
        #[cfg(not(feature = "metaworld-controls"))]
        {
            Err(format!(
                "No compiled World controls in this build: {path} {name:?}"
            ))
        }
    }

    pub fn show(&self) -> Result<(), PlatformError> {
        match self {
            Self::Dynamic(component) => component.show(),
            #[cfg(feature = "metaworld-controls")]
            Self::Metaworld(component) => component.show(),
        }
    }

    pub fn set_property(&self, name: &str, value: Value) -> Result<(), String> {
        match self {
            Self::Dynamic(component) => {
                component.set_property(name, value).map_err(|e| e.to_string())
            }
            #[cfg(feature = "metaworld-controls")]
            Self::Metaworld(component) => component.set_property(name, value),
        }
    }

    pub fn set_callback(
        &self,
        name: &str,
        callback: impl Fn(&[Value]) -> Value + 'static,
    ) -> Result<(), String> {
        match self {
            Self::Dynamic(component) => {
                component.set_callback(name, callback).map_err(|e| e.to_string())
            }
            #[cfg(feature = "metaworld-controls")]
            Self::Metaworld(component) => component.set_callback(name, callback),
        }
    }
}
