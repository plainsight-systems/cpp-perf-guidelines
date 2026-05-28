+++
id = "TLM.4"
title = "Front-door the sink behind a macro layer — runtime code names the phase, not the sink"
category = "telemetry"
status = "draft"
summary = "Runtime call sites should name what they are doing, not where the data goes. A thin macro layer routes the event to Tracy, ETW, Insights, or nothing — swappable without touching the hot path."
tags = ["macros", "abstraction", "tracy", "etw", "insights", "boundary"]
+++

## Rationale

Hot-path call sites that import a specific profiler's API
directly — `ZoneScopedN("decode")` straight inside the decode
loop — couple the runtime to that profiler. Swapping Tracy for
Insights, adding ETW for a Windows build, or turning the whole
thing off in a stripped release means a global rewrite.

The pattern every mature engine uses is a **thin macro layer**
at the boundary between runtime code and the sink:

- Runtime code emits `APP_ZONE("decode.loop")`, not
  `ZoneScopedN("decode.loop")`.
- The macro layer (one header) decides which sink the macro
  expands to: Tracy, Optick, Insights, ETW, a custom binary
  ring, or `((void)0)`.
- Build profiles choose the sink at compile time; runtime
  code never knows or cares.

This is the same principle as `LIFE.7` (placement-new sites
are at a boundary, not scattered) and `MEM.*` (allocators are
parameterised through `pmr` and friends, not hard-coded). The
runtime names the *thing it is doing*; the boundary chooses
the implementation.

Concrete examples:

- **Unreal Insights** — runtime code uses
  `TRACE_CPUPROFILER_EVENT_SCOPE(MyEvent)` and
  `TRACE_COUNTER_INCREMENT(MyCounter, n)`. The macros expand
  differently depending on `UE_TRACE_ENABLED` and the
  channel's enable bit. Runtime code never calls
  `FCpuProfilerTrace::Begin*` directly.
- **Tracy** — `ZoneScoped` and friends are macros precisely
  because the disabled expansion is empty. Calling Tracy's
  C++ API directly bypasses the gate.
- An inference-engine adoption of this pattern (see
  References) — runtime code uses `APP_TRACE_*` macros at
  every call site; the boundary layer
  (`src/runtime/trace.h`) is the only place that imports the
  underlying trace implementation. Direct `trace::` calls are
  restricted to the implementation file and the smoke test.

The macro layer also absorbs the **thread-naming** concern
(see `TLM.3`). The boundary registers thread names at thread
start; runtime code does not call `pthread_setname_np`
directly.

A related discipline: **the macro layer must not leak the
sink's types into runtime code**. Runtime code includes a
single header (`telemetry.h`); that header forward-declares or
fully hides the sink type. If runtime code can write
`tracy::ScopedZone` it is no longer behind a boundary.

## Guidance

- **One header is the front door.** All telemetry macros live
  in one place (`telemetry.h`, `runtime/trace.h`, or
  equivalent). The rest of the codebase includes only that
  header.
- **Macros take phase names, not sink-specific types.**
  `APP_ZONE("decode.loop")` is portable; `APP_ZONE(tracy::
  SourceLocation{...})` is not.
- **The sink choice is build-time.** A build profile
  (`--profile`, `--trace`, `--shipping`) picks the sink at
  compile time via `#if defined(...)` in the header. Runtime
  code never branches on which sink is active.
- **Wrap thread naming at the boundary.** A
  `APP_NAME_THREAD("decoder")` macro that compiles to
  `pthread_setname_np` / `SetThreadDescription` is the right
  primitive. Runtime code calls it once at thread creation
  and never imports the platform header.
- **Wrap lock instrumentation at the boundary.** A
  `AppLockable<std::mutex>` typedef that aliases
  `TracyLockable<std::mutex>` or `std::mutex` (depending on
  the build) is the right shape. Runtime code declares
  `AppLockable<std::mutex> m_lock;` and is portable.
- **The boundary header includes nothing public.** No `using
  namespace tracy`, no exposed `ScopedZone` type. The macros
  are the API.
- **Restrict direct sink-API calls to the boundary
  implementation file and tests.** A grep or `clang-query`
  rule in CI that fails the build if `tracy::`, `ITTAPI`, or
  equivalent appears outside the boundary file is the
  enforcement primitive. Cross-reference `TLM.8` for the
  verification step.

## Example

```cpp
// Good: front-door header. The rest of the codebase includes
// only this. Sink choice is at compile time.
// telemetry.h
#pragma once

#if defined(APP_TRACE_TRACY)
    #include <tracy/Tracy.hpp>
    #define APP_ZONE(name)        ZoneScopedN(name)
    #define APP_ZONE_VALUE(v)     ZoneValue(static_cast<std::uint64_t>(v))
    #define APP_COUNTER(name, v)  TracyPlot(name, v)
    #define APP_NAME_THREAD(name) tracy::SetThreadName(name)
    template<class M> using AppLockable = TracyLockable<M>;
#elif defined(APP_TRACE_INSIGHTS)
    #include <Trace/Trace.h>
    #define APP_ZONE(name)        TRACE_CPUPROFILER_EVENT_SCOPE_STR(name)
    #define APP_ZONE_VALUE(v)     ((void)(v))
    #define APP_COUNTER(name, v)  TRACE_COUNTER_SET(name, v)
    #define APP_NAME_THREAD(name) FPlatformProcess::SetThreadName(name)
    template<class M> using AppLockable = M;
#else
    #define APP_ZONE(name)        ((void)0)
    #define APP_ZONE_VALUE(v)     ((void)0)
    #define APP_COUNTER(name, v)  ((void)0)
    #define APP_NAME_THREAD(name) ((void)0)
    template<class M> using AppLockable = M;
#endif

// Good: runtime code uses only the front-door macros and types.
// Portable across sinks; compiles to nothing in shipping.
// decode.cpp
#include "telemetry.h"

void worker_main() {
    APP_NAME_THREAD("worker-decoder");
    while (auto batch = next_batch()) {
        APP_ZONE("decode.batch");
        APP_ZONE_VALUE(batch->size);
        decode(*batch);
        APP_COUNTER("decode.tokens", batch->size);
    }
}

// Bad: runtime code knows about Tracy. Cannot switch sinks
// without rewriting; cannot compile to nothing without an
// #ifdef at every call site.
// decode.cpp
#include <tracy/Tracy.hpp>

void worker_main_bad() {
    tracy::SetThreadName("worker-decoder");
    while (auto batch = next_batch()) {
        ZoneScopedN("decode.batch");
        ZoneValue(static_cast<std::uint64_t>(batch->size));
        decode(*batch);
        TracyPlot("decode.tokens", static_cast<double>(batch->size));
    }
}
```

## Caveats

- **A thin macro layer is not zero abstraction tax.** The
  compiler inlines through it in release builds, but for
  debugging the layer it can be useful to keep functions
  rather than macros — at the cost of slightly worse
  diagnostics when the macro expansion is empty.
- **Macros with arguments that look like function calls can
  break on commas inside template arguments.** Wrap
  template-y arguments in parentheses or use C++20
  `__VA_OPT__` patterns.
- **Some sinks need a non-default constructor argument.**
  Tracy zones embed source-location data via macro
  expansion; the front-door macro must preserve that
  (forward to `ZoneScopedN`, not call `tracy::ScopedZone`
  directly).
- **Conditional `using` template aliases** (as in
  `AppLockable<M>`) need careful `#if`-`#elif` discipline.
  An incorrect specialisation can cause silent type
  mismatches.
- **Boundary erosion is gradual.** Without a verification
  rule (TLM.8), direct sink calls slowly accumulate as
  developers reach past the boundary. Add a grep /
  clang-query gate to the build.
- **The front door is a contract for the binary, not
  per-library.** If a static library is built with one sink
  choice and linked into a binary with a different sink, the
  result is two coexisting telemetry stacks. Make the sink
  choice a project-level setting.

## References

- Unreal Engine, *Trace Developer Guide* — macro front door
  (`TRACE_CPUPROFILER_EVENT_SCOPE_*`, `TRACE_COUNTER_*`,
  `UE_TRACE_LOG`) —
  <https://dev.epicgames.com/documentation/unreal-engine/developer-guide-to-tracing-in-unreal-engine>
- Tracy Profiler — `ZoneScoped`, `TracyPlot`, `FrameMark` as
  macros — <https://github.com/wolfpld/tracy>
- Optick — `OPTICK_EVENT`, `OPTICK_THREAD`, `OPTICK_FRAME`
  macros — <https://github.com/bombomby/optick>
- Microprofile — `MICROPROFILE_SCOPEI` macro layer —
  <https://github.com/jonasmr/microprofile>
- Intel ITT API — `__itt_task_begin`/`end` C API typically
  wrapped in user macros — <https://github.com/intel/ittapi>
- Microsoft PIX — `PIXScopedEvent` macro layer —
  <https://devblogs.microsoft.com/pix/>
- Plainsight Systems internal engineering records (the **Vigil**
  ML inference engine project) — the canonical implementation of
  this pattern for an inference engine, including the rule that
  direct `trace::` calls are restricted to the boundary file.
  Cited for technique provenance; documents are Plainsight-
  private and not publicly available.
- Linux `pthread_setname_np(3)`, Windows
  `SetThreadDescription` — the platform primitives the macro
  layer wraps.
- Cross-reference: `TLM.1` (the macro layer's empty
  expansion is the compile-out story), `TLM.3` (handle and
  thread-name interning happen here), `TLM.5` (the macro
  layer is also where the schema choice is hidden),
  `TLM.8` (verification that direct sink calls do not leak
  outside the boundary), `MEM.*` (analogous `pmr` boundary).
