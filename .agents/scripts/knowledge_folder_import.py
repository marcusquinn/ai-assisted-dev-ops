#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Replay-safe recursive folder ingestion for the aidevops knowledge plane."""

from __future__ import annotations

import argparse
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from knowledge_folder_manifest import (
    FolderImportError,
    ManifestEntry,
    checkpoint,
    emit,
    final_status,
    load_manifest,
    new_manifest,
    record,
    summary,
    utc_now,
)
from knowledge_folder_model import EvidenceProcessingError, ExpansionBudget
from knowledge_folder_processor import FileProcessor
from knowledge_folder_state import Lease, RootHandle, open_root, secure_child_directory, validate_limits
from knowledge_folder_store import SourceStore
from knowledge_folder_types import sanitize_reason
from knowledge_folder_walk import InventoryItem, walk


@dataclass
class SnapshotRunner:
    """Own one manifest transaction and its bounded inventory counters."""

    args: argparse.Namespace
    root: RootHandle
    manifest_path: Path
    previous: dict[str, Any] | None
    token: int
    persist: bool
    lease: Lease | None = None
    manifest: dict[str, Any] = field(init=False)
    previous_entries: dict[str, Any] = field(init=False)
    store: SourceStore = field(init=False)
    deadline: float = field(init=False)
    seen: set[str] = field(init=False, default_factory=set)
    unobserved_prefixes: set[str] = field(init=False, default_factory=set)
    coverage_complete: bool = field(init=False, default=True)
    file_count: int = field(init=False, default=0)
    byte_count: int = field(init=False, default=0)

    def __post_init__(self) -> None:
        self.previous_entries = dict((self.previous or {}).get("entries", {}))
        self.manifest = new_manifest(self.root.root_id, self.previous, self.token, self.args)
        self.store = SourceStore(self.args.knowledge_root, self.args.corpus_id, self.args.scripts_dir)
        self.deadline = time.monotonic() + self.args.max_seconds

    def run(self) -> tuple[dict[str, Any], int]:
        self._checkpoint()
        inventory = walk(
            self.root, self.args.exclude, self.args.max_depth, self.deadline, self.args.max_nodes
        )
        for item in inventory:
            keep_scanning = self._process_item(item)
            self._checkpoint()
            if not keep_scanning:
                break
        self._observe_deletions()
        self.manifest["status"] = final_status(self.manifest["counts"])
        self.manifest["commit_state"] = "committed" if self.persist else "planned"
        self.manifest["updated_at"] = utc_now()
        self._checkpoint()
        result_code = 2 if self.manifest["status"] in {"partial", "budget-stopped"} else 0
        return self.manifest, result_code

    def _process_item(self, item: InventoryItem) -> bool:
        self.seen.add(item.relative)
        if item.disposition is not None:
            return self._record_disposition(item)
        decision = self._budget_decision(item)
        if decision is not None:
            return self._record_budget(item, decision)
        self._import_file(item)
        return True

    def _record_disposition(self, item: InventoryItem) -> bool:
        disposition = item.disposition or "unknown"
        status = "skipped"
        stop = False
        if disposition.startswith("unobserved:"):
            self.coverage_complete = False
            self.unobserved_prefixes.add(item.relative)
            self.manifest["observations"].append(
                {"path": item.relative, "observation": "coverage-incomplete", "reason": disposition[11:]}
            )
            status = "failed"
        elif disposition in {"depth-limit", "global-budget"}:
            self.coverage_complete = False
            status = "budget-stopped"
            stop = disposition == "global-budget"
        elif disposition == "excluded":
            self.coverage_complete = False
        record(
            self.manifest, item.relative,
            ManifestEntry(status, item.info.st_size, reason=disposition),
        )
        return not stop

    def _budget_decision(self, item: InventoryItem) -> tuple[str, str, bool] | None:
        if self.file_count >= self.args.max_files or time.monotonic() >= self.deadline:
            return "budget-stopped", "scan budget reached", True
        if item.info.st_size > self.args.max_item_bytes:
            return "skipped", "item size limit exceeded", False
        if self.byte_count + item.info.st_size > self.args.max_bytes:
            return "budget-stopped", "byte budget reached", True
        return None

    def _record_budget(self, item: InventoryItem, decision: tuple[str, str, bool]) -> bool:
        status, reason, stop = decision
        if status == "budget-stopped":
            self.coverage_complete = False
        record(
            self.manifest, item.relative,
            ManifestEntry(status, item.info.st_size, reason=reason),
        )
        return not stop

    def _import_file(self, item: InventoryItem) -> None:
        self.file_count += 1
        self.byte_count += item.info.st_size
        budget = ExpansionBudget(
            self.args.max_files - self.file_count,
            self.args.max_bytes - self.byte_count,
            self.deadline,
        )
        try:
            FileProcessor(
                self.manifest, self.previous_entries, self.store, self.args.dry_run, budget
            ).process(item)
        except (EvidenceProcessingError, OSError, UnicodeError, ValueError, TypeError) as error:
            record(
                self.manifest, item.relative,
                ManifestEntry("failed", item.info.st_size, reason=error),
            )
        self.file_count += budget.consumed_items
        self.byte_count += budget.consumed_bytes

    def _checkpoint(self) -> None:
        if not self.persist:
            return
        if self.lease is None:
            raise FolderImportError("folder lease is required for persistent checkpoints")
        checkpoint(self.manifest_path, self.manifest, self.lease)

    def _observe_deletions(self) -> None:
        if not self.persist or not self.coverage_complete:
            return
        for relative, prior in self.previous_entries.items():
            covered_by_error = any(
                relative == prefix or relative.startswith(f"{prefix}/")
                for prefix in self.unobserved_prefixes
            )
            if relative not in self.seen and not covered_by_error and isinstance(prior, dict):
                self.manifest["observations"].append(
                    {"path": relative, "observation": "source-deleted", "source_id": prior.get("source_id")}
                )


def run_import(args: argparse.Namespace) -> int:
    validate_limits(args)
    with open_root(args.folder, args.allow_root) as root:
        state_dir = secure_child_directory(
            args.knowledge_root, "index", "folder-imports", root.root_id, create=not args.dry_run
        )
        manifest_path = state_dir / "manifest.json"
        if args.dry_run:
            previous = load_manifest(manifest_path)
            token = int((previous or {}).get("fencing_token", 0)) + 1
            runner = SnapshotRunner(args, root, manifest_path, previous, token, False)
            manifest, result_code = runner.run()
        else:
            with Lease(state_dir / "lease.json") as lease:
                previous = load_manifest(manifest_path)
                token = int((previous or {}).get("fencing_token", 0)) + 1
                runner = SnapshotRunner(args, root, manifest_path, previous, token, True, lease)
                manifest, result_code = runner.run()
    emit(summary(manifest), args.json)
    return result_code


def run_status(args: argparse.Namespace) -> int:
    with open_root(args.folder, args.allow_root) as root:
        state_dir = secure_child_directory(
            args.knowledge_root, "index", "folder-imports", root.root_id, create=False
        )
        manifest_path = state_dir / "manifest.json"
    manifest = load_manifest(manifest_path)
    if manifest is None:
        raise FolderImportError("no folder import manifest exists")
    emit(summary(manifest), args.json)
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("import", "status"):
        child = subparsers.add_parser(command)
        child.add_argument("folder", type=Path)
        child.add_argument("--knowledge-root", required=True, type=Path)
        child.add_argument("--scripts-dir", required=True, type=Path)
        child.add_argument("--corpus-id", default="repo:default")
        child.add_argument("--allow-root", action="append", default=[], type=Path)
        child.add_argument("--json", action="store_true")
        if command == "import":
            child.add_argument("--dry-run", action="store_true")
            child.add_argument("--exclude", action="append", default=[])
            child.add_argument("--max-depth", type=int, default=16)
            child.add_argument("--max-files", type=int, default=10_000)
            child.add_argument("--max-nodes", type=int, default=100_000)
            child.add_argument("--max-bytes", type=int, default=10 * 1024 * 1024 * 1024)
            child.add_argument("--max-item-bytes", type=int, default=512 * 1024 * 1024)
            child.add_argument("--max-seconds", type=int, default=300)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "import":
            return run_import(args)
        return run_status(args)
    except (FolderImportError, OSError, ValueError) as error:
        print(f"ERROR: {sanitize_reason(error)}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
