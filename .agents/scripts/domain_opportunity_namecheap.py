#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only Namecheap Market sale ingestion for domain-opportunity evidence."""

from __future__ import annotations

import hashlib
import json
import os
import time
import uuid
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

from domain_opportunity_contract import KeywordMetric, content_hash, utc_now
from domain_opportunity_store import DomainOpportunityStore, DomainOpportunityStoreError

API_BASE = "https://aftermarketapi.namecheap.com/client/api"
PROVIDER = "namecheap-market"
MAX_PAGES = 100
MAX_ATTEMPTS = 3
REQUEST_TIMEOUT_SECONDS = 20
SALE_FIELDS = (
    "id", "name", "tld", "status", "saleType", "price", "startPrice", "renewPrice",
    "bidCount", "minBid", "startDate", "endDate", "endDateExtendedMs", "createdDate",
    "soldDate", "registeredDate", "auctionType", "ahrefsDomainRating", "alexaRanking",
    "umbrellaRanking", "backlinksCount", "cloudflareRanking", "estibotValue", "goDaddyValue",
    "extensionsTaken", "keywordSearchCount", "keywordSearchQuery", "lastSoldPrice", "lastSoldYear",
)


class NamecheapMarketError(RuntimeError):
    """Classified, credential-safe ingestion failure."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class SyncResult:
    """Deterministic sanitized sync counters."""

    inserted: int
    records: int
    skipped: int
    source_run_id: str

    def as_dict(self) -> dict[str, int | str]:
        """Return stable CLI-safe reporting data."""
        return {
            "inserted": self.inserted,
            "records": self.records,
            "skipped": self.skipped,
            "source_run_id": self.source_run_id,
        }


Transport = Callable[[str | None], tuple[int, Mapping[str, Any], float | None]]


@dataclass(frozen=True)
class SyncOptions:
    """Explicit optional inputs for a deterministic provider sync."""

    fixture: Path | None = None
    max_pages: int = MAX_PAGES
    transport: Transport | None = None
    sleep: Callable[[float], None] = time.sleep


def _require(value: bool, code: str) -> None:
    """Raise a classified error when a provider invariant is not satisfied."""
    if not value:
        raise NamecheapMarketError(code)


def _token() -> str:
    """Read the opt-in bearer token only when a live request is needed."""
    token = os.environ.get("NAMECHEAP_MARKET_API_TOKEN", "").strip()
    _require(bool(token), "authentication_required")
    return token


def _response_payload(handle: Any) -> Mapping[str, Any]:
    """Decode one JSON response without exposing its contents on failure."""
    try:
        payload = json.loads(handle.read().decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise NamecheapMarketError("malformed_response") from exc
    _require(isinstance(payload, Mapping), "malformed_response")
    return payload


def live_transport(cursor: str | None) -> tuple[int, Mapping[str, Any], float | None]:
    """Fetch only the documented read-only sales endpoint."""
    query: dict[str, str] = {"tld": "com"}
    if cursor:
        query["cursor"] = cursor
    request = Request(
        f"{API_BASE}/sales?{urlencode(query)}",
        headers={"Accept": "application/json", "Authorization": f"Bearer {_token()}"},
        method="GET",
    )
    try:
        with urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:  # nosec B310 -- fixed official HTTPS API
            status = int(response.status)
            retry_after = response.headers.get("Retry-After")
            return status, _response_payload(response), float(retry_after) if retry_after else None
    except HTTPError as exc:
        retry_after = exc.headers.get("Retry-After") if exc.headers else None
        return int(exc.code), {}, float(retry_after) if retry_after and retry_after.isdigit() else None
    except (TimeoutError, URLError, OSError) as exc:
        raise NamecheapMarketError("transient_request_failure") from exc


def _valid_cursor(has_more: bool, next_cursor: Any) -> bool:
    """Check the documented cursor shape without a compound decision tree."""
    return (not has_more) if next_cursor is None else isinstance(next_cursor, str) and bool(next_cursor)


def _valid_page(payload: Mapping[str, Any]) -> tuple[list[Mapping[str, Any]], bool, str | None]:
    """Validate the bounded portion of the documented cursor response."""
    items = payload.get("items")
    has_more = payload.get("hasMore")
    next_cursor = payload.get("nextCursor")
    _require(isinstance(items, list), "malformed_response")
    _require(isinstance(has_more, bool), "malformed_response")
    _require(_valid_cursor(has_more, next_cursor), "malformed_response")
    _require(all(isinstance(item, Mapping) for item in items), "malformed_response")
    return list(items), has_more, next_cursor


def _retry_delay(retry_after: float | None, attempt: int) -> float:
    """Return a bounded provider-safe retry delay."""
    return min(max(retry_after or float(2**attempt), 0.0), 30.0)


def _response_outcome(status: int, payload: Mapping[str, Any], retry_after: float | None, attempt: int) -> tuple[Mapping[str, Any] | None, float]:
    """Classify one HTTP response as success, retry, or a safe terminal failure."""
    error_code = {401: "authentication_failed", 403: "authentication_failed", 400: "request_validation_failed", 422: "request_validation_failed"}.get(status)
    if error_code:
        raise NamecheapMarketError(error_code)
    if 200 <= status < 300:
        return payload, 0.0
    if status != 429 and not 500 <= status < 600:
        raise NamecheapMarketError("unexpected_response_status")
    if attempt + 1 == MAX_ATTEMPTS:
        raise NamecheapMarketError("rate_limited" if status == 429 else "transient_server_failure")
    return None, _retry_delay(retry_after, attempt)


def _request_attempt(transport: Transport, cursor: str | None, attempt: int) -> tuple[Mapping[str, Any] | None, float]:
    """Execute one transport attempt without leaking provider response details."""
    try:
        return _response_outcome(*transport(cursor), attempt)
    except NamecheapMarketError:
        raise
    except Exception as exc:
        if attempt + 1 == MAX_ATTEMPTS:
            raise NamecheapMarketError("transient_request_failure") from exc
        return None, float(2**attempt)


def _request_page(transport: Transport, cursor: str | None, sleep: Callable[[float], None]) -> Mapping[str, Any]:
    """Fetch one page with bounded retry and sanitized error classification."""
    for attempt in range(MAX_ATTEMPTS):
        payload, delay = _request_attempt(transport, cursor, attempt)
        if payload is not None:
            return payload
        sleep(delay)
    raise NamecheapMarketError("transient_request_failure")


def _advance_cursor(has_more: bool, next_cursor: str | None, seen_cursors: set[str]) -> str | None:
    """Return the next cursor or fail before repeating a provider page."""
    if not has_more:
        return None
    _require(next_cursor not in seen_cursors, "repeated_cursor")
    seen_cursors.add(next_cursor or "")
    return next_cursor


def iter_sales(transport: Transport, *, max_pages: int = MAX_PAGES, sleep: Callable[[float], None] = time.sleep) -> Iterator[Mapping[str, Any]]:
    """Yield validated pages with bounded pagination and retry behavior."""
    _require(max_pages >= 1, "invalid_page_limit")
    cursor: str | None = None
    seen_cursors: set[str] = set()
    for _ in range(max_pages):
        items, has_more, next_cursor = _valid_page(_request_page(transport, cursor, sleep))
        yield {"items": items, "has_more": has_more, "next_cursor": next_cursor}
        cursor = _advance_cursor(has_more, next_cursor, seen_cursors)
        if cursor is None:
            return
    raise NamecheapMarketError("page_limit_reached")


def _price_micros(value: Any) -> int:
    """Convert documented dollar values to exact integer micros."""
    _require(not isinstance(value, bool) and value is not None, "malformed_sale")
    try:
        decimal = Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise NamecheapMarketError("malformed_sale") from exc
    _require(decimal.is_finite() and decimal >= 0, "malformed_sale")
    return int((decimal * Decimal("1000000")).quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def map_sale(sale: Mapping[str, Any], *, observed_at: str, source_run_id: str) -> dict[str, Any]:
    """Map a documented active .com sale while retaining all known raw fields."""
    raw = dict(sale)
    for field in SALE_FIELDS:
        raw.setdefault(field, None)
    sale_id = raw["id"]
    name = raw["name"]
    tld = raw["tld"]
    _require(isinstance(sale_id, str) and bool(sale_id), "malformed_sale")
    _require(isinstance(name, str) and bool(name), "malformed_sale")
    _require(isinstance(tld, str) and tld.lower().lstrip(".") == "com", "malformed_sale")
    fqdn = name.rstrip(".").lower()
    _require(fqdn.endswith(".com") and fqdn.count(".") == 1, "malformed_sale")
    _require(raw["status"] == "active" and raw["saleType"] == "auction", "unsupported_sale")
    _require(isinstance(raw["bidCount"], int) and not isinstance(raw["bidCount"], bool) and raw["bidCount"] >= 0, "malformed_sale")
    _require(isinstance(raw["startDate"], str) and isinstance(raw["endDate"], str), "malformed_sale")
    return {
        "provider": PROVIDER,
        "provider_listing_id": sale_id,
        "fqdn": fqdn,
        "sld": fqdn[:-4],
        "tld": "com",
        "status": "active",
        "auction_type": "auction",
        "current_price_micros": _price_micros(raw["price"]),
        "current_price_currency": "USD",
        "bid_count": raw["bidCount"],
        "start_time": raw["startDate"],
        "end_time": raw["endDate"],
        "source_url": f"{API_BASE}/sales/{quote(sale_id, safe='')}",
        "observed_at": observed_at,
        "source_run_id": source_run_id,
        "payload_hash": content_hash(raw),
        "raw_json": raw,
    }


def _fixture_transport(path: Path) -> Transport:
    """Create a no-network page transport from a redacted fixture document."""
    _require(not path.is_symlink() and path.is_file(), "invalid_fixture")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise NamecheapMarketError("invalid_fixture") from exc
    pages = document.get("pages") if isinstance(document, Mapping) else None
    _require(isinstance(pages, list) and all(isinstance(page, Mapping) for page in pages), "invalid_fixture")
    index = 0

    def transport(cursor: str | None) -> tuple[int, Mapping[str, Any], float | None]:
        nonlocal index
        _require(index < len(pages), "invalid_fixture")
        page = pages[index]
        expected_cursor = page.get("requestCursor")
        _require(expected_cursor == cursor, "invalid_fixture")
        index += 1
        return 200, page, None

    return transport


def _source_run_id(options: SyncOptions) -> str:
    """Create a fixture-stable or live-unique run identity."""
    if options.fixture is None:
        return f"namecheap-live-{uuid.uuid4()}"
    return f"namecheap-fixture-{hashlib.sha256(options.fixture.read_bytes()).hexdigest()[:24]}"


def _map_page(items: list[Mapping[str, Any]], observed_at: str, source_run_id: str) -> tuple[list[dict[str, Any]], int]:
    """Keep valid active sales while isolating malformed provider records."""
    records: list[dict[str, Any]] = []
    skipped = 0
    for sale in items:
        try:
            records.append(map_sale(sale, observed_at=observed_at, source_run_id=source_run_id))
        except NamecheapMarketError:
            skipped += 1
    return records, skipped


def _collect_records(transport: Transport, options: SyncOptions, observed_at: str, source_run_id: str) -> tuple[list[dict[str, Any]], int]:
    """Retrieve and map every bounded provider page before any observation write."""
    records: list[dict[str, Any]] = []
    skipped = 0
    for page in iter_sales(transport, max_pages=options.max_pages, sleep=options.sleep):
        page_records, page_skipped = _map_page(page["items"], observed_at, source_run_id)
        records.extend(page_records)
        skipped += page_skipped
    return records, skipped


def _write_records(store: DomainOpportunityStore, records: list[dict[str, Any]], source_run_id: str, observed_at: str) -> int:
    """Write one complete source run through the store transaction boundary."""
    inserted = 0
    for record in records:
        inserted += int(store.upsert_listing_observation(record))
        raw = record["raw_json"]
        search_count = raw["keywordSearchCount"]
        if isinstance(search_count, int) and not isinstance(search_count, bool) and search_count >= 0:
            store.insert_keyword_metric(
                KeywordMetric(
                    provider=PROVIDER,
                    provider_listing_id=record["provider_listing_id"],
                    source_run_id=source_run_id,
                    source="namecheap-market",
                    metric_name="keyword_search_count",
                    value=search_count,
                    unit="count",
                    observed_at=observed_at,
                    payload_hash=content_hash({"sale": record["payload_hash"], "metric": "keyword_search_count"}),
                )
            )
    store.complete_source_run(source_run_id, len(records))
    return inserted


def sync(database: str | os.PathLike[str], options: SyncOptions = SyncOptions()) -> SyncResult:
    """Ingest active sales while preserving a prior successful current view on failure."""
    transport = options.transport or (_fixture_transport(options.fixture) if options.fixture else live_transport)
    source_run_id = _source_run_id(options)
    observed_at = utc_now()
    with DomainOpportunityStore(database, initialize=True) as store:
        with store.transaction():
            store.begin_source_run(source_run_id, PROVIDER, started_at=observed_at)
        try:
            records, skipped = _collect_records(transport, options, observed_at, source_run_id)
            with store.transaction():
                inserted = _write_records(store, records, source_run_id, observed_at)
        except (NamecheapMarketError, DomainOpportunityStoreError):
            with store.transaction():
                store.fail_source_run(source_run_id, "sync_failed")
            raise
    return SyncResult(inserted=inserted, records=len(records), skipped=skipped, source_run_id=source_run_id)
