# 2026-09-05-wasm-category-buildout: Build out the `wasm` category

**Status:** completed
**Change class:** local - adds guideline content under `guidelines/wasm/`

## Intent

- **What is changing:** Add an eleventh category, `wasm`, covering C++
  compiled to WebAssembly and the interop seams around it: linear memory
  sizing, the JS/FFI boundary, the cooperative event loop, indirect-dispatch
  cost, cross-origin isolation and threads, wasm SIMD, startup and code
  caching, module size, asset streaming, runtime capability negotiation, and
  browser measurement conditions.
- **Why the change is necessary:** WebAssembly is a shipping target for C++
  engines and applications, and the corpus said nothing about it. Several
  existing rules also mislead there: `MEM.7`'s reserve-and-commit is
  unavailable on wasm32, and `GEN`'s dispatch guidance understates
  indirect-call cost in a browser.
- **Expected behavior changes:** The corpus grows from ten categories to
  eleven, and from 87 to 101 guidelines. The format and parser contract are
  unchanged.
- **Guaranteed invariants/contracts:** All prose is original per
  `CONTRIBUTING.md`. Source material is used for technique extraction and
  citation only.

## Source material

Recorded in
[`docs/research/2026-09-05-wasm-techniques.md`](../../research/2026-09-05-wasm-techniques.md):
peer-reviewed measurement (Jangda et al. USENIX ATC 2019; Szewczyk et al.
IISWC 2022), shipped engine web targets (Unity, Godot, Unreal), production C++
ports (Photoshop, Figma), Emscripten and V8 documentation, and W3C/MDN
specifications.

In-house exploratory work is not a source. An earlier draft cited an internal
browser harness for WebGPU limit behaviour; that material was removed and
re-grounded externally. Where the internal conclusion and the external sources
disagreed — on whether requesting an adapter's advertised maxima is a sound
design rule — the external source governs.

## Acceptance Criteria

- [x] Research note exists and classifies sources per the `CONTRIBUTING.md`
      sourcing rule.
- [x] `wasm` declared in `categories.toml` with token `WASM`.
- [x] Guidelines follow the `README.md` format and the established corpus
      shape.
- [x] Every guideline is original prose and includes references.
- [x] No guideline cites in-house exploratory work as evidence.
- [x] `python3 tools/validate_corpus.py` passes with 101 guidelines.
- [x] `README.md`, `MEMORY.md` and `QUEUE.md` reflect the new category.

## Verification

- `python3 tools/validate_corpus.py` — 101 guidelines across 11 categories.
- All 19 cross-referenced guideline IDs resolved against the files on disk and
  their descriptions compared to the referenced titles. Six were wrong and were
  corrected: `CACHE.5`→`CACHE.6`, `CONC.1`→`CACHE.1`, `SIMD.2`→`SIMD.6`,
  `SIMD.5`→`SIMD.3`, `TLM.4`→`TLM.6`, `EMB.1`→`MEM.9`.
- The C++ examples were **not** checked against the Core Guidelines during this
  packet. That gap was closed under
  [`2026-09-05-wasm-review-remediation`](2026-09-05-wasm-review-remediation.md).

## Records

- 2026-09-05 - Category identity: `wasm` / `WASM`, slot 11, display name
  "WebAssembly & Browser Targets".
- 2026-09-05 - First research pass rejected as too narrow; re-run as a full
  external survey.
- 2026-09-05 - WASM.1–WASM.14 added.
