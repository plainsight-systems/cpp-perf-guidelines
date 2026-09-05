+++
id = "WASM.2"
title = "Batch work across the JS boundary; every crossing is validation plus an FFI transition"
category = "wasm"
status = "draft"
summary = "Calls out of WASM pay a foreign-function transition and, for web APIs, argument validation; move a phase per crossing and pass pointer-length pairs, not objects."
tags = ["ffi", "javascript-boundary", "draw-calls", "webgl", "marshalling"]
+++

## Rationale

WebAssembly cannot hold a reference to a JavaScript object. Anything structured
that crosses the boundary is encoded into linear memory and decoded on the far
side: strings pay UTF-8 conversion, arrays of objects pay allocation and copying.

Engine-level call overhead has fallen — V8 inlines the JS-to-Wasm wrapper at the
call site — but the graphics API is *on the far side of that boundary*, and this
is where the cost concentrates. Every WebGL call pays twice: the browser must
validate it, because native OpenGL provides none of the security guarantees the
web requires, and the call itself is an FFI transition between WASM and the
browser's native code.

The practical consequence is that **draw-call count is a first-order cost in the
browser in a way it is not natively**, for reasons that have nothing to do with
the GPU. Unity states it plainly: GPU rendering is close to native, but the CPU
side dispatch of WebGL operations is slower than native OpenGL.

## Guidance

- **Move a phase per crossing, not an item.** One call that processes 10,000
  elements beats 10,000 calls that process one.
- **Pass `(pointer, length)` into linear memory.** Let the module own the bytes;
  do not marshal structured objects per call.
- **Never query GL state at render time.** `glGetError()`,
  `glCheckFramebufferStatus()` and `glGet*()` force a round trip. Cache uniform
  locations at startup.
- **Never create or destroy GL resources during rendering.** `glGen*`,
  `glCreate*` and `glDelete*` belong in load phases; deletion can force a
  pipeline flush. `glCompileShader` and `glLinkProgram` can be very slow.
- **Batch uniform uploads.** Prefer one `glUniform4fv` over repeated
  `glUniform4f`; use uniform buffer objects and vertex array objects on WebGL 2.
- **Change GL state lazily.** Do not reset to a known baseline after each draw —
  that doubles the call count to buy tidiness.
- **Avoid the emulation layers.** `-sFULL_ES2` / `-sFULL_ES3` emulate
  client-side memory and are documented as slow, as is `-sLEGACY_GL_EMULATION`.
- **Compile the module once and share it.** `postMessage` a
  `WebAssembly.Module` to workers rather than compiling per worker.

## Example

```cpp
// Bad: the boundary is crossed once per particle, and each crossing carries
// a uniform upload and a draw. At 2,000 particles this is 4,000 validated
// FFI transitions per frame before any pixel is shaded.
void draw_particles_bad(std::span<const Particle> particles) {
    for (const Particle& p : particles) {
        glUniform4f(u_offset_, p.x, p.y, p.z, p.scale);   // crossing
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);            // crossing
    }
}

// Good: build the whole frame's instance data in linear memory, upload it in
// one call, and issue one instanced draw. Two crossings, independent of
// particle count.
class ParticleBatch {
public:
    void begin(std::size_t count) {
        instances_.clear();
        instances_.reserve(count);   // no reallocation mid-frame (WASM.1)
    }

    void add(const Particle& p) {
        instances_.push_back(Instance{p.x, p.y, p.z, p.scale});
    }

    void flush() {
        if (instances_.empty()) {
            return;                  // do not pay two crossings for nothing
        }
        // One transition: the whole buffer as a pointer-length pair. glBufferData
        // reads straight out of linear memory; nothing is marshalled per item.
        glBufferSubData(GL_ARRAY_BUFFER, 0,
                        static_cast<GLsizeiptr>(instances_.size() * sizeof(Instance)),
                        instances_.data());
        // One transition: every particle drawn from the buffer just uploaded.
        glDrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4,
                              static_cast<GLsizei>(instances_.size()));
    }

private:
    struct Instance { float x, y, z, scale; };
    std::vector<Instance> instances_;
};

// Uniform locations are queried once, at load. Querying inside the frame turns
// a compile-time constant into a per-frame round trip through the browser.
class ShaderProgram {
public:
    void bind_locations() {           // called once, during load
        u_view_proj_ = glGetUniformLocation(program_, "u_viewProj");
        u_time_      = glGetUniformLocation(program_, "u_time");
    }
private:
    GLuint program_{0};
    GLint u_view_proj_{-1};
    GLint u_time_{-1};
};

// Review test: a crossing whose count scales with scene content needs a
// written reason. Acceptable: "once per material batch, 12 per frame."
// Suspicious: "once per visible object."
struct BoundaryBudget {
    const char* phase;             // "upload instances", "submit draws"
    int crossings_per_frame;       // must be bounded, not content-proportional
    bool scales_with_scene;        // if true, this is the thing to fix
};
```

## Caveats

- **The cost is per crossing, not per byte.** One large upload is usually right,
  but an upload larger than the frame needs wastes bandwidth. Batch to the
  frame's working set, not to everything.
- **Batching changes error attribution.** When 2,000 particles fail as one draw,
  the failure names the batch. Keep a diagnostic path that submits individually,
  compiled out of the shipped module.
- **Instancing has its own floor.** For a handful of objects, the setup can cost
  more than the draws it replaces. Measure at realistic counts.
- **This is not a licence to defer everything.** Accumulating a frame's work to
  submit at the end can add a frame of latency; see `GPU.7`.
- **WebGPU reduces but does not remove the seam.** Command encoding batches
  naturally, which helps — the transition and validation still exist.

## References

- [Emscripten — Optimizing WebGL](https://emscripten.org/docs/optimizing/Optimizing-WebGL.html)
- [Unity — Web performance considerations](https://docs.unity3d.com/6000.4/Documentation/Manual/webgl-performance.html)
- [MDN — WebGL best practices](https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API/WebGL_best_practices)
- [web.dev — WebAssembly performance patterns for web apps](https://web.dev/articles/webassembly-performance-patterns-for-web-apps)
- [V8 — Speculative optimizations for WebAssembly](https://v8.dev/blog/wasm-speculative-optimizations)
- Cross-reference: `WASM.3` (the loop that issues these calls), `GPU.6`
  (batching tiny GPU work), `GPU.7` (CPU/GPU pipelining).
