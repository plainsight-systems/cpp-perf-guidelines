+++
id = "MEM.2"
title = "Use a pool allocator for many objects of one fixed size"
category = "memory"
status = "draft"
summary = "When many objects share one size and churn rapidly, serve them from a pre-allocated pool of fixed slots with an intrusive free list — O(1) allocate and free, no fragmentation."
tags = ["pool", "freelist", "allocator", "object-pooling"]
+++

## Rationale

Game engines and embedded systems allocate enormous numbers of small,
identically-sized objects that come and go constantly: particles, events,
entity components, network packets, tree nodes. Routing that traffic through a
general-purpose `malloc` pays a steep price — the allocator searches free
lists, may take a lock, and interleaves these short-lived objects with
unrelated allocations, fragmenting the heap.

A *pool allocator* removes the search entirely. It pre-allocates one block of
memory divided into fixed-size *slots*, all the same size, and tracks which
slots are free with a *free list*. Because every slot is interchangeable,
allocation is "take the first free slot" and deallocation is "return this slot
to the free list" — both O(1), both branch-light, and neither able to fragment
the pool: a freed slot can always satisfy the next request.

This is the workhorse anti-fragmentation structure in production engines.
Unreal's `MallocBinned` allocators bucket allocations into size classes and
serve each class from pages of identically-sized bins. Sony London Studio's
64-bit memory system packs sub-64-byte allocations into 16 KB pages of one size
class with *no per-allocation header at all*. The pool is that idea at its
simplest.

## Guidance

Use a pool when you have many objects of a **single fixed size** (or a small
set of sizes, one pool each) with **high churn**.

- Pre-allocate the slot block **once**. Size it for the worst-case live count.
- Maintain an **intrusive free list**: store each free slot's "next free slot"
  pointer *inside the slot's own memory*. The free list then costs no extra
  storage — a free slot's contents are unused by definition.
- Allocate by popping the free-list head; deallocate by pushing the slot back
  as the new head. Both are a handful of instructions.
- A slot must be at least `sizeof(void*)` and aligned for the pooled type.
- On exhaustion, fail **explicitly** (return `nullptr`). Do not silently fall
  back to the global heap — that hides the under-sizing.
- Run destructors yourself: returning a slot to the free list does not destroy
  the object that lived there.

A pool also gives **pointer stability**: pooled objects never move, so raw
pointers and indices into the pool stay valid for the object's lifetime.

## Example

```cpp
// A pool of fixed-size slots over a caller-provided buffer. Each free slot
// stores the address of the next free slot in its own memory — an intrusive
// free list with zero per-slot overhead. `slot_size` must be >= sizeof(void*),
// and the buffer must be aligned for the pooled type.
class FixedPool {
public:
    FixedPool(void* buffer, std::size_t slot_size, std::size_t slot_count) {
        auto* p = static_cast<std::byte*>(buffer);
        free_head_ = p;
        // Thread slot i to slot i + 1; the last slot terminates the list.
        for (std::size_t i = 0; i + 1 < slot_count; ++i) {
            void* next = p + (i + 1) * slot_size;
            std::memcpy(p + i * slot_size, &next, sizeof(next));
        }
        void* end = nullptr;
        std::memcpy(p + (slot_count - 1) * slot_size, &end, sizeof(end));
    }

    void* allocate() noexcept {
        if (free_head_ == nullptr) return nullptr;          // exhaustion: explicit
        void* slot = free_head_;
        std::memcpy(&free_head_, slot, sizeof(free_head_));  // pop the head
        return slot;
    }

    void deallocate(void* slot) noexcept {
        std::memcpy(slot, &free_head_, sizeof(free_head_));  // push the head
        free_head_ = slot;
    }

private:
    void* free_head_;
};
```

`std::memcpy` reads and writes the next-slot pointer through the slot's raw
storage; it states the intent — treat these bytes as a pointer — without the
aliasing and object-lifetime hazards of a bare `reinterpret_cast`. Callers
construct the object in the returned slot with placement `new` and destroy it
explicitly before `deallocate`.

## Caveats

- **One size only.** A pool serves a single slot size. Objects of different
  sizes need different pools, or a size-class scheme — see `MEM.5`.
- **Headerless pools cannot detect a stomp.** Storing the free-list link in the
  slot means a write past the end of one object corrupts another slot's link.
  A debug build can add guard bytes or a separate free bitmap — see `MEM.10`.
- **Exhaustion is real.** A fixed pool can run out. Decide deliberately whether
  the correct response is to fail the operation or to size the pool larger —
  never a silent heap fallback.
- **Destructors are the caller's job.** `deallocate` reclaims storage, not
  object lifetime.

## References

- Stefan Reinalter, "Memory allocation strategies: a pool allocator",
  Molecular Musings — <https://blog.molecular-matters.com/2012/09/17/memory-allocation-strategies-a-pool-allocator/>
- Jason Gregory, *Game Engine Architecture*, 3rd ed., §6.2 (pool allocators).
- "An illustrated overview of the Unreal MallocBinned2 allocator" —
  <https://rawsourcecode.io/posts/illustrated-overview-mb2-allocator-part-1>
- Aaron MacDougall, "Building a Low-Fragmentation Memory System for 64-bit
  Games", GDC 2016 — <https://media.gdcvault.com/gdc2016/Presentations/MacDougall_Aaron_Building_A_Low.pdf>
