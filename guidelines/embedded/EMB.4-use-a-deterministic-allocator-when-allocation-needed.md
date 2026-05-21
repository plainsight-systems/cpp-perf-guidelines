+++
id = "EMB.4"
title = "When dynamic allocation is unavoidable, use a deterministic allocator and size the worst case"
category = "embedded"
status = "draft"
summary = "When dynamic lifetimes are unavoidable, use a bounded-fragmentation deterministic allocator such as TLSF or o1heap, sized offline."
tags = ["tlsf", "o1heap", "deterministic-allocation", "real-time"]
+++

## Rationale

`MEM.9` and `EMB.1` push toward "no allocation in the steady state."
Sometimes that boundary is genuinely impossible to hold. A CAN / UAVCAN
stack reassembling multi-frame messages, an IP stack fragmenting packets, a
log subsystem batching variable-sized records — these have data structures
whose sizes are known only at runtime and whose lifetimes do not nest.
Forcing them into fixed-capacity containers either wastes RAM at the
worst-case-times-N scale or fails on a perfectly valid input.

A general-purpose `malloc` is still the wrong answer. Two failure modes
disqualify it:

- **Worst-case latency is unbounded.** A free-list walk on a heavily
  fragmented heap can run for thousands of cycles; WCET tools cannot bound
  it. A real-time deadline disappears the first time the allocator picks
  the wrong free block.
- **Fragmentation is unbounded over time.** Decades-running embedded
  systems with general `malloc` accumulate fragmentation until an
  allocation that should succeed fails — the OOM-with-free-memory failure
  mode.

The fix is a **constant-time, bounded-fragmentation** allocator. Two are
production-real:

- **TLSF (Two-Level Segregated Fit)** — Masmano / Ripoll / Crespo / Real,
  ECRTS 2004. The reference real-time allocator. O(1) `malloc` and `free`;
  fragmentation provably bounded by a small constant factor times the
  largest live block. Mature implementations in BSD-licensed C
  (`mattconte/tlsf`, `sysprog21/tlsf-bsd`).
- **o1heap** — Pavel Kirienko, MIT. About 500 lines, designed to be read
  end-to-end during a safety review. O(1), used by OpenCyphal's libcanard
  and libudpard. The smallness *is* the design — auditability for
  high-integrity targets.

Even with TLSF / o1heap, you size the worst case offline, prove the arena
is large enough, and treat OOM as a fault — not a recoverable condition.

## Guidance

- **Default first to static or fixed-capacity allocation** (`EMB.2`,
  `MEM.9`). Only when those genuinely cannot bound the data — a protocol
  layer with variable-shape lifetimes — do you reach for a dynamic
  allocator.
- **Choose TLSF or o1heap by audit and footprint:**
  - **TLSF** — battle-tested, multiple production implementations, more
    features. Use when you want a known-good O(1) allocator and code size
    is not the binding constraint.
  - **o1heap** — minimal, auditable in one sitting, designed for
    high-integrity. Use when the reviewer of last resort is a human
    reading the allocator source.
- **Size the arena offline.** Identify the worst-case live working set
  through analysis, profiling under representative load, or both. Add a
  margin; document it.
- **Treat OOM as a fault**, not as an error to recover from. The arena is
  sized; running out means the sizing analysis was wrong or the input is
  out of spec. Trigger the platform's safe state.
- **Wrap behind the `EMB.1` / `MEM.6` allocator interface** so the rest of
  the system uses one abstraction and the allocator choice stays
  swappable.
- **Do not mix general-purpose `malloc` and a deterministic allocator** in
  the same address space. If the bring-up runtime uses `malloc` for
  init-phase, switch off the heap before the steady-state loop starts.

## Example

```cpp
// Use o1heap's C API behind a project-local Allocator interface (see MEM.6).
// The rest of the system depends on Allocator; the allocator implementation
// is the one swappable concern.
class O1HeapAllocator : public Allocator {   // Allocator from MEM.6
public:
    // arena_size is chosen offline from a worst-case-demand analysis,
    // with margin documented in the project's WCET / sizing report.
    explicit O1HeapAllocator(void* arena, std::size_t arena_size) noexcept
        : heap_{o1heapInit(arena, arena_size, /*lock*/nullptr, /*unlock*/nullptr)} {
        // o1heapInit returns nullptr if the arena is too small or
        // misaligned — treat as a startup fault.
    }

    void* allocate(std::size_t size, std::size_t /*align*/) override {
        void* p = o1heapAllocate(heap_, size);
        // Failure here is a sized-arena overrun: trip the platform's safe
        // state. Returning nullptr to callers that are not designed to
        // handle it is a deferred fault.
        if (!p) on_oom_fault();
        return p;
    }

    void deallocate(void* p) noexcept override {
        o1heapFree(heap_, p);
    }

private:
    O1HeapInstance* heap_;
};

// Worst-case sizing documented at the construction site, not buried in a
// generic helper. The constant is project policy — derived from analysis
// plus margin — not a guess.
static constexpr std::size_t kCanReassemblyArenaBytes = 32 * 1024;
alignas(O1HEAP_ALIGNMENT) std::byte can_arena[kCanReassemblyArenaBytes];

static O1HeapAllocator can_allocator{can_arena, sizeof(can_arena)};
```

## Caveats

- **Deterministic allocators add a WCET term, not zero cost.** O(1) means
  the bound is a small constant — for TLSF, a few dozen cycles on typical
  ARMv7 cores. Static or fixed-capacity allocation has *no* runtime cost
  at all. The deterministic allocator is the right tool only when the
  alternative is worse.
- **Bounded fragmentation is not zero fragmentation.** Size the arena with
  margin (typical guidance: 1.5–2 × the analysed worst-case live demand,
  documented). An under-sized arena fragments fatally just like a general
  heap, only with a tighter bound.
- **Multi-threaded / ISR access** introduces a lock dimension TLSF and
  o1heap do not solve for you. Either give each thread its own arena
  (preferred — eliminates the lock) or wrap the allocator in a
  priority-inheritance mutex (and add the mutex's worst case to WCET).
- **Implementation choice matters.** TLSF has multiple BSD implementations
  with different feature sets; pick one and pin its version. o1heap is a
  single repo; review the version you ship.
- **Audit the boundary.** It is easy to call the deterministic allocator
  in one place and `malloc` in another via a transitive library
  dependency. Audit linked libraries; redirect or rebuild as needed.

## References

- M. Masmano, I. Ripoll, A. Crespo, J. Real, "TLSF: A New Dynamic Memory
  Allocator for Real-Time Systems", ECRTS 2004 —
  <https://www.gii.upv.es/tlsf/files/ecrts04_tlsf.pdf>
- TLSF implementations (BSD) — <https://github.com/mattconte/tlsf>;
  <https://github.com/sysprog21/tlsf-bsd>;
  <https://github.com/rmind/tlsf>
- o1heap (MIT) — <https://github.com/pavel-kirienko/o1heap>
- libcanard / libudpard — production consumers of o1heap —
  <https://github.com/OpenCyphal/libcanard>;
  <https://github.com/OpenCyphal/libudpard>
- Embedded.com, "Deterministic dynamic memory allocation & fragmentation
  in C & C++" —
  <https://www.embedded.com/deterministic-dynamic-memory-allocation-fragmentation-in-c-c/>
- Cross-reference: `MEM.9` (allocate at init), `MEM.6` (one allocator
  interface), `EMB.1` (certification implications of allocating at all).
