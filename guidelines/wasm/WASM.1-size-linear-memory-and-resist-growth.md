+++
id = "WASM.1"
title = "Size linear memory to the real high-water mark and resist growing it"
category = "wasm"
status = "draft"
summary = "The WASM heap is one contiguous host allocation; growing it needs both heaps resident at once and detaches every JS view, so size it up front and keep it small."
tags = ["linear-memory", "heap-growth", "wasm32", "memory64", "arraybuffer"]
+++

## Rationale

A WebAssembly linear memory is a single **contiguous** allocation in the host
process. On wasm32 it is capped at 65,536 pages of 64 KiB — 4 GiB — because
pointers are 32 bits.

Growing it is not a `realloc` that usually succeeds. `WebAssembly.Memory.grow`
**detaches** the backing `ArrayBuffer`: every JavaScript typed-array view over
the heap is invalidated and must be recreated, and the engine may copy the old
contents into the new allocation. During that copy **both** allocations are
resident, so the moment you grow is the moment of peak memory pressure — the
opposite of what the caller intended. Host address-space fragmentation can
defeat the new allocation even when total free memory is ample.

This inverts the native instinct. Natively you reserve generously and commit
lazily; `MEM.7`'s reserve-and-commit strategy depends on a large address space
that wasm32 does not have. Here you size to the measured high-water mark and
stream everything that does not fit.

## Guidance

- **Set an explicit initial size.** Use `-sINITIAL_MEMORY` set to the
  application's measured peak, not a round number chosen for comfort.
- **Treat `-sALLOW_MEMORY_GROWTH=1` as a fallback, not a default.** It converts
  a deterministic out-of-memory at startup into a nondeterministic one under
  load, at the least predictable moment.
- **Cap growth where you do allow it.** `-sMAXIMUM_MEMORY` bounds the damage and
  makes the failure reproducible.
- **Never hold a JS typed-array view across a call that can grow the heap.**
  Re-derive `HEAPU8` and friends after every such call; a stale view is a
  use-after-detach, not a stale read.
- **Budget the memory that is not in the heap.** Decompressed asset blobs,
  download buffers, audio buffers, and the module's own code all consume host
  memory and are invisible to an in-heap allocator profile.
- **Reach for memory64 only when you need more than 4 GiB.** It buys address
  space and costs the engine optimizations that assume 32-bit pointers.
- **Size for the weakest target device, not the development machine** — see
  `WASM.14`.

## Example

```cpp
// The failure this guideline prevents. `process()` can grow the heap, which
// detaches the ArrayBuffer that `view` was created over. On the JS side the
// old view still exists and reads zeroes (or throws) forever after.
//
//   const view = new Uint8Array(Module.HEAPU8.buffer, ptr, len);  // BAD
//   Module._process();          // may grow -> detaches `view`
//   view[0];                    // reads a detached buffer
//
// The C++ side cannot see this happen. The contract must therefore be that
// the module hands out a (pointer, length) pair per call and the caller
// re-derives its view each time.

// Instead of growing on demand, pre-size a fixed pool at startup and fail
// loudly if it does not fit. Failure at init is diagnosable; failure at
// frame 40,000 is not.
class FixedHeapPool {
public:
    // Contract: throws on construction if the budget is unavailable. There is
    // no degraded mode -- a pool that silently shrinks would let the caller
    // believe it had capacity it does not have.
    explicit FixedHeapPool(std::size_t bytes)
        : storage_(static_cast<std::byte*>(std::malloc(bytes))), capacity_(bytes) {
        if (storage_ == nullptr) {
            throw std::bad_alloc{};   // at init, with a known budget in hand
        }
    }

    ~FixedHeapPool() { std::free(storage_); }

    FixedHeapPool(const FixedHeapPool&) = delete;
    FixedHeapPool& operator=(const FixedHeapPool&) = delete;

    // Returns nullptr rather than growing. The caller decides what to shed.
    [[nodiscard]] std::byte* allocate(std::size_t bytes, std::size_t align) noexcept {
        const std::size_t base = (used_ + align - 1) & ~(align - 1);
        if (base + bytes > capacity_) {
            return nullptr;
        }
        used_ = base + bytes;
        return storage_ + base;
    }

    void reset() noexcept { used_ = 0; }

    [[nodiscard]] std::size_t high_water() const noexcept { return used_; }

private:
    std::byte* storage_;
    std::size_t capacity_;
    std::size_t used_{0};
};

// Report the high-water mark from a diagnostic build so -sINITIAL_MEMORY can
// be set from evidence rather than guessed. Compile this out of the shipped
// module; see the telemetry category.
struct HeapBudget {
    std::size_t initial_memory_bytes;   // what the link line asked for
    std::size_t observed_peak_bytes;    // what a real session actually used
    bool growth_enabled;                // if true, say why in the packet
};
```

## Caveats

- **A hard cap is a product decision.** Refusing to grow means some inputs will
  not load. That is often correct on the web, but it must be stated, not
  discovered by a user.
- **Emscripten's growth handling is correct** — it recreates the JS views for
  you. The hazard is views that *application* JavaScript captured and held.
- **Streaming has its own cost.** Chunked processing adds bookkeeping and can
  hurt locality. It wins here because the alternative is not availability but
  failure.
- **Engines differ on the practical ceiling.** The 4 GiB figure is the wasm32
  architectural limit; a browser on a phone will reclaim the tab long before
  that, and the usable budget is far smaller.

## References

- [WebAssembly memory64 proposal](https://github.com/WebAssembly/spec/blob/wasm-3.0/proposals/memory64/Overview.md)
- [Emscripten — Compiler Settings reference](https://emscripten.org/docs/tools_reference/settings_reference.html)
- [Unity — Memory in Unity Web](https://docs.unity3d.com/Manual/webgl-memory.html)
- [Unity — Understanding memory in Unity WebGL](https://unity.com/blog/engine-platform/understanding-memory-in-unity-webgl)
- [Kongregate — Unity WebGL memory optimization](https://blog.kongregate.com/unity-webgl-memory-optimization-part-deux/)
- Cross-reference: `MEM.7` (reserve-and-commit — unavailable on wasm32),
  `WASM.9` (asset streaming), `WASM.14` (device budget), `MEM.9`
  (allocate at init, not in steady state).
