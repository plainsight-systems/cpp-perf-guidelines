# 2026-09-05-wasm-review-remediation: Work the codex review of the `wasm` category

**Status:** completed
**Change class:** local - corrects guideline content under `guidelines/wasm/`

## Intent

- **What is changing:** Correct the findings raised by the independent review at
  [`2026-09-05-wasm-category-buildout-codex-review.md`](../../research/2026-09-05-wasm-category-buildout-codex-review.md):
  one P0 (undefined behavior in a WASM.10 example), eight P1 (incorrect API and
  toolchain claims, historical engine behavior presented as current,
  unsupported device thresholds, one reversed source attribution), three P2,
  and a set of C++ Core Guidelines violations in the examples.
- **Why the change is necessary:** The corpus is guidance others will cite. A
  guideline that is well-formatted and factually wrong is worse than no
  guideline, because its confidence is what makes it dangerous. Three of the
  findings are self-contradictions inside a single file, which no reader should
  have to detect.
- **Expected behavior changes:** Guideline content changes. No new guidelines,
  no removals, no ID changes. The corpus stays at 101 guidelines across 11
  categories and the parser contract is untouched.
- **Guaranteed invariants/contracts:** IDs are stable and not reused. The
  `README.md` format is unchanged. All prose remains original per
  `CONTRIBUTING.md` — including the one attributed quotation the review flagged,
  which is paraphrased here.

## Findings worked

| # | Sev | File | Correction |
|---|---|---|---|
| 1 | P0 | WASM.10 | Planner dereferenced `plan.buffers.back()` on an empty vector; also unchecked size arithmetic, no alignment precondition, and no re-check after starting a new buffer |
| 2 | P1 | WASM.3 | Return behavior is governed by `simulate_infinite_loop`, not `EXIT_RUNTIME` — and the file's own example contradicted its guidance |
| 3 | P1 | WASM.7 | A wrong MIME type makes native `instantiateStreaming` reject; it does not silently fall back |
| 4 | P1 | WASM.7/13/14 | V8 compiles lazily on first call, not eagerly over the whole module; the 128 kB threshold is a dated implementation note; URL stability, not path-vs-query, is what preserves a cache entry; module-inflation advice removed |
| 5 | P1 | WASM.1 | Detach applies to non-shared memory; shared memory does not detach. Logical contiguity is not a claim about host allocation strategy. `GROWABLE_ARRAYBUFFERS` now exists |
| 6 | P1 | WASM.10/14 | 128 MiB is the WebGPU spec default, not a mobile classification; the spec does not classify limits by device class, and the 4 GB desktop endpoint was unsupported |
| 7 | P1 | WASM.12 | The `#error` guard rejected every Emscripten build of the core, contradicting the guideline's own thesis |
| 8 | P1 | WASM.9 | Unity attribution was reversed: AssetBundles download *directly into* the Unity heap, avoiding a second browser allocation. Data Caching is the separate mechanism |
| 9 | P1 | WASM.4 | Stack-entry and indirect-call checks scoped to the engines measured; `std::variant` lowering is something to inspect, not a guarantee |
| 10 | P2 | WASM.11 | Timer resolution figures labelled as Chrome's |
| 11 | P2 | WASM.6 | `-fno-vectorize` demoted from build guidance to a narrow measured workaround |
| 12 | — | WASM.3 | Quoted phrase paraphrased under the repository's no-copy rule |
| 13 | P1/P2 | WASM.1/3/7/11 | Core Guidelines: `R.10`, `R.11`, `I.11`, `R.3`, `SL.con.3`, `I.5`, `ES.103` |

## Reviewer errors recorded

The review is accepted, with two corrections to it:

- Finding 9 cites `https://v8.dev/blog/wasm-speculative-call-indirect`. That URL
  returns 404; the correct page is `wasm-speculative-optimizations`, already
  cited in the corpus. The finding is substantively valid; the citation was not.
- The review states `em++` is unavailable locally and that the examples were
  not compiled. emsdk is present. The WASM.6 kernel was compiled with `emcc` and
  executed under Node against a scalar reference during this session, which is
  how its alpha-preservation defect was found. The review's C++ findings are
  manual-reading only, and were weighed accordingly.

## Acceptance Criteria

- [x] Every P0 and P1 finding is corrected or explicitly rejected with a reason.
- [x] Every replacement claim is verified against a primary source, not swapped
      for another unsourced assertion.
- [x] Examples that the review flagged for undefined behavior or Core Guidelines
      violations are corrected.
- [x] Version-sensitive claims carry the date and engine they were checked
      against, per the review's residual-risk note.
- [x] `python3 tools/validate_corpus.py` passes with 101 guidelines.
- [x] No in-house exploratory work is introduced as evidence.

## Verification Plan

- Run `python3 tools/validate_corpus.py`.
- Compile the changed C++ examples with the local emsdk toolchain where they are
  self-contained, rather than reviewing them by eye.
- Re-check each corrected claim against the primary source that replaces it.

## Records

- 2026-09-05 - Packet opened from the independent review. Full finding list
  accepted for work at the maintainer's direction.
- 2026-09-05 - Replacement facts verified before editing: `simulate_infinite_loop`
  semantics and `fps=0` (Emscripten API reference); V8 lazy compilation with
  dynamic tiering (V8 compilation pipeline docs); `GROWABLE_ARRAYBUFFERS`
  present in the local emsdk `settings.js`; WebGPU spec does not classify limits
  by device class and `maxStorageBuffersPerShaderStage` default is 8.
- 2026-09-05 - All 12 findings worked; none rejected. Every replacement claim
  was checked against a primary source before the edit, not after.
- 2026-09-05 - Examples verified by compilation and execution rather than by
  reading, which is what the review could not do:
  - WASM.10 planner: extracted, compiled, and run over seven cases including the
    exact single-small-tensor input that was undefined behavior. Also covers
    alignment padding, oversized-tensor rejection, binding-count rejection,
    spilling to a second physical buffer, zero alignment, and an empty list.
  - WASM.1 `FixedHeapPool`: nine cases — zero alignment, non-power-of-two
    alignment, oversized request, `SIZE_MAX` request, overflowing alignment,
    high-water tracking, reset, and fill-to-capacity.
  - WASM.7 `measure` and WASM.11 `mean_cost_ms`: zero-iteration and
    single-iteration paths under `-fsanitize=undefined`.
  - WASM.6 kernel: compiled with `emcc` for both `-msimd128` and baseline, and
    run under Node against a scalar reference.
- 2026-09-05 - Note for future runs: AddressSanitizer binaries hang in this
  sandbox. UndefinedBehaviorSanitizer works. Plain builds work.
- 2026-09-05 - Validator passes: 101 guidelines across 11 categories.
- 2026-09-06 - **MCP grounding performed**, closing the verification the
  buildout packet claimed and did not do. Both servers called directly.
  - `cpp-perf-guidelines`: confirmed the published corpus contains no `wasm`
    entries yet, as expected, and surfaced no contradiction with the new
    guidelines.
  - `cpp-guidelines`: searched, then fetched `I.4` and `SL.str.2` in full.
    Findings beyond those the independent review had already raised:
    - **`SL.str.2`** — twelve `const char*` members across WASM.2, 5, 8, 10, 11,
      13 and 14 became `std::string_view`. The one survivor is
      `extern "C" const char* build_variant()` in WASM.13, which crosses the C
      ABI to JavaScript and must stay NUL-terminated; that exception is now
      stated in the example.
    - **`I.4`** — WASM.8's type-erasure boundary took `(const void*, size_t)`.
      `I.4`'s enforcement is literally "report the use of `void*` as a parameter
      or return type", and its bad example is that exact signature. Replaced
      with `std::span<const std::byte>`, which erases the type without
      discarding the size (`R.14`). Compiled and run.
    - **`I.4` again, accepted rather than fixed** — WASM.3's
      `step(void* user_data)` is dictated by the Emscripten C callback ABI and
      cannot be typed away. Now confined to a single adapter that recovers the
      type immediately, with the concession stated.
    - **`I.2` / `R.6`** — WASM.3's `MainLoop` owns frame state in a
      function-local static, which is non-`const` global state. Accepted,
      because the browser provides exactly one main loop and the ABI carries no
      caller-controlled context; annotated in the example and added to Caveats
      so it is not read as a pattern to copy. Thread-safe initialisation per
      `CP.110`.
    - **`E.26`** — WASM.1's pool constructor relies on `make_unique` throwing,
      while WASM.8 recommends `-fno-exceptions` for some builds. The tension is
      now named in the example: under `-fno-exceptions` the throw becomes an
      abort, which is still failing fast at init with a known budget.
- 2026-09-06 - Changed examples re-verified by compilation: the span-based
  registry compiled and run for both a scalar and a POD element type.
