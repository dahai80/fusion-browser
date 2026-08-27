// fb_core — Rust AXTree compiler (PRD §4.3 module 5). C-ABI FFI.
// Ownership: Rust-allocates output (Box::into_raw), Swift copies + calls
// fb_core_free (Box::from_raw). Every export wraps catch_unwind -> FB_ERR_PANIC.
#![allow(clippy::missing_safety_doc)]

pub mod compile;
mod error;
pub mod markdown;
mod token;

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;

use error::{FB_ERR_DECODE, FB_ERR_PANIC, FB_OK, FB_VERSION};

// Allocate an output buffer Swift will free via fb_core_free.
// into_boxed_slice gives a Box<[u8]> (fat ptr carrying len); we hand Swift the
// thin data ptr + the len separately, then reconstruct the fat ptr on free.
fn box_output(bytes: Vec<u8>) -> (*mut u8, usize) {
    let len = bytes.len();
    let boxed: Box<[u8]> = bytes.into_boxed_slice();
    let ptr = Box::into_raw(boxed) as *mut u8;
    (ptr, len)
}

// fb_core_compile: decode walker JSON -> combined {markdown,nodes,audit} JSON.
// Rust allocates *out; Swift MUST release with fb_core_free exactly once.
//
// # Safety
// `in_ptr` must point to `in_len` readable bytes. `out`/`out_len` must be valid
// write slots. On FB_OK, *out is Rust-owned and must be freed via fb_core_free.
#[no_mangle]
pub unsafe extern "C" fn fb_core_compile(
    in_ptr: *const u8,
    in_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let guard = AssertUnwindSafe(|| {
        let input = slice::from_raw_parts(in_ptr, in_len);
        let bytes = compile::compile(input)?;
        let (ptr, len) = box_output(bytes);
        *out = ptr;
        *out_len = len;
        Ok::<(), serde_json::Error>(())
    });
    match catch_unwind(guard) {
        Ok(Ok(())) => FB_OK,
        Ok(Err(_)) => FB_ERR_DECODE,
        Err(_) => FB_ERR_PANIC,
    }
}

// fb_core_free: release a Rust-allocated buffer from fb_core_compile.
//
// # Safety
// `ptr`/`len` must be exactly the pair returned by fb_core_compile, freed once.
#[no_mangle]
pub unsafe extern "C" fn fb_core_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    let _ = catch_unwind(|| {
        // Reconstruct the Box<[u8]> fat ptr from the thin data ptr + recorded len.
        let slice_ptr = slice::from_raw_parts_mut(ptr, len) as *mut [u8];
        drop(Box::from_raw(slice_ptr));
    });
}

// fb_core_estimate_tokens: coarse token heuristic for markdown.
#[no_mangle]
pub unsafe extern "C" fn fb_core_estimate_tokens(md_ptr: *const u8, md_len: usize) -> u32 {
    let guard = AssertUnwindSafe(|| {
        let md = slice::from_raw_parts(md_ptr, md_len);
        let s = std::str::from_utf8(md).unwrap_or("");
        token::estimate_tokens(s)
    });
    catch_unwind(guard).unwrap_or(0)
}

// fb_core_version: packed 0xMM_mm_pp.
#[no_mangle]
pub extern "C" fn fb_core_version() -> i32 {
    FB_VERSION
}
