# WebAssembly technique extraction

**Date:** 2026-09-05
**Packet:** `2026-09-05-wasm-category-buildout`
**Purpose:** Source survey and technique extraction for a `wasm` category
covering C++ compiled to WebAssembly, and the interop seams around it.

## Sourcing classification

Per `CONTRIBUTING.md`, sources are studied for technique and cited; no text or
code is copied.

| Class | Sources |
|---|---|
| Peer-reviewed measurement | Jangda et al., *Not So Fast* (USENIX ATC 2019); Szewczyk et al., *Leaps and Bounds* (IISWC 2022) |
| Game engines, shipped web targets | Unity (Web/WebGL manual, engine blog, Kongregate production write-ups), Godot (web export docs, 4.3 progress report), Unreal (Mozilla/Epic asm.js era; Wonder Interactive / SimplyStream WebGPU RHI) |
| Production application ports | Adobe Photoshop on the web (Chrome/Adobe collaboration), Figma (asm.js → WASM) |
| Toolchain documentation | Emscripten — settings reference, optimizing code, optimizing WebGL, SIMD, pthreads, Asyncify, runtime environment |
| Engine documentation | V8 — compilation pipeline, code caching, speculative optimizations; Chrome DevTools; Chrome for Developers |
| Standards / platform | WebAssembly spec and proposals (memory64, SIMD, relaxed SIMD, exception handling); W3C WebGPU; W3C High Resolution Time; MDN |
| Asset delivery | Khronos KTX2 / Binomial Basis Universal |

**Explicitly excluded as evidence.** In-house exploratory work is not a source
for this corpus. Internal harnesses are consumers of the guidelines, not
generators of them: their numbers are single-device, single-browser, and taken
under changing code. Where an internal project and an external source appeared
to agree, only the external source is cited below; where they disagreed, §11
records that the external source won.

**Why the historical sources matter.** The 2013–2017 asm.js/Emscripten push —
Mozilla and Epic shipping Unreal Engine 3 (Epic Citadel, GDC 2013) and then
Unreal Engine 4 in Firefox (2014), Unity's WebGL target, and the GDC talks
around them — is where the *engine-scale* technique set was worked out. Most of
that guidance survived the move from asm.js to WebAssembly intact, because the
binding constraints (one contiguous heap, a cooperative event loop, an FFI
transition on every graphics call, no threads without headers) are properties of
the browser rather than of the bytecode format. The parts that did *not* survive
are equally instructive and are flagged in §14.

## Why this is a category, not a footnote on `embedded`

WebAssembly resembles `embedded` — bounded memory, no ambient OS, pressure to
drop exceptions and RTTI — but differs on four axes that make existing guidance
actively mislead:

1. **The memory ceiling is an address space, not a budget.** wasm32 caps linear
   memory at 4 GiB because pointers are 32-bit, and the heap must be one
   *contiguous* allocation in the host process. `MEM.7`'s reserve-then-commit
   strategy is unavailable.
2. **A safety check sits on every indirect call and every function entry.**
   These are design constraints of the format, not toolchain immaturity, and
   they change which C++ constructs are cheap.
3. **Every I/O is a foreign-function transition into another language.** The
   cost model for a graphics call is not "a call".
4. **The measurement apparatus is itself constrained.** The clock is clamped for
   security, the compiler tiers underneath the running code, and opening the
   debugger changes what is being measured.

## Technique extraction

### 1. What "near-native" actually means, and for whom

The commonly repeated figure — WebAssembly within ~10% of native — comes from
small scientific kernels. Jangda et al. built Browsix-Wasm to run *unmodified
SPEC CPU* applications in the browser and measured:

| | Chrome | Firefox |
|---|---|---|
| Slowdown, geomean | **1.55×** | **1.45×** |
| Slowdown, median | 1.53× | 1.54× |
| Peak slowdown | **2.5×** | 2.08× |

Szewczyk et al. measured a different point on the same axis: **WAVM**, an
LLVM-based *ahead-of-time* runtime, at **8–20%** over native on x86-64 for
PolyBench/C and a SPEC CPU 2017 subset.

**Inference (high confidence):** the gap between "8–20%" and "45–55%" is largely
*browser JIT vs offline compiler*, not WebAssembly the format. A browser must
compile fast enough to run online; Clang can spend as long as it likes. Quoting
the AoT number as if it applied to a browser game is the most common error in
this space.

Both are dated (2019, 2022) and V8 has advanced since — speculative
`call_indirect` inlining plus deoptimization shipped in Chrome M137, and V8
inlines the JS-to-Wasm wrapper at the call site. Direction of travel is good;
the structural causes in §2 have not gone away.

### 2. The structural causes of the gap

Jangda et al. isolated the causes with hardware performance counters. Geomean
increase over native across SPEC CPU:

| Counter | Chrome | Firefox |
|---|---|---|
| loads retired | 2.02× | 1.92× |
| stores retired | 2.30× | 2.16× |
| branches retired | 1.75× | 1.65× |
| conditional branches | 1.65× | 1.62× |
| instructions retired | 1.80× | 1.75× |
| cpu cycles | 1.54× | 1.38× |
| **L1 i-cache load misses** | **2.83×** | **2.04×** |

Attributed causes, and the paper's own verdict on which are fundamental:

- **Reserved registers** *(fundamental)*. Chrome reserves `r13` (a pointer to
  the GC root array) plus `r10`/`xmm13` as scratch; Firefox reserves `r15` (heap
  base) plus `r11`/`xmm15`. None are available to WebAssembly code. Fewer
  registers → more spills → the ~2× load/store counts above.
- **A stack-overflow check on every function call** *(fundamental)*. Both
  engines compare a running stack-size global against a maximum at function
  entry — an extra compare and conditional jump per call.
- **A type check on every indirect call** *(fundamental)*. WebAssembly validates
  at runtime that an indirect call target is in the function table and that its
  type matches the call site. **In C++ this is every virtual call and every
  function pointer.**
- **Increased code size** *(consequence)*. The above plus poorer codegen inflates
  instruction count 1.75–1.80×, which shows up as 2–2.8× more L1 instruction
  cache misses. One benchmark (`458.sjeng`) hit 26.5× more i-cache misses in
  Chrome.
- **Poor register allocation and redundant loop branches** *(not fundamental)* —
  implementation quality, improvable and since improved.

**Extraction.** The corpus already tells readers to prefer flat, predictable
dispatch (`GEN`) and to respect the instruction cache (`CACHE`). Under WASM
those recommendations get materially stronger, for a *specific and citable*
reason: indirect dispatch carries a runtime type check that native code does not
pay, and code size converts to i-cache misses at a worse exchange rate. A deep
virtual hierarchy in a hot loop is a different proposition here.

Note the counter-example the paper found: `429.mcf` runs **faster** than native
in both browsers, because its hot loop fits in L1i. Instruction footprint is the
dominant term, not the check in isolation.

### 3. Bounds checking is a design axis, not a fixed tax

Szewczyk et al. implemented five bounds-checking modes across four runtimes
(WAVM, Wasmtime, Wasm3, V8) on three ISAs (x86-64, Armv8, RISC-V RV64GC):
`None`, `Clamp` (`addr = min(addr, MEMORY_END)`), `Trap` (explicit
compare-and-trap), `Mprotect` (guard pages plus signal handler), and
`UserfaultFD`.

Findings relevant here:

- On PolyBench/C kernels the **relative** cost of each mechanism is roughly the
  same across all three ISAs — this is not an x86 quirk.
- `mprotect()` on Linux **scales poorly with threads**; their `userfaultfd`
  approach mitigates it.
- The paper's abstract puts worst-case bounds-checking overhead at up to ~650%.

**Inference (moderate confidence):** a C++ developer targeting the browser does
not choose the mechanism — the engine does, and browsers rely on virtual-memory
guard regions rather than explicit checks for wasm32. The transferable lesson is
that *access pattern* interacts with the safety mechanism, so a workload that is
effectively bounds-check-free natively may not be. This is a caveat to attach to
`CACHE` and `SIMD` guidance rather than a standalone rule.

### 4. Linear memory is one contiguous block you should keep small

- wasm32 tops out at 65,536 pages × 64 KiB = **4 GiB**. Memory64 reached phase 4
  and shipped in Chrome and Firefox; browsers cap it far below the 64-bit range
  (~16 GiB reported), and engines lose optimizations that assume 32-bit
  pointers. It buys address space at a throughput cost.
- `WebAssembly.Memory.grow` **detaches the existing `ArrayBuffer`**. Every JS
  typed-array view over the heap is invalidated and must be recreated
  (Emscripten's `updateMemoryViews`), and the engine may copy the old contents.
  A long-lived JS reference into the heap is a use-after-detach.

**Unity's production position is the strongest evidence here**, because it is
advice given to thousands of shipped titles:

- The Unity heap is a single **contiguous** allocation. Automatic resizing "can
  cause your application to crash if the browser fails to allocate a contiguous
  memory block in the address space" — so Unity's guidance is to keep the heap
  **as small as possible**, which is the opposite of the native instinct.
- Growth is worse than it looks: a resize needs the old heap *and* the new heap
  live simultaneously, so the moment of growth is the moment of peak pressure.
  Fragmentation of the host address space can defeat an allocation even when
  total free memory is ample.
- Historically Unity capped the heap at **2032 MB**, because 2048 MB or more
  overflows the signed 32-bit size of the JS TypedArray backing it. Current
  Unity documents up to 4 GB via Maximum Memory Size. Both figures are worth
  recording: the first is the shape of the trap, the second is the current
  ceiling.
- Kongregate's production write-ups and Unity's own docs converge on the same
  counter-intuitive rule, and Unity has "never recommended" enabling
  `ALLOW_MEMORY_GROWTH`.
- Memory Unity needs *outside* the heap is easy to forget and is not visible to
  the engine profiler: the unpacked `.data` asset file, GC scratch, XHR download
  buffers spiking at roughly bundle size, WebAudio's uncompressed buffers, and
  the module code itself.

Unity also documents a WASM-specific garbage-collection constraint that has a
direct allocation consequence: the collector can only run when no managed code
is executing, and only at the end of a frame — so temporaries allocated inside a
loop accumulate for the whole frame rather than being reclaimed as they die.

### 5. The frame belongs to the event loop, and Asyncify costs ~50%

This is the most common porting failure for engine code, and it predates
WebAssembly — it was the asm.js-era problem too.

- The browser is cooperatively scheduled. A C++ `while (true) { frame(); }`
  never returns control, so the page hangs and nothing renders: WebGL only
  presents when control returns to the event loop.
- The structural fix is to invert the loop —
  `emscripten_set_main_loop()` / `emscripten_request_animation_frame_loop()`
  call one iteration per frame. Emscripten states these carry **no** size or
  speed overhead.
- The shortcut is **Asyncify**, which instruments code so a blocking call can
  unwind and rewind the stack. Emscripten's own documentation puts the cost at
  "**something like 50% or so**" in both code size and speed, and warns that
  unoptimized Asyncify builds are very large (`-O3` is close to mandatory).
- **JSPI** (`-sJSPI`, JavaScript Promise Integration) is the modern replacement:
  code size stays flat, but async boundaries must be declared explicitly via
  `JSPI_IMPORTS` / `JSPI_EXPORTS`, where Asyncify infers them.

**Extraction.** Restructuring the main loop is a one-time architectural cost;
Asyncify is a permanent ~50% tax paid to avoid it. That is a rare case where the
corpus can state a tradeoff numerically, from the toolchain's own documentation.

### 6. Every boundary crossing is an FFI transition — and graphics is all boundary

Per-call overhead into WASM has fallen (V8 inlines the JS-to-Wasm wrapper). What
has not fallen is the cost of *what crosses*, and — critically for engines —
**the graphics API is on the far side of the boundary**.

Emscripten's WebGL optimization guidance is explicit about the double cost:
every GL call pays (a) validation, because WebGL must enforce security
guarantees native OpenGL does not provide, and (b) an FFI transition between
WASM and the browser's native code. Concretely:

- Never call `glGetError()`, `glCheckFramebufferStatus()`, or `glGet*()` at
  render time. Cache uniform locations at startup.
- Never `glGen*`/`glCreate*`/`glDelete*` during rendering — deletion can force a
  pipeline flush. `glCompileShader`/`glLinkProgram` can be extremely slow.
- Batch uniform uploads (`glUniform4fv` over repeated `glUniform4f`); use UBOs
  and VAOs in WebGL 2; replace render-time `glReadPixels` with
  `GL_PIXEL_PACK_BUFFER`.
- Do not reset state to a known baseline after each draw; change lazily.
- Avoid the emulation layers: `-sFULL_ES2`/`-sFULL_ES3` (client-side memory) and
  `-sLEGACY_GL_EMULATION` are documented as slow. `-sMAX_WEBGL_VERSION=2` is
  cited at a 3–7% speed improvement.
- Double- or triple-buffer dynamic vertex data to avoid GPU stalls.

Unity's manual states the same conclusion from the engine side: GPU rendering is
close to native, but "the CPU side dispatch of WebGL operations is slower than
in native OpenGL", and the headline recommendation is to avoid large draw-call
counts and lean on instancing and batching.

`OFFSCREEN_FRAMEBUFFER` lets a pthread issue GL by proxying calls to the main
thread. Emscripten's own issue tracker records this as a performance footgun
when enabled by default.

**Extraction.** Draw-call count is a first-order cost in the browser in a way it
is not natively, for a reason that has nothing to do with the GPU. The same
logic generalizes: batch a phase into one crossing, pass `(pointer, length)`
into linear memory rather than structured objects, and keep hot loops entirely
inside the module. web.dev adds the module-level version: compile once on the
main thread and `postMessage` the `WebAssembly.Module` to workers rather than
recompiling per worker.

### 7. Threads are a deployment decision, and the cost is reach, not difficulty

WASM threads need `SharedArrayBuffer`, which needs cross-origin isolation:
`Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp`.

**Setting those headers is ordinary server configuration wherever you control
the server.** web.dev documents a complete, unremarkable migration path: enable
COOP first, audit cross-origin subresources and give them
`Cross-Origin-Resource-Policy` (or the `crossorigin` attribute where they are
CORS-enabled), roll out behind `Cross-Origin-Embedder-Policy-Report-Only` to
find breakage without causing it, then enforce. COEP `credentialless` (Chrome 96+,
Edge) relaxes the CORP requirement by stripping credentials from cross-origin
loads. None of this is exotic.

**The real cost is what isolation forbids, not what it takes to turn on.**
Cross-origin subresources that have not opted in stop loading. That is the
constraint that decides the question, and it is a product constraint:

- **Godot 4.3 made single-threaded the default** — and its stated reasoning is
  worth reading precisely. Cross-origin isolation removes "the capacity to make
  remote calls to other websites", which takes out game monetization and
  third-party API calls. Most web-game publishing platforms do not let
  developers set the headers; itch.io's `SharedArrayBuffer` support is
  described as experimental and depends on a feature not supported by Safari or
  Firefox for Android. Godot also found an unrelated benefit: long-standing
  macOS and iOS problems with their web exports disappeared under
  single-threaded export. The tradeoff was not free — single-threaded
  introduced audio glitching at both ends of the hardware range, which they
  fixed with sample-based playback.
- **Photoshop is the opposite decision.** Photoshop depends on multithreading,
  so Adobe and Chrome worked through the W3C to bring dynamic multithreading
  (and usable C++ exceptions) to WebAssembly rather than design around their
  absence. An application behind a login has no ad network to protect.

**Where headers genuinely cannot be set**, they are also honored when applied by
a service worker — the `coi-serviceworker` approach. Its constraints are
documented and real: it must be a separate file served from your own origin
(not a CDN), the page must be HTTPS or localhost, and the first load triggers a
reload once the worker installs. Some game portals expose an explicit
SharedArrayBuffer toggle instead.

Emscripten specifics that bite once threads are available: `Atomics.wait` cannot
block the main browser thread, so `pthread_join`/`pthread_cond_wait` there would
busy-wait or deadlock against a proxied call — `-sPROXY_TO_PTHREAD` moves
`main()` off it. `pthread_create` only takes effect after returning to the event
loop, which breaks POSIX expectations, so `-sPTHREAD_POOL_SIZE` pre-creates
workers. The default `dlmalloc` has a single global lock; `-sMALLOC=mimalloc`
gives thread-local contexts at a size and memory cost.

**Extraction.** Threading is decided by what the page must be able to embed and
who must be able to play it — reach and revenue — not by whether the headers are
achievable. State the decision and its reason; do not inherit either default by
accident. A thread-pool abstraction the deployment target will not run is a
§3.1 facade, and so is a single-threaded design justified by a header limitation
that was never actually tested.

Note also that the same headers govern timer resolution (§12) — one decision,
two consequences, documented in unrelated places.

### 8. SIMD pays well, is fixed at 128 bits, and has documented sharp edges

- `-msimd128` enables fixed-width 128-bit SIMD (`__wasm_simd128__`);
  `-mrelaxed-simd` enables relaxed SIMD (`__wasm_relaxed_simd__`). Fixed-width
  SIMD is broadly shipped; relaxed SIMD landed later and more unevenly. Specific
  version numbers are deliberately not recorded here — see §14: they go stale,
  and `webassembly.org/features` is the live source.
- **The payoff is real and large.** Photoshop on the web reports SIMD giving a
  **3–4× speedup on average, and 80–160× in some cases**, chiefly through their
  Halide image-processing kernels.
- **The width is fixed at 128 bits.** No AVX-512-style widening, no SVE-style
  scalable vectors. Much of `SIMD`'s ISA-targeting and predication guidance
  simply does not apply, and portable-abstraction libraries buy less.
- Emscripten documents instructions that lower badly. On x86 in V8: `i8x16`
  shifts (5–11 instructions — use `i16x8`), `i64x2.shr_s` (6–12), `i8x16.mul`
  and `i64x2.mul` (~10), `f32x4`/`f64x2` `min`/`max` (7–10, because WASM's NaN
  propagation does not match the hardware instruction — `pmin`/`pmax` lower
  cleanly), non-constant `i8x16.swizzle` (prefer `i8x16.shuffle`), and the
  saturating float→int conversions. On ARM, anything that is not a 128-bit "q"
  operation is scalarized.
- Relaxed SIMD trades **determinism** for speed: defined-but-varying results
  across engines for some float and integer operations. That is a direct
  conflict with the reproducibility requirement and must be an explicit,
  labelled decision, not a flag someone adds.
- Autovectorization can be disabled with `-fno-vectorize -fno-slp-vectorize`.
- Unity's guidance is consistent: enable the WebAssembly 2023 feature set for
  SIMD on newer browsers.

### 9. The module is a shipped artifact, and size is startup latency

- `WebAssembly.instantiateStreaming` compiles while downloading; also preload
  with `<link rel="preload">`.
- **V8's** code cache (Chrome/Edge; other engines cache differently) applies **only** to the streaming APIs, only to modules of
  **128 kB or more**, and only from the **second load**. It is invalidated by a
  changed `.wasm`, by a V8 update (~every six weeks), and by **any URL change
  including query parameters** — so cache-busting query strings defeat it
  outright.
- V8 tiers: **Liftoff** emits baseline code fast on first call, **TurboFan**
  recompiles hot functions in the background. Early loop iterations run baseline
  code. Observable in `chrome://tracing` under `v8.wasm` (`wasm.TopTierFinished`).
- **Figma** is the canonical load-time case study: moving the C++ engine from
  asm.js to WASM cut load time ~3×, from ~12 s to under 4 s on large documents —
  attributed to the compactness of the binary format, ~20× faster parsing, and
  cacheable compiled code.
- **Photoshop** reports a **75%** reduction in code initialization time by
  precaching JS and WASM with a service worker (Workbox) alongside V8's caching.
- Size levers: `-O3` vs `-Os`/`-Oz`; `-flto` on compile *and* link; `--closure 1`
  on the JS support code; `-sFILESYSTEM=0`; `-sENVIRONMENT=web,worker`;
  `-sINLINING_LIMIT`; `-sMALLOC=emmalloc` (smaller, slower).
- Exceptions/RTTI: `-fno-exceptions`/`-fno-rtti` where the code permits;
  otherwise `-fwasm-exceptions` uses native WASM EH (one-phase unwinding),
  smaller and faster than the legacy JS-based scheme. Unity's manual now says
  that with the WebAssembly 2023 feature set the overhead of exception support
  options is minor — a real change from the era when "Exception handling: None"
  was standard WebGL advice.

**Extraction.** `EMB` already covers exception and RTTI cost. The WASM-specific
part is that code size is **downloaded on the critical path and compiled on
arrival**, so size is a latency lever, not only a footprint one.

### 10. Assets should stay compressed all the way to their destination

- Unity: use asset bundles loaded and unloaded on demand; LZ4 or uncompressed,
  **not** LZMA on web (decompression stalls); Brotli at the server; a separate
  IndexedDB cache avoids keeping downloads resident. Split bundles so a download
  spike does not match the whole payload, but not so finely that request count
  dominates.
- KTX2 / Basis Universal: supercompressed textures transcode at load into the
  device's native GPU format (BC / ASTC / ETC2), staying compressed into VRAM —
  typically 4–8× less texture memory, with one interchange asset per texture
  instead of one per target format.
- Photoshop pages document data between disk and memory through **OPFS access
  handles**, which is the closest the web has to memory mapping.

**Extraction.** In a 32-bit address space with no memory mapping, "decompress
then use" is often not affordable at all. Choose formats whose *decode target*
is the consumer, and treat the download buffer itself as a resident cost.

### 11. Device capability is negotiated at runtime, and the default is deliberately weak

This applies to every graphics path, not just the newest one. It is worth being
explicit that **WebGPU is not the default web accelerator** — Godot's web export
is WebGL 2.0 only and does not support WebGPU at all; Unity's shipped Web target
is WebGL-based; the Unreal-to-browser work (Wonder Interactive / SimplyStream)
is the WebGPU case. A corpus rule written only against WebGPU would not apply to
most of what actually ships.

The general shape holds across all of them: **the runtime tells you what you may
use, after you ask, and the default answer is the portable minimum.**

- **WebGL** negotiates through extensions and queried limits — capabilities are
  requested via `getExtension()` and ceilings read via `getParameter()`
  (`MAX_TEXTURE_SIZE`, `MAX_VARYING_VECTORS`, and so on). MDN's best-practices
  guidance is to check rather than assume, and to have a path when an extension
  is absent.
- **WebGPU** makes the same negotiation explicit, and is widely misunderstood in
  a specific way:

  - `requestDevice()` **with no `requiredLimits` returns the spec default
    limits**, not the hardware's capability. Chrome's own migration guide
    states the default device is "a reasonable and lowest common denominator of
    all GPUs" — a portability mechanism, not a hardware report.
  - `GPUAdapter.limits` describes what the adapter *could* support;
    `GPUDevice.limits` describes what validation will actually enforce. These
    are different objects answering different questions, and conflating them is
    the standard error.
  - Requesting an unsupported capability **fails** — `requestDevice` rejects.
    The spec guarantees adapters support "the defaults or better".
  - MDN warns that browsers deliberately report **tiered** limit values to
    reduce fingerprinting surface, so advertised numbers are quantized and vary
    by browser; "thorough testing is advised".
  - WebGPU Fundamentals gives the design rule and warns against the tempting
    shortcut: **do not blindly promote the adapter's advertised limits into
    `requiredLimits`.** Decide what the application must have, request exactly
    that, and handle absence. Requesting everything on offer produces code that
    silently depends on optional capacity and fails mysteriously elsewhere.
  - Concrete spread: `maxStorageBufferBindingSize` is documented at a 128 MB
    floor on mobile, ranging to 4 GB on desktop — a 32× span across the devices
    one build must serve.

**Correction recorded.** An earlier draft of this note asserted that requesting
the adapter's own advertised maxima "is always satisfiable and so costs no
portability". That came from internal exploratory work, and the external sources
do not support it as a design rule: even where such a request succeeds, it
converts an explicit capability contract into an implicit one, which is the
failure mode the WebGPU limits design exists to prevent. The externally grounded
rule is the narrower one — request what you need, not what is offered.

### 12. Know the clock, and know that the debugger changes the program

Three independent hazards, all of which produce plausible wrong numbers:

- **The clock is clamped.** `performance.now()` resolves to **100 µs** in a
  non-isolated context and **5 µs** in a cross-origin isolated one. The clamp is
  a Spectre mitigation; Chrome has applied it since version 91. Any per-item
  cost near the quantum must be measured in aggregate, not per item.
- **The same headers gate threads and the clock.** A page that is not
  cross-origin isolated has no `SharedArrayBuffer` *and* a 100 µs quantum. These
  are documented in unrelated places and are one decision (see §7) — which also
  means a measurement rig may be able to isolate even when the shipping page
  deliberately does not.
- **Opening DevTools changes the compiled code.** Chrome's own DevTools
  documentation states that with DevTools open the code Chrome runs "isn't
  optimized. It's tiered down to give you better debugging experience," and that
  `console.time()` and `performance.now()` therefore cannot be relied on for
  profiling in that state. Use the Performance panel, or run the measurement
  with DevTools closed and inspect afterwards.
- **Tiering hides warm-up.** Liftoff runs first, TurboFan replaces hot functions
  later (§9), so early iterations measure baseline code. Unity additionally
  notes browsers throttle background tabs to roughly one update per second.

**Extraction.** Every browser-side timing figure needs its measurement
conditions stated — clock resolution, isolation status, DevTools state, and
whether warm-up was discarded. This is the browser instance of the `telemetry`
category's discipline: the instrument has known, coarse, documented limits.

### 13. Keep the compute core buildable natively, because the browser is a poor lab

A **measurement** argument before an architecture one. §12 establishes that
in-browser timing is coarse, tier-dependent, and perturbed by the debugger.
Browsers also do not expose hardware performance counters to page content, so
the counter-level analysis in §2 is simply unavailable from inside a page.

The strongest evidence is the research itself: Jangda et al. could not measure
real applications in a browser with existing tooling and had to build
Browsix-Wasm to do it, then read `perf` counters from outside. If a peer-reviewed
team needed a purpose-built harness to answer "why is this slow", an application
team will not get the answer from `performance.now()`.

Practitioner tooling confirms the shape: profiling WebAssembly at the machine
level is done today by driving V8's linux-perf integration from outside the
browser, precisely because DevTools cannot show the generated machine code
without changing it.

Engines already work this way for their own reasons — Unity, Unreal and Godot
each keep a portable engine core and treat web as a platform layer, which is
what makes a native profiling build possible at all.

**Extraction.** Keep platform-neutral compute in translation units that compile
for a native target, with the clock and I/O injected. Then the browser measures
end-to-end behaviour and the native build measures the kernel, and neither is
asked to do the other's job. Confining browser-specific code to a small,
identifiable boundary is what makes this checkable in CI rather than by review.

### 14. Reach is the constraint the desktop-Chromium view hides

Three related gaps, recorded because the evidence base for WASM performance —
including much of this note — skews heavily toward V8 on desktop.

**Engines tier differently, so "warm-up" is not one shape.** V8 uses two
compiler tiers: Liftoff eagerly compiles the whole module (~5× faster to
compile, ~1.5× slower to execute) and TurboFan replaces hot functions from a
background thread. SpiderMonkey also uses two compiler tiers. **JavaScriptCore
uses three** — an LLInt interpreter plus BBQ (quick JIT) and OMG (optimizing
JIT), tiering up from LLInt or BBQ. A warm-up procedure tuned to V8's curve is
not automatically valid on Safari, and `chrome://tracing`'s `wasm.TopTierFinished`
has no equivalent there.

**Mobile ceilings are far below desktop ones, and iOS is the binding case.**
Unity documents separate, more aggressive memory tuning for mobile browsers,
advising that Initial Memory Size be set to the application's typical heap usage
rather than left at a desktop-friendly default. The community-reported iOS
Safari figures are lower still — a few hundred MB before the tab is reclaimed —
though these are forum and vendor-blog reports rather than published limits, and
should be treated as directional. The design consequence is not in doubt: a heap
budget that is comfortable on desktop Chrome can be fatal on an iPhone, and the
`maxStorageBufferBindingSize` floor differs by 32× across the same span.

**WebAssembly has no in-module feature detection.** Every instruction in a
module must be supported by the target, so a SIMD build simply fails to
instantiate where SIMD is unavailable — there is no graceful in-module
fallback. The technique is therefore to **compile a variant per feature set and
select at load**, detecting from JavaScript before instantiating
(`wasm-feature-detect` is the standard implementation; web.dev documents the
pattern). Note this interacts with §9: each variant is a separate URL and
therefore a separate code-cache entry. Feature support is genuinely uneven and
moves — `webassembly.org/features` is the status source, and per-browser claims
go stale fast, which is why this note cites the mechanism rather than a support
matrix.

**Extraction.** Decide the target matrix explicitly and state it, the way Unity
and Godot both do. "Works on my desktop Chrome" is not a portability claim, and
the corpus should not let a Chromium-desktop measurement stand in for the web.

### 15. What changed, and what did not

Recorded because stale WASM advice is abundant and much of it is still repeated.

| Advice from the asm.js / early-WASM era | Status 2026 |
|---|---|
| "Disable exceptions entirely" | Softened. `-fwasm-exceptions` (native EH) is materially better than the JS-based scheme; Unity reports the overhead as minor under the WebAssembly 2023 feature set. |
| "Never grow the heap" | **Still true**, and for a reason often misstated: contiguity and double-residency at the moment of growth, not the copy alone. |
| "You can't have threads" | Conditional, and the condition is commercial. COOP/COEP is routine server config where you own the server; what it costs is cross-origin embedding — ads, third-party APIs. Godot defaults single-threaded for reach, not because the headers are unattainable. |
| "SIMD isn't available" | Obsolete. 128-bit SIMD is broadly shipped; relaxed SIMD too. |
| "The WebGPU default limits are the hardware's limits" | Wrong, and inverted — the default is a deliberate lowest common denominator. |
| "wasm32's 4 GiB is a hard wall" | Conditional. Memory64 exists but costs 32-bit pointer optimizations. |
| "WebGPU is the web's GPU API" | Premature as a default. Godot's web export is WebGL 2.0 only and does not support WebGPU; Unity's shipped Web target is WebGL-based. WebGPU is the leading edge, not the floor. |
| "Wasm is ~10% slower than native" | Misapplied. True-ish for AoT runtimes on kernels; browser JITs on real applications measured 1.45–1.55×. |
| "Batch your draw calls" | **More true than natively**, and for a browser-specific reason: validation plus an FFI transition per call. |

## Guideline slate

| ID | Working title | Primary grounding |
|---|---|---|
| WASM.1 | Size linear memory as one contiguous block and resist growing it | Unity manual + engine blog, Kongregate, Emscripten, memory64 proposal |
| WASM.2 | Batch across the boundary — every crossing is validation plus an FFI transition | Emscripten Optimizing WebGL, Unity manual, web.dev, V8 |
| WASM.3 | Give the frame back to the event loop; don't buy Asyncify to avoid it | Emscripten runtime environment + Asyncify docs |
| WASM.4 | Reduce indirect dispatch — every indirect call is type-checked at runtime | Jangda et al. §6.1.1, §6.2.2, §6.2.3, §6.3 |
| WASM.5 | Decide cross-origin isolation on reach and embedding, then design threading to match | Godot 4.3, Photoshop/Chrome, web.dev COOP/COEP, Emscripten pthreads |
| WASM.6 | Target 128-bit wasm SIMD explicitly and avoid the emulated operations | Emscripten SIMD doc, Photoshop figures, Unity |
| WASM.7 | Budget startup: stream instantiation, keep the code cache, measure past tier-up | V8 code caching + pipeline, Figma, Photoshop, web.dev |
| WASM.8 | Ship the module as a sized artifact; code size is startup latency | Emscripten Optimizing Code, Figma, Unity |
| WASM.9 | Keep assets compressed to their destination and stream them | Unity asset bundles, KTX2/Basis, OPFS via Photoshop |
| WASM.10 | Request the device capability you need, not the one on offer | WebGPU spec, MDN, Chrome, WebGPU Fundamentals, MDN WebGL best practices |
| WASM.11 | State the measurement conditions or the number means nothing | MDN, Chrome for Developers, Chrome DevTools, V8 |
| WASM.12 | Keep the compute core natively buildable so it can be profiled properly | Jangda et al. methodology, Chrome DevTools, Unity/Godot/Unreal structure |
| WASM.13 | Ship a build per feature set and select at load — WASM cannot detect its own | web.dev feature detection, `wasm-feature-detect`, webassembly.org/features |
| WASM.14 | State the target matrix; budget memory for the weakest device, not the development one | Unity mobile tuning, Godot host/Safari findings, WebGPU limit spread, JSC vs V8 tiering |

## Boundary against existing categories

- **`gpu`** owns device-side behaviour — coalescing, occupancy, divergence,
  barriers. `wasm` owns the seam: capability negotiated at acquisition
  (WASM.10), and the API call itself being an FFI transition (WASM.2).
- **`simd`** owns vectorization strategy. WASM.6 owns what differs under a fixed
  128-bit width with a documented list of badly lowering instructions, and the
  determinism cost of relaxed SIMD.
- **`codegen`** owns branch and dispatch shape generally. WASM.4 owns the
  WASM-specific reason it matters more: a runtime type check per indirect call
  and a worse code-size-to-i-cache exchange rate.
- **`embedded`** owns deterministic constraint discipline. WASM.1 and WASM.8
  cross-reference it; the differences are that the ceiling is an address space
  and code size is download latency.
- **`memory`** owns allocator strategy. WASM.1 records that `MEM.7`'s
  reserve-and-commit is unavailable on wasm32.
- **`telemetry`** owns instrumentation discipline. WASM.11 and WASM.12 are the
  browser instance: a coarse instrument, and a lab that must be built elsewhere.

## Sources

**Peer-reviewed**

- A. Jangda, B. Powers, E. D. Berger, A. Guha, "Not So Fast: Analyzing the
  Performance of WebAssembly vs. Native Code", USENIX ATC 2019 —
  <https://www.usenix.org/conference/atc19/presentation/jangda> (PDF:
  <https://arxiv.org/pdf/1901.09056>)
- R. Szewczyk, K. Stonehouse, A. Barbalace, T. Spink, "Leaps and Bounds:
  Analyzing WebAssembly's Performance with a Focus on Bounds Checking",
  IISWC 2022 — <https://ieeexplore.ieee.org/document/9975418/>

**Game engines**

- Unity, Memory in Unity Web — <https://docs.unity3d.com/Manual/webgl-memory.html>
- Unity, Web performance considerations — <https://docs.unity3d.com/6000.4/Documentation/Manual/webgl-performance.html>
- Unity, Understanding memory in Unity WebGL — <https://unity.com/blog/engine-platform/understanding-memory-in-unity-webgl>
- Kongregate, Unity WebGL memory and performance optimization —
  <https://blog.kongregate.com/unity-webgl-memory-optimization-part-deux/>
- Godot, Exporting for the Web — <https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html>
- Godot, Progress report: web export in 4.3 — <https://godotengine.org/article/progress-report-web-export-in-4-3/>
- Mozilla, Mozilla and Epic preview Unreal Engine 4 running in Firefox (2014) —
  <https://blog.mozilla.org/blog/2014/03/12/mozilla-and-epic-preview-unreal-engine-4-running-in-firefox/>
- A. Zakai, L. Wagner, "Compiling to the Web: Getting Started with asm.js and
  Emscripten", GDC 2014 — <https://www.gdcvault.com/play/1020720/Compiling-to-the-Web-Getting>
- Wonder Interactive / SimplyStream, Unreal Engine 5 via WebGPU + WebAssembly —
  <https://forums.unrealengine.com/t/webgpu-for-unreal-engine-5-5-6-and-5-7-support/2693960>

**Production ports**

- Chrome/Adobe, Photoshop's journey to the web — <https://web.dev/articles/ps-on-the-web>
- E. Wallace, WebAssembly cut Figma's load time by 3× —
  <https://madebyevan.com/figma/webassembly-cut-figmas-load-time-by-3x/>

**Toolchain**

- Emscripten, Optimizing Code — <https://emscripten.org/docs/optimizing/Optimizing-Code.html>
- Emscripten, Optimizing WebGL — <https://emscripten.org/docs/optimizing/Optimizing-WebGL.html>
- Emscripten, Using SIMD with WebAssembly — <https://emscripten.org/docs/porting/simd.html>
- Emscripten, Pthreads support — <https://emscripten.org/docs/porting/pthreads.html>
- Emscripten, Asynchronous Code (Asyncify / JSPI) — <https://emscripten.org/docs/porting/asyncify.html>
- Emscripten, Emscripten Runtime Environment — <https://emscripten.org/docs/porting/emscripten-runtime-environment.html>
- Emscripten, Compiler Settings reference — <https://emscripten.org/docs/tools_reference/settings_reference.html>

**Engines, tooling and platform**

- V8, WebAssembly compilation pipeline — <https://v8.dev/docs/wasm-compilation-pipeline>
- V8, Code caching for WebAssembly developers — <https://v8.dev/blog/wasm-code-caching>
- V8, Speculative optimizations for WebAssembly — <https://v8.dev/blog/wasm-speculative-optimizations>
- Chrome DevTools, Debug C/C++ WebAssembly — <https://developer.chrome.com/docs/devtools/wasm>
- Chrome for Developers, Aligning timers with cross-origin isolation restrictions —
  <https://developer.chrome.com/blog/cross-origin-isolated-hr-timers>
- Chrome for Developers, From WebGL to WebGPU — <https://developer.chrome.com/docs/web-platform/webgpu/from-webgl-to-webgpu>
- Leaning Technologies, Profiling web apps at the assembly level —
  <https://labs.leaningtech.com/blog/beyond-devtools-profiling-webapps-at-the-assembly-level>
- web.dev, WebAssembly performance patterns for web apps —
  <https://web.dev/articles/webassembly-performance-patterns-for-web-apps>
- web.dev, Loading WebAssembly modules efficiently — <https://web.dev/articles/loading-wasm>
- MDN, `Performance.now()` — <https://developer.mozilla.org/en-US/docs/Web/API/Performance/now>
- MDN, `WebAssembly.instantiateStreaming()` — <https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/JavaScript_interface/instantiateStreaming_static>
- MDN, `GPUAdapter.limits` — <https://developer.mozilla.org/en-US/docs/Web/API/GPUAdapter/limits>
- MDN, WebGL best practices — <https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API/WebGL_best_practices>
- WebGPU Fundamentals, Optional features and limits —
  <https://webgpufundamentals.org/webgpu/lessons/webgpu-limits-and-features.html>
- W3C, WebGPU — <https://www.w3.org/TR/webgpu/>
- W3C, High Resolution Time — <https://www.w3.org/TR/hr-time-3/>
- WebAssembly memory64 proposal — <https://github.com/WebAssembly/spec/blob/wasm-3.0/proposals/memory64/Overview.md>

**Asset delivery**

- Khronos, KTX — <https://www.khronos.org/ktx/>
- Binomial LLC, Basis Universal — <https://github.com/BinomialLLC/basis_universal>

**Cross-origin isolation**

- web.dev, Making your website "cross-origin isolated" using COOP and COEP —
  <https://web.dev/articles/coop-coep>
- G. Zuidhof, `coi-serviceworker` — <https://github.com/gzuidhof/coi-serviceworker>
- T. Steiner, Setting the COOP and COEP headers on static hosting —
  <https://blog.tomayac.com/2025/03/08/setting-coop-coep-headers-on-static-hosting-like-github-pages/>

**Portability and feature detection**

- web.dev, WebAssembly feature detection — <https://web.dev/articles/webassembly-feature-detection>
- GoogleChromeLabs, `wasm-feature-detect` — <https://github.com/GoogleChromeLabs/wasm-feature-detect>
- WebAssembly, Feature status — <https://webassembly.org/features/>
- V8, Liftoff: a new baseline compiler for WebAssembly — <https://v8.dev/blog/liftoff>
- A. Wingo, Understanding WebAssembly code generation throughput (V8, SpiderMonkey
  and JavaScriptCore tiering compared) —
  <https://wingolog.org/archives/2020/04/14/understanding-webassembly-code-generation-throughput>
