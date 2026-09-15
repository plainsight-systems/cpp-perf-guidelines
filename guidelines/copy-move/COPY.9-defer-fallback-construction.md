+++
id = "COPY.9"
title = "Defer fallback construction: value_or and try_emplace evaluate their argument even when it is unused"
category = "copy-move"
status = "draft"
summary = "C++ evaluates every argument before the call, so value_or and try_emplace can build a fallback that is never used. Defer it with a lazy factory or or_else, and remember deferral is not caching."
tags = ["eager-evaluation", "lazy-defaults", "value_or", "try_emplace", "temporaries"]
+++

## Rationale

Every function argument is fully evaluated before the callee runs. That is a
language rule, not an optimization the compiler is free to skip. So an API that
accepts a ready value and uses it only in a branch that may not execute still
pays, at the call site, to build that value on every call.

The cost is invisible in review because the call reads as a plain default. The
work only appears later, in a profiler, as a constructor or an allocation no one
can account for.

Two standard-library shapes are the common offenders, and any value-sink API
that takes an already-built argument has the same shape:

- `optional::value_or(x)` constructs `x` even when the optional is engaged and
  `x` is thrown away.
- `map::try_emplace(k, v)` evaluates `v` at the call site even when `k` is
  already present. `try_emplace` is designed to avoid constructing the *mapped
  element* on a hit, but it cannot un-evaluate an argument you already built and
  handed it.

The fix is to hand the sink something cheap to construct that produces the value
only if the branch is taken: a facility that is lazy by design, or a small lazy
factory.

## Guidance

- **Recognize the shape.** Any API that takes a value as an argument and uses it
  only in a fallback, insert, or error branch evaluates that argument eagerly.
  The eager cost is the argument, independent of what the callee does with it.
- **Prefer a lazy-by-design facility when one exists.** `optional::or_else`
  (C++23) invokes its callable only when the optional is empty. For a map miss, a
  plain `find` followed by `emplace` builds the value only on the miss.
- **For `try_emplace`, pass cheap constructor arguments, not a pre-built value.**
  `try_emplace(k, ctor_args...)` defers the mapped construction to the insert
  branch. That deferral is real only when the arguments themselves are cheap to
  evaluate. If producing the value is the expensive part, `try_emplace` does not
  help; check first, or use a lazy factory.
- **When no lazy overload exists, pass a lazy factory.** A tiny wrapper that
  stores a callable and converts to the target type only when the sink reads it
  restores laziness for any value-argument API. It requires a non-explicit
  conversion operator to satisfy sinks like `value_or`; that is a deliberate
  exception to Core Guidelines C.164, so keep the type single-purpose and local
  (see Caveats).
- **Reserve it for values that cost something.** For an `int` or a small
  trivially-constructed default, eager evaluation is free and a wrapper is pure
  noise. This is a technique for defaults that allocate or do real work.

## Example

```cpp
#include <optional>
#include <string>
#include <map>
#include <type_traits>

std::string expensive_default();   // allocates / does real work

// BAD: value_or constructs its argument unconditionally.
std::string name_bad(const std::optional<std::string>& opt) {
    return opt.value_or(expensive_default());   // built even when opt is engaged
}

// GOOD (C++23): or_else runs the callable only on the empty branch.
std::string name_good(const std::optional<std::string>& opt) {
    return opt.or_else([] {
        return std::optional<std::string>{expensive_default()};
    }).value();
}

// GENERAL: a lazy factory for any value-sink with no lazy overload.
// It converts to T only when the sink actually reads it.
template <class F>
struct Lazy {
    F make;
    // Implicit by necessity: value_or constrains on is_convertible_v, so an
    // explicit operator fails to compile. Deliberate C.164 exception (Caveats).
    operator std::invoke_result_t<const F&>() const { return make(); }
};
template <class F> Lazy(F) -> Lazy<F>;

std::string name_lazy(const std::optional<std::string>& opt) {
    return opt.value_or(Lazy{[] { return expensive_default(); }});  // built only if empty
}

// BAD: the argument is evaluated before try_emplace is entered.
void cache_bad(std::map<int, std::string>& m, int key) {
    m.try_emplace(key, expensive_default());   // built every call, used only on insert
}

// GOOD: build the value only on the miss.
void cache_good(std::map<int, std::string>& m, int key) {
    if (auto it = m.find(key); it == m.end())
        m.emplace(key, expensive_default());
}
```

## Caveats

- **Deferral is not memoization.** A lazy factory recomputes on every
  conversion. The name misleads: `lazy` in many languages memoizes on first
  access (Kotlin `by lazy`, Scala `lazy val`, C# `Lazy<T>`), so the reflex is to
  hoist one lazy value and reuse it. This wrapper does not cache. Reuse it across
  loop iterations that all hit the fallback and you turn one evaluation into N,
  reintroducing the cost you removed. If you need compute-once, hoist the
  computed value into a variable, or use a memoizing lazy.
- **`or_else` changes the return type to `optional<T>`.** Its callable must
  return `optional<T>`, not `T`; chain `.value()` or handle `nullopt`
  deliberately.
- **Confirm the sink is genuinely conditional.** The wrapper only pays off if the
  callee reads the argument in a branch that is often not taken. If the value is
  almost always used, laziness buys nothing and costs a conversion.
- **The lazy factory needs an implicit conversion operator, against C.164.**
  `value_or` constrains its argument on `is_convertible_v`, so an `explicit`
  conversion operator fails to compile ("U must be convertible to T"). The
  implicit conversion is therefore required — a "serious need" exception to Core
  Guidelines C.164 (avoid implicit conversion operators). Contain the risk C.164
  warns about: make the wrapper a single-purpose type used only at these call
  sites, never a general vocabulary type, and give it nothing else that could
  convert in a surprising context.
- **`find` + `emplace` does two lookups.** The check-then-insert form traverses
  the map twice on a miss. Where that second lookup matters, use `lower_bound` to
  locate the insertion point once and `emplace_hint` there; the eager-evaluation
  point is unchanged.
- **Do not preempt the profiler.** When the default is cheap, this is a
  pessimization of readability. Apply it where the eager construction shows up in
  a measurement (Core Guidelines Per.1, Per.6).

## References

- cppreference: `std::optional::value_or`, `std::optional::or_else` (C++23),
  `std::map::try_emplace` —
  <https://en.cppreference.com/w/cpp/utility/optional/or_else>,
  <https://en.cppreference.com/w/cpp/container/map/try_emplace>
- ISO C++ `[expr.call]`: each argument is initialized before the call —
  <https://eel.is/c++draft/expr.call>
- C++ Core Guidelines Per.1 / Per.6 (don't optimize without reason; measure) —
  **cite-by-reference**.
- C++ Core Guidelines C.164 (avoid implicit conversion operators) — the
  lazy-factory tradeoff —
  <https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines#c164-avoid-implicit-conversion-operators>
- Related in this corpus: `COPY.7` (hidden temporaries at call boundaries),
  `COPY.3` (sink-parameter shape).
