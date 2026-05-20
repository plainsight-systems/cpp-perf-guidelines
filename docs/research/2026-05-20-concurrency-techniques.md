# C++ Concurrency — Memory Effects, Atomics Cost, and Lock-Free Patterns — Technique Extraction

Research note — 2026-05-20. Supports packet
`2026-05-20-concurrency-category-buildout`. Technique-extraction pass for the
`concurrency` category — what each source actually teaches (the rule, the
cost, the anti-pattern), not bibliography. `CACHE.1` already addresses false
sharing as a *layout* concern; this note covers the broader concurrency-
memory story. Sources are classified per the `CONTRIBUTING.md` sourcing rule:

- **Citable** — free public talk / paper / blog (link is the citation).
- **Cite-by-reference** — copyrighted book / paid standard.
- **Study-only code** — proprietary or non-permissive.
- **Permissive code** — MIT / BSD / Apache-2.0 / similar.

---

## 1. Memory model foundations

### Boehm, "Threads cannot be implemented as a library" (HP Labs TR, 2004) — Citable

Treating threads as a pure library on top of a sequential language is
fundamentally unsound. The compiler, knowing nothing of threads, can
introduce data races into race-free programs through:

- Speculative stores (writing through a location to spill a register, even
  when the source program never writes that location on the executed path).
- Adjacent-field rewrites (writing a 32-bit word to update a bitfield,
  clobbering a neighbouring field another thread is writing).
- Register promotion across loops (hoisting a load out of a loop where
  another thread expects to see updates).

**Anti-pattern this kills:** "pthreads-only" reasoning, where developers
assumed `volatile` or function-call boundaries would prevent reordering.
They do not. The conclusion drove the C++11 / C11 memory model.

### Boehm & Adve, "Foundations of the C++ Concurrency Memory Model" (PLDI 2008) — Citable

Defines the happens-before / synchronizes-with edge structure that
underpins `[intro.races]`. Key technique: **data-race-freedom (DRF) as a
contract** — if the program contains no data race under sequential
consistency, the implementation guarantees SC behaviour (SC-for-DRF).
Programs with races have *undefined behaviour*, not "implementation-
defined" or "tearing." Atomics are the only way to communicate
non-synchronisation data between threads without UB.

### `[intro.races]` and `[atomics]` (C++ working draft)

The six memory orders, formally:

| Order | Synchronisation edge | x86 cost | ARMv8 cost |
|---|---|---|---|
| `relaxed` | none beyond atomicity | plain load / store | plain load / store |
| `consume` | dependency-ordered-before | (deprecated; promoted to acquire) | (same) |
| `acquire` | synchronizes-with paired release on load | plain load | `LDAR` |
| `release` | synchronizes-with paired acquire on store | plain store | `STLR` |
| `acq_rel` | both, on RMW | `LOCK`-prefixed RMW | `LDAXR`/`STLXR` loop or `LDADDAL` |
| `seq_cst` | total order across all SC ops | `LOCK XCHG` / `MFENCE` after store | `STLR` + `DMB ISH` or `LDAR` + `DMB ISH` |

**P0668 ("Revising the C++ memory model")** documents the cost asymmetry on
Power / ARM and provides the corrected SC-store mapping. **`consume` was
deprecated in practice**: no compiler tracks dependency chains correctly,
so every implementation silently strengthens `consume` to `acquire`. The
committee deprecated the semantics in P0371; P2055 / P0750 continue
revisiting it.

## 2. The real cost of atomic operations

### Preshing on Programming (Jeff Preshing) — Citable

On **x86 (TSO)**, all loads are acquire and all stores are release *for
free* — the hardware does not reorder load-load, load-store, or store-
store; only store-load is reordered. So `relaxed`, `acquire`, and `release`
cost the same as plain accesses for aligned, naturally-sized scalars.
`seq_cst` stores require an `MFENCE` or a `LOCK`-prefixed op.

On **ARMv8**, the hardware is weakly ordered. `LDAR` / `STLR` (added in
ARMv8) implement acquire / release directly; `DMB ISH` is needed for
`seq_cst`. The cost gap between relaxed and seq_cst is much larger on ARM
than on x86.

**Atomic RMW cost is dominated by cache-line exclusivity acquisition**,
not by the instruction itself. An uncontended `lock cmpxchg` is ~15–30
cycles on modern x86; a contended one with bouncing between cores costs
hundreds to thousands of cycles per attempt.

### Sutter, "atomic<> Weapons" (C++ and Beyond 2012, two parts) — Citable

The **SC-DRF default rationale:** `seq_cst` is the default because it is
the only model most humans can reason about; relaxing it requires proof
obligations. Includes concrete mapping tables (what `std::atomic` ops
compile to on x86, IA64, ARM, Power). The "publication / consumption"
idiom: a `release` store of a pointer paired with an `acquire` load is the
canonical way to publish an immutable structure.

### Williams, *C++ Concurrency in Action* 2e — Cite-by-reference

Chapters 5 ("The C++ memory model and operations on atomic types") and 7
("Designing lock-free concurrent data structures") are the practical
reference. Specific techniques:

- The "release sequence" rule — why a chain of RMW operations on the same
  variable continues to propagate the release.
- A worked SPSC queue using only `relaxed` for indices plus a single
  `acquire` / `release` pair for the data handoff.
- Implementation of a lock-free stack with leaked nodes, then with hazard
  pointers, then with reference-counted nodes — **reclamation, not the
  push / pop logic, is the hard part**.

### Pikus, "Lockless Algorithms for the Common Programmer" (CppCon 2017) and "The Speed of Concurrency" (CppCon 2016) — Citable

Empirical RMW cost curves: a single core doing CAS in a tight loop
sustains hundreds of millions of ops / sec; two cores contending on the
same line drop to a few million combined; eight cores to under one
million. **Throughput collapses non-linearly with contender count.**

The "atomic counter as global bottleneck" anti-pattern; sharded counters
or per-thread counters with a periodic merge are 1–2 orders of magnitude
faster under contention. **Lock-free is about progress guarantees, not
throughput.**

### Tony Van Eerd, "Lock-Free by Example" / "Postmodern Immutable Data Structures" (CppCon) — Citable

The design discipline of writing lock-free code by proving each
linearisation point and each invariant under interleaving. Immutable
persistent data structures sidestep most of the problem — the only atomic
op is the root-pointer swap.

## 3. Cache-coherency cost (MESI / MOESI)

### Intel 64 / IA-32 Optimization Reference Manual

A cache line in `M` (Modified) on one core, requested by another, must
transition through the coherence protocol: invalidate the source, transfer
the line, install in the requester. On modern Intel parts this is **~30–
100 cycles for L3-resident lines, 100–300+ cycles for cross-socket
transfers**.

`LOCK`-prefixed RMW operations require the line in `M` state; if it is `S`
or `I`, the core must first acquire exclusivity. This is the same
mechanism that causes false-sharing slowdowns (cross-reference `CACHE.1`);
the difference is that *deliberate* sharing of a contended atomic is
unavoidable — only the access frequency and contention can be reduced.

### ARM Architecture Reference Manual (ARMv8-A)

ARMv8 introduces `LDAR` / `STLR` (load-acquire / store-release) as
one-shot ordered ops, replacing the older `LDREX` / `STREX` + `DMB`
sequences. ARMv8.1 adds atomic RMW instructions (`LDADD`, `LDCLR`, `SWP`,
`CAS`) that avoid the `LDREX` / `STREX` retry loop — dramatically faster
under contention because they execute in the cache controller rather than
requiring a successful exclusive monitor. `DMB ISH` (inner shareable) is
the standard SMP barrier; `DSB` is heavier (drains the pipeline); `ISB`
flushes the instruction pipeline (rarely needed for data synchronisation).

## 4. Lock-free data structures

### Folly (Apache-2.0) — Permissive code

- **`folly::ProducerConsumerQueue`** — SPSC bounded ring. Uses `relaxed`
  for index loads on the owning side, `acquire` / `release` for the
  cross-thread index reads. **No CAS anywhere** — the SPSC advantage.
- **`folly::MPMCQueue`** — bounded MPMC using per-slot turn-based
  sequencing (a Vyukov variation). Each slot has a sequence number;
  producers and consumers `CAS` on a global ticket then wait until their
  slot's sequence matches.
- **`folly::DistributedMutex`** — cache-line-local mutex with per-waiter
  request lists; reduces the bouncing of a single lock word.
- **`folly::SharedMutex`** — reader-writer lock with a fast path for
  readers using thread-local slots.

### moodycamel `ConcurrentQueue` (BSD-2) — Permissive code

Practical MPMC unbounded queue using per-producer sub-queues plus a
work-stealing-style consumer that scans producer slots. Hybrid: lock-free
common path, mutex only on producer-list growth. The `ProducerToken` /
`ConsumerToken` API amortises per-op overhead — a technique worth
borrowing.

### libcds (Boost License) — Permissive code

Reference implementations of Michael–Scott queue, Harris–Michael lock-free
list, Fraser's skip list, lock-free hash maps. Couples each with its
required reclamation strategy (hazard pointers, epoch-based, user-space
RCU).

### Intel TBB / oneTBB (Apache-2.0) — Permissive code

`concurrent_queue`, `concurrent_hash_map`, `concurrent_vector` — production
lock-free / partial-lock containers. The TBB work-stealing scheduler:
per-thread deques, owner pushes / pops at the bottom, thieves pop from
the top. The deque operations require careful CAS protocols (Chase-Lev
deque).

### Herlihy & Shavit, *The Art of Multiprocessor Programming* — Cite-by-reference

The formal theory: linearisability; wait-freedom vs lock-freedom vs
obstruction-freedom; the universal construction; ABA; hazard pointers;
the Michael–Scott queue with proof. Required reading; not citable as
text.

## 5. Reclamation: hazard pointers and RCU

### P2530 (hazard pointers) and P2545 (RCU)

Two canonical solutions to "a lock-free pop unlinks a node; when can I
free it?"

- **Hazard pointers** — each thread publishes a small array of
  "currently dereferencing" pointers. A retiring thread scans all hazard
  slots before freeing. O(threads × hazards) per reclamation; bounded
  memory.
- **RCU** — writers replace pointers; readers are wrapped in "RCU
  read-side critical sections" delimited by quiescent states; memory is
  freed only after all readers have passed a quiescent state. Excellent
  for read-mostly workloads.

### McKenney, *Is Parallel Programming Hard, And, If So, What Can You Do About It?* — Citable (free PDF)

Complete treatment of RCU semantics, including `rcu_read_lock` /
`rcu_dereference` / `synchronize_rcu` / `call_rcu`. Writers do not block
readers; readers do not synchronise at all on the read path. Also defines
the Linux kernel memory model (LKMM), which is stricter and more
operational than the C++ model.

## 6. NUMA locality

Cross-socket DRAM access on modern x86 is **1.5–2× the latency** of local
DRAM and roughly halves bandwidth; on multi-socket POWER or large AMD
EPYC parts the ratio can reach 3–10× depending on hop count.

Techniques:

- `numactl --membind` / `--cpunodebind` for whole-process pinning.
- `mbind()` / `set_mempolicy()` for per-region policy; `MPOL_BIND` or
  `MPOL_PREFERRED`.
- **First-touch allocation**: physical page is allocated on the node that
  first writes to it. Zeroing a large buffer from one thread anchors it to
  that thread's node. *Anti-pattern:* allocate from a main thread, then
  access from worker threads on other nodes.
- The Linux kernel's auto-NUMA-balancing periodically migrates pages
  toward the threads touching them, but this is reactive and lossy;
  explicit placement wins for latency-critical work.

## 7. Spinlocks vs mutexes vs lock-free

Rule of thumb (Williams, Pikus, Sutter agree):

- Expected wait < context-switch cost (~1–5 μs on Linux): **spin**.
- Expected wait > context-switch cost or unknown: **mutex** (which on
  Linux is futex-based — spins briefly, then sleeps).
- **Hybrid:** spin with a bounded budget, then `yield()` or `futex_wait`.
  `std::mutex` in libstdc++ already does this internally on x86_64.

**Anti-pattern:** raw spinlock on a system with preemption and
oversubscription — the lock holder can be descheduled while everyone else
burns CPU. Priority inversion on real-time systems is worse. MCS locks
(queue-based; each waiter spins on a thread-local flag) avoid the
lock-line bouncing of a naive `test_and_set` spinlock and are the textbook
fix. Ticket locks are FIFO but bounce the ticket counter; MCS locks are
FIFO and bounce only the predecessor's flag.

## 8. `std::atomic_ref` (C++20)

Atomic access to *existing* non-atomic storage — useful for atomically
updating a single field in a large POD without redesigning the type, for
bridging C ABIs that expose plain `int` arrays you need to update
concurrently, and for GPU-style algorithms where a buffer is mostly
accessed non-atomically with occasional atomic ops. Constraint: the
storage must satisfy the alignment requirement of the corresponding
`std::atomic<T>`, which may exceed `alignof(T)`. Bryce Adelstein Lelbach
has CppCon talks covering `atomic_ref` and its interaction with
`std::execution` (P2300).

## 9. Contention and back-off

Under N contenders, a naive CAS loop wastes O(N²) work because each failed
attempt invalidates all other contenders' lines. **Exponential back-off**
(random delay doubling on each failure) reduces this to roughly
O(N log N). MCS and CLH queue locks reduce it to O(N) by serialising
waiters on local flags.

When hand-rolled back-off is worth it: only when profiling shows the
atomic line is the bottleneck *and* there are many contenders. For ≤2
contenders, naive CAS is fine. For >8, redesigning to remove contention
(sharding, batching, per-thread state) almost always beats tuning
back-off.

## 10. Naughty Dog job system (Gyrling, GDC 2015) — Citable

Lockless job queue per worker thread; jobs migrate via work-stealing.
Synchronisation between jobs uses *counters* (atomic decrement; when it
reaches zero a continuation fibre is scheduled). Avoids mutexes on the
critical path entirely; the only OS sync primitives are the semaphores
that put idle worker threads to sleep.

**Lesson:** structure work so synchronisation is rare and coarse; lock-
free is the means, not the goal.

## 11. The canonical anti-pattern

"Lock-free is faster than mutex." It is not, in general. A `std::mutex`
on Linux holds for ~25 ns uncontended (futex fast path). A lock-free MPMC
queue's enqueue is 50–200 ns under no contention and degrades under
contention just like a mutex.

Lock-free is appropriate when:

- A blocked thread holding a mutex would block the system (real-time,
  signal handlers, priority inversion risk).
- Forward-progress guarantees matter for correctness.
- The contention pattern is reader-heavy (RCU, seqlocks).

Otherwise: **measure**. A coarse-grained mutex around a well-designed
batch operation routinely outperforms a fine-grained lock-free structure.

## Sources

### Citable

- Boehm, "Threads cannot be implemented as a library," HP Labs HPL-2004-209 — <https://www.hpl.hp.com/techreports/2004/HPL-2004-209.pdf>
- Boehm & Adve, "Foundations of the C++ Concurrency Memory Model," PLDI 2008 — <https://www.hpl.hp.com/techreports/2008/HPL-2008-56.pdf>
- C++ working draft (`[intro.races]`, `[atomics]`) — <https://eel.is/c++draft/intro.races>; <https://eel.is/c++draft/atomics>
- P0668, "Revising the C++ memory model" — <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2018/p0668r5.html>
- P0371 / P2055 / P0750 on `memory_order_consume` deprecation — <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2016/p0371r1.html>
- P2530 (hazard pointers) — <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2024/p2530r3.pdf>
- P2545 (RCU) — <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2024/p2545r4.pdf>
- Sutter, *atomic<> Weapons* (C++ and Beyond 2012) — <https://herbsutter.com/2013/02/11/atomic-weapons-the-c-memory-model-and-modern-hardware/>
- Pikus, "Lockless Algorithms for the Common Programmer," CppCon 2017 — <https://www.youtube.com/watch?v=ZQFzMfHIxng>
- Pikus, "The Speed of Concurrency," CppCon 2016 — <https://www.youtube.com/watch?v=9hJkWwHDDxs>
- Van Eerd, *Lock-Free by Example*, CppCon — <https://www.youtube.com/watch?v=sWeOREgNrHg>
- McKenney, *Is Parallel Programming Hard, And, If So, What Can You Do About It?* — <https://mirrors.edge.kernel.org/pub/linux/kernel/people/paulmck/perfbook/perfbook.html>
- Gyrling, *Parallelizing the Naughty Dog Engine Using Fibers*, GDC 2015 — <https://www.gdcvault.com/play/1022186/Parallelizing-the-Naughty-Dog-Engine>
- Preshing on Programming (memory ordering series) — <https://preshing.com/archives/>
- Intel 64 / IA-32 Optimization Reference Manual — <https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html>
- ARM Architecture Reference Manual (ARMv8 / v9) — <https://developer.arm.com/documentation/ddi0487/latest>
- AMD64 Architecture Programmer's Manual — <https://www.amd.com/system/files/TechDocs/40332.pdf>

### Cite-by-reference

- Williams, *C++ Concurrency in Action* 2e, Manning 2019.
- Herlihy & Shavit, *The Art of Multiprocessor Programming* 2e, Morgan
  Kaufmann 2020.

### Permissive code

- Folly (Apache-2.0) — <https://github.com/facebook/folly>
- moodycamel ConcurrentQueue (BSD-2) — <https://github.com/cameron314/concurrentqueue>
- libcds (Boost License) — <https://github.com/khizmax/libcds>
- Intel TBB / oneTBB (Apache-2.0) — <https://github.com/uxlfoundation/oneTBB>
- liburcu — **cite-by-reference** (LGPL) — <https://liburcu.org/>
