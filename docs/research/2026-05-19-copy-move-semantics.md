# Copy and Move Semantics — Technique Extraction

Research note — 2026-05-19. Supports packet
`2026-05-19-copy-move-category-buildout`. Technique-extraction pass for the
`copy-move` category — what each source actually teaches (the technique, the
anti-pattern, the language guarantee), not bibliography. Sources are
classified per the `CONTRIBUTING.md` sourcing rule:

- **Citable** — free public talk / paper / blog (link is the citation).
- **Cite-by-reference** — copyrighted book; reference by item, do not quote.
- **Study-only code** — proprietary or non-permissive source; read but do not
  copy.
- **Permissive code** — MIT / BSD / Apache-2.0 / similar; quotable with
  attribution.

---

## 1. Value semantics as the foundation

Sean Parent's *C++ Seasoning* (GoingNative 2013, **Citable**) is the canonical
argument that "value semantics is a discipline": objects own their state,
copies are independent, mutation is local, and you reach for `shared_ptr` only
when ownership is genuinely shared. The famous "no raw loops" line is
downstream of this — algorithms compose on values, raw loops leak state.
**Technique extracted:** prefer regular types (copyable, equality-comparable,
default-constructible) as the default; reach for move-only or
reference-semantic types only when the domain demands it. This sets the bar the
rest of this category measures against.

Stroustrup's modern-C++ writing (**Cite-by-reference**, *A Tour of C++*,
*The C++ Programming Language*) reinforces the same point: "regular type" is
the default, and rvalue references exist to make value semantics *affordable*,
not to replace it.

## 2. What the language actually guarantees

**P0135 "Guaranteed copy elision through simplified value categories"**
(Smith, **Citable**, adopted into C++17) is the load-bearing standards change.
After C++17:

- A prvalue is not a "temporary object" — it is an *expression that will
  materialise* a result object. Materialisation only happens when needed.
- `T f() { return T{}; }` and `T x = f();` involve **no** copy or move,
  *guaranteed*, even if `T`'s copy/move constructors are deleted.

What P0135 does **not** guarantee:

- **NRVO** (returning a named local) — still permitted, not mandatory. The
  compiler is allowed to elide; an implicit move from the local is the
  fallback.
- **Returning a function parameter** — never elided; the implicit move is the
  best you get.
- **Returning a data member** — *not* a prvalue context for the enclosing
  object; same NRVO rules as named locals.

**Technique extracted:** factory functions returning by value are free in
C++17. `return T{...};` is a zero-cost idiom. `return std::move(local);` is
*actively worse* — it suppresses NRVO and forces a move (`COPY.1` in the
corpus). Hinnant has hammered this in talks since rvalue references shipped.

## 3. Howard Hinnant — the author's framing

Hinnant authored the original rvalue-references proposals (N1377, N1690,
N1855, N1952 series, **Citable**). His "Everything you ever wanted to know
about move semantics" talk (CppCon 2014, ACCU 2016, **Citable**) is the single
best end-to-end view:

- Move is *just an optimisation of copy*; semantically a moved-from object is
  still a fully-formed object of its type, just with unspecified value.
- "Valid but unspecified" means: destructor runs cleanly, assignment works,
  and any operation whose precondition does not depend on the value works.
  Operations that *do* depend on the value (`front()` on an empty container,
  `*` on a moved-from `unique_ptr`) are undefined unless the type documents
  otherwise.
- The standard library *does* over-specify in some places (e.g. moved-from
  `unique_ptr` is guaranteed null; moved-from `shared_ptr` is empty).
- His copy-elision posts (`isocpp.org` and personal site, **Citable**) explain
  why `return std::move(x)` defeats elision: the return expression is no
  longer the name of an automatic object of the function's return type, so the
  named-return-value path closes.

## 4. The Josuttis "Nightmare" talk

Nicolai Josuttis, *The Nightmare of Move Semantics for Trivial Classes*
(CppCon 2019, **Citable**). Mines a deep seam of surprises around the
*forwarding-reference vs by-value vs const-ref* overload set for a class with
a single string member:

- A `template<class T> void set_name(T&&)` "forwarding reference" setter
  outperforms by-value-and-move on lvalues, ties on rvalues, but happily binds
  to `int`, `nullptr_t`, derived classes, braced-init-lists in ways the author
  never intended — and produces incomprehensible error messages.
- Constraining with `requires std::convertible_to<T, std::string>` (or
  pre-C++20 SFINAE) is required to make the forwarding setter behave like a
  setter and not a sink for the universe.
- Pass-by-value-and-move is *correct* but pays an extra move per call vs the
  constrained forwarding-reference version.
- Two overloads (`set_name(const std::string&)` + `set_name(std::string&&)`)
  is the lowest-surprise option for non-templated APIs.

**Technique extracted:** for sink parameters in *headers / templates*, use
constrained perfect forwarding. For *non-template* APIs, use the two-overload
form. By-value-and-move is the "default that is never wrong but sometimes one
move slower" — fine for most code.

## 5. Iglberger — Back to Basics

Klaus Iglberger, *Back to Basics: Move Semantics* (CppCon 2021–2022,
**Citable**). Highest-yield items:

- The Rule of Five / Rule of Zero. If a type owns a resource, write *all*
  five (dtor, copy ctor, copy assign, move ctor, move assign). If it owns no
  resource and is composed of types that already manage themselves, write
  *none* — let the compiler generate them and never declare a destructor.
- Declaring a user-defined destructor *suppresses* the implicit move
  operations and is the single most common source of accidentally-copying
  classes that "should" move. Add the destructor only with the four other
  members.
- `noexcept` on the move constructor is not cosmetic. `std::vector`
  reallocation uses `std::move_if_noexcept` — if move is not `noexcept`,
  reallocation **copies** to preserve the strong exception guarantee. For a
  vector of large objects this is a multi-order-of-magnitude difference.

## 6. Arthur O'Dwyer

Personal site and CppCon talks (**Citable**). The most actionable items:

- *The Knightmare of Initialization in C++* and follow-up posts on
  `return std::move` — corroborates Hinnant and adds the rule: the *only* time
  `std::move` on a return is correct is when the return expression is not
  already an automatic object of the return type (e.g. returning a parameter,
  a member, or a subobject of different type).
- His writing on "trivially relocatable" (P1144) explains the gap between
  *trivially copyable* (you can `memcpy` *into raw storage* and then there
  exists an object) and *trivially relocatable* (you can `memcpy` and treat
  the source as ended — the model `std::vector` reallocation actually wants).
  `memcpy` is currently legal only for trivially-copyable types and even then
  only via the object-representation rules of `[basic.types]`; using it on a
  non-trivially-copyable type is UB regardless of how the bytes "look right".

## 7. Effective Modern C++ (Meyers) — items to lift by reference

**Cite-by-reference.** Do not quote; cite item numbers.

- Item 23: `std::move` casts to rvalue, performs no move. `std::forward` is a
  conditional cast for forwarding references. Neither does work.
- Item 25: use `std::move` on rvalue references, `std::forward` on
  universal/forwarding references. *Do not* `std::move` a return value of the
  function's return type — it suppresses RVO/NRVO.
- Item 27: alternatives to overloading on universal references — tag dispatch,
  `enable_if` constraints, pass-by-value-and-move. This is the formal
  counterpart to Josuttis's sink-parameter problem.
- Item 29: assume move operations are not present, not cheap, and not used.
  In particular: types with `noexcept(false)` move are skipped by vector
  reallocation; types in legacy code may not have move at all.
- Item 30: perfect forwarding fails for braced initialisers, `0`/`NULL` as
  null pointers, declaration-only static const integral members, overload set
  names, and bitfields.

## 8. Library implementations — what `std::vector` actually does

`libstdc++`, `libc++`, MSVC STL (all **Permissive code** under their
respective licences, runtime sources readable on GitHub) implement
`vector::push_back` reallocation via `std::move_if_noexcept`. The contract:
`move_if_noexcept(x)` yields `std::move(x)` iff `T`'s move constructor is
`noexcept` *or* `T` has no copy constructor; otherwise it yields `const T&`.

**Consequence:** a type whose move constructor is not `noexcept` and which has
a copy constructor will be *copied* every time the vector reallocates,
regardless of how cheap the move would have been.

**Technique extracted:** mark every move constructor `noexcept` unless you
genuinely cannot. If you cannot (e.g. an allocator's move can throw), that is
a design problem to surface, not a default to accept.

## 9. EASTL — divergence from `std`

EA's EASTL (BSD-3, **Permissive code**) documents its move-semantics
divergences in `EASTL/doc/`:

- Uses `eastl::move` even when `std::move` would suffice, to remain buildable
  on stripped consoles without full `<utility>`.
- `eastl::vector` is more aggressive about `move_if_noexcept`-style logic and
  falls back to copy without strong-exception guarantees on some paths — a
  deliberate "we know the game-engine constraints" tradeoff documented in
  source comments.
- Containers use a "swap and move" idiom rather than constructing a moved
  copy, for ABI-stable in-place updates.

## 10. Unreal — `FString` / `TArray`

Unreal Engine source (**Study-only code**; not redistributable). The
discipline visible in headers:

- `FString` exposes both `FString&&` and `const FString&` overloads on
  operations rather than relying on perfect forwarding. Avoids the Josuttis
  trap and keeps error messages readable for game programmers.
- `TArray` reallocation uses an internal `RelocateConstructItems` template
  that, for types tagged `TIsTriviallyRelocatable`, does a single `memmove`
  rather than a per-element move — Unreal pre-empted P1144's trivial
  relocation by tagging.

The discipline is describable by reference; original reimplementations live in
the corpus's own example code. Do not paste UE source.

## 11. Specific question answers (compact)

- **When is `std::move` on a return wrong?** Whenever the return expression is
  the name of an automatic object whose type matches the function's return
  type. The implicit move already happens; `std::move` only kills NRVO.
  Correct uses: returning a *parameter*, returning a *member*, or returning a
  *base subobject* — none of which are NRVO candidates.

- **When is a type move-only?** When the resource it owns has unique ownership
  semantics (file handle, GPU buffer, socket, `unique_ptr`, thread). Express
  by `= delete`ing the copy operations *and* writing `noexcept` move
  operations. Do not pretend a move-only type is copyable by deep-copying —
  that is a different type.

- **Sink parameters — which idiom?** Constrained forwarding reference for
  templates and headers; two overloads (`const T&` + `T&&`) for stable
  non-template APIs; pass-by-value-and-move as the "always correct, one move
  slower" default. Never an *unconstrained* forwarding-reference sink.

- **When is `memcpy` legal?** Only for *trivially copyable* types (no
  user-provided copy/move/dtor, no virtual, no non-trivially-copyable
  members) and only between objects of the same type or into raw storage that
  will then host such an object. `memcpy` of a non-trivially-copyable type is
  UB even if "the bytes look right" — including for types that are *trivially
  relocatable* but not trivially copyable until P1144 is voted in.

- **The `noexcept` / `std::vector` contract.** Move constructor `noexcept` →
  vector reallocation moves. Move constructor not `noexcept` and copy
  available → vector reallocation **copies**. This is observable, large, and
  silent. Bench it.

- **Hidden copies.** `for (auto x : v)` copies each element — use
  `for (const auto& x : v)` or `for (auto&& x : v)`. Lambdas default-capturing
  by value copy. `std::function` and `std::any` copy on construction from any
  callable. Returning `const T` by value disables move on the caller side
  because the returned prvalue is `const` — drop the top-level `const` on
  by-value returns.

- **Moved-from state.** "Valid but unspecified" = destructible and assignable;
  nothing else guaranteed by the language. Library types often guarantee more
  (moved-from `unique_ptr` is null; moved-from `string` is valid empty or
  small in practice but the standard only says "valid unspecified"). Your own
  types should document.

- **ABI stability and move.** Adding a move constructor to an existing class
  with a stable ABI changes the implicit-move generation rules and can change
  which special members are trivial — both ABI-affecting on Itanium. Safe
  approach: add move ops in the same release that breaks ABI for other
  reasons, or never expose the type by value across the ABI boundary (PIMPL).

## 12. Honest gaps

- No single canonical Hinnant *paper* on copy elision; the authoritative
  treatment is scattered across his blog posts, `isocpp.org` answers, and the
  original proposals. The corpus should aggregate, not invent.
- P1144 (trivial relocation, O'Dwyer) is **not** in any standard yet as of
  C++23; treat as forward-looking guidance, not a guarantee.
- MSVC's debug-mode iterator behaviour around moved-from containers is
  documented only in MSVC STL source comments — note it but do not rely.
- Compiler-specific NRVO holes (returning from inside a `try`/`catch`,
  multiple return paths returning different named locals) are
  Godbolt-observable but not in any standards document.

## Sources

- Sean Parent, *C++ Seasoning*, GoingNative 2013 —
  <https://channel9.msdn.com/Events/GoingNative/2013/Cpp-Seasoning>
- Howard Hinnant, *Everything You Ever Wanted to Know About Move Semantics*,
  CppCon 2014 / ACCU 2016 — <https://www.youtube.com/watch?v=vLinb2fgkHk>
- Howard Hinnant, copy-elision and `return std::move` posts —
  <https://howardhinnant.github.io/>
- Howard Hinnant et al., N1377 / N1690 / N1855 / N1952 rvalue-references
  proposals — <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/>
- Richard Smith, P0135R1 *Wording for guaranteed copy elision through
  simplified value categories* —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2016/p0135r1.html>
- Nicolai Josuttis, *The Nightmare of Move Semantics for Trivial Classes*,
  CppCon 2019 — <https://www.youtube.com/watch?v=PNRju6_yn3o>
- Klaus Iglberger, *Back to Basics: Move Semantics*, CppCon 2021 —
  <https://www.youtube.com/watch?v=St0MNEU5b0o> and
  <https://www.youtube.com/watch?v=pIzaZbKUw2s>
- Arthur O'Dwyer, blog posts on move/return/elision and trivial relocation —
  <https://quuxplusone.github.io/blog/>
- Arthur O'Dwyer, P1144 *Object relocation in terms of move plus destroy* —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2023/p1144r9.html>
- Scott Meyers, *Effective Modern C++*, items 23, 25, 27, 29, 30 (O'Reilly,
  2014) — **Cite-by-reference**.
- Bjarne Stroustrup, *A Tour of C++* (3rd ed.) and *The C++ Programming
  Language* — **Cite-by-reference**.
- libstdc++ `<bits/vector.tcc>` reallocation path —
  <https://github.com/gcc-mirror/gcc/blob/master/libstdc%2B%2B-v3/include/bits/vector.tcc>
- libc++ `<vector>` — <https://github.com/llvm/llvm-project/blob/main/libcxx/include/vector>
- MSVC STL `<vector>` —
  <https://github.com/microsoft/STL/blob/main/stl/inc/vector>
- EASTL — <https://github.com/electronicarts/EASTL> (BSD-3)
- Unreal Engine `FString` / `TArray` — **Study-only code** under Epic source
  licence.
- cppreference: value categories, `std::move_if_noexcept`, copy elision —
  <https://en.cppreference.com/w/cpp/language/value_category>,
  <https://en.cppreference.com/w/cpp/utility/move_if_noexcept>,
  <https://en.cppreference.com/w/cpp/language/copy_elision>
