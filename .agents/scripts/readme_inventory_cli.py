# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Check/update README claims and editable hero figures from the same inventory."""

import argparse
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from readme_inventory import KEYS, LABELS, display_counts, inventory, show_counts

PATTERNS = {
    "main_agents": r"(?:main|primary|domain) agents",
    "subagents": r"sub[ -]?agents",
    "scripts": r"helper scripts",
    "slash_commands": r"slash[- ]commands",
}
SVG_NS = {"svg": "http://www.w3.org/2000/svg"}
SUMMARY_START = "<!-- aidevops:inventory:start -->"
SUMMARY_END = "<!-- aidevops:inventory:end -->"


def claim_pattern(key):
    return re.compile(r"(?P<number>~?\d[\d,]*\+?) (?P<label>" + PATTERNS[key] + r")\b")


def inventory_summary(counts):
    values = [f"**{counts[key]:,} {label}**" for key, label in zip(KEYS, LABELS)]
    return (
        SUMMARY_START
        + "\nExact source inventory: "
        + ", ".join(values)
        + ".\n"
        + SUMMARY_END
    )


def hero_title(counts):
    display = display_counts(counts)
    return ", ".join(f"{display[key]} {label}" for key, label in zip(KEYS, LABELS))


def hero_description(counts):
    values = ", ".join(f"{counts[key]:,} {label}" for key, label in zip(KEYS, LABELS))
    return f"AI DevOps source inventory: {values}. See DESIGN.md for counting rules."


def validate_readme(text, counts):
    errors = []
    display = display_counts(counts)
    for key in KEYS:
        matches = list(claim_pattern(key).finditer(text))
        if not matches:
            errors.append(f"README is missing a {key} claim")
        for match in matches:
            number = match["number"].lstrip("~")
            expected = display[key] if number.endswith("+") else f"{counts[key]:,}"
            if number.replace(",", "") != expected.replace(",", ""):
                errors.append(f"Stale claim: {match[0]} (expected {expected})")
    if SUMMARY_START in text or SUMMARY_END in text:
        if text.count(SUMMARY_START) != 1 or text.count(SUMMARY_END) != 1:
            errors.append("Inventory summary markers must occur exactly once")
        elif inventory_summary(counts) not in text:
            errors.append("Exact inventory summary is stale")
    return errors


def validate_svg(text, counts):
    root = ET.fromstring(text)
    errors = []
    display = display_counts(counts)
    for key in KEYS:
        nodes = root.findall(f'.//svg:text[@data-count="{key}"]', SVG_NS)
        if len(nodes) != 1 or nodes[0].text != display[key]:
            errors.append(f"Hero figure {key} must be {display[key]}")
    for tag, expected in (
        ("title", hero_title(counts)),
        ("desc", hero_description(counts)),
    ):
        if root.findtext(f"svg:{tag}", namespaces=SVG_NS) != expected:
            errors.append(f"Hero {tag} is stale")
    return errors


def update_readme(text, counts):
    display = display_counts(counts)
    for key in KEYS:
        text = claim_pattern(key).sub(
            lambda match, key=key: display[key] + " " + match["label"], text
        )
    if SUMMARY_START not in text and SUMMARY_END not in text:
        return text
    if text.count(SUMMARY_START) != 1 or text.count(SUMMARY_END) != 1:
        raise ValueError("README needs exactly one inventory summary block")
    pattern = re.escape(SUMMARY_START) + r".*?" + re.escape(SUMMARY_END)
    return re.sub(
        pattern, lambda _match: inventory_summary(counts), text, flags=re.DOTALL
    )


def replace_svg_text(text, tag, value, key=None):
    """Preserve source formatting, comments, XML prefixes, and attribute quotes."""
    name = r"(?:[A-Za-z_][\w.-]*:)?" + tag
    attribute = (
        r"(?=[^>]*\bdata-count\s*=\s*(?:\"" + key + r"\"|'" + key + r"'))"
        if key
        else ""
    )
    pattern = (
        r"(?P<open><(?P<tag>"
        + name
        + r")\b"
        + attribute
        + r"[^>]*>)[^<]*(?P<close></(?P=tag)>)"
    )
    updated, replaced = re.subn(
        pattern, lambda match: match["open"] + value + match["close"], text
    )
    if replaced != 1:
        raise ValueError(f"Expected one hero element for {key or tag}")
    return updated


def update_svg(text, counts):
    ET.fromstring(text)
    for key, value in display_counts(counts).items():
        text = replace_svg_text(text, "text", value, key)
    text = replace_svg_text(text, "title", hero_title(counts))
    return replace_svg_text(text, "desc", hero_description(counts))


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    counts = commands.add_parser(
        "counts", help="Count tracked sources, excluding aliases and tests"
    )
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
                help="Write README and SVG; rerender PNG separately",
            )
    return result


def process_documents(args, root, counts):
    readme = args.file or root / "README.md"
    text = readme.read_text(encoding="utf-8")
    svg = root / "docs/assets/og-stats.svg" if args.file is None else None
    svg_text = svg.read_text(encoding="utf-8") if svg else None
    if args.command == "check":
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
    except (OSError, ValueError, subprocess.CalledProcessError, ET.ParseError) as error:
        print(f"Inventory error: {error}", file=sys.stderr)
        return 1
