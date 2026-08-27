// FFI status codes — must stay in sync with fb_core.h.
pub const FB_OK: i32 = 0;
pub const FB_ERR_PANIC: i32 = 1;
pub const FB_ERR_DECODE: i32 = 2;

// Semantic version packed as 0xMM_mm_pp (major, minor, patch).
pub const FB_VERSION: i32 = 0x0001_0000;
