#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate social providers and import bounded browser-gap evidence."""

from __future__ import annotations

import argparse
import json
import stat
import sys
from pathlib import Path
from typing import Any

from knowledge_corpus_catalog import DEFAULT_ALIAS, resolve
from knowledge_corpus_context import CatalogError
from knowledge_social_import import canonical_json, import_archive_payload, reject_credentials
from knowledge_social_store import SocialStoreError, validate_opaque, validate_root

CONTRACT_VERSION = 1
GAP_STATES = ("partial", "unavailable")


def private_json(path: Path, label: str, max_bytes: int) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise SocialStoreError(f"{label} must be a regular non-symlink file")
    if stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise SocialStoreError(f"{label} must have mode 0600")
    if path.stat().st_size > max_bytes:
        raise SocialStoreError(f"{label} exceeds the byte budget")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SocialStoreError(f"{label} is not valid UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise SocialStoreError(f"{label} root must be an object")
    reject_credentials(value)
    return value


def text(value: dict[str, Any], key: str) -> str:
    result = value.get(key)
    if not isinstance(result, str) or not result:
        raise SocialStoreError(f"provider contract requires non-empty {key}")
    return result


def validate_manifest(manifest: dict[str, Any]) -> dict[str, Any]:
    if manifest.get("contract_version") != CONTRACT_VERSION:
        raise SocialStoreError("unsupported provider contract version")
    provider = validate_opaque(text(manifest, "provider"), "provider")
    streams = manifest.get("streams")
    writes = manifest.get("write_operations")
    routes = manifest.get("collection_routes")
    if not isinstance(streams, list) or not streams:
        raise SocialStoreError("provider contract requires at least one stream")
    if any(not isinstance(item, str) or not item for item in streams):
        raise SocialStoreError("provider streams must be non-empty strings")
    if len(set(streams)) != len(streams):
        raise SocialStoreError("provider streams must be unique")
    if writes != []:
        raise SocialStoreError("social providers must declare no write operations")
    if routes != ["api", "archive", "browser_gap"]:
        raise SocialStoreError("collection routes must preserve API/archive/browser order")
    browser = manifest.get("browser_gap")
    if not isinstance(browser, dict) or browser.get("checkpointed") is not True:
        raise SocialStoreError("browser gap route must declare checkpointed capture")
    if browser.get("read_only") is not True:
        raise SocialStoreError("browser gap route must be read-only")
    return {"contract_version": CONTRACT_VERSION, "provider": provider, "streams": sorted(streams)}


def validate_gap(
    gap: dict[str, Any], provider: str, streams: list[str]
) -> tuple[str, str, str]:
    if gap.get("provider") != provider:
        raise SocialStoreError("gap provider does not match the provider contract")
    stream = text(gap, "stream")
    if stream not in streams:
        raise SocialStoreError("gap stream is not declared by the provider")
    if gap.get("status") not in GAP_STATES:
        raise SocialStoreError("browser capture requires a partial or unavailable gap")
    if gap.get("official_routes_exhausted") is not True:
        raise SocialStoreError("API/archive routes must be exhausted before browser capture")
    text(gap, "reason")
    return stream, text(gap, "observed_at"), text(gap, "selector_version")


def capture_records(capture: dict[str, Any], max_items: int) -> dict[str, list[dict[str, Any]]]:
    records: dict[str, list[dict[str, Any]]] = {}
    total = 0
    for key in ("accounts", "objects", "activities", "media"):
        value = capture.get(key, [])
        if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
            raise SocialStoreError(f"capture {key} must be an array of objects")
        records[key] = value
        total += len(value)
    if total > max_items:
        raise SocialStoreError("capture exceeds the item budget")
    return records


def build_archive(
    manifest: dict[str, Any], gap: dict[str, Any], capture: dict[str, Any], max_items: int
) -> dict[str, Any]:
    contract = validate_manifest(manifest)
    stream, gap_observed_at, selector_version = validate_gap(
        gap, contract["provider"], contract["streams"]
    )
    if capture.get("read_only") is not True:
        raise SocialStoreError("browser capture must attest read-only operation")
    if capture.get("provider") != contract["provider"] or capture.get("stream") != stream:
        raise SocialStoreError("capture scope does not match the approved gap")
    if capture.get("selector_version") != selector_version:
        raise SocialStoreError("browser selector version drifted from the approved gap")
    if not isinstance(capture.get("complete"), bool):
        raise SocialStoreError("capture complete must be boolean")
    records = capture_records(capture, max_items)
    checkpoint = text(capture, "checkpoint")
    observed_at = text(capture, "observed_at")
    coverage_status = "complete" if capture.get("complete") is True else "paused"
    return {
        "provider": contract["provider"],
        "connection_id": validate_opaque(text(capture, "connection_id"), "connection_id"),
        "remote_account_id": text(capture, "remote_account_id"),
        "enabled_streams": [stream],
        "policy": {"collector": "browser_gap", "read_only": True},
        "exported_at": observed_at,
        **records,
        "coverage": [{
            "stream": stream,
            "cursor_exhausted": capture.get("complete") is True,
            "retention_limit": None,
            "unavailable_reason": gap.get("reason"),
            "status": coverage_status,
            "observed_at": observed_at,
            "provider_json": {"checkpoint": checkpoint, "gap_observed_at": gap_observed_at},
        }],
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("provider-validate", "capture-browser-gap"))
    parser.add_argument("--base", type=Path)
    parser.add_argument("--alias", default=DEFAULT_ALIAS)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--gap", type=Path)
    parser.add_argument("--capture", type=Path)
    parser.add_argument("--max-items", type=int, default=100)
    parser.add_argument("--max-bytes", type=int, default=1_048_576)
    args = parser.parse_args()
    if not 1 <= args.max_items <= 1000:
        parser.error("--max-items must be between 1 and 1000")
    if not 1024 <= args.max_bytes <= 10_485_760:
        parser.error("--max-bytes must be between 1024 and 10485760")
    if args.command == "capture-browser-gap" and (args.gap is None or args.capture is None):
        parser.error("capture-browser-gap requires --gap and --capture")
    return args


def main() -> int:
    args = parse_args()
    try:
        manifest = private_json(args.manifest, "provider manifest", args.max_bytes)
        if args.command == "provider-validate":
            result = validate_manifest(manifest)
        else:
            gap = private_json(args.gap, "gap record", args.max_bytes)
            capture = private_json(args.capture, "browser capture", args.max_bytes)
            archive = build_archive(manifest, gap, capture, args.max_items)
            base = args.base or Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"
            root = validate_root(resolve(base, args.alias, "knowledge.write"))
            result = import_archive_payload(root, archive, canonical_json(archive).encode("utf-8"))
            result.update({"route": "browser_gap", "checkpoint": capture["checkpoint"]})
        print(json.dumps(result, sort_keys=True))
        return 0
    except (CatalogError, OSError, SocialStoreError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
