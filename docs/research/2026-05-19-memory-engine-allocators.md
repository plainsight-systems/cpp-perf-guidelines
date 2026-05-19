# Memory Management & Allocators in Real Game Engines — Technique Extraction

Research note — 2026-05-19. Supports packet
`2026-05-19-memory-category-buildout`. Companion to
`2026-05-19-memory-allocators-sources.md` (the source survey); this note
extracts concrete allocator *techniques* engine by engine. No code is
reproduced; GPL (id Tech) and EULA (Unreal) sources are studied conceptually
per the `CONTRIBUTING.md` sourcing rule.

## 1. id Tech (Quake → id Tech 5)

**Quake (1996)** ships three cooperating allocators carved out of one
contiguous block obtained at startup:

- **Hunk** — a double-ended stack allocator. Large static assets (geometry,
  textures, models) push from the low end, temporary data from the high end;
  the only way to free is to reset a pointer.
- **Zone** — a header-tagged free-list for small, volatile allocations
  (strings, cvars). Each block carries size, allocation tag, and prev/next
  links; tag 0 means free.
- **Cache** — an LRU-style region for reusable-but-reloadable objects (alias
  models, sounds, menu graphics) that can be evicted under pressure.

The notable idea is *intent-segregated allocators*: small/volatile traffic is
physically separated from large/static traffic so the latter never fragments.

**Quake II / III** evolve this. Quake II uses tagged `Z_Malloc`. Quake III
formalizes a dual scheme: a hunk with two stacks meeting in the middle, plus a
zone split into a "main zone" (general dynamic) and a "small zone" (tiny
allocations isolated to avoid fragmenting the main zone). The progression is
toward more, finer-grained, purpose-specific arenas.

**Doom 3 / id Tech 4 (2004)** routes everything through
`Mem_Alloc16`/`Mem_Free16` (16-byte aligned) — a tiered allocator with
small/medium/large size pools created at load time, a B-tree over free blocks
for dynamic management, and per-class statistics. Independent benchmarks put it
roughly 2.5–3× faster than the MSVC `malloc`/`free` of the era.

**id Tech 5 (Rage, 2011)** shifts the problem from heap allocators to *virtual
texture streaming* ("MegaTexture"). Levels are authored as one enormous
texture, sliced into small pages streamed from disk to RAM/GPU on demand based
on what the camera needs. Memory management becomes a page-residency /
working-set problem, not a free-list problem.

*Takeaway:* segregate allocations by lifetime and size class; stack/arena
allocators dominate for static data; the long-term trend is page-granular,
demand-mapped working sets. *Licensing:* Quake/QII/QIII/Doom 3 are GPL —
**study-only**; id Tech 5 is proprietary, documented via talks/articles only.

## 2. Unreal Engine

Unreal centralizes allocation behind the `FMalloc` virtual interface
(`Malloc`/`Realloc`/`Free`/`Quantize`), exposed through the global `GMalloc`
pointer; `FMemory::Malloc` and overloaded global `new`/`delete` route through
it. The concrete allocator is selectable per platform and via command line
(`-binnedmalloc`, `-binnedmalloc2`, `-tbbmalloc`, `-ansimalloc`).

The **MallocBinned family** is a segregated-free-list / pool design.
Allocations are bucketed into power-of-two-ish size classes (8 B, 16 B … 32 KB);
each class draws from pages of identically-sized bins, so a freed bin is
reusable only by same-size requests — eliminating small-block fragmentation.
*Binned2* manages 64 KiB pages, tracks free bins via `FPoolInfo`, and forwards
large requests (more than ~32 KB) to a paged OS allocator at 64 KiB-aligned,
4 KiB-granular addresses; locking is per-pool to reduce contention. *Binned3*
is 64-bit only: it reserves a large contiguous virtual address range (~1 GB)
per size class and commits/decommits OS pages on demand within it — the
virtual-reservation technique now common across modern engines. **TBBMalloc**
(Intel TBB) was historically the editor default for multithreaded scalability;
**mimalloc** (Microsoft) is integrated as an alternative in UE5.

`FMemStack` is Unreal's per-frame **linear stack allocator**: items are pushed
via `PushBytes` / a specialized `operator new` and freed en masse by popping an
`FMemMark`. It is the canonical pattern for transient per-frame scratch.

*Takeaway:* one polymorphic allocator interface + a binned pool allocator for
the general heap + a linear stack allocator for per-frame data. Size-class
pooling is the workhorse anti-fragmentation tool. *Licensing:* source-available
under EULA — **study-only** — but extensively documented in Epic's API docs and
community write-ups (citable).

## 3. RE Engine (Capcom)

Capcom's RE:2023 talk "The Road to Introducing Virtual Memory Allocators" is a
direct, citable source. The old in-house heap allocated all budgeted memory at
startup into fixed-capacity *segments* (Default / Permanent / Temp / Resource)
and returned it only at process exit — capacity was worst-case-sized and
vulnerable to fragmentation, which proved fatal for open-world modes (Street
Fighter 6's World Tour, Exoprimal). The redesign decouples *virtual* from
*physical* addressing: virtual address space is vast, so physical pages can be
gathered from anywhere and fragmentation becomes negligible; segments degrade
to budgeting *guides* rather than hard partitions, allowing cross-segment
pooling. Implementation is built on **Microsoft's mimalloc 2.0.3** (MIT),
chosen for lockless multi-core scaling. Console-specific tuning: low-priority
threads share heap instances instead of each owning one (cutting
per-thread-heap overhead by ~30%); an **LRU cache of memory mappings** smooths
syscall spikes (~70% hit rate); allocation granularity is tuned to the game
loop.

*Takeaway:* virtual-address reservation + demand physical paging converts
fragmentation from a fatal allocation-failure risk into a non-issue; cache the
expensive map/unmap syscalls.

## 4. Naughty Dog & Sony First-Party

**Naughty Dog** — "Parallelizing the Naughty Dog Engine Using Fibers" (GDC
2015, Christian Gyrling) is the canonical talk and does discuss memory:
frame-centric design, per-frame allocation patterns, and lock strategy
alongside the fiber job system. *Honest gap:* there is no dedicated Naughty Dog
allocator-internals talk; memory is covered as part of the engine/concurrency
story, not a standalone deep-dive.

**Sony London Studio** — "Building a Low-Fragmentation Memory System for 64-bit
Games" (GDC 2016, Aaron MacDougall) is a fully citable, slide-available
allocator deep-dive and the strongest single source here. Its model: split the
entire ~944 GB virtual address space into regions and map physical memory on
demand. Specialized allocator *modules* each own a region behind a common
`Allocator` interface (`Allocate(size, align)` / `Deallocate` / `GetSize` /
`GetName`); a `GeneralAllocator` dispatches by size to Small / Medium / Large /
Giant:

- **Small module** — sub-64-byte allocations packed into 16 KB pages of one
  size class, *no per-allocation headers*, free-lists per size. Tiny, fast,
  near-zero waste.
- **Large module** — reserves 160 GB virtual, divided into power-of-two size
  tables of equal slots; maps/unmaps 64 KB pages on demand, guarantees
  contiguous virtual memory, ~200 lines, no headers, no fragmentation. The key
  enabler of texture streaming: reserve a slot, map pages on demand, never copy
  or defragment.
- **Medium module** — traditional doubly-linked-list with headers and
  power-of-two free-lists for everything else.
- **Frame allocator** — per-thread linear push/pop scratch, no locks.
- **GPU scratch allocator** — double-buffered, atomic-protected, no
  deallocation.

Debugging is first-class: memorable byte-fill clear values, header guard
patterns, full allocation tracing with callstacks, live graphs, and HTML dumps
on demand / OOM / leak.

*Takeaway:* on 64-bit, reserve giant virtual ranges and map physical pages on
demand; use *headerless* size-class pages for small allocations; make per-frame
and GPU-scratch allocators linear and lock-free; treat debugging
instrumentation as a design requirement.

## 5. Other Engines

**Frostbite (EA/DICE)** — the public memory-relevant talk is "FrameGraph:
Extensible Rendering Architecture in Frostbite" (Yuriy O'Donnell, GDC 2017).
Not a CPU-allocator talk, but a *transient resource aliasing* technique:
render-graph resources live one frame, and non-overlapping lifetimes share the
same GPU memory.

**Bungie / Destiny** — "Lessons from the Core Engine Architecture of Destiny"
(GDC 2015) covers foundation systems including platform memory management and a
data-structure toolbox; the rendering work splits simulation state from render
state, cutting per-frame duplicated memory substantially. Neither is an
allocator deep-dive — cite for *architectural* memory discipline, not allocator
internals.

## 6. Books

Jason Gregory's *Game Engine Architecture* (memory chapter, §6.2) is the
canonical cite-by-reference text. It documents: **stack allocators** (LIFO,
simple, cheap), **double-ended stack allocators** (the Quake hunk pattern),
**pool allocators** (many identical fixed-size blocks, O(1) alloc/free,
fragmentation-immune), **single-frame allocators** (cleared every frame), and
**double-buffered frame allocators** (preserve data across two frames). It
treats **alignment** explicitly (over-allocate, round up, store the
adjustment), and frames fragmentation as the central pathology that motivates
pools and defragmentation / handle-based relocation.

*Takeaway:* the book is the vocabulary source — every engine above is an
instance of the stack / pool / frame / binned allocators it names.
*Licensing:* copyrighted — **cite by reference**, do not reproduce.

## Cross-Engine Synthesis (for guideline authors)

- **Segregate by size class and by lifetime.** Every engine isolates
  small/volatile from large/static traffic.
- **Linear/stack allocators for transient data.** Per-frame scratch should
  push/pop, never free individually — ideally per-thread and lock-free.
- **64-bit changes the game.** Reserve huge virtual address ranges,
  commit/decommit physical pages on demand — fragmentation becomes *address*
  fragmentation, and addresses are now cheap (Sony London, RE Engine, UE
  Binned3).
- **Headerless pools** minimize waste for tiny allocations but cost
  stomp-detection ability — a real tradeoff to call out.
- **Debugging is a design requirement** — byte-fill patterns, header guards,
  allocation tracing with callstacks, OOM/leak dumps.

## Sources

- Quake `zone.h` (id Software, GPL) — <https://github.com/id-Software/Quake/blob/master/WinQuake/zone.h>
- Quake memory manager / Zone (InsideQC) — <https://forums.insideqc.com/viewtopic.php?t=1925>
- Memory Management — Quake III Arena (RealityForge) — <https://realityforge.org/Quake-III-Arena/idTech/memory.html>
- DOOM-3 `Heap.cpp` (id Software, GPL) — <https://github.com/id-Software/DOOM-3/blob/master/neo/idlib/Heap.cpp>
- Doom memory allocator overview — <https://bookdown.org/robertness/doom_tour/3_1_memory_allocator.html>
- Benchmarking malloc with Doom 3 (ForrestTheWoods) — <https://www.forrestthewoods.com/blog/benchmarking-malloc-with-doom3/>
- id Tech 5 / virtual texturing — <https://en.wikipedia.org/wiki/Id_Tech_5>
- FMallocBinned3 — Unreal Engine documentation — <https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Core/FMallocBinned3>
- Unreal Source Explained — memory — <https://github.com/donaldwuid/unreal_source_explained/blob/master/main/memory.md>
- Allocators / malloc — UE4 Gamedev Guide — <https://ikrima.dev/ue4guide/engine-programming/memory/allocators-malloc/>
- Illustrated overview of the Unreal MallocBinned2 allocator — <https://rawsourcecode.io/posts/illustrated-overview-mb2-allocator-part-1>
- FMemStackBase — Unreal Engine documentation — <https://docs.unrealengine.com/en-US/API/Runtime/Core/Misc/FMemStackBase/index.html>
- The Road to Introducing Virtual Memory Allocators — Capcom RE:2023 — <https://www.capcom-games.com/coc/2023/en/session/13/>
- The Road to Introducing Virtual Memory Allocators — slides — <https://www.docswell.com/s/CAPCOM_RandD/ZXYDVM-RE2023>
- Parallelizing the Naughty Dog Engine Using Fibers — GDC 2015 — <https://media.gdcvault.com/gdc2015/presentations/Gyrling_Christian_Parallelizing_The_Naughty.pdf>
- Building a Low-Fragmentation Memory System for 64-bit Games — GDC 2016 — <https://media.gdcvault.com/gdc2016/Presentations/MacDougall_Aaron_Building_A_Low.pdf>
- FrameGraph: Extensible Rendering Architecture in Frostbite — GDC 2017 — <https://www.gdcvault.com/play/1024612/FrameGraph-Extensible-Rendering-Architecture-in>
- Lessons from the Core Engine Architecture of Destiny — GDC 2015 — <https://gdcvault.com/play/1022106/Lessons-from-the-Core-Engine>
- Gregory, *Game Engine Architecture*, 3rd ed. — <https://www.routledge.com/Game-Engine-Architecture-Third-Edition/Gregory/p/book/9781138035454>
