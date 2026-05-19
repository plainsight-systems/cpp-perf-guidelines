---
id: MEM.1
title: Use an arena allocator for allocations bounded by a known scope
category: memory
status: draft
summary: For allocations whose lifetime is bounded by a frame, request, or load step, bump a pointer into a pre-reserved buffer and reset it all at once.
tags: [arena, allocator, object-pooling]
---

## Rationale

General-purpose `malloc`/`free` (and `new`/`delete`) have unpredictable cost: the
allocator walks free lists, may lock, and may fault in new pages. It also
fragments the heap over time. In game engines and embedded systems, large
populations of allocations share a single, well-known lifetime — everything
allocated during a frame is dead at the end of that frame. Paying per-object
allocation and deallocation cost for objects that all die together is wasted work.

An arena (also called a linear or bump allocator) reduces allocation to advancing
an offset and reduces deallocation of the *entire population* to resetting that
offset to zero.

## Guidance

When a set of allocations shares a lifetime bounded by a known scope (one frame,
one request, one level load):

- Reserve a single contiguous buffer **once**, at startup, sized for the worst case.
- Allocate by aligning and advancing an offset into that buffer.
- "Free" the whole scope by resetting the offset — do not free individual objects.
- Restrict the arena to **trivially destructible** types, or run destructors
  explicitly before the reset. The offset reset does not call destructors.

Do not mix allocations of different lifetimes in one arena; that defeats the
single-reset model and forces you back toward general-purpose allocation.

## Example

```cpp
class Arena {
public:
    explicit Arena(std::size_t capacity)
        : buffer_(static_cast<std::byte*>(::operator new(capacity)))
        , capacity_(capacity) {}

    ~Arena() { ::operator delete(buffer_); }

    void* allocate(std::size_t size, std::size_t align) {
        std::size_t aligned = (offset_ + align - 1) & ~(align - 1);
        if (aligned + size > capacity_) return nullptr;  // explicit failure
        offset_ = aligned + size;
        return buffer_ + aligned;
    }

    void reset() { offset_ = 0; }  // frees the entire scope at once

private:
    std::byte*  buffer_;
    std::size_t capacity_;
    std::size_t offset_ = 0;
};
```

## Caveats

- No individual deallocation: an arena is the wrong tool when objects have
  independent or unknown lifetimes.
- Non-trivial destructors must be invoked explicitly before `reset()`; forgetting
  this leaks resources owned by those objects (file handles, child allocations).
- Sizing is a hard commitment. Returning `nullptr` on exhaustion is honest, but
  callers must handle it — silently falling back to the heap hides the overflow.

## References

- [Introduction to allocators and arenas — GameDev.net](https://gamedev.net/blogs/entry/2271578-introduction-to-allocators-and-arenas/)
- [Custom C++ allocators suitable for video games — AnKi 3D Engine](https://anki3d.org/cpp-allocators-for-games/)
