+++
id = "WASM.7"
title = "Budget startup: instantiate by streaming, keep the code cache, and measure past tier-up"
category = "wasm"
status = "draft"
summary = "Download and compilation are on the critical path; streaming instantiation overlaps them, the code cache has strict preconditions, and early iterations run baseline-tier code."
tags = ["startup", "instantiate-streaming", "code-caching", "liftoff", "turbofan"]
+++

## Rationale

A native binary is already on disk. A WebAssembly module is downloaded and
compiled every time a user opens the page, so both are on the critical path to
first frame.

`WebAssembly.instantiateStreaming` compiles as the bytes arrive, overlapping
compilation with download instead of serialising them. Figma's migration from
asm.js to WebAssembly cut load time roughly **3×**, from about 12 s to under
4 s on large documents, attributed to the compactness of the binary format,
parsing that is around 20× faster, and compiled code the browser can cache.

That cache has preconditions, and they are easy to break. V8 applies it **only**
to the streaming APIs and **only** from the second load onward; the module must
also clear a size threshold, published as 128 kB in V8's 2019 write-up. Treat
the specific number as a dated implementation note rather than a platform
contract — it is not specified anywhere, and no engine guarantees it. The cache
is invalidated by a changed module, by a V8 update (roughly every six weeks on
Chrome's release cadence), and by a changed URL. Query parameters are part of
the URL, so a *cache-busting* query string discards the entry on every deploy —
but a stable URL caches perfectly well whether or not it carries a query.

Compilation is also tiered, and it is **lazy**: V8's own documentation states
that functions are compiled with Liftoff when first called, not eagerly across
the module, and that functions crossing a call-count threshold are recompiled by
TurboFan on a background thread. Early iterations therefore measure baseline
code, not the code that will run in steady state. (Checked 2026-09-05.)

## Guidance

- **Instantiate by streaming, and serve `Content-Type: application/wasm`.** The
  native API requires that MIME type and **rejects the promise** without it — it
  does not quietly fall back. A generated loader may catch the rejection and
  retry non-streaming; that is the loader's behavior, not the platform's, so
  know which one you are relying on.
- **Preload the module** with `<link rel="preload" as="fetch" crossorigin>` so
  the fetch starts before the script that needs it is parsed.
- **Serve modules from immutable, stable URLs.** A URL that changes every deploy
  discards its cache entry; one that does not, keeps it. Path versioning
  (`app.v7.wasm`) achieves that naturally, but a stable query string is not
  itself a problem — churn is.
- **Consider a service worker for the second-load path.** Photoshop reports a
  **75%** reduction in code initialization time by precaching JS and WASM with
  Workbox alongside V8's own caching.
- **Compile once and share.** `postMessage` a `WebAssembly.Module` to workers
  rather than compiling per worker.
- **Discard warm-up explicitly in any benchmark.** Report the discarded count.
  An unqualified "first 100 iterations" figure is a Liftoff measurement.
- **Do not assume V8's tiering shape elsewhere** — see `WASM.14`.

## Example

```cpp
// C++ side: separate "module is instantiated" from "application is ready".
// Conflating them makes startup unmeasurable, because the expensive part
// (first-touch of large structures, shader compilation, tier-up) happens after
// instantiation and before anything useful renders.
enum class StartupPhase {
    Instantiated,     // wasm module exists; nothing initialised
    ResourcesReady,   // assets decoded, GPU objects created
    FirstFrame,       // something is on screen
    SteadyState,      // hot functions have tiered up
};

// Publish the transitions so the page can report them and a test can assert
// them. A single "load time" number hides which phase regressed.
class StartupTimeline {
public:
    void mark(StartupPhase phase, double now_ms) noexcept {
        marks_[static_cast<std::size_t>(phase)] = now_ms;
    }

    [[nodiscard]] double elapsed_ms(StartupPhase from, StartupPhase to) const noexcept {
        return marks_[static_cast<std::size_t>(to)]
             - marks_[static_cast<std::size_t>(from)];
    }

private:
    std::array<double, 4> marks_{};
};

// Benchmarks must discard warm-up and say so. This reports the discarded count
// alongside the result, so a reader can tell a steady-state number from a
// baseline-tier one.
struct BenchResult {
    std::size_t warmup_iterations;   // discarded; not optional, not implicit
    std::size_t measured_iterations;
    double median_ms;
    double p95_ms;
};

template <typename Fn>
BenchResult measure(Fn&& fn, std::size_t warmup, std::size_t iterations) {
    // Warm-up exists to let the optimising tier replace baseline code. Its size
    // is a property of the engine, not a constant -- see the caveats.
    for (std::size_t i = 0; i != warmup; ++i) {
        fn();
    }

    std::vector<double> samples;
    samples.reserve(iterations);
    for (std::size_t i = 0; i != iterations; ++i) {
        const double start = clock_ms();     // injected; see WASM.12
        fn();
        samples.push_back(clock_ms() - start);
    }

    // Precondition, not an assumption: indexing an empty vector is undefined
    // (SL.con.3), and a zero-iteration benchmark has no result to report.
    if (samples.empty()) {
        return BenchResult{warmup, 0, 0.0, 0.0};
    }

    std::sort(samples.begin(), samples.end());
    const std::size_t p95_index =
        std::min(samples.size() - 1,
                 static_cast<std::size_t>(samples.size() * 0.95));
    return BenchResult{
        warmup, iterations,
        samples[samples.size() / 2],
        samples[p95_index],
    };
}

// The loading contract, stated for the JS side. Getting any of these wrong
// silently costs a full recompile on every visit:
//
//   <link rel="preload" as="fetch" href="app.v7.wasm" crossorigin>
//   ...
//   // Streaming: required for code caching at all.
//   const { instance } = await WebAssembly.instantiateStreaming(
//       fetch('app.v7.wasm'),        // path-versioned, NOT '?v=7'
//       imports);                    // server must send application/wasm
```

## Caveats

- **Code caching is engine-specific and unspecified.** The size threshold and
  second-load behaviour are V8's, published in 2019. Other engines cache on
  different terms. Nothing here is a platform contract, so measure your own
  cold- and warm-load costs rather than designing to a number.
- **Cache invalidation on browser update is unavoidable.** A user on a
  six-weekly Chrome cadence pays a cold compile periodically no matter what you
  do; budget for the cold path, do not assume the warm one.
- **Warm-up length is not portable.** Tuning the iteration count against V8's
  curve does not make it correct on JavaScriptCore, which has three tiers rather
  than two.
- **Do not inflate a module to chase a cache threshold.** A larger module costs
  every first-time visitor more download and compile time, to chase a number no
  engine guarantees. If repeat-visit cost matters that much, measure it.
- **The wrong MIME type is a failure, not a slowdown.** Serving
  `application/octet-stream` rejects the streaming call. If your page appears to
  work anyway, a loader is catching that rejection for you.
- **Startup measured on a fast connection is not startup.** Download dominates
  on real networks; measure with throttling.

## References

- [V8 — Code caching for WebAssembly developers](https://v8.dev/blog/wasm-code-caching)
- [V8 — WebAssembly compilation pipeline](https://v8.dev/docs/wasm-compilation-pipeline)
- [V8 — Liftoff: a new baseline compiler for WebAssembly](https://v8.dev/blog/liftoff)
- [MDN — WebAssembly.instantiateStreaming()](https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/JavaScript_interface/instantiateStreaming_static)
- [web.dev — Loading WebAssembly modules efficiently](https://web.dev/articles/loading-wasm)
- [E. Wallace — WebAssembly cut Figma's load time by 3x](https://madebyevan.com/figma/webassembly-cut-figmas-load-time-by-3x/)
- Cross-reference: `WASM.8` (module size), `WASM.11` (measurement conditions),
  `WASM.13` (variants are separate cache entries), `TLM.9` (timestamp source).
