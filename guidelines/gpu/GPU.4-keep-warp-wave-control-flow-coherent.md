+++
id = "GPU.4"
title = "Keep warp, wave, and SIMD-group control flow coherent"
category = "gpu"
status = "draft"
summary = "When lanes in the same GPU execution group take different paths, the hardware serializes those paths; group work so neighboring lanes do the same thing."
tags = ["divergence", "warp", "wavefront", "simdgroup", "branching"]
+++

## Rationale

GPU lanes in a warp/wave/SIMD group share instruction issue. When a branch
splits lanes, the hardware runs one path for the lanes that need it and then
the other path for the remaining lanes. Inactive lanes still occupy the group
while the other path runs.

The branch itself is not the problem. Uniform branches, where every lane takes
the same path, are cheap. The expensive case is per-lane divergence in hot
code, especially when each path performs memory access or long arithmetic.

A useful review question: does the branch condition vary by dispatch/pass, by
threadgroup, or by lane? Dispatch- and threadgroup-uniform decisions are
usually fine. Lane-varying decisions inside a hot warp/wave are the expensive
case.

## Guidance

- Sort, bin, compact, or dispatch separately so neighboring lanes process the
  same material, operation, particle state, ray state, or object type.
- Hoist uniform decisions out of the kernel/shader variant when possible.
- Split a mixed kernel into coherent kernels when each branch body is large
  enough that launch/compaction overhead is not the limiter.
- Use predication for tiny branches only when the extra work is cheaper than
  divergent control flow.
- Avoid divergent reads from constant/uniform buffers. If each lane indexes a
  different value, use a storage/resource buffer shape intended for divergent
  access.
- For ray tracing and irregular workloads, group work by coherence domain:
  material, shader, ray depth, tile, or spatial cluster.
- Measure branch efficiency, inactive lanes, or equivalent profiler counters
  before and after a restructuring pass.
- Keep tail handling separate from the hot body when possible. A cleanup
  dispatch or scalar tail can be cheaper than making every lane carry edge
  conditions through the main kernel.

## Example

```cpp
// Bad: one mixed kernel processes every particle state. Warps that contain
// live, sleeping, and colliding particles serialize all paths.
__global__ void update_particles_mixed(Particle* p, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;

    if (p[i].state == ParticleState::Colliding) {
        solve_collision(p[i]);
    } else if (p[i].state == ParticleState::Sleeping) {
        decay_sleep_timer(p[i]);
    } else {
        integrate(p[i]);
    }
}

// Better: compact indices by state, then launch coherent kernels over each
// list. Each warp mostly executes one path.
update_colliding<<<grid_a, block>>>(particles, colliding_indices, colliding_n);
update_sleeping<<<grid_b, block>>>(particles, sleeping_indices, sleeping_n);
update_live<<<grid_c, block>>>(particles, live_indices, live_n);
```

```cpp
// Also good: make the decision dispatch-uniform. The branch remains, but all
// lanes in the dispatch take the same path.
enum class ParticlePass { integrate, collide, sleep };

template<ParticlePass pass>
__global__ void update_particles_pass(Particle* p, const int* indices, int n) {
    int lane = blockIdx.x * blockDim.x + threadIdx.x;
    if (lane >= n) return;

    Particle& particle = p[indices[lane]];
    if constexpr (pass == ParticlePass::collide) {
        solve_collision(particle);
    } else if constexpr (pass == ParticlePass::sleep) {
        decay_sleep_timer(particle);
    } else {
        integrate(particle);
    }
}
```

## Caveats

- Splitting work creates extra passes, queues, or compaction cost. It pays
  when the avoided divergence is larger than the scheduling overhead.
- Small cleanup branches at the edge of an array are normal.
- Some hardware features, such as shader execution reordering, can reduce
  divergence costs for specific workloads, but they do not remove the need to
  feed coherent work.

## References

- Apple, Creating threads and threadgroups -
  <https://developer.apple.com/documentation/metal/compute_passes/creating_threads_and_threadgroups>
- NVIDIA, Advanced API Performance: Shaders -
  <https://developer.nvidia.com/blog/advanced-api-performance-shaders/>
- NVIDIA, CUDA C++ Programming Guide -
  <https://docs.nvidia.com/cuda/cuda-c-programming-guide/>
- Capcom RE Engine meshlet rendering pipeline -
  <https://enginearchitecture.org/downloads/REAC_2025_Capcom.pdf>
- Cross-reference: `GEN.2` (branchless vs predicted), `GPU.2` (lane access
  shape), `GPU.10` (branch/divergence counters).
