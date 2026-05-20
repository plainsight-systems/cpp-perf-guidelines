+++
id = "GEN.2"
title = "Pick branchless versus predicted branch by predictability and dependency, not aesthetic"
category = "codegen"
status = "draft"
summary = "Modern branch predictors are 95-99% accurate on stable patterns; a predicted branch is effectively free. Branchless code (cmov, csel, bitmask) wins on unpredictable data and short bodies; it loses on predictable branches because cmov serialises the dependency chain."
tags = ["branchless", "cmov", "branch-prediction", "data-dependent-latency"]
+++

## Rationale

There is a folk belief that branchless code is "always faster than
branchy" code. It is not. Modern branch predictors are remarkably good:
95–99 % accuracy on stable patterns is normal, and a correctly-predicted
branch executes with effectively zero latency on the right path while
the out-of-order machine speculates past it. A `cmov` / `csel` /
bitmask-and-OR sequence, by contrast, runs both sides of the conditional
*and* introduces a data dependency on the condition into the result
register — the OoO machine cannot speculate past it.

The two regimes:

- **Predictable data, simple body** → predicted branch wins. The
  predicted side runs at full throughput; the dependency chain is
  broken by the branch.
- **Unpredictable data, simple body** → branchless wins. Each mispredict
  on x86 costs ~15–20 cycles (Skylake-class and later), comparable on
  Apple M-series and recent Zen, ~10–15 cycles on Cortex-A. Branchless
  pays a few cycles for the `cmov` and serialises through it.
- **Long body either way** → branch is the right tool. Branchless
  versions become expensive or impossible; the body's runtime
  dominates the mispredict cost.
- **Embedded short pipelines** (Cortex-M3 / M4) → the mispredict
  penalty is a few cycles. Branchless tricks usually are not worth
  the readability cost.

The famous "sorted vs unsorted array" demonstration is the canonical
case: an `if (data[i] > 128)` accumulator is 5–6× faster on a sorted
array (predictable branch) than on an unsorted one. On the unsorted
array, branchless reclaims most of the gap.

## Guidance

- **Default to the natural branch.** Most branches in real code are
  predictable; the predictor wins. Reach for branchless only with a
  reason.
- **Use branchless when the branch is unpredictable** — random data,
  hash-collision rates, security-sensitive code where timing must not
  depend on the input.
- **Compilers often emit `cmov` from a ternary.** Write `cond ? a : b`
  and check Godbolt. Reach for explicit bitmask or arithmetic select
  only when the compiler does *not* emit `cmov` for the natural
  expression.
- **On embedded with short pipelines**, do not assume branchless is the
  win. A Cortex-M's mispredict cost may be smaller than the data
  dependency `cmov` introduces. Measure.
- **Sort first when you can.** If the data ordering is under your
  control, sorting to make the branch predictable beats either
  branchless or unsorted branchy on most workloads.
- **Time-side-channel security is a separate concern.** If you need
  constant-time code (cryptography), branchless is mandatory — but
  compiler optimisation can reintroduce branches; use a vetted
  library (libsodium) rather than rolling your own.

## Example

```cpp
// Predictable branch: positive-count over mostly-positive data. The
// branch predictor will get this right ~95% of the time; the predicted
// path is effectively free.
std::size_t count_positive(std::span<const int> v) noexcept {
    std::size_t n = 0;
    for (int x : v) {
        if (x > 0) ++n;            // predictor handles this well
    }
    return n;
}

// Unpredictable data: same loop, random signs. Here a misprediction
// on every other element costs the loop ~15-20 cycles each. The
// branchless equivalent runs both sides at one or two cycles total.
std::size_t count_positive_branchless(std::span<const int> v) noexcept {
    std::size_t n = 0;
    for (int x : v) {
        // (x > 0) is a 0 / 1 result; arithmetic add avoids any branch.
        // Modern compilers emit a `cmov` or `setg` here automatically;
        // writing it explicitly is for documentation, not codegen.
        n += static_cast<std::size_t>(x > 0);
    }
    return n;
}

// When the compiler does not emit cmov: bitmask select.
// 32-bit signed shift: x >> 31 is -1 if negative, 0 if non-negative.
// (Implementation-defined for signed shift in pre-C++20; defined as
// arithmetic shift in C++20. Use std::bit_cast for portability where
// it matters.)
inline int select_nonneg(int x, int a, int b) noexcept {
    const std::int32_t mask = x >> 31;        // -1 when negative, else 0
    return (b & mask) | (a & ~mask);          // mask ? b : a
}

// When NOT to go branchless: a long conditional body. The branch cost
// is tiny relative to the work; branchless would force both sides to
// execute.
void update_object_bad(Object& o, bool dirty) {
    // Forcing both branches is just wasted work on the cold side.
    rebuild_transform(o);             // expensive
    if (!dirty) o.transform = o.cached_transform;   // also "no-op" if dirty
}
void update_object(Object& o, bool dirty) {
    if (dirty) {
        rebuild_transform(o);          // only the side we need runs
    } else {
        o.transform = o.cached_transform;
    }
}
```

## Caveats

- **Compilers often beat you to it.** Writing a bitmask select instead
  of a ternary usually emits the same code. Check Godbolt before
  introducing tricks.
- **`cmov` serialises the dependency chain.** A branch lets the
  predicted path proceed independently of the condition; `cmov` makes
  the result depend on the condition. In long latency-bound dependency
  chains, the *predicted* version can be faster even on unpredictable
  data.
- **The sorted-array demo is real but specific.** It works because the
  branch becomes perfectly predictable after sorting, and the body is
  small. For a long body, sorting buys nothing.
- **Side channels are not throughput.** If your goal is constant-time
  behaviour against a timing attacker, `cmov` is necessary but not
  sufficient — compiler optimisations can reintroduce branches.
  Cryptographic primitives belong in a vetted library, not in your
  hot loop.
- **Vectorisation interaction.** Some compilers auto-vectorise the
  branchless form but not the branchy form (the vectoriser cannot
  reason across the branch). Cross-reference the `simd` category.

## References

- Agner Fog, *Optimizing software in C++* and the microarchitecture
  manual — <https://www.agner.org/optimize/>
- Intel 64 / IA-32 Optimization Reference Manual (branch prediction
  and mispredict cost) —
  <https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html>
- ARM Architecture Reference Manual (Cortex-A branch prediction;
  Cortex-M pipeline) — <https://developer.arm.com/documentation/>
- Chandler Carruth, *Tuning C++: Benchmarks, and CPUs, and Compilers!
  Oh My!*, CppCon 2015 —
  <https://www.youtube.com/watch?v=nXaxk27zwlk>
- Cross-reference: `GEN.1` (branch hints affect layout, not the
  predictor), the `simd` category (auto-vectorisation interaction).
