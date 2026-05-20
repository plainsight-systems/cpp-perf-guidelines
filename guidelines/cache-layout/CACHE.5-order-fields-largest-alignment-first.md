+++
id = "CACHE.5"
title = "Order struct fields largest-alignment-first; group co-accessed fields adjacently"
category = "cache-layout"
status = "draft"
summary = "Field declaration order materially affects struct size because of padding. Order fields largest-alignment-first to minimise padding; group fields touched together so they share a cache line."
tags = ["padding", "alignment", "struct-layout"]
+++

## Rationale

The C++ object model guarantees each non-static data member's *alignment*; it
does **not** guarantee a packed layout. Whenever a struct mixes field widths,
the compiler inserts padding to satisfy each member's alignment requirement,
and the order in which the programmer declared the fields determines how much
padding ends up between them. The classic example:

```cpp
struct Bad  { char a; double b; char c; };   // 24 bytes (7 + 0 + 7 padding)
struct Good { double b; char a; char c; };   // 16 bytes
```

`Good` is 33 % smaller for the same fields. On a 64-byte cache line `Bad`
fits two elements; `Good` fits four. A hot loop over an array of these moves
the same data twice as fast — for nothing more than re-ordering three field
declarations.

Drepper's *What Every Programmer Should Know About Memory* §6.2.1 and Agner
Fog's *Optimizing Software in C++* ch. 9 give the rule: order fields by
alignment, largest first, then group co-accessed fields adjacently so they
share a line. Compilers cannot reorder data members for you — the layout is
part of the type's ABI.

## Guidance

- **Order fields by alignment, largest first.** 8-byte members
  (`double`, `void*`, `std::int64_t`) before 4-byte (`float`, `int`) before
  2-byte (`short`) before 1-byte (`char`, `bool`).
- **Within an alignment tier, group fields the loop touches together.** Those
  fields share lines and travel in and out of cache together.
- **Verify with `static_assert`.** A back-of-envelope minimum
  (`sum of field sizes, rounded up to the alignment of the largest member`)
  is the size the type *should* be; if `sizeof(T)` exceeds that, padding
  exists and field order can probably reduce it.
- **Put rarely-touched fields at the end** (or split them out — see
  `CACHE.6`); they push hot fields further from each other if they are
  interleaved.
- **Avoid `[[gnu::packed]]` / `#pragma pack`** as a fix. Packed structs
  produce misaligned loads on most ISAs (correctness-fatal on older ARM,
  always slower than aligned access on x86). Re-order; don't pack.

## Example

```cpp
// Bad: padded to 24 bytes for no good reason.
struct Bad {
    char   a;
    double b;
    char   c;
};
static_assert(sizeof(Bad) == 24);

// Good: largest-alignment-first; 16 bytes — 33 % smaller.
struct Good {
    double b;
    char   a;
    char   c;
};
static_assert(sizeof(Good) == 16);

// Real-world layout: a particle whose hot fields are (position, alive flag)
// and whose cold fields are (debug name pointer, asset id). Order so the
// hot fields share the first cache line; the cold fields go at the end.
struct Particle {
    // hot: read every frame ----------------------------------------------
    Vec3        position;        // 12, alignment 4
    float       life;            //  4, alignment 4
    bool        alive;           //  1, alignment 1
    // 3 bytes padding here to align the next 8-byte field

    // less hot ------------------------------------------------------------
    std::size_t spawn_tick;      //  8, alignment 8

    // cold: rarely touched ------------------------------------------------
    const char* debug_name;      //  8, alignment 8
    std::uint32_t asset_id;      //  4, alignment 4
    // 4 bytes trailing padding to bring sizeof to a multiple of 8
};
static_assert(sizeof(Particle) == 40);
// Hot fields (position + life + alive) occupy bytes 0..16 — same cache line.

// Empty-base / empty-member optimisation: [[no_unique_address]] (C++20)
// lets an empty subobject share storage with the next field, saving the
// stand-alone byte plus its padding.
struct Stateless {};   // empty

struct WithStateless {
    [[no_unique_address]] Stateless s;
    int                            i;
};
static_assert(sizeof(WithStateless) == sizeof(int));
```

## Caveats

- **Re-ordering changes the type's ABI.** A struct exposed across a library
  boundary (shared library, plugin, IPC) cannot be silently re-ordered.
  Field order in such types is a versioned contract.
- **Some alignments are surprising.** A struct containing a `double` has
  alignment 8 even if you intuit less. `std::atomic<T>` may have stricter
  alignment than `T` so it can be lock-free. Check with
  `alignof(T)`.
- **Bit-fields layout is implementation-defined** — adjacent bit-fields may
  or may not share a byte, and signed bit-fields have signedness traps. Use
  `std::bitset` or hand-rolled masks for portable bit-packed state.
- **Trailing padding still counts.** A struct's `sizeof` is rounded up to
  its alignment so arrays of it stride correctly. Re-ordering can sometimes
  shave trailing padding by moving the largest member out of the last
  position — measure.

## References

- Ulrich Drepper, *What Every Programmer Should Know About Memory*, §6.2.1 —
  <https://people.freebsd.org/~lstewart/articles/cpumemory.pdf>
- Agner Fog, *Optimizing Software in C++*, ch. 9 (memory layout) —
  <https://www.agner.org/optimize/optimizing_cpp.pdf>
- cppreference, "Object representation and value representation" —
  <https://en.cppreference.com/w/cpp/language/object>
- C++ Core Guidelines C.47 (define and initialize member variables in the
  order of member declaration) —
  <https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines#c47-define-and-initialize-member-variables-in-the-order-of-member-declaration>
