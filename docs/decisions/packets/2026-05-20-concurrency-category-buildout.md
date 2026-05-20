# 2026-05-20-concurrency-category-buildout: Build out the `concurrency` category

**Status:** completed
**Change class:** local — adds guideline content under `guidelines/concurrency/`

## Intent

- **What is changing:** Research and author guidelines for the
  `concurrency` category — MESI / cache-coherency cost, atomics cost across
  memory orders (`relaxed` / `acquire` / `release` / `seq_cst`), the
  `[intro.races]` C++ memory model and how it composes with the hardware
  model, fences and barriers, NUMA locality, work-stealing scheduling
  shape, lock-free / wait-free data structures (SPSC / MPSC / MPMC
  ringbuffers, hazard pointers, RCU), spinlocks vs mutexes vs lock-free,
  and the `CACHE.1` false-sharing material's cross-references. Begins with
  a technique-extraction research pass in `docs/research/`, then guideline
  entries under `guidelines/concurrency/`.
- **Why the change is necessary:** With `memory`, `copy-move`,
  `cache-layout`, `lifetime`, and `embedded` populated, `concurrency` is
  the next category in order. `CACHE.1` already addresses false sharing as
  a *layout* concern; this category covers the broader concurrency-memory
  story.
- **Expected behavior changes:** New research notes and guideline files;
  the corpus grows. No change to the corpus format, the ID scheme, or the
  `cpp-perf-guidelines` MCP server.
- **Guaranteed invariants/contracts:** The corpus format (see `README.md`)
  and the MCP server's parser contract are unchanged. All content is
  original prose per the `CONTRIBUTING.md` sourcing rule.

## Acceptance Criteria

- [x] A `concurrency` technique-extraction research note exists in
      `docs/research/`, classifying sources by the `CONTRIBUTING.md`
      sourcing rule.
- [x] New `concurrency` guidelines follow the `README.md` format and parse
      cleanly.
- [x] Every guideline is original prose with a `## References` section; no
      copied text or code.

## Verification Plan

- Run the corpus parser integration test (`parses_real_corpus_when_present`
  in the `cpp-perf-guidelines` crate) with `CPP_PERF_GUIDELINES_REPO_PATH`
  pointed at this repository.

## Records

- 2026-05-20 — Packet opened. Concurrency category research started.
- 2026-05-20 — Technique-extraction research completed:
  `docs/research/2026-05-20-concurrency-techniques.md`.
- 2026-05-20 — First authoring pass: CONC.1–CONC.4 written.
- 2026-05-20 — Second authoring pass: CONC.5–CONC.8 written. Corpus
  parser test parses all 50 guidelines across 8 categories. Packet
  completed; review and acceptance are the maintainer's call.
