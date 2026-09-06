#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate and copy bounded dependency snapshots for the controller restore path.

No installation, permissions, registry ownership transfer, or worker resume occurs
here. Callers must hold their existing restore lock and own the destination.
Only npm and pnpm installations with verifiable installed lock metadata qualify.
"""

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
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


def object_json(data):
    result = json.loads(data)
    if not isinstance(result, dict):
        raise Rejected("invalid-object-metadata")
    return result


def pnpm_inventory(lock):
    """Accept only pnpm's simple v9 packages map, not arbitrary YAML features."""
    text = lock.decode("utf-8")
    if not re.search(r"(?m)^lockfileVersion: ['\"]?9\.0['\"]?$", text):
        raise Rejected("unsupported-pnpm-lock")
    section = False
    packages = set()
    for line in text.splitlines():
        if line == "packages:":
            section = True
            continue
        if section and line and not line.startswith(" "):
            break
        if section and line.startswith("  ") and not line.startswith("   "):
            match = re.fullmatch(r"  ['\"]?(@?[a-zA-Z0-9_./-]+@[0-9][a-zA-Z0-9.+_-]*)['\"]?:", line)
            if not match:
                raise Rejected("unsupported-pnpm-package-key")
            packages.add(match[1])
    if not packages:
        raise Rejected("missing-pnpm-inventory")
    return packages


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
    trusted(worktree.parent.stat())
    trusted(worktree.stat())
    if relative.is_absolute() or ".." in relative.parts:
        raise Rejected("invalid-package-path")
    source, dest = [contained_path(p / relative) for p in (repo, worktree)]
    for base in (repo, worktree):
        current = base
        for part in relative.parts:
            current /= part
            trusted(current.stat())
    package = regular_bytes(source / "package.json")
    if package != regular_bytes(dest / "package.json"):
        raise Rejected("stale-package-identity")
    parsed = object_json(package)
    if not parsed.get("name"):
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
        inventory = ("pnpm", pnpm_inventory(lock))
    else:
        expected = object_json(lock).get("packages")
        installed = object_json(regular_bytes(modules / ".package-lock.json")).get("packages")
        if not isinstance(expected, dict) or not isinstance(installed, dict) or not installed:
            raise Rejected("missing-installed-identity")
        root_package = expected.get("")
        if not isinstance(root_package, dict) or any(
            parsed.get(key) != root_package.get(key)
            for key in ("name", "version", "dependencies", "devDependencies", "optionalDependencies")
        ):
            raise Rejected("stale-root-lock-identity")
        if set(expected) - {""} != set(installed):
            raise Rejected("incomplete-installed-inventory")
        for location, metadata in installed.items():
            if not isinstance(metadata, dict) or metadata != expected[location]:
                raise Rejected("stale-installed-lock")
            if not location.startswith("node_modules/") or ".." in Path(location).parts:
                raise Rejected("invalid-installed-path")
            manifest = object_json(regular_bytes(contained_path(source / location / "package.json")))
            if not manifest.get("name") or not manifest.get("version") or manifest["version"] != metadata.get("version"):
                raise Rejected("stale-installed-package")
        inventory = ("npm", set(installed))
    return modules, inventory


def snapshot(root, max_bytes, max_entries, copy_to=None, inventory=None):
    root = contained_path(root)
    total = 0
    count = 0
    records = {}
    seen_packages = set()

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
                package_root = Path("node_modules") / rel
                namespace = name.startswith("@") and stat.S_ISDIR(info.st_mode)
                metadata_entry = (
                    name in {".bin", ".pnpm"} and stat.S_ISDIR(info.st_mode)
                    or name in {".package-lock.json", ".modules.yaml", ".pnpm-workspace-state-v1.json"}
                    and stat.S_ISREG(info.st_mode)
                )
                resolution_root = (
                    package_root.parent.name == "node_modules" and not (namespace or metadata_entry)
                    or package_root.parent.name.startswith("@") and package_root.parent.parent.name == "node_modules"
                )
                if inventory and resolution_root:
                    if not (stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)):
                        raise Rejected("unrecorded-module-file")
                    resolved = (root / rel).resolve(strict=True)
                    if not resolved.is_relative_to(root):
                        raise Rejected("escaping-package-root")
                    manifest = object_json(regular_bytes(resolved / "package.json"))
                    package_key = (str(package_root) if inventory[0] == "npm" else
                                   f"{manifest.get('name')}@{manifest.get('version')}")
                    if package_key not in inventory[1]:
                        raise Rejected("unrecorded-package-root")
                if stat.S_ISLNK(info.st_mode):
                    target = os.readlink(name, dir_fd=fd)
                    if os.path.isabs(target) or not (root / rel).resolve(strict=True).is_relative_to(root):
                        raise Rejected("escaping-dependency-link")
                    records[str(rel)] = b"link\0" + target.encode()
                    if output is not None:
                        os.symlink(target, name, dir_fd=output)
                elif stat.S_ISDIR(info.st_mode):
                    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                    target_dir = None
                    try:
                        if output is not None:
                            os.mkdir(name, mode=0o755, dir_fd=output)
                            target_dir = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=output)
                        records[str(rel)] = b"dir\0"
                        walk(child, rel, target_dir, depth + 1)
                    finally:
                        os.close(child)
                        if target_dir is not None:
                            os.close(target_dir)
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
                    package_path = Path("node_modules") / rel.parent
                    is_package = (package_path.parent.name == "node_modules" or
                                  (package_path.parent.name.startswith("@") and package_path.parent.parent.name == "node_modules"))
                    if inventory and name == "package.json" and is_package:
                        manifest = object_json(data)
                        key = (str(package_path) if inventory[0] == "npm" else
                               f"{manifest.get('name')}@{manifest.get('version')}")
                        if key not in inventory[1]:
                            raise Rejected("unrecorded-package")
                        seen_packages.add(key)
                    records[str(rel)] = b"file\0" + str(before.st_mode & 0o755).encode() + hashlib.sha256(data).digest()
                    if output is not None:
                        destination_fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                                 0o600, dir_fd=output)
                        with os.fdopen(destination_fd, "wb") as destination:
                            destination.write(data)
                            os.fchmod(destination_fd, before.st_mode & 0o755)
                else:
                    raise Rejected("special-file")

    with open_directory(root) as fd:
        if copy_to is None:
            walk(fd, Path(), None)
        else:
            with open_directory(copy_to) as output_fd:
                trusted(os.fstat(output_fd))
                walk(fd, Path(), output_fd)
    if count == 0:
        raise Rejected("missing-dependencies")
    if inventory and seen_packages != inventory[1]:
        raise Rejected("incomplete-package-inventory")
    digest = hashlib.sha256()
    for name, value in sorted(records.items()):
        digest.update(name.encode() + b"\0" + value)
    return f"{digest.hexdigest()} {total} {count}"


def publish(stage, worktree, relative):
    """Atomic no-replace promotion using pinned directories; no BSD mv fallback."""
    stage, worktree = contained_path(stage), contained_path(worktree)
    if (stage.name != "node_modules" or stage.parent.parent != worktree
            or not stage.parent.name.startswith(".aidevops-deps-")):
        raise Rejected("invalid-promotion-source")
    trusted(stage.parent.stat())
    if stage.parent.stat().st_mode & 0o077:
        raise Rejected("non-private-stage")
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo")
    parser.add_argument("worktree")
    parser.add_argument("relative")
    parser.add_argument("--snapshot", help="Validate a private staged copy instead of the source")
    parser.add_argument("--copy-to", help="Copy with enforced byte/entry limits into an empty private staging directory")
    parser.add_argument("--publish", help="Validate and atomically promote a private staged copy without replacing a destination")
    parser.add_argument("--max-bytes", type=int, default=64 * 1024 * 1024)
    parser.add_argument("--max-entries", type=int, default=20000)
    args = parser.parse_args()
    try:
        if not 0 < args.max_bytes <= 64 * 1024 * 1024 or not 0 < args.max_entries <= 20000:
            raise Rejected("invalid-budget")
        modules, inventory = identity(args.repo, args.worktree, Path(args.relative))
        staging = args.snapshot or args.publish
        root = contained_path(staging) if staging else modules
        if staging and not root.is_relative_to(contained_path(args.worktree)):
            raise Rejected("foreign-staging-directory")
        output = contained_path(args.copy_to) if args.copy_to else None
        if output is not None:
            if (not output.is_relative_to(contained_path(args.worktree))
                    or output.stat().st_mode & 0o077 or any(output.iterdir())):
                raise Rejected("invalid-private-staging")
            trusted(output.stat())
        result = snapshot(root, args.max_bytes, args.max_entries, output, inventory)
        if args.publish:
            publish(root, Path(args.worktree), Path(args.relative))
        print(result)
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        # Never copy raw paths, package contents or subprocess stderr into logs.
        print("dependency-provision-rejected", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
