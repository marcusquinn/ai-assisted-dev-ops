#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate and privately persist provider-neutral search observations."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from _reach_observation_storage import (
    ObservationStorageError,
    copy_evidence as _copy_evidence,
    ensure_private_child_directory as _ensure_private_child_directory,
    load_json_object as _load_json_object,
    observation_id_key as _observation_id_key,
    open_private_child_directory as _open_private_child_directory,
    open_private_directory as _open_private_directory,
    read_private_file as _read_private_file,
    write_record as _write_record,
)
from knowledge_source_contract import SourceContractError, reject_credentials

SCHEMA_VERSION = 1
MAX_INPUT_BYTES = 64 * 1024
MAX_EVIDENCE_BYTES = 25 * 1024 * 1024
PROFILE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
COUNTRY = re.compile(r"^[A-Z]{2}$")
LOCALE = re.compile(r"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$")
TIMEZONE = re.compile(r"^(?:UTC|[A-Za-z0-9._+-]+(?:/[A-Za-z0-9._+-]+)+)$")
ENGINES = {"brave", "google", "bing"}
METHODS = {"browser", "search_api"}
SURFACES = {"web", "news", "images", "videos", "local", "maps", "shopping"}
DEVICES = {"desktop", "mobile", "tablet"}
AUTHORIZATION_BASES = {"public_data", "owned_account", "client_approved"}
STORAGE_AUTHORIZATION_BASES = {
    "personal_use",
    "provider_terms",
    "provider_permission",
}
BROWSERS = {"brave", "chromium", "edge", "chrome", "firefox", "mullvad"}
EGRESS_CLASSES = {"direct", "vpn", "socks5", "residential", "isp", "mobile"}
USAGE_SCOPES = {"public", "account"}
SESSION_MODES = {"stable", "rotating"}
MEDIA_SUFFIXES = {
    "application/json": "json",
    "text/html": "html",
    "text/plain": "txt",
}
REQUIRED_FIELDS = {
    "schema_version",
    "evidence_class",
    "engine",
    "collection_method",
    "query",
    "observed_at",
    "egress_profile",
    "device_class",
    "signed_in",
    "authorization_basis",
    "result_surface",
    "evidence_path",
    "evidence_media_type",
}
OPTIONAL_FIELDS = {"notes", "storage_authorization_basis"}


class ObservationError(ValueError):
    """Raised when an observation violates the private evidence contract."""


@dataclass(frozen=True)
class EgressContext:
    """Validated location and network metadata without credential references."""

    profile_name: str
    browser_class: str
    egress_class: str
    usage_scope: str
    session_mode: str
    country: str
    region: str
    city: str
    timezone: str
    locale: str


@dataclass(frozen=True)
class PersistenceContext:
    """Validated inputs and pinned storage for one immutable observation."""

    observation: dict[str, Any]
    egress: EgressContext
    evidence_payload: bytes
    evidence_hash: str
    evidence_fd: int
    records_fd: int
    observation_key: bytes


def _canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def _required_text(value: Any, field: str, maximum: int = 2048) -> str:
    if not isinstance(value, str):
        raise ObservationError(f"{field} must be text")
    normalized = value.strip()
    if not normalized or len(normalized) > maximum:
        raise ObservationError(f"{field} length is invalid")
    if any(ord(character) < 32 for character in normalized):
        raise ObservationError(f"{field} must be single-line text")
    return normalized


def _optional_text(value: Any, field: str, maximum: int = 240) -> str:
    if value is None or value == "":
        return ""
    return _required_text(value, field, maximum)


def _choice(value: Any, field: str, choices: set[str]) -> str:
    normalized = _required_text(value, field, 64)
    if normalized not in choices:
        raise ObservationError(f"{field} is unsupported")
    return normalized


def _observation_time(value: Any) -> str:
    text = _required_text(value, "observed_at", 64)
    try:
        parsed = dt.datetime.fromisoformat(text[:-1] + "+00:00" if text.endswith("Z") else text)
    except ValueError as error:
        raise ObservationError("observed_at must be an ISO-8601 timestamp") from error
    if parsed.tzinfo is None:
        raise ObservationError("observed_at requires a timezone")
    normalized = parsed.astimezone(dt.timezone.utc).replace(microsecond=0)
    if normalized > dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=5):
        raise ObservationError("observed_at cannot be in the future")
    return normalized.isoformat().replace("+00:00", "Z")


def _validated_observation(document: dict[str, Any]) -> dict[str, Any]:
    unknown = set(document) - REQUIRED_FIELDS - OPTIONAL_FIELDS
    missing = REQUIRED_FIELDS - set(document)
    if unknown or missing:
        raise ObservationError("observation fields do not match schema version 1")
    version = document["schema_version"]
    if isinstance(version, bool) or version != SCHEMA_VERSION:
        raise ObservationError("observation schema_version is unsupported")
    if document["evidence_class"] != "search_result_observation":
        raise ObservationError("evidence_class must be search_result_observation")
    signed_in = document["signed_in"]
    if not isinstance(signed_in, bool):
        raise ObservationError("signed_in must be boolean")
    media_type = _choice(
        document["evidence_media_type"], "evidence_media_type", set(MEDIA_SUFFIXES)
    )
    storage_authorization_basis = ""
    if "storage_authorization_basis" in document:
        storage_authorization_basis = _choice(
            document["storage_authorization_basis"],
            "storage_authorization_basis",
            STORAGE_AUTHORIZATION_BASES,
        )
    validated = {
        "schema_version": SCHEMA_VERSION,
        "evidence_class": "search_result_observation",
        "engine": _choice(document["engine"], "engine", ENGINES),
        "collection_method": _choice(
            document["collection_method"], "collection_method", METHODS
        ),
        "query": _required_text(document["query"], "query"),
        "observed_at": _observation_time(document["observed_at"]),
        "egress_profile": _required_text(
            document["egress_profile"], "egress_profile", 64
        ),
        "device_class": _choice(document["device_class"], "device_class", DEVICES),
        "signed_in": signed_in,
        "authorization_basis": _choice(
            document["authorization_basis"],
            "authorization_basis",
            AUTHORIZATION_BASES,
        ),
        "result_surface": _choice(
            document["result_surface"], "result_surface", SURFACES
        ),
        "evidence_path": _required_text(
            document["evidence_path"], "evidence_path", 4096
        ),
        "evidence_media_type": media_type,
        "notes": _optional_text(document.get("notes"), "notes"),
    }
    if storage_authorization_basis:
        validated["storage_authorization_basis"] = storage_authorization_basis
    return validated


def _egress_text(document: dict[str, Any], field: str, maximum: int = 120) -> str:
    return _required_text(document.get(field), f"egress {field}", maximum)


def _egress_choice(document: dict[str, Any], field: str, choices: set[str]) -> str:
    return _choice(document.get(field), f"egress {field}", choices)


def _load_egress(workspace_fd: int, profile_name: str) -> EgressContext:
    if not PROFILE_NAME.fullmatch(profile_name):
        raise ObservationError("egress_profile is invalid")
    egress_fd = _open_private_child_directory(
        workspace_fd, "egress-profiles", "egress profile storage"
    )
    try:
        document = _load_json_object(
            f"{profile_name}.json",
            "egress profile",
            MAX_INPUT_BYTES,
            egress_fd,
        )
    finally:
        os.close(egress_fd)
    if document.get("schema_version") != SCHEMA_VERSION:
        raise ObservationError("egress profile schema is unsupported")
    if document.get("profile_name") != profile_name:
        raise ObservationError("egress profile identity does not match")
    country = _egress_text(document, "country", 2)
    timezone = _egress_text(document, "timezone", 120)
    locale = _egress_text(document, "locale", 64)
    if not COUNTRY.fullmatch(country):
        raise ObservationError("egress country is invalid")
    if not TIMEZONE.fullmatch(timezone):
        raise ObservationError("egress timezone is invalid")
    if not LOCALE.fullmatch(locale):
        raise ObservationError("egress locale is invalid")
    return EgressContext(
        profile_name=profile_name,
        browser_class=_egress_choice(document, "browser_class", BROWSERS),
        egress_class=_egress_choice(document, "egress_class", EGRESS_CLASSES),
        usage_scope=_egress_choice(document, "usage_scope", USAGE_SCOPES),
        session_mode=_egress_choice(document, "session_mode", SESSION_MODES),
        country=country,
        region=_optional_text(document.get("region"), "egress region", 120),
        city=_optional_text(document.get("city"), "egress city", 120),
        timezone=timezone,
        locale=locale,
    )


def _validate_policy(observation: dict[str, Any], egress: EgressContext) -> None:
    if observation["signed_in"]:
        if observation["authorization_basis"] == "public_data":
            raise ObservationError("signed-in observations require account authorization")
        if egress.usage_scope != "account" or egress.session_mode != "stable":
            raise ObservationError("signed-in observations require stable account egress")
        if observation["collection_method"] != "browser":
            raise ObservationError("signed-in observations require browser collection")
    if observation["collection_method"] == "search_api" and observation["engine"] != "brave":
        raise ObservationError("search_api observations currently support Brave only")
    if observation["collection_method"] == "search_api":
        if not observation.get("storage_authorization_basis"):
            raise ObservationError(
                "search_api observations require storage_authorization_basis"
            )
    elif observation.get("storage_authorization_basis"):
        raise ObservationError(
            "storage_authorization_basis applies only to search_api observations"
        )


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _validate_evidence(path: Path, media_type: str) -> tuple[bytes, str]:
    payload = _read_private_file(path, "evidence file", MAX_EVIDENCE_BYTES)
    if media_type == "application/json":
        try:
            parsed = json.loads(payload.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise ObservationError("JSON evidence must be valid UTF-8 JSON") from error
        try:
            reject_credentials(parsed)
        except SourceContractError as error:
            raise ObservationError(
                "JSON evidence contains credential-shaped fields"
            ) from error
    return payload, _sha256(payload)


def _evidence_path(input_path: Path, value: str) -> Path:
    candidate = Path(value).expanduser()
    return candidate if candidate.is_absolute() else input_path.parent / candidate


def _record(input_path: Path, workspace: Path) -> dict[str, Any]:
    observation = _validated_observation(
        _load_json_object(input_path, "observation input", MAX_INPUT_BYTES)
    )
    workspace_fd = _open_private_directory(workspace, "Reach workspace")
    observations_fd = -1
    evidence_fd = -1
    records_fd = -1
    try:
        egress = _load_egress(workspace_fd, observation["egress_profile"])
        _validate_policy(observation, egress)
        evidence_path = _evidence_path(input_path, observation.pop("evidence_path"))
        evidence_payload, evidence_hash = _validate_evidence(
            evidence_path, observation["evidence_media_type"]
        )
        observations_fd = _ensure_private_child_directory(
            workspace_fd, "observations", "observation storage"
        )
        evidence_fd = _ensure_private_child_directory(
            observations_fd, "evidence", "observation evidence storage"
        )
        records_fd = _ensure_private_child_directory(
            observations_fd, "records", "observation record storage"
        )
        observation_key = _observation_id_key(workspace_fd)
        return _persist_observation(
            PersistenceContext(
                observation,
                egress,
                evidence_payload,
                evidence_hash,
                evidence_fd,
                records_fd,
                observation_key,
            )
        )
    finally:
        for descriptor in (records_fd, evidence_fd, observations_fd, workspace_fd):
            if descriptor >= 0:
                os.close(descriptor)


def _persist_observation(context: PersistenceContext) -> dict[str, Any]:
    observation = context.observation
    egress = context.egress
    evidence_payload = context.evidence_payload
    evidence_hash = context.evidence_hash
    environment = {
        "egress_profile_name": egress.profile_name,
        "egress_profile_hash": hashlib.sha256(egress.profile_name.encode()).hexdigest()[:16],
        "browser_class": egress.browser_class,
        "egress_class": egress.egress_class,
        "usage_scope": egress.usage_scope,
        "session_mode": egress.session_mode,
        "country": egress.country,
        "region": egress.region,
        "city": egress.city,
        "timezone": egress.timezone,
        "locale": egress.locale,
        "egress_claim_status": "configured_unverified",
    }
    suffix = MEDIA_SUFFIXES[observation["evidence_media_type"]]
    storage_ref = f"evidence/{evidence_hash}.{suffix}"
    record_base = {
        **observation,
        "environment": environment,
        "evidence": {
            "sha256": evidence_hash,
            "bytes": len(evidence_payload),
            "media_type": observation["evidence_media_type"],
            "storage_ref": storage_ref,
        },
        "sensitivity": "private",
        "trust": "observed_unverified",
    }
    observation_id = "obs-" + hmac.new(
        context.observation_key, _canonical_bytes(record_base), hashlib.sha256
    ).hexdigest()[:24]
    record = {
        **record_base,
        "observation_id": observation_id,
        "recorded_at": dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
    }
    _copy_evidence(
        evidence_payload,
        context.evidence_fd,
        f"{evidence_hash}.{suffix}",
        evidence_hash,
        MAX_EVIDENCE_BYTES,
    )
    status = _write_record(
        context.records_fd, f"{observation_id}.json", record, MAX_INPUT_BYTES
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "observation_id": observation_id,
        "record_status": status,
        "evidence_class": observation["evidence_class"],
        "engine": observation["engine"],
        "collection_method": observation["collection_method"],
        "observed_at": observation["observed_at"],
        "browser_class": egress.browser_class,
        "egress_class": egress.egress_class,
        "country": egress.country,
        "signed_in": observation["signed_in"],
        "storage_authorization_basis": observation.get(
            "storage_authorization_basis", ""
        ),
        "evidence_sha256": evidence_hash,
        "egress_claim_status": "configured_unverified",
        "query_printed": False,
        "private_path_printed": False,
        "contacted_targets": False,
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    record = subparsers.add_parser("record")
    record.add_argument("--input", required=True, type=Path)
    record.add_argument("--workspace", required=True, type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "record":
            print(json.dumps(_record(args.input, args.workspace), sort_keys=True))
            return 0
    except (ObservationError, ObservationStorageError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except OSError:
        print("ERROR: observation persistence failed", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
