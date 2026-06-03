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

The classic trap is fixing one memory problem and creating another. A tiled
transpose can use shared memory to make global reads and writes coalesced, but
the shared tile itself is banked. If every lane in a warp hits the same bank
pattern, the on-chip access serializes. Padding the shared tile by one column
often breaks the conflict. The important part is not the magic `+ 1`; it is
knowing that shared memory has a banking model that must be profiled.

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
- Prefer asynchronous global-to-shared copy paths when the platform provides
  them and the tile pipeline has enough work to overlap the copy.

## Example

```cpp
constexpr int tile_dim = 32;

__global__ void transpose_tiled(float* out, const float* in,
                                int width, int height) {
    // Bad shape for a transposed read would be:
    //     __shared__ float tile[tile_dim][tile_dim];
    // because many lanes can hit the same bank when reading tile[x][y].
    //
    // Better: the extra column changes the bank mapping for transposed reads.
    // The exact padding rule is hardware-specific; profile local-memory
    // conflict counters rather than cargo-culting this into every kernel.
    __shared__ float tile[tile_dim][tile_dim + 1];

    int x = blockIdx.x * tile_dim + threadIdx.x;
    int y = blockIdx.y * tile_dim + threadIdx.y;

    if (x < width && y < height) {
        tile[threadIdx.y][threadIdx.x] = in[y * width + x];
    }

    __syncthreads();

    x = blockIdx.y * tile_dim + threadIdx.x;
    y = blockIdx.x * tile_dim + threadIdx.y;

    if (x < height && y < width) {
        out[y * height + x] = tile[threadIdx.x][threadIdx.y];
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
- A shared-memory tile can reduce memory traffic and still lose if it lowers
  occupancy below what the kernel needs to hide latency.

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
