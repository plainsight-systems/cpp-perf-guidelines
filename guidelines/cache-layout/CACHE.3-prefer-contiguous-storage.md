+++
id = "CACHE.3"
title = "Prefer contiguous storage; pointer-chasing pays a cache miss per node"
category = "cache-layout"
status = "draft"
summary = "std::list, std::map, and pointer-chasing trees pay a cache miss per node. std::vector and flat-hash tables let the hardware prefetcher do its job — the difference is one to two orders of magnitude."
tags = ["contiguous", "vector", "list", "flat-hash"]
+++

## Rationale

The "Big-O" analysis taught in introductory courses ignores the constant
factors on memory access — and on real hardware those factors are not
constants, they are *gradients*. A linear walk through a `std::vector`
streams memory at the bandwidth of the prefetcher (a few cycles per element).
A linear walk through a `std::list` pays a cache miss per node — ~100–300
cycles when the node is not already in cache, which it almost never is.

Stroustrup demonstrated this on stage at GoingNative 2012 with a simple
benchmark: insert N random integers into a sorted sequence, using
`std::vector<int>` versus `std::list<int>`. The textbook prediction is that
`list` should eventually win, because its O(1) insert beats `vector`'s O(N)
shift. **The crossover never arrives.** `vector` is faster by one to two
orders of magnitude across the entire measured range (a few hundred to
~500 000 elements). The reason is the cache, not the algorithm: `vector`'s
shift is a streaming `memmove` the hardware prefetcher handles trivially;
`list` traversal stalls on every link.

Chandler Carruth's *Efficiency with Algorithms, Performance with Data
Structures* (CppCon 2014) generalises the rule: `std::list` and `std::map`
are almost never the right answer. If you need ordering, sort a vector. If
you need keyed lookup, use a flat-hash table or a sorted vector + binary
search.

## Guidance

- Default to **contiguous storage**. `std::vector<T>` is the right container
  more often than any other.
- For **ordered sequences**, prefer a sorted `std::vector` + binary search
  (`std::lower_bound`) over `std::set` / `std::map`. The constant factor on
  every operation is dramatically lower.
- For **keyed lookup**, prefer a *flat* hash table (Abseil's
  `absl::flat_hash_map`, `robin_hood::unordered_flat_map`, `boost::unordered_flat_map`)
  over `std::unordered_map`. The standard `unordered_map`'s node-based design
  is a cache pathology; the flat variants store key / value pairs in one
  contiguous array.
- Use `std::list` only when **stable iteration through arbitrary
  insertions / deletions** is a hard requirement and you have measured. Use
  `std::map` only when **ordered iteration** is a hard requirement.
- For "pointer-stable handles into the container", store **indices into a
  vector** rather than pointers — indices survive growth, and the vector
  pays the cache cost of being a vector once.

## Example

```cpp
// Bad: std::map and std::list look natural and are cache-toxic. Every find,
// every iteration step, is a node-pointer chase that the hardware prefetcher
// cannot predict.
std::map<EntityId, Widget>   by_id;     // pointer-chasing tree
std::list<Event>              events;    // pointer-chasing list

// Good: contiguous storage. Lookups and iteration stream through L1.
absl::flat_hash_map<EntityId, Widget> by_id;     // contiguous key/value
std::vector<Event>                    events;    // contiguous

// Sorted-vector pattern: ordered iteration without the std::set tax.
struct SortedSet {
    std::vector<int> data;   // kept sorted

    void insert(int x) {
        auto it = std::lower_bound(data.begin(), data.end(), x);
        if (it == data.end() || *it != x) data.insert(it, x);
    }
    bool contains(int x) const {
        return std::binary_search(data.begin(), data.end(), x);
    }
};

// Stable-handle pattern: index, not pointer. Iterator invalidation on grow
// does not invalidate indices.
class HandleTable {
public:
    using Handle = std::uint32_t;

    Handle create(Widget w) {
        items_.push_back(std::move(w));
        return static_cast<Handle>(items_.size() - 1);
    }
    Widget& get(Handle h) noexcept { return items_[h]; }

private:
    std::vector<Widget> items_;
};
```

## Caveats

- **`std::vector` invalidates iterators and pointers on growth.** Code that
  holds raw pointers / iterators across an `emplace_back` is buggy.
  `reserve()` to the worst case, or use indices (the handle pattern above).
- **A flat-hash table requires a good hash for the key.** A bad hash collapses
  performance to linear probing across a contiguous array — still better than
  `unordered_map`'s node chain, but the win is much smaller.
- **Sorted-vector insert is O(N).** It still beats `std::set` for small to
  medium N; past some threshold (workload-specific, measure) the algorithm
  wins back. The threshold is much larger than intuition suggests.
- **There are real `std::list` cases.** Splice-without-copy is genuinely O(1)
  and `std::list` is the only standard container that offers it. The point is
  to *measure*, not to ban the type — the default should not be `list`.

## References

- Bjarne Stroustrup, *C++11 Style* (the vector-vs-list demo), GoingNative
  2012 —
  <https://channel9.msdn.com/Events/GoingNative/GoingNative-2012/Keynote-Bjarne-Stroustrup-Cpp11-Style>
- Chandler Carruth, *Efficiency with Algorithms, Performance with Data
  Structures*, CppCon 2014 —
  <https://www.youtube.com/watch?v=fHNmRkzxHWs>
- Abseil — `absl::flat_hash_map` documentation —
  <https://abseil.io/docs/cpp/guides/container>
- C++ Core Guidelines SL.con.2 (prefer `std::vector` by default) —
  <https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines#slcon2-prefer-using-stl-vector-by-default-unless-you-have-a-reason-to-use-a-different-container>
