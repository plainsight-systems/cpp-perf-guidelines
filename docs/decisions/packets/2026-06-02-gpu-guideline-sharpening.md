# 2026-06-02-gpu-guideline-sharpening: Sharpen the `gpu` category

**Status:** completed
**Change class:** local - revises guideline content under `guidelines/gpu/`

## Intent

- **What is changing:** Revise the initial GPU category so the guidance is
  more technique-level and closer to the rest of the corpus. Keep the
  `GPU.1`-`GPU.10` IDs stable; improve rationales, guidance, examples,
  caveats, and cross-references.
- **Why the change is necessary:** The first pass was structurally correct
  but too generic. It named the right GPU topics, but several examples did
  not expose the concrete failure mode or measurable lever. The corpus is
  strongest when it tells a reader what to count, what to change, and what
  trap to avoid.
- **Expected behavior changes:** Same category and same guideline count.
  Better CUDA/Metal/Vulkan/D3D12 specificity; stronger examples around
  memory transactions, register/shared-memory occupancy cliffs, bank
  conflicts, non-default streams, precise barriers, and counter-driven
  profiling.
- **Guaranteed invariants/contracts:** The corpus format and parser
  contract remain unchanged. Existing `GPU.*` IDs are not reused or
  renumbered. Prose remains original and cited sources are used for
  technique extraction only.

## Acceptance Criteria

- [x] No new parser contract changes.
- [x] `GPU.1`-`GPU.10` remain draft guidelines with stable IDs.
- [x] Weak illustrative examples are replaced or reinforced with concrete
      cost-model examples.
- [x] Research note records the sharpening pass and additional concrete
      source extraction.
- [x] `tools/validate_corpus.py` passes.

## Verification Plan

- Run `python3 tools/validate_corpus.py`.
- Check examples against the C++ Core Guidelines MCP where code shape is
  non-trivial.
- Check cross-references against the cpp-performance MCP where adjacent
  guidance already exists.

## Records

- 2026-06-02 - Packet opened after maintainer review found the initial GPU
  pass less valuable than the other performance categories.
- 2026-06-02 - Focus sharpened around concrete levers: 32-byte coalescing
  transactions, occupancy limiters, shared-memory bank padding, non-default
  stream overlap, queue-specific synchronization, and profiling counter
  decision trees.
- 2026-06-02 - C++ Core Guidelines MCP checked. CUDA/global-kernel examples
  intentionally use raw pointers as non-owning device-buffer views despite
  `R.2`/`R.14` preferring spans for ordinary C++ array interfaces; this is
  the established kernel ABI shape, not an ownership transfer. `constexpr`
  and `static_assert` examples align with `Con.5` / `T.123`.
- 2026-06-02 - Validator passes with 87 guidelines across 10 categories.
