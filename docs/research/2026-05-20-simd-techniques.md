# C++ SIMD and Vectorisation — Technique Extraction

Research note — 2026-05-20. Supports packet
`2026-05-20-simd-category-buildout`. Technique-extraction pass for the
final corpus category — what each source actually teaches, not
bibliography. Vectorisation is its own category; the codegen *nudges*
(branch hints, restrict, LTO, PGO) live separately under `codegen`.
Sources are classified per the `CONTRIBUTING.md` sourcing rule:

- **Citable** — free public talk / paper / blog.
- **Cite-by-reference** — copyrighted book.
- **Study-only code** — proprietary or undocumented.
- **Permissive code** — MIT / BSD / Apache-2.0 / similar.

---

## 1. Vectorisation-friendly layout

The autovectoriser materialises a vector by loading N contiguous
elements of the *same field* into one register. AoS forces it to either
gather (slow — see §5) or to load-then-shuffle, which it usually
declines and falls back to scalar. SoA makes the load a single aligned
`movdqa` / `vmovdqa` / `ld1`. Cross-reference `CACHE.4` for the layout
itself; the SIMD-specific reason to choose SoA is that the vector load
instruction is the *unit of work* the compiler can emit.

**AoSoA** (struct of blocks of, say, 8 floats × N fields) is the
compromise when you also iterate per-entity locally: each block is
SoA-shaped for one vector width, while neighbouring fields stay
cache-line-near. Highway and Eve both target this shape via `Vec<D>`-
sized blocks.

**Heuristic:** if a hot loop reads more than one field per element and
the lane count is ≥ 8, default to SoA; reach for AoSoA only after
measuring cache pressure (`CACHE.4`).

## 2. The three vectorisation approaches

### 2.1 Autovectorisation — write scalar, let the compiler do it

**When it works:** counted loops over contiguous SoA buffers; no early
exit; no calls (or only inlinable / `__attribute__((const))` calls); no
aliasing ambiguity (use `__restrict__` — cross-reference `GEN.3`);
reductions over `+ * min max` (associative-by-pragma for `+` `*` on
float requires `-ffast-math` or `#pragma omp simd reduction(...)`).

**Diagnostics — the actual technique:**

- Clang: `-Rpass=loop-vectorize -Rpass-missed=loop-vectorize
  -Rpass-analysis=loop-vectorize`.
- GCC: `-fopt-info-vec -fopt-info-vec-missed`.
- MSVC: `/Qvec-report:2`.

The missed-vectorisation report tells you *why* a loop did not vectorise
(e.g. "cannot identify array bounds" → add `__restrict__`; "unsafe
dependent memory operations" → SoA-ify).

**When it fails predictably:** anything with data-dependent control
flow, anything indirect-indexed (gather), anything with cross-iteration
carries that aren't recognised reductions.

### 2.2 Intrinsics — direct ISA targeting

**When worth the lock-in cost:** when the autovectoriser refuses *and*
the kernel dominates a profile. simdjson is the canonical example —
UTF-8 validation and structural-character indexing are written in
`_mm256_*` / `vld1q_u8` because the autovectoriser cannot synthesise
the shuffles and masks involved. Wojciech Muła's `0x80.pl` benchmarks
routinely show intrinsics 2–10× over autovec on parse-heavy workloads.

**Vendor-lock cost is real.** Highway, xsimd, and Eve exist precisely
because shipping AVX-2 + NEON + SVE means three kernels in three
intrinsic dialects, three sets of tests, three maintenance burdens.

### 2.3 `std::simd` — the middle path, landing in C++26

**Provenance:** Matthias Kretz, P0214 (Parallelism TS v2, accepted
2018) → P1928 (`std::simd` for C++26, merged 2024). Implementations:
`std::experimental::simd` in libstdc++ since GCC 11, partial in libc++.
P2638 / P3060 / P2964 added reductions, `simd_cast`, masked operations,
and convergence with `std::execution`.

**Design intent (Kretz):** a fixed-width-by-default `simd<T, Abi>` where
`Abi` is "native" (the compiler picks the best for the target). The
ABI parameterisation lets the same source compile to SSE on Bulldozer,
AVX-2 on Haswell, AVX-512 on Sapphire Rapids, NEON on M-series, and
SVE on Graviton — without source changes.

**Ready today:** arithmetic, comparisons, reductions, basic masks via
`std::experimental::simd` in libstdc++. **Not yet ready:** SVE-native
scalable vectors (the TS is fixed-width); some platform-specific
shuffles; the full AVX-512 mask algebra is approximated rather than
exposed directly.

## 3. Portable SIMD libraries

| Library | License | Best for | Notable design |
|---|---|---|---|
| **Google Highway** | Apache-2.0 | Production cross-ISA, including SVE / RVV scalable | `Vec<D>` tagged by descriptor `D = ScalableTag<float>`; same source compiles for fixed and scalable. Used by JPEG XL, Chrome. |
| **xsimd** | BSD-3-Clause | Header-only, easy drop-in for numeric kernels | Explicit batch type `batch<T, A>`; clean API; used by xtensor. |
| **Eve** | BSL-1.0 | C++20-style, range-friendly | Function-first (`eve::add`, `eve::reduce`); composes with ranges. |
| **`std::simd`** | (standard) | Future-proof when C++26 lands | Subset of the above, but standardised. |

**Decision rule.** Need SVE / RVV scalable today → Highway. Want
minimal dependencies on NEON + AVX → xsimd or Eve. Can wait for the
compiler upgrade cycle → `std::simd`.

## 4. Alignment

The historical rule — "`alignas(32)` for AVX, `alignas(64)` for
AVX-512" — is now mostly a *correctness* concern, not a performance
one. On Haswell+ Intel, on Zen+ AMD: aligned and unaligned loads of
the same naturally-aligned address hit the same uop and the same
latency. The cost shows up only on cache-line splits and page splits.

**What still matters:**

- Older `mova`-family instructions (`MOVAPS`, `VMOVAPS` non-`U`)
  fault on misaligned addresses. If you hand-code an intrinsic, pick
  `_mm256_loadu_ps` unless you have guaranteed alignment.
- ARMv7 and some embedded ARMv8 in strict mode fault on misaligned
  NEON access.
- AVX-512 has gather / scatter variants that are aligned-only.

**Practical rule:** `alignas(64)` your hot SoA buffers (free, removes
a class of bugs); use unaligned-load intrinsics; cross-reference
`CACHE.5`.

## 5. Gather and scatter — usually a trap

`vpgatherdd` (AVX-2) is microcoded as N internal loads on every Intel
and AMD microarchitecture shipped to date (Skylake → Sapphire Rapids;
Zen 1 → Zen 5). Agner Fog's instruction tables list AVX-2 gather at
~12–20 cycles for 8 lanes — perhaps 1.5× over a scalar loop, not 8×.

AVX-512 gather (`vgatherdps` with `k` mask) is better — 8–10 cycles
on Sapphire Rapids — but nowhere near a contiguous load. SVE gather
is also predicated and microcoded.

**Rule:** restructure to SoA + linear iteration if you can; the layout
change beats the gather instruction. Gather is unavoidable for
genuinely random-access kernels (sparse matvec, hash-table probing).
Even there, **blocking** the access to be locally-linear inside a
tile often wins.

## 6. ISA targeting and runtime dispatch

### AVX-512 downclocking — historical, not current

**Skylake-X, Cascade Lake, Ice Lake server (Xeon):** running AVX-512
dropped core frequency by 100–300 MHz for hundreds of milliseconds
after the last 512-bit instruction. The "use AVX-512 only after
benchmarking" advice originated here.

**Current reality:** Sapphire Rapids (2023+) and all Zen 4 / Zen 5:
full-width AVX-512 with negligible frequency penalty. Zen 4 implements
it as two 256-bit micro-ops internally but exposes the full ISA — even
on the double-pumped implementation, practitioners report it is often
a win. Zen 5 is full-width. **Apple Silicon** has no AVX at all —
NEON only on M1–M3; NEON + SME on M4.

### Runtime dispatch — the standard shape

```cpp
__attribute__((target("avx512f"))) void kernel_avx512(...);
__attribute__((target("avx2")))    void kernel_avx2(...);
__attribute__((target("default"))) void kernel_scalar(...);
// One-time CPUID dispatch at startup; cache the function pointer.
```

GCC's `target_clones("default,avx2,avx512f")` automates this — the
compiler emits all variants and an IFUNC resolver. Clang offers
`target_version`. Cost: binary size. Benefit: single-binary
distribution across a heterogeneous fleet.

## 7. Masks and predication — the step change

**AVX-512** introduced 8 mask registers `k0`–`k7` plus per-instruction
`{k1}` and `{k1}{z}` (merge vs zero). Loops that previously needed
compare-then-blend-then-store (SSE / AVX shuffle-and-blend) become
compare-to-mask, masked-store — one instruction each. Huge
expressiveness gain for conditional kernels (e.g. ray–box intersection
where some lanes miss).

**ARM SVE** went further: *every* SVE instruction is predicated by a
governing predicate register `p0`–`p15`. Combined with length-agnostic
vectors and `whilelt`-style loop control, SVE loops vectorise tail
iterations naturally — no scalar epilogue, no peel loop. SME extends
this to 2D tiles.

**Practical implication:** kernels with data-dependent skips
(collision broadphase, particle culling, sparse updates) that would
not vectorise under SSE / AVX are first-class on AVX-512 and SVE.

## 8. The last-resort drop to hand-written assembly

Three honest cases:

1. **Vendor extension not yet exposed as intrinsics** in your
   toolchain. Rare on x86; occasional on ARM (some SME variants
   lagged Clang support).
2. **Apple AMX, pre-SME.** AMX is Apple's undocumented matrix
   coprocessor on M1–M3 — used internally by `Accelerate.framework`
   (vDSP, BNNS) but not exposed as intrinsics or even documented
   opcodes. Reaching it from custom kernels required hand-written
   assembly with reverse-engineered opcodes (community work by
   Dougall Johnson and others). **SME on M4 normalises this** — new
   code should target SME, not AMX.
3. **Constant-time cryptographic primitives.** Compiler optimisation
   breaks the timing-side-channel guarantee. The corpus's
   recommendation: *do not roll your own crypto.* Use **libsodium**
   (ISC license, audited). Cite-by-reference only; out of scope for
   routine engine work.

Hand-written assembly is **not** the right answer for "the intrinsic
is ugly." The intrinsic is the boundary; below it is craft work the
corpus does not recommend.

## 9. Honest gaps

- Specific cycle counts for gather on Zen 5 and Sapphire Rapids are
  vendor-published but vary by stepping; Agner Fog's tables lag the
  newest parts by 6–12 months. Treat any single number as
  approximate; benchmark on the target.
- `std::simd` C++26 wording is still in flight as of this note; P1928
  is the merge paper but interface details may shift before the IS.
- Apple has not published SME microarchitecture details for M4;
  performance claims rely on third-party measurement.

## Sources

### Citable

- P0214R9, *Data-Parallel Vector Types & Operations* (Kretz, 2018) —
  <https://wg21.link/p0214>
- P1928, *Merge `data-parallel types` from the Parallelism TS 2* —
  <https://wg21.link/p1928>
- P2638, *Intel's response to P1915 concerns* —
  <https://wg21.link/p2638>
- P3060, *Add `std::simd::iota`* — <https://wg21.link/p3060>
- P2964, *Allowing user-defined types in `std::simd`* —
  <https://wg21.link/p2964>
- Matthias Kretz, *SIMD Libraries in C++*, CppCon — search:
  <https://www.youtube.com/results?search_query=Kretz+std+simd+CppCon>
- Daniel Lemire, blog and simdjson talks —
  <https://lemire.me/blog/>;
  <https://github.com/simdjson/simdjson>
- Wojciech Muła, SIMD benchmarks — <http://0x80.pl/>
- Agner Fog, *Optimizing software in C++*, *Microarchitecture*,
  *Instruction Tables* — <https://www.agner.org/optimize/>
- Intel 64 / IA-32 Optimization Reference Manual —
  <https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html>
- Intel Intrinsics Guide —
  <https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html>
- ARM Architecture Reference Manual (NEON / SVE / SME) —
  <https://developer.arm.com/documentation/ddi0487/latest>
- AMD64 Architecture Programmer's Manual —
  <https://www.amd.com/en/support/tech-docs>

### Cite-by-reference

- Henry S. Warren Jr., *Hacker's Delight* 2e — bit-twiddling and
  mask construction.
- Hennessy & Patterson, *Computer Architecture: A Quantitative
  Approach* — vector-ISA chapter.

### Permissive code

- Google Highway (Apache-2.0) —
  <https://github.com/google/highway>
- xsimd (BSD-3-Clause) —
  <https://github.com/xtensor-stack/xsimd>
- Eve (BSL-1.0) — <https://github.com/jfalcou/eve>
- simdjson (Apache-2.0) — <https://github.com/simdjson/simdjson>
- libsodium (ISC) — <https://libsodium.org>

### Study-only

- Apple `Accelerate.framework` / vDSP — proprietary headers describe
  what AMX exposed; do not copy.
- Reverse-engineered AMX opcode notes (Dougall Johnson et al.) —
  citable for historical context only; new code targets SME.
