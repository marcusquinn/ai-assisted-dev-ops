#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Provider-neutral canonical evidence identity and projection contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit

CONTRACT_VERSION = 1
SHA256 = re.compile(r"^[0-9a-f]{64}$")
IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{2,191}$")
FORBIDDEN_CREDENTIAL_KEYS = {
    "accesstoken", "apikey", "apitoken", "auth", "authentication",
    "authorization", "bearer", "bearertoken", "clientsecret", "cookie",
    "cookiejar", "cookies", "credential", "credentials", "csrftoken",
    "idtoken", "jwt", "oauthtoken", "passphrase", "password", "privatekey",
    "refreshtoken", "secret", "secretaccesskey", "sessioncookie",
    "sessiontoken", "setcookie", "token",
}
FORBIDDEN_CREDENTIAL_SUFFIXES = (
    "accesstoken", "apikey", "authorization", "clientsecret", "cookie",
    "password", "privatekey", "refreshtoken", "secretaccesskey", "sessiontoken",
)


class SourceContractError(ValueError):
    """Raised when evidence would violate the canonical source contract."""


@dataclass(frozen=True)
class SourceMetaInput:
    """Validated inputs for one canonical document source manifest."""

    source_id: str
    corpus_id: str
    connector_id: str
    source_uri: str
    content_sha256: str
    size_bytes: int
    kind: str
    sensitivity: str
    trust: str
    ingested_at: str
    blob_ref: str | None


def canonical_json(value: Any) -> str:
    """Serialize contract data deterministically."""
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def validate_identifier(value: str, field: str) -> str:
    """Validate an opaque or logical contract identifier."""
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
        raise SourceContractError(f"{field} must be a stable opaque identifier")
    return value


def validate_sha256(value: str) -> str:
    """Validate a lower-case SHA-256 digest."""
    if not isinstance(value, str) or not SHA256.fullmatch(value):
        raise SourceContractError("content_sha256 must be a lower-case SHA-256 digest")
    return value


def reject_credentials(value: Any) -> None:
    """Reject credential-shaped fields recursively before persistence."""
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = "".join(
                character for character in str(key).lower() if character.isalnum()
            )
            if normalized in FORBIDDEN_CREDENTIAL_KEYS or normalized.endswith(
                FORBIDDEN_CREDENTIAL_SUFFIXES
            ):
                raise SourceContractError("evidence contains forbidden credential material")
            reject_credentials(child)
    elif isinstance(value, list):
        for child in value:
            reject_credentials(child)


def canonical_evidence_id(
    corpus_id: str, connector_id: str, content_sha256: str
) -> str:
    """Return one replay-stable evidence ID scoped to a corpus and connector."""
    validate_identifier(corpus_id, "corpus_id")
    validate_identifier(connector_id, "connector_id")
    validate_sha256(content_sha256)
    return f"ev{CONTRACT_VERSION}:{corpus_id}:{connector_id}:sha256:{content_sha256}"


def projection_id(evidence_id: str, projection_kind: str, local_id: str) -> str:
    """Return a stable ID for derived state without creating another truth."""
    validate_identifier(projection_kind, "projection_kind")
    if not isinstance(evidence_id, str) or not evidence_id.startswith("ev1:"):
        raise SourceContractError("projection requires a canonical evidence_id")
    digest = hashlib.sha256(
        canonical_json([evidence_id, projection_kind, local_id]).encode("utf-8")
    ).hexdigest()
    return f"pr{CONTRACT_VERSION}:{digest}"


def sanitize_source_uri(source_uri: str, source_name: str) -> str:
    """Remove operator paths, credentials, query strings, and fragments."""
    parsed = urlsplit(source_uri)
    if parsed.scheme in ("http", "https"):
        hostname = parsed.hostname or ""
        port = f":{parsed.port}" if parsed.port is not None else ""
        return urlunsplit((parsed.scheme, f"{hostname}{port}", parsed.path, "", ""))
    return f"local:{Path(source_name).name}"


def build_source_meta(source: SourceMetaInput) -> dict[str, Any]:
    """Build a version-2 document source manifest with version-1 compatibility fields."""
    validate_identifier(source.source_id, "source_id")
    evidence_id = canonical_evidence_id(
        source.corpus_id, source.connector_id, source.content_sha256
    )
    if not isinstance(source.size_bytes, int) or source.size_bytes < 0:
        raise SourceContractError("size_bytes must be a non-negative integer")
    manifest = {
        "version": 2,
        "contract_version": CONTRACT_VERSION,
        "id": source.source_id,
        "corpus_id": source.corpus_id,
        "evidence_id": evidence_id,
        "authority": "raw",
        "plane": "_knowledge",
        "projection": False,
        "kind": source.kind,
        "source_uri": sanitize_source_uri(source.source_uri, source.source_id),
        "sha256": source.content_sha256,
        "content_sha256": source.content_sha256,
        "ingested_at": source.ingested_at,
        "ingested_by": "local-operator",
        "sensitivity": source.sensitivity,
        "trust": source.trust,
        "blob_path": source.blob_ref,
        "size_bytes": source.size_bytes,
        "connector": {"id": source.connector_id, "native_id": source.source_id},
        "provenance": {
            "captured_at": source.ingested_at,
            "source_uri": sanitize_source_uri(source.source_uri, source.source_id),
            "content_sha256": source.content_sha256,
        },
    }
    reject_credentials(manifest)
    return manifest


def validate_source_meta(manifest: dict[str, Any]) -> None:
    """Validate a canonical source manifest before another plane references it."""
    reject_credentials(manifest)
    if manifest.get("version") != 2 or manifest.get("contract_version") != CONTRACT_VERSION:
        raise SourceContractError("source manifest contract version is unsupported")
    if (
        manifest.get("authority") != "raw"
        or manifest.get("plane") != "_knowledge"
        or manifest.get("projection") is not False
    ):
        raise SourceContractError("source manifest does not describe canonical raw evidence")
    connector = manifest.get("connector")
    if not isinstance(connector, dict):
        raise SourceContractError("source manifest connector is missing")
    source_id = validate_identifier(str(manifest.get("id", "")), "source_id")
    if connector.get("native_id") != source_id:
        raise SourceContractError("source native identity was rebound")
    content_sha256 = manifest.get("content_sha256")
    if content_sha256 != manifest.get("sha256"):
        raise SourceContractError("source integrity digests conflict")
    expected = canonical_evidence_id(
        str(manifest.get("corpus_id", "")),
        str(connector.get("id", "")),
        str(content_sha256),
    )
    if manifest.get("evidence_id") != expected:
        raise SourceContractError("source evidence identity does not match provenance")
    source_uri = manifest.get("source_uri")
    if not isinstance(source_uri, str) or source_uri.startswith("file:"):
        raise SourceContractError("source manifest exposes an operator path")


def validate_pointer(pointer: dict[str, Any], expected_corpus_id: str) -> None:
    """Validate a case/project projection pointer against an authorized corpus."""
    reject_credentials(pointer)
    if pointer.get("contract_version") != CONTRACT_VERSION:
        raise SourceContractError("pointer contract version is unsupported")
    if pointer.get("corpus_id") != expected_corpus_id:
        raise SourceContractError("cross-corpus pointer requires an explicit grant")
    if pointer.get("authority") != "projection" or pointer.get("canonical_plane") != "_knowledge":
        raise SourceContractError("pointer must remain a non-authoritative knowledge projection")
    evidence_id = pointer.get("evidence_id")
    if not isinstance(evidence_id, str) or not evidence_id.startswith(
        f"ev{CONTRACT_VERSION}:{expected_corpus_id}:"
    ):
        raise SourceContractError("pointer evidence_id is outside the expected corpus")


def validate_checkpoint_transition(
    previous: dict[str, Any] | None,
    candidate: dict[str, Any],
    *,
    expected_connector_id: str,
    minimum_fencing_token: int,
) -> None:
    """Fail closed on identity rebinding, stale leases, or incomplete coverage."""
    reject_credentials(candidate)
    if candidate.get("connector_id") != expected_connector_id:
        raise SourceContractError("checkpoint connector identity was rebound")
    token = candidate.get("fencing_token")
    if isinstance(token, bool) or not isinstance(token, int) or token < minimum_fencing_token:
        raise SourceContractError("checkpoint fencing token is stale")
    if candidate.get("commit_state") != "committed":
        raise SourceContractError("checkpoint cannot advance before evidence commits")
    if previous is not None and previous.get("connector_id") != expected_connector_id:
        raise SourceContractError("stored checkpoint connector identity conflicts")


def _source_meta_command(args: argparse.Namespace) -> int:
    blob_ref = None if args.blob_ref == "null" else args.blob_ref
    result = build_source_meta(
        SourceMetaInput(
            source_id=args.source_id,
            corpus_id=args.corpus_id,
            connector_id=args.connector_id,
            source_uri=args.source_uri,
            content_sha256=args.sha256,
            size_bytes=args.size_bytes,
            kind=args.kind,
            sensitivity=args.sensitivity,
            trust=args.trust,
            ingested_at=args.ingested_at,
            blob_ref=blob_ref,
        )
    )
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def _validate_meta_command(args: argparse.Namespace) -> int:
    if args.meta.is_symlink() or not args.meta.is_file():
        raise SourceContractError("source manifest must be a regular non-symlink file")
    try:
        manifest = json.loads(args.meta.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SourceContractError("source manifest is not valid UTF-8 JSON") from error
    if not isinstance(manifest, dict):
        raise SourceContractError("source manifest root must be an object")
    validate_source_meta(manifest)
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    source = subparsers.add_parser("source-meta")
    source.add_argument("--source-id", required=True)
    source.add_argument("--corpus-id", required=True)
    source.add_argument("--connector-id", default="local-file")
    source.add_argument("--source-uri", required=True)
    source.add_argument("--sha256", required=True)
    source.add_argument("--size-bytes", required=True, type=int)
    source.add_argument("--kind", required=True)
    source.add_argument("--sensitivity", required=True)
    source.add_argument("--trust", required=True)
    source.add_argument("--ingested-at", required=True)
    source.add_argument("--blob-ref", default="null")
    validate = subparsers.add_parser("validate-meta")
    validate.add_argument("--meta", required=True, type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "source-meta":
            return _source_meta_command(args)
        if args.command == "validate-meta":
            return _validate_meta_command(args)
    except (OSError, SourceContractError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
