+++
id = "CONC.5"
title = "For SPSC patterns, no CAS is needed — relaxed indices with one acquire/release handoff"
category = "concurrency"
status = "draft"
summary = "Single producer, single consumer is the easy concurrency case. Each side owns its index; relaxed loads on its own index; one release/acquire pair on the cross-side index. No atomic RMW, no contention."
tags = ["spsc", "ring-buffer", "atomic", "lock-free"]
+++

## Rationale

The single-producer / single-consumer (SPSC) pattern is the easiest
concurrent data-handoff to make correct and the easiest to make fast. The
geometry is the source of both: exactly one writer touches each index,
exactly one reader touches it, and the writer and reader are different
threads. No two contexts ever modify the same variable, so **no
read-modify-write atomic is needed**. The expensive cache-line-exclusivity
operation that dominates atomic RMW cost (`CONC.3`) simply does not
occur.

The minimal SPSC ring buffer needs two indices, `head` (producer) and
`tail` (consumer), and a fixed-capacity backing array. Each side performs
only:

- A **relaxed** load of its own index (no cross-thread visibility
  required — it wrote this value most recently).
- A **relaxed** or **acquire** load of the *other* side's index (to
  check space / availability).
- A plain (non-atomic) write or read of the slot itself.
- A **release** store of its own index to publish the new slot's
  contents.

That is one acquire and one release per operation, both on indices that
live on separate cache lines (each padded per `CACHE.1`). Folly's
`folly::ProducerConsumerQueue` is the canonical permissive-licensed
implementation. Boost.Lockfree's `spsc_queue` is a close cousin.

The pattern generalises along two axes: SPSC ring (here), SPSC stream
(producer batches into a buffer, swaps it with the consumer at frame
boundaries — the `MEM.4` double-buffered allocator pattern applied to
concurrency), and SPSC futex-wake (producer signals via futex when the
queue was empty).

## Guidance

When you can structure the handoff as **exactly one producer and
exactly one consumer**, use an SPSC ring buffer.

- **One thread per side, no exceptions.** SPSC correctness relies on it.
  If a second producer can appear (even rarely), the design must move
  to MPSC or be guarded by a producer-side mutex.
- **Pad the indices to separate cache lines** (`CACHE.1`). Without that,
  every consumer read of `tail` invalidates the producer's `head` line
  and the design is no faster than a contended atomic.
- **Use `std::atomic` for the indices**, but the orders are simple:
  - Own index: `relaxed` (load) and `release` (store on publish).
  - Other side's index: `acquire` (load before reading / writing slots).
- **Slot reads / writes are plain.** The release / acquire on the
  cross-side index already synchronises them.
- **Size the capacity offline.** A bounded SPSC queue has a clear
  full / empty signal; the right response to "full" is producer-defined
  (drop, wait, escalate), not a hidden overflow.
- **Reach for the library first.** Folly's `ProducerConsumerQueue` is
  audited, exception-safe, and benchmark-proven. Use it; the hand-rolled
  version below is for understanding, not production.

## Example

```cpp
// A bounded SPSC ring. One producer thread calls write(); one consumer
// thread calls read(). Each owns one index; each acquires the other's
// for the availability check. No atomic RMW anywhere.
template <class T, std::size_t Capacity>
class SpscRing {
    static_assert((Capacity & (Capacity - 1)) == 0,
                  "Capacity must be a power of two for the mask trick");
public:
    bool write(T value) noexcept {
        const auto head = head_.load(std::memory_order_relaxed);
        const auto next = (head + 1) & (Capacity - 1);
        if (next == tail_.load(std::memory_order_acquire)) return false;  // full
        slots_[head] = std::move(value);                    // plain write
        head_.store(next, std::memory_order_release);       // publish
        return true;
    }

    bool read(T& out) noexcept {
        const auto tail = tail_.load(std::memory_order_relaxed);
        if (tail == head_.load(std::memory_order_acquire)) return false;  // empty
        out = std::move(slots_[tail]);                      // plain read
        tail_.store((tail + 1) & (Capacity - 1),
                    std::memory_order_release);             // publish
        return true;
    }

private:
    // Padding keeps the producer's head and consumer's tail on distinct
    // cache lines — without this, every read of one side invalidates the
    // other and the design is no faster than a contended atomic.
    alignas(std::hardware_destructive_interference_size)
        std::atomic<std::size_t> head_{0};
    alignas(std::hardware_destructive_interference_size)
        std::atomic<std::size_t> tail_{0};
    alignas(std::hardware_destructive_interference_size)
        std::array<T, Capacity> slots_{};
};

// Production: use Folly's ProducerConsumerQueue (Apache-2.0). It handles
// the corner cases — non-trivial T, exception safety on assignment,
// power-of-two vs arbitrary capacity, futex-wake variants — that the
// snippet above leaves to the reader.
//
//   folly::ProducerConsumerQueue<Packet> rx_queue{1024};
//   if (!rx_queue.write(p)) { /* full */ }
//   Packet p; if (rx_queue.read(p)) { /* got one */ }
```

## Caveats

- **Exactly one producer and one consumer.** Two producers, even
  briefly, break the design — the indices race. If you need
  multi-producer or multi-consumer, see Folly's `MPMCQueue` or
  moodycamel's `ConcurrentQueue` (`CONC.6` cross-references).
- **Indices must be on different cache lines.** Without padding, the
  producer's head and consumer's tail false-share (`CACHE.1`); the
  design then behaves like a contended atomic.
- **`T` must be safely movable / copyable between threads.** Plain
  trivial types are easiest; non-trivial types need a `noexcept` move
  to keep the queue exception-safe.
- **Bounded SPSC must define its full / empty policy.** Drop, block,
  resize — pick one, document it, do not pretend the queue cannot fill.
- **Cache-line bouncing is reduced, not zero.** Each cross-side read
  still pulls the *index* line across cores. Batching (write or read N
  items at a time, publish once) amortises this; high-frequency one-at-
  a-time SPSC still costs the line transfer per direction.

## References

- `folly::ProducerConsumerQueue` (Apache-2.0) —
  <https://github.com/facebook/folly/blob/main/folly/ProducerConsumerQueue.h>
- Boost.Lockfree `spsc_queue` —
  <https://www.boost.org/doc/libs/release/doc/html/lockfree.html>
- Dmitry Vyukov, *Single-Producer / Single-Consumer Queue* —
  <https://www.1024cores.net/home/lock-free-algorithms/queues/single-producer-single-consumer-queue>
- Anthony Williams, *C++ Concurrency in Action* 2e, chapter 7
  (lock-free queues) — **cite-by-reference**.
- Cross-reference: `CACHE.1` (cache-line padding), `MEM.4` (double-
  buffered allocator — the SPSC pattern applied to allocation lifetime),
  `CONC.3` (the contention curve that motivates the SPSC restriction).
