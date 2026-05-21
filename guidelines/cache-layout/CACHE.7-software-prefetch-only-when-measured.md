+++
id = "CACHE.7"
title = "Use software prefetching only for pointer-chasing or gather — and measure"
category = "cache-layout"
status = "draft"
summary = "Hardware prefetchers handle linear access for free. Software prefetch helps only when measurement proves the hardware cannot predict the pattern."
tags = ["prefetch", "memory-level-parallelism", "perf"]
+++

## Rationale

Modern CPUs have aggressive hardware prefetchers that detect linear and
small-stride memory access and bring lines into cache ahead of demand, at no
software cost. For the common case — a `for` loop over a contiguous array —
software prefetch instructions (`__builtin_prefetch`, `_mm_prefetch`,
`__pld`) are redundant at best.

Software prefetch is useful for the two patterns the hardware cannot
predict:

- **Pointer-chasing** through linked structures (intrusive lists, B-trees,
  graphs, hash probe sequences), where the next address is computable a few
  iterations ahead from a *pointer load* the hardware sees only when the
  current iteration retires.
- **Gathers** indexed by an array of indices the hardware cannot guess.

When misused, software prefetch *hurts* in four measurable ways:

- **Cache pollution.** Prefetching `T0` (all-level) data you do not end up
  using evicts something hot. Use `T1`, `T2`, or `NTA` (non-temporal,
  stream-once) for data you touch once.
- **Bandwidth competition.** On a memory-bound loop, the prefetch and the
  demand miss compete for the same line-fill buffers (~10 outstanding on
  current Intel / AMD cores). Excessive prefetch *reduces* memory-level
  parallelism rather than increasing it.
- **Instruction throughput.** A `prefetch` is an instruction; in a tight loop
  it can push you off a fused-issue boundary or out of the loop buffer.
- **Distance miscalibration.** Prefetching the *next* iteration's line is too
  late — the demand fetch already started. Prefetching 32 iterations ahead
  may exceed working set and waste fill bandwidth on lines you evict before
  using.

Drepper §6.3.4 and Agner Fog's microarchitecture manual converge on the same
discipline: targets, hints, and a measurement before and after.

## Guidance

- **Default to no software prefetch.** For linear or short-stride loops,
  let the hardware prefetcher do its job.
- **Add a prefetch only for** pointer-chasing or gather, and only when a
  profiler has shown the loop stalls on memory.
- **Target one main-memory latency of work between prefetch and use** — on
  current hardware, roughly **100–300 cycles**, which is typically a few
  iterations of a non-trivial loop body.
- **Pick the right hint.** `T0` for hot, reused data. `T1` or `T2` for data
  you will touch once but want in L2/L3. `NTA` (non-temporal access) for
  streaming data you read once and want to bypass the cache hierarchy.
- **Measure before and after.** Run `perf stat -e LLC-loads,LLC-load-misses,
  cycles,instructions` on both versions. If LLC misses do not fall *and* IPC
  does not rise, **remove the prefetch** — it is making things worse.

## Example

```cpp
// Bad: blind prefetch on a contiguous, prefetcher-friendly loop. Adds
// instruction overhead and competes for fill buffers; gains nothing.
void sum_blind(std::span<const std::uint64_t> data, std::uint64_t& out) {
    std::uint64_t s = 0;
    for (std::size_t i = 0; i < data.size(); ++i) {
        __builtin_prefetch(&data[i + 8], 0, 3);   // T0 hint, pointless here
        s += data[i];
    }
    out = s;
}

// Good: pointer-chasing where the next node's address is loaded a few
// iterations ahead — exactly the pattern the hardware prefetcher cannot
// see, because the address comes from a load that depends on a load.
struct Node { Node* next; int value; };

int sum_list(const Node* head) {
    int sum = 0;
    const Node* p = head;
    while (p) {
        // Prefetch the node we will process several hops from here. T2 is a
        // reasonable hint: the line will be touched once shortly.
        if (p->next) __builtin_prefetch(p->next->next, 0, 1);
        sum += p->value;
        p = p->next;
    }
    return sum;
}

// Good: indexed gather with software prefetch, distance tuned to ~one
// main-memory latency. The HW prefetcher cannot see the indirection.
int gather_sum(std::span<const int>      values,
               std::span<const std::uint32_t> indices) {
    constexpr std::size_t kAhead = 16;   // tune per platform; measure
    int sum = 0;
    for (std::size_t i = 0; i < indices.size(); ++i) {
        if (i + kAhead < indices.size()) {
            __builtin_prefetch(&values[indices[i + kAhead]], 0, 1);
        }
        sum += values[indices[i]];
    }
    return sum;
}
```

## Caveats

- **Hardware prefetcher capability is CPU-specific.** Skylake-class cores
  detect more patterns than the in-order cores you target on a console. What
  is redundant on a desktop may be load-bearing on an embedded target.
  Profile on every target you care about.
- **`__builtin_prefetch` is a hint.** The compiler is free to drop it. On
  some platforms `_mm_prefetch` or platform-specific intrinsics emit the
  exact instruction you intended.
- **Non-temporal stores are a separate technique.** They bypass cache on
  *writes*, not reads, and have their own discipline (alignment, fence
  ordering). This guideline is about read prefetch.
- **Prefetch is not a substitute for layout.** Fixing the data layout
  (`CACHE.3`–`CACHE.6`) typically wins more than any prefetch, with no
  per-target tuning.

## References

- Ulrich Drepper, *What Every Programmer Should Know About Memory*, §6.3.4
  (prefetching) —
  <https://people.freebsd.org/~lstewart/articles/cpumemory.pdf>
- Agner Fog, *Optimizing Software in C++* and the microarchitecture manual
  — <https://www.agner.org/optimize/>
- Intel 64 / IA-32 Architectures Optimization Reference Manual —
  <https://www.intel.com/content/www/us/en/develop/download/intel-64-and-ia-32-architectures-optimization-reference-manual.html>
- GCC, `__builtin_prefetch` —
  <https://gcc.gnu.org/onlinedocs/gcc/Other-Builtins.html#index-_005f_005fbuiltin_005fprefetch>
