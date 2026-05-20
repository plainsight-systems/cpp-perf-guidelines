+++
id = "CACHE.6"
title = "Split hot fields from cold when the hot path is memory-bound"
category = "cache-layout"
status = "draft"
summary = "When a hot loop touches a small subset of a large struct's fields and the loop is memory-bound, extract the hot fields into a parallel container — collapsing the working set by the cold ratio."
tags = ["hot-cold-splitting", "working-set", "data-oriented-design"]
+++

## Rationale

Field ordering (`CACHE.5`) only reduces *padding* between fields. It does
nothing about the more common cache pathology: the hot loop touches three or
four fields of a struct that has twenty, and the cold sixteen ride into cache
on every iteration just because they happen to live in the same line. The
hardware moves whole lines; you pay for what is on the line, not what you
read.

Acton's `BoundingSphere` example in CppCon 2014 is the canonical case. A
`Visibility` system needs only a position, a radius, and a "visible" flag —
~20 bytes of state — but in an object-oriented game engine those fields live
on a `GameObject` that also carries its transform matrix, mesh handle, AI
state, physics state, and network state. Visibility iterates the full
`GameObject`. The working set is fat, the prefetcher is fighting the loop,
and the per-element time is dominated by lines that the loop never reads.

The fix is *layout-level pay-for-what-you-use*: extract the hot fields into a
separate struct, kept in lockstep with the original. The hot loop iterates
the hot half only; the cold fields stay where they were. Done in the right
place, the per-element bandwidth drops to the hot-half ratio — a 4× to 10×
collapse is typical on real engines.

Niklas Gray's Bitsquid blog posts make this concrete with engine examples
(splitting `Transform` into a hot "dirty + parent" column and a cold "local
TRS / world TRS" column).

## Guidance

Split hot from cold only when **all three** conditions hold:

- **The hot half is materially smaller than the full struct.** Typically
  ≤ 25–50 % by size. A split that only saves 10 % is not worth the
  bookkeeping.
- **The hot loop is measurably memory-bound.** Profile first
  (`CACHE.8`). If the loop is compute-bound, the line bandwidth is not the
  cost and a split changes nothing.
- **The bookkeeping cost is amortised.** The two halves must stay in
  lockstep on insert / delete — this cost pays back only across many hot-loop
  iterations.

Mechanics:

- Store hot and cold in parallel containers (`std::vector<Hot>` +
  `std::vector<Cold>`) indexed by the same handle, or as a single struct of
  two arrays.
- Provide a single mutation API that updates both halves at once; never let
  callers update one without the other.
- Assert the invariant in debug — `hot.size() == cold.size()` at the API
  boundary.
- Iterate the hot loop over the hot half only; the cold half should not be
  named in that function.

## Example

```cpp
// Before — a fat object. The Visibility loop touches three fields but pays
// for the whole 256+ byte struct on every iteration. ~3 elements per line
// of bandwidth wasted.
struct GameObjectFat {
    Vec3            position;        // hot
    float           radius;          // hot
    bool            visible;          // hot
    Mat4            transform;       // cold
    MeshHandle      mesh;             // cold
    AiState         ai;               // cold
    PhysicsState    physics;          // cold
    NetworkState    net;              // cold
    std::string     debug_name;       // cold
};

// After — hot and cold split. Visibility iterates `hots` only; the working
// set collapses to ~17 hot bytes per element, ~3-4 elements per 64 B line.
struct Hot {
    Vec3  position;
    float radius;
    bool  visible;
};

struct Cold {
    Mat4         transform;
    MeshHandle   mesh;
    AiState      ai;
    PhysicsState physics;
    NetworkState net;
    std::string  debug_name;
};

class World {
public:
    using Handle = std::uint32_t;

    // Single mutation API: insert keeps the halves in lockstep.
    Handle add(Hot h, Cold c) {
        hot_.push_back(h);
        cold_.push_back(std::move(c));
        assert(hot_.size() == cold_.size());
        return static_cast<Handle>(hot_.size() - 1);
    }

    // Hot loop — names only the hot half. Linear, prefetcher-friendly.
    void update_visibility(const Frustum& f) noexcept {
        for (auto& h : hot_) {
            h.visible = f.contains(h.position, h.radius);
        }
    }

    // Cold access — through the handle, only on the cold path.
    const Cold& cold(Handle h) const noexcept { return cold_[h]; }

private:
    std::vector<Hot>  hot_;
    std::vector<Cold> cold_;
};
```

## Caveats

- **Lockstep is a real cost.** Every operation that adds, removes, or moves
  an element now touches two containers; a swap-remove pattern needs to swap
  both halves with the same index. Audit the entire mutation API.
- **Cache-line straddle at the boundary.** If the hot half is, say, 17 B,
  some array elements will straddle a 64 B line. Padding the hot struct to a
  factor of the line size avoids the half-line load — measure whether it
  helps.
- **A cold-path hit through the cold container is now a cache miss.** That
  cost was previously hidden inside the fat struct's full load. Make sure
  the cold path is genuinely cold; if it is invoked once per hot iteration,
  the split has not helped.
- **Refactoring cost is real.** A struct exposed across a stable boundary
  cannot be silently split. Apply this where the data is owned by the system
  doing the iteration.

## References

- Mike Acton, *Data-Oriented Design and C++* (the `BoundingSphere` /
  `Visibility` example), CppCon 2014 —
  <https://www.youtube.com/watch?v=rX0ItVEVjHc>
- Niklas Gray, Bitsquid / Our Machinery blog archive (`Transform`
  hot/cold posts) —
  <https://bitsquid.blogspot.com/>; <https://ruby0x1.github.io/machinery_blog_archive/>
- Richard Fabian, *Data-Oriented Design* (book, free online) —
  <https://www.dataorienteddesign.com/dodbook/>
