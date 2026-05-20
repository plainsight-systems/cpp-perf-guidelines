# 2026-05-19-copy-move-category-buildout: Build out the `copy-move` category

**Status:** implementing
**Change class:** local — adds guideline content under `guidelines/copy-move/`

## Intent

- **What is changing:** Research and author guidelines for the `copy-move`
  category — value semantics, RVO / NRVO and guaranteed copy elision, move-only
  and sink types, eliminating hidden copies, and the `noexcept`-move /
  `vector` relationship. Begins with a source survey and technique-extraction
  pass in `docs/research/`, then guideline entries under
  `guidelines/copy-move/`.
- **Why the change is necessary:** `copy-move` is one of the corpus's three
  original pillars and currently has a single seed entry (`COPY.1`). With the
  `memory` category populated, `copy-move` is the next category to build out.
- **Expected behavior changes:** New research notes and guideline files; the
  corpus grows. No change to the corpus format, the ID scheme, or the
  `cpp-perf-guidelines` MCP server.
- **Guaranteed invariants/contracts:** The corpus format (see `README.md`) and
  the MCP server's parser contract are unchanged. `COPY.1` is not renumbered.
  All content is original prose per the `CONTRIBUTING.md` sourcing rule.

## Acceptance Criteria

- [ ] A `copy-move` source survey and technique-extraction note exist in
      `docs/research/`, classifying each source by the `CONTRIBUTING.md`
      sourcing rule.
- [ ] New `copy-move` guidelines follow the `README.md` format and parse
      cleanly.
- [ ] Every guideline is original prose with a `## References` section; no
      copied text or code.

## Verification Plan

- Run the corpus parser integration test (`parses_real_corpus_when_present` in
  the `cpp-perf-guidelines` crate) with `CPP_PERF_GUIDELINES_REPO_PATH` pointed
  at this repository.

## Records

- 2026-05-19 — Packet opened. Copy-move category research started.
- 2026-05-19 — Technique-extraction research completed:
  `docs/research/2026-05-19-copy-move-semantics.md`.
- 2026-05-20 — First authoring pass: COPY.2–COPY.5 written. COPY.6–COPY.8
  remain for a second pass.
