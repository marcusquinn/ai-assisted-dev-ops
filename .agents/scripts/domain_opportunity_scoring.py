#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deterministic, evidence-labelled scoring for exact-match .com candidates.

Phrase readings come only from provider/operator evidence already stored with a
listing, or from a source-labelled keyword metric. This module intentionally
ships no word list and performs no model- or host-dictionary segmentation.
"""

from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Mapping

from domain_opportunity_contract import CandidateScore, canonical_json, content_hash, utc_now
from domain_opportunity_store import DomainOpportunityStore

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


def exact_phrase_readings(sld: str, evidence: Any) -> list[dict[str, Any]]:
    """Preserve every source-labelled reading whose tokens concatenate to SLD."""
    if not isinstance(evidence, list):
        return []
    readings: list[dict[str, Any]] = []
    for item in evidence:
        if not isinstance(item, Mapping):
            continue
        tokens = _tokens(item.get("phrase"))
        source = item.get("source")
        confidence = item.get("confidence")
        if "".join(tokens) != sld or not isinstance(source, str) or not source.strip():
            continue
        if isinstance(confidence, bool) or not isinstance(confidence, (int, float)):
            continue
        if not 0 <= float(confidence) <= 1:
            continue
        reading: dict[str, Any] = {
            "phrase": " ".join(tokens),
            "tokens": list(tokens),
            "source": source.strip(),
            "confidence_micros": round(float(confidence) * MICROS),
        }
        intent = item.get("commercial_intent")
        if isinstance(intent, (int, float)) and not isinstance(intent, bool) and 0 <= float(intent) <= 1:
            reading["commercial_intent_micros"] = round(float(intent) * MICROS)
        flags = item.get("risk_flags")
        if isinstance(flags, list):
            reading["risk_flags"] = sorted({flag for flag in flags if isinstance(flag, str) and flag})
        readings.append(reading)
    return sorted(readings, key=lambda item: (-item["confidence_micros"], item["phrase"], item["source"]))


def _unknown(reason: str) -> dict[str, Any]:
    return {"value_micros": 0, "weight_micros": 0, "evidence": {"status": "unknown", "reason": reason}}


def _known(value: int, weight: int, evidence: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "value_micros": max(0, min(MICROS, value)),
        "weight_micros": max(0, min(MICROS, weight)),
        "evidence": {"status": "measured", **evidence},
    }


def _raw_evidence(store: DomainOpportunityStore, listing: Mapping[str, Any]) -> dict[str, Any]:
    row = store.connection.execute(
        """SELECT o.raw_json FROM listings l JOIN listing_observations o
             ON o.observation_id=l.current_observation_id
           WHERE l.provider=? AND l.provider_listing_id=?""",
        (listing["provider"], listing["provider_listing_id"]),
    ).fetchone()
    if row is None or row["raw_json"] is None:
        return {}
    try:
        decoded = json.loads(row["raw_json"])
    except (TypeError, json.JSONDecodeError):
        return {}
    return decoded if isinstance(decoded, dict) else {}


def _keyword_evidence(store: DomainOpportunityStore, listing: Mapping[str, Any]) -> list[dict[str, Any]]:
    rows = store.connection.execute(
        """SELECT k.source,k.value_text,k.observed_at FROM keyword_metrics k
             JOIN listings l ON l.listing_id=k.listing_id
           WHERE l.provider=? AND l.provider_listing_id=?
           ORDER BY k.observed_at DESC,k.metric_id DESC""",
        (listing["provider"], listing["provider_listing_id"]),
    ).fetchall()
    evidence: list[dict[str, Any]] = []
    for row in rows:
        try:
            value = json.loads(row["value_text"])
        except (TypeError, json.JSONDecodeError):
            continue
        if isinstance(value, dict):
            evidence.append({"source": row["source"], "observed_at": row["observed_at"], **value})
    return evidence


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


def score_listing(
    store: DomainOpportunityStore, listing: Mapping[str, Any], policy: ScoringPolicy
) -> dict[str, Any]:
    """Build a deterministic explanation without mutating source evidence."""
    policy.validate()
    raw = _raw_evidence(store, listing)
    metrics = _keyword_evidence(store, listing)
    phrase_evidence = list(raw.get("phrase_evidence", [])) if isinstance(raw.get("phrase_evidence"), list) else []
    for metric in metrics:
        phrase = metric.get("input_phrase")
        if isinstance(phrase, str) and metric.get("status") == "found":
            phrase_evidence.append({"phrase": phrase, "source": metric["source"], "confidence": 1.0})
    readings = exact_phrase_readings(str(listing.get("sld", "")), phrase_evidence)
    hard_flags = _hard_flags(listing, policy)
    word_flags = []
    if readings and not any(policy.min_words <= len(reading["tokens"]) <= policy.max_words for reading in readings):
        word_flags.append("word_count_out_of_bounds")
    eligible_readings = [
        reading for reading in readings if policy.min_words <= len(reading["tokens"]) <= policy.max_words
    ]
    flags = sorted(set(hard_flags + word_flags + ([] if eligible_readings else ["missing_exact_phrase_evidence"])))
    risk_flags = sorted({flag for reading in readings for flag in reading.get("risk_flags", [])})
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


def score_store(store: DomainOpportunityStore, policy: ScoringPolicy | None = None) -> dict[str, Any]:
    """Score current listings and persist one atomic, idempotent policy run."""
    selected = policy or ScoringPolicy()
    selected.validate()
    explanations = [score_listing(store, listing, selected) for listing in store.current_listings()]
    calculated_at = utc_now()
    for explanation in explanations:
        explanation["calculated_at"] = calculated_at
    run_hash = content_hash({"policy": asdict(selected), "inputs": [item["input_hash"] for item in explanations]})
    run_id = f"domain-score-{selected.version}-{run_hash[:24]}"
    with store.transaction():
        store.begin_source_run(run_id, "domain-opportunity-scoring", started_at=calculated_at)
        for explanation in explanations:
            store.insert_candidate_score(
                CandidateScore(
                    provider=str(explanation["provider"]),
                    provider_listing_id=str(explanation["provider_listing_id"]),
                    source_run_id=run_id,
                    model=selected.version,
                    score_micros=int(explanation["score_micros"]),
                    observed_at=str(explanation["calculated_at"]),
                    components=explanation["components"],
                    payload_hash=explanation["input_hash"],
                )
            )
        store.complete_source_run(run_id, len(explanations))
    return {"policy_version": selected.version, "run_id": run_id, "records": len(explanations), "candidates": explanations}


def explain_domain(store: DomainOpportunityStore, domain: str, policy_version: str = POLICY_VERSION) -> dict[str, Any]:
    """Read the newest persisted explanation for one domain and policy."""
    row = store.connection.execute(
        """SELECT s.score_id,s.score_micros,s.observed_at,s.payload_hash,l.fqdn
             FROM candidate_scores s JOIN listings l ON l.listing_id=s.listing_id
           WHERE l.fqdn=? AND s.model=? ORDER BY s.score_id DESC LIMIT 1""",
        (domain.casefold().rstrip("."), policy_version),
    ).fetchone()
    if row is None:
        raise DomainOpportunityScoringError("no persisted score matches the domain and policy")
    components = store.connection.execute(
        "SELECT name,value_micros,weight_micros,evidence_json FROM score_components WHERE score_id=? ORDER BY name",
        (row["score_id"],),
    ).fetchall()
    return {
        "domain": row["fqdn"], "policy_version": policy_version, "score_micros": row["score_micros"],
        "calculated_at": row["observed_at"], "input_hash": row["payload_hash"],
        "components": {
            component["name"]: {
                "value_micros": component["value_micros"], "weight_micros": component["weight_micros"],
                "evidence": None if component["evidence_json"] is None else json.loads(component["evidence_json"]),
            } for component in components
        },
    }


def load_fixture(store: DomainOpportunityStore, path: str | Path) -> dict[str, int]:
    """Import synthetic JSONL listings, continuing past malformed records."""
    fixture = Path(path)
    if fixture.is_symlink() or not fixture.is_file():
        raise DomainOpportunityScoringError("fixture must be a regular JSONL file")
    imported = rejected = 0
    for line in fixture.read_text(encoding="utf-8").splitlines():
        try:
            record = json.loads(line)
            if not isinstance(record, dict):
                raise DomainOpportunityScoringError("fixture row is not an object")
            raw = record.get("raw_json") if isinstance(record.get("raw_json"), dict) else {}
            if "phrase_evidence" in record:
                raw = {**raw, "phrase_evidence": record.pop("phrase_evidence")}
            record["raw_json"] = raw
            with store.transaction():
                store.begin_source_run(record["source_run_id"], record["provider"], started_at=record["observed_at"])
                imported += int(store.upsert_listing_observation(record))
                store.complete_source_run(record["source_run_id"], 1)
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            rejected += 1
    return {"imported": imported, "rejected": rejected}


def export_candidates(store: DomainOpportunityStore, policy_version: str = POLICY_VERSION) -> list[dict[str, Any]]:
    """Return one stable latest-score export row per domain."""
    domains = store.connection.execute(
        """SELECT DISTINCT l.fqdn FROM candidate_scores s JOIN listings l ON l.listing_id=s.listing_id
           WHERE s.model=? ORDER BY l.fqdn""", (policy_version,)
    ).fetchall()
    return [explain_domain(store, row["fqdn"], policy_version) for row in domains]
