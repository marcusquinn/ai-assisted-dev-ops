# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Counts/check/update CLI for the auditable README inventory."""

import argparse
import sys
from pathlib import Path

from readme_inventory import inventory, show_counts
from readme_inventory_documents import (
    hero_title,
    update_readme,
    update_svg,
    validate_readme,
    validate_svg,
)


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    counts = commands.add_parser("counts", help="Count tracked source definitions")
    output = counts.add_mutually_exclusive_group()
    for name in ("json", "approx", "inventory"):
        output.add_argument(
            "--" + name, action="store_const", const=name, dest="output"
        )
    for name in ("check", "update"):
        command = commands.add_parser(name)
        command.add_argument(
            "file", nargs="?", type=Path, help="Alternative README (hero unchanged)"
        )
        if name == "update":
            command.add_argument(
                "--apply",
                action="store_true",
                help="Write README/SVG; rerender PNG separately",
            )
    return result


def check_documents(text, svg_text, counts):
    errors = validate_readme(text, counts)
    if svg_text is not None:
        errors.extend(validate_svg(svg_text, counts))
    for error in errors:
        print(error, file=sys.stderr)
    if not errors:
        print(
            "README and editable hero counts verified; inspect the rendered PNG separately."
        )
    return int(bool(errors))


def process_documents(args, root, counts):
    readme = args.file or root / "README.md"
    text = readme.read_text(encoding="utf-8")
    svg = root / "docs/assets/og-stats.svg" if args.file is None else None
    svg_text = svg.read_text(encoding="utf-8") if svg else None
    if args.command == "check":
        return check_documents(text, svg_text, counts)
    updated = update_readme(text, counts)
    updated_svg = update_svg(svg_text, counts) if svg_text is not None else None
    if not args.apply:
        print("Dry run: " + hero_title(counts))
        return 0
    readme.with_name(readme.name + ".bak").write_text(text, encoding="utf-8")
    readme.write_text(updated, encoding="utf-8")
    if svg is not None:
        svg.write_text(updated_svg, encoding="utf-8")
    print(
        "Counts updated. Rerender og-image.png from og-stats.svg using DESIGN.md before committing."
    )
    return 0


def main(argv=None):
    arguments = sys.argv[1:] if argv is None else argv
    if not arguments or arguments == ["help"]:
        arguments = ["--help"]
    args = parser().parse_args(arguments)
    root = Path(__file__).resolve().parents[2]
    try:
        data = inventory(root)
        if args.command == "counts":
            show_counts(data, args.output)
            return 0
        return process_documents(args, root, data["counts"])
    except (OSError, ValueError) as error:
        print(f"Inventory error: {error}", file=sys.stderr)
        return 1
