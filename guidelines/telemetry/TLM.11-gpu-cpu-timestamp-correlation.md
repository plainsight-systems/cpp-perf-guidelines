+++
id = "TLM.11"
title = "GPU and accelerator timestamps require explicit calibration — the GPU clock is not the CPU clock"
category = "telemetry"
status = "draft"
summary = "Vulkan, D3D12, Metal, and CUDA expose their own timestamp queries; aligning them with CPU time needs periodic calibration events and a documented error bar. Heterogeneous time is approximate."
tags = ["gpu", "accelerator", "vulkan", "d3d12", "metal", "cuda", "mlx", "calibration"]
+++

## Rationale

A CPU-only profiler shows a single timeline: events tagged
with `rdtsc` / `CLOCK_MONOTONIC` ticks, all from the same
clock domain. The moment the system uses an accelerator —
GPU for graphics, GPU/NPU for inference, FPGA, dedicated
crypto silicon — there are *two* clocks, and they do not
agree.

The technical reality:

- **The GPU has its own oscillator.** Its timestamp queries
  read a GPU-internal counter that ticks at a frequency the
  CPU does not directly know. Even on unified-memory
  systems (Apple Silicon, AMD APUs) the CPU and GPU
  timestamp registers are different domains.
- **The frequency relationship is not constant.** GPU
  thermal/power management can change the tick rate
  mid-frame; the CPU's TSC is independently frequency-
  managed.
- **The phase is undefined.** "GPU tick zero" and "CPU
  tick zero" are unrelated; they have to be related by
  *calibration* — capturing both clocks at the same
  external event.
- **Calibration drifts.** Even after a known-good
  calibration point, the two domains drift apart at
  rates of microseconds per second. Long captures need
  periodic re-calibration; short captures need at least
  one.

This is well-trodden ground in the graphics community —
PIX, RenderDoc, Microprofile, Tracy's GPU support, and
Unreal Insights all solve a version of it — and it
becomes urgent in any system where CPU and GPU work
overlap and a timeline view is needed for analysis.

### The API surface

Each accelerator API exposes calibration primitives:

- **D3D12** — `ID3D12CommandQueue::GetClockCalibration`
  returns a CPU TSC value and a GPU timestamp value
  captured at the same instant.
  `GetTimestampFrequency` returns the GPU tick rate.
  Together they are sufficient for one-shot calibration.
- **Vulkan** — `VK_EXT_calibrated_timestamps` extension
  exposes `vkGetCalibratedTimestampsEXT`, which atomically
  reads any subset of `{device, monotonic, monotonic_raw,
  query_performance_counter}` clocks.
  `VK_EXT_host_query_reset` for reusing query pools.
- **Metal** — `MTLCommandBuffer.GPUStartTime` and
  `GPUEndTime`, and `MTLDevice.sampleTimestamps(...)`
  on macOS 11+ / iOS 14+, return CPU host time and GPU
  device time captured together.
- **CUDA** — `cudaEventRecord` + `cudaEventElapsedTime`
  for relative GPU timing; the CPU correlation comes
  from `cudaEventRecord` + `clock_gettime` captured at
  the same line of host code (approximate, no atomic
  primitive).
- **MLX** (Apple Silicon ML) — captures via Metal's
  timestamp infrastructure; the same calibration story
  applies.

### The error model

A correlated timeline is **approximate** with a documented
error bar:

- **Calibration error.** The "atomic" capture of two
  domains is not actually atomic on all APIs; the
  documentation gives bounds (e.g.,
  `VkCalibratedTimestampInfoEXT`'s `maxDeviation`
  output). For one-shot calibration, treat the error
  as ±(maxDeviation / 2).
- **Drift between calibrations.** Linear interpolation
  between two calibration points carries an error
  proportional to the time since the last calibration
  and the rate of frequency change. Frame-by-frame
  re-calibration keeps this bounded.
- **Frequency uncertainty.** `GetTimestampFrequency` on
  D3D12 is documented as a *nominal* frequency; the
  actual rate during execution may differ.

The discipline:

1. **Capture a calibration point at trace start.**
2. **Re-calibrate periodically** — once per frame in
   graphics, once per inference step or every N seconds
   in headless workloads.
3. **Record the calibration error** in the trace
   metadata.
4. **Never quote sub-microsecond CPU/GPU alignment
   without showing the error bar.** Cross-domain
   alignment claims that the calibration cannot support
   are noise dressed as precision.

### Where this matters for the corpus

An ML inference engine on Apple Silicon (MLX on the GPU,
sampler and post-processing on the CPU) operates exactly
in this regime: decode work runs partly on the CPU and
partly on the GPU, and a trace that
correlates these is the difference between "we know
where the time went" and "we know the CPU side of where
the time went." Game engines have the same need for
render-pipeline analysis; servers with GPU offload
(rendering, ML inference, video transcode) have it for
end-to-end latency analysis.

## Guidance

- **Use the API's calibrated-timestamp primitive when
  available.** Vulkan's `VK_EXT_calibrated_timestamps`,
  D3D12's `GetClockCalibration`, Metal's
  `sampleTimestamps`. They give bounded error; ad-hoc
  "read CPU time near a GPU query" does not.
- **Record both the GPU tick value and the calibrated
  CPU value in the trace.** The analyzer converts to a
  common timeline at presentation time; the raw values
  let the calibration be redone if the trace format
  evolves.
- **Calibrate at trace start and at frame/step
  boundaries.** Once-per-trace is the bare minimum;
  once-per-frame keeps the alignment drift under one
  millisecond on graphics-grade hardware.
- **Record the calibration error.** Vulkan's
  `maxDeviation` and equivalents; document the bound
  alongside every aligned event.
- **Treat the GPU timeline as a separate channel** (TLM.2).
  GPU events are emitted asynchronously by the device;
  the CPU may not know the GPU's timestamp until the
  command buffer is read back. The pipeline is: GPU
  emits, CPU drains, analyzer correlates.
- **Cross-thread (and cross-domain) correlation needs a
  shared origin.** Within a process, all threads use the
  same CPU clock; across CPU and GPU, the calibration is
  the origin.
- **For unified-memory systems (Apple Silicon, AMD APUs)
  the same rules apply.** UMA reduces *memory copy*
  cost; it does not reduce *clock domain* cost. The CPU
  and GPU timestamps still need calibration.
- **Cross-reference `TLM.9`.** GPU clocks are not the
  CPU TSC; everything `TLM.9` says about explicit
  source and fenced reads applies on the CPU side, and
  the GPU side has its own equivalents.

## Example

```cpp
// Good: Vulkan VK_EXT_calibrated_timestamps. One atomic
// read returns the GPU device timestamp and the host
// CPU timestamp; the maxDeviation field bounds the
// error.
#include <vulkan/vulkan.h>

struct Calibration {
    std::uint64_t gpu_ticks;
    std::uint64_t cpu_ticks;
    std::uint64_t cpu_ticks_per_ns;     // from CPUID.15H or QPF
    std::uint64_t gpu_ticks_per_ns;     // from timestampPeriod
    std::uint64_t max_deviation_ticks;  // from vkGetCalibratedTimestampsEXT
};

Calibration calibrate_vulkan(VkDevice dev) noexcept {
    const VkCalibratedTimestampInfoEXT info[] = {
        {VK_STRUCTURE_TYPE_CALIBRATED_TIMESTAMP_INFO_EXT, nullptr,
         VK_TIME_DOMAIN_DEVICE_EXT},
        {VK_STRUCTURE_TYPE_CALIBRATED_TIMESTAMP_INFO_EXT, nullptr,
         VK_TIME_DOMAIN_CLOCK_MONOTONIC_EXT},
    };
    std::uint64_t timestamps[2]{};
    std::uint64_t max_dev{};
    vkGetCalibratedTimestampsEXT(dev, 2, info, timestamps, &max_dev);
    return {.gpu_ticks = timestamps[0],
            .cpu_ticks = timestamps[1],
            .max_deviation_ticks = max_dev};
}

// Good: Metal sampleTimestamps. Returns CPU host time and
// GPU device time captured at the same instant.
// (Pseudocode for an Objective-C++ / Swift-C boundary.)
struct MetalCalibration {
    std::uint64_t cpu_mach_time;
    std::uint64_t gpu_device_time;
};

MetalCalibration calibrate_metal(/*MTLDevice*/) noexcept {
    MetalCalibration c{};
    // [device sampleTimestamps:&c.cpu_mach_time
    //              gpuTimestamp:&c.gpu_device_time];
    return c;
}

// Good: per-frame re-calibration. Re-anchor the timeline
// at each render/inference frame; drift cannot exceed
// one frame's worth of frequency change.
void render_frame(VkDevice dev, std::uint32_t frame_idx) noexcept {
    const auto cal = calibrate_vulkan(dev);
    trace_emit_calibration(frame_idx, cal);   // recorded in the trace
    // ... GPU work, timestamp queries ...
}

// Bad: ad-hoc "read CPU time near a GPU query." The two
// reads are not atomic; the error is unbounded and varies
// with scheduler delays, interrupt latency, and the
// driver's submission cost.
struct AdHocBad {
    std::uint64_t cpu_time;
    std::uint64_t gpu_time;
};

AdHocBad calibrate_bad(VkDevice dev) noexcept {
    AdHocBad c{};
    c.cpu_time = monotonic_ns();
    // ... unbounded delay here ...
    vkGetQueryPoolResults(dev, /*...,*/ &c.gpu_time, /*...*/);
    // c.cpu_time and c.gpu_time are not at the same instant.
    return c;
}

// Bad: implying sub-microsecond alignment without the
// error bar. The trace says CPU-task ended at 12.345 ms,
// GPU-task started at 12.346 ms — the truth might be that
// the calibration error is 0.5 ms, in which case the
// alignment is noise.
void mislead_render_pipeline_view(/*...*/) {
    // "GPU started immediately after CPU finished — pipeline
    //  is well-fed!"   ← unsupported without showing maxDeviation
}
```

## Caveats

- **Not every API exposes calibrated timestamps.**
  Older drivers, OpenGL on some platforms, OpenCL,
  some compute frameworks (CUDA, MLX via Metal). When
  the primitive is missing, the best alternative is
  read-CPU-then-immediately-issue-GPU-query, accepting
  the unbounded error and documenting it.
- **Unified memory ≠ unified time.** Apple Silicon and
  AMD APUs share memory between CPU and GPU; they do
  not share clocks. The clock-domain math is identical
  to discrete-GPU systems.
- **Calibration costs cycles.** A
  `vkGetCalibratedTimestampsEXT` call is a host-device
  round-trip; doing it every frame is fine, every emit
  is not. Calibrate at frame boundaries; convert per-
  event timestamps at analysis time.
- **`GetTimestampFrequency` on D3D12 is nominal.** The
  documentation says it returns the *nominal* tick rate;
  actual instantaneous rate can differ. For
  microsecond-grade analysis this is fine; for
  nanosecond-grade it is not.
- **Multi-GPU systems have multiple clock domains.**
  Each GPU has its own counter; calibration is
  per-device, not per-application.
- **Some platforms expose privileged calibration only.**
  `VK_TIME_DOMAIN_CLOCK_MONOTONIC_RAW_EXT` requires the
  driver and OS to support it; not universal.
- **Apple Silicon GPU timestamps are coarse.** The
  M-series GPU counter resolution is documented in the
  Metal docs and is coarser than the CPU's. The
  resolution sets the floor on what alignment can mean.
- **The "GPU work happens after the CPU schedules it"
  invariant can be violated by CPU/GPU overlap.** A
  command buffer submitted at time T may execute at
  time T+epsilon, where epsilon depends on driver and
  hardware state. Calibration captures the relationship
  but does not eliminate it.

## References

- Khronos Vulkan registry, `VK_EXT_calibrated_timestamps` —
  <https://registry.khronos.org/vulkan/specs/1.3-extensions/man/html/VK_EXT_calibrated_timestamps.html>
- Microsoft Learn, *Direct3D 12 Timing* —
  `ID3D12CommandQueue::GetClockCalibration`,
  `GetTimestampFrequency` —
  <https://learn.microsoft.com/en-us/windows/win32/direct3d12/timing>
- Apple Developer, *Metal sampleTimestamps and
  MTLCommandBuffer GPUStartTime* —
  <https://developer.apple.com/documentation/metal/>
- NVIDIA, *CUDA C++ Programming Guide — Events* —
  `cudaEventRecord`, `cudaEventElapsedTime` —
  <https://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html>
- Microprofile — CPU/GPU timing with documented
  drift — <https://github.com/jonasmr/microprofile>
- Tracy Profiler — GPU support across
  OpenGL / Vulkan / D3D11 / D3D12 / Metal / CUDA /
  OpenCL — <https://github.com/wolfpld/tracy>
- Microsoft PIX for Windows — CPU/GPU correlation via
  ETW + timestamp queries —
  <https://devblogs.microsoft.com/pix/>
- Unreal Engine, *GPU Profiling* documentation.
- Cross-reference: `TLM.2` (GPU is its own channel),
  `TLM.5` (the calibration must be recorded in the
  trace schema, not implied), `TLM.9` (the CPU side
  uses the fenced/invariant TSC; the GPU side uses
  its API's primitives — same discipline, different
  primitives), `TLM.10` (GPU events are drained
  asynchronously; the per-thread ring model on the CPU
  side maps to per-queue or per-device buffers on the
  GPU side).
