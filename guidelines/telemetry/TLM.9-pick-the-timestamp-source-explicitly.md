+++
id = "TLM.9"
title = "Pick the timestamp source explicitly and fence it — `rdtsc` is not serialising; document the clock and verify Invariant TSC"
category = "telemetry"
status = "draft"
summary = "The timestamp is the unit of the whole harness. `rdtsc` reorders around the work; `rdtscp` and `lfence;rdtsc` serialise; Invariant TSC must be verified. Pick deliberately."
tags = ["rdtsc", "rdtscp", "lfence", "invariant-tsc", "clock-monotonic", "tracy", "timer"]
+++

## Rationale

Every telemetry event has a timestamp. Two questions follow:
*how* is it read, and *what does it mean*. Both have known
right answers; both have known wrong answers; the corpus has
been silent on them until now.

### The reordering problem

`rdtsc` on x86 is not a serialising instruction. The CPU is
free to schedule it before or after surrounding instructions
based on its own dispatch policy. In a sequence like:

```cpp
auto t0 = rdtsc();
do_work();
auto t1 = rdtsc();
```

the compiler-emitted assembly contains *no fence* between
`rdtsc` and the work. The hardware can issue the second
`rdtsc` while parts of `do_work` are still in flight, or
issue the first `rdtsc` after preceding loads have already
been re-ordered past it. The measured `t1 - t0` can be off
by tens to hundreds of cycles in either direction.

The mitigations are well-documented:

- **`rdtscp`** — `RDTSCP` reads the TSC *after* serialising
  with respect to prior instructions (but not with respect
  to later ones). One-instruction cost. The "right enough
  for most purposes" choice.
- **`lfence; rdtsc`** — explicit serialisation before the
  read; pairs cleanly with `rdtsc; lfence` after, for full
  two-sided fencing. Two-instruction sequence; the
  canonical "I really mean this" pattern from
  microbenchmark literature (Akinshin, Intel SDM Vol 2).
- **`mfence; lfence; rdtsc; lfence`** — full barrier both
  sides; rare outside harness internals and explicitly
  documented as the "no surprises" form.

On ARM, the equivalent is the generic timer register
(`CNTVCT_EL0` on AArch64), which is read by a coprocessor
register access; serialisation requirements differ from x86
and the ARM Architecture Reference Manual is the source.

### The "is this a clock?" problem

`rdtsc` reads a *counter*, not a *clock*. Three properties
the counter must have for telemetry use:

1. **Invariant TSC.** The counter rate is independent of
   CPU frequency. Pre-Sandy-Bridge Intel CPUs without this
   property changed TSC rate with frequency scaling,
   making the counter unusable as a wall clock. Modern x86
   guarantees Invariant TSC on most SKUs (verifiable via
   `CPUID.80000007H:EDX[8]`); ARM generic timer is always
   invariant by spec.
2. **Synchronised across cores.** The TSC must read the
   same value (within bounded skew) from any core in the
   socket. Cross-socket synchronisation is not guaranteed
   on multi-socket x86; thread migration across sockets
   during a measurement is a bug source.
3. **Constant rate.** The counter ticks at a known
   frequency (typically the nominal CPU clock; `CPUID.15H`
   on Intel). Without the frequency, ticks cannot be
   converted to time.

The right discipline: **verify these properties at
startup**, and fall back to `clock_gettime` if any check
fails.

### The portable alternative

`std::chrono::steady_clock` and its platform underpinnings
are the portable choice:

- Linux: `clock_gettime(CLOCK_MONOTONIC)` (or
  `CLOCK_MONOTONIC_RAW` to avoid NTP adjustment). Typical
  cost: one vDSO call, ~15–30 ns on modern x86.
- macOS: `mach_absolute_time()` + `mach_timebase_info()`.
- Windows: `QueryPerformanceCounter` /
  `QueryPerformanceFrequency`.

These are slower than fenced `rdtsc` (by an order of
magnitude) but solve all three "is this a clock" problems
internally.

Tracy's design is instructive: x86 Sandy Bridge and later
use fenced `rdtsc`; AArch64 uses the generic timer; the
`TRACY_TIMER_FALLBACK` and `TRACY_TIMER_QPC` knobs let the
user override per-platform when the default is wrong (VM
guests, exotic CPUs, NTP-sensitive captures).

### The format question

Once a timestamp is captured, store it as **integer
nanoseconds (or ticks) since a fixed epoch**, not
floating-point seconds. `double` runs out of nanosecond
precision around 100 days from epoch; `int64_t`
nanoseconds covers 292 years. The schema cost is the same
(8 bytes); the precision cost is the difference between a
trace that survives and one that does not.

## Guidance

- **Pick the timestamp source explicitly per platform.**
  Document it in the harness header. On x86, default to
  fenced `rdtsc` (or `rdtscp`); on AArch64, default to the
  generic timer register; everywhere else, `clock_gettime
  (CLOCK_MONOTONIC)` or `mach_absolute_time()`.
- **Use `rdtscp` or `lfence; rdtsc` for serialised
  reads.** A bare `rdtsc` in a telemetry harness is a bug.
  The exception is reading the counter in a context where
  ordering with the surrounding work does not matter — a
  rare case worth commenting.
- **Verify Invariant TSC and cross-core synchronisation
  at startup.** `CPUID.80000007H:EDX[8]` for Invariant
  TSC; a startup self-test that reads the counter on
  multiple cores and checks the skew. Refuse to use
  `rdtsc` if either check fails; fall back to
  `clock_gettime`.
- **Convert from ticks to nanoseconds once, at capture
  time.** Don't make every analyzer carry the frequency
  table. The on-wire format is integer nanoseconds.
- **Use `int64_t` nanoseconds**, not `double` seconds, in
  the schema. Precision is permanent.
- **Pin threads when timing matters.** A thread migrating
  across sockets during a measurement can cross TSC
  domains. `pthread_setaffinity_np` /
  `SetThreadAffinityMask` for benchmark harnesses; the
  same is rarely needed in production telemetry.
- **For cross-thread or cross-process correlation, share
  the clock origin.** All threads in a process can use
  the same `monotonic_ns()` function; cross-process
  needs an external sync point (a shared file, a
  `CLOCK_MONOTONIC` reading captured by both at handshake
  time).
- **Cross-reference `TLM.11`.** GPU/accelerator timestamps
  do not share the CPU TSC and need their own calibration.

## Example

```cpp
// Good: explicit, fenced, per-platform timestamp source.
// The header chooses; the call site is a single function.
#include <cstdint>

#if defined(__x86_64__) || defined(_M_X64)
    #include <x86intrin.h>
    static inline std::uint64_t read_tsc_fenced() noexcept {
        // lfence; rdtsc — canonical fenced read.
        _mm_lfence();
        return __rdtsc();
    }
#elif defined(__aarch64__)
    static inline std::uint64_t read_tsc_fenced() noexcept {
        std::uint64_t val;
        __asm__ volatile ("mrs %0, cntvct_el0" : "=r"(val));
        return val;
    }
#else
    #error "timestamp source not defined for this platform"
#endif

// Startup verification — refuse to use TSC if invariant or
// cross-core checks fail.
struct TimerCalibration {
    bool   invariant_tsc;     // CPUID.80000007H:EDX[8] on x86
    double ticks_per_ns;      // CPUID.15H frequency / 1e9
    bool   cross_core_ok;     // measured skew below threshold
};

TimerCalibration calibrate_timer() noexcept;

// Per-event: read fenced TSC, convert to nanoseconds at capture.
struct Event {
    std::int64_t  timestamp_ns;   // monotonic ns, not float seconds
    std::uint16_t name_handle;
    std::uint8_t  kind;
};

void emit_event(std::uint16_t handle, std::uint8_t kind) noexcept {
    const auto tsc = read_tsc_fenced();
    const auto ns = static_cast<std::int64_t>(tsc * inv_ticks_per_ns_);
    write_to_ring(Event{.timestamp_ns = ns, .name_handle = handle,
                        .kind = kind});
}

// Bad: bare rdtsc with no fence. The compiler-emitted asm
// has no barrier; the CPU can reorder. The measured
// duration is unreliable.
void emit_event_bad() noexcept {
    const auto tsc = __rdtsc();     // not fenced!
    write_to_ring_bad(tsc);
}

// Bad: floating-point seconds. Precision degrades over a
// long capture; arithmetic on `double seconds_t` introduces
// rounding the integer ns format does not.
struct EventBad {
    double seconds_since_epoch;     // lose ns precision over days
    char   name[64];                // no interning either
};
```

## Caveats

- **Virtualised TSC is its own discipline.** Inside a VM,
  `rdtsc` may be host-emulated, host-passthrough, or
  guest-only. Each has different cost and synchronisation
  characteristics. VM guests are the canonical case for
  `TRACY_TIMER_FALLBACK` to `clock_gettime`.
- **`clock_gettime(CLOCK_MONOTONIC)` is fast but not
  free.** ~15–30 ns on Linux x86 via vDSO. For events at
  microsecond cadence, this is negligible; for events at
  nanosecond cadence (Tracy zones), this is the
  bottleneck.
- **`CLOCK_MONOTONIC_RAW` is Linux-specific** and avoids
  NTP adjustment but is slower (no vDSO acceleration on
  older kernels).
- **Apple Silicon's timer is fast but coarse.**
  `mach_absolute_time()` ticks at 24 MHz on M-series
  silicon; the resolution is ~42 ns, not 1 ns. For most
  CPU zones this is fine; for very tight loops, the
  resolution sets the floor.
- **Windows `QueryPerformanceCounter` frequency is not
  always the TSC.** On modern Windows it usually is, but
  the documentation does not guarantee it. Use
  `QueryPerformanceFrequency` and treat ticks as
  ticks-per-second.
- **Frequency-scaling-free TSC does not mean
  drift-free.** Even Invariant TSC drifts over hours and
  days against UTC; for long captures, periodic
  re-sync against `CLOCK_REALTIME` may matter.
- **The fences cost cycles.** `lfence; rdtsc; lfence` is
  ~50 cycles minimum on most cores. For very-high-rate
  emit, the unfenced shape is faster — at the cost of
  measurement precision. Choose deliberately.

## References

- Intel, *Software Developer's Manual Vol 2*, `RDTSC`
  and `RDTSCP` semantics —
  <https://www.intel.com/sdm>
- Intel, *Software Developer's Manual Vol 3A*, §17.17
  ("Invariant TSC").
- Andrey Akinshin, *Time Stamp Counter (TSC)* —
  <https://aakinshin.net/vignettes/tsc/>
- *A Systems Engineer's Guide to Benchmarking with
  RDTSC* —
  <https://blog.codingconfessions.com/p/rdtsc>
- ARM, *ARM Architecture Reference Manual* — generic
  timer (`CNTVCT_EL0`) semantics.
- Tracy Profiler manual — per-platform timer source,
  `TRACY_TIMER_FALLBACK` / `TRACY_TIMER_QPC` —
  <https://github.com/wolfpld/tracy/blob/master/manual/tracy.tex>
- Linux man pages, `clock_gettime(2)` —
  `CLOCK_MONOTONIC` / `CLOCK_MONOTONIC_RAW` semantics.
- Apple Developer, `mach_absolute_time` documentation.
- Microsoft Learn, *QueryPerformanceCounter* —
  <https://learn.microsoft.com/en-us/windows/win32/api/profileapi/nf-profileapi-queryperformancecounter>
- Cross-reference: `TLM.5` (the schema carries integer
  ticks/ns, not floating-point seconds), `TLM.10` (the
  emit path uses the fenced read), `TLM.11` (GPU
  timestamps are not TSC and need calibration),
  `CONC.7` (memory ordering — fences here are about
  *measurement* ordering, but the same `lfence` /
  `mfence` semantics apply).
