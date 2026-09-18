fn main() {
    #[cfg(feature = "metaworld-controls")]
    slint_build::compile("../../../worlds/metaworld/native/controls.slint")
        .expect("compile optional Metaworld controls");
}
