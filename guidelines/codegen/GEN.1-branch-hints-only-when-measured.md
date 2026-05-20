+++
id = "GEN.1"
title = "Use [[likely]] / [[unlikely]] only on measured or structurally-cold branches"
category = "codegen"
status = "draft"
summary = "Branch hints change code layout, not the dynamic predictor. They help when the compiler has no other signal; they are noise under PGO; a wrong hint forces the hot path out-of-line and costs I-cache."
tags = ["branch-hints", "likely", "pgo", "i-cache"]
+++

## Rationale

`[[likely]]` (C++20), `[[unlikely]]` (C++20), and `__builtin_expect` (GCC,
Clang) do not configure the CPU's dynamic branch predictor. Modern x86
and ARM predictors are dynamic and ignore static hints at runtime. What
the hints actually change is **code layout**: the hot path is placed as
fall-through and contiguous; the cold path is pushed out-of-line or to a
cold section. That layout shift indirectly helps the initial prediction
(most CPUs predict forward branches not-taken, backward branches taken)
and — more importantly — reduces I-cache pressure on the hot path.

Two consequences follow:

- **Hints help when the compiler has no other signal.** A hot loop with a
  rare error or assertion path, in code that has not been built with PGO,
  is the canonical case.
- **Hints are noise — or worse — when the compiler already knows.** PGO
  produces real probabilities that dominate static hints. Calls to
  `abort`, `throw`, `__builtin_unreachable` already mark blocks cold
  without any annotation. A *wrong* hint forces the hot path
  out-of-line, costing I-cache and front-end fetch cycles.

Linus Torvalds has repeatedly criticised `likely` / `unlikely` abuse in
the Linux kernel: most developers' intuitions about branch probabilities
are wrong, and bad hints are worse than no hints. The kernel has actively
removed annotations where measurement showed they were wrong. The rule
for engines: hint only branches you have **measured** or where the cold
path is **structurally guaranteed**.

## Guidance

- **Default: no annotation.** The compiler's heuristics, plus the
  implicit "calls to `abort` / `throw` / `__builtin_unreachable` are
  cold" rule, cover the common cases.
- **Annotate when you have measurement** showing a specific branch is
  hot and the compiler has no other signal.
- **Annotate when the cold side is structurally guaranteed** — an
  early-return error path, a debug assertion, a precondition check
  that fails only on programmer error.
- **Do not annotate under PGO.** Profile data dominates; static hints
  are noise that may *disagree* with measured behaviour.
- **Do not annotate cold paths twice.** A branch whose taken side is
  `abort()` is already cold by the call; an `[[unlikely]]` on that arm
  is redundant.
- **Prefer the C++20 attribute** (`[[likely]]` / `[[unlikely]]`) to
  `__builtin_expect` — portable across GCC, Clang, and MSVC, and
  attached to the statement / label rather than the expression.

## Example

```cpp
// Good: a structurally-cold error path in a hot loop. The compiler
// already gets this right because `throw` and `abort` mark blocks cold,
// but the annotation is clearer to a human reader and survives changes
// that move the throw behind a helper.
void process(std::span<const Packet> packets) {
    for (const auto& p : packets) {
        if (!p.is_valid()) [[unlikely]] {
            return raise_protocol_error(p);
        }
        handle(p);
    }
}

// Good: a measured assertion in a hot path. We profiled; the predicate
// is true ~99.9% of the time; the cold side is logging plus an early
// out. The hint moves the log call out-of-line.
void update(World& w) {
    if (w.is_consistent()) [[likely]] {
        step(w);
    } else {
        log_inconsistent(w);
        return;
    }
}

// Bad: hinting both sides "to be safe." The hot side is the one the
// compiler picks; conflicting hints just confuse the layout pass.
void scan_bad(std::span<const int> v) {
    for (auto x : v) {
        if (x > 0) [[likely]] {
            count_pos();
        } else [[unlikely]] {       // redundant — see "Caveats"
            count_neg();
        }
    }
}

// Bad: hinting under PGO. The profile says positive is 60 / 40; the
// static hint says it is 99 / 1. The compiler will believe the profile;
// the hint is noise and disagrees with reality.
```

## Caveats

- **PGO subsumes hints (`GEN.5`).** Once a project ships with PGO, audit
  the hints — many will become noise, some will contradict the profile.
- **A wrong hint is worse than no hint.** Misplacing `[[likely]]` puts
  the hot path out-of-line; the I-cache penalty is silent.
- **`[[likely]]` on a single arm of a two-arm `if` already implies
  `[[unlikely]]` on the other.** Annotating both sides adds nothing.
- **Hot paths inside cold functions.** Marking the enclosing function
  `[[gnu::cold]]` (`GEN.7`) does not undo `[[likely]]` on an inner
  branch. The two affect different optimiser passes.
- **Branch hints are not branch *prediction*.** They cannot fix mispredicts
  on unpredictable data; `cmov` and branchless arithmetic (`GEN.2`) are
  the tool for that.
- **MSVC differs.** MSVC honours `[[likely]]` / `[[unlikely]]` but does
  not expose `__builtin_expect` — another reason to prefer the
  attribute.

## References

- cppreference, `[[likely]]` / `[[unlikely]]` —
  <https://en.cppreference.com/w/cpp/language/attributes/likely>
- GCC, `__builtin_expect` and related —
  <https://gcc.gnu.org/onlinedocs/gcc/Other-Builtins.html>
- Chandler Carruth, *Tuning C++: Benchmarks, and CPUs, and Compilers!
  Oh My!*, CppCon 2015 —
  <https://www.youtube.com/watch?v=nXaxk27zwlk>
- Linus Torvalds on `likely` / `unlikely` (LKML, recurring) — example
  <https://lwn.net/Articles/255364/>
- Cross-reference: `GEN.5` (PGO subsumes static hints), `GEN.7`
  (hot / cold function placement), `GEN.2` (branchless when the issue
  is predictability, not layout).
