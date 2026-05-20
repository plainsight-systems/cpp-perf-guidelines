+++
id = "SIMD.3"
title = "Use a portable SIMD library when you ship multiple ISAs"
category = "simd"
status = "draft"
summary = "Highway, xsimd, and Eve let one source compile to NEON, AVX, AVX-512, and SVE. The maintenance cost of N intrinsics dialects is the reason these libraries exist."
tags = ["highway", "xsimd", "eve", "portable-simd"]
+++

## Rationale

A modern game engine ships on x86_64 (AVX-2, sometimes AVX-512) and
Apple Silicon (NEON, soon SME), and an embedded codebase may also ship
to ARM Cortex-A (NEON / SVE) or AWS Graviton (NEON / SVE). Writing
intrinsics directly means **one kernel per ISA family** — three to five
parallel implementations, three to five sets of tests, three to five
performance regressions waiting to happen.

The portable SIMD libraries exist precisely to amortise this cost:

| Library | License | Best for | Notable design |
|---|---|---|---|
| **Google Highway** | Apache-2.0 | Production cross-ISA, including SVE / RVV scalable | `Vec<D>` tagged by descriptor `D = ScalableTag<float>`; same source compiles fixed and scalable. Used by JPEG XL, Chrome. |
| **xsimd** | BSD-3-Clause | Header-only, easy drop-in for numeric kernels | Explicit batch type `batch<T, A>`; clean API; used by xtensor. |
| **Eve** | BSL-1.0 | C++20-style, range-friendly | Function-first (`eve::add`, `eve::reduce`); composes with ranges. |
| **`std::simd`** | (standard) | Future-proof — C++26 | Subset of the above, standardised. |

The choice between them is real engineering. Highway is the most
production-hardened and the only one with first-class scalable-vector
support (SVE, RISC-V V); xsimd is the smallest dependency and the
easiest to drop in; Eve is the most modern-C++ in style. `std::simd`
is on track to absorb most of what they do once C++26 toolchain
support is universal.

The autovectoriser still does a great deal of work and should be the
default (`SIMD.1`); a portable SIMD library is the layer above it for
the cases the autovectoriser refuses but you do not want intrinsics'
maintenance burden.

## Guidance

- **If you ship multiple ISAs, use a portable SIMD library** rather
  than writing N intrinsic kernels.
- **Choose by requirement, not taste:**
  - Need SVE / RVV scalable today, or already use it in production
    code that bigger consumers (Chrome, JPEG XL) trust → **Highway**.
  - Want minimal dependencies for NEON + AVX numeric kernels →
    **xsimd**.
  - Want C++20-style ergonomics, range composition →
    **Eve**.
  - Can wait for C++26 toolchain rollout → start writing
    `std::experimental::simd` today (libstdc++ ships it since GCC 11).
- **Wrap the library at the kernel boundary.** The rest of the codebase
  passes `std::span` / `std::byte` / plain pointers; the kernel is the
  only place the library type appears. Limits blast radius if you
  change libraries.
- **Test on every ISA you ship.** A portable library compiles
  everywhere; correctness still needs CI on each target. NEON
  semantics on saturation differ from AVX; SVE's scalable width may
  not equal what your fixed-width tests assumed.
- **Do not mix two libraries.** Pick one; the cost of two abstractions
  for the same job is the cost of the one you were trying to avoid.

## Example

```cpp
// Highway: one source, every ISA. The `HWY_FULL` tag (or
// `ScalableTag<float>`) picks the right vector width for the target;
// the loop runs at AVX-2 speed on Haswell, AVX-512 on Sapphire
// Rapids, NEON on M-series, SVE on Graviton — with no source changes.
#include <hwy/highway.h>

namespace hn = hwy::HWY_NAMESPACE;

void axpy_highway(float* HWY_RESTRICT y,
                  const float* HWY_RESTRICT x,
                  float a, std::size_t n) noexcept {
    const hn::ScalableTag<float> d;
    const auto av = hn::Set(d, a);

    std::size_t i = 0;
    for (; i + hn::Lanes(d) <= n; i += hn::Lanes(d)) {
        const auto xv = hn::LoadU(d, x + i);
        const auto yv = hn::LoadU(d, y + i);
        hn::StoreU(hn::MulAdd(av, xv, yv), d, y + i);
    }
    for (; i < n; ++i) y[i] = a * x[i] + y[i];
}

// xsimd: one source, similar shape, smaller dependency footprint.
#include <xsimd/xsimd.hpp>

void axpy_xsimd(float* y, const float* x, float a, std::size_t n) noexcept {
    using batch = xsimd::batch<float>;
    const batch av(a);
    const std::size_t W = batch::size;

    std::size_t i = 0;
    for (; i + W <= n; i += W) {
        auto xv = batch::load_unaligned(x + i);
        auto yv = batch::load_unaligned(y + i);
        (av * xv + yv).store_unaligned(y + i);
    }
    for (; i < n; ++i) y[i] = a * x[i] + y[i];
}

// std::experimental::simd: today's name for what becomes std::simd in
// C++26 (P1928). Same source shape; the standard owns the vocabulary.
// This is the same kernel from SIMD.1; reproduced for comparison.
#include <experimental/simd>
namespace stdx = std::experimental;

void axpy_simd(float* __restrict__ y, const float* __restrict__ x,
               float a, std::size_t n) noexcept {
    using vf = stdx::native_simd<float>;
    const vf av(a);
    const std::size_t W = vf::size();

    std::size_t i = 0;
    for (; i + W <= n; i += W) {
        vf xv, yv;
        xv.copy_from(x + i, stdx::element_aligned);
        yv.copy_from(y + i, stdx::element_aligned);
        (av * xv + yv).copy_to(y + i, stdx::element_aligned);
    }
    for (; i < n; ++i) y[i] = a * x[i] + y[i];
}
```

## Caveats

- **Portable does not mean automatic.** A loop that the autovectoriser
  refuses also refuses to vectorise through a portable library if you
  write the same scalar shape inside it. The library makes the *vector*
  formulation portable; it does not invent vectorisation.
- **Mixing portable code with platform-specific intrinsics is messy.**
  Highway's `target_features` and the per-function `__attribute__
  ((target(...)))` mechanism (`SIMD.6`) let you do it, but the
  maintenance picture is closer to "intrinsics" than "portable."
- **Scalable vectors break fixed-width assumptions.** Code that hard-
  codes `Lanes(d) == 8` works on AVX-2 floats and breaks on SVE 256
  / 512 / 1024-bit. Highway's tag system enforces "ask the descriptor,
  do not assume."
- **The C++26 `std::simd` interface is still in flight.** Anything you
  write against `std::experimental::simd` today will need small
  touch-ups before the C++26 IS lands.
- **Library choice has a code-size impact** (Highway emits per-target
  kernels; xsimd inlines aggressively; Eve's templates are extensive).
  For embedded with tight flash budgets, measure.

## References

- Google Highway (Apache-2.0) —
  <https://github.com/google/highway>
- xsimd (BSD-3-Clause) — <https://github.com/xtensor-stack/xsimd>
- Eve (BSL-1.0) — <https://github.com/jfalcou/eve>
- P1928, `std::simd` for C++26 — <https://wg21.link/p1928>
- libstdc++ `<experimental/simd>` —
  <https://gcc.gnu.org/onlinedocs/libstdc++/manual/experimental.html>
- Cross-reference: `SIMD.1` (the approach choice), `SIMD.2` (SoA
  layout — the libraries do not invent it for you), `SIMD.6` (runtime
  dispatch when one binary serves multiple ISAs).
