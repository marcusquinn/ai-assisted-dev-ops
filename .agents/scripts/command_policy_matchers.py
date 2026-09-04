#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Static destructive-command matchers for command-policy-helper.py."""

from __future__ import annotations

import os
from pathlib import Path

from command_policy_git_matchers import (
    _git_parts,
    _has_flag,
    _matches_git,
    _short_flags,
)

__all__ = [
    "_canonical_operand",
    "_git_parts",
    "_has_flag",
    "_is_root_or_home_operand",
    "_is_temp_operand",
    "_matches",
    "_matches_gh_command_path",
    "_matches_gh_pr_merge",
    "_matches_git",
    "_matches_rm",
    "_rm_operands",
    "_short_flags",
]


def _matches_gh_command_path(argv: list[str], command_paths: list[list[str]]) -> bool:
    return (
        len(argv) >= 3
        and os.path.basename(argv[0]) == "gh"
        and argv[1:3] in command_paths
    )


def _without_gh_repo_options(args: list[str]) -> list[str]:
    """Remove global repository options while retaining command arguments."""
    positional: list[str] = []
    skip_value = False
    for arg in args:
        if skip_value:
            skip_value = False
        elif arg in {"-R", "--repo"}:
            skip_value = True
        elif not (arg.startswith("--repo=") or arg.startswith("-R")):
            positional.append(arg)
    return positional


def _gh_pr_merge_remainder(argv: list[str]) -> list[str] | None:
    if not argv or os.path.basename(argv[0]) != "gh":
        return None
    args = _without_gh_repo_options(argv[1:])
    return args[2:] if args[:2] == ["pr", "merge"] else None


def _matches_gh_pr_merge(argv: list[str]) -> bool:
    remainder = _gh_pr_merge_remainder(argv)
    return remainder is not None and not any(
        arg in {"--help", "-h"} for arg in argv[1:]
    )


def _matches_gh_pr_disable_auto(argv: list[str]) -> bool:
    return _matches_gh_pr_merge(argv) and any(
        arg == "--disable-auto" or arg.startswith("--disable-auto=") for arg in argv
    )


def _rm_operands(args: list[str]) -> list[str]:
    separator = next(
        (index for index, arg in enumerate(args) if arg == "--"), len(args)
    )
    return [arg for arg in args[:separator] if not arg.startswith("-")] + args[
        separator + 1 :
    ]


def _canonical_operand(path: str, cwd: str) -> str | None:
    if not path or "\x00" in path or any(part == ".." for part in Path(path).parts):
        return None
    if path.startswith(("$", "~")):
        return None
    candidate = path if os.path.isabs(path) else os.path.join(cwd, path)
    return os.path.realpath(os.path.normpath(candidate))


def _is_temp_operand(path: str, cwd: str) -> bool:
    canonical = _canonical_operand(path, cwd)
    if not canonical:
        return False
    # Classification roots only; no temporary file is created.
    roots = ["/tmp", "/var/tmp"]  # nosec B108
    tmpdir = os.environ.get("TMPDIR", "")
    if tmpdir:
        roots.append(tmpdir)
    return any(_is_path_below(canonical, root) for root in roots)


def _is_path_below(path: str, root: str) -> bool:
    canonical_root = os.path.realpath(os.path.normpath(root))
    try:
        return (
            os.path.commonpath([path, canonical_root]) == canonical_root
            and path != canonical_root
        )
    except ValueError:
        return False


def _is_root_or_home_operand(path: str, cwd: str) -> bool:
    canonical = _canonical_operand(path, cwd)
    if not canonical:
        return path in {"/", "~", "$HOME", "${HOME}"}
    home = os.path.realpath(str(Path.home()))
    return canonical == "/" or canonical == home or canonical.startswith(home + os.sep)


def _matches(matcher: str, argv: list[str], cwd: str) -> bool:
    if matcher in {"rm_recursive_force_root", "rm_recursive_force"}:
        return _matches_rm(matcher, argv, cwd)
    if matcher == "gh_pr_disable_auto_direct":
        return _matches_gh_pr_disable_auto(argv)
    if matcher == "gh_pr_merge_direct":
        return _matches_gh_pr_merge(argv)
    subcommand, git_args = _git_parts(argv)
    if not subcommand:
        return False
    return _matches_git(matcher, subcommand, git_args)


def _matches_rm(matcher: str, argv: list[str], cwd: str) -> bool:
    executable = os.path.basename(argv[0]) if argv else ""
    args = argv[1:]
    if not _is_recursive_force_rm(executable, args):
        return False
    operands = _rm_operands(args)
    if not operands or all(_is_temp_operand(path, cwd) for path in operands):
        return False
    is_root = any(_is_root_or_home_operand(path, cwd) for path in operands)
    return is_root if matcher == "rm_recursive_force_root" else not is_root


def _is_recursive_force_rm(executable: str, args: list[str]) -> bool:
    return (
        executable == "rm"
        and _has_flag(args, "r", "--recursive")
        and _has_flag(args, "f", "--force")
    )
