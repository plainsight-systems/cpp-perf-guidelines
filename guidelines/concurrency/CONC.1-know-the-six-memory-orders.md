+++
id = "CONC.1"
title = "Know the six memory orders and what each costs on x86 versus ARMv8"
category = "concurrency"
status = "draft"
summary = "relaxed, acquire, release, acq_rel, seq_cst (and the deprecated consume) compile to very different code on TSO x86 versus weakly-ordered ARMv8. Default to seq_cst; relax only with proof."
tags = ["atomic", "memory-order", "x86", "arm"]
+++

## Rationale

`std::atomic` operations take an optional `std::memory_order` argument
that defaults to `seq_cst`. The default is correct everywhere and is the
*only* model most humans can reason about — Sutter's "SC-DRF default"
rationale. Relaxing it is a measurable optimization on weakly-ordered
hardware (ARM, POWER, RISC-V), nearly free on TSO hardware (x86_64),
and *always* a proof obligation: the relaxed code must remain
data-race-free under all reorderings the chosen order permits.

The mapping from C++ memory orders to hardware instructions is asymmetric:

| Order | x86_64 (TSO) | ARMv8 | What it buys |
|---|---|---|---|
| `relaxed` | plain `mov` | plain `ldr`/`str` | atomicity only |
| `acquire` | plain `mov` (load is acquire on TSO) | `LDAR` | no later ops reorder before this load |
| `release` | plain `mov` (store is release on TSO) | `STLR` | no earlier ops reorder after this store |
| `acq_rel` | `LOCK`-prefixed RMW | `LDAXR`/`STLXR` loop or `LDADDAL` | both, on a single RMW |
| `seq_cst` | `LOCK XCHG` / `MFENCE` after store | `STLR` + `DMB ISH` or `LDAR` + `DMB ISH` | total order across all SC ops |
| `consume` | (treated as acquire) | (treated as acquire) | **deprecated in practice** |

On x86, `relaxed` / `acquire` / `release` cost the same as plain
load / store for aligned natural-sized scalars — the hardware does not
reorder load–load, load–store, or store–store, only store–load. Only
`seq_cst` stores pay a real cost (an `MFENCE` or a `LOCK` op). On ARMv8
the cost gap between `relaxed` and `seq_cst` is much larger, because the
hardware is weakly ordered and the barriers are real instructions.

`memory_order_consume` was meant to be cheaper than `acquire` for
dependency-ordered reads, but no compiler implements it correctly — every
implementation silently promotes `consume` to `acquire`. P0371 and the
follow-ups deprecate the semantics in practice; do not use it.

## Guidance

- **Default to `seq_cst`.** The default exists because sequential
  consistency is the only model where local reasoning matches behavior.
  Switching off it is the optimization, not the starting position.
- **Use `relaxed`** for counters and statistics where the *value* matters
  but no other state depends on the ordering. Telemetry counters,
  cumulative histograms, performance probes.
- **Use `acquire` / `release`** to publish data across threads — see
  `CONC.2`. The producer stores `release`, the consumer loads `acquire`;
  the pair creates a happens-before edge that makes the producer's prior
  writes visible to the consumer.
- **Use `acq_rel`** on read-modify-write operations whose result is both
  a publication and a consumption (a CAS that hands off both a slot index
  and prior writes).
- **Never use `consume`.** Deprecated in practice; promoted to `acquire`
  by every implementation.
- **Test on the actual target.** Code that works on x86 may break on
  ARMv8 because the x86 hardware gave you barriers for free.

## Example

```cpp
// Telemetry counter — value is observed by other threads but no other
// state depends on it. relaxed is correct and free on x86, ARM, POWER.
std::atomic<std::uint64_t> bytes_received{0};

void on_packet(std::size_t n) {
    bytes_received.fetch_add(n, std::memory_order_relaxed);
}

// Publication pattern — see CONC.2 for the full release/acquire idiom.
// release on the producer side; acquire on the consumer side.
struct Snapshot { /* ... */ };
Snapshot                  current_snapshot;
std::atomic<bool>         snapshot_ready{false};

void produce(const RawData& raw) {
    fill_snapshot(current_snapshot, raw);                       // step 1
    snapshot_ready.store(true, std::memory_order_release);      // step 2: publish
}

void consume() {
    if (snapshot_ready.load(std::memory_order_acquire)) {       // step 3: see step 2
        use_snapshot(current_snapshot);                          // step 4: sees step 1
    }
}

// seq_cst — the default. Use it when reasoning across multiple atomics
// would require a single total order. The cost on ARM is real (a DMB
// barrier on stores); the cost on x86 is one MFENCE per store.
std::atomic<bool> a{false};
std::atomic<bool> b{false};

void thread_a() {
    a.store(true);              // seq_cst by default
    if (!b.load()) do_thing();  // no other thread will see a==false && b==true
}

void thread_b() {
    b.store(true);
    if (!a.load()) do_other();
}
```

## Caveats

- **x86 is friendly; do not test only on x86.** Code that works under
  default `seq_cst` may also work with `relaxed` on x86 because the
  hardware does not reorder the way ARM does. The same code is buggy on
  ARMv8. CI on the target architecture is the only honest verification.
- **`seq_cst` is global.** It establishes a total order across *all*
  `seq_cst` operations in the program, not just those touching the same
  variable. This is what makes it the safe default and what makes it
  expensive — every `seq_cst` store on ARMv8 emits a `DMB ISH`.
- **Mixed orders on the same variable** are legal but rarely what you
  want. Pick one per variable and stick to it.
- **Acquire / release synchronizes one variable.** A release-store on `X`
  paired with an acquire-load on `X` creates an edge through `X` only;
  it says nothing about other atomic variables. For cross-variable
  ordering, use `seq_cst` (or two release-acquire pairs in sequence with
  the right intermediate variable).
- **`consume` looks tempting in the documentation.** It is not. Every
  toolchain compiles it to acquire; the dependency-ordered semantics it
  claims to provide are not delivered.

## References

- ISO C++ working draft, `[intro.races]` and `[atomics]` —
  <https://eel.is/c++draft/intro.races>;
  <https://eel.is/c++draft/atomics>
- Hans-J. Boehm and Sarita V. Adve, "Foundations of the C++ Concurrency
  Memory Model", PLDI 2008 —
  <https://www.hpl.hp.com/techreports/2008/HPL-2008-56.pdf>
- Herb Sutter, *atomic<> Weapons*, C++ and Beyond 2012 —
  <https://herbsutter.com/2013/02/11/atomic-weapons-the-c-memory-model-and-modern-hardware/>
- Jeff Preshing, *Acquire and Release Semantics* —
  <https://preshing.com/20120913/acquire-and-release-semantics/>
- P0371R1 (deprecating `memory_order_consume`) —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2016/p0371r1.html>
- Anthony Williams, *C++ Concurrency in Action* 2e, chapter 5 —
  **cite-by-reference**.
