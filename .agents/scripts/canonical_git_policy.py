#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Repository-target and subcommand policy for the canonical Git guard."""

from __future__ import annotations

import os
import re
import tempfile
from pathlib import Path

from canonical_git_invocation import repository_values, split_invocation
from canonical_git_readonly import CANONICAL_CHECKS
from canonical_git_repository import git_output as _git_output
from canonical_git_repository import is_canonical as _is_canonical
from canonical_git_repository import real_git

BLOCK_EXIT = 42
READ_ONLY = frozenset(
    (
        "status",
        "diff",
        "diff-files",
        "diff-tree",
        "log",
        "show",
        "rev-parse",
        "show-ref",
        "for-each-ref",
        "cat-file",
        "check-ref-format",
        "ls-files",
        "ls-remote",
        "ls-tree",
        "rev-list",
        "merge-base",
        "describe",
        "grep",
        "blame",
        "shortlog",
        "whatchanged",
        "name-rev",
        "count-objects",
        "version",
        "help",
    )
)


def _is_allowed_canonical(subcommand: str, args: list[str]) -> bool:
    if subcommand in READ_ONLY:
        return True
    checker = CANONICAL_CHECKS.get(subcommand)
    return bool(checker and checker(args))


def _is_isolated_prospective_merge_tree(
    real_git_path: str,
    effective_cwd: str,
    prefix: list[str],
    subcommand: str,
    args: list[str],
) -> bool:
    """Allow the full-loop read probe only in its private temporary bare repo."""
    if (
        subcommand != "merge-tree"
        or len(args) != 3
        or args[0] != "--write-tree"
        or not all(re.fullmatch(r"[0-9a-fA-F]{40,64}", value) for value in args[1:])
    ):
        return False
    if (
        _git_output(
            real_git_path,
            effective_cwd,
            *prefix,
            "rev-parse",
            "--is-bare-repository",
        )
        != "true"
    ):
        return False
    git_dir = _git_output(
        real_git_path,
        effective_cwd,
        *prefix,
        "rev-parse",
        "--path-format=absolute",
        "--git-dir",
    )
    if not git_dir or os.path.basename(git_dir) != "repository.git":
        return False
    context_dir = os.path.dirname(os.path.realpath(git_dir))
    if not os.path.basename(context_dir).startswith("aidevops-prospective-todo."):
        return False
    return os.path.dirname(context_dir) == os.path.realpath(tempfile.gettempdir())


def _is_isolated_routines_publisher(
    real_git_path: str,
    effective_cwd: str,
    prefix: list[str],
    subcommand: str,
) -> bool:
    """Allow bounded mutations only in the routines publisher's private clone."""
    if subcommand not in {"add", "commit", "fetch", "push"}:
        return False
    git_dir = _git_output(
        real_git_path,
        effective_cwd,
        *prefix,
        "rev-parse",
        "--path-format=absolute",
        "--git-dir",
    )
    repo_dir = _git_output(
        real_git_path,
        effective_cwd,
        *prefix,
        "rev-parse",
        "--path-format=absolute",
        "--show-toplevel",
    )
    if not git_dir or not repo_dir:
        return False
    repo_dir = os.path.realpath(repo_dir)
    context_dir = os.path.dirname(repo_dir)
    return bool(
        os.path.basename(repo_dir) == "repo"
        and re.fullmatch(r"routines-publisher\.[A-Za-z0-9]+", os.path.basename(context_dir))
        and os.path.dirname(context_dir) == os.path.realpath(tempfile.gettempdir())
        and os.path.realpath(git_dir) == os.path.join(repo_dir, ".git")
    )


def _worktree_remove_target(args: list[str]) -> str:
    """Return the single remove target when args are in the safe subset."""
    target = ""
    invalid = not args or args[0] != "remove"
    option_terminator = False
    for arg in ([] if invalid else args[1:]):
        if option_terminator:
            if target:
                invalid = True
            else:
                target = arg
        elif arg == "--":
            option_terminator = True
        elif arg in {"-f", "--force"}:
            continue
        elif arg.startswith("-"):
            invalid = True
        elif target:
            invalid = True
        else:
            target = arg
    return "" if invalid else target


def _git_repo_identity(
    real_git_path: str, cwd: str, prefix: list[str]
) -> tuple[str, str, str]:
    """Return common dir, git dir, and top-level for a Git target."""
    common_dir = _git_output(
        real_git_path,
        cwd,
        *prefix,
        "rev-parse",
        "--path-format=absolute",
        "--git-common-dir",
    )
    git_dir = _git_output(
        real_git_path,
        cwd,
        *prefix,
        "rev-parse",
        "--path-format=absolute",
        "--git-dir",
    )
    top = _git_output(
        real_git_path,
        cwd,
        *prefix,
        "rev-parse",
        "--path-format=absolute",
        "--show-toplevel",
    )
    return common_dir, git_dir, top


def _is_linked_worktree_remove_for_canonical(
    real_git_path: str,
    effective_cwd: str,
    prefix: list[str],
    args: list[str],
) -> bool:
    """Allow removing only linked worktrees that belong to this canonical repo."""
    target = _worktree_remove_target(args)
    allowed = False

    if target:
        canonical_common_dir, _canonical_git_dir, canonical_top = _git_repo_identity(
            real_git_path, effective_cwd, prefix
        )
        target_path = Path(target).expanduser()
        if not target_path.is_absolute():
            target_path = Path(effective_cwd) / target_path
        target_real = os.path.realpath(target_path)
        target_common_dir, target_git_dir, target_top = _git_repo_identity(
            real_git_path, target_real, []
        )
        required_paths = [
            canonical_common_dir,
            canonical_top,
            target_common_dir,
            target_git_dir,
            target_top,
        ]
        same_common_dir = os.path.realpath(target_common_dir) == os.path.realpath(
            canonical_common_dir
        )
        separate_git_dir = os.path.realpath(target_git_dir) != os.path.realpath(
            target_common_dir
        )
        target_is_toplevel = os.path.realpath(target_top) == target_real
        target_is_not_canonical = target_real != os.path.realpath(canonical_top)
        allowed = all(
            [
                all(required_paths),
                same_common_dir,
                separate_git_dir,
                target_is_toplevel,
                target_is_not_canonical,
            ]
        )
    return allowed


def classify_git_argv(
    argv: list[str], cwd: str, real_git_path: str, check_unresolved: bool = False
) -> tuple[bool, str]:
    """Classify one Git argv vector against canonical-worktree policy."""
    prefix, effective_cwd, subcommand, args = split_invocation(argv, cwd)
    if not subcommand:
        return False, "unable to classify Git subcommand"
    repo_values = repository_values(prefix)
    if check_unresolved and any(
        value.startswith("~") or re.search(r"[$`*?\[\]{}]", value)
        for value in repo_values
    ):
        return False, "unresolved shell syntax in Git repository target"
    try:
        is_canonical = _is_canonical(real_git_path, effective_cwd, prefix)
    except RuntimeError as error:
        result = False, str(error)
    else:
        if not is_canonical:
            result = True, "linked worktree or non-repository target"
        elif _is_isolated_prospective_merge_tree(
            real_git_path, effective_cwd, prefix, subcommand, args
        ):
            result = True, "isolated prospective merge-tree probe"
        elif _is_isolated_routines_publisher(
            real_git_path, effective_cwd, prefix, subcommand
        ):
            result = True, "isolated routines publisher mutation"
        elif subcommand == "worktree" and _is_linked_worktree_remove_for_canonical(
            real_git_path, effective_cwd, prefix, args
        ):
            result = True, "linked-worktree removal for canonical repository"
        elif _is_allowed_canonical(subcommand, args):
            result = True, "read-only canonical operation or linked-worktree creation"
        else:
            result = False, f"canonical worktree mutation via 'git {subcommand}'"
    return result
