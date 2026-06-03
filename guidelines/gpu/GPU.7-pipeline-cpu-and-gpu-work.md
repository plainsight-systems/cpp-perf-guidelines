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
- In CUDA, overlap requires all three preconditions: hardware that supports
  concurrent copy/execute, pinned host memory, and copies/kernels in different
  non-default streams.
- In graphics APIs, keep command recording, copy, compute, and graphics work
  ordered by explicit dependencies rather than global waits.
- Delay readback consumption by one or more frames/steps when exact same-frame
  CPU visibility is not required.
- Use rings for upload/readback resources. Reusing one staging buffer every
  frame is a hidden fence.
- Profile the timeline. A pipeline design is only real if the trace shows
  overlap and bounded in-flight memory.

## Example

```cpp
struct Chunk {
    float* host_in;       // pinned/page-locked host memory
    float* host_out;      // pinned/page-locked host memory
    float* dev_in;
    float* dev_out;
    cudaStream_t copy_stream;
    cudaStream_t compute_stream;
    cudaEvent_t copied_to_device;
    cudaEvent_t compute_done;
};

// Good CUDA shape: stage chunks so H2D copy for chunk N+1 overlaps compute
// for chunk N. The event is the narrow dependency; no device-wide sync.
void submit_chunk(Chunk& c, std::size_t bytes, int n) {
    cudaMemcpyAsync(c.dev_in, c.host_in, bytes, cudaMemcpyHostToDevice,
                    c.copy_stream);
    cudaEventRecord(c.copied_to_device, c.copy_stream);

    cudaStreamWaitEvent(c.compute_stream, c.copied_to_device, 0);
    kernel<<<grid_for(n), block_size, 0, c.compute_stream>>>(c.dev_out,
                                                             c.dev_in, n);
    cudaEventRecord(c.compute_done, c.compute_stream);

    cudaStreamWaitEvent(c.copy_stream, c.compute_done, 0);
    cudaMemcpyAsync(c.host_out, c.dev_out, bytes, cudaMemcpyDeviceToHost,
                    c.copy_stream);
}
```

## Caveats

- More frames in flight increase latency and memory use.
- Some algorithms truly need immediate CPU visibility. Isolate those waits so
  they are visible in the profile and not confused with general submission.
- Async copy/compute overlap depends on hardware engines, resource
  dependencies, and transfer size. Streams or queues alone do not guarantee
  overlap.
- CUDA's legacy default stream synchronizes with other streams unless the
  application opts into per-thread default stream behavior. Be explicit.

## References

- Khronos, Vulkan wait-idle performance sample -
  <https://docs.vulkan.org/samples/latest/samples/performance/wait_idle/README.html>
- Microsoft, D3D12 multi-engine synchronization -
  <https://learn.microsoft.com/en-us/windows/win32/direct3d12/user-mode-heap-synchronization>
- Apple, Metal resource synchronization -
  <https://developer.apple.com/documentation/metal/resource-synchronization>
- NVIDIA, CUDA C++ Best Practices Guide -
  <https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/>
- NVIDIA, How to Overlap Data Transfers in CUDA C/C++ -
  <https://developer.nvidia.com/blog/how-overlap-data-transfers-cuda-cc/>
- Cross-reference: `MEM.4` (double buffering), `TLM.11` (CPU/GPU
  timestamp correlation), `GPU.1` (device residency).
