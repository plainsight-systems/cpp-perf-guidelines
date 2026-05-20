+++
id = "LIFE.6"
title = "Avoid the static-initialization-order fiasco with the function-local-static idiom"
category = "lifetime"
status = "draft"
summary = "Two namespace-scope statics in different translation units have unspecified construction order. Wrap them in a function returning a reference; C++11 guarantees safe initialisation on first call."
tags = ["static-initialization", "lifetime", "construct-on-first-use"]
+++

## Rationale

Within a single translation unit, namespace-scope statics are constructed
in declaration order. **Across translation units the order is unspecified.**
If one TU's static needs the value of another TU's static during its own
construction, the order may be wrong and the access reads an uninitialised
object — the classic *static-initialization-order fiasco*. The bug is
unreproducible-looking: it depends on link order, optimisation level, or
which day the compiler's mood changed.

The fix is older than C++11 and is now better-supported than ever:

- Hide the static behind a function that constructs it on first use.
- Return a reference. The static is local to the function; the *function*
  is the public entry point.
- **C++11 guarantees thread-safe initialisation of function-local statics**
  (the "magic statics" rule in `[stmt.dcl]`). Two threads racing to the
  first call see exactly one construction.

Destruction order is the same problem in reverse: function-local statics
are destroyed in reverse order of *completion of initialisation*, which
becomes well-defined because every access to one of them establishes a
"before" relationship.

The C++ FAQ has carried this guidance since the early standardisation era;
Sutter's *Exceptional C++* items 47–48 are the canonical book treatment.

## Guidance

For any object with static storage duration whose construction or use can
cross translation-unit boundaries:

- **Wrap it in a function returning a reference**:
  ```cpp
  T& instance() { static T x; return x; }
  ```
- The return type is `T&` (or `const T&` if the object is logically
  immutable). Never return by value — that would copy at every call.
- The function-local `static` is constructed on the first call, threadsafe
  since C++11, and destroyed in reverse order of completion at program
  shutdown.
- For dependencies between several such singletons, prefer to make the
  dependency explicit (pass the upstream as a parameter) rather than nest
  more singletons. Singletons compound poorly.
- Resist the urge to inline-construct an extra `bool` "is-initialised" flag
  or a double-checked lock — `static T x;` inside a function already
  carries the C++11 guarantee, and rolling your own is a thread-safety
  hazard.

## Example

```cpp
// Bad: two namespace-scope statics with a cross-TU dependency.
//
// translation unit A:
//   Config the_config;   // depends on the_logger being constructed first
//
// translation unit B:
//   Logger the_logger;
//
// If A's static initialiser runs before B's, the_config's construction
// reads an uninitialised the_logger. The order is unspecified and the bug
// may surface only on a different platform or with a different linker.

// Good: the Construct-On-First-Use idiom. Order of construction is
// determined by order of first use; thread-safe under C++11; destruction
// happens in reverse order of completion of initialisation, which is now
// well-defined.
Logger& logger() {
    static Logger instance;        // thread-safe init, exactly once
    return instance;
}

Config& config() {
    static Config instance{logger()};   // explicit dependency on logger()
    return instance;
}

void use() {
    config().write("ready");       // first call constructs logger(),
                                   // then config(); order is deterministic.
}
```

## Caveats

- **Function-local statics destroy at program termination.** If one
  destructor needs another's, you have the destruction-order fiasco —
  symmetric to the construction-order one. Sutter's "leaky singleton"
  pattern (allocate with `new` and *never delete*) is one workaround;
  `std::quick_exit` and atexit ordering are others. Neither is free.
- **Each call has a small cost** — the compiler emits a thread-safe
  initialisation check (typically an atomic load plus a branch). On hot
  paths, cache the reference in a local; do not call `instance()` per
  iteration.
- **Not a singleton endorsement.** Singletons compound poorly across
  modules and test suites. Use this idiom for the genuinely
  cross-TU-shared resource, not as a default access pattern.
- **The C++11 thread-safety guarantee assumes a conforming compiler.**
  All mainstream compilers honour it; embedded toolchains targeting older
  language modes may not. For freestanding C++ check the
  implementation-defined behaviour.

## References

- ISO C++ working draft, `[stmt.dcl]` ("magic statics") and
  `[basic.start.term]` (destruction order) — <https://eel.is/c++draft/stmt.dcl>;
  <https://eel.is/c++draft/basic.start.term>
- isocpp.org C++ FAQ, "What's the 'static initialization order fiasco'?" —
  <https://isocpp.org/wiki/faq/ctors#static-init-order>
- Herb Sutter, *Exceptional C++*, items 47–48 — **cite-by-reference**.
- Bjarne Stroustrup, *A Tour of C++* 3e, §16.4.1 (initialisation across
  TUs) — **cite-by-reference**.
- cppreference, "Storage duration" and "Initialization" —
  <https://en.cppreference.com/w/cpp/language/storage_duration>;
  <https://en.cppreference.com/w/cpp/language/initialization>
