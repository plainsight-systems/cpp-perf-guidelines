+++
id = "TLM.3"
title = "Static names and interned strings on hot paths — names are sent to the sink once, not per-event"
category = "telemetry"
status = "draft"
summary = "Dynamic per-event strings are documented overhead in every profiler that supports them. Name your zones with `__FILE__:__LINE__` interning or compile-time literals; let the analyzer resolve the name."
tags = ["static-names", "string-interning", "source-location", "tracy", "perfetto"]
+++

## Rationale

A telemetry event has two parts: the *what* (a name) and the
*when* (a timestamp). The timestamp is cheap; the name, if
handled naively, is not. Sending a copy of the name string on
every emit means:

- An allocation (if the string was built at runtime), or at
  best a `memcpy` into the event buffer.
- Bandwidth from the producer to the sink — every byte of the
  name multiplied by every emit.
- Cache pressure on the producer's L1 — name bytes the work
  loop did not need.

The mature pattern is **string interning at the source**. The
name is sent to the sink *once* — at compile time via
`__FILE__:__LINE__` lookup, at thread start via a register-name
call, or at first emit via a deduplicated handle — and every
subsequent event carries only the handle (a small integer, or
the address of a static `const char*`).

Concrete examples from the field:

- **Tracy** uses `__FILE__:__LINE__:__FUNCTION__` as a
  zone-source-location key; the actual string bytes are sent
  once per source location, on first emit. The hot-path
  payload is a pointer to a static `SourceLocationData` struct.
- **Unity** documents `ProfilerMarker` as a *static* handle:
  `static readonly ProfilerMarker k_DecodeMarker = new
  ProfilerMarker("App.Decode")`. The marker handle is the
  thing crossed; the string is registered once.
- **Perfetto** distinguishes `StaticString` (no runtime cost,
  string is constant for the binary lifetime) from
  `DynamicString` (runtime cost, requires interning at emit).
  The Perfetto docs explicitly warn about dynamic string
  overhead.
- **Unreal Insights** documents the same warning — dynamic
  strings carry extra performance and memory overhead. Use
  channels and macros that take literal names.
- **Intel ITT** uses `__itt_string_handle_create("name")` to
  register a name once, returning a handle; subsequent
  `__itt_task_begin(domain, ..., handle)` calls cross the
  handle, not the string.

The trap is using `std::format` / `printf`-style names in the
hot path:

```cpp
// Anti-pattern: dynamic name on every emit
for (auto& item : items) {
    ZoneScopedN(std::format("process[{}]", item.id).c_str());
    process(item);
}
```

Each iteration allocates, formats, and copies the name. The
zone overhead — nominally ~2.25 ns — becomes hundreds of
nanoseconds.

## Guidance

- **Use compile-time literal names.** `ZoneScopedN("decode.loop")`,
  not `ZoneScopedN(name_buffer)`. The macro layer registers the
  literal once at first emit and crosses a pointer thereafter.
- **For per-iteration variation, prefer adding a *value*, not a
  varying *name*.** `ZoneScoped` + `ZoneValue(i)` lets the
  analyzer group by zone and parameterise by value, at lower
  cost than a per-iteration distinct name.
- **Static `ProfilerMarker` / handle pattern in C++.** Where the
  profiler library exposes a handle type, declare it `static
  const` at function scope (Unity-style) or namespace scope:
  `static const TraceHandle kDecodeZone = MakeZone("decode")`.
- **Static thread names.** Set the thread name once at thread
  creation (`pthread_setname_np`, `SetThreadDescription`,
  `prctl(PR_SET_NAME, ...)`) — the analyzer keys threads by
  name forever after. Cross-reference `TLM.4`.
- **No `std::format`, `printf`, or `to_string` in the hot
  path** for telemetry purposes. If a value must be reported,
  emit it as a counter (`TLM.2`) or as a binary payload —
  let the analyzer format.
- **Source-location–keyed zones are the analyzer's friend.**
  `__FILE__:__LINE__` is unique and stable; the analyzer can
  link zones back to source. The profiler library does the
  interning; the call site is just `ZoneScoped`.

## Example

```cpp
// Good: compile-time literal name. The profiler library
// (Tracy, Optick, Insights, ITT) interns the string once at
// first emit; the hot path carries only the handle.
void decode_loop(std::span<const Token> tokens) noexcept {
    APP_ZONE("decode.loop");
    for (const auto& tok : tokens) {
        process_token(tok);
    }
}

// Good: per-iteration variation as a *value*, not a name.
void process_batch(std::span<const Item> items) noexcept {
    for (const auto& it : items) {
        APP_ZONE("process.item");        // static name
        APP_ZONE_VALUE(it.id);            // varying value
        process(it);
    }
}

// Good: static handle (Unity-style). The handle is registered
// once at static-init time; every Begin/End call site crosses
// the handle, not the string.
namespace app {
    static const TraceHandle kDecodeZone =
        MakeZone("decode.loop");

    void decode() noexcept {
        ScopedTrace _z{kDecodeZone};
        // ...
    }
}

// Good: thread names set once at thread creation. The analyzer
// keys the timeline by name forever after.
void worker_thread_main(int worker_id) {
    char name[16];
    std::snprintf(name, sizeof(name), "app-worker-%d", worker_id);
    pthread_setname_np(pthread_self(), name);   // Linux/glibc
    // (different signature on macOS; SetThreadDescription on Windows)

    // ... work loop ...
}

// Bad: dynamic name on every iteration. Allocation, format,
// copy, all to give every event a distinct name the analyzer
// would have parameterised for you.
void process_batch_bad(std::span<const Item> items) noexcept {
    for (const auto& it : items) {
        const auto name = std::format("process.item[{}]", it.id);
        APP_ZONE(name.c_str());      // alloc + format + copy
        process(it);
    }
}
```

## Caveats

- **Truly distinct names sometimes matter.** A scheduler with
  N task kinds may genuinely need N distinct zone names. The
  answer is N distinct static handles, not a dynamic
  template. If the task kinds are open-ended, the right
  primitive is *bookmarks* (`TLM.7`) or *counters* (`TLM.2`),
  not zones.
- **`__FILE__` paths can be long and leak directory
  structure into the trace.** Tracy and most profilers
  truncate or basename; verify before assuming the trace is
  publishable.
- **Static initialization order across translation units
  affects handle availability.** A handle declared `static
  const` at namespace scope in one TU is not guaranteed to
  be initialised before code in another TU runs. Function-
  local statics (Meyers singletons) are safer for
  cross-TU use.
- **String interning is the profiler library's
  responsibility, not yours.** Do not roll your own
  interning at the call site; use the library's handle or
  source-location primitive. Custom interning behind the
  macro layer is fine; custom interning at each call site is
  noise.
- **Compile-time string concatenation (`"prefix." + name`) of
  string literals is fine** — the result is a single literal.
  Runtime concatenation is not.

## References

- Tracy Profiler — source-location interning via
  `SourceLocationData` — <https://github.com/wolfpld/tracy>
- Tracy manual — `ZoneScoped`, `ZoneScopedN`, `ZoneValue`
  semantics —
  <https://github.com/wolfpld/tracy/blob/master/manual/tracy.tex>
- Unity, *Profiling Core API* — static `ProfilerMarker`
  handles, "Begin/End are conditionally compiled away" —
  <https://docs.unity3d.com/Packages/com.unity.profiling.core@1.0/manual/profilermarker-guide.html>
- Perfetto, *Track Events* — `StaticString` vs `DynamicString`
  warning — <https://perfetto.dev/docs/instrumentation/track-events>
- Unreal Engine, *Trace Developer Guide* — dynamic string
  overhead warning —
  <https://dev.epicgames.com/documentation/unreal-engine/developer-guide-to-tracing-in-unreal-engine>
- Intel ITT API — `__itt_string_handle_create`,
  `__itt_task_begin` handle model —
  <https://github.com/intel/ittapi>
- Linux man page, `pthread_setname_np(3)`.
- Microsoft Learn, `SetThreadDescription` — Windows thread
  naming.
- Cross-reference: `TLM.2` (channels), `TLM.4` (the macro
  layer that hides the handle machinery), `TLM.5`
  (structured records — the handle is the "name field" of
  the record).
