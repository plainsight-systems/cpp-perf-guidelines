+++
id = "EMB.8"
title = "Know the freestanding C++ subset — C++23 expanded what's mandated"
category = "embedded"
status = "draft"
summary = "Bare-metal targets get only the freestanding library subset. C++23 expanded it, but you still need to know what your toolchain provides."
tags = ["freestanding", "p1642", "p2407", "bare-metal"]
+++

## Rationale

A *freestanding* C++ implementation runs without an operating system or a
hosted runtime. Most of the standard library was designed around a hosted
environment — heap, threads, locale, filesystem, exceptions — and large
parts of it simply do not exist on a bare-metal target. Code that compiles
on Linux and silently fails to link on a Cortex-M is usually code that
reached for a header the freestanding subset does not include.

Two things have changed recently and are worth treating as the new
baseline:

- The standard has historically been vague about *which* headers a
  freestanding implementation must provide. C++23's **P1642** and **P2407**
  fix this. They mandate large parts of `<expected>`, `<optional>`,
  `<string_view>`, `<span>`, `<bit>`, the lock-free portion of
  `<atomic>`, and most of `<utility>`, `<type_traits>`, `<concepts>`,
  `<ranges>`, `<algorithm>`, and `<numeric>` as freestanding. The list is
  long enough to support real applications.
- Major embedded toolchains (GCC `arm-none-eabi`, Clang with
  `-ffreestanding`) are catching up. What used to be "you can't use the
  STL on bare metal" is now "you can use a known, growing subset."

Knowing the subset lets the project state explicitly which headers the
embedded path may use, decouples portability from toolchain accident,
and lets newer features — `std::expected` for non-throwing error returns,
`std::span` for zero-allocation views — replace the older patterns
(`std::pair<bool, T>`, raw pointer + size).

## Guidance

- **Compile embedded targets with `-ffreestanding`** (GCC, Clang). The
  flag tells the compiler not to assume a hosted environment and disables
  certain built-in optimizations that rely on hosted-library identities.
- **Default the embedded path to the freestanding-mandated headers**:
  - `<type_traits>`, `<utility>`, `<tuple>`, `<concepts>`, `<bit>`,
    `<bitset>`, `<limits>`, `<numeric>` (most), `<initializer_list>`.
  - `<atomic>` — the lock-free subset.
  - `<cstdint>`, `<cstddef>`, `<cstring>`, `<climits>`.
  - **C++23 additions** (where toolchain support is present):
    `<expected>`, `<optional>`, `<string_view>`, `<span>`, more of
    `<algorithm>` and `<ranges>`.
- **Avoid the hosted-only headers on the steady-state path**:
  `<iostream>`, `<fstream>`, `<filesystem>`, `<thread>`, `<mutex>`,
  `<future>`, `<regex>`, `<locale>`, most of `<chrono>` clocks. These
  either require an OS or pull in the heap.
- **Replace heap-touching idioms** with the freestanding equivalents.
  `std::expected<T, E>` for error returns (replaces throw or
  `std::pair<bool, T>`). `std::span<T>` for views into caller-provided
  storage (replaces `T*` + `size_t`). `std::string_view` for non-owning
  text (replaces `const char*` + `strlen`).
- **Document the subset in the project's coding standard**. The list of
  permitted headers is small and stable; making it explicit lets a
  reviewer reject a hosted dependency on sight.
- **Check toolchain support before relying on a C++23 freestanding
  addition.** Compiler conformance is uneven; verify `std::expected` and
  the freestanding `<algorithm>` ranges before using them in production.

## Example

```cpp
// Bare-metal-safe C++ using only freestanding facilities. No iostream,
// no std::string, no std::vector, no exceptions — and yet a reasonable
// modern-C++ API.

#include <array>          // freestanding
#include <atomic>         // freestanding (lock-free subset)
#include <bit>            // freestanding
#include <cstddef>        // freestanding
#include <cstdint>        // freestanding
#include <expected>       // freestanding since C++23 (P2407)
#include <span>           // freestanding since C++23
#include <string_view>    // freestanding since C++23

enum class ParseError { TooShort, Bad, Overflow };

// Non-throwing error return using std::expected — no exceptions, no
// heap-allocated error message.
std::expected<std::uint32_t, ParseError>
parse_u32_le(std::span<const std::byte> bytes) {
    if (bytes.size() < 4) return std::unexpected(ParseError::TooShort);
    return std::bit_cast<std::uint32_t>(
        std::array{bytes[0], bytes[1], bytes[2], bytes[3]});
}

// A non-owning view into a caller-provided buffer (no allocation;
// freestanding).
void process_packet(std::span<const std::byte> packet) {
    if (auto v = parse_u32_le(packet); v) {
        handle_u32(*v);
    } else {
        log_parse_error(v.error());
    }
}

// Lock-free atomic flag — freestanding subset of <atomic>.
inline std::atomic<bool> tick{false};

extern "C" void systick_isr() {
    tick.store(true, std::memory_order_release);
}
```

## Caveats

- **C++23 freestanding additions are recent.** The standard mandates them;
  not every toolchain has shipped them yet. Check before depending on
  `std::expected` in production-grade firmware; fall back to a `tl::expected`-
  style local implementation where needed.
- **Header presence does not mean every feature.** `<atomic>` is
  freestanding, but `std::atomic_flag::wait` is not — it would require an
  OS to block on. `<chrono>` is freestanding, but `std::chrono::system_clock`
  is not. The standard carves the subset feature-by-feature.
- **`-ffreestanding` changes optimization assumptions.** Some compilers
  refuse to call certain hosted built-ins under `-ffreestanding`; verify
  what you lose. Most projects also pass `-nostdlib` and/or `-nostartfiles`
  for the linker side.
- **A C runtime is still needed.** Freestanding C++ presumes a C runtime
  (newlib, newlib-nano, picolibc) that provides the C primitives the
  freestanding headers transitively depend on. Pick one deliberately.
- **The freestanding subset is not "the STL minus heap."** It is a specific
  list. Code that compiles for the hosted target may use a hosted-only
  feature that is invisible until link-time. The discipline of *building
  on the embedded target* in CI catches this; relying on read-through is
  not enough.

## References

- P1642R11, "Freestanding `std::lib`" —
  <https://wg21.link/p1642>
- P2407R5, "Freestanding library: Partial classes" — broader freestanding
  set; <https://wg21.link/p2407>
- cppreference, "Freestanding implementation" —
  <https://en.cppreference.com/w/cpp/freestanding>
- GCC, `-ffreestanding` —
  <https://gcc.gnu.org/onlinedocs/gcc/Standards.html>
- Cross-reference: `EMB.1` (the certification standard determines which
  subset on top of freestanding), `EMB.3` (`-fno-exceptions` /
  `-fno-rtti` interact with what is genuinely usable), `EMB.7`
  (`<atomic>` is freestanding for lock-free types only).
