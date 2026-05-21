+++
id = "CONC.4"
title = "Choose spinlock, mutex, or lock-free by expected wait time"
category = "concurrency"
status = "draft"
summary = "Use spinlocks only for tiny non-preempted waits, std::mutex as the default, and lock-free only when blocking is unacceptable."
tags = ["spinlock", "mutex", "lock-free", "futex"]
+++

## Rationale

Three primitives serialize access to shared state, and each wins in a
different regime — confusing them costs more than tuning ever recovers.

- **Spinlock** — a `compare_exchange` loop that burns CPU while waiting.
  Wins when the expected wait is shorter than the cost of a context
  switch (~1–5 μs on Linux) *and* the executing context cannot be
  preempted (a pinned worker on an OS-isolated core, or an
  interrupts-disabled section). A spinlock on a preemptable thread is a
  textbook anti-pattern — if the holder is descheduled, every spinner
  burns its quantum on nothing.
- **`std::mutex`** — on Linux a *futex*: it spins briefly, then calls
  `futex_wait` to put the thread to sleep. Uncontended cost on x86_64
  is ~25 ns (a single atomic CAS plus a cheap branch). Wins for any
  wait longer than a few microseconds, and is the right default for
  most application code.
- **Lock-free** — no thread is allowed to block another. Wins when
  blocking is unacceptable (real-time deadlines, signal handlers,
  priority-inversion-prone systems) or when the workload is read-heavy
  (RCU). It is **not** faster on average — a well-tuned mutex routinely
  beats a hand-rolled lock-free queue on throughput.

Williams (`CCiA` ch. 5), Sutter ("atomic<> Weapons"), and Pikus
("The Speed of Concurrency") all converge on the same rule of thumb,
and on the same anti-pattern: reaching for spinlocks or lock-free
without measuring.

## Guidance

- **Default to `std::mutex`.** Futex-backed on Linux; the fast path is
  cheaper than most spinlocks under any non-trivial workload.
  Coarse-grained locking around a well-designed batch operation
  routinely outperforms fine-grained lock-free.
- **Use a spinlock only when all three hold:**
  - The critical section is **shorter than ~100 ns** (a few cache-line
    accesses worth of work).
  - The contending threads are **not preemptable** during the wait
    (pinned cores, kernel threads, ISR context).
  - You have measured a real bottleneck.
- **Use lock-free only with a stated reason:**
  - Real-time progress guarantee (a deadline that cannot tolerate a
    blocked priority chain).
  - Signal handler or interrupt-service routine safety (cannot acquire
    a mutex; cannot block).
  - Read-mostly workload where readers must not contend with writers
    (RCU, seqlocks).
- **Reach for a library, not a hand-roll.** Folly
  (`folly::DistributedMutex`, `folly::SharedMutex`), Intel TBB,
  moodycamel's queue, and Boost.Lockfree are audited; your first
  hand-rolled MPMC queue will not be.
- **Prefer MCS / CLH queue locks over naive spinlocks** when you do
  spin — they spin on thread-local flags and bounce only the
  predecessor's line, not the shared lock word.

## Example

```cpp
// 1. Default: std::mutex. Futex-backed on Linux; uncontended ~25 ns.
//    Right for the vast majority of cases.
class Cache {
public:
    std::optional<Value> get(Key k) {
        std::lock_guard lock{mu_};
        if (auto it = map_.find(k); it != map_.end()) return it->second;
        return std::nullopt;
    }
    void put(Key k, Value v) {
        std::lock_guard lock{mu_};
        map_.insert_or_assign(std::move(k), std::move(v));
    }
private:
    std::mutex                 mu_;
    std::unordered_map<Key, Value> map_;
};

// 2. Spinlock: only when the critical section is tiny AND threads cannot
//    be preempted while waiting. Pinned worker on an isolated core, or
//    an ISR context.
class Spinlock {
public:
    void lock() noexcept {
        while (flag_.exchange(true, std::memory_order_acquire)) {
            // Architecture-specific pause: yields to a sibling hyperthread,
            // tells the cache controller this is a busy-wait, and reduces
            // power. On x86: _mm_pause(); on ARM: __asm__ __volatile__("yield").
            cpu_relax();
        }
    }
    void unlock() noexcept {
        flag_.store(false, std::memory_order_release);
    }
private:
    std::atomic<bool> flag_{false};
};

// 3. Lock-free: when blocking is unacceptable. Use the library, not the
//    hand-roll. Example: a folly-backed SPSC queue (production-grade)
//    between an ISR-like producer and a main consumer.
folly::ProducerConsumerQueue<Packet> rx_queue{1024};   // bounded SPSC

void producer_isr_like(const Packet& p) {
    // Never blocks; returns false on full. Caller decides what to do.
    rx_queue.write(p);
}

void consumer_loop() {
    Packet p;
    while (running()) {
        if (rx_queue.read(p)) {
            handle(p);
        } else {
            std::this_thread::yield();
        }
    }
}
```

## Caveats

- **A raw spinlock under preemption is a denial-of-service.** The lock
  holder is descheduled; every other thread that wants the lock burns
  its quantum spinning. If the OS does not allow disabling preemption
  for the critical section, use a mutex.
- **`std::mutex` is futex on Linux, not on all platforms.** On Windows
  it is a `CRITICAL_SECTION` (also a spin-then-sleep hybrid). On
  embedded RTOSes it may be a heavier kernel mutex. Verify on the
  target.
- **Hand-rolled lock-free is a long-running bug source.** Memory order
  errors are subtle, target-dependent, and often invisible at code
  review. Use a library; if you must hand-roll, prove each
  linearization point.
- **Priority inversion is a real-time problem, not a hypothetical.** A
  high-priority thread waiting on a mutex held by a low-priority
  thread can be blocked indefinitely if a medium-priority thread
  preempts the holder. Use priority-inheritance mutexes
  (`PTHREAD_PRIO_INHERIT`) or design lock-free.
- **"Lock-free is faster" is the canonical anti-claim.** It is not, in
  general. Measure both before committing to lock-free, and treat
  forward-progress as the deciding criterion, not throughput.

## References

- Anthony Williams, *C++ Concurrency in Action* 2e — **cite-by-reference**.
- Herb Sutter, *atomic<> Weapons* —
  <https://herbsutter.com/2013/02/11/atomic-weapons-the-c-memory-model-and-modern-hardware/>
- Fedor Pikus, *The Speed of Concurrency*, CppCon 2016 —
  <https://www.youtube.com/watch?v=9hJkWwHDDxs>
- John M. Mellor-Crummey and Michael L. Scott, "Algorithms for Scalable
  Synchronization on Shared-Memory Multiprocessors" (MCS locks),
  ACM TOCS 1991 — <https://www.cs.rochester.edu/u/scott/papers/1991_TOCS_synch.pdf>
- Folly synchronization primitives —
  <https://github.com/facebook/folly/tree/main/folly/synchronization>
- Cross-reference: `CONC.3` (the contention curve that motivates avoiding
  fine-grained locks), `CACHE.1` (lock-word false sharing).
