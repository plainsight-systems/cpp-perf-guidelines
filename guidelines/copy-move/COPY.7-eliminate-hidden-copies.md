+++
id = "COPY.7"
title = "Eliminate hidden copies in range-for, captures, std::function, and const returns"
category = "copy-move"
status = "draft"
summary = "Most C++ performance regressions come from idioms that look right and silently copy — auto in range-for, default-by-value lambda captures, std::function, returning const T. Audit each."
tags = ["hidden-copies", "move-semantics", "range-for", "lambda-capture"]
+++

## Rationale

Most performance regressions in modern C++ are not from "wrong" code — they
are from idioms that *look right* and silently copy. The code reads clean,
the compiler emits no warning, the profiler shows the copy constructor in
the hot path. Move semantics did not eliminate copies; it made them
optional, and the burden of opting in shifted to the author.

The recurring offenders form a short catalogue, each with a one-line fix.

## Guidance

- **Range-based `for` with `auto`.** `for (auto x : v)` deduces `x` by value
  and *copies* each element. Use `const auto&` to read, `auto&` to mutate,
  `auto&&` to forward.
- **Default-by-value lambda captures.** `[=]` copies each named variable into
  the lambda — including any large container. Capture by reference (`[&]`)
  when the lambda does not outlive the captured object, or use C++14
  init-capture (`[d = std::move(data)]`) to move into the lambda's storage.
- **`std::function` and `std::any`.** Each *copies* the callable or value
  into its internal storage on construction. For a state-heavy callable,
  prefer a function pointer + context, a small virtual interface, or — in
  C++23 — `std::move_only_function`, which can hold a move-only target.
- **Returning `const T` by value.** The returned prvalue is `const`, which
  inhibits the caller's move-construction (a const rvalue cannot bind to a
  non-`const` rvalue reference). Drop the top-level `const` on by-value
  returns; const-correctness applies to references and storage, not to
  values being returned.
- **Implicit conversions at call boundaries** can build temporaries. Watch
  for `f(s)` where `f` takes `const std::string&` and `s` is a `const
  char*` — the temporary `std::string` is constructed and destroyed per
  call.

The general rule: make the value-category and capture choice deliberate. If
you write `auto`, mean *by value*. If you write `&`, mean *by reference*. The
default cannot be "whatever the compiler picks" — the compiler picks the
literal type.

## Example

```cpp
// 1. Range-based for. `auto` deduces to the value type and COPIES.
void scan_bad(const std::vector<std::string>& v) {
    for (auto s : v)                    // copies every string
        process(s);
}
void scan_good(const std::vector<std::string>& v) {
    for (const auto& s : v)             // read by reference
        process(s);
}
void mutate_good(std::vector<std::string>& v) {
    for (auto& s : v)                   // mutate in place
        s.append(".bak");
}

// 2. Default-by-value lambda capture copies every named variable.
auto make_handler_bad(std::vector<int> data) {
    return [=]() {                      // [=] copies `data` into the lambda
        return std::accumulate(data.begin(), data.end(), 0);
    };
}
auto make_handler_good(std::vector<int> data) {
    return [d = std::move(data)]() {    // init-capture moves the vector in
        return std::accumulate(d.begin(), d.end(), 0);
    };
}

// 3. std::function copies the callable into its internal storage on
//    construction. For state-heavy callables, prefer alternatives.
void register_callback_bad(std::function<void()> cb);   // copies `cb`'s state
// Possible alternatives (pick deliberately):
//   void register_callback(void (*cb)(void*), void* ctx);   // C-style
//   void register_callback(ICallback& cb);                  // virtual iface
//   void register_callback(std::move_only_function<void()> cb);  // C++23

// 4. `const T` return disables move on the caller side. The returned prvalue
//    is const, so the caller's move constructor cannot bind to it.
const std::string make_label_bad();     // caller is forced to copy
std::string       make_label_good();    // caller moves (or P0135 elides)
```

## Caveats

- **`auto` by value is correct for small trivially-copyable types**
  (`int`, `int*`, small structs). The rule is "be deliberate," not "always
  reference."
- **`auto&&` (forwarding reference in range-for) is broadly defensible.** It
  binds to the iterator's reference type whatever that is, so it works
  uniformly across containers, proxy iterators (`std::vector<bool>`), and
  generator-style ranges. It is also less self-documenting than `const auto&`
  or `auto&` — readers must reason about the iterator type to know whether
  they are reading or mutating.
- **`const T` return is only an anti-pattern for *types*.** A `const int`
  return is harmless: `int` has no move constructor for the const to inhibit.
  Reserve the warning for class types.
- **`std::function` is the right tool for type-erased callables.** Replace it
  when its allocation/copy cost shows up in a profile, not preemptively.

## References

- Scott Meyers, *Effective Modern C++*, items 5, 31, 32 (auto, lambda
  capture) — **cite-by-reference**.
- Howard Hinnant, *Everything You Ever Wanted to Know About Move Semantics*
  — <https://www.youtube.com/watch?v=vLinb2fgkHk>
- C++ Core Guidelines ES.71 (prefer range-`for` to a `for` statement with
  explicit loop variable) and F.16 — pass-by-value rules —
  <https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines#es71-prefer-a-range-for-statement-to-a-for-statement-when-there-is-a-choice>
- cppreference, `std::move_only_function` (C++23) —
  <https://en.cppreference.com/w/cpp/utility/functional/move_only_function>
