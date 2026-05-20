+++
id = "CONC.7"
title = "Plan for NUMA: first-touch allocation pins pages; pin threads to nodes; avoid cross-socket DRAM"
category = "concurrency"
status = "draft"
summary = "Cross-socket DRAM is 1.5-10x slower than local DRAM. First-touch allocation anchors a page to the writing thread's node; allocate from the worker, not from main; pin threads to nodes for predictable latency."
tags = ["numa", "first-touch", "thread-pinning", "memory-locality"]
+++

## Rationale

On a multi-socket server (and on some single-socket parts with chiplet
designs — EPYC, recent Xeon SP), main memory is **NUMA**: each CPU
socket has a directly-attached pool of DRAM, and access to a remote
socket's DRAM crosses an interconnect. Concrete cost on current
hardware:

- **Local DRAM**: ~80–100 ns latency, full memory channel bandwidth.
- **Cross-socket DRAM (one hop)**: ~130–200 ns latency,
  roughly half the bandwidth.
- **Multi-hop (large EPYC, POWER)**: 3–10× the local latency.

Two mechanisms govern where pages live and which thread touches them:

- **First-touch allocation.** On Linux, a freshly mapped page has no
  physical backing; the kernel allocates a physical page on the node of
  the *first thread that writes to it*. The page then stays on that node
  until explicit migration. A buffer allocated and zeroed on the main
  thread, then handed to a worker on a different node, will run with
  cross-node DRAM access for the rest of its life.
- **Thread placement.** A thread's NUMA node is the node of the core it
  runs on; the scheduler will move it under load. Pinning a thread to a
  core via `pthread_setaffinity_np` or `taskset` keeps it on a known
  node — and keeps its first-touch allocations local.

The pattern matters most for the kind of work this corpus targets:
game-engine workers that consume large per-frame buffers; HPC kernels
that operate on multi-gigabyte arrays; database query threads that scan
shared columnar data. For sub-gigabyte working sets on a single-socket
system, NUMA effects are usually noise.

## Guidance

- **Decide whether NUMA matters for the workload.** Single-socket with
  one chiplet → ignore. Multi-socket, or multi-chiplet single-socket
  with cross-CCX latency, with large per-thread working sets → plan.
- **Allocate large buffers from the thread that will own them.**
  First-touch is per-thread; do not pre-zero a per-worker buffer from
  the main thread and then hand it off.
- **Pin worker threads to cores** on the same node as their data.
  `pthread_setaffinity_np` (Linux) or `SetThreadAffinityMask` (Windows)
  is enough; on Linux, `numactl --cpunodebind` for whole-process
  pinning.
- **For deliberately shared allocations**, set policy with `mbind()` or
  `set_mempolicy()`. `MPOL_BIND` forces a node; `MPOL_INTERLEAVE` stripes
  pages round-robin (sometimes the best default for a read-mostly
  shared structure with no clear owning thread).
- **Audit `numastat`** (`numastat -p <pid>`) to verify pages landed
  where you expected. Auto-NUMA-balancing migrates pages reactively;
  the result is lossy and you should verify, not assume.
- **One arena per NUMA node** is the canonical scalable allocator
  layout — `MEM.6`'s injected-allocator pattern applies. Each worker
  draws from the arena on its node.

## Example

```cpp
// Bad: main thread allocates and zeroes the per-worker buffers, then
// hands them out. First-touch anchored every page to node 0; workers
// on node 1 run with cross-socket DRAM for the entire job.
void launch_workers_bad(std::size_t worker_count, std::size_t buf_bytes) {
    std::vector<std::vector<std::byte>> bufs(worker_count);
    for (auto& b : bufs) b.assign(buf_bytes, std::byte{0});   // node-0 pages
    for (std::size_t i = 0; i < worker_count; ++i) {
        std::thread{[&, i] { run_worker(i, bufs[i]); }}.detach();
        // worker is scheduled on whichever node — DRAM is on node 0.
    }
}

// Good: each worker thread allocates and first-touches its own buffer.
// The kernel places those pages on the worker's node. The function pins
// the thread first so the placement is deterministic.
struct WorkerArgs { int node_id; std::size_t buf_bytes; };

void worker_main(WorkerArgs args) {
    pin_to_node(args.node_id);     // pthread_setaffinity_np to a core on the node

    // First-touch on this thread → pages allocated on this node.
    std::vector<std::byte> buf(args.buf_bytes, std::byte{0});
    run_worker(buf);
}

void launch_workers(std::size_t worker_count, std::size_t buf_bytes) {
    for (std::size_t i = 0; i < worker_count; ++i) {
        const int node = static_cast<int>(i % num_numa_nodes());
        std::thread{worker_main, WorkerArgs{node, buf_bytes}}.detach();
    }
}

// Verify with numastat after the workload settles:
//   $ numastat -p $(pidof my_app)
//                            Node 0          Node 1           Total
//   Numa_Hit         <pages touched locally>
//   Numa_Miss        <pages touched remotely>   <- the number to minimize
```

## Caveats

- **Single-socket, single-chiplet → NUMA does not exist for you.**
  Mobile CPUs and many client desktops have one node. Spending design
  effort on NUMA placement there is wasted; verify with `numactl
  --hardware` before optimizing.
- **The Linux auto-NUMA-balancer is reactive, not predictive.** It
  migrates pages toward the threads touching them, but the migration
  itself costs work and the system runs with cross-node traffic until
  it stabilises. Explicit placement wins for predictable latency;
  auto-balancing is a fallback, not a strategy.
- **Pinning conflicts with co-scheduling.** A pinned thread cannot be
  migrated off a busy core by the scheduler. If the workload has bursty
  per-node load, pinning can leave one node idle while another is
  saturated. Pin for predictability, not for throughput per se.
- **Memory bandwidth is per-channel, not per-node.** A node has finite
  memory bandwidth; saturating it from one node's workers is a
  separate bottleneck NUMA placement does not address. Watch
  `pcm-memory` (Intel) or `amd_pmu` outputs.
- **NUMA-aware allocators exist.** jemalloc has per-arena policies;
  Hoard has explicit NUMA arenas; mimalloc respects first-touch
  naturally. For the allocator-injection pattern (`MEM.6`), one arena
  per node is the canonical setup.

## References

- Christoph Lameter, *NUMA (Non-Uniform Memory Access): An Overview*,
  ACM Queue 2013 — <https://queue.acm.org/detail.cfm?id=2513149>
- Ulrich Drepper, *What Every Programmer Should Know About Memory*,
  §5 (NUMA) —
  <https://people.freebsd.org/~lstewart/articles/cpumemory.pdf>
- Linux `numactl(8)`, `numastat(8)`, `set_mempolicy(2)`, `mbind(2)` —
  <https://man7.org/linux/man-pages/man8/numactl.8.html>
- Intel optimization manual, NUMA-aware programming chapter —
  <https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html>
- jemalloc per-arena NUMA policy —
  <https://jemalloc.net/jemalloc.3.html>
- Cross-reference: `MEM.6` (one allocator interface — one arena per
  node), `MEM.7` (virtual reservation; commit lands on the touching
  thread's node).
