# Contributing

Thanks for considering a contribution to the C++ Performance Guidelines corpus.

## What this repository is

A curated corpus of low-level C++ performance guidelines. Each guideline is a
single Markdown file with TOML frontmatter under `guidelines/<category>/`. The
format is specified in `README.md` — read it before adding or changing entries.

## Engineering philosophy

This corpus is maintained to the Plainsight Systems engineering philosophy:
<https://github.com/plainsight-systems/.github/blob/main/engineering_philosophies.md>

## Adding or changing a guideline

- One guideline per file; one primary idea per guideline.
- Follow the frontmatter and section format specified in `README.md`.
- New guidelines start at `status: draft`; promote to `stable` only after
  review.
- Prefer measurable, technique-level guidance over general advice.
- Guideline IDs are stable and are never reused.

Before submitting, run this with Python 3.11+:

```sh
python3 tools/validate_corpus.py
```

The validator checks category declarations, frontmatter, ID/category/token
consistency, required sections, summary length, and local Markdown links.

## Sourcing rule

Every guideline is original work. Learn from sources — never copy them.

- Techniques, algorithms, and methods are not copyrightable. You may study any
  source (books, papers, conference talks, open-source or source-available
  engine code) and write original guidance about what you learn.
- Cite where a technique is documented in the guideline's `## References`
  section. Citing a source — including books and source-available engines such
  as Unreal — is always acceptable and encouraged.
- Do not copy or closely paraphrase a source's text or code. Illustrative code
  samples must be written for this corpus, not lifted or transliterated.
- Source-available (e.g. Unreal) and copyleft/GPL (e.g. id Tech) code must
  never be copied into this repository. Study the technique; describe it in
  your own words.

## Licensing

By contributing, you agree your contributions are licensed under this
repository's terms: guideline content under CC BY 4.0, code samples and tooling
under Apache-2.0. See `LICENSE-CC-BY` and `LICENSE-APACHE`.

## Security

Do not report security vulnerabilities in public issues. See `SECURITY.md`.

## Code of conduct

Participation in this project is governed by `CODE_OF_CONDUCT.md`.
