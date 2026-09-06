#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate and copy bounded dependency snapshots for the controller restore path.

No installs, permission changes, ownership transfers or worker resumes occur here.
Callers must hold their existing restore lock and own the destination.
"""

import argparse
import ctypes
import os
from pathlib import Path
from subprocess import SubprocessError  # nosec B404 -- exception type only, no process execution.
import sys

from _worktree_dependency_identity import Rejected, contained_path, identity, open_directory, trusted
from _worktree_dependency_snapshot import snapshot


def publish(stage, worktree, relative):
    """Atomic no-replace promotion using pinned directories; no BSD mv fallback."""
    stage, worktree = contained_path(stage), contained_path(worktree)
    validate_promotion_source(stage, worktree)
    libc = ctypes.CDLL(None, use_errno=True)
    name, flag = ("renameatx_np", 4) if sys.platform == "darwin" else ("renameat2", 1)
    rename = getattr(libc, name, None)
    if rename is None:
        raise Rejected("atomic-no-replace-unavailable")
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    with open_directory(stage.parent) as source, open_directory(worktree / relative) as destination:
        trusted(os.fstat(source))
        trusted(os.fstat(destination))
        if rename(source, b"node_modules", destination, b"node_modules", flag) != 0:
            raise Rejected("atomic-promotion-refused")


def validate_promotion_source(stage, worktree):
    if (stage.name != "node_modules" or stage.parent.parent != worktree
            or not stage.parent.name.startswith(".aidevops-deps-")):
        raise Rejected("invalid-promotion-source")
    trusted(stage.parent.stat())
    if stage.parent.stat().st_mode & 0o077:
        raise Rejected("non-private-stage")


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo")
    parser.add_argument("worktree")
    parser.add_argument("relative")
    parser.add_argument("--snapshot", help="Validate a private staged copy instead of the source")
    parser.add_argument("--copy-to", help="Copy with enforced limits into an empty private staging directory")
    parser.add_argument("--publish", help="Validate and atomically promote a private staged copy without replacement")
    parser.add_argument("--max-bytes", type=int, default=64 * 1024 * 1024)
    parser.add_argument("--max-entries", type=int, default=20000)
    return parser.parse_args()


def staging_root(args, modules):
    staging = args.snapshot or args.publish
    root = contained_path(staging) if staging else modules
    if staging and not root.is_relative_to(contained_path(args.worktree)):
        raise Rejected("foreign-staging-directory")
    return root


def copy_destination(args):
    if not args.copy_to:
        return None
    output = contained_path(args.copy_to)
    if (not output.is_relative_to(contained_path(args.worktree))
            or output.stat().st_mode & 0o077 or any(output.iterdir())):
        raise Rejected("invalid-private-staging")
    trusted(output.stat())
    return output


def run(args):
    if not 0 < args.max_bytes <= 64 * 1024 * 1024 or not 0 < args.max_entries <= 20000:
        raise Rejected("invalid-budget")
    modules, inventory = identity(args.repo, args.worktree, Path(args.relative))
    root = staging_root(args, modules)
    result = snapshot(root, args.max_bytes, args.max_entries, copy_destination(args), inventory)
    if args.publish:
        publish(root, Path(args.worktree), Path(args.relative))
    return result


def main():
    args = parse_args()
    try:
        print(run(args))
        return 0
    except (OSError, ValueError, RuntimeError, SubprocessError):
        # Never copy raw paths, package contents or subprocess stderr into logs.
        print("dependency-provision-rejected", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
