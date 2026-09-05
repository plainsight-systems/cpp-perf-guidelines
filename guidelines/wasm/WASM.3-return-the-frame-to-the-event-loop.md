+++
id = "WASM.3"
title = "Return each frame to the event loop; do not buy Asyncify to keep a blocking loop"
category = "wasm"
status = "draft"
summary = "The browser is cooperatively scheduled, so a blocking main loop hangs the page and never presents; restructuring costs once, Asyncify costs about 50% forever."
tags = ["main-loop", "asyncify", "jspi", "event-loop", "emscripten"]
+++

## Rationale

The browser runs on cooperative multitasking: each turn of the event loop must
return control before anything else — input, rendering, network completion — can
run. A C++ program written as `while (true) { frame(); }` never returns, so the
page hangs and the browser eventually offers to kill it. WebGL only presents
when control returns to the event loop, so a blocking loop does not merely stall
the page; it renders nothing at all.

There are two ways out, and they are not equivalent.

**Invert the loop.** Hoist the loop body into a function the browser calls once
per frame, via `emscripten_set_main_loop()` or
`emscripten_request_animation_frame_loop()`. Emscripten documents these as
carrying no size or speed overhead. The cost is a one-time restructuring: state
that lived in loop locals must move into an explicit frame context.

**Or instrument the whole module so it can unwind and rewind.** That is
Asyncify, and Emscripten's own documentation puts the overhead at roughly half
again, in *both* code size and speed — a permanent tax on the entire module,
paid to avoid a one-time refactor. `-O3` becomes close to mandatory because unoptimized Asyncify
builds are very large.

## Guidance

- **Restructure the loop; treat Asyncify as a porting crutch with a price tag.**
  A permanent overhead of roughly 50% to avoid a bounded refactor is rarely the
  right trade.
- **Make frame-persistent state explicit.** Anything that was a loop local and
  must survive to the next frame belongs in a frame context object, not a
  function-local or a global.
- **Prefer `emscripten_request_animation_frame_loop()`** when the loop is
  display-driven; it follows the browser's presentation cadence.
- **Pass `0` as the fps argument** to `emscripten_set_main_loop` to use
  `requestAnimationFrame` rather than a fixed timer.
- **Know which `simulate_infinite_loop` mode you asked for.** With `false` the
  call returns normally, the caller's stack unwinds, and code after the call
  runs before the first frame — so stack objects the loop needs are already
  destroyed. With `true` the call throws to stop the caller, and the stack is
  not unwound. Neither mode runs global destructors or `atexit` handlers, since
  the loop is still live.
- **Where async really is unavoidable, prefer JSPI over Asyncify.** `-sJSPI`
  keeps code size flat, at the cost of declaring boundaries explicitly through
  `JSPI_IMPORTS` and `JSPI_EXPORTS`, which Asyncify infers.
- **Never block on the main thread.** `Atomics.wait` is prohibited there, so
  `pthread_join` and `pthread_cond_wait` would busy-wait or deadlock; see
  `WASM.5`.

## Example

```cpp
// The native shape. Correct everywhere except a browser, where it hangs the
// tab and presents nothing, because control never returns to the event loop.
void run_native() {
    Renderer renderer;
    World world;
    double previous = now_seconds();

    while (!world.should_quit()) {          // never returns under wasm
        const double current = now_seconds();
        world.step(current - previous);     // `previous` is a loop local
        renderer.draw(world);
        previous = current;
    }
}

// The browser shape. The loop body becomes a function; everything that used to
// live in loop locals moves into a context that outlives the call.
struct FrameContext {
    Renderer renderer;
    World world;
    double previous_seconds;                // was a loop local above
};

// The loop outlives every scope in this file, so something must own the context
// for that whole time. An owning registry keeps that explicit: no raw `new`, no
// `delete` in a callback (R.11), and the callback's pointer is plainly
// non-owning (R.3).
class MainLoop {
public:
    // The callback receives a NON-owning pointer. Ownership stays here.
    static void start(std::unique_ptr<FrameContext> ctx) {
        instance() = std::move(ctx);
        // fps = 0 selects requestAnimationFrame, which follows the display
        // rather than a fixed timer. simulate_infinite_loop = 0 means this call
        // returns and the caller's stack unwinds -- which is why the context
        // could not have lived on that stack.
        emscripten_set_main_loop_arg(&MainLoop::step, instance().get(),
                                     /*fps=*/0, /*simulate_infinite_loop=*/0);
    }

    static void stop() noexcept {
        emscripten_cancel_main_loop();
        instance().reset();                 // RAII, not `delete &ctx`
    }

private:
    static std::unique_ptr<FrameContext>& instance() noexcept {
        static std::unique_ptr<FrameContext> ctx;
        return ctx;
    }

    // Called once per frame by the browser. Returning is what lets the page
    // render, handle input and stay responsive -- it is the point, not an
    // inconvenience.
    static void step(void* user_data) {
        auto& ctx = *static_cast<FrameContext*>(user_data);   // non-owning view

        const double current = emscripten_get_now() / 1000.0;
        ctx.world.step(current - ctx.previous_seconds);
        ctx.renderer.draw(ctx.world);
        ctx.previous_seconds = current;

        if (ctx.world.should_quit()) {
            stop();
        }
    }
};

void run_browser() {
    MainLoop::start(std::make_unique<FrameContext>(
        Renderer{}, World{}, emscripten_get_now() / 1000.0));
    // Execution reaches here: with simulate_infinite_loop = 0 the call returned.
    // Anything below runs BEFORE the first frame, not after the last.
}

// What Asyncify would have bought instead: the original loop, unchanged, with
// a yield inserted. It compiles and it works -- and it instruments every
// function that could reach the sleep, inflating the whole module.
//
//   while (!world.should_quit()) {
//       world.step(dt);
//       renderer.draw(world);
//       emscripten_sleep(0);          // -sASYNCIFY: ~50% size and speed
//   }
//
// Record the decision if you take it. "We shipped Asyncify because the port
// deadline was fixed" is an honest reason; "it was easier" is a cost nobody
// signed off.
```

## Caveats

- **The two loop modes have different ownership stories.** With
  `simulate_infinite_loop = 0` the stack unwinds, so frame state must be owned
  somewhere that survives the call. With `1` the stack is not unwound, but the
  caller is stopped by a thrown exception — which is unavailable if the build
  disables exceptions.
- **Asyncify is the right answer for some ports.** A large legacy codebase with
  blocking I/O threaded through hundreds of call sites may not be refactorable
  on any realistic schedule. The rule is to price it, not to ban it.
- **JSPI requires explicit boundary declarations.** Missing one produces a
  runtime failure rather than a compile error, so the migration needs testing
  that exercises every async path.
- **Background tabs are throttled.** Browsers drop hidden tabs to roughly one
  update per second, so a frame delta can be enormous. Clamp it, or a physics
  step will explode on tab return.
- **`emscripten_get_now()` is a browser clock** with the resolution limits in
  `WASM.11`. Do not use it to time sub-millisecond work.

## References

- [Emscripten — Emscripten Runtime Environment](https://emscripten.org/docs/porting/emscripten-runtime-environment.html)
- [Emscripten — Asynchronous Code (Asyncify and JSPI)](https://emscripten.org/docs/porting/asyncify.html)
- [Emscripten — Compiler Settings reference](https://emscripten.org/docs/tools_reference/settings_reference.html)
- [Godot — Exporting for the Web](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)
- Cross-reference: `WASM.2` (what the frame body should not do), `WASM.5`
  (blocking and the main thread), `WASM.11` (the clock this example uses).
