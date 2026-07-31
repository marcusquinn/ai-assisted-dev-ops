#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate Tabby profile argument types before PTY launch."""

from __future__ import annotations

import re
import sys
from typing import NamedTuple

from tabby_profile_utils import (
    _block_end,
    _line_indent_len,
    _normalise_yaml_scalar,
    _profile_block_end,
)


class ProfileArgTypeIssue(NamedTuple):
    """A non-string value persisted in a Tabby profile's ``options.args``."""

    profile_name: str
    line_number: int
    value: str


def _is_non_string_yaml_list_item(value: str) -> bool:
    """Return True when a simple YAML list item is not a string scalar."""
    value = value.strip()
    if not value or value.startswith(("{", "[")):
        return True
    if re.fullmatch(r"'(?:[^']|'')*'", value) or re.fullmatch(
        r'"(?:[^"\\]|\\.)*"', value
    ):
        return False
    if re.search(r":(?:\s|$)", value):
        return True
    if value.lower() in {"null", "true", "false", "~"}:
        return True
    return bool(re.fullmatch(r"[-+]?(?:\d[\d_]*)(?:\.\d[\d_]*)?", value))


def _find_block_arg_type_issues(
    lines: list[str],
    start: int,
    end: int,
    expected_indent: int,
    profile_name: str,
) -> list[ProfileArgTypeIssue]:
    """Find non-string list entries in one block-style ``args`` value."""
    issues: list[ProfileArgTypeIssue] = []
    for line_index in range(start, end):
        line = lines[line_index]
        if _line_indent_len(line) != expected_indent:
            continue
        item_match = re.match(r"^\s*-\s*(?P<value>.*)$", line)
        if not item_match:
            continue
        value = item_match.group("value").strip()
        if not _is_non_string_yaml_list_item(value):
            continue
        issues.append(ProfileArgTypeIssue(profile_name, line_index + 1, value))
    return issues


def _find_profile_arg_type_issues(
    lines: list[str], profile_start: int, profile_end: int, profile_name: str
) -> list[ProfileArgTypeIssue]:
    """Find invalid ``args`` entries inside one Tabby profile block."""
    issues: list[ProfileArgTypeIssue] = []
    index = profile_start + 1
    while index < profile_end:
        args_match = re.match(r"^(?P<indent>\s*)args:\s*(?P<value>.*)$", lines[index])
        if not args_match:
            index += 1
            continue

        inline_value = args_match.group("value").strip()
        if inline_value and "{" in inline_value:
            issues.append(ProfileArgTypeIssue(profile_name, index + 1, inline_value))
            index += 1
            continue

        args_indent_len = len(args_match.group("indent"))
        args_end = _block_end(lines, index, args_indent_len)
        issues.extend(
            _find_block_arg_type_issues(
                lines,
                index + 1,
                args_end,
                args_indent_len + 2,
                profile_name,
            )
        )
        index = args_end
    return issues


def find_profile_arg_type_issues(config_text: str) -> list[ProfileArgTypeIssue]:
    """Find profile args that Tabby cannot pass to its PTY as ``string[]``."""
    lines = config_text.split("\n")
    issues: list[ProfileArgTypeIssue] = []
    index = 0
    while index < len(lines):
        profile_match = re.match(r"^  - name:\s*(?P<name>.+?)\s*$", lines[index])
        if not profile_match:
            index += 1
            continue

        profile_name = _normalise_yaml_scalar(profile_match.group("name"))
        profile_end = _profile_block_end(lines, index)
        issues.extend(
            _find_profile_arg_type_issues(
                lines, index, profile_end, profile_name
            )
        )
        index = profile_end
    return issues


def report_profile_arg_type_issues(config_text: str) -> bool:
    """Print actionable profile-schema errors and return whether any exist."""
    issues = find_profile_arg_type_issues(config_text)
    if not issues:
        return False

    locations: dict[str, list[int]] = {}
    for issue in issues:
        locations.setdefault(issue.profile_name, []).append(issue.line_number)

    print(
        "Invalid Tabby profile configuration: options.args must contain only strings.",
        file=sys.stderr,
    )
    for profile_name, line_numbers in locations.items():
        lines_text = ", ".join(str(line_number) for line_number in line_numbers)
        print(
            f"  - {profile_name}: non-string argument at line(s) {lines_text}",
            file=sys.stderr,
        )
    print(
        "Do not launch the listed profiles. In Tabby's command-line field, paste "
        "the full quoted /bin/zsh -l -c '<command>' invocation so shell operators "
        "remain inside one string argument.",
        file=sys.stderr,
    )
    return True
