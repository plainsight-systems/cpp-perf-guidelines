+++
id = "MEM.6"
title = "Allocate behind one injected interface, never the global heap directly"
category = "memory"
status = "draft"
summary = "Subsystems should receive an allocator through an explicit interface rather than calling global new or malloc, so allocation can be pooled, swapped, budgeted, instrumented, and tested."
tags = ["allocator", "ownership", "dependency-injection"]
+++

## Rationale

A custom allocator is only worth building if code actually uses it. Code that
calls global `new`, `malloc`, or `std::make_unique` directly has hard-wired
itself to the general heap. It cannot be moved onto a pool, redirected to a
per-level arena, given a per-subsystem memory budget, instrumented for leak
tracking, or handed a fake allocator in a test. The allocation strategy is
frozen at the call site — the worst possible place to change it.

Production engines avoid this by funnelling all allocation through **one
interface** and **injecting** the concrete allocator into the code that needs
it:

- **Unreal** routes every allocation through the `FMalloc` interface behind the
  global `GMalloc`; the concrete allocator is chosen per platform and is
  swappable from the command line.
- **Sony London Studio** gives every allocator module a common `Allocator`
  interface (`Allocate`, `Deallocate`, `GetSize`, `GetName`); subsystems depend
  on the interface, not on a specific allocator.

The interface makes the allocator a *dependency* — visible, replaceable,
testable — instead of an ambient global.

## Guidance

- Define **one allocator interface**: `allocate(size, align)`,
  `deallocate(ptr)`, and whatever observability the project needs (owned size,
  a name or tag).
- Have subsystems **receive** an allocator — by constructor parameter — rather
  than reach for a global. The subsystem should neither know nor care whether
  it was handed an arena, a pool, or an instrumented test double.
- Inject at **subsystem boundaries**, not through every function signature. A
  particle system takes one allocator; it does not thread an allocator argument
  through every internal call.
- For standard-library containers, the standard expression of this is
  `std::pmr` — a polymorphic allocator passed to allocator-aware containers
  (covered by a later guideline in this category).
- The injected allocator must **outlive** every subsystem that holds a
  reference to it.

## Example

```cpp
// One interface. Every subsystem depends on this, not on global operator new.
class Allocator {
public:
    virtual ~Allocator() = default;
    virtual void* allocate(std::size_t size, std::size_t align) = 0;
    virtual void  deallocate(void* p) noexcept = 0;
};

// Bad: the allocation strategy is hard-wired to the global heap. This system
// can never be pooled, budgeted, instrumented, or tested in isolation.
class ParticleSystemBad {
public:
    Particle* spawn() { return new Particle{}; }   // global ::operator new
};

// Good: the allocator is injected. The same system runs on a pool in the
// shipping build and on a leak-tracking allocator under test — unchanged.
class ParticleSystem {
public:
    explicit ParticleSystem(Allocator& alloc) noexcept : alloc_{alloc} {}

    Particle* spawn() {
        void* p = alloc_.allocate(sizeof(Particle), alignof(Particle));
        return p ? ::new (p) Particle{} : nullptr;   // exhaustion stays visible
    }

    void destroy(Particle* particle) noexcept {
        if (!particle) return;
        particle->~Particle();
        alloc_.deallocate(particle);
    }

private:
    Allocator& alloc_;
};
```

## Caveats

- **Inject at boundaries, not everywhere.** Threading an allocator parameter
  through every function is its own kind of coupling. Hand it to a subsystem
  once.
- **Lifetime.** The allocator must outlive its users; injecting a reference
  makes that ordering the caller's explicit responsibility.
- **A virtual interface has a call cost.** It is negligible against the cost of
  a real allocation, but for the very hottest paths a template allocator
  parameter avoids the indirect call. Choose deliberately.
- Global `new`/`delete` *can* be overridden to route to a chosen allocator, but
  that is one process-wide policy; explicit injection is what gives
  per-subsystem control.

## References

- John Lakos, "Local ('Arena') Memory Allocators", CppCon 2017.
- Unreal Engine memory — the `FMalloc` interface and `GMalloc` —
  <https://github.com/donaldwuid/unreal_source_explained/blob/master/main/memory.md>
- Aaron MacDougall, "Building a Low-Fragmentation Memory System for 64-bit
  Games", GDC 2016 — <https://media.gdcvault.com/gdc2016/Presentations/MacDougall_Aaron_Building_A_Low.pdf>
- Electronic Arts, EASTL design documentation —
  <https://github.com/electronicarts/EASTL/blob/master/doc/Design.md>
