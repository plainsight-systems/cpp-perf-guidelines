+++
id = "GPU.5"
title = "Use shared or threadgroup memory only when reuse or reordering pays"
category = "gpu"
status = "draft"
summary = "Shared memory is a scarce per-block resource; use it to reuse data or repair access patterns, not as a reflexive cache for every kernel."
tags = ["shared-memory", "threadgroup-memory", "lds", "tiling", "barriers"]
+++

## Rationale

CUDA shared memory, AMD LDS, and Metal threadgroup memory are fast on-chip
storage visible to a block/threadgroup. They are also scarce. Allocating more
of it can reduce occupancy, add barriers, introduce bank conflicts, and make
the kernel harder to reason about.

Shared memory wins when it changes the memory traffic shape: a tile is loaded
once and reused many times, or global memory is read/written coalesced and
then rearranged locally. It is not automatically faster than registers,
read-only caches, texture paths, or a simple coalesced global load.

## Guidance

- Use shared/threadgroup memory for tiled reuse: matrix blocks, stencils,
  convolution windows, histogram bins, reductions, or neighborhood queries.
- Use it to turn uncoalesced global access into coalesced global loads plus
  local rearrangement.
- Count barriers. A tile that needs many full-threadgroup barriers may lose to
  a simpler multi-pass approach.
- Budget occupancy impact. Record bytes per block/threadgroup and the
  resulting resident block/wave count.
- Avoid bank conflicts by padding or changing indexing when profiler counters
  show local-memory serialization.
- Prefer warp/wave/SIMD-group shuffle operations for within-group reductions
  when the data never needs full threadgroup visibility.

## Example

```cpp
// Sketch: a tiled stencil. The block cooperatively loads a tile plus halo,
// synchronizes once, then each thread reuses neighboring values from shared
// memory instead of issuing several global loads.
__global__ void stencil_1d(float* out, const float* in, int n) {
    extern __shared__ float tile[];

    int local = threadIdx.x;
    int global = blockIdx.x * blockDim.x + local;
    int shared_i = local + 1;

    if (global < n) tile[shared_i] = in[global];
    if (local == 0 && global > 0) tile[0] = in[global - 1];
    if (local == blockDim.x - 1 && global + 1 < n) {
        tile[shared_i + 1] = in[global + 1];
    }

    __syncthreads();

    if (global > 0 && global + 1 < n) {
        out[global] = 0.25f * tile[shared_i - 1]
                    + 0.50f * tile[shared_i]
                    + 0.25f * tile[shared_i + 1];
    }
}
```

## Caveats

- On some modern GPUs, cache hierarchy changes make threadgroup memory less
  beneficial for simple read-once patterns.
- Shared memory does not fix incoherent global stores by itself; the final
  store pattern still matters.
- Bank-conflict rules differ by vendor and generation. Treat padding folklore
  as a hypothesis to profile.

## References

- NVIDIA, CUDA C++ Best Practices Guide -
  <https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/>
- NVIDIA, Using Shared Memory in CUDA C/C++ -
  <https://developer.nvidia.com/blog/using-shared-memory-cuda-cc/>
- Apple, Creating threads and threadgroups -
  <https://developer.apple.com/documentation/metal/compute_passes/creating_threads_and_threadgroups>
- Wicked Engine, GPU-based particle simulation -
  <https://wickedengine.net/2017/11/07/gpu-based-particle-simulation/>
- Cross-reference: `GPU.2` (coalescing), `GPU.3` (occupancy), `SIMD.7`
  (masks and predication).
