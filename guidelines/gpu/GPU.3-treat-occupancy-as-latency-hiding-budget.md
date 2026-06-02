+++
id = "GPU.3"
title = "Treat occupancy as latency-hiding budget, not a score"
category = "gpu"
status = "draft"
summary = "Higher occupancy helps only when more resident warps or waves hide stalls; register, shared-memory, and block-size changes must be tied to measured bottlenecks."
tags = ["occupancy", "register-pressure", "latency-hiding", "cuda", "rdna"]
+++

## Rationale

Occupancy measures how many warps/waves can reside on a GPU execution unit
relative to its maximum. It is useful because GPUs hide latency by switching
to other ready warps while one waits on memory or a dependency.

But occupancy is not throughput. A kernel can run faster at lower occupancy
if each thread does more useful work, uses fewer global memory transactions,
or keeps data in registers. A kernel can also report high occupancy while all
resident waves are stalled on the same memory bottleneck.

The question is not "how do I reach 100% occupancy?" The question is "does
this kernel need more independent resident work to hide its dominant stall?"

## Guidance

- Use the profiler to classify the bottleneck first: memory latency, memory
  bandwidth, instruction throughput, dependency stalls, launch overhead, or
  synchronization.
- If memory latency dominates, try increasing resident warps/waves by reducing
  register pressure, shared/threadgroup memory use, or oversized blocks.
- If memory bandwidth or ALU throughput dominates, higher occupancy may not
  help. Focus on coalescing, reuse, arithmetic intensity, or fewer
  instructions.
- Watch register spills. Reducing declared register use is not a win if it
  pushes live values into local/global memory.
- Sweep block/threadgroup sizes. Do not assume the maximum legal block size is
  the fastest.
- Keep occupancy notes with the kernel: registers per thread, shared memory
  per block, block size, measured bottleneck, and the profiler/tool version.

## Example

```cpp
// Occupancy tuning is an experiment, not a constant baked into folklore.
// Test block sizes against profiler counters and end-to-end time.
for (int block_size : {64, 128, 256, 512}) {
    dim3 block(block_size);
    dim3 grid((n + block_size - 1) / block_size);

    // In CUDA, also record registers/thread and achieved occupancy from
    // Nsight Compute for each variant.
    kernel<<<grid, block, dynamic_shared_bytes>>>(out, in, n);
}
```

## Caveats

- Occupancy calculators estimate residency, not performance.
- For tiny kernels, launch overhead can dominate before occupancy matters.
- Some algorithms deliberately trade occupancy for locality, more work per
  thread, or fewer global-memory passes. That can be correct.

## References

- AMD GPUOpen, Occupancy explained -
  <https://gpuopen.com/learn/occupancy-explained/>
- NVIDIA, Nsight Compute Profiling Guide -
  <https://docs.nvidia.com/nsight-compute/ProfilingGuide/>
- NVIDIA, CUDA C++ Best Practices Guide -
  <https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/>
- Apple, Learn performance best practices for Metal shaders -
  <https://developer.apple.com/videos/play/tech-talks/111373>
- Cross-reference: `GPU.5` (shared memory tradeoffs), `GPU.10` (counter
  profiling).
