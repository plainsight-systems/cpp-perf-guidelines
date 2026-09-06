+++
id = "WASM.8"
title = "Treat the module as a shipped artifact: its size is startup latency"
category = "wasm"
status = "draft"
summary = "Module bytes are downloaded and compiled on every cold load, so code size is a latency lever rather than only a footprint one; budget it and enforce the budget in CI."
tags = ["code-size", "lto", "closure", "exceptions", "rtti", "emscripten"]
+++

## Rationale

On a native target, code size mostly costs disk and instruction cache. On the
web it also costs **time on every cold load**, because the module is downloaded
and compiled before anything runs. That reframes a set of familiar decisions:
`-Oz` versus `-O3`, exceptions and RTTI, template instantiation depth, and
dead-code elimination are all latency levers here.

The `embedded` category already covers the cost of exceptions and RTTI in
constrained environments. Two things differ on the web. First, the pressure is
on delivery rather than on a fixed flash budget. Second, the old advice to
disable exceptions outright has genuinely softened: `-fwasm-exceptions` uses
native WebAssembly exception handling with one-phase unwinding, which is smaller
and faster than the legacy JavaScript-based scheme, and Unity now reports the
overhead of exception support as minor under the WebAssembly 2023 feature set.

Code size also feeds back into `WASM.4`: WebAssembly's safety checks inflate
instruction count 1.75–1.80× over native, and that inflation shows up as a
2–2.8× increase in L1 instruction-cache misses. Size is not only a download
cost; it is a runtime cost through the i-cache.

## Guidance

- **Set a byte budget and enforce it in CI.** A size regression that arrives
  gradually is never attributable afterwards.
- **Measure the delivered bytes, not the build output.** What matters is the
  compressed transfer size of the `.wasm` *and* its JavaScript support file.
- **Build and link with `-flto`.** Cross-translation-unit inlining removes code
  as well as adding it, and enables devirtualisation (`GEN.4`).
- **Run `--closure 1` on the support JavaScript.** The glue is often a large
  share of delivered bytes and compresses poorly without it.
- **Strip what the platform does not need:** `-sFILESYSTEM=0` when you do not
  use the virtual filesystem, `-sENVIRONMENT=web,worker` to drop Node paths.
- **Choose the allocator deliberately.** `-sMALLOC=emmalloc` is smaller and
  slower; the default is faster and larger. This is a real trade, not a default
  to inherit.
- **Prefer `-fwasm-exceptions` to disabling exceptions** unless the code is
  already exception-free. Blanket `-fno-exceptions` on a codebase that uses them
  is a correctness change, not a size optimisation.
- **Compare `-O3`, `-Os` and `-Oz` on the real module.** The right answer depends
  on how compute-bound the workload is; do not assume `-O3`.
- **Watch template instantiation.** A container instantiated over twenty types is
  twenty copies of its code in the download.

## Example

```cpp
// Size is a contract, so state it where CI can check it. A budget in a comment
// is a wish; a budget in a test is a control.
//
//   # tools/check_size.sh
//   BROTLI_WASM=$(brotli -c build/app.wasm | wc -c)
//   BROTLI_JS=$(brotli -c build/app.mjs | wc -c)
//   TOTAL=$((BROTLI_WASM + BROTLI_JS))
//   # Budget agreed in packet NNN: 2.5 MiB compressed, both files.
//   # Raising it requires a packet, not a commit.
//   [ "$TOTAL" -le 2621440 ] || { echo "size budget exceeded: $TOTAL"; exit 1; }

// Template instantiation is a download cost. This header-only helper looks
// free and is not: every distinct T emits another copy of the whole body into
// the module.
template <typename T>
class Registry {
public:
    void add(T value);              // instantiated per T, in full
    void remove(const T& value);
    [[nodiscard]] bool contains(const T& value) const;
private:
    std::vector<T> entries_;
};

// Type-erase the body so the per-type code is a thin wrapper over one shared
// implementation. The bytes stop scaling with the number of instantiations.
class RegistryBase {
protected:
    // A span of bytes rather than (void*, size): type erasure without giving up
    // the size, and no unverified cast at the call site (I.4, R.14).
    void add_bytes(std::span<const std::byte> value);
    void remove_bytes(std::span<const std::byte> value);
    [[nodiscard]] bool contains_bytes(std::span<const std::byte> value) const;
private:
    std::vector<std::byte> storage_;    // one implementation, shared
};

template <typename T>
class SmallRegistry : private RegistryBase {
    static_assert(std::is_trivially_copyable_v<T>,
                  "byte-wise storage requires trivial copyability");
public:
    // Each of these is a few instructions that forward to the shared body,
    // rather than a full copy of the container's logic.
    void add(const T& value) { add_bytes(as_bytes(value)); }
    void remove(const T& value) { remove_bytes(as_bytes(value)); }
    [[nodiscard]] bool contains(const T& value) const {
        return contains_bytes(as_bytes(value));
    }

private:
    [[nodiscard]] static std::span<const std::byte> as_bytes(const T& value) noexcept {
        return std::as_bytes(std::span<const T, 1>{&value, 1});
    }
};

// Report the size decisions as data, so a reviewer sees what was traded and
// a regression can be attributed to a decision rather than to "the build".
struct SizeBudget {
    std::size_t wasm_compressed_bytes;
    std::size_t js_glue_compressed_bytes;
    std::string_view optimisation_level;  // "-Oz", "-O3"
    bool lto_enabled;
    bool closure_enabled;
    std::string_view exception_mode;      // "-fwasm-exceptions", "-fno-exceptions"
};
```

## Caveats

- **`-Oz` can cost more than it saves.** For a compute-bound module, a smaller
  binary that runs slower is a bad trade past first frame. Measure both.
- **`-fno-exceptions` is a semantic change.** It is not a size flag on a codebase
  that throws; it changes what happens on failure.
- **Aggressive size reduction fights `WASM.4`.** Disabling inlining shrinks the
  module and can reintroduce the indirect calls you were trying to remove.
- **Closure compiler can break hand-written glue.** It renames aggressively;
  externs must be declared or the failure appears only in the minified build.
- **Compressed size is what ships, uncompressed size is what compiles.** They
  move differently — the download cost follows the former, compilation the
  latter.
- **A budget with no owner erodes.** Someone must be accountable for raising it,
  or it becomes a rubber stamp.

## References

- [Emscripten — Optimizing Code](https://emscripten.org/docs/optimizing/Optimizing-Code.html)
- [Emscripten — Compiler Settings reference](https://emscripten.org/docs/tools_reference/settings_reference.html)
- [Unity — Web performance considerations](https://docs.unity3d.com/6000.4/Documentation/Manual/webgl-performance.html)
- [E. Wallace — WebAssembly cut Figma's load time by 3x](https://madebyevan.com/figma/webassembly-cut-figmas-load-time-by-3x/)
- Cross-reference: `EMB.3` (exceptions and RTTI cost), `GEN.4` (LTO), `GEN.6`
  (inlining attributes), `WASM.4` (code size as i-cache pressure), `WASM.7`
  (the cache threshold that size interacts with).
