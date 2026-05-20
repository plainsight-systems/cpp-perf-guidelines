# C++ Performance Guidelines

A curated corpus of **low-level C++ performance guidelines** for game-engine and
embedded-systems developers.

This corpus deliberately sits *below* the [ISO C++ Core Guidelines](https://isocpp.github.io/CppCoreGuidelines/).
The ISO guidelines stop at "use the standard library well" — they tell you to
minimize allocations and access memory predictably, but never *how*. This corpus
owns the concrete technique layer: custom allocators, hardware-aware data layout,
copy/move discipline, object lifetime, and embedded constraints.

It is consumed by the `cpp-perf-guidelines` MCP server in the `mcp-servers`
workspace, which clones this repo, parses it, and exposes it to agents via the
Model Context Protocol.

- **Parent entity:** Plainsight Systems LLC — parent-org infrastructure (no operating brand).
- **Maturity:** early — `memory` (10), `copy-move` (8), and `cache-layout` (8) are populated; `lifetime` has 4 guidelines; the remaining four categories (`embedded`, `concurrency`, `codegen`, `simd`) are not yet populated.
- **Governance:** built to the [Plainsight Systems engineering philosophy](https://github.com/plainsight-systems/.github/blob/main/engineering_philosophies.md). To contribute, see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Repository layout

```
categories.toml          Declares the 7 categories (key, ID token, display name).
guidelines/
  memory/                One subdirectory per category key.
    MEM.1-<slug>.md      One file per guideline.
  copy-move/
  cache-layout/
  lifetime/
  embedded/
  concurrency/
  codegen/
```

The document format **is** the parser contract. The MCP server's parser depends on
the structure described below; changes here are changes to that contract.

## Guideline file format

Each guideline is a single Markdown file with **TOML frontmatter** followed by a
**Markdown body**.

### Filename

```
<ID>-<kebab-slug>.md          e.g. MEM.1-arena-allocator-for-frame-scope.md
```

The `<kebab-slug>` portion is exposed by the MCP server as the guideline `anchor`.

### Frontmatter (required block, delimited by `+++`)

A TOML document, opened and closed by a line containing exactly `+++`.

| Field      | Required | Description                                                        |
|------------|----------|--------------------------------------------------------------------|
| `id`       | yes      | `"<TOKEN>.<n>"` — token from `categories.toml`, integer `n`. Stable, never reused. |
| `title`    | yes      | Short imperative title.                                            |
| `category` | yes      | Must equal a `key` declared in `categories.toml`.                  |
| `status`   | yes      | `"draft"` or `"stable"`.                                           |
| `summary`  | yes      | One line, ≤ 200 chars. Surfaced in `search_guidelines` results.    |
| `tags`     | no       | Array of lowercase cross-cutting tags (e.g. `["alignment", "object-pooling"]`). |

```toml
+++
id = "MEM.1"
title = "Use an arena allocator for allocations bounded by a known scope"
category = "memory"
status = "draft"
summary = "One-line summary, surfaced in search results."
tags = ["arena", "allocator"]
+++
```

### Body (Markdown, `##` section headings)

| Section         | Required | Purpose                                            |
|-----------------|----------|----------------------------------------------------|
| `## Rationale`  | yes      | Why this matters — the cost being avoided.         |
| `## Guidance`   | yes      | The actual rule or technique.                      |
| `## Example`    | no       | Illustrative code.                                 |
| `## Caveats`    | no       | When *not* to apply; tradeoffs.                    |
| `## References` | no       | Links to authoritative sources.                    |

### Invariants

- `id` is globally unique and **never reused**, even if a guideline is deleted.
- `category` must match the directory the file lives in (`guidelines/<category>/`).
- The `<TOKEN>` in `id` must be the token declared for that `category`.

## Categories

See [`categories.toml`](categories.toml). The 7 categories and their ID tokens:

| Token  | Category                              |
|--------|---------------------------------------|
| `MEM`  | Custom Allocators & Memory Management |
| `COPY` | Copy & Move Discipline                |
| `CACHE`| Data Layout & Cache Behavior          |
| `LIFE` | Object Lifetime & Construction        |
| `EMB`  | Embedded & Deterministic Constraints  |
| `CONC` | Concurrency & Memory Effects          |
| `GEN`  | Branching & Codegen                   |
| `SIMD` | SIMD & Vectorization                  |

## Contributing

- One guideline per file. One primary idea per guideline.
- New guidelines start at `status: draft`. Promote to `stable` only after review.
- Prefer measurable, technique-level guidance over general advice — the general
  advice already lives in the ISO Core Guidelines.

## License

This repository is dual-licensed to separate prose from code:

- **Guideline content** — the prose of every guideline, `categories.toml`, and
  this README — is licensed under
  [Creative Commons Attribution 4.0 International](LICENSE-CC-BY) (CC BY 4.0).
  Reuse and adaptation are permitted, including commercially, with attribution.
- **Code** — code samples embedded in the guidelines, and any scripts or
  tooling in this repository — is licensed under the
  [Apache License 2.0](LICENSE-APACHE).
