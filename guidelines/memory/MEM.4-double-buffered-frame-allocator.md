+++
id = "MEM.4"
title = "Use a double-buffered allocator for data that crosses one frame"
category = "memory"
status = "draft"
summary = "When data computed this frame is consumed next frame, allocate it from two arenas swapped each frame so last frame's results stay valid exactly long enough."
tags = ["frame-allocator", "double-buffer", "arena", "allocator"]
+++

## Rationale

A per-frame scratch allocator — an arena reset at the end of every frame — is
one of the most effective tools an engine has: transient work costs a pointer
bump and is reclaimed for free at the frame boundary. But it has a sharp edge.
Some data computed in frame *N* is not consumed until frame *N+1*: a visibility
result handed to next frame's render, a physics contact list, a network
snapshot awaiting acknowledgement. Reset a single arena at the end of frame *N*
and that data is gone before its reader runs.

A *double-buffered allocator* solves this without giving the data a longer,
heap-managed life. It holds **two** arenas. Each frame, one is *current* and
one is *previous*. Allocations go to the current arena; reads of last frame's
hand-off data come from the previous arena, which is still intact. At the frame
boundary the two are swapped and the new current is reset. Data therefore lives
for **exactly two frames** — long enough for next frame to read it, no longer.

Sony London Studio's memory system uses exactly this for GPU scratch: a
double-buffered, atomically-protected allocator with no individual
deallocation. Per-frame and double-buffered allocators recur in every engine
surveyed.

## Guidance

Use a double-buffered allocator for data with a **produce-this-frame,
consume-next-frame** lifetime.

- Hold two linear/arena allocators. Allocate only from the *current* one.
- At a single, well-defined point per frame — after the frame's work, before
  the next begins — **swap** current and previous, then **reset** the new
  current.
- Data a later frame must read should be allocated *before* the swap and read
  *after* it, from what is then the previous buffer.
- Keep one double-buffered allocator **per thread** that needs one; that keeps
  allocation lock-free. Do not share one across threads behind a lock.
- Size each buffer for one frame's worst-case hand-off plus scratch.

This is the right tool *only* for the two-frame lifetime. Data that must live
longer belongs in a pool (`MEM.2`) or a general allocator; data that never
crosses a frame needs only a single-frame arena (`MEM.1`).

## Example

```cpp
// Two arenas. `flip()` is called once per frame: it swaps current/previous and
// clears the new current. Memory allocated before a flip stays valid until the
// *next* flip — that is, for exactly one further frame.
//
// StackAllocator is the linear allocator from MEM.3; only its bump-allocate
// and rewind-to-empty behavior is used here.
class DoubleBufferedAllocator {
public:
    DoubleBufferedAllocator(void* buf_a, void* buf_b, std::size_t capacity)
        : arena_{{buf_a, capacity}, {buf_b, capacity}} {}

    // Allocate from the current frame's buffer.
    void* allocate(std::size_t size, std::size_t align) noexcept {
        return arena_[current_].allocate(size, align);
    }

    // The previous frame's buffer — valid to read until the next flip().
    StackAllocator& previous() noexcept { return arena_[current_ ^ 1]; }

    // Call once per frame, at the frame boundary.
    void flip() noexcept {
        current_ ^= 1;
        arena_[current_].rewind(0);   // 0 == empty: reclaim the new current
    }

private:
    StackAllocator arena_[2];
    int            current_ = 0;
};
```

## Caveats

- **Exactly two frames, no more.** A pointer into the previous buffer is
  dangling after the next `flip()`. Never retain double-buffered memory beyond
  one frame hand-off.
- **One flip point.** Calling `flip()` from more than one place, or at an
  ill-defined time, makes lifetimes unpredictable. Flip once, at a fixed point
  in the frame loop.
- **Per thread.** Sharing one double-buffered allocator across threads
  reintroduces the locking it exists to avoid. Give each producer thread its
  own.
- Resetting a buffer does not run destructors.

## References

- Aaron MacDougall, "Building a Low-Fragmentation Memory System for 64-bit
  Games", GDC 2016 (frame and GPU-scratch allocators) —
  <https://media.gdcvault.com/gdc2016/Presentations/MacDougall_Aaron_Building_A_Low.pdf>
- Robert Nystrom, *Game Programming Patterns*, "Double Buffer" —
  <https://gameprogrammingpatterns.com/double-buffer.html>
- Jason Gregory, *Game Engine Architecture*, 3rd ed., §6.2 (single-frame and
  double-buffered allocators).
