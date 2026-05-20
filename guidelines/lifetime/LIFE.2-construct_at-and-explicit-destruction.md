+++
id = "LIFE.2"
title = "Use std::construct_at (or placement new) to begin lifetime in raw storage; pair it with explicit destruction"
category = "lifetime"
status = "draft"
summary = "For non-implicit-lifetime types, writing bytes does not create an object. Use std::construct_at (C++20) or placement new to begin the lifetime, and explicitly destroy before reusing the storage."
tags = ["placement-new", "construct_at", "destroy_at", "raii"]
+++

## Rationale

The C++ object model is not "wherever there are bytes of the right type,
there is an object." A type with any non-trivial construction — a
user-provided constructor, a virtual function, a non-trivial subobject — is
**not** implicit-lifetime, which means raw bytes are *just bytes*: writing
to them does not begin an object's lifetime, and reading through a pointer
to that type is undefined behavior even if every byte happens to match a
valid representation.

The primitive that explicitly begins lifetime is **placement new**, with
C++20's `std::construct_at` as the `constexpr`-friendly wrapper. It runs
the constructor in caller-provided storage and returns a pointer that has
the new object's lifetime status by the language's rules. The matching
primitive for ending lifetime is `std::destroy_at` (or a direct
`p->~T()`), which must precede any reuse of the storage for a different
object whose construction would observe the old one.

This is the lifetime layer that sits on top of the storage produced by
`MEM.2`'s pool, `MEM.1`'s arena, or `std::aligned_storage`'s replacement
(see `LIFE.8`). The pool gives you bytes; this guideline turns them into
objects.

## Guidance

- For any **non-implicit-lifetime type** placed in raw storage, begin its
  lifetime with `std::construct_at(ptr, args...)` (C++20) or
  `::new (ptr) T{args...}` (placement new). Storage must be properly aligned
  for `T` and at least `sizeof(T)` bytes.
- **Use the pointer the construction returns**, not a pointer to the storage
  you started from. The returned pointer has the new object's lifetime; the
  storage pointer may be stale (see `LIFE.3` on `std::launder`).
- **Explicitly destroy before reusing storage** for a different object —
  `std::destroy_at(p)` or `p->~T();`. For trivially-destructible types
  (`LIFE.1`) the destructor call is a no-op, but writing it keeps the
  discipline portable.
- For *implicit-lifetime* types (scalars, aggregates, trivially-copyable
  with trivial constructors), you do not need this — writing bytes via
  `memcpy` is enough (see `LIFE.4`).
- For trivially-copyable but *not* implicit-lifetime types over raw bytes,
  see `LIFE.5` (`std::start_lifetime_as`).

## Example

```cpp
// A tiny in-place buffer for a non-implicit-lifetime type (std::string has a
// user-provided destructor and is not implicit-lifetime, so writing bytes
// would not create one). std::construct_at begins lifetime; std::destroy_at
// ends it before the storage is dropped.
class InplaceString {
public:
    template <class... Args>
    explicit InplaceString(Args&&... args) {
        std::construct_at(ptr(), std::forward<Args>(args)...);
    }

    ~InplaceString() {
        std::destroy_at(ptr());
    }

    InplaceString(const InplaceString&)            = delete;
    InplaceString& operator=(const InplaceString&) = delete;

    std::string&       value()       noexcept { return *ptr(); }
    const std::string& value() const noexcept { return *ptr(); }

private:
    // alignas + std::byte[] (LIFE.8) — preferred over the deprecated
    // std::aligned_storage_t.
    alignas(std::string) std::byte storage_[sizeof(std::string)];

    std::string*       ptr()       noexcept {
        return std::launder(reinterpret_cast<std::string*>(storage_));
    }
    const std::string* ptr() const noexcept {
        return std::launder(reinterpret_cast<const std::string*>(storage_));
    }
};

// Why std::launder on the storage pointer? See LIFE.3: when you do not have
// the pointer construct_at returned, you must launder before access. The
// returned pointer is already laundered.
```

## Caveats

- **`std::construct_at` is `constexpr`-friendly** but otherwise equivalent
  to `::new (p) T{args...}` at runtime; pick whichever reads better. In
  generic code, `construct_at` is the portable choice.
- **`construct_at` requires brace-init** semantics that can suppress some
  conversions placement-new would accept. If you need `()`-initialization
  with narrowing, use placement-new directly.
- **The destructor is the caller's responsibility.** A pool that hands out
  slots (`MEM.2`) and never destroys is a leak; a pool that destroys twice
  is undefined behavior. The lifetime cycle is one of `LIFE.7`'s subjects.
- **Storage size and alignment must be correct.** Misaligned construction is
  UB on most ISAs and a correctness fault on ARM with strict alignment.
  Always `alignas(T)` (or stronger) the storage.

## References

- ISO C++ working draft, `[basic.life]` (object lifetime) and `[expr.new]`
  (placement new) — <https://eel.is/c++draft/basic.life>;
  <https://eel.is/c++draft/expr.new>
- cppreference, `std::construct_at` and `std::destroy_at` —
  <https://en.cppreference.com/w/cpp/memory/construct_at>;
  <https://en.cppreference.com/w/cpp/memory/destroy_at>
- C++ Core Guidelines R.13 and ES.60–ES.62 (raw memory / placement new) —
  <https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines#es60-avoid-new-and-delete-outside-resource-management-functions>
- Scott Meyers, *Effective Modern C++*, items 18–22 — **cite-by-reference**.
