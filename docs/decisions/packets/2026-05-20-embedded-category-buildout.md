# 2026-05-20-embedded-category-buildout: Build out the `embedded` category

**Status:** implementing
**Change class:** local — adds guideline content under `guidelines/embedded/`

## Intent

- **What is changing:** Research and author guidelines for the `embedded`
  category — heapless / static allocation, fixed-capacity containers,
  worst-case execution time (WCET), stack budgeting, disabling exceptions
  and RTTI, deterministic-allocation reference designs (TLSF, o1heap),
  freestanding-C++ constraints, memory-mapped I/O / `volatile`, and the
  functional-safety standards (MISRA C++, AUTOSAR C++14, ISO 26262)
  framing. Begins with a technique-extraction research pass in
  `docs/research/`, then guideline entries under `guidelines/embedded/`.
- **Why the change is necessary:** With `memory`, `copy-move`,
  `cache-layout`, and `lifetime` populated, `embedded` is the next category
  in order. It pairs tightly with `memory` (especially `MEM.9` "allocate at
  init") and is currently empty.
- **Expected behavior changes:** New research notes and guideline files;
  the corpus grows. No change to the corpus format, the ID scheme, or the
  `cpp-perf-guidelines` MCP server.
- **Guaranteed invariants/contracts:** The corpus format (see `README.md`)
  and the MCP server's parser contract are unchanged. All content is
  original prose per the `CONTRIBUTING.md` sourcing rule.

## Acceptance Criteria

- [ ] An `embedded` technique-extraction research note exists in
      `docs/research/`, classifying sources by the `CONTRIBUTING.md`
      sourcing rule.
- [ ] New `embedded` guidelines follow the `README.md` format and parse
      cleanly.
- [ ] Every guideline is original prose with a `## References` section; no
      copied text or code.

## Verification Plan

- Run the corpus parser integration test (`parses_real_corpus_when_present`
  in the `cpp-perf-guidelines` crate) with `CPP_PERF_GUIDELINES_REPO_PATH`
  pointed at this repository.

## Records

- 2026-05-20 — Packet opened. Embedded category research started.
- 2026-05-20 — Technique-extraction research completed:
  `docs/research/2026-05-20-embedded-techniques.md`.
- 2026-05-20 — First authoring pass: EMB.1–EMB.4 written. EMB.5–EMB.8
  remain for a second pass.
