+++
id = "GPU.9"
title = "Suballocate and alias transient GPU memory from frame or graph-owned heaps"
category = "gpu"
status = "draft"
summary = "Per-resource GPU allocation is expensive and fragments memory; allocate large heaps, suballocate, and alias transient resources whose lifetimes do not overlap."
tags = ["gpu-memory", "heaps", "suballocation", "aliasing", "render-graph"]
+++

## Rationale

GPU memory allocation is not the same operation as bumping a CPU pointer.
Creating and destroying device allocations can involve driver work, page table
updates, residency management, synchronization, and fragmentation. Modern
explicit APIs therefore push applications toward large heaps and
suballocation.

Renderers also create many temporary resources: G-buffers, shadow maps,
post-processing textures, visibility buffers, intermediate compute buffers,
and readback staging. Many of these lifetimes do not overlap. A render graph
or frame allocator can alias them onto the same physical memory when the
dependencies prove it is safe.

## Guidance

- Allocate large GPU heaps or pools and suballocate resources from them.
- Keep steady-state allocation out of the frame loop. Per-frame transient
  allocation should be pointer arithmetic inside an existing heap.
- Use a render/frame graph to compute lifetimes and alias non-overlapping
  transient resources.
- Keep long-lived resources, upload/readback staging, and transient resources
  in separate pools. Their lifetimes and access patterns differ.
- Fully initialize aliased resources before use, and emit the required
  barriers/transitions when memory changes role.
- Track high-water marks, fragmentation, aliasing savings, and residency
  failures in telemetry.

## Example

```cpp
struct TransientResource {
    std::size_t size;
    std::size_t align;
    int first_pass;
    int last_pass;
};

// Sketch: a graph allocator can reuse memory when lifetimes do not overlap.
constexpr bool can_alias(const TransientResource& a,
                         const TransientResource& b) noexcept {
    return a.last_pass < b.first_pass || b.last_pass < a.first_pass;
}

// Shadows and bloom_temp can occupy the same heap range if the graph proves
// the bloom pass starts after all shadow consumers are complete.
constexpr TransientResource shadows{64 * MiB, 64 * KiB, 1, 4};
constexpr TransientResource bloom_temp{64 * MiB, 64 * KiB, 8, 10};
static_assert(can_alias(shadows, bloom_temp));
```

## Caveats

- Aliasing raises the cost of incorrect lifetime tracking. Use graph
  validation and debug names aggressively.
- Sparse/placed/aliased resources have platform-specific hazards. Follow the
  API and vendor rules for initialization, barriers, and residency.
- Small projects can start with a simpler pool. The rule is to avoid
  unbounded per-frame device allocation, not to build a full render graph on
  day one.

## References

- AMD GPUOpen, RDNA Performance Guide -
  <https://gpuopen.com/learn/rdna-performance-guide/>
- Unreal Engine, Render Dependency Graph -
  <https://dev.epicgames.com/documentation/en-us/unreal-engine/render-dependency-graph-in-unreal-engine>
- Filament framegraph notes -
  <https://google.github.io/filament/notes/framegraph.html>
- NVIDIA, CUDA C++ Programming Guide - stream-ordered allocator and graphs -
  <https://docs.nvidia.com/cuda/cuda-c-programming-guide/>
- Cross-reference: `MEM.1` (arena allocation), `MEM.4` (frame allocator),
  `GPU.8` (barriers).
