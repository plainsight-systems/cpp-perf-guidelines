+++
id = "LIFE.8"
title = "Prefer alignas(T) std::byte[sizeof(T)] over the deprecated std::aligned_storage"
category = "lifetime"
status = "draft"
summary = "std::aligned_storage and std::aligned_union are deprecated in C++23 (P1413). The replacement is a direct alignas(T) std::byte[sizeof(T)] buffer — equivalent, more obvious, and not deprecated."
tags = ["alignas", "aligned-storage", "placement-new", "p1413"]
+++

## Rationale

`std::aligned_storage` and `std::aligned_union` were the C++11 "give me a
buffer that can hold one `T`" wrappers. They are deprecated in C++23 by
P1413, on three grounds that the standardisation committee made explicit:

- **Defaults are quietly wrong.** `std::aligned_storage_t<sizeof(T)>`
  defaults the alignment to `alignof(std::max_align_t)`, *not*
  `alignof(T)` — an under-alignment trap for any type with stronger
  alignment than the platform default (16 B-aligned SIMD types, `alignas`-
  decorated classes, atomics with stricter alignment than `T` would
  otherwise have).
- **The result is a type, not an object.** Reasoning about the lifetime
  contract is harder than it needs to be: the wrapper hides a `union` with
  padding inside, and the user still has to placement-new into a member.
- **The replacement is shorter.** `alignas(T) std::byte buf[sizeof(T)]` —
  one line, two well-known primitives, no wrapper.

The standard's own implementation of `std::aligned_storage` in libstdc++,
libc++, and MSVC STL is exactly an `alignas` + array of bytes. There is no
optimisation, no portability, and no clarity lost by writing it directly.

This is a small but real porting concern: a codebase reaching for
`std::aligned_storage_t` today is using deprecated machinery whose default
can silently under-align.

## Guidance

- **In new code**, write `alignas(T) std::byte buf[sizeof(T)]` (or
  `alignas(T) unsigned char buf[sizeof(T)]`). Pair with
  `std::construct_at` / placement new (`LIFE.2`).
- **In existing code targeting C++20 or later**, replace
  `std::aligned_storage_t<sizeof(T), alignof(T)>` and
  `std::aligned_storage_t<sizeof(T)>` (note: the second form is the wrong
  one — under-aligned for many `T`) with the `alignas` + `std::byte[]`
  pattern.
- **For "either-`T`-or-`U`" storage**, the pattern is the same with the
  larger of `sizeof(T)`, `sizeof(U)` and the strictest of `alignof(T)`,
  `alignof(U)` — or just use `std::variant<T, U>`, which manages this for
  you. `std::aligned_union` was the wrapper for this and is deprecated
  alongside `aligned_storage`.
- **For "give me a single `T` later", reach first for `std::optional<T>`**.
  It already handles the storage, the engaged bit, and the
  construction / destruction cycle. Drop to raw `alignas`+`std::byte[]`
  only when `optional`'s contract does not fit.

## Example

```cpp
// Deprecated since C++23. The default alignment is alignof(std::max_align_t),
// not alignof(T) — an under-alignment trap for types with stricter
// alignment than the platform default.
template <class T>
struct InplaceBad {
    std::aligned_storage_t<sizeof(T)> storage;   // default alignment: WRONG
    // ... placement-new into &storage ...
};

// Preferred. alignas(T) is exactly what is meant. std::byte makes the
// "this is raw storage" intent explicit; alignment is correct by
// construction. Same machinery; same codegen.
template <class T>
class Inplace {
public:
    template <class... Args>
    explicit Inplace(Args&&... args) {
        std::construct_at(ptr(), std::forward<Args>(args)...);
    }

    ~Inplace() {
        std::destroy_at(ptr());
    }

    Inplace(const Inplace&)            = delete;
    Inplace& operator=(const Inplace&) = delete;

    T*       get()       noexcept { return ptr(); }
    const T* get() const noexcept { return ptr(); }

private:
    alignas(T) std::byte storage_[sizeof(T)];

    T*       ptr()       noexcept {
        return std::launder(reinterpret_cast<T*>(storage_));
    }
    const T* ptr() const noexcept {
        return std::launder(reinterpret_cast<const T*>(storage_));
    }
};

// Quick check: alignment and size match T exactly.
static_assert(alignof(Inplace<Widget>) >= alignof(Widget));
static_assert(sizeof(Inplace<Widget>)  >= sizeof(Widget));
```

## Caveats

- **`std::aligned_storage_t` is deprecated, not removed.** Existing code
  compiles and works (with the alignment trap above). The migration is
  about hygiene and avoiding the silent under-alignment, not about urgent
  brokenness.
- **Use `std::byte` over `unsigned char` for new code.** Both are
  byte-addressable and both work; `std::byte` (C++17) is the typed-as-bytes
  spelling and signals intent. `char` (signed) is the wrong choice.
- **`alignas(T)` cannot be weaker than `T`'s natural alignment.** It can be
  stronger — useful for SIMD types (`alignas(32)` for `_mm256`) or
  cache-line padding (`alignas(std::hardware_destructive_interference_size)`,
  per `CACHE.1`).
- **Pair with `std::construct_at` and `std::launder` correctly** (`LIFE.2`,
  `LIFE.3`). Raw `alignas`+`std::byte[]` is *just storage*; it is not an
  object until you construct in it, and the laundering rules apply when
  you access it through a pointer not returned by the construction.

## References

- P1413R3, "Deprecate `std::aligned_storage` and `std::aligned_union`"
  (C++23) —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2022/p1413r3.pdf>
- cppreference, `std::aligned_storage` (deprecation note) —
  <https://en.cppreference.com/w/cpp/types/aligned_storage>
- cppreference, `alignas` and `std::byte` —
  <https://en.cppreference.com/w/cpp/language/alignas>;
  <https://en.cppreference.com/w/cpp/types/byte>
- Cross-references: `LIFE.2` (`std::construct_at`), `LIFE.3`
  (`std::launder`), `CACHE.1` (`hardware_destructive_interference_size`).
