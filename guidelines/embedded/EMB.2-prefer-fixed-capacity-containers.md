+++
id = "EMB.2"
title = "Prefer fixed-capacity containers (ETL, EASTL fixed_*) — the STL throws and allocates"
category = "embedded"
status = "draft"
summary = "On embedded targets where heap and exceptions are banned, use fixed-capacity containers with inline storage and explicit capacity."
tags = ["fixed-capacity-container", "etl", "eastl", "embedded"]
+++

## Rationale

The C++ standard library was not designed for embedded steady-state code.
`std::vector::push_back` allocates when capacity is exhausted;
`std::string` reallocates on assignment; `std::unordered_map` allocates a
node per insertion; `std::function` may copy a heavy callable through a
heap-fallback small-buffer optimisation. Every one of these is a violation
of `MEM.9`'s "allocate at init, not in steady state."

The failure-signalling story is just as wrong. `std::vector::at` throws on
out-of-range; `std::stoi` throws on parse error; `std::variant::get` throws
on wrong-alternative access. With exceptions disabled (`EMB.3`), these
become hidden `std::terminate` paths.

Two libraries fix this by re-cutting the STL shape with the embedded
constraints baked in:

- **ETL — Embedded Template Library** (Wellbelove, MIT). Header-only, no
  heap, no exceptions, capacity in the type. The configurable error policy
  on overflow (assert, abort, user handler) makes the failure mode
  explicit.
- **EASTL `fixed_*`** (EA, BSD-3). Same heapless philosophy from a
  games-and-consoles author. The `bEnableOverflow` template flag is the
  design tell — embedded users set it `false`; games use it for "fast path
  99 % of the time, slow path for the rare large case."

Capacity is part of the type. Overflow is a contract violation, not a
runtime error to recover from gracefully. Both libraries treat it that way.

## Guidance

- **Default to a fixed-capacity container** for any container reachable
  from the steady-state path. `etl::vector<T, N>`, `etl::deque<T, N>`,
  `etl::map<K, V, N>`, `etl::string<N>`, `etl::circular_buffer<T, N>`.
- **Pick the library by audience.** ETL for general embedded and
  safety-targeted projects (MIT, audit-friendly, configurable error
  handler). EASTL `fixed_*` for game-engine projects already using EASTL.
- **Size N from an offline budget**, never "a number that feels safe." The
  worst-case live count must be analysable and demonstrable; the value of
  fixed-capacity is *exactly* that you have to do this analysis.
- **Configure the overflow policy at the library boundary**, not per call
  site. ETL lets you set assert / abort / callback once per build; pick
  the option your target supports.
- **Hand-roll only for layouts neither library offers** — typically
  intrusive lists where link pointers live inside the element. For
  everything else, ETL / EASTL is cheaper than the bugs you would write.
- **Use `etl::ivector<T>` (capacity-erased) as a parameter type** so a
  function can take "any ETL vector of `T`" without templating on capacity.

## Example

```cpp
// Bad: an std::vector reachable from the steady state will allocate on
// push_back when the capacity is exceeded. emplace_back hides this — the
// hidden allocation is the bug.
class EventQueueBad {
public:
    void post(Event e) {           // may allocate; UB under MEM.9
        events_.push_back(std::move(e));
    }
private:
    std::vector<Event> events_;     // unbounded, heap-backed
};

// Good: capacity is part of the type. Storage is inline. Overflow signals
// via ETL's configured error handler — explicit, not exception-based.
class EventQueue {
public:
    static constexpr std::size_t kCapacity = 64;

    // Returns true on success, false on overflow. The caller chooses how to
    // handle the failure — drop, log, escalate to a fault. No std::terminate
    // path; no exceptions; no allocation.
    bool post(Event e) {
        if (events_.full()) return false;
        events_.push_back(std::move(e));
        return true;
    }

private:
    etl::vector<Event, kCapacity> events_;
};

// Capacity-erased parameter: a function that consumes events from any
// ETL vector of Event, regardless of declared capacity.
void drain(etl::ivector<Event>& q);
```

## Caveats

- **Capacity sizing is the new risk.** A fixed-capacity container fails
  *deterministically* when full, but that failure must be designed for —
  the producer must check, or the system must guarantee by construction
  that overflow cannot occur. The analysis replaces, but does not remove,
  the work.
- **API differences from the STL are real.** ETL's containers do not
  throw; `at()` returns a sentinel or invokes the error handler depending
  on configuration. Code copy-pasted from STL examples will not compile or
  will misbehave; treat them as a different library.
- **EASTL's `bEnableOverflow == true` is not the embedded mode.** It is
  the games mode — fall back to a general allocator on overflow. Embedded
  use sets it `false`.
- **`etl::vector` is not bit-compatible with `std::vector`.** Do not
  cross-cast or rely on layout equivalence with the STL.
- **For tiny static collections** (a handful of fixed-size enums, a
  startup-only set), `std::array` and language arrays are simpler than
  either ETL or EASTL. Reach for the fixed-capacity library when the
  collection size varies but is bounded.

## References

- ETL — Embedded Template Library (MIT) —
  <https://github.com/ETLCPP/etl>; <https://www.etlcpp.com/>
- EASTL (BSD-3) — fixed-capacity containers —
  <https://github.com/electronicarts/EASTL>;
  design doc <https://github.com/electronicarts/EASTL/blob/master/doc/Design.md>
- Embedded Artistry, *Heap-less C++ Programming* —
  <https://embeddedartistry.com/fieldatlas/embedded-c-coding-standards/>
- Cross-reference: `MEM.9` (allocate at init), `EMB.3` (`-fno-exceptions`).
