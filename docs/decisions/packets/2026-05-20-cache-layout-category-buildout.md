# 2026-05-20-cache-layout-category-buildout: Build out the `cache-layout` category

**Status:** implementing
**Change class:** local — adds guideline content under `guidelines/cache-layout/`

## Intent

- **What is changing:** Research and author guidelines for the `cache-layout`
  category — cache hierarchy and access patterns, false sharing, struct
  layout and alignment, AoS vs SoA vs AoSoA, hot/cold field splitting,
  software prefetching, cache-miss reasoning. Begins with a
  technique-extraction research pass in `docs/research/`, then guideline
  entries under `guidelines/cache-layout/`.
- **Why the change is necessary:** `cache-layout` is the third of the
  corpus's original pillars and currently has a single seed entry
  (`CACHE.1`). With `memory` and `copy-move` populated, `cache-layout` is
  the next category to build out.
- **Expected behavior changes:** New research notes and guideline files; the
  corpus grows. No change to the corpus format, the ID scheme, or the
  `cpp-perf-guidelines` MCP server.
- **Guaranteed invariants/contracts:** The corpus format (see `README.md`)
  and the MCP server's parser contract are unchanged. `CACHE.1` is not
  renumbered. All content is original prose per the `CONTRIBUTING.md`
  sourcing rule.

## Acceptance Criteria

- [ ] A `cache-layout` technique-extraction research note exists in
      `docs/research/`, classifying sources by the `CONTRIBUTING.md` sourcing
      rule.
- [ ] New `cache-layout` guidelines follow the `README.md` format and parse
      cleanly.
- [ ] Every guideline is original prose with a `## References` section; no
      copied text or code.

## Verification Plan

- Run the corpus parser integration test (`parses_real_corpus_when_present` in
  the `cpp-perf-guidelines` crate) with `CPP_PERF_GUIDELINES_REPO_PATH` pointed
  at this repository.

## Records

- 2026-05-20 — Packet opened. Cache-layout category research started.
