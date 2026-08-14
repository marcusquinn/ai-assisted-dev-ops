#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Initialize, ingest, reconcile, inspect, and export marketing performance data."""

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
from typing import Any, Iterable

from performance_adapters import SUPPORTED, normalize

SCHEMA_VERSION = "aidevops.performance-marketing/v1"
EVENT_SCHEMA = "aidevops.marketing-performance-event/v1"
SUBJECT_SCHEMA = "aidevops.marketing-subject/v1"
METRIC_RE = re.compile(r"^marketing\.[a-z0-9_]+\.[a-z0-9_]+$")
SAFE_ID_RE = re.compile(r"^[A-Za-z0-9._:-]+$")
CONFIDENCE = {"low", "medium", "high", "verified"}
FRESHNESS = {"fresh", "stale", "unknown"}
VERIFICATION = {"verified", "unverified", "partial", "invalid"}


class PerformanceError(ValueError):
    """Raised when input cannot be safely normalized or projected."""


def utc_now() -> str:
    """Return a stable UTC timestamp."""
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def digest(prefix: str, *parts: str) -> str:
    """Build a stable pseudonymous identifier."""
    material = "\0".join(parts).encode("utf-8")
    return prefix + hashlib.sha256(material).hexdigest()[:32]


def atomic_json(path: Path, value: Any) -> None:
    """Atomically replace a JSON artifact on its destination volume."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def atomic_jsonl(path: Path, records: Iterable[dict[str, Any]]) -> None:
    """Atomically replace a JSONL projection."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            for record in records:
                handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def plane(repo: str) -> Path:
    """Resolve the marketing performance plane without creating it."""
    return Path(repo).resolve() / "_performance" / "marketing"


def initialize(root: Path) -> None:
    """Create a versioned, rebuildable plane layout."""
    for relative in ("raw", "projections", "state", "quarantine"):
        (root / relative).mkdir(parents=True, exist_ok=True)
    config = root / "config.json"
    if not config.exists():
        atomic_json(config, {"schema": SCHEMA_VERSION, "created_at": utc_now(), "stale_after_seconds": 172800})
    state = root / "state" / "sources.json"
    if not state.exists():
        atomic_json(state, {"schema": SCHEMA_VERSION, "sources": {}})


def read_json(path: Path, label: str) -> Any:
    """Read one JSON document with a bounded diagnostic."""
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PerformanceError(f"{label} is unavailable or invalid: {path}") from error


def read_jsonl(path: Path, *, tolerate_corrupt: bool = False) -> tuple[list[dict[str, Any]], list[int]]:
    """Read JSONL and return corrupt line numbers without exposing content."""
    records: list[dict[str, Any]] = []
    corrupt: list[int] = []
    if not path.exists():
        return records, corrupt
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise PerformanceError(f"cannot read performance record store: {path}") from error
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
            if not isinstance(value, dict):
                raise ValueError
            records.append(value)
        except (json.JSONDecodeError, ValueError):
            corrupt.append(number)
    if corrupt and not tolerate_corrupt:
        raise PerformanceError(f"corrupt JSONL lines in {path.name}: {','.join(map(str, corrupt))}")
    return records, corrupt


def require_timestamp(value: Any, field: str) -> str:
    """Validate an RFC 3339 timestamp and normalize Z for parsing."""
    if not isinstance(value, str):
        raise PerformanceError(f"{field} must be an RFC 3339 timestamp")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise PerformanceError(f"{field} must be an RFC 3339 timestamp") from error
    if parsed.tzinfo is None:
        raise PerformanceError(f"{field} must include a timezone")
    return value


def validate_source(source: Any) -> dict[str, Any]:
    """Validate source isolation, scope, coverage, and evidence."""
    if not isinstance(source, dict):
        raise PerformanceError("source must be an object")
    required = ("provider", "source_class", "account_id", "captured_at", "cursor", "coverage", "scope_status", "evidence_ref")
    missing = [key for key in required if key not in source]
    if missing:
        raise PerformanceError(f"source is missing: {', '.join(missing)}")
    if source["source_class"] not in SUPPORTED or not SAFE_ID_RE.fullmatch(str(source["account_id"])):
        raise PerformanceError("source class or account_id is invalid")
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", str(source["provider"])):
        raise PerformanceError("source provider is invalid")
    require_timestamp(source["captured_at"], "source.captured_at")
    if source["scope_status"] not in {"complete", "partial", "missing"}:
        raise PerformanceError("source.scope_status is invalid")
    if not isinstance(source["coverage"], (int, float)) or not 0 <= source["coverage"] <= 1:
        raise PerformanceError("source.coverage must be between zero and one")
    if not isinstance(source["evidence_ref"], str) or not source["evidence_ref"].strip():
        raise PerformanceError("source.evidence_ref is required")
    return source


def normalize_subject(raw: Any, source: dict[str, Any]) -> dict[str, Any]:
    """Build a pseudonymous subject; raw contact identifiers are rejected."""
    if not isinstance(raw, dict):
        raise PerformanceError("subject must be an object")
    source_hash = raw.get("source_subject_hash")
    if not isinstance(source_hash, str) or not re.fullmatch(r"sha256:[a-f0-9]{64}", source_hash):
        raise PerformanceError("subject requires a precomputed source_subject_hash; raw identifiers are not accepted")
    kind = raw.get("subject_type", "person")
    if kind not in {"person", "account", "audience"}:
        raise PerformanceError("subject_type is invalid")
    subject_id = digest("mps_", source["provider"], source["account_id"], source_hash)
    consent = raw.get("consent", [])
    suppressions = raw.get("suppressions", [])
    changes = raw.get("identity_changes", [])
    if not all(isinstance(item, dict) for item in consent + suppressions + changes):
        raise PerformanceError("subject ledger entries must be objects")
    for item in consent:
        if item.get("purpose") not in {"measurement", "marketing", "personalization"} or item.get("status") not in {"granted", "denied", "withdrawn", "unknown"}:
            raise PerformanceError("consent purpose or status is invalid")
        if item.get("lawful_basis") not in {"consent", "contract", "legitimate_interest", "legal_obligation", "unknown"}:
            raise PerformanceError("consent lawful_basis is invalid")
        require_timestamp(item.get("effective_at"), "consent.effective_at")
        if not item.get("source_ref"):
            raise PerformanceError("consent source_ref is required")
    for item in suppressions:
        if item.get("scope") not in {"all", "email", "social", "ads", "outreach"} or item.get("status") not in {"active", "revoked"}:
            raise PerformanceError("suppression scope or status is invalid")
        require_timestamp(item.get("effective_at"), "suppression.effective_at")
        if not item.get("source_ref") or not item.get("reason"):
            raise PerformanceError("suppression provenance is required")
    for item in changes:
        if item.get("action") not in {"merge", "split"} or item.get("automatic") is not False:
            raise PerformanceError("identity merge/split must be explicit and automatic=false")
        require_timestamp(item.get("effective_at"), "identity_change.effective_at")
        if not item.get("evidence_ref") or not item.get("related_subject_ids"):
            raise PerformanceError("identity change provenance is required")
    return {
        "schema": SUBJECT_SCHEMA,
        "subject_id": subject_id,
        "subject_type": kind,
        "source_links": [{
            "provider": source["provider"], "account_id": source["account_id"], "source_subject_hash": source_hash,
            "linked_at": source["captured_at"], "evidence_ref": source["evidence_ref"],
        }],
        "consent": consent, "suppressions": suppressions, "identity_changes": changes, "updated_at": source["captured_at"],
    }


def normalize_event(raw: Any, source: dict[str, Any], subjects: dict[str, str]) -> dict[str, Any]:
    """Build one stable source/account-isolated normalized event."""
    if not isinstance(raw, dict):
        raise PerformanceError("event must be an object")
    source_event_id = raw.get("source_event_id")
    if not isinstance(source_event_id, str) or not source_event_id:
        raise PerformanceError("event source_event_id is required")
    metric = raw.get("metric")
    measurement = raw.get("measurement")
    quality = raw.get("quality")
    if not isinstance(metric, dict) or not METRIC_RE.fullmatch(str(metric.get("id", ""))):
        raise PerformanceError("event metric.id must be a marketing dotted ID")
    if metric.get("kind") not in {"count", "currency", "ratio", "percentage"} or metric.get("version") != 1 or not metric.get("label"):
        raise PerformanceError("event metric definition is invalid")
    if not isinstance(measurement, dict) or not isinstance(measurement.get("value"), (int, float)):
        raise PerformanceError("event measurement.value must be numeric")
    if measurement.get("aggregation") not in {"sum", "average", "latest"} or not re.fullmatch(r"[a-z][a-z0-9_]*", str(measurement.get("unit", ""))):
        raise PerformanceError("event measurement unit or aggregation is invalid")
    currency = measurement.get("currency")
    if metric["kind"] == "currency" and (not isinstance(currency, str) or not re.fullmatch(r"[A-Z]{3}", currency)):
        raise PerformanceError("currency metrics require an ISO 4217 currency")
    if metric["kind"] != "currency" and currency is not None:
        raise PerformanceError("currency is only valid for currency metrics")
    for field in ("period_start", "period_end"):
        if measurement.get(field) is not None:
            require_timestamp(measurement[field], f"measurement.{field}")
    if (measurement.get("period_start") is None) != (measurement.get("period_end") is None):
        raise PerformanceError("measurement period bounds must both be present or null")
    event_type = raw.get("event_type", "outcome")
    if event_type not in {"touchpoint", "outcome", "correction", "refund", "cost"}:
        raise PerformanceError("event_type is invalid")
    if event_type == "refund" and measurement["value"] > 0:
        raise PerformanceError("refund values must be zero or negative")
    correction_of = raw.get("correction_of")
    if event_type == "correction" and not correction_of:
        raise PerformanceError("correction events require correction_of")
    if correction_of and not re.fullmatch(r"mpe_[a-f0-9]{32}", str(correction_of)):
        raise PerformanceError("correction_of is invalid")
    if not isinstance(quality, dict) or quality.get("confidence") not in CONFIDENCE or quality.get("freshness") not in FRESHNESS or quality.get("verification_status") not in VERIFICATION:
        raise PerformanceError("event quality is invalid")
    occurred_at = require_timestamp(raw.get("occurred_at"), "event.occurred_at")
    dimensions = raw.get("dimensions", {})
    if not isinstance(dimensions, dict) or not all(isinstance(value, (str, int, float, bool)) for value in dimensions.values()):
        raise PerformanceError("event dimensions must be scalar")
    subject_hash = raw.get("source_subject_hash")
    subject_ref = subjects.get(subject_hash) if subject_hash else raw.get("subject_ref")
    if subject_hash and not subject_ref:
        raise PerformanceError("event references an unknown source_subject_hash")
    event_id = digest("mpe_", source["provider"], source["account_id"], source_event_id)
    event_source = {key: source[key] for key in ("provider", "source_class", "account_id", "captured_at", "scope_status", "coverage")}
    event_source.update({"source_event_id": source_event_id, "evidence_ref": source["evidence_ref"]})
    return {
        "schema": EVENT_SCHEMA, "event_id": event_id, "event_type": event_type,
        "subject_ref": subject_ref, "correction_of": correction_of, "source": event_source,
        "metric": metric, "measurement": measurement, "occurred_at": occurred_at,
        "dimensions": dimensions, "quality": quality,
    }


def source_key(source: dict[str, Any]) -> str:
    """Return the checkpoint isolation key."""
    return f"{source['provider']}:{source['account_id']}"


class Lease:
    """A fail-closed per-source filesystem lease."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.descriptor: int | None = None

    def __enter__(self) -> "Lease":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self.descriptor = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.write(self.descriptor, f"{os.getpid()}\n".encode())
        except FileExistsError as error:
            raise PerformanceError("source ingest is already leased; retry after the active writer completes") from error
        return self

    def __exit__(self, *_args: object) -> None:
        if self.descriptor is not None:
            os.close(self.descriptor)
        self.path.unlink(missing_ok=True)


def append_new(path: Path, records: list[dict[str, Any]], id_field: str) -> int:
    """Durably append records not already present by stable ID."""
    existing, _ = read_jsonl(path)
    identifiers = {record[id_field] for record in existing}
    additions = [record for record in records if record[id_field] not in identifiers]
    if not additions:
        return 0
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        for record in additions:
            handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    return len(additions)


def append_versions(path: Path, records: list[dict[str, Any]]) -> int:
    """Append changed ledger versions while deduplicating exact replay."""
    existing, _ = read_jsonl(path)
    fingerprints = {json.dumps(record, sort_keys=True, separators=(",", ":")) for record in existing}
    additions = [record for record in records if json.dumps(record, sort_keys=True, separators=(",", ":")) not in fingerprints]
    if not additions:
        return 0
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        for record in additions:
            handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    return len(additions)


def project(root: Path) -> dict[str, Any]:
    """Rebuild aggregate projections from append-only normalized events."""
    events, corrupt = read_jsonl(root / "raw" / "events.jsonl", tolerate_corrupt=True)
    quarantine = [{"store": "events.jsonl", "line": line, "reason": "invalid_json"} for line in corrupt]
    groups: dict[str, dict[str, Any]] = {}
    seen: set[str] = set()
    for event in sorted(events, key=lambda item: (item.get("occurred_at", ""), item.get("event_id", ""))):
        try:
            normalized = normalize_event_projection(event)
        except PerformanceError:
            quarantine.append({"store": "events.jsonl", "event_id": event.get("event_id"), "reason": "invalid_event"})
            continue
        if normalized["event_id"] in seen:
            continue
        seen.add(normalized["event_id"])
        key_parts = [normalized["metric"]["id"], normalized["measurement"]["unit"], str(normalized["measurement"].get("currency")), json.dumps(normalized["dimensions"], sort_keys=True)]
        key = hashlib.sha256("\0".join(key_parts).encode()).hexdigest()
        group = groups.setdefault(key, {
            "schema_version": 1, "metric": normalized["metric"],
            "subject": {"type": "marketing_projection", "id": f"projection:{key[:16]}"},
            "dimensions": normalized["dimensions"],
            "measurement": {"value": 0.0, "unit": normalized["measurement"]["unit"], "currency": normalized["measurement"].get("currency"), "aggregation": "sum", "period_start": normalized["occurred_at"], "period_end": normalized["occurred_at"], "observed_at": normalized["occurred_at"], "recorded_at": utc_now()},
            "quality": {"confidence": "verified", "source_type": "derived", "source_ref": "_performance/marketing/raw/events.jsonl", "collected_by": "performance-helper.py", "evidence": [], "notes": None},
        })
        group["measurement"]["value"] += normalized["measurement"]["value"]
        group["measurement"]["period_start"] = min(group["measurement"]["period_start"], normalized["occurred_at"])
        group["measurement"]["period_end"] = max(group["measurement"]["period_end"], normalized["occurred_at"])
        group["measurement"]["observed_at"] = group["measurement"]["period_end"]
        group["quality"]["evidence"].append(normalized["event_id"])
        if normalized["quality"]["verification_status"] != "verified" or normalized["source"]["scope_status"] != "complete" or normalized["quality"]["freshness"] != "fresh":
            group["quality"]["confidence"] = "low"
            group["quality"]["notes"] = "Contains unverified, stale, or partial source evidence"
    projections = sorted(groups.values(), key=lambda item: (item["metric"]["id"], json.dumps(item["dimensions"], sort_keys=True)))
    atomic_jsonl(root / "projections" / "results.jsonl", projections)
    atomic_jsonl(root / "quarantine" / "records.jsonl", quarantine)
    return {"events": len(seen), "projections": len(projections), "quarantined": len(quarantine)}


def normalize_event_projection(event: dict[str, Any]) -> dict[str, Any]:
    """Validate persisted event fields needed by projection."""
    if event.get("schema") != EVENT_SCHEMA or not re.fullmatch(r"mpe_[a-f0-9]{32}", str(event.get("event_id", ""))):
        raise PerformanceError("persisted event schema is invalid")
    if not isinstance(event.get("measurement", {}).get("value"), (int, float)) or not METRIC_RE.fullmatch(str(event.get("metric", {}).get("id", ""))):
        raise PerformanceError("persisted event measurement is invalid")
    require_timestamp(event.get("occurred_at"), "event.occurred_at")
    return event


def load_input(path: Path, adapter: str) -> Any:
    """Load JSON for provider adapters or Markdown for legacy campaigns."""
    if adapter == "campaign" and path.suffix.lower() == ".md":
        try:
            return path.read_text(encoding="utf-8")
        except OSError as error:
            raise PerformanceError(f"campaign results are unavailable: {path}") from error
    return read_json(path, "adapter input")


def command_init(arguments: argparse.Namespace) -> int:
    """Initialize the plane."""
    root = plane(arguments.repo)
    initialize(root)
    print(json.dumps({"status": "initialized", "path": str(root)}, sort_keys=True))
    return 0


def command_validate(arguments: argparse.Namespace) -> int:
    """Validate and normalize input without mutation."""
    document = normalize(arguments.adapter, load_input(Path(arguments.input), arguments.adapter), source_account=arguments.source_account, evidence_ref=arguments.evidence_ref or arguments.input)
    source = validate_source(document.get("source"))
    subjects = [normalize_subject(item, source) for item in document.get("subjects", [])]
    refs = {item["source_links"][0]["source_subject_hash"]: item["subject_id"] for item in subjects}
    events = [normalize_event(item, source, refs) for item in document.get("events", [])]
    print(json.dumps({"status": "valid", "subjects": len(subjects), "events": len(events), "source": source_key(source)}, sort_keys=True))
    return 0


def command_ingest(arguments: argparse.Namespace) -> int:
    """Append normalized records, rebuild projections, then commit the cursor."""
    document = normalize(arguments.adapter, load_input(Path(arguments.input), arguments.adapter), source_account=arguments.source_account, evidence_ref=arguments.evidence_ref or arguments.input)
    source = validate_source(document.get("source"))
    subjects = [normalize_subject(item, source) for item in document.get("subjects", [])]
    refs = {item["source_links"][0]["source_subject_hash"]: item["subject_id"] for item in subjects}
    events = [normalize_event(item, source, refs) for item in document.get("events", [])]
    summary: dict[str, Any] = {"status": "dry-run" if arguments.dry_run else "ingested", "source": source_key(source), "subjects": len(subjects), "events": len(events)}
    if arguments.dry_run:
        print(json.dumps(summary, sort_keys=True))
        return 0
    root = plane(arguments.repo)
    initialize(root)
    lock_name = hashlib.sha256(source_key(source).encode()).hexdigest() + ".lock"
    with Lease(root / "state" / "leases" / lock_name):
        summary["subjects_added"] = append_versions(root / "raw" / "subjects.jsonl", subjects)
        summary["events_added"] = append_new(root / "raw" / "events.jsonl", events, "event_id")
        summary["projection"] = project(root)
        state_path = root / "state" / "sources.json"
        state = read_json(state_path, "source state")
        state["sources"][source_key(source)] = {
            "cursor": source["cursor"], "captured_at": source["captured_at"], "scope_status": source["scope_status"],
            "coverage": source["coverage"], "last_success_at": utc_now(), "event_count": len(events),
        }
        atomic_json(state_path, state)
    print(json.dumps(summary, sort_keys=True))
    return 0


def command_reconcile(arguments: argparse.Namespace) -> int:
    """Rebuild projections and report corrupt source state explicitly."""
    root = plane(arguments.repo)
    if not (root / "config.json").is_file():
        raise PerformanceError("marketing performance plane is not initialized")
    summary = project(root)
    summary["status"] = "reconciled"
    print(json.dumps(summary, sort_keys=True))
    return 0


def command_list(arguments: argparse.Namespace) -> int:
    """List normalized events or result projections."""
    root = plane(arguments.repo)
    path = root / ("raw/events.jsonl" if arguments.kind == "events" else "projections/results.jsonl")
    records, _ = read_jsonl(path)
    print(json.dumps(records, indent=2, sort_keys=True))
    return 0


def command_status(arguments: argparse.Namespace) -> int:
    """Report source freshness, coverage, and projection health."""
    root = plane(arguments.repo)
    config = read_json(root / "config.json", "performance config")
    state = read_json(root / "state" / "sources.json", "source state")
    now = dt.datetime.now(dt.timezone.utc)
    sources = []
    for key, value in sorted(state["sources"].items()):
        captured = dt.datetime.fromisoformat(value["captured_at"].replace("Z", "+00:00"))
        lag = max(0, int((now - captured).total_seconds()))
        sources.append({"source": key, **value, "lag_seconds": lag, "stale": lag > config["stale_after_seconds"]})
    projections, _ = read_jsonl(root / "projections" / "results.jsonl")
    quarantine, _ = read_jsonl(root / "quarantine" / "records.jsonl")
    print(json.dumps({"schema": SCHEMA_VERSION, "sources": sources, "projection_count": len(projections), "quarantine_count": len(quarantine), "partial": any(item["scope_status"] != "complete" or item["stale"] for item in sources)}, indent=2, sort_keys=True))
    return 0


def latest_by(entries: list[dict[str, Any]], key: str) -> dict[str, dict[str, Any]]:
    """Reduce time-bound ledger entries to latest per key."""
    result: dict[str, dict[str, Any]] = {}
    for entry in sorted(entries, key=lambda item: item["effective_at"]):
        result[str(entry[key])] = entry
    return result


def eligible(subject: dict[str, Any], scope: str) -> bool:
    """Fail closed unless current marketing consent is granted and suppression is absent."""
    consent = latest_by(subject.get("consent", []), "purpose").get("marketing")
    if not consent or consent["status"] != "granted":
        return False
    suppressions = latest_by(subject.get("suppressions", []), "scope")
    return not any(suppressions.get(candidate, {}).get("status") == "active" for candidate in ("all", scope))


def command_export(arguments: argparse.Namespace) -> int:
    """Export projections or consent-safe pseudonymous audience IDs."""
    root = plane(arguments.repo)
    if arguments.kind == "results":
        records, _ = read_jsonl(root / "projections" / "results.jsonl")
    else:
        subjects, _ = read_jsonl(root / "raw" / "subjects.jsonl")
        current = {item["subject_id"]: item for item in subjects}
        records = [{"subject_id": item["subject_id"], "subject_type": item["subject_type"]} for item in current.values() if eligible(item, arguments.scope)]
    output = json.dumps(records, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        path = Path(arguments.output).resolve()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(output, encoding="utf-8")
    else:
        sys.stdout.write(output)
    return 0


def add_input_arguments(parser: argparse.ArgumentParser) -> None:
    """Add common adapter arguments."""
    parser.add_argument("--adapter", choices=sorted(SUPPORTED), required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--source-account")
    parser.add_argument("--evidence-ref")
    parser.add_argument("--repo", default=".")


def main() -> int:
    """Parse the provider-neutral performance CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init")
    init.add_argument("--repo", default=".")
    init.set_defaults(handler=command_init)
    validate = commands.add_parser("validate")
    add_input_arguments(validate)
    validate.set_defaults(handler=command_validate)
    ingest = commands.add_parser("ingest")
    add_input_arguments(ingest)
    ingest.add_argument("--dry-run", action="store_true")
    ingest.set_defaults(handler=command_ingest)
    reconcile = commands.add_parser("reconcile")
    reconcile.add_argument("--repo", default=".")
    reconcile.set_defaults(handler=command_reconcile)
    listing = commands.add_parser("list")
    listing.add_argument("--repo", default=".")
    listing.add_argument("--kind", choices=("events", "results"), default="results")
    listing.set_defaults(handler=command_list)
    status = commands.add_parser("status")
    status.add_argument("--repo", default=".")
    status.set_defaults(handler=command_status)
    export = commands.add_parser("export")
    export.add_argument("--repo", default=".")
    export.add_argument("--kind", choices=("results", "audience"), default="results")
    export.add_argument("--scope", choices=("email", "social", "ads", "outreach"), default="outreach")
    export.add_argument("--output")
    export.set_defaults(handler=command_export)
    arguments = parser.parse_args()
    return arguments.handler(arguments)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (PerformanceError, ValueError) as error:
        print(f"marketing performance: {error}", file=sys.stderr)
        raise SystemExit(1)
