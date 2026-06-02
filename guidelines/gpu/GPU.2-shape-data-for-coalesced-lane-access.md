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

This is the GPU version of the CPU cache-layout rule, but the penalty is
stronger because dozens of lanes participate in each memory instruction.

## Guidance

- Start from the lane mapping. Write down what lane 0, lane 1, lane 2, and
  lane N access for each hot load/store.
- Prefer structure-of-arrays or array-of-structures-of-arrays when kernels
  process one field across many objects.
- Keep the fastest-varying index in memory aligned with the fastest-varying
  lane. For 2D data, choose row/column mapping deliberately.
- Transpose data at load/build time if that turns every frame or timestep
  into coalesced access.
- Avoid pointer-rich object graphs in kernels. Flatten into indices and
  contiguous buffers.
- For graphics compute, swizzle threadgroup IDs only when profiling shows
  cache-locality benefit; keep the base lane-to-address mapping obvious.

## Example

```cpp
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

// Bad for a kernel that only integrates x: each lane loads through a stride
// that includes all other fields.
__global__ void integrate_x_aos(ParticleAos* p, float dt, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) p[i].x += p[i].vx * dt;
}

// Good: lane i reads x[i] and vx[i], so the warp touches contiguous ranges.
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
