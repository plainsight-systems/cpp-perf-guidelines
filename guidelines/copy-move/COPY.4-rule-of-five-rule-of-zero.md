+++
id = "COPY.4"
title = "Follow the Rule of Zero — and never declare only a destructor"
category = "copy-move"
status = "draft"
summary = "Default to the Rule of Zero — own resources through self-managing types and declare none of the special members. Otherwise declare all five. A bare destructor silently suppresses implicit moves."
tags = ["rule-of-five", "rule-of-zero", "move-semantics"]
+++

## Rationale

The compiler generates the five special member functions — copy constructor,
copy-assignment, move constructor, move-assignment, destructor — under a
careful set of rules. Two disciplines navigate those rules:

- **Rule of Zero.** If your type owns no resources *directly* (it composes
  types that already manage their own lifetimes — containers, smart pointers,
  RAII wrappers), declare **none** of the special members. The compiler
  generates them correctly, and the move operations end up `noexcept`
  automatically if every subobject's move is `noexcept`.

- **Rule of Five.** If your type owns a resource directly (a raw pointer, a
  file handle, an OS handle), declare **all five**, each as `= default`,
  `= delete`, or a custom body. The implicit-generation rules around when
  *some* members are auto-defined and others are suppressed are too subtle to
  rely on per-case.

The high-impact pitfall connecting the two:

> **Declaring a user-defined destructor suppresses the implicit move
> constructor and move-assignment.**

A class with one innocent line — `~T() = default;` — silently loses its moves.
Move construction now falls back to the copy constructor (which is still
implicit). `std::vector<T>` reallocation copies. There is no diagnostic.
Iglberger has called this the single most common cause of "the type should
move but doesn't."

## Guidance

- **Default to Rule of Zero.** Compose owning types (`std::string`,
  `std::vector`, `std::unique_ptr`) and let the compiler handle the rest.
- **If a type owns a resource directly, apply Rule of Five.** Declare all
  five members; mark move operations `noexcept` (`COPY.2`).
- **Never declare only a destructor.** A bare `~T() = default;` written "for
  documentation" or "in case I need to change it later" silently disables
  implicit moves. If you want to document movability, write
  `static_assert(std::is_nothrow_move_constructible_v<T>);` instead — it
  documents *and* enforces.
- **Polymorphic bases** are the unavoidable exception: a `virtual` destructor
  is required, and you must then explicitly handle (or `= delete`) the four
  other members. This is intentional — moving a polymorphic base by value
  rarely makes sense.

## Example

```cpp
// Rule of Zero. The type owns nothing directly: its members manage their own
// lifetimes. The compiler generates correct, noexcept-where-possible copy /
// move / destructor.
class Widget {
public:
    void run();
private:
    std::string             name_;
    std::vector<int>        data_;
    std::unique_ptr<Engine> engine_;
};
static_assert(std::is_nothrow_move_constructible_v<Widget>);   // generated

// Bad: one innocent line silently suppresses implicit move generation.
// Move construction now resolves to the COPY constructor (still implicit),
// which is not noexcept and can throw. std::vector reallocation copies.
// There is no diagnostic.
class WidgetBad {
public:
    ~WidgetBad() = default;          // <-- silently disables implicit moves
private:
    std::string             name_;
    std::vector<int>        data_;
    std::unique_ptr<Engine> engine_;
};
static_assert(!std::is_nothrow_move_constructible_v<WidgetBad>);   // proves it

// Rule of Five. The type owns a resource directly, so declare ALL FIVE,
// each as = default, = delete, or a custom body. Move ops are noexcept.
class OwningHandle {
public:
    explicit OwningHandle(Resource* r) noexcept : r_{r} {}
    ~OwningHandle() { if (r_) release(r_); }

    OwningHandle(const OwningHandle&)            = delete;
    OwningHandle& operator=(const OwningHandle&) = delete;

    OwningHandle(OwningHandle&& other) noexcept
        : r_{std::exchange(other.r_, nullptr)} {}

    OwningHandle& operator=(OwningHandle&& other) noexcept {
        if (this != &other) {
            if (r_) release(r_);
            r_ = std::exchange(other.r_, nullptr);
        }
        return *this;
    }

private:
    Resource* r_;
};
static_assert(std::is_nothrow_move_constructible_v<OwningHandle>);
```

## Caveats

- **A user-declared destructor is anything that is not implicitly declared.**
  `= default` counts; `= delete` counts; an empty body counts. The suppression
  rule does not care about the destructor's body.
- **`virtual` destructors in polymorphic bases** unavoidably trigger the
  rule. Declare or `= delete` the four other members explicitly — copy/move
  of polymorphic bases is its own design decision.
- **Rule of Zero does not mean "never write a destructor."** It means: do not
  write a destructor in a type whose work it would not do. If the destructor
  actually has resource-release work, that means the type owns a resource
  directly, which means Rule of Five applies.

## References

- Klaus Iglberger, *Back to Basics: Move Semantics*, CppCon 2021 —
  <https://www.youtube.com/watch?v=St0MNEU5b0o>
- Scott Meyers, *Effective Modern C++*, item 17 (understand special member
  function generation) — **cite-by-reference**.
- C++ Core Guidelines C.20 (rule of zero) and C.21 (rule of five) —
  <https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines#c20-if-you-can-avoid-defining-default-operations-do>
- cppreference, "The rule of three/five/zero" —
  <https://en.cppreference.com/w/cpp/language/rule_of_three>
