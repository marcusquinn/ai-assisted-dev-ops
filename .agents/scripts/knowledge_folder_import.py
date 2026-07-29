#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Replay-safe recursive folder ingestion for the aidevops knowledge plane."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from knowledge_folder_store import (
    EvidenceProcessingError,
    ExpansionBudget,
    SourceStore,
)
from knowledge_folder_types import (
    atomic_write_json,
    classify_fd,
    excluded,
    sanitize_reason,
    sha256_fd,
)
from knowledge_folder_walk import (
    InventoryItem,
    Lease,
    RootHandle,
    open_root,
    secure_child_directory,
    validate_limits,
    walk,
)


SCHEMA = "aidevops.knowledge-folder/v1"
COUNT_KEYS = ("planned", "imported", "unchanged", "skipped", "unsupported", "failed", "budget-stopped")


class FolderImportError(RuntimeError):
    """Raised when traversal cannot preserve the folder import contract."""


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _load_manifest(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    if path.is_symlink() or not path.is_file():
        raise FolderImportError("folder manifest is not a regular private file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise FolderImportError("folder manifest is not valid UTF-8 JSON") from error
    if not isinstance(value, dict) or value.get("schema") != SCHEMA:
        raise FolderImportError("folder manifest schema is unsupported")
    return value


def _new_manifest(root_id: str, previous: dict[str, Any] | None, token: int, args: argparse.Namespace) -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "root_id": root_id,
        "connector_id": "local-folder",
        "fencing_token": token,
        "commit_state": "running",
        "status": "running",
        "started_at": _utc_now(),
        "updated_at": _utc_now(),
        "limits": {
            "max_depth": args.max_depth,
            "max_files": args.max_files,
            "max_nodes": args.max_nodes,
            "max_bytes": args.max_bytes,
            "max_item_bytes": args.max_item_bytes,
            "max_seconds": args.max_seconds,
        },
        "counts": {key: 0 for key in COUNT_KEYS},
        "entries": dict((previous or {}).get("entries", {})),
        "observations": [],
    }


def _record(
    manifest: dict[str, Any],
    relative: str,
    status_name: str,
    *,
    digest: str | None = None,
    size: int = 0,
    kind: str = "unknown",
    reason: str | None = None,
    source_id: str | None = None,
    evidence_id: str | None = None,
    aliases: list[str] | None = None,
    relations: tuple[dict[str, str], ...] = (),
) -> None:
    entry: dict[str, Any] = {
        "status": status_name,
        "size_bytes": size,
        "kind": kind,
        "observed_at": _utc_now(),
    }
    if digest:
        entry["sha256"] = digest
    if reason:
        entry["reason"] = sanitize_reason(reason)
    if source_id:
        entry["source_id"] = source_id
    if evidence_id:
        entry["evidence_id"] = evidence_id
    if aliases:
        entry["aliases"] = sorted(set(aliases))
    if relations:
        entry["relations"] = list(relations)
    manifest["entries"][relative] = entry
    manifest["counts"][status_name] += 1
    manifest["updated_at"] = _utc_now()


def _aliases_for_digest(entries: dict[str, Any], relative: str, digest: str) -> list[str]:
    aliases = [relative]
    for prior_path, prior in entries.items():
        if isinstance(prior, dict) and prior.get("sha256") == digest:
            aliases.extend(prior.get("aliases", []))
            aliases.append(prior_path)
    return sorted(set(aliases))


def _final_status(counts: dict[str, int]) -> str:
    if counts["budget-stopped"]:
        return "budget-stopped"
    if counts["failed"]:
        return "partial"
    return "complete"


def _summary(manifest: dict[str, Any]) -> dict[str, Any]:
    return {
        "root_id": manifest["root_id"],
        "status": manifest["status"],
        "fencing_token": manifest["fencing_token"],
        "counts": manifest["counts"],
    }


def _emit(summary: dict[str, Any], as_json: bool) -> None:
    if as_json:
        print(json.dumps(summary, sort_keys=True))
        return
    counts = summary["counts"]
    rendered = ", ".join(f"{key}={counts[key]}" for key in COUNT_KEYS)
    print(f"folder {summary['root_id']}: {summary['status']} ({rendered})")


def _checkpoint(path: Path, manifest: dict[str, Any], lease: Lease) -> None:
    lease.assert_owned()
    atomic_write_json(path, manifest)


def _process_file(
    item: InventoryItem,
    manifest: dict[str, Any],
    previous_entries: dict[str, Any],
    store: SourceStore,
    dry_run: bool,
    expansion_budget: ExpansionBudget,
) -> tuple[int, int]:
    if item.descriptor is None:
        raise FolderImportError("regular file descriptor is unavailable")
    classification = classify_fd(item.name, item.descriptor)
    if not classification.supported:
        _record(manifest, item.relative, "unsupported", size=item.info.st_size, reason=classification.reason)
        return 0, 0
    if not classification.valid:
        _record(
            manifest, item.relative, "failed", size=item.info.st_size,
            kind=classification.kind, reason=classification.reason,
        )
        return 0, 0
    digest = sha256_fd(item.descriptor)
    current = os.fstat(item.descriptor)
    before = (item.info.st_ino, item.info.st_size, item.info.st_mtime_ns)
    after = (current.st_ino, current.st_size, current.st_mtime_ns)
    if before != after:
        _record(
            manifest, item.relative, "failed", size=item.info.st_size,
            kind=classification.kind, reason="file changed during scan",
        )
        return 0, 0
    aliases = _aliases_for_digest(previous_entries, item.relative, digest)
    previous = previous_entries.get(item.relative, {})
    previous_source = previous.get("source_id") if isinstance(previous, dict) else None
    existing = store.by_digest.get(digest)
    if dry_run:
        status_name = "unchanged" if existing is not None else "planned"
        _record(
            manifest, item.relative, status_name, digest=digest, size=item.info.st_size,
            kind=classification.kind, source_id=existing[0] if existing else None, aliases=aliases,
        )
        return 0, 0
    if existing is not None and previous.get("sha256") == digest and previous_source == existing[0]:
        _record(
            manifest, item.relative, "unchanged", digest=digest, size=item.info.st_size,
            kind=classification.kind, source_id=existing[0], evidence_id=existing[1],
            aliases=aliases, relations=tuple(previous.get("relations", [])),
        )
        return 0, 0
    try:
        result = store.import_file(
            item.name, item.descriptor, item.info.st_size, digest, classification.kind,
            classification.mime_type, classification.processors, expansion_budget,
        )
    except EvidenceProcessingError as error:
        preserved = store.by_digest.get(digest)
        _record(
            manifest, item.relative, "failed", digest=digest, size=item.info.st_size,
            kind=classification.kind, reason=error,
            source_id=preserved[0] if preserved else None,
            evidence_id=preserved[1] if preserved else None,
            aliases=aliases,
        )
        return expansion_budget.consumed_items, expansion_budget.consumed_bytes
    current = os.fstat(item.descriptor)
    if (current.st_ino, current.st_size, current.st_mtime_ns) != after:
        _record(
            manifest, item.relative, "failed", digest=digest, size=item.info.st_size,
            kind=classification.kind, reason="file changed while evidence was copied",
            source_id=result.source_id, evidence_id=result.evidence_id, aliases=aliases,
        )
        return expansion_budget.consumed_items, expansion_budget.consumed_bytes
    status_name = "budget-stopped" if result.budget_stopped else ("unchanged" if result.reused else "imported")
    _record(
        manifest, item.relative, status_name, digest=digest, size=item.info.st_size,
        kind=classification.kind, source_id=result.source_id, evidence_id=result.evidence_id,
        aliases=aliases, relations=result.relations,
    )
    return expansion_budget.consumed_items, expansion_budget.consumed_bytes


def _run_snapshot(
    args: argparse.Namespace,
    root: RootHandle,
    root_id: str,
    manifest_path: Path,
    previous: dict[str, Any] | None,
    token: int,
    persist: bool,
    lease: Lease | None = None,
) -> tuple[dict[str, Any], int]:
    previous_entries = dict((previous or {}).get("entries", {}))
    manifest = _new_manifest(root_id, previous, token, args)
    store = SourceStore(args.knowledge_root, args.corpus_id, args.scripts_dir)
    started = time.monotonic()
    deadline = started + args.max_seconds
    seen: set[str] = set()
    unobserved_prefixes: set[str] = set()
    coverage_complete = True
    file_count = 0
    byte_count = 0
    if persist:
        if lease is None:
            raise FolderImportError("folder lease is required for persistent checkpoints")
        _checkpoint(manifest_path, manifest, lease)
    for item in walk(root, args.exclude, args.max_depth, deadline, args.max_nodes):
        seen.add(item.relative)
        if item.disposition is not None:
            if item.disposition.startswith("unobserved:"):
                coverage_complete = False
                unobserved_prefixes.add(item.relative)
                manifest["observations"].append(
                    {"path": item.relative, "observation": "coverage-incomplete", "reason": item.disposition[11:]}
                )
                _record(manifest, item.relative, "failed", size=item.info.st_size, reason=item.disposition)
            elif item.disposition == "depth-limit":
                coverage_complete = False
                _record(manifest, item.relative, "budget-stopped", size=item.info.st_size, reason=item.disposition)
            elif item.disposition == "global-budget":
                coverage_complete = False
                _record(manifest, item.relative, "budget-stopped", size=item.info.st_size, reason=item.disposition)
                if persist:
                    _checkpoint(manifest_path, manifest, lease)
                break
            else:
                if item.disposition == "excluded":
                    coverage_complete = False
                _record(manifest, item.relative, "skipped", size=item.info.st_size, reason=item.disposition)
        elif file_count >= args.max_files or time.monotonic() >= deadline:
            coverage_complete = False
            _record(manifest, item.relative, "budget-stopped", size=item.info.st_size, reason="scan budget reached")
            if persist:
                _checkpoint(manifest_path, manifest, lease)
            break
        elif item.info.st_size > args.max_item_bytes:
            _record(manifest, item.relative, "skipped", size=item.info.st_size, reason="item size limit exceeded")
        elif byte_count + item.info.st_size > args.max_bytes:
            coverage_complete = False
            _record(manifest, item.relative, "budget-stopped", size=item.info.st_size, reason="byte budget reached")
            if persist:
                _checkpoint(manifest_path, manifest, lease)
            break
        else:
            file_count += 1
            byte_count += item.info.st_size
            expansion_budget = ExpansionBudget(
                args.max_files - file_count,
                args.max_bytes - byte_count,
                deadline,
            )
            try:
                child_items, child_bytes = _process_file(
                    item, manifest, previous_entries, store, args.dry_run, expansion_budget
                )
                file_count += child_items
                byte_count += child_bytes
            except (EvidenceProcessingError, OSError, UnicodeError, ValueError, TypeError) as error:
                _record(manifest, item.relative, "failed", size=item.info.st_size, reason=error)
        if persist:
            _checkpoint(manifest_path, manifest, lease)
    if persist and coverage_complete:
        for relative, prior in previous_entries.items():
            covered_by_error = any(
                relative == prefix or relative.startswith(f"{prefix}/")
                for prefix in unobserved_prefixes
            )
            if relative not in seen and not covered_by_error and isinstance(prior, dict):
                manifest["observations"].append(
                    {"path": relative, "observation": "source-deleted", "source_id": prior.get("source_id")}
                )
    manifest["status"] = _final_status(manifest["counts"])
    manifest["commit_state"] = "committed" if persist else "planned"
    manifest["updated_at"] = _utc_now()
    if persist:
        _checkpoint(manifest_path, manifest, lease)
    result_code = 2 if manifest["status"] in {"partial", "budget-stopped"} else 0
    return manifest, result_code


def run_import(args: argparse.Namespace) -> int:
    validate_limits(args)
    with open_root(args.folder, args.allow_root) as root:
        state_dir = secure_child_directory(
            args.knowledge_root, "index", "folder-imports", root.root_id, create=not args.dry_run
        )
        manifest_path = state_dir / "manifest.json"
        if args.dry_run:
            previous = _load_manifest(manifest_path)
            token = int((previous or {}).get("fencing_token", 0)) + 1
            manifest, result_code = _run_snapshot(
                args, root, root.root_id, manifest_path, previous, token, False
            )
        else:
            with Lease(state_dir / "lease.json") as lease:
                previous = _load_manifest(manifest_path)
                token = int((previous or {}).get("fencing_token", 0)) + 1
                manifest, result_code = _run_snapshot(
                    args, root, root.root_id, manifest_path, previous, token, True, lease
                )
    _emit(_summary(manifest), args.json)
    return result_code


def run_status(args: argparse.Namespace) -> int:
    with open_root(args.folder, args.allow_root) as root:
        state_dir = secure_child_directory(
            args.knowledge_root, "index", "folder-imports", root.root_id, create=False
        )
        manifest_path = state_dir / "manifest.json"
    manifest = _load_manifest(manifest_path)
    if manifest is None:
        raise FolderImportError("no folder import manifest exists")
    _emit(_summary(manifest), args.json)
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
