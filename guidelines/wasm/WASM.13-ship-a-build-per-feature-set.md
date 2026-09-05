+++
id = "WASM.13"
title = "Ship a build per feature set and select at load; WASM cannot detect its own features"
category = "wasm"
status = "draft"
summary = "Every instruction in a module must be supported by the target, so a SIMD build fails to instantiate where SIMD is absent; detect from JavaScript and pick a variant before instantiating."
tags = ["feature-detection", "build-variants", "simd128", "portability", "instantiation"]
+++

## Rationale

WebAssembly has **no in-module feature detection**. Validation happens for the
whole module before any of it runs, and every instruction must be supported by
the engine. There is no way to write a runtime branch that uses SIMD when
available and scalar code otherwise, because the module containing the SIMD
instructions will not instantiate at all on an engine that lacks them.

This is unlike every native equivalent. A native binary can `cpuid` and dispatch
to an AVX-512 path or an SSE2 path at runtime from one image. On the web the
equivalent is to **compile a variant per feature set and choose between them in
JavaScript before instantiating**, which makes feature support a build-and-deploy
concern rather than a runtime branch.

The variants are not free. Each is a separate URL and therefore a separate code
cache entry (`WASM.7`), each doubles the build matrix, and each must be tested.
So the right number of variants is small and deliberate — usually two.

## Guidance

- **Detect before instantiating, from JavaScript.** `wasm-feature-detect` is the
  standard implementation; all detectors are asynchronous.
- **Keep the variant count small.** Two — a baseline and an enhanced build — is
  usually right. A matrix over four independent features is sixteen artifacts to
  build, host, cache and test.
- **Choose the axis that pays.** SIMD is usually the one worth a second build;
  threads change the architecture (`WASM.5`) rather than just the codegen.
- **Keep one source.** Guard with `__wasm_simd128__` and friends so both variants
  come from the same translation units, differing only in flags.
- **Make the baseline the default.** If detection fails or is inconclusive, load
  the variant that runs everywhere.
- **Version variants by path.** Each is its own cache entry; a query string
  discards the cache for all of them.
- **Test the baseline path deliberately.** It is the one nobody runs during
  development, and therefore the one that breaks.
- **Check current support rather than hardcoding a matrix.**
  `webassembly.org/features` is the status source; per-browser claims go stale
  quickly.

## Example

```cpp
// One source, two builds. The guard keeps both paths compiling from the same
// translation unit, so the scalar path cannot rot -- it is compiled every time
// the baseline variant is built.
void convolve(std::span<float> out, std::span<const float> in,
              std::span<const float> kernel) noexcept {
#ifdef __wasm_simd128__
    convolve_simd(out, in, kernel);
#else
    convolve_scalar(out, in, kernel);
#endif
}

// Both implementations must exist and both must be tested. A scalar path that
// is never exercised is a scalar path that does not work.
void convolve_simd(std::span<float> out, std::span<const float> in,
                   std::span<const float> kernel) noexcept;
void convolve_scalar(std::span<float> out, std::span<const float> in,
                     std::span<const float> kernel) noexcept;

// Expose which variant is running so it reaches diagnostics and bug reports.
// "Slow on my machine" is unactionable without knowing which module loaded.
extern "C" const char* build_variant() noexcept {
#ifdef __wasm_simd128__
    return "simd128";
#else
    return "baseline";
#endif
}

// Two link lines from one source tree. Path-versioned, so each keeps its own
// code cache entry:
//
//   emcc ... -o dist/app.baseline.v7.wasm
//   emcc ... -msimd128 -o dist/app.simd.v7.wasm
//
// Selection happens in JavaScript, before instantiation, because by the time
// C++ runs the decision has already been made:
//
//   import { simd } from './wasm-feature-detect.js';
//
//   // Default to the variant that runs everywhere. Only upgrade on a
//   // positive detection -- an inconclusive result must not select SIMD.
//   const url = (await simd())
//       ? './app.simd.v7.wasm'
//       : './app.baseline.v7.wasm';
//
//   const { instance } = await WebAssembly.instantiateStreaming(fetch(url), imports);
//
// Note what does NOT work, and fails at instantiation rather than at the call:
//
//   if (cpuSupportsSimd()) { useSimdFunction(); }   // in a SIMD-containing module
//
// The module never loads on an engine without SIMD, so the guard never runs.

// Assert that both variants stay in the build. A variant that stops being
// produced is discovered by a user on the platform you do not develop on.
struct BuildMatrix {
    const char* variant;          // "baseline", "simd128"
    const char* artifact_path;    // path-versioned, one cache entry each
    bool covered_by_tests;        // the baseline row is the one that lapses
};
```

## Caveats

- **Every variant multiplies cost.** Build time, hosting, cache entries, CI
  matrix and test surface all scale with the count. Two is a decision; eight is
  an accident.
- **The first visit pays detection latency.** Detection is asynchronous and
  precedes the fetch, so it sits on the critical path unless you speculatively
  preload the likely variant.
- **Baseline coverage decays.** Developers run the enhanced build; nothing
  exercises the scalar path unless CI does it explicitly.
- **Support levels move.** A feature that needed a variant last year may be
  universal now, and carrying a dead variant is pure cost. Re-check periodically.
- **Some features are not build-time axes at all.** Threads change the program's
  architecture, not just its instruction selection, so a "threaded variant" is a
  much larger commitment than a SIMD variant.
- **Detection libraries instantiate tiny probe modules.** That is cheap but not
  zero, and it happens before your module loads.

## References

- [web.dev — WebAssembly feature detection](https://web.dev/articles/webassembly-feature-detection)
- [GoogleChromeLabs — wasm-feature-detect](https://github.com/GoogleChromeLabs/wasm-feature-detect)
- [WebAssembly — Feature status](https://webassembly.org/features/)
- [Emscripten — Using SIMD with WebAssembly](https://emscripten.org/docs/porting/simd.html)
- Cross-reference: `WASM.6` (the SIMD build this variants over), `WASM.7`
  (each variant is a separate cache entry), `WASM.14` (which targets justify a
  variant), `SIMD.6` (runtime dispatch — the native equivalent that WASM lacks).
