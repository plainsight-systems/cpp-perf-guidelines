+++
id = "SIMD.8"
title = "Drop to hand-written assembly only for AMX, unsupported vendor extensions, or constant-time crypto"
category = "simd"
status = "draft"
summary = "Use assembly only for missing intrinsic coverage, vendor-specific extensions, or constant-time crypto where compiler choice is a risk."
tags = ["inline-assembly", "amx", "sme", "constant-time", "crypto"]
+++

## Rationale

The case for hand-written assembly in C++ has narrowed dramatically.
Twenty years ago, the compiler's vector codegen was poor, intrinsics
were inconsistent across vendors, and a senior engineer with an
optimisation manual could routinely beat the compiler on the inner
kernel. None of those conditions hold today:

- **The autovectoriser** (`SIMD.4`) generates good vector code from
  ordinary C++ loops for the AVX-2 / AVX-512 / NEON / SVE common
  surface.
- **Intrinsics** are the same low-level primitives the assembler
  would emit, with proper register allocation and scheduling from
  the compiler. A hand-tuned asm block does not usually outperform
  the same kernel written in intrinsics.
- **Portable SIMD libraries** (`SIMD.3`) cover the multi-ISA case at
  intrinsic-grade speed.
- **Modern out-of-order cores** schedule code well enough that
  microarchitectural sequencing — the historical reason for asm —
  matters less than it did on in-order or short-pipeline machines.

What remains as a legitimate reason to drop to assembly:

1. **Matrix-extension ISAs with no usable intrinsic surface.** Intel
   AMX (Advanced Matrix Extensions, Sapphire Rapids / Granite Rapids
   / Sierra Forest) and Apple's pre-SME AMX (a private CPU
   instruction set predating ARM SME) operate on 2-D tile registers
   the C surface barely exposes. Intel ships AMX intrinsics
   (`_tile_loadd`, `_tile_dpbf16ps`), but tile configuration
   (`LDTILECFG`, `STTILECFG`), tile palette switching, and the
   register-file lifecycle are awkward in C and routinely
   hand-asm'd in production (oneDNN, Eigen, llamafile). ARM SME
   (Scalable Matrix Extension, in ARMv9.2-A: Cobalt, Apple M4) has a
   cleaner ACLE intrinsic surface than AMX, and is closer to "write
   it in intrinsics."

2. **Vendor-specific or undocumented extensions with no intrinsic.**
   Apple's pre-SME AMX (M1/M2/M3) is *not* the ARM SME; it is a
   private undocumented instruction set, and the only way to issue
   its instructions is hand-crafted `.byte` sequences inside
   `__asm__`. The `dougallj/applegpu` reverse-engineering tradition
   produced the public knowledge here; libraries like Corsix's
   AMX docs and llamafile are the practical references.

3. **Constant-time cryptography.** A C++ implementation of a cipher
   or signature scheme is at the compiler's mercy: the optimiser is
   free to add branches, fold constants, or schedule instructions
   in ways that leak through timing or power side-channels.
   Constant-time crypto code is written in assembly to deny the
   compiler that freedom. BoringSSL, libsodium, and OpenSSL all
   ship hand-asm cores for AES, GHM, ChaCha20, Curve25519, and the
   AVX-512-IFMA Kyber / Dilithium hot paths.

4. **A specific instruction the compiler refuses to emit.** Rare,
   but real: an instruction the autovectoriser does not recognise
   (e.g., `_pdep_u64` patterns that defeat the optimiser), a
   prefetch instruction whose intrinsic the compiler reorders, a
   memory barrier that the compiler weakens.

That is the list. Outside it, hand-asm has costs that outweigh the
optimisation:

- **Portability dies.** An asm block is bound to a specific ISA,
  syntax (Intel vs AT&T), and (often) operand convention.
- **The compiler cannot reason about it.** Code around an asm
  block is opaque to the optimiser: it cannot inline through it,
  cannot fold constants past it, and may pessimise register
  allocation around the clobber list.
- **Maintenance is single-author.** The colleague who has to read
  your AT&T-syntax `vpermb` block five years from now is going to
  rewrite it in intrinsics.
- **Safety is yours.** Calling-convention mistakes (clobbering a
  callee-saved register), stack-alignment errors, and red-zone
  violations are silent bugs that surface as crashes in unrelated
  code.

The right test for "should this be asm?" is: *does the compiler
have no other way to express this?* If a portable-SIMD-library
intrinsic or a `target` attribute does the job, those are the
right tools.

## Guidance

- **Default to intrinsics or a portable SIMD library.** If the
  compiler can express it, let it.
- **Drop to asm only when the surface above does not exist** —
  AMX without sufficient intrinsics, Apple AMX, constant-time
  crypto, a specific instruction the compiler refuses.
- **For matrix extensions, prefer a vetted library over rolling
  your own.** oneDNN, Eigen (with AMX backends), Highway's
  matrix routines, and llamafile's tinyBLAS exist precisely to
  amortise the cost of getting these right.
- **For crypto, prefer a vetted library over rolling your own.**
  Constant-time correctness is a research discipline; BoringSSL /
  libsodium / OpenSSL absorb the assembly work.
- **If you must write asm, isolate it behind a tiny header-only
  wrapper.** The rest of the codebase calls a C function; the
  function body is a single `__asm__` block. Limits blast radius
  on portability and review.
- **Document the calling convention, clobber list, and target
  ISA at the asm block.** The next reader (you, in three months)
  needs to know what registers the block touches, what
  preconditions it assumes, and which CPU it requires.
- **Test on the actual hardware.** Asm code is not portable across
  ISAs or even across microarchitectures of the same ISA. A
  Sapphire Rapids AMX block does not run on Cascade Lake; an
  Apple AMX block does not run on M3 Pro identically to M3.
- **Apple AMX is undocumented.** Production use should depend on
  the public reverse-engineered documentation and accept that
  Apple may change or remove the instructions at any macOS
  revision. SME is the public successor (M4+).

## Example

```cpp
// Good: a tiny inline-asm wrapper for a single Apple AMX
// instruction. The rest of the codebase calls amx_set(); the asm
// detail is contained. Clobber list and target are explicit.
//
// WARNING: Apple AMX is private and undocumented. Use Apple's
// ARM SME on M4+ where available; this is shown as an example
// of the *style* of containment, not an endorsement of using
// Apple AMX in new code.
namespace apple_amx_private {
    // Public docs (reverse-engineered): the AMX coprocessor is
    // entered with op 0x11 << 5; bits encode the sub-op.
    // Apple Silicon M1/M2/M3 only. Not portable. Not stable.

    static inline void amx_set() noexcept {
        // .word emits the raw 32-bit instruction; the assembler
        // would otherwise reject the private opcode.
        __asm__ volatile (".word 0x00201000" ::: "memory");
    }
    static inline void amx_clr() noexcept {
        __asm__ volatile (".word 0x00201001" ::: "memory");
    }
}

// Good: Intel AMX via intrinsics — the supported path. The
// intrinsics handle tile loads / stores and dot-product; only
// the tile configuration requires care.
#if defined(__AMX_BF16__)
#include <immintrin.h>

namespace intel_amx {
    // Tile config is the awkward part; the intrinsics handle the
    // rest. This is "intrinsics with an asm escape hatch only for
    // the configuration block."
    struct TileConfig {
        std::uint8_t palette;
        std::uint8_t start_row;
        std::uint8_t reserved[14];
        std::uint16_t colsb[16];
        std::uint8_t rows[16];
    };

    inline void load_tile_config(const TileConfig* cfg) noexcept {
        _tile_loadconfig(cfg);
    }

    // The compute itself is an intrinsic, not asm.
    inline void bf16_matmul_block(/* ... */) noexcept {
        _tile_dpbf16ps(0, 1, 2);
    }
}
#endif

// Good: constant-time conditional swap (the crypto pattern). The
// asm exists to deny the compiler the freedom to emit a branch.
// This is a textbook case where C++ is *less* expressive than asm
// for the property we need.
namespace ct {
    // Swap *a and *b if mask is all-ones; otherwise leave them.
    // The compiler-generated equivalent might emit a CMOV (constant
    // time on most x86) or a branch (not constant time on any).
    // The asm form pins the choice.
    inline void cswap_u64(std::uint64_t* a, std::uint64_t* b,
                          std::uint64_t mask) noexcept {
#if defined(__x86_64__)
        __asm__ volatile (
            "movq (%[a]), %%rax\n\t"
            "movq (%[b]), %%rcx\n\t"
            "movq %%rax, %%rdx\n\t"
            "xorq %%rcx, %%rdx\n\t"
            "andq %[m], %%rdx\n\t"
            "xorq %%rdx, %%rax\n\t"
            "xorq %%rdx, %%rcx\n\t"
            "movq %%rax, (%[a])\n\t"
            "movq %%rcx, (%[b])\n\t"
            :
            : [a] "r"(a), [b] "r"(b), [m] "r"(mask)
            : "rax", "rcx", "rdx", "memory"
        );
#else
        // Portable fallback. May or may not be constant time
        // depending on the compiler; for production, gate the
        // platform.
        std::uint64_t t = (*a ^ *b) & mask;
        *a ^= t;
        *b ^= t;
#endif
    }
}
```

## Caveats

- **The compiler can be coaxed.** Before reaching for asm,
  consider `__attribute__((target(...)))` (`SIMD.6`), `#pragma
  GCC ivdep`, `#pragma clang loop` (`SIMD.4`), or restructuring
  to a vectorisable shape (`SIMD.2`). Asm is the floor, not the
  first step.
- **Inline asm is harder than freestanding asm.** GCC / Clang
  inline-asm constraint syntax (`"=r"`, `"=&r"`, clobber lists)
  is famously easy to get wrong; the resulting bugs are silent
  miscompilations. Freestanding `.s` files compiled separately
  are easier to review.
- **Apple AMX is private.** No documented stability guarantee.
  Production deployment of Apple AMX code is an active risk
  that the next macOS release may break. ARM SME is the
  public, supported successor.
- **AMX (Intel) requires tile-configuration on every context
  switch and zeroing across exceptions.** The OS support for
  AMX is real but recent (Linux 5.16+, macOS does not support
  Intel AMX). Embedded scheduling matters here.
- **Constant-time asm requires constant-time *microarchitectural*
  behaviour, not just constant-time *instruction sequences*.**
  Some "constant-time" instructions on some CPUs leak through
  cache or branch-predictor state. The asm is necessary but not
  sufficient; this is why crypto is a research discipline.
- **A correctness bug in hand-asm code is a CVE.** Crypto asm
  must be reviewed by people who do that for a living. For new
  projects, do not write it yourself; depend on BoringSSL /
  libsodium / OpenSSL.

## References

- Intel, *Intel Architecture Instruction Set Extensions Programming
  Reference* (AMX chapter) —
  <https://www.intel.com/content/www/us/en/develop/download/intel-architecture-instruction-set-extensions-programming-reference.html>
- Intel, *Intrinsics Guide* (`_tile_*` AMX intrinsics) —
  <https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html>
- ARM, *Scalable Matrix Extension (SME) overview and ACLE
  intrinsics* —
  <https://developer.arm.com/documentation/109246/latest/>
- Peter Cawley (corsix), *Apple AMX reverse-engineering notes* —
  <https://github.com/corsix/amx>
- BoringSSL — design rationale for hand-written asm in crypto cores —
  <https://boringssl.googlesource.com/boringssl/>
- libsodium documentation, *Performance and constant-time
  guarantees* — <https://doc.libsodium.org/>
- llamafile / tinyBLAS — practical AMX + ARM dot-product asm in
  production — <https://github.com/Mozilla-Ocho/llamafile>
- Agner Fog, *Optimizing subroutines in assembly language* (the
  classical reference; still relevant for the constraints) —
  <https://www.agner.org/optimize/>
- Cross-reference: `SIMD.1` (asm is the last column of the
  decision table), `SIMD.3` (the portable library covers most
  cases), `SIMD.7` (mask programming covers most of what
  pre-mask asm did).
