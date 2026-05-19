---
id: COPY.1
title: Do not std::move a local variable in a return statement
category: copy-move
status: draft
summary: Returning a local by plain value is eligible for NRVO; wrapping it in std::move suppresses elision and forces a move, or pessimizes copy-only types.
tags: [rvo, nrvo, move-semantics]
---

## Rationale

When a function returns a local variable by value, the compiler may apply Named
Return Value Optimization (NRVO): the local is constructed directly in the
caller's storage, so *no* copy or move runs at all. Even when NRVO is not applied,
the return of a named local is treated as an rvalue, so a move is selected
automatically.

Writing `return std::move(local);` changes the expression from an
NRVO-eligible name to a function call. NRVO can no longer apply, so a move
construction is now mandatory where elision would have produced nothing. Worse,
if the return type is copy-only (no move constructor), the explicit `std::move`
still binds to the copy constructor — you have written `std::move` and gained a
copy.

## Guidance

Return local objects by **plain value**. Let NRVO, or guaranteed copy elision for
prvalues, do the work:

```cpp
Buffer make_buffer() {
    Buffer b;
    fill(b);
    return b;          // NRVO-eligible; falls back to an implicit move
}
```

Never write `return std::move(local);` when `local` is a local variable of the
function's return type.

## Example

```cpp
// Pessimized: NRVO suppressed, a move is forced.
Widget bad() {
    Widget w;
    return std::move(w);
}

// Correct: NRVO may elide entirely; otherwise an implicit move runs.
Widget good() {
    Widget w;
    return w;
}
```

## Caveats

`std::move` on a return *is* correct, and necessary, when the returned object is
**not** an NRVO candidate:

- Returning a **data member** or a **by-reference parameter** — these are never
  NRVO-eligible, and without `std::move` a copy is selected.
- Returning a **base-class subobject** of a derived local.

The rule is narrow: it applies only to a local variable whose type matches the
return type.

## References

- [Return Value Optimization — cppcheatsheet](https://cppcheatsheet.com/notes/cpp/cpp_rvo.html)
- [C++ Rvalues, Move Semantics, and Copy Elision](https://medium.com/swlh/c-rvalues-move-semantics-and-copy-elision-36d492da5446)
