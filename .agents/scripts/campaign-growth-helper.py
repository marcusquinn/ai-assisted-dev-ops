#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Coordinate evidence-backed campaign growth stages without provider writes.

This helper is deliberately an orchestration boundary.  It reads owner evidence
and writes only an atomic campaign checkpoint; research, production, outbound
queueing, performance ingestion, and reporting stay with their existing owners.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


VERSION = 1
STAGES = ("intake", "research", "production", "review", "distribution", "performance", "report")
TERMINAL = {"succeeded", "partial", "failed", "unknown", "blocked", "review_required"}
STATE_FILE = "campaign-growth-state.json"


class GrowthError(ValueError):
    """Raised when orchestration inputs or checkpoints are unsafe."""


def _read_json(path: Path, label: str) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise GrowthError(f"{label} is unavailable")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise GrowthError(f"{label} must be valid UTF-8 JSON") from exc
    if not isinstance(value, dict):
        raise GrowthError(f"{label} must be a JSON object")
    return value


def _digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _campaign_dir(repo: str, campaign_id: str) -> Path:
    if not campaign_id or "/" in campaign_id or ".." in campaign_id:
        raise GrowthError("campaign_id must be a bounded campaign alias")
    root = Path(repo).expanduser().absolute()
    campaign = root / "_campaigns" / "active" / campaign_id
    if any(path.is_symlink() for path in (root, root / "_campaigns", root / "_campaigns" / "active", campaign)):
        raise GrowthError("campaign path must not contain symlinks")
    if not campaign.is_dir():
        raise GrowthError("active campaign is unavailable")
    return campaign.resolve()


def _intake(path: Path) -> dict[str, Any]:
    value = _read_json(path, "campaign intake")
    required = ("brand", "product", "offer", "objectives", "channels", "approvals")
    if value.get("schema_version") != 1 or any(key not in value for key in required):
        raise GrowthError("campaign intake does not satisfy the schema-v1 orchestration minimum")
    return value


def _evidence(path: Path | None, campaign: Path | None) -> dict[str, Any]:
    default = campaign / "orchestration" / "evidence.json" if campaign else None
    source = path or default
    if source is None or not source.exists():
        return {"version": VERSION, "stages": {}}
    value = _read_json(source, "campaign growth evidence")
    if value.get("version") != VERSION or not isinstance(value.get("stages", {}), dict):
        raise GrowthError("campaign growth evidence must use version 1 and contain stages")
    return value


def _stage(status: str, evidence: list[str], operation_ids: list[str] | None = None, reason: str | None = None) -> dict[str, Any]:
    value: dict[str, Any] = {"status": status, "evidence": evidence}
    if operation_ids:
        value["operation_ids"] = operation_ids
    if reason:
        value["reason"] = reason
    return value


def _owner_stage(source: dict[str, Any], stage: str) -> dict[str, Any] | None:
    candidate = source.get("stages", {}).get(stage)
    if not isinstance(candidate, dict):
        return None
    status = candidate.get("status")
    evidence = candidate.get("evidence")
    if status not in TERMINAL or not isinstance(evidence, list) or not all(isinstance(item, str) and item for item in evidence):
        raise GrowthError(f"{stage} evidence must have a truthful status and non-empty evidence references")
    operation_ids = candidate.get("operation_ids", [])
    if not isinstance(operation_ids, list) or not all(isinstance(item, str) and item for item in operation_ids):
        raise GrowthError(f"{stage} operation_ids must be strings")
    return _stage(status, evidence, operation_ids, candidate.get("reason"))


def _build_state(campaign_id: str, intake: dict[str, Any], source: dict[str, Any]) -> dict[str, Any]:
    stages: dict[str, dict[str, Any]] = {
        "intake": _stage("succeeded", ["intake.json"]),
    }
    prior_ok = True
    approvals = intake.get("approvals", {})
    for name in STAGES[1:]:
        if not prior_ok:
            stages[name] = _stage("not_started", [], reason="an earlier owner stage is incomplete")
            continue
        supplied = _owner_stage(source, name)
        if supplied is None:
            if name in {"review", "distribution"}:
                stages[name] = _stage("review_required", [], reason="explicit approval and owner evidence are required")
            else:
                stages[name] = _stage("blocked", [], reason=f"{name} owner evidence is unavailable")
            prior_ok = False
            continue
        if name == "review" and (approvals.get("claims") != "approved" or approvals.get("creative") != "approved"):
            stages[name] = _stage("review_required", supplied["evidence"], supplied.get("operation_ids"), "claims or creative approval is absent or expired")
            prior_ok = False
            continue
        if name == "distribution" and source.get("stages", {}).get(name, {}).get("approval") != "approved":
            stages[name] = _stage("review_required", supplied["evidence"], supplied.get("operation_ids"), "distribution approval is absent or expired")
            prior_ok = False
            continue
        stages[name] = supplied
        prior_ok = supplied["status"] == "succeeded"
    statuses = [entry["status"] for entry in stages.values()]
    if all(status == "succeeded" for status in statuses):
        overall = "succeeded"
    elif "unknown" in statuses:
        overall = "unknown"
    elif "review_required" in statuses:
        overall = "review_required"
    elif "failed" in statuses:
        overall = "failed"
    elif "partial" in statuses:
        overall = "partial"
    else:
        overall = "blocked"
    operations = sorted({operation for stage in stages.values() for operation in stage.get("operation_ids", [])})
    return {
        "schema_version": VERSION,
        "campaign_id": campaign_id,
        "status": overall,
        "stages": stages,
        "operation_ids": operations,
        "evidence_hash": _digest(source),
    }


def _capabilities(script_dir: Path) -> list[dict[str, str]]:
    registry = _read_json(script_dir.parent / "configs" / "capability-registry.json", "capability registry")
    names = {entry.get("name"): entry for entry in registry.get("capabilities", []) if isinstance(entry, dict)}
    required = ("campaign-research-dossiers", "social-provider-readiness", "approval-bound-social-publishing")
    result: list[dict[str, str]] = []
    for name in required:
        entry = names.get(name)
        result.append({"name": name, "status": "available" if entry else "degraded", "fallback": str(entry.get("fallback", "manual-handoff")) if entry else "manual-handoff"})
    return result


def _plan(arguments: argparse.Namespace) -> int:
    intake = _intake(Path(arguments.intake).expanduser().absolute())
    plan = {
        "schema": "aidevops.campaign-growth-plan/v1",
        "dry_run": True,
        "campaign": {
            "brand": intake["brand"].get("name"),
            "product": intake["product"].get("name"),
            "offer": intake["offer"].get("summary"),
            "channels": intake["channels"],
            "objectives": intake["objectives"],
        },
        "stages": list(STAGES),
        "capabilities": _capabilities(Path(__file__).resolve().parent),
        "approvals_required": ["claims", "creative", "distribution", "budget/audience/offer changes"],
        "artifacts": ["research dossier", "production manifests", "distribution receipts", "performance summary", "report recommendation"],
        "fallbacks": ["research-unavailable", "gated-no-mutation", "approval-required-manual-handoff"],
        "mutation": False,
    }
    print(json.dumps(plan, sort_keys=True))
    return 0


def _state_path(campaign: Path) -> Path:
    destination = campaign / "orchestration" / STATE_FILE
    if destination.parent.is_symlink() or destination.is_symlink():
        raise GrowthError("campaign checkpoint path is unsafe")
    return destination


def _write_state(path: Path, state: dict[str, Any], prior: dict[str, Any] | None) -> dict[str, Any]:
    path.parent.mkdir(parents=True, exist_ok=True)
    if prior and prior.get("evidence_hash") == state["evidence_hash"]:
        state["generation"] = prior.get("generation", 1)
    else:
        state["generation"] = int(prior.get("generation", 0)) + 1 if prior else 1
    state["updated_at"] = int(time.time())
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(state, indent=2, sort_keys=True) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        Path(temporary_name).unlink(missing_ok=True)
        raise
    return state


def _load_state(path: Path) -> dict[str, Any] | None:
    return _read_json(path, "campaign checkpoint") if path.exists() else None


def _status(arguments: argparse.Namespace, write: bool) -> int:
    campaign = _campaign_dir(arguments.repo, arguments.campaign_id)
    intake = _intake(campaign / "intake.json")
    source = _evidence(Path(arguments.evidence).expanduser().absolute() if arguments.evidence else None, campaign)
    state = _build_state(arguments.campaign_id, intake, source)
    path = _state_path(campaign)
    if write:
        state = _write_state(path, state, _load_state(path))
    elif path.exists():
        state["checkpoint"] = _load_state(path)
    print(json.dumps(state, sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    plan = commands.add_parser("plan", help="Print a non-mutating campaign growth plan")
    plan.add_argument("--intake", required=True)
    plan.set_defaults(handler=_plan)
    for name, help_text, write in (
        ("status", "Show the evidence-derived orchestration state", False),
        ("start", "Create or update an orchestration checkpoint", True),
        ("resume", "Reconcile evidence and update an orchestration checkpoint", True),
    ):
        command = commands.add_parser(name, help=help_text)
        command.add_argument("campaign_id")
        command.add_argument("--repo", default=".")
        command.add_argument("--evidence", help="owner-produced stage evidence JSON")
        command.set_defaults(handler=lambda arguments, write=write: _status(arguments, write))
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        return int(arguments.handler(arguments))
    except GrowthError as error:
        print(f"campaign growth: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
