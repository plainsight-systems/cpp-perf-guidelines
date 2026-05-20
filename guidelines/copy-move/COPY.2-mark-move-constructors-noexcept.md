+++
id = "COPY.2"
title = "Mark move constructors and move-assignment operators noexcept"
category = "copy-move"
status = "draft"
summary = "Mark move constructors and move-assignments noexcept — otherwise std::vector reallocation silently copies movable-but-not-noexcept types via move_if_noexcept."
tags = ["noexcept", "move-semantics", "trivially-copyable"]
+++

## Rationale

This is the single highest-leverage modern-C++ technique — observable, large,
silent, and default-on across every standard library. When `std::vector` (and
the other reallocating standard containers) move elements during reallocation,
they call `std::move_if_noexcept` on each element. The contract:

> `move_if_noexcept(x)` yields `std::move(x)` if `T`'s move constructor is
> `noexcept` *or* `T` has no copy constructor; otherwise it yields `const T&`.

The reason is the strong exception guarantee: if a move could throw partway
through reallocation, vector cannot restore the original buffer. So when there
is a copy constructor *and* the move might throw, vector chooses **copy**.

The consequence is invisible from the call site. A `std::vector<Buffer>` with
`Buffer` having a fast, pointer-stealing move that *might* throw, plus a deep
copy constructor, **copies** on every reallocation. The move you wrote is
never used. The bug looks like "vector is slow" — a profiler shows the copy
constructor in the hot path; the compiler emits no warning.

libstdc++, libc++, and MSVC STL all implement reallocation this way.

## Guidance

- Mark **every** move constructor and move-assignment operator `noexcept`.
- Prefer to let the compiler generate them (Rule of Zero — see `COPY.4`); the
  generated moves are `noexcept` if every subobject's move is `noexcept`.
- For a hand-written move, the body must in fact not throw — typically only
  pointer swaps, integer copies, and `std::exchange`.
- If a move genuinely cannot be `noexcept` — e.g. a contained allocator's move
  may allocate — that is a design problem to surface, not a default to accept.
  Reconsider the resource model.
- Make the property a **checkable invariant**: assert
  `std::is_nothrow_move_constructible_v<T>` at the type definition, where the
  bug originates, not at the container declaration far away.

## Example

```cpp
// Bad: the move constructor is not noexcept. std::vector reallocation calls
// std::move_if_noexcept; for a type with a copy constructor and a throwing
// move, it returns a const lvalue reference — vector COPIES instead of
// moving, regardless of how cheap the move would have been. No diagnostic.
class BufferBad {
public:
    BufferBad(BufferBad&& other) /* not noexcept */
        : data_{other.data_}, size_{other.size_} {
        other.data_ = nullptr;
        other.size_ = 0;
    }
    BufferBad(const BufferBad& other);   // expensive deep copy
    BufferBad& operator=(BufferBad&& other);          // also not noexcept
    BufferBad& operator=(const BufferBad& other);
    ~BufferBad();
private:
    std::byte*  data_;
    std::size_t size_;
};

// Good: the move operations are noexcept. std::vector reallocation moves.
class Buffer {
public:
    Buffer(Buffer&& other) noexcept
        : data_{std::exchange(other.data_, nullptr)}
        , size_{std::exchange(other.size_, 0)} {}

    Buffer& operator=(Buffer&& other) noexcept {
        if (this != &other) {
            delete[] data_;
            data_ = std::exchange(other.data_, nullptr);
            size_ = std::exchange(other.size_, 0);
        }
        return *this;
    }

    Buffer(const Buffer& other);    // still expensive, but never called by
                                    // std::vector reallocation now.
    Buffer& operator=(const Buffer& other);
    ~Buffer() { delete[] data_; }

private:
    std::byte*  data_ = nullptr;
    std::size_t size_ = 0;
};

// Check the property where it matters — at the type definition.
static_assert(std::is_nothrow_move_constructible_v<Buffer>);
static_assert(std::is_nothrow_move_assignable_v<Buffer>);
```

## Caveats

- **`noexcept` must be honest.** Declaring a move `noexcept` whose body can
  throw is a contract violation — `std::terminate` runs if an exception
  escapes. Use `noexcept` only when the body genuinely cannot throw.
- **Allocator-aware moves.** If the type owns an allocator whose move may
  allocate (e.g. a stateful allocator that must rebind on a different
  resource), the move honestly is not `noexcept`. The fix is at the resource
  model — usually by making the allocator non-propagating or holding it by
  reference — not by lying in the declaration.
- **Copy can be `noexcept` too** where applicable; the load-bearing one for
  STL container behavior is move.

## References

- Howard Hinnant, *Everything You Ever Wanted to Know About Move Semantics*,
  CppCon 2014 / ACCU 2016 —
  <https://www.youtube.com/watch?v=vLinb2fgkHk>
- Klaus Iglberger, *Back to Basics: Move Semantics*, CppCon 2021 —
  <https://www.youtube.com/watch?v=St0MNEU5b0o>
- Scott Meyers, *Effective Modern C++*, item 14 (declare functions `noexcept`
  where possible) and item 29 (assume move operations are not present, not
  cheap, and not used) — **cite-by-reference**.
- cppreference, `std::move_if_noexcept` —
  <https://en.cppreference.com/w/cpp/utility/move_if_noexcept>
- libstdc++ `<bits/vector.tcc>` reallocation path —
  <https://github.com/gcc-mirror/gcc/blob/master/libstdc%2B%2B-v3/include/bits/vector.tcc>
