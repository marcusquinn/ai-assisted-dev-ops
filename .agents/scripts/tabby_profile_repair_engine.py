#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Low-level repair engine for one Tabby OpenCode profile block."""

from __future__ import annotations

import re

from tabby_profile_utils import (
    _block_end,
    _direct_opencode_args_block,
    _has_prior_option_key,
    _is_broken_opencode_args,
    _is_command_field_opencode,
    _is_legacy_direct_opencode_args,
    _line_indent_len,
    _line_is_option_key,
    _next_option_line,
    _option_key_match,
    _parse_block_args,
    _parse_inline_args,
    _tabby_autorun_env_end,
)


class _ProfileRepairContext:
    """Mutable state for repairing one Tabby profile block."""

    def __init__(self, lines: list[str]) -> None:
        self.lines = lines
        self.repaired: list[str] = []
        self.repairs = 0
        self.pending_command_field_indent: str | None = None
        self.index = 0


def _append_direct_args(
    context: _ProfileRepairContext,
    indent: str,
    next_line: str,
    count_repair: bool,
) -> None:
    """Append canonical OpenCode args without duplicating an env key."""
    include_env = not _line_is_option_key(
        next_line, indent, "env"
    ) and not _has_prior_option_key(context.repaired, indent, "env")
    context.repaired.extend(
        _direct_opencode_args_block(indent, include_env=include_env)
    )
    if count_repair:
        context.repairs += 1


def _repair_command_field(context: _ProfileRepairContext, line: str) -> bool:
    """Replace one legacy command-field launch and advance the context."""
    match = re.match(r"^(?P<indent>\s*)command:\s*(?P<value>.*)$", line)
    if not match or not _is_command_field_opencode(match.group("value")):
        return False

    indent = match.group("indent")
    if _has_prior_option_key(context.repaired, indent, "command"):
        context.index = _block_end(context.lines, context.index, len(indent))
    else:
        context.repaired.append(f"{indent}command: /bin/zsh")
        context.pending_command_field_indent = indent
        context.index += 1
    context.repairs += 1
    return True


def _skip_duplicate_option(context: _ProfileRepairContext, line: str) -> bool:
    """Skip a duplicate managed option key and advance the context."""
    option_key = _option_key_match(line)
    if option_key is None:
        return False

    indent, key = option_key
    if key == "args" and context.pending_command_field_indent == indent:
        return False
    if not _has_prior_option_key(context.repaired, indent, key):
        return False

    context.index = _block_end(context.lines, context.index, len(indent))
    context.repairs += 1
    return True


def _flush_pending_command_args(context: _ProfileRepairContext, line: str) -> None:
    """Insert missing args before leaving a repaired command's options block."""
    indent = context.pending_command_field_indent
    if indent is None or not line.strip():
        return
    if _line_indent_len(line) > len(indent) or _line_is_option_key(
        line, indent, "args"
    ):
        return

    _append_direct_args(context, indent, line, count_repair=False)
    context.pending_command_field_indent = None


def _repair_inline_args(
    context: _ProfileRepairContext,
    indent: str,
    indent_len: int,
    args: list[str],
) -> None:
    """Repair an inline args value and advance the context."""
    next_line = _next_option_line(context.lines, context.index + 1)
    if context.pending_command_field_indent == indent:
        _append_direct_args(context, indent, next_line, count_repair=False)
        context.pending_command_field_indent = None
    elif _is_broken_opencode_args(args) or _is_legacy_direct_opencode_args(args):
        _append_direct_args(context, indent, next_line, count_repair=True)
    elif args == ["-l", "-i"]:
        env_end = _tabby_autorun_env_end(
            context.lines, context.index + 1, indent_len
        )
        if env_end is not None:
            _append_direct_args(context, indent, "", count_repair=True)
            context.index = env_end
            return
        context.repaired.append(context.lines[context.index])
    else:
        context.repaired.append(context.lines[context.index])
    context.index += 1


def _repair_block_args(
    context: _ProfileRepairContext,
    indent: str,
    indent_len: int,
    block_end: int,
    args: list[str],
) -> None:
    """Repair a block-style args value and advance the context."""
    next_line = _next_option_line(context.lines, block_end)
    if context.pending_command_field_indent == indent:
        _append_direct_args(context, indent, next_line, count_repair=False)
        context.pending_command_field_indent = None
    elif _is_broken_opencode_args(args) or _is_legacy_direct_opencode_args(args):
        _append_direct_args(context, indent, next_line, count_repair=True)
    elif args == ["-l", "-i"]:
        env_end = _tabby_autorun_env_end(context.lines, block_end, indent_len)
        if env_end is not None:
            _append_direct_args(context, indent, "", count_repair=True)
            context.index = env_end
            return
        context.repaired.extend(context.lines[context.index:block_end])
    else:
        context.repaired.extend(context.lines[context.index:block_end])
    context.index = block_end


def _repair_broken_opencode_launch_profile_block(config_text: str) -> tuple[str, int]:
    """Repair fragile Tabby OpenCode launch profiles inside one profile block."""
    context = _ProfileRepairContext(config_text.split("\n"))
    while context.index < len(context.lines):
        line = context.lines[context.index]
        if _repair_command_field(context, line):
            continue
        if _skip_duplicate_option(context, line):
            continue

        _flush_pending_command_args(context, line)
        match = re.match(r"^(?P<indent>\s*)args:\s*(?P<value>.*)$", line)
        if not match:
            context.repaired.append(line)
            context.index += 1
            continue

        indent = match.group("indent")
        indent_len = len(indent)
        inline_args = _parse_inline_args(match.group("value"))
        if inline_args is not None:
            _repair_inline_args(context, indent, indent_len, inline_args)
            continue

        block_end = _block_end(context.lines, context.index, indent_len)
        block_args = _parse_block_args(context.lines[context.index + 1 : block_end])
        _repair_block_args(context, indent, indent_len, block_end, block_args)

    if context.pending_command_field_indent is not None:
        _append_direct_args(
            context,
            context.pending_command_field_indent,
            "",
            count_repair=False,
        )
    return "\n".join(context.repaired), context.repairs
