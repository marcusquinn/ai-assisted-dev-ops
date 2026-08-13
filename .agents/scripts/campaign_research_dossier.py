#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Dossier assembly, validation, and public summary rendering."""

from __future__ import annotations

import datetime as dt
import hashlib
from dataclasses import dataclass
from typing import Any

from campaign_research_common import CONFIDENCES, KINDS, MAX_OBSERVATIONS, MAX_SOURCES, SCHEMA_VERSION, SOURCE_STATUSES, DossierError, canonical_bytes, parse_time, required_text
from campaign_research_sources import load_source


@dataclass(frozen=True)
class DossierComponents:
    """Normalized inputs used to assemble one campaign research dossier."""

    campaign_id: str
    intake: dict[str, Any]
    ledgers: list[dict[str, Any]]
    observations: list[dict[str, Any]]
    grouped: dict[str, list[dict[str, Any]]]
    generated_at: dt.datetime


def build_dossier(campaign_id: str, intake: dict[str, Any], source_paths: list[Any], now: dt.datetime) -> dict[str, Any]:
    """Build deterministic insights and explicit source coverage from packages."""
    if len(source_paths) > MAX_SOURCES:
        raise DossierError(f"at most {MAX_SOURCES} source packages are allowed")
    ledgers, observations = _load_packages(source_paths, now)
    if len(observations) > MAX_OBSERVATIONS:
        raise DossierError(f"at most {MAX_OBSERVATIONS} observations are allowed")
    grouped = _group_observations(observations)
    components = DossierComponents(campaign_id, intake, ledgers, observations, grouped, now)
    dossier = _assemble_dossier(components)
    validate_dossier(dossier)
    return dossier


def _load_packages(source_paths: list[Any], now: dt.datetime) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    ledgers: list[dict[str, Any]] = []
    observations: list[dict[str, Any]] = []
    source_ids: set[str] = set()
    for source_path in source_paths:
        ledger, loaded = load_source(source_path, now)
        if ledger["source_id"] in source_ids:
            raise DossierError(f"duplicate source_id: {ledger['source_id']}")
        source_ids.add(ledger["source_id"])
        ledgers.append(ledger)
        observations.extend(loaded)
    return ledgers, observations


def _group_observations(observations: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    grouped = {kind: [] for kind in KINDS}
    seen: set[tuple[str, str, str]] = set()
    for observation in observations:
        insight = observation["insight"]
        key = (observation["kind"], insight["label"].casefold(), insight["summary"].casefold())
        if key not in seen:
            grouped[observation["kind"]].append(insight)
            seen.add(key)
    return grouped


def _assemble_dossier(components: DossierComponents) -> dict[str, Any]:
    """Assemble the finalized dossier from normalized source components."""
    counts = {status: sum(item["status"] == status for item in components.ledgers) for status in sorted(SOURCE_STATUSES)}
    usable = [item for item in components.ledgers if item["status"] in {"complete", "partial"} and item["freshness"] == "fresh"]
    coverage = "complete" if usable and all(item["status"] == "complete" and item["freshness"] == "fresh" for item in components.ledgers) else "partial" if usable else "unavailable"
    roles = sorted({role for audience in components.intake["audiences"] if isinstance(audience, dict) for role in audience.get("buying_roles", []) if isinstance(role, str) and role})
    audiences = [{"label": required_text(audience.get("segment"), "intake audience", 240), "summary": "Research question seeded from the approved campaign intake.", "confidence": "medium", "evidence_source_ids": ["campaign-intake"]} for audience in components.intake["audiences"] if isinstance(audience, dict)]
    snapshot = {"campaign_id": components.campaign_id, "intake": components.intake, "ledger": components.ledgers, "observations": components.observations}
    return {"schema_version": SCHEMA_VERSION, "campaign_id": components.campaign_id, "semantic_snapshot_sha256": hashlib.sha256(canonical_bytes(snapshot)).hexdigest(), "generated_at": components.generated_at.replace(microsecond=0).isoformat().replace("+00:00", "Z"), "coverage": {"status": coverage, "source_counts": counts}, "audiences": audiences + components.grouped["audience"], "buying_roles": roles, "competitors": components.grouped["competitor"], "creators": components.grouped["creator"], "trends": components.grouped["trend"], "channel_fit": components.grouped["channel_fit"], "opportunities": components.grouped["opportunity"], "contradictions": components.grouped["contradiction"], "provenance_ledger": components.ledgers}


def validate_dossier(dossier: dict[str, Any]) -> None:
    """Enforce emitted schema invariants without a runtime schema dependency."""
    required = {"schema_version", "campaign_id", "semantic_snapshot_sha256", "generated_at", "coverage", "audiences", "buying_roles", "competitors", "creators", "trends", "channel_fit", "opportunities", "contradictions", "provenance_ledger"}
    if set(dossier) != required or dossier["schema_version"] != SCHEMA_VERSION:
        raise DossierError("generated dossier does not match schema version 1")
    if not isinstance(dossier["semantic_snapshot_sha256"], str) or len(dossier["semantic_snapshot_sha256"]) != 64:
        raise DossierError("generated dossier snapshot hash is invalid")
    parse_time(dossier["generated_at"], "generated_at")
    _validate_coverage(dossier["coverage"])
    _validate_ledger(dossier["provenance_ledger"])
    for key in ("audiences", "competitors", "creators", "trends", "channel_fit", "opportunities", "contradictions"):
        _validate_insights(key, dossier[key])


def _validate_coverage(coverage: Any) -> None:
    if not isinstance(coverage, dict) or coverage.get("status") not in {"complete", "partial", "unavailable"} or not isinstance(coverage.get("source_counts"), dict):
        raise DossierError("generated dossier coverage is invalid")


def _validate_ledger(ledger: Any) -> None:
    source_ids: set[str] = set()
    required = {"source_id", "source_type", "reference", "captured_at", "freshness", "authorization_mode", "status", "confidence", "sensitivity"}
    for source in ledger:
        if not isinstance(source, dict) or set(source) != required or source["source_id"] in source_ids:
            raise DossierError("generated dossier provenance is invalid")
        source_ids.add(source["source_id"])


def _validate_insights(key: str, insights: Any) -> None:
    if not isinstance(insights, list):
        raise DossierError(f"generated dossier {key} must be an array")
    for insight in insights:
        valid = isinstance(insight, dict) and set(insight) == {"label", "summary", "confidence", "evidence_source_ids"}
        if not valid or insight["confidence"] not in CONFIDENCES or not insight["evidence_source_ids"]:
            raise DossierError(f"generated dossier {key} insight is invalid")


def render_summary(dossier: dict[str, Any]) -> str:
    """Render a publishable reference-only summary without raw source content."""
    lines = [f"# Campaign Research Dossier: {dossier['campaign_id']}", "", f"**Schema:** v{SCHEMA_VERSION}", f"**Coverage:** {dossier['coverage']['status']}", f"**Snapshot:** `{dossier['semantic_snapshot_sha256']}`", "", "## Source coverage", ""]
    lines.extend(f"- **{source['source_id']}:** {source['status']}; {source['freshness']}; {source['source_type']}; reference `{source['reference']}`" for source in dossier["provenance_ledger"])
    for key, heading in (("audiences", "Audiences"), ("competitors", "Competitors"), ("creators", "Creators and partners"), ("trends", "Trends"), ("channel_fit", "Channel fit"), ("opportunities", "Opportunities"), ("contradictions", "Contradictions and gaps")):
        lines.extend(["", f"## {heading}", ""])
        lines.extend(f"- **{entry['label']}:** {entry['summary']}" for entry in dossier[key]) or lines.append("- No supported evidence captured.")
    return "\n".join(lines) + "\n"
