+++
id = "GEN.3"
title = "Use __restrict__ when same-type pointers are guaranteed not to alias"
category = "codegen"
status = "draft"
summary = "TBAA covers incompatible types. __restrict__ is for same-type non-aliasing and can unlock loop fusion, register promotion, and vectorisation."
tags = ["restrict", "aliasing", "tbaa", "vectorisation"]
+++

## Rationale

When a function takes two pointers of the same type, the compiler must
assume they *might* alias — that a store through one could affect a load
through the other. That assumption forces it to reload after every
store, refuse loop fusion, refuse register promotion across stores, and
often refuse to vectorise. The cost is invisible in the source.

C++ has no standard `restrict` keyword. C has had `restrict` since C99;
GCC, Clang, and MSVC all provide `__restrict__` / `__restrict` as a
non-standard extension with the same semantics: **within the pointer's
scope, the object reached through it is not reached through any other
pointer**. Promising this to the compiler unlocks:

- Loop fusion across stores.
- Invariant hoisting past writes.
- Keeping a value in a register across a store through a different
  `restrict` pointer.
- Auto-vectorisation (cross-reference the `simd` category) — the
  vectoriser's first bail-out is "these pointers might alias"; the
  runtime aliasing check it would otherwise insert often costs the
  vectorisation.

Where the compiler **already knows** pointers do not alias, `restrict`
adds nothing. C++ type-based alias analysis (TBAA) lets the compiler
assume two pointers of incompatible types do not alias — modulo
`char*`, `std::byte*`, `unsigned char*`, and `[[gnu::may_alias]]`-
tagged types, which are explicitly allowed to alias anything. So a
`float*` and an `int*` argument pair gets the same optimisation
opportunity without `restrict`. The benefit shows up for **same-type
parameters**: two `float*` ins and an out, two `int*` operands and a
result.

## Guidance

- **Add `__restrict__` to function parameters when you can promise the
  pointers do not alias.** Output buffers, scratch buffers, and
  separate input streams are the canonical cases.
- **The contract must hold at every call site.** A `restrict` violation
  is undefined behaviour, silently incorrect. Audit callers when the
  function is called from new code.
- **For different types, TBAA already wins.** `restrict` on a `float*`
  + `int*` pair is redundant; the compiler already assumed
  non-aliasing.
- **`char*` and `std::byte*` defeat TBAA.** They may alias anything.
  `restrict` is the only escape — and the only way to autovectorise
  through them.
- **Use a portable macro** — there is no portable spelling for
  `restrict` in C++:

  ```cpp
  #if defined(_MSC_VER)
    #define RESTRICT __restrict
  #else
    #define RESTRICT __restrict__
  #endif
  ```
- **`restrict` is orthogonal to `std::launder` (`LIFE.3`).** `launder`
  fixes pointer-provenance after lifetime reuse; `restrict` constrains
  aliasing. Developers conflate them; they are different tools.

## Example

```cpp
// Without restrict, the compiler must assume `dst` and `src` could
// overlap. Every store through `dst` invalidates the assumption that
// later loads through `src` still hold. Result: no loop fusion, no
// vectorisation, an opaque scalar loop.
void scale_naive(float* dst, const float* src, float k, std::size_t n) {
    for (std::size_t i = 0; i < n; ++i) {
        dst[i] = src[i] * k;
    }
}

// With restrict, we promise neither pointer reaches the other's storage.
// Compiler autovectorises, fuses, and produces a tight SIMD loop.
void scale(float* RESTRICT dst,
           const float* RESTRICT src,
           float k, std::size_t n) {
    for (std::size_t i = 0; i < n; ++i) {
        dst[i] = src[i] * k;
    }
}

// Different types — restrict adds nothing. TBAA already assumes
// non-aliasing between float* and std::int32_t*.
void quantise(std::int32_t* out,
              const float*  in,
              std::size_t   n) {
    for (std::size_t i = 0; i < n; ++i) {
        out[i] = static_cast<std::int32_t>(in[i]);
    }
}

// std::byte* / char* / unsigned char* defeat TBAA — they may alias
// anything. Here restrict matters even though the types differ.
void copy_bytes(std::byte* RESTRICT dst,
                const std::byte* RESTRICT src,
                std::size_t n) {
    std::memcpy(dst, src, n);   // memcpy already implies non-overlap
    // For element-by-element loops over std::byte buffers, restrict is
    // what tells the compiler the two halves don't alias.
}

// Bad: violating the restrict contract is silent UB. The compiler
// trusts you; reordered loads against stores may produce wrong values.
//
//   void aliased_call(float* p, std::size_t n) {
//       scale(p, p, 2.0f, n);    // dst == src; UB under restrict
//   }
```

## Caveats

- **`restrict` violation is UB.** The compiler trusts the promise; if
  two `restrict` pointers do reach the same storage, results are
  silently wrong (and not necessarily reproducible across optimiser
  versions).
- **`restrict` applies through the pointer.** `restrict` on a class
  member that holds a `T*` does not propagate; it applies to the
  outermost pointer only.
- **MSVC's `__restrict` is similar but has corner-case differences.**
  Use the macro pattern; do not assume identical semantics.
- **`restrict` is not C++23.** P3088 and related papers have proposed
  it; nothing is in the standard. Use the extension.
- **Auto-vectorisation pre-conditions.** `restrict` removes the
  aliasing bail-out, but vectorisation also needs aligned data,
  no early-exit, no `volatile`, and reasonable trip counts. See the
  `simd` category for the full picture.

## References

- GCC manual, `__restrict__` —
  <https://gcc.gnu.org/onlinedocs/gcc/Restricted-Pointers.html>
- Clang documentation, `__restrict__` extension —
  <https://clang.llvm.org/docs/AttributeReference.html>
- MSVC, `__restrict` —
  <https://learn.microsoft.com/cpp/cpp/extension-restrict>
- Chandler Carruth, *Tuning C++: Benchmarks, and CPUs, and Compilers!
  Oh My!*, CppCon 2015 —
  <https://www.youtube.com/watch?v=nXaxk27zwlk>
- Matt Godbolt, *What Has My Compiler Done for Me Lately?*, CppCon
  2017 — <https://www.youtube.com/watch?v=bSkpMdDe4g4>
- ISO C99, §6.7.3.1 (restrict) — the C definition that the C++
  extensions reproduce.
- Cross-reference: `LIFE.3` (`std::launder` — orthogonal, often
  confused with `restrict`).
