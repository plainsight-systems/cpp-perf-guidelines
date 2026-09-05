+++
id = "WASM.5"
title = "Decide cross-origin isolation on reach and embedding, then design threading to match"
category = "wasm"
status = "draft"
summary = "Threads need SharedArrayBuffer, which needs COOP/COEP; the headers are routine to set, but isolation blocks cross-origin embedding, so the decision is commercial."
tags = ["threads", "sharedarraybuffer", "cross-origin-isolation", "coop-coep", "pthreads"]
+++

## Rationale

WebAssembly threads require `SharedArrayBuffer`, which requires the page to be
cross-origin isolated: `Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp`.

**Setting those headers is ordinary server configuration** wherever you control
the server, and the migration path is well documented: enable COOP, give
cross-origin subresources a `Cross-Origin-Resource-Policy` header or the
`crossorigin` attribute, roll out behind `Cross-Origin-Embedder-Policy-Report-Only`
to find breakage without causing it, then enforce.

The real cost is not turning it on — it is **what isolation forbids**.
Cross-origin subresources that have not opted in stop loading. Godot made
single-threaded the default for its web export in 4.3 on exactly this basis:
isolation removes the capacity to make remote calls to other websites, which
takes out game monetization and third-party API integration. Adobe went the
other way for Photoshop, working through the W3C to bring dynamic multithreading
to WebAssembly, because an application behind a login has no ad network to
protect.

Both decisions are correct for their product. What is not correct is inheriting
either default without deciding.

## Guidance

- **Decide isolation before designing the concurrency model.** It determines
  whether threads exist at all, and retrofitting either direction is expensive.
- **Price it as reach and revenue, not as difficulty.** The question is what the
  page must embed and who must be able to load it.
- **Do not assume the headers are unavailable.** Most hosting sets them; some
  game portals expose an explicit SharedArrayBuffer toggle. Test before
  concluding.
- **Where headers genuinely cannot be set**, they are also honored via a service
  worker (the `coi-serviceworker` approach). Its constraints are real: a separate
  file served from your own origin rather than a CDN, HTTPS or localhost, and a
  reload on first visit.
- **Pre-create workers with `-sPTHREAD_POOL_SIZE`.** `pthread_create` only takes
  effect after returning to the event loop, so an on-demand thread is not
  running when POSIX says it is.
- **Never block the main browser thread.** `Atomics.wait` is prohibited there;
  `pthread_join` and `pthread_cond_wait` busy-wait or deadlock against a proxied
  call. Use `-sPROXY_TO_PTHREAD` to move `main()` off it.
- **Replace `dlmalloc` under threads.** The default allocator has one global
  lock; `-sMALLOC=mimalloc` gives thread-local contexts at a size and memory cost.
- **A plain Web Worker needs no isolation.** Moving work off the main thread for
  responsiveness is available unconditionally; only *shared memory* needs headers.

## Example

```cpp
// State the decision in the build, where it cannot drift. A comment on the link
// options is the cheapest place to record why a whole concurrency model was
// ruled in or out.
//
//   # Threaded: requires COOP/COEP on the serving origin. We control the
//   # origin and embed no third-party resources, so isolation costs nothing.
//   target_link_options(app PRIVATE -pthread -sPTHREAD_POOL_SIZE=4
//                                   -sPROXY_TO_PTHREAD -sMALLOC=mimalloc)
//
//   # Single-threaded: deliberately not -pthread. The page embeds a
//   # third-party ad SDK that has no CORP header, so isolation would break
//   # monetisation. Revisit if that dependency goes away.

// Design the work so the answer is a configuration, not a rewrite. Split the
// decomposition from the execution, and the same kernel serves both worlds.
struct WorkRange {
    std::size_t begin;
    std::size_t end;
};

// Pure, single-threaded, natively testable. Nothing here knows about threads.
void shade_range(std::span<Pixel> pixels, WorkRange range) noexcept;

// Sequential executor: always available, no headers required.
class InlineExecutor {
public:
    void run(std::span<Pixel> pixels, std::span<const WorkRange> ranges) {
        for (const WorkRange& r : ranges) {
            shade_range(pixels, r);
        }
    }
};

#if defined(__EMSCRIPTEN_PTHREADS__)
// Parallel executor: compiled only when the toolchain actually has threads.
// The macro is the honest gate -- if the build did not ask for -pthread, this
// code does not exist, rather than existing and silently running sequentially.
class PoolExecutor {
public:
    // The pool is sized at construction and reused. Creating a thread per
    // batch would not start until the next event-loop turn.
    explicit PoolExecutor(unsigned threads);

    void run(std::span<Pixel> pixels, std::span<const WorkRange> ranges);
};
#endif

// Note what this deliberately does NOT do: provide a PoolExecutor that falls
// back to running inline when threads are unavailable. That would let calling
// code claim parallelism it does not have -- the caller must see the difference
// so it can size its work accordingly.

// Record the decision as data so it can be asserted in a test and reported on
// the page, rather than being folklore in a build script.
struct ConcurrencyPolicy {
    bool cross_origin_isolated;      // measured at runtime, not assumed
    bool shared_memory_available;    // implies the headers actually landed
    unsigned worker_count;           // 0 == single-threaded by design
    const char* rationale;           // "third-party ad SDK lacks CORP"
};
```

## Caveats

- **Isolation also buys a finer clock.** The same headers raise
  `performance.now()` resolution from 100 µs to 5 µs, so a non-isolated build is
  also a harder build to measure (`WASM.11`).
- **A measurement rig can isolate even when the shipping page does not.** These
  are separate deployments; do not let the product decision constrain the lab.
- **Single-threaded is not free.** Godot found it introduced audio glitching at
  both ends of the hardware range, which needed sample-based playback to fix.
- **Portal toggles carry their own support matrix.** itch.io's SharedArrayBuffer
  support is described as experimental and depends on a feature unsupported by
  Safari and Firefox for Android.
- **Isolation can fix unrelated things.** Godot found long-standing macOS and
  iOS problems with their web exports disappeared under single-threaded export —
  evidence that the threaded path has its own portability surface.
- **`credentialless` COEP relaxes the CORP requirement** by stripping credentials
  from cross-origin loads, which may recover some third-party resources.

## References

- [web.dev — Making your website "cross-origin isolated" using COOP and COEP](https://web.dev/articles/coop-coep)
- [Godot — Progress report: web export in 4.3](https://godotengine.org/article/progress-report-web-export-in-4-3/)
- [Godot — Exporting for the Web](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)
- [Chrome/Adobe — Photoshop's journey to the web](https://web.dev/articles/ps-on-the-web)
- [Emscripten — Pthreads support](https://emscripten.org/docs/porting/pthreads.html)
- [gzuidhof — coi-serviceworker](https://github.com/gzuidhof/coi-serviceworker)
- Cross-reference: `WASM.3` (blocking and the main thread), `WASM.11` (the clock
  the same headers govern), `CACHE.1` (padding shared fields against false sharing).
