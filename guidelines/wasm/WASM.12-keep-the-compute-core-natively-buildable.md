+++
id = "WASM.12"
title = "Keep the compute core natively buildable so it can be profiled properly"
category = "wasm"
status = "draft"
summary = "A browser tab is a poor laboratory — coarse clock, tiering, no hardware counters — so keep platform-neutral compute compiling for a native target with the clock and I/O injected."
tags = ["profiling", "platform-boundary", "testability", "native-build", "perf-counters"]
+++

## Rationale

This is a measurement argument before it is an architectural one.

`WASM.11` establishes that in-browser timing is coarse, tier-dependent, and
perturbed by the debugger. On top of that, browsers do not expose hardware
performance counters to page content, so the counter-level questions — is this
loop missing in L1i, is it spilling, is it mispredicting — cannot be asked from
inside a page at all.

The strongest evidence is the research literature itself. Jangda et al. could
not measure real applications in a browser with existing tooling; they built
Browsix-Wasm to run them and then read `perf` counters from outside. Their
finding that WebAssembly suffers 2.83× more L1 instruction-cache misses than
native in Chrome is not a number any application team will obtain from
`performance.now()`. Practitioner tooling has the same shape: machine-level
WebAssembly profiling is done today by driving V8's linux-perf integration from
outside the browser, precisely because DevTools cannot show the generated code
without changing it.

Engines already work this way for their own reasons — Unity, Unreal and Godot
each keep a portable core and treat web as a platform layer. That structure is
what makes a native profiling build possible at all.

## Guidance

- **Keep compute in translation units that compile for a native target.** If a
  kernel only exists in the browser build, it can only be measured badly.
- **Inject the clock.** A core that calls `emscripten_get_now()` directly cannot
  be timed natively, and cannot be given a deterministic clock in a test.
- **Inject I/O behind an interface.** Fetch, storage and canvas belong to the
  platform layer; the core should take bytes and return bytes.
- **Confine platform-specific code to an identifiable boundary** so the
  separation is checkable rather than aspirational.
- **Enforce the boundary in CI, not in review.** A grep for platform headers
  outside the platform layer is a control; a reviewer noticing a stray include is
  not.
- **Use the same source for both benchmarks.** One benchmark body, run natively
  for kernel cost and in the browser for end-to-end cost.
- **Let each build answer its own question.** Native measures the kernel;
  the browser measures delivery, boundary crossings, and what the user
  experiences. Neither substitutes for the other.
- **Prefer an API with a native implementation** where a choice exists, so the
  same code can run under a native harness.

## Example

```cpp
// core/clock.h -- the seam. The core depends on this interface, never on a
// platform clock. Natively this is backed by std::chrono; in the browser by
// emscripten_get_now(); in a test by a deterministic counter.
class Clock {
public:
    virtual ~Clock() = default;
    [[nodiscard]] virtual double now_ms() const noexcept = 0;
};

// core/shade.h -- platform-neutral. No emscripten.h, no EM_JS, no
// #ifdef __EMSCRIPTEN__. This compiles unchanged in both configurations,
// which is what makes it measurable under `perf`.
void shade_tile(std::span<Pixel> tile, const ShadeParams& params) noexcept;

// core/bench_shade.h -- one benchmark body, two hosts. Run natively it reports
// kernel cost against a real clock with counters available; run in the browser
// it reports what the page actually experiences.
struct ShadeBenchResult {
    double median_ms;
    std::size_t iterations;
};

[[nodiscard]] ShadeBenchResult bench_shade(const Clock& clock,
                                           std::span<Pixel> tile,
                                           const ShadeParams& params,
                                           std::size_t iterations);

// platform/wasm/bindings.cpp -- the ONLY translation unit that knows it is in a
// browser. Its job is translation, not behaviour: supply the clock, marshal the
// result, own nothing else.
//
//   #include <emscripten.h>
//   class BrowserClock final : public Clock {
//   public:
//       double now_ms() const noexcept override { return emscripten_get_now(); }
//   };
//
// platform/native/main.cpp -- supplies std::chrono and runs under perf:
//
//   $ perf stat -e L1-icache-load-misses,instructions ./bench_shade
//
// This is the measurement the browser cannot give you at all, and it is the
// one that answers "why is this slow" rather than "how slow is this".

// tools/check_boundaries.sh -- the control that keeps the property true.
// Review does not catch a stray include; a build step does.
//
//   #!/bin/sh
//   set -e
//   if grep -rlE '#include *<emscripten|EM_JS|EM_ASM|__EMSCRIPTEN__' src/core/; then
//       echo "platform dependency leaked into src/core/" >&2
//       exit 1
//   fi

// Guard the property in code as well, so the failure is a compile error rather
// than a CI message arriving after the design has drifted.
#if defined(__EMSCRIPTEN__) && defined(BUILDING_CORE)
#  error "src/core must not be compiled with browser-specific assumptions; \
          platform code belongs in platform/wasm"
#endif
```

## Caveats

- **Native measurement does not predict browser performance.** It answers
  different questions: relative kernel cost, cache behaviour, whether a change
  helped the algorithm. Absolute numbers do not transfer.
- **Some behaviour only exists in the browser** — boundary crossings, tiering,
  the graphics driver path. Those must be measured in the browser, coarsely, and
  that is the right tool for them.
- **The boundary has a cost.** Injecting a clock and an I/O interface adds
  indirection, which `WASM.4` warns about in hot paths. Inject at phase
  granularity, not per element.
- **A native build can diverge silently.** If it is not run in CI it will stop
  compiling, and the option evaporates exactly when it is needed.
- **Not every project can afford two build configurations.** For a small module
  the browser-only path may be right; the cost is that "why is this slow"
  becomes very hard to answer.
- **A native reference may need a real implementation of the platform API**,
  which can be substantial work in its own right.

## References

- [Jangda et al., *Not So Fast: Analyzing the Performance of WebAssembly vs. Native Code*, USENIX ATC 2019](https://www.usenix.org/conference/atc19/presentation/jangda)
- [Chrome DevTools — Debug C/C++ WebAssembly](https://developer.chrome.com/docs/devtools/wasm)
- [Leaning Technologies — Profiling web apps at the assembly level](https://labs.leaningtech.com/blog/beyond-devtools-profiling-webapps-at-the-assembly-level)
- [Unity — Web performance considerations](https://docs.unity3d.com/6000.4/Documentation/Manual/webgl-performance.html)
- Cross-reference: `WASM.11` (why the browser is a poor lab), `WASM.4`
  (indirection cost of the seam), `TLM.1` (compile-out-by-default
  instrumentation), `TLM.9` (timestamp source).
