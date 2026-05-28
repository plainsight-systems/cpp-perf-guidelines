+++
id = "TLM.2"
title = "Channelize — CPU timing, counters, memory, locks, frames, bookmarks, and payloads are separate channels with separate costs"
category = "telemetry"
status = "draft"
summary = "Each kind of telemetry has a different cost model. Treat CPU zones, counters, memory hooks, lock contention, frames, bookmarks, and payloads as independent channels with independent activation."
tags = ["channels", "counters", "memory", "locks", "frames", "unreal-insights", "perfetto"]
+++

## Rationale

A telemetry harness that emits "everything" in a single stream
forces every consumer to pay for every event whether they need it
or not. Mature profilers — Unreal Insights, Perfetto, Tracy,
Optick, Intel ITT, PIX — converge on a *channel* model: each kind
of event lives in its own logical stream, each channel has its
own activation, and each channel has its own documented cost.

The channels that recur across the field:

- **CPU zones** (`Cpu` in Insights, `category("cpu")` in Perfetto,
  `ZoneScoped` in Tracy, `OPTICK_EVENT`). Per-zone overhead is
  the unit number every profiler publishes (Tracy: ~2.25 ns per
  begin+end on x86).
- **Counters** (`TRACE_COUNTER_INCREMENT` in Insights,
  `TracyPlot` in Tracy, `__itt_counter` in ITT, Chrome Trace
  Event `C` phase). A monotonic or gauge value sampled over
  time. Not an event — record the value; the analyzer
  interpolates.
- **Memory** (`MemAlloc` and `MemTag` channels in Insights,
  `TracyAlloc`/`TracyFree` in Tracy, Heaptrack as an external
  collector). Documented as higher-overhead than zones; every
  allocation is intercepted.
- **Locks** (`TracyLockable` in Tracy, `perf lock` on Linux,
  Intel VTune locks-and-waits, mutrace historically). The
  contending thread is *not on CPU*; a CPU-only profile sees
  nothing. A separate channel is the only way to surface
  contention.
- **Frames / phases** (`FrameMark` in Tracy, `Frame` channel in
  Insights, `OPTICK_FRAME`, `__itt_frame_begin_v3`). The periodic
  boundary marker the analyzer uses to aggregate everything
  else. For frame-less systems (servers, inference, embedded
  control loops) the boundary must be invented and emitted
  (`request_start`, `decode_step`, `tick`).
- **Bookmarks** (`TRACE_BOOKMARK` in Insights, `CSV_EVENT` in CSV
  Profiler, `TracyMessage`). Sparse, infrequent state-change
  annotations — covered in `TLM.7`.
- **Payloads** (screenshots, stack traces, memory dumps,
  capture-rate-limited frames). Treat as a separate channel
  precisely because the cost is per-payload, not per-event.

The reason this matters in C++ specifically is that **each
channel has a different emit shape**, and conflating them forces
the cheapest-channel costs upward. A counter sample is a single
atomic store plus a record; a memory allocation hook is a
function call on the malloc/free path; a CPU zone is two
timestamps plus a record; a stack-trace payload is `backtrace()`
or `libunwind` — orders of magnitude apart in cost.

Channels also serve as the **enable axis**. Long captures run
with cheap channels on and expensive channels off; short
diagnostic captures turn the expensive ones on. Without
channels, every capture is all-or-nothing.

## Guidance

- **Define channels explicitly.** Name them. CPU, counters,
  memory, locks, frames, bookmarks, payloads — and any
  domain-specific ones (a representative example from an
  inference engine: `decode`, `scheduler`, `cache`, `sampler`,
  `callback`).
- **Each channel has its own enable bit.** Compile-time or
  run-time, but separate. The runtime decides what to emit by
  checking the channel's bit, not a global "telemetry on" flag.
- **Counters are not events.** Use the counter channel
  primitives (`TracyPlot`, `TRACE_COUNTER_*`, `__itt_counter`),
  not "emit an event whose value is the count." The analyzer
  knows how to interpolate counter samples and the storage
  shape is different.
- **Memory channel is opt-in and labeled.** Allocation hooks are
  intrusive (`malloc`/`free` interception, `new`/`delete`
  overrides) and observably change the program. Treat the
  memory channel as a separate capture mode, not a default-on.
- **Locks need their own channel for "wait time."** A
  CPU-zone-only profiler shows nothing while threads wait on
  mutexes. `TracyLockable` and equivalents wrap the mutex type
  so contention becomes a visible event.
- **Pick a frame boundary even in frame-less systems.** If the
  system has no natural frame (server, inference, embedded
  control loop), invent one. The analyzer needs it to
  aggregate.
- **Cross-reference `CONC.*` for lock contention findings.** The
  channel surfaces contention; `CONC.1` (false sharing) and
  `CONC.7` (atomic-ordering cost) are where the fixes live.

## Example

```cpp
// Good: explicit channels with independent enable bits. The
// runtime macro layer checks the per-channel bit before emit.
namespace app::telemetry {
    enum Channel : std::uint32_t {
        kCpu      = 1u << 0,
        kCounters = 1u << 1,
        kMemory   = 1u << 2,
        kLocks    = 1u << 3,
        kFrames   = 1u << 4,
        kBookmark = 1u << 5,
        kPayload  = 1u << 6,
    };
    inline std::uint32_t g_enabled_channels = 0;   // set by build profile

    constexpr bool enabled(Channel c) noexcept {
        return (g_enabled_channels & c) != 0;
    }
}

#define APP_CPU_ZONE(name)                                \
    auto _z = app::telemetry::enabled(                    \
                  app::telemetry::kCpu)                   \
        ? app::telemetry::CpuZone{name} : app::telemetry::CpuZone{}

#define APP_COUNTER(name, value)                           \
    do {                                                     \
        if (app::telemetry::enabled(                       \
                app::telemetry::kCounters))                \
            app::telemetry::counter_emit(name, (value));   \
    } while (0)

void decode_loop(std::size_t n) noexcept {
    APP_CPU_ZONE("decode.loop");
    for (std::size_t i = 0; i < n; ++i) {
        process_token(i);
    }
    APP_COUNTER("decode.tokens", n);
}

// Frame boundary in a frame-less system: name the periodic unit.
void run_inference_session() {
    while (auto request = next_request()) {
        APP_FRAME_BEGIN("inference.request");
        process(*request);
        APP_FRAME_END("inference.request");
    }
}

// Bad: one giant "telemetry on" flag. Everything emits or
// nothing does; allocation hooks pay even when only CPU
// timings were wanted.
extern bool g_telemetry_on;

void decode_loop_bad(std::size_t n) noexcept {
    if (g_telemetry_on) emit_event("decode.loop.begin");
    for (std::size_t i = 0; i < n; ++i) process_token(i);
    if (g_telemetry_on) {
        emit_event("decode.loop.end");
        emit_alloc_report();    // pays whether wanted or not
        emit_lock_report();     // pays whether wanted or not
    }
}
```

## Caveats

- **The channel split is logical, not necessarily physical.**
  Tracy emits all channels into one binary stream tagged by
  type; the channel separation is at the event-record level,
  not at the file level. Perfetto similarly. Treat "channel"
  as the activation/cost axis, not necessarily the storage
  axis.
- **Counters can be expensive when sampled per-iteration.** A
  `TracyPlot("tokens", ++count)` on every loop iteration is
  cheap per-call but still emits a record per call; for very
  tight loops, sample the counter at frame boundaries instead.
- **Memory channel intersects with custom allocators
  (`MEM.*`).** A custom arena (`MEM.1`) does not go through
  `malloc`/`free`; a profiler hooking `malloc` will not see it.
  Allocator-internal instrumentation is the answer.
- **Lock channels miss spin-locks and lock-free contention.**
  A `std::atomic` CAS loop that retries 50 times shows
  nothing in a mutex-based lock channel. Use CPU sampling
  (`SIMD`-grade analysis) to find these.
- **GPU/accelerator channel is its own discipline** —
  see `TLM.11`. The CPU-side channel model does not capture
  GPU events; calibration is required.

## References

- Unreal Engine, *Developer Guide to Tracing in Unreal Engine* —
  channels listed (`Cpu`, `Counters`, `Gpu`, `MemAlloc`,
  `MemTag`, `File`, `Frame`, `Stats`) —
  <https://dev.epicgames.com/documentation/unreal-engine/developer-guide-to-tracing-in-unreal-engine>
- Perfetto, *Track Events* — category model and
  per-category enable/disable —
  <https://perfetto.dev/docs/instrumentation/track-events>
- Tracy Profiler — channel types (zones, plots, allocations,
  locks, frames, messages) —
  <https://github.com/wolfpld/tracy>
- Intel ITT API — task / counter / frame / domain primitives —
  <https://github.com/intel/ittapi>
- Optick — frame markers (`OPTICK_FRAME`), tags, GPU events —
  <https://github.com/bombomby/optick>
- Microprofile — CPU + GPU correlated timing with per-thread
  buffers — <https://github.com/jonasmr/microprofile>
- Plainsight Systems internal engineering records (the **Vigil**
  ML inference engine project) — the channelized model adopted
  for an inference engine. Cited for technique provenance;
  documents are Plainsight-private and not publicly available.
- Cross-reference: `TLM.1` (each channel inherits the
  compile-out gate), `TLM.7` (the bookmark channel
  specifically), `CONC.1` (false sharing of telemetry
  counters), `MEM.*` (custom allocators interact with the
  memory channel), `TLM.11` (GPU/accelerator channel
  correlation).
