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

## Licensing

By contributing, you agree your contributions are licensed under this
repository's terms: guideline content under CC BY 4.0, code samples and tooling
under Apache-2.0. See `LICENSE-CC-BY` and `LICENSE-APACHE`.

## Security

Do not report security vulnerabilities in public issues. See `SECURITY.md`.

## Code of conduct

Participation in this project is governed by `CODE_OF_CONDUCT.md`.
