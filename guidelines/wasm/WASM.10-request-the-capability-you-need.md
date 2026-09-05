+++
id = "WASM.10"
title = "Request the device capability you need, not the one the adapter offers"
category = "wasm"
status = "draft"
summary = "Web graphics APIs grant a portable minimum unless you ask for more; ask for exactly what the application requires so the contract is explicit and failures are diagnosable."
tags = ["webgpu", "webgl", "device-limits", "capability-negotiation", "portability"]
+++

## Rationale

Web graphics APIs negotiate capability at runtime, and the default answer is
deliberately the portable minimum rather than a report of the hardware.

In WebGPU, `requestDevice()` with no `requiredLimits` returns the **spec default
limits**; Chrome's migration guidance describes this device as a reasonable
lowest common denominator of all GPUs. `GPUAdapter.limits` says what the adapter
*could* support; `GPUDevice.limits` says what validation will actually enforce.
These are different objects answering different questions, and conflating them
is the standard error. WebGL negotiates the same way through `getExtension()`
and ceilings read with `getParameter()`.

The tempting shortcut is to read the adapter's advertised limits and pass them
straight back as `requiredLimits`. Avoid it. Even where the request succeeds, it
converts an explicit capability contract into an implicit one: the code now
depends on whatever the development machine happened to advertise, and fails
somewhere else for reasons no one can trace. This is precisely the failure the
limits design exists to prevent.

The spread is not small, but it is also not something the specification
enumerates for you. WebGPU defines *defaults* every adapter must meet —
128 MiB for `maxStorageBufferBindingSize`, 8 for
`maxStorageBuffersPerShaderStage` — and says nothing about device classes.
What a given adapter advertises above those is device-, driver- and
browser-dependent, and is deliberately reported in **tiers** to reduce
fingerprinting surface. So the only trustworthy range is one you measured on
the devices in your target matrix.

## Guidance

- **Decide what the application must have, then request exactly that.** The
  request is a specification of your requirements, not a wish list.
- **Fail loudly when a requirement is unavailable.** A rejected `requestDevice`
  with a named reason beats a device that silently cannot do the job.
- **Treat adapter limits as diagnostics, not as capacity.** Log them; do not
  plan against them.
- **Read the granted limits back and plan from those.** `GPUDevice.limits` is
  what validation enforces, and it is known only after acquisition.
- **Verify at the documented defaults.** Your packing must work at the WebGPU
  minimums, because some device will grant exactly those and nothing more.
- **Distinguish the limits that constrain different things.** Allocation size,
  bindable range, binding count, and offset alignment are separate constraints;
  satisfying one does not satisfy the others.
- **Check WebGL extensions before use and have a path without them.** An absent
  extension is a supported configuration, not an error.
- **Do not treat WebGPU as the baseline.** Godot's web export is WebGL 2.0 only;
  Unity's shipped Web target is WebGL-based. See `WASM.14`.

## Example

```cpp
// Bad: promote whatever this machine advertises into the requirement. It works
// on the development laptop and encodes its GPU into the contract. On a device
// that advertises less, either acquisition fails for no stated reason, or the
// code silently assumes capacity it was never granted.
//
//   WGPULimits advertised{};
//   wgpuAdapterGetLimits(adapter, &advertised);
//   required = advertised;                        // <- the mistake

// Good: state the requirement, request it, and let the request be the contract.
struct DeviceRequirements {
    std::uint64_t max_buffer_size;                 // largest single allocation
    std::uint64_t max_storage_binding_size;        // largest bindable range
    std::uint32_t max_storage_buffers_per_stage;   // bindings one shader needs
    const char* rationale;                         // why these numbers
};

// Derived from what the renderer actually does, not from what a GPU offers.
// Each number should be traceable to a structure in the application.
inline constexpr DeviceRequirements kRequirements{
    .max_buffer_size = 128u * 1024 * 1024,         // largest atlas we build
    .max_storage_binding_size = 128u * 1024 * 1024,// the WebGPU default
    .max_storage_buffers_per_stage = 8,            // the WebGPU default; this
                                                   // renderer binds 8 in total
    .rationale = "sized for the mobile floor; see packet NNN",
};

// The planner consumes GRANTED limits, never advertised ones. These are four
// separate constraints: a plan can satisfy allocation size and still be
// unbindable because it violated alignment or binding count.
class BufferPlanner {
public:
    struct Granted {
        std::uint64_t max_buffer_size;              // caps buffer creation
        std::uint64_t max_storage_binding_size;     // caps the bound range
        std::uint64_t min_storage_offset_alignment; // caps suballocated offsets
        std::uint32_t max_storage_buffers_per_stage;// caps bindings per shader
    };

    // Preconditions are checked, not assumed: alignment must be a non-zero
    // power of two, or align_up below is meaningless (I.5, ES.103).
    [[nodiscard]] static bool granted_is_usable(const Granted& g) noexcept {
        return g.min_storage_offset_alignment != 0
            && (g.min_storage_offset_alignment & (g.min_storage_offset_alignment - 1)) == 0
            && g.max_buffer_size != 0
            && g.max_storage_binding_size != 0
            && g.max_storage_buffers_per_stage != 0;
    }

    explicit BufferPlanner(Granted granted) noexcept : granted_(granted) {}

    // Returns nullopt rather than clamping. A silently clamped plan is a plan
    // that uploads correctly and then cannot be bound.
    [[nodiscard]] std::optional<Plan> plan(
            std::span<const Tensor> tensors) const noexcept {
        if (!granted_is_usable(granted_)) {
            return std::nullopt;
        }

        Plan plan;
        plan.buffers.emplace_back();      // never call back() on an empty vector
        std::uint64_t offset = 0;

        for (const Tensor& t : tensors) {
            // Reject before any arithmetic: a tensor that exceeds either ceiling
            // can never be placed, in this buffer or a fresh one.
            if (t.bytes > granted_.max_storage_binding_size ||
                t.bytes > granted_.max_buffer_size) {
                return std::nullopt;
            }

            const std::uint64_t aligned = align_up(offset, granted_.min_storage_offset_alignment);
            if (aligned == kAlignOverflow) {
                return std::nullopt;
            }

            // Subtract instead of adding, so the check cannot overflow. t.bytes
            // is already known to be <= max_buffer_size, so this is well formed.
            const bool fits_here = aligned <= granted_.max_buffer_size - t.bytes;
            if (!fits_here) {
                plan.buffers.emplace_back();   // start a new physical buffer
                offset = 0;
            }

            Buffer& current = plan.buffers.back();
            if (current.binding_count == granted_.max_storage_buffers_per_stage) {
                return std::nullopt;           // too many bindings for one shader
            }

            const std::uint64_t place_at =
                fits_here ? aligned : 0;       // a fresh buffer starts at zero
            current.place(t, place_at);
            offset = place_at + t.bytes;       // <= max_buffer_size, so no wrap
        }
        return plan;
    }

private:
    static constexpr std::uint64_t kAlignOverflow = ~std::uint64_t{0};

    // Reports overflow rather than wrapping. `a` is a non-zero power of two,
    // checked by granted_is_usable above.
    [[nodiscard]] static constexpr std::uint64_t align_up(std::uint64_t v,
                                                          std::uint64_t a) noexcept {
        const std::uint64_t mask = a - 1;
        if (v > (~std::uint64_t{0}) - mask) {
            return kAlignOverflow;
        }
        return (v + mask) & ~mask;
    }

    Granted granted_;
};

// A test at the documented default is not optional. Some device grants exactly
// these, and it will not be the one on your desk.
static_assert(kRequirements.max_storage_binding_size <= 128u * 1024 * 1024,
              "requirements must be satisfiable at the WebGPU default limits");

## Caveats

- **Requesting less than you need fails later and worse.** This is not an
  argument for minimalism — it is an argument for accuracy.
- **A declared floor is a product decision.** Requiring more than the spec
  minimum means some devices cannot run the application at all. That may be
  right; it must be stated.
- **Tiered reporting means advertised values are quantized.** Two machines with
  different GPUs may report identically; thorough testing across real devices is
  the only reliable check.
- **Limits are not the only capability axis.** Optional features, texture format
  support, and shader features negotiate separately.
- **WebGL's model is looser.** Extensions are queried rather than requested, so
  the discipline has to come from your code — there is no rejection to catch a
  missing requirement.

## References

- [W3C — WebGPU](https://www.w3.org/TR/webgpu/)
- [MDN — GPUAdapter.limits](https://developer.mozilla.org/en-US/docs/Web/API/GPUAdapter/limits)
- [WebGPU Fundamentals — Optional features and limits](https://webgpufundamentals.org/webgpu/lessons/webgpu-limits-and-features.html)
- [Chrome for Developers — From WebGL to WebGPU](https://developer.chrome.com/docs/web-platform/webgpu/from-webgl-to-webgpu)
- [MDN — WebGL best practices](https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API/WebGL_best_practices)
- Cross-reference: `GPU.9` (suballocating transient GPU memory), `WASM.14`
  (target matrix), `WASM.1` (the heap the staging copy lands in).
