# 2026-05-19-memory-category-buildout: Build out the `memory` category

**Status:** completed
**Change class:** local — adds guideline content under `guidelines/memory/`

## Intent

- **What is changing:** Research and author guidelines for the `memory`
  category — custom allocators and memory management. Begins with a source
  survey in `docs/research/`, then guideline entries under `guidelines/memory/`.
- **Why the change is necessary:** The corpus has one seed entry (`MEM.1`).
  `memory` is the core category, the user's stated primary interest, and the
  richest literature — it anchors the corpus.
- **Expected behavior changes:** New research notes and guideline files; the
  corpus grows. No change to the corpus format, the ID scheme, or the
  `cpp-perf-guidelines` MCP server.
- **Guaranteed invariants/contracts:** The corpus format (see `README.md`) and
  the MCP server's parser contract are unchanged. Guideline IDs remain stable
  and unique; `MEM.1` is not renumbered. All content is original prose per the
  `CONTRIBUTING.md` sourcing rule.

## Acceptance Criteria

- [x] A `memory`-category source survey exists in `docs/research/`, classifying
      each source by the `CONTRIBUTING.md` sourcing rule.
- [x] New `memory` guidelines follow the `README.md` format and parse cleanly.
- [x] Every guideline is original prose with a `## References` section; no
      copied text or code.

## Verification Plan

- Run the corpus parser integration test (`parses_real_corpus_when_present` in
  the `cpp-perf-guidelines` crate) with `CPP_PERF_GUIDELINES_REPO_PATH` pointed
  at this repository.

## Records

- 2026-05-19 — Packet opened. Memory-category source research started.
- 2026-05-19 — Source survey completed:
  `docs/research/2026-05-19-memory-allocators-sources.md`.
- 2026-05-19 — Engine technique-extraction completed:
  `docs/research/2026-05-19-memory-engine-allocators.md`.
- 2026-05-19 — First authoring pass: MEM.2–MEM.6 written.
- 2026-05-19 — Second authoring pass: MEM.7–MEM.10 written. Corpus parser
  test parses all 12 guidelines across 7 categories. Packet completed;
  review and acceptance are the maintainer's call.
