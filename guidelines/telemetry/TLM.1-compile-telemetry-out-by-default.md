+++
id = "TLM.1"
title = "Compile telemetry out by default — release and shipping builds carry zero instrumentation cost"
category = "telemetry"
status = "draft"
summary = "Telemetry that is on in the binary is paying for itself on every cycle. The default is off; the default is verified by reading the generated code, not by assuming the macros expanded to nothing."
tags = ["compile-out", "tracy", "macros", "build-profile", "usdt"]
+++

## Rationale

Every cycle a telemetry harness consumes in a shipping build is a
cycle the work loop did not have. The cross-engine answer is
unanimous: instrumentation is **off by default in release and
shipping builds**, and the macro layer expands to nothing.

Two distinct shapes of "zero cost" exist, and conflating them
produces wrong claims about overhead:

- **True elision.** Tracy (`TRACY_ENABLE` undefined), Unity
  (`ProfilerMarker.Begin/End` conditionally compiled), Optick
  (`OPTICK_ENABLE_GPU` and friends), Unreal Stats Group inclusion,
  a project-specific `APP_ENABLE_TRACE=OFF` build profile. The macro is
  defined as `((void)0)` or empty; the compiler emits **no
  instruction** where the probe was.
- **NOP-when-disabled.** USDT probes (`<sys/sdt.h>` `STAP_PROBE`),
  Linux `user_events`. The compile gate leaves a single `nop` in
  the binary plus an ELF note describing the probe; when no
  consumer is attached (`perf`, eBPF, DTrace, LTTng) the cost is
  one skipped instruction. When a consumer attaches, the `nop` is
  live-patched to a tracepoint.

Both are valid; choose deliberately. True elision wins for
self-contained capture (a game engine shipping a profiler in the
binary, a benchmark harness that runs once and exits). USDT wins
when *on-host attachment matters more than self-contained capture* —
a running production service, an embedded device with a remote
debugger, a binary you cannot rebuild against the user's profiler
of choice.

The trap is treating "compile out by default" as an *assertion*
rather than a *verification step*. A `#define APP_TRACE(...)
((void)0)` looks like elision, but if the surrounding `if` branch
depends on a runtime variable, the compiler may still emit the
branch test. The only sound check is `TLM.8`: read the generated
code or scan the shipped archive.

## Guidance

- **Default to off.** The shipping/release build profile defines
  no telemetry-enable macro. The runtime cost is whatever the
  generated code has — which should be nothing, and which TLM.8
  validates.
- **Pick the shape of "off" deliberately.** True elision for
  self-contained binaries (games, benchmark harnesses, one-shot
  tools). USDT / `user_events` for long-running services where
  the operator may attach a tracer at runtime.
- **Make the gate a compile-time macro, not a runtime variable.**
  A `bool g_trace_enabled` read on every probe site is not "off";
  it is "off-but-still-branchy." If the build profile says off,
  the macro must expand to nothing.
- **Pair the gate with build-profile fail-closed.** The build
  system should reject combinations that contradict the
  performance contract (e.g., `--performance --trace`); an
  exit-code-2 fail-closed pattern at the build script is the
  right shape.
- **Verify, do not assume.** Read the generated assembly for the
  hot loop in the disabled build, or run `nm -C` and `strings`
  against the shipped archive (`TLM.8`). "I `#define`d the macro
  to nothing" is not evidence; the linked output is.
- **Document the cost of the *enabled* build, not just the
  disabled one.** Tracy's ~2.25 ns per zone (begin + end) on
  x86 is a concrete number; users decide whether to ship enabled
  or not with that number in hand.

## Example

```cpp
// Good (true elision): the macro layer expands to nothing when
// the build profile does not define the enable macro. The hot
// path then carries zero instructions for the probe.
#if defined(APP_PROFILE_ENABLED)
    #include <tracy/Tracy.hpp>
    #define APP_ZONE(name)        ZoneScopedN(name)
    #define APP_PLOT(name, value) TracyPlot(name, value)
#else
    #define APP_ZONE(name)        ((void)0)
    #define APP_PLOT(name, value) ((void)0)
#endif

void decode_loop(std::span<const Token> input) noexcept {
    APP_ZONE("decode.loop");                 // disappears in release
    for (const auto& tok : input) {
        process(tok);
    }
}

// Good (USDT / NOP-when-disabled): the binary carries a single
// nop plus an ELF note. perf / eBPF / DTrace can attach without
// a rebuild; otherwise the cost is one skipped instruction.
#include <sys/sdt.h>

void on_policy_change(int new_policy) noexcept {
    STAP_PROBE1(myapp, scheduler_policy_changed, new_policy);
    // ... apply policy ...
}

// Bad: "off" via runtime variable. Even when g_trace_enabled is
// false, every probe site still loads a global and branches on
// it. Not elision; not free.
extern std::atomic<bool> g_trace_enabled;

void decode_loop_bad(std::span<const Token> input) noexcept {
    if (g_trace_enabled.load(std::memory_order_relaxed)) {
        emit_zone_begin("decode.loop");
    }
    for (const auto& tok : input) { process(tok); }
    if (g_trace_enabled.load(std::memory_order_relaxed)) {
        emit_zone_end();
    }
}
```

## Caveats

- **"Elided" claims are unverified by default.** Until
  `nm`/`strings` on the shipped archive prove no telemetry
  symbols or strings remain (TLM.8), elision is an aspiration.
- **`__attribute__((always_inline))` and LTO can erase the
  difference between USDT NOP and true elision** when the
  compiler proves the probe is unreachable. They can also fail
  to do so; do not assume.
- **NDEBUG is not the right gate.** `NDEBUG` controls `assert`;
  it has nothing to do with telemetry. Use a dedicated macro
  (`APP_PROFILE_ENABLED`, `TRACY_ENABLE`, `OPTICK_ENABLE`).
- **Library boundaries can carry residual cost.** If a static
  library was compiled with telemetry enabled, linking it into a
  release binary brings the cost with it. The compile gate must
  be consistent across all translation units of the artefact.
- **Inline-asm probes are not free even when disabled.** A `nop`
  is one instruction in the icache; for very tight inner loops
  with many probe sites, the icache footprint of NOPs is
  measurable.
- **Telemetry that is on in the binary changes the optimiser's
  choices.** Even before the probe runs, its presence affects
  register allocation, inlining, and branch layout around the
  probe site. The cost of "telemetry enabled" is not just the
  probe — it is the whole codegen shape.

## References

- Tracy Profiler — <https://github.com/wolfpld/tracy>
- Tracy manual (compile-time gating, overhead numbers) —
  <https://github.com/wolfpld/tracy/blob/master/manual/tracy.tex>
- Unity, *Profiling Core API — `ProfilerMarker` guide* —
  <https://docs.unity3d.com/Packages/com.unity.profiling.core@1.0/manual/profilermarker-guide.html>
- Optick — <https://github.com/bombomby/optick>
- Unreal Engine, *Stats System Overview* —
  <https://dev.epicgames.com/documentation/unreal-engine/unreal-engine-stats-system-overview>
- SystemTap `<sys/sdt.h>` `STAP_PROBE` family (USDT) — see Red
  Hat developer documentation on userspace probes.
- Linux `user_events` —
  <https://docs.kernel.org/trace/user_events.html>
- Plainsight Systems internal engineering records (the
  **Vigil** ML inference engine project) — the compile-gate
  inventory and build-profile fail-closed pattern. Cited for
  technique provenance; the documents are Plainsight-private
  and not publicly available.
- Cross-reference: `TLM.4` (the macro layer that hides which
  flavor of "off" is chosen), `TLM.8` (verifying that the
  disabled path is genuinely empty), `GEN.7` (cold/error paths
  and I-cache pollution — telemetry that is on perturbs the
  same caches), `MEM.10` (production engines build diagnostics
  in as a design requirement but gate the cost).
