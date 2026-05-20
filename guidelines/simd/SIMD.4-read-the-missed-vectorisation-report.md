+++
id = "SIMD.4"
title = "Read the vectoriser's missed-vectorisation report — fix what it tells you"
category = "simd"
status = "draft"
summary = "Clang's -Rpass-missed=loop-vectorize and GCC's -fopt-info-vec-missed name each refusal: aliasing, early exit, unsupported reduction, function call. Each refusal has a fix; the report is the diagnosis."
tags = ["autovectorisation", "diagnostics", "opt-info", "rpass"]
+++

## Rationale

The autovectoriser is not a black box. It emits a *report* — one line
per loop — explaining whether it vectorised, and if not, why not. The
report is a list of concrete reasons:

- "cannot identify array bounds" — pointer arguments without
  `__restrict__` (`GEN.3`).
- "loop contains a function call" — non-inlinable callee in the
  inner loop.
- "unsafe dependent memory operations" — possible aliasing the
  compiler cannot rule out.
- "control flow cannot be substituted for a select" — early exit, or
  data-dependent branch the masking model cannot express.
- "unrecognised reduction" — accumulator using an operator the
  vectoriser does not have a reduction template for (e.g. `min` /
  `max` on float without `-ffast-math`).
- "loop trip count is not constant" — handled, but with a more
  conservative vectorisation choice.

Each line points at a specific fix. The report is the answer to "why is
my loop slow?" *before* reaching for intrinsics (`SIMD.1`). Without it,
"the compiler didn't vectorise" is a vague complaint; with it, the
issue is named and addressable.

The flags:

- **Clang:** `-Rpass=loop-vectorize -Rpass-missed=loop-vectorize
  -Rpass-analysis=loop-vectorize`. Inline diagnostics, function and
  line marked.
- **GCC:** `-fopt-info-vec -fopt-info-vec-missed`. Same shape.
- **MSVC:** `/Qvec-report:2`.

The reports are noisy on a full codebase; filter to the file of
interest, build with `-O2` (not `-O0`), and add the report flag only
when investigating.

## Guidance

- **Before reaching for intrinsics or a portable SIMD library,
  read the vectoriser report.** Most loops that look "unvectorisable"
  have a named, fixable reason.
- **The standard fixes:**
  - "cannot identify array bounds" / "may alias" → add `__restrict__`
    (`GEN.3`).
  - "loop contains a function call" → mark the callee `inline` and
    define it in the header, or enable LTO (`GEN.4`).
  - "unsupported reduction" → use a supported reduction operator
    (`+`, `*`, `min`, `max`, `&`, `|`, `^`); or, for float
    associativity, allow `-ffast-math` or `#pragma omp simd
    reduction(...)` for the specific loop.
  - "control flow" → restructure to use the mask model (compare into
    a vector, blend) or split the loop in two.
  - "indirect access" → restructure to linear (`SIMD.5`).
- **Use `#pragma clang loop vectorize(enable)` /
  `#pragma GCC ivdep`** when the report says "could vectorise but
  uncertain" and you can vouch that the uncertainty is unfounded
  (typically: no aliasing, no dependence). The pragma is a promise.
- **Build the report flags into CI on the perf-critical files.**
  Regressions ("this loop used to vectorise") then surface at the PR
  that broke it, not three releases later.
- **Do not silence the report.** If the report says a loop did not
  vectorise and you cannot fix it, document the reason on the loop.
  Silent non-vectorisation is the bug; explained non-vectorisation
  is a design decision.

## Example

```cpp
// Bad: no __restrict__, no inline of the helper, and a min reduction
// the autovectoriser doesn't recognise without help. The report will
// name all three.
namespace bad {
    extern float clamp_to_range(float, float, float);   // defined elsewhere

    void process(float* dst, const float* src, std::size_t n) noexcept {
        float lo = 1e30f;
        for (std::size_t i = 0; i < n; ++i) {
            dst[i] = clamp_to_range(src[i], 0.0f, 1.0f);   // opaque call
            lo = std::min(lo, src[i]);                     // unrecognised reduction
        }
        publish_min(lo);
    }
}
//
// Clang report (typical, paraphrased):
//   bad.cpp:5:5: remark: loop not vectorized: cannot identify array bounds
//   bad.cpp:6:9: remark: loop not vectorized: call to function
//                'bad::clamp_to_range' is opaque
//   bad.cpp:7:9: remark: loop not vectorized: value used outside the loop
//                cannot be a recognized reduction

// Good: __restrict__ removes the aliasing barrier; the helper is
// inlined; the reduction uses an explicit pragma to assert it is
// safe to vectorise. The report now reports "vectorized loop".
namespace good {
    inline float clamp01(float x) noexcept {
        return x < 0.0f ? 0.0f : (x > 1.0f ? 1.0f : x);
    }

    void process(float* __restrict__ dst,
                 const float* __restrict__ src,
                 std::size_t n) noexcept {
        float lo = std::numeric_limits<float>::infinity();
        #pragma omp simd reduction(min:lo)
        for (std::size_t i = 0; i < n; ++i) {
            dst[i] = clamp01(src[i]);
            lo = std::min(lo, src[i]);
        }
        publish_min(lo);
    }
}
```

```text
# Build to see the vectoriser report.
# Clang (preferred — most detail):
clang++ -O2 -std=c++20 -march=native \
        -Rpass=loop-vectorize \
        -Rpass-missed=loop-vectorize \
        -Rpass-analysis=loop-vectorize \
        -c src/hot_loop.cpp -o build/hot_loop.o

# GCC:
g++ -O2 -std=c++20 -march=native \
    -fopt-info-vec \
    -fopt-info-vec-missed \
    -c src/hot_loop.cpp -o build/hot_loop.o
```

## Caveats

- **`-Rpass-missed` is noisy on large translation units.** Filter to
  the file you are investigating; build only that TU with the flag.
- **The report is the *vectoriser*'s view.** It does not promise the
  vectorised loop is *faster* — only that it vectorised. Pair with a
  benchmark.
- **"Vectorised" can mean SLP (superword-level parallelism) rather
  than loop vectorisation.** SLP merges scalar operations in straight-
  line code into vectors; loop vectorisation handles inner loops. The
  reports distinguish them; do not conflate them.
- **`-ffast-math` reorders floating-point reductions** and produces
  technically different results. For numeric code that needs IEEE-
  strict semantics, use `#pragma omp simd reduction(...)` on the
  specific loop instead of a global compile flag.
- **Pragmas are promises.** `#pragma clang loop vectorize(enable)` on a
  loop that *does* have aliasing or dependence produces wrong code.
  Use them only when you can vouch for the absence of the named
  hazard.

## References

- Clang documentation, *Optimisation remarks* —
  <https://clang.llvm.org/docs/UsersManual.html#options-to-emit-optimization-reports>
- GCC documentation, `-fopt-info` —
  <https://gcc.gnu.org/onlinedocs/gcc/Developer-Options.html>
- LLVM, *Loop vectoriser cookbook* —
  <https://llvm.org/docs/Vectorizers.html>
- Matt Godbolt, *What Has My Compiler Done for Me Lately?*, CppCon
  2017 — <https://www.youtube.com/watch?v=bSkpMdDe4g4>
- Cross-reference: `SIMD.1` (read the report *before* reaching for
  intrinsics), `GEN.3` (`__restrict__` fixes most "may alias"
  refusals), `GEN.4` (LTO fixes most "cannot inline" refusals).
