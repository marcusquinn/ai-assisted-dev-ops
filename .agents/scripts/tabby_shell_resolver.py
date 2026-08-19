#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Resolve a safe executable login shell for aidevops-managed Tabby profiles."""

from __future__ import annotations

import argparse
import os
import platform
import pwd
import sys
from collections.abc import Callable, Iterable


SUPPORTED_SHELL_NAMES = frozenset({"bash", "dash", "ksh", "mksh", "sh", "zsh"})


class ShellResolutionError(RuntimeError):
    """Raised when no safe executable login shell can be resolved."""


def is_executable_command(path: str) -> bool:
    """Return whether ``path`` is an absolute executable regular file."""
    if not path or any(character in path for character in ("\x00", "\n", "\r")):
        return False
    if any(character.isspace() for character in path):
        return False
    return os.path.isabs(path) and os.path.isfile(path) and os.access(path, os.X_OK)


def is_executable_shell(path: str) -> bool:
    """Return whether ``path`` is a supported executable login shell."""
    return is_executable_command(path) and os.path.basename(path) in SUPPORTED_SHELL_NAMES


def _account_login_shell() -> str:
    """Return the current account's configured login shell when available."""
    try:
        return pwd.getpwuid(os.getuid()).pw_shell or ""
    except (KeyError, OSError):
        return ""


def _fallback_shells(platform_name: str) -> tuple[str, ...]:
    """Return deterministic platform-specific fallback candidates."""
    if platform_name == "Darwin":
        return ("/bin/zsh", "/bin/bash", "/bin/sh", "/usr/bin/zsh", "/usr/bin/bash")
    return ("/bin/bash", "/bin/sh", "/usr/bin/bash", "/bin/zsh", "/usr/bin/zsh")


def resolve_login_shell(
    configured_shell: str | None = None,
    fallback_candidates: Iterable[str] | None = None,
    platform_name: str | None = None,
    validator: Callable[[str], bool] = is_executable_shell,
) -> str:
    """Resolve configured login shell first, then deterministic safe fallbacks."""
    candidates = [
        configured_shell or "",
        os.environ.get("AIDEVOPS_TABBY_LOGIN_SHELL", ""),
        os.environ.get("SHELL", ""),
        _account_login_shell(),
    ]
    candidates.extend(
        fallback_candidates
        if fallback_candidates is not None
        else _fallback_shells(platform_name or platform.system())
    )

    seen: set[str] = set()
    for candidate in candidates:
        candidate = candidate.strip()
        if not candidate or candidate in seen:
            continue
        seen.add(candidate)
        if validator(candidate):
            return candidate
    raise ShellResolutionError(
        "No safe executable login shell found; configure an absolute executable "
        "POSIX shell with AIDEVOPS_TABBY_LOGIN_SHELL"
    )


def main() -> int:
    """Print the resolved shell for shell-script callers."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    try:
        print(resolve_login_shell())
    except ShellResolutionError as exc:
        print(f"Tabby login-shell resolution failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
