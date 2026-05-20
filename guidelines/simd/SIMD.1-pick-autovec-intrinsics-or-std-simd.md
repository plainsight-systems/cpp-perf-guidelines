+++
id = "SIMD.1"
title = "Pick autovectorisation, intrinsics, or std::simd by maintenance cost vs expressiveness"
category = "simd"
status = "draft"
summary = "Three approaches with three trade-off profiles. Autovec for portable scalar-shaped loops. Intrinsics for kernels the compiler can't reach. std::simd as the standardised portable middle path landing in C++26."
tags = ["autovectorisation", "intrinsics", "std-simd"]
+++

## Rationale

There are three legitimate ways to write SIMD code in C++, and they
have very different trade-off profiles:

- **Autovectorisation.** Write straight scalar loops and rely on the
  compiler to emit SIMD. Maximum portability (one source, every
  target); minimum expressiveness (the compiler refuses anything it
  cannot prove safe).
- **Intrinsics.** Write directly to the ISA — `<immintrin.h>` on x86,
  `<arm_neon.h>` / `<arm_sve.h>` on ARM. Maximum expressiveness; one
  kernel per ISA family; vendor-lock cost is real (an engine shipping
  AVX-2 + AVX-512 + NEON + SVE writes four kernels and tests four).
- **`std::simd`.** The standardised portable wrapper landing in C++26
  via P1928 (Matthias Kretz; Parallelism TS v2 lineage). One source
  compiles to the right ISA on every target. `std::experimental::simd`
  is available today in libstdc++ (GCC 11+) and partially in libc++.

The choice is not aesthetic — it is a maintenance-cost decision.
Intrinsics shine on parser-like kernels (simdjson, Wojciech Muła's
benchmarks) where the autovectoriser refuses and the kernel dominates
the profile. Autovec carries everything else. `std::simd` is positioned
to absorb the cases in between, once toolchain support is universal.

The corpus's first SIMD guideline is therefore the choice itself.

## Guidance

- **Default to autovectorisation** for tight contiguous loops. Write
  the loop in SoA (`SIMD.2`), make pointers non-aliasing (`GEN.3`),
  and check the vectoriser's missed-vectorisation report (`SIMD.4`)
  before assuming the compiler can't handle it.
- **Reach for intrinsics only when** (a) the autovectoriser refuses
  despite a clean loop, *and* (b) the kernel dominates a profile.
  Accept the vendor-lock cost — one kernel per ISA family — and write
  the tests to match.
- **Use a portable SIMD library** (`SIMD.3`: Highway / xsimd / Eve) as
  the middle path *today* — one source, multiple ISAs, more
  expressive than autovec, far less maintenance than per-ISA
  intrinsics.
- **Track `std::simd`.** The C++26 wording is in flight; libstdc++ and
  libc++ already ship `std::experimental::simd`. New code that will
  outlive the C++26 toolchain rollout can be written against the
  experimental header today.
- **Do not write the same kernel twice unless you must.** If you have
  three intrinsic versions of the same loop, you have three things to
  keep in sync; the portable libraries exist to prevent that.

## Example

```cpp
// 1. Autovectorisation — the default. Tight, contiguous, SoA, no
//    aliasing, no early exit. The compiler emits AVX2/AVX-512/NEON/SVE
//    from this single source.
void axpy_auto(float* __restrict__ y,
               const float* __restrict__ x,
               float a, std::size_t n) noexcept {
    for (std::size_t i = 0; i < n; ++i) {
        y[i] = a * x[i] + y[i];
    }
}

// 2. Intrinsics — when the autovectoriser refuses and the kernel
//    matters enough to write per ISA. simdjson-style shuffle/mask
//    work belongs here. Note: one source per ISA family.
//
//    AVX2 version (x86_64):
#if defined(__AVX2__)
void axpy_avx2(float* __restrict__ y, const float* __restrict__ x,
               float a, std::size_t n) noexcept {
    const __m256 av = _mm256_set1_ps(a);
    std::size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        __m256 xv = _mm256_loadu_ps(x + i);
        __m256 yv = _mm256_loadu_ps(y + i);
        _mm256_storeu_ps(y + i, _mm256_fmadd_ps(av, xv, yv));
    }
    for (; i < n; ++i) y[i] = a * x[i] + y[i];   // scalar tail
}
#endif
//    A NEON version of the same loop would live alongside, under
//    #if defined(__ARM_NEON). Same logic; different intrinsic dialect.

// 3. std::simd / std::experimental::simd — one source, every ISA. The
//    `simd<float>` type's width is chosen by the compiler for the
//    target ABI. C++26 standardises the spelling; today's name is
//    std::experimental::simd in libstdc++ and (partial) libc++.
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
    for (; i < n; ++i) y[i] = a * x[i] + y[i];   // scalar tail
}
```

## Caveats

- **Autovectorisation depends on aliasing being provable.** A loop that
  takes two `float*` parameters will not vectorise without `__restrict__`
  (`GEN.3`) — the compiler must assume the writes could affect the
  reads.
- **Intrinsics' vendor-lock is not just compile-time.** Tests run on
  every target; the kernel must be benchmarked on every target;
  regressions surface per-target. Budget the cost.
- **`std::experimental::simd` is not the final ABI.** Names, traits,
  and tag types will shift before C++26 is fixed. Code written against
  it will need small touch-ups.
- **`std::simd` is fixed-width by default.** SVE's scalable vectors
  are not yet first-class in the standard. Highway covers this case
  today (`SIMD.3`).
- **Hot-loop intrinsics demand vectoriser opt-out.** When you write
  intrinsics, you are taking responsibility for the codegen; you do
  not want the autovectoriser also touching that loop. The intrinsics
  are explicit enough that this is rarely a problem in practice.

## References

- P0214R9, *Data-Parallel Vector Types & Operations* (Kretz) —
  <https://wg21.link/p0214>
- P1928, *Merge `data-parallel types` from the Parallelism TS 2* —
  <https://wg21.link/p1928>
- Matthias Kretz on `std::simd`, CppCon —
  <https://www.youtube.com/results?search_query=Kretz+std+simd+CppCon>
- simdjson (Apache-2.0) — the canonical intrinsics-win-on-parsing
  case study — <https://github.com/simdjson/simdjson>
- Wojciech Muła, SIMD benchmarks — <http://0x80.pl/>
- Intel Intrinsics Guide —
  <https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html>
- Cross-reference: `SIMD.2` (SoA layout), `SIMD.3` (portable
  libraries), `SIMD.4` (vectoriser diagnostics), `GEN.3` (`restrict`).
