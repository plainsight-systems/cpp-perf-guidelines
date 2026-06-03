+++
id = "GPU.2"
title = "Shape data for coalesced lane access before tuning the kernel"
category = "gpu"
status = "draft"
summary = "A warp or wave is fastest when adjacent lanes touch adjacent addresses; fix layout and indexing before chasing instruction-level tweaks."
tags = ["coalescing", "soa", "memory-bandwidth", "cuda", "compute-shaders"]
+++

## Rationale

GPU memory systems are built to serve groups of lanes at once. CUDA calls the
group a warp; AMD documentation often says wave or wavefront; Metal says SIMD
group; Vulkan exposes subgroups. The names differ, but the cost model rhymes:
if adjacent lanes read adjacent addresses, hardware can combine the request
into a small number of memory transactions. If lanes scatter across memory,
the same useful data needs many transactions and wastes bandwidth.

On modern NVIDIA GPUs, the review model is concrete: for compute capability
6.0 and newer, a warp's global-memory load coalesces into the number of
32-byte transactions needed to cover the addresses touched by the participating
lanes. Thirty-two lanes loading `float x[i]` consume 128 useful bytes and can
be served by four 32-byte sectors. Thirty-two lanes loading `x[i * 8]` still
consume only 128 useful bytes, but the addresses span 1024 bytes and can force
many more sectors. The kernel did the same arithmetic and lost on memory
layout.

This is the GPU version of the CPU cache-layout rule, but the penalty is
stronger because dozens of lanes participate in each memory instruction.

## Guidance

- Start from the lane mapping. For each hot load/store, write down the address
  touched by lane 0, lane 1, lane 2, and lane 31/63.
- Count sectors/cache lines, not just bytes. The useful payload may be 128
  bytes while the transaction footprint is much larger.
- Prefer structure-of-arrays or array-of-structures-of-arrays when kernels
  process one field across many objects.
- Keep the fastest-varying index in memory aligned with the fastest-varying
  lane. For 2D data, choose row/column mapping deliberately.
- Transpose data at load/build time if that turns every frame or timestep
  into coalesced access.
- Avoid pointer-rich object graphs in kernels. Flatten into indices and
  contiguous buffers.
- Align base allocations enough that the first warp does not straddle an extra
  sector/cache line. CUDA allocations are suitably aligned; suballocators must
  preserve that property.
- For graphics compute, swizzle threadgroup IDs only when profiling shows
  cache-locality benefit; keep the base lane-to-address mapping obvious.

## Example

```cpp
constexpr std::size_t warp_lanes = 32;
constexpr std::size_t sector_bytes = 32;

constexpr std::size_t sectors_for_warp_float_load(std::size_t stride) noexcept {
    // Model for a warp where lane L loads base + L * stride * sizeof(float).
    // It assumes an aligned base and participating lanes 0..31.
    const std::size_t last_byte = ((warp_lanes - 1) * stride * sizeof(float))
                                + sizeof(float) - 1;
    return (last_byte / sector_bytes) + 1;
}

static_assert(sectors_for_warp_float_load(1) == 4);   // 128 useful bytes.
static_assert(sectors_for_warp_float_load(8) == 32);  // Same payload, 8x sectors.

struct ParticleAos {
    float x, y, z;
    float vx, vy, vz;
    float lifetime;
};

struct ParticleSoa {
    float* x;
    float* y;
    float* z;
    float* vx;
    float* vy;
    float* vz;
    float* lifetime;
};

// Bad for a kernel that only integrates x: lane L reads p[L].x and p[L].vx.
// Those fields are separated by the whole object stride, so the warp touches
// more sectors than the useful x/vx payload requires.
__global__ void integrate_x_aos(ParticleAos* p, float dt, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) p[i].x += p[i].vx * dt;
}

// Good: lane L reads x[L] and vx[L]. Each instruction is a contiguous warp
// load, so memory transactions carry mostly useful payload.
__global__ void integrate_x_soa(ParticleSoa p, float dt, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) p.x[i] += p.vx[i] * dt;
}
```

## Caveats

- AoS can still be right when every lane consumes the whole object and object
  size is compact/aligned.
- Texture units and read-only caches can soften scattered reads, but they do
  not make arbitrary pointer chasing free.
- Layout changes affect CPU code too. If the CPU also consumes the data
  heavily, choose a shared layout only after profiling both sides.
- Compression, tiling, and vendor swizzles can change the exact transaction
  shape for images/textures. The lane-address review still applies to storage
  buffers, global memory, and compute-oriented data.

## References

- NVIDIA, CUDA C++ Best Practices Guide -
  <https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/>
- AMD GPUOpen, RDNA Performance Guide -
  <https://gpuopen.com/learn/rdna-performance-guide/>
- NVIDIA, Advanced API Performance: Shaders -
  <https://developer.nvidia.com/blog/advanced-api-performance-shaders/>
- Godot, GPU optimization -
  <https://docs.godotengine.org/en/4.5/tutorials/performance/gpu_optimization.html>
- Cross-reference: `CACHE.4` (AoS/SoA/AoSoA), `SIMD.2` (SoA for linear
  vector loads), `SIMD.5` (gather is usually a trap).
