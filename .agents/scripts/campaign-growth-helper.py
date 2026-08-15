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
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from campaign_growth_contract import STAGES, GrowthError, build_state, campaign_dir, evidence, intake, read_json


STATE_FILE = "campaign-growth-state.json"


def _capabilities(script_dir: Path) -> list[dict[str, str]]:
    registry = read_json(script_dir.parent / "configs" / "capability-registry.json", "capability registry")
    names = {entry.get("name"): entry for entry in registry.get("capabilities", []) if isinstance(entry, dict)}
    required = ("campaign-research-dossiers", "social-provider-readiness", "approval-bound-social-publishing")
    result: list[dict[str, str]] = []
    for name in required:
        entry = names.get(name)
        result.append({"name": name, "status": "available" if entry else "degraded", "fallback": str(entry.get("fallback", "manual-handoff")) if entry else "manual-handoff"})
    return result


def _plan(arguments: argparse.Namespace) -> int:
    campaign_intake = intake(Path(arguments.intake).expanduser().absolute())
    plan = {
        "schema": "aidevops.campaign-growth-plan/v1",
        "dry_run": True,
        "campaign": {
            "brand": campaign_intake["brand"].get("name"),
            "product": campaign_intake["product"].get("name"),
            "offer": campaign_intake["offer"].get("summary"),
            "channels": campaign_intake["channels"],
            "objectives": campaign_intake["objectives"],
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
    return read_json(path, "campaign checkpoint") if path.exists() else None


def _status(arguments: argparse.Namespace, write: bool) -> int:
    campaign = campaign_dir(arguments.repo, arguments.campaign_id)
    campaign_intake = intake(campaign / "intake.json")
    source = evidence(Path(arguments.evidence).expanduser().absolute() if arguments.evidence else None, campaign)
    state = build_state(arguments.campaign_id, campaign_intake, source)
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
