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

The spread is not small. `maxStorageBufferBindingSize` is documented at a 128 MB
floor on mobile and up to 4 GB on desktop — a 32× range across devices one build
must serve. Browsers additionally report **tiered** values to reduce
fingerprinting surface, so the advertised numbers are quantized and vary by
browser.

## Guidance

- **Decide what the application must have, then request exactly that.** The
  request is a specification of your requirements, not a wish list.
- **Fail loudly when a requirement is unavailable.** A rejected `requestDevice`
  with a named reason beats a device that silently cannot do the job.
- **Treat adapter limits as diagnostics, not as capacity.** Log them; do not
  plan against them.
- **Read the granted limits back and plan from those.** `GPUDevice.limits` is
  what validation enforces, and it is known only after acquisition.
- **Verify at the spec floor.** Your packing must work at the documented
  minimums, because some device will grant exactly those.
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
    .max_storage_binding_size = 128u * 1024 * 1024,// spec floor: we fit in it
    .max_storage_buffers_per_stage = 8,            // spec floor: 4 in, 4 out
    .rationale = "sized for the mobile floor; see packet NNN",
};

// The planner consumes GRANTED limits, never advertised ones. Note that these
// are four separate constraints: a plan can satisfy allocation size and still
// be unbindable because it violated alignment or binding count.
class BufferPlanner {
public:
    struct Granted {
        std::uint64_t max_buffer_size;             // caps buffer creation
        std::uint64_t max_storage_binding_size;    // caps the bound range
        std::uint64_t min_storage_offset_alignment;// caps suballocated offsets
        std::uint32_t max_storage_buffers_per_stage;// caps bindings per shader
    };

    explicit BufferPlanner(Granted granted) noexcept : granted_(granted) {}

    // Returns nullopt rather than clamping. A silently clamped plan is a plan
    // that uploads correctly and cannot be bound.
    [[nodiscard]] std::optional<Plan> plan(
            std::span<const Tensor> tensors) const noexcept {
        std::uint64_t offset = 0;
        Plan plan;

        for (const Tensor& t : tensors) {
            // A suballocated binding must start on an aligned boundary, so the
            // padding is part of the budget, not a surprise at bind time.
            offset = align_up(offset, granted_.min_storage_offset_alignment);

            if (t.bytes > granted_.max_storage_binding_size) {
                return std::nullopt;               // will never be bindable
            }
            if (offset + t.bytes > granted_.max_buffer_size) {
                offset = 0;                        // start a new physical buffer
                plan.buffers.push_back(Buffer{});
            }
            if (plan.buffers.back().binding_count + 1 >
                granted_.max_storage_buffers_per_stage) {
                return std::nullopt;               // too many bindings per shader
            }

            plan.buffers.back().place(t, offset);
            offset += t.bytes;
        }
        return plan;
    }

private:
    static constexpr std::uint64_t align_up(std::uint64_t v, std::uint64_t a) noexcept {
        return (v + a - 1) / a * a;
    }
    Granted granted_;
};

// A test at the spec floor is not optional. Some device grants exactly this,
// and it will not be the one on your desk.
static_assert(kRequirements.max_storage_binding_size <= 128u * 1024 * 1024,
              "requirements must be satisfiable at the documented floor");
```

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
