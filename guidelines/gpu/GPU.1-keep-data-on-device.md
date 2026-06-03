+++
id = "GPU.1"
title = "Keep data on the device; every host-device round trip needs a budget"
category = "gpu"
status = "draft"
summary = "GPU speedups vanish when each stage copies data back to the CPU; keep intermediate data device-resident and budget transfers explicitly."
tags = ["cuda", "transfers", "latency", "bandwidth", "device-memory"]
+++

## Rationale

A GPU can have enormous arithmetic throughput and still lose to the CPU if
the pipeline keeps crossing the host-device boundary. A transfer has fixed
latency, consumes PCIe/NVLink/unified-memory bandwidth, and often creates an
ordering point. A readback is worse: it can force the CPU to wait until all
prior GPU work that produces the data is complete.

CUDA exposes the failure mode directly: a kernel that is fast in isolation
does not help if the caller copies input to the device, launches one tiny
kernel, copies the result back, then repeats. Graphics APIs have the same
shape with upload heaps, staging buffers, readback buffers, command buffers,
and fences.

The device boundary is therefore part of the algorithm, not an I/O detail.

## Guidance

- Draw the ownership graph for the data. If the next three consumers are GPU
  kernels/passes, the CPU should not see the intermediate form.
- Keep intermediate buffers, reductions, visibility lists, particles, or ML
  activations on the device when later GPU work consumes them.
- Move decisions onto the GPU when the CPU only needs the result to schedule
  more GPU work. Use compaction, prefix sums, indirect draws, indirect
  dispatch, or persistent device-side state.
- Batch unavoidable transfers. Prefer one large copy over many small copies.
- Use pinned/page-locked host memory for high-bandwidth asynchronous CUDA
  transfers; use API-specific upload/readback resources for graphics APIs.
- Treat CPU readback as a frame or step boundary. If it appears in the hot
  loop, record the expected latency, the queue/fence it waits on, and the
  measured cost.
- Budget transfers as `bytes / measured_link_bandwidth + synchronization`.
  The synchronization term is often the part that makes a scalar readback
  expensive.
- On unified-memory systems, do not assume the problem disappeared. Shared
  physical memory removes a discrete copy path, but cache migration, resource
  synchronization, and CPU/GPU ordering still have cost.

## Example

```cpp
// Bad: every iteration pulls the scalar result back to the CPU, then uses it
// to decide the next GPU operation. The readback serializes the loop.
for (int step = 0; step != steps; ++step) {
    launch_score_kernel<<<grid, block>>>(state_dev, score_dev);
    float score{};
    cudaMemcpy(&score, score_dev, sizeof(score), cudaMemcpyDeviceToHost);
    if (score > threshold) {
        launch_refine_kernel<<<grid, block>>>(state_dev);
    }
}

// Good: keep the decision device-side and compact work for the next kernel.
for (int step = 0; step != steps; ++step) {
    launch_score_and_mark_kernel<<<grid, block>>>(state_dev, flags_dev);
    launch_compact_marked_items_kernel<<<grid, block>>>(flags_dev, worklist_dev,
                                                        work_count_dev);
    launch_refine_indirect_kernel(state_dev, worklist_dev, work_count_dev);
}
```

```cpp
// Review test: a scalar readback in a hot loop needs a written reason.
// Acceptable: "once per frame, feeds the CPU frame scheduler, hidden behind
// a two-frame readback ring." Suspicious: "used to decide the next kernel
// in the same loop."
struct ReadbackBudget {
    std::size_t bytes;
    double measured_transfer_us;
    double measured_wait_us;
    int frames_delayed;
};
```

## Caveats

- Device-side control is not free. If the branch is rare, the GPU-side
  compaction path may cost more than a coarse CPU decision.
- Large readbacks for final output are normal. The rule is about repeated
  round trips inside the performance-critical loop.
- Unified-memory APIs can hide copies until a page fault or synchronization
  point. Profile migrations instead of assuming "no memcpy" means no cost.
- Error handling and validation may require CPU visibility. Keep that path out
  of the throughput measurement or label it as diagnostic.

## References

- NVIDIA, CUDA C++ Best Practices Guide -
  <https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/>
- NVIDIA, CUDA C++ Programming Guide -
  <https://docs.nvidia.com/cuda/cuda-c-programming-guide/>
- Apple, Metal resource synchronization -
  <https://developer.apple.com/documentation/metal/resource-synchronization>
- Wicked Engine, GPU-based particle simulation -
  <https://wickedengine.net/2017/11/07/gpu-based-particle-simulation/>
- Cross-reference: `GPU.7` (CPU/GPU pipelining), `GPU.10` (GPU timelines),
  `MEM.4` (double-buffered frame allocation).
