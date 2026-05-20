+++
id = "GEN.7"
title = "Mark [[gnu::cold]] on error and init paths to remove them from the hot function's I-cache footprint"
category = "codegen"
status = "draft"
summary = "[[gnu::cold]] moves a function to .text.cold, predicts calls to it not-taken, and tells the inliner to keep it out of hot callers. Synergistic with PGO; the fallback when PGO is not feasible."
tags = ["cold-functions", "i-cache", "hot-cold", "function-attributes"]
+++

## Rationale

A function used only on the error path or only at initialisation
contributes nothing to steady-state performance — but if it gets inlined
into a hot caller, or if its code sits adjacent to hot code in `.text`,
it consumes I-cache that the hot path needs. The cost is silent: the
hot loop's IPC drops a few percent and the profiler shows nothing
obviously wrong.

**`[[gnu::cold]]`** (GCC, Clang) marks a function as cold. The compiler
then:

- **Moves it to `.text.cold`** (or `.text.unlikely`) — a separate
  section, typically placed at the end of the binary. The hot
  function's I-cache window stays tight.
- **Predicts calls to it not-taken** at the branch / call site.
- **Deprioritises inlining it** into hot callers — the heuristic
  rejects it more aggressively.

`[[gnu::hot]]` is the symmetric attribute: cluster this function near
other hot functions; bias the inliner the other way. In practice
`[[gnu::cold]]` is the more useful of the pair — marking the *exception*
to a function's general hotness is cheaper than annotating every hot
function in the program.

PGO (`GEN.5`) subsumes manual `[[gnu::cold]]` annotations: profile data
already tells the compiler which functions are cold, with no annotation
needed. `[[gnu::cold]]` is the **fallback when PGO is not feasible** —
shipped libraries without telemetry, embedded firmware without a
representative workload capture, or code paths that PGO's profile
genuinely does not exercise.

## Guidance

- **Mark error / fault / log helpers `[[gnu::cold]]`.** Functions like
  `log_overflow`, `report_invalid_packet`, `panic_unreachable`,
  assertion helpers, retry-with-backoff loops.
- **Mark init / shutdown helpers `[[gnu::cold]]`.** Configuration
  parsing, plugin discovery, teardown — none of this is on the hot
  path.
- **Pair with `[[gnu::noinline]]`** when the body is large and you want
  to be absolutely sure it does not get folded into a hot caller. Most
  cold functions benefit from both.
- **Do not mark `[[gnu::hot]]` reflexively.** Marking the entire hot
  path "hot" is noisy; the inliner already prioritises it, and PGO
  handles the placement better. Reserve `[[gnu::hot]]` for the rare
  case where a hot function is heuristically misclassified as cold
  (e.g. it is only called through a virtual interface and the
  inliner cannot see the call frequency).
- **Under PGO**, audit `[[gnu::cold]]` annotations — the profile data
  dominates and a contradictory annotation is misleading rather than
  helpful.
- **MSVC has no direct equivalent.** `__declspec(noinline)` plus the
  section-placement pragma is the workaround; in practice, MSVC's
  inliner handles the common cases without help.

## Example

```cpp
// Cold helper: an assertion / fault path. Marked cold so the compiler
// keeps it out of .text proper, predicts the call not-taken, and does
// not inline it into hot callers. noinline is belt and braces.
[[gnu::cold, gnu::noinline]] static
void report_packet_error(const Context& ctx, const Packet& p) {
    // formatting, logging, possibly throwing or trapping — none of
    // this is on the hot path.
    log_error(ctx, "invalid packet seq=", p.seq);
    raise_protocol_fault(ctx);
}

// Hot loop calls the cold helper on the rare error branch. The
// [[unlikely]] on the branch and the [[cold]] on the callee both
// inform layout: the body of report_packet_error is far away in
// .text.cold; the call site predicts not-taken.
void process(std::span<Packet> packets, Context& ctx) {
    std::uint64_t accepted = 0;
    for (auto& p : packets) {
        if (!p.is_valid()) [[unlikely]] {
            report_packet_error(ctx, p);
            continue;
        }
        accepted += handle(p);
    }
    publish(accepted);
}

// Cold init: parsing a JSON config file at startup. This function runs
// once. Marking it cold pulls it out of the hot path's I-cache footprint.
[[gnu::cold]] static
Config parse_config(std::string_view text);

// Hot function: PGO would discover this on its own. Manual [[gnu::hot]]
// is the exception, used when the inliner heuristic misclassifies — for
// example, a function only ever called through a virtual interface
// where the inliner cannot see the call frequency.
[[gnu::hot]]
inline void blend_pixel(Pixel& dst, const Pixel& src) noexcept;
```

## Caveats

- **`[[gnu::cold]]` is a hint, not a contract.** The compiler may
  still inline a cold function if other heuristics override (e.g. a
  trivial one-line body). The attribute strengthens the deprioritisation;
  it does not eliminate it.
- **Section placement (`.text.cold`) needs linker cooperation.** Modern
  linkers (`ld.bfd`, `ld.gold`, `lld`) honour the section; some embedded
  linkers may not. Verify with `objdump --section-headers` on the target.
- **Cold-section placement does not equal slow execution.** A cold
  function still runs at full speed when called; the attribute only
  affects layout and inlining decisions. The "saving" is in the hot
  caller's I-cache.
- **Cold + virtual + LTO.** A virtual function marked `[[gnu::cold]]`
  gets the layout benefit, but with LTO and whole-program devirt
  (`GEN.4`) the call may become direct and inline regardless. The
  attribute and the devirt are not in conflict; the LTO pass simply
  has the last word.
- **Embedded.** On flash-XIP MCUs there is often no I-cache to optimise
  for. `[[gnu::cold]]` still helps the linker pack the function into
  a separate section, which can matter for code layout in ROM vs RAM,
  but the typical hot/cold motivation does not apply.

## References

- GCC function attributes — `hot`, `cold`, related —
  <https://gcc.gnu.org/onlinedocs/gcc/Common-Function-Attributes.html>
- Clang attribute reference —
  <https://clang.llvm.org/docs/AttributeReference.html>
- Maksim Panchenko et al., *BOLT* (post-link binary optimiser;
  treats hot / cold layout as the dominant lever) —
  <https://arxiv.org/abs/1807.06735>
- Cross-reference: `GEN.5` (PGO subsumes manual hot / cold under a
  representative profile), `GEN.6` (`noinline` pairs with `cold`),
  `GEN.1` (`[[unlikely]]` on the branch complements `[[gnu::cold]]`
  on the callee).
