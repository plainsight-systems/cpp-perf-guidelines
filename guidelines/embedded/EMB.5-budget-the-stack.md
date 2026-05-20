+++
id = "EMB.5"
title = "Budget the stack: no recursion, bounded locals, -fstack-usage + call-graph analysis"
category = "embedded"
status = "draft"
summary = "Stack overflow corrupts adjacent memory silently. WCET requires a bounded depth. Ban recursion, size locals, run -fstack-usage and a call-graph analyzer, and budget ISR stacks separately."
tags = ["stack-usage", "wcet", "fstack-usage", "puncover"]
+++

## Rationale

The stack on an embedded target is a fixed region carved out of RAM by the
linker script. Overflow does not raise an exception or generate a clean
fault — it overwrites whatever is adjacent (often the `.bss` or the heap)
and produces a non-deterministic crash some milliseconds later, possibly
miles from the actual overflow site. WCET analysis cannot proceed unless
the stack depth is bounded.

Three behaviours make the stack unanalysable, and each maps directly to a
rule:

- **Recursion** — depth is data-dependent and analytically unbounded. MISRA
  Rule 17.2 (and its C++ equivalents) ban it outright; AUTOSAR restricts it
  to "provably bounded."
- **Large locals** — a `std::array<float, 8192>` on the stack is 32 KiB
  that the toolchain's stack-usage analysis sees, but a programmer reading
  the code often does not. Local objects above the few-hundred-byte range
  belong in `static` storage, an object pool (`MEM.2`), or a deliberately
  sized arena.
- **Deep call chains under condition** — a function that calls a different
  helper depending on a runtime value contributes the *maximum* of all
  reachable callees to the worst case. The depth is bounded but the
  analysis must walk the call graph.

The toolchain provides the primitives. `-fstack-usage` (GCC, Clang) emits a
`.su` file per translation unit with one line per function: name, frame
size, qualifier. **puncover** (Memfault, Apache-2.0) reads `.su` files
across the linked image, walks the call graph, and emits a worst-case
stack-depth report — including catches of recursion that slipped past code
review.

A Cortex-M target additionally has *two* stacks (MSP for handler mode, PSP
for thread mode) that must each be budgeted independently — main-context
depth on the MSP path, nested-interrupt depth on the handler path.

## Guidance

- **No recursion** anywhere in code reachable from the steady-state loop.
  Convert recursive algorithms to iterative ones with an explicit stack
  data structure (capacity bounded — `EMB.2`).
- **Cap stack-local objects at a small budget** — typical guidance ~256 B.
  Anything larger goes `static`, into a pool, or into an arena.
- **Build with `-fstack-usage`.** It costs nothing at runtime; it emits
  `.su` files alongside object files.
- **Run a call-graph analyzer** (`puncover`, or a hand-rolled script over
  the `.su` files + a linker map) at every commit. Fail the build if the
  worst-case depth exceeds the linker-script reservation.
- **Budget ISR and main stacks separately.** On Cortex-M, set the MSP and
  PSP sizes in the linker script to the analyzed worst cases of each.
- **Turn on the platform's stack-overflow detection** where available —
  MPU-based guard regions on Cortex-M, hardware stack-limit registers on
  Cortex-M33+, RTOS canaries on FreeRTOS / Zephyr. Failing loudly at the
  overflow beats failing silently a millisecond later.

## Example

```cpp
// Bad: recursion. Depth is data-dependent, the call-graph analyzer cannot
// bound it, and a deeper-than-expected input is silent stack overflow.
int tree_depth_bad(const Node* n) {
    if (!n) return 0;
    return 1 + std::max(tree_depth_bad(n->left),
                        tree_depth_bad(n->right));
}

// Good: iterative with an explicit, fixed-capacity stack. Depth is bounded
// by the container's capacity, sized from the worst-case tree height
// derived offline.
int tree_depth(const Node* root) {
    if (!root) return 0;
    etl::vector<std::pair<const Node*, int>, kMaxTreeDepth> stack;
    stack.push_back({root, 1});
    int best = 0;
    while (!stack.empty()) {
        auto [n, depth] = stack.back();
        stack.pop_back();
        best = std::max(best, depth);
        if (n->left)  stack.push_back({n->left,  depth + 1});
        if (n->right) stack.push_back({n->right, depth + 1});
    }
    return best;
}

// Bad: a large stack-local. 32 KiB on a Cortex-M with a 4 KiB stack is an
// immediate overflow, but the compiler will not warn — the function looks
// fine in isolation.
void filter_bad(std::span<float> in, std::span<float> out) {
    std::array<float, 8192> scratch;            // 32 KiB on the stack
    // ...
}

// Good: scratch lives in static storage sized once, or in a dedicated
// arena, and the call site sees only a span.
namespace filters {
    static std::array<float, 8192> scratch;     // .bss; sized at link time
}
void filter(std::span<float> in, std::span<float> out) {
    auto& scratch = filters::scratch;           // no stack growth here
    // ...
}
```

Build-time check (excerpt — concept, not literal command):

```sh
gcc -fstack-usage -O2 -c src/foo.cpp -o build/foo.o
# -> emits build/foo.su

puncover --elf build/firmware.elf \
         --src-root src/ \
         --build-dir build/ \
         --gcc-tools-base arm-none-eabi-
# -> HTML report; flags worst-case depth and dynamic-stack functions.
```

## Caveats

- **`-fstack-usage` reports per-function frame size**, not call-graph depth.
  The analyzer doing the call-graph walk (puncover or equivalent) is the
  piece that produces the actionable worst-case number.
- **Functions marked `dynamic` in `.su`** (frame size depends on runtime —
  variable-length arrays, `alloca`) defeat static analysis. Treat any
  `dynamic` entry as a bug; rewrite to a fixed-size local or a pool.
- **Link-time optimisation can move stack** in unexpected ways. Re-run the
  analysis on the linked binary, not just the per-TU `.su` files.
- **The MSP / PSP budget is platform-specific.** Cortex-M0 / M0+ have no
  hardware stack-limit register; Cortex-M33+ does. Use the MPU where the
  CPU does not.
- **Nested-interrupt worst case is its own analysis.** The deepest interrupt
  chain — counting tail-chained handlers — sets the ISR stack size, not the
  single longest handler.

## References

- GCC, `-fstack-usage` —
  <https://gcc.gnu.org/onlinedocs/gcc/Code-Gen-Options.html>
- puncover (Memfault, Apache-2.0) —
  <https://github.com/HBehrens/puncover>
- Memfault Interrupt blog, "Tracking Down Stack Overflows" —
  <https://interrupt.memfault.com/blog/measuring-stack-usage>
- Embedded Artistry, "Heap-less C++ Programming" (notes on stack
  discipline alongside heap discipline) —
  <https://embeddedartistry.com/fieldatlas/embedded-c-coding-standards/>
- Cross-reference: `EMB.1` (MISRA Rule 17.2 ban on recursion), `EMB.2`
  (`etl::vector` for the explicit-stack pattern).
