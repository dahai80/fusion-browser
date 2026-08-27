#ifndef FB_CORE_H
#define FB_CORE_H

#include <stdint.h>
#include <stddef.h>

// fb_core — Rust AXTree compiler C-ABI (PRD §4.3 module 5).
// Ownership: Rust allocates the output buffer; the caller MUST release it
// with fb_core_free exactly once. Never free with free() — different allocator.

#define FB_OK         0
#define FB_ERR_PANIC  1
#define FB_ERR_DECODE 2

// Decode walker JSON (in, in_len) -> combined {markdown,nodes,audit} JSON.
// On FB_OK: *out/*out_len hold a Rust-allocated buffer (free with fb_core_free).
// FB_ERR_DECODE: bad JSON. FB_ERR_PANIC: Rust panic (caught).
int32_t fb_core_compile(const uint8_t* in, uintptr_t in_len,
                        uint8_t** out, uintptr_t* out_len);

// Release a Rust-allocated buffer from fb_core_compile. Safe on null.
void fb_core_free(uint8_t* ptr, uintptr_t len);

// Coarse token heuristic for a markdown buffer.
uint32_t fb_core_estimate_tokens(const uint8_t* md, uintptr_t md_len);

// Packed version 0xMM_mm_pp.
int32_t fb_core_version(void);

#endif /* FB_CORE_H */
