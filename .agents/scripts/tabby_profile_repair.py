#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Repair aidevops-managed Tabby OpenCode profiles."""

from __future__ import annotations

import re

from tabby_profile_repair_engine import (
    _repair_broken_opencode_launch_profile_block,
)
from tabby_profile_utils import (
    _profile_block_end,
    _profile_mentions_opencode_launch,
)
from tabby_shell_resolver import resolve_login_shell


def _enable_dynamic_title(profile_text: str) -> tuple[str, bool]:
    """Allow OSC title updates for one aidevops-managed OpenCode profile."""
    lines = profile_text.split("\n")
    for index, line in enumerate(lines):
        if re.match(r"^    disableDynamicTitle:\s*", line):
            replacement = "    disableDynamicTitle: false"
            if line == replacement:
                return profile_text, False
            lines[index] = replacement
            return "\n".join(lines), True

    insert_at = len(lines)
    for index, line in enumerate(lines):
        if re.match(r"^    type:\s*", line):
            insert_at = index
            break
    lines.insert(insert_at, "    disableDynamicTitle: false")
    return "\n".join(lines), True


def repair_broken_opencode_launch_profiles(
    config_text: str, shell_path: str | None = None
) -> tuple[str, int]:
    """Repair fragile OpenCode profiles without touching custom profiles."""
    shell_path = shell_path or resolve_login_shell()
    lines = config_text.split("\n")
    repaired: list[str] = []
    repairs = 0
    index = 0

    while index < len(lines):
        line = lines[index]
        if not line.startswith("  - name:"):
            repaired.append(line)
            index += 1
            continue

        block_end = _profile_block_end(lines, index)
        profile_lines = lines[index:block_end]
        if not _profile_mentions_opencode_launch(profile_lines):
            repaired.extend(profile_lines)
            index = block_end
            continue

        original_block = "\n".join(profile_lines)
        repaired_block, repaired_count = _repair_broken_opencode_launch_profile_block(
            original_block, shell_path
        )
        repaired_block, dynamic_title_changed = _enable_dynamic_title(repaired_block)
        repaired.extend(repaired_block.split("\n"))
        if repaired_count > 0 or dynamic_title_changed:
            repairs += 1
        index = block_end

    return "\n".join(repaired), repairs
