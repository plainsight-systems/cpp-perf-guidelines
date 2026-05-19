# Source Survey: `memory` Category (Custom Allocators & Memory Management)

Research note — 2026-05-19. Supports packet
`2026-05-19-memory-category-buildout`. Sources are classified by the
`CONTRIBUTING.md` sourcing rule:

- **Citable** — freely published, or a public talk/paper: cite and write
  original prose.
- **Cite-by-reference** — copyrighted books / paid standards: cite the
  reference, never reproduce text.
- **Study-only code** — source-available (Unreal EULA) or copyleft/GPL
  (id Tech): study the technique, never copy code.
- **Permissive code** — MIT/BSD/Apache code that may be referenced more
  directly (still write original guideline prose).

## Scope and structure

The `memory` domain breaks into seven sub-topics. Sources are grouped by
sub-topic, then assessed individually.

### 1. Hardware foundations (cache hierarchy, page size, TLB, NUMA, huge pages)

- **Ulrich Drepper, "What Every Programmer Should Know About Memory" (2007).**
  The canonical primer on DRAM/SRAM, multi-level caches, cache lines, TLBs,
  prefetching, and NUMA. Underpins sizing allocations to the cache hierarchy.
  Published as a 7-part LWN.net series and a ~114-page PDF. **Tier: Citable.**
  Note: pre-dates current core counts but the structural model holds — flag
  age in any guideline.
- **Red Hat Enterprise Linux performance docs — "Configuring huge pages."**
  Current treatment of HugeTLB vs. Transparent Huge Pages (THP), per-NUMA-node
  reservation, and TLB-pressure tradeoffs. **Tier: Citable** (vendor docs).
- **LWN.net, "Transparent huge pages, NUMA locality, and performance
  regressions" (2019).** Documents the THP/NUMA failure mode. Good for a
  fragmentation/locality caveat. **Tier: Citable.**

### 2. Agner Fog's optimization manuals

- **Agner Fog, "Optimizing software in C++"** (plus the microarchitecture and
  instruction-tables manuals). Covers avoiding dynamic allocation, efficient
  container templates, data-layout cost. **Tier: Citable with care.** Freely
  downloadable from agner.org, but Fog retains copyright — cite, never
  reproduce text or figures.

### 3. Game-engine allocator design (arena/linear, stack, pool, ring/frame)

- **Jason Gregory, *Game Engine Architecture* (3rd ed., CRC Press).** §6.2
  ("Memory Management") and Ch. 3 cover stack allocators, double-buffered/frame
  allocators, pool allocators, and memory-layout cost. The best structured
  reference for the engine-developer audience. **Tier: Cite-by-reference.**
- **Molecular Musings blog (Stefan Reinalter).** "Memory system Parts 1–5" and
  "Memory allocation strategies" (linear, stack-like/LIFO, growing, pool,
  virtual-memory/page allocators); policy-based-design framing with
  bounds-checking/tagging. **Tier: Citable** (public blog; treat substantial
  code snippets as study-only unless licensed).
- **AnKi 3D Engine dev blog, "Custom C++ allocators suitable for video
  games."** Practical write-up of linear/stack/pool/chain allocators.
  **Tier: Citable.**
- **Ryan Fleury, "Untangling Lifetimes: The Arena Allocator."** Influential
  modern essay on arena lifetime design. **Tier: Citable.**
- **Robert Nystrom, *Game Programming Patterns* — "Double Buffer," "Object
  Pool."** Pattern-level treatment. **Freely readable online** at
  gameprogrammingpatterns.com. **Tier: Citable.**
- **GDC Vault engine memory-management talks.** **Tier: Cite-by-reference**
  unless a specific talk is confirmed free — much GDC Vault content is
  paywalled; cite metadata, do not reproduce slides.

### 4. C++ standard library: allocators and `std::pmr`

- **CppCon 2017 — Bob Steagall, "How to Write a Custom Allocator."**
  C++14/17 allocator requirements and allocator-aware containers.
  **Tier: Citable** (public talk; video + slides).
- **CppCon 2017 — Pablo Halpern, "Allocators: The Good Parts."** Rationale for
  the PMR model; companion repo `phalpern/CppCon2017Code`. **Tier: Citable**
  for the talk; the code repo is **Permissive code** if its LICENSE confirms.
- **CppCon 2017 — John Lakos, "Local ('Arena') Memory Allocators" (2 parts).**
  Deep treatment of arena allocators with measured benefit. **Tier: Citable.**
- **CppCon 2019 — Meredith & Halpern, "Getting Allocators out of Our Way."**
  Allocator ergonomics and PMR adoption. **Tier: Citable.**
- **WG21 N3916, "Polymorphic Memory Resources" (Halpern).** The standardization
  proposal — definitive `std::pmr` design intent. **Tier: Citable** (ISO C++
  committee paper).
- **cppreference.com `<memory_resource>` / `polymorphic_allocator`.**
  Authoritative contract reference. **Tier: Citable** — but cppreference is
  CC BY-SA; paraphrase rather than paste, to avoid license-mixing into this
  CC BY 4.0 corpus.
- **Nico Josuttis, "PMR — Polymorphic Memory Resources" (isocpp.org)** and
  **R. Kaiser, "C++17 PMR and STL for Embedded Applications" (embo++ 2021).**
  Practical PMR usage including embedded. **Tier: Citable.**

### 5. EA EASTL design documentation

- **Electronic Arts, EASTL — `doc/Design.md` and repository.** Documents the
  single-allocator-interface model, allocator-aware containers, and the
  deliberate divergence from `std::allocator` for game development.
  **Tier: Permissive code** — EASTL is BSD-3-Clause; reference more directly,
  quote with attribution, still write original guideline prose.

### 6. Production general-purpose allocators (fragmentation/threading reference designs)

- **mimalloc (Microsoft) — repo + technical report (Daan Leijen).** Free-list
  sharding, thread-local heaps, segment design. **Tier: Permissive code**
  (MIT); technical report **Citable**.
- **jemalloc (Jason Evans) and TCMalloc (Google).** Arena/size-class design,
  thread caches. **Tier: Permissive code** (jemalloc BSD-2-Clause; TCMalloc
  Apache-2.0); papers/design docs **Citable**.

### 7. Embedded / real-time / heapless allocation

- **MISRA C++ and AUTOSAR C++14 Coding Guidelines.** MISRA historically bans
  dynamic heap allocation (leaks, exhaustion, non-determinism); AUTOSAR C++14
  permits controlled dynamic memory with explicit rules. Essential for the
  embedded audience and for framing fragmentation/determinism guidelines.
  **Tier: Cite-by-reference** — cite rule IDs and rationale, never reproduce.
- **TLSF — Masmano, Ripoll, Crespo, Real, "TLSF: a new dynamic memory
  allocator for real-time systems" (ECRTS 2004).** The reference O(1),
  bounded-fragmentation real-time allocator. **Tier: paper —
  Cite-by-reference** (IEEE-published); **implementations — Permissive code**
  (`sysprog21/tlsf-bsd`, `rmind/tlsf` are BSD-licensed).
- **o1heap (Pavel Kirienko).** Constant-complexity deterministic allocator for
  hard real-time / high-integrity embedded. **Tier: Permissive code** (MIT —
  verify) and **Citable** docs.
- **Embedded.com, "Deterministic dynamic memory allocation & fragmentation in
  C & C++."** Accessible treatment of embedded fragmentation control.
  **Tier: Citable.**

### Michael Abrash — *Graphics Programming Black Book*

Verified: released online free in 2001 by Abrash and Dr. Dobb's; the
`jagregory/abrash-black-book` reproduction is published "with the blessing of
Michael Abrash." Caveat: free *access* is granted, but no formal open license
(MIT/CC) is declared. **Tier: Citable for technique; treat text as
Cite-by-reference** — cite and paraphrase, do not assume reproduction rights.
Relevance: the Black Book's value here is cache/data-layout and the
optimization mindset; it has *little direct allocator content*, so it is a
supporting source, not an anchor for `memory`.

## Strongest anchor sources

1. **Drepper, "What Every Programmer Should Know About Memory"** — hardware
   foundation (Citable).
2. **Gregory, *Game Engine Architecture*, Ch. 3 & §6.2** — engine allocator
   taxonomy (Cite-by-reference).
3. **Molecular Musings "Memory allocation strategies" series** — concrete,
   freely-citable linear/stack/pool/page allocator design (Citable).
4. **Lakos, "Local ('Arena') Memory Allocators," CppCon 2017** — arena
   rationale + measured benefit (Citable).
5. **WG21 N3916 + Halpern's PMR talks** — authoritative `std::pmr` design
   intent (Citable).
6. **EASTL `doc/Design.md`** — production allocator-ownership and
   allocator-aware-container model, BSD-licensed (Permissive code).
7. **TLSF paper + BSD implementations** — the real-time, bounded-fragmentation
   reference (paper Cite-by-reference; code Permissive).
8. **AUTOSAR C++14 Guidelines (memory rules)** — embedded/real-time rule
   framing and rationale (Cite-by-reference).

## Cautions

- Verify each code repo's actual LICENSE before treating it as Permissive
  (mimalloc MIT, jemalloc BSD-2, TCMalloc Apache-2.0, EASTL / tlsf-bsd BSD-3
  are expected — confirm at use time).
- cppreference is CC BY-SA — paraphrase rather than paste, to avoid
  license-mixing into this CC BY 4.0 corpus.
- Agner Fog's manuals and the Abrash Black Book are *free to read* but not
  openly licensed — cite, never reproduce.
- GDC Vault content is frequently paywalled; confirm a talk is freely
  available before relying on it.
- There is no widely-cited "Naughty Dog allocator talk." For per-frame scratch
  memory and data-oriented allocation the correct public reference is Mike
  Acton's *Insomniac Games* talk, "Data-Oriented Design and C++" (CppCon 2014).

## Sources

- Abrash, *Graphics Programming Black Book* — <https://github.com/jagregory/abrash-black-book>, <https://www.jagregory.com/abrash-black-book/>
- Drepper, "What Every Programmer Should Know About Memory" — <https://people.freebsd.org/~lstewart/articles/cpumemory.pdf>, <https://lwn.net/Articles/250967/>
- Agner Fog, optimization manuals — <https://www.agner.org/optimize/>
- Gregory, *Game Engine Architecture*, 3rd ed. — <https://www.routledge.com/Game-Engine-Architecture-Third-Edition/Gregory/p/book/9781138035454>
- Molecular Musings — <https://blog.molecular-matters.com/2012/08/14/memory-allocation-strategies-a-linear-allocator/>, <https://blog.molecular-matters.com/2012/08/27/memory-allocation-strategies-a-stack-like-lifo-allocator/>, <https://blog.molecular-matters.com/2012/09/17/memory-allocation-strategies-a-pool-allocator/>
- AnKi 3D — Custom C++ allocators for games — <https://anki3d.org/cpp-allocators-for-games/>
- Ryan Fleury — Untangling Lifetimes: The Arena Allocator — <https://www.rfleury.com/p/untangling-lifetimes-the-arena-allocator>
- Nystrom, *Game Programming Patterns* — <https://gameprogrammingpatterns.com/double-buffer.html>
- Game Developer — Designing and implementing a pool allocator — <https://www.gamedeveloper.com/programming/designing-and-implementing-a-pool-allocator-data-structure-for-memory-management-in-games>
- CppCon 2017 — Bob Steagall, How to Write a Custom Allocator — <https://isocpp.org/blog/2018/08/cppcon-2017-how-to-write-a-custom-allocator-bob-steagall>
- CppCon 2017 — Pablo Halpern, Allocators: The Good Parts (code) — <https://github.com/phalpern/CppCon2017Code>
- WG21 N3916 — Polymorphic Memory Resources — <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2014/n3916.pdf>
- cppreference — std::pmr::polymorphic_allocator — <https://en.cppreference.com/w/cpp/memory/polymorphic_allocator.html>
- isocpp blog — Josuttis, PMR fully described — <https://isocpp.org/blog/2018/10/pmr-polymorphic-memory-resources>
- R. Kaiser — C++17 PMR & STL for Embedded (embo++ 2021) — <https://www.rkaiser.de/wp-content/uploads/2021/03/embo2021-pmr-STL-for-Embedded-Applications-en.pdf>
- EASTL — <https://github.com/electronicarts/EASTL>, <https://github.com/electronicarts/EASTL/blob/master/doc/Design.md>
- Mike Acton — Data-Oriented Design and C++, CppCon 2014 — <https://www.youtube.com/watch?v=rX0ItVEVjHc>
- mimalloc — <https://github.com/microsoft/mimalloc>
- AUTOSAR C++14 Coding Guidelines — <https://www.autosar.org/fileadmin/standards/R17-10_R1.2.0/AP/AUTOSAR_RS_CPP14Guidelines.pdf>
- Embedded.com — Deterministic dynamic memory allocation & fragmentation — <https://www.embedded.com/deterministic-dynamic-memory-allocation-fragmentation-in-c-c/>
- TLSF paper — <https://www.researchgate.net/publication/4080369_TLSF_A_new_dynamic_memory_allocator_for_real-time_systems>; tlsf-bsd — <https://github.com/sysprog21/tlsf-bsd>
- o1heap — <https://github.com/pavel-kirienko/o1heap>
- Red Hat — Configuring huge pages — <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/monitoring_and_managing_system_status_and_performance/configuring-huge-pages_monitoring-and-managing-system-status-and-performance>
- LWN — Transparent huge pages, NUMA locality, and performance regressions — <https://lwn.net/Articles/787434/>
