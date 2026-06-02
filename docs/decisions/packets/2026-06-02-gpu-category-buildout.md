# 2026-06-02-gpu-category-buildout: Build out the `gpu` category

**Status:** completed
**Change class:** local - adds guideline content under `guidelines/gpu/`

## Intent

- **What is changing:** Add a tenth category, `gpu`, covering
  API-neutral GPU and accelerator optimization for C++ systems. Scope:
  CUDA, Metal, Vulkan/D3D12 compute, game-engine render graphs, GPU
  memory movement, coalesced access, SIMT divergence, occupancy,
  shared/threadgroup memory, launch and command-submission overhead,
  CPU/GPU synchronization, barriers, transient GPU memory, async compute,
  and GPU-counter-driven profiling.
- **Why the change is necessary:** The current corpus mentions GPU work
  only indirectly through telemetry, scratch allocation, and CPU SIMD
  analogies. Public feedback asked whether the corpus helps with CUDA
  projects. The honest answer was "not directly yet." This packet makes
  GPU performance a first-class corpus topic while preserving the
  technique-level style of the existing categories.
- **Expected behavior changes:** New research notes and guideline files;
  the corpus grows from nine categories to ten. The corpus format and
  parser contract are unchanged.
- **Guaranteed invariants/contracts:** The corpus format in `README.md`
  remains unchanged. All prose is original per `CONTRIBUTING.md`. Source
  material is used for technique extraction and citation only; no copied
  engine code or source text is introduced.

## Source material

The research pass draws from:

- NVIDIA CUDA C++ Programming Guide, CUDA C++ Best Practices Guide,
  Nsight Compute/Nsight Systems documentation, and NVIDIA CUDA Graphs /
  shader-performance articles.
- Apple Metal documentation and performance talks for threadgroups,
  SIMD groups, resource synchronization, and Apple Silicon considerations.
- Khronos Vulkan synchronization guidance and performance samples.
- Microsoft D3D12 synchronization and queue documentation.
- AMD GPUOpen RDNA Performance Guide and occupancy explanation.
- Unreal Engine Render Dependency Graph and GPU profiling documentation.
- Godot GPU optimization and rendering architecture documentation.
- Filament framegraph notes and Android GPU counter case study.
- Public Capcom RE Engine meshlet rendering material.
- Public Naughty Dog rendering / engine talks where they expose GPU or
  frame-pipeline lessons.
- Open-source engine/framework practice from Godot, Filament, Wicked
  Engine, The Forge-style render-graph/resource-management patterns, and
  vendor-supported GPU memory allocators.

## Acceptance Criteria

- [x] A GPU technique-extraction research note exists in `docs/research/`
      and classifies sources by the `CONTRIBUTING.md` sourcing rule.
- [x] The `gpu` category is declared in `categories.toml` with token
      `GPU`.
- [x] New GPU guidelines follow the `README.md` format and parse cleanly
      under `tools/validate_corpus.py`.
- [x] Every guideline is original prose and includes references.
- [x] `README.md`, `MEMORY.md`, and `QUEUE.md` reflect the new category
      and work state.

## Verification Plan

- Run `python3 tools/validate_corpus.py`.
- Review the generated guideline IDs, filenames, category keys, summaries,
  and local links for parser-contract consistency.

## Records

- 2026-06-02 - Packet opened. Category identity confirmed: `gpu` / `GPU`,
  slot 10, display name "GPU & Accelerator Optimization".
- 2026-06-02 - Research landed at
  `docs/research/2026-06-02-gpu-optimization-techniques.md`.
- 2026-06-02 - First guideline slate selected: GPU.1-GPU.10.
- 2026-06-02 - Category and guideline files added; validator passes with
  87 guidelines across 10 categories.
- 2026-06-02 - C++ Core Guidelines MCP and cpp-performance MCP checked
  against the examples. `GPU.9` corrected so its `static_assert` example is
  valid constant evaluation; raw CUDA/device pointers are intentionally
  non-owning kernel views per Core Guidelines `R.3`.
