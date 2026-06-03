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

Occupancy has real named limiters. CUDA reports registers per thread, shared
memory per block, blocks per SM, and achieved occupancy. AMD tooling exposes
VGPR pressure, LDS use, threadgroup size, barrier pressure, and lack of enough
waves to fill the machine. Those are the levers; "make occupancy higher" is
not a lever.

The question is not "how do I reach 100% occupancy?" The question is "does
this kernel need more independent resident work to hide its dominant stall?"

## Guidance

- Use the profiler to classify the bottleneck first: memory latency, memory
  bandwidth, instruction throughput, dependency stalls, launch overhead, or
  synchronization.
- If memory latency dominates, try increasing resident warps/waves by reducing
  register pressure, shared/threadgroup memory use, oversized blocks, or
  unnecessary threadgroup barriers.
- If memory bandwidth or ALU throughput dominates, higher occupancy may not
  help. Focus on coalescing, reuse, arithmetic intensity, or fewer
  instructions.
- Watch register spills. Reducing declared register use is not a win if it
  pushes live values into local/global memory.
- Sweep block/threadgroup sizes. Do not assume the maximum legal block size is
  the fastest.
- Look for occupancy cliffs. A one-register or one-kilobyte shared-memory
  increase can drop the number of resident blocks/waves by a whole step.
- Keep occupancy notes with the kernel: registers per thread, shared memory
  per block, block size, measured bottleneck, and the profiler/tool version.

## Example

```cpp
// CUDA sketch: start with the occupancy API to find plausible launch shapes,
// then verify with Nsight Compute. The API predicts residency; it does not
// prove throughput.
int min_grid_size = 0;
int block_size = 0;
cudaOccupancyMaxPotentialBlockSize(&min_grid_size, &block_size,
                                   kernel, dynamic_shared_bytes, 0);

dim3 block(block_size);
dim3 grid((n + block_size - 1) / block_size);
kernel<<<grid, block, dynamic_shared_bytes>>>(out, in, n);

// Then record, for this exact build and GPU:
// - registers/thread
// - static + dynamic shared memory/block
// - theoretical occupancy
// - achieved occupancy
// - top stall reason
// - local-memory spills
```

```cpp
// Bad review comment: "force max registers lower until occupancy improves."
// If the cap spills hot values to local memory, the kernel may do more global
// memory traffic and run slower at higher occupancy.
//
// Better review comment: "This kernel is memory-latency stalled, uses 96
// registers/thread, and drops from 4 to 2 resident blocks at 97 registers.
// Try a version that recomputes one temporary to stay below the cliff, then
// check spills and end-to-end time."
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
