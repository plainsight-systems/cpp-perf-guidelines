+++
id = "MEM.5"
title = "Segregate allocations by size class and by lifetime"
category = "memory"
status = "draft"
summary = "Do not funnel every allocation through one general heap; route each request to an allocator matched to its size class and lifetime, the way production engines do."
tags = ["fragmentation", "size-class", "allocator", "object-pooling"]
+++

## Rationale

The most consistent technique across production game engines is not a
particular allocator — it is the *refusal to use one allocator for everything*.
Mixing allocations of wildly different sizes and lifetimes in one heap is what
produces fragmentation: a long-lived 2 MB texture wedged between short-lived
32-byte nodes leaves a hole no later request fits.

Every engine surveyed segregates traffic:

- **id Tech** physically separated the `Zone` (small, volatile allocations)
  from the `Hunk` (large, static data) from the `Cache` (reloadable, evictable
  data) — three allocators, three lifetime classes, one block.
- **Unreal's `MallocBinned`** buckets allocations into power-of-two **size
  classes**; a freed bin can be reused only by a same-size request, so
  small-block fragmentation cannot occur.
- **Sony London Studio** routes every request by size to a Small, Medium,
  Large, or Giant *module*, each a different allocator tuned to its class.

Two axes matter. **Size class:** equal-sized things pack without fragmenting —
this is why `MEM.2`'s pool works. **Lifetime:** things that die together should
be reclaimed together — this is why `MEM.1`'s arena and `MEM.3`'s stack work.
Sorting allocations onto these two axes is what makes the specific allocators
effective.

## Guidance

Classify each allocation by **size class** and **lifetime**, and route it to an
allocator suited to that class instead of to a general heap.

- **By lifetime:** per-frame and transient → an arena or stack (`MEM.1`,
  `MEM.3`); produced-this-frame, read-next → double-buffered (`MEM.4`);
  long-lived and fixed-size → a pool (`MEM.2`); long-lived and static → an
  arena reset only at teardown.
- **By size class:** give small, high-churn allocations their own size-classed
  pools; serve large allocations from a page-mapped allocator. Keep the two
  apart so large allocations never fragment the small ones.
- Put the size dispatch behind a single front-end allocator; let callers select
  *lifetime* through *which* allocator they are handed (see `MEM.6`).
- **Choose the class boundaries from measurement** — an allocation histogram of
  the real workload — not from a guess.

## Example

```cpp
// A front-end allocator that dispatches by size class. Each sub-allocator is
// specialized for its class: a size-classed pool for small objects, a general
// free-list for medium, a page-mapped allocator for large. Lifetime is chosen
// by callers through which allocator they are given (see MEM.6).
class GeneralAllocator {
public:
    void* allocate(std::size_t size, std::size_t align) {
        if (size <= kSmallMax) return small_.allocate(size, align);
        if (size <  kLargeMin) return medium_.allocate(size, align);
        return large_.allocate(size, align);
    }

    // deallocate dispatches the same way: each sub-allocator owns a distinct
    // address range, so the owner is recoverable from the pointer. ...

private:
    static constexpr std::size_t kSmallMax = 256;          // measured boundary
    static constexpr std::size_t kLargeMin = 64 * 1024;    // measured boundary

    SmallSizeClassPools small_;    // headerless pools, one per size class
    MediumAllocator     medium_;   // general free-list with coalescing
    LargePageAllocator  large_;    // virtual reservation + demand paging (MEM.7)
};
```

The sub-allocators are sketched, not defined: this guideline is the organizing
*principle*, and the allocators it routes to are `MEM.1`–`MEM.4` and `MEM.7`.

## Caveats

- **Do not over-segment.** Too many fixed-capacity arenas waste memory in
  unused reservations and can fail even when total free memory is ample —
  Capcom rebuilt the RE Engine allocator specifically because rigid,
  worst-case-sized segments broke its open-world titles. Segment by *class*,
  not by an ever-growing list of named buckets.
- **Boundaries are workload-specific.** The size-class cutoffs that suit one
  game will not suit another; re-measure per project.
- **The dispatch has a cost.** Keep the size test cheap and branch-predictable;
  it runs on every allocation.

## References

- Memory management in Quake — `Zone`, `Hunk`, and `Cache` —
  <https://realityforge.org/Quake-III-Arena/idTech/memory.html>
- "An illustrated overview of the Unreal MallocBinned2 allocator" —
  <https://rawsourcecode.io/posts/illustrated-overview-mb2-allocator-part-1>
- Aaron MacDougall, "Building a Low-Fragmentation Memory System for 64-bit
  Games", GDC 2016 — <https://media.gdcvault.com/gdc2016/Presentations/MacDougall_Aaron_Building_A_Low.pdf>
- "The Road to Introducing Virtual Memory Allocators", Capcom RE:2023 —
  <https://www.docswell.com/s/CAPCOM_RandD/ZXYDVM-RE2023>
