+++
id = "LIFE.5"
title = "Use std::start_lifetime_as for non-implicit-lifetime trivially-copyable types over raw bytes"
category = "lifetime"
status = "draft"
summary = "P2590 (C++23) explicitly begins lifetime for a trivially-copyable type without running its constructor. The right tool when bytes are valid and the type is not implicit-lifetime."
tags = ["p2590", "start_lifetime_as", "trivially-copyable", "lifetime"]
+++

## Rationale

`LIFE.4`'s implicit object creation (P0593) covers only *implicit-lifetime*
types — aggregates, scalars, and trivially-copyable class types whose
eligible constructors are trivial. There is a real gap: a type that is
**trivially-copyable but not implicit-lifetime** (most commonly because it
has a user-provided default constructor) cannot have its lifetime begun by
writing bytes alone. Pre-C++23, the only standards-conforming option was
placement new, which would *run the constructor* — overwriting the bytes
you just placed there.

**P2590 (Timur Doumler, C++23)** introduces `std::start_lifetime_as<T>(p)`
and `std::start_lifetime_as_array<T>(p, n)` to close this. They take a
pointer to raw bytes containing a valid object representation of `T`,
explicitly begin `T`'s lifetime without invoking any constructor, and
return a pointer with full lifetime status.

The use cases are concrete and common:

- Mapping a binary file or shared-memory region containing a serialised
  struct that has a user-provided default constructor (often for
  initialise-to-zero behaviour) — placement-new would clobber the data.
- Custom serialisation / IPC where the bytes are known good and constructor
  side-effects are not wanted.
- Treating a `std::byte` buffer of known valid layout as a typed view.

`std::start_lifetime_as` is **not** a substitute for placement new on
non-trivially-copyable types — those constructors must run. It is also
**not** for type-punning between unrelated types — strict aliasing still
applies.

## Guidance

- Use `std::start_lifetime_as<T>(p)` when **all** of:
  - `T` is trivially-copyable (`std::is_trivially_copyable_v<T>`).
  - `T` is *not* implicit-lifetime (e.g. has a user-provided default
    constructor) — otherwise `LIFE.4` already covers it.
  - The bytes at `p` are a valid object representation of `T`.
  - You do *not* want to run `T`'s constructor.
- Use `std::start_lifetime_as_array<T>(p, n)` for an array of `n` such
  objects.
- For types with non-trivial constructors, use `std::construct_at` /
  placement new (`LIFE.2`) — the constructor must run.
- For implicit-lifetime types, do nothing special; bytes are enough
  (`LIFE.4`).
- For type-punning between trivially-copyable types of the same size,
  prefer `std::bit_cast` (it returns a *new* object, no lifetime question).

## Example

```cpp
// A trivially-copyable type that is NOT implicit-lifetime: a user-provided
// default constructor zero-initialises the version field. P0593 does not
// implicitly create one; placement-new would re-zero the bytes you just
// wrote. std::start_lifetime_as is exactly the missing primitive.
struct Message {
    Message() : version{0} {}            // user-provided ctor
    std::uint32_t version;
    std::uint32_t length;
    std::array<std::byte, 64> payload;
};
static_assert( std::is_trivially_copyable_v<Message>);
// std::is_implicit_lifetime_v<Message> is false on C++23 because of the
// user-provided default constructor.

const Message* view_message(const std::byte* bytes) {
    // C++23: begin lifetime without running Message::Message().
    return std::start_lifetime_as<Message>(bytes);
}

// Array form: a buffer of N consecutive Messages.
const Message* view_messages(const std::byte* bytes, std::size_t n) {
    return std::start_lifetime_as_array<Message>(bytes, n);
}

// What NOT to use std::start_lifetime_as for:
//
// - A type with a non-trivial constructor that does real work (e.g. takes a
//   lock, initialises a member std::string). Use std::construct_at
//   (LIFE.2) — the constructor must run.
//
// - An implicit-lifetime aggregate. P0593 (LIFE.4) already covers it; no
//   call is needed.
//
// - Type-punning between unrelated trivially-copyable types of the same
//   size. Use std::bit_cast — it produces a fresh object and sidesteps the
//   aliasing question.
```

## Caveats

- **`std::start_lifetime_as` is C++23.** Toolchain support is uneven; on
  older toolchains, the closest legal alternative is placement-new and
  acceptance of the constructor side-effects, or a `std::bit_cast` into a
  freshly-constructed object.
- **The bytes must be a valid object representation.** Calling
  `start_lifetime_as<T>` on bytes that violate `T`'s invariants is
  undefined behaviour just like every other lifetime primitive — the
  function does not validate.
- **Not a type-punning tool.** Begin lifetime *of the type the bytes were
  meant to be*. Reading the same bytes as an unrelated type via
  `start_lifetime_as<U>` is the same aliasing problem `LIFE.3` warned
  about; `start_lifetime_as` does not help.
- **No constructor runs.** That is the point. If you needed a constructor
  side-effect (resource acquisition, validation, logging), this is the
  wrong primitive.

## References

- P2590R2, "Explicit lifetime management — `std::start_lifetime_as`"
  (C++23) —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2022/p2590r2.pdf>
- cppreference, `std::start_lifetime_as` —
  <https://en.cppreference.com/w/cpp/memory/start_lifetime_as>
- ISO C++ working draft, `[basic.life]` (object lifetime) —
  <https://eel.is/c++draft/basic.life>
- Timur Doumler, "Lifetime in C++ — Implicit Object Creation and
  `std::start_lifetime_as`" — search at CppCon —
  <https://www.youtube.com/results?search_query=timur+doumler+start_lifetime_as>
