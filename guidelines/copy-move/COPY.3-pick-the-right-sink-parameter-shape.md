+++
id = "COPY.3"
title = "Pick the right sink-parameter shape"
category = "copy-move"
status = "draft"
summary = "Pick sink-parameter shape by API kind: by-value-and-move as default; two overloads for stable non-template APIs; constrained perfect forwarding in templates; never unconstrained."
tags = ["sink-parameter", "perfect-forwarding", "move-semantics"]
+++

## Rationale

A *sink parameter* is a function (often a setter or constructor) that consumes
its argument into storage. It is one of the few places in the language where
the choice of parameter shape directly determines copy/move cost. The four
serious candidates are not equivalent, and the right choice depends on whether
the API is template- or non-template, and whether the API is stable.

Nicolai Josuttis's CppCon 2019 talk *The Nightmare of Move Semantics for
Trivial Classes* dissects the trap that an unconstrained forwarding-reference
sink

```cpp
template <typename T>
void set_name(T&& n);   // unconstrained — binds to the universe
```

happily binds to `int`, `nullptr_t`, derived classes, braced-init-lists, and
swallows overload resolution against other constructors — emitting error
messages no human should have to read. Yet a *constrained* perfect-forwarding
sink is the most efficient form for templates. The shape choice is real.

## Guidance

Pick by API kind:

- **Default (most code): pass-by-value-and-move.** Correct in all cases. Costs
  at most one extra move per call compared to the constrained-forwarding form,
  and is by far the most readable. Reach for anything else only when measured
  perf or a stable-ABI constraint demands it.
- **Stable, non-template APIs: two overloads** — `const T&` and `T&&`. Lowest
  surprise; no template instantiation surprises at the boundary; plays well
  with shared-library ABIs. The right shape for setters in
  reflection/serialization libraries, framework base classes, and public
  vocabulary types.
- **Templates and headers: constrained perfect forwarding.** Use a `requires`
  clause (C++20) or `std::enable_if`/SFINAE (pre-C++20) so the function binds
  only to the intended argument types. This avoids the Josuttis trap and gives
  the best performance on lvalues.
- **Never: an unconstrained forwarding-reference sink.** It is the trap.

The sink should also `noexcept`-move what it consumes (`COPY.2`).

## Example

```cpp
// 1. Default for most code: pass-by-value-and-move.
//    Correct in all cases; at most one extra move vs constrained forwarding.
class Person1 {
public:
    void set_name(std::string n) noexcept { name_ = std::move(n); }
private:
    std::string name_;
};

// 2. Non-template stable APIs: two overloads.
//    Lowest surprise; readable; ABI-friendly.
class Person2 {
public:
    void set_name(const std::string& n)     { name_ = n; }
    void set_name(std::string&& n) noexcept { name_ = std::move(n); }
private:
    std::string name_;
};

// 3. Templates and headers: CONSTRAINED forwarding reference.
//    The constraint is essential — it confines the function to the intended
//    types and gives the compiler something useful to say in error messages.
class Person3 {
public:
    template <std::convertible_to<std::string> S>
    void set_name(S&& n) noexcept(std::is_nothrow_assignable_v<std::string&, S>) {
        name_ = std::forward<S>(n);
    }
private:
    std::string name_;
};

// BAD: an UNCONSTRAINED forwarding-reference sink. Binds to int, nullptr_t,
// derived classes, braced-init-lists; swallows other overloads; fails with
// novella-length template errors when it should not have bound at all.
class PersonBad {
public:
    template <typename T>
    void set_name(T&& n) { name_ = std::forward<T>(n); }   // trap
private:
    std::string name_;
};
```

## Caveats

- **Pass-by-value-and-move costs one extra move** vs constrained forwarding —
  usually negligible. In tight inner loops where the parameter is large and
  the call site usually passes lvalues, the constrained-forwarding template
  can win. Measure before optimizing.
- **Two overloads double the declarations** — manageable for a setter, painful
  for a constructor taking five sink parameters. The combinatorial blowup is
  why templates exist; it is also why the constrained-forwarding form has its
  place.
- **Forwarding constructors swallow other constructors.** A template
  constructor `template<class T> Class(T&&)` will out-rank `Class(int)` for
  `Class(0)`. The constraint must exclude the cases the other constructors
  own; this gets fiddly fast, which is another argument for two overloads in
  vocabulary types.
- **Always `noexcept` what you can** in the sink so containers actually move
  (`COPY.2`).

## References

- Nicolai Josuttis, *The Nightmare of Move Semantics for Trivial Classes*,
  CppCon 2019 — <https://www.youtube.com/watch?v=PNRju6_yn3o>
- Scott Meyers, *Effective Modern C++*, items 25 and 27 — **cite-by-reference**.
- Herb Sutter, "GotW #4: Class Mechanics" and the wider
  pass-by-value-and-move discussion —
  <https://herbsutter.com/gotw/_004/>
- C++ Core Guidelines F.16 (pass cheap-to-copy by value, expensive by ref) /
  F.18 (sink parameters) —
  <https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines#f16-for-in-parameters-pass-cheaply-copied-types-by-value-and-others-by-reference-to-const>
