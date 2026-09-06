# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Filesystem and installed-package identity checks for controller provisioning."""

import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess  # nosec B404 -- fixed read-only Git plumbing, never a shell.
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
    packages = {pnpm_package_key(line) for line in pnpm_package_lines(text)}
    if not packages:
        raise Rejected("missing-pnpm-inventory")
    return packages


def pnpm_package_lines(text):
    section = False
    for line in text.splitlines():
        if line == "packages:":
            section = True
            continue
        if not section:
            continue
        if line and not line.startswith(" "):
            return
        if line.startswith("  ") and not line.startswith("   "):
            yield line


def pnpm_package_key(line):
    match = re.fullmatch(r"  ['\"]?(@?[a-zA-Z0-9_./-]+@[0-9][a-zA-Z0-9.+_-]*)['\"]?:", line)
    if not match:
        raise Rejected("unsupported-pnpm-package-key")
    return match[1]


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
    executable = shutil.which("git")
    if executable is None:
        raise Rejected("git-unavailable")
    return subprocess.check_output(  # nosec B603 -- fixed rev-parse arguments; path is data-only argv.
        [executable, "-C", str(path), *args], stderr=subprocess.DEVNULL,
        timeout=10, text=True,
    ).strip()


def repository_identity(repo, worktree):
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
    return repo, worktree


def package_directories(repo, worktree, relative):
    if relative.is_absolute() or ".." in relative.parts:
        raise Rejected("invalid-package-path")
    source, dest = [contained_path(p / relative) for p in (repo, worktree)]
    for base in (repo, worktree):
        current = base
        for part in relative.parts:
            current /= part
            trusted(current.stat())
    return source, dest


def matching_package(source, dest):
    package = regular_bytes(source / "package.json")
    if package != regular_bytes(dest / "package.json"):
        raise Rejected("stale-package-identity")
    parsed = object_json(package)
    if not parsed.get("name"):
        raise Rejected("missing-package-identity")
    return parsed


def matching_lock(source, dest):
    locks = [name for name in ("package-lock.json", "pnpm-lock.yaml")
             if (source / name).exists() or (dest / name).exists()]
    if len(locks) != 1:
        raise Rejected("missing-or-ambiguous-supported-lock")
    name = locks[0]
    lock = regular_bytes(source / name)
    if lock != regular_bytes(dest / name):
        raise Rejected("stale-lock-identity")
    return name, lock


def identity(repo, worktree, relative):
    repo, worktree = repository_identity(repo, worktree)
    source, dest = package_directories(repo, worktree, relative)
    parsed = matching_package(source, dest)
    name, lock = matching_lock(source, dest)
    modules = contained_path(source / "node_modules")
    if name == "pnpm-lock.yaml":
        installed = contained_path(modules / ".pnpm" / "lock.yaml")
        if regular_bytes(installed) != lock:
            raise Rejected("stale-installed-lock")
        inventory = ("pnpm", pnpm_inventory(lock))
    else:
        inventory = ("npm", npm_inventory(source, modules, lock, parsed))
    return modules, inventory


def npm_inventory(source, modules, lock, parsed):
    expected = object_json(lock).get("packages")
    installed = object_json(regular_bytes(modules / ".package-lock.json")).get("packages")
    if not isinstance(expected, dict) or not isinstance(installed, dict) or not installed:
        raise Rejected("missing-installed-identity")
    validate_root_lock(expected.get(""), parsed)
    if set(expected) - {""} != set(installed):
        raise Rejected("incomplete-installed-inventory")
    for location, metadata in installed.items():
        validate_npm_package(source, location, metadata, expected[location])
    return set(installed)


def validate_root_lock(root_package, parsed):
    if not isinstance(root_package, dict):
        raise Rejected("stale-root-lock-identity")
    keys = ("name", "version", "dependencies", "devDependencies", "optionalDependencies")
    if any(parsed.get(key) != root_package.get(key) for key in keys):
        raise Rejected("stale-root-lock-identity")


def validate_npm_package(source, location, metadata, expected):
    if not isinstance(metadata, dict) or metadata != expected:
        raise Rejected("stale-installed-lock")
    if not location.startswith("node_modules/") or ".." in Path(location).parts:
        raise Rejected("invalid-installed-path")
    manifest = object_json(regular_bytes(contained_path(source / location / "package.json")))
    if not manifest.get("name") or not manifest.get("version") or manifest["version"] != metadata.get("version"):
        raise Rejected("stale-installed-package")
