+++
id = "MEM.3"
title = "Use a stack allocator with markers for nested temporary scopes"
category = "memory"
status = "draft"
summary = "When temporary allocations nest in last-in-first-out order, bump a pointer to allocate and rewind to a saved marker to free a whole scope at once."
tags = ["stack-allocator", "arena", "allocator"]
+++

## Rationale

An arena (`MEM.1`) frees everything at once. Many workloads need something
between an arena and per-object freeing: temporary allocations whose lifetimes
**nest**. Loading a level allocates working memory; loading a mesh within it
allocates more; the mesh's scratch should be reclaimed when the mesh finishes,
the level's when the level finishes — strict last-in-first-out order.

A *stack allocator* serves exactly this shape. It allocates by bumping a
top-of-stack offset, like an arena. The addition is the **marker**: a saved
copy of the current top. Freeing means *rewinding* the top back to a marker,
which reclaims — in one assignment — everything allocated since that marker was
taken. Nested scopes take nested markers and rewind in reverse.

id Tech's `Hunk` is the canonical example: a single block with a stack growing
from each end, static data from the low end and temporary data from the high
end. Unreal's `FMemStack` is a stack allocator whose `FMemMark` captures a
position and releases everything above it when it is destroyed.

## Guidance

Use a stack allocator when temporary allocations are created and released in
**LIFO order**.

- Allocate by aligning and advancing the top offset; this is as cheap as an
  arena.
- Expose `marker()` to capture the current top and `rewind(marker)` to release
  everything above it.
- Wrap marker/rewind in an **RAII scope guard** so the rewind cannot be
  forgotten and is exception-safe.
- For two independent temporary lifetimes over one buffer, consider a
  **double-ended** stack — two tops growing toward each other (the `Hunk`
  pattern). They share capacity without a fixed partition between them.
- As with an arena, the rewind does not run destructors; restrict the stack to
  trivially-destructible types or destroy objects explicitly before rewinding.

## Example

```cpp
// A linear allocator with markers. `rewind` frees, in one assignment,
// everything allocated since the matching `marker()` call.
class StackAllocator {
public:
    using Marker = std::size_t;

    StackAllocator(void* buffer, std::size_t capacity) noexcept
        : base_{static_cast<std::byte*>(buffer)}, capacity_{capacity} {}

    void* allocate(std::size_t size, std::size_t align) noexcept {
        std::size_t aligned = (top_ + align - 1) & ~(align - 1);
        if (aligned + size > capacity_) return nullptr;   // exhaustion: explicit
        top_ = aligned + size;
        return base_ + aligned;
    }

    Marker marker() const noexcept { return top_; }
    void   rewind(Marker m) noexcept { top_ = m; }

private:
    std::byte*  base_;
    std::size_t capacity_;
    std::size_t top_ = 0;   // offset of the next free byte
};

// RAII: capture a marker on entry, rewind to it on exit. Allocations made
// inside the scope are released when the scope ends — including on an
// exception.
class StackScope {
public:
    explicit StackScope(StackAllocator& a) noexcept
        : alloc_{a}, mark_{a.marker()} {}
    ~StackScope() { alloc_.rewind(mark_); }

    StackScope(const StackScope&)            = delete;
    StackScope& operator=(const StackScope&) = delete;

private:
    StackAllocator&        alloc_;
    StackAllocator::Marker mark_;
};
```

Aligning the *offset* assumes `base_` itself is aligned to at least the largest
`align` requested; allocate the backing buffer accordingly.

## Caveats

- **LIFO only.** Rewinding past memory that is still in use — because scopes
  were not closed in reverse order — silently hands out live memory again. The
  RAII scope guard makes correct nesting the path of least resistance.
- **Markers are not handles.** A marker is valid only until something below it
  is rewound. Do not store markers across frame or scope boundaries.
- **No per-object free.** A stack allocator cannot release an inner allocation
  without releasing everything above it. If lifetimes are not nested, use a
  pool (`MEM.2`) or a general allocator.
- Rewinding does not destroy objects.

## References

- Memory management in Quake — the `Hunk` allocator —
  <https://realityforge.org/Quake-III-Arena/idTech/memory.html>
- `FMemStackBase`, Unreal Engine documentation —
  <https://docs.unrealengine.com/en-US/API/Runtime/Core/Misc/FMemStackBase/index.html>
- Jason Gregory, *Game Engine Architecture*, 3rd ed., §6.2 (stack and
  double-ended stack allocators).
