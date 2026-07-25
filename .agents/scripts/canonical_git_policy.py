#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Repository-target and subcommand policy for the canonical Git guard."""

from __future__ import annotations

import re

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
        elif _is_allowed_canonical(subcommand, args):
            result = True, "read-only canonical operation or linked-worktree creation"
        else:
            result = False, f"canonical worktree mutation via 'git {subcommand}'"
    return result
