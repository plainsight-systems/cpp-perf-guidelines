+++
id = "EMB.3"
title = "Build embedded targets with -fno-exceptions and -fno-rtti"
category = "embedded"
status = "draft"
summary = "Exceptions and RTTI add flash, metadata, and unbounded paths. Disable both on embedded targets and use explicit alternatives."
tags = ["no-exceptions", "no-rtti", "noexcept", "variant"]
+++

## Rationale

Two language features carry concrete embedded costs and concrete bans from
the major safety standards:

**Exceptions.** The compiler emits unwind tables (`.ARM.exidx`,
`.eh_frame`, `.gcc_except_table`) into flash for every function with a
non-trivial destructor on the stack — *even functions that never throw*.
On Cortex-M this can add tens of kilobytes of code-size for no runtime
benefit on the no-throw path. Worse, `__cxa_allocate_exception` allocates
via `malloc` by default: a `throw` from an ISR or a tight loop can OOM
through a path the static analyzer cannot bound. MISRA C++ 2008 and 2023
ban exceptions outright; AUTOSAR permits them only under tight
controlled-propagation rules (`EMB.1`); JSF AV C++ bans them.

**RTTI.** Every polymorphic class carries a `type_info` reference in its
vtable; the `type_info` objects themselves (with mangled-name strings) sit
in flash. `dynamic_cast` walks the class hierarchy — *not* O(1), and a
latent WCET problem in deep hierarchies. MISRA and JSF AV C++ ban
`dynamic_cast` and `typeid`; AUTOSAR permits with justification.

`-fno-exceptions` and `-fno-rtti` (GCC, Clang) eliminate both costs. The
replacement pattern for `dynamic_cast` between a closed set of types is
`std::variant` + `std::visit` (or a hand-rolled tagged union) — which
trades open extensibility for compile-time-known cases, exactly the trade
the embedded constraint wants.

## Guidance

- **Build with `-fno-exceptions` and `-fno-rtti`** on the embedded target.
  Code-size savings on Cortex-M are routinely 5–20 % of flash for non-
  trivial codebases; WCET tools can ignore unwind paths they no longer
  exist.
- **Design as if `noexcept` is the default.** Mark constructors,
  destructors, and move operations `noexcept` where the body genuinely
  cannot throw. Destructors are `noexcept` by default since C++11; do not
  weaken them.
- **Replace failure-as-exception APIs.** `std::vector::at` (throws on
  out-of-range), `std::stoi` (throws on parse error), `std::variant::get`
  (throws on wrong alternative) — under `-fno-exceptions` these become
  silent `std::terminate` paths. Prefer non-throwing alternatives
  (`std::expected`, sentinel returns, precondition checks).
- **Replace `dynamic_cast` with closed-set polymorphism.** When the set of
  derived types is known at compile time, `std::variant<...>` + `std::visit`
  is faster, smaller, and compatible with `-fno-rtti`. When the set is
  truly open, redesign — open polymorphism rarely belongs in the embedded
  steady-state path.
- **Configure ETL / EASTL overflow handlers explicitly.** Without
  exceptions, library overflow signals through whatever handler you
  configured (`EMB.2`); do not leave it as the default `abort()` if you
  have a better fault path.

## Example

```cpp
// Bad: a base + derived hierarchy resolved at runtime with dynamic_cast.
// Requires RTTI; fails to compile under -fno-rtti; even with RTTI the
// hierarchy walk has no useful WCET bound.
struct ShapeBase { virtual ~ShapeBase() = default; };
struct Circle    : ShapeBase { float r; };
struct Square    : ShapeBase { float s; };

float area_bad(ShapeBase& shape) {
    if (auto* c = dynamic_cast<Circle*>(&shape)) return 3.14159f * c->r * c->r;
    if (auto* q = dynamic_cast<Square*>(&shape)) return q->s * q->s;
    return 0.0f;
}

// Good: closed-set polymorphism via std::variant + std::visit. No RTTI;
// no vtable; the compiler sees every case at the visit site and can inline
// each one. Adding a new shape is a localised compile error rather than a
// silent fall-through.
struct Circle2 { float r; };
struct Square2 { float s; };
using Shape = std::variant<Circle2, Square2>;

float area(const Shape& shape) {
    return std::visit([](const auto& s) -> float {
        using T = std::decay_t<decltype(s)>;
        if constexpr (std::is_same_v<T, Circle2>) return 3.14159f * s.r * s.r;
        else if constexpr (std::is_same_v<T, Square2>) return s.s * s.s;
    }, shape);
}

// Bad: a function whose failure mode is an exception under hosted C++ is
// a silent terminate under -fno-exceptions.
int parse_id_bad(std::string_view s) {
    return std::stoi(std::string{s});   // throws std::invalid_argument;
                                        // -> std::terminate under -fno-exceptions
}

// Good: explicit failure as a value. std::from_chars never throws.
std::optional<int> parse_id(std::string_view s) {
    int out{};
    auto [p, ec] = std::from_chars(s.data(), s.data() + s.size(), out);
    if (ec != std::errc{}) return std::nullopt;
    return out;
}
```

## Caveats

- **`noexcept` must be honest.** A `noexcept`-declared function whose body
  can throw calls `std::terminate` on the throw. With `-fno-exceptions`
  there is no throw, but a third-party library compiled *with* exceptions
  may still introduce one across the ABI boundary. Audit linked code.
- **Some libraries assume exceptions** and either fail to compile under
  `-fno-exceptions` or produce no-op error paths that are worse than the
  original. Newer-style libraries using `std::expected` and `tl::expected`
  are the right fit.
- **`-fno-rtti` does not break virtual functions** — only `dynamic_cast`
  between polymorphic types and `typeid` on them. Virtual dispatch itself
  is unaffected; the cost story for virtual dispatch is separate (WCET
  pessimism, vtable size).
- **`std::variant` + `std::visit` has its own costs.** The variant carries
  a discriminator and uses a generated jump table for the visit. For most
  cases this beats `dynamic_cast`; for two-or-three case sets, a hand-
  rolled `enum class` + `switch` is often smaller still.
- **Mixed-mode builds are real.** A library compiled with `-fexceptions`
  linked against an application compiled with `-fno-exceptions` mostly
  works, but throws from the library still unwind through your code and
  may hit `std::terminate` at a function boundary. Build the whole tree
  the same way when you can.

## References

- AUTOSAR C++14 Coding Guidelines — sections on exceptions and `dynamic_cast`
  — <https://www.autosar.org/fileadmin/standards/R22-11/AP/AUTOSAR_RS_CPP14Guidelines.pdf>
- GCC, `-fno-exceptions` / `-fno-rtti` —
  <https://gcc.gnu.org/onlinedocs/gcc/C_002b_002b-Dialect-Options.html>
- Ben Saks, *Back to Basics: `volatile`*, CppCon (also discusses
  embedded-C++ subset choices) — search:
  <https://www.youtube.com/results?search_query=ben+saks+volatile+cppcon>
- bitbashing.io, *C++ on Embedded Systems* —
  <https://bitbashing.io/embedded-cpp.html>
- Cross-reference: `EMB.1` (which standard requires which ban), `EMB.2`
  (containers configured for no-exceptions overflow).
