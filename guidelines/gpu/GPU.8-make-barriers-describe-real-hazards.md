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

Treat GPU barriers like memory-order edges in CPU code. `AllCommands ->
AllCommands` is the GPU equivalent of reaching for the strongest ordering
because the real dependency was not identified. Sometimes that is necessary;
as a default it serializes work that could have overlapped.

## Guidance

- For every barrier, identify the resource, producer pass, consumer pass,
  previous access, next access, and pipeline stages involved.
- Use the narrowest stage and access masks that express the hazard.
- Separate memory hazards from queue ownership and layout/state transitions.
  They often travel together in examples, but they answer different questions.
- Prefer split barriers or events when they allow independent work to run
  between release and acquire.
- Avoid device-wide or queue-wide idle calls in frame loops.
- Let a render/frame graph synthesize barriers when the graph has complete
  resource lifetime and pass-dependency information.
- Validate synchronization with API validation layers and GPU debugging tools,
  then profile to remove overly conservative edges.

## Example

```cpp
// Bad Vulkan shape: "compute wrote something, block the whole pipe."
VkMemoryBarrier2 too_broad{
    .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER_2,
    .srcStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
    .srcAccessMask = VK_ACCESS_2_MEMORY_WRITE_BIT,
    .dstStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
    .dstAccessMask = VK_ACCESS_2_MEMORY_READ_BIT | VK_ACCESS_2_MEMORY_WRITE_BIT,
};

// Better shape: a compute shader wrote a storage image; the next pass samples
// it in the fragment shader. Unrelated vertex work, copies, and other compute
// can remain eligible to overlap.
VkImageMemoryBarrier2 precise{
    .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
    .srcStageMask = VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT,
    .srcAccessMask = VK_ACCESS_2_SHADER_WRITE_BIT,
    .dstStageMask = VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
    .dstAccessMask = VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
    .oldLayout = VK_IMAGE_LAYOUT_GENERAL,
    .newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    .image = texture,
    .subresourceRange = color_mips_and_layers,
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
- Microsoft, D3D12 resource barriers -
  <https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-resource-barriers-to-synchronize-resource-states-in-direct3d-12>
- Unreal Engine, Render Dependency Graph -
  <https://dev.epicgames.com/documentation/en-us/unreal-engine/render-dependency-graph-in-unreal-engine>
- Cross-reference: `GPU.7` (CPU/GPU pipelining), `TLM.11` (correlated GPU
  timelines).
