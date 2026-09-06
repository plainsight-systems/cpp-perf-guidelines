# 2026-09-05-wasm-review-remediation: Work the independent review of the `wasm` category

**Status:** completed
**Change class:** local - corrects guideline content under `guidelines/wasm/`

## Intent

- **What is changing:** Correct the findings raised by the independent review at
  [`2026-09-05-wasm-category-buildout-codex-review.md`](../../research/2026-09-05-wasm-category-buildout-codex-review.md)
  — one P0, eight P1, three P2, and a set of C++ Core Guidelines violations in
  the examples.
- **Why the change is necessary:** The corpus is guidance others will cite. A
  guideline that is well-formatted and factually wrong is worse than no
  guideline. Three findings were self-contradictions inside a single file.
- **Expected behavior changes:** Guideline content changes. No new guidelines,
  no removals, no ID changes. The corpus stays at 101 guidelines.
- **Guaranteed invariants/contracts:** IDs are stable and not reused. The
  `README.md` format is unchanged. All prose remains original.

## Findings worked

| # | Sev | File | Correction |
|---|---|---|---|
| 1 | P0 | WASM.10 | Planner dereferenced `plan.buffers.back()` on an empty vector; also unchecked size arithmetic and no alignment precondition |
| 2 | P1 | WASM.3 | Return behavior is governed by `simulate_infinite_loop`, not `EXIT_RUNTIME` — the file's own example contradicted its guidance |
| 3 | P1 | WASM.7 | A wrong MIME type makes native `instantiateStreaming` reject; it does not silently fall back |
| 4 | P1 | WASM.7/13/14 | V8 compiles lazily on first call, not eagerly; the 128 kB threshold is a dated implementation note; URL stability, not path-vs-query, preserves a cache entry |
| 5 | P1 | WASM.1 | Detach applies to non-shared memory; shared memory does not detach. `GROWABLE_ARRAYBUFFERS` now exists |
| 6 | P1 | WASM.10/14 | 128 MiB is the WebGPU spec default, not a mobile classification; the spec does not classify limits by device class |
| 7 | P1 | WASM.12 | The `#error` guard rejected every Emscripten build of the core, contradicting the guideline's own thesis |
| 8 | P1 | WASM.9 | Unity attribution reversed: AssetBundles download *directly into* the Unity heap |
| 9 | P1 | WASM.4 | Stack-entry and indirect-call checks scoped to the engines measured; `std::variant` lowering is not a guarantee |
| 10 | P2 | WASM.11 | Timer resolution figures labelled as Chrome's |
| 11 | P2 | WASM.6 | `-fno-vectorize` demoted to a narrow measured workaround |
| 12 | — | WASM.3 | Quoted phrase paraphrased under the no-copy rule |
| 13 | P1/P2 | WASM.1/3/7/8/10/11 | Core Guidelines: `R.10`, `R.11`, `I.11`, `R.3`, `I.2`, `I.4`, `SL.con.3`, `SL.str.2`, `I.5`, `ES.103`, `E.26` |

Two corrections to the review itself: its finding 9 cites a V8 URL that 404s
(the correct page is `wasm-speculative-optimizations`), and it reported the
Emscripten toolchain as unavailable when it was present, so its C++ findings
were manual reading only.

## Acceptance Criteria

- [x] Every P0 and P1 finding corrected or explicitly rejected with a reason.
- [x] Every replacement claim verified against a primary source.
- [x] Flagged examples corrected.
- [x] Version-sensitive claims carry the date they were checked.
- [x] `python3 tools/validate_corpus.py` passes with 101 guidelines.

## Verification

- `python3 tools/validate_corpus.py` — 101 guidelines.
- Examples compiled and run rather than reviewed by eye: the WASM.10 planner
  over 7 cases including the exact input that was undefined behavior; WASM.1's
  pool over 9 cases; WASM.7 and WASM.11 benchmark guards under
  `-fsanitize=undefined`; the WASM.6 kernel built for both `-msimd128` and
  baseline and run against a scalar reference, which found a destroyed alpha
  channel; WASM.8's span-based registry for a scalar and a POD.
- Replacement claims checked against primary sources before editing:
  `simulate_infinite_loop` semantics (Emscripten API reference), V8 lazy
  compilation (V8 pipeline docs), `INITIAL_HEAP` and `GROWABLE_ARRAYBUFFERS`
  (Emscripten settings), AssetBundle heap behaviour (Unity manual), WebGPU
  defaults (WebGPU specification).
- Core Guidelines checked via the `cpp-guidelines` MCP server, closing the gap
  left by the buildout packet. Beyond the review's findings this produced 12
  `SL.str.2` corrections and one `I.4` correction, with three findings accepted
  and annotated: the Emscripten callback ABI's `void*`, the main-loop
  singleton, and the constructor-throws tension against `-fno-exceptions`.

## Records

- 2026-09-05 - Full finding list accepted for work.
- 2026-09-06 - Corrections applied and verified.
