# C++ Codegen Nudges — Technique Extraction

Research note — 2026-05-20. Supports packet
`2026-05-20-codegen-category-buildout`. Technique-extraction pass for the
`codegen` category — what each source actually teaches (the rule, the
cost, the anti-pattern), not bibliography. Vectorisation is a separate
category (`simd`); this note covers the codegen *nudges*. Sources are
classified per the `CONTRIBUTING.md` sourcing rule:

- **Citable** — free public talk / paper / blog (link is the citation).
- **Cite-by-reference** — copyrighted book / paid standard.
- **Study-only code** — proprietary or non-permissive.
- **Permissive code** — MIT / BSD / Apache-2.0 / similar.

---

## 1. Branch hints (`[[likely]]` / `[[unlikely]]` / `__builtin_expect`)

### What the optimiser actually does

- **Block layout.** Hot path is laid out contiguously (fall-through);
  cold path is moved out-of-line or to a cold section. Reduces I-cache
  pressure and helps the front-end fetch the right path.
- **Register-allocation bias.** Hot block gets first pick of registers;
  cold block may spill more.
- **No effect on the dynamic predictor.** x86 / ARM predictors are
  dynamic and do not consume static hints at runtime. Hints affect
  *code placement*, which in turn affects the *initial* prediction
  (most CPUs predict forward branches not-taken, backward taken) and
  the I-cache footprint of the hot path.

### When they help

- Hot loop with a rare error / abort path.
- Branches that have **no profile data** (no PGO) and where the
  compiler has no other signal (e.g. the call site does not contain
  `__builtin_trap`, `abort`, `throw`, which already mark a block cold
  implicitly).
- Cross-TU calls where the inliner cannot see the callee.

### When they are noise or worse

- **With PGO.** Profile data dominates static hints. Carruth and the
  GCC manual both note this explicitly.
- **On cold paths.** Marking the cold side `[[unlikely]]` is redundant
  — the compiler already knows `abort()`, `throw`, `__builtin_unreachable()`
  are cold.
- **Misapplied.** A wrong hint forces the hot path out-of-line, costing
  I-cache and front-end fetch cycles.

Torvalds has repeatedly criticised `likely()` / `unlikely()` abuse in
the kernel: most developers' intuitions about branch probabilities are
wrong, and bad hints are worse than no hints. The kernel has actively
*removed* hints where measurement showed they were wrong. **Rule for
engines:** hint only branches you have measured, or where the cold
path is structurally guaranteed (error handling, asserts).

C++20's `[[likely]]` / `[[unlikely]]` are statement attributes
(portable across GCC, Clang, MSVC). `__builtin_expect` is GCC / Clang
only and operates on an expression. Functionally equivalent on
supporting compilers.

## 2. Branchless code vs predicted branches

### Mispredict cost

- Modern x86 (Skylake-class and later): **~15–20 cycle** mispredict
  penalty, sometimes higher with deep pipelines.
- Apple M-series, recent Zen: similar order of magnitude.
- ARM Cortex-A: ~10–15 cycles.
- Cortex-M3 / M4 (in-order, short pipeline): only a few cycles —
  branchless tricks often *not worth it*.

### When branchless wins

- **Unpredictable data.** The classic sorted-vs-unsorted example: on
  random data, `cmov` or arithmetic select beats a branch.
- **Short conditional work.** `cmov`, `csel` (ARM), bitmask-and-OR
  idioms — when the work on both sides is a few cycles.
- **Inside tight inner loops** where one mispredict per iteration would
  dominate.

### When branchless loses

- **Predictable branch.** 95–99 % predictor accuracy on stable patterns
  means the predicted path is effectively zero-latency, and *only* the
  predicted side executes. Branchless executes *both* sides — wasted
  work.
- **Data-dependent latency.** `cmov` introduces a data dependency on
  the condition into the output register; the OoO machine cannot
  speculate past it. A correctly-predicted branch breaks the
  dependency chain.
- **Long conditional bodies.** Branchless equivalents become expensive
  or impossible; a branch is the right tool.

Compilers often emit `cmov` from `cond ? a : b` already; check Godbolt
before reaching for bitmask tricks (`result = (mask & a) | (~mask & b);`)
or arithmetic select (`result = b + (a - b) * cond;`).

## 3. Pointer aliasing and `restrict`

### What `restrict` unlocks

`__restrict` / `__restrict__` is a non-standard extension (C has
`restrict` since C99; C++ does not). It promises the compiler that
within the pointer's scope, the object reached through it is not
reached through any other pointer.

Unlocked optimisations:

- **Loop fusion** and **invariant hoisting** across stores.
- **Register promotion**: keep a value in a register across a store
  through a different pointer.
- **Vectorisation** (cross-reference the `simd` category): the
  auto-vectoriser bails out on potential aliasing without runtime
  checks; `restrict` removes the bail-out.
- **Better scheduling**: loads and stores through different `restrict`
  pointers can be freely reordered.

### Where strict aliasing already gives the compiler the info

C++ TBAA (type-based alias analysis) lets the compiler assume two
pointers of incompatible types do not alias (modulo `char*`,
`std::byte*`, and `[[may_alias]]`). So:

- `float*` and `int*` are already considered non-aliasing — `restrict`
  adds nothing.
- Two `float*` parameters: TBAA cannot help; `restrict` is the only
  tool short of inlining + escape analysis.

### Orthogonal: `std::launder`

`std::launder` solves the *pointer provenance* problem after placement
new reuses storage (see `LIFE.3`) — it does not change aliasing
assumptions. Developers conflate the two; they are different tools.

### Cross-compiler

`__restrict` is supported by MSVC with similar semantics. No portable
attribute spans all three; use a macro:

```cpp
#if defined(_MSC_VER)
  #define RESTRICT __restrict
#else
  #define RESTRICT __restrict__
#endif
```

## 4. Link-Time Optimisation (LTO)

### What LTO unlocks

- **Cross-TU inlining.** The killer feature. Without LTO, anything
  called across a TU boundary is opaque.
- **Whole-program devirtualisation** (Clang: `-flto
  -fwhole-program-vtables`, plus `-fstrict-vtable-pointers` for full
  effect): if a class hierarchy is closed within the program, virtual
  calls become direct calls and inline.
- **Dead-code elimination at program scope:** unused functions, unused
  virtual overrides.
- **Constant propagation across TUs:** a function always called with
  `true` can be specialised.

### Cost

- **Full LTO.** The link becomes a whole-program compile. 5–20× link-
  time increase on large codebases. Memory-hungry — multi-million-LOC
  codebases can need tens of GB at link.
- **ThinLTO** (Clang; GCC has analogous WHOPR mode): per-TU summaries
  are linked, then per-function importing happens in parallel. Link
  time grows ~2–4× over non-LTO; most cross-TU inlining wins are
  retained. **Practical default for engines.**

### Wins

- 5–15 % runtime on typical engines (LLVM ThinLTO papers; game-engine
  post-mortems).
- Dramatically higher on virtual-dispatch-heavy code: whole-program
  devirt turns "virtual call + indirect branch mispredict" into a
  direct inlined call.

### Embedded note

LTO is a major code-size win for embedded (10–30 % reduction via
cross-TU DCE). GCC `-flto` works on Cortex-M targets in current GCC
ARM releases.

## 5. Profile-Guided Optimisation (PGO)

### Instrumented PGO

1. Build with `-fprofile-generate` (Clang or GCC).
2. Run representative workload — emits `.gcda` / `.profraw` files.
3. (Clang) merge with `llvm-profdata merge`.
4. Build with `-fprofile-use=...`.

### Sampling PGO — AutoFDO and CSSPGO

- **AutoFDO** (Chen et al., CGO 2016): collect Linux `perf` samples on
  an unmodified optimised binary; feed back as profile. No
  instrumentation overhead in production. Accuracy is lower
  (sample-based, debug-info-anchored) but good enough for branch
  ordering and hot / cold.
- **CSSPGO** (Context-Sensitive Sample PGO, Clang 13+): adds
  calling-context to samples. Closer to instrumented-quality with
  sampling overhead.

### What PGO actually changes

- **Inlining decisions.** Hot callees get inlined even when they exceed
  the heuristic threshold; cold callees stay out-of-line.
- **Hot / cold splitting.** Cold basic blocks moved to a `.text.cold`
  section, often at the end of the binary. Major I-cache win.
- **Branch ordering.** The actually-taken path is laid out as
  fall-through, regardless of source order.
- **Register allocation.** Hot blocks get priority.
- **Layout.** Hot functions clustered.

### Wins

- 5–20 % typical; 30 %+ on dispatch-heavy code.
- Meta's BOLT (post-link binary optimiser) shows ~5–10 % is *still* on
  the table after PGO — code layout is the dominant lever.

## 6. Function-attribute inlining discipline

### When `[[gnu::always_inline]]` / `__forceinline` is appropriate

- **Tiny utility functions in tight loops** (a few instructions;
  getter / setter on a hot type).
- **Intrinsic wrappers.** Thin C++ wrappers over compiler intrinsics
  where any call overhead destroys the win.
- **RAII helpers** where the destructor must fold into the caller for
  the optimiser to see scope.

### When it backfires

- **Code bloat.** Inlined many times → I-cache pressure → net loss.
- **Register pressure.** Forcing a large body into a small caller can
  cause spills that cost more than the call.
- **Inlining a function with a cold path.** The cold path now pollutes
  the hot function.

### `[[gnu::flatten]]`

Inlines everything the function calls (recursively, where allowed).
Use sparingly on a single dispatch root — a "fully inlined kernel"
pattern. Catastrophic if applied to a function that calls a deep tree.

### `[[gnu::noinline]]`

- Keep a cold helper out of the caller's I-cache footprint.
- Preserve a function boundary for debugging or `perf` attribution.
- Prevent the inliner from cascading into a body that triggers
  register-pressure regression.

## 7. Hot / cold function placement

`[[gnu::hot]]` and `[[gnu::cold]]` (GCC, Clang) annotate whole
functions:

- **`cold`** — function moved to `.text.unlikely`; calls to it are
  predicted not-taken; inlining heuristic deprioritises it.
- **`hot`** — clustered with other hot functions; inlining heuristic
  prioritises it.

Synergistic with PGO — but PGO usually subsumes manual annotation.
Manual hot / cold is the **fallback when PGO is not feasible**
(shipped game without telemetry, embedded firmware without
representative workload capture).

**Embedded note:** on flash-XIP MCUs, hot / cold does not change
I-cache (often there isn't one), but it can pack hot functions into
RAM-resident sections via linker scripts. Tooling, not the attribute
alone.

## 8. The optimiser's anti-promises

- **Copy elision** — YES, guaranteed since C++17 (P0135). Covered
  under `COPY.8`.
- **Auto-vectorisation** — NO guarantee. Cross-reference the `simd`
  category.
- **Seeing through `volatile`** — NO, intentionally. Every read and
  write to a `volatile` glvalue is preserved (cross-reference
  `EMB.7`).
- **Eliminating dead atomics** — NO. The standard treats atomic
  operations as having side effects visible to other threads; the
  compiler must preserve them.
- **Cross-TU inlining without LTO** — NO. The TU boundary is a hard
  wall. `inline` only permits multiple definitions; it does not force
  or enable cross-TU inlining without LTO.
- **Devirtualisation across TUs** — NO without LTO +
  `-fwhole-program-vtables`. A `final` class or method *can* be
  devirtualised intra-TU without LTO.

## 9. Honest gaps

- No single canonical CppCon / LLVM-Dev-Meeting talk titled "Hot/cold
  splitting" was located. The technique is discussed inside broader
  PGO and BOLT talks (Johnson, Panchenko) rather than as a standalone
  presentation. Flagged rather than invented.
- "Code Modernization: Performance" was a Sutter candidate but could
  not be verified by exact title; *Atomic Weapons* (C++ and Beyond
  2012) and "Modern C++: What You Need to Know" (CppCon 2014) are
  verifiable adjacent material.

## Sources

### Talks (Citable)

- Chandler Carruth, *Garbage In, Garbage Out: Arguing about Undefined
  Behavior with Nasal Demons*, CppCon 2016 —
  <https://www.youtube.com/watch?v=yG1OZ69H_-o>
- Chandler Carruth, *Tuning C++: Benchmarks, and CPUs, and Compilers!
  Oh My!*, CppCon 2015 —
  <https://www.youtube.com/watch?v=nXaxk27zwlk>
- Chandler Carruth, *Efficiency with Algorithms, Performance with Data
  Structures*, CppCon 2014 —
  <https://www.youtube.com/watch?v=fHNmRkzxHWs>
- Matt Godbolt, *What Has My Compiler Done for Me Lately? Unbolting
  the Compiler's Lid*, CppCon 2017 —
  <https://www.youtube.com/watch?v=bSkpMdDe4g4>
- Teresa Johnson, *ThinLTO: Scalable and incremental LTO*, LLVM Dev
  Meeting 2015 — <https://llvm.org/devmtg/2015-10/#talk7>

### Manuals and documentation (Citable)

- Agner Fog, *Optimizing software in C++* and the microarchitecture
  manuals — <https://www.agner.org/optimize/>
- LLVM LTO — <https://llvm.org/docs/LinkTimeOptimization.html>
- Clang ThinLTO — <https://clang.llvm.org/docs/ThinLTO.html>
- LLVM PGO (instrumented + sampling) —
  <https://clang.llvm.org/docs/UsersManual.html#profile-guided-optimization>
- LLVM CSSPGO —
  <https://clang.llvm.org/docs/UsersManual.html#using-sampling-profilers>
- GCC `__builtin_expect` —
  <https://gcc.gnu.org/onlinedocs/gcc/Other-Builtins.html>
- GCC function attributes (`hot`, `cold`, `always_inline`, `flatten`,
  `noinline`) —
  <https://gcc.gnu.org/onlinedocs/gcc/Common-Function-Attributes.html>
- GCC `-fprofile-generate` / `-fprofile-use` —
  <https://gcc.gnu.org/onlinedocs/gcc/Instrumentation-Options.html>
- GCC LTO — <https://gcc.gnu.org/onlinedocs/gccint/LTO-Overview.html>
- Intel 64 / IA-32 Optimization Reference Manual —
  <https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html>
- ARM Architecture Reference Manual —
  <https://developer.arm.com/documentation/>
- cppreference, `[[likely]]` / `[[unlikely]]` —
  <https://en.cppreference.com/w/cpp/language/attributes/likely>

### Papers (Citable)

- Dehao Chen et al., *AutoFDO: Automatic Feedback-Directed Optimization
  for Warehouse-Scale Applications*, CGO 2016 —
  <https://research.google/pubs/pub45290/>
- Maksim Panchenko et al., *BOLT: A Practical Binary Optimizer for Data
  Centers and Beyond*, CGO 2019 —
  <https://arxiv.org/abs/1807.06735>

### Engineering rationale (Citable)

- Linus Torvalds on `likely` / `unlikely` (recurring on LKML) —
  <https://lwn.net/Articles/255364/>
- Dmitry Vyukov, 1024cores — branch prediction notes —
  <https://www.1024cores.net/>
