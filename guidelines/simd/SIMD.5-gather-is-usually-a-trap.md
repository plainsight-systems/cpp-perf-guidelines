+++
id = "SIMD.5"
title = "Gather is usually a trap — restructure to linear loads, or block the access"
category = "simd"
status = "draft"
summary = "Vector gather (VGATHERDPS, NEON LD1 lanes, SVE LDR-gather) issues N scalar loads behind a vector facade. The width is vectorised; the memory traffic is not. Re-lay the data instead."
tags = ["gather", "scatter", "soa", "indirection", "memory-bandwidth"]
+++

## Rationale

The vector gather instruction looks like a memory operation: one
opcode, one vector result, N elements pulled from N addresses computed
from an index vector. The microarchitectural reality is different.
Intel's `VGATHERDPS` (AVX-2 / AVX-512) decodes to a microcode
sequence that issues, in the worst case, one cache-line probe per
element; AMD Zen 1–3 implementations were slower still; Zen 4
improved the case but did not match a contiguous load. On NEON, the
"gather" pattern is even more explicit: there is no single
instruction — code emits per-lane `LD1` or `LDR` and then `MOV` /
`INS` the result into a lane. SVE's `LD1<W>{,GATHER}` is a true
instruction but pays the same memory cost: every element is its own
cache-line access, no spatial locality.

The cost model:

- **Contiguous load (`VMOVAPS` / `LDR Q`):** one cache line per
  16 (AVX-2) / 64 (AVX-512) bytes — saturates L1 bandwidth.
- **Gather of `float`s from random indices:** up to 16 cache-line
  accesses per AVX-512 vector — *16× the memory traffic* per
  result.
- **Gather with locality (most indices hit the same line):** modern
  microarchitectures coalesce these. Still slower than a contiguous
  load; sometimes by an integer factor, not a 10×.

This is why gather is a trap. The vector width hides the per-element
cost. A benchmark that compares "scalar loop" against "gather loop"
on a *random* index set may report no speed-up despite an 8× or 16×
vector width. The gather *is* working; the memory subsystem is doing
N independent loads regardless of the gather facade.

Restructuring is the answer, in this order of preference:

1. **Re-lay the data to be linear.** If the access pattern can be
   anticipated at construction time, sort or re-pack the consumed
   data so the inner loop reads it contiguously (`CACHE.4`).
2. **Block / tile the access.** If the indices are sparse but
   *locally* clustered (e.g., spatial-hash neighbour lookups), block
   the outer loop into tiles that fit in L1; within a tile, the
   gather degenerates to a small number of cache lines (this is the
   classic indexed-grid case).
3. **Two-pass: gather to dense, then vectorise.** Issue a scalar
   gather *outside* the vector loop into a temporary contiguous
   buffer, then run a contiguous-load vector loop over the buffer.
   Pays the gather cost once; runs the vector loop at full
   throughput.
4. **Last resort — leave it scalar.** A scalar loop with prefetch
   hints is often faster than a "vectorised" gather loop.

The same logic applies to **scatter**: the AVX-512 `VSCATTERDPS`
issues per-element store-buffer entries; the per-vector cost scales
with the number of distinct cache lines written. Scatter is even
more fragile because it interacts with store-forwarding and the
L1 write-combine paths.

## Guidance

- **Before reaching for `VGATHER` / `VSCATTER` / scalar-emulated
  gather, ask: can the data be re-laid so the loop loads
  contiguously?** This is almost always the right fix and pays back
  every iteration of every subsequent run.
- **If indices are *clustered locally* (spatial, temporal),
  block the outer loop into tiles** so the gather sees a small
  number of cache lines per iteration. The "gather" is then almost
  contiguous within the tile.
- **If indices are *random*, prefer a two-pass:** scalar gather into
  a dense temporary; then run the vector kernel over the dense
  buffer. The first pass is memory-bound but predictable; the second
  pass runs at vector throughput.
- **Measure, do not assume.** "Gather works on AVX-512" is true; "the
  gather instruction is fast" is a microarchitecture claim. Check
  the throughput / latency numbers for your specific CPU
  (`uops.info` / Agner Fog) and benchmark with realistic index
  distributions.
- **Constant-stride access is *not* a gather.** A loop reading
  `x[i*stride]` with `stride` known at compile time can be expressed
  as strided loads + shuffles, which the vectoriser can handle. If
  the stride is small (2–8), this is usually fine; if large
  (≥ cache-line / element-size), it becomes a gather in disguise.
- **Cross-reference `CACHE.4` (AoS vs SoA vs AoSoA) and `SIMD.2`
  (SoA for linear loads).** A gather-shaped loop is often a symptom
  of AoS data being read in vector contexts.

## Example

```cpp
// Bad: gather pattern. positions[] is AoS, indices[] is random;
// the inner loop issues one cache-line probe per element. On
// AVX-512 this is 16× the memory traffic of a contiguous load.
namespace bad {
    struct Particle {
        float x, y, z;  // AoS — gather-hostile
        float padding;
    };

    void sum_selected_x(const Particle* particles,
                        const std::uint32_t* indices,
                        std::size_t n,
                        float* out_sum) noexcept {
        float s = 0.0f;
        // Compiler may emit VGATHERDPS over particles[indices[i]].x;
        // each element pulls a separate cache line.
        for (std::size_t i = 0; i < n; ++i) {
            s += particles[indices[i]].x;
        }
        *out_sum = s;
    }
}

// Good (option A — re-lay the data): switch to SoA so the consumed
// field is its own contiguous array. If the access is still indexed,
// the gather is on `xs[]` directly — better, but still N loads.
// The real win is when the *consumer* can iterate `xs[]` linearly
// (the index lookup goes away).
namespace good_a {
    struct ParticlesSoA {
        std::vector<float> xs, ys, zs;
    };

    void sum_all_x(const ParticlesSoA& p, float* out_sum) noexcept {
        // Contiguous load on xs[]; vectorises trivially.
        float s = 0.0f;
        for (float x : p.xs) s += x;
        *out_sum = s;
    }
}

// Good (option B — two-pass): scalar gather into a dense
// buffer, then a contiguous-load vector reduction. The first pass
// is memory-bound but predictable; the second runs at AVX-512
// throughput. Pays back when the inner loop does meaningful work.
namespace good_b {
    void process_selected(const Particle* particles,
                          const std::uint32_t* indices,
                          std::size_t n,
                          float* out) noexcept {
        // Pass 1: dense gather (scalar, predictable).
        std::vector<float> dense_x(n);
        for (std::size_t i = 0; i < n; ++i) {
            dense_x[i] = particles[indices[i]].x;
        }

        // Pass 2: vector kernel on dense buffer (contiguous loads).
        for (std::size_t i = 0; i < n; ++i) {
            out[i] = some_expensive_kernel(dense_x[i]);
        }
    }
}

// Good (option C — tile the access): when indices cluster locally
// (e.g., spatial-hash neighbour iteration), block the outer loop
// so the gather within a tile is small.
namespace good_c {
    constexpr std::size_t TILE = 64;  // tune to L1 line count

    void neighbour_kernel(const Particle* particles,
                          const std::uint32_t* indices,
                          std::size_t n) noexcept {
        for (std::size_t base = 0; base < n; base += TILE) {
            const std::size_t end = std::min(base + TILE, n);
            // Within a tile, indices[base..end] are locally clustered;
            // the "gather" hits a small working set still hot in L1.
            for (std::size_t i = base; i < end; ++i) {
                do_work(particles[indices[i]]);
            }
        }
    }
}
```

## Caveats

- **Gather is not categorically slow.** On Sapphire Rapids and
  Zen 4 with well-behaved indices (most hits in the same cache
  line), `VGATHERDPS` is fast enough to be useful. The "trap" is
  unprincipled use against a random index set.
- **Constant-stride loops are not gathers.** A vectoriser-friendly
  stride pattern (`x[2*i]`, `x[4*i]`) compiles to strided loads + a
  shuffle, not a gather.
- **AVX-512 gather is faster than AVX-2 gather, but not faster than
  a contiguous load.** Microbenchmarks that compare gather widths
  miss the point; the comparison is gather vs *not gather*.
- **Scatter is worse than gather** on every microarchitecture that
  supports both. If the choice is between a gather read and a
  scatter write, prefer the gather; for scatter, restructure even
  more aggressively (write to a dense temporary; then scatter once,
  scalar, after the vector kernel).
- **GPU "coalesced loads" are the same lesson on different
  hardware.** GPUs penalise gather even more strongly. Code that
  needs to run on both CPU vector units and GPUs will want SoA and
  contiguous access by construction.

## References

- Agner Fog, *Instruction tables* (Intel / AMD throughput &
  latency) — <https://www.agner.org/optimize/>
- Intel, *Intrinsics Guide* (`VGATHERDPS`, `VPGATHERDD`,
  `VSCATTERDPS`) —
  <https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html>
- AMD, *Zen 4 software optimisation guide* (gather/scatter
  improvements) — <https://www.amd.com/en/developer.html>
- Travis Downs, *Gathering intel on Intel AVX-512 transitions* (and
  follow-ups on gather throughput on Sapphire Rapids) —
  <https://travisdowns.github.io/>
- Cross-reference: `SIMD.2` (SoA for linear loads), `CACHE.4` (AoS
  vs SoA vs AoSoA), `CACHE.1` (cache-line awareness).
