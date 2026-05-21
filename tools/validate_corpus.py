#!/usr/bin/env python3
"""Validate the cpp-perf-guidelines corpus format.

This intentionally uses only the Python 3.11+ standard library so contributors
can run it without setting up the MCP server workspace.
"""

from __future__ import annotations

import argparse
import re
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path


REQUIRED_FRONTMATTER = {"id", "title", "category", "status", "summary"}
REQUIRED_SECTIONS = {"Rationale", "Guidance"}
VALID_STATUSES = {"draft", "stable"}
LINK_RE = re.compile(r"\[[^\]]+\]\(([^)]+)\)")


@dataclass(frozen=True)
class Category:
    key: str
    token: str


def load_categories(root: Path) -> dict[str, Category]:
    data = tomllib.loads((root / "categories.toml").read_text(encoding="utf-8"))
    categories: dict[str, Category] = {}
    tokens: set[str] = set()

    for item in data.get("category", []):
        key = item.get("key")
        token = item.get("token")
        if not key or not token:
            raise ValueError("category entries require key and token")
        if key in categories:
            raise ValueError(f"duplicate category key: {key}")
        if token in tokens:
            raise ValueError(f"duplicate category token: {token}")
        categories[key] = Category(key=key, token=token)
        tokens.add(token)

    if not categories:
        raise ValueError("categories.toml declares no categories")
    return categories


def split_frontmatter(path: Path) -> tuple[dict[str, object], str]:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("+++\n"):
        raise ValueError("missing TOML frontmatter opening delimiter")

    end = text.find("\n+++\n", 4)
    if end == -1:
        raise ValueError("missing TOML frontmatter closing delimiter")

    frontmatter = tomllib.loads(text[4:end])
    body = text[end + len("\n+++\n") :]
    return frontmatter, body


def section_names(body: str) -> set[str]:
    return {
        line[3:].strip()
        for line in body.splitlines()
        if line.startswith("## ") and line[3:].strip()
    }


def is_external_link(target: str) -> bool:
    return bool(re.match(r"^[a-z][a-z0-9+.-]*:", target)) or target.startswith("#")


def validate_local_links(root: Path, path: Path, body: str) -> list[str]:
    errors: list[str] = []
    for match in LINK_RE.finditer(body):
        target = match.group(1).split("#", 1)[0]
        if not target or is_external_link(target):
            continue

        resolved = (path.parent / target).resolve()
        try:
            resolved.relative_to(root.resolve())
        except ValueError:
            errors.append(f"local link escapes repository: {target}")
            continue

        if not resolved.exists():
            errors.append(f"local link target does not exist: {target}")
    return errors


def validate_guideline(
    root: Path,
    path: Path,
    categories: dict[str, Category],
    seen_ids: set[str],
) -> list[str]:
    rel = path.relative_to(root)
    errors: list[str] = []

    try:
        frontmatter, body = split_frontmatter(path)
    except Exception as exc:  # noqa: BLE001 - report all parse failures cleanly.
        return [f"{rel}: {exc}"]

    missing = REQUIRED_FRONTMATTER - set(frontmatter)
    if missing:
        errors.append(f"missing frontmatter fields: {', '.join(sorted(missing))}")

    gid = frontmatter.get("id")
    title = frontmatter.get("title")
    category_key = frontmatter.get("category")
    status = frontmatter.get("status")
    summary = frontmatter.get("summary")

    if not isinstance(gid, str) or not re.match(r"^[A-Z]+[A-Z0-9]*\.[0-9]+$", gid):
        errors.append("id must look like TOKEN.n")
    elif gid in seen_ids:
        errors.append(f"duplicate id: {gid}")
    elif not path.name.startswith(f"{gid}-"):
        errors.append(f"filename must start with '{gid}-'")
    else:
        seen_ids.add(gid)

    if not isinstance(title, str) or not title.strip():
        errors.append("title must be a non-empty string")

    if not isinstance(summary, str) or not summary.strip():
        errors.append("summary must be a non-empty string")
    elif len(summary) > 200:
        errors.append(f"summary must be <= 200 chars, got {len(summary)}")

    if status not in VALID_STATUSES:
        errors.append(f"status must be one of {sorted(VALID_STATUSES)}")

    parent_category = path.parent.name
    if category_key != parent_category:
        errors.append(
            f"category '{category_key}' must match directory '{parent_category}'"
        )

    category = categories.get(str(category_key))
    if category is None:
        errors.append(f"unknown category: {category_key}")
    elif isinstance(gid, str):
        token = gid.split(".", 1)[0]
        if token != category.token:
            errors.append(
                f"id token '{token}' must match category token '{category.token}'"
            )

    missing_sections = REQUIRED_SECTIONS - section_names(body)
    if missing_sections:
        errors.append(f"missing sections: {', '.join(sorted(missing_sections))}")

    errors.extend(validate_local_links(root, path, body))
    return [f"{rel}: {error}" for error in errors]


def validate(root: Path) -> list[str]:
    errors: list[str] = []
    try:
        categories = load_categories(root)
    except Exception as exc:  # noqa: BLE001 - report all parse failures cleanly.
        return [f"categories.toml: {exc}"]

    guideline_root = root / "guidelines"
    seen_ids: set[str] = set()
    files = sorted(guideline_root.glob("*/*.md"))
    if not files:
        errors.append("guidelines/: no guideline markdown files found")

    for path in files:
        errors.extend(validate_guideline(root, path, categories, seen_ids))

    declared_dirs = set(categories)
    actual_dirs = {path.name for path in guideline_root.iterdir() if path.is_dir()}
    for missing_dir in sorted(declared_dirs - actual_dirs):
        errors.append(f"guidelines/{missing_dir}: missing category directory")
    for extra_dir in sorted(actual_dirs - declared_dirs):
        errors.append(f"guidelines/{extra_dir}: undeclared category directory")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "root",
        nargs="?",
        default=Path(__file__).resolve().parents[1],
        type=Path,
        help="repository root, defaults to this script's parent repository",
    )
    args = parser.parse_args()

    root = args.root.resolve()
    errors = validate(root)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    count = len(list((root / "guidelines").glob("*/*.md")))
    print(f"Validated {count} guidelines.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
