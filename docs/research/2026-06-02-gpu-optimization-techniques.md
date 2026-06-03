# GPU and Accelerator Optimization - Technique Extraction

Research note - 2026-06-02. Supports packet
`2026-06-02-gpu-category-buildout`. Technique-extraction pass for the
`gpu` category: what each source teaches as a reusable rule, cost model, or
anti-pattern. This category sits beside `simd`, `cache-layout`,
`telemetry`, and `memory`: the same C++ systems code often owns both the
CPU side of submission and the GPU-side kernels/shaders.

Sources are classified per the `CONTRIBUTING.md` sourcing rule:

- **Citable** - free public docs, articles, talks, papers, or slides.
- **Cite-by-reference** - copyrighted books, paid standards, or public
  talks whose text/slides are not freely reusable.
- **Permissive code** - MIT / BSD / Apache-2.0 / similar source code.
- **Study-only code** - source-available or non-permissive code; study
  concepts only, do not copy code.

---

## 1. CUDA fundamentals

### NVIDIA, CUDA C++ Programming Guide - Citable

The CUDA programming model exposes a hierarchy that maps directly to the
guidelines:

- A kernel launch creates a grid of thread blocks; a block runs on one
  streaming multiprocessor and can cooperate through shared memory and
  block-level barriers.
- Threads execute in warps. Work that diverges inside a warp serializes
  paths and leaves lanes inactive.
- Device memory spaces have different lifetime, visibility, and cost:
  registers, local memory, shared memory, global memory, constant memory,
  and texture memory.
- Streams express ordering; independent streams can overlap kernel
  execution, host work, and transfers when the hardware and dependencies
  allow it.
- CUDA Graphs capture repeated command sequences and replay them with
  lower CPU launch overhead.

**Rules extracted:** keep reusable work in kernels rather than bouncing to
the CPU; design launches around block-level cooperation; use streams and
events as the dependency language; use graphs for repeated short command
sequences.

### NVIDIA, CUDA C++ Best Practices Guide - Citable

Core lessons:

- Minimize transfers between host and device. If a value will be used by
  later GPU work, leave it on the device even if one kernel is not faster
  than CPU code in isolation.
- Prefer pinned/page-locked host memory for transfer bandwidth and
  asynchronous copies.
- Coalesced global-memory access is a first-order rule: adjacent threads
  should touch adjacent memory whenever possible.
- Shared memory is not automatically faster; it pays when it removes
  redundant global reads or reorders an otherwise uncoalesced access
  pattern.
- Occupancy is constrained by registers, shared memory, block size, and
  hardware limits. Higher occupancy only helps when the workload needs
  more latency hiding.

**Anti-patterns killed:** tiny CPU/GPU round trips in the middle of a
pipeline; AoS layouts that force each warp into strided loads; using
shared memory as a ritual without measuring reuse; maximizing occupancy
after a kernel has become compute-bound.

### NVIDIA Nsight Compute and Nsight Systems - Citable

Nsight Compute splits kernel analysis into sections such as occupancy,
memory workload, scheduler stats, instruction throughput, and "speed of
light" resource utilization. Nsight Systems shows the end-to-end timeline:
host API calls, launch latency, queue gaps, device execution, memcpy, and
synchronization stalls.

**Rule extracted:** a GPU optimization claim needs the right profiler.
Nsight Systems answers "why is the GPU idle?" Nsight Compute answers "why
is this kernel slow?" `nvidia-smi` utilization is not a kernel diagnosis.

### NVIDIA CUDA Graphs articles - Citable

Modern GPUs execute many useful kernels in microseconds, while CPU launch
and driver submission overhead are also microsecond-scale. CUDA Graphs
reduce repeated launch overhead by capturing a sequence and replaying it
as one graph launch. The same pattern appears in graphics APIs as command
buffers, bundles, render graphs, and precompiled pipeline state.

**Rule extracted:** repeated short kernels or passes should be fused,
batched, or graph-captured. Optimizing the kernel body is not enough when
submission overhead dominates.

## 2. Metal, Vulkan, D3D12, and explicit GPU APIs

### Apple Metal documentation and performance talks - Citable

Metal exposes compute grids, threadgroups, threadgroup memory, and SIMD
groups. Apple documentation explicitly warns that divergent control flow
inside a SIMD group executes both paths. Metal resource synchronization
documentation frames GPU work as parallel commands over shared resources:
fences, events, barriers, storage modes, and multiple resource instances
are the tools for avoiding hazards and CPU/GPU stalls.

**Rules extracted:** design threadgroup size around `threadExecutionWidth`
and measured resource usage; avoid SIMD-group divergence; use multiple
resource instances to keep CPU and GPU from waiting on the same object;
make synchronization precise enough to preserve overlap.

### Khronos Vulkan synchronization docs and samples - Citable

Vulkan makes synchronization the application's responsibility. Pipeline
barriers define source and destination stage/access scopes; overbroad
barriers stall stages that do not need to wait. The wait-idle performance
sample demonstrates that `vkDeviceWaitIdle`/`vkQueueWaitIdle` in a frame
loop creates bubbles, while fences let the CPU advance without draining
the GPU.

**Rules extracted:** a barrier is a dependency edge, not a flush button.
Use the narrowest stages/access masks that describe the actual hazard.
Avoid frame-loop wait-idle except for teardown or exceptional recovery.

### Microsoft D3D12 multi-engine synchronization - Citable

D3D12 exposes graphics, compute, and copy queues. The API allows overlap
between engines, but only if command lists, resource states, fences, and
queue dependencies are correct. Incorrect or unnecessary synchronization
turns explicit control into hidden serialization.

**Rule extracted:** async copy/compute requires a dependency graph and
proof that resources and engines do not contend; queue count alone does
not create overlap.

### AMD GPUOpen RDNA Performance Guide and Occupancy Explained - Citable

AMD's material separates theoretical occupancy from performance. Occupancy
is the number of resident waves relative to hardware capacity and mostly
matters as a latency-hiding resource. Register pressure, LDS usage,
threadgroup size, memory behavior, and wave mode shape it. RDNA guidance
also stresses barriers, memory allocation/suballocation, coalesced blocks,
and profiler-driven workflow through Radeon GPU Profiler and PIX/Vulkan
validation checks.

**Rules extracted:** occupancy is a budget, not a score; reduce register
pressure and LDS usage when they block latency hiding; profile before
trading arithmetic for occupancy.

## 3. Engine and renderer practice

### Unreal Engine Render Dependency Graph and GPU profiling docs - Citable

Unreal's RDG records render passes into a graph, reasons about resource
lifetimes and dependencies, aliases transient resources, inserts
transitions and split barriers, culls unused passes, schedules async
compute where dependencies allow it, and exposes RDG Insights. Unreal GPU
profiling emphasizes pass-level timing, not just whole-frame time.

**Rules extracted:** express the frame as a graph so transient memory,
barriers, async compute, and pass culling can be optimized from declared
dependencies. Async compute is a graph scheduling result, not a flag to
sprinkle on unrelated work.

### Godot GPU optimization and rendering architecture docs - Citable

Godot emphasizes diagnosing whether a frame is CPU-bound, vertex-bound,
fragment/fill-rate-bound, bandwidth-bound, or shader-bound. It calls out
expensive shaders, texture reads, viewport textures, overdraw, shadows,
post-processing, VRAM compression, and mobile tile-based rendering.

**Rules extracted:** identify the limiting GPU stage before changing
content or code; reduce pixels, samples, texture reads, overdraw, or
shader complexity only when that stage is the bottleneck. Mobile tilers
make render-pass and attachment decisions first-order.

### Filament framegraph and Android GPU counter case study - Citable

Filament's framegraph computes render resources and pass dependencies for
a frame. Android's Filament case study shows GPU counter analysis finding
frames waiting on GPU completion and interpreting throughput/counter data
rather than treating FPS as a sufficient diagnosis.

**Rules extracted:** framegraphs are memory-lifetime and dependency
systems, not only architecture diagrams. Counter-based profiling is the
path from "the frame is slow" to the specific stage and resource causing
it.

### Capcom RE Engine meshlet rendering material - Citable

Public Capcom RE Engine material on meshlet rendering, visibility buffers,
and two-phase occlusion demonstrates the engine-level GPU pattern:
restructure scene data and visibility work so the GPU avoids processing
invisible or incoherent geometry. This is not CUDA, but the transferable
lesson is work amplification control.

**Rule extracted:** performance often comes from changing the work shape
(meshlets, culling, compaction, visibility buffers), not micro-tuning the
same shader.

### Naughty Dog public rendering talks - Citable / cite-by-reference

Public Naughty Dog material around Uncharted 4 and PS4-era engine work
shows production use of GPU-side vertex processing, material systems,
frame pipelining, and tight budgets. The important corpus lesson is not a
single API trick; it is that shipping engines make data-oriented GPU
pipelines that keep work coherent and budgeted per frame.

**Rule extracted:** GPU optimization is a content/data/pipeline problem as
much as a kernel problem. Avoid per-feature one-offs that create incoherent
passes, shader variants, or unbounded per-frame GPU work.

### Wicked Engine GPU particles - Citable / permissive-code-adjacent

Wicked Engine's GPU particle implementation uses compute shaders,
append/consume buffers, LDS/threadgroup memory, and GPU-side simulation to
avoid CPU round trips. The source is permissive enough to study, but the
guideline prose does not copy code.

**Rule extracted:** once data is naturally device-resident, keep simulation
and compaction on the GPU and emit compact draw/dispatch inputs rather
than round-tripping to the CPU.

## 4. Guideline slate

- `GPU.1` - Keep data on the device; every host-device round trip needs a
  latency and bandwidth budget.
- `GPU.2` - Shape data for coalesced lane access before tuning the kernel.
- `GPU.3` - Treat occupancy as latency-hiding budget, not a score.
- `GPU.4` - Keep warp/wave/SIMD-group control flow coherent.
- `GPU.5` - Use shared/threadgroup memory only when reuse or reordering
  pays for barriers and occupancy loss.
- `GPU.6` - Batch tiny GPU work with graphs, command buffers, or kernel
  fusion.
- `GPU.7` - Pipeline CPU and GPU work with queues, streams, fences, and
  multi-buffered resources.
- `GPU.8` - Make barriers describe real hazards; overbroad barriers kill
  overlap.
- `GPU.9` - Suballocate and alias transient GPU memory from frame or
  graph-owned heaps.
- `GPU.10` - Profile with GPU timelines and counters before optimizing.

## 5. Sharpening pass - 2026-06-02

Maintainer review of the first GPU pass: the category had the right outline,
but the guidance was less valuable than the established CPU-side categories
because it stopped too often at "use the right profiler" or "avoid
round-trips." The revision pass extracts more concrete mechanics:

- **Coalescing needs a transaction model.** NVIDIA's current best-practices
  guide summarizes compute capability 6.0+ global-memory coalescing as the
  number of 32-byte transactions needed to serve the warp. That gives a
  usable review question: for this instruction, how many 32-byte sectors does
  a warp touch? Stride-1 `float` loads are four sectors for 32 lanes; stride-8
  can turn the same useful 128 bytes into many more sectors. This is the
  missing concrete lever in `GPU.2`.
- **Occupancy needs named limiters.** AMD's occupancy article splits
  practical limiters into VGPR pressure, LDS, threadgroup size, barriers, and
  lack of enough waves. NVIDIA exposes the same resource logic through the
  CUDA occupancy APIs and Nsight Compute: registers per thread, shared memory
  per block, blocks per SM, and achieved occupancy. `GPU.3` should make those
  limiters explicit instead of presenting occupancy as a profiler vibe.
- **Shared memory needs bank-conflict examples.** NVIDIA and AMD both document
  banked on-chip memory. The classic valuable example is tiled transpose:
  shared memory coalesces global loads/stores, but a `[tile][tile]` layout can
  create bank conflicts; padding the second dimension (`tile + 1`) breaks the
  conflict. This is more useful than a generic stencil in `GPU.5`.
- **Overlap requires exact preconditions.** CUDA overlap is not "use streams."
  It requires concurrent-copy hardware, pinned host memory, and operations in
  different non-default streams. Vulkan/D3D12/Metal equivalents require
  queue/engine capability, separate in-flight resources, and fences/events
  narrow enough not to drain the device. `GPU.7` should name those
  preconditions.
- **Barriers should be reviewed like memory-order edges.** The useful
  question is "what wrote, what reads, which stage/access pair connects
  them?" A generic all-stage barrier example is less valuable than showing a
  compute-shader-write to fragment-shader-read edge and calling out
  wait-idle as the synchronization equivalent of `seq_cst` everywhere.
- **Profiling should map symptom to counter family.** The stronger
  `GPU.10` form is a decision table: queue gaps -> timeline; high memory
  sectors/request -> coalescing; low achieved occupancy + VGPR limiter ->
  register pressure; high barrier/wait stalls -> synchronization; low branch
  efficiency/inactive lanes -> divergence; high launch/API time -> batching
  or graphs.

## 6. Source index

- NVIDIA, CUDA C++ Programming Guide -
  <https://docs.nvidia.com/cuda/cuda-c-programming-guide/>
- NVIDIA, CUDA C++ Best Practices Guide -
  <https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/>
- NVIDIA, Nsight Compute Profiling Guide -
  <https://docs.nvidia.com/nsight-compute/ProfilingGuide/>
- NVIDIA, *Getting Started with CUDA Graphs* -
  <https://developer.nvidia.com/blog/cuda-graphs/>
- NVIDIA, *Advanced API Performance: Shaders* -
  <https://developer.nvidia.com/blog/advanced-api-performance-shaders/>
- Apple, Metal compute threadgroups -
  <https://developer.apple.com/documentation/metal/compute_passes/creating_threads_and_threadgroups>
- Apple, Metal resource synchronization -
  <https://developer.apple.com/documentation/metal/resource-synchronization>
- Apple, *Learn performance best practices for Metal shaders* -
  <https://developer.apple.com/videos/play/tech-talks/111373>
- Khronos, Vulkan pipeline barriers sample -
  <https://docs.vulkan.org/samples/latest/samples/performance/pipeline_barriers/README.html>
- Khronos, Vulkan wait-idle sample -
  <https://docs.vulkan.org/samples/latest/samples/performance/wait_idle/README.html>
- Khronos, Vulkan synchronization spec -
  <https://docs.vulkan.org/spec/latest/chapters/synchronization.html>
- Microsoft, D3D12 multi-engine synchronization -
  <https://learn.microsoft.com/en-us/windows/win32/direct3d12/user-mode-heap-synchronization>
- AMD GPUOpen, RDNA Performance Guide -
  <https://gpuopen.com/learn/rdna-performance-guide/>
- AMD GPUOpen, *Occupancy explained* -
  <https://gpuopen.com/learn/occupancy-explained/>
- Unreal Engine, Render Dependency Graph -
  <https://dev.epicgames.com/documentation/en-us/unreal-engine/render-dependency-graph-in-unreal-engine>
- Unreal Engine, GPU/rendering optimization guidelines -
  <https://dev.epicgames.com/documentation/en-us/unreal-engine/guidelines-for-optimizing-rendering-for-real-time-in-unreal-engine>
- Godot, GPU optimization -
  <https://docs.godotengine.org/en/4.5/tutorials/performance/gpu_optimization.html>
- Godot, internal rendering architecture -
  <https://docs.godotengine.org/en/4.5/engine_details/architecture/internal_rendering_architecture.html>
- Filament framegraph notes -
  <https://google.github.io/filament/notes/framegraph.html>
- Android Developers, Filament GPU counter case study -
  <https://developer.android.com/android-performance-analyzer/case-study/filament>
- Capcom RE Engine meshlet rendering pipeline -
  <https://enginearchitecture.org/downloads/REAC_2025_Capcom.pdf>
- Naughty Dog, *The Technical Art of Uncharted 4* -
  <https://advances.realtimerendering.com/other/2016/naughty_dog/>
- Naughty Dog, *Parallelizing the Naughty Dog Engine Using Fibers* -
  <https://media.gdcvault.com/gdc2015/presentations/Gyrling_Christian_Parallelizing_The_Naughty.pdf>
- Wicked Engine, GPU-based particle simulation -
  <https://wickedengine.net/2017/11/07/gpu-based-particle-simulation/>
