+++
id = "WASM.14"
title = "State the target matrix and budget for the weakest device, not the development one"
category = "wasm"
status = "draft"
summary = "Engines tier differently, mobile memory ceilings are far below desktop, and graphics limits span 32x; a desktop-Chromium measurement is not a portability claim."
tags = ["portability", "mobile", "safari", "javascriptcore", "target-matrix", "memory-budget"]
+++

## Rationale

Most published WebAssembly performance material — and most developer experience
— is V8 on desktop. That is a narrow slice of what a web target actually has to
run on, and the differences are not marginal.

**Engines tier differently.** V8 uses two compiler tiers and compiles lazily:
Liftoff compiles a function when it is first called, and TurboFan recompiles it
on a background thread once it is called often enough. SpiderMonkey also uses
two compiler tiers. JavaScriptCore uses **three** — an LLInt interpreter plus
BBQ and OMG. A warm-up procedure tuned to V8's curve is not automatically valid
on Safari, and V8's tracing markers have no equivalent there.

**Mobile ceilings are far below desktop ones.** Unity documents separate, more
aggressive memory tuning for mobile browsers, advising that initial memory size
be set to the application's typical heap usage rather than left at a
desktop-friendly default. A heap budget that is comfortable on a desktop can get
the tab reclaimed on a phone.

**Graphics capability varies far more than the specification tells you.**
WebGPU publishes *defaults* every adapter must meet — 128 MiB for
`maxStorageBufferBindingSize` — but it does not classify limits by device class,
and what an adapter advertises above the default is device-, driver- and
browser-specific, reported in privacy-motivated tiers. The range you design
against has to come from measuring your own target devices, not from a
published table.

And the API baseline is not what the newest documentation implies: Godot's web
export is **WebGL 2.0 only and does not support WebGPU**, and Unity's shipped Web
target is WebGL-based. WebGPU is the leading edge, not the floor.

## Guidance

- **Write the target matrix down.** Browsers, engines, form factors, and the
  minimum device. An unstated matrix defaults to "the machine on my desk".
- **Budget memory against the weakest supported device**, then verify on it. A
  desktop-derived heap size is not a budget.
- **Do not treat Chromium behaviour as the platform.** Code caching thresholds,
  tiering shape, and tracing markers are V8-specific.
- **Re-derive warm-up per engine.** An iteration count tuned against Liftoff and
  TurboFan says nothing about LLInt, BBQ and OMG.
- **Verify against the WebGPU defaults, not the limits granted** on your
  hardware (`WASM.10`). The defaults are the only figures the specification
  guarantees.
- **Pick the graphics baseline from the matrix, not from the newest API.** If the
  matrix includes engines or devices without WebGPU, WebGL 2 is the floor and
  WebGPU is an enhancement.
- **Test on a real low-end device.** Emulated throttling does not reproduce
  memory reclamation, thermal behaviour, or driver differences.
- **State reach decisions as decisions.** Dropping a platform is legitimate and
  should be recorded, not discovered from a support ticket.

## Example

```cpp
// The matrix as data, so it can be asserted rather than assumed. A budget that
// lives in a spreadsheet is not a control; this one can be tested.
struct TargetProfile {
    const char* name;                   // "desktop-chromium", "ios-safari"
    std::size_t heap_budget_bytes;      // MEASURED on this device, not assumed
    std::uint64_t min_storage_binding;  // what you require; default is 128 MiB
    bool has_webgpu;                    // false is a supported configuration
    bool cross_origin_isolated;         // determines threads and clock
};

// Ordered weakest-first, because the weakest row constrains every sizing
// decision. Every number here must come from a measurement on that device --
// the WebGPU specification publishes defaults, not device classes, and no
// vendor publishes a per-device heap ceiling.
inline constexpr std::array<TargetProfile, 3> kTargets{{
    {"mobile-safari",    192u * 1024 * 1024, 128u * 1024 * 1024, false, false},
    {"mobile-chromium",  256u * 1024 * 1024, 128u * 1024 * 1024, true,  false},
    {"desktop-chromium", 1024u * 1024 * 1024, 128u * 1024 * 1024, true,  true},
}};

// Derive the budget from the matrix rather than from the development machine.
// If this returns a number that makes the application infeasible, that is the
// finding -- not an argument for measuring on a better laptop.
[[nodiscard]] constexpr std::size_t binding_heap_budget() noexcept {
    std::size_t smallest = std::numeric_limits<std::size_t>::max();
    for (const TargetProfile& t : kTargets) {
        smallest = std::min(smallest, t.heap_budget_bytes);
    }
    return smallest;
}

// The sizing decision now cites the constraint that produced it, so a later
// reader can tell a considered budget from a convenient one.
static_assert(binding_heap_budget() <= 192u * 1024 * 1024,
              "heap budget must be sized for mobile-safari, the weakest target");

// WebGPU is an enhancement over a WebGL floor whenever the matrix includes a
// target without it. Structure the renderer so the floor is the default path,
// not a degraded afterthought that nobody exercises.
class RenderBackend {
public:
    virtual ~RenderBackend() = default;
    virtual void submit(std::span<const DrawBatch>) = 0;
};

// Selected from the matrix at startup. Note the ordering: the universally
// supported backend is the fallback, and it is the one CI runs by default.
[[nodiscard]] std::unique_ptr<RenderBackend> make_backend(const TargetProfile& target) {
    if (target.has_webgpu) {
        if (auto gpu = try_make_webgpu_backend()) {
            return gpu;                         // enhancement
        }
    }
    return make_webgl2_backend();               // the floor, always present
}

// Warm-up is engine-specific, so it is a property of the target rather than a
// constant. A single hardcoded count is a V8 assumption in disguise.
struct WarmupPolicy {
    const char* engine;              // "V8", "JavaScriptCore", "SpiderMonkey"
    std::size_t iterations;          // JSC has three tiers; V8 has two
    const char* basis;               // how this count was determined
};
```

## Caveats

- **A wide matrix costs real engineering.** Each row is testing, CI capacity and
  bug surface. Narrowing it is legitimate; leaving it unstated is not.
- **Published mobile memory figures are scarce, and device-class tables are
  mostly folklore.** Vendor documentation gives guidance rather than hard limits;
  community-reported numbers vary by device and OS version. Anything you cannot
  trace to a specification default or your own measurement should be treated as
  unverified.
- **The weakest device may not be the oldest.** A recent phone under memory
  pressure from other tabs can be tighter than an older one at rest.
- **Sizing for the floor can waste capable hardware.** Where that matters, scale
  content by detected capability — but keep the floor working, since it is what
  most users have.
- **The matrix ages.** WebGPU availability, feature support, and engine tiering
  all move; a matrix written once and never revisited becomes wrong quietly.
- **Emulated device modes are not devices.** They reproduce viewport and input,
  not memory reclamation or GPU limits.

## References

- [Unity — Memory in Unity Web](https://docs.unity3d.com/Manual/webgl-memory.html)
- [Unity — Web performance considerations](https://docs.unity3d.com/6000.4/Documentation/Manual/webgl-performance.html)
- [Godot — Exporting for the Web](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)
- [V8 — Liftoff: a new baseline compiler for WebAssembly](https://v8.dev/blog/liftoff)
- [A. Wingo — Understanding WebAssembly code generation throughput](https://wingolog.org/archives/2020/04/14/understanding-webassembly-code-generation-throughput)
- [WebGPU Fundamentals — Optional features and limits](https://webgpufundamentals.org/webgpu/lessons/webgpu-limits-and-features.html)
- Cross-reference: `WASM.1` (the heap being budgeted), `WASM.10` (verifying at
  the floor), `WASM.11` (warm-up per engine), `WASM.13` (which targets justify a
  build variant).
