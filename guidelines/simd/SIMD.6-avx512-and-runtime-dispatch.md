+++
id = "SIMD.6"
title = "Use AVX-512 freely on Sapphire Rapids and Zen 4+ — runtime-dispatch for mixed fleets"
category = "simd"
status = "draft"
summary = "On current silicon, AVX-512 is usually a dispatch and binary-management problem, not a blanket downclocking problem."
tags = ["avx-512", "runtime-dispatch", "ifunc", "target-attribute", "target-clones"]
+++

## Rationale

For the first half of AVX-512's life — Skylake-X (2017) through
Cascade Lake — using a 512-bit vector caused the CPU to drop its core
frequency by several hundred MHz to stay inside the power envelope.
"AVX-512 downclocking" was real, was measurable in production
(Cloudflare, Phoronix), and made the optimisation locally negative
for many workloads: the wider vectors did *more* work per cycle, but
the cycles were slower. The recommendation at the time — "use AVX-2;
AVX-512 only for sustained vector kernels" — was correct for that
silicon.

That recommendation is out of date. On Sapphire Rapids (2023), Granite
Rapids (2024), and AMD Zen 4 (2022) / Zen 5 (2024), the
licensing-power transition is small (low single-digit percent) or
absent. AVX-512 can be used as the default ISA for vector kernels
without measurable frequency penalty. The cost model is now:

- **AVX-512 vs AVX-2 on Sapphire Rapids / Zen 4+:** typically
  1.4–1.9× throughput at near-identical clocks; cache pressure is the
  bigger constraint than power.
- **AVX-512 on Skylake-X / Cascade Lake (the original "downclocking"
  cores):** still real, still costs a few percent of clock. Use AVX-2
  by default on these CPUs unless the kernel sustains 512-bit
  utilisation for milliseconds.
- **AMD Zen 4 "double-pumped" AVX-512:** decoded as two 256-bit ops;
  no power penalty, but throughput is "AVX-2 grade with the AVX-512
  programming model" — still useful (mask registers, new ops). Zen 5
  is true 512-bit.

The shifted problem is **binary fragmentation**. A single binary
shipped to a heterogeneous fleet must choose:

1. **Compile for the lowest common denominator** (e.g., AVX-2). The
   AVX-512 capability is wasted on every machine that has it.
2. **Compile for the highest** (`-march=sapphirerapids`). The binary
   crashes on older CPUs.
3. **Runtime-dispatch**: compile the hot kernels for multiple ISAs;
   pick at startup based on `cpuid`.

Option 3 is the answer for code that ships to mixed fleets. The
mechanisms are well-supported but require discipline to use without
the dispatch logic itself becoming the bottleneck:

- **GCC / Clang function multiversioning (`__attribute__
  ((target_clones("default,avx2,avx512f")))`):** the compiler emits
  one version per target and an IFUNC resolver that picks at first
  call. Cost: one indirect call per dispatched function.
- **Per-function target attribute (`__attribute__
  ((target("avx2")))` / `target("avx512f")`):** explicit per-version
  bodies; you write the dispatch by hand. More verbose, more
  control.
- **Manual dispatch table:** detect CPU features once at startup,
  store a function pointer per kernel. One indirect call per call
  site (same cost as a virtual function); avoids the IFUNC
  resolver's first-call overhead.
- **Highway / xsimd target-feature multi-build:** the portable SIMD
  libraries (`SIMD.3`) build their kernels per target automatically
  and dispatch internally. If you already use one, the dispatch is
  free.

The only wrong answer is to ignore the question and ship one ISA.

## Guidance

- **Compile vector kernels at the highest ISA the target fleet
  supports.** For a private game-engine deployment to known hardware
  (e.g., Strix Halo developer kits), this is a `-march=znver5` or
  `-march=sapphirerapids` decision, not a dispatch decision.
- **For ship-to-the-world binaries, runtime-dispatch the hot
  kernels.** "Hot" means the kernel runs enough to dominate
  profile; cold or short-lived code should not pay the dispatch
  cost.
- **The default ISA baseline as of 2026 is AVX-2 + FMA + BMI2.** Any
  x86-64 machine sold in the last decade has it. Compile the default
  for that; dispatch upward for AVX-512.
- **Use function multiversioning (`target_clones`) for ergonomics;
  fall back to a manual dispatch table when first-call latency
  matters.** The IFUNC resolver runs once per function; for
  hundreds of dispatched functions, the startup cost adds up.
- **Detect features once at startup, store the result.** Calling
  `cpuid` at every kernel entry is a classic anti-pattern; the
  detection should run before the hot loop ever sees a call.
- **Test on each ISA you dispatch to.** Compile coverage is not
  runtime coverage. A bug in the AVX-512 variant will not surface
  on a CI runner that only has AVX-2.
- **Do not assume AVX-512 implies all AVX-512 sub-extensions.**
  AVX-512F is the foundation; VL, DQ, BW, VBMI, IFMA, VNNI, BF16,
  FP16 are independent feature bits. Sapphire Rapids has all of
  them; Skylake-X does not. Dispatch on the specific feature, not
  the umbrella.

## Example

```cpp
// Option A: function multiversioning (target_clones). One source,
// the compiler emits one body per ISA and an IFUNC resolver.
// Simple but adds an indirect call on the dispatched function.
__attribute__((target_clones("default,avx2,avx512f,avx512f+avx512vl+avx512dq")))
void dot_product(const float* a, const float* b, float* out,
                 std::size_t n) noexcept {
    float s = 0.0f;
    for (std::size_t i = 0; i < n; ++i) s += a[i] * b[i];
    *out = s;
}

// Option B: per-function target attribute + manual dispatch table.
// More verbose but the dispatch is one pointer load at the call
// site, identical to a virtual function call.
namespace dispatch {
    __attribute__((target("default")))
    static void dot_default(const float* a, const float* b, float* out,
                            std::size_t n) noexcept { /* scalar */ }

    __attribute__((target("avx2,fma")))
    static void dot_avx2(const float* a, const float* b, float* out,
                         std::size_t n) noexcept { /* AVX-2 + FMA */ }

    __attribute__((target("avx512f")))
    static void dot_avx512(const float* a, const float* b, float* out,
                           std::size_t n) noexcept { /* AVX-512F */ }

    using DotFn = void(*)(const float*, const float*, float*, std::size_t);

    inline DotFn pick_dot() noexcept {
        if (__builtin_cpu_supports("avx512f")) return &dot_avx512;
        if (__builtin_cpu_supports("avx2"))    return &dot_avx2;
        return &dot_default;
    }

    // Detect once at startup; store the result in a global function
    // pointer. Call sites pay one indirect call — same as a virtual.
    inline const DotFn dot = pick_dot();
}

// Option C: portable SIMD library with target-feature multi-build
// (Highway). The library does the dispatch; the application sees
// one entry point. See SIMD.3.
#include <hwy/highway.h>
#include <hwy/foreach_target.h>

namespace hn = hwy::HWY_NAMESPACE;

HWY_ATTR void dot_product_hwy_impl(const float* a, const float* b,
                                   float* out, std::size_t n) noexcept {
    /* one source; Highway expands per HWY_TARGETS macro */
}

// At call site:
HWY_EXPORT(dot_product_hwy_impl);
void dot_product_hwy(const float* a, const float* b, float* out,
                     std::size_t n) noexcept {
    HWY_DYNAMIC_DISPATCH(dot_product_hwy_impl)(a, b, out, n);
}
```

```text
# Build with multi-version targets:
g++ -O2 -std=c++20 \
    -mavx2 -mfma                                          \
    -c dot_product.cpp -o dot.o

# Check that the IFUNC resolver and per-target symbols exist:
nm -C dot.o | grep -E '(dot_product|ifunc|@@)'
# Expect: dot_product, dot_product.avx2, dot_product.avx512f,
#         dot_product.resolver
```

## Caveats

- **The downclocking story still applies to Skylake-X / Cascade
  Lake.** If the fleet includes those cores, benchmark the AVX-512
  variant on them specifically. It may still be slower than AVX-2
  on those machines despite being faster on Sapphire Rapids.
- **Function multiversioning increases binary size** — one full
  copy per ISA per function. For 50 dispatched kernels at 3 ISAs,
  expect tens to hundreds of KB. Embedded (`EMB.1`) cares; servers
  do not.
- **The IFUNC resolver runs in early dynamic-loader context** —
  before `main`, before global constructors. Resolvers must not
  call into the C library beyond a tiny safe subset
  (`__builtin_cpu_supports` is safe; `printf` is not).
- **`__builtin_cpu_supports("avx512f")` returns true on Zen 4 even
  though Zen 4's AVX-512 is double-pumped.** That is the correct
  answer for *correctness* (the instructions execute), but the
  throughput is "AVX-2 grade with mask register support."
  Throughput-sensitive dispatch may want to detect Zen 4
  explicitly (`__builtin_cpu_is("znver4")`).
- **macOS on Apple Silicon does not have AVX-512.** Apple Silicon
  is NEON / SME; dispatch for x86 is irrelevant. For macOS x86
  (Intel Macs, now legacy), the dispatch matters until those
  machines age out.
- **`-mavx512f` on the *compiler command line* (without dispatch)
  means the binary crashes on older CPUs.** Dispatched code must
  guard the high-ISA variants behind `target` attributes, not
  command-line flags.

## References

- Travis Downs, *Gathering intel on Intel AVX-512 transitions* —
  <https://travisdowns.github.io/blog/2020/01/17/avxfreq1.html>
- Daniel Lemire, *AVX-512: when and how to use these new instructions*
  (and various follow-ups on Sapphire Rapids) —
  <https://lemire.me/blog/>
- Intel, *Architecture Day 2022 — Sapphire Rapids* (AVX-512
  licensing changes) — <https://www.intel.com/content/www/us/en/newsroom/>
- AMD, *Zen 4 / Zen 5 software optimisation guides* (AVX-512
  implementation notes) — <https://www.amd.com/en/developer.html>
- GCC manual, *Function Multiversioning* —
  <https://gcc.gnu.org/onlinedocs/gcc/Function-Multiversioning.html>
- Clang documentation, *Function multiversioning* —
  <https://clang.llvm.org/docs/AttributeReference.html#target-clones>
- Cross-reference: `SIMD.1` (approach choice), `SIMD.3` (portable
  SIMD libraries that bundle dispatch), `EMB.1` (binary-size
  cost matters in embedded).
