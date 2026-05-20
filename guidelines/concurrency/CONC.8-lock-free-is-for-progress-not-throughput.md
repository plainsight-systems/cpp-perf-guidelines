+++
id = "CONC.8"
title = "Lock-free is for forward-progress, not throughput — measure before reaching for it"
category = "concurrency"
status = "draft"
summary = "A well-tuned std::mutex routinely outperforms a naive lock-free queue. The reason to reach for lock-free is forward-progress guarantees — real-time deadlines, signal-safety, priority-inversion avoidance — not raw speed."
tags = ["lock-free", "anti-pattern", "real-time", "mutex"]
+++

## Rationale

The most consistent misconception in concurrent C++ writing is that
*lock-free is faster than mutex-based*. It is not, in general. The
numbers:

- A `std::mutex` on Linux, uncontended, costs **~25 ns** for the
  lock + unlock — the futex fast path is a single atomic CAS plus a
  cheap branch.
- A production lock-free MPMC queue's enqueue is **50–200 ns**
  uncontended (per-slot turn-number CAS, plus the load fences, plus
  whatever waiting protocol).
- Under contention, both degrade. The mutex sleeps; the lock-free
  queue spins or retries. Throughput is workload-specific, and the
  mutex frequently wins (Pikus, CppCon 2016 — measured curves) because
  it pays one wake-up rather than N spinning CAS retries.

The reason to reach for lock-free is therefore not throughput. It is
**forward-progress guarantees** — situations where a *blocked* thread is
unacceptable for reasons external to performance:

- **Real-time deadlines.** A blocked thread holds the mutex; a deadline
  expires; the system fails. The mutex itself is fast — the *failure
  mode* is unacceptable. Lock-free guarantees that *some* thread always
  makes progress.
- **Signal handlers and ISRs.** A signal handler cannot acquire a mutex
  (most mutex implementations are not async-signal-safe, and the
  handler may run on the same thread that holds it). Lock-free
  primitives — usually a single atomic operation — are signal-safe.
- **Priority-inversion-prone systems.** A high-priority thread waiting
  on a mutex held by a low-priority thread, with a medium-priority
  thread preempting the holder, can be blocked indefinitely. Lock-free
  removes the dependency entirely. Priority-inheritance mutexes are the
  alternative.
- **Reader-heavy workloads where readers must not block writers** (or
  vice versa) — the RCU pattern (`CONC.6`).

Williams (CCiA chapter 7), Sutter ("atomic<> Weapons"), and Pikus all
arrive at the same rule: **measure before reaching for lock-free.** A
coarse-grained mutex around a well-designed batch operation routinely
outperforms a fine-grained lock-free structure. The lock-free option is
correct when the *failure mode* of blocking is unacceptable, not when
the average case is slow.

## Guidance

Before choosing lock-free over a mutex:

- **State the reason.** Real-time deadline. Signal / ISR safety.
  Priority-inversion avoidance. Reader-heavy with no-block-readers
  contract. Write the reason in the design doc; if you cannot state
  one, you do not want lock-free.
- **Measure both implementations** on a representative workload. The
  mutex version is the baseline; the lock-free version must justify
  its complexity *and* its reclamation strategy (`CONC.6`).
- **Batch where you can.** A coarse-grained mutex around a 1000-element
  batch operation beats a fine-grained lock-free that does 1000
  individual operations. Throughput is dominated by amortising the
  synchronisation cost.
- **Use the simplest lock-free shape that solves your problem.** SPSC
  (`CONC.5`) needs no CAS at all. MPSC and MPMC are progressively
  harder. Reach for a library (Folly, moodycamel, libcds) before
  hand-rolling.
- **Lock-free does not mean wait-free.** A lock-free algorithm
  guarantees that *some* thread makes progress globally; a wait-free
  algorithm guarantees that *every* thread makes progress in a bounded
  number of steps. Wait-freedom is what real-time targets typically
  need, and it is much harder to achieve.
- **Document the failure mode.** Lock-free code that fails (memory
  reclamation bug, ABA bug, ordering bug) fails subtly and far from
  the cause. The mutex version's bugs (deadlock, livelock) are noisy
  by comparison. Make the design rationale part of the artefact.

## Example

```cpp
// Baseline: a mutex around a small queue. Uncontended cost ~25 ns;
// contended cost amortised by sleeping. The right default for
// application code.
class WorkQueueMutex {
public:
    void push(Item x) {
        std::lock_guard lock{mu_};
        items_.push_back(std::move(x));
        cv_.notify_one();
    }

    Item pop() {
        std::unique_lock lock{mu_};
        cv_.wait(lock, [&]{ return !items_.empty(); });
        Item x = std::move(items_.front());
        items_.pop_front();
        return x;
    }

private:
    std::mutex              mu_;
    std::condition_variable cv_;
    std::deque<Item>        items_;
};

// Lock-free alternative: pay this complexity when you have a stated
// reason — e.g. the producer is an ISR (cannot block) or there is a
// real-time deadline on the consumer side. Otherwise the baseline wins.
//
// Use folly::ProducerConsumerQueue for SPSC (CONC.5), or
// folly::MPMCQueue / moodycamel::ConcurrentQueue for MPMC. Hand-roll
// only with proof of correctness and a reclamation strategy (CONC.6).
//
//   folly::MPMCQueue<Item> q{1024};
//   q.write(std::move(x));     // non-blocking on a full queue: returns false
//   Item out; q.read(out);     // non-blocking on empty: returns false

// The wrong reason to switch:
//
//   "The lock-free version is faster on a microbenchmark."
//
// A microbenchmark with no contention exposes the lock-free version's
// extra fences; a microbenchmark with maximum contention exposes the
// mutex's sleep / wake; neither represents a real workload. Measure
// the workload.
```

## Caveats

- **Mutex implementations vary by platform.** `std::mutex` on Linux is
  a futex; on Windows a `SRWLOCK` (or `CRITICAL_SECTION` depending on
  version); on embedded RTOSes a kernel mutex (heavier). The
  uncontended ~25 ns figure is Linux / x86_64; verify on the target.
- **Priority-inheritance mutexes (`PTHREAD_PRIO_INHERIT`)** are the
  textbook fix for priority inversion. They make the medium-priority
  preemption case work; they do not solve the *no-blocking-at-all*
  case (real-time deadlines, ISR safety).
- **A correctly written lock-free structure is still subject to memory
  ordering bugs**, the ABA problem, and the reclamation problem. The
  cost of getting these right is the cost of choosing lock-free.
- **`std::atomic_flag::test_and_set`** is the closest the standard
  library comes to a lock-free building block. It is too primitive to
  build production-quality structures on; use it for hand-rolled
  spinlocks (`CONC.4`) and reach for a library for anything more.
- **The contention regime matters.** Mutex curves and lock-free curves
  cross under different loads — moodycamel's queue beats a mutex queue
  at very high throughput on many producers; the mutex queue wins at
  moderate throughput with batching. Measure on the workload, not in
  the abstract.

## References

- Fedor Pikus, *The Speed of Concurrency*, CppCon 2016 (measured curves)
  — <https://www.youtube.com/watch?v=9hJkWwHDDxs>
- Anthony Williams, *C++ Concurrency in Action* 2e, chapter 7 —
  **cite-by-reference**.
- Herb Sutter, *atomic<> Weapons* —
  <https://herbsutter.com/2013/02/11/atomic-weapons-the-c-memory-model-and-modern-hardware/>
- Maurice Herlihy and Nir Shavit, *The Art of Multiprocessor
  Programming* 2e (formal progress definitions: lock-free vs
  wait-free) — **cite-by-reference**.
- Folly synchronization primitives —
  <https://github.com/facebook/folly/tree/main/folly/synchronization>
- Christian Gyrling, *Parallelizing the Naughty Dog Engine Using Fibers*
  (production case study: lock-free job system with counter-based
  synchronisation, not lock-free for its own sake) —
  <https://www.gdcvault.com/play/1022186/Parallelizing-the-Naughty-Dog-Engine>
- Cross-reference: `CONC.4` (when each primitive wins by wait time),
  `CONC.5` (SPSC — the easiest lock-free case), `CONC.6` (reclamation).
