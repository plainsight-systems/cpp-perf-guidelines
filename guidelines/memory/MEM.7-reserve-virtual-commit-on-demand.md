+++
id = "MEM.7"
title = "Reserve virtual address space, commit physical pages on demand"
category = "memory"
status = "draft"
summary = "On 64-bit, reserve a large contiguous virtual range up front and commit physical pages only as they are touched — fragmentation moves to abundant address space."
tags = ["virtual-memory", "allocator", "fragmentation"]
+++

## Rationale

On a 64-bit process, virtual address space is effectively unlimited — hundreds
of terabytes — while physical RAM remains scarce. This asymmetry is a tool. The
classic allocator problem is fragmentation of *physical* memory: free blocks
exist, but none is contiguous enough for the next request. If allocation is
expressed in terms of *virtual* addresses, the problem changes shape:
fragmentation becomes address-space fragmentation, and address space is
something there is plenty of.

The technique: **reserve** a large contiguous virtual range up front — which
consumes no physical memory, only address space — and **commit** physical
pages (map RAM to those addresses) lazily, only for the regions actually
touched. **Decommit** pages when a region falls idle to return the RAM.

This is now standard in production engines. Capcom rebuilt the RE Engine
allocator around decoupling virtual from physical addressing — once physical
pages can be gathered from anywhere in a vast virtual space, fragmentation
"becomes negligible." Sony London Studio's Large module reserves 160 GB of
virtual space and maps/unmaps 64 KB pages on demand, guaranteeing contiguous
virtual memory with no fragmentation. Unreal's `MallocBinned3` reserves a
virtual range per size class and commits OS pages within it on demand.

## Guidance

Use virtual reservation for **large** or **growth-prone** allocations.

- Reserve the maximum plausible size as virtual address space at creation. The
  reservation is cheap — no RAM, just page-table bookkeeping.
- Commit physical pages as allocation advances past the committed high-water
  mark; commit in page-size multiples.
- Decommit regions that go idle to return physical memory while keeping the
  virtual reservation.
- A growable buffer built this way **never moves**: because the virtual range
  is contiguous and fixed, growth commits more pages in place — no
  reallocate-and-copy, and pointers stay stable.
- This is the foundation of asset streaming: reserve a virtual slot per asset,
  map pages as it loads, unmap on eviction — never copy or defragment.

The OS primitives: Windows `VirtualAlloc` with `MEM_RESERVE` then `MEM_COMMIT`
(and `VirtualFree` with `MEM_DECOMMIT`); POSIX `mmap` with `PROT_NONE` to
reserve then `mprotect` to commit (or `mmap`/`madvise` with `MADV_DONTNEED` to
decommit). Isolate these behind a small platform layer.

## Example

```cpp
// Reserve a large contiguous virtual range up front (no physical memory used),
// then commit physical pages only as allocation advances. The reservation is
// fixed and contiguous, so allocated pointers never move. os_reserve and
// os_commit wrap the platform calls named above.
class VirtualArena {
public:
    VirtualArena(std::size_t max_capacity, std::size_t page_size)
        : page_size_{page_size}
        , reserved_{max_capacity}
        , base_{static_cast<std::byte*>(os_reserve(max_capacity))} {}

    void* allocate(std::size_t size, std::size_t align) {
        std::size_t aligned = (used_ + align - 1) & ~(align - 1);
        if (aligned + size > reserved_) return nullptr;   // reservation exhausted

        // Commit physical pages up to the new high-water mark.
        std::size_t needed = aligned + size;
        if (needed > committed_) {
            std::size_t commit_to = round_up(needed, page_size_);
            os_commit(base_ + committed_, commit_to - committed_);
            committed_ = commit_to;
        }
        used_ = needed;
        return base_ + aligned;
    }

private:
    static std::size_t round_up(std::size_t n, std::size_t m) noexcept {
        return (n + m - 1) / m * m;
    }
    std::size_t page_size_;
    std::size_t reserved_;
    std::size_t committed_ = 0;   // bytes backed by physical pages
    std::size_t used_      = 0;   // bytes handed out
    std::byte*  base_;
};
```

## Caveats

- **This is a 64-bit technique.** A 32-bit process has no address space to
  spare; do not reserve large ranges there.
- **Page granularity.** Commit and decommit operate on whole pages (commonly
  4 KB; reservations are 64 KB-granular on Windows). Sub-page precision is not
  available.
- **Reservations are cheap, not free.** They consume page-table entries and
  count against OS limits and overcommit policy; do not reserve absurd ranges
  per object.
- **Decommit timing is a tuning problem.** Decommit too eagerly and pages
  thrash back in; too lazily and RAM is wasted. Measure.
- This serves large allocations. Tiny objects still belong in pools (`MEM.2`);
  route by size (`MEM.5`).

## References

- "The Road to Introducing Virtual Memory Allocators", Capcom RE:2023 —
  <https://www.docswell.com/s/CAPCOM_RandD/ZXYDVM-RE2023>
- Aaron MacDougall, "Building a Low-Fragmentation Memory System for 64-bit
  Games", GDC 2016 — <https://media.gdcvault.com/gdc2016/Presentations/MacDougall_Aaron_Building_A_Low.pdf>
- `FMallocBinned3`, Unreal Engine documentation —
  <https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Core/FMallocBinned3>
