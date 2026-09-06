#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate and copy bounded dependency snapshots for the controller restore path.

No installation, permissions, registry ownership transfer, or worker resume occurs
here. Callers must hold their existing restore lock and own the destination.
Only npm and pnpm installations with verifiable installed lock metadata qualify.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
from contextlib import contextmanager


class Rejected(ValueError):
    """A dependency snapshot cannot safely be provisioned."""


@contextmanager
def open_directory(path):
    """Pin every directory component without following a racing symlink."""
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in Path(os.path.abspath(path)).parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        yield fd
    finally:
        os.close(fd)


def trusted(info):
    if info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise Rejected("foreign-or-shared-source")


def regular_bytes(path, limit=8 * 1024 * 1024):
    path = Path(path)
    with open_directory(path.parent) as parent:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        trusted(info)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise Rejected("invalid-or-oversized-file")
        data = source.read(limit + 1)
        if len(data) > limit:
            raise Rejected("byte-budget-exceeded")
        return data


def contained_path(path):
    """Reject symlink components, including dangling links, before any read."""
    path = Path(os.path.abspath(path))
    for parent in [*reversed(path.parents), path]:
        if parent.is_symlink():
            raise Rejected("symlink-component")
    return path


def git(path, *args):
    return subprocess.check_output(
        ["git", "-C", str(path), *args], stderr=subprocess.DEVNULL,
        timeout=10, text=True,
    ).strip()


def identity(repo, worktree, relative):
    repo, worktree = contained_path(repo), contained_path(worktree)
    if repo == worktree or git(worktree, "rev-parse", "--show-toplevel") != str(worktree):
        raise Rejected("not-linked-worktree")
    if git(repo, "rev-parse", "--show-toplevel") != str(repo):
        raise Rejected("not-repository-root")
    common = [git(p, "rev-parse", "--path-format=absolute", "--git-common-dir")
              for p in (repo, worktree)]
    if (common[0] != common[1] or not (worktree / ".git").is_file()
            or not (repo / ".git").is_dir()):
        raise Rejected("foreign-repository")
    trusted(repo.stat())
    if relative.is_absolute() or ".." in relative.parts:
        raise Rejected("invalid-package-path")
    source, dest = [contained_path(p / relative) for p in (repo, worktree)]
    if dest.stat().st_uid != os.getuid() or dest.stat().st_mode & 0o022:
        raise Rejected("foreign-or-shared-destination")
    package = regular_bytes(source / "package.json")
    if package != regular_bytes(dest / "package.json"):
        raise Rejected("stale-package-identity")
    parsed = json.loads(package)
    if not isinstance(parsed, dict) or not parsed.get("name"):
        raise Rejected("missing-package-identity")
    locks = [name for name in ("package-lock.json", "pnpm-lock.yaml")
             if (source / name).exists() or (dest / name).exists()]
    if len(locks) != 1:
        raise Rejected("missing-or-ambiguous-supported-lock")
    name = locks[0]
    lock = regular_bytes(source / name)
    if lock != regular_bytes(dest / name):
        raise Rejected("stale-lock-identity")
    modules = contained_path(source / "node_modules")
    if name == "pnpm-lock.yaml":
        installed = contained_path(modules / ".pnpm" / "lock.yaml")
        if regular_bytes(installed) != lock:
            raise Rejected("stale-installed-lock")
    else:
        expected = json.loads(lock).get("packages")
        installed = json.loads(regular_bytes(modules / ".package-lock.json")).get("packages")
        if not expected or not installed:
            raise Rejected("missing-installed-identity")
        for location, metadata in installed.items():
            if location not in expected or metadata != expected[location]:
                raise Rejected("stale-installed-lock")
            if not location.startswith("node_modules/") or ".." in Path(location).parts:
                raise Rejected("invalid-installed-path")
            manifest = json.loads(regular_bytes(contained_path(source / location / "package.json")))
            if not manifest.get("name") or not manifest.get("version") or manifest["version"] != metadata.get("version"):
                raise Rejected("stale-installed-package")
    return modules


def snapshot(root, max_bytes, max_entries, copy_to=None):
    root = contained_path(root)
    total = 0
    count = 0
    records = {}

    def walk(fd, relative, output, depth=0):
        nonlocal total, count
        trusted(os.fstat(fd))
        if depth > 64:
            raise Rejected("depth-budget-exceeded")
        with os.scandir(fd) as entries:
            for entry in entries:
                count += 1
                if count > max_entries:
                    raise Rejected("entry-budget-exceeded")
                name = entry.name
                lower = name.lower()
                if (lower in {".git", ".ssh", ".aws", ".npmrc", ".netrc", ".pypirc", "credentials.json"}
                        or lower.startswith(".env") or lower.endswith((".pem", ".key", ".p12", ".pfx"))):
                    raise Rejected("credential-bearing-path")
                rel = relative / name
                info = entry.stat(follow_symlinks=False)
                if stat.S_ISLNK(info.st_mode):
                    target = os.readlink(name, dir_fd=fd)
                    if os.path.isabs(target) or not (root / rel).resolve(strict=True).is_relative_to(root):
                        raise Rejected("escaping-dependency-link")
                    records[str(rel)] = b"link\0" + target.encode()
                    if output is not None:
                        os.symlink(target, output / name)
                elif stat.S_ISDIR(info.st_mode):
                    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                    try:
                        target_dir = output / name if output is not None else None
                        if target_dir is not None:
                            target_dir.mkdir(mode=0o755)
                        records[str(rel)] = b"dir\0"
                        walk(child, rel, target_dir, depth + 1)
                    finally:
                        os.close(child)
                elif stat.S_ISREG(info.st_mode):
                    source_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
                    with os.fdopen(source_fd, "rb") as source:
                        before = os.fstat(source_fd)
                        trusted(before)
                        if not stat.S_ISREG(before.st_mode) or before.st_size > max_bytes - total:
                            raise Rejected("byte-budget-exceeded")
                        data = source.read(max_bytes - total + 1)
                        total += len(data)
                        after = os.fstat(source_fd)
                        if total > max_bytes or (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                            raise Rejected("changed-or-oversized-source")
                    records[str(rel)] = b"file\0" + hashlib.sha256(data).digest()
                    if output is not None:
                        with (output / name).open("xb") as destination:
                            destination.write(data)
                        (output / name).chmod(before.st_mode & 0o755)
                else:
                    raise Rejected("special-file")

    with open_directory(root) as fd:
        walk(fd, Path(), copy_to)
    if count == 0:
        raise Rejected("missing-dependencies")
    digest = hashlib.sha256()
    for name, value in sorted(records.items()):
        digest.update(name.encode() + b"\0" + value)
    return f"{digest.hexdigest()} {total} {count}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo")
    parser.add_argument("worktree")
    parser.add_argument("relative")
    parser.add_argument("--snapshot", help="Validate a private staged copy instead of the source")
    parser.add_argument("--copy-to", help="Copy with enforced byte/entry limits into an empty private staging directory")
    parser.add_argument("--max-bytes", type=int, default=64 * 1024 * 1024)
    parser.add_argument("--max-entries", type=int, default=20000)
    args = parser.parse_args()
    try:
        if not 0 < args.max_bytes <= 64 * 1024 * 1024 or not 0 < args.max_entries <= 20000:
            raise Rejected("invalid-budget")
        modules = identity(args.repo, args.worktree, Path(args.relative))
        root = contained_path(args.snapshot) if args.snapshot else modules
        if args.snapshot and not root.is_relative_to(contained_path(args.worktree)):
            raise Rejected("foreign-staging-directory")
        output = contained_path(args.copy_to) if args.copy_to else None
        if output is not None:
            if (not output.is_relative_to(contained_path(args.worktree))
                    or output.stat().st_mode & 0o077 or any(output.iterdir())):
                raise Rejected("invalid-private-staging")
            trusted(output.stat())
        print(snapshot(root, args.max_bytes, args.max_entries, output))
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        # Never copy raw paths, package contents or subprocess stderr into logs.
        print("dependency-provision-rejected", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
