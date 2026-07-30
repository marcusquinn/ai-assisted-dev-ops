#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Private manifest schema and checkpoint helpers for folder ingestion."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from knowledge_folder_state import Lease
from knowledge_folder_types import atomic_write_json, sanitize_reason


SCHEMA = "aidevops.knowledge-folder/v1"
COUNT_KEYS = ("planned", "imported", "unchanged", "skipped", "unsupported", "failed", "budget-stopped")


class FolderImportError(RuntimeError):
    """Raised when traversal cannot preserve the folder import contract."""


@dataclass(frozen=True)
class ManifestEntry:
    """One sanitized item observation ready for manifest publication."""

    status: str
    size: int = 0
    kind: str = "unknown"
    digest: str | None = None
    reason: object | None = None
    source_id: str | None = None
    evidence_id: str | None = None
    aliases: list[str] | None = None
    relations: tuple[dict[str, str], ...] = ()


def load_manifest(path: Path) -> dict[str, Any] | None:
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


def new_manifest(
    root_id: str, previous: dict[str, Any] | None, token: int, args: argparse.Namespace
) -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "root_id": root_id,
        "connector_id": "local-folder",
        "fencing_token": token,
        "commit_state": "running",
        "status": "running",
        "started_at": utc_now(),
        "updated_at": utc_now(),
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


def record(manifest: dict[str, Any], relative: str, item: ManifestEntry) -> None:
    entry: dict[str, Any] = {
        "status": item.status,
        "size_bytes": item.size,
        "kind": item.kind,
        "observed_at": utc_now(),
    }
    optional = {
        "sha256": item.digest,
        "reason": sanitize_reason(item.reason) if item.reason is not None else None,
        "source_id": item.source_id,
        "evidence_id": item.evidence_id,
        "aliases": sorted(set(item.aliases)) if item.aliases else None,
        "relations": list(item.relations) if item.relations else None,
    }
    entry.update({key: value for key, value in optional.items() if value is not None})
    manifest["entries"][relative] = entry
    manifest["counts"][item.status] += 1
    manifest["updated_at"] = utc_now()


def aliases_for_digest(entries: dict[str, Any], relative: str, digest: str) -> list[str]:
    aliases = [relative]
    for prior_path, prior in entries.items():
        if isinstance(prior, dict) and prior.get("sha256") == digest:
            aliases.extend(prior.get("aliases", []))
            aliases.append(prior_path)
    return sorted(set(aliases))


def final_status(counts: dict[str, int]) -> str:
    if counts["budget-stopped"]:
        return "budget-stopped"
    return "partial" if counts["failed"] else "complete"


def summary(manifest: dict[str, Any]) -> dict[str, Any]:
    return {
        "root_id": manifest["root_id"],
        "status": manifest["status"],
        "fencing_token": manifest["fencing_token"],
        "counts": manifest["counts"],
    }


def emit(value: dict[str, Any], as_json: bool) -> None:
    if as_json:
        print(json.dumps(value, sort_keys=True))
        return
    counts = value["counts"]
    rendered = ", ".join(f"{key}={counts[key]}" for key in COUNT_KEYS)
    print(f"folder {value['root_id']}: {value['status']} ({rendered})")


def checkpoint(path: Path, manifest: dict[str, Any], lease: Lease) -> None:
    lease.assert_owned()
    atomic_write_json(path, manifest)


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
