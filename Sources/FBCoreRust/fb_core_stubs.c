// FBCoreRust cTarget anchor. The actual implementation is the Rust staticlib
// built by the FBCoreRustBuilder plugin (cargo build --release -> libfb_core.a).
// This file exists so SPM treats Sources/FBCoreRust as a buildable C target that
// exposes the committed fb_core.h via the module.modulemap. No C code here.
