+++
id = "TLM.7"
title = "Sparse bookmarks for state changes — bookmarks are for transitions, not per-iteration progress"
category = "telemetry"
status = "draft"
summary = "Bookmarks annotate rare events that change interpretation (policy switches, scene loads, GC). Per-iteration bookmark spam is documented overhead in every profiler that warns about it."
tags = ["bookmarks", "events", "unreal-trace", "csv-profiler", "tracy-message"]
+++

## Rationale

Profilers expose a *bookmark* primitive — Unreal's
`TRACE_BOOKMARK`, the CSV Profiler's `CSV_EVENT`, Tracy's
`TracyMessage`, Perfetto's instant events. The shape is the
same: a sparse, named annotation on the timeline that the
analyzer treats as a marker, not a sample.

Bookmarks are for **transitions** — the moments where the
interpretation of the rest of the timeline changes:

- A scheduling policy switched.
- A scene loaded.
- The garbage collector ran.
- An allocator was reset.
- A user pressed pause.
- The renderer changed quality tier.
- An MTP policy decision was made (the Vigil example).

They are not for progress. A bookmark per token in a decode
loop, per pixel in a render loop, per row in a database scan,
or per request in a server is the documented anti-pattern —
Unreal's docs explicitly warn that overuse of bookmarks
"creates performance and memory overhead," and the CSV
Profiler docs say the same about `CSV_EVENT`.

Why bookmarks are different from CPU zones in cost:

- A bookmark typically carries a **string** (the name of the
  state change). Even with interning (`TLM.3`), each
  bookmark emit costs more than a zone-begin/zone-end pair
  because the analyzer treats bookmarks as significant.
- Bookmarks are often stored in a **separate, smaller
  buffer** sized for the expected frequency. A flood
  overflows the bookmark buffer well before it overflows the
  zone ring.
- Some analyzers materialise bookmarks **eagerly** —
  rendering them at every zoom level, indexing them for
  search. A million bookmarks degrades the analyzer UX,
  independent of the producer cost.

The right frequency model:

- **Bookmarks per minute, not per millisecond.** If a
  bookmark fires more than ~10 times a second across the
  whole capture, ask whether it should be a counter (TLM.2)
  or a CPU zone (TLM.4) instead.
- **One bookmark per *transition*, not per *iteration in
  which a transition is possible*.** A policy that is
  evaluated every iteration but changes rarely should
  produce one bookmark when it actually changes, not one
  per evaluation.
- **Bookmark names describe the new state, not the event.**
  "policy=conservative" or "scene=desert_outpost" rather
  than "policy_change_event_3271".

For high-frequency state changes, the right primitive is a
*counter* (TLM.2) tracking the current state's encoded
value, or a *zone* covering the state's duration. Bookmarks
are reserved for the genuinely sparse.

## Guidance

- **Emit bookmarks only at transitions.** The pattern is
  "compare new state to old; if changed, bookmark with the
  new state." If old equals new, no bookmark.
- **Name the new state, not the event.** `bookmark("policy=
  conservative")` reads in the analyzer; `bookmark("policy_
  changed")` requires looking at the previous bookmark to
  know what changed to what.
- **Treat bookmark frequency as a budget.** Tens per second
  is high; per-iteration is wrong. If you find yourself
  emitting a bookmark inside a hot loop, switch to a
  counter or a zone.
- **For state with N possible values, encode it as a counter.**
  `TracyPlot("mtp.policy", policy_id)` produces a step
  function in the analyzer that conveys exactly the same
  information as a bookmark per transition, at lower cost
  and with a cleaner UI.
- **For state that exists for a duration, use a zone.**
  `ZoneScopedN("scene.desert_outpost")` for the lifetime of
  the scene captures both the transition and the duration,
  and the analyzer aggregates across scenes.
- **Cross-reference `TLM.2`.** Bookmarks are one channel
  among many; choose the right one for the cost model.

## Example

```cpp
// Good: bookmark only on transition. Comparing the current
// policy to the new one; bookmarking the new state's name.
namespace vigil::mtp {
    enum class Policy { kConservative, kBalanced, kAggressive };

    void apply_policy(Policy desired) noexcept {
        VIGIL_ZONE("mtp.apply_policy");
        if (desired == current_policy_) return;

        // Transition. Bookmark with the new state.
        switch (desired) {
            case Policy::kConservative:
                VIGIL_BOOKMARK("mtp.policy=conservative"); break;
            case Policy::kBalanced:
                VIGIL_BOOKMARK("mtp.policy=balanced"); break;
            case Policy::kAggressive:
                VIGIL_BOOKMARK("mtp.policy=aggressive"); break;
        }
        current_policy_ = desired;
        // ... apply ...
    }
}

// Good: state-as-counter. The analyzer plots the policy id
// as a step function; transitions are visually obvious; the
// runtime cost is one counter sample per evaluation.
void evaluate_policy_every_step(std::span<const Sample> samples) noexcept {
    for (const auto& s : samples) {
        const Policy p = choose_policy(s);
        VIGIL_COUNTER("mtp.policy", static_cast<std::uint64_t>(p));
        apply_policy(p);                  // bookmark only on transition
    }
}

// Bad: per-iteration bookmark spam. Even with interning, the
// bookmark buffer overflows quickly, the analyzer UI becomes
// unreadable, and the runtime pays the cost on every emit.
void evaluate_policy_every_step_bad(std::span<const Sample> samples) noexcept {
    for (const auto& s : samples) {
        const Policy p = choose_policy(s);
        VIGIL_BOOKMARK("policy_evaluated");          // every iteration
        VIGIL_BOOKMARK("chose_policy");              // every iteration
        apply_policy(p);
    }
}

// Bad: bookmark name describes the event, not the state. To
// read this in the analyzer you have to look at the
// previous and next bookmarks to know "from what to what."
void apply_policy_bad(Policy desired) noexcept {
    if (desired != current_policy_) {
        VIGIL_BOOKMARK("policy_changed");            // change to what?
        current_policy_ = desired;
    }
}
```

## Caveats

- **Genuinely sparse high-cardinality bookmarks are
  fine.** A bookmark per scene-load in a game produces one
  per few minutes of capture; nothing wrong with that. The
  rule is *not* "few distinct names"; it is "few emits per
  unit time."
- **Tracy's `TracyMessage` is closer to a structured log
  line than a bookmark.** It carries arbitrary string
  payloads and is sometimes used for things bookmarks are
  not the right primitive for. Read the manual; pick by
  intent.
- **Bookmarks are visible to humans by default.** If a
  bookmark name leaks internal jargon, the analyzer view
  becomes hard to share with non-engineers. Pick names that
  read across the team.
- **Counters and zones are not always cheaper.** A counter
  that updates every iteration is still an emit per
  iteration; the saving over bookmarks is that the analyzer
  storage and UI cost is lower, not that the producer cost
  is zero. For genuinely-very-hot paths, even counters
  should be sampled at frame boundaries (TLM.2).
- **The state-as-counter trick assumes the state is
  enumerable.** For continuous state (a float threshold, a
  rolling average), the right primitive is the counter
  directly with the actual value, not the state's category
  encoding.

## References

- Unreal Engine, *Trace Developer Guide* — `TRACE_BOOKMARK`
  and the warning about overuse —
  <https://dev.epicgames.com/documentation/unreal-engine/developer-guide-to-tracing-in-unreal-engine>
- Unreal Engine, *CSV Profiler* — `CSV_EVENT` overuse
  warning —
  <https://dev.epicgames.com/documentation/en-us/unreal-engine/csv-profiler>
- Tracy Profiler — `TracyMessage`, instant events —
  <https://github.com/wolfpld/tracy>
- Perfetto — instant events and slices —
  <https://perfetto.dev/docs/instrumentation/track-events>
- Chrome Trace Event format — `i` (instant) phase —
  <https://docs.google.com/document/d/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/preview>
- Cross-reference: `TLM.2` (bookmarks are one channel;
  counters and zones are the alternatives for higher-
  frequency state), `TLM.3` (bookmark names benefit from
  interning), `TLM.6` (per-iteration bookmark spam in a
  benchmark build is a clean-baseline contaminant).
