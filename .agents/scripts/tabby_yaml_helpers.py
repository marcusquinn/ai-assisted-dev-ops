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
from itertools import dropwhile, takewhile
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


def _parse_block_scalar(
    lines: list[str], start_idx: int, parent_indent: int, style: str
) -> tuple[str, int]:
    """Parse a folded or literal YAML block scalar."""
    continuation = list(
        takewhile(
            lambda line: (
                not line.strip() or len(line) - len(line.lstrip(" \t")) > parent_indent
            ),
            lines[start_idx:],
        )
    )
    content = dropwhile(lambda line: not line.strip(), continuation)
    collected = [
        line.lstrip(" \t").rstrip() for line in content if style == "|" or line.strip()
    ]
    separator = " " if style == ">" else "\n"
    return separator.join(collected).strip(), start_idx + len(continuation)


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
    document = yaml.safe_load(config_text) or {}
    profiles_value = document.get("profiles", []) if isinstance(document, dict) else []
    profiles = profiles_value if isinstance(profiles_value, list) else []
    options = (
        profile.get("options", {}) for profile in profiles if isinstance(profile, dict)
    )
    return {
        str(option["cwd"]).strip()
        for option in options
        if isinstance(option, dict) and option.get("cwd") is not None
    }


def _profiles_section_bounds(lines: list[str]) -> Optional[tuple[int, int]]:
    """Return the content bounds of the top-level profiles section."""
    start = next(
        (
            index + 1
            for index, line in enumerate(lines)
            if re.match(r"^profiles:\s*(?:\[\])?\s*(?:#.*)?$", line.rstrip("\r\n"))
        ),
        None,
    )
    if start is None:
        return None
    end = next(
        (
            index
            for index in range(start, len(lines))
            if lines[index].strip() and not lines[index][0].isspace()
        ),
        len(lines),
    )
    return start, end


def _profile_removal_end(lines: list[str], start: int, parse_end: int) -> int:
    """Exclude trailing blank lines and comments from a profile block."""
    removal_end = parse_end
    while removal_end > start + 1:
        trailing = lines[removal_end - 1].strip()
        if trailing and not trailing.startswith("#"):
            break
        removal_end -= 1
    return removal_end


def _parse_profile_block(
    lines: list[str], start: int, parse_end: int
) -> Optional[ProfileBlock]:
    """Parse one profile block while retaining its original line range."""
    document = yaml.safe_load("profiles:\n" + "".join(lines[start:parse_end]))
    profiles = document.get("profiles") if isinstance(document, dict) else None
    if not (
        isinstance(profiles, list)
        and len(profiles) == 1
        and isinstance(profiles[0], dict)
    ):
        return None
    return ProfileBlock(
        start, _profile_removal_end(lines, start, parse_end), profiles[0]
    )


def extract_profile_blocks(config_text: str) -> list[ProfileBlock]:
    """Return parseable top-level profile blocks with zero-based line ranges."""
    lines = config_text.splitlines(keepends=True)
    bounds = _profiles_section_bounds(lines)
    if bounds is None:
        return []
    profiles_start, profiles_end = bounds
    starts = [
        index
        for index in range(profiles_start, profiles_end)
        if re.match(r"^  -(?:\s|$)", lines[index])
    ]
    ends = starts[1:] + [profiles_end]
    blocks = (
        _parse_profile_block(lines, start, parse_end)
        for start, parse_end in zip(starts, ends)
    )
    return [block for block in blocks if block is not None]


def remove_profile_blocks(config_text: str, blocks: list[ProfileBlock]) -> str:
    """Remove selected profile blocks while preserving all unrelated text."""
    if not blocks:
        return config_text
    lines = config_text.splitlines(keepends=True)
    for block in sorted(blocks, key=lambda item: item.start, reverse=True):
        del lines[block.start : block.end]
    return "".join(lines)


def extract_group_id(config_text: str) -> Optional[str]:
    """Find the 'Projects' group ID, or return None."""
    document = yaml.safe_load(config_text) or {}
    groups = document.get("groups", []) if isinstance(document, dict) else []
    return next(
        (
            str(group["id"])
            for group in groups
            if isinstance(group, dict)
            and group.get("name") == "Projects"
            and group.get("id") is not None
        ),
        None,
    )


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
