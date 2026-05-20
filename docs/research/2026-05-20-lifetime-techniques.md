# C++ Object Lifetime and Construction — Technique Extraction

Research note — 2026-05-20. Supports packet
`2026-05-20-lifetime-category-buildout`. Technique-extraction pass for the
`lifetime` category — what each source actually teaches (the rule, the
anti-pattern, the language guarantee), not bibliography. Sources are
classified per the `CONTRIBUTING.md` sourcing rule:

- **Citable** — free public talk / paper / blog (link is the citation).
- **Cite-by-reference** — copyrighted book; reference by item, do not quote.
- **Study-only code** — proprietary or non-permissive source; read but do not
  copy.
- **Permissive code** — MIT / BSD / Apache-2.0 / similar; quotable with
  attribution.

---

## 1. Problem framing

Object lifetime in C++ is governed by `[basic.life]` and `[basic.types]`. The
category covers four interacting concerns: (a) when an object legally *exists*
such that lvalue-to-rvalue conversion is defined, (b) when storage can be
*reused* for an object of a different type, (c) when the compiler may *assume*
an object exists based on byte writes (implicit object creation), and (d) the
*order* in which objects are destroyed. The pool-allocator case (`MEM.2`)
sits at the intersection of (a) and (b): allocation gives you raw bytes, and
lifetime-correct code must explicitly construct and destroy in those bytes.

## 2. The four-way type taxonomy

This is the load-bearing distinction. Sources consistently conflate these,
which is the anti-pattern to call out.

| Property | What it permits | Example |
|---|---|---|
| **Trivial** (trivially-default-constructible AND trivially-copyable) | Default initialisation is a no-op | `int`, `struct Pod { int a; double b; };` with no user-declared constructors |
| **Trivially-copyable** (not necessarily trivial) | `std::memcpy` between objects of the type is defined; storable in `std::atomic` | `struct S { S() { x = 0; } int x; };` — user-provided default ctor makes it non-trivial but it remains trivially-copyable |
| **Trivially-destructible** (not necessarily trivially-copyable) | You may skip destructor calls when reusing storage; required for `constexpr` destruction in C++20 | A type with a non-trivial copy constructor but `~T() = default;` and only trivially-destructible members |
| **Implicit-lifetime type** (C++20, P0593) | Operations like `malloc`, `memcpy`, `bit_cast` *implicitly create* the object — no placement-new required | Aggregates, scalar types, arrays of these, trivially-copyable class types whose eligible constructors are trivial |

The standard's term **implicit-lifetime type** is the post-P0593 successor to
the older informal "POD" notion. Scalar types, arrays, and
aggregate/trivially-copyable classes with a trivial eligible constructor and
trivial destructor qualify. `std::is_implicit_lifetime_v<T>` is the C++23
trait (LWG / P2674).

## 3. Placement new — when it is legal

From `[basic.life]` and `[expr.new]`, the preconditions are:

1. **Suitable storage**: properly aligned for `T` and at least `sizeof(T)`
   bytes.
2. **Storage is not currently the in-lifetime storage of another object whose
   destructor has side effects** — or you must call that destructor first.
3. The placement-new expression itself begins the lifetime of the new object.

For implicit-lifetime types, P0593 means you frequently *do not need*
placement-new at all — writing bytes via `memcpy` into suitably-aligned
storage implicitly creates the object and ends the lifetimes of any prior
implicit-lifetime objects in those bytes. For non-implicit-lifetime types
(anything with a user-provided constructor, virtual functions, virtual bases,
etc.), placement-new (or `std::construct_at` / `std::start_lifetime_as`) is
mandatory.

## 4. `std::launder` — what it actually does

P0137R1 (Richard Smith) introduced `std::launder` in C++17 to solve a narrow
but real problem: the compiler is allowed to assume that **`const` and
reference non-static data members of an object do not change for the object's
lifetime**. If you reuse the storage of an object containing a `const` or
reference member, a pointer to the *old* object is no longer guaranteed to
access the *new* object's bytes even at the same address.

**Required when:**

- You reuse storage of a class type containing `const` or reference
  subobjects, and you hold a pointer/reference of the original type.
- The pointer returned by placement-new differs from the original pointer in
  *transparently replaceable* status (see `[basic.life]/8`).

**Concretely:**

```cpp
struct S { const int n; };
alignas(S) std::byte buf[sizeof(S)];
S* p = ::new (buf) S{1};
p->~S();
S* q = ::new (buf) S{2};   // q is the safe pointer
// reading *p is UB; std::launder(p) gives a pointer equivalent to q
```

**A no-op when:** the type has no `const`/reference subobjects, *and* you
already have the pointer returned by placement-new. The placement-new return
value is *already laundered* — you only need `launder` when you have a stale
pointer to the storage.

Arthur O'Dwyer's posts ("The Power of `std::launder`", "What `std::launder`
is for") are the most accessible treatment; he emphasises that `launder`
does not affect codegen on common compilers — it constrains the *abstract
machine model*. **Citable**.

## 5. P0593 — implicit object creation

P0593 (C++20, Richard Smith, Ville Voutilainen) retroactively legalises the
`malloc(sizeof(T)); /* write bytes */; T* p = (T*)buf; p->x;` pattern that
every C-interop codebase has always written. The mechanism:

- Certain operations (`malloc`, `calloc`, `realloc`, `aligned_alloc`,
  `operator new`, `std::allocator<T>::allocate` for byte types, `memcpy`,
  `memmove`, `bit_cast`, `std::byte` array creation) **implicitly create**
  objects of implicit-lifetime types within the storage they produce or
  manipulate.
- The created object is the one that makes the program's subsequent reads
  well-defined (the "as-if" choice the implementation makes).
- This does **not** extend to non-implicit-lifetime types. You cannot
  `malloc` a `std::string`.

What P0593 does *not* do: it does not begin the lifetime of a type with a
non-trivial constructor, it does not let you skip placement-new for
`std::vector`, and it does not retroactively bless type-punning between
unrelated types (strict aliasing still applies).

## 6. P2590 — `std::start_lifetime_as`

P2590 (Timur Doumler, C++23) fills the gap left by P0593: when you have raw
bytes that contain a *valid object representation* of a trivially-copyable
but non-implicit-lifetime type (say, one with a user-provided default
constructor), you cannot rely on implicit object creation.
`std::start_lifetime_as<T>(p)` and `std::start_lifetime_as_array<T>(p, n)`
explicitly begin lifetime without running a constructor. Use cases:

- Mapping a file or shared-memory region containing a serialised
  trivially-copyable struct with a user-defined constructor.
- Implementing custom serialisation where the bytes are known good but the
  type is not implicit-lifetime.

It is **not** a substitute for placement-new on types with non-trivial
constructors — those constructors must run.

## 7. Destruction order — the rules

Confirmed against `[class.base.init]`, `[stmt.jump]`, and
`[basic.start.term]`:

- **Members**: reverse of declaration order, regardless of mem-initialiser
  order.
- **Bases**: reverse of construction order — direct non-virtual bases in
  reverse declaration order, then virtual bases in reverse depth-first
  left-to-right traversal.
- **Automatic locals**: reverse of declaration order within a block;
  exception/early-return unwinds destroy in reverse construction order.
- **Namespace-scope statics**: reverse of completion-of-construction order,
  **within a TU**. **Across TUs** the order is unspecified — this is the
  **static-initialization-order fiasco**.

### The fiasco and the function-local-static idiom

Two namespace-scope statics in different TUs have unspecified construction
order. The fix, attributed to Cargill / Sutter / the C++ FAQ, is the
**Construct-On-First-Use** idiom:

```cpp
T& instance() { static T x; return x; }
```

C++11 guarantees thread-safe initialisation of function-local statics
(`[stmt.dcl]/4`, the "magic statics" rule). Destruction order of
function-local statics is reverse order of *completion of initialisation*,
which is well-defined across TUs. Herb Sutter's *Exceptional C++* and GotW
entries treat this; Stroustrup's *Tour of C++* §16.4.1 covers it briefly.
**Cite-by-reference** for the books; isocpp.org's C++ FAQ entry on the
fiasco is **Citable**.

## 8. Storage reuse and pools (cross-reference MEM.2)

A pool allocator gives you a slot of suitably-aligned bytes. The lifetime
discipline is:

1. `T* p = std::construct_at(slot, args...);` (C++20; equivalent to
   placement-new but `constexpr`-friendly).
2. Use `*p`.
3. `std::destroy_at(p);` before reusing the slot.
4. To reuse the slot for a `U` of different type, no `launder` is needed
   *for the new `U*` returned by `construct_at`* — but any stale `T*` is
   invalid.
5. If the pool node embeds a freelist `next` pointer in a `union` with the
   payload, writing to `next` after destroying the payload is fine; reading
   the payload through the old `T*` is UB.

`std::aligned_storage` / `std::aligned_union` are **deprecated in C++23**
(P1413). The replacement is `alignas(T) std::byte buf[sizeof(T)]` or
`alignas(T) unsigned char buf[sizeof(T)]`. This is a real porting concern.

## 9. Library implementations — what the STL actually does

- **`std::vector::emplace_back`** uses `std::allocator_traits<A>::construct`
  which calls placement-new (or `std::construct_at` since C++20). Growth
  reallocates raw storage, then *move-constructs* (or copies, if move-ctor
  not `noexcept`) into the new buffer, then destroys originals.
  Cross-references P1144 (relocation) and the `copy-move` category.
- **`std::optional<T>`** holds `alignas(T) unsigned char` storage; `emplace`
  calls placement-new; `reset` calls `~T()`; the discriminator `bool` tracks
  the engaged state. libstdc++ and libc++ implementations are
  **Permissive code** (GPL-with-exception / Apache-2.0-with-LLVM-exception
  respectively).
- **`std::variant`** is similar, with a type index; uses `std::launder`-
  equivalent guarantees from `[basic.life]` because the active member can
  change.
- **`std::aligned_storage_t`** was the recommended buffer type; now
  deprecated. Replacement pattern is direct `alignas` + `std::byte[]`.

EASTL's `eastl::construct_at` / `eastl::destroy_at` predate the standard's
`std::construct_at`. **Permissive code** (BSD-3-Clause).

Unreal's `TArray::Emplace` uses placement-new into pre-allocated storage
with explicit destructor calls in `RemoveAt`. `UObject` GC lifetime is
separate — the GC controls destruction timing, not the C++ runtime, via
`MarkAsGarbage` and the reachability pass. **Study-only**.

Boost.Container's `small_vector` and `static_vector` implement the same
construct/destroy discipline with `boost::container::allocator_traits`.
**Permissive code** (Boost Software License).

## 10. Strict aliasing and placement-new

Placement-new establishes a new object's lifetime; reads through a pointer
of that object's type are then well-defined. Type-punning via placement-new
is *legal* in the sense that you can place a `float` into bytes that
previously held an `int` and then read the `float` — but you cannot read the
*old* `int` through the new `float*` or vice versa. For pure type-punning
without lifetime change, `std::bit_cast` (C++20) is the correct tool for
trivially-copyable types; it produces a new object and side-steps the
aliasing question.

## 11. Moved-from state — cross-reference COPY.6

The language guarantees: a moved-from object is still in its lifetime (its
destructor will run). The standard library requires moved-from standard
objects to be in a *valid but unspecified state*. User types have no such
obligation but should follow it. P1144 (Arthur O'Dwyer) proposes *trivial
relocation* — destroying-the-source-as-part-of-the-move — which is a
lifetime concept and the bridge to the `copy-move` category.

## 12. Honest gaps

- A dedicated "Back to Basics: Object Lifetime" CppCon talk in the 2019–2023
  Back to Basics tracks could not be confirmed — the track covers RAII
  (O'Dwyer 2019) and special member functions (Iglberger 2021), not
  `[basic.life]` / `launder` specifically. Per the cache-layout precedent:
  do not cite a talk that cannot be verified.
- Pablo Halpern has WG21 papers on allocator-aware types and `pmr`, but no
  confirmed dedicated lifetime talk.
- Tom Honermann's public talks are predominantly on text encoding
  (`char8_t`), not lifetime — do not cite him for this category.

Verified talks worth citing:

- Timur Doumler, "Lifetime in C++ — Implicit Object Creation and
  `std::start_lifetime_as`" (CppCon 2023 / C++ on Sea variants).
- Nicolai Josuttis, on `std::launder` — multiple Meeting C++ / CppCon
  appearances.
- Arthur O'Dwyer, "Back to Basics: RAII and the Rule of Zero" (CppCon 2019).

## Sources

### WG21 papers
- P0137R1, `std::launder` —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2016/p0137r1.html>
- P0593R6, "Implicit creation of objects for low-level object manipulation"
  — <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2020/p0593r6.html>
- P2590R2, "Explicit lifetime management — `std::start_lifetime_as`" —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2022/p2590r2.pdf>
- P1144R10, "Object relocation" —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2023/p1144r10.html>
- P1413R3, deprecating `std::aligned_storage` —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2022/p1413r3.pdf>
- Working draft `[basic.life]` / `[basic.types]` —
  <https://eel.is/c++draft/basic.life>; <https://eel.is/c++draft/basic.types>

### Talks and posts
- Arthur O'Dwyer, "The Power of `std::launder`" —
  <https://quuxplusone.github.io/blog/2022/01/13/launder/>
- Arthur O'Dwyer, "What `std::launder` is for" —
  <https://quuxplusone.github.io/blog/2018/09/01/what-is-launder/>
- Arthur O'Dwyer, "Back to Basics: RAII and the Rule of Zero", CppCon 2019 —
  <https://www.youtube.com/watch?v=7Qgd9B1KuMQ>
- Timur Doumler on `std::start_lifetime_as` and implicit object creation —
  CppCon 2023 / C++ on Sea search —
  <https://www.youtube.com/results?search_query=timur+doumler+start_lifetime_as>
- isocpp.org C++ FAQ, static-initialization-order fiasco —
  <https://isocpp.org/wiki/faq/ctors#static-init-order>
- cppreference, `[basic.life]` summary —
  <https://en.cppreference.com/w/cpp/language/lifetime>
- cppreference, `std::launder` —
  <https://en.cppreference.com/w/cpp/utility/launder>
- cppreference, `std::start_lifetime_as` —
  <https://en.cppreference.com/w/cpp/memory/start_lifetime_as>
- cppreference, `std::is_implicit_lifetime` —
  <https://en.cppreference.com/w/cpp/types/is_implicit_lifetime>

### Books
- Scott Meyers, *Effective Modern C++*, O'Reilly 2014 — items 18–22
  (**cite-by-reference**).
- Bjarne Stroustrup, *The C++ Programming Language* 4e, Addison-Wesley 2013,
  §17 (**cite-by-reference**).
- Bjarne Stroustrup, *A Tour of C++* 3e, Addison-Wesley 2022, §6, §16.4
  (**cite-by-reference**).
- Herb Sutter, *Exceptional C++*, Addison-Wesley 2000, items 47–48
  (**cite-by-reference**).

### Library / engine code
- libstdc++ `<optional>`, `<variant>`, `<vector>` — **permissive** —
  <https://gcc.gnu.org/onlinedocs/libstdc++/>
- libc++ — **permissive** —
  <https://github.com/llvm/llvm-project/tree/main/libcxx>
- Microsoft STL — **permissive** — <https://github.com/microsoft/STL>
- EASTL — **permissive** — <https://github.com/electronicarts/EASTL>
- Boost.Container — **permissive** —
  <https://github.com/boostorg/container>
- Unreal Engine `TArray`, `UObject` lifetime — **study-only** —
  <https://github.com/EpicGames/UnrealEngine> (gated)
