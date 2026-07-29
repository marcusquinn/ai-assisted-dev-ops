#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Idempotently render a framework-managed block into a Markdown file."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


class ManagedBlockError(ValueError):
    """Raised when a template or target has unsafe marker structure."""


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise ManagedBlockError(f"{path} is not valid UTF-8") from exc


def _template_parts(template_path: Path) -> tuple[str, str, str]:
    if not template_path.is_file():
        raise ManagedBlockError(f"template not found: {template_path}")

    block = _read_text(template_path).strip()
    lines = block.splitlines()
    if len(lines) < 2:
        raise ManagedBlockError("template must contain start and end markers")

    start_marker = lines[0].strip()
    end_marker = lines[-1].strip()
    for marker, label in ((start_marker, "start"), (end_marker, "end")):
        if not marker.startswith("<!-- aidevops:") or not marker.endswith(" -->"):
            raise ManagedBlockError(
                f"template {label} marker must be an aidevops HTML comment"
            )
    if start_marker == end_marker:
        raise ManagedBlockError("template markers must be distinct")
    return block, start_marker, end_marker


def _join_markdown_sections(*sections: str) -> str:
    return "\n\n".join(filter(None, sections)) + "\n"


def _normalise_formatter_spacing(
    content: str, start_marker: str, end_marker: str
) -> str:
    """Ignore formatter-added blank lines immediately inside block markers."""
    content = re.sub(
        rf"{re.escape(start_marker)}\n(?:[ \t]*\n)+",
        f"{start_marker}\n",
        content,
    )
    return re.sub(
        rf"\n(?:[ \t]*\n)+{re.escape(end_marker)}",
        f"\n{end_marker}",
        content,
    )


def render_managed_markdown(
    current: str,
    block: str,
    start_marker: str,
    end_marker: str,
    default_heading: str,
) -> str:
    """Return current Markdown with exactly one canonical managed block."""
    start_count = current.count(start_marker)
    end_count = current.count(end_marker)
    if start_count != end_count or start_count > 1:
        raise ManagedBlockError(
            "target must contain either zero markers or one ordered marker pair"
        )

    if start_count == 1:
        start_index = current.index(start_marker)
        end_index = current.index(end_marker, start_index) + len(end_marker)
        prefix = current[:start_index].rstrip()
        suffix = current[end_index:].strip()
        return _join_markdown_sections(prefix, block, suffix)

    prefix = current.rstrip()
    if not prefix:
        prefix = default_heading.strip()
    return _join_markdown_sections(prefix, block)


def _render_target(file_path: Path, template_path: Path, default_heading: str) -> str:
    block, start_marker, end_marker = _template_parts(template_path)
    current = _read_text(file_path) if file_path.exists() else ""
    return render_managed_markdown(
        current, block, start_marker, end_marker, default_heading
    )


def _atomic_write(file_path: Path, content: str) -> None:
    file_path.parent.mkdir(parents=True, exist_ok=True)
    original_mode = (
        stat.S_IMODE(file_path.stat().st_mode) if file_path.exists() else 0o644
    )
    temp_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=file_path.parent,
            prefix=f".{file_path.name}.",
            delete=False,
        ) as temp_file:
            temp_file.write(content)
            temp_file.flush()
            temp_name = temp_file.name
        os.chmod(temp_name, original_mode)
        os.replace(temp_name, file_path)
    finally:
        if temp_name and os.path.exists(temp_name):
            os.unlink(temp_name)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Check or apply an aidevops-managed Markdown block"
    )
    parser.add_argument("command", choices=("check", "apply", "render"))
    parser.add_argument("--file", required=True, type=Path)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--default-heading", default="# Contributing")
    return parser


def _run_command(args: argparse.Namespace) -> int:
    rendered = _render_target(args.file, args.template, args.default_heading)
    current = _read_text(args.file) if args.file.exists() else ""
    _, start_marker, end_marker = _template_parts(args.template)
    is_current = current == rendered or _normalise_formatter_spacing(
        current, start_marker, end_marker
    ) == _normalise_formatter_spacing(rendered, start_marker, end_marker)

    if args.command == "render":
        sys.stdout.write(rendered)
    elif args.command == "check":
        return 0 if is_current else 1
    elif is_current:
        print("CURRENT")
    else:
        _atomic_write(args.file, rendered)
        print("UPDATED")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        return _run_command(args)
    except (ManagedBlockError, OSError) as exc:
        print(f"managed-markdown-block-helper: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
