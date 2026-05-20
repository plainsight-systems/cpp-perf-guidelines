# C++ for Embedded, Real-Time, and Safety-Critical Systems — Technique Extraction

Research note — 2026-05-20. Supports packet
`2026-05-20-embedded-category-buildout`. Technique-extraction pass for the
`embedded` category — what each source actually teaches (the rule, the
rationale, the anti-pattern), not bibliography. Builds on `MEM.9` ("allocate
at init, not in steady state"). Sources are classified per the
`CONTRIBUTING.md` sourcing rule:

- **Citable** — free public talk / paper / blog (link is the citation).
- **Cite-by-reference** — copyrighted book / paid standard; reference but do
  not quote.
- **Study-only code** — proprietary or non-permissive source.
- **Permissive code** — MIT / BSD / Apache-2.0 / similar.

---

## 1. Allocation as a discipline

### 1.1 The steady-state-no-allocation rule (builds on `MEM.9`)

The dominant rule in this category is not "no heap" — it is **no heap after
init**. All allocation happens during a bounded initialization phase; the
steady-state (control loop, ISR path, scheduler tick) must be allocation-free.
This is the rule that makes WCET, fragmentation, and OOM all become
non-issues by construction. `MEM.9` introduces the principle; embedded
extends it from "advisable" to "load-bearing for certification."

### 1.2 Pure static allocation

The strictest tier (MISRA, JSF AV C++, DO-178C DAL-A code) forbids
`operator new` and `malloc` entirely. The technique:

- Global / `static` storage for all long-lived objects.
- Object pools (`etl::pool`, `etl::generic_pool`) for object-grained reuse.
- Fixed-capacity containers with embedded storage for variable-shaped data.
- "Construct in place" with `std::optional`, `std::variant`, or
  `alignas(T) std::byte[sizeof(T)]` (see `LIFE.8`) for late-but-not-dynamic
  initialization.

Anti-patterns: `std::vector::push_back` anywhere in the steady state;
`std::string` returned by value from any function reachable from an ISR;
`std::function` (small-buffer-optimised with a silent heap fallback that is
fatal here).

### 1.3 Deterministic allocators (when allocation is unavoidable)

When a system genuinely needs dynamic lifetimes (CAN/UAVCAN framing, message
reassembly), the answer is a **constant-time, bounded-fragmentation
allocator**, not a general-purpose one:

- **TLSF (Two-Level Segregated Fit)** — Masmano / Ripoll / Crespo / Real,
  ECRTS 2004. O(1) `malloc`/`free`, provable fragmentation bound. The
  standard reference real-time allocator. Paper **cite-by-reference**;
  implementations in `mattconte/tlsf` and `sysprog21/tlsf-bsd` are BSD —
  **permissive code**.
- **o1heap** — Pavel Kirienko, MIT. ~500 LOC, auditable, O(1), targeted at
  high-integrity systems and certified avionics. The smallness is the
  design — it can be read end-to-end during a safety review. **Permissive
  code.**
- **libcanard / libudpard** consume o1heap as their only allocator,
  demonstrating the "size the worst case, then let the allocator run"
  pattern.

Even with TLSF / o1heap, you **size the worst case offline**, prove the
arena is large enough, and treat OOM as a fault, not a recoverable
condition.

## 2. Exceptions: cost, bans, and `-fno-exceptions`

### 2.1 Why MISRA bans them, why AUTOSAR conditionally permits

- **MISRA C++ 2008** and **MISRA C++ 2023** ban exceptions outright:
  non-local control flow defeats reviewability and static analysis, and the
  Itanium ABI's `__cxa_throw` path is not WCET-bounded.
- **AUTOSAR C++14** permits exceptions under tight rules — controlled
  propagation, no exceptions across ASIL boundaries, no exception
  specifications. The rationale split: AUTOSAR targets ASIL-B/C automotive
  code where stop-the-world is not acceptable; MISRA targets stricter
  regimes.
- **JSF AV C++** (Lockheed, 2005) bans exceptions; the reasoning (non-local
  control flow, code size, WCET) is unchanged.

### 2.2 What exceptions actually cost

- **Code size:** unwind tables (`.ARM.exidx`, `.eh_frame`,
  `.gcc_except_table`) live in flash. On Cortex-M, enabling exceptions adds
  tens of KB *for code that never throws*, because every function with a
  non-trivial destructor on the stack contributes an entry.
- **Throw path:** `__cxa_allocate_exception` calls `malloc` by default. This
  alone disqualifies exceptions for many embedded targets — a throw can OOM.
- **Cold-path optimisation barrier:** even on no-throw paths, the compiler
  must preserve unwind state across calls that *could* throw.

### 2.3 What `-fno-exceptions` actually changes

- `throw` and `try`/`catch` become compile errors.
- Standard-library calls that would throw call `std::terminate` (or are
  replaced with `abort()`-equivalent stubs in vendor libcs like
  newlib-nano).
- The compiler omits unwind tables and EH personality routines —
  measurable code-size reduction.
- `std::vector::at` still exists but on overflow calls `terminate`.
  **Library API that *encodes* failure as an exception becomes effectively
  unusable.**

This is why ETL and EASTL exist: they re-cut the STL API to never throw.

## 3. RTTI: `-fno-rtti`

### 3.1 Cost

- Every polymorphic class carries a `type_info` reference in its vtable;
  the `type_info` objects (with mangled name strings) sit in flash.
- `dynamic_cast` walks the class hierarchy — not O(1). In a deep hierarchy
  this is a latent WCET problem.
- `typeid` on a polymorphic reference dereferences the vtable.

### 3.2 Bans and alternative

MISRA and JSF AV C++ ban `dynamic_cast` and `typeid` on polymorphic types.
AUTOSAR permits with justification. `-fno-rtti` removes `type_info` strings
and the `dynamic_cast` runtime, and forbids `dynamic_cast` between
polymorphic types.

The replacement pattern is closed-set polymorphism via `std::variant` +
`std::visit`, or a hand-rolled tagged union, or the classic visitor pattern
— trading open extensibility for compile-time-known cases, which is
exactly the trade embedded wants.

## 4. Fixed-capacity containers

### 4.1 ETL — Embedded Template Library (Wellbelove, MIT, **permissive code**)

- Header-only; no heap; no exceptions (configurable to assert, log-and-
  abort, or call a user handler).
- `etl::vector<T, N>`, `etl::deque<T, N>`, `etl::map<K, V, N>`,
  `etl::flat_map`, `etl::unordered_map`, `etl::string<N>`,
  `etl::circular_buffer`.
- Design from docs: **capacity is part of the type**; overflow is a
  contract violation, not a runtime error to recover from; storage is
  inline. `etl::ivector<T>` provides a capacity-erased reference so
  functions can take "any ETL vector of `T`."
- Adds embedded-specific facilities the STL does not: state machines
  (`etl::fsm`), CRCs, frame protocols, `etl::message_router`.

### 4.2 EASTL `fixed_*` containers (EA, BSD-3, **permissive code**)

- `fixed_vector<T, N, bEnableOverflow>`, `fixed_string<N>`,
  `fixed_hash_map<K, V, N>`.
- The `bEnableOverflow` template flag is the design tell: EASTL lets you
  opt into a fallback allocator if you exceed capacity; embedded users set
  it `false`. Games use it for "fast path 99 % of the time, slow path for
  the rare large case."

### 4.3 Hand-rolled versus library

Hand-roll only when you need a layout the libraries do not offer (e.g.
intrusive lists where the link pointers live *in* the element). For
everything else, ETL / EASTL is cheaper than the bugs you will write.

## 5. WCET and the language

Features that compose with WCET analysis:

- `constexpr` — work moves out of WCET entirely.
- Templates — monomorphic, statically resolved.
- `noexcept` everywhere — no unwind paths to bound.
- Static dispatch, CRTP — call targets known at compile time.
- Bounded loops with compile-time-known bounds.

Features that do not:

- Exceptions (non-local, unbounded unwind).
- Virtual dispatch (analyzable but pessimistic).
- Dynamic allocation (general `malloc` unbounded; TLSF / o1heap bounded but
  add a term).
- `std::function`, `std::any`, RTTI.

## 6. Stack budgeting

- **Recursion bans** (MISRA): unbounded stack depth is unanalyzable.
- **Large locals** — anything over a few hundred bytes goes static or into
  a pool.
- **Toolchain support:** `-fstack-usage` (GCC, Clang) emits a `.su` file
  per TU with per-function stack frame sizes. `puncover` (Memfault,
  Apache-2.0) walks the call graph and produces a stack-budget report.
  Recursion detection via `cflow`-style call-graph analysis.
- **Pattern:** ISRs use a separate stack (the MSP on Cortex-M); the main
  stack budget is sized for worst-case main-context depth, the ISR stack
  for worst-case nested-IRQ depth, verified independently.

## 7. `constexpr` / `consteval` as compile-time relocation

The embedded payoff is direct: a `constexpr` lookup table is `.rodata` in
flash — zero RAM, zero init cost, zero WCET term. `consteval` (C++20) makes
"must evaluate at compile time" explicit, so a regression that accidentally
pulls a table into runtime initialization is a compile error. Typical
wins: protocol CRCs, sine / cosine tables, parser DFAs, command dispatch
tables. Push parsing of configuration and generation of dispatch to compile
time wherever the inputs are statically known.

## 8. MMIO and `volatile` correctness

- `volatile T*` is the correct tool for **memory-mapped registers** — it
  prevents the compiler from removing, reordering (with respect to other
  `volatile` accesses), or coalescing loads / stores that have hardware
  side effects. This is the *only* mainstream use of `volatile` that is
  unambiguously correct.
- `volatile` is **not** the right tool for **concurrency** between ISR and
  main code: it provides no atomicity and no inter-thread ordering. Use
  `std::atomic<T>` with explicit `memory_order_acquire` / `release`. On
  Cortex-M, `std::atomic<uint32_t>` with naturally aligned types is
  lock-free and compiles to plain load / store with the right barriers.
- **Both are needed** when an ISR writes to an MMIO register *and* updates
  a shared flag the main loop reads: `volatile` for the register,
  `std::atomic` for the flag.
- Ben Saks' CppCon talks on `volatile` are the standard reference.

## 9. Freestanding C++

What is **typically present** on bare-metal (GCC `arm-none-eabi`, Clang
with `-ffreestanding`):

- `<type_traits>`, `<utility>`, `<tuple>`, `<array>`, `<bit>`, `<bitset>`,
  `<limits>`, `<numeric>` (most), `<initializer_list>`, `<atomic>` (subset,
  lock-free types), `<cstdint>`, `<cstddef>`.

What is **typically absent or unusable**:

- `<iostream>`, `<fstream>`, `<filesystem>` — require an OS / heap.
- `<thread>`, `<mutex>`, parts of `<future>` — require an OS threading
  model.
- `<regex>`, `<locale>` — heap-heavy.
- `<exception>` — present in headers, unusable with `-fno-exceptions`.

C++23 adds significant **explicit freestanding** carve-outs (P1642,
P2407) — more of `<expected>`, `<optional>`, `<string_view>`, `<span>` are
mandated freestanding. The standard is finally meeting embedded where it
lives.

## 10. Functional-safety framing — the *why*

- **ISO 26262** (automotive, ASIL A–D): bans / mitigations for
  non-deterministic behaviour; rationale for AUTOSAR C++14.
- **IEC 61508** (industrial, SIL 1–4): parent of 26262; same posture
  toward dynamic memory and exceptions.
- **DO-178C** (avionics, DAL A–E): structural-coverage requirements that
  make non-local control flow (exceptions) and runtime polymorphism
  (RTTI / `dynamic_cast`) extremely expensive to certify.

These standards do not write code rules; they create the *evidentiary
burden* that drives MISRA / AUTOSAR / JSF to ban features whose
cost-of-evidence exceeds their benefit. **Cite-by-reference.**

## 11. Linker / section attributes (flagged, not deep)

`__attribute__((section(".dtcm")))`, `__attribute__((section(".itcm")))`,
`__attribute__((used))`, and the linker-script side of placing hot data in
tightly-coupled memory or RAM-resident code in ITCM. Flagged here; depth
belongs elsewhere (build-system territory).

## 12. Honest gaps

- Could not confirm a single canonical Phil Nash *embedded* talk; his
  public work centres on Catch2 and tooling. Omitted.
- Could not confirm a public, attributable Pavel Kirienko talk with a
  stable URL beyond the OpenCyphal / o1heap repos and READMEs. Treated
  those as the citable artefacts.
- "Almost Always Auto" (Sutter): citable as a modern-C++ guideline but
  **does not survive the embedded subset cleanly** — `auto` with brace-
  init still works, but the AAA examples involving `std::string` /
  `std::vector` returns are exactly the heap-touching patterns the
  embedded subset rejects. Flag as a "modern C++ idiom that needs
  translation for embedded."

---

## Sources

### Citable (free public)

- Embedded Artistry, *C++ Heapless Programming* —
  <https://embeddedartistry.com/fieldatlas/embedded-c-coding-standards/>
- bitbashing.io, *C++ on Embedded Systems* —
  <https://bitbashing.io/embedded-cpp.html>
- JSF AV C++ Coding Standards (Lockheed Martin, 2005) —
  <https://www.stroustrup.com/JSF-AV-rules.pdf>
- AUTOSAR C++14 Coding Guidelines (public PDF) —
  <https://www.autosar.org/fileadmin/standards/R22-11/AP/AUTOSAR_RS_CPP14Guidelines.pdf>
- Ben Saks, *Back to Basics: `volatile`*, CppCon — search:
  <https://www.youtube.com/results?search_query=ben+saks+volatile+cppcon>
- Wouter van Ooijen, *What can C++ do for embedded?*, CppCon 2018 —
  <https://www.youtube.com/watch?v=zBpfXEoH2H0>
- Odin Holmes, *Modern C++ in Embedded Systems*, Meeting C++ —
  <https://www.youtube.com/results?search_query=odin+holmes+embedded+c%2B%2B>
- C++23 freestanding (P1642, P2407) — <https://wg21.link/p1642>;
  <https://wg21.link/p2407>
- GCC `-fstack-usage` —
  <https://gcc.gnu.org/onlinedocs/gcc/Code-Gen-Options.html>
- Memfault Interrupt, *Tracking Down Stack Overflows* and `puncover`
  overview —
  <https://interrupt.memfault.com/blog/measuring-stack-usage>;
  <https://github.com/HBehrens/puncover>
- M. Masmano et al., *TLSF: A New Dynamic Memory Allocator for Real-Time
  Systems*, ECRTS 2004 —
  <https://www.gii.upv.es/tlsf/files/ecrts04_tlsf.pdf>

### Cite-by-reference (paid / standards)

- MISRA C++ 2008 — <https://misra.org.uk/product/misra-cpp2008/>
- MISRA C++ 2023 — <https://misra.org.uk/product/misra-cpp2023/>
- ISO 26262 — <https://www.iso.org/standard/68383.html>
- IEC 61508 — <https://webstore.iec.ch/publication/5515>
- DO-178C / RTCA — <https://www.rtca.org/>

### Permissive code

- ETL (MIT) — <https://github.com/ETLCPP/etl>; docs:
  <https://www.etlcpp.com/>
- EASTL (BSD-3) — <https://github.com/electronicarts/EASTL>
- o1heap (MIT, Kirienko) — <https://github.com/pavel-kirienko/o1heap>
- libcanard (MIT) — <https://github.com/OpenCyphal/libcanard>
- libudpard (MIT) — <https://github.com/OpenCyphal/libudpard>
- TLSF implementations (BSD) — <https://github.com/mattconte/tlsf>;
  <https://github.com/sysprog21/tlsf-bsd>;
  <https://github.com/rmind/tlsf>
- puncover (Apache-2.0) — <https://github.com/HBehrens/puncover>
