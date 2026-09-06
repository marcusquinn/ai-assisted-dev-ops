#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate bounded dependency snapshots for the controller's fast_cp path.

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


class Rejected(ValueError):
    """A dependency snapshot cannot safely be provisioned."""


def regular_bytes(path, limit=8 * 1024 * 1024):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
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
    if common[0] != common[1] or not (worktree / ".git").is_file():
        raise Rejected("foreign-repository")
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


def snapshot(root, max_bytes, max_entries):
    root = contained_path(root)
    digest = hashlib.sha256()
    total = 0
    count = 0
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in sorted(dirs + files):
            count += 1
            if count > max_entries:
                raise Rejected("entry-budget-exceeded")
            lower = name.lower()
            if (lower in {".git", ".ssh", ".aws", ".npmrc", ".netrc", ".pypirc", "credentials.json"}
                    or lower.startswith(".env") or lower.endswith((".pem", ".key", ".p12", ".pfx"))):
                raise Rejected("credential-bearing-path")
            path = Path(directory) / name
            info = path.lstat()
            digest.update(str(path.relative_to(root)).encode() + b"\0")
            if stat.S_ISLNK(info.st_mode):
                target = os.readlink(path)
                if os.path.isabs(target) or not path.resolve(strict=True).is_relative_to(root):
                    raise Rejected("escaping-dependency-link")
                digest.update(b"link\0" + target.encode())
            elif stat.S_ISDIR(info.st_mode):
                digest.update(b"dir\0")
            elif stat.S_ISREG(info.st_mode):
                if info.st_size > max_bytes - total:
                    raise Rejected("byte-budget-exceeded")
                data = regular_bytes(path, max_bytes - total)
                total += len(data)
                digest.update(b"file\0" + hashlib.sha256(data).digest())
            else:
                raise Rejected("special-file")
    if not root.is_dir() or count == 0:
        raise Rejected("missing-dependencies")
    return f"{digest.hexdigest()} {total} {count}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo")
    parser.add_argument("worktree")
    parser.add_argument("relative")
    parser.add_argument("--snapshot", help="Validate a private staged copy instead of the source")
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
        print(snapshot(root, args.max_bytes, args.max_entries))
        return 0
    except (OSError, ValueError, subprocess.SubprocessError):
        # Never copy raw paths, package contents or subprocess stderr into logs.
        print("dependency-provision-rejected", file=__import__("sys").stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
