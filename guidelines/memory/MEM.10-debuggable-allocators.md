+++
id = "MEM.10"
title = "Make custom allocators debuggable: fill patterns, guard bytes, tracking"
category = "memory"
status = "draft"
summary = "Build allocator debugging in from the start — fill patterns, guard bytes, allocation tracking — gated behind a build flag so release builds pay nothing."
tags = ["allocator", "debugging", "object-pooling"]
+++

## Rationale

A custom allocator that is faster than `malloc` but abandons `malloc`'s
debugging affordances is a poor trade. The headerless pools of `MEM.2` and the
bump allocators of `MEM.1` and `MEM.3` cannot, unaided, detect a use-after-free
or a buffer overrun — the very bugs custom allocation makes easier to write.

Production engines treat allocator instrumentation as a **design requirement**,
not an afterthought. Sony London Studio's memory system ships with memorable
byte-fill clear values, header guard patterns, full allocation tracing with
captured callstacks, live graphs, and HTML dumps produced on out-of-memory or
on demand. The instrumentation is part of what makes the fast allocator safe
to depend on.

The cost is paid only where it is wanted: all of it sits behind a build flag,
so shipping builds get the bare, fast allocator and checked builds get the
diagnostics.

## Guidance

Build these in from the start, each gated behind a compile-time switch:

- **Fill patterns.** Fill freshly allocated memory with one recognizable byte
  (e.g. `0xCD`) and freed memory with another (e.g. `0xDD`). Reading
  uninitialized or freed memory then shows an obvious pattern in a debugger
  instead of plausible-looking garbage.
- **Guard bytes.** Write a known sentinel immediately before and after each
  allocation; verify it on free. A corrupted sentinel is a contiguous overrun
  or underrun, caught at the moment of free with the allocation's identity in
  hand.
- **Allocation tracking.** Record each live allocation's size and a captured
  callstack. On shutdown, anything still live is a leak — reported with the
  exact site it came from.
- **Dumps.** On out-of-memory, or on demand, dump the live-allocation set so a
  human can see what is consuming the budget.
- **Make it free to disable.** Keep every check behind one obvious build flag.
  Release builds must get the unwrapped allocator.

## Example

```cpp
// A debug wrapper around any Allocator (see MEM.6). It records each
// allocation's size in a header, brackets the payload with guard sentinels,
// and fills allocated/freed memory with recognizable patterns. With
// CPP_PERF_DEBUG_ALLOC undefined it forwards directly to the inner allocator,
// so release builds carry no overhead.
class DebugAllocator {
public:
    explicit DebugAllocator(Allocator& inner) noexcept : inner_{inner} {}

    void* allocate(std::size_t size, std::size_t align) {
#if defined(CPP_PERF_DEBUG_ALLOC)
        auto* p = static_cast<std::byte*>(
            inner_.allocate(kHeader + size + kGuard, align));
        if (!p) return nullptr;
        std::memcpy(p, &size, sizeof(size));      // header records the size
        write_sentinel(p + sizeof(size));         // front guard
        write_sentinel(p + kHeader + size);       // back guard
        std::memset(p + kHeader, 0xCD, size);     // 0xCD == freshly allocated
        return p + kHeader;
#else
        return inner_.allocate(size, align);
#endif
    }

    void deallocate(void* user) noexcept {
#if defined(CPP_PERF_DEBUG_ALLOC)
        auto* p = static_cast<std::byte*>(user) - kHeader;
        std::size_t size;
        std::memcpy(&size, p, sizeof(size));
        check_sentinel(p + sizeof(size));         // underrun -> trap
        check_sentinel(p + kHeader + size);       // overrun  -> trap
        std::memset(user, 0xDD, size);            // 0xDD == freed
        inner_.deallocate(p);
#else
        inner_.deallocate(user);
#endif
    }

private:
    // kHeader must be a multiple of the largest alignment requested so the
    // returned pointer stays correctly aligned.
    static constexpr std::size_t kHeader = 16;   // size field + front guard
    static constexpr std::size_t kGuard  = 8;    // back guard
    // write_sentinel / check_sentinel write and verify a fixed byte pattern;
    // a mismatch traps with the offending allocation's details. ...
    Allocator& inner_;
};
```

## Caveats

- **Checks cost memory and time.** Guards and headers enlarge every
  allocation; fills touch every byte. Keep them in debug and checked builds,
  out of release.
- **Fill patterns reveal, they do not prevent.** They make a use-after-free
  *visible*; they do not stop it.
- **Guard bytes catch contiguous overruns only.** A wild pointer or a
  far-away write goes undetected — guards are one layer, not the whole story;
  pair them with a sanitizer where available.
- **Alignment.** The header shifts the user pointer; its size must preserve the
  requested alignment.
- **Be honest about the build.** If the checks are compiled out, the allocator
  is not "checked." Keep the flag and its meaning obvious.

## References

- Aaron MacDougall, "Building a Low-Fragmentation Memory System for 64-bit
  Games", GDC 2016 (allocator debugging — fill values, guards, tracing,
  dumps) — <https://media.gdcvault.com/gdc2016/Presentations/MacDougall_Aaron_Building_A_Low.pdf>
- Jason Gregory, *Game Engine Architecture*, 3rd ed., §6.2 (memory debugging).
