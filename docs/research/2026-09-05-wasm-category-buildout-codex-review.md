OUTCOME: changes_requested

## Summary

The packet’s mechanical claims hold: the `wasm` category exists, the corpus contains 101 guidelines across 11 categories, the expected files and sections are present, and `python3 tools/validate_corpus.py` passes.

The substantive acceptance claim does not hold. The current tree contains one example with immediate undefined behavior, several incorrect API/toolchain claims, historical V8 behavior presented as current, unsupported device thresholds, and multiple examples that violate consulted C++ Core Guidelines rules.

Four scoped files changed during this review without edits from me: the research note and WASM.1, WASM.6, and WASM.9. This review covers the final working-tree state I observed; the WASM.6 premultiplication bug was corrected by those concurrent edits.

## Factual accuracy findings

1. **P0 — The “good” WebGPU buffer planner dereferences an empty vector.**  
   [WASM.10:104](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.10-request-the-capability-you-need.md:104)

   - **Claim:** The example safely plans tensors against granted limits.
   - **Actual behavior:** `Plan plan` starts with no buffers. For an ordinary first tensor that fits, line 116 does not add a buffer, and line 118 evaluates `plan.buffers.back()`. That is undefined behavior. The same routine can overflow `offset + t.bytes` and `v + a - 1`, divide by zero when alignment is zero, and place an object larger than `max_buffer_size` after resetting the offset.
   - **Sources checked:** cpp-guidelines `SL.con.3`, `ES.103`, `I.5`, and `ES.105`.
   - **Expected correction:** Create the first buffer before accessing `back()`, validate nonzero alignment, reject tensors exceeding either applicable size limit, and use checked subtraction/addition for all size arithmetic.

2. **P1 — `emscripten_set_main_loop` return behavior is stated incorrectly.**  
   [WASM.3:45](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.3-return-the-frame-to-the-event-loop.md:45)

   - **Claim:** “Nothing after `emscripten_set_main_loop` runs when `-sEXIT_RUNTIME=0`.”
   - **Actual source:** Return behavior is controlled by `simulate_infinite_loop`, not by `EXIT_RUNTIME`. With `simulate_infinite_loop=false`, the call returns normally and the caller’s stack unwinds. The example itself passes false and correctly says it returns at lines 103–106, directly contradicting the guidance.
   - **Source checked:** [Emscripten API reference](https://emscripten.org/docs/api_reference/emscripten.h.html).
   - **Expected correction:** Describe the two `simulate_infinite_loop` modes accurately and base the ownership discussion on the selected mode.

3. **P1 — Wrong MIME type does not cause native `instantiateStreaming` to “silently fall back.”**  
   [WASM.7:36](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.7-budget-startup-and-keep-the-code-cache.md:36), [WASM.7:145](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.7-budget-startup-and-keep-the-code-cache.md:145)

   - **Claim:** The browser silently uses non-streaming compilation when the server sends the wrong MIME type.
   - **Actual source:** The native API requires `application/wasm`; failure rejects the promise. A particular generated loader may implement a fallback, but that is not native API behavior.
   - **Source checked:** [MDN: WebAssembly.instantiateStreaming](https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/JavaScript_interface/instantiateStreaming_static).
   - **Expected correction:** State that native streaming instantiation fails, then show an explicit fallback if one is desired or identify the specific loader that supplies it.

4. **P1 — Historical V8 caching and compilation behavior is presented as current design guidance.**  
   [WASM.7:22](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.7-budget-startup-and-keep-the-code-cache.md:22), [WASM.7:29](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.7-budget-startup-and-keep-the-code-cache.md:29), [WASM.13:41](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.13-ship-a-build-per-feature-set.md:41), [WASM.14:16](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.14-state-the-target-matrix.md:16)

   - **Claims:** V8 eagerly compiles the whole module with Liftoff; 128 kB is the operative cache threshold; growing a module past that threshold may improve startup; path versioning preserves code caching while query versioning discards it.
   - **Actual sources:** Current V8 documentation describes lazy first-call compilation with Liftoff and later TurboFan optimization. The fixed 128 kB rule comes from a 2019 implementation note and is not a current platform contract. A changed path and a changed query both produce a different URL/cache entry; a stable query URL is not inherently uncached.
   - **Sources checked:** [V8 compilation pipeline](https://v8.dev/docs/wasm-compilation-pipeline) and [V8’s 2019 code-caching article](https://v8.dev/blog/wasm-code-caching).
   - **Expected correction:** Remove the module-inflation recommendation, treat cache thresholds as measured/versioned implementation details, and recommend immutable stable URLs without claiming special V8 semantics for path components.

5. **P1 — WASM.1 makes non-universal memory-growth behavior categorical.**  
   [WASM.1:6](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.1-size-linear-memory-and-resist-growth.md:6), [WASM.1:12](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.1-size-linear-memory-and-resist-growth.md:12)

   - **Claim:** Growth detaches every JS view and necessarily requires both complete host allocations to be resident.
   - **Actual sources:** Ordinary non-shared memories detach their previous `ArrayBuffer`, even for `grow(0)`. Shared memories do not detach the old `SharedArrayBuffer`; its length stays unchanged and a new `buffer` exposes the larger extent. Copying and simultaneous full allocations are possible implementation behavior, not a WebAssembly guarantee. Current Emscripten also exposes `GROWABLE_ARRAYBUFFERS`.
   - **Sources checked:** [MDN: WebAssembly.Memory.grow](https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/JavaScript_interface/Memory/grow) and [Emscripten settings reference](https://emscripten.org/docs/tools_reference/settings_reference.html).
   - **Expected correction:** Distinguish shared from non-shared memory, logical contiguity from host allocation strategy, and legacy typed-array handling from current growable-buffer support.

6. **P1 — The 128 MB-mobile/4 GB-desktop “32× range” is not established by the cited sources.**  
   [WASM.10:30](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.10-request-the-capability-you-need.md:30), [WASM.14:28](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.14-state-the-target-matrix.md:28)

   - **Claim:** `maxStorageBufferBindingSize` has a documented 128 MB mobile floor and 4 GB desktop ceiling.
   - **Actual sources:** 128 MiB is a WebGPU default/minimum capability value, not a mobile classification. Adapter limits are implementation/device-dependent and tiered. The checked sources do not establish 4 GiB as a general desktop endpoint.
   - **Sources checked:** [MDN: GPUAdapter.limits](https://developer.mozilla.org/en-US/docs/Web/API/GPUAdapter/limits) and [WebGPU Fundamentals: limits](https://webgpufundamentals.org/webgpu/lessons/webgpu-limits-and-features.html).
   - **Expected correction:** State the specification default separately from observed adapter values, and cite measured browser/device/version data for any range.

   The example’s comment `spec floor: 4 in, 4 out` at line 81 is also wrong: `maxStorageBuffersPerShaderStage` counts bindings visible to a stage; it is not divided into input and output quotas.

7. **P1 — The native-build guard prevents the promised cross-target core build.**  
   [WASM.12:112](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.12-keep-the-compute-core-natively-buildable.md:112)

   - **Claim:** The guard prevents browser-specific assumptions from entering `src/core`.
   - **Actual behavior:** It rejects every Emscripten build that defines `BUILDING_CORE`, even when the core contains no platform dependency. That is the opposite of the surrounding design, which says the same core compiles for native and WASM.
   - **Expected correction:** Guard actual platform headers/macros or rely on the shown dependency check; do not reject the target itself.

8. **P1 — WASM.9 attributes the opposite memory behavior to Unity.**  
   [WASM.9:26](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.9-keep-assets-compressed-to-their-destination.md:26)

   - **Claim:** Unity’s AssetBundle guidance keeps downloads out of the heap.
   - **Actual source:** Current Unity documentation says AssetBundles are downloaded directly into the Unity heap, avoiding an additional browser-side allocation.
   - **Source checked:** [Unity: Memory in Unity Web](https://docs.unity3d.com/Manual/webgl-memory.html).
   - **Expected correction:** Describe the direct-to-Unity-heap behavior and its avoidance of duplicate buffering; retain load/unload-on-demand as a separate recommendation.

9. **P1 — WASM.4 turns measured engine behavior and possible compiler lowering into universal facts.**  
   [WASM.4:15](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.4-reduce-indirect-dispatch.md:15), [WASM.4:39](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.4-reduce-indirect-dispatch.md:39), [WASM.4:97](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.4-reduce-indirect-dispatch.md:97)

   - **Claims:** A stack-overflow check is emitted at every function entry, and `std::variant` visitation lowers to direct calls or a jump table without function-table lookup.
   - **Actual source:** Jangda et al. measured stack checks and other overheads in specific 2019 Chrome/Firefox implementations. WebAssembly does not mandate that machine-code implementation. C++ and `std::visit` do not guarantee the claimed lowering; implementations can use dispatch tables, and modern V8 can speculatively inline indirect calls.
   - **Sources checked:** [Jangda et al., USENIX ATC 2019](https://www.usenix.org/conference/atc19/presentation/jangda) and [V8 speculative call-indirect inlining](https://v8.dev/blog/wasm-speculative-call-indirect).
   - **Expected correction:** Scope the measured overheads to engines/versions, treat variant lowering as something to inspect and benchmark, and distinguish semantic validation from checks remaining in optimized machine code.

10. **P2 — Timer resolution is generalized from Chrome to “the browser.”**  
    [WASM.11:6](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.11-state-the-measurement-conditions.md:6)

    - **Claim:** Browser clocks are 100 µs normally and 5 µs under isolation.
    - **Actual sources:** Those are Chrome’s documented values; other browsers may expose coarser resolutions.
    - **Sources checked:** [Chrome: cross-origin isolation](https://developer.chrome.com/blog/enabling-shared-array-buffer/) and [MDN: performance.now](https://developer.mozilla.org/en-US/docs/Web/API/Performance/now).
    - **Expected correction:** Label the figures as Chrome-specific examples and require recording observed resolution, browser, and version.

11. **P2 — Disabling autovectorization is presented as necessary for handwritten SIMD.**  
    [WASM.6:49](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.6-target-128-bit-wasm-simd.md:49)

    - **Claim:** Disable loop and SLP vectorization so the compiler does not undo an intrinsic layout.
    - **Actual source:** Emscripten documents these switches when autovectorization is undesirable; it does not say handwritten intrinsics require global disabling, and the approaches can coexist in one module.
    - **Source checked:** [Emscripten SIMD guide](https://emscripten.org/docs/porting/simd.html).
    - **Expected correction:** Make this a measured, narrow per-file/function workaround rather than default build guidance.

## Sourcing and originality

No material copied code or close prose translation was found in the cited examples I spot-checked. The examples appear bespoke.

The packet’s literal “all prose is original” guarantee is nevertheless not quite true: [WASM.3:28](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.3-return-the-frame-to-the-event-loop.md:28) reproduces Emscripten’s short phrase “something like 50% or so” as a quotation. This is attributed, brief, and not a material licensing exposure, but under the repository’s unusually strict no-copy rule it should be paraphrased.

The larger sourcing problem is inaccurate attribution rather than copying: Unity does not support WASM.9’s “out of the heap” statement, and the 2019 V8 cache article does not support treating path versioning, the 128 kB threshold, or eager whole-module compilation as current platform contracts.

## Corpus consistency

All referenced IDs exist. Descriptions of existing rules checked through cpp-performance were materially accurate, including `MEM.7`, `MEM.9`, `GPU.6`, `GPU.7`, `GPU.9`, `GEN.4`, `GEN.6`, `GEN.7`, `CACHE.1`, `CACHE.6`, `SIMD.1`, `SIMD.3`, `SIMD.6`, `SIMD.7`, `TLM.1`, `TLM.6`, `TLM.9`, and `EMB.3`.

No silent contradiction with the published corpus was found. WASM.1 explicitly qualifies `MEM.7` for wasm32, and the SIMD/build-variant guidance identifies how web feature selection differs from `SIMD.6`. Adjacent GPU batching, allocation, telemetry, and code-layout guidance is complementary rather than duplicative.

## C++ example review

Grounded through cpp-guidelines:

- **P0:** WASM.10 violates `SL.con.3`, `ES.103`, `I.5`, and potentially `ES.105`, as described above.
- **P1:** [WASM.3:83](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.3-return-the-frame-to-the-event-loop.md:83) transfers owning state through `void*`, allocates with explicit `new`, and destroys it via `delete &ctx`. That conflicts with `R.11`, `I.11`, and the non-owning interpretation of raw pointers in `R.3`. Use an owning registry/RAII handle with an explicitly non-owning callback pointer.
- **P2:** [WASM.1:76](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.1-size-linear-memory-and-resist-growth.md:76) uses `malloc/free` despite `R.10`, and its alignment arithmetic lacks a nonzero-power-of-two precondition and overflow protection (`I.5`, `ES.103`).
- **P2:** [WASM.7:112](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.7-budget-startup-and-keep-the-code-cache.md:112) indexes an empty vector when `iterations == 0`, violating `SL.con.3`; [WASM.11:92](/Users/andyhunter/repositories/cpp-perf-guidelines/guidelines/wasm/WASM.11-state-the-measurement-conditions.md:92) likewise lacks a nonzero-iterations precondition.
- Positive checks: the polymorphic examples use virtual destructors consistently with `C.127`; `final`/`override` advice aligns with `C.128`; span-based interfaces are generally bounds-conscious.

The examples were reviewed manually. They were not compiled because the repository supplies no example harness and `em++` is unavailable locally.

## Format and parser contract

`python3 tools/validate_corpus.py` passes:

```text
Validated 101 guidelines.
```

The category count, `wasm`/`WASM` declaration, file/ID/category consistency, required sections, reference sections, summary constraints, and local links pass the repository validator. README, MEMORY, and QUEUE contain the claimed category/work-state updates.

The working tree is not clean: four scoped files contain concurrent uncommitted changes, and an unrelated untracked `scripts/` directory exists.

## MCP grounding

Both mandatory servers were available. **REVIEW ENVIRONMENT FAILURE: none.**

Calls actually made:

- `cpp-guidelines.search_guidelines`
- `cpp-guidelines.get_guideline` for `R.3`, `R.10`, `R.11`, `I.5`, `I.11`, `SL.con.3`, `ES.103`, `ES.105`, `C.127`, and `C.128`
- `cpp-performance.search_guidelines`
- `cpp-performance.get_guideline` for the existing corpus IDs listed under Corpus consistency

External sources actually opened included:

- Emscripten settings, SIMD, Asyncify/JSPI, pthreads, runtime-environment, and API-reference documentation
- MDN pages for `Memory.grow`, `instantiateStreaming`, `performance.now`, and WebGPU adapter limits
- Current V8 compilation-pipeline documentation, the 2019 caching article, and speculative indirect-call inlining
- Jangda et al.’s USENIX page and paper
- Current Unity memory/performance documentation
- Current Godot web-export documentation
- Chrome timer-isolation and WebGPU migration documentation
- Khronos KTX/Basis documentation
- WebAssembly feature-detection documentation and `wasm-feature-detect`
- Photoshop’s web port report

The monolithic W3C WebGPU page exceeded the web reader’s size limit. The exact 4 GiB/device-class claim was therefore checked against the cited MDN and WebGPU limits material and remained unsupported.

## Residual risk

The 14 files contain many fast-moving browser and engine details. After correcting the blockers, version-sensitive claims should be explicitly dated and rechecked against current vendor documentation.

Originality review was a manual comparison of the cited material, not a corpus-wide plagiarism detector. Example compilation also remains unperformed. Most importantly, the concurrent changes mean the packet should be re-reviewed from a stable commit before its status returns to `completed`.