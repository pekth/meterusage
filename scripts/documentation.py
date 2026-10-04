#!/usr/bin/env python3
"""Check required documentation and add missing ADR index entries with --write."""

import argparse
from pathlib import Path
import re
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    required = ["README.md", "CHANGELOG.md", "docs/KB.md", "docs/adr/README.md"]
    for name in required:
        path = root / name
        if not path.is_file() or not path.read_text(encoding="utf-8").strip():
            print(f"Missing or empty documentation: {name}", file=sys.stderr)
            return 1

    index = root / "docs/adr/README.md"
    content = index.read_text(encoding="utf-8")
    indexed = re.findall(r"^\| \[[^\]]+\]\(([^)]+\.md)\)", content, re.MULTILINE)
    records = {path.name: path for path in sorted(index.parent.glob("[0-9][0-9][0-9][0-9]-*.md"))}
    errors = []
    for name in indexed:
        if name not in records:
            errors.append(f"ADR index points to a missing record: {name}")
    if len(indexed) != len(set(indexed)):
        errors.append("ADR index contains duplicate rows")
    for name, path in records.items():
        if name in indexed:
            continue
        if args.write:
            text = path.read_text(encoding="utf-8")
            title = text.splitlines()[0].removeprefix("# ").replace("|", "\\|")
            status = re.search(r"^- Status: (.+)$", text, re.MULTILINE)
            label = status.group(1).replace("|", "\\|") if status else "See record"
            content = content.rstrip() + f"\n| [{name[:4]}]({name}) | {title} | {label} |\n"
        else:
            errors.append(f"ADR missing from index: {name}; run --write")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    if args.write and content != index.read_text(encoding="utf-8"):
        index.write_text(content, encoding="utf-8")
    print("Documentation check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
