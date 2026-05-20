# Data Layout for the Cache Hierarchy — Technique Extraction

Research note — 2026-05-20. Supports packet
`2026-05-20-cache-layout-category-buildout`. Technique-extraction pass for the
`cache-layout` category — what each source actually teaches (the technique,
the anti-pattern, the measurement), not bibliography. `CACHE.1` (false
sharing) already exists as a seed; this note covers everything else in scope.
Sources are classified per the `CONTRIBUTING.md` sourcing rule:

- **Citable** — free public talk / paper / blog (link is the citation).
- **Cite-by-reference** — copyrighted book; reference by item, do not quote.
- **Study-only code** — proprietary or non-permissive source; read but do not
  copy.
- **Permissive code** — MIT / BSD / Apache-2.0 / similar; quotable with
  attribution.

---

## 1. The cache as a constraint on data layout — foundational framing

Mike Acton's *Data-Oriented Design and C++* (CppCon 2014, **Citable**) is the
load-bearing talk. The framing — "the purpose of all programs is to transform
data; if you don't understand the data, you don't understand the problem" —
is downstream of one hardware fact: an L2 miss to main memory on the talk's
PS4 target costs ~200 cycles, during which an in-order core retires ~600
nops. Acton's three "lies of OOP" all reduce to cache lies: "software is a
platform" hides the actual machine; "code designs around a model of the
world" hides the actual data shapes; "code is more important than data"
inverts what the hardware optimises for.

**Technique extracted:** start every design from "what does the data look
like, in bulk, on this hardware?" — count bytes per element, elements per
cache line, lines per working set; then choose containers and access pattern.
His `BoundingSphere` example is the canonical hot/cold split: a `Visibility`
system needs only the sphere centre, radius, and an "is visible" bit, so
extracting those off the fat `GameObject` collapses the working set by an
order of magnitude.

Stoyan Nikolov, *OOP Is Dead, Long Live Data-oriented Design* (CppCon 2018,
**Citable**) — the Hummingbird / Coherent Labs browser-engine redesign. Rare
because it reports measured before/after numbers on a real shipping product,
not a microbenchmark. The DOM / style / layout pipeline rebuilt around
contiguous arrays of POD records (instead of polymorphic `DOMNode`
hierarchies) ran the layout phase 2–3× faster with much smaller binary size;
Nikolov attributes the win to predictable linear access and the eliminated
vtable load on every node touch.

**Technique extracted:** even in a "tree" domain (DOM), the *traversal* is a
stream over a contiguous pool indexed by handle; the tree is structure, the
layout is array.

Richard Fabian, *Data-Oriented Design* (free online book, **Citable**) — the
canonical DOD reference. Key items beyond Acton: (a) the "existential
processing" pattern — sort entities by which system applies to them so hot
loops never branch on "does this apply?"; (b) explicit advocacy of
table-shaped data ("rows are entities, columns are properties; iterate
columns"), which is SoA in disguise; (c) boolean flags should be bitsets at
the column level, not `bool` members per row.

## 2. AoS vs SoA vs AoSoA — when each wins

The mechanical rule, drawn from Drepper §6, Agner Fog's microarchitecture
manual, and Fabian:

| Pattern | Wins when |
| --- | --- |
| **AoS** (`struct { x, y, z, ... }; vector<T>`) | Per-element work touches **most fields together** and the struct fits in O(1) cache lines. "One object's worth of work at a time" code. |
| **SoA** (`struct { vector<float> x; vector<float> y; ... }`) | A loop touches a **subset** of fields across many elements (the canonical DOD case), or you want vectorisation: contiguous `x[]` autovectorises; `xyz[].x` does not without a gather. |
| **AoSoA** (blocks of N elements, each block laid out SoA) | You want SIMD width (4/8/16 lanes) **and** locality of all fields for one block. The chunk size matches the vector width (or a small multiple) so one block fits in a few cache lines. |

Unity DOTS / Burst public talks (Joachim Ante, Unite 2018–19, **Citable**;
engine itself **Study-only**) formalise AoSoA as the *chunk*: a 16 KiB block
holding one archetype's components, each component stored as a contiguous
column inside the chunk. 16 KiB is chosen so a chunk's hot columns fit in L1
(typically 32 KiB) with room for the loop's other working state.

**Technique extracted:** the chunk size is a tuning knob against L1 capacity,
not a language artefact.

EnTT (BSD-2, **Permissive code**) uses a different formalisation: a
sparse-set per component type, each backed by a dense `std::vector<Component>`.
Iteration over a single component is pure AoS over the dense array; iteration
over N components uses the smallest dense array as the driver and indexes
into the others. The discipline: never iterate by entity identity, always by
component pool.

Unreal's Mass Entity framework (Epic, **Study-only code**; public docs
**Citable**) chose chunk-based AoSoA much closer to DOTS than to EnTT —
fragments live in ~64 KiB chunks per archetype. Plain `UObject` actors remain
AoS-of-pointers (the legacy world); Mass exists specifically for cases where
that fails to scale.

## 3. Cache line size, alignment, and `hardware_destructive_interference_size`

Concrete numbers: **64 B cache lines on x86-64** (Intel since Pentium 4, AMD
since K8) and on **AArch64** (ARMv8) including Apple Silicon, PS4 / PS5,
Xbox One / Series. The historical exceptions matter:

- **Intel's spatial prefetcher pairs lines**, so on Sandy Bridge through
  current cores destructive interference effectively spans **128 B** even
  though the L1 line is 64 B — the rationale libstdc++ gives for
  `std::hardware_destructive_interference_size == 128` on x86-64 (GCC).
- **Older PowerPC** (Xbox 360, PS3 PPU) used 128 B.
- **ARM Cortex-A** cores are typically 64 B; some server parts and the Apple
  M1/M2 L2 use 128 B.

**Technique extracted:** never hardcode 64; for portability use
`std::hardware_destructive_interference_size` for *padding* (`CACHE.1`'s
case) and `std::hardware_constructive_interference_size` for *grouping*.

The controversy (P0154, Giroux; later P1822; GCC #89370, **Citable**): the
values are implementation-defined and ABI-affecting, so changing them is an
ABI break. libstdc++ on x86-64 emits a noisy warning when these are
referenced from a non-inline context; libc++ until recently did not provide
them at all. **Honest portability story:** treat them as compile-time hints
worth using *inside a translation unit*, but do not expose them across ABI
boundaries (do not embed them in a public type's `alignas`). For an
ABI-stable class, use a concrete `alignas(64)` (or `alignas(128)` if you
target Intel server) and document the assumption.

`alignas` is needed beyond the false-sharing case for: SIMD types where the
ISA requires natural alignment (`_mm256` 32 B, `_mm512` 64 B); DMA buffers on
embedded targets (32–128 B boundaries); atomic types whose lock-free
guarantee depends on alignment (`std::atomic<T>::is_always_lock_free` plus
natural alignment); avoiding split-line accesses for 16 B `long double` /
`__int128`.

## 4. Struct padding, ordering, and hot/cold splitting

Field order materially affects size whenever a struct mixes widths:

```cpp
struct Bad  { char a; double b; char c; };   // 24 B (7 + 0 + 7 padding)
struct Good { double b; char a; char c; };   // 16 B
```

On a 64 B line you fit two `Bad` versus four `Good`. **Rule** (Drepper §6.2.1;
Fog *Optimizing C++* ch. 9): order fields largest-alignment-first; group
fields touched together adjacently so they share a line; put rarely-touched
fields last (or push them to a separate cold struct entirely).

Hot / cold splitting is the same idea taken further: extract the fields
touched on the hot path into one struct (the "hot half") indexed parallel to
the original, and leave the rest behind. **Cost:** an extra indirection or
parallel-array bookkeeping, and a correctness burden — the two halves must
stay in lockstep on insert / delete. Do it only when (i) the hot half is
≤ ~25–50 % of the original size, (ii) the hot loop is measurably memory-bound,
and (iii) the parallel bookkeeping is amortised over many iterations.

Niklas Gray's Bitsquid / Our Machinery blog posts (**Citable**) make this
concrete with engine examples — e.g. splitting `Transform` into a
"dirty bit + parent index" hot column and a "local TRS + world TRS" cold
column.

## 5. The vector-vs-list cache argument

Stroustrup (*Why You Should Avoid Linked Lists*, GoingNative 2012,
**Citable**) and Chandler Carruth (*Efficiency with Algorithms, Performance
with Data Structures*, CppCon 2014, **Citable**) make the same demonstration:
insert N random integers keeping the sequence sorted, using `std::vector<int>`
versus `std::list<int>`. The vector wins by 1–2 orders of magnitude across
the entire range Stroustrup measured (a few hundred to ~500 000 elements),
and the crossover point where list "should" win (because vector's O(N) shift
dominates list's O(1) insert) never arrives in practice.

The reason: list traversal pays a cache miss per node (~100–300 cycles);
vector's shift is a streaming `memmove` the hardware prefetcher handles
trivially (a few cycles per element). Carruth's stronger claim: `std::list`
and `std::map` are almost never the right answer. If you need ordering, sort
a vector; if you need keyed lookup, prefer a flat-hash table or a sorted
vector + binary search.

**Technique extracted:** "O()" without a cache model is misleading; the
constants on memory access dominate at every practical N.

## 6. Software prefetching — when it helps and when it hurts

Drepper §6.3.4 and Fog converge: hardware prefetchers handle linear and
small-stride patterns perfectly; software prefetch is only useful for (a)
pointer-chasing where the next address is computable a few iterations ahead
(linked structures, hash probe sequences), and (b) gather patterns the HW
prefetcher will not detect.

How `__builtin_prefetch` (and `_mm_prefetch`) **hurts**:

- **Cache pollution.** Prefetching `T0` (all-levels) data you do not end up
  using evicts hot lines. Prefer `T1` / `T2` / `NTA` hints when the line is
  touched once.
- **Bandwidth competition.** On a memory-bound loop, the prefetch and the
  demand miss compete for the same fill buffers (~10 outstanding on Skylake /
  Zen 3); excessive prefetch *reduces* effective memory-level parallelism.
- **Instruction throughput.** The prefetch itself is an instruction — on a
  tight loop it can push you off a fused-issue boundary or out of the loop
  buffer.
- **Distance miscalibration.** Prefetching the next iteration's line is too
  late (the line is already coming); prefetching 32 iterations ahead may
  exceed the working set and waste fetches.

**Rule of thumb:** target ~100–300 cycles of work between prefetch and use
(one main-memory latency). Measure with `perf stat -e LLC-loads,LLC-load-misses`
before and after — if LLC misses do not fall *and* IPC does not rise, remove
the prefetch.

## 7. Cache-miss taxonomy and how to distinguish in a profiler

The textbook 3C taxonomy (Hill & Smith, IEEE TC 1989, **Citable**):

- **Compulsory** — first touch of a line. Reduced only by prefetching or by
  touching less data.
- **Capacity** — working set exceeds cache. Reduced by blocking / tiling or
  by shrinking elements (this is where hot / cold pays off).
- **Conflict** — set-associativity collisions (a stride that hits the same
  set repeatedly, e.g. power-of-two row pitch in image processing). Reduced
  by padding the stride off the bad power of two.

Distinguishing them in practice:

- `perf stat -e cache-references,cache-misses,LLC-loads,LLC-load-misses`
  gives the raw rate.
- `perf c2c` (Linux ≥ 4.10) attributes HITM events to specific cache lines —
  the canonical tool for *false sharing*, and by extension conflict patterns.
- Intel VTune's Memory Access analysis decomposes stalls into L1 / L2 / LLC /
  DRAM bound; the "loaded latency" view directly identifies capacity vs.
  conflict pressure. AMD uProf has comparable PMU plumbing.
- Heuristic: vary working-set size. If miss rate jumps at a specific size
  matching a cache level, it is capacity. If miss rate is high but
  independent of size and stride is a power of two, it is conflict. If miss
  rate is one-per-line on the first sweep and zero on the second sweep over
  the same data, it was compulsory.

## 8. Honest gaps

- The prior memory-category research mentioned a "Notre Dame DOD talk" that I
  cannot verify exists; the canonical DOD reference set is Acton, Nikolov,
  Fabian, Gray.
- Andrei Alexandrescu's CppCon talks bear on branch prediction and
  small-string layout more than on the cache-hierarchy techniques in this
  category — useful, but tangential.
- Console-specific cache numbers (PS5, Xbox Series) live in NDA SDK docs; the
  public statements only confirm 64 B lines and AArch64-class hierarchies.

## Sources

- Mike Acton, *Data-Oriented Design and C++*, CppCon 2014 —
  <https://www.youtube.com/watch?v=rX0ItVEVjHc>
- Stoyan Nikolov, *OOP Is Dead, Long Live Data-oriented Design*, CppCon 2018
  — <https://www.youtube.com/watch?v=yy8jQgmhbAU>
- Chandler Carruth, *Efficiency with Algorithms, Performance with Data
  Structures*, CppCon 2014 —
  <https://www.youtube.com/watch?v=fHNmRkzxHWs>
- Bjarne Stroustrup, *C++11 Style* / "Why you should avoid Linked Lists",
  GoingNative 2012 —
  <https://channel9.msdn.com/Events/GoingNative/GoingNative-2012/Keynote-Bjarne-Stroustrup-Cpp11-Style>
- Richard Fabian, *Data-Oriented Design* (book, free online) —
  <https://www.dataorienteddesign.com/dodbook/>
- Niklas Gray, Bitsquid / Our Machinery blog archive —
  <https://bitsquid.blogspot.com/> ;
  <https://ruby0x1.github.io/machinery_blog_archive/>
- Ulrich Drepper, *What Every Programmer Should Know About Memory* —
  <https://people.freebsd.org/~lstewart/articles/cpumemory.pdf>
- Agner Fog, optimization manuals (microarchitecture; optimizing C++) —
  <https://www.agner.org/optimize/>
- Joachim Ante, Unity DOTS talks (Unite Copenhagen 2019) —
  <https://www.youtube.com/watch?v=tGmnZdY5Y-E>
- EnTT (Michele Caini, BSD-2) — <https://github.com/skypjack/entt>;
  sparse-set storage in `entt/src/entt/entity/storage.hpp`.
- Unreal Mass Entity documentation —
  <https://docs.unrealengine.com/5.0/en-US/overview-of-mass-entity-in-unreal-engine/>
- P0154R1 (Giroux), `hardware_destructive_interference_size` —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2016/p0154r1.html>
- libstdc++ ABI concerns / GCC #89370 —
  <https://gcc.gnu.org/bugzilla/show_bug.cgi?id=89370>
- Mark D. Hill, Alan Jay Smith, *Evaluating Associativity in CPU Caches*
  (3C model), IEEE TC 1989 —
  <https://research.cs.wisc.edu/multifacet/papers/ieeetc89_3csmodel.pdf>
- Joe Mario, "C2C: False Sharing Detection in Linux Perf" —
  <https://joemario.github.io/blog/2016/09/01/c2c-blog/>
- Intel 64 / IA-32 Architectures Optimization Reference Manual —
  <https://www.intel.com/content/www/us/en/develop/download/intel-64-and-ia-32-architectures-optimization-reference-manual.html>
- ARM Cortex-A Series Programmer's Guide (cache organisation) —
  <https://developer.arm.com/documentation/den0024/latest/>
- Jason Gregory, *Game Engine Architecture* (3rd ed.), memory & data-layout
  chapter — **Cite-by-reference**.
