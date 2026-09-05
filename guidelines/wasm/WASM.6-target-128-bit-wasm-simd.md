+++
id = "WASM.6"
title = "Target 128-bit wasm SIMD explicitly and avoid the operations engines emulate"
category = "wasm"
status = "draft"
summary = "wasm SIMD is a fixed 128-bit width with a documented set of badly lowering instructions; the payoff is large, and relaxed SIMD buys speed by giving up determinism."
tags = ["simd128", "relaxed-simd", "vectorisation", "emscripten", "determinism"]
+++

## Rationale

WebAssembly SIMD is a **fixed 128-bit width**. There is no AVX-512-style
widening and no SVE-style scalable vector, so much of the `simd` category's
guidance about ISA targeting, dispatch across vector widths, and predication
does not apply, and portable-abstraction libraries buy correspondingly less.

The payoff for using it is nonetheless large: Adobe reports wasm SIMD giving
Photoshop on the web a **3–4× speedup on average, and 80–160× in some cases**,
chiefly through their Halide image-processing kernels.

The sharp edge is that a handful of instructions do not map onto host hardware
and are emulated at a documented, substantial cost. `f32x4.min` and `f32x4.max`
are the trap most likely to catch a numerical kernel: WebAssembly's NaN
propagation semantics do not match the x86 instruction, so V8 emulates them with
7–10 instructions, while `pmin` and `pmax` lower cleanly.

Relaxed SIMD offers to close some of these gaps by permitting
defined-but-varying results across engines. That is a deliberate trade of
**determinism** for speed, and it must be a recorded decision rather than a flag
someone adds to a build.

## Guidance

- **Compile with `-msimd128` and gate on `__wasm_simd128__`.** The macro is the
  portable way to keep a scalar path compiling.
- **Prefer `pmin`/`pmax` over `min`/`max` for floats** unless you need
  WebAssembly's exact NaN semantics. This is the single highest-value
  substitution.
- **Avoid the documented slow paths on x86:** `i8x16` shifts (5–11 instructions —
  widen to `i16x8`), `i64x2.shr_s` (6–12), `i8x16.mul` and `i64x2.mul` (~10),
  and the saturating float-to-int conversions.
- **Use constant shift amounts.** Variable shifts add bounds checking.
- **Prefer `i8x16.shuffle` over `i8x16.swizzle`** when indices are compile-time
  constants; a non-constant swizzle costs extra instructions.
- **Keep everything 128-bit wide on ARM.** Any operation that is not a "q"
  variant is scalarized.
- **Treat relaxed SIMD as a determinism decision.** If reproducibility is a
  requirement, `-mrelaxed-simd` is off, and the reason belongs in the build.
- **Disable autovectorization when hand-writing** with `-fno-vectorize
  -fno-slp-vectorize`, so the compiler does not undo the layout you chose.
- **Ship a scalar variant.** A SIMD module fails to instantiate where SIMD is
  unavailable; see `WASM.13`.

## Example

```cpp
#include <wasm_simd128.h>

// The min/max trap. This looks like the obvious clamp and is one of the most
// expensive things you can write in a wasm SIMD kernel on x86: WebAssembly's
// NaN propagation does not match the hardware instruction, so V8 emulates each
// of these with roughly 7-10 instructions.
inline v128_t clamp_slow(v128_t x, v128_t lo, v128_t hi) noexcept {
    return wasm_f32x4_min(wasm_f32x4_max(x, lo), hi);      // ~14-20 instructions
}

// The same clamp with pseudo-min/max, which lower to a single hardware
// instruction each. The difference is NaN handling: pmin/pmax return the second
// operand when either input is NaN. For a clamp over known-finite data that is
// not merely acceptable, it is irrelevant.
inline v128_t clamp_fast(v128_t x, v128_t lo, v128_t hi) noexcept {
    return wasm_f32x4_pmin(wasm_f32x4_pmax(x, lo), hi);    // 2 instructions
}

// A worked kernel: premultiply RGBA by alpha, four pixels at a time. Note the
// widening to i16x8 for the multiply -- i8x16.mul is emulated at ~10
// instructions, so the widen-multiply-narrow sequence is cheaper than the
// operation it replaces.
void premultiply(std::span<std::uint8_t> rgba) noexcept {
#ifdef __wasm_simd128__
    const std::size_t vector_count = rgba.size() / 16;      // 16 bytes = 4 pixels

    for (std::size_t i = 0; i != vector_count; ++i) {
        std::uint8_t* p = rgba.data() + i * 16;
        const v128_t pixels = wasm_v128_load(p);

        // Widen to 16-bit lanes: the 8-bit multiply is emulated, the 16-bit one
        // is not. Two halves, each holding 8 lanes of 16 bits.
        const v128_t lo = wasm_u16x8_extend_low_u8x16(pixels);
        const v128_t hi = wasm_u16x8_extend_high_u8x16(pixels);

        // Shuffle indices are compile-time constants, so this is a shuffle
        // rather than a swizzle -- broadcast each pixel's alpha across its
        // three colour lanes.
        const v128_t alpha_lo = wasm_i16x8_shuffle(lo, lo, 3, 3, 3, 3, 7, 7, 7, 7);
        const v128_t alpha_hi = wasm_i16x8_shuffle(hi, hi, 3, 3, 3, 3, 7, 7, 7, 7);

        // (c * a + 127) / 255, approximated as (c * a * 257 + 257) >> 16.
        // The shift amount is a literal: a variable shift would add a bounds
        // check on every lane.
        const v128_t scaled_lo = wasm_u16x8_shr(wasm_i16x8_mul(lo, alpha_lo), 8);
        const v128_t scaled_hi = wasm_u16x8_shr(wasm_i16x8_mul(hi, alpha_hi), 8);

        wasm_v128_store(p, wasm_u8x16_narrow_i16x8(scaled_lo, scaled_hi));
    }

    premultiply_scalar(rgba.subspan(vector_count * 16));    // tail
#else
    premultiply_scalar(rgba);        // still compiles without -msimd128
#endif
}

// Relaxed SIMD changes results, not just speed. If this build ships, the
// decision belongs somewhere a reviewer will see it.
//
//   #ifdef __wasm_relaxed_simd__
//   #  error "relaxed SIMD produces engine-dependent results; this product \
//             asserts bit-identical output across browsers. See packet NNN."
//   #endif
```

## Caveats

- **Measure before hand-writing.** Autovectorization handles simple loops well;
  intrinsics are a maintenance cost that must be earned.
- **`pmin`/`pmax` are not `min`/`max`.** They differ on NaN and on signed zero.
  If your data can contain either and the distinction matters, take the slow
  path deliberately.
- **The emulated-instruction list is engine- and version-specific.** It reflects
  V8 on x86 at the time of writing; check the current Emscripten documentation
  rather than treating this list as permanent.
- **Photoshop's 80–160× figures are outliers**, drawn from image kernels that
  vectorise nearly perfectly. The 3–4× average is the number to plan against.
- **Fixed 128-bit width caps the ceiling.** Code that would use 512-bit vectors
  natively will not reach native throughput here regardless of effort.
- **Relaxed SIMD failures are silent.** Results differ rather than erroring, so
  the divergence surfaces as a rendering artifact or a failed hash, far from
  the build flag that caused it.

## References

- [Emscripten — Using SIMD with WebAssembly](https://emscripten.org/docs/porting/simd.html)
- [Chrome/Adobe — Photoshop's journey to the web](https://web.dev/articles/ps-on-the-web)
- [WebAssembly — Feature status](https://webassembly.org/features/)
- [Unity — Web performance considerations](https://docs.unity3d.com/6000.4/Documentation/Manual/webgl-performance.html)
- Cross-reference: `SIMD.1` (autovectorisation vs intrinsics), `SIMD.3`
  (portable SIMD libraries), `SIMD.7` (masks and predication — largely inapplicable at fixed
  width), `WASM.13` (shipping a scalar variant).
