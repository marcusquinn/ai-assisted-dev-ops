#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""YAML utilities shared by Tabby profile validation and repair."""

from __future__ import annotations

import re


TABBY_OPENCODE_LAUNCH = "exec aidevops opencode --tabby-shell"
TABBY_COMMAND_FIELD_OPENCODE = f"/bin/zsh -l -c '{TABBY_OPENCODE_LAUNCH}'"
PRE_RECOVERY_TABBY_OPENCODE_LAUNCH = "aidevops opencode; exec zsh"
PRE_RECOVERY_TABBY_COMMAND_FIELD_OPENCODE = (
    f"/bin/zsh -l -c '{PRE_RECOVERY_TABBY_OPENCODE_LAUNCH}'"
)
LEGACY_TABBY_OPENCODE_LAUNCH = "opencode; exec zsh"
LEGACY_TABBY_COMMAND_FIELD_OPENCODE = "/bin/zsh -l -c 'opencode; exec zsh'"


def _normalise_yaml_scalar(value: str) -> str:
    """Return a plain scalar value from a simple YAML string/list item."""
    in_single_quote = False
    in_double_quote = False
    comment_start = len(value)
    for index, char in enumerate(value):
        if char == "'" and not in_double_quote:
            in_single_quote = not in_single_quote
        elif char == '"' and not in_single_quote:
            in_double_quote = not in_double_quote
        elif char == "#" and not in_single_quote and not in_double_quote:
            comment_start = index
            break
    value = value[:comment_start].strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    return value


def _next_option_line(lines: list[str], start: int) -> str:
    """Return the next non-comment line from ``start`` or an empty string."""
    while start < len(lines):
        line = lines[start]
        if line.strip() and not line.lstrip().startswith("#"):
            return line
        start += 1
    return ""


def _parse_inline_args(value: str) -> list[str] | None:
    """Parse a simple inline YAML list such as ``['-l', '-i']``."""
    value = value.strip()
    if not (value.startswith("[") and value.endswith("]")):
        return None
    inner = value[1:-1].strip()
    if not inner:
        return []
    return [_normalise_yaml_scalar(part) for part in inner.split(",")]


def _parse_block_args(lines: list[str]) -> list[str]:
    """Parse simple ``- value`` YAML list entries from an args block."""
    args: list[str] = []
    for line in lines:
        match = re.match(r"^\s*-\s*(.+?)\s*$", line)
        if match:
            args.append(_normalise_yaml_scalar(match.group(1)))
    return args


def _is_broken_opencode_args(args: list[str]) -> bool:
    """Return True for the Tabby launch shape that breaks zsh job control."""
    return args == ["-l", "-i", "-c", "opencode"]


def _is_command_field_opencode(value: str) -> bool:
    """Return True for the Tabby command-field shape that Tabby cannot exec."""
    value = value.strip()
    normalised = _normalise_yaml_scalar(value)
    opencode_commands = (
        TABBY_COMMAND_FIELD_OPENCODE,
        PRE_RECOVERY_TABBY_COMMAND_FIELD_OPENCODE,
        LEGACY_TABBY_COMMAND_FIELD_OPENCODE,
    )
    return value in opencode_commands or normalised in opencode_commands


def _is_legacy_direct_opencode_args(args: list[str]) -> bool:
    """Return True for direct OpenCode args that still use the shared DB."""
    return args in (
        ["-l", "-c", PRE_RECOVERY_TABBY_OPENCODE_LAUNCH],
        ["-l", "-c", LEGACY_TABBY_OPENCODE_LAUNCH],
    )


def _direct_opencode_args_block(args_indent: str, include_env: bool) -> list[str]:
    """Build the direct Tabby args/env block for OpenCode profiles."""
    child_indent = f"{args_indent}  "
    block = [
        f"{args_indent}args:",
        f"{child_indent}- '-l'",
        f"{child_indent}- '-c'",
        f"{child_indent}- '{TABBY_OPENCODE_LAUNCH}'",
    ]
    if include_env:
        block.append(f"{args_indent}env: {{}}")
    return block


def _line_indent_len(line: str) -> int:
    """Return the number of leading spaces in ``line``."""
    return len(line) - len(line.lstrip(" "))


def _option_key_match(line: str) -> tuple[str, str] | None:
    """Return ``(indent, key)`` for option-level keys we manage."""
    match = re.match(r"^(?P<indent>\s*)(?P<key>args|command|env):(?:\s|$)", line)
    if not match:
        return None
    return match.group("indent"), match.group("key")


def _line_is_option_key(line: str, indent: str, key: str) -> bool:
    """Return True if ``line`` is ``key`` at ``indent``."""
    return bool(re.match(rf"^{re.escape(indent)}{re.escape(key)}:(?:\s|$)", line))


def _has_prior_option_key(repaired: list[str], indent: str, key: str) -> bool:
    """Return True if ``key`` already appeared in the current options block."""
    indent_len = len(indent)
    for previous in reversed(repaired):
        if previous.strip() == "options:":
            return False
        if previous.strip() and _line_indent_len(previous) < indent_len:
            return False
        if _line_is_option_key(previous, indent, key):
            return True
    return False


def _block_end(lines: list[str], start: int, base_indent_len: int) -> int:
    """Return the first line after the scalar/list/mapping block at ``start``."""
    block_end = start + 1
    while block_end < len(lines):
        next_line = lines[block_end]
        if next_line.strip() and _line_indent_len(next_line) <= base_indent_len:
            break
        block_end += 1
    return block_end


def _tabby_autorun_env_end(
    lines: list[str], start: int, base_indent_len: int
) -> int | None:
    """Return env block end if it only carries ``TABBY_AUTORUN=opencode``."""
    if start >= len(lines):
        return None
    env_line = lines[start]
    env_indent_len = len(env_line) - len(env_line.lstrip(" "))
    if env_indent_len != base_indent_len or env_line.strip() != "env:":
        return None

    block_end = start + 1
    has_autorun = False
    has_other_env = False
    while block_end < len(lines):
        next_line = lines[block_end]
        if next_line.strip():
            next_indent_len = len(next_line) - len(next_line.lstrip(" "))
            if next_indent_len <= env_indent_len:
                break
            stripped = next_line.strip().strip("'").strip('"')
            if stripped == "TABBY_AUTORUN: opencode":
                has_autorun = True
            else:
                has_other_env = True
        block_end += 1

    if has_autorun and not has_other_env:
        return block_end
    return None


def _line_mentions_opencode_launch(line: str) -> bool:
    """Return True when a non-comment YAML line mentions an OpenCode launch."""
    stripped = line.strip()
    return bool(stripped and not stripped.startswith("#") and "opencode" in stripped)


def _profile_mentions_opencode_launch(profile_lines: list[str]) -> bool:
    """Return True when a profile block clearly targets OpenCode."""
    return any(_line_mentions_opencode_launch(line) for line in profile_lines)


def _profile_block_end(lines: list[str], start: int) -> int:
    """Return the first line after the Tabby profile block at ``start``."""
    return _block_end(lines, start, 2)
