+++
id = "CACHE.1"
title = "Pad independently-written shared fields to a cache line"
category = "cache-layout"
status = "draft"
summary = "When two threads write distinct variables that share a 64-byte cache line, MESI coherency bounces the line between cores; separate hot fields onto their own lines."
tags = ["false-sharing", "alignment", "cache-line"]
+++

## Rationale

Caches transfer memory in fixed-size lines, typically 64 bytes. Coherency
protocols such as MESI track ownership at line granularity, not variable
granularity. When two threads running on two cores write to *distinct* variables
that happen to occupy the *same* line, each write invalidates the other core's
copy of the whole line. The line ping-pongs between cores even though there is no
real data dependency between the two variables.

This is **false sharing**. It can erase the scaling benefit of multithreading
entirely: code that should speed up with more cores instead slows down.

## Guidance

For fields written by different threads — per-thread counters, per-core
accumulators, hot flags in a shared struct — place each on its own cache line:

```cpp
struct alignas(std::hardware_destructive_interference_size) PerCoreCounter {
    std::atomic<std::uint64_t> value{0};
};
```

Use `std::hardware_destructive_interference_size` (C++17) as the alignment. Where
it is unavailable, `alignas(64)` is a reasonable portable approximation for
mainstream x86-64 and AArch64.

The same applies to fields *inside* one struct: separate the producer-written
field from the consumer-written field with explicit padding so they never share a
line.

## Example

```cpp
// False sharing: both counters live in one 64-byte line.
struct Bad {
    std::atomic<std::uint64_t> produced;
    std::atomic<std::uint64_t> consumed;   // written by a different thread
};

// Fixed: each counter owns its line.
struct Good {
    alignas(std::hardware_destructive_interference_size)
        std::atomic<std::uint64_t> produced;
    alignas(std::hardware_destructive_interference_size)
        std::atomic<std::uint64_t> consumed;
};
```

## Caveats

- Padding costs memory. A struct of eight `uint64_t` counters grows from 64 bytes
  to 512. Apply this only to fields that are genuinely hot and written by
  different threads.
- **Read-mostly** shared data does not suffer false sharing — shared reads keep
  the line in a shared coherency state with no invalidation. Do not pad it.
- Measure first. False sharing is real but frequently misdiagnosed; confirm with
  a profiler (HITM events) before padding.

## References

- [Performance Implications of False Sharing — CoffeeBeforeArch](https://coffeebeforearch.github.io/2019/12/28/false-sharing-tutorial.html)
- [C++ Performance: False Sharing, MESI, and Padding — StudyPlan](https://www.studyplan.dev/concurrency-vectorization/cache-coherency-false-sharing)
