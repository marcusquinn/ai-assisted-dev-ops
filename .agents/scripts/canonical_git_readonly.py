#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Argument-aware read-only checks for canonical Git operations."""

from __future__ import annotations

from typing import Callable

from canonical_git_ref_queries import REF_QUERY_CHECKS


def _branch_is_read_only(args: list[str]) -> bool:
    if not args:
        return True
    mutating = {
        "-d",
        "-D",
        "-m",
        "-M",
        "-c",
        "-C",
        "-f",
        "--delete",
        "--move",
        "--copy",
        "--force",
        "--edit-description",
        "--set-upstream-to",
        "--unset-upstream",
    }
    if any(
        arg in mutating or arg.startswith(("--move=", "--copy=", "--set-upstream-to="))
        for arg in args
    ):
        return False
    listing = any(
        arg in {"--list", "--contains", "--merged", "--no-merged", "--points-at"}
        or arg.startswith(("--contains=", "--merged=", "--no-merged=", "--points-at="))
        for arg in args
    )
    return listing or all(arg.startswith("-") or arg in {"HEAD", "@"} for arg in args)


def _config_is_read_only(args: list[str]) -> bool:
    read_flags = {
        "--get",
        "--get-all",
        "--get-regexp",
        "--get-urlmatch",
        "--list",
        "-l",
        "--show-origin",
        "--show-scope",
        "--name-only",
        "--includes",
        "--null",
        "-z",
    }
    write_flags = {
        "--add",
        "--unset",
        "--unset-all",
        "--rename-section",
        "--remove-section",
        "--replace-all",
    }
    return (
        bool(args)
        and any(arg in read_flags for arg in args)
        and not any(arg in write_flags for arg in args)
    )


def _clean_is_read_only(args: list[str]) -> bool:
    return any(
        arg == "--dry-run"
        or (arg.startswith("-") and not arg.startswith("--") and "n" in arg[1:])
        for arg in args
    )


def _bundle_is_read_only(args: list[str]) -> bool:
    if not args or args[0] != "verify":
        return False
    bundle_args = args[1:]
    if not bundle_args:
        return False
    allowed_flags = {"-q", "--quiet"}
    paths = [arg for arg in bundle_args if arg not in allowed_flags]
    return len(paths) == 1 and not paths[0].startswith("-")


CANONICAL_CHECKS: dict[str, Callable[[list[str]], bool]] = {
    "branch": _branch_is_read_only,
    "bundle": _bundle_is_read_only,
    "config": _config_is_read_only,
    "clean": _clean_is_read_only,
    **REF_QUERY_CHECKS,
}
