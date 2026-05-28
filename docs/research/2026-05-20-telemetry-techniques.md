# C++ Telemetry & Observability Harnesses — Technique Extraction

Research note — 2026-05-20. Supports packet
`2026-05-20-telemetry-category-buildout`. Technique-extraction pass
for the ninth corpus category — telemetry harnesses for
performance-sensitive C++ systems. The framing is narrow: this is
*not* generic observability (metrics-to-backend, distributed
tracing). It is the engineering discipline of instrumenting a hot
C++ system without contaminating clean-throughput measurements,
without leaking diagnostic behavior into product code paths, and
without lying about what was measured.

Sources are classified per the `CONTRIBUTING.md` sourcing rule:

- **Citable** — free public talk / paper / blog / open-source docs.
- **Cite-by-reference** — copyrighted book.
- **Study-only code** — proprietary, undocumented, or NDA.
- **Permissive code** — MIT / BSD / Apache-2.0 / similar.

Seed material — two internal Plainsight Systems engineering
records from the **Vigil** ML inference engine project. They
are *Plainsight-private*: cited here for technique provenance,
not reproduced in this corpus, and not publicly available.
Named once for full context; subsequent references in this
note use generic terms ("the seed material", "internal source").

- *Game-engine profiling and debug patterns* — cross-engine
  survey (Unreal Stats, Insights Trace, CSV Profiler, Unity
  ProfilerMarker, Godot Performance, Tracy). Eight distilled
  design rules.
- *Unreal-style observability boundary* — the adoption decision
  that operationalised the eight rules: macro front door,
  compile-gate inventory, artifact-scan validation, observer-
  effect labeling.

These are **cite-by-reference** sources for the corpus —
treated like an unpublished engineering paper. The principles
they articulate are technique-level and not copyrightable; the
documents themselves are not reproduced.

---

## 1. The failure mode this category addresses

A telemetry harness that *measures* well but *lies* about what was
measured is worse than no harness at all. The concrete failure modes
observed on the consuming side:

- Environment-variable-gated experimental behavior leaking from
  diagnostic builds into product code paths.
- `stderr` "debug stats" that fire on every iteration of the
  decode/render/tick loop, baked into the benchmark numbers.
- Diagnostic builds masquerading as clean-throughput evidence — no
  label, no observer-effect note, just "we ran the benchmark."
- Compile gates whose disabled expansion was assumed to be free but
  was never verified in the generated code or in the shipped
  archive.

This is the No-Facades rule applied to performance measurement. The
telemetry harness is part of the contract — when it lies, the rest
of the system has no ground truth.

## 2. The converged cross-engine pattern

Unreal Insights (and the legacy Unreal Stats System), Unity's
ProfilerMarker API, Godot's Performance singleton, Tracy, Optick,
Microprofile, Perfetto, Intel ITT, and Linux `perf` user markers
all converge on the same architecture. The names differ; the
shape is the same.

- **Compile out by default.** Release/shipping builds carry zero
  instrumentation cost. Macros expand to nothing. Tracy's
  `TRACY_ENABLE`, Unity's conditional `Begin`/`End`, Optick's
  `optick.config.h`, and the seed material's `APP_ENABLE_TRACE`
  gate.
- **Channels.** CPU timing, counters, memory, GPU/accelerator,
  file/I-O, frames, locks, bookmarks, and payloads are separate
  channels with independent activation. Unreal Insights names them
  explicitly (`Cpu`, `Counters`, `Gpu`, `MemAlloc`, `MemTag`,
  `File`, `Frame`); Perfetto calls them categories.
- **Static names on the hot path.** Per-event dynamic strings are
  documented overhead in every profiler that supports them. Unity
  static `ProfilerMarker` handles, Perfetto's interned-string
  distinction (`StaticString` vs `DynamicString`), and Tracy's
  source-location interning are the same idea: names are sent to
  the sink once, not per-event.
- **Macro front door.** Runtime call sites name *the phase*; the
  macro layer decides which sink (or none) receives the event.
  `ZoneScoped`, `OPTICK_EVENT`, `MICROPROFILE_SCOPEI`,
  `PIXScopedEvent`, `__itt_task_begin`,
  `TRACE_CPUPROFILER_EVENT_SCOPE`.
- **Structured binary events.** The runtime writes a compact
  record; the analyzer formats it. Chrome Trace Event JSON,
  Perfetto protobuf, CTF (Common Trace Format), Unreal Insights
  binary trace, Tracy binary stream — all of them, never
  `stderr` text on the hot path.
- **Diagnostic mode ≠ benchmark mode.** Telemetry-enabled runs
  carry an observer-effect label and cannot be quoted as clean
  throughput. Unity's "deep profiling" disclaimer, Unreal CSV
  Profiler's "not in shipping" doc, Tracy's enabled-build
  acknowledgement, and the seed material's build-profile
  fail-closed at the build script.
- **Sparse bookmarks for state changes.** Bookmarks (Unreal
  `TRACE_BOOKMARK`, CSV `CSV_EVENT`, Tracy `TracyMessage`) are
  for *transitions* — policy changes, scene loads, GC events —
  not for per-iteration progress.
- **Artifact-scan validation.** The seed material's contribution:
  prove the disabled path is genuinely empty by scanning shipped
  archives with `strings` and `nm -C` for diagnostic symbols, env
  names, and trace-sink labels. The novelty is the *validation
  step* — the underlying "compile to nothing" claim is implicit
  in every other source.

The eight bullets above are the draft slate for TLM.1–TLM.8.

## 3. Gaps in the draft — what the cross-engine survey missed

Going past the Unreal-and-Unity baseline of the seed material
into Tracy's manual, Optick's source, Microprofile's design,
Perfetto's SDK, Intel ITT, PIX, RAD Telemetry's public discussion,
and the Linux `perf` / `user_events` / CTF lineage surfaces two
principles the draft slate does not capture.

### 3.1 Timestamp source discipline

The draft slate is silent on *how the runtime gets a timestamp*.
This is the most C++-and-hardware-specific question in the category.

On x86, `rdtsc` is not a serialising instruction. The CPU is free
to reorder it around the work it claims to measure; a bare `rdtsc`
in a hot loop can report timings that have no relationship to the
code immediately preceding it. The mitigations are well-documented
but specific:

- `rdtscp` — serialises with respect to prior instructions but not
  later ones; one-instruction cost.
- `lfence; rdtsc` — explicit serialisation, two-instruction
  sequence; the canonical "I really mean this" pattern.
- `mfence; lfence; rdtsc; lfence` — full fence both sides; rare
  outside microbenchmark harnesses.

Beyond serialisation, the *invariant TSC* property must hold for
the counter to be usable as a wall clock. Pre-Sandy-Bridge Intel
CPUs without Invariant TSC could change TSC rate with frequency
scaling; modern CPUs are guaranteed Invariant TSC on most SKUs,
but the guarantee is per-socket. Cross-CPU comparison without
calibration is unsound.

The alternatives in the C++ runtime layer:

- `std::chrono::steady_clock` — portable, but the underlying
  resolution and cost are implementation-defined. On Linux this is
  typically `clock_gettime(CLOCK_MONOTONIC)`, which is fast (one
  vDSO call) but not as fast as fenced `rdtsc`.
- `clock_gettime(CLOCK_MONOTONIC_RAW)` — Linux-specific; avoids
  NTP adjustments.
- `mach_absolute_time()` — macOS; requires `mach_timebase_info()`
  to convert to nanoseconds.
- `QueryPerformanceCounter` — Windows; documented frequency.

Tracy makes the timestamp-source choice explicit and per-platform:
fenced `rdtsc` on x86 Sandy Bridge and later, ARM generic timer
register on AArch64, with fallback knobs (`TRACY_TIMER_FALLBACK`,
`TRACY_TIMER_QPC`) for cases where the default is wrong.

The corpus needs a guideline naming this. Not just "use a fast
clock" but: *pick the timestamp source explicitly, document its
ordering guarantees, and verify the disabled assumption (invariant
TSC, frequency stability) at startup.*

Citable sources:
- Intel Software Developer's Manual Vol 2 (`RDTSC`, `RDTSCP`),
  Vol 3A §17.17 ("Invariant TSC").
- Andrey Akinshin, *Time Stamp Counter (TSC)* —
  <https://aakinshin.net/vignettes/tsc/>
- *A Systems Engineer's Guide to Benchmarking with RDTSC* —
  <https://blog.codingconfessions.com/p/rdtsc>
- Tracy manual, timer source selection —
  <https://github.com/wolfpld/tracy/blob/master/manual/tracy.tex>

### 3.2 Per-thread lock-free emit with a lossy ring buffer

The draft slate covers the *record format* (TLM.5 — structured
events, not text) but is silent on *how the record reaches the
sink*. This is the single largest implementation principle behind
every profiler the slate already cites.

Every mature profiler converges on the same emit shape:

- **Per-thread buffers** — the work thread writes to its own
  ring buffer; no cross-thread contention on the emit path.
- **Single-producer / single-consumer queue** — atomic head and
  tail counters with relaxed-or-acquire-release ordering; no
  locks.
- **Lossy on overflow** — the buffer overwrites old events when
  full rather than blocking the producer. This is the
  production-safety contract: telemetry can never deny service to
  the work loop it is observing.
- **Dedicated drain** — a sink thread, an in-process flush, or an
  external collector (`traced`, `perf record`, ETW session)
  reads the buffer; the work thread never serialises against the
  reader.

Tracy documents this at roughly 2.25 ns per zone (begin + end) on
x86, on a per-thread lock-free queue. Microprofile uses 2 MB
per-thread buffers by default. Optick gives each thread an event
buffer with a dedicated worker. Perfetto's producer SDK puts the
producer-side buffer in shared memory with the `traced` daemon.
LTTng's CTF ring buffer specifies the wait-free protocol formally.

The lossy-vs-lossless choice is the production contract:

- **Lossy** — the ring overwrites; the trace will be missing
  events when the consumer falls behind, but the work loop is
  never blocked. The right default for anything that ships.
- **Lossless** — the producer blocks (or returns an error) when
  the buffer is full. Useful for development/debug runs where you
  need every event; never safe for production.

The corpus needs a guideline naming this shape. Not just "fast
emit" but: *per-thread SPSC ring buffer, lossy on overflow, drained
by a separate thread or external collector. Never let the
telemetry path block the work path.*

Citable sources:
- Tracy manual — <https://github.com/wolfpld/tracy/blob/master/manual/tracy.tex>
- Microprofile design — <https://github.com/jonasmr/microprofile>
- Optick — <https://github.com/bombomby/optick>
- Perfetto SDK docs — <https://perfetto.dev/docs/instrumentation/track-events>
- LTTng CTF ring-buffer protocol — <https://lttng.org/docs/>
- Linux `perf_event_open(2)` ring-buffer semantics (lossy with
  "lost events" counter) — kernel.org
- Linux `user_events` documentation —
  <https://docs.kernel.org/trace/user_events.html>

## 4. Tier-2 principles — fold into existing guidelines, not their own

Several principles are real but narrow enough to live as sections
inside existing guidelines.

### 4.1 Thread naming (fold into TLM.4)

Every analyzer UI treats the thread name as the primary axis of
legibility. The instrumentation is one call per thread at startup:
`pthread_setname_np` (Linux/glibc), `pthread_setname_np` (macOS,
different signature), `SetThreadDescription` (Windows),
`prctl(PR_SET_NAME, ...)`. C++ `std::thread` does not name threads;
the macro front door (TLM.4) is the right place to put the call.

Tracy `SetThreadName`, Optick `OPTICK_THREAD(name)`, Intel ITT
`__itt_thread_set_name`.

### 4.2 Schema as ABI (fold into TLM.5)

Structured events are TLM.5; the corollary is that the wire/file
format is a contract. Prefer formats with a published schema
(Chrome Trace Event JSON; Perfetto protobuf; CTF) or version your
own and treat the layout as ABI. Tracy's binary format is *not*
published; the consequence is that runtime and viewer are tied
together at the same version — a documented choice, but a choice.

### 4.3 USDT / `user_events` as a second flavor of "zero cost" (fold into TLM.1)

TLM.1 conflates two distinct shapes of "compiled out":

- **True elision** — Tracy / Unity / Optick / Unreal Stats Group
  inclusion. The compile gate removes the macro entirely; the
  binary has *no instruction* where the probe was.
- **NOP-when-disabled** — USDT (`sys/sdt.h` `STAP_PROBE`), Linux
  `user_events`. The probe is a single `nop` instruction plus an
  ELF note; when no consumer is attached the cost is one skipped
  instruction. When a consumer attaches (perf, eBPF, DTrace,
  LTTng), the `nop` is patched to a tracepoint.

Both are valid; conflating them hides the cost. For systems where
*on-host attachment matters more than self-contained capture* (a
running production service, an embedded device with a remote
debugger), USDT is the right primitive. For self-contained capture
(a game engine shipping a profiler with the binary), true elision
is right.

### 4.4 Counters as their own channel (fold into TLM.2)

Counters (monotonic or gauge) are not events. The right shape is
"record the value, the analyzer interpolates", not "emit an event
with a value." Unreal Trace `TRACE_COUNTER_*`, Tracy `TracyPlot`,
Perfetto counter tracks, Chrome Trace Event `C` phase, Intel ITT
`__itt_counter`. This is one of the named channels under TLM.2,
not its own guideline.

### 4.5 Memory and locks as their own channels (fold into TLM.2)

Allocation tracking (Tracy `TracyAlloc`/`TracyFree`, Unreal
`MemAlloc`/`MemTag` channels, Heaptrack, jemalloc profiling) and
lock contention tracking (Tracy `TracyLockable`, Linux `perf
lock`, Intel VTune locks-and-waits) are documented as separate
channels with documented overhead. They are concrete cases of
TLM.2 (channelize), worth as sections under TLM.2 with worked
examples — not their own guidelines unless the corpus chooses to
expand.

## 5. Tier-3 — not worth their own guideline

- **Frame markers as the unit of analysis.** Every profiler has
  one (Tracy `FrameMark`, Unreal `Frame` channel, Optick
  `OPTICK_FRAME`, ITT `__itt_frame_*`), and for frame-less
  systems (servers, inference, embedded control loops) the
  boundary has to be invented. This is real, but it lives
  inside TLM.2 as one of the named channels.
- **Sampling profilers as complementary to instrumented
  telemetry.** Real and important methodology — `perf record`,
  Instruments Time Profiler, VTune sampling — but the corpus is
  technique-focused, and the methodology point is best made in
  TLM.6's body ("a benchmark can still be sampled externally
  because sampling is approximately non-invasive; instrumented
  telemetry cannot be added without perturbing the run").
- **GPU/CPU timestamp correlation.** D3D12
  `GetClockCalibration`, Vulkan `VK_EXT_calibrated_timestamps`,
  Metal counters, the calibration-drift problem. Relevant for
  game engines and inference workloads with accelerator time
  (the seed material's workload class); deferred to a separate
  decision because adding it forces a TLM.11 and conflicts
  with the corpus's 8–10 per-category rhythm. Worth flagging
  to the maintainer as the most defensible eleventh candidate.
- **Build flags vs sampling-profiler stack attribution.**
  `-fno-omit-frame-pointer`, `--call-graph dwarf` vs `lbr` vs
  `fp` — real, but more codegen than telemetry, and overlaps
  with `GEN.*`.
- **OpenTelemetry C++ on the hot path.** OT's span/metric/log
  SDK is not appropriate for nanosecond-per-zone hot paths.
  Worth one sentence in TLM.4 ("if the sink is a span-based
  SDK, the runtime must absorb its cost; do not put SDK calls
  in the decode loop"); not a guideline.

## 6. Proposed slate — 10 guidelines

| ID | Title |
|---|---|
| TLM.1 | Compile telemetry out by default — release/shipping carries zero instrumentation cost (with sections on true elision vs USDT NOP-when-disabled) |
| TLM.2 | Channelize — CPU timing, counters, memory, locks, frames, bookmarks, and payloads are separate channels with separate costs |
| TLM.3 | Static names and interned strings on hot paths — names are sent to the sink once, not per-event |
| TLM.4 | Front-door the sink behind a macro layer — runtime names the phase, not the sink (with a section on thread naming) |
| TLM.5 | Structured events with a schema, not stderr text — hot path writes records; analyzer formats (with a section on schema-as-ABI) |
| TLM.6 | Diagnostic mode is not benchmark mode — telemetry-enabled runs carry observer-effect labels and cannot be quoted as clean throughput |
| TLM.7 | Sparse bookmarks for state changes — bookmarks are for transitions, not per-iteration progress |
| TLM.8 | Validate clean builds by artifact scan — `strings`, `nm -C` prove diagnostic symbols, env names, and trace sinks are absent |
| **TLM.9** | **Pick the timestamp source explicitly and fence it — `rdtsc` is not serialising; document the clock and verify Invariant TSC at startup** |
| **TLM.10** | **Per-thread lock-free emit with a lossy ring buffer — never contend, never block the work loop** |

TLM.1–TLM.8 from the draft slate, with Tier-2 candidates folded as
sections inside them. TLM.9 and TLM.10 are the genuinely missing
principles surfaced by the deep dive.

## 7. Open question for the maintainer

The strongest candidate for an eleventh guideline is **GPU /
accelerator timestamp correlation** — Vulkan
`VK_EXT_calibrated_timestamps`, D3D12 `GetClockCalibration`, Metal
counters. Relevant for game engines and inference workloads with
heterogeneous time. The case for keeping it is that the seed
material's workload (an MLX-based ML inference engine on Apple
Silicon) operates exactly in that regime; the case against is
the per-category rhythm of 8–10 guidelines. Decision deferred
to the maintainer.

The runner-up candidate is **sampling vs instrumented profilers as
complementary methodology**. The case for keeping it is that the
corpus already includes methodology principles (`SIMD.4` — read
the missed-vectorization report — is methodology); the case against
is that the technique itself ("use both") is thin and best made as
a paragraph inside TLM.6.

## 8. Sources

### Engine and profiler documentation (citable)

- Unreal Engine, *Stats System Overview* —
  <https://dev.epicgames.com/documentation/unreal-engine/unreal-engine-stats-system-overview>
- Unreal Engine, *Developer Guide to Tracing in Unreal Engine* —
  <https://dev.epicgames.com/documentation/unreal-engine/developer-guide-to-tracing-in-unreal-engine>
- Unreal Engine, *Unreal Insights Reference* —
  <https://dev.epicgames.com/documentation/unreal-engine/unreal-insights-reference-in-unreal-engine-5>
- Unreal Engine, *CSV Profiler* —
  <https://dev.epicgames.com/documentation/en-us/unreal-engine/csv-profiler>
- Unity, *Profiling Core API — `ProfilerMarker`* —
  <https://docs.unity3d.com/Packages/com.unity.profiling.core@1.0/manual/profilermarker-guide.html>
- Godot, *Custom Performance Monitors* —
  <https://docs.godotengine.org/en/stable/tutorials/scripting/debug/custom_performance_monitors.html>
- Tracy Profiler — <https://github.com/wolfpld/tracy>
- Tracy manual — <https://github.com/wolfpld/tracy/blob/master/manual/tracy.tex>
- Optick Profiler — <https://github.com/bombomby/optick>
- Microprofile — <https://github.com/jonasmr/microprofile>
- Perfetto, *Track Events* — <https://perfetto.dev/docs/instrumentation/track-events>
- Intel ITT (Instrumentation and Tracing Technology) API —
  <https://github.com/intel/ittapi>
- Microsoft PIX for Windows —
  <https://devblogs.microsoft.com/pix/>

### Trace formats and OS-level tracing (citable)

- Chrome Trace Event Format specification —
  <https://docs.google.com/document/d/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/preview>
- LTTng / CTF (Common Trace Format) — <https://lttng.org/docs/>
- Linux `user_events` — <https://docs.kernel.org/trace/user_events.html>
- Linux `perf_event_open(2)` and `perf record` —
  <https://man7.org/linux/man-pages/man2/perf_event_open.2.html>
- ETW (Event Tracing for Windows) reference — Microsoft Learn.

### Timestamp source discipline (citable)

- Intel SDM Vol 2 (`RDTSC`, `RDTSCP`), Vol 3A §17.17 ("Invariant
  TSC") — <https://www.intel.com/sdm>
- Andrey Akinshin, *Time Stamp Counter (TSC)* —
  <https://aakinshin.net/vignettes/tsc/>
- *A Systems Engineer's Guide to Benchmarking with RDTSC* —
  <https://blog.codingconfessions.com/p/rdtsc>

### GPU / heterogeneous time correlation (citable)

- Microsoft, *DirectX 12 Timing* —
  <https://learn.microsoft.com/en-us/windows/win32/direct3d12/timing>
- Khronos Vulkan registry (`VK_EXT_calibrated_timestamps`) —
  <https://registry.khronos.org/vulkan/>

### Profiling methodology (citable)

- Brendan Gregg, *perf Examples* —
  <https://www.brendangregg.com/perf.html>

### Seed material (cite-by-reference, internal to Plainsight Systems)

- Plainsight Systems internal engineering records from the
  **Vigil** ML inference engine project: (a) a cross-engine
  profiling-patterns research note, and (b) an observability-
  boundary decision. Both are Plainsight-private and not
  publicly available; cited for technique provenance, not
  reproduced.

### Books (cite-by-reference)

- Jason Gregory, *Game Engine Architecture* (profiler chapter).
- *Real-Time Rendering* (debug & profiling sections).

---

This note grounds the slate. The next step is the first authoring
pass (TLM.1–TLM.5), then the second (TLM.6–TLM.10).
