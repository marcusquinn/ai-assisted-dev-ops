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
    return _config_is_allowed_global_auth_write(args) or (
        bool(args)
        and any(arg in read_flags for arg in args)
        and not any(arg in write_flags for arg in args)
    )


def _config_is_allowed_global_auth_write(args: list[str]) -> bool:
    """Allow GitHub CLI auth setup to update user-scoped credential config.

    The canonical guard protects repository worktrees. A `gh auth refresh` or
    `gh auth setup-git` may run while the shell happens to be inside a canonical
    checkout, but its intended mutation is `~/.gitconfig`, not the repository.
    Keep this narrow: only explicit user-scope writes to credential helper keys
    are allowed; repo-local config writes remain blocked.
    """
    destructive_writes = {"--unset", "--unset-all", "--remove-section", "--rename-section"}
    keys = _config_write_keys(args)
    key = keys[0]
    credential_key = key == "credential.helper" or (
        key.startswith("credential.") and key.endswith(".helper")
    )
    user_scoped = any(arg in {"--global", "--user"} for arg in args)
    repo_scoped = any(arg in {"--local", "--worktree", "--file", "-f"} for arg in args)
    alternate_source = any(arg.startswith(("--file=", "--blob=")) for arg in args)
    destructive = any(arg in destructive_writes for arg in args)
    return all(
        (
            args,
            user_scoped,
            not repo_scoped,
            not alternate_source,
            not destructive,
            key,
            credential_key,
        )
    )


def _config_write_keys(args: list[str]) -> list[str]:
    value_options = {"--type", "--fixed-value"}
    ignored_flags = {"--global", "--user", "--add", "--replace-all"}
    keys: list[str] = []
    skip_next = False
    invalid = False
    for arg in args:
        if skip_next:
            skip_next = False
        elif arg in value_options:
            skip_next = True
        elif arg.startswith("--") or arg in ignored_flags:
            continue
        elif arg.startswith("-"):
            invalid = True
            break
        else:
            keys.append(arg)
    return keys if not invalid and keys else [""]


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


def _is_hash_object_write_flag(arg: str) -> bool:
    return arg == "-w" or (
        arg.startswith("-") and not arg.startswith("--") and "w" in arg[1:]
    )


def _hash_object_options(args: list[str]) -> list[str]:
    try:
        return args[: args.index("--")]
    except ValueError:
        return args


def _is_unknown_hash_object_option(arg: str) -> bool:
    read_only_options = {
        "--literally",
        "--no-filters",
        "--stdin",
        "--stdin-paths",
    }
    return (
        arg.startswith("-")
        and arg not in read_only_options
        and not arg.startswith("--path=")
    )


def _hash_object_is_read_only(args: list[str]) -> bool:
    """Allow hashing inputs while rejecting object database writes."""
    expect_value = False

    for arg in _hash_object_options(args):
        if expect_value:
            expect_value = False
            continue
        if arg == "-t":
            expect_value = True
            continue
        if _is_hash_object_write_flag(arg) or _is_unknown_hash_object_option(arg):
            return False

    return not expect_value


CANONICAL_CHECKS: dict[str, Callable[[list[str]], bool]] = {
    "branch": _branch_is_read_only,
    "bundle": _bundle_is_read_only,
    "config": _config_is_read_only,
    "clean": _clean_is_read_only,
    "hash-object": _hash_object_is_read_only,
    **REF_QUERY_CHECKS,
}
