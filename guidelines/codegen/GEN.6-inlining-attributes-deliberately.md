+++
id = "GEN.6"
title = "Use always_inline / flatten / noinline sparingly — the inliner is usually right"
category = "codegen"
status = "draft"
summary = "The inliner's heuristic is the right default. Override only with reason: always_inline for tiny hot utilities and intrinsic wrappers; noinline for cold helpers and debug stability; flatten only on a single dispatch root."
tags = ["inlining", "always_inline", "noinline", "flatten"]
+++

## Rationale

The compiler's inliner balances three things: instruction cache
footprint, register pressure, and call-overhead amortisation. Its
heuristic considers callee size, callsite frequency, and (with PGO)
measured hotness. For the vast majority of code, the heuristic is the
right default — overriding it tends to make things worse, not better.

The function-attribute family lets you override:

- **`[[gnu::always_inline]]`** (GCC, Clang) / **`__forceinline`** (MSVC)
  — inline this function at every call site, regardless of the
  heuristic.
- **`[[gnu::noinline]]`** — never inline this function.
- **`[[gnu::flatten]]`** — inline everything *this* function calls,
  recursively.

Each is appropriate in narrow cases, and each backfires when misused.

`always_inline` is correct for tiny utility functions in tight loops,
intrinsic wrappers (where any call overhead destroys the win), and RAII
helpers whose code generation must fold into the caller for the
optimiser to see scope. It is wrong when applied to a body that bloats
the call site, increases register pressure to the point of spills, or
pulls a cold path into a hot function.

`noinline` is correct for cold helpers (keep the cold path out of the
hot caller's I-cache footprint), preserving function boundaries for
debugging or `perf` attribution, and stopping the inliner from
cascading into a body that triggers register-pressure regression.

`flatten` is the rarest. It produces a "fully inlined kernel" — a
function with no internal call boundaries. Use it on a single
performance-critical dispatch root; do not apply it to a function whose
callees form a deep tree (catastrophic code bloat).

## Guidance

- **Default: no annotation.** The inliner is right most of the time.
- **`[[gnu::always_inline]]` for:**
  - Tiny utility functions called in tight loops where call overhead
    matters.
  - Intrinsic wrappers (`std::countl_zero` over `__builtin_clz`, custom
    SIMD intrinsic shims).
  - RAII helpers whose scope must be visible to the caller's optimiser
    (locks, scope guards on hot paths).
- **`[[gnu::noinline]]` for:**
  - Cold helpers that should not pollute the hot caller's I-cache.
  - Functions whose body causes register spills when inlined.
  - Preserving a function boundary for stable `perf` attribution or
    breakpoints.
- **`[[gnu::flatten]]` for:**
  - A single performance-critical dispatch root with a known, bounded
    callee tree. Do not apply blindly; the recursive inlining can
    explode binary size.
- **PGO (`GEN.5`) subsumes most of this.** Under PGO, the inliner's
  decisions are evidence-based; the cases where manual override
  improves on profile-guided inlining are rare.
- **MSVC equivalent:** `__forceinline` for `always_inline`;
  `__declspec(noinline)` for `noinline`. There is no `flatten`
  equivalent on MSVC.

## Example

```cpp
// always_inline: a tiny utility called inside a tight loop. The function-
// call overhead would be a measurable fraction of the body; inlining
// folds the work into the caller.
[[gnu::always_inline]] inline
std::uint32_t hash_step(std::uint32_t h, std::uint8_t b) noexcept {
    return (h * 31) ^ b;
}

std::uint32_t hash_buffer(std::span<const std::uint8_t> bytes) {
    std::uint32_t h = 0;
    for (auto b : bytes) {
        h = hash_step(h, b);          // inlined; one mul + one xor per byte
    }
    return h;
}

// always_inline: intrinsic wrapper. Any call overhead defeats the
// intrinsic's purpose.
[[gnu::always_inline]] inline
unsigned count_leading_zeros(std::uint64_t x) noexcept {
    return x ? static_cast<unsigned>(__builtin_clzll(x)) : 64u;
}

// noinline: a cold helper that should not bloat the hot caller. Without
// noinline the optimiser might inline log_overflow into the hot loop
// "just in case" and pollute the caller's I-cache window.
[[gnu::noinline, gnu::cold]] static
void log_overflow(const Context& ctx, std::uint64_t value);

void hot_loop(std::span<std::uint64_t> values, const Context& ctx) {
    std::uint64_t sum = 0;
    for (auto v : values) {
        if (v > kThreshold) [[unlikely]] {
            log_overflow(ctx, v);     // never inlined; stays out of band
        }
        sum += v;
    }
    publish(sum);
}

// flatten: a single dispatch root with a shallow, bounded callee tree.
// The whole kernel folds into one function body — no internal call
// boundaries, maximum optimiser visibility.
[[gnu::flatten]]
void render_pixel(const Pixel& p, Framebuffer& fb) noexcept {
    const auto shaded = shade(p);     // inlined
    const auto blent  = blend(shaded, fb.at(p.x, p.y));   // inlined
    fb.write(p.x, p.y, blent);        // inlined
}

// Bad: always_inline on a large function. Every call site bloats; the
// inliner's heuristic would have made the right call.
//   [[gnu::always_inline]] inline
//   void big_handler(/* many params, large body */) { ... }
//
// Bad: flatten on a function whose callees include real algorithms.
// Recursive inlining explodes binary size.
//   [[gnu::flatten]]
//   void process_request(const Request& r) {
//       parse(r); validate(r); execute(r); ... // deep call tree
//   }
```

## Caveats

- **Inlining is not free.** A function inlined at 100 call sites costs
  ~100× its body's size in `.text`. The I-cache penalty can erase the
  call-overhead savings.
- **Register pressure cascade.** Inlining a function with many locals
  into a caller that also has many locals can force spills that cost
  more than the avoided call.
- **`always_inline` does not guarantee inlining in all cases.** The
  attribute is a strong hint, not a contract — recursion, taking the
  function's address, and certain ABI requirements can still prevent
  inlining. The compiler will diagnose when it cannot honour the
  attribute.
- **`flatten` plus recursion is undefined-behaviour-adjacent.** The
  compiler must bottom out somewhere; behaviour is
  implementation-defined.
- **PGO often makes the manual annotations redundant.** When you ship
  with PGO, audit `[[gnu::always_inline]]` / `[[gnu::noinline]]`
  annotations — many will be doing nothing useful, and some may
  contradict the profile.
- **Debug builds.** `always_inline` is honoured even at `-O0` in most
  compilers, but stepping through inlined code is harder. Mark only
  the functions where the inlining is genuinely a performance
  contract, not those where you "think it should be inlined."

## References

- GCC function attributes (`always_inline`, `noinline`, `flatten`,
  `hot`, `cold`) —
  <https://gcc.gnu.org/onlinedocs/gcc/Common-Function-Attributes.html>
- Clang attribute reference —
  <https://clang.llvm.org/docs/AttributeReference.html>
- MSVC, `__forceinline` —
  <https://learn.microsoft.com/cpp/cpp/inline-functions-cpp>
- Chandler Carruth, *Tuning C++: Benchmarks, and CPUs, and Compilers!
  Oh My!*, CppCon 2015 —
  <https://www.youtube.com/watch?v=nXaxk27zwlk>
- Cross-reference: `GEN.5` (PGO subsumes most manual inlining
  decisions), `GEN.7` (`[[gnu::cold]]` complements `noinline`).
