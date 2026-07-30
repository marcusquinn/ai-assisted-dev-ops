#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Descriptor-relative traversal, limits, and scan leases for folder ingestion."""

from __future__ import annotations

import os
import stat
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

from knowledge_folder_state import (
    DIRECTORY_FLAGS,
    FolderWalkError,
    Lease,
    RootHandle,
    open_root,
    secure_child_directory,
    validate_limits,
)
from knowledge_folder_types import excluded, sanitize_reason


FILE_FLAGS = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)


@dataclass(frozen=True)
class InventoryItem:
    """One descriptor-relative traversal observation."""

    relative: str
    name: str
    descriptor: int | None
    info: os.stat_result
    disposition: str | None = None


@dataclass
class _WalkContext:
    exclude_patterns: list[str]
    max_depth: int
    deadline: float
    max_nodes: int
    root_info: os.stat_result
    visited_nodes: int = 0
    stopped: bool = False

    def visit(self, directory_descriptor: int, prefix: str, depth: int) -> Iterator[InventoryItem]:
        try:
            with os.scandir(directory_descriptor) as entries:
                for entry in entries:
                    yield from self._visit_entry(entry, directory_descriptor, prefix, depth)
                    if self.stopped:
                        return
        except OSError as error:
            relative = prefix or "."
            reason = f"unobserved:{sanitize_reason(error)}"
            yield InventoryItem(relative, Path(prefix).name or ".", None, self.root_info, reason)

    def _visit_entry(
        self, entry: os.DirEntry[str], directory_descriptor: int, prefix: str, depth: int
    ) -> Iterator[InventoryItem]:
        relative = f"{prefix}/{entry.name}" if prefix else entry.name
        self.visited_nodes += 1
        if self.visited_nodes > self.max_nodes or time.monotonic() >= self.deadline:
            self.stopped = True
            yield InventoryItem(relative, entry.name, None, self.root_info, "global-budget")
            return
        try:
            info = entry.stat(follow_symlinks=False)
        except OSError as error:
            reason = f"unobserved:{sanitize_reason(error)}"
            yield InventoryItem(relative, entry.name, None, self.root_info, reason)
            return
        if excluded(relative, self.exclude_patterns):
            yield InventoryItem(relative, entry.name, None, info, "excluded")
        elif stat.S_ISLNK(info.st_mode):
            yield InventoryItem(relative, entry.name, None, info, "symlink-not-followed")
        elif stat.S_ISDIR(info.st_mode):
            yield from self._visit_directory(entry.name, relative, directory_descriptor, info, depth)
        elif stat.S_ISREG(info.st_mode):
            yield from _open_file(entry.name, relative, directory_descriptor, info)
        else:
            yield InventoryItem(relative, entry.name, None, info, "non-regular-file")

    def _visit_directory(
        self, name: str, relative: str, parent_descriptor: int, expected: os.stat_result, depth: int
    ) -> Iterator[InventoryItem]:
        if depth >= self.max_depth:
            yield InventoryItem(relative, name, None, expected, "depth-limit")
            return
        try:
            child_descriptor = os.open(name, DIRECTORY_FLAGS, dir_fd=parent_descriptor)
        except OSError as error:
            yield InventoryItem(relative, name, None, expected, f"unobserved:{sanitize_reason(error)}")
            return
        try:
            child_info = os.fstat(child_descriptor)
            if (child_info.st_dev, child_info.st_ino) != (expected.st_dev, expected.st_ino):
                yield InventoryItem(relative, name, None, expected, "unobserved:directory changed")
                return
            yield from self.visit(child_descriptor, relative, depth + 1)
        finally:
            os.close(child_descriptor)


def walk(
    root: RootHandle,
    exclude_patterns: list[str],
    max_depth: int,
    deadline: float,
    max_nodes: int,
) -> Iterator[InventoryItem]:
    """Walk beneath an opened root without following path replacements or symlinks."""
    root_descriptor = os.dup(root.descriptor)
    context = _WalkContext(exclude_patterns, max_depth, deadline, max_nodes, os.fstat(root_descriptor))
    try:
        yield from context.visit(root_descriptor, "", 0)
    finally:
        os.close(root_descriptor)


def _open_file(
    name: str, relative: str, directory_descriptor: int, expected: os.stat_result
) -> Iterator[InventoryItem]:
    try:
        file_descriptor = os.open(name, FILE_FLAGS, dir_fd=directory_descriptor)
    except OSError as error:
        yield InventoryItem(relative, name, None, expected, f"unobserved:{sanitize_reason(error)}")
        return
    try:
        opened = os.fstat(file_descriptor)
        if (opened.st_dev, opened.st_ino) != (expected.st_dev, expected.st_ino):
            yield InventoryItem(relative, name, None, expected, "unobserved:file changed")
            return
        yield InventoryItem(relative, name, file_descriptor, opened)
    finally:
        os.close(file_descriptor)
