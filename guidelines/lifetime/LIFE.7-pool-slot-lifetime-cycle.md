+++
id = "LIFE.7"
title = "Object-pool lifetime cycle: construct_at, destroy_at, reconstruct"
category = "lifetime"
status = "draft"
summary = "A pool gives raw bytes (MEM.2). Object lifetime in those bytes is your job: construct_at to begin, destroy_at before reuse, never dereference a stale pointer to the prior occupant."
tags = ["pool", "construct_at", "destroy_at", "object-pooling"]
+++

## Rationale

`MEM.2`'s pool allocator hands out a slot of raw bytes — properly aligned,
correctly sized, ready for one object. It does **not** hand out an object;
beginning and ending the lifetime of the object that lives in that slot is
the *user* of the pool's responsibility. Getting the cycle right is the
difference between a fast, safe pool and a quiet source of double-frees
and use-after-frees.

The cycle is one of the simplest contracts in C++:

1. **Construct** — `std::construct_at(slot, args...)` (C++20) or
   `::new (slot) T{args...}` (placement new) begins `T`'s lifetime in the
   bytes the pool returned. The returned pointer is the safe one.
2. **Use** — through the pointer the construction returned. A pointer to
   the raw storage from before construction is stale for non-trivial cases
   (see `LIFE.3`).
3. **Destroy** — `std::destroy_at(p)` (or `p->~T();`) ends `T`'s lifetime.
   Required before reusing the slot for any non-trivially-destructible
   type, and good discipline to write even for trivially-destructible
   types so the code is portable to a type change.
4. **Reconstruct** — if the slot is now to hold a `U` (possibly the same
   `T`, possibly different), `std::construct_at` begins `U`'s lifetime
   afresh. Any pointer from the prior step is now dead.

The pattern is identical whether the pool is your own `MEM.2`-style
`FixedPool`, a `std::pmr::unsynchronized_pool_resource`, or an
allocator-aware `std::vector` reallocating in place.

## Guidance

- **Always pair `construct_at` with `destroy_at`.** A slot reclaimed
  without destruction is a leak of whatever the object owned; a slot
  reclaimed twice is undefined behaviour.
- **Hold and use only the pointer the construction returned.** Stale
  pointers to the storage from before construction are dangerous (see
  `LIFE.3` for the `std::launder` rule when you must).
- **For pool nodes embedding a freelist `next` pointer in a `union` with
  the payload**: write to `next` only *after* `destroy_at`. Reading the
  payload through any prior `T*` after that point is UB.
- **Track which slots are occupied** if your pool serves more than one
  type. A typical pool either has uniform-type slots (one `T` per pool) or
  carries a per-slot type tag that `destroy_at` dispatches on.
- **In RAII-shaped wrappers**, the wrapper's destructor calls
  `destroy_at`. Do not call it twice — the wrapper's destruction is the
  reclamation event.
- **Skipping `destroy_at` is only legal for trivially-destructible types**
  (`LIFE.1`) — and even then, write it for portability; a future change
  that adds a non-trivial member will silently turn the omission into a
  leak.

## Example

```cpp
// A minimal slot wrapper that enforces the construct/use/destroy cycle.
// The pool gives raw bytes; this owns the lifetime of one object in those
// bytes.
template <class T>
class Slot {
public:
    // Begin lifetime of T in caller-provided raw storage.
    template <class... Args>
    explicit Slot(void* storage, Args&&... args)
        : p_{std::construct_at(static_cast<T*>(storage),
                               std::forward<Args>(args)...)} {}

    ~Slot() noexcept {
        if (p_) std::destroy_at(p_);     // exactly once
    }

    Slot(const Slot&)            = delete;
    Slot& operator=(const Slot&) = delete;

    Slot(Slot&& other) noexcept : p_{std::exchange(other.p_, nullptr)} {}

    Slot& operator=(Slot&& other) noexcept {
        if (this != &other) {
            if (p_) std::destroy_at(p_);
            p_ = std::exchange(other.p_, nullptr);
        }
        return *this;
    }

    T*       get()       noexcept { return p_; }
    const T* get() const noexcept { return p_; }

private:
    T* p_;   // returned by construct_at — already has T's lifetime
};

// Reconstruct in the same slot. After destroy_at, the bytes are raw again;
// construct_at begins a new object's lifetime. Any pointer to the prior
// object is dead.
void reuse_example(void* storage) {
    Widget* w1 = std::construct_at(static_cast<Widget*>(storage), 1);
    use(w1);
    std::destroy_at(w1);

    // w1 is now a dangling pointer to raw bytes. Do not dereference it.
    Widget* w2 = std::construct_at(static_cast<Widget*>(storage), 2);
    use(w2);                              // OK through w2
    std::destroy_at(w2);
}

// Freelist-in-union pattern (the MEM.2 idiom). After destroy_at, the slot
// is raw bytes again; storing the freelist `next` pointer in those bytes
// is fine. Reading through the old Widget* is UB.
union PoolNode {
    Widget   payload;
    void*    next;     // valid only when the slot is on the free list
};
```

## Caveats

- **Single-type pools are simpler.** A pool that allocates a single `T`
  needs no per-slot type tag; the destruction is just `destroy_at<T>`.
  Mixed-type pools require explicit dispatch.
- **Exception safety.** If a constructor throws, the slot's lifetime never
  began; do not call `destroy_at`. Conversely, a destructor that throws
  inside a pool's reclaim path is its own problem — mark destructors
  `noexcept` (the standard default since C++11) and assert.
- **Cross-reference `LIFE.3`.** Storage reuse with `const` or reference
  subobjects requires `std::launder` on any pointer not returned by the
  most recent `construct_at`. The cleanest rule is: do not keep stale
  pointers.
- **For `std::pmr` containers**, the construct/destroy cycle is handled by
  the container; you do not call `destroy_at` directly on its elements.
  This guideline is for hand-rolled pool wrappers.

## References

- ISO C++ working draft, `[basic.life]` (object lifetime) —
  <https://eel.is/c++draft/basic.life>
- cppreference, `std::construct_at` and `std::destroy_at` —
  <https://en.cppreference.com/w/cpp/memory/construct_at>;
  <https://en.cppreference.com/w/cpp/memory/destroy_at>
- Cross-references: `MEM.2` (pool allocator), `LIFE.2` (placement
  new / construct_at), `LIFE.3` (`std::launder`), `COPY.6` (moved-from
  state and trivially-copyable / relocatable types).
- libstdc++ `<vector>` reallocation path (the construct / destroy cycle
  in production) —
  <https://github.com/gcc-mirror/gcc/blob/master/libstdc%2B%2B-v3/include/bits/vector.tcc>
