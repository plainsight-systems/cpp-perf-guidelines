+++
id = "CACHE.4"
title = "Choose AoS, SoA, or AoSoA by which fields the hot loop touches"
category = "cache-layout"
status = "draft"
summary = "AoS wins when loops touch most fields of an element together. SoA wins when loops touch one field across many elements and you want vectorization. AoSoA gives both — chunked SoA tuned to L1."
tags = ["aos", "soa", "aosoa", "data-oriented-design", "simd"]
+++

## Rationale

Layout for a *population* of elements is a choice about which fields the hot
loop accesses together. The three shapes are not styles — they are mechanical
fits to the access pattern.

- **Array of Structs (AoS)** — `struct{x,y,z,...}; std::vector<T>;` — packs all
  fields of one element together. Wins when the loop touches most fields of
  one element before moving on, and when the struct fits in O(1) cache lines.
- **Struct of Arrays (SoA)** — `struct{vector<float> x; vector<float> y; ...};`
  — splits each field into its own contiguous array. Wins when the loop
  touches one field (or a small subset) across many elements; also enables
  the autovectorizer, which handles `x[i]` but not `xyz[i].x` without a
  gather.
- **Array of Structs of Arrays (AoSoA)** — blocks of N elements, each block
  internally SoA — gives SIMD-lane width *and* locality of one block's fields.
  Unity DOTS formalises this as the *chunk*: a 16 KiB block per archetype,
  sized so the hot columns fit in L1 (~32 KiB) with room for the rest of the
  loop's working state.

EnTT (BSD-2) takes a different formalisation: a sparse-set per component
type, each backed by a dense `std::vector<T>`. Iteration over one component
is pure AoS over the dense array; multi-component iteration uses the smallest
pool as the driver and indexes into the others. The discipline — *never
iterate by entity identity, always by component pool* — is the SoA insight in
ECS form.

## Guidance

Match layout to the *hot* access pattern:

- **AoS** when the per-element work touches **most fields together** and the
  struct fits in a small number of cache lines. Configuration objects,
  one-off domain entities, UI event records.
- **SoA** when a loop touches **a subset of fields across many elements** —
  the canonical DOD case — or when you want autovectorization. Particle
  systems, physics integration, transformation cascades, graphics vertex
  streams.
- **AoSoA** when you want SIMD width **and** block locality. Pick chunk size
  to match L1 capacity (Unity uses 16 KiB; tune to the target). Implement as
  fixed-size chunks per archetype with columns inside each chunk.

The choice is a workload property — re-measure for new workloads.

## Example

```cpp
// AoS — the natural shape when the loop touches most fields per element.
// One Particle is one cache line at 32 B; the integrate loop touches all of
// it.
struct ParticleAoS {
    Vec3  position;
    Vec3  velocity;
    float life;
    float size;
};
static_assert(sizeof(ParticleAoS) == 32);

void integrate_aos(std::span<ParticleAoS> ps, float dt) {
    for (auto& p : ps) {
        p.position = add(p.position, scale(p.velocity, dt));
        p.life    -= dt;
    }
}

// SoA — when a loop touches one field across many elements, this is much
// better: contiguous `x[]`/`y[]`/`z[]` are dense, prefetcher-friendly, and
// the autovectorizer can SIMD-process them. The integrate loop no longer
// pulls `size` (cold here) into cache.
struct ParticlesSoA {
    std::vector<float> px, py, pz;
    std::vector<float> vx, vy, vz;
    std::vector<float> life;
    std::vector<float> size;
};

void integrate_soa(ParticlesSoA& p, float dt) {
    const std::size_t n = p.px.size();
    for (std::size_t i = 0; i < n; ++i) {
        p.px[i] += p.vx[i] * dt;
        p.py[i] += p.vy[i] * dt;
        p.pz[i] += p.vz[i] * dt;
        p.life[i] -= dt;
    }
}

// AoSoA — chunks of N elements, each chunk internally SoA. N is sized so the
// chunk's hot columns fit in L1; the loop processes one chunk at a time,
// keeping all the per-element state hot together while still vectorizing
// within each column.
template <std::size_t N>
struct ParticleChunk {
    float px[N], py[N], pz[N];
    float vx[N], vy[N], vz[N];
    float life[N];
    float size[N];
};
using ParticleChunks = std::vector<ParticleChunk<256>>;   // 256-wide chunks
```

## Caveats

- **SoA fragments per-entity reasoning.** Reading or serialising "one
  particle's state" now touches every array. Provide a helper (or a view
  type) for the rare per-entity paths so the SoA stays the default and the
  AoS-style access is the exception.
- **AoSoA is a tuning surface.** Chunk size, alignment, and column ordering
  inside the chunk are all platform-dependent. Don't write a templated AoSoA
  utility that everyone uses with default parameters; tune per workload.
- **Mixed fields with different lifetimes** are the hot/cold problem, not the
  AoS/SoA problem. See `CACHE.6` — that splits *which fields exist together*,
  not how a fixed field set is laid out.
- **Cold AoS is fine.** A configuration struct read once at startup does not
  benefit from SoA and gets harder to read. Apply this where the loop is hot.

## References

- Mike Acton, *Data-Oriented Design and C++*, CppCon 2014 —
  <https://www.youtube.com/watch?v=rX0ItVEVjHc>
- Richard Fabian, *Data-Oriented Design* (book, free online) —
  <https://www.dataorienteddesign.com/dodbook/>
- Joachim Ante, Unity DOTS / Burst talks (Unite Copenhagen 2019) —
  <https://www.youtube.com/watch?v=tGmnZdY5Y-E>
- EnTT (Michele Caini, BSD-2) — sparse-set + dense-vector storage —
  <https://github.com/skypjack/entt>
- Ulrich Drepper, *What Every Programmer Should Know About Memory*, §6 —
  <https://people.freebsd.org/~lstewart/articles/cpumemory.pdf>
