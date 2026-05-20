+++
id = "COPY.6"
title = "memcpy is legal only on trivially-copyable types; the moved-from state is 'valid but unspecified'"
category = "copy-move"
status = "draft"
summary = "memcpy is legal only between trivially-copyable types; the moved-from state is 'valid but unspecified' — destructor and assignment work, nothing about the value is guaranteed."
tags = ["memcpy", "trivially-copyable", "move-semantics", "bit_cast"]
+++

## Rationale

Two intertwined questions are easy to get wrong together: "can I `memcpy`
these bytes?" and "what can I still do with this object after `std::move`?"
Both have surprisingly narrow guarantees.

**`memcpy` on C++ objects.** Bytewise copy is well-defined only between
objects of a **trivially copyable** type — no user-provided copy/move/dtor,
no virtual functions, no non-trivially-copyable subobjects. For any other
type, `memcpy` to a same-type destination is **undefined behavior**, even if
the type's move constructor "would have just copied the pointer." The bytes
may look right; the object's identity, lifetime, and invariants do not survive.

For type-punning between two trivially-copyable types of the same size, the
right tool since C++20 is **`std::bit_cast`** — it is `memcpy` with the types
in the signature, and the compiler enforces the trivially-copyable
precondition.

Arthur O'Dwyer's **P1144** proposes *trivially relocatable* as a separate
weaker concept (you can `memcpy` *and* treat the source as ended), which is
the model `std::vector` reallocation actually wants. As of C++23, P1144 is
not in the standard — treat it as forward-looking. Unreal Engine has shipped
its own equivalent (`TIsTriviallyRelocatable`) for years.

**The moved-from state.** After `std::move(x)`, the standard guarantees only
that `x`'s destructor will run cleanly and that you can assign to `x`. Anything
that reads the *value* — `front()` on a moved-from container, `*` on a
moved-from `unique_ptr` — is undefined unless the specific type promises
otherwise. The standard library *does* over-specify in places (a moved-from
`unique_ptr` is guaranteed null), but the language itself promises very
little. For your own types, document what you guarantee.

## Guidance

- Use `memcpy` between objects of type `T` only when
  `std::is_trivially_copyable_v<T>`. Assert it.
- For type-punning between same-sized trivially-copyable types, prefer
  `std::bit_cast` over a hand-rolled `memcpy`.
- Do **not** use `memcpy` to "relocate" non-trivially-copyable objects. That
  is the trivially-relocatable model (P1144), which is not yet standard.
- After `std::move(x)`, treat `x` as **destructible and assignable, nothing
  more** unless the type's documentation promises more.
- For types you write, document the moved-from contract — e.g. "moved-from
  instances compare equal to a default-constructed instance" — and provide a
  cheap way to check it (`empty()`, an `operator==`, etc.).

## Example

```cpp
// Good: memcpy between trivially-copyable types is well-defined.
struct Vec3 { float x, y, z; };
static_assert(std::is_trivially_copyable_v<Vec3>);

void copy_vertices(const Vec3* src, Vec3* dst, std::size_t n) {
    std::memcpy(dst, src, n * sizeof(Vec3));    // OK
}

// Good: bit_cast is memcpy with the types in the signature; the compiler
// enforces trivially-copyable on both sides.
std::uint32_t bit_pattern(float f) {
    return std::bit_cast<std::uint32_t>(f);     // C++20
}

// Bad: memcpy on a non-trivially-copyable type is UB, even if the bytes
// would "look right." The object's invariants (here: ownership of `data`)
// require move/copy construction, not bytewise duplication.
struct Buffer {
    std::byte*  data;
    std::size_t size;
    ~Buffer() { delete[] data; }                // user-defined dtor -> not trivial
};
static_assert(!std::is_trivially_copyable_v<Buffer>);

void relocate_buffer_bad(Buffer* src, Buffer* dst) {
    std::memcpy(dst, src, sizeof(Buffer));      // UB: double-free at destruction
}

// Document the moved-from state on your own types. The standard guarantees
// only that the destructor and assignment work; anything readable about the
// value is your contract.
class Identifier {
public:
    Identifier() = default;
    explicit Identifier(std::string name) noexcept : name_{std::move(name)} {}

    Identifier(Identifier&& other) noexcept
        : name_{std::exchange(other.name_, std::string{})} {}

    // Moved-from contract (documented): an Identifier moved from is empty()
    // and compares equal to a default-constructed Identifier. Safe to assign
    // to or destroy. Reading `name()` is also defined — it returns "".
    bool empty() const noexcept { return name_.empty(); }
    std::string_view name() const noexcept { return name_; }

private:
    std::string name_;
};
```

## Caveats

- **Standard types often over-specify** the moved-from state. Moved-from
  `unique_ptr` is guaranteed null; moved-from `string` is "valid but
  unspecified" by the standard, though every mainstream implementation leaves
  it empty in practice. Rely on what the standard promises, not what your
  library happens to do.
- **Trivially copyable is narrower than it looks.** A class that *contains*
  any non-trivially-copyable subobject is not trivially copyable. A virtual
  destructor or any user-declared destructor disqualifies the class. Check
  with `static_assert`, not by inspection.
- **`std::memmove` has the same precondition** as `memcpy` with respect to
  C++ object lifetime, plus tolerance for overlap. It is not a license to
  copy non-trivially-copyable objects.
- **P1144 trivial relocation is forward-looking.** A type-trait-tagged
  relocation primitive (as Unreal Engine has) is a defensible
  *implementation-internal* technique; do not export it across module
  boundaries as if it were standard until it is.

## References

- Richard Smith, P0135R1, "Guaranteed copy elision through simplified value
  categories" (C++17) —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2016/p0135r1.html>
- Arthur O'Dwyer, P1144R9, "Object relocation in terms of move plus destroy"
  — <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2023/p1144r9.html>
- Howard Hinnant, *Everything You Ever Wanted to Know About Move Semantics*,
  CppCon 2014 / ACCU 2016 — <https://www.youtube.com/watch?v=vLinb2fgkHk>
- cppreference, `std::is_trivially_copyable` and `std::bit_cast` —
  <https://en.cppreference.com/w/cpp/types/is_trivially_copyable>,
  <https://en.cppreference.com/w/cpp/numeric/bit_cast>
