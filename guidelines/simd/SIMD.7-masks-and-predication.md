+++
id = "SIMD.7"
title = "AVX-512 masks and SVE predication unlock loops the shuffle-blend model could not vectorise"
category = "simd"
status = "draft"
summary = "First-class mask registers (`k0..k7`) and SVE predicate registers turn data-dependent branches, tail loops, and partial-vector stores from open-coded blends into native primitives — the difference between vectorising and not."
tags = ["avx-512", "sve", "mask-registers", "predication", "tail-loop"]
+++

## Rationale

The pre-AVX-512 vectorisation model — SSE, AVX, AVX-2, NEON
ASIMD — has no first-class concept of a *mask*. Conditional
execution inside a vector loop is open-coded: compute both sides of
the branch, compare into a vector of `0` / `~0`, and `BLENDVPS` /
`VBSL` to pick. Partial-vector tails (the last `n % W` iterations)
must run as a scalar epilogue. Loop early-exits cannot vectorise at
all: the vector model has no way to express "this lane is done."

AVX-512 changes the model with the **mask register file**
(`k0..k7`): eight dedicated registers, separate from the vector
file, that hold a per-lane bit. Most AVX-512 instructions accept a
mask operand and either *zero-mask* (`{k1}{z}`) or *merge-mask*
(`{k1}`) the result. The semantics are first-class: a masked load
*does not fault* on disabled lanes; a masked store *does not write*
disabled lanes; comparisons produce masks directly (`VCMPPS k1, ...`).

SVE goes further. Predicate registers (`p0..p15`) are not an
extension to a 128-bit instruction set; they are the **entire model
for control flow** inside a vector. The canonical SVE loop is:

```asm
; i = 0; while-loop guarded by a predicate that shrinks each iter
mov   x0, #0
ptrue p0.s
loop:
    whilelo p1.s, x0, x_n     ; p1 = active lanes for this iter
    ld1w    z0.s, p1/z, [x_a, x0, lsl #2]   ; gather guarded by p1
    ...
    incw    x0
    b.first loop              ; branch while any lanes were active
```

There is no scalar tail. The predicate handles the partial vector at
the end. There is no "do I have enough work to vectorise?" check —
SVE *always* vectorises, with the right predicate.

What masks and predication unlock:

- **Data-dependent branches inside the loop** become per-lane
  conditional execution. The vector loop covers what was previously
  a scalar loop.
- **Tail loops disappear.** A single masked vector iteration handles
  the last partial vector; no scalar epilogue.
- **Early exits become expressible.** "Stop when any lane satisfies
  X" maps to `vptest` / `KORTESTW` on AVX-512, `b.first` /
  `b.last` on SVE.
- **Sparse / irregular workloads vectorise.** A loop that
  conditionally processes 30% of its elements ran as 100% scalar in
  the pre-mask world (no benefit from vectorising if most lanes
  are wasted). With masks, the vector kernel runs always; the
  *store* is masked.
- **Compress / expand operations** (`VCOMPRESSPS`, SVE `compact`)
  become a single instruction that gathers "active" lanes to the
  bottom — the building block for stream compaction (filter, GPU-
  style `select-and-pack`).

The same approach generalises. RVV (RISC-V vector) uses the same
predicate model as SVE. ARM SME extends it further with matrix
predicates. Once you absorb the mental shift from "blend with
~0 / 0" to "first-class predicate", the vectorisation surface
expands dramatically.

## Guidance

- **When targeting AVX-512 or SVE, use masks for what masks are
  for** — data-dependent branches, tail loops, partial-vector
  stores — not as a curiosity. The result is fewer scalar
  fallbacks and fewer guard branches around vector kernels.
- **Drop the scalar tail.** A loop pattern
  `for (i; i + W <= n; i += W) ... ; for (; i < n; ++i) ...` is
  one cycle of work in the pre-mask model; on AVX-512 / SVE it is
  one masked vector iteration. Cleaner, faster, smaller.
- **For SVE, write the loop with `svwhilelt` (or the C `svwhilelt_b32`
  intrinsic) as the predicate generator.** This is the canonical
  pattern; the compiler recognises it and the predicate handles
  scalability across vector widths.
- **For AVX-512, generate masks from comparisons** (`_mm512_cmp_ps_mask`
  and friends), not from constants. The mask register is then live
  for both the conditional compute and the masked store.
- **Use `compress` / `expand` for stream compaction.** A scalar
  filter loop (`if (pred) out[j++] = ...`) vectorises to
  `VCOMPRESSPS` (AVX-512) or `compact` (SVE) — one instruction
  emits the packed result.
- **The autovectoriser uses masks when it can.** Clang and GCC
  with `-march=skylake-avx512` (or higher) will emit masked
  AVX-512 for many of the patterns that previously fell back to
  scalar. Read `SIMD.4`'s report to confirm.
- **Mask-and-merge is not a `bool`-and-`if`.** `bool` in the source
  becomes a mask register only when the loop is recognised as a
  predicated kernel. Loops with side effects in one branch may not
  predicate cleanly — split them.

## Example

```cpp
// Bad: pre-mask vector code. The conditional store is open-coded
// with a blend; the tail is a separate scalar loop. The same shape
// is needed on AVX-2 and NEON.
namespace pre_mask {
    void clamp_positive(const float* x, float* y, std::size_t n) noexcept {
        std::size_t i = 0;
        for (; i + 8 <= n; i += 8) {
            __m256 v = _mm256_loadu_ps(x + i);
            __m256 mask = _mm256_cmp_ps(v, _mm256_setzero_ps(), _CMP_GT_OQ);
            __m256 out  = _mm256_blendv_ps(_mm256_setzero_ps(), v, mask);
            _mm256_storeu_ps(y + i, out);
        }
        for (; i < n; ++i) y[i] = x[i] > 0.0f ? x[i] : 0.0f;  // scalar tail
    }
}

// Good: AVX-512 with masks. The comparison produces a mask register
// directly; the masked store handles both the conditional write and
// the partial-vector tail. The scalar epilogue disappears.
namespace avx512 {
    void clamp_positive(const float* x, float* y, std::size_t n) noexcept {
        constexpr std::size_t W = 16;  // 512-bit / 32-bit float
        std::size_t i = 0;
        for (; i + W <= n; i += W) {
            __m512 v = _mm512_loadu_ps(x + i);
            __mmask16 m = _mm512_cmp_ps_mask(v, _mm512_setzero_ps(), _CMP_GT_OQ);
            _mm512_mask_storeu_ps(y + i, m, v);   // only lanes where v > 0
            // For lanes where v <= 0, y is left unchanged. If y must be
            // zeroed, store zero first or use mask-merge with a zero src.
        }
        if (i < n) {
            // One masked iteration handles the partial vector. No scalar
            // tail. The mask is "active lanes < remaining."
            __mmask16 tail = (1u << (n - i)) - 1u;
            __m512 v = _mm512_maskz_loadu_ps(tail, x + i);
            __mmask16 m = _mm512_kand(tail,
                                      _mm512_cmp_ps_mask(v, _mm512_setzero_ps(),
                                                         _CMP_GT_OQ));
            _mm512_mask_storeu_ps(y + i, m, v);
        }
    }
}

// Good: SVE — the canonical predicated loop. There is no scalar
// tail because there is no "full vector vs partial vector"
// distinction. `svwhilelt_b32` produces the predicate that shrinks
// in the last iteration.
#include <arm_sve.h>

namespace sve {
    void clamp_positive(const float* x, float* y, std::size_t n) noexcept {
        std::size_t i = 0;
        svbool_t pg = svwhilelt_b32(i, n);
        while (svptest_first(svptrue_b32(), pg)) {
            svfloat32_t v = svld1(pg, x + i);
            svbool_t pos  = svcmpgt(pg, v, 0.0f);
            svst1(pos, y + i, v);          // store only positive lanes
            i += svcntw();                  // advance by current VL
            pg = svwhilelt_b32(i, n);       // shrink predicate at the end
        }
    }
}

// Good: stream compaction via VCOMPRESSPS. A scalar filter loop
// becomes one masked compute + one compress + one masked store.
namespace compaction {
    std::size_t filter_positive(const float* x, float* y,
                                std::size_t n) noexcept {
        std::size_t j = 0;
        constexpr std::size_t W = 16;
        for (std::size_t i = 0; i + W <= n; i += W) {
            __m512 v = _mm512_loadu_ps(x + i);
            __mmask16 m = _mm512_cmp_ps_mask(v, _mm512_setzero_ps(), _CMP_GT_OQ);
            _mm512_mask_compressstoreu_ps(y + j, m, v);  // packs and stores
            j += __builtin_popcount(m);
        }
        // (scalar tail elided for brevity)
        return j;
    }
}
```

## Caveats

- **Masks are a programming model, not a free pass.** A masked
  store still issues a store; the active lanes still consume cache
  bandwidth. A loop where most lanes are masked-off is still
  bandwidth-bound on the inputs.
- **Mask-merge vs mask-zero matters.** `{k1}` merges with the
  destination (existing lane values preserved on masked-off
  lanes); `{k1}{z}` zeros masked-off lanes. Choosing the wrong one
  produces wrong code.
- **`compress` does not preserve ordering across vector
  boundaries.** Within a vector, active lanes are packed in their
  original order; across two vectors, you must accumulate the
  output index between iterations.
- **Pre-AVX-512 x86 has no masks.** The same source compiled for
  AVX-2 falls back to blend-and-tail; for portability, write the
  source against a portable SIMD library (`SIMD.3`) and let it
  choose.
- **NEON ASIMD has no first-class masks** (it has compare-into-
  vector). For ARM-side mask-style code, use SVE (`-march=armv8.2-a+sve`)
  on hardware that supports it; NEON-only targets use the
  pre-mask shape.
- **SVE's vector length is unknown at compile time.** Code that
  assumes `svcntw() == 8` is wrong. The predicate model is the
  language for this; `svwhilelt_*` and `svcntw()` are the
  primitives. Hard-coding lane counts breaks scalability.
- **AVX-512 mask intrinsics are verbose.** For non-trivial
  kernels, `std::simd` or Highway compose the mask operations
  more cleanly than raw intrinsics; the intrinsic form shown here
  is for the cases where every cycle counts.

## References

- Intel, *Intrinsics Guide* (AVX-512 mask intrinsics: `_mm512_mask_*`,
  `_mm512_cmp_*_mask`, `_mm512_mask_compressstoreu_*`) —
  <https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html>
- ARM, *SVE Programming Examples* (`whilelt`, predicate-driven
  loops, `compact`) —
  <https://developer.arm.com/documentation/dai0548/latest/>
- ARM, *SVE/SVE2 ACLE intrinsics* —
  <https://developer.arm.com/documentation/102476/latest/>
- Daniel Lemire, *Filtering with AVX-512 compress instructions* —
  <https://lemire.me/blog/2017/04/10/removing-duplicates-from-lists-quickly/>
- RVV (RISC-V Vector) specification — predicated loops use the
  same pattern: <https://github.com/riscv/riscv-v-spec>
- Cross-reference: `SIMD.1` (approach choice), `SIMD.3` (portable
  libraries that expose masks), `SIMD.4` (the vectoriser's report
  tells you when masks would help), `SIMD.6` (AVX-512 dispatch).
