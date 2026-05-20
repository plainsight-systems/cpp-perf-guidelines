# 2026-05-20-codegen-category-buildout: Build out the `codegen` category

**Status:** completed
**Change class:** local — adds guideline content under `guidelines/codegen/`

## Intent

- **What is changing:** Research and author guidelines for the `codegen`
  category — *codegen nudges*, distinct from `simd`'s operationalised
  programming model. Scope: branchless code (`cmov`, predicated
  arithmetic); branch hints (`[[likely]]`, `[[unlikely]]`,
  `__builtin_expect`); `restrict` and pointer aliasing; link-time
  optimisation (LTO) and link-time devirtualisation; profile-guided
  optimisation (PGO); function-attribute-driven inlining
  (`[[gnu::always_inline]]`, `[[gnu::flatten]]`, `[[gnu::hot]]`,
  `[[gnu::cold]]`); hot/cold function placement; what the optimiser
  promises and what it does not.
- **Why the change is necessary:** With six categories populated,
  `codegen` is the next category in order. SIMD has been split out into
  its own category (the previous taxonomy change); `codegen` is now
  focused on the *nudges* that shape what the compiler emits.
- **Expected behavior changes:** New research notes and guideline files;
  the corpus grows. No change to the corpus format, the ID scheme, or
  the `cpp-perf-guidelines` MCP server.
- **Guaranteed invariants/contracts:** The corpus format and the MCP
  server's parser contract are unchanged. All content is original prose
  per the `CONTRIBUTING.md` sourcing rule.

## Acceptance Criteria

- [x] A `codegen` technique-extraction research note exists in
      `docs/research/`, classifying sources by the `CONTRIBUTING.md`
      sourcing rule.
- [x] New `codegen` guidelines follow the `README.md` format and parse
      cleanly.
- [x] Every guideline is original prose with a `## References` section;
      no copied text or code.

## Verification Plan

- Run the corpus parser integration test (`parses_real_corpus_when_present`
  in the `cpp-perf-guidelines` crate) with `CPP_PERF_GUIDELINES_REPO_PATH`
  pointed at this repository.

## Records

- 2026-05-20 — Packet opened. Codegen category research started.
- 2026-05-20 — Technique-extraction research completed:
  `docs/research/2026-05-20-codegen-techniques.md`.
- 2026-05-20 — First authoring pass: GEN.1–GEN.4 written.
- 2026-05-20 — Second authoring pass: GEN.5–GEN.8 written. Corpus
  parser test parses all 58 guidelines across 8 categories. Packet
  completed; review and acceptance are the maintainer's call.
