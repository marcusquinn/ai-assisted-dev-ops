# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded no-follow traversal of inventory-backed dependency sources."""

import hashlib
import os
from pathlib import Path
import stat
from contextlib import ExitStack, contextmanager

from _worktree_dependency_identity import Rejected, contained_path, object_json, open_directory, regular_bytes, trusted


def safe_entry_name(name):
    lower = name.lower()
    sensitive = {".git", ".ssh", ".aws", ".npmrc", ".netrc", ".pypirc", "credentials.json"}
    if lower in sensitive or lower.startswith(".env") or lower.endswith((".pem", ".key", ".p12", ".pfx")):
        raise Rejected("credential-bearing-path")


def metadata_entry(name, mode):
    if name in {".bin", ".pnpm"}:
        return stat.S_ISDIR(mode)
    files = {".package-lock.json", ".modules.yaml", ".pnpm-workspace-state-v1.json"}
    return name in files and stat.S_ISREG(mode)


def package_position(path):
    return path.parent.name == "node_modules" or (
        path.parent.name.startswith("@") and path.parent.parent.name == "node_modules")


def resolution_root(path, mode):
    namespace = path.name.startswith("@") and stat.S_ISDIR(mode)
    if path.parent.name == "node_modules":
        return not (namespace or metadata_entry(path.name, mode))
    return package_position(path)


@contextmanager
def directory_at(parent, name):
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    try:
        yield fd
    finally:
        os.close(fd)


class Snapshot:
    """One bounded traversal with pinned source and destination descriptors."""

    def __init__(self, root, max_bytes, max_entries, inventory):
        self.root = contained_path(root)
        self.max_bytes = max_bytes
        self.max_entries = max_entries
        self.inventory = inventory
        self.total = 0
        self.count = 0
        self.records = {}
        self.seen_packages = set()

    def walk(self, fd, relative, output, depth=0):
        trusted(os.fstat(fd))
        if depth > 64:
            raise Rejected("depth-budget-exceeded")
        with os.scandir(fd) as entries:
            for entry in entries:
                self.visit(fd, relative / entry.name, output, entry.stat(follow_symlinks=False), depth)

    def visit(self, fd, rel, output, info, depth):
        self.count += 1
        if self.count > self.max_entries:
            raise Rejected("entry-budget-exceeded")
        safe_entry_name(rel.name)
        self.check_package_root(rel, info.st_mode)
        if stat.S_ISLNK(info.st_mode):
            self.copy_link(fd, rel, output)
        elif stat.S_ISDIR(info.st_mode):
            self.copy_directory(fd, rel, output, depth)
        elif stat.S_ISREG(info.st_mode):
            self.copy_file(fd, rel, output)
        else:
            raise Rejected("special-file")

    def resolved_inside(self, rel):
        resolved = (self.root / rel).resolve(strict=True)
        if not resolved.is_relative_to(self.root):
            raise Rejected("escaping-package-root")
        return resolved

    def inventory_key(self, package_path, manifest):
        if self.inventory[0] == "npm":
            key = str(package_path)
        else:
            key = f"{manifest.get('name')}@{manifest.get('version')}"
        if key not in self.inventory[1]:
            raise Rejected("unrecorded-package")
        return key

    def check_package_root(self, rel, mode):
        package_root = Path("node_modules") / rel
        if not self.inventory or not resolution_root(package_root, mode):
            return
        if not (stat.S_ISDIR(mode) or stat.S_ISLNK(mode)):
            raise Rejected("unrecorded-module-file")
        manifest = object_json(regular_bytes(self.resolved_inside(rel) / "package.json"))
        self.inventory_key(package_root, manifest)

    def copy_link(self, fd, rel, output):
        target = os.readlink(rel.name, dir_fd=fd)
        if os.path.isabs(target):
            raise Rejected("escaping-dependency-link")
        self.resolved_inside(rel)
        self.records[str(rel)] = b"link\0" + target.encode()
        if output is not None:
            os.symlink(target, rel.name, dir_fd=output)

    def copy_directory(self, fd, rel, output, depth):
        with ExitStack() as stack:
            child = stack.enter_context(directory_at(fd, rel.name))
            target = None
            if output is not None:
                os.mkdir(rel.name, mode=0o755, dir_fd=output)
                target = stack.enter_context(directory_at(output, rel.name))
            self.records[str(rel)] = b"dir\0"
            self.walk(child, rel, target, depth + 1)

    def read_payload(self, fd, name):
        source_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        with os.fdopen(source_fd, "rb") as source:
            before = os.fstat(source_fd)
            trusted(before)
            if not stat.S_ISREG(before.st_mode) or before.st_size > self.max_bytes - self.total:
                raise Rejected("byte-budget-exceeded")
            data = source.read(self.max_bytes - self.total + 1)
            self.total += len(data)
            after = os.fstat(source_fd)
            if self.total > self.max_bytes or (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                raise Rejected("changed-or-oversized-source")
        return data, before.st_mode & 0o755

    def record_package(self, rel, data):
        package_path = Path("node_modules") / rel.parent
        if self.inventory and rel.name == "package.json" and package_position(package_path):
            key = self.inventory_key(package_path, object_json(data))
            self.seen_packages.add(key)

    def copy_file(self, fd, rel, output):
        data, mode = self.read_payload(fd, rel.name)
        self.record_package(rel, data)
        self.records[str(rel)] = b"file\0" + str(mode).encode() + hashlib.sha256(data).digest()
        if output is None:
            return
        destination_fd = os.open(rel.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                 0o600, dir_fd=output)
        with os.fdopen(destination_fd, "wb") as destination:
            destination.write(data)
            os.fchmod(destination_fd, mode)

    def scan(self, copy_to):
        with ExitStack() as stack:
            fd = stack.enter_context(open_directory(self.root))
            output_fd = None
            if copy_to is not None:
                output_fd = stack.enter_context(open_directory(copy_to))
                trusted(os.fstat(output_fd))
            self.walk(fd, Path(), output_fd)
        if self.count == 0:
            raise Rejected("missing-dependencies")
        if self.inventory and self.seen_packages != self.inventory[1]:
            raise Rejected("incomplete-package-inventory")
        digest = hashlib.sha256()
        for name, value in sorted(self.records.items()):
            digest.update(name.encode() + b"\0" + value)
        return f"{digest.hexdigest()} {self.total} {self.count}"


def snapshot(root, max_bytes, max_entries, copy_to=None, inventory=None):
    return Snapshot(root, max_bytes, max_entries, inventory).scan(copy_to)
