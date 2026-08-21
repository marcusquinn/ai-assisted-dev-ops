#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalized interchange contract for local domain-auction evidence."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Mapping
from urllib.parse import urlparse

SCHEMA_VERSION = 1
LISTING_STATUSES = frozenset({"active", "ended", "sold", "cancelled", "unknown"})
AUCTION_TYPES = frozenset({"auction", "buy_now", "closeout", "offer", "unknown"})
CSV_COLUMNS = tuple(
    (
        "provider provider_listing_id fqdn sld tld status auction_type "
        "current_price_micros current_price_currency bid_count start_time end_time "
        "source_url observed_at source_run_id payload_hash"
    ).split()
)
LISTING_FIELDS = CSV_COLUMNS + ("raw_json",)

_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
_CURRENCY_RE = re.compile(r"^[A-Z]{3}$")
_HASH_RE = re.compile(r"^[0-9a-f]{64}$")


class DomainOpportunityContractError(ValueError):
    """Raised when normalized evidence violates the interchange contract."""


@dataclass(frozen=True)
class KeywordMetric:
    """One source-labelled keyword metric for a known listing."""

    provider: str
    provider_listing_id: str
    source_run_id: str
    source: str
    metric_name: str
    value: str | int
    unit: str
    observed_at: str
    payload_hash: str


@dataclass(frozen=True)
class TrendSeries:
    """One source-labelled trend series for a known listing."""

    provider: str
    provider_listing_id: str
    source_run_id: str
    source: str
    query: str
    geography: str
    timeframe: str
    observed_at: str
    points: tuple[tuple[str, int], ...]
    payload_hash: str | None = None


@dataclass(frozen=True)
class CandidateScore:
    """One reproducible model score and its named components."""

    provider: str
    provider_listing_id: str
    source_run_id: str
    model: str
    score_micros: int
    observed_at: str
    components: Mapping[str, Mapping[str, Any]]
    payload_hash: str | None = None


def utc_timestamp(value: Any, field: str) -> str:
    """Return a canonical UTC ISO-8601 timestamp."""
    if not isinstance(value, str) or not value.strip():
        raise DomainOpportunityContractError(f"{field} must be a UTC timestamp")
    text = value.strip()
    if text.endswith("Z"):
        text = f"{text[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as exc:
        raise DomainOpportunityContractError(f"{field} must be a UTC timestamp") from exc
    if parsed.tzinfo is None:
        raise DomainOpportunityContractError(f"{field} must include a timezone")
    normalized = parsed.astimezone(timezone.utc)
    return normalized.isoformat(timespec="seconds").replace("+00:00", "Z")


def utc_now() -> str:
    """Return the current whole-second UTC timestamp."""
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def money_micros(value: Any, field: str = "current_price_micros") -> int:
    """Validate an integer number of currency micros without float coercion."""
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise DomainOpportunityContractError(f"{field} must be a non-negative integer")
    return value


def canonical_json(value: Any) -> str:
    """Serialize JSON evidence deterministically."""
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    except (TypeError, ValueError) as exc:
        raise DomainOpportunityContractError("raw_json must contain valid JSON data") from exc


def content_hash(value: Any) -> str:
    """Hash canonical JSON evidence for idempotent observation storage."""
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def _required_text(record: Mapping[str, Any], field: str) -> str:
    value = record.get(field)
    if not isinstance(value, str) or not value.strip():
        raise DomainOpportunityContractError(f"{field} must be a non-empty string")
    return value.strip()


def _domain_parts(record: Mapping[str, Any]) -> tuple[str, str, str]:
    raw_fqdn = _required_text(record, "fqdn").rstrip(".").lower()
    try:
        fqdn = raw_fqdn.encode("idna").decode("ascii")
    except UnicodeError as exc:
        raise DomainOpportunityContractError("fqdn is invalid") from exc
    if "." not in fqdn or len(fqdn) > 253:
        raise DomainOpportunityContractError("fqdn must contain an sld and tld")
    sld, tld = fqdn.split(".", 1)
    if not sld or not tld or any(not label for label in fqdn.split(".")):
        raise DomainOpportunityContractError("fqdn must contain valid labels")
    supplied_sld = _required_text(record, "sld").lower()
    supplied_tld = _required_text(record, "tld").lower().lstrip(".")
    if (supplied_sld, supplied_tld) != (sld, tld):
        raise DomainOpportunityContractError("sld and tld must match fqdn")
    return fqdn, sld, tld


def normalize_listing(record: Mapping[str, Any]) -> dict[str, Any]:
    """Validate and canonicalize one normalized listing observation."""
    if not isinstance(record, Mapping):
        raise DomainOpportunityContractError("listing record must be a JSON object")
    provider = _required_text(record, "provider").lower()
    listing_id = _required_text(record, "provider_listing_id")
    run_id = _required_text(record, "source_run_id")
    if not _NAME_RE.fullmatch(provider):
        raise DomainOpportunityContractError("provider contains unsupported characters")
    if len(listing_id) > 256 or len(run_id) > 256:
        raise DomainOpportunityContractError("listing and run identifiers must be at most 256 characters")
    fqdn, sld, tld = _domain_parts(record)
    status = _required_text(record, "status").lower()
    auction_type = _required_text(record, "auction_type").lower()
    if status not in LISTING_STATUSES:
        raise DomainOpportunityContractError("status is not supported")
    if auction_type not in AUCTION_TYPES:
        raise DomainOpportunityContractError("auction_type is not supported")
    currency = _required_text(record, "current_price_currency").upper()
    if not _CURRENCY_RE.fullmatch(currency):
        raise DomainOpportunityContractError("current_price_currency must be an ISO 4217 code")
    bid_count = record.get("bid_count")
    if isinstance(bid_count, bool) or not isinstance(bid_count, int) or bid_count < 0:
        raise DomainOpportunityContractError("bid_count must be a non-negative integer")
    source_url = _required_text(record, "source_url")
    parsed_url = urlparse(source_url)
    if parsed_url.scheme not in {"http", "https"} or not parsed_url.netloc:
        raise DomainOpportunityContractError("source_url must be an HTTP(S) URL")
    payload_hash = _required_text(record, "payload_hash").lower()
    if not _HASH_RE.fullmatch(payload_hash):
        raise DomainOpportunityContractError("payload_hash must be a lowercase SHA-256 digest")
    raw_json = record.get("raw_json")
    if isinstance(raw_json, str):
        try:
            raw_json = json.loads(raw_json)
        except json.JSONDecodeError as exc:
            raise DomainOpportunityContractError("raw_json must contain valid JSON data") from exc
    normalized: dict[str, Any] = {
        "provider": provider,
        "provider_listing_id": listing_id,
        "fqdn": fqdn,
        "sld": sld,
        "tld": tld,
        "status": status,
        "auction_type": auction_type,
        "current_price_micros": money_micros(record.get("current_price_micros")),
        "current_price_currency": currency,
        "bid_count": bid_count,
        "start_time": utc_timestamp(record.get("start_time"), "start_time"),
        "end_time": utc_timestamp(record.get("end_time"), "end_time"),
        "source_url": source_url,
        "observed_at": utc_timestamp(record.get("observed_at"), "observed_at"),
        "source_run_id": run_id,
        "payload_hash": payload_hash,
        "raw_json": None if raw_json is None else canonical_json(raw_json),
    }
    if normalized["end_time"] < normalized["start_time"]:
        raise DomainOpportunityContractError("end_time must not precede start_time")
    return normalized
