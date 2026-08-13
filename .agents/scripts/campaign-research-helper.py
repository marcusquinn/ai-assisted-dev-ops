#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Build a bounded, reference-oriented campaign research dossier from supplied evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
MAX_SOURCES = 20
MAX_OBSERVATIONS = 200
MAX_AGE_DAYS = 30
SOURCE_TYPES = {"manual", "export", "knowledge_query", "public_search", "seo"}
AUTHORIZATION_MODES = {"manual", "authorized_export", "authorized_collector", "public_lawful"}
SOURCE_STATUSES = {"complete", "partial", "gated", "absent", "stale", "rate_limited", "failed"}
SENSITIVITIES = {"public", "internal", "sensitive"}
CONFIDENCES = {"low", "medium", "high"}
KINDS = {"audience", "competitor", "creator", "trend", "channel_fit", "opportunity", "contradiction"}
PRIVATE_IDENTIFIER = re.compile(r"(?i)(?:api[_ -]?key|password|token|secret|email|phone)\s*[:=]|\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b|\+?[0-9][0-9 .()/-]{7,}[0-9]")
INSTRUCTION_LIKE_CONTENT = re.compile(r"(?i)\b(?:ignore|disregard)\b.{0,80}\b(?:instruction|prompt|rule)s?\b")


class DossierError(ValueError):
    """Raised when campaign research input violates the bounded contract."""


def canonical_bytes(value: Any) -> bytes:
    """Return deterministic JSON bytes for snapshot hashing."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def required_text(value: Any, field: str, maximum: int = 2000) -> str:
    """Validate a safe single-line text field."""
    if not isinstance(value, str) or not value.strip() or len(value.strip()) > maximum:
        raise DossierError(f"{field} must be non-empty text up to {maximum} characters")
    text = value.strip()
    if any(ord(character) < 32 for character in text):
        raise DossierError(f"{field} must be single-line text")
    return text


def parse_time(value: Any, field: str) -> tuple[str, dt.datetime]:
    """Normalize a timezone-aware ISO timestamp."""
    text = required_text(value, field, 64)
    try:
        parsed = dt.datetime.fromisoformat(text[:-1] + "+00:00" if text.endswith("Z") else text)
    except ValueError as error:
        raise DossierError(f"{field} must be ISO-8601") from error
    if parsed.tzinfo is None:
        raise DossierError(f"{field} requires a timezone")
    normalized = parsed.astimezone(dt.timezone.utc).replace(microsecond=0)
    return normalized.isoformat().replace("+00:00", "Z"), normalized


def relative_reference(value: Any) -> str:
    """Reject absolute and traversal references without dereferencing source artifacts."""
    reference = required_text(value, "reference", 1024)
    if reference.startswith(("/", "~")) or ".." in Path(reference).parts:
        raise DossierError("reference must be a relative non-traversing reference")
    return reference


def source_freshness(captured_at: dt.datetime, status: str, now: dt.datetime) -> str:
    """Compute truthful freshness without advancing failed evidence."""
    if status == "stale" or now - captured_at > dt.timedelta(days=MAX_AGE_DAYS):
        return "stale"
    return "fresh"


def load_source(path: Path, now: dt.datetime) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Load and normalize one supplied source package, ignoring untrusted raw content."""
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise DossierError(f"cannot read source package {path}: {error}") from error
    if not isinstance(raw, dict) or raw.get("schema_version") != SCHEMA_VERSION:
        raise DossierError(f"source package {path} has unsupported schema_version")
    source_id = required_text(raw.get("source_id"), "source_id", 120)
    source_type = required_text(raw.get("source_type"), "source_type", 64)
    authorization_mode = required_text(raw.get("authorization_mode"), "authorization_mode", 64)
    status = required_text(raw.get("status"), "status", 64)
    sensitivity = required_text(raw.get("sensitivity"), "sensitivity", 64)
    confidence = required_text(raw.get("confidence"), "confidence", 64)
    if source_type not in SOURCE_TYPES or authorization_mode not in AUTHORIZATION_MODES or status not in SOURCE_STATUSES or sensitivity not in SENSITIVITIES or confidence not in CONFIDENCES:
        raise DossierError(f"source package {path} has unsupported source metadata")
    captured_at_text, captured_at = parse_time(raw.get("captured_at"), "captured_at")
    ledger = {"source_id": source_id, "source_type": source_type, "reference": relative_reference(raw.get("reference")), "captured_at": captured_at_text, "freshness": source_freshness(captured_at, status, now), "authorization_mode": authorization_mode, "status": status, "confidence": confidence, "sensitivity": sensitivity}
    observations = raw.get("observations", [])
    if not isinstance(observations, list):
        raise DossierError(f"source package {path} observations must be an array")
    normalized: list[dict[str, Any]] = []
    for observation in observations:
        if not isinstance(observation, dict):
            raise DossierError(f"source package {path} contains a non-object observation")
        kind = required_text(observation.get("kind"), "observation kind", 64)
        if kind not in KINDS:
            raise DossierError(f"source package {path} has unsupported observation kind")
        label = required_text(observation.get("label"), "observation label", 240)
        summary = required_text(observation.get("summary"), "observation summary", 2000)
        if PRIVATE_IDENTIFIER.search(summary) or INSTRUCTION_LIKE_CONTENT.search(summary):
            raise DossierError("observation summary contains private or instruction-like content")
        item_confidence = required_text(observation.get("confidence", confidence), "observation confidence", 64)
        if item_confidence not in CONFIDENCES:
            raise DossierError("observation confidence is unsupported")
        normalized.append({"kind": kind, "insight": {"label": label, "summary": summary, "confidence": item_confidence, "evidence_source_ids": [source_id]}})
    return ledger, normalized if status in {"complete", "partial"} and ledger["freshness"] == "fresh" else []


def load_intake(campaign_dir: Path) -> dict[str, Any]:
    """Load the canonical intake that anchors role refinement."""
    intake_path = campaign_dir / "intake.json"
    try:
        intake = json.loads(intake_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise DossierError(f"cannot read campaign intake: {error}") from error
    if not isinstance(intake, dict) or intake.get("schema_version") != SCHEMA_VERSION or not isinstance(intake.get("audiences"), list):
        raise DossierError("campaign intake is unsupported or missing audiences")
    return intake


def build_dossier(campaign_id: str, intake: dict[str, Any], source_paths: list[Path], now: dt.datetime) -> dict[str, Any]:
    """Build deterministic insights and explicit source coverage from bounded packages."""
    if len(source_paths) > MAX_SOURCES:
        raise DossierError(f"at most {MAX_SOURCES} source packages are allowed")
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
    if len(observations) > MAX_OBSERVATIONS:
        raise DossierError(f"at most {MAX_OBSERVATIONS} observations are allowed")
    counts = {status: sum(item["status"] == status for item in ledgers) for status in sorted(SOURCE_STATUSES)}
    usable = [item for item in ledgers if item["status"] in {"complete", "partial"} and item["freshness"] == "fresh"]
    coverage = "complete" if usable and all(item["status"] == "complete" and item["freshness"] == "fresh" for item in ledgers) else "partial" if usable else "unavailable"
    grouped = {kind: [] for kind in KINDS}
    seen: set[tuple[str, str, str]] = set()
    for observation in observations:
        insight = observation["insight"]
        key = (observation["kind"], insight["label"].casefold(), insight["summary"].casefold())
        if key not in seen:
            grouped[observation["kind"]].append(insight)
            seen.add(key)
    roles = sorted({role for audience in intake["audiences"] if isinstance(audience, dict) for role in audience.get("buying_roles", []) if isinstance(role, str) and role})
    intake_audiences = [{"label": required_text(audience.get("segment"), "intake audience", 240), "summary": "Research question seeded from the approved campaign intake.", "confidence": "medium", "evidence_source_ids": ["campaign-intake"]} for audience in intake["audiences"] if isinstance(audience, dict)]
    snapshot = {"campaign_id": campaign_id, "intake": intake, "ledger": ledgers, "observations": observations}
    dossier = {"schema_version": SCHEMA_VERSION, "campaign_id": campaign_id, "semantic_snapshot_sha256": hashlib.sha256(canonical_bytes(snapshot)).hexdigest(), "generated_at": now.replace(microsecond=0).isoformat().replace("+00:00", "Z"), "coverage": {"status": coverage, "source_counts": counts}, "audiences": intake_audiences + grouped["audience"], "buying_roles": roles, "competitors": grouped["competitor"], "creators": grouped["creator"], "trends": grouped["trend"], "channel_fit": grouped["channel_fit"], "opportunities": grouped["opportunity"], "contradictions": grouped["contradiction"], "provenance_ledger": ledgers}
    validate_dossier(dossier)
    return dossier


def validate_dossier(dossier: dict[str, Any]) -> None:
    """Enforce the emitted schema invariants without a runtime JSON-schema dependency."""
    required = {"schema_version", "campaign_id", "semantic_snapshot_sha256", "generated_at", "coverage", "audiences", "buying_roles", "competitors", "creators", "trends", "channel_fit", "opportunities", "contradictions", "provenance_ledger"}
    if set(dossier) != required or dossier["schema_version"] != SCHEMA_VERSION:
        raise DossierError("generated dossier does not match schema version 1")
    if not re.fullmatch(r"[a-f0-9]{64}", dossier["semantic_snapshot_sha256"]):
        raise DossierError("generated dossier snapshot hash is invalid")
    parse_time(dossier["generated_at"], "generated_at")
    coverage = dossier["coverage"]
    if not isinstance(coverage, dict) or coverage.get("status") not in {"complete", "partial", "unavailable"} or not isinstance(coverage.get("source_counts"), dict):
        raise DossierError("generated dossier coverage is invalid")
    source_ids = set()
    for source in dossier["provenance_ledger"]:
        if not isinstance(source, dict) or set(source) != {"source_id", "source_type", "reference", "captured_at", "freshness", "authorization_mode", "status", "confidence", "sensitivity"}:
            raise DossierError("generated dossier provenance is invalid")
        if source["source_id"] in source_ids:
            raise DossierError("generated dossier provenance has duplicate source IDs")
        source_ids.add(source["source_id"])
    for key in ("audiences", "competitors", "creators", "trends", "channel_fit", "opportunities", "contradictions"):
        if not isinstance(dossier[key], list):
            raise DossierError(f"generated dossier {key} must be an array")
        for insight in dossier[key]:
            if not isinstance(insight, dict) or set(insight) != {"label", "summary", "confidence", "evidence_source_ids"}:
                raise DossierError(f"generated dossier {key} insight is invalid")
            if insight["confidence"] not in CONFIDENCES or not insight["evidence_source_ids"]:
                raise DossierError(f"generated dossier {key} confidence or provenance is invalid")


def atomic_write(path: Path, content: str) -> None:
    """Atomically replace one dossier artifact on its destination volume."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def render_summary(dossier: dict[str, Any]) -> str:
    """Render a publishable reference-only summary without raw source content."""
    lines = [f"# Campaign Research Dossier: {dossier['campaign_id']}", "", f"**Schema:** v{SCHEMA_VERSION}", f"**Coverage:** {dossier['coverage']['status']}", f"**Snapshot:** `{dossier['semantic_snapshot_sha256']}`", "", "## Source coverage", ""]
    for source in dossier["provenance_ledger"]:
        lines.append(f"- **{source['source_id']}:** {source['status']}; {source['freshness']}; {source['source_type']}; reference `{source['reference']}`")
    for key, heading in (("audiences", "Audiences"), ("competitors", "Competitors"), ("creators", "Creators and partners"), ("trends", "Trends"), ("channel_fit", "Channel fit"), ("opportunities", "Opportunities"), ("contradictions", "Contradictions and gaps")):
        lines.extend(["", f"## {heading}", ""])
        entries = dossier[key]
        if entries:
            lines.extend(f"- **{entry['label']}:** {entry['summary']}" for entry in entries)
        else:
            lines.append("- No supported evidence captured.")
    return "\n".join(lines) + "\n"


def run(arguments: argparse.Namespace) -> int:
    """Execute one campaign research run and preserve a previous dossier on failed refresh."""
    campaign_id = required_text(arguments.campaign_id, "campaign_id", 160)
    campaign_dir = Path(arguments.repo).resolve() / "_campaigns" / "active" / campaign_id
    if not campaign_dir.is_dir():
        raise DossierError(f"active campaign not found: {campaign_id}")
    now = dt.datetime.now(dt.timezone.utc)
    dossier = build_dossier(campaign_id, load_intake(campaign_dir), [Path(value) for value in arguments.source], now)
    research_dir = campaign_dir / "research"
    dossier_path = research_dir / "dossier.json"
    existing: dict[str, Any] | None = None
    try:
        existing = json.loads(dossier_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pass
    if existing and existing.get("semantic_snapshot_sha256") == dossier["semantic_snapshot_sha256"]:
        print(f"Campaign research unchanged: {dossier_path}")
        return 0
    if dossier["coverage"]["status"] == "unavailable" and existing:
        raise DossierError("all supplied sources are unavailable; previous valid dossier was preserved")
    atomic_write(dossier_path, json.dumps(dossier, indent=2, sort_keys=True) + "\n")
    atomic_write(research_dir / "dossier.md", render_summary(dossier))
    print(f"Campaign research dossier written: {dossier_path}")
    return 0


def main() -> int:
    """Parse the narrow orchestration interface."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("campaign_id")
    parser.add_argument("--repo", default=".", help="repository containing _campaigns")
    parser.add_argument("--source", action="append", default=[], help="supplied source package JSON; repeatable")
    try:
        return run(parser.parse_args())
    except DossierError as error:
        print(f"campaign research: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
