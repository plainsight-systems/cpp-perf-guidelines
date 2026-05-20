+++
id = "CONC.2"
title = "Pair release-store with acquire-load to publish data across threads"
category = "concurrency"
status = "draft"
summary = "The canonical cross-thread publication pattern. Producer fills data, then release-stores a ready flag; consumer acquire-loads the flag and is guaranteed to see all prior producer writes."
tags = ["atomic", "memory-order", "publication", "synchronization"]
+++

## Rationale

The C++ memory model's central guarantee is the **release / acquire
synchronizes-with edge**: a `release` store on an atomic, observed by a
matching `acquire` load on the *same* atomic, makes every write the
producer made *before* the release visible to every read the consumer
makes *after* the acquire. This is the primitive that lets you hand off
arbitrary non-atomic state between threads without sequential consistency
on every access — the smallest, cheapest synchronization edge the
language offers above `relaxed`.

The pattern matches the way humans think about producer / consumer
hand-off:

1. Producer prepares the data (plain, non-atomic writes).
2. Producer signals readiness with an atomic `release` store.
3. Consumer checks readiness with an atomic `acquire` load.
4. If the acquire saw the release, the consumer is guaranteed to see the
   producer's step-1 writes.

On x86 (TSO), this compiles to plain loads and stores — the hardware
already gives you these orderings for free. On ARMv8, it compiles to
`STLR` (release store) and `LDAR` (acquire load) — one-shot ordered
instructions added precisely to make this pattern fast.

Sutter's "publication / consumption" idiom and Williams's release-sequence
chapter both centre on this pattern. It is the building block beneath
SPSC queues (`CONC.5`), one-shot lazy initialization, and almost every
other publication scheme.

## Guidance

When one thread prepares data and another reads it:

- **Producer:** complete every write to the data (plain, non-atomic),
  then `flag.store(true, std::memory_order_release)`.
- **Consumer:** `if (flag.load(std::memory_order_acquire))`, then read
  the data through ordinary non-atomic loads. The acquire creates the
  edge; the consumer sees everything the producer wrote before its
  release.
- **One atomic, one publication.** The release / acquire pair
  synchronizes *that one variable*. To publish two unrelated data
  bundles, use two different atomic flags (and two release / acquire
  pairs).
- **Do not relax to `relaxed` and add a fence "to compensate."**
  `std::atomic_thread_fence` exists and works, but the per-operation
  `acquire` / `release` is clearer, locally provable, and exactly what
  the optimizer can reason about.
- **Reuse requires care.** A flag set once and read once is the easy
  case. A flag toggled repeatedly between producer and consumer needs
  the SPSC ring-buffer treatment (`CONC.5`), not a single release /
  acquire pair.
- **For a published *pointer* to immutable data**, the release-store of
  the pointer is sufficient. Readers acquire-load the pointer and may
  then access `*p` non-atomically. This is the read-only-after-publication
  idiom; pair with reference counting or RCU for reclamation
  (`CONC.6`).

## Example

```cpp
// Publication of a precomputed table. The producer fills the table on
// startup; the consumer threads read it forever after. Plain writes
// inside the table; release-store of the pointer; acquire-load by
// readers.
struct Lookup {
    std::array<float, 4096> sine;
    std::array<float, 4096> cosine;
};

inline std::atomic<const Lookup*> g_lookup{nullptr};

void initialise_lookup_on_main_thread() {
    auto* t = new Lookup{};                 // non-atomic writes
    for (std::size_t i = 0; i < t->sine.size(); ++i) {
        t->sine[i]   = std::sin(2 * std::numbers::pi * float(i) / t->sine.size());
        t->cosine[i] = std::cos(2 * std::numbers::pi * float(i) / t->cosine.size());
    }
    g_lookup.store(t, std::memory_order_release);   // publish
}

// Any worker thread, after main has called the initializer:
float lookup_sin(std::size_t i) {
    const auto* t = g_lookup.load(std::memory_order_acquire);   // observe
    return t ? t->sine[i] : 0.0f;
    // Reading t->sine[i] non-atomically is safe — the acquire guarantees
    // we see every write the producer made before its release.
}

// A common bug: relaxing both sides. With relaxed on both, the consumer
// may see `flag == true` BEFORE seeing the producer's writes to the data,
// and read garbage.
//
//   g_lookup.store(t,  std::memory_order_relaxed);   // BAD
//   const auto* t = g_lookup.load(std::memory_order_relaxed);
//   /* reads through t are NOT synchronized */
```

## Caveats

- **Both sides must agree on the variable.** A release on `X` paired
  with an acquire on `Y` synchronizes nothing.
- **The edge is one-way.** The release happens-before the matching
  acquire — *not* the other way. The consumer's writes after the acquire
  are not synchronized back to the producer; that requires its own
  release / acquire in the reverse direction.
- **Acquire / release does not bind across variables.** If the producer
  writes data `A` and then release-stores flag `X`, and the consumer
  acquire-loads flag `X` and then reads data `B` (different variable
  with no producer write before the release), the consumer's view of `B`
  is *not* constrained by the edge.
- **`std::atomic_thread_fence(std::memory_order_release)` plus a
  `relaxed` store** is equivalent for hand-rolled cases but harder to
  reason about. Prefer the per-op form.
- **For multi-step publication** (e.g. fill data, publish a generation
  counter, consumer checks generation), still build it from
  release / acquire pairs — one per atomic — rather than reaching for
  `seq_cst` everywhere.

## References

- ISO C++ working draft, `[intro.races]` (release sequence, synchronizes-
  with) — <https://eel.is/c++draft/intro.races>
- Herb Sutter, *atomic<> Weapons* — the publication / consumption pattern
  — <https://herbsutter.com/2013/02/11/atomic-weapons-the-c-memory-model-and-modern-hardware/>
- Jeff Preshing, *Acquire and Release Semantics* —
  <https://preshing.com/20120913/acquire-and-release-semantics/>
- Anthony Williams, *C++ Concurrency in Action* 2e, chapter 5
  (release sequences, publication) — **cite-by-reference**.
- cppreference, `std::memory_order` —
  <https://en.cppreference.com/w/cpp/atomic/memory_order>
