+++
id = "CACHE.2"
title = "Design data layout from the data, not from the model"
category = "cache-layout"
status = "draft"
summary = "Before choosing containers or abstractions, count bytes per element, elements per cache line, lines per working set. Reject framings that hide the data shape."
tags = ["data-oriented-design", "cache", "working-set"]
+++

## Rationale

The hardware fact that makes data layout matter at all: an L2 miss to main
memory costs on the order of 200 cycles, during which a modern core retires
hundreds of unrelated instructions. The cost of *touching memory the cache did
not predict* dominates the cost of arithmetic by two to three orders of
magnitude. Layout choices that ignore this — that organise data around the
*conceptual model* of the problem rather than the *bytes the loops actually
touch* — pay it every iteration.

Mike Acton's *Data-Oriented Design and C++* (CppCon 2014) frames the
discipline. The three things "object-oriented" usually means — software is a
platform; code is designed around a model of the world; code is more important
than data — all hide the data shape from the engineer who is supposed to be
optimising it. Start instead from the data: how many bytes per element, how
many elements per cache line, how many lines per working set, on the actual
target hardware. The container and access pattern fall out of that.

The win is not theoretical. Coherent Labs rebuilt their Hummingbird browser
engine's DOM / style / layout pipeline around contiguous pools of POD records
instead of polymorphic `DOMNode` hierarchies; the layout phase ran 2–3× faster
on real pages (Nikolov, CppCon 2018). Even a *tree* domain like a DOM
flattens into a stream in production code.

This guideline is the lens the rest of the `cache-layout` category is read
through.

## Guidance

Before reaching for a container or an abstraction, answer four questions
about the data the hot loop actually touches:

- **Bytes per element.** What is `sizeof(T)`, and is it close to the minimum
  needed for the fields the loop touches? If most of `T` is cold, you are
  burning bandwidth — split it (`CACHE.6`).
- **Elements per cache line.** `64 / sizeof(T)` on most hardware. If a hot
  element does not fit in a small whole number of lines, layout is the first
  problem to solve.
- **Lines per working set.** How many distinct cache lines does one pass of
  the loop touch? Compare to L1 (~32 KiB), L2 (~1 MiB), LLC sizes for the
  target. Blow past a level and miss rate jumps.
- **Access order.** Is the access pattern linear, strided, or random? Linear
  the hardware prefetches for free; random it cannot.

Choose containers and access pattern to fit. Reject framings that defer the
data-shape question — "model the domain first, optimise later" is a deferred
cache miss per element forever.

## Example

```cpp
// Bad: a fat object designed around the model. The Visibility system needs
// only position, radius, and a flag — but each iteration drags the rest of
// the object through the cache for nothing.
struct GameObjectFat {
    Vec3            position;   // hot
    float           radius;     // hot
    bool            visible;    // hot
    Mat4            transform;  // cold
    MeshHandle      mesh;       // cold
    AiState         ai;         // cold
    PhysicsState    physics;    // cold
    NetworkState    net;        // cold
    std::string     debug_name; // cold
};
static_assert(sizeof(GameObjectFat) >= 256);   // one or two cache lines each

// Per-iteration bandwidth, working set on 64 B lines:
//   one fat element  =  4+ cache lines pulled in
//   one hot element  =  16 / 64 of a cache line

// Good: the Visibility loop iterates a hot half. The cold fields live in a
// parallel container, indexed in lockstep with the hot half. The visibility
// working set collapses by an order of magnitude.
struct VisibilityHot {
    Vec3  position;
    float radius;
    bool  visible;
    // ~17 bytes worth, ~3-4 hot elements per 64 B line.
};

void update_visibility(std::span<VisibilityHot> hots, const Frustum& f) {
    for (auto& h : hots) {                       // linear, prefetcher-friendly
        h.visible = f.contains(h.position, h.radius);
    }
}
```

A common before/after pattern: the same loop, the same algorithm — only the
layout changes, and the iteration time falls by a factor that the algorithm
analysis alone cannot explain.

## Caveats

- **Data-oriented design is not ideology.** Code that genuinely does one
  object's worth of work at a time (a UI event handler, a one-off
  configuration step) is fine as AoS. Apply this guideline where the loop is
  hot.
- **Premature SoA is a cost too.** It fragments updates to "one entity's
  state" across many arrays, complicates serialisation, and clutters reads.
  Measure that the hot path is memory-bound before reshaping the data.
- **`sizeof(T)` is the *static* size.** Pointer-rich types (a `std::string`
  with a long body, a `std::vector` with capacity) own additional cache lines
  the loop will also touch. Count those as part of working set.

## References

- Mike Acton, *Data-Oriented Design and C++*, CppCon 2014 —
  <https://www.youtube.com/watch?v=rX0ItVEVjHc>
- Stoyan Nikolov, *OOP Is Dead, Long Live Data-oriented Design*, CppCon
  2018 — <https://www.youtube.com/watch?v=yy8jQgmhbAU>
- Richard Fabian, *Data-Oriented Design* (book, free online) —
  <https://www.dataorienteddesign.com/dodbook/>
- Ulrich Drepper, *What Every Programmer Should Know About Memory*, §6 —
  <https://people.freebsd.org/~lstewart/articles/cpumemory.pdf>
