+++
id = "CACHE.8"
title = "Diagnose cache misses with the 3C taxonomy and the right profiler"
category = "cache-layout"
status = "draft"
summary = "Cache misses fall into compulsory, capacity, and conflict — three causes with three different fixes. Don't guess; ask the right counter or sweep the working set."
tags = ["profiling", "perf", "cache-miss", "diagnostics"]
+++

## Rationale

"This loop is slow" is not a diagnosis. The same symptom — a high
cycles-per-element count, low IPC, lots of LLC misses — has at least three
different root causes, each with a different fix. The textbook taxonomy
(Hill & Smith, 1989) separates them:

- **Compulsory** — the first touch of a line. The line was never in any
  cache, by definition; demand fetch fills it. Reducible only by
  *prefetching* (`CACHE.7`) or by *touching less data* (`CACHE.5`,
  `CACHE.6`).
- **Capacity** — the working set exceeds the cache level. Lines that were
  loaded earlier in the loop have been evicted to make room for newer ones,
  and we hit them again. Reducible by *blocking / tiling* (process subsets
  that fit) or by *shrinking elements* (`CACHE.5`, `CACHE.6`,
  AoS→SoA in `CACHE.4`).
- **Conflict** — distinct lines map to the same cache set because of the
  set-associative geometry, evicting each other repeatedly. Reducible by
  *padding the stride* off the bad power of two.

Each cause leaves a different fingerprint, and modern profilers can lift it
directly. The wrong diagnosis wastes work — prefetching capacity misses, or
padding compulsory misses, changes nothing.

## Guidance

Start with the cheapest, broadest counter and refine:

- **`perf stat -e cycles,instructions,cache-references,cache-misses,LLC-loads,LLC-load-misses`**
  gives the raw rate and the ratio of misses to references. High LLC miss
  rate is the trigger to look further.
- **For false sharing and conflict patterns** — `perf c2c` (Linux ≥ 4.10)
  attributes HITM (cache-line bounce) events to specific source lines. It is
  the canonical tool for confirming `CACHE.1` and conflict-set issues.
- **For capacity vs. conflict pressure** — Intel VTune's *Memory Access
  Analysis* decomposes stalls into L1 / L2 / LLC / DRAM bound and shows
  loaded-latency; AMD uProf has comparable plumbing. The bound breakdown
  tells you which level the working set exceeds.
- **For compulsory vs. capacity** — sweep the working-set size. Re-run the
  loop with N at 4 KB, 32 KB, 256 KB, 4 MB. If the miss rate jumps at the
  L1, L2, or LLC size boundary, it is **capacity** at that level. If the
  rate stays flat across the sweep, it is compulsory. If the rate is high
  and **strongly dependent on stride** (and the stride is a power of two),
  it is **conflict**.
- **Always profile on the target.** Counter names, prefetcher behaviour,
  and cache geometry differ between Intel, AMD, ARM Cortex-A, ARM Apple
  Silicon, and console silicon. A diagnosis on your laptop is not a
  diagnosis on the device.

## Example

```text
# Raw rate. High LLC-load-misses / LLC-loads means the loop is missing in
# the last-level cache; go further.
perf stat -e cycles,instructions,cache-references,cache-misses, \
                  LLC-loads,LLC-load-misses ./bench

# Confirm false sharing or hot-line bouncing. Reports HITM by source line.
perf c2c record -- ./bench
perf c2c report

# Pinpoint level-bound vs. DRAM-bound stalls (Intel).
vtune -collect memory-access -- ./bench

# Sweep working-set size to separate compulsory from capacity.
# Pseudocode for the bench driver — vary N, re-run, log the LLC miss rate.
for N in 1024 8192 65536 524288 4194304; do
    ./bench --n="$N" --report-misses
done
```

A small in-process scaffold for the working-set sweep:

```cpp
// Run the same hot loop at several working-set sizes and report the
// per-element cost. If cost stays flat across sizes, the misses are
// compulsory; if it jumps at L1/L2/LLC capacity, the misses are capacity
// at that level.
void cache_sweep(std::size_t bytes_step, std::size_t max_bytes) {
    for (std::size_t bytes = 1024; bytes <= max_bytes; bytes *= 4) {
        std::vector<std::uint8_t> buf(bytes);
        warm_up(buf);
        const auto t0 = std::chrono::steady_clock::now();
        constexpr int kPasses = 32;
        for (int i = 0; i < kPasses; ++i) hot_loop(buf);
        const auto t1 = std::chrono::steady_clock::now();
        report(bytes, t1 - t0);
    }
}
```

## Caveats

- **PMU counters are CPU-specific.** Event names and meanings vary across
  Intel, AMD, ARM Cortex-A, and Apple Silicon. Consult the platform's PMU
  guide before interpreting numbers; one platform's "LLC miss" is not
  another's.
- **Microbenchmarks lie if the working set is wrong.** A loop that fits in L1
  in the benchmark but exceeds L1 in production is the entire point of this
  guideline. Profile the *real* workload, not a stand-in.
- **Counters can disagree with wall-clock time.** Low IPC plus high LLC miss
  rate is a reliable memory-bound fingerprint; high IPC with high LLC miss
  rate usually means the loop is doing other work that hides the misses.
  Cross-check.
- **Sampling, not just counting.** `perf record -e LLC-load-misses` (sampling)
  attributes misses to source lines, not just totals — much more useful
  than `perf stat` alone for non-trivial code.

## References

- Mark D. Hill, Alan Jay Smith, *Evaluating Associativity in CPU Caches*
  (the 3C model), IEEE Transactions on Computers, 1989 —
  <https://research.cs.wisc.edu/multifacet/papers/ieeetc89_3csmodel.pdf>
- Joe Mario, "C2C: False Sharing Detection in Linux Perf" —
  <https://joemario.github.io/blog/2016/09/01/c2c-blog/>
- Intel VTune Profiler — Memory Access analysis —
  <https://www.intel.com/content/www/us/en/developer/articles/technical/vtune-cookbook.html>
- `perf-stat(1)` and `perf-c2c(1)` —
  <https://man7.org/linux/man-pages/man1/perf-stat.1.html>,
  <https://man7.org/linux/man-pages/man1/perf-c2c.1.html>
- Brendan Gregg, "CPU Profiling" / "Memory Analysis" notes —
  <https://www.brendangregg.com/perf.html>
