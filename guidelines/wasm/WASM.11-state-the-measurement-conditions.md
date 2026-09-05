+++
id = "WASM.11"
title = "State the measurement conditions or the browser number means nothing"
category = "wasm"
status = "draft"
summary = "The browser clock is clamped to 100 microseconds unless cross-origin isolated, opening DevTools de-optimizes the code being measured, and early iterations run baseline-tier output."
tags = ["measurement", "performance-now", "timer-clamp", "devtools", "tiering"]
+++

## Rationale

Three independent effects make a naive browser timing figure wrong, and all
three produce numbers that look plausible.

**The clock is clamped.** In **Chrome**, `performance.now()` resolves to
**100 µs** in a non-isolated context and **5 µs** in a cross-origin isolated
one; the clamp is a Spectre mitigation applied since version 91. Other engines
clamp too, but not necessarily to those values — treat these as Chrome's
documented figures rather than the web's, and record the resolution you actually
observed. A page measuring
operations that take tens of microseconds is reading quantization noise, and the
tell is that every reported figure is an exact multiple of the quantum.

**Opening the debugger changes the program.** Chrome's DevTools documentation
states that with DevTools open the code Chrome runs "isn't optimized. It's
tiered down to give you better debugging experience," and that `console.time()`
and `performance.now()` therefore cannot be relied on for profiling in that
state.

**The compiler tiers underneath you.** V8 runs Liftoff output first — roughly
1.5× slower to execute than TurboFan — and replaces hot functions in the
background. A benchmark that reports its first iterations is reporting the
baseline tier.

None of these are exotic conditions. They are the default state of a browser
tab, which is why the conditions have to be reported alongside the number rather
than assumed.

## Guidance

- **Report the clock resolution with every browser-side timing.** A median of
  0.5 ms from a 100 µs clock carries five significant steps, not five digits.
- **Check `crossOriginIsolated` at runtime and record it.** Do not infer the
  clock from the deployment you think you are on.
- **Aggregate when the per-item cost approaches the quantum.** Time 1,000
  iterations and divide; do not time one and quote it.
- **Measure with DevTools closed.** Run the benchmark, then open DevTools to
  read the results, or use the Performance panel, which accounts for itself.
- **Discard and report warm-up.** State how many iterations were dropped; an
  undisclosed warm-up is an unreproducible measurement.
- **Distinguish overhead floors from workload costs.** A round trip measured
  against a trivial dispatch establishes the floor. The ratio against that
  trivial dispatch is not a speedup figure and should not be quoted as one.
- **Prefer absolute costs to ratios when reporting.** An absolute overhead
  transfers to other workloads; a ratio against an empty kernel does not.
- **Take fine-grained answers from a native build** — see `WASM.12`.

## Example

```cpp
// A result type that cannot be reported without its conditions. If the fields
// are mandatory, the caller cannot quote a bare number by accident.
struct BrowserMeasurement {
    double median_ms;
    double p95_ms;
    std::size_t iterations;
    std::size_t warmup_discarded;

    // Conditions. Every one of these changes what the number means.
    double clock_resolution_us;      // measured, not assumed from a blog post
    bool cross_origin_isolated;      // read at runtime, never assumed
    bool devtools_open;              // if true, the figure is not quotable
    const char* engine;              // "V8 12.x"; tiering differs by engine
};

// The quantization check. If every sample is a multiple of the clock's
// resolution, the distribution is the clock's, not the workload's -- and the
// spread between min and p95 is not information.
[[nodiscard]] inline bool samples_are_clock_limited(
        std::span<const double> samples_ms, double resolution_us) noexcept {
    const double quantum_ms = resolution_us / 1000.0;
    for (const double s : samples_ms) {
        const double steps = s / quantum_ms;
        if (std::abs(steps - std::round(steps)) > 1e-6) {
            return false;            // at least one sample lies off the grid
        }
    }
    return true;                     // every sample is an exact multiple
}

// Aggregate rather than timing individual items when the item is small. One
// timed call around N iterations costs one clock read; N timed calls cost N
// clock reads, each quantized.
template <typename Fn>
[[nodiscard]] double mean_cost_ms(Fn&& fn, std::size_t iterations, Clock& clock) {
    if (iterations == 0) {
        return 0.0;                  // precondition: dividing by it below (I.5)
    }
    const double start = clock.now_ms();
    for (std::size_t i = 0; i != iterations; ++i) {
        fn();
    }
    // Divide after measuring, not before. Timing each call individually would
    // put a 100 us floor under an operation that may cost 2 us.
    return (clock.now_ms() - start) / static_cast<double>(iterations);
}

// Reporting discipline. The first form is a claim; the second is evidence.
//
//   BAD:  "the round trip costs 0.5 ms, and serialising is 10x slower"
//
//   GOOD: "0.5 ms median over 200 iterations, 20 discarded as warm-up.
//          Clock resolution 100 us (not cross-origin isolated), so the
//          median carries 5 steps of precision and the min/p95 spread is
//          partly quantization. The 10x figure is against a deliberately
//          empty dispatch and establishes an overhead floor; it is not a
//          speedup and does not transfer to real work."
```

## Caveats

- **Cross-origin isolation for the finer clock is a deployment change**, and it
  brings the embedding restrictions in `WASM.5`. A measurement rig can isolate
  even when the shipping page deliberately does not.
- **A 100 µs clock is adequate for frame-level work.** This is a rule about
  measuring sub-millisecond operations, not a reason to distrust frame timings.
- **The Performance panel is not free either**, but it accounts for its own
  overhead in a way `performance.now()` under an open DevTools does not.
- **Warm-up length is engine-specific.** A count tuned to V8's two-tier curve is
  not valid on JavaScriptCore, which has three tiers. Since V8 compiles lazily,
  the very first call to a function is also its compilation.
- **Background tabs are throttled** to roughly one update per second, so a
  measurement taken while the tab was hidden is meaningless.
- **Quantization detection has false positives** on genuinely coarse workloads
  whose costs happen to be near-multiples. Use it as a prompt to check, not as
  proof.

## References

- [MDN — Performance.now()](https://developer.mozilla.org/en-US/docs/Web/API/Performance/now)
- [Chrome for Developers — Aligning timers with cross-origin isolation restrictions](https://developer.chrome.com/blog/cross-origin-isolated-hr-timers)
- [Chrome DevTools — Debug C/C++ WebAssembly](https://developer.chrome.com/docs/devtools/wasm)
- [V8 — WebAssembly compilation pipeline](https://v8.dev/docs/wasm-compilation-pipeline)
- [W3C — High Resolution Time](https://www.w3.org/TR/hr-time-3/)
- Cross-reference: `TLM.9` (choosing a timestamp source), `TLM.6` (diagnostic mode is not
  benchmark mode), `WASM.5` (the headers that govern the clock), `WASM.12`
  (where to get a finer answer).
