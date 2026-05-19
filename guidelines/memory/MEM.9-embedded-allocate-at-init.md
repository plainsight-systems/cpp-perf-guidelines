+++
id = "MEM.9"
title = "Embedded: allocate at init, not in steady state"
category = "memory"
status = "draft"
summary = "In embedded and real-time systems, do all dynamic allocation during a bounded init phase and run the steady state with a fixed memory footprint — no heap calls on the hot path."
tags = ["embedded", "fixed-capacity-container", "allocator"]
+++

## Rationale

In embedded, real-time, and safety-critical systems, dynamic allocation in the
steady state is a hazard on three counts. It can **fail** — the heap can be
exhausted, and a real-time loop usually has no meaningful way to recover. It
**fragments** — over a long uptime, a general heap degrades until a request
fails despite ample free memory. And it is **not deterministic in time** — the
worst-case duration of `malloc`/`free` is unbounded, which breaks worst-case
execution time (WCET) analysis.

This is why MISRA C++ has historically banned heap allocation outright, and why
AUTOSAR C++14 permits it only under strict, reviewed rules. The discipline that
satisfies both: confine all dynamic allocation to a bounded **initialization
phase**, then run the steady state with a **fixed memory footprint** — no
`new`, `malloc`, or `free` on the hot path.

This does not forbid the allocators in this category — it schedules them.
Pools, arenas, and buffers are *built* during init, sized to worst case, and
then *drawn from* during the real-time loop without touching the heap.

## Guidance

- **Allocate everything during init.** Construct pools (`MEM.2`), arenas, and
  fixed-capacity buffers before the real-time loop starts, each sized to its
  worst case.
- **In steady state, draw only from those fixed structures.** Use
  fixed-capacity containers (`etl`, EASTL `fixed_*`, or `std::array`-backed
  types) and object pools. No heap call appears on the hot path.
- **If steady-state dynamic allocation is genuinely unavoidable**, use a
  *deterministic* allocator — TLSF (O(1), bounded fragmentation) or o1heap
  (constant-complexity, designed for high-integrity systems) — never a
  general-purpose `malloc`.
- **Make "no allocation after init" a checked invariant.** Flip a global flag
  when init ends; in a debug build, route `operator new` through a check that
  traps if it is called after the flag is set. A hope becomes a test.

## Example

```cpp
// An allocation gate. Dynamic allocation is expected only during the
// initialization phase; after init, a debug build traps on any heap
// allocation — turning "no allocation in steady state" into a checked
// invariant rather than a hope. In release builds the override is absent
// and there is zero overhead.
namespace alloc_gate {
    inline bool init_phase = true;                 // true until the RT loop starts
    inline void close() noexcept { init_phase = false; }
}

#if defined(EMBEDDED_DEBUG_ALLOC_GATE)
void* operator new(std::size_t size) {
    if (!alloc_gate::init_phase) {
        trap("heap allocation after init phase");  // assert / hardware breakpoint
    }
    void* p = std::malloc(size);
    if (!p) throw std::bad_alloc{};
    return p;
}
// ... matching operator delete, and the array forms ...
#endif

void run() {
    ParticlePool pool{/* worst-case capacity */};   // allocated during init
    alloc_gate::close();                             // steady state begins

    while (running()) {                              // the real-time loop:
        Particle* p = pool.acquire();                //   draws from the pool
        // ... no new, no malloc, no free on this path ...
    }
}
```

## Caveats

- **Worst-case sizing is a hard commitment.** Size too small and the system
  fails; too large and RAM is wasted. This is the point: the problem moves to
  sizing *analysis*, which — unlike steady-state heap behavior — can actually
  be analyzed.
- **The gate is a debug aid.** It must not change release behavior; keep it
  fully behind the build flag, and make the flag obvious.
- **Audit third-party code.** Libraries — and parts of the standard library,
  such as exceptions or `std::function` — may allocate internally. "No
  allocation after init" holds only if everything on the path honors it.
- Disabling exceptions and RTTI is a related but separate embedded concern
  (see the `embedded` category).

## References

- AUTOSAR C++14 Coding Guidelines — dynamic-memory rules and rationale —
  <https://www.autosar.org/fileadmin/standards/R17-10_R1.2.0/AP/AUTOSAR_RS_CPP14Guidelines.pdf>
- M. Masmano et al., "TLSF: a new dynamic memory allocator for real-time
  systems", ECRTS 2004.
- o1heap — a constant-complexity deterministic allocator —
  <https://github.com/pavel-kirienko/o1heap>
- "Deterministic dynamic memory allocation & fragmentation in C & C++",
  Embedded.com —
  <https://www.embedded.com/deterministic-dynamic-memory-allocation-fragmentation-in-c-c/>
