#!/usr/bin/env python3
"""Deterministic historical coding-task replay benchmark.

The harness deliberately owns corpus integrity and orchestration, not provider
SDKs. Model execution goes through aidevops' supported headless runtime.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path
from typing import Any

SCHEMA = "aidevops-historical-replay/v1"
CASE_FILES = ("prompt.md", "verifier.sh", "gold.patch")
CLASSES = ("autonomous", "prescriptive")
PROFILES = ("aidevops", "wordpress-plugin", "nextjs")


class InvalidCase(RuntimeError):
    """A replay case failed closed."""


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise InvalidCase(f"cannot read valid JSON from {path.name}: {exc}") from exc


def run(command: list[str], cwd: Path, *, capture: bool = True) -> subprocess.CompletedProcess[str]:
    # Commands are argument arrays built by this harness; case scripts execute
    # only inside a disposable synthetic repository by explicit operator action.
    return subprocess.run(command, cwd=cwd, text=True, capture_output=capture, check=False)  # nosec B603


def case_identity(case_dir: Path, manifest: dict[str, Any]) -> str:
    identity = {
        "base_tree": manifest.get("base_tree"),
        "harness_policy": manifest.get("harness_policy"),
        "framework_version": manifest.get("framework_version"),
        "runtime_version": manifest.get("runtime_version"),
        "files": {name: digest(case_dir / name) for name in CASE_FILES},
    }
    return hashlib.sha256(canonical(identity)).hexdigest()


def validate_case(case_dir: Path, *, qualified: bool = False) -> dict[str, Any]:
    manifest_path = case_dir / "case.json"
    if not manifest_path.is_file():
        raise InvalidCase("missing case.json")
    manifest = load_json(manifest_path)
    required = ("profile", "experiment_class", "base_tree", "harness_policy", "framework_version", "runtime_version")
    missing = [key for key in required if not manifest.get(key)]
    if missing:
        raise InvalidCase("missing required fields: " + ", ".join(missing))
    if manifest["profile"] not in PROFILES:
        raise InvalidCase(f"unsupported profile: {manifest['profile']}")
    if manifest["experiment_class"] not in CLASSES:
        raise InvalidCase(f"unsupported experiment_class: {manifest['experiment_class']}")
    for name in CASE_FILES:
        if not (case_dir / name).is_file():
            raise InvalidCase(f"missing immutable artifact: {name}")
    actual = case_identity(case_dir, manifest)
    declared = manifest.get("case_id")
    if declared and declared != actual:
        raise InvalidCase(f"case identity mismatch: declared {declared}, calculated {actual}")
    manifest["case_id"] = actual
    receipt_path = case_dir / "qualification.json"
    if qualified or receipt_path.exists():
        receipt = load_json(receipt_path)
        if receipt.get("case_id") != actual or receipt.get("status") != "qualified":
            raise InvalidCase("missing, stale, or failed qualification receipt")
    return manifest


def export_base(case_dir: Path, manifest: dict[str, Any], destination: Path) -> None:
    archive = case_dir / "base.tar"
    if not archive.is_file():
        raise InvalidCase("missing base.tar; cases must archive a tree without future history")
    expected = manifest.get("base_tree_sha256")
    if expected and digest(archive) != expected:
        raise InvalidCase("base.tar hash mismatch")
    destination.mkdir(parents=True)
    with tarfile.open(archive) as bundle:
        root = destination.resolve()
        for member in bundle.getmembers():
            target = (destination / member.name).resolve()
            if target != root and root not in target.parents:
                raise InvalidCase("base.tar contains an unsafe path")
        bundle.extractall(destination, filter="data")
    for command in (("git", "init", "-q"), ("git", "add", "-A"), ("git", "-c", "user.name=Replay", "-c", "user.email=replay@invalid", "commit", "-qm", "synthetic base")):
        result = run(list(command), destination)
        if result.returncode:
            raise InvalidCase(f"synthetic repository creation failed: {result.stderr.strip()}")


def verifier(repo: Path, script: Path) -> subprocess.CompletedProcess[str]:
    return run(("bash", str(script)), repo)


def qualify(case_dir: Path) -> dict[str, Any]:
    manifest = validate_case(case_dir)
    with tempfile.TemporaryDirectory(prefix="aidevops-replay-") as temp:
        repo = Path(temp) / "repo"
        export_base(case_dir, manifest, repo)
        broken = verifier(repo, case_dir / "verifier.sh")
        if broken.returncode == 0:
            raise InvalidCase("broken base unexpectedly passes the target verifier")
        applied = run(("git", "apply", "--index", str(case_dir / "gold.patch")), repo)
        if applied.returncode:
            raise InvalidCase(f"gold patch does not apply: {applied.stderr.strip()}")
        first = verifier(repo, case_dir / "verifier.sh")
        second = verifier(repo, case_dir / "verifier.sh")
        if first.returncode or second.returncode:
            raise InvalidCase("gold patch fails the verifier")
        if (first.stdout, first.stderr) != (second.stdout, second.stderr):
            raise InvalidCase("verifier output is non-deterministic across identical runs")
        for command in manifest.get("pass_to_pass", []):
            check = run(("bash", "-lc", command), repo)
            if check.returncode:
                raise InvalidCase(f"pass-to-pass check failed: {command}")
    receipt = {"schema": SCHEMA, "case_id": manifest["case_id"], "status": "qualified", "verifier_sha256": digest(case_dir / "verifier.sh")}
    (case_dir / "qualification.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


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
    expected = limit
    if len(selected) != expected:
        raise InvalidCase(f"{budget} budget requires exactly {expected} qualified cases")
    return selected


def parse_models(path: Path) -> list[dict[str, str]]:
    models = load_json(path)
    if not isinstance(models, list) or not models:
        raise InvalidCase("models file must be a non-empty JSON array")
    for model in models:
        if not all(model.get(key) for key in ("model", "tier", "effort")):
            raise InvalidCase("every model requires model, tier, and effort")
    return models


def provider(model: str) -> str:
    if "/" not in model:
        raise InvalidCase(f"model must include provider prefix: {model}")
    return model.split("/", 1)[0]


def build_plan(corpus: Path, models_path: Path, budget: str, output: Path) -> dict[str, Any]:
    cases = corpus_cases(corpus, budget)
    models = parse_models(models_path)
    predictions = []
    executions = []
    for case_dir, case in cases:
        for model in models:
            prediction = {
                "case_id": case["case_id"], "profile": case["profile"],
                "experiment_class": case["experiment_class"], "model": model["model"],
                "tier": model["tier"], "effort": model["effort"],
                "success_probability": model.get("success_probability", 0.5),
                "predicted_cost_usd": model.get("predicted_cost_usd"),
                "predicted_seconds": model.get("predicted_seconds"),
                "predicted_failure_mode": model.get("predicted_failure_mode", "none"),
            }
            predictions.append(prediction)
            executions.append({**prediction, "case_directory": case_dir.name})
    ledger = {"schema": SCHEMA, "sealed": True, "predictions": predictions}
    ledger_hash = hashlib.sha256(canonical(ledger)).hexdigest()
    output.mkdir(parents=True, exist_ok=True)
    (output / "predictions.json").write_text(json.dumps(ledger, indent=2) + "\n")
    plan = {
        "schema": SCHEMA, "budget": budget, "provider_calls": False,
        "prediction_sha256": ledger_hash, "executions": executions,
        "policy": {"early_dominance_stop": True, "effort_sweeps": "discriminating-only", "route_changing_repeats": True},
    }
    (output / "plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    report = report_data(plan, [])
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
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
    return {"schema": SCHEMA, "budget": plan["budget"], "provider_calls": bool(results), "groups": grouped,
            "pairwise_separation": "requires repeated executed pairs", "prediction_calibration": "reported after outcomes",
            "integrity_caveats": ["deterministic verifier is authoritative", "diff similarity and LLM judgment are excluded", "experiment classes are never aggregated"]}


def execute(corpus: Path, plan_dir: Path, allowlist: set[str]) -> list[dict[str, Any]]:
    plan = load_json(plan_dir / "plan.json")
    ledger = load_json(plan_dir / "predictions.json")
    if hashlib.sha256(canonical(ledger)).hexdigest() != plan.get("prediction_sha256") or not ledger.get("sealed"):
        raise InvalidCase("prediction ledger is absent, unsealed, or changed")
    helper = shutil.which("headless-runtime-helper.sh")
    if not helper:
        raise InvalidCase("supported headless runtime helper is unavailable")
    results = []
    for number, item in enumerate(plan["executions"], 1):
        model_provider = provider(item["model"])
        if model_provider not in allowlist:
            raise InvalidCase(f"provider is not eligible: {model_provider}")
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
            results.append({key: item[key] for key in ("case_id", "profile", "experiment_class", "model", "tier", "effort")} |
                           {"effective_model": item["model"], "effective_effort": item["effort"], "runtime": "headless-runtime-helper.sh",
                            "runtime_exit": outcome.returncode, "verified": checked.returncode == 0, "seconds": round(time.monotonic() - started, 3),
                            "cost_usd": None, "failure_mode": "none" if checked.returncode == 0 else "verification_failed"})
    (plan_dir / "results.json").write_text(json.dumps({"schema": SCHEMA, "results": results}, indent=2) + "\n")
    report = report_data(plan, results)
    (plan_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    return results


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate")
    validate.add_argument("--case", type=Path, required=True)
    qualification = commands.add_parser("qualify")
    qualification.add_argument("--case", type=Path, required=True)
    dry = commands.add_parser("dry-run")
    dry.add_argument("--corpus", type=Path, required=True)
    dry.add_argument("--models", type=Path, required=True)
    dry.add_argument("--budget", choices=("quick", "full"), default="quick")
    dry.add_argument("--output", type=Path, required=True)
    execution = commands.add_parser("run")
    execution.add_argument("--corpus", type=Path, required=True)
    execution.add_argument("--plan", type=Path, required=True)
    execution.add_argument("--eligible-provider", action="append", required=True)
    reporting = commands.add_parser("report")
    reporting.add_argument("--plan", type=Path, required=True)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "validate":
            print(json.dumps(validate_case(args.case), sort_keys=True))
        elif args.command == "qualify":
            print(json.dumps(qualify(args.case), sort_keys=True))
        elif args.command == "dry-run":
            print(json.dumps(build_plan(args.corpus, args.models, args.budget, args.output), sort_keys=True))
        elif args.command == "run":
            print(json.dumps(execute(args.corpus, args.plan, set(args.eligible_provider)), sort_keys=True))
        elif args.command == "report":
            print((args.plan / "report.json").read_text(), end="")
        return 0
    except (InvalidCase, OSError) as exc:
        print(f"replay benchmark: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
