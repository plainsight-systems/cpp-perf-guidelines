+++
id = "TLM.10"
title = "Per-thread lock-free emit with a lossy ring buffer — never contend, never block the work loop"
category = "telemetry"
status = "draft"
summary = "Mature profilers converge on the same emit shape: per-thread SPSC ring buffer, drained externally, lossy on overflow. Blocking on a full buffer is denial-of-service against the work loop."
tags = ["spsc", "ring-buffer", "lossy", "tracy", "perfetto", "ctf", "lock-free"]
+++

## Rationale

The structured-event rule (`TLM.5`) covers *what* the runtime
writes; this guideline covers *how it reaches the sink*. The
emit-path shape is the single largest implementation
principle behind every profiler the corpus cites, and every
mature one converges on the same answer.

The shape:

- **Per-thread buffers.** The work thread writes to its own
  ring buffer; no cross-thread contention on the emit
  path. Each thread's buffer lives in memory it already
  owns, in cache lines no other thread is touching
  (`CONC.1`).
- **Single-producer / single-consumer queue.** Atomic head
  and tail counters with `release`/`acquire` ordering (or
  `relaxed` plus an explicit fence at the consumer side).
  No locks; no compare-and-swap loops.
- **Lossy on overflow.** When the consumer falls behind,
  the producer overwrites the oldest events rather than
  blocking. The trace is missing data; the application is
  not blocked.
- **External drain.** A dedicated sink thread, a separate
  collector process (`traced` for Perfetto, `perf` for
  the kernel ring buffer), or a post-run flush reads the
  buffer. The work thread never serialises against the
  reader.

The cost-per-event numbers from the field validate the
shape:

- **Tracy**: ~2.25 ns per zone (begin + end) on x86. The
  emit path is a fenced `rdtsc`, a struct write to the
  per-thread queue, and an atomic head increment.
- **Microprofile**: 2 MB per-thread buffers by default;
  web viewer drains them.
- **Optick**: per-thread event buffers; dedicated worker
  thread for flush.
- **Perfetto SDK**: producer-side shared-memory buffer
  between the producer process and the `traced` daemon;
  the wire ABI is documented.
- **LTTng**'s **CTF ring-buffer protocol** specifies the
  wait-free wire format formally; it is the closest thing
  to a published-schema reference for this shape.
- **Linux `perf_event_open`**: ring buffer with a
  "lost events" counter exposed to userspace; the
  canonical lossy-with-observability pattern.

### Lossy vs lossless — the production contract

The choice of behavior on overflow is the contract:

- **Lossy** — the producer overwrites the oldest events
  when the buffer is full. The consumer sees a "gap" and a
  "lost events" counter advances; the trace is incomplete
  but the application was not perturbed. **The right
  default for any build that ships, including diagnostic
  builds.**
- **Lossless** — the producer blocks (or returns an
  error) when the buffer is full. The trace is complete;
  the application stalls or fails. **Acceptable in
  development/debug runs where the trace matters more
  than throughput**, but never safe in production.

Tracy supports both via configuration; Optick is lossy by
default; perf is lossy with a counter; CTF supports both
modes. The point is: pick deliberately, label the choice,
and never let "lossless" be the unintentional default.

### Why this shape rather than alternatives

A *global* lock-free queue (multi-producer, single-consumer)
sounds cheaper than per-thread buffers — one queue, not N.
In practice the producers contend on the head counter;
under load the throughput collapses to single-threaded.
Per-thread queues with no cross-thread atomic traffic on
the hot path are the answer that survives load.

A *mutex-protected* emit queue is the wrong answer at any
scale. The mutex acquisition is the slowest part of the
emit path; on contention it serialises the worker threads
that should be doing work.

A *direct write to file / socket* per event is the wrong
answer for a different reason: a syscall per event
saturates the kernel boundary regardless of buffer
encoding.

The per-thread SPSC + external drain shape is the *only*
shape that meets the cost target the field has documented.

## Guidance

- **One ring per thread, allocated at thread creation.**
  The buffer is owned by the producer thread; the
  consumer reads from it through atomic head/tail
  counters. A worker that did not create a ring does not
  emit events.
- **Use atomic head and tail with appropriate ordering.**
  Producer: `relaxed` increment of head, `release` store
  of the event payload. Consumer: `acquire` load of head,
  `relaxed` reads of payload. Cross-reference `CONC.7`.
- **Pad the head and tail counters to separate cache lines.**
  False sharing of the producer's head and the consumer's
  tail collapses throughput to single-cycle. `alignas(64)`
  or `std::hardware_destructive_interference_size` on
  both. Cross-reference `CONC.1`.
- **Default to lossy.** Document the buffer size, the
  overflow behavior, and the "lost events" counter the
  consumer reads. Lossy + visible-loss is the right
  contract.
- **Size the buffer for the worst expected burst, not
  the average.** Allocations during a burst defeat the
  point; ring size should comfortably exceed the largest
  reasonable producer-consumer skew.
- **Drain externally, not on the work thread.** A
  dedicated sink thread (Tracy, Optick) or external
  collector process (Perfetto, perf). Work threads never
  flush, never wait on the consumer.
- **Cross-reference `MEM.*` for buffer allocation.** The
  ring should not come from the same allocator as the
  work loop; it lives for the lifetime of the thread and
  is a one-shot allocation at thread creation.

## Example

```cpp
// Good: per-thread SPSC ring buffer with cache-line-padded
// head and tail, lossy on overflow.
template <std::size_t N>
class alignas(64) EventRing {
    static_assert((N & (N - 1)) == 0, "N must be a power of two");

    struct alignas(64) Producer { std::atomic<std::uint64_t> head{0}; };
    struct alignas(64) Consumer { std::atomic<std::uint64_t> tail{0}; };

    Producer producer_;
    Consumer consumer_;
    std::array<Event, N> slots_;
    std::atomic<std::uint64_t> lost_events_{0};

public:
    // Producer side (work thread). Lossy on overflow.
    void emit(const Event& ev) noexcept {
        const auto head = producer_.head.load(std::memory_order_relaxed);
        const auto tail = consumer_.tail.load(std::memory_order_acquire);
        if (head - tail >= N) {
            // Buffer full. Two options:
            //   (a) overwrite oldest: advance both head and tail.
            //   (b) drop newest: bump lost counter, return.
            // Choosing (b) — keeps consumer's view coherent without
            // racing the consumer's tail.
            lost_events_.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        slots_[head & (N - 1)] = ev;
        producer_.head.store(head + 1, std::memory_order_release);
    }

    // Consumer side (sink thread). Single reader; drains in batches.
    std::size_t drain(std::span<Event> out) noexcept {
        const auto tail = consumer_.tail.load(std::memory_order_relaxed);
        const auto head = producer_.head.load(std::memory_order_acquire);
        const auto avail = std::min<std::size_t>(head - tail, out.size());
        for (std::size_t i = 0; i < avail; ++i) {
            out[i] = slots_[(tail + i) & (N - 1)];
        }
        consumer_.tail.store(tail + avail, std::memory_order_release);
        return avail;
    }

    std::uint64_t lost() const noexcept {
        return lost_events_.load(std::memory_order_relaxed);
    }
};

// Good: one ring per worker thread, allocated at thread start.
thread_local EventRing<1u << 14> g_event_ring;   // 16K events

void emit_zone(std::uint16_t name_handle, std::uint8_t kind) noexcept {
    g_event_ring.emit(Event{
        .timestamp_ns = monotonic_ns_fenced(),    // TLM.9
        .name_handle  = name_handle,
        .kind         = kind,
    });
}

// Bad: global mutex-protected queue. Under contention this
// becomes the slowest part of the work loop.
class GlobalQueueBad {
    std::mutex                 mu_;
    std::vector<Event>         events_;

public:
    void emit(const Event& ev) {
        std::lock_guard<std::mutex> g(mu_);   // contention!
        events_.push_back(ev);                // may allocate!
    }
};

// Bad: direct file I/O per event. One syscall per event
// saturates the kernel boundary regardless of payload size.
void emit_to_file_bad(const Event& ev) noexcept {
    std::ofstream trace("trace.bin", std::ios::app | std::ios::binary);
    trace.write(reinterpret_cast<const char*>(&ev), sizeof(ev));
    // open, write, close per event — orders of magnitude
    // slower than a ring buffer drained externally.
}
```

## Caveats

- **Per-thread buffers cost memory proportional to thread
  count.** A 16K-event ring × 32 threads × 32-byte event =
  16 MB. For embedded with tight memory, shrink the ring
  and accept higher loss rates; for servers, the cost is
  trivial.
- **Lossy is invisible without instrumentation.** A trace
  missing the most interesting events because the
  consumer was slow looks the same as a trace where
  nothing interesting happened. The lost-events counter
  must be visible in the analyzer.
- **The sink thread is itself a profiled artefact.**
  Naming the sink thread (`TLM.4`) and excluding it from
  CPU-only aggregations is part of the contract.
- **SPSC is harder than it looks.** Memory ordering on
  the head/tail counters is the entire correctness
  question. A `relaxed` store on the producer where
  `release` was needed corrupts the consumer's reads in
  ways that are hard to reproduce. Use a vetted SPSC
  implementation (Folly's `ProducerConsumerQueue`,
  Tracy's internal queue, rigtorp/SPSCQueue) unless the
  use case demands a custom one.
- **False sharing of head and tail is the classic bug.**
  If both counters share a cache line, every producer
  store invalidates the consumer's loaded copy and vice
  versa; throughput collapses. `alignas` discipline is
  mandatory, not aspirational.
- **Burst behaviour matters more than average.** A
  bursty producer (a render frame, a decode step) can
  fill a buffer that handles the average rate ten times
  over. Size for bursts; measure the worst observed
  occupancy in CI.
- **Shared-memory rings across processes are different.**
  Perfetto's producer/`traced` ABI uses shared memory
  and is documented; rolling your own across-process
  SPSC is significantly harder than within-process.

## References

- Tracy Profiler — per-thread lock-free queue; ~2.25 ns
  per zone — <https://github.com/wolfpld/tracy>
- Tracy manual — buffer model, lossless mode caveats —
  <https://github.com/wolfpld/tracy/blob/master/manual/tracy.tex>
- Microprofile — per-thread buffers (2 MB default) —
  <https://github.com/jonasmr/microprofile>
- Optick — per-thread event buffers and worker drain —
  <https://github.com/bombomby/optick>
- Perfetto SDK, *Track Events* — producer/`traced` shared
  memory ABI —
  <https://perfetto.dev/docs/instrumentation/track-events>
- LTTng / CTF, *Ring buffer protocol* —
  <https://lttng.org/docs/>
- Linux `perf_event_open(2)` — ring buffer and lost-events
  semantics — <https://man7.org/linux/man-pages/man2/perf_event_open.2.html>
- Erik Rigtorp, *SPSCQueue* — vetted single-header SPSC
  implementation — <https://github.com/rigtorp/SPSCQueue>
- Folly `ProducerConsumerQueue` —
  <https://github.com/facebook/folly>
- Cross-reference: `TLM.5` (record format the ring
  carries), `TLM.9` (timestamp source — the fenced read
  on the emit path), `CONC.1` (cache-line padding to
  avoid false sharing of head/tail), `CONC.7` (acquire/
  release semantics on the head/tail counters),
  `MEM.*` (ring allocation lifetime — created once at
  thread start, not per-event).
