+++
id = "GEN.8"
title = "Know what the optimiser does not promise — no autovectorisation, no volatile see-through, no dead-atomic removal, no cross-TU inlining without LTO"
category = "codegen"
status = "draft"
summary = "The optimiser keeps a fixed set of contracts. Outside them, you do not get what you might assume. Knowing the anti-promises is what keeps performance tuning honest."
tags = ["optimiser", "anti-promises", "as-if", "lto", "volatile", "atomic"]
+++

## Rationale

The C++ optimiser is bound by the standard's *as-if rule*: it may
transform a program in any way that preserves the observable behaviour
of the abstract machine. That rule is wide but not unlimited. There is
a fixed set of contracts the optimiser keeps, and a fixed set of
things it cannot — by the standard or by the implementation — assume
or eliminate. Writing performance code without knowing these
anti-promises produces silent regressions and bug reports against the
wrong layer.

The anti-promises that matter most for the audience of this corpus:

- **Auto-vectorisation is *not* guaranteed.** A loop that "looks
  vectorisable" may not be. Strict aliasing, alignment, early exits,
  reductions with unsupported operators, side effects in the body, and
  vendor-specific autovectoriser limits all interfere. The `simd`
  category is the home for what actually works.
- **The optimiser does *not* see through `volatile`.** Every read and
  write of a `volatile` glvalue is preserved exactly. This is correct
  by design — `EMB.7` depends on it for memory-mapped I/O. It also
  means a value cached in a `volatile` field is reloaded each time;
  constant-fold optimisations stop at `volatile`.
- **Dead atomic operations are *not* eliminated.** The standard treats
  atomic operations as having side effects observable to other
  threads; the compiler must preserve them even if no other thread is
  provably reading. This is what makes `std::atomic` a synchronisation
  primitive in the first place (`CONC.2`).
- **Copy elision *is* guaranteed since C++17 (P0135)** for prvalues
  — covered under `COPY.8`. This is the major as-if exception in the
  copy direction; the optimiser is *required* to elide. Most other
  promises are one-way ("the optimiser *may*"), not contracts.
- **Cross-TU inlining requires LTO.** `inline` only permits multiple
  definitions across TUs; it does not enable cross-TU inlining without
  LTO (`GEN.4`). A function call across a non-LTO TU boundary will
  remain a call.
- **Cross-TU devirtualisation requires LTO + whole-program-vtables.**
  Intra-TU, a `final` class or method can be devirtualised. Across
  TUs, the optimiser must assume any class in any other TU could be
  derived from the base; LTO with `-fwhole-program-vtables` lets it
  see the whole class hierarchy.
- **Strict-aliasing does some work `restrict` does not.** Pointers of
  incompatible types are already assumed not to alias (`GEN.3`). What
  the optimiser *cannot* assume without `restrict` is that two
  same-type pointers do not alias.
- **No promises on undefined behaviour.** UB is the optimiser's
  licence to do whatever produces the most efficient code. Signed
  integer overflow, out-of-bounds reads, type-punning through unrelated
  types — once you have any UB, the optimiser is free to assume it
  away in any direction. Carruth's "Nasal Demons" talk is the canonical
  treatment.

## Guidance

Use these anti-promises to set expectations and to debug surprises:

- **If a loop did not vectorise, the question is "why not."** Check
  alignment, aliasing (`GEN.3`), early exits, reductions, the
  vectoriser report (`-Rpass=loop-vectorize`, `-fopt-info-vec`). The
  `simd` category covers what to do about each.
- **If a value through a `volatile` field reloads on every access,
  that is correct.** Cache it in a non-`volatile` local across the
  loop if you don't need each read to hit memory.
- **If a `std::atomic` operation is not elided "for free" in a loop
  that seems to allow it, that is also correct.** Move the atomic
  outside the loop, or replace with a local + one publish at the end.
- **If a call across a TU boundary is not inlined, enable LTO
  (`GEN.4`).** Without LTO, no amount of `inline` keyword or
  `always_inline` attribute will help.
- **If a virtual call is not devirtualised, mark the class `final`**
  (if appropriate) or rely on LTO + `-fwhole-program-vtables`.
- **If you cannot explain a performance result, suspect UB before
  blaming the optimiser.** UB sanitizers (`-fsanitize=undefined`,
  `-fsanitize=address`) on a debug build often reveal the actual
  cause.

## Example

```cpp
// 1. Volatile is not optimised through. The compiler will not hoist
//    the read out of the loop — every iteration reloads from memory.
//    This is correct for MMIO; it is wasteful if the field is not MMIO.
struct Regs { volatile std::uint32_t status; };

void wait_busy_bad(Regs& r) {
    while ((r.status & 0x1) != 0) { /* spin */ }   // reloads each iter; CORRECT
}

// 2. Atomic loads are not optimised away even when "nothing changes."
//    The compiler treats them as observable side effects.
std::atomic<bool> running{true};

void worker() {
    while (running.load(std::memory_order_relaxed)) {
        // The load happens every iteration; the compiler will not hoist
        // it out of the loop even with -O3. If you don't need that, copy
        // it once at entry:
        //   bool local = running.load(std::memory_order_relaxed);
        //   while (local) { ... }
        // (and accept that you won't see a flip until the next entry.)
        work();
    }
}

// 3. Cross-TU inlining without LTO does not happen. The `inline`
//    keyword permits the definition in the header; it does not enable
//    cross-TU inlining when the body is in a .cpp.
//
// in fast_helpers.h:
inline std::uint32_t fnv1a_step(std::uint32_t h, std::uint8_t b) noexcept;
//
// in fast_helpers.cpp:
std::uint32_t fnv1a_step(std::uint32_t h, std::uint8_t b) noexcept {
    return (h ^ b) * 0x01000193u;
}
//
// in hot_loop.cpp:
std::uint32_t hash(std::span<const std::uint8_t> bytes) {
    std::uint32_t h = 0x811C9DC5u;
    for (auto b : bytes) h = fnv1a_step(h, b);  // real call without LTO.
}

// 4. Devirtualisation across TUs requires LTO + whole-program vtables.
//    Without LTO, even a class that only has one implementation in the
//    program is treated as if any TU could derive a new one.
struct Renderer {
    virtual ~Renderer() = default;
    virtual void draw(Frame&) = 0;
};
struct DefaultRenderer final : Renderer {           // final on the class
    void draw(Frame& f) override;                   // helps intra-TU only
};

void render(Renderer& r, Frame& f) {
    r.draw(f);   // direct call only with LTO + -fwhole-program-vtables.
}
```

## Caveats

- **"The optimiser is conservative" is not a bug report.** Each
  anti-promise above is the optimiser doing its job — preserving the
  observable behaviour of the abstract machine. Working with them is
  the work; working *against* them produces wrong code.
- **Tooling helps.** `-Rpass=...`, `-fopt-info-...`, Godbolt, and
  `llvm-mca` make the optimiser's decisions inspectable. Inspect
  before guessing.
- **The "C++ memory model" intersects all of this.** `volatile`,
  `std::atomic`, and the lifetime rules interact with optimisation in
  ways covered by `EMB.7`, `CONC.1`, `LIFE.4`, and `COPY.8`. This
  guideline is the index; the categories are the depth.
- **UB sanitizers do not catch everything.** Strict-aliasing
  violations, certain alignment bugs, and timing-dependent UB pass
  ASan / UBSan unnoticed. When the optimiser produces "surprising"
  code, suspect UB first.
- **Vendor-specific guarantees do exist.** GCC and Clang document
  many behaviours that the standard does not require; MSVC less so.
  Use vendor-specific guarantees deliberately; document the dependency.

## References

- Chandler Carruth, *Garbage In, Garbage Out: Arguing about Undefined
  Behavior with Nasal Demons*, CppCon 2016 —
  <https://www.youtube.com/watch?v=yG1OZ69H_-o>
- Matt Godbolt, *What Has My Compiler Done for Me Lately?*, CppCon
  2017 — <https://www.youtube.com/watch?v=bSkpMdDe4g4>
- ISO C++ working draft, `[intro.abstract]` (the as-if rule) —
  <https://eel.is/c++draft/intro.abstract>
- P0135R1, *Guaranteed copy elision* (C++17) —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2016/p0135r1.html>
- Cross-reference: `COPY.8` (the one major as-if guarantee), `EMB.7`
  (`volatile` for MMIO), `CONC.1` and `CONC.2` (atomic side effects),
  `GEN.3` / `GEN.4` (`restrict` and LTO unlocking the optimisations
  the optimiser otherwise cannot perform).
