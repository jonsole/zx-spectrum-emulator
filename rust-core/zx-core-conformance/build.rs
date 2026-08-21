fn main() {
    // Compiles the EXACT same vendored core + shim the Python project's
    // cffi bindings use (zxspectrum/_native/shim.c wrapping
    // vendor/chips/z80.h), so this crate compares the new Rust core
    // against the real proven implementation, not a second reimplementation
    // of it.
    println!("cargo:rerun-if-changed=../../zxspectrum/_native/shim.c");
    println!("cargo:rerun-if-changed=../../zxspectrum/_native/shim.h");
    println!("cargo:rerun-if-changed=../../vendor/chips/z80.h");

    cc::Build::new()
        .file("../../zxspectrum/_native/shim.c")
        .include("../../zxspectrum/_native")
        .include("../../vendor/chips")
        .compile("zxshim");
}
