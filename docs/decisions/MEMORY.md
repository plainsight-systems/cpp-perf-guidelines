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

## Active Workflow Pointers

- Queue: `QUEUE.md`
- Packets: `packets/`
- Workflow: `workflow.md`
