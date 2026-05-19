+++
id = "MEM.8"
title = "Use std::pmr to back standard containers with a custom allocator"
category = "memory"
status = "draft"
summary = "std::pmr lets standard containers take a memory resource at runtime, so an arena or pool can back a std::vector or std::string without changing the container type."
tags = ["pmr", "allocator", "fixed-capacity-container"]
+++

## Rationale

The custom allocators in this category are powerful, but the standard
containers historically made them painful to use. A container's allocator was a
*template parameter*: `std::vector<T, ArenaAllocator>` is a distinct type from
`std::vector<T>`, so a custom allocator infected every function signature that
touched the container, and two containers with different allocators could not
interoperate.

C++17's `std::pmr` (polymorphic memory resources) removes that friction. A
`std::pmr::vector<T>`, `std::pmr::string`, or `std::pmr::unordered_map` holds a
pointer to a `std::pmr::memory_resource` chosen **at run time**, not a type
parameter. The container type is fixed regardless of where its memory comes
from — so an arena, a pool, or a plain heap can back it without changing the
container's type or any signature.

`std::pmr` is the standard, portable expression of `MEM.6` (inject the
allocator) for the standard library. The standard ships ready-made resources:
`monotonic_buffer_resource` is an arena (`MEM.1`); the pool resources are pools
(`MEM.2`).

## Guidance

Use `std::pmr` whenever you want standard containers backed by a custom
allocator.

- `std::pmr::monotonic_buffer_resource` over a caller-provided buffer is an
  arena for standard containers: every allocation bumps a pointer, nothing is
  freed until the resource is destroyed. Ideal for scoped, temporary container
  use — especially over a stack buffer.
- `std::pmr::unsynchronized_pool_resource` pools many small, similar
  allocations for single-threaded use; `synchronized_pool_resource` is the
  thread-safe variant.
- Pass the resource to the container's constructor:
  `std::pmr::vector<int> v{&resource};`.
- Resources **chain**: a resource has an *upstream* it falls back to. Set the
  upstream to `std::pmr::null_memory_resource()` to make a fixed buffer a hard
  cap that throws on overflow instead of silently reaching the heap.
- The resource is a property of the container *instance*; `std::pmr` containers
  do not adopt a source's resource on copy or move-assignment.

## Example

```cpp
// monotonic_buffer_resource turns a plain stack buffer into an arena for
// standard containers: allocations bump a pointer into the buffer, and nothing
// is freed until the resource is destroyed. With a null upstream, overflowing
// the buffer throws std::bad_alloc rather than silently allocating on the heap.
void summarize(std::span<const int> input) {
    std::array<std::byte, 8 * 1024> buffer;
    std::pmr::monotonic_buffer_resource arena{
        buffer.data(), buffer.size(), std::pmr::null_memory_resource()};

    // This vector allocates from `arena` — i.e. from the stack buffer.
    std::pmr::vector<int> scratch{&arena};
    scratch.assign(input.begin(), input.end());
    std::sort(scratch.begin(), scratch.end());
    // ... use scratch ...
}   // `arena` is destroyed: every byte scratch held is reclaimed at once —
    // no per-element free, and no heap allocation occurred at all.
```

## Caveats

- **Resource lifetime.** A `std::pmr` container stores a bare pointer to its
  resource. The resource must outlive the container — exactly the lifetime
  discipline of `MEM.6`.
- **`monotonic_buffer_resource` never frees individual allocations.** That is
  the arena contract, not a bug; do not use it for long-lived containers with
  high churn.
- **Indirection cost.** Each allocation goes through a virtual call on the
  resource. It is negligible against the cost of allocation itself, but it is
  not zero.
- **pmr is still a type boundary.** `std::pmr::vector<T>` is not
  `std::vector<T>`; code converts at the boundary. The gain is that *all* pmr
  containers share the one allocator type, instead of one type per allocator.

## References

- Pablo Halpern, "Polymorphic Memory Resources", WG21 N3916 —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2014/n3916.pdf>
- Nico Josuttis, "PMR — Polymorphic Memory Resources", isocpp.org —
  <https://isocpp.org/blog/2018/10/pmr-polymorphic-memory-resources>
- R. Kaiser, "C++17 PMR and STL for Embedded Applications", embo++ 2021 —
  <https://www.rkaiser.de/wp-content/uploads/2021/03/embo2021-pmr-STL-for-Embedded-Applications-en.pdf>
