#!/usr/bin/env python3
"""Require documentation on every new or changed authored function, including tests."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess
import sys
import tempfile

try:
    from . import docstring_coverage as coverage
except ImportError:
    import docstring_coverage as coverage


def git(root: Path, *arguments: str) -> bytes:
    """Read Git evidence without allowing external diff commands or ignoring failures."""
    return subprocess.run(["git", "-C", str(root), *arguments], check=True,
                          capture_output=True).stdout


def parse_sources(root: Path, paths: list[str]) -> list[coverage.Declaration]:
    """Parse explicit source paths with the same pinned parsers as the overall gate."""
    declarations = []
    javascript = []
    for path in paths:
        language = coverage.source_language(path, include_tests=True)
        if language in {"JavaScript", "TypeScript"}:
            javascript.append(path)
        elif language:
            parser = {"Swift": coverage.swift_declarations, "Python": coverage.python_declarations,
                      "Shell": coverage.shell_declarations}[language]
            declarations.extend(parser(path, (root / path).read_text(encoding="utf-8")))
    declarations.extend(coverage.javascript_declarations(root, javascript))
    return declarations


def function_text(root: Path, declaration: coverage.Declaration) -> str:
    """Retain the full declaration, documentation, attributes, and body for comparison."""
    if declaration.start_line is None or declaration.end_line is None:
        raise ValueError(f"Missing function source span: {declaration.path}:{declaration.line}")
    lines = (root / declaration.path).read_text(encoding="utf-8").splitlines()
    return "\n".join(lines[declaration.start_line - 1:declaration.end_line])


def changed_declarations(root: Path, base: str) -> list[coverage.Declaration]:
    """Compare surviving function bodies against an immutable base, including local new files.

    Exact source matches consume a multiset entry, so line shifts do not count as
    edits and duplicate additions cannot borrow an unchanged function's exemption.
    Removed functions need no documentation; renamed files are treated as additions.
    """
    base_sha = git(root, "rev-parse", "--verify", f"{base}^{{commit}}").decode().strip()
    changed = git(root, "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                  "--name-only", "--diff-filter=ACMRT", "-z", base_sha, "--").decode().split("\0")
    changed += git(root, "ls-files", "--others", "--exclude-standard", "-z").decode().split("\0")
    paths = sorted({path for path in changed if path and coverage.source_language(path, include_tests=True)
                    and (root / path).is_file()})
    if not paths:
        return []
    old_paths = set(git(root, "ls-tree", "-r", "--name-only", "-z", base_sha).decode().split("\0"))
    with tempfile.TemporaryDirectory(prefix="intents-function-docs-") as directory:
        previous_root = Path(directory)
        previous_paths = [path for path in paths if path in old_paths]
        for path in previous_paths:
            target = previous_root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(git(root, "show", f"{base_sha}:{path}"))
        previous = Counter((item.path, item.kind, item.name, item.documented, function_text(previous_root, item))
                           for item in parse_sources(previous_root, previous_paths))
        result = []
        for item in parse_sources(root, paths):
            key = (item.path, item.kind, item.name, item.documented, function_text(root, item))
            if previous[key]:
                previous[key] -= 1
            else:
                result.append(item)
    return sorted(result, key=lambda item: (item.path, item.line, item.name))


def main(argv: list[str] | None = None) -> int:
    """Print actionable missing documentation and fail closed on invalid comparison evidence."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, help="Immutable PR merge base or push's previous commit")
    parser.add_argument("--root", type=Path, default=coverage.ROOT, help="Git checkout to inspect")
    parser.add_argument("--json", action="store_true", help="Print changed declarations and exact counts")
    args = parser.parse_args(argv)
    try:
        changed = changed_declarations(args.root.resolve(), args.base)
    except (OSError, ValueError, SyntaxError, subprocess.CalledProcessError) as error:
        print(f"Changed-function documentation check failed: {error}", file=sys.stderr)
        return 2
    missing = [item for item in changed if not item.documented]
    if args.json:
        from dataclasses import asdict
        print(json.dumps({"changed": len(changed), "missing": len(missing),
                          "declarations": [asdict(item) for item in changed]}, indent=2))
    else:
        print(f"Changed-function documentation: {len(changed) - len(missing)}/{len(changed)} documented")
        for item in missing:
            print(f"{item.path}:{item.line}: document {item.kind} {item.name}")
    return int(bool(missing))


if __name__ == "__main__":
    sys.exit(main())
