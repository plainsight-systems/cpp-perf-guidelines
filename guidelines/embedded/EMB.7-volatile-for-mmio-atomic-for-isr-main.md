+++
id = "EMB.7"
title = "volatile for memory-mapped I/O; std::atomic for ISR-main concurrency"
category = "embedded"
status = "draft"
summary = "volatile prevents the compiler from removing, reordering, or coalescing hardware-observable accesses. It provides no atomicity. Use std::atomic with explicit memory_order for ISR-main signalling; use both when both apply."
tags = ["volatile", "atomic", "mmio", "memory-order", "isr"]
+++

## Rationale

Two C++ tools sound similar and address two genuinely different problems.
Conflating them is the canonical embedded bug.

**`volatile`** is the correct tool for *memory-mapped I/O*. A `volatile`
load or store is hardware-observable: the compiler may not remove it,
reorder it with respect to other `volatile` accesses, or coalesce
repeated writes. Reading a hardware status register may *clear* it as a
side effect; writing a register may trigger DMA. None of that is
captured in the C++ object model — `volatile` is the type system's
acknowledgement that these accesses talk to the outside world.

`volatile` is **not** a concurrency primitive. It says nothing about
atomicity of multi-byte accesses, nothing about ordering with respect to
non-`volatile` memory, and nothing about cross-CPU visibility. The
well-known and decades-old anti-pattern — `volatile bool ready;` shared
between an interrupt service routine and the main loop — is unsafe on any
CPU that does not happen to make 32-bit aligned writes atomic, and even
where it is atomic it provides no guarantee that other state written by
the ISR is visible to the main loop.

**`std::atomic<T>`** is the correct tool for *concurrency between
execution contexts* — ISR and main, or multiple cores, or RTOS tasks. It
provides atomicity of the access *and* the memory-order semantics that
guarantee other writes visible. On a Cortex-M (single-issue, in-order,
no SMP), `std::atomic<std::uint32_t>` with natural alignment is lock-free
and compiles down to plain load and store instructions; the `memory_order`
argument controls compiler-side reordering and emits `DMB`/`DSB` barriers
where needed.

When the same hardware path needs both — an ISR writes a register and
sets a flag the main loop reads — you need **both**: `volatile` for the
register, `std::atomic` for the flag. They are doing different work.

## Guidance

- **`volatile` for every memory-mapped register access**, no exceptions.
  Define register-block types whose members are `volatile`-qualified, so
  the type system enforces it at every access.
- **`std::atomic<T>` for every shared variable between an ISR and main**
  (or between any two execution contexts). Use explicit `memory_order_*`
  arguments; the default `seq_cst` is correct but pessimistic on the hot
  path.
- **Use both** when both apply: an ISR writing a register and signalling a
  flag uses `volatile` for the register write and `std::atomic` for the
  flag.
- **Never use `volatile` to "fix" a race.** A `volatile` access between
  threads is undefined behaviour for the purpose it suggests; the compiler
  is free to assume away the race in non-`volatile` adjacent state.
- **Check `std::atomic<T>::is_always_lock_free`** at the type definition.
  An atomic that is not lock-free on the target falls back to a library
  mutex implementation that may not exist on freestanding C++ at all
  (`EMB.8`).
- **Match memory orders to the synchronisation pattern.** ISR writes flag
  + data → `memory_order_release` on the flag. Main loop reads flag, then
  reads data → `memory_order_acquire` on the flag. Sequential consistency
  is the safe default; relax only with a clear reason.

## Example

```cpp
// Memory-mapped UART block. Every register is volatile — the compiler may
// not remove, reorder among these, or coalesce these accesses.
struct UartRegs {
    volatile std::uint32_t DR;      // data register; reading consumes a byte
    volatile std::uint32_t SR;      // status register; bits may auto-clear
    volatile std::uint32_t CR;      // control register
};

static UartRegs* const UART1 = reinterpret_cast<UartRegs*>(0x4001'3800);

// Shared flag for ISR-main signalling. NOT volatile — atomic. The
// release / acquire pair guarantees that the buffer write in the ISR is
// visible to the main loop before it reads from the buffer.
inline std::atomic<bool> rx_ready{false};
inline RingBuffer<std::uint8_t, 64> rx_buffer;

extern "C" void uart1_isr() {
    // MMIO read: must be volatile — the load clears the RX-data-available
    // status as a hardware side effect.
    const auto byte = UART1->DR;
    rx_buffer.push(static_cast<std::uint8_t>(byte));
    rx_ready.store(true, std::memory_order_release);   // publish
}

void main_loop() {
    while (true) {
        if (rx_ready.exchange(false, std::memory_order_acquire)) {
            process(rx_buffer);
        }
        // ... rest of the loop ...
    }
}

// BAD: volatile used as a concurrency primitive. This compiles, runs, and
// looks fine on a single-issue in-order core — until a different compiler
// optimization, a different target, or a multi-byte type breaks it.
//
//   volatile bool ready = false;          // wrong tool
//   volatile RingBuffer<uint8_t, 64> rx;  // worse; no atomicity at all
```

## Caveats

- **`std::atomic` lock-free guarantees are type-specific.**
  `std::atomic<std::uint32_t>` is lock-free on every mainstream target.
  `std::atomic<some_struct>` may not be. Check with
  `std::atomic<T>::is_always_lock_free`; the lock-fallback path may pull
  in a mutex that does not exist on freestanding.
- **Compound `volatile` accesses are not atomic.**
  `regs->CR |= MASK;` is read-modify-write on the register — the *read* and
  the *write* are each `volatile`, but the sequence is not atomic with
  respect to another context (or another core) writing the same register.
  Use the hardware's set / clear / toggle aliases when the platform
  provides them.
- **Default `memory_order` is `seq_cst`** — correct, sometimes pessimistic.
  Hot paths can use `memory_order_relaxed` (for counters), `release` /
  `acquire` (for hand-off), or `consume` (rare, niche). Be explicit; the
  default is not always what the reviewer needs to see.
- **Aliasing through volatile pointers** is correct (the standard
  guarantees access through the volatile pointer happens) but
  type-punning is still subject to strict aliasing. Use
  `reinterpret_cast<volatile UartRegs*>(address)` for register blocks; do
  not type-pun through a `volatile T*` cast.
- **C `volatile` is the same construct, but C++ does not provide
  `std::atomic` to C code.** Mixed-language drivers either expose the
  register block to C++ and do the synchronisation in C++, or use the
  C11 `_Atomic` types.

## References

- ISO C++ working draft, `[atomics]` —
  <https://eel.is/c++draft/atomics>
- cppreference, `std::atomic` and `memory_order` —
  <https://en.cppreference.com/w/cpp/atomic/atomic>;
  <https://en.cppreference.com/w/cpp/atomic/memory_order>
- Ben Saks, *Back to Basics: `volatile`*, CppCon — search:
  <https://www.youtube.com/results?search_query=ben+saks+volatile+cppcon>
- Hans Boehm, "Threads cannot be implemented as a library" (the original
  paper on why `volatile` is not a concurrency primitive) —
  <https://www.hpl.hp.com/techreports/2004/HPL-2004-209.pdf>
- ARM Architecture Reference Manual, sections on memory barriers
  (DMB, DSB, ISB) — vendor docs.
