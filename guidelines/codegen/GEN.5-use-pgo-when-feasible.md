+++
id = "GEN.5"
title = "Use PGO when feasible; AutoFDO or CSSPGO when instrumentation is impractical"
category = "codegen"
status = "draft"
summary = "PGO replaces compiler guesses with profile data. Use instrumented PGO for representative workloads and sampling PGO when instrumentation is impractical."
tags = ["pgo", "autofdo", "csspgo", "bolt"]
+++

## Rationale

Without profile data, the compiler's inlining, hot/cold splitting, and
branch-ordering decisions are heuristic — informed guesses based on
source structure. **Profile-guided optimisation (PGO)** replaces guesses
with measurements: you run a representative workload, collect a profile,
and rebuild with the profile as input. The compiler then knows which
callees are hot, which branches are taken, which functions are cold.

The wins are concrete:

- **Inlining decisions become evidence-based.** Hot callees get inlined
  even when they exceed the heuristic threshold; cold callees stay
  out-of-line.
- **Hot / cold splitting becomes automatic.** Cold basic blocks move to
  a `.text.cold` section; the hot function's I-cache footprint shrinks
  to what is actually hot.
- **Branch ordering follows reality.** The actually-taken path becomes
  fall-through regardless of source order.
- **Register allocation is biased.** Hot blocks get priority.
- **Function layout is clustered.** Hot functions are placed near each
  other in `.text`, improving I-cache locality across calls.

Typical wins: **5–20 % runtime** on engines; **30 %+** on
dispatch-heavy code (lots of virtual calls, lots of branch decisions).
Meta's BOLT post-link binary optimiser shows another 5–10 % is *still*
on the table after PGO — code layout is the dominant lever in modern
hot-path performance, larger than algorithmic-level micro-optimisations.

Two flavours of PGO:

- **Instrumented PGO** — build twice. First with `-fprofile-generate`;
  run a representative workload; rebuild with `-fprofile-use`. Accurate
  but the instrumented binary runs slower (1.5–3×), so the workload
  must tolerate it.
- **Sampling PGO — AutoFDO / CSSPGO** (Google, LLVM). Run the
  production-optimised binary under Linux `perf`, then convert the
  perf data to a PGO profile. No instrumentation overhead.
  Accuracy is lower (samples are debug-info-anchored), but excellent
  for branch ordering and hot / cold. CSSPGO adds calling-context to
  the samples for closer-to-instrumented quality.

## Guidance

- **Use instrumented PGO** when you can run a representative workload
  through an instrumented build — internal services, server fleets,
  game engines with reproducible benchmark scenes.
- **Use sampling PGO** (AutoFDO or CSSPGO) when instrumentation is
  impractical — shipped binaries in production, latency-sensitive
  services that cannot tolerate the instrumented build's overhead,
  workloads that only occur in the field.
- **Combine PGO with LTO.** They are additive: PGO improves intra-TU
  decisions, LTO unlocks cross-TU optimisation. ThinLTO + PGO is the
  standard shipping configuration on modern toolchains.
- **Treat the profile as code.** Check it in, version it, regenerate
  it on workload-shape changes. A stale profile actively misleads
  the compiler.
- **When PGO is enabled, audit static branch hints (`GEN.1`).** Profile
  data dominates — `[[likely]]` annotations that contradict the
  profile are noise that the reviewer should remove.
- **Embedded** — PGO works on Cortex-M targets via GCC. The harder
  problem is collecting a representative profile on a board with no
  filesystem; the instrumented build typically streams counters over
  semihosting or a debug UART.

## Example

```text
# Instrumented PGO (Clang):
#
# 1) Build with instrumentation. Binary will be slower (~1.5-3x).
clang++ -O3 -fprofile-generate=./pgo-data -c src/*.cpp -o build/
clang++ -O3 -fprofile-generate=./pgo-data -o my_app build/*.o
#
# 2) Run a representative workload. Profile is emitted into ./pgo-data.
./my_app --bench=representative-workload
#
# 3) Merge the raw profile.
llvm-profdata merge -output=my_app.profdata ./pgo-data/*.profraw
#
# 4) Rebuild with the profile. This is the shipping binary.
clang++ -O3 -flto=thin -fprofile-use=my_app.profdata -c src/*.cpp -o build/
clang++ -O3 -flto=thin -fprofile-use=my_app.profdata -o my_app build/*.o

# Sampling PGO with AutoFDO (Clang):
#
# 1) Build a normal optimised binary with extra debug info for AutoFDO.
clang++ -O3 -flto=thin -gline-tables-only \
         -fdebug-info-for-profiling -o my_app src/*.cpp
#
# 2) Profile under perf on representative production traffic.
perf record -b -e br_inst_retired.near_taken -- ./my_app --serve
perf script | create_llvm_prof --binary=my_app --out=my_app.prof
#
# 3) Rebuild with the sampled profile.
clang++ -O3 -flto=thin -fprofile-sample-use=my_app.prof \
        -o my_app src/*.cpp
```

```cmake
# CMake snippet — wire PGO behind an option.
option(MY_APP_PGO "Build with PGO" OFF)
option(MY_APP_PGO_GENERATE "Build with PGO instrumentation" OFF)

if (MY_APP_PGO_GENERATE)
    target_compile_options(my_app PRIVATE -fprofile-generate=${CMAKE_BINARY_DIR}/pgo-data)
    target_link_options   (my_app PRIVATE -fprofile-generate=${CMAKE_BINARY_DIR}/pgo-data)
elseif (MY_APP_PGO)
    target_compile_options(my_app PRIVATE -fprofile-use=${CMAKE_SOURCE_DIR}/pgo/my_app.profdata)
    target_link_options   (my_app PRIVATE -fprofile-use=${CMAKE_SOURCE_DIR}/pgo/my_app.profdata)
endif()
```

## Caveats

- **Representativeness is the whole game.** A profile from an
  unrepresentative workload optimises for the wrong hot paths. Build
  the benchmark workload deliberately; revisit it when behaviour
  changes.
- **Instrumented PGO slows the instrumented build 1.5–3×.** Latency
  budgets, real-time deadlines, and small embedded targets may not
  tolerate the instrumented run. Sampling PGO is the answer there.
- **Profiles are tied to source.** A function that gets refactored or
  renamed disappears from the profile; the compiler falls back to
  heuristics for it. Regenerate on major source movements.
- **Instrumented and sampling PGO are not interchangeable.**
  Instrumented produces counter-accurate data; sampling produces
  statistical data. Sampling is excellent for branch ordering and hot /
  cold but weaker for fine-grained value-profile information.
- **CSSPGO requires recent toolchains.** Clang 13+; binutils with
  appropriate support. Verify on the target.
- **PGO is not a substitute for measurement.** A 5–20 % win from PGO
  does not justify a 10× algorithmic regression. Use it on code that
  has been measured and shaped first.

## References

- Clang, *Profile-guided optimization* —
  <https://clang.llvm.org/docs/UsersManual.html#profile-guided-optimization>
- Clang, *Using sampling profilers* (AutoFDO and CSSPGO) —
  <https://clang.llvm.org/docs/UsersManual.html#using-sampling-profilers>
- GCC, `-fprofile-generate` / `-fprofile-use` —
  <https://gcc.gnu.org/onlinedocs/gcc/Instrumentation-Options.html>
- Dehao Chen et al., *AutoFDO: Automatic Feedback-Directed Optimization
  for Warehouse-Scale Applications*, CGO 2016 —
  <https://research.google/pubs/pub45290/>
- Maksim Panchenko et al., *BOLT: A Practical Binary Optimizer for
  Data Centers and Beyond*, CGO 2019 —
  <https://arxiv.org/abs/1807.06735>
- Cross-reference: `GEN.4` (LTO — additive with PGO), `GEN.1` (audit
  static branch hints under PGO), `GEN.7` (`[[gnu::cold]]` is the
  manual fallback when PGO is not feasible).
