+++
id = "GPU.7"
title = "Pipeline CPU and GPU work with queues, streams, fences, and multi-buffered resources"
category = "gpu"
status = "draft"
summary = "Avoid hot-loop waits by giving the CPU and GPU separate in-flight resources and explicit dependency edges."
tags = ["streams", "queues", "fences", "readback", "multi-buffering"]
+++

## Rationale

The CPU and GPU are separate processors connected by queues. Good GPU
programs let them overlap: the CPU records frame N+1 while the GPU executes
frame N, or one CUDA stream copies input while another stream runs compute.

The common failure mode is accidental serialization. A wait-idle call,
blocking readback, reused upload buffer, single frame resource, or coarse
fence can force the CPU to wait for the GPU or the GPU to wait for the CPU.
The frame still "works," but the timeline contains bubbles where expensive
hardware is idle.

## Guidance

- Use multiple instances of per-frame resources: constant/uniform buffers,
  upload buffers, descriptor arenas, temporary render targets, readback
  slots, and staging memory.
- Use fences/events to wait for a specific resource lifetime, not for the
  entire device or queue.
- In CUDA, use streams and events to express overlap between copies and
  kernels. Pair this with pinned host memory for asynchronous transfers.
- In graphics APIs, keep command recording, copy, compute, and graphics work
  ordered by explicit dependencies rather than global waits.
- Delay readback consumption by one or more frames/steps when exact same-frame
  CPU visibility is not required.
- Profile the timeline. A pipeline design is only real if the trace shows
  overlap and bounded in-flight memory.

## Example

```cpp
struct ReadbackSlot {
    Buffer buffer;
    Fence fence;
};

std::array<ReadbackSlot, 3> readbacks;

void submit_frame(std::uint64_t frame_index) {
    ReadbackSlot& write_slot = readbacks[frame_index % readbacks.size()];

    // GPU writes this frame's result and signals only this slot's fence.
    encode_gpu_work(write_slot.buffer);
    signal_fence(write_slot.fence, frame_index);

    // CPU consumes an older slot if it is ready. No device-wide wait.
    ReadbackSlot& read_slot = readbacks[(frame_index + 1) % readbacks.size()];
    if (is_fence_complete(read_slot.fence, frame_index - 2)) {
        consume_readback(read_slot.buffer);
    }
}
```

## Caveats

- More frames in flight increase latency and memory use.
- Some algorithms truly need immediate CPU visibility. Isolate those waits so
  they are visible in the profile and not confused with general submission.
- Async copy/compute overlap depends on hardware engines, resource
  dependencies, and transfer size. Streams or queues alone do not guarantee
  overlap.

## References

- Khronos, Vulkan wait-idle performance sample -
  <https://docs.vulkan.org/samples/latest/samples/performance/wait_idle/README.html>
- Microsoft, D3D12 multi-engine synchronization -
  <https://learn.microsoft.com/en-us/windows/win32/direct3d12/user-mode-heap-synchronization>
- Apple, Metal resource synchronization -
  <https://developer.apple.com/documentation/metal/resource-synchronization>
- NVIDIA, CUDA C++ Best Practices Guide -
  <https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/>
- Cross-reference: `MEM.4` (double buffering), `TLM.11` (CPU/GPU
  timestamp correlation), `GPU.1` (device residency).
