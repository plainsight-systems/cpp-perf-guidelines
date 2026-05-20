+++
id = "CONC.3"
title = "Atomic RMW under contention collapses non-linearly — shard, batch, or stay single-writer"
category = "concurrency"
status = "draft"
summary = "An uncontended atomic CAS is ~15-30 cycles on x86; under N contenders, throughput drops to O(1/N) or worse and per-op latency reaches thousands of cycles. The fix is to remove the contention, not optimize the CAS."
tags = ["atomic", "rmw", "contention", "false-sharing", "sharding"]
+++

## Rationale

A read-modify-write (RMW) atomic — `fetch_add`, `compare_exchange`,
`exchange` — requires **cache-line exclusivity** before it can modify the
value. On a single core in a tight loop, modern x86 sustains hundreds of
millions of CAS ops per second; the line lives in `M` state on the
issuing core. Add a second core contending on the same line and the line
bounces — each acquisition costs a coherence transaction
(~30–100 cycles for L3-resident transfers, 100–300+ for cross-socket).
Add eight contenders, and throughput drops to under a million combined
ops per second, with per-op latency in the thousands of cycles.

Pikus's empirical curves (CppCon 2016, 2017) and the formal
multiprocessor literature converge on the same shape: a naive CAS loop
under N contenders wastes **O(N²)** work, because each failed attempt
invalidates every other contender's line. Exponential back-off reduces
this to roughly O(N log N); queue-based locks (MCS, CLH) reduce it to
O(N) by serializing waiters on local flags. None of these recover the
single-core throughput.

The implication is mechanical: **the right answer to "this atomic counter
is slow" is almost never "tune the atomic." It is "reduce the
contention."** Sharded counters, per-thread accumulators with periodic
merge, and single-writer designs are routinely 1–2 orders of magnitude
faster.

## Guidance

- **Treat any heavily-contended atomic as a design smell.** Measure with
  `perf c2c` (Linux); look for HITM (cache-to-cache hit-miss) events on
  the line.
- **For high-rate counters and statistics**, use **per-thread shards**
  with a periodic merge — typical pattern, one atomic per thread, sum at
  read time. The read is the only contention point and it is rare.
- **For accumulators that report continuously**, **batch locally** —
  accumulate in a thread-local for some interval, atomic-add the batch
  once. Trades latency of update visibility for orders-of-magnitude
  throughput.
- **For high-rate single-writer cases**, stay **single-writer** — the
  SPSC ring buffer (`CONC.5`) has no RMW at all, just paired release /
  acquire on indices.
- **When multiple writers are inherent** — a work-stealing scheduler's
  deque, a shared accumulator — prefer **queue-based locks** (MCS, CLH)
  over naive spinlocks; they bounce only the predecessor's line, not
  the shared lock word.
- **Exponential back-off** in CAS loops helps for moderate contention,
  but past ~8 contenders the right fix is structural (shard, batch).

## Example

```cpp
// Bad: a global atomic counter that every worker hits per operation.
// Throughput is capped at the line's bounce rate — single-digit million
// ops/sec under heavy load, regardless of how many cores you have.
inline std::atomic<std::uint64_t> g_packets{0};

void on_packet_bad() {
    g_packets.fetch_add(1, std::memory_order_relaxed);   // contended line
}

// Good: per-thread sharded counter. Each thread updates a private slot
// (no contention); a reader sums the slots when it needs the total.
inline constexpr std::size_t kMaxThreads = 128;

struct alignas(std::hardware_destructive_interference_size) Slot {
    std::atomic<std::uint64_t> value{0};
};

inline std::array<Slot, kMaxThreads> g_packet_slots;

inline std::uint64_t thread_index() noexcept;   // 0..kMaxThreads-1; pinned

void on_packet() {
    g_packet_slots[thread_index()].value.fetch_add(
        1, std::memory_order_relaxed);             // own line; no contention
}

std::uint64_t total_packets() noexcept {
    std::uint64_t sum = 0;
    for (auto& s : g_packet_slots) {
        sum += s.value.load(std::memory_order_relaxed);
    }
    return sum;
}

// Each Slot occupies its own cache line (CACHE.1's padding). Writers
// never touch each other's lines; readers do the merge at observation
// time. Throughput scales with cores instead of collapsing with cores.
```

## Caveats

- **Sharding costs memory.** A counter sharded across 128 threads is
  128 × 64 B = 8 KiB instead of 8 B. Worth it for hot counters;
  wasteful for ones updated once a second.
- **Padding is necessary.** Without `alignas(hardware_destructive_interference_size)`
  the shard slots false-share (`CACHE.1`); without that the design
  reintroduces the contention it was meant to remove.
- **Merge cost is read-side.** Each read of the total sums N atomic
  loads. Cheap if reads are rare; expensive if reads are also hot —
  in that case combine sharding with a coarser periodic merge into a
  single read-side variable.
- **Back-off is for the middle case.** For ≤2 contenders, naive CAS is
  fine. For >8, sharding wins. Exponential back-off helps in between,
  and built-in lock implementations (`std::mutex`, futexes) already
  apply some form of back-off.
- **`perf c2c` shows the line, not the cause.** The same line can be
  contended because of false sharing (different fields, fix with
  padding — `CACHE.1`) or deliberate sharing (one atomic, fix with
  sharding here). The fix differs; the diagnosis tool does not.

## References

- Fedor Pikus, *The Speed of Concurrency*, CppCon 2016 —
  <https://www.youtube.com/watch?v=9hJkWwHDDxs>
- Fedor Pikus, *Lockless Algorithms for the Common Programmer*, CppCon
  2017 — <https://www.youtube.com/watch?v=ZQFzMfHIxng>
- Maurice Herlihy and Nir Shavit, *The Art of Multiprocessor Programming*
  2e — **cite-by-reference**.
- Joe Mario, *C2C: False Sharing Detection in Linux Perf* —
  <https://joemario.github.io/blog/2016/09/01/c2c-blog/>
- Cross-reference: `CACHE.1` (false sharing — the layout cause of the
  same line-bouncing symptom).
