# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Check/update README claims and editable hero figures from the same inventory."""

import re

from readme_inventory import KEYS, LABELS, display_counts
from readme_inventory_svg import parse_svg

PATTERNS = {
    "main_agents": r"(?:main|primary|domain) agents",
    "subagents": r"sub[ -]?agents",
    "scripts": r"helper scripts",
    "slash_commands": r"slash[- ]commands",
}
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


def claim_errors(text, key, count, display):
    errors = []
    matches = list(claim_pattern(key).finditer(text))
    if not matches:
        errors.append(f"README is missing a {key} claim")
    for match in matches:
        number = match["number"].lstrip("~")
        expected = display if number.endswith("+") else f"{count:,}"
        if number.replace(",", "") != expected.replace(",", ""):
            errors.append(f"Stale claim: {match[0]} (expected {expected})")
    return errors


def summary_errors(text, counts):
    if SUMMARY_START not in text and SUMMARY_END not in text:
        return []
    if text.count(SUMMARY_START) != 1 or text.count(SUMMARY_END) != 1:
        return ["Inventory summary markers must occur exactly once"]
    if inventory_summary(counts) not in text:
        return ["Exact inventory summary is stale"]
    return []


def validate_readme(text, counts):
    errors = summary_errors(text, counts)
    for key, display in display_counts(counts).items():
        errors.extend(claim_errors(text, key, counts[key], display))
    return errors


def validate_svg(text, counts):
    elements = parse_svg(text)
    errors = []
    display = display_counts(counts)
    for key in KEYS:
        if elements.get(key) != [display[key]]:
            errors.append(f"Hero figure {key} must be {display[key]}")
    for tag, expected in (
        ("title", hero_title(counts)),
        ("desc", hero_description(counts)),
    ):
        if elements.get(tag) != [expected]:
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
    parse_svg(text)
    for key, value in display_counts(counts).items():
        text = replace_svg_text(text, "text", value, key)
    text = replace_svg_text(text, "title", hero_title(counts))
    return replace_svg_text(text, "desc", hero_description(counts))
