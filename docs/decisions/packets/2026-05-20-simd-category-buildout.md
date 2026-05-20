# 2026-05-20-simd-category-buildout: Build out the `simd` category

**Status:** implementing
**Change class:** local — adds guideline content under `guidelines/simd/`

## Intent

- **What is changing:** Research and author guidelines for the `simd`
  category — vectorisation-friendly layout (cross-referencing `CACHE.4`
  AoS / SoA / AoSoA); intrinsics vs `std::simd` vs autovectorisation;
  alignment for vector loads / stores (cross-referencing `CACHE.5`);
  gather and scatter; ISA targeting (SSE / AVX / AVX-512, NEON / SVE /
  SME); mask operations; the last-resort drop to hand-written assembly
  (Apple AMX-style undocumented extensions; constant-time crypto). Per
  the earlier taxonomy split, SIMD is its own category, distinct from
  `codegen`'s nudges.
- **Why the change is necessary:** This is the eighth and final
  category. With seven categories populated, SIMD completes the corpus.
- **Expected behavior changes:** New research notes and guideline files;
  the corpus grows. No change to the corpus format, the ID scheme, or
  the `cpp-perf-guidelines` MCP server.
- **Guaranteed invariants/contracts:** The corpus format (see `README.md`)
  and the MCP server's parser contract are unchanged. All content is
  original prose per the `CONTRIBUTING.md` sourcing rule.

## Acceptance Criteria

- [ ] A `simd` technique-extraction research note exists in
      `docs/research/`, classifying sources by the `CONTRIBUTING.md`
      sourcing rule.
- [ ] New `simd` guidelines follow the `README.md` format and parse
      cleanly.
- [ ] Every guideline is original prose with a `## References` section;
      no copied text or code.

## Verification Plan

- Run the corpus parser integration test (`parses_real_corpus_when_present`
  in the `cpp-perf-guidelines` crate) with `CPP_PERF_GUIDELINES_REPO_PATH`
  pointed at this repository.

## Records

- 2026-05-20 — Packet opened. SIMD category research started.
- 2026-05-20 — Technique-extraction research completed:
  `docs/research/2026-05-20-simd-techniques.md`.
