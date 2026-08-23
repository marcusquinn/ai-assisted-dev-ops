"""Sealed planning, supported-runtime execution, and deterministic reporting."""

from __future__ import annotations

import hashlib
import json
import shutil
import tempfile
import time
from pathlib import Path
from typing import Any

from _historical_replay_core import SCHEMA, InvalidCase, canonical, export_base, load_json, run, validate_case, verifier


def corpus_cases(corpus: Path, budget: str) -> list[tuple[Path, dict[str, Any]]]:
    index = load_json(corpus / "index.json")
    entries = index.get("cases", index) if isinstance(index, dict) else index
    limit = 9 if budget == "quick" else 18
    if not isinstance(entries, list):
        raise InvalidCase("corpus index must be an array or contain a cases array")
    selected: list[tuple[Path, dict[str, Any]]] = []
    for entry in entries[:limit]:
        relative = entry if isinstance(entry, str) else entry.get("directory")
        if not relative or Path(relative).is_absolute() or ".." in Path(relative).parts:
            raise InvalidCase("index contains an unsafe case directory")
        case_dir = corpus / relative
        selected.append((case_dir, validate_case(case_dir, qualified=True)))
    if len(selected) != limit:
        raise InvalidCase(f"{budget} budget requires exactly {limit} qualified cases")
    return selected


def parse_models(path: Path) -> list[dict[str, Any]]:
    models = load_json(path)
    if not isinstance(models, list) or not models:
        raise InvalidCase("models file must be a non-empty JSON array")
    if any(not all(model.get(key) for key in ("model", "tier", "effort")) for model in models):
        raise InvalidCase("every model requires model, tier, and effort")
    return models


def provider(model: str) -> str:
    if "/" not in model:
        raise InvalidCase(f"model must include provider prefix: {model}")
    return model.split("/", 1)[0]


def prediction(case: dict[str, Any], model: dict[str, Any]) -> dict[str, Any]:
    return {
        "case_id": case["case_id"], "profile": case["profile"], "experiment_class": case["experiment_class"],
        "model": model["model"], "tier": model["tier"], "effort": model["effort"],
        "success_probability": model.get("success_probability", 0.5),
        "predicted_cost_usd": model.get("predicted_cost_usd"), "predicted_seconds": model.get("predicted_seconds"),
        "predicted_failure_mode": model.get("predicted_failure_mode", "none"),
    }


def build_plan(corpus: Path, models_path: Path, budget: str, output: Path) -> dict[str, Any]:
    executions = []
    predictions = []
    for case_dir, case in corpus_cases(corpus, budget):
        for model in parse_models(models_path):
            item = prediction(case, model)
            predictions.append(item)
            executions.append({**item, "case_directory": case_dir.name})
    ledger = {"schema": SCHEMA, "sealed": True, "predictions": predictions}
    output.mkdir(parents=True, exist_ok=True)
    (output / "predictions.json").write_text(json.dumps(ledger, indent=2) + "\n")
    plan = {
        "schema": SCHEMA, "budget": budget, "provider_calls": False,
        "prediction_sha256": hashlib.sha256(canonical(ledger)).hexdigest(), "executions": executions,
        "policy": {"early_dominance_stop": True, "effort_sweeps": "discriminating-only", "route_changing_repeats": True},
    }
    (output / "plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    (output / "report.json").write_text(json.dumps(report_data(plan, []), indent=2) + "\n")
    return plan


def report_data(plan: dict[str, Any], results: list[dict[str, Any]]) -> dict[str, Any]:
    grouped: dict[str, dict[str, Any]] = {}
    for result in results:
        key = f"{result['model']}|{result['effort']}|{result['experiment_class']}"
        item = grouped.setdefault(key, {"runs": 0, "verified": 0, "cost_usd": 0.0, "seconds": 0.0})
        item["runs"] += 1
        item["verified"] += int(result["verified"])
        item["cost_usd"] += float(result.get("cost_usd") or 0)
        item["seconds"] += float(result.get("seconds") or 0)
    for item in grouped.values():
        verified = item["verified"]
        item["reliability"] = verified / item["runs"]
        item["cost_per_verified_success"] = item["cost_usd"] / verified if verified else None
        item["seconds_per_verified_success"] = item["seconds"] / verified if verified else None
    return {
        "schema": SCHEMA, "budget": plan["budget"], "provider_calls": bool(results), "groups": grouped,
        "pairwise_separation": "requires repeated executed pairs", "prediction_calibration": "reported after outcomes",
        "integrity_caveats": ["deterministic verifier is authoritative", "diff similarity and LLM judgment are excluded",
                              "experiment classes are never aggregated"],
    }


def execute_one(corpus: Path, item: dict[str, Any], helper: str, number: int) -> dict[str, Any]:
    case_dir = corpus / item["case_directory"]
    case = validate_case(case_dir, qualified=True)
    if case["case_id"] != item["case_id"]:
        raise InvalidCase("plan case identity is stale")
    with tempfile.TemporaryDirectory(prefix="aidevops-replay-run-") as temp:
        repo = Path(temp) / "repo"
        export_base(case_dir, case, repo)
        started = time.monotonic()
        command = [helper, "run", "--role", "triage", "--session-key", f"replay-{case['case_id'][:12]}-{number}",
                   "--dir", str(repo), "--title", f"Historical replay {case['case_id'][:12]}",
                   "--prompt-file", str(case_dir / "prompt.md"), "--model", item["model"], "--tier", item["tier"],
                   "--variant", item["effort"]]
        outcome = run(command, repo)
        checked = verifier(repo, case_dir / "verifier.sh")
        identity = {key: item[key] for key in ("case_id", "profile", "experiment_class", "model", "tier", "effort")}
        observed = {"effective_model": item["model"], "effective_effort": item["effort"], "runtime": "headless-runtime-helper.sh",
                    "runtime_exit": outcome.returncode, "verified": checked.returncode == 0,
                    "seconds": round(time.monotonic() - started, 3), "cost_usd": None,
                    "failure_mode": "none" if checked.returncode == 0 else "verification_failed"}
        return identity | observed


def execute(corpus: Path, plan_dir: Path, allowlist: set[str]) -> list[dict[str, Any]]:
    plan = load_json(plan_dir / "plan.json")
    ledger = load_json(plan_dir / "predictions.json")
    if hashlib.sha256(canonical(ledger)).hexdigest() != plan.get("prediction_sha256") or not ledger.get("sealed"):
        raise InvalidCase("prediction ledger is absent, unsealed, or changed")
    helper = shutil.which("headless-runtime-helper.sh")
    if not helper:
        raise InvalidCase("supported headless runtime helper is unavailable")
    if any(provider(item["model"]) not in allowlist for item in plan["executions"]):
        raise InvalidCase("execution plan contains a provider that is not eligible")
    results = [execute_one(corpus, item, helper, number) for number, item in enumerate(plan["executions"], 1)]
    (plan_dir / "results.json").write_text(json.dumps({"schema": SCHEMA, "results": results}, indent=2) + "\n")
    (plan_dir / "report.json").write_text(json.dumps(report_data(plan, results), indent=2) + "\n")
    return results
