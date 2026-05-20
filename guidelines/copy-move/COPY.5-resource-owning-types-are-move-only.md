+++
id = "COPY.5"
title = "Express unique-ownership resources as move-only types"
category = "copy-move"
status = "draft"
summary = "Resources with unique ownership semantics should be move-only types: delete the copy operations, write noexcept moves that leave the source in a safe sentinel state. std::unique_ptr is the model."
tags = ["move-only", "raii", "move-semantics"]
+++

## Rationale

Some resources have *unique* ownership semantics. A file descriptor, a GPU
buffer handle, a socket, an OS thread, a database connection — each is a
single thing in the underlying system, and two C++ objects holding the same
handle are either a bug (double-close on destruction) or a refcount in
disguise.

The cleanest expression of unique ownership is a **move-only** type: copy
operations are deleted, and move operations are `noexcept` (`COPY.2`). The
unique-ownership invariant becomes a compile-time property — duplicating the
handle is a compile error, not a runtime bug. Hinnant's framing in
"Everything You Ever Wanted to Know About Move Semantics" makes the case at
length; `std::unique_ptr`, `std::thread`, `std::ifstream`, and many other
standard types follow exactly this shape.

A move-only type also forces a small but important design discipline: define
what the **moved-from state** looks like, and make sure the destructor is
safe on that state. The "valid but unspecified" rule the standard imposes
requires only that the destructor and assignment work — your type usually
needs to say more.

## Guidance

If the resource has unique ownership semantics:

- **Delete the copy operations.** Both copy constructor and copy assignment
  are `= delete`. The compile error at the wrong copy site is the feature.
- **Write `noexcept` move operations** (`COPY.2`) — either `= default` if the
  subobjects already do the right thing, or a custom body that swaps a handle
  with a sentinel value.
- **Define the moved-from state explicitly.** A move leaves the source in a
  state where the destructor is a safe no-op — typically by giving the
  handle a sentinel value (`nullptr`, `-1`, `INVALID_HANDLE_VALUE`).
- **The destructor must be safe on the sentinel.** It runs on every
  moved-from object.
- **Do not "make it copyable" by deep-copying the resource.** A copy of a
  file descriptor that secretly `dup()`s is a different type with different
  semantics; if you need that, build it as its own type with an explicit
  name.

Move-only types compose: `std::vector<std::unique_ptr<T>>` works fine, and so
does `std::vector<YourMoveOnlyType>` since C++11.

## Example

```cpp
// A move-only RAII wrapper for a POSIX file descriptor. Copy is deleted —
// duplicating an fd is either a bug or refcounting in disguise. Move is
// noexcept and leaves the source in the sentinel (closed) state so the
// destructor can run safely on a moved-from object.
class FileHandle {
public:
    static constexpr int kInvalid = -1;

    explicit FileHandle(int fd) noexcept : fd_{fd} {}

    ~FileHandle() {
        if (fd_ != kInvalid) ::close(fd_);
    }

    // Copy: deleted. Two FileHandle objects must not own the same fd.
    FileHandle(const FileHandle&)            = delete;
    FileHandle& operator=(const FileHandle&) = delete;

    // Move: noexcept, leaves the source in the sentinel state.
    FileHandle(FileHandle&& other) noexcept
        : fd_{std::exchange(other.fd_, kInvalid)} {}

    FileHandle& operator=(FileHandle&& other) noexcept {
        if (this != &other) {
            if (fd_ != kInvalid) ::close(fd_);
            fd_ = std::exchange(other.fd_, kInvalid);
        }
        return *this;
    }

    int  get()   const noexcept { return fd_; }
    bool valid() const noexcept { return fd_ != kInvalid; }

private:
    int fd_;
};

static_assert(!std::is_copy_constructible_v<FileHandle>);
static_assert( std::is_nothrow_move_constructible_v<FileHandle>);

// Bad: pretending unique ownership is copyable by silently sharing the fd.
// Two FileHandleBad objects can now each close the same fd — double-close,
// resource corruption, undefined behavior. The bug is silent at every call
// site.
class FileHandleBad {
public:
    explicit FileHandleBad(int fd) noexcept : fd_{fd} {}
    ~FileHandleBad() { if (fd_ != -1) ::close(fd_); }
    // Copy operations defaulted-implicit: shallow copy of fd_.
private:
    int fd_;
};
```

## Caveats

- **The moved-from state must be a safe no-op for the destructor.** Forgetting
  to set the source to the sentinel — or picking a sentinel the destructor
  treats as live (`0` is a valid fd, namely stdin) — is the classic
  use-after-move bug.
- **Move-only breaks `Copyable` and `Regular` concepts.** Code that assumes
  regular types will fail to compile against your type — usually that
  surprise is exactly the case where copying would have been the bug.
- **The standard library's stronger guarantees are opt-in.** Moved-from
  `unique_ptr` is guaranteed empty; moved-from `string` is "valid but
  unspecified" — the standard does *not* promise it is empty (though in
  practice every implementation makes it so). Your own types should document
  what they guarantee.
- **Some "unique" resources are actually refcounted at the OS level**
  (`std::shared_ptr`, refcounted handles). Those are different types from a
  move-only wrapper; pick one model and name it.

## References

- Howard Hinnant, *Everything You Ever Wanted to Know About Move Semantics*,
  CppCon 2014 / ACCU 2016 —
  <https://www.youtube.com/watch?v=vLinb2fgkHk>
- `std::unique_ptr` (the canonical move-only type) — cppreference —
  <https://en.cppreference.com/w/cpp/memory/unique_ptr>
- C++ Core Guidelines R.20 / R.21 (prefer `unique_ptr` for unique ownership) —
  <https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines#r20-use-unique_ptr-or-shared_ptr-to-represent-ownership>
- Scott Meyers, *Effective Modern C++*, items 18 (use `std::unique_ptr` for
  exclusive-ownership resource management) and 19 — **cite-by-reference**.
