+++
id = "WASM.4"
title = "Reduce indirect dispatch in hot paths; WASM type-checks every indirect call"
category = "wasm"
status = "draft"
summary = "WebAssembly validates the target and signature of every indirect call, so virtual calls and function pointers cost more than natively, and the extra code costs i-cache."
tags = ["indirect-call", "virtual-dispatch", "function-pointers", "i-cache", "devirtualisation"]
+++

## Rationale

WebAssembly *semantically* requires that every indirect call be checked: that
the target index is a valid entry in the function table, and that the callee's
runtime type matches the type at the call site. In C++ that means every virtual
call and every call through a function pointer or `std::function`.

How much of that survives into optimised machine code is an engine decision, and
the distinction matters. Jangda et al. measured Chrome and Firefox as they were
in 2019 and found the checks present in generated code, along with a
stack-overflow check at each function entry and reserved registers (Chrome held
`r13`, `r10` and `xmm13`; Firefox held `r15`, `r11` and `xmm15`). They
classified these as consequences of WebAssembly's safety design rather than of
any one compiler — but WebAssembly does not mandate a particular lowering, and
engines have since narrowed the gap. V8 now speculatively inlines
`call_indirect` with deoptimization support.

Treat the numbers below as a measured lower bound on what indirection can cost,
not as a permanent property of the platform.

The measured effect is mostly *code size*, and code size is where it hurts:
instructions retired rose 1.75–1.80× over native, and **L1 instruction-cache
misses rose 2.83× in Chrome and 2.04× in Firefox**. The paper's own
counter-example makes the mechanism clear — `429.mcf` runs *faster* than native
in both browsers because its hot loop fits in L1i.

So the corpus's existing advice to prefer flat, predictable dispatch (`GEN`) and
to respect the instruction cache (`CACHE`) is not merely still true here. The
exchange rate is worse, and a deep virtual hierarchy in a hot loop is a
different proposition than it is natively.

## Guidance

- **Hoist dispatch out of the loop.** Select the implementation once, then run a
  monomorphic loop — one check instead of one per element.
- **Prefer a closed set over an open one in hot paths.** A `switch` over an enum
  or an `std::variant` visit compiles to a direct call or a jump table; a
  virtual call does not.
- **Mark leaf implementations `final`.** It gives the compiler the license to
  devirtualise, and `-flto` gives it the visibility (`GEN.4`).
- **Avoid `std::function` in hot paths.** It is an indirect call plus a possible
  allocation; a template parameter or a `function_ref`-style non-owning callable
  is a direct call.
- **Batch by type rather than iterating polymorphically.** Sorting work into
  per-type spans turns N indirect calls into one per type.
- **Watch total code size, not just call counts.** Aggressive inlining that
  removes indirect calls but inflates the loop body can lose on i-cache; measure
  both (`GEN.6`).
- **Do not extrapolate from a microbenchmark.** The cost shows up as cache
  pressure at scale, which a tight benchmark with a hot L1i will not reproduce.

## Example

```cpp
// Bad: one indirect call per entity per frame. Each pays a table-bounds check
// and a runtime signature check, and the vtable targets are scattered, so the
// loop touches many code lines.
struct Component {
    virtual ~Component() = default;
    virtual void update(float dt) = 0;
};

void update_all_bad(std::span<const std::unique_ptr<Component>> components, float dt) {
    for (const auto& c : components) {
        c->update(dt);              // indirect: bounds check + type check
    }
}

// Better: group by concrete type once, then run monomorphic loops. The call
// inside each loop is direct and inlinable, and the loop body is one code
// region rather than a scatter across every component implementation.
struct Physics { float x, y, vx, vy; };
struct Sprite  { float x, y; std::uint32_t tint; };

class ComponentStore {
public:
    void update(float dt) noexcept {
        // Direct calls, inlinable, one tight code region per pass.
        for (Physics& p : physics_) {
            p.x += p.vx * dt;
            p.y += p.vy * dt;
        }
        for (Sprite& s : sprites_) {
            s.tint = fade(s.tint, dt);
        }
    }
private:
    static std::uint32_t fade(std::uint32_t tint, float dt) noexcept;
    std::vector<Physics> physics_;   // contiguous, see the cache-layout category
    std::vector<Sprite> sprites_;
};

// When polymorphism is genuinely required, close the set. A closed set gives
// the compiler the option of a direct call or a jump table rather than an
// indirect call through the function table. That is an opportunity, not a
// guarantee -- std::visit's lowering is implementation-defined, and some
// implementations use a dispatch table of their own. Inspect the output before
// claiming the win.
using AnyComponent = std::variant<Physics, Sprite>;

struct StepVisitor {
    float dt;
    void operator()(Physics& p) const noexcept { step(p, dt); }
    void operator()(Sprite& s) const noexcept { step(s, dt); }
};

void update_all(std::span<AnyComponent> components, float dt) noexcept {
    for (AnyComponent& c : components) {
        std::visit(StepVisitor{dt}, c);   // inspect the lowering; do not assume
    }
}

// Where a virtual interface must stay, hoist the dispatch. One indirect call
// per batch instead of one per element.
struct Renderer {
    virtual ~Renderer() = default;
    virtual void draw_batch(std::span<const Sprite>) = 0;   // batch, not item
};

// Not: virtual void draw_one(const Sprite&) = 0;  // one indirect call each

// `final` lets the compiler devirtualise when the concrete type is visible;
// with -flto that visibility extends across translation units.
class GlRenderer final : public Renderer {
public:
    void draw_batch(std::span<const Sprite> sprites) override;
};
```

## Caveats

- **This is a hot-path rule.** Virtual dispatch is the right tool for plugin
  boundaries, platform abstraction, and anything called at configuration
  frequency. Do not flatten a design that is not in a loop.
- **The measurements are from 2019 and engines have improved.** V8 shipped
  speculative `call_indirect` inlining with deoptimization support in Chrome
  M137. The semantic requirement remains; how much of it costs anything at
  runtime is engine- and version-specific, so re-measure rather than citing
  these figures as current. (Checked 2026-09-05.)
- **Devirtualisation can enlarge code.** Inlining several implementations into
  one loop trades indirect calls for i-cache footprint — the very resource this
  guideline is protecting. Measure both sides.
- **Type-sorting has a cost.** Maintaining per-type storage complicates
  insertion and deletion. It pays when iteration dominates mutation.
- **`std::variant` is not free either.** A visit over many alternatives can
  produce a large jump table; keep the alternative count small.

## References

- [Jangda et al., *Not So Fast: Analyzing the Performance of WebAssembly vs. Native Code*, USENIX ATC 2019](https://www.usenix.org/conference/atc19/presentation/jangda)
- [V8 — Speculative optimizations for WebAssembly](https://v8.dev/blog/wasm-speculative-optimizations)
- [Emscripten — Optimizing Code](https://emscripten.org/docs/optimizing/Optimizing-Code.html)
- Cross-reference: `GEN.4` (LTO and devirtualisation), `GEN.6` (inlining
  attributes), `GEN.7` (cold-path placement), `CACHE.6` (hot/cold splitting),
  `WASM.8` (module size).
