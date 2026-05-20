+++
id = "LIFE.4"
title = "Rely on P0593 implicit object creation for memcpy and malloc-style code"
category = "lifetime"
status = "draft"
summary = "For implicit-lifetime types, malloc, memcpy, bit_cast and friends implicitly create the object — no placement-new needed. This retroactively legalises decades of C-interop code."
tags = ["p0593", "implicit-lifetime", "memcpy", "malloc"]
+++

## Rationale

Before C++20, every codebase that allocated raw bytes with `malloc`, wrote
data into them, and read back through a pointer of the target type was
quietly in undefined-behavior territory according to the strict letter of
`[basic.life]`. The compilers tolerated it; the standard did not. **P0593
("Implicit creation of objects for low-level object manipulation",
Richard Smith / Ville Voutilainen, C++20)** closes that gap.

The mechanism: a fixed set of "implicit object creation" operations —
`malloc`, `calloc`, `realloc`, `aligned_alloc`, `operator new`,
`std::allocator<T>::allocate` for byte types, `memcpy`, `memmove`,
`std::bit_cast`, and creation of `std::byte` arrays — **implicitly create**
objects of any implicit-lifetime type (see `LIFE.1`) within the storage they
produce or manipulate. The standard defines the implementation as if it
chose, at any later use of the storage, the implicit object whose creation
would make the program well-defined.

The consequence: for *implicit-lifetime types*, you do **not** need
placement new or `std::start_lifetime_as` — writing the bytes is enough.

P0593 deliberately does *not* extend to non-implicit-lifetime types. A
`std::string` has a user-provided destructor; you cannot `malloc` one. For
those, use `std::construct_at` (`LIFE.2`) or `std::start_lifetime_as`
(`LIFE.5`).

## Guidance

- For **implicit-lifetime types** (scalars, aggregates, trivially-copyable
  class types with trivial eligible constructors and a trivial destructor —
  check `std::is_implicit_lifetime_v<T>` in C++23):
  - `malloc(sizeof(T))` + write bytes + read through `T*` is well-defined.
  - `memcpy` between two byte buffers preserves any implicit-lifetime
    objects within them.
  - Reading a `std::byte` array as the underlying object representation of
    an implicit-lifetime type is well-defined.
- For **non-implicit-lifetime types**, P0593 does not apply. Use:
  - `std::construct_at` / placement new for full construction (`LIFE.2`).
  - `std::start_lifetime_as` for trivially-copyable types whose constructor
    you do not want to run, when you already have valid object bytes
    (`LIFE.5`).
- **Strict aliasing still applies.** P0593 implicitly creates an object of
  *the type the access uses*. It does not bless reading the same bytes as
  two unrelated types — `std::bit_cast` is the tool for that.
- **C interop becomes legal, not just "tolerated."** A binary protocol
  parser that reads a header struct directly out of a byte buffer is now
  standards-conformant, given the header type is implicit-lifetime.

## Example

```cpp
// Implicit-lifetime types: malloc + memcpy + read is well-defined.
struct Header {                 // aggregate; no user-declared constructors
    std::uint32_t magic;
    std::uint32_t length;
    std::uint16_t flags;
    std::uint16_t reserved;
};
static_assert(std::is_trivially_copyable_v<Header>);
// std::is_implicit_lifetime_v<Header> is true on C++23.

const Header* parse_header(const std::byte* bytes) {
    // No placement-new needed: Header is an implicit-lifetime type, so
    // accessing `*hp` after writing valid bytes through `bytes` is well-
    // defined by P0593.
    return reinterpret_cast<const Header*>(bytes);
}

// memcpy preserves implicit-lifetime objects.
void copy_message(const std::byte* src, std::byte* dst, std::size_t n) {
    std::memcpy(dst, src, n);
    // Any implicit-lifetime objects represented in src now exist in dst.
}

// What P0593 does NOT cover: non-implicit-lifetime types.
// std::string has a user-provided destructor and is not implicit-lifetime;
// reinterpreting raw bytes as a std::string is UB regardless of whether
// the bytes happen to match a valid representation.
class Bad {
public:
    void parse(const std::byte* bytes) {
        // UB: std::string is not implicit-lifetime; you must construct one.
        // const auto& s = *reinterpret_cast<const std::string*>(bytes);
        //
        // For non-trivial types, see LIFE.2 (std::construct_at) or
        // LIFE.5 (std::start_lifetime_as for trivially-copyable + non-
        // implicit-lifetime).
    }
};
```

## Caveats

- **Implicit-lifetime is narrower than "trivially-copyable."** A type can
  be trivially-copyable but not implicit-lifetime — for example, a class
  with a user-provided default constructor. For that case use `LIFE.5`
  (`std::start_lifetime_as`), not P0593's implicit creation.
- **The "implicit object" is selected by the implementation.** You write
  bytes; the abstract machine chooses, retroactively, which implicit object
  the bytes refer to. Do not write code that relies on which one is chosen
  among multiple compatible types in the same storage at the same time.
- **P0593 is C++20.** Pre-C++20 codebases still get the same compiler
  behaviour in practice, but the standard did not formally permit it.
  Document the C++20 dependency where it matters.
- **`std::is_implicit_lifetime_v` is C++23.** Pre-C++23 toolchains lack the
  trait; the workable stand-in is "trivially-copyable, trivially-
  destructible, and an aggregate or scalar."

## References

- P0593R6, "Implicit creation of objects for low-level object
  manipulation" (C++20) —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2020/p0593r6.html>
- ISO C++ working draft, `[basic.types]` (implicit-lifetime types) —
  <https://eel.is/c++draft/basic.types>
- cppreference, `std::is_implicit_lifetime` —
  <https://en.cppreference.com/w/cpp/types/is_implicit_lifetime>
- Timur Doumler, "Lifetime in C++ — Implicit Object Creation and
  `std::start_lifetime_as`" — search at CppCon —
  <https://www.youtube.com/results?search_query=timur+doumler+start_lifetime_as>
