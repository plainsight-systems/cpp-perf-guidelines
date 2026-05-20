+++
id = "EMB.1"
title = "Let the certification standard you target shape the C++ subset"
category = "embedded"
status = "draft"
summary = "ISO 26262, IEC 61508, DO-178C don't write code rules — they create the evidentiary burden that drives MISRA / AUTOSAR / JSF to ban specific C++ features. The standard comes first; the subset follows."
tags = ["misra", "autosar", "iso-26262", "do-178c", "certification"]
+++

## Rationale

Embedded C++ is shaped less by what the *language* allows than by what the
*certification standard for the target system* will accept as evidence. ISO
26262 (automotive), IEC 61508 (industrial), DO-178C (avionics), and the
defense lineage culminating in JSF AV C++ do not write coding rules — they
create the **evidentiary burden** that drives the coding standards on top
(MISRA C++, AUTOSAR C++14, JSF AV C++) to ban or restrict whichever C++
features cost more to certify than they earn back.

The order of operations is fixed: pick the system standard first, derive
the coding subset from it, then write code in that subset. Doing this
backwards — writing modern C++ first and trying to certify it after — has
been a pattern of failed embedded projects since the 2000s. Features the
standard cannot bound (exceptions' unwind path, `dynamic_cast`'s hierarchy
walk, `malloc`'s worst-case latency) are unbounded *cost of evidence*, even
when their runtime cost is small.

This guideline sits at the top of the `embedded` category because every
other guideline here is downstream of it: which containers (`EMB.2`),
whether exceptions / RTTI (`EMB.3`), which allocator if any (`EMB.4`), how
WCET tools see your code (`EMB.5`).

## Guidance

Identify the target's certification standard and ASIL / SIL / DAL level
**before** picking a coding subset.

- **Automotive, ASIL B–D** → **AUTOSAR C++14 Coding Guidelines**.
  Heap permitted under explicit rules; exceptions permitted under tight
  controlled-propagation rules; `dynamic_cast` permitted with
  justification. The most-modern of the major embedded subsets.
- **Industrial, SIL 1–4 / non-automotive safety** → **MISRA C++ 2023**
  (or 2008 on older projects). No heap, no exceptions, no RTTI, restricted
  undefined-behavior surface. Strictest mainstream subset.
- **Avionics, DAL A–E** → **DO-178C** structural-coverage requirements
  drive a MISRA-like subset in practice; non-local control flow
  (exceptions) and runtime polymorphism (RTTI, virtual dispatch) are
  expensive to certify and usually avoided.
- **Defense / aerospace** → historically **JSF AV C++**; modern programmes
  increasingly adopt **MISRA C++ 2023**.
- **Non-certified embedded** → there is no formal subset, but the same
  techniques pay back in code size, reliability, and reviewability. The
  practical default: design as if MISRA, relax only where measurement
  justifies.

Document the choice in the project's top-level architecture doc — the
coding standard and the ASIL / SIL / DAL it serves. Subsequent code
reviews refer to that document, not to general C++ taste.

## Example

```text
# Worked example — what choosing the standard tells you to do
# (illustrative; consult the actual standard text for binding rules)

Target system: brake-actuation ECU, ASIL D, automotive.
=> Coding standard: AUTOSAR C++14.
   - Heap:        permitted under section "A18-x" rules; init-phase only.
   - Exceptions:  permitted only with controlled propagation; never across
                  ASIL boundaries; no exception specifications.
   - RTTI:        permitted with justification; dynamic_cast acceptable
                  only when the alternative is materially worse.
   - Required:    deterministic allocator if heap is used; WCET evidence
                  for hot paths.

Target system: industrial pressure-control loop, SIL 3, IEC 61508.
=> Coding standard: MISRA C++ 2023.
   - Heap:        banned (after init, in steady state).
   - Exceptions:  banned outright.
   - RTTI:        banned outright.
   - Required:    no recursion; bounded stack; static analysis for the
                  full UB surface MISRA enumerates.

Target system: Hobbyist sensor on a Cortex-M0+, no formal certification.
=> Coding standard: project-internal; defaults to "MISRA-like".
   - Heap:        avoided by default; deterministic allocator if needed.
   - Exceptions:  -fno-exceptions (code-size win — EMB.3).
   - RTTI:        -fno-rtti (code-size win — EMB.3).
   - Required:    none externally; the discipline still pays back in flash
                  footprint and reliability.
```

## Caveats

- **Standards evolve.** MISRA C++ 2023 differs materially from 2008 on
  several features. AUTOSAR C++14 is being superseded by the merged
  AUTOSAR / MISRA effort. Specify which *version* of the standard the
  project targets; "MISRA" alone is not a citation.
- **Tooling coverage is uneven.** A clause in a coding standard is only
  enforceable if static analysis can detect violations. Check the chosen
  analyzer (Coverity, Polyspace, Helix QAC, clang-tidy with the right
  checks) actually flags the rules that matter for the level.
- **AUTOSAR's permissions are not licenses.** "Permitted with
  justification" requires a written rationale per use site, not a blanket
  acceptance.
- **A non-certified target is not exempt** from the underlying physics.
  An ISR that throws an exception will still OOM via
  `__cxa_allocate_exception`; the certification standard merely codifies
  what good practice already says (`EMB.3`).

## References

- AUTOSAR C++14 Coding Guidelines (R22-11, public PDF) — **Citable** —
  <https://www.autosar.org/fileadmin/standards/R22-11/AP/AUTOSAR_RS_CPP14Guidelines.pdf>
- JSF AV C++ Coding Standards (Lockheed Martin, 2005) — **Citable** —
  <https://www.stroustrup.com/JSF-AV-rules.pdf>
- MISRA C++ 2008 / MISRA C++ 2023 — **cite-by-reference** (paid) —
  <https://misra.org.uk/product/misra-cpp2008/>;
  <https://misra.org.uk/product/misra-cpp2023/>
- ISO 26262 (automotive functional safety) — **cite-by-reference** —
  <https://www.iso.org/standard/68383.html>
- IEC 61508 (industrial functional safety) — **cite-by-reference** —
  <https://webstore.iec.ch/publication/5515>
- DO-178C / RTCA — **cite-by-reference** — <https://www.rtca.org/>
