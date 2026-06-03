+++
id = "GPU.6"
title = "Batch tiny GPU work with graphs, command buffers, or kernel fusion"
category = "gpu"
status = "draft"
summary = "When kernels or passes are only microseconds long, CPU submission and driver overhead can dominate; batch repeated work or fuse stages."
tags = ["cuda-graphs", "command-buffers", "launch-overhead", "kernel-fusion"]
+++

## Rationale

GPU operations are not free to submit. A CUDA kernel launch, a graphics
dispatch, a command-buffer commit, or a queue submission has CPU-side runtime
and driver work before the device can execute. As GPUs get faster, useful
kernels can shrink to the same microsecond scale as the launch overhead.

If a frame, inference step, simulation tick, or renderer pass sequence is a
long chain of tiny GPU operations, optimizing a single kernel body may not
move the needle. The CPU is spending too much time describing work the GPU
finishes quickly.

The smell is visible in a timeline: the GPU runs a short dispatch, then waits
while the CPU/runtime submits the next one, then runs another short dispatch.
The fix is not a faster multiply in the kernel; it is fewer submissions or a
captured submission graph.

## Guidance

- Use CUDA Graphs for repeated sequences of kernels, copies, and events with
  stable structure.
- Use graphics command buffers, bundles, secondary command buffers, or render
  graph compilation to amortize repeated submission work.
- Fuse kernels/passes when adjacent stages share data and fusion does not
  create excessive register pressure, shared-memory pressure, or divergence.
- Keep pipeline state and descriptors/bindings stable across repeated work
  where the API allows it.
- For very small compute kernels, compare three options: one fused kernel, a
  captured graph, and the original sequence. Pick by end-to-end time, not
  aesthetic separation.
- Record whether a workload is launch-bound. Future readers need to know why
  a larger kernel or graph exists.
- Keep graph/update boundaries explicit. A graph that is constantly rebuilt
  has turned launch overhead into graph-management overhead.

## Example

```cpp
// Bad: a fixed sequence of tiny kernels launched independently every step.
for (int step = 0; step != steps; ++step) {
    normalize<<<grid, block>>>(x);
    score<<<grid, block>>>(x, scores);
    threshold<<<grid, block>>>(scores, flags);
    compact<<<grid, block>>>(flags, work);
}

// Better shape: capture once, replay many times. Real code handles graph
// creation, parameter updates, and stream capture errors explicitly.
cudaGraph_t graph{};
cudaGraphExec_t exec{};
cudaStreamBeginCapture(stream, cudaStreamCaptureModeGlobal);
normalize<<<grid, block, 0, stream>>>(x);
score<<<grid, block, 0, stream>>>(x, scores);
threshold<<<grid, block, 0, stream>>>(scores, flags);
compact<<<grid, block, 0, stream>>>(flags, work);
cudaStreamEndCapture(stream, &graph);
cudaGraphInstantiate(&exec, graph, nullptr, nullptr, 0);

for (int step = 0; step != steps; ++step) {
    cudaGraphLaunch(exec, stream);
}
```

```text
Timeline review:

Before:
    CPU launch normalize -> GPU 8 us
    CPU launch score     -> GPU 6 us
    CPU launch threshold -> GPU 4 us
    CPU launch compact   -> GPU 7 us

After:
    CPU graph launch     -> GPU runs the captured chain

If the before trace has visible CPU gaps between dispatches, batching can be
the optimization. If the GPU is continuously busy inside one long kernel,
CUDA Graphs will not fix the bottleneck.
```

## Caveats

- Fusion can reduce launch overhead while making the kernel slower through
  register pressure, lower occupancy, or lost reuse. Measure both.
- CUDA Graphs pay capture/instantiation cost. They fit repeated structure,
  not one-off dynamic work.
- Render graphs and command buffers do not remove GPU work; they reduce
  CPU-side orchestration and expose optimization opportunities.
- Fusion is a semantic change to scheduling and lifetime. It can make
  profiling harder; keep debug markers or internal phases when possible.

## References

- NVIDIA, Getting Started with CUDA Graphs -
  <https://developer.nvidia.com/blog/cuda-graphs/>
- NVIDIA, CUDA C++ Programming Guide - CUDA Graphs -
  <https://docs.nvidia.com/cuda/cuda-c-programming-guide/>
- Unreal Engine, Render Dependency Graph -
  <https://dev.epicgames.com/documentation/en-us/unreal-engine/render-dependency-graph-in-unreal-engine>
- Filament framegraph notes -
  <https://google.github.io/filament/notes/framegraph.html>
- Cross-reference: `GPU.10` (timeline profiling), `GEN.4` (whole-program
  optimization analogy).
