# 2026-05-20-lifetime-category-buildout: Build out the `lifetime` category

**Status:** completed
**Change class:** local — adds guideline content under `guidelines/lifetime/`

## Intent

- **What is changing:** Research and author guidelines for the `lifetime`
  category — placement new and explicit construction/destruction;
  `std::launder` and pointer provenance; the four-way distinction between
  *trivial* / *trivially-copyable* / *trivially-destructible* /
  *implicit-lifetime* types; P0593 implicit object creation; P2590
  `std::start_lifetime_as`; storage reuse for objects of different types in
  the same buffer; destruction order (members, bases, namespace scope,
  static initialization order); object lifetime in pooled storage. Begins
  with a technique-extraction research pass in `docs/research/`, then
  guideline entries under `guidelines/lifetime/`.
- **Why the change is necessary:** With `memory`, `copy-move`, and
  `cache-layout` populated, `lifetime` is the natural next category — it
  pairs tightly with `memory` (allocators give storage; lifetime governs
  object identity inside it) and is currently empty.
- **Expected behavior changes:** New research notes and guideline files;
  the corpus grows. No change to the corpus format, the ID scheme, or the
  `cpp-perf-guidelines` MCP server.
- **Guaranteed invariants/contracts:** The corpus format (see `README.md`)
  and the MCP server's parser contract are unchanged. All content is
  original prose per the `CONTRIBUTING.md` sourcing rule.

## Acceptance Criteria

- [x] A `lifetime` technique-extraction research note exists in
      `docs/research/`, classifying sources by the `CONTRIBUTING.md` sourcing
      rule.
- [x] New `lifetime` guidelines follow the `README.md` format and parse
      cleanly.
- [x] Every guideline is original prose with a `## References` section; no
      copied text or code.

## Verification Plan

- Run the corpus parser integration test (`parses_real_corpus_when_present`
  in the `cpp-perf-guidelines` crate) with `CPP_PERF_GUIDELINES_REPO_PATH`
  pointed at this repository.

## Records

- 2026-05-20 — Packet opened. Lifetime category research started.
- 2026-05-20 — Technique-extraction research completed:
  `docs/research/2026-05-20-lifetime-techniques.md`.
- 2026-05-20 — First authoring pass: LIFE.1–LIFE.4 written.
- 2026-05-20 — Second authoring pass: LIFE.5–LIFE.8 written. Corpus
  parser test parses all 34 guidelines across 8 categories. Packet
  completed; review and acceptance are the maintainer's call.
