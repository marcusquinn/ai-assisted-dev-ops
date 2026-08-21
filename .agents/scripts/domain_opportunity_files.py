#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded, local-only auction inventory parsing and normalized-store writes."""

from __future__ import annotations

import csv
import gzip
import hashlib
import io
import json
import os
import stat
import tempfile
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

from domain_opportunity_contract import DomainOpportunityContractError, canonical_json, utc_now, utc_timestamp
from domain_opportunity_store import DomainOpportunityStore

MAX_COMPRESSED_BYTES = 32 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 64 * 1024 * 1024
MAX_COMPRESSION_RATIO = 100
PROFILE_VERSION = "auction-file-v1"


class DomainOpportunityFileError(ValueError):
    """Raised when a local inventory file is unsafe or incompatible."""


@dataclass(frozen=True)
class Profile:
    """One explicit provider header profile."""

    name: str
    fields: dict[str, tuple[str, ...]]
    required: frozenset[str]


PROFILES = {
    "godaddy": Profile(
        "godaddy",
        {
            "fqdn": ("domain name", "domain"),
            "provider_listing_id": ("auction id", "listing id", "id"),
            "current_price": ("current bid", "current price", "price"),
            "bid_count": ("bid count", "bids"),
            "start_time": ("start date", "start time"),
            "end_time": ("end date", "end time", "auction end"),
            "status": ("status",),
            "source_url": ("url", "listing url"),
        },
        frozenset({"fqdn", "current_price", "start_time", "end_time", "source_url"}),
    ),
    "snapnames": Profile(
        "snapnames",
        {
            "fqdn": ("domain", "domain name"),
            "provider_listing_id": ("auction id", "listing id", "id"),
            "current_price": ("current bid", "current price", "price"),
            "bid_count": ("bids", "bid count"),
            "start_time": ("auction start", "start date", "start time"),
            "end_time": ("auction end", "end date", "end time"),
            "status": ("status",),
            "source_url": ("url", "listing url"),
        },
        frozenset({"fqdn", "current_price", "start_time", "end_time", "source_url"}),
    ),
    "namejet": Profile(
        "namejet",
        {
            "fqdn": ("domain", "domain name"),
            "provider_listing_id": ("auction id", "listing id", "id"),
            "current_price": ("current bid", "current price", "price"),
            "bid_count": ("bids", "bid count"),
            "start_time": ("auction start", "start date", "start time"),
            "end_time": ("auction end", "end date", "end time"),
            "status": ("status",),
            "source_url": ("url", "listing url"),
        },
        frozenset({"fqdn", "current_price", "start_time", "end_time", "source_url"}),
    ),
    "generic": Profile(
        "generic",
        {name: (name.replace("_", " "), name) for name in (
            "provider_listing_id", "fqdn", "status", "auction_type", "current_price_micros",
            "current_price_currency", "bid_count", "start_time", "end_time", "source_url", "observed_at",
        )},
        frozenset({
            "fqdn", "status", "auction_type", "current_price_micros", "current_price_currency",
            "bid_count", "start_time", "end_time", "source_url", "observed_at",
        }),
    ),
}


def _header(value: str) -> str:
    return " ".join(value.strip().casefold().replace("_", " ").split())


def _read_limited(handle: Any, limit: int = MAX_UNCOMPRESSED_BYTES) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = handle.read(1024 * 1024)
        if not chunk:
            return b"".join(chunks)
        total += len(chunk)
        if total > limit:
            raise DomainOpportunityFileError("archive content exceeds uncompressed size limit")
        chunks.append(chunk)


def _regular_input(path: Path) -> None:
    if path.is_symlink() or not path.is_file():
        raise DomainOpportunityFileError("input must be a regular local file")
    if path.stat().st_size > MAX_COMPRESSED_BYTES:
        raise DomainOpportunityFileError("input exceeds compressed size limit")


def read_inventory(path: str | os.PathLike[str]) -> tuple[bytes, str]:
    """Read one bounded plain, gzip, or safe single-file ZIP inventory."""
    source = Path(path).expanduser()
    _regular_input(source)
    raw = source.read_bytes()
    if raw.startswith(b"\x1f\x8b"):
        with gzip.GzipFile(fileobj=io.BytesIO(raw)) as handle:
            content = _read_limited(handle)
        if len(content) > len(raw) * MAX_COMPRESSION_RATIO:
            raise DomainOpportunityFileError("gzip compression ratio exceeds limit")
        return content, "gzip"
    if raw.startswith(b"PK\x03\x04"):
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            entries = archive.infolist()
            if not entries:
                raise DomainOpportunityFileError("ZIP archive contains no files")
            candidates = []
            for entry in entries:
                member = PurePosixPath(entry.filename)
                if member.is_absolute() or ".." in member.parts or entry.is_dir():
                    raise DomainOpportunityFileError("ZIP archive contains an unsafe path")
                if entry.flag_bits & 0x1 or stat.S_ISLNK(entry.external_attr >> 16):
                    raise DomainOpportunityFileError("ZIP archive contains encrypted or linked content")
                if member.suffix.casefold() in {".zip", ".gz", ".tgz", ".bz2", ".xz"}:
                    raise DomainOpportunityFileError("nested archives are not supported")
                candidates.append(entry)
            if len(candidates) != 1:
                raise DomainOpportunityFileError("ZIP archive must contain exactly one inventory file")
            entry = candidates[0]
            if entry.file_size > MAX_UNCOMPRESSED_BYTES:
                raise DomainOpportunityFileError("archive content exceeds uncompressed size limit")
            if entry.compress_size and entry.file_size > entry.compress_size * MAX_COMPRESSION_RATIO:
                raise DomainOpportunityFileError("ZIP compression ratio exceeds limit")
            with archive.open(entry) as handle:
                return _read_limited(handle), "zip"
    if len(raw) > MAX_UNCOMPRESSED_BYTES:
        raise DomainOpportunityFileError("input exceeds uncompressed size limit")
    return raw, "plain"


def _mapping(profile: Profile, headers: Iterable[str]) -> tuple[dict[str, str], list[str], list[str]]:
    canonical = {_header(header): header for header in headers if header is not None}
    mapping: dict[str, str] = {}
    for field, aliases in profile.fields.items():
        for alias in aliases:
            source = canonical.get(_header(alias))
            if source is not None:
                mapping[field] = source
                break
    recognized = {_header(value) for value in mapping.values()}
    missing = sorted(profile.required - mapping.keys())
    unknown = sorted(header for header in canonical if header not in recognized)
    return mapping, missing, unknown


def _decode_rows(content: bytes, *, allow_jsonl: bool = False) -> tuple[list[str], list[dict[str, str]]]:
    try:
        text = content.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise DomainOpportunityFileError("input must be UTF-8 text") from exc
    if allow_jsonl and text.lstrip().startswith("{"):
        rows: list[dict[str, str]] = []
        headers: set[str] = set()
        for line_number, line in enumerate(text.splitlines(), start=1):
            if not line.strip():
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError as exc:
                raise DomainOpportunityFileError(f"JSONL record {line_number} is invalid") from exc
            if not isinstance(item, dict) or any(not isinstance(key, str) for key in item):
                raise DomainOpportunityFileError(f"JSONL record {line_number} must be an object")
            headers.update(item)
            rows.append({key: "" if value is None else str(value) for key, value in item.items()})
        if not rows:
            raise DomainOpportunityFileError("input contains no JSONL records")
        return sorted(headers), rows
    reader = csv.DictReader(io.StringIO(text))
    if not reader.fieldnames:
        raise DomainOpportunityFileError("input has no CSV header")
    headers = [header for header in reader.fieldnames if header is not None]
    if len(headers) != len(set(headers)):
        raise DomainOpportunityFileError("input has duplicate CSV headers")
    return headers, list(reader)


def inspect(path: str | os.PathLike[str], provider: str) -> dict[str, Any]:
    """Return parser diagnostics without mutating a store."""
    profile = _profile(provider)
    content, archive_format = read_inventory(path)
    headers, rows = _decode_rows(content, allow_jsonl=profile.name == "generic")
    _, missing, unknown = _mapping(profile, headers)
    return {
        "archive_format": archive_format,
        "content_sha256": hashlib.sha256(content).hexdigest(),
        "headers": headers,
        "missing_required_headers": missing,
        "provider": profile.name,
        "row_count": len(rows),
        "unknown_headers": unknown,
    }


def _profile(provider: str) -> Profile:
    normalized = provider.strip().casefold()
    if normalized not in PROFILES:
        raise DomainOpportunityFileError("provider must be godaddy, snapnames, namejet, or generic")
    return PROFILES[normalized]


def _price_micros(value: str) -> int:
    cleaned = value.strip().replace(",", "").replace("$", "")
    try:
        amount = Decimal(cleaned)
    except InvalidOperation as exc:
        raise DomainOpportunityFileError("price is invalid") from exc
    if not amount.is_finite() or amount < 0 or amount.as_tuple().exponent < -6:
        raise DomainOpportunityFileError("price is invalid")
    return int(amount * Decimal(1_000_000))


def _text(row: dict[str, str], mapping: dict[str, str], field: str, default: str = "") -> str:
    source = mapping.get(field)
    return (row.get(source, default) if source else default).strip()


def _normalized_row(
    row: dict[str, str], profile: Profile, mapping: dict[str, str], source_hash: str, line_number: int, observed_at: str
) -> dict[str, Any]:
    if profile.name == "generic":
        record = {field: _text(row, mapping, field) for field in mapping}
        record["provider"] = "generic"
        record["current_price_micros"] = int(record["current_price_micros"])
        record["bid_count"] = int(record["bid_count"])
    else:
        fqdn = _text(row, mapping, "fqdn").rstrip(".").lower()
        if "." not in fqdn:
            raise DomainOpportunityFileError("domain must contain a registrable suffix")
        sld, tld = fqdn.split(".", 1)
        end_time = utc_timestamp(_text(row, mapping, "end_time"), "end_time")
        provider_listing_id = _text(row, mapping, "provider_listing_id")
        if not provider_listing_id:
            provider_listing_id = hashlib.sha256(f"{profile.name}\0{fqdn}\0{end_time}".encode()).hexdigest()[:32]
        record = {
            "provider": profile.name,
            "provider_listing_id": provider_listing_id,
            "fqdn": fqdn,
            "sld": sld,
            "tld": tld,
            "status": _text(row, mapping, "status", "active").casefold() or "active",
            "auction_type": "auction",
            "current_price_micros": _price_micros(_text(row, mapping, "current_price")),
            "current_price_currency": "USD",
            "bid_count": int(_text(row, mapping, "bid_count", "0") or "0"),
            "start_time": _text(row, mapping, "start_time"),
            "end_time": end_time,
            "source_url": _text(row, mapping, "source_url"),
            "observed_at": observed_at,
        }
    fqdn = record["fqdn"].rstrip(".").lower()
    if "." not in fqdn:
        raise DomainOpportunityFileError("domain must contain a registrable suffix")
    sld, tld = fqdn.split(".", 1)
    record["fqdn"], record["sld"], record["tld"] = fqdn, sld, tld
    if not record.get("provider_listing_id"):
        record["provider_listing_id"] = hashlib.sha256(
            f"{record['provider']}\0{fqdn}\0{record['end_time']}".encode()
        ).hexdigest()[:32]
    record["source_run_id"] = f"{record['provider']}-{source_hash}"
    record["raw_json"] = {"profile": PROFILE_VERSION, "row": row}
    record["payload_hash"] = hashlib.sha256(canonical_json(record["raw_json"]).encode()).hexdigest()
    return record


def _write_rejects(path: str | os.PathLike[str], rejects: list[dict[str, Any]]) -> None:
    destination = Path(path).expanduser()
    if destination.exists() and destination.is_symlink():
        raise DomainOpportunityFileError("rejects output must not be a symbolic link")
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            for reject in rejects:
                handle.write(canonical_json(reject) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def import_inventory(
    path: str | os.PathLike[str], provider: str, database: str | os.PathLike[str], *, rejects_path: str | None = None,
    observed_at: str | None = None,
) -> dict[str, Any]:
    """Import valid rows atomically, retaining only sanitized optional rejects."""
    profile = _profile(provider)
    content, archive_format = read_inventory(path)
    source_hash = hashlib.sha256(content).hexdigest()
    headers, rows = _decode_rows(content, allow_jsonl=profile.name == "generic")
    mapping, missing, unknown = _mapping(profile, headers)
    if missing:
        raise DomainOpportunityFileError(f"missing required headers: {', '.join(missing)}")
    timestamp = utc_timestamp(observed_at, "observed_at") if observed_at else utc_now()
    records: list[dict[str, Any]] = []
    rejects: list[dict[str, Any]] = []
    for line_number, row in enumerate(rows, start=2):
        try:
            records.append(_normalized_row(row, profile, mapping, source_hash, line_number, timestamp))
        except (DomainOpportunityFileError, DomainOpportunityContractError, ValueError) as exc:
            rejects.append({"line": line_number, "reason": str(exc)[:256]})
    if not records:
        raise DomainOpportunityFileError("input contains no valid listing records")
    run_id = records[0]["source_run_id"]
    with DomainOpportunityStore(database, initialize=True) as store:
        with store.transaction():
            store.begin_source_run(run_id, profile.name, started_at=timestamp)
            inserted = sum(store.upsert_listing_observation(record) for record in records)
            store.complete_source_run(run_id, len(records))
    if rejects_path is not None:
        _write_rejects(rejects_path, rejects)
    return {
        "archive_format": archive_format,
        "content_sha256": source_hash,
        "imported": inserted,
        "provider": profile.name,
        "records": len(records),
        "rejected": len(rejects),
        "unknown_headers": unknown,
    }
