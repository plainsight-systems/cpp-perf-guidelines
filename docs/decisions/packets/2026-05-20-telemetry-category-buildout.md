# 2026-05-20-telemetry-category-buildout: Build out the `telemetry` category

**Status:** implementing
**Change class:** local — adds guideline content under `guidelines/telemetry/`

## Intent

- **What is changing:** Add a ninth category — `telemetry` — covering
  the engineering discipline of instrumenting performance-sensitive
  C++ systems *without lying about their performance*. Scope:
  compile-out-by-default instrumentation; channelized events
  (Unreal-style); static names and per-thread lock-free emitters on
  hot paths; macro/channel front doors that hide the sink from
  runtime call sites; structured events vs stderr text; the
  diagnostic-mode-is-not-benchmark-mode rule and observer-effect
  labeling; sparse bookmarks for state changes; artifact-scan
  validation that clean builds carry no diagnostic symbols.
- **Why the change is necessary:** Telemetry harnesses were a real
  failure mode on the consuming side (Vigil): env-var-gated
  experimental behavior leaked into product paths, stderr "debug
  stats" polluted benchmarks, and diagnostic builds masqueraded as
  clean-throughput evidence. This is the No-Facades rule applied to
  performance measurement; it has converged cross-engine answers
  (Unreal Insights, Unity ProfilerMarker, Tracy, Perfetto) and
  belongs in the corpus next to `codegen` and `embedded`.
- **Expected behavior changes:** New research notes and guideline
  files; the corpus grows to nine categories. No change to the
  corpus format, the ID scheme (token `TLM`), or the
  `cpp-perf-guidelines` MCP server's parser contract.
- **Guaranteed invariants/contracts:** The corpus format (see
  `README.md`) and the MCP server's parser contract are unchanged.
  All content is original prose per the `CONTRIBUTING.md` sourcing
  rule. Two Vigil documents are the seed material and will be cited
  with full attribution; their text and code are not copied.

## Source material

Two prior-art documents from the consuming project (`vigil`) seed the
research and define the failure mode this category addresses:

- `/Users/andyhunter/repositories/vigil/docs/research/packet133_game_engine_profiling_patterns.md`
  — cross-engine survey (Unreal Stats, Unreal Insights Trace, Unreal
  CSV Profiler, Unity ProfilerMarker, Godot Performance, Tracy).
  Distilled cross-engine design rules.
- `/Users/andyhunter/repositories/vigil/docs/decisions/packets/142-unreal-style-observability-boundary.md`
  — Vigil's adoption packet that operationalised the rules: macro
  front door, compile-gate inventory, artifact-scan validation,
  observer-effect labeling.

An independent deep-dive research pass is also being commissioned to
surface additional valid principles beyond what the two Vigil
documents cover (Intel ITT, Optick, Microprofile, PIX, RAD
Telemetry, Perfetto/Chrome trace event format, CTF / LTTng,
eBPF/perf/DTrace user markers, OpenTelemetry C++, GPU/CPU
correlation, sampling vs tracing, lock-free emitters, timestamp
source discipline, frame markers, thread naming).

## Acceptance Criteria

- [ ] A `telemetry` technique-extraction research note exists in
      `docs/research/`, classifying sources by the `CONTRIBUTING.md`
      sourcing rule and integrating both the seed Vigil documents
      and the independent deep-dive research pass.
- [ ] The `telemetry` category is declared in `categories.toml`
      (key, token, display_name, order, description).
- [ ] New `telemetry` guidelines follow the `README.md` format and
      parse cleanly under `tools/validate_corpus.py` and the MCP
      server's parser test.
- [ ] Every guideline is original prose with a `## References`
      section; no copied text or code.
- [ ] The README maturity line is updated to reflect the ninth
      category.

## Verification Plan

- Run `python3 tools/validate_corpus.py` after each authoring pass.
- Run the corpus parser integration test
  (`parses_real_corpus_when_present` in the `cpp-perf-guidelines`
  crate) with `CPP_PERF_GUIDELINES_REPO_PATH` pointed at this
  repository.

## Records

- 2026-05-20 — Packet opened. Category identity confirmed:
  `telemetry` / `TLM`, slot 9, display name "Telemetry &
  Observability Harnesses".
- 2026-05-20 — `categories.toml` updated with the ninth category;
  `guidelines/telemetry/` directory created.
- 2026-05-20 — Independent deep-dive research pass commissioned to
  extend beyond the Vigil seed documents. Pending.
