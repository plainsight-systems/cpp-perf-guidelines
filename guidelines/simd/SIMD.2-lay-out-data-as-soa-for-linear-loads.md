+++
id = "SIMD.2"
title = "Lay out data as SoA so vector loads are linear"
category = "simd"
status = "draft"
summary = "The autovectoriser emits a single vector load per N contiguous elements of one field. AoS forces gather or shuffle, which it usually refuses. SoA is what SIMD actually consumes."
tags = ["soa", "aosoa", "data-layout", "autovectorisation"]
+++

## Rationale

A vector instruction operates on N lanes of the same field. The
autovectoriser materialises that vector by issuing a single load of N
contiguous elements of that field — `movdqa` / `vmovdqa` on x86, `ld1`
on ARM NEON, a predicated `ld1w` on SVE. If the data is **array of
structs (AoS)**, the same field's elements are *strided* — they live
`sizeof(struct)` bytes apart, not adjacent — and the compiler either
emits a gather (`SIMD.5` — usually a trap) or refuses to vectorise and
falls back to scalar.

**Struct of arrays (SoA)** is the layout the SIMD hardware was
designed to consume. The same field's elements are dense; one vector
load fills a register; the loop runs at the lane count. `CACHE.4`
already argues for SoA from the *cache* angle (one field, many
elements, no padding); the SIMD-specific reason is mechanical — the
vector load is the unit of work the compiler can emit, and SoA makes
that load possible.

**AoSoA** (struct of small blocks of SoA — N elements per block, one
block per cache line) is the compromise when you also do per-entity
work nearby in the loop. Highway and Eve target AoSoA via `Vec<D>`-
sized blocks; Unity DOTS structures archetype chunks at 16 KiB so the
hot columns fit in L1 (cross-reference `CACHE.4`).

## Guidance

- **For any hot loop iterating a population**, default to **SoA**. One
  contiguous array per field; the loop reads each field through its
  own pointer.
- **If you also need locality across fields per entity** (e.g. mixed
  loops, some entity-at-a-time and some batched), use **AoSoA** —
  blocks of N entities, each block laid out SoA inside.
- **AoS is fine for genuinely one-entity-at-a-time work** — UI event
  records, configuration objects, low-rate state machines. SIMD never
  enters the picture; layout choice is about clarity, not vectors.
- **Size AoSoA blocks against the target's SIMD width** — 8 lanes for
  AVX-2 floats, 16 for AVX-512, 4 for NEON 32-bit. Highway's
  `ScalableTag<T>` and Eve's `eve::wide<T>` pick the right block size
  for the target; rolling your own means a target-specific constant.
- **Avoid the "AoS now, refactor later" trap.** Refactoring a heavily-
  used AoS struct to SoA late in development is expensive and
  introduces correctness risk. Choose the layout when the
  data-population *exists*, not when the loop arrives.

## Example

```cpp
// AoS — the natural shape when you write a Particle "as a thing." A
// loop over particles cannot vectorise: position and velocity are
// strided by sizeof(Particle), so the compiler either gathers (slow)
// or refuses (scalar fallback). This is the layout to walk away from
// when the loop becomes hot.
struct ParticleAoS {
    Vec3  position;
    Vec3  velocity;
    float life;
    float size;
};

void integrate_aos(std::span<ParticleAoS> ps, float dt) noexcept {
    for (auto& p : ps) {
        p.position.x += p.velocity.x * dt;
        p.position.y += p.velocity.y * dt;
        p.position.z += p.velocity.z * dt;
        p.life       -= dt;
        // Stride between consecutive p.position.x is sizeof(ParticleAoS) — autovec stalls.
    }
}

// SoA — every field is contiguous. The integrate loop touches only
// position and velocity (no need for life or size in cache here);
// each load is dense and aligned; the autovectoriser emits a single
// FMA per W lanes.
struct ParticlesSoA {
    std::vector<float> px, py, pz;
    std::vector<float> vx, vy, vz;
    std::vector<float> life;
    std::vector<float> size;
};

void integrate_soa(ParticlesSoA& p, float dt) noexcept {
    const std::size_t n = p.px.size();
    for (std::size_t i = 0; i < n; ++i) {
        p.px[i] += p.vx[i] * dt;     // vectorises: dense float[] loads
        p.py[i] += p.vy[i] * dt;
        p.pz[i] += p.vz[i] * dt;
        p.life[i] -= dt;
    }
}

// AoSoA — when you need both vector locality and per-entity locality.
// One block holds W entities laid out SoA; consecutive blocks live
// near each other in memory. Choose W to match the target's vector
// width (typical: 8 or 16 for floats on x86; let a portable library
// pick).
template <std::size_t W>
struct ParticleChunk {
    float px[W], py[W], pz[W];
    float vx[W], vy[W], vz[W];
    float life[W], size[W];
};

using ParticleChunks = std::vector<ParticleChunk<8>>;   // tune W per target

void integrate_chunked(ParticleChunks& chunks, float dt) noexcept {
    for (auto& c : chunks) {
        for (std::size_t i = 0; i < 8; ++i) {        // unrolls to one vector op
            c.px[i] += c.vx[i] * dt;
            c.py[i] += c.vy[i] * dt;
            c.pz[i] += c.vz[i] * dt;
            c.life[i] -= dt;
        }
    }
}
```

## Caveats

- **SoA has its own costs.** Allocating eight parallel arrays is more
  setup than one; serialising "one particle's state" now touches every
  array; an entity-id-keyed `find` is no longer a single struct read.
  Helpers exist (`make_particle_view(i)`); the cost is real.
- **AoSoA tuning is platform-specific.** Block size that fits AVX-2's
  8-float vector is wrong for AVX-512's 16. Use a portable SIMD
  library to make the block size a `Vec<D>::size()` rather than a
  literal `8`.
- **Mixed loops want AoSoA, not pure SoA.** A loop that touches every
  field per entity prefers AoS or AoSoA; a loop that touches one
  field across entities prefers SoA. Choose the layout that fits the
  *dominant* loop and accept slight pessimism on the others.
- **A vector-friendly layout is not enough alone.** The loop must also
  be vectorisable (`SIMD.1`, `SIMD.4`) — no aliasing surprises, no
  early exits, reductions over recognised operators.
- **Cross-references:** `CACHE.4` for the cache angle; `CACHE.5` for
  field ordering inside a block; `MEM.4` for double-buffered storage
  patterns when the SoA buffers cycle frame-to-frame.

## References

- Mike Acton, *Data-Oriented Design and C++*, CppCon 2014 —
  <https://www.youtube.com/watch?v=rX0ItVEVjHc>
- Joachim Ante, Unity DOTS / Burst (chunked AoSoA at 16 KiB) —
  <https://www.youtube.com/watch?v=tGmnZdY5Y-E>
- Google Highway, `ScalableTag` and `Vec<D>` —
  <https://github.com/google/highway>
- Cross-reference: `CACHE.4` (AoS / SoA / AoSoA — cache perspective),
  `SIMD.1` (vectoriser approach), `GEN.3` (`restrict` to remove
  aliasing barrier).
