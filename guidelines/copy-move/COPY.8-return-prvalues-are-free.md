+++
id = "COPY.8"
title = "In C++17, return a prvalue — factory functions by value are free"
category = "copy-move"
status = "draft"
summary = "After C++17 (P0135), returning a prvalue (return T{...}) is guaranteed to perform no copy or move — even for types with deleted copy/move. Factory functions by value are genuinely free."
tags = ["rvo", "nrvo", "copy-elision", "p0135"]
+++

## Rationale

Before C++17, `T f() { return T{}; }` followed by `T x = f();` was understood
to involve copies or moves that the compiler was *permitted* to elide — the
copy/move constructor still had to *exist*, and an implementation that chose
not to elide was conforming. Generic libraries had to assume the move would
happen.

**P0135 ("Guaranteed copy elision through simplified value categories")**
adopted into C++17 makes this binding. A prvalue is no longer "a temporary
object"; it is an *expression that will materialize* a result object, and
materialization only happens when the result object's location is required.
The practical consequences:

- `T f() { return T{...}; }` and `T x = f();` involve **no copy and no
  move**. Guaranteed. The prvalue **is** the object being initialized.
- A type with both copy and move constructors `= delete`d can still be
  returned by value from a factory, as long as the return expression is a
  prvalue. Standard examples: a factory returning a `std::lock_guard` or any
  immovable type.
- The construction chain works through function arguments and other prvalue
  contexts.

What P0135 does **not** change:

- **NRVO** — returning a named local — remains *permitted, not mandatory*.
  The compiler may elide; otherwise an implicit move (or copy) runs. This is
  why `COPY.1` matters: `std::move(local)` on a return suppresses NRVO and
  forces a move where elision was possible.
- **Returning a function parameter** is not a prvalue context. The implicit
  move is the best you get.
- **Returning a data member** is also not a prvalue context for the
  enclosing object.

Hinnant has hammered the prvalue-elision rule in talks for a decade; P0135
made it the language's contract.

## Guidance

- For factory functions, return a **prvalue** — `return T{args...};` — to
  get guaranteed elision.
- A factory function can return a type whose copy and move are `= delete`d.
  Use this for immovable RAII types (locks, scope guards, transactions) when
  you want to deny ownership transfer but still permit construction by a
  helper.
- For functions that build up a named local before returning it, return the
  named local by name (`return b;`) — NRVO will usually elide; otherwise an
  implicit move runs. **Do not** `std::move` the local (see `COPY.1`).
- If a function returns a member or a parameter, the implicit move is what
  you get — be aware that no elision applies, and the type's move had better
  be `noexcept` (`COPY.2`).
- Builder-pattern factories work cleanly: a chain of `&&`-qualified setters
  building up state, with a final `build() &&` that returns a prvalue.

## Example

```cpp
// In C++17, returning a prvalue performs NO copy and NO move — even when
// both are deleted. The prvalue IS the object being initialized.
class Mutex {
public:
    Mutex() = default;
    ~Mutex() = default;
    Mutex(const Mutex&)            = delete;
    Mutex& operator=(const Mutex&) = delete;
    Mutex(Mutex&&)                 = delete;   // immovable
    Mutex& operator=(Mutex&&)      = delete;
};

// OK in C++17: no copy, no move — the prvalue constructs in place.
Mutex make_mutex() { return Mutex{}; }

void demo() {
    Mutex m = make_mutex();   // direct construction; no temporary
}

// Builder-pattern factory: the final `build() &&` returns a prvalue. The
// caller initializes its Command directly from that prvalue — no move.
class CommandBuilder {
public:
    CommandBuilder& set_name(std::string s) &  noexcept {
        name_ = std::move(s); return *this;
    }
    CommandBuilder& add_arg(std::string a) &  noexcept {
        args_.push_back(std::move(a)); return *this;
    }
    Command build() && {                           // prvalue return
        return Command{std::move(name_), std::move(args_)};
    }

private:
    std::string              name_;
    std::vector<std::string> args_;
};

// NRVO is permitted, not mandatory. Pair with COPY.1: do NOT std::move the
// local — that suppresses NRVO and forces a move where elision was possible.
Buffer load_buffer(const Path& p) {
    Buffer b;
    fill_from_disk(b, p);
    return b;               // NRVO candidate; otherwise an implicit move
    // return std::move(b); // bad — kills NRVO (see COPY.1)
}
```

## Caveats

- **NRVO is optional.** Building up a complex named object and returning it
  may or may not be elided; rely on `noexcept` move (`COPY.2`) as the
  fallback. Returning a prvalue (`return T{...}`) is mandatory elision and
  has no fallback to depend on — prefer it when the construction can be
  expressed inline.
- **Returning a member or a parameter is not a prvalue context.** An
  implicit move applies; `std::move` *is* needed there (this is one of the
  narrow exceptions to `COPY.1`).
- **Compiler NRVO holes exist.** Returning from inside a `try`/`catch`
  block, or returning different named locals on different paths, may
  suppress NRVO in some compilers. The behavior is Godbolt-observable but
  not in the standard. The move-fallback still runs; the cost is a move you
  did not expect.
- **Do not return references to locals.** That is a different bug from
  anything in this guideline — and a dangling-reference one, not a copy one.

## References

- Richard Smith, P0135R1, "Guaranteed copy elision through simplified value
  categories" (C++17) —
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2016/p0135r1.html>
- Howard Hinnant, copy-elision posts and answers —
  <https://howardhinnant.github.io/>
- Scott Meyers, *Effective Modern C++*, item 25 (use `std::move` on rvalue
  references, `std::forward` on universal references) — **cite-by-reference**.
- cppreference, "Copy elision" —
  <https://en.cppreference.com/w/cpp/language/copy_elision>
