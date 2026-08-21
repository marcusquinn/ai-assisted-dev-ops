#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only Google Ads historical-keyword-metrics collection helpers."""

from __future__ import annotations

import json
import re
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Callable, Iterable, Mapping

from domain_opportunity_contract import KeywordMetric, canonical_json, content_hash, utc_now
from domain_opportunity_store import DomainOpportunityStore

GOOGLE_ADS_SCOPE = "https://www.googleapis.com/auth/adwords"
DEFAULT_API_MAJOR = "v25"
MAX_BATCH_SIZE = 10_000
MAX_BATCHES = 100
_API_VERSION_RE = re.compile(r"^v[0-9]+$")
_CURRENCY_RE = re.compile(r"^[A-Z]{3}$")


class GoogleAdsError(RuntimeError):
    """Raised for a sanitized, recoverable Google Ads batch failure."""


@dataclass(frozen=True)
class GoogleAdsRequest:
    """The explicit, auditable non-secret request context."""

    api_major: str
    language: str
    geographies: tuple[str, ...]
    network: str
    currency: str

    def __post_init__(self) -> None:
        checks = (
            (bool(_API_VERSION_RE.fullmatch(self.api_major)), "Google Ads API major must be formatted like v25"),
            (self.language.startswith("languageConstants/"), "language must be a Google Ads language resource name"),
            (
                all((self.geographies, *(item.startswith("geoTargetConstants/") for item in self.geographies))),
                "at least one Google Ads geo target resource name is required",
            ),
            (bool(self.network), "keyword plan network is required"),
            (bool(_CURRENCY_RE.fullmatch(self.currency)), "currency must be an ISO 4217 code"),
        )
        for valid, message in checks:
            if not valid:
                raise GoogleAdsError(message)


@dataclass(frozen=True)
class GoogleAdsCredentials:
    """Ephemeral live-read credentials kept outside stored request evidence."""

    access_token: str
    developer_token: str
    customer_id: str
    login_customer_id: str | None = None

    def __post_init__(self) -> None:
        if not all((self.access_token, self.developer_token, self.customer_id)):
            raise GoogleAdsError("Google Ads live sync requires configured credentials and a customer target")


def normalized_phrase(value: str) -> str:
    """Return one stable phrase identity without applying linguistic guesses."""
    return " ".join(value.casefold().split())


def retrieval_month(now: datetime | None = None) -> str:
    """Return the UTC monthly partition used for cache identity."""
    moment = now or datetime.now(timezone.utc)
    return f"{moment.astimezone(timezone.utc).year:04d}-{moment.astimezone(timezone.utc).month:02d}"


def request_identity(phrases: Iterable[str], request: GoogleAdsRequest, month: str) -> str:
    """Hash all factors that make a monthly historical-metrics result distinct."""
    return content_hash(
        {
            "phrases": sorted({normalized_phrase(phrase) for phrase in phrases}),
            "language": request.language,
            "geographies": sorted(request.geographies),
            "network": request.network,
            "currency": request.currency,
            "api_major": request.api_major,
            "retrieval_month": month,
        }
    )


def _integer_or_none(value: Any, field: str) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool):
        raise GoogleAdsError(f"{field} must be an integer when supplied")
    try:
        converted = int(value)
    except (TypeError, ValueError) as exc:
        raise GoogleAdsError(f"{field} must be an integer when supplied") from exc
    if converted < 0:
        raise GoogleAdsError(f"{field} must not be negative")
    return converted


def _month_value(value: Any) -> str | None:
    if not isinstance(value, Mapping):
        return None
    year = _integer_or_none(value.get("year"), "monthlySearchVolumes.year")
    try:
        month = {
            "JANUARY": 1, "FEBRUARY": 2, "MARCH": 3, "APRIL": 4, "MAY": 5, "JUNE": 6,
            "JULY": 7, "AUGUST": 8, "SEPTEMBER": 9, "OCTOBER": 10, "NOVEMBER": 11, "DECEMBER": 12,
        }[value["month"].upper()]
        return f"{year:04d}-{month:02d}"
    except (AttributeError, KeyError, TypeError):
        return None


def normalize_metrics(raw: Any) -> dict[str, Any]:
    """Preserve documented Google Ads units and absent values as JSON null."""
    metrics = raw if isinstance(raw, Mapping) else {}
    raw_volumes = metrics.get("monthlySearchVolumes")
    volumes = [
        {
            "month": _month_value(item),
            "searches": _integer_or_none(item.get("monthlySearches"), "monthlySearchVolumes.monthlySearches"),
        }
        for item in raw_volumes if isinstance(item, Mapping)
    ] if isinstance(raw_volumes, list) else []
    return {
        "average_monthly_searches": _integer_or_none(metrics.get("avgMonthlySearches"), "avgMonthlySearches"),
        "monthly_search_volumes": volumes,
        "competition": metrics.get("competition") if isinstance(metrics.get("competition"), str) else None,
        "competition_index": _integer_or_none(metrics.get("competitionIndex"), "competitionIndex"),
        "low_top_of_page_bid_micros": _integer_or_none(metrics.get("lowTopOfPageBidMicros"), "lowTopOfPageBidMicros"),
        "high_top_of_page_bid_micros": _integer_or_none(metrics.get("highTopOfPageBidMicros"), "highTopOfPageBidMicros"),
        "units": {
            "average_monthly_searches": "searches",
            "monthly_search_volumes.searches": "searches",
            "competition_index": "index_0_100",
            "low_top_of_page_bid_micros": "currency_micros",
            "high_top_of_page_bid_micros": "currency_micros",
        },
    }


def _response_group(raw_result: Mapping[str, Any]) -> dict[str, Any]:
    """Normalize one documented result into an unordered matching group."""
    variants = [raw_result["text"]]
    close_variants = raw_result.get("closeVariants")
    if isinstance(close_variants, list):
        variants.extend(item for item in close_variants if isinstance(item, str))
    return {
        "returned_text": raw_result["text"],
        "close_variants": sorted(set(variants[1:])),
        "identities": {normalized_phrase(item) for item in variants},
        "metrics": normalize_metrics(raw_result.get("keywordMetrics")),
    }


def response_groups(response: Mapping[str, Any]) -> list[dict[str, Any]]:
    """Map response groups by returned text and close variants, never array position."""
    raw_results = response.get("results")
    if not isinstance(raw_results, list):
        raise GoogleAdsError("Google Ads response does not contain a results array")
    return [
        _response_group(raw_result)
        for raw_result in raw_results
        if isinstance(raw_result, Mapping) and isinstance(raw_result.get("text"), str)
    ]


def map_phrases_to_groups(phrases: Iterable[str], response: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
    """Return explicit found, missing, or ambiguous outcomes for each input phrase."""
    groups = response_groups(response)
    mapped: dict[str, dict[str, Any]] = {}
    for phrase in sorted({normalized_phrase(item) for item in phrases if normalized_phrase(item)}):
        matched = [group for group in groups if phrase in group["identities"]]
        if len(matched) == 1:
            group = matched[0]
            mapped[phrase] = {
                "status": "found",
                "returned_text": group["returned_text"],
                "close_variants": group["close_variants"],
                "metrics": group["metrics"],
            }
            continue
        mapped[phrase] = {
            "status": ("missing", "ambiguous")[bool(matched)],
            "returned_text": None,
            "close_variants": [],
            "metrics": None,
        }
    return mapped


@dataclass(frozen=True)
class GoogleAdsTransport:
    """Injectable standard-library transport for deterministic local checks."""

    opener: Callable[..., Any] = urllib.request.urlopen
    sleep: Callable[[float], None] = time.sleep
    monotonic: Callable[[], float] = time.monotonic


DEFAULT_TRANSPORT = GoogleAdsTransport()


class GoogleAdsClient:
    """Minimal read-only REST client for one historical-metrics request stream."""

    def __init__(
        self,
        request: GoogleAdsRequest,
        credentials: GoogleAdsCredentials,
        *,
        transport: GoogleAdsTransport = DEFAULT_TRANSPORT,
    ) -> None:
        self.request = request
        self.credentials = credentials
        self.transport = transport
        self._last_request_at = float("-inf")

    def _wait_for_request_slot(self) -> None:
        """Keep this customer stream at the documented one request per second."""
        remaining = 1.0 - (self.transport.monotonic() - self._last_request_at)
        if remaining > 0:
            self.transport.sleep(remaining)

    @staticmethod
    def _retry_delay(error: urllib.error.HTTPError, attempt: int) -> float:
        """Honor a bounded provider delay before one of two retry attempts."""
        try:
            provider_delay = float(getattr(error.headers, "get", lambda _key: 0.0)("Retry-After"))
        except (TypeError, ValueError):
            provider_delay = 0.0
        return min(60.0, max(1.0, provider_delay, float(2**attempt)))

    def historical_metrics(self, phrases: list[str]) -> dict[str, Any]:
        """Perform only the documented read-only historical metrics method."""
        if not 0 < len(phrases) <= MAX_BATCH_SIZE:
            raise GoogleAdsError("Google Ads batch size is invalid")
        payload = canonical_json(
            {
                "keywords": phrases,
                "language": self.request.language,
                "geoTargetConstants": list(self.request.geographies),
                "keywordPlanNetwork": self.request.network,
            }
        ).encode("utf-8")
        endpoint = (
            f"https://googleads.googleapis.com/{self.request.api_major}/customers/"
            f"{self.credentials.customer_id}:generateKeywordHistoricalMetrics"
        )
        headers = {
            "Authorization": f"Bearer {self.credentials.access_token}",
            "developer-token": self.credentials.developer_token,
            "Content-Type": "application/json",
        }
        if self.credentials.login_customer_id:
            headers["login-customer-id"] = self.credentials.login_customer_id
        request = urllib.request.Request(endpoint, data=payload, headers=headers, method="POST")
        for attempt in range(3):
            try:
                self._wait_for_request_slot()
                self._last_request_at = self.transport.monotonic()
                with self.transport.opener(request, timeout=30) as response:
                    decoded = json.loads(response.read().decode("utf-8"))
            except urllib.error.HTTPError as exc:
                if exc.code in {401, 403}:
                    raise GoogleAdsError("Google Ads authentication or access was denied") from exc
                if (exc.code, attempt) not in {
                    (429, 0), (429, 1), (500, 0), (500, 1), (502, 0),
                    (502, 1), (503, 0), (503, 1), (504, 0), (504, 1),
                }:
                    raise GoogleAdsError("Google Ads quota or transient request failure") from exc
                self.transport.sleep(self._retry_delay(exc, attempt))
                continue
            except (OSError, ValueError, json.JSONDecodeError) as exc:
                raise GoogleAdsError("Google Ads historical metrics response was invalid") from exc
            if not isinstance(decoded, dict):
                raise GoogleAdsError("Google Ads historical metrics response was invalid")
            return decoded
        raise GoogleAdsError("Google Ads historical metrics request failed")


def candidate_phrases(store: DomainOpportunityStore) -> dict[str, list[dict[str, str]]]:
    """Use each listing's SLD as its conservative candidate phrase identity."""
    candidates: dict[str, list[dict[str, str]]] = {}
    for listing in store.current_listings(active_only=True):
        phrase = normalized_phrase(str(listing["sld"]))
        candidates.setdefault(phrase, []).append(
            {"provider": str(listing["provider"]), "provider_listing_id": str(listing["provider_listing_id"])}
        )
    candidates.pop("", None)
    return candidates


def _request_batches(
    store: DomainOpportunityStore, request: GoogleAdsRequest, month: str | None
) -> tuple[dict[str, list[dict[str, str]]], list[list[str]], str, str]:
    """Build the shared candidate, monthly identity, and bounded batch plan."""
    candidates = candidate_phrases(store)
    phrases = sorted(candidates)
    period = month or retrieval_month()
    identity = request_identity(phrases, request, period)
    batches = [phrases[index : index + MAX_BATCH_SIZE] for index in range(0, len(phrases), MAX_BATCH_SIZE)]
    if len(batches) > MAX_BATCHES:
        raise GoogleAdsError("Google Ads batch fuse exceeded")
    return candidates, batches, identity, period


def plan(store: DomainOpportunityStore, request: GoogleAdsRequest, *, month: str | None = None) -> dict[str, Any]:
    """Report bounded batches without issuing a Google Ads request."""
    candidates, batches, identity, period = _request_batches(store, request, month)
    return {"batch_count": len(batches), "batch_ids": [content_hash(batch)[:12] for batch in batches], "candidate_count": len(candidates), "input_hash": identity, "retrieval_month": period}


def sync(
    store: DomainOpportunityStore,
    request: GoogleAdsRequest,
    fetch: Callable[[list[str]], Mapping[str, Any]],
    *,
    month: str | None = None,
) -> dict[str, Any]:
    """Fetch bounded batches and retain completed evidence when a later batch fails."""
    candidates, batches, identity, period = _request_batches(store, request, month)
    run_id = f"google-ads-{identity[:32]}"
    inserted = 0
    completed_batches = 0
    try:
        with store.transaction():
            store.begin_source_run(run_id, "google-ads")
        for batch in batches:
            response = fetch(batch)
            mapped = map_phrases_to_groups(batch, response)
            with store.transaction():
                for phrase, outcome in mapped.items():
                    payload = {
                        "api_major": request.api_major,
                        "language": request.language,
                        "geographies": list(request.geographies),
                        "network": request.network,
                        "account_currency": request.currency,
                        "input_phrase": phrase,
                        "input_hash": identity,
                        "retrieval_month": period,
                        "metric_source": "google_ads.keyword_plan_idea.generate_historical_metrics",
                        **outcome,
                    }
                    digest = content_hash(payload)
                    for listing in candidates[phrase]:
                        inserted += int(
                            store.insert_keyword_metric(
                                KeywordMetric(
                                    provider=listing["provider"],
                                    provider_listing_id=listing["provider_listing_id"],
                                    source_run_id=run_id,
                                    source="google-ads",
                                    metric_name="historical_keyword_metrics",
                                    value=canonical_json(payload),
                                    unit="json",
                                    observed_at=utc_now(),
                                    payload_hash=digest,
                                )
                            )
                        )
                completed_batches += 1
        with store.transaction():
            store.complete_source_run(run_id, inserted)
    except Exception:
        with store.transaction():
            store.fail_source_run(run_id, "batch_failed")
        raise
    return {"batches_completed": completed_batches, "input_hash": identity, "inserted": inserted, "records": len(candidates), "retrieval_month": period, "run_id": run_id}
