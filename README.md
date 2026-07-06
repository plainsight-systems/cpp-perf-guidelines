[![MseeP.ai Security Assessment Badge](https://mseep.net/pr/plainsight-systems-cpp-perf-guidelines-badge.png)](https://mseep.ai/app/plainsight-systems-cpp-perf-guidelines)

# C++ Performance Guidelines

A curated corpus of **low-level C++ performance guidelines** for game-engine and
embedded-systems developers.

This corpus deliberately sits *below* the [ISO C++ Core Guidelines](https://isocpp.github.io/CppCoreGuidelines/).
The ISO guidelines stop at "use the standard library well" — they tell you to
minimize allocations and access memory predictably, but never *how*. This corpus
owns the concrete technique layer: custom allocators, hardware-aware data layout,
copy/move discipline, object lifetime, embedded constraints, and GPU /
accelerator optimization.

It is consumed by the `cpp-perf-guidelines` MCP server in the `mcp-servers`
workspace, which clones this repo, parses it, and exposes it to agents via the
Model Context Protocol.

- **Parent entity:** Plainsight Systems LLC — parent-org infrastructure (no operating brand).
- **Maturity:** early — all ten categories are populated: `memory` (10), `copy-move` (8), `cache-layout` (8), `lifetime` (8), `embedded` (8), `concurrency` (8), `codegen` (8), `simd` (8), `telemetry` (11), and `gpu` (10). All guidelines are `draft`; promotion to `stable` is the maintainer's call.
- **Governance:** built to the [Plainsight Systems engineering philosophy](https://github.com/plainsight-systems/.github/blob/main/engineering_philosophies.md). To contribute, see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## How to use this corpus

You can read the corpus directly under [`guidelines/`](guidelines/), or consume
it through the companion MCP server in the
[`plainsight-systems/mcp-servers`](https://github.com/plainsight-systems/mcp-servers)
repository.

The MCP server exposes:

- `search_guidelines` — semantic search across the corpus.
- `get_guideline` — fetch a guideline by ID, such as `MEM.1`.
- `list_category` — browse a category, such as `memory` or `simd`.
- `update_guidelines` — refresh the indexed corpus from this repository.

## Validation

Before opening a pull request, run the corpus validator with Python 3.11+:

```sh
python3 tools/validate_corpus.py
```

The validator checks the parser contract: category declarations, frontmatter,
stable ID/category/token relationships, required sections, summary length, and
local Markdown links.

## Repository layout

```
categories.toml          Declares the 10 categories (key, ID token, display name).
guidelines/
  memory/                One subdirectory per category key.
    MEM.1-<slug>.md      One file per guideline.
  copy-move/
  cache-layout/
  lifetime/
  embedded/
  concurrency/
  codegen/
  simd/
  telemetry/
  gpu/
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

See [`categories.toml`](categories.toml). The 10 categories and their ID tokens:

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
| `TLM`  | Telemetry & Observability Harnesses   |
| `GPU`  | GPU & Accelerator Optimization        |

## Contributing

- One guideline per file. One primary idea per guideline.
- New guidelines start at `status: draft`. Promote to `stable` only after review.
- Prefer measurable, technique-level guidance over general advice — the general
  advice already lives in the ISO Core Guidelines.
- Run `python3 tools/validate_corpus.py` with Python 3.11+ before submitting changes.

## License

This repository is dual-licensed to separate prose from code:

- **Guideline content** — the prose of every guideline, `categories.toml`, and
  this README — is licensed under
  [Creative Commons Attribution 4.0 International](LICENSE-CC-BY) (CC BY 4.0).
  Reuse and adaptation are permitted, including commercially, with attribution.
- **Code** — code samples embedded in the guidelines, and any scripts or
  tooling in this repository — is licensed under the
  [Apache License 2.0](LICENSE-APACHE).
