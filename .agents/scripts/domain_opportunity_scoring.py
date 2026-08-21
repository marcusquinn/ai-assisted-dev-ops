#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deterministic, evidence-labelled scoring for exact-match .com candidates.

Phrase readings come only from provider/operator evidence already stored with a
listing, or from a source-labelled keyword metric. This module intentionally
ships no word list and performs no model- or host-dictionary segmentation.
"""

from __future__ import annotations

import re
from dataclasses import asdict, dataclass
from typing import Any, Mapping

from domain_opportunity_contract import content_hash

POLICY_VERSION = "exact-match-com-v1"
MICROS = 1_000_000
_ASCII_LABEL = re.compile(r"^[a-z]+$")
_TOKEN = re.compile(r"^[a-z]+$")


class DomainOpportunityScoringError(ValueError):
    """Raised when scoring policy or phrase evidence is invalid."""


@dataclass(frozen=True)
class ScoringPolicy:
    """Versioned hard-filter and bounded-component policy."""

    version: str = POLICY_VERSION
    tld: str = "com"
    min_length: int = 4
    max_length: int = 24
    min_words: int = 1
    max_words: int = 4
    max_repeated_characters: int = 3
    max_price_micros: int = 5_000_000_000
    risk_penalty_micros: int = 250_000
    disallowed_terms: tuple[str, ...] = ("adult", "casino", "porn")

    def validate(self) -> None:
        """Reject malformed policy before any score is published."""
        if not self.version or not _TOKEN.fullmatch(self.tld):
            raise DomainOpportunityScoringError("policy version and ASCII TLD are required")
        if not 1 <= self.min_length <= self.max_length <= 63:
            raise DomainOpportunityScoringError("length bounds must be ordered within one DNS label")
        if not 1 <= self.min_words <= self.max_words <= 8:
            raise DomainOpportunityScoringError("word-count bounds must be ordered from one to eight")
        if not 1 <= self.max_repeated_characters <= 8 or self.max_price_micros <= 0:
            raise DomainOpportunityScoringError("repeat and price limits must be positive")
        if not 0 <= self.risk_penalty_micros <= MICROS:
            raise DomainOpportunityScoringError("risk penalty must be between zero and one million")
        if any(not _TOKEN.fullmatch(term) for term in self.disallowed_terms):
            raise DomainOpportunityScoringError("disallowed terms must be lowercase ASCII words")


def _tokens(phrase: Any) -> tuple[str, ...]:
    """Return explicit lowercase ASCII tokens without guessing boundaries."""
    if not isinstance(phrase, str):
        return ()
    tokens = tuple(phrase.casefold().split())
    return tokens if tokens and all(_TOKEN.fullmatch(token) for token in tokens) else ()


def _reading(item: Any, sld: str) -> dict[str, Any] | None:
    """Normalize one explicit reading, returning none at any invalid boundary."""
    try:
        tokens = _tokens(item["phrase"])
        source = item["source"].strip()
        confidence_value = item["confidence"]
    except (AttributeError, KeyError, TypeError):
        return None
    if "".join(tokens) != sld or not source or type(confidence_value) not in (int, float):
        return None
    confidence = float(confidence_value)
    if not 0 <= confidence <= 1:
        return None
    reading: dict[str, Any] = {
        "phrase": " ".join(tokens), "tokens": list(tokens), "source": source,
        "confidence_micros": round(confidence * MICROS),
    }
    intent = item.get("commercial_intent")
    if type(intent) in (int, float) and 0 <= float(intent) <= 1:
        reading["commercial_intent_micros"] = round(float(intent) * MICROS)
    flags = item.get("risk_flags", ())
    reading_flags = sorted({flag for flag in flags if isinstance(flag, str) and flag}) if isinstance(flags, list) else []
    if reading_flags:
        reading["risk_flags"] = reading_flags
    return reading


def exact_phrase_readings(sld: str, evidence: Any) -> list[dict[str, Any]]:
    """Preserve every source-labelled reading whose tokens concatenate to SLD."""
    items = evidence if isinstance(evidence, list) else []
    readings = [reading for item in items if (reading := _reading(item, sld)) is not None]
    return sorted(readings, key=lambda item: (-item["confidence_micros"], item["phrase"], item["source"]))


def _unknown(reason: str) -> dict[str, Any]:
    return {"value_micros": 0, "weight_micros": 0, "evidence": {"status": "unknown", "reason": reason}}


def _known(value: int, weight: int, evidence: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "value_micros": max(0, min(MICROS, value)),
        "weight_micros": max(0, min(MICROS, weight)),
        "evidence": {"status": "measured", **evidence},
    }


def _hard_flags(listing: Mapping[str, Any], policy: ScoringPolicy) -> list[str]:
    sld = str(listing.get("sld", ""))
    flags: list[str] = []
    if listing.get("tld") != policy.tld:
        flags.append("unsupported_tld")
    if not _ASCII_LABEL.fullmatch(sld):
        flags.append("non_ascii_or_punctuation")
    if "-" in sld:
        flags.append("hyphen")
    if any(character.isdigit() for character in sld):
        flags.append("digit")
    if not policy.min_length <= len(sld) <= policy.max_length:
        flags.append("length_out_of_bounds")
    if any(character * (policy.max_repeated_characters + 1) in sld for character in set(sld)):
        flags.append("repeated_characters")
    if any(term in sld for term in policy.disallowed_terms):
        flags.append("disallowed_term")
    return sorted(set(flags))


def _phrase_state(
    listing: Mapping[str, Any], raw: Mapping[str, Any],
    metrics: list[dict[str, Any]], policy: ScoringPolicy,
) -> tuple[list[dict[str, Any]], list[str], list[str]]:
    """Collect eligible phrase readings plus hard and review flags."""
    phrase_evidence = list(raw.get("phrase_evidence", [])) if isinstance(raw.get("phrase_evidence"), list) else []
    for metric in metrics:
        phrase = metric.get("input_phrase")
        if isinstance(phrase, str) and metric.get("status") == "found":
            phrase_evidence.append({"phrase": phrase, "source": metric["source"], "confidence": 1.0})
    readings = exact_phrase_readings(str(listing.get("sld", "")), phrase_evidence)
    flags = _hard_flags(listing, policy)
    eligible_readings = [
        reading for reading in readings if policy.min_words <= len(reading["tokens"]) <= policy.max_words
    ]
    if readings and not eligible_readings:
        flags.append("word_count_out_of_bounds")
    if not eligible_readings:
        flags.append("missing_exact_phrase_evidence")
    risk_flags = sorted({flag for reading in readings for flag in reading.get("risk_flags", [])})
    return eligible_readings, sorted(set(flags)), risk_flags


def score_listing(
    listing: Mapping[str, Any], policy: ScoringPolicy,
    raw: Mapping[str, Any] | None = None, metrics: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Build a deterministic explanation without mutating source evidence."""
    policy.validate()
    raw = raw or {}
    metrics = metrics or []
    eligible_readings, flags, risk_flags = _phrase_state(listing, raw, metrics, policy)
    eligible = not flags

    components: dict[str, dict[str, Any]] = {}
    structural = MICROS - min(500_000, abs(len(str(listing.get("sld", ""))) - 12) * 40_000)
    components["structural_readability"] = _known(
        structural, 200_000,
        {"sld_length": len(str(listing.get("sld", ""))), "eligible": eligible, "hard_filter_flags": flags},
    )
    if eligible_readings:
        best = eligible_readings[0]
        components["phrase_confidence"] = _known(
            best["confidence_micros"], 250_000,
            {"reading_count": len(eligible_readings), "best_source": best["source"], "readings": eligible_readings},
        )
        intents = [reading["commercial_intent_micros"] for reading in eligible_readings if "commercial_intent_micros" in reading]
        components["commercial_intent"] = (
            _known(max(intents), 100_000, {"source": "phrase_evidence"})
            if intents else _unknown("no source-labelled commercial-intent taxonomy evidence")
        )
    else:
        components["phrase_confidence"] = _unknown("no exact source-labelled phrase reading")
        components["commercial_intent"] = _unknown("no eligible phrase reading")

    price = listing.get("current_price_micros")
    if isinstance(price, int) and price >= 0:
        price_fit = max(0, MICROS - round(price * MICROS / policy.max_price_micros))
        components["current_price_fit"] = _known(price_fit, 150_000, {"price_micros": price, "ceiling_micros": policy.max_price_micros})
    else:
        components["current_price_fit"] = _unknown("current price is unavailable")

    found_metrics = [metric for metric in metrics if metric.get("status") == "found" and isinstance(metric.get("metrics"), dict)]
    searches = [metric["metrics"].get("average_monthly_searches") for metric in found_metrics]
    searches = [value for value in searches if isinstance(value, int) and value >= 0]
    components["demand"] = (
        _known(min(MICROS, max(searches) * 1_000), 100_000, {"average_monthly_searches": max(searches), "source": "google-ads"})
        if searches else _unknown("no measured search-demand observation")
    )
    components["provider_appraisal_comparables"] = (
        _known(min(MICROS, int(raw["appraisal_confidence_micros"])), 50_000, {"source": raw.get("appraisal_source", "provider")})
        if isinstance(raw.get("appraisal_confidence_micros"), int) else _unknown("no provider appraisal or comparable-sale observation")
    )
    components["backlink_history"] = (
        _known(min(MICROS, int(raw["history_confidence_micros"])), 50_000, {"source": raw.get("history_source", "provider")})
        if isinstance(raw.get("history_confidence_micros"), int) else _unknown("no backlink or domain-history observation")
    )
    components["source_freshness"] = _unknown("freshness has no configured source-specific expiry in policy v1")
    components["risk_quality"] = _known(
        max(0, MICROS - len(risk_flags) * policy.risk_penalty_micros), 150_000,
        {"flags": risk_flags, "penalty_micros_per_flag": policy.risk_penalty_micros, "legal_clearance": False},
    )

    weighted = sum(component["value_micros"] * component["weight_micros"] for component in components.values())
    weights = sum(component["weight_micros"] for component in components.values())
    total = round(weighted / weights) if eligible and weights else 0
    evidence_snapshot = {
        "listing": dict(listing), "phrase_readings": eligible_readings, "raw_evidence": raw,
        "keyword_evidence": metrics, "policy": asdict(policy),
    }
    return {
        "domain": listing.get("fqdn"), "provider": listing.get("provider"),
        "provider_listing_id": listing.get("provider_listing_id"), "policy_version": policy.version,
        "eligible": eligible, "flags": flags, "risk_flags": risk_flags, "phrase_readings": eligible_readings,
        "components": components, "score_micros": total, "input_hash": content_hash(evidence_snapshot),
    }
