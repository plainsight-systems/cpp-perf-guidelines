+++
id = "TLM.5"
title = "Structured events with a schema, not stderr text — hot path writes records; the analyzer formats"
category = "telemetry"
status = "draft"
summary = "`printf`/`fprintf` on the hot path is an unbounded cost. Mature profilers emit compact binary records with a published or versioned schema; formatting happens offline, in the analyzer."
tags = ["structured-events", "binary-format", "chrome-trace", "perfetto", "ctf", "schema"]
+++

## Rationale

Text output on a performance-sensitive path is, by every
measurement that has ever been published, slower than people
expect. `printf`/`fprintf`/`std::cout`/`std::format` carry:

- Locale lookup and conversion (`LC_NUMERIC`, decimal
  separator).
- Allocator interaction (the formatted string lives somewhere).
- `stdio` buffer locks (`flockfile`/`funlockfile` on most
  libcs) — a hidden mutex acquired on every call.
- Syscall traffic on flush (`write(2)`, possibly `dup2`'d to a
  pipe, possibly through a TTY driver).
- Format-string parsing — for `printf`, every emit re-parses the
  format string at runtime.

None of this matters at human-speed logging (tens of events
per second). On a hot path emitting hundreds of thousands of
events per second, it dominates the measurement.

The mature pattern is **structured binary records with a
documented schema**, written to a per-thread buffer (see
`TLM.10`), and formatted *offline* by a separate analyzer.
Examples:

- **Chrome Trace Event format** — JSON with documented phase
  letters (`B`/`E`/`X` for begin/end/complete, `i` for
  instant, `C` for counter, `b`/`e` for async begin/end,
  `s`/`t`/`f` for flow, `M` for metadata). Consumed by
  `chrome://tracing` and Perfetto UI.
- **Perfetto protobuf trace format** — schema is the protobuf
  `.proto` file; producers and consumers share it as a
  contract.
- **CTF (Common Trace Format)** — Linux Foundation; LTTng's
  binary format; a metadata header describes the layout of
  the binary stream.
- **Unreal Insights binary trace** — schema is implicit in the
  Insights tooling version.
- **Tracy binary stream** — schema is internal; runtime and
  viewer are version-locked.
- **ETW (Event Tracing for Windows)** — manifest-described
  binary events; consumers read the manifest to decode.

The schema is **ABI**. Once a producer emits a record in a
given layout, every consumer that reads the trace must parse
that layout. Two failure modes follow:

1. **Implicit layout via `struct`.** A producer that writes
   `MyEvent{.t=now, .name=ptr, .value=v}` and casts to bytes
   has a schema — the C++ struct layout, which depends on
   the compiler, ABI, alignment, and field order. Changing
   any of those breaks consumers silently.

2. **Version-locked private schema.** A profiler like Tracy
   ships its schema alongside the viewer; runtime and viewer
   are upgraded together. This is a documented choice with
   documented consequences (you cannot mix Tracy 0.9
   captures with Tracy 0.10 viewer); it is not an
   accidentally evolving schema.

The right defaults:

- For **interop** (analyzers from multiple vendors,
  cross-team captures, long-lived archives) — choose a
  published format (Chrome Trace Event, Perfetto, CTF).
- For **self-contained capture** (one profiler library
  shipping with the binary, one viewer) — version-lock the
  schema and treat the version as ABI.

What never works: text output on the hot path. The cost is
unbounded; the analyzer must re-parse what the producer just
formatted; the schema is "whatever the format strings happen
to produce."

## Guidance

- **No `printf`/`fprintf`/`std::format`/`std::cout` on the
  hot path** for telemetry. Reserve text output for
  startup, shutdown, fatal errors, and tools-mode output.
- **Emit compact binary records.** Fixed-width fields where
  possible; variable-width data (names, payloads) referenced
  by handle (`TLM.3`).
- **Pick the schema deliberately.** Either a published
  format (Chrome Trace Event JSON, Perfetto protobuf, CTF)
  or a versioned private one. Document the choice.
- **Treat the schema as ABI.** Bump the version on any
  layout change. The consumer reads the version first and
  branches on it; never reads an unknown version as a known
  one.
- **Avoid raw-struct serialisation.** `reinterpret_cast<const
  std::byte*>(&event)` couples the trace to the C++ struct
  layout and the compiler/ABI. Use explicit field-by-field
  writes (`memcpy` of each field at a known offset) or a
  serialisation library with stable layout.
- **Formatting happens in the analyzer.** Names, units, time
  conversions, human-readable timestamps — none of these
  are the runtime's job. The runtime emits microseconds (or
  ticks); the analyzer presents "1.234 ms."
- **Stderr remains valid for startup banners and fatal
  errors.** A clean shutdown summary, a fatal abort message
  — these are not telemetry; they are logging. The rule is
  "no text *on the hot path*."

## Example

```cpp
// Good: compact binary record, fixed layout, version-tagged.
// The hot path writes one record; the analyzer formats.
#pragma pack(push, 1)
struct AppEventV1 {
    std::uint8_t  version;       // 1
    std::uint8_t  kind;          // 0=zone-begin, 1=zone-end, 2=counter
    std::uint16_t name_handle;   // interned-name index (TLM.3)
    std::uint64_t timestamp_ns;  // monotonic ns since epoch
    std::uint64_t value;         // counter value or thread id
};
#pragma pack(pop)

void emit_event(EventKind kind, std::uint16_t name_handle,
                std::uint64_t value) noexcept {
    AppEventV1 ev{
        .version = 1,
        .kind = static_cast<std::uint8_t>(kind),
        .name_handle = name_handle,
        .timestamp_ns = monotonic_ns(),    // see TLM.9
        .value = value,
    };
    // TLM.10: write to per-thread ring buffer, lossy on overflow.
    write_to_ring(&ev, sizeof(ev));
}

// Good: emitting in a published format (Chrome Trace Event)
// for interop. JSON is heavier than binary but every analyzer
// in this space reads it.
void emit_chrome_trace_zone(const char* name, std::uint64_t ts_us,
                            std::uint64_t dur_us, int tid) noexcept {
    // Pre-formatted into a thread-local buffer; the buffer is
    // flushed in chunks, not per-event.
    auto& buf = thread_local_buffer();
    fmt::format_to(std::back_inserter(buf),
        R"({{"name":"{}","ph":"X","ts":{},"dur":{},"pid":1,"tid":{}}},)",
        name, ts_us, dur_us, tid);
}

// Bad: text on the hot path. Locale lookups, allocator
// interaction, stdio lock, syscall flush — none of which the
// decode loop should pay for.
void on_token_bad(std::uint32_t token_id, float prob) noexcept {
    fprintf(stderr, "decoded token %u with prob %.6f\n",
            token_id, prob);
    // Worse: includes the format string in the binary (cache
    // miss), parses it every call, locks stdio, calls write().
}

// Bad: raw-struct serialisation. Schema is the C++ struct
// layout, which is compiler/ABI-dependent. Adding a field or
// changing alignment silently breaks every consumer.
struct InternalEvent {        // no version, no pack pragma
    std::string name;          // pointer + size, ABI-variant
    std::chrono::steady_clock::time_point ts;   // opaque
    double value;
};
void emit_bad(const InternalEvent& e) noexcept {
    fwrite(&e, sizeof(e), 1, trace_file);   // pointer-bytes!
}
```

## Caveats

- **Per-event syscall on a binary path is just as bad as text.**
  The point of the binary format is to write to a per-thread
  buffer (`TLM.10`); writing each binary record straight to
  the file dominates regardless of encoding.
- **Chrome Trace JSON is verbose.** For very-high-rate
  capture, the JSON parser at the viewer side becomes the
  bottleneck. Perfetto protobuf is the standard upgrade
  path; CTF is the binary alternative.
- **Version bumps must be readable.** A consumer reading an
  unknown version should print a clear error, not parse the
  bytes as a known version. "Newer trace, please upgrade
  your viewer" is the right failure mode.
- **Floating-point in traces is sometimes wrong.** Time as
  `double seconds` loses precision at long runs; time as
  `uint64_t nanoseconds since boot` does not. Prefer integer
  timestamps.
- **Endianness matters for cross-platform captures.** A
  binary trace produced on little-endian and read on
  big-endian (rare today, but real for embedded) needs
  explicit byte-order declarations in the schema.
- **A schema is not the same as a format.** Two profilers
  may both emit "Chrome Trace Event JSON" but disagree on
  what goes in the `args` field. The format constrains the
  shape; the schema constrains the meaning. Pin both.

## References

- *Trace Event Format* (Chrome / Perfetto-compatible JSON) —
  <https://docs.google.com/document/d/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/preview>
- Perfetto, *Track Events* (protobuf schema model) —
  <https://perfetto.dev/docs/instrumentation/track-events>
- LTTng documentation, *CTF (Common Trace Format)* —
  <https://lttng.org/docs/>
- Unreal Engine, *Trace Developer Guide* — binary structured
  events — <https://dev.epicgames.com/documentation/unreal-engine/developer-guide-to-tracing-in-unreal-engine>
- Tracy Profiler — binary protocol, version-locked viewer —
  <https://github.com/wolfpld/tracy>
- Microsoft Learn, *Event Tracing for Windows (ETW)
  Manifest* — <https://learn.microsoft.com/en-us/windows/win32/etw/>
- Cross-reference: `TLM.3` (names are interned; the schema
  carries handles, not strings), `TLM.4` (the macro layer
  hides the schema choice), `TLM.9` (timestamp source and
  format — integer ticks/ns, not floating-point seconds),
  `TLM.10` (records are written to per-thread buffers,
  drained externally — not direct file I/O).
