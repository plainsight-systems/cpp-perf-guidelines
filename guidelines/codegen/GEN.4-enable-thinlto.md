+++
id = "GEN.4"
title = "Enable ThinLTO as the default — cross-TU inlining and devirtualisation are the real wins"
category = "codegen"
status = "draft"
summary = "Without LTO, every TU boundary is opaque to the inliner. ThinLTO restores cross-TU inlining and whole-program devirtualisation at a few-times link cost. 5-15% runtime wins are routine; embedded code-size wins are larger."
tags = ["lto", "thinlto", "cross-tu-inlining", "devirtualisation"]
+++

## Rationale

A translation unit boundary is a hard wall for the inliner. Without LTO,
a function call from `foo.cpp` to a function defined in `bar.cpp` cannot
be inlined — the compiler does not see `bar.cpp`'s body when it
compiles `foo.cpp`. The link step then accepts call instructions and
emits a final binary that runs every cross-TU call out-of-line. This
single fact costs a measurable amount of performance on every non-LTO
build of every non-trivial C++ program.

**Link-Time Optimisation (LTO)** delays optimisation until after all TUs
have been seen. Two flavours:

- **Full LTO.** The link becomes a whole-program compile. Maximum
  cross-TU opportunity; ~5–20× link time on large codebases;
  multi-million-LOC builds may need tens of gigabytes of RAM at link.
  Worth it for shipping binaries; painful in interactive iteration.
- **ThinLTO.** Per-TU summaries are linked, then per-function importing
  happens in parallel. Link time grows ~2–4× over a non-LTO build;
  most of the cross-TU inlining wins are retained. **Practical default
  for engines and shipped binaries.**

What LTO actually unlocks:

- Cross-TU inlining. Most of the runtime win.
- Whole-program devirtualisation (Clang `-flto -fwhole-program-vtables`,
  plus `-fstrict-vtable-pointers` for full effect). A virtual call to a
  method whose only implementation in the program is known becomes a
  direct, inlinable call. Major win on virtual-dispatch-heavy code.
- Dead-code elimination at program scope — unused functions, unused
  virtual overrides.
- Constant propagation across TUs — a function always called with a
  constant argument can be specialised.

Typical wins on engines: 5–15 % runtime, dramatically higher on heavy
virtual dispatch. Code-size wins on embedded are routinely 10–30 % from
program-scope dead-code elimination.

## Guidance

- **Default to ThinLTO** for shipping builds. `-flto=thin` on Clang;
  `-flto` on GCC (which has a similar parallelisable mode).
- **Enable devirtualisation flags** where applicable. On Clang:
  `-fwhole-program-vtables` plus `-fstrict-vtable-pointers`. On GCC:
  `-fdevirtualize` (default at `-O2`) plus `-fdevirtualize-speculatively`.
- **Verify across compilers.** ThinLTO behaviour and ABI-level
  interactions differ between Clang and GCC; build on every target you
  ship.
- **For interactive debug / development builds**, leave LTO off. The
  link-time cost dominates the edit-build-test loop; the optimisation
  wins are not relevant.
- **For embedded targets**, LTO is also a code-size win. `arm-none-eabi`
  GCC supports `-flto` and routinely produces 10–30 % smaller flash
  images.
- **For library code shipped as static archives**, ship a non-LTO build
  and let downstream choose. LTO across consumer boundaries requires
  matching compiler versions.

## Example

```text
# CMake snippet — enable ThinLTO for the release build.
# (Use the documented spelling for your CMake / Clang / GCC version.)
if (CMAKE_BUILD_TYPE STREQUAL "Release")
    include(CheckIPOSupported)
    check_ipo_supported(RESULT ipo_supported OUTPUT ipo_msg)
    if (ipo_supported)
        set_property(TARGET my_engine PROPERTY
                     INTERPROCEDURAL_OPTIMIZATION TRUE)
    else()
        message(WARNING "IPO/LTO not supported: ${ipo_msg}")
    endif()
endif()

# Clang ThinLTO + devirtualisation:
#   CXXFLAGS:  -O3 -flto=thin -fwhole-program-vtables
#   LDFLAGS:   -O3 -flto=thin -fwhole-program-vtables
#
# GCC LTO:
#   CXXFLAGS:  -O3 -flto -fdevirtualize
#   LDFLAGS:   -O3 -flto
```

```cpp
// Demonstration of what LTO unlocks: a hot dispatch that crosses a TU
// boundary. Without LTO the inliner cannot see Handler::run() across
// the boundary and emits a real call every iteration. With LTO the
// implementation is inlined into the loop and (for a sealed hierarchy
// with -fwhole-program-vtables) devirtualised.

// in handler.h:
struct Handler {
    virtual void run(Packet&) = 0;
    virtual ~Handler() = default;
};
struct DefaultHandler final : Handler {
    void run(Packet& p) override;          // defined in handler.cpp
};

// in hot_loop.cpp:
void process(std::span<Packet> ps, Handler& h) {
    for (auto& p : ps) {
        h.run(p);   // without LTO: indirect call per iteration.
                    // with LTO + whole-program vtables and only
                    // DefaultHandler in the program: direct, inlined.
    }
}
```

## Caveats

- **ABI compatibility.** LTO can expose code paths the compiler would
  have kept hidden, occasionally surfacing missing symbols or
  one-definition-rule violations. Fix the underlying bug; do not turn
  off LTO to silence it.
- **Link-time RAM cost.** Full LTO can need tens of GB on large
  codebases. ThinLTO is friendlier; use it as the default.
- **Compiler-version skew.** LTO bitcode is a compiler-version-tied
  format. Mixing Clang versions across a link is unreliable; pin the
  toolchain.
- **`inline` is not LTO.** `inline` only permits multiple definitions
  across TUs; it does not enable cross-TU inlining without LTO.
- **Devirtualisation needs a closed world.** A virtual call in a
  shipped library cannot be devirtualised against types only the
  application defines. `-fwhole-program-vtables` works for the
  application; library boundaries break it.
- **Embedded with LTO + `-fno-exceptions`** is the right combination —
  removes the unwind paths LTO would otherwise preserve. See `EMB.3`.

## References

- LLVM, *Link-Time Optimization* —
  <https://llvm.org/docs/LinkTimeOptimization.html>
- Clang, *ThinLTO* — <https://clang.llvm.org/docs/ThinLTO.html>
- Teresa Johnson, *ThinLTO: Scalable and incremental LTO*, LLVM Dev
  Meeting 2015 — <https://llvm.org/devmtg/2015-10/#talk7>
- GCC, *LTO Overview* —
  <https://gcc.gnu.org/onlinedocs/gccint/LTO-Overview.html>
- CMake, `INTERPROCEDURAL_OPTIMIZATION` —
  <https://cmake.org/cmake/help/latest/prop_tgt/INTERPROCEDURAL_OPTIMIZATION.html>
- Cross-reference: `GEN.5` (PGO — additive with LTO), `EMB.3`
  (LTO + `-fno-exceptions` for embedded).
