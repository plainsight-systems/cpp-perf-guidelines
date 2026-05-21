+++
id = "CONC.6"
title = "Lock-free reclamation: hazard pointers, RCU, or leak — pick one deliberately"
category = "concurrency"
status = "draft"
summary = "Lock-free removal does not make memory safe to free. Use hazard pointers, RCU, epochs, or bulk collection to handle reclamation."
tags = ["lock-free", "hazard-pointers", "rcu", "memory-reclamation"]
+++

## Rationale

The hard part of lock-free data structures is **not** the push or the pop
— it is figuring out *when it is safe to free a node*. A lock-free pop
unlinks a node from the structure; one or more other threads may still
hold a pointer to it from before the unlink and be about to dereference.
Freeing the node then is undefined behaviour exactly the same way a
single-threaded use-after-free is. The lock-free literature converges
on three solutions, plus a fourth that is sometimes correct:

- **Hazard pointers** (Michael 2002; standardised by P2530, C++26
  candidate). Each thread publishes a small array of "currently
  dereferencing" pointers. A retiring thread scans every other thread's
  hazard slots before freeing — if its pointer is present anywhere, it
  defers the free. Bounded memory; O(threads × hazards) per reclamation.
- **Read-Copy-Update (RCU)** (McKenney, the Linux kernel canonical
  pattern; standardised by P2545). Writers replace pointers; readers are
  wrapped in "read-side critical sections" delimited by *quiescent
  states*. The retiring writer waits until every reader has passed a
  quiescent state — at which point no reader can hold a pointer to the
  retired node — and then frees. Excellent for read-mostly workloads.
- **Epoch-based reclamation**. A coarser approximation of RCU: divide
  time into epochs, each thread announces its current epoch, retired
  nodes are tagged with their epoch, free when all threads have moved
  past it. Used by Crossbeam (Rust) and by `libcds`'s epoch GC.
- **Leak, then bulk-collect at a quiescent point**. When the program has
  natural quiescent points (frame boundaries in a game engine, a
  "rebuild the index" pause in a database), simply *do not* free in the
  lock-free path; collect retired nodes into a thread-local list, free
  them all at the quiescent point when no reader is in the critical
  section. Simple, correct, and pays nothing on the hot path.

Williams (CCiA chapter 7) walks through a lock-free stack with leaked
nodes, then with hazard pointers, then with reference-counted nodes —
specifically to show that the *reclamation* layer is the load-bearing
choice. `libcds` ships all three (hazard pointers, RCU, epoch); pick by
workload, not by taste.

## Guidance

For any lock-free data structure that unlinks nodes from a shared
structure (queue, stack, hash map, skip list):

- **Choose a reclamation strategy at design time.** Do not bolt one on
  afterward — the data-structure code interacts with the reclamation
  protocol (when to publish a hazard, when to mark a quiescent state).
- **Hazard pointers** when reads are common and the number of threads is
  bounded. Bounded memory overhead; standardised path forward (P2530).
- **RCU** when reads vastly outnumber writes and writers can tolerate a
  small delay before reclamation. The read path is unsynchronised
  (load + dependency-ordered use); the write path waits for a
  grace period.
- **Epoch-based** when you want RCU's read cost without the per-call
  `rcu_read_lock` / `rcu_read_unlock` discipline. Coarser, simpler,
  used in many production systems.
- **Leak-and-bulk-collect** when the program has a natural quiescent
  point. Game-engine frame boundaries are the canonical case: deferred
  frees collect on a thread-local list and free during the next frame
  swap, when no thread is mid-pop.
- **Reach for a library**, not a hand-roll. `libcds` and Folly include
  all three of hazard pointers, RCU, and epoch GC, with the
  data-structure side already integrated.

## Example

```cpp
// A lock-free stack with leak-and-bulk-collect at a quiescent point. The
// hot path is push and pop; reclamation happens once per frame, when no
// thread is inside pop().
template <class T>
class GameStack {
public:
    void push(T value) {
        auto* node = new Node{std::move(value), nullptr};
        auto  head = head_.load(std::memory_order_relaxed);
        do {
            node->next = head;
        } while (!head_.compare_exchange_weak(head, node,
                                              std::memory_order_release,
                                              std::memory_order_relaxed));
    }

    bool pop(T& out) {
        auto* head = head_.load(std::memory_order_acquire);
        while (head &&
               !head_.compare_exchange_weak(head, head->next,
                                            std::memory_order_acquire,
                                            std::memory_order_acquire)) {}
        if (!head) return false;
        out = std::move(head->value);
        // Defer the free — head may still be referenced by a concurrent
        // pop() that loaded it before we CAS'd it out.
        retired_.push_back(head);
        return true;
    }

    // Called at a quiescent point (e.g. end-of-frame) when no thread is
    // inside pop(). At that point every concurrent loader has either
    // CAS'd a different node or has passed through pop()'s exit.
    void reclaim_at_quiescent_point() {
        for (auto* n : retired_) delete n;
        retired_.clear();
    }

private:
    struct Node { T value; Node* next; };
    std::atomic<Node*>            head_{nullptr};
    // Thread-local in real code; simplified here.
    std::vector<Node*>            retired_;
};

// For long-running services without a quiescent point, swap leak-and-
// bulk-collect for hazard pointers (P2530 / folly::hazptr) or RCU
// (folly::Synchronized + folly::RCU, or the libcds equivalents). The
// pop()'s "head still referenced" worry is the same; only the protocol
// for proving it isn't differs.
```

## Caveats

- **A lock-free data structure *without* a reclamation story leaks.**
  Leaking is sometimes correct (a fixed-size pool with no actual frees,
  for example), but it must be a *decision*, not an oversight.
- **Hazard pointers add a per-access publication.** Every dereference
  inside a critical region writes a hazard slot. The cost is small but
  not zero; for very hot read paths, RCU is often cheaper.
- **RCU has writer-side wait costs.** Synchronising with all readers
  takes microseconds-to-milliseconds depending on traffic; writers in a
  write-heavy workload pay it on every retire. Read-mostly is where RCU
  earns its keep.
- **Epoch-based reclamation has subtle correctness conditions** — a
  thread that pauses mid-critical-section without announcing its epoch
  can stall reclamation forever. Documented schemes (Crossbeam,
  libcds-epoch) handle this; rolling your own is a long-running bug
  source.
- **Reclamation is the part you copy a library for, not the algorithm.**
  Standardise on one strategy across the codebase; one place to audit
  the protocol invariants.

## References

- Maged Michael, "Safe Memory Reclamation for Dynamic Lock-Free
  Objects Using Atomic Reads and Writes" (PODC 2002) —
  <https://www.cs.toronto.edu/~tomhart/papers/tomhart_thesis.pdf>
  (background); Michael's hazard-pointers paper —
  <https://dl.acm.org/doi/10.1109/TPDS.2004.8>
- P2530R3, "Hazard Pointers for the Standard Library" —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2024/p2530r3.pdf>
- P2545R4, "Read-Copy-Update (RCU)" —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2024/p2545r4.pdf>
- Paul E. McKenney, *Is Parallel Programming Hard, And, If So, What
  Can You Do About It?* (free PDF) —
  <https://mirrors.edge.kernel.org/pub/linux/kernel/people/paulmck/perfbook/perfbook.html>
- libcds (concurrent data structures with three reclamation strategies)
  — <https://github.com/khizmax/libcds>
- Folly `hazptr` and `synchronization/Rcu.h` —
  <https://github.com/facebook/folly/tree/main/folly/synchronization>
- Anthony Williams, *C++ Concurrency in Action* 2e, chapter 7 —
  **cite-by-reference**.
