+++
id = "LIFE.1"
title = "Distinguish trivial, trivially-copyable, trivially-destructible, and implicit-lifetime"
category = "lifetime"
status = "draft"
summary = "Four different properties with four different consequences. Sources routinely conflate them; the conflation causes UB. Use the type traits, check each property independently."
tags = ["triviality", "implicit-lifetime", "trivially-copyable"]
+++

## Rationale

C++ defines four distinct "this type is simple enough that the runtime can
skip some work" properties, and the popular shorthand "POD" collapses them
into one. The conflation is the anti-pattern: each property unlocks a
different operation, and assuming one when you only have another is
undefined behavior.

- **Trivial** — the type has no user-provided default constructor *and* is
  trivially copyable. Default-initializing it costs nothing.
- **Trivially-copyable** — copy / move / destroy are all trivial. `std::memcpy`
  between objects of the type is well-defined; the type can be stored in
  `std::atomic`; it is eligible for `std::bit_cast`.
- **Trivially-destructible** — destruction is a no-op. You may skip the
  destructor call when reusing storage, and the type is eligible for
  `constexpr` destruction.
- **Implicit-lifetime** (C++20, P0593) — `malloc`, `memcpy`, `bit_cast`, and
  the other implicit-object-creation operations *create* objects of this
  type automatically, no placement-new required.

These overlap but are not equivalent. A type with a user-provided default
constructor that copies bitwise (`struct S { S(){x=0;} int x; };`) is *not*
trivial but *is* trivially-copyable. A type with a non-trivial copy
constructor but a defaulted destructor and trivially-destructible members is
*trivially-destructible* but not *trivially-copyable*. An *aggregate* with no
user-declared constructors is *implicit-lifetime* and almost always all four;
a class with `virtual` functions is none of them.

The type traits make the question checkable. Use them.

## Guidance

- Reach for the **specific** trait the operation requires, not "trivial":
  - `std::is_trivially_copyable_v<T>` for `memcpy`, `std::atomic<T>`,
    `std::bit_cast`.
  - `std::is_trivially_destructible_v<T>` to know whether you may skip
    `~T()` when reusing storage.
  - `std::is_implicit_lifetime_v<T>` (C++23) to know whether `malloc` and
    friends implicitly create objects of `T`.
  - `std::is_trivial_v<T>` only when you actually need both — rare.
- **Static-assert the property at the type definition.** A change that
  breaks `is_trivially_copyable` (e.g. adding a user-defined destructor)
  should fail loudly where the type lives, not silently at the call site
  that depended on it.
- **Beware of accidentally losing triviality.** A user-defined destructor
  (`~T() = default;` counts — see `COPY.4`), a virtual function, a
  non-trivial subobject, or `std::shared_ptr` membership all break
  trivially-copyable.
- For pre-C++23 toolchains lacking `is_implicit_lifetime_v`, the workable
  approximation is `is_trivially_copyable_v<T> && is_trivially_destructible_v<T>`
  plus "no user-declared constructors" — but the trait is the right check
  when available.

## Example

```cpp
// Four types, each with a different combination of properties. The
// static_asserts spell out which operations are legal for each.
//
// 1. Trivial — and therefore all four.
struct Trivial { int a; double b; };
static_assert(std::is_trivial_v<Trivial>);
static_assert(std::is_trivially_copyable_v<Trivial>);
static_assert(std::is_trivially_destructible_v<Trivial>);
// implicit-lifetime per [basic.types]; see is_implicit_lifetime_v on C++23.

// 2. Trivially-copyable but not trivial: a user-provided default ctor
//    disqualifies it from trivial, but copy / move / destroy are all
//    trivial. memcpy between two objects of S is still well-defined.
struct S {
    S() : x{0} {}
    int x;
};
static_assert(!std::is_trivial_v<S>);
static_assert( std::is_trivially_copyable_v<S>);

// 3. Trivially-destructible but not trivially-copyable: a non-trivial copy
//    constructor disqualifies copy-triviality, but the destructor is
//    defaulted and the members are trivially-destructible — so skipping
//    ~T() when reusing storage is legal.
struct D {
    D() = default;
    D(const D& other) noexcept : x{other.x + 1} {}    // non-trivial copy
    int x = 0;
};
static_assert(!std::is_trivially_copyable_v<D>);
static_assert( std::is_trivially_destructible_v<D>);

// 4. None of the above. A virtual function breaks every triviality property.
struct Polymorphic {
    virtual ~Polymorphic() = default;
};
static_assert(!std::is_trivially_copyable_v<Polymorphic>);
static_assert(!std::is_trivially_destructible_v<Polymorphic>);

// What each property unlocks (see the other LIFE guidelines for detail):
//   trivially_copyable     -> memcpy legal (COPY.6), std::atomic<T>, bit_cast
//   trivially_destructible -> may skip ~T() on storage reuse (LIFE.7)
//   implicit_lifetime      -> malloc/memcpy creates the object (LIFE.4)
```

## Caveats

- **`std::is_trivial`** requires both *trivially-copyable* and a
  *trivial default constructor*. Outside of `std::aligned_storage`-style
  uses, you almost never want "trivial" — you want one of the more specific
  properties.
- **A defaulted destructor still counts as user-declared** for the
  implicit-move suppression rule (`COPY.4`). The triviality traits are
  unaffected, but the move story is.
- **`std::is_implicit_lifetime_v` is C++23.** Pre-C++23 codebases must
  approximate or wait. The conservative pre-C++23 stand-in:
  trivially-copyable, trivially-destructible, aggregate or scalar.
- **"POD" was removed from the standard in C++20** as a defined term; the
  word survives in literature and old standards. Use the specific traits
  instead.

## References

- ISO C++ working draft, `[basic.types]` (object representation and
  triviality) — <https://eel.is/c++draft/basic.types>
- P0593R6, "Implicit creation of objects for low-level object
  manipulation" (C++20) —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2020/p0593r6.html>
- cppreference, "Named requirements" page set — `TriviallyCopyable`,
  `TrivialType`, implicit-lifetime types —
  <https://en.cppreference.com/w/cpp/named_req/TriviallyCopyable>;
  <https://en.cppreference.com/w/cpp/types/is_implicit_lifetime>
- Scott Meyers, *Effective Modern C++*, item 18 et seq. —
  **cite-by-reference**.
