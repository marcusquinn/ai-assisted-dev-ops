#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
YAML parsing and insertion helpers for tabby-profile-sync.py.

Extracted from tabby-profile-sync.py to reduce file complexity.
Handles Tabby config.yaml reading, existing profile detection,
and new profile/group insertion.
"""

from __future__ import annotations

import os
import re
import tempfile
from typing import NamedTuple, Optional

import yaml


class ProfileBlock(NamedTuple):
    """One top-level Tabby profile and its line range."""

    start: int
    end: int
    data: dict


def load_yaml_simple(path: str) -> str:
    """Load and validate a Tabby YAML document as text."""
    with open(path, "r") as f:
        content = f.read()
    validate_yaml_document(content)
    return content


def save_yaml(path: str, content: str) -> None:
    """Validate and atomically replace a Tabby YAML document."""
    validate_yaml_document(content)
    destination = os.path.abspath(path)
    directory = os.path.dirname(destination)
    mode = os.stat(destination).st_mode & 0o777
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{os.path.basename(destination)}.", dir=directory, text=True
    )
    try:
        with os.fdopen(descriptor, "w") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def validate_yaml_document(content: str) -> None:
    """Require a mapping document with list-valued Tabby sections."""
    document = yaml.safe_load(content)
    if not isinstance(document, dict):
        raise ValueError("Tabby config must be a YAML mapping")
    for key in ("profiles", "groups"):
        value = document.get(key)
        if value is not None and not isinstance(value, list):
            raise ValueError(f"Tabby config '{key}' must be a list")


_CWD_LINE_RE = re.compile(r"^(?P<indent>\s+)cwd:\s*(?P<value>.*)$")


def _parse_block_scalar(
    lines: list[str], start_idx: int, parent_indent: int, style: str
) -> tuple[str, int]:
    """Parse a YAML block scalar (folded ``>`` or literal ``|``).

    Starts at the line AFTER the ``cwd: >-`` (or ``|-``, ``>``, ``|``) header.
    Consumes indented continuation lines until a line dedents back to or below
    ``parent_indent``.

    Returns ``(joined_value, next_line_idx)``.

    - Folded (``>``): continuation lines are joined with single spaces.
    - Literal (``|``): continuation lines are joined with newlines.

    Chomping indicators (``-`` strip, ``+`` keep) affect trailing newlines,
    but since we only use the value as a path we strip whitespace regardless.
    """
    collected: list[str] = []
    i = start_idx
    while i < len(lines):
        line = lines[i]
        # Blank lines are part of the block; preserve only for literal style.
        if not line.strip():
            if style == "|" and collected:
                collected.append("")
            i += 1
            continue
        # Measure the leading whitespace of this line.
        stripped = line.lstrip(" \t")
        line_indent = len(line) - len(stripped)
        if line_indent <= parent_indent:
            break
        collected.append(stripped.rstrip())
        i += 1

    if style == ">":
        value = " ".join(collected)
    else:
        value = "\n".join(collected)
    return value.strip(), i


def extract_existing_cwds(config_text: str) -> set[str]:
    """Extract all cwd paths from existing profiles.

    Handles three YAML scalar forms that Tabby emits:

    1. Inline plain or quoted: ``cwd: /path`` / ``cwd: '/path'``.
    2. Folded block scalar: ``cwd: >-`` followed by an indented path on the
       next line. Tabby rewrites long paths into this form whenever it
       re-saves the config via its GUI.
    3. Literal block scalar: ``cwd: |-`` followed by an indented path.

    Missing any of (2) or (3) causes duplicate profile generation on every
    sync because the dedup check fails to recognise the existing path.
    """
    cwds: set[str] = set()
    lines = config_text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        match = _CWD_LINE_RE.match(line)
        if not match:
            i += 1
            continue

        parent_indent = len(match.group("indent"))
        value = match.group("value").strip()

        # Block scalar header? ``>``, ``>-``, ``>+``, ``|``, ``|-``, ``|+``.
        if value and value[0] in (">", "|"):
            style = value[0]
            folded_value, next_i = _parse_block_scalar(
                lines, i + 1, parent_indent, style
            )
            if folded_value:
                cwds.add(folded_value)
            i = next_i
            continue

        # Inline form (plain or quoted). Empty value means malformed — skip.
        if value:
            cwds.add(value.strip("'\""))
        i += 1

    return cwds


def extract_profile_blocks(config_text: str) -> list[ProfileBlock]:
    """Return parseable top-level profile blocks with zero-based line ranges."""
    lines = config_text.splitlines(keepends=True)
    profiles_start: Optional[int] = None
    profiles_end = len(lines)
    for index, line in enumerate(lines):
        if profiles_start is None:
            if re.match(r"^profiles:\s*(?:\[\])?\s*(?:#.*)?$", line.rstrip("\r\n")):
                profiles_start = index + 1
            continue
        if line.strip() and not line[0].isspace():
            profiles_end = index
            break

    if profiles_start is None:
        return []

    starts = [
        index
        for index in range(profiles_start, profiles_end)
        if re.match(r"^  -(?:\s|$)", lines[index])
    ]
    blocks: list[ProfileBlock] = []
    for position, start in enumerate(starts):
        parse_end = starts[position + 1] if position + 1 < len(starts) else profiles_end
        document = yaml.safe_load("profiles:\n" + "".join(lines[start:parse_end]))
        profiles = document.get("profiles") if isinstance(document, dict) else None
        if (
            isinstance(profiles, list)
            and len(profiles) == 1
            and isinstance(profiles[0], dict)
        ):
            removal_end = parse_end
            while removal_end > start + 1:
                trailing = lines[removal_end - 1].strip()
                if trailing and not trailing.startswith("#"):
                    break
                removal_end -= 1
            blocks.append(ProfileBlock(start, removal_end, profiles[0]))
    return blocks


def remove_profile_blocks(config_text: str, blocks: list[ProfileBlock]) -> str:
    """Remove selected profile blocks while preserving all unrelated text."""
    if not blocks:
        return config_text
    lines = config_text.splitlines(keepends=True)
    for block in sorted(blocks, key=lambda item: item.start, reverse=True):
        del lines[block.start:block.end]
    return "".join(lines)


def extract_group_id(config_text: str) -> Optional[str]:
    """Find the 'Projects' group ID, or return None."""
    # Look for groups section — capture all indented content after "groups:"
    groups_match = re.search(
        r"^groups:\s*\n((?:[ \t]+.*\n)*)", config_text, re.MULTILINE
    )
    if not groups_match:
        return None

    # Parse group entries by accumulating blocks (each starts with "  - ")
    group_block = groups_match.group(1)
    blocks: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in group_block.split("\n"):
        if not line.strip():
            continue
        # New group entry starts with "  - " (list item)
        if re.match(r"\s+-\s+", line):
            if current:
                blocks.append(current)
            current = {}
            # The first field may be on the same line as "-"
            line = re.sub(r"^\s+-\s+", "  ", line)
        # Extract key: value pairs
        kv_match = re.match(r"\s+(\w+):\s+(.+)", line)
        if kv_match:
            current[kv_match.group(1)] = kv_match.group(2).strip().strip("'\"")
    if current:
        blocks.append(current)

    # Find the "Projects" group
    for block in blocks:
        if block.get("name") == "Projects" and "id" in block:
            return block["id"]
    return None


def find_profiles_insert_line(lines: list[str]) -> tuple[bool, Optional[int]]:
    """Find where to insert new profiles in the YAML lines.

    Returns (has_profiles_key, insert_line).
    """
    has_profiles_key = False
    in_profiles = False
    insert_line = None
    for i, line in enumerate(lines):
        if re.match(r"^profiles:", line):
            has_profiles_key = True
            in_profiles = True
            continue
        if in_profiles and re.match(r"^[a-zA-Z]", line):
            insert_line = i
            break
    return has_profiles_key, insert_line


def find_version_insert_at(lines: list[str]) -> int:
    """Find the line index after the version: line, or 0 if not found."""
    for i, line in enumerate(lines):
        if re.match(r"^version:", line):
            return i + 1
    return 0


def insert_profiles_block(config_text: str, new_block: str) -> str:
    """Insert new_block into the profiles section of config_text."""
    lines = config_text.split("\n")
    for i, line in enumerate(lines):
        inline_empty = re.match(r"^(profiles:)\s*\[\]\s*(#.*)?$", line)
        if inline_empty:
            comment = inline_empty.group(2)
            lines[i] = f"profiles:{f' {comment}' if comment else ''}"
            break
        if re.match(r"^profiles:\s*\S", line):
            raise ValueError("Unsupported inline profiles value")
    has_profiles_key, insert_line = find_profiles_insert_line(lines)

    if not has_profiles_key:
        insert_at = find_version_insert_at(lines)
        lines.insert(insert_at, f"profiles:\n{new_block}")
    else:
        if insert_line is None:
            insert_line = len(lines)
        lines.insert(insert_line, new_block)

    return "\n".join(lines)
