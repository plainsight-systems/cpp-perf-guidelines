+++
id = "GPU.8"
title = "Make barriers describe real hazards; overbroad barriers kill overlap"
category = "gpu"
status = "draft"
summary = "A GPU barrier should name the producer, consumer, stages, and access types that actually conflict; global waits and all-stage barriers create bubbles."
tags = ["barriers", "synchronization", "vulkan", "d3d12", "metal"]
+++

## Rationale

Explicit GPU APIs put synchronization in the application's hands. A barrier
is a dependency edge: previous work that writes a resource must become visible
before later work reads or writes the same resource. When the edge is precise,
unrelated work can overlap. When the edge is broad, the GPU drains work that
did not need to wait.

The dangerous habit is using barriers as a debugging flush: all commands, all
stages, all access, every time. That can hide hazards during development while
destroying the scheduler's ability to overlap graphics, compute, copy, and
independent passes.

## Guidance

- For every barrier, identify the resource, producer pass, consumer pass,
  previous access, next access, and pipeline stages involved.
- Use the narrowest stage and access masks that express the hazard.
- Prefer split barriers or events when they allow independent work to run
  between release and acquire.
- Avoid device-wide or queue-wide idle calls in frame loops.
- Let a render/frame graph synthesize barriers when the graph has complete
  resource lifetime and pass-dependency information.
- Validate synchronization with API validation layers and GPU debugging tools,
  then profile to remove overly conservative edges.

## Example

```cpp
// Bad shape: "something changed, block everything."
Barrier too_broad{
    .src_stage = Stage::AllCommands,
    .src_access = Access::All,
    .dst_stage = Stage::AllCommands,
    .dst_access = Access::All,
    .resource = texture,
};

// Better shape: compute wrote an image; the fragment shader samples it next.
Barrier precise{
    .src_stage = Stage::ComputeShader,
    .src_access = Access::ShaderWrite,
    .dst_stage = Stage::FragmentShader,
    .dst_access = Access::ShaderRead,
    .resource = texture,
};
```

## Caveats

- A missing barrier is a correctness bug, not a performance tradeoff.
- Some APIs or hardware paths force coarser synchronization than the ideal.
  Document that platform constraint.
- Validation can prove some hazards are described, but it cannot prove a
  barrier is performance-optimal. Use profiler timelines for that.

## References

- Khronos, Vulkan pipeline barriers performance sample -
  <https://docs.vulkan.org/samples/latest/samples/performance/pipeline_barriers/README.html>
- Khronos, Vulkan synchronization spec -
  <https://docs.vulkan.org/spec/latest/chapters/synchronization.html>
- Microsoft DirectXTK12, Resource Barriers -
  <https://github.com/microsoft/DirectXTK12/wiki/Resource-Barriers>
- Unreal Engine, Render Dependency Graph -
  <https://dev.epicgames.com/documentation/en-us/unreal-engine/render-dependency-graph-in-unreal-engine>
- Cross-reference: `GPU.7` (CPU/GPU pipelining), `TLM.11` (correlated GPU
  timelines).
