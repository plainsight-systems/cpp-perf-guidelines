+++
id = "GPU.10"
title = "Profile with GPU timelines and counters before optimizing"
category = "gpu"
status = "draft"
summary = "Wall-clock frame time and utilization percentages do not identify GPU bottlenecks; use timelines and counters to classify stalls, bandwidth, occupancy, divergence, and submission gaps."
tags = ["profiling", "nsight", "rgp", "pix", "xcode", "counters"]
+++

## Rationale

GPU performance is not visible from CPU timing alone. A CPU timer around a
dispatch often measures enqueue cost, not execution. A whole-frame timer says
the frame is slow, but not whether the limit is launch overhead, memory
bandwidth, occupancy, divergence, barriers, fill rate, texture sampling, or a
CPU/GPU wait. A utilization number can say the GPU was busy without saying
what resource was saturated.

A credible GPU optimization starts by classifying the bottleneck with the
right tool:

- timeline tools show queue gaps, submission overhead, copies, waits, and
  CPU/GPU overlap;
- kernel/shader profilers show occupancy, memory transactions, cache behavior,
  divergence, instruction throughput, and stalls;
- render pass profilers show which pass or attachment dominates the frame.

## Guidance

- Use a timeline first when the symptom is "the GPU is idle" or "the frame
  has bubbles": Nsight Systems, PIX, RenderDoc/GPU captures, Xcode GPU tools,
  Unreal Insights/RDG Insights, Tracy, or platform equivalents.
- Use a kernel/shader counter profiler when one dispatch/pass dominates:
  Nsight Compute, Radeon GPU Profiler, Xcode counters, PIX counters, Android
  GPU Inspector, or vendor equivalents.
- Record pass/dispatch names and debug markers in clean profiling builds.
  Anonymous command buffers produce anonymous guesses.
- Separate CPU submission time, queue wait time, GPU execution time, and
  readback/synchronization time.
- Capture before/after profiles for each optimization. Include the hardware,
  driver, tool version, workload, resolution/problem size, and power mode.
- Do not use debug builds, validation-heavy captures, shader printf, or
  diagnostic instrumentation as throughput evidence unless the overhead is the
  thing being measured.

## Example

```cpp
// Good: name the GPU work so the timeline and counter tools can attach
// measurements to the same semantic operation across captures.
void dispatch_cull(CommandList& cmd, Buffer visible, Buffer meshlets) {
    cmd.begin_marker("Cull meshlets");
    cmd.bind_pipeline(cull_pipeline);
    cmd.bind_buffer("VisibleMeshlets", visible);
    cmd.bind_buffer("Meshlets", meshlets);
    cmd.dispatch(indirect_or_grid_size(meshlets));
    cmd.end_marker();
}
```

## Caveats

- Profilers perturb execution. Use them to identify shape and counters, then
  confirm final throughput in a clean build.
- GPU counters are vendor- and generation-specific. Compare the same counter
  family on the same hardware before drawing conclusions.
- Thermal and power management can dominate laptops, mobile devices, and
  consoles in constrained modes. Lock or record power conditions.

## References

- NVIDIA, Nsight Compute Profiling Guide -
  <https://docs.nvidia.com/nsight-compute/ProfilingGuide/>
- NVIDIA, Understanding the Visualization of Overhead and Latency in Nsight
  Systems - <https://developer.nvidia.com/blog/understanding-the-visualization-of-overhead-and-latency-in-nsight-systems/>
- AMD GPUOpen, RDNA Performance Guide -
  <https://gpuopen.com/learn/rdna-performance-guide/>
- Android Developers, Filament GPU counter case study -
  <https://developer.android.com/android-performance-analyzer/case-study/filament>
- Unreal Engine, Render Dependency Graph -
  <https://dev.epicgames.com/documentation/en-us/unreal-engine/render-dependency-graph-in-unreal-engine>
- Cross-reference: `TLM.6` (diagnostic is not benchmark), `TLM.11`
  (CPU/GPU timestamp correlation), `GPU.3` (occupancy).
