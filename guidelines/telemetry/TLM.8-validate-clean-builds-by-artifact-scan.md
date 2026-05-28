+++
id = "TLM.8"
title = "Validate clean builds by artifact scan — `strings` and `nm` prove diagnostic symbols, env names, and trace sinks are absent"
category = "telemetry"
status = "draft"
summary = "Compile-out claims are aspirations until the linked archive confirms them. Scan with `strings` and `nm -C` for diagnostic symbols, label strings, and trace sinks; fail closed on unapproved residuals."
tags = ["validation", "build-gate", "strings", "nm", "ci"]
+++

## Rationale

The "compile telemetry out by default" rule (`TLM.1`) is only
real if you can prove it. A macro defined to `((void)0)` and a
build flag named `--no-trace` are *intentions* until the
linked archive confirms they did their job. The verification
step is not optional.

The verification primitives are well-known and platform-
standard:

- `strings <archive>` — every printable string literal in the
  binary. Diagnostic environment variable names
  (`APP_SCHEDULER_DEBUG_STATS`), trace label strings
  (`app.render.generate_impl`), and diagnostic banner text
  all surface here.
- `nm -C <archive>` — every symbol (function, global) in the
  binary, demangled. Trace sink functions
  (`trace::ScopedPhase`, `trace::duration`), diagnostic
  helpers (`read_app_debug_stats_from_env`), and
  self-test bodies surface here.
- `objdump -d <archive>` — disassembled object code; the
  last resort when names and strings are inconclusive and
  the question is "does this region contain instructions at
  all?"

The pattern, generalised from an inference-engine adoption
(see References):

1. **Define the contract.** "A `--performance` build must
   contain no symbol matching `trace::*`, no string
   matching `APP_TRACE_*`, no string matching
   `APP_*_DEBUG_*`, no self-test helper names."
2. **List the approved residuals.** Some symbols/strings
   will be present and are explicitly approved (for example,
   product-configuration adapter symbols that belong to a
   prior, unrelated decision). The list is short, named, and
   reviewed.
3. **Run the scan in CI on every release-class build.**
   Not just at release time; not just when someone
   remembers.
4. **Fail closed on unknown residuals.** A new symbol that
   matches a forbidden pattern but is not on the approved
   list aborts the build, with a message naming the
   symbol.

This is the same discipline as a `pre-commit` hook or a
linter — automated checks for an invariant that cannot be
maintained by human review alone. The invariant being
checked: *what the source claims is compiled out actually is
compiled out*.

The technique is particularly important for **boundary
violations**. A direct `tracy::` call snuck past the macro
front door (`TLM.4`) shows up in `nm -C` as a `tracy::`-prefixed
symbol in a translation unit that should not have one. A
`fprintf(stderr, ...)` in a hot path shows up in `strings` as
its format string. These are bugs the source review missed
and the build process surfaces.

The novelty of this guideline within the published profiler
documentation landscape is the **validation step itself**.
Every profiler claims its disabled macros compile to nothing;
none of them ship a "check that this is true" tool. The
inference-engine adoption cited in References was where the
check was made mandatory in CI; that's the contribution worth
flagging.

## Guidance

- **Run `strings` and `nm -C` on every release-class
  artefact.** Static archives (`.a`), shared libraries
  (`.so`/`.dylib`), and final executables.
- **Maintain a forbidden-pattern list** for the build
  profile. Use prefix patterns (`trace::*`,
  `APP_*_DEBUG_*`) and explicit symbol names where the
  prefix is too broad.
- **Maintain an approved-residual-symbol list** with
  justification. Each entry names the symbol, names the
  reason it is acceptable (e.g., "product configuration
  adapter from packet 140"), and is reviewed when changed.
- **Make the scan the build step's gate.** A failed scan
  exits non-zero before producing the final binary; CI
  catches it; release scripts refuse to package.
- **Scan both negative and positive evidence on
  trace-enabled builds.** The diagnostic build profile
  should produce a binary that *does* contain trace sink
  symbols and label strings — the scan confirms that, too.
- **Verify boundary discipline.** Direct `tracy::`,
  `__itt_*`, `PIXScopedEvent`, or other sink-API symbols
  in translation units that should be behind the macro
  front door (`TLM.4`) are surfaceable in `nm -C` output
  with a one-line `grep`.
- **Document the scan as part of the build contract.** The
  README or build-script comment names the scan as the
  validation step for TLM.1. Without the comment, future
  maintainers see the scan as ceremony and remove it.

## Example

```bash
#!/usr/bin/env bash
# scripts/validate_clean_build.sh — fail closed on residuals.
# Run after every --performance / --benchmark build.

set -euo pipefail

ARCHIVE="${1:?usage: validate_clean_build.sh <archive.a>}"

# Forbidden symbol patterns in a clean performance build.
FORBIDDEN_NM_PATTERNS=(
    'trace::'
    'app::diagnostic::'
    'read_.*_debug_stats_from_env'
    'self_test'
    'audit_'
)

# Forbidden string patterns in a clean performance build.
FORBIDDEN_STRINGS_PATTERNS=(
    'APP_TRACE_'
    'APP_.*_DEBUG_'
    'APP_SCHEDULER_DEBUG_STATS'
    'app\.render\.'      # trace marker name space
    '--diagnostic'
)

# Approved residual symbols (product-config adapter from packet 140).
APPROVED_RESIDUAL=(
    'read_app_product_config_from_env'
)

# 1. Symbol scan.
NM_OUTPUT=$(nm -C "$ARCHIVE")
for pattern in "${FORBIDDEN_NM_PATTERNS[@]}"; do
    hits=$(echo "$NM_OUTPUT" | grep -E "$pattern" || true)
    while read -r line; do
        [ -z "$line" ] && continue
        approved=false
        for ok in "${APPROVED_RESIDUAL[@]}"; do
            if echo "$line" | grep -q -- "$ok"; then approved=true; fi
        done
        if ! $approved; then
            echo "FAIL: forbidden symbol in clean build: $line"
            exit 2
        fi
    done <<< "$hits"
done

# 2. String scan.
STRINGS_OUTPUT=$(strings "$ARCHIVE")
for pattern in "${FORBIDDEN_STRINGS_PATTERNS[@]}"; do
    if echo "$STRINGS_OUTPUT" | grep -qE "$pattern"; then
        echo "FAIL: forbidden string in clean build:"
        echo "$STRINGS_OUTPUT" | grep -E "$pattern" | head -5
        exit 2
    fi
done

echo "OK: clean build scan passed for $ARCHIVE"
```

```bash
# Positive evidence on the diagnostic build — the scan
# expects to find trace symbols and trace labels here.
# scripts/validate_diagnostic_build.sh — fail closed if the
# diagnostic build is *missing* the trace machinery.
nm -C build-diagnostic/src/libapp_core.a | grep -q 'trace::' \
    || { echo "FAIL: diagnostic build missing trace symbols"; exit 2; }
strings build-diagnostic/src/libapp_backend.a | grep -q 'app\.render\.' \
    || { echo "FAIL: diagnostic build missing trace labels"; exit 2; }
```

## Caveats

- **Static archives keep debug names by default.** Even a
  successfully compile-out'd template can leave residual
  symbols in a `.a` until link-time dead-code elimination
  runs. Scan the final executable / shared library, not
  just the archive.
- **`nm` on a stripped binary returns nothing.** The scan
  must run on the pre-strip artefact. CI builds typically
  keep symbols; release builds strip — scan before
  stripping.
- **Patterns must be precise.** A pattern like `trace`
  matches `untraced` and `subtract`; quote and anchor
  patterns appropriately (`'^trace::'`, `' trace::'`).
- **Approved-residual lists drift.** Quarterly review of
  the approved list; entries should have a packet
  reference or comment naming why they exist.
- **LTO can move symbols across TUs.** A function defined
  in a forbidden TU may be inlined into an allowed TU and
  vanish from the symbol table. Conversely, a function
  the source thought was inlined may survive as a symbol.
  Verify against the actual linked output.
- **The scan does not catch runtime data-driven leakage.**
  An env-var-named-from-a-config-file is invisible to a
  string-pattern scan. Cross-reference `TLM.6`
  (build-profile fail-closed) and the broader principle
  that *config-driven diagnostic behavior* needs its own
  policy.
- **Some platforms have additional artefact types.** macOS
  dSYM bundles, Windows PDB files — both contain symbols
  and strings worth scanning. Adapt the scan to the
  platform's release artefacts.

## References

- Plainsight Systems internal engineering records (the **Vigil**
  ML inference engine project) — the canonical worked example:
  clean archive scans for `strings` and `nm -C`, approved-
  residual-symbol list with justification, build-profile
  fail-closed. Cited for technique provenance; the documents
  are Plainsight-private and not publicly available.
- `nm(1)`, `strings(1)`, `objdump(1)` — GNU binutils
  manpages.
- LLVM `llvm-nm`, `llvm-strings`, `llvm-objdump` — equivalent
  tools for LLVM toolchains.
- Apple Developer, *Build-time validation with `nm`* — Xcode
  documentation on inspecting Mach-O binaries.
- Microsoft, *DUMPBIN /SYMBOLS* — the Windows equivalent for
  PE binaries.
- Cross-reference: `TLM.1` (the claim being verified),
  `TLM.4` (boundary discipline — direct sink calls outside
  the macro layer are detectable here), `TLM.5` (label
  strings live here), `TLM.6` (build-profile fail-closed is
  the upstream gate; the scan is the downstream gate),
  `GEN.4` (LTO can move symbols, complicating the scan).
