+++
id = "LIFE.3"
title = "Use std::launder only when storage reuse breaks transparent replacement"
category = "lifetime"
status = "draft"
summary = "std::launder is required only when you reuse storage of a class with const or reference subobjects and access through a stale pointer. Elsewhere it's a no-op; do not sprinkle it preemptively."
tags = ["launder", "placement-new", "pointer-provenance"]
+++

## Rationale

`std::launder` (C++17, P0137) exists for one specific failure mode: the
compiler is permitted to assume that **`const` and reference non-static
data members of an object do not change for the object's lifetime.** When
you reuse storage of a class type with such members — via placement new —
the compiler may, in principle, continue to assume the old object's values
when reading through a pointer of the original type. The standard's
"transparent replacement" rule (`[basic.life]/8`) calls out exactly when
this is or is not safe, and `std::launder` is the escape hatch for the
not-safe case.

Two things follow from this:

- **`std::launder` is necessary** when (a) you reuse storage of a class
  containing a `const` or reference subobject, **and** (b) you access the
  new object through a pointer of the original type that you held *before*
  the reuse. In that exact scenario the pointer's link to the new object's
  bytes is severed by the abstract machine; `launder` fixes it.

- **`std::launder` is a no-op** elsewhere. It is also a no-op for codegen
  on every mainstream compiler — it constrains the abstract machine, not
  the binary. Sprinkling it "to be safe" is cargo-culted and obscures the
  cases where it matters.

The pointer returned by `placement new` (or `std::construct_at`) is
*already* the right one for the new object — it does not need laundering.
You only need `launder` when you have a *stale* pointer to the storage.

## Guidance

- Use `std::launder` **only** when both:
  - You have a pointer to storage whose contents were replaced by placement
    new of a type with `const` or reference subobjects (or one whose
    transparent-replacement status changed), **and**
  - You did not receive the new object's pointer from the placement-new
    expression itself.
- **Prefer to keep the pointer that placement-new returns.** If you have
  that pointer, you do not need `std::launder`.
- For storage-reuse helpers that reinterpret a `std::byte[]` buffer as a
  particular object, use `std::launder` on the cast result — that *is* the
  stale-pointer case (see `LIFE.2`'s `InplaceString::ptr()`).
- Do not use `std::launder` to "fix" type-punning between unrelated types.
  Strict aliasing still applies; `std::launder` is about *lifetime*, not
  aliasing.

## Example

```cpp
// The narrow case that REQUIRES std::launder: a class with a const member,
// storage reused via placement new, and an access through a pointer held
// from before the reuse.
struct WithConst { const int n; };

void const_member_reuse() {
    alignas(WithConst) std::byte buf[sizeof(WithConst)];
    WithConst* p = ::new (buf) WithConst{1};
    p->~WithConst();
    WithConst* q = ::new (buf) WithConst{2};

    // q is the safe pointer — it came from the new placement-new and is
    // already laundered. Read q->n freely.
    (void)q->n;   // OK

    // p was acquired before the reuse. The compiler may assume p->n is
    // still 1, even though the bytes now hold 2. Reading p->n is UB.
    // std::launder severs that assumption.
    (void)std::launder(p)->n;   // OK

    // Best of all: do not hold the stale pointer in the first place.
}

// A no-op case: same storage reuse, but the type has no const or reference
// members. Transparent-replacement applies; std::launder is not needed.
struct PlainInt { int n; };

void plain_reuse() {
    alignas(PlainInt) std::byte buf[sizeof(PlainInt)];
    PlainInt* p = ::new (buf) PlainInt{1};
    p->~PlainInt();
    PlainInt* q = ::new (buf) PlainInt{2};

    (void)p->n;   // OK — transparent replacement covers this case.
    (void)q->n;   // Also OK.
}
```

## Caveats

- **`std::launder` does not change codegen** on GCC, Clang, or MSVC for the
  cases it is actually intended for. It is purely a contract with the
  abstract machine. Do not expect it to fix mis-aligned or aliasing bugs.
- **A reference member is the same as a `const` member** for this rule.
  Both block transparent replacement.
- **`std::launder` is not a license for type-punning.** Reading the bytes of
  a `float` through a `std::launder`'d `int*` is still UB; that is a strict-
  aliasing problem and `std::launder` cannot help. Use `std::bit_cast` (or
  `std::start_lifetime_as` — see `LIFE.5`) for type-punning.
- **If your code includes `std::launder` defensively in places that do not
  satisfy the trigger conditions above, delete those calls.** They do
  nothing useful, and they signal to readers that the lifetime story is
  unclear when it is in fact fine.

## References

- P0137R1, "Replacement of class objects containing reference members" —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2016/p0137r1.html>
- ISO C++ working draft, `[basic.life]` (especially the "transparent
  replacement" rule) — <https://eel.is/c++draft/basic.life>
- Arthur O'Dwyer, "The Power of `std::launder`" —
  <https://quuxplusone.github.io/blog/2022/01/13/launder/>
- Arthur O'Dwyer, "What `std::launder` is for" —
  <https://quuxplusone.github.io/blog/2018/09/01/what-is-launder/>
- cppreference, `std::launder` —
  <https://en.cppreference.com/w/cpp/utility/launder>
