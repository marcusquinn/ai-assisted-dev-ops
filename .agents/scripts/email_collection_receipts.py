#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Content-free collection receipts linking staged mail to canonical evidence."""

from __future__ import annotations

import argparse
import json
import re
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping

from email_match_rules import rule_digest
from email_match_validation import validate_rule


_RECEIPT_SUFFIX = ".collection.json"
_RULE_TOKEN = re.compile(r"[A-Za-z0-9_.-]{1,64}")


@dataclass(frozen=True)
class ReceiptContext:
    """Provider identity for one content-free collection reference."""

    transport: str
    mailbox_id: str
    folder: str
    message_key: str


def sidecar_path(eml_path: str | Path) -> Path:
    """Return the collection sidecar path adjacent to one staged message."""
    path = Path(eml_path)
    return path.with_name(path.name + _RECEIPT_SUFFIX)


def _rule_references(rules: Iterable[Mapping[str, Any]]) -> list[dict[str, str]]:
    references = {
        (str(rule.get("id") or rule.get("name")), rule_digest(rule))
        for rule in rules
    }
    return [
        {"id": rule_id, "digest": digest}
        for rule_id, digest in sorted(references)
    ]


def build_receipt(
    context: ReceiptContext, rules: Iterable[Mapping[str, Any]]
) -> dict[str, Any]:
    """Build a private receipt containing selectors and rule IDs, never literals."""
    payload = {
        "version": 1,
        "transport": context.transport,
        "mailbox_id": context.mailbox_id,
        "folder": context.folder,
        "message_key": context.message_key,
        "rules": _rule_references(rules),
    }
    return _validate_receipt(payload)


def _validate_receipt(receipt: object) -> dict[str, Any]:
    if not isinstance(receipt, dict) or set(receipt) != {
        "version", "transport", "mailbox_id", "folder", "message_key", "rules"
    }:
        raise ValueError("invalid collection receipt shape")
    if receipt.get("version") != 1 or receipt.get("transport") not in {"imap", "jmap"}:
        raise ValueError("invalid collection receipt version or transport")
    for field_name in ("mailbox_id", "folder", "message_key"):
        if not isinstance(receipt.get(field_name), str) or not receipt[field_name]:
            raise ValueError("invalid collection receipt identity")
    rules = receipt.get("rules")
    if not isinstance(rules, list) or not rules:
        raise ValueError("invalid collection receipt rules")
    for rule in rules:
        if not isinstance(rule, dict) or set(rule) != {"id", "digest"}:
            raise ValueError("invalid collection rule reference")
        if not _RULE_TOKEN.fullmatch(str(rule.get("id") or "")):
            raise ValueError("invalid collection rule id")
        if not re.fullmatch(r"[0-9a-f]{16}", str(rule.get("digest") or "")):
            raise ValueError("invalid collection rule digest")
    return receipt


def _load_sidecar(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    with path.open(encoding="utf-8") as handle:
        return _validate_receipt(json.load(handle))


def _identity(receipt: Mapping[str, Any]) -> tuple[str, str, str, str]:
    return tuple(
        str(receipt[name])
        for name in ("transport", "mailbox_id", "folder", "message_key")
    )  # type: ignore[return-value]


def _merge_receipts(
    existing: dict[str, Any] | None, current: dict[str, Any]
) -> dict[str, Any]:
    if existing is None:
        return current
    if _identity(existing) != _identity(current):
        raise ValueError("collection receipt identity changed")
    merged = dict(current)
    merged["rules"] = sorted(
        {json.dumps(rule, sort_keys=True) for rule in existing["rules"] + current["rules"]}
    )
    merged["rules"] = [json.loads(rule) for rule in merged["rules"]]
    return merged


def _write_json_atomic(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def write_collection_receipt(
    eml_path: str | Path,
    context: ReceiptContext,
    rules: Iterable[Mapping[str, Any]],
) -> Path:
    """Atomically write or extend a sidecar for an already staged message."""
    path = sidecar_path(eml_path)
    payload = _merge_receipts(_load_sidecar(path), build_receipt(context, rules))
    _write_json_atomic(path, payload)
    return path


def stage_collection_receipt(
    staged_eml: str | Path,
    destination_eml: str | Path,
    context: ReceiptContext,
    rules: Iterable[Mapping[str, Any]],
) -> tuple[Path, Path]:
    """Stage a merged sidecar and return its atomic publish pair."""
    staged_path = sidecar_path(staged_eml)
    destination = sidecar_path(destination_eml)
    payload = _merge_receipts(
        _load_sidecar(destination), build_receipt(context, rules)
    )
    with staged_path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return staged_path, destination


def collection_refs_for_eml(eml_path: str | Path) -> list[dict[str, Any]]:
    """Return a validated canonical-meta reference list for one staged message."""
    receipt = _load_sidecar(sidecar_path(eml_path))
    return [receipt] if receipt is not None else []


def merge_receipt_into_meta(eml_path: str | Path, meta_path: str | Path) -> None:
    """Merge one staged receipt into an existing canonical email metadata file."""
    incoming = collection_refs_for_eml(eml_path)
    if not incoming:
        return
    path = Path(meta_path)
    with path.open(encoding="utf-8") as handle:
        meta = json.load(handle)
    if not isinstance(meta, dict):
        raise ValueError("canonical email metadata must be an object")
    raw_references = meta.get("collection_refs") or []
    if not isinstance(raw_references, list):
        raise ValueError("invalid canonical collection references")
    references = [_validate_receipt(reference) for reference in raw_references]
    incoming_receipt = incoming[0]
    for index, reference in enumerate(references):
        if _identity(reference) == _identity(incoming_receipt):
            references[index] = _merge_receipts(reference, incoming_receipt)
            break
    else:
        references.append(incoming_receipt)
    meta["collection_refs"] = sorted(references, key=_identity)
    _write_json_atomic(path, meta)


def rule_is_eligible(meta_path: str | Path, rule: Mapping[str, Any]) -> bool:
    """Require exact collection provenance only for explicit collection rules."""
    block = rule.get("match")
    uses_v2_match = isinstance(block, Mapping) and (
        "all" in block or "any" in block
    )
    if uses_v2_match:
        validate_rule(rule)
    collection = rule.get("collection", uses_v2_match)
    if collection is not True:
        return True
    rule_id = str(rule.get("id") or rule.get("name") or "")
    if not _RULE_TOKEN.fullmatch(rule_id):
        raise ValueError("invalid collection rule id")
    expected = {"id": rule_id, "digest": rule_digest(rule)}
    with Path(meta_path).open(encoding="utf-8") as handle:
        meta = json.load(handle)
    references = meta.get("collection_refs") if isinstance(meta, dict) else None
    if references is None:
        return False
    if not isinstance(references, list):
        raise ValueError("invalid canonical collection references")
    validated = [_validate_receipt(reference) for reference in references]
    return any(expected in reference["rules"] for reference in validated)


def _cmd_extract(args: argparse.Namespace) -> int:
    print(json.dumps(collection_refs_for_eml(args.eml), sort_keys=True))
    return 0


def _cmd_merge(args: argparse.Namespace) -> int:
    merge_receipt_into_meta(args.eml, args.meta)
    return 0


def _cmd_eligible(args: argparse.Namespace) -> int:
    rule = json.load(sys.stdin)
    if not isinstance(rule, dict):
        raise ValueError("collection rule must be an object")
    return 0 if rule_is_eligible(args.meta, rule) else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Canonical email collection receipts")
    subparsers = parser.add_subparsers(dest="command", required=True)
    extract = subparsers.add_parser("extract")
    extract.add_argument("--eml", required=True)
    merge = subparsers.add_parser("merge-meta")
    merge.add_argument("--eml", required=True)
    merge.add_argument("--meta", required=True)
    eligible = subparsers.add_parser("eligible")
    eligible.add_argument("--meta", required=True)
    args = parser.parse_args()
    try:
        handlers = {
            "extract": _cmd_extract,
            "merge-meta": _cmd_merge,
            "eligible": _cmd_eligible,
        }
        return handlers[args.command](args)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ERROR: collection receipt {type(exc).__name__}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
