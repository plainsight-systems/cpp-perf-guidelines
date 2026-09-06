# Project Memory

This file is the canonical entry point for durable project context.

## Product Identity

- **Product:** C++ Performance Guidelines (corpus)
- **Operating brand:** None — parent-org infrastructure
- **Parent entity:** Plainsight Systems LLC
- **Repository:** cpp-perf-guidelines

## Engineering Philosophy

This corpus is maintained to the Plainsight Systems engineering philosophy:
<https://github.com/plainsight-systems/.github/blob/main/engineering_philosophies.md>

## Locked Decisions

- Governance adopted 2026-05-19. Decisions predating this date are recorded in
  git history rather than here.

## Research Index

- [`2026-05-19-memory-allocators-sources.md`](../research/2026-05-19-memory-allocators-sources.md)
  — source survey for the `memory` category.
- [`2026-05-19-memory-engine-allocators.md`](../research/2026-05-19-memory-engine-allocators.md)
  — allocator technique extraction from id Tech, Unreal, RE Engine, Sony
  first-party, and game-engine books.
- [`2026-05-19-copy-move-semantics.md`](../research/2026-05-19-copy-move-semantics.md)
  — copy/move technique extraction (RVO/NRVO, P0135, sink-parameter
  idioms, `noexcept` move and `std::vector`, trivially-copyable /
  relocatable, moved-from state, ABI).
- [`2026-05-20-cache-layout-techniques.md`](../research/2026-05-20-cache-layout-techniques.md)
  — cache-layout technique extraction (Acton DOD framing, AoS/SoA/AoSoA,
  cache line size and `hardware_destructive_interference_size`,
  struct ordering and hot/cold splitting, vector vs list, software
  prefetching, 3C taxonomy + profiler tools).
- [`2026-05-20-lifetime-techniques.md`](../research/2026-05-20-lifetime-techniques.md)
  — lifetime technique extraction (the four-way triviality distinction,
  placement new, `std::launder`, P0593 implicit object creation, P2590
  `start_lifetime_as`, static-init-order fiasco, object-pool lifetime,
  `aligned_storage` deprecation).
- [`2026-05-20-embedded-techniques.md`](../research/2026-05-20-embedded-techniques.md)
  — embedded technique extraction (steady-state-no-allocation discipline,
  exceptions/RTTI cost and bans, fixed-capacity containers from ETL/EASTL,
  deterministic allocators TLSF/o1heap, stack budgeting,
  `constexpr`/`consteval` for flash, `volatile` vs `std::atomic`,
  freestanding C++ subset, ISO 26262/MISRA/AUTOSAR/JSF framing).
- [`2026-05-20-concurrency-techniques.md`](../research/2026-05-20-concurrency-techniques.md)
  — concurrency technique extraction (C++ memory model, six memory
  orders mapped to x86 / ARMv8 cost, MESI / coherence cost, lock-free
  data structures via Folly / moodycamel / libcds / TBB, hazard pointers
  and RCU for reclamation, NUMA locality, spinlocks vs mutex vs
  lock-free).
- [`2026-05-20-codegen-techniques.md`](../research/2026-05-20-codegen-techniques.md)
  — codegen-nudge technique extraction (branch hints, branchless vs
  predicted branches with mispredict cost, `restrict` and TBAA, LTO /
  ThinLTO, instrumented PGO and sampling PGO / AutoFDO / CSSPGO,
  attribute-driven inlining, hot / cold placement, the optimiser's
  anti-promises).
- [`2026-05-20-simd-techniques.md`](../research/2026-05-20-simd-techniques.md)
  — SIMD technique extraction (autovec vs intrinsics vs `std::simd`,
  the portable libraries Highway / xsimd / Eve, alignment now mostly
  a correctness concern, gather as a trap, AVX-512 downclocking is
  historical, AVX-512 masks and SVE predication as the step change,
  the AMX → SME transition).
- [`2026-06-02-gpu-optimization-techniques.md`](../research/2026-06-02-gpu-optimization-techniques.md)
  — GPU and accelerator technique extraction (CUDA, Metal,
  Vulkan/D3D12, Unreal RDG, Godot, Filament, AMD GPUOpen, Capcom
  RE Engine, Naughty Dog; device residency, coalescing, occupancy,
  divergence, shared/threadgroup memory, launch overhead, CPU/GPU
  pipelining, barriers, transient GPU memory, and GPU profiling).

- [`2026-09-05-wasm-category-buildout-codex-review.md`](../research/2026-09-05-wasm-category-buildout-codex-review.md)
  — independent review of the `wasm` category (outcome: changes_requested;
  all findings worked under the remediation packet).
- [`2026-09-05-wasm-techniques.md`](../research/2026-09-05-wasm-techniques.md)
  — WebAssembly technique extraction (browser-JIT vs AoT slowdown figures,
  the safety checks behind indirect-call cost, contiguous linear memory and
  growth, the cooperative event loop and Asyncify's ~50% tax, FFI transitions
  on every graphics call, cross-origin isolation as a reach decision,
  fixed-width wasm SIMD, code caching and tier-up, asset streaming,
  runtime capability negotiation, browser measurement conditions, and the
  desktop-Chromium skew in the available evidence).

## Locked Decisions Added by This Packet

- **In-house exploratory work is not a source for this corpus.** Internal
  projects consume the guidelines; they do not generate them. Their numbers
  are single-device, single-browser, and taken under changing code.
  Guidelines must rest on external, citable sources. Recorded 2026-09-05
  while building the `wasm` category, after an internal harness's conclusion
  about WebGPU limit negotiation was found to contradict the platform's own
  guidance.

- **Corpus examples are verified by compilation, not by reading.** Independent
  review catches wrong *claims* well and wrong *code* poorly — it read the
  examples by eye and reported the toolchain as unavailable when it was not.
  Compiling and running an example found defects review did not: a destroyed
  alpha channel in a SIMD kernel, and undefined behavior in a planner whose
  whole subject was careful planning. Recorded 2026-09-05.

- **A verification step is not complete until it has been run.** The `wasm`
  buildout packet listed an MCP grounding check in its Verification Plan, then
  marked every acceptance criterion done without calling either server. The
  independent review found exactly the defect class that check exists to catch.
  Do not tick an acceptance criterion from intent; tick it from a tool result.
  Recorded 2026-09-06.

## Active Workflow Pointers

- Queue: `QUEUE.md`
- Packets: `packets/`
- Workflow: `workflow.md`
