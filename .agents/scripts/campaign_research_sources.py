#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Source-package loading for campaign research dossiers."""

from __future__ import annotations

import datetime as dt
import json
from pathlib import Path
from typing import Any

from campaign_research_common import (
    AUTHORIZATION_MODES,
    CONFIDENCES,
    INSTRUCTION_LIKE_CONTENT,
    KINDS,
    PRIVATE_IDENTIFIER,
    SCHEMA_VERSION,
    SENSITIVITIES,
    SOURCE_STATUSES,
    SOURCE_TYPES,
    DossierError,
    parse_time,
    relative_reference,
    required_text,
    source_freshness,
)


def load_source(path: Path, now: dt.datetime) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Load a supplied package, retaining only safe structured observations."""
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise DossierError(f"cannot read source package {path}: {error}") from error
    if not isinstance(raw, dict) or raw.get("schema_version") != SCHEMA_VERSION:
        raise DossierError(f"source package {path} has unsupported schema_version")
    ledger = _load_ledger(raw, path, now)
    observations = raw.get("observations", [])
    if not isinstance(observations, list):
        raise DossierError(f"source package {path} observations must be an array")
    normalized = [_normalize_observation(item, ledger["source_id"], ledger["confidence"], path) for item in observations]
    if ledger["status"] not in {"complete", "partial"} or ledger["freshness"] != "fresh":
        normalized = []
    return ledger, normalized


def _load_ledger(raw: dict[str, Any], path: Path, now: dt.datetime) -> dict[str, Any]:
    source_id = required_text(raw.get("source_id"), "source_id", 120)
    source_type = required_text(raw.get("source_type"), "source_type", 64)
    authorization_mode = required_text(raw.get("authorization_mode"), "authorization_mode", 64)
    status = required_text(raw.get("status"), "status", 64)
    sensitivity = required_text(raw.get("sensitivity"), "sensitivity", 64)
    confidence = required_text(raw.get("confidence"), "confidence", 64)
    supported = source_type in SOURCE_TYPES and authorization_mode in AUTHORIZATION_MODES
    supported = supported and status in SOURCE_STATUSES and sensitivity in SENSITIVITIES and confidence in CONFIDENCES
    if not supported:
        raise DossierError(f"source package {path} has unsupported source metadata")
    captured_at_text, captured_at = parse_time(raw.get("captured_at"), "captured_at")
    return {"source_id": source_id, "source_type": source_type, "reference": relative_reference(raw.get("reference")), "captured_at": captured_at_text, "freshness": source_freshness(captured_at, status, now), "authorization_mode": authorization_mode, "status": status, "confidence": confidence, "sensitivity": sensitivity}


def _normalize_observation(observation: Any, source_id: str, confidence: str, path: Path) -> dict[str, Any]:
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
    return {"kind": kind, "insight": {"label": label, "summary": summary, "confidence": item_confidence, "evidence_source_ids": [source_id]}}


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
