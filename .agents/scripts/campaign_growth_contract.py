#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Campaign growth evidence contract and truthful state projection."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


VERSION = 1
STAGES = ("intake", "research", "production", "review", "distribution", "performance", "report")
TERMINAL = {"succeeded", "partial", "failed", "unknown", "blocked", "review_required"}


class GrowthError(ValueError):
    """Raised when orchestration inputs or checkpoints are unsafe."""


def read_json(path: Path, label: str) -> dict[str, Any]:
    """Read one regular JSON object without following a symlink."""
    if path.is_symlink() or not path.is_file():
        raise GrowthError(f"{label} is unavailable")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise GrowthError(f"{label} must be valid UTF-8 JSON") from exc
    if not isinstance(value, dict):
        raise GrowthError(f"{label} must be a JSON object")
    return value


def digest(value: Any) -> str:
    """Return a stable source-evidence hash for idempotent recovery."""
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def campaign_dir(repo: str, campaign_id: str) -> Path:
    """Resolve an active campaign only when every ancestor is a real directory."""
    if not campaign_id or "/" in campaign_id or ".." in campaign_id:
        raise GrowthError("campaign_id must be a bounded campaign alias")
    root = Path(repo).expanduser().absolute()
    campaign = root / "_campaigns" / "active" / campaign_id
    if any(path.is_symlink() for path in (root, root / "_campaigns", root / "_campaigns" / "active", campaign)):
        raise GrowthError("campaign path must not contain symlinks")
    if not campaign.is_dir():
        raise GrowthError("active campaign is unavailable")
    return campaign.resolve()


def intake(path: Path) -> dict[str, Any]:
    """Require the fields needed to plan safely from schema-v1 intake."""
    value = read_json(path, "campaign intake")
    required = ("brand", "product", "offer", "objectives", "channels", "approvals")
    if value.get("schema_version") != VERSION or any(key not in value for key in required):
        raise GrowthError("campaign intake does not satisfy the schema-v1 orchestration minimum")
    return value


def evidence(path: Path | None, campaign: Path | None) -> dict[str, Any]:
    """Load supplied owner evidence or use the campaign-local default."""
    source = path or (campaign / "orchestration" / "evidence.json" if campaign else None)
    if source is None or not source.exists():
        return {"version": VERSION, "stages": {}}
    value = read_json(source, "campaign growth evidence")
    if value.get("version") != VERSION or not isinstance(value.get("stages", {}), dict):
        raise GrowthError("campaign growth evidence must use version 1 and contain stages")
    return value


def _stage(status: str, evidence_refs: list[str], operation_ids: list[str] | None = None, reason: str | None = None) -> dict[str, Any]:
    value: dict[str, Any] = {"status": status, "evidence": evidence_refs}
    if operation_ids:
        value["operation_ids"] = operation_ids
    if reason:
        value["reason"] = reason
    return value


def _owner_stage(source: dict[str, Any], stage: str) -> dict[str, Any] | None:
    candidate = source.get("stages", {}).get(stage)
    if not isinstance(candidate, dict):
        return None
    status, evidence_refs = candidate.get("status"), candidate.get("evidence")
    if status not in TERMINAL or not isinstance(evidence_refs, list) or not all(isinstance(item, str) and item for item in evidence_refs):
        raise GrowthError(f"{stage} evidence must have a truthful status and non-empty evidence references")
    operation_ids = candidate.get("operation_ids", [])
    if not isinstance(operation_ids, list) or not all(isinstance(item, str) and item for item in operation_ids):
        raise GrowthError(f"{stage} operation_ids must be strings")
    return _stage(status, evidence_refs, operation_ids, candidate.get("reason"))


def _resolve_stage(name: str, source: dict[str, Any], approvals: dict[str, Any], prior_ok: bool) -> tuple[dict[str, Any], bool]:
    if not prior_ok:
        return _stage("not_started", [], reason="an earlier owner stage is incomplete"), False
    supplied = _owner_stage(source, name)
    if supplied is None:
        status = "review_required" if name in {"review", "distribution"} else "blocked"
        return _stage(status, [], reason=f"{name} owner evidence is unavailable"), False
    if name == "review" and (approvals.get("claims") != "approved" or approvals.get("creative") != "approved"):
        return _stage("review_required", supplied["evidence"], supplied.get("operation_ids"), "claims or creative approval is absent or expired"), False
    if name == "distribution" and source.get("stages", {}).get(name, {}).get("approval") != "approved":
        return _stage("review_required", supplied["evidence"], supplied.get("operation_ids"), "distribution approval is absent or expired"), False
    return supplied, supplied["status"] == "succeeded"


def _overall_status(stages: dict[str, dict[str, Any]]) -> str:
    statuses = {entry["status"] for entry in stages.values()}
    if statuses == {"succeeded"}:
        return "succeeded"
    return next((status for status in ("unknown", "review_required", "failed", "partial") if status in statuses), "blocked")


def build_state(campaign_id: str, campaign_intake: dict[str, Any], source: dict[str, Any]) -> dict[str, Any]:
    """Project owner evidence into a single checkpoint without mutating owners."""
    stages: dict[str, dict[str, Any]] = {"intake": _stage("succeeded", ["intake.json"])}
    prior_ok = True
    approvals = campaign_intake.get("approvals", {})
    for name in STAGES[1:]:
        stages[name], prior_ok = _resolve_stage(name, source, approvals, prior_ok)
    operations = sorted({operation for stage in stages.values() for operation in stage.get("operation_ids", [])})
    return {
        "schema_version": VERSION,
        "campaign_id": campaign_id,
        "status": _overall_status(stages),
        "stages": stages,
        "operation_ids": operations,
        "evidence_hash": digest(source),
    }
