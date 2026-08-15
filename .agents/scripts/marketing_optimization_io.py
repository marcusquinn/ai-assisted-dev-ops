#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Safe input snapshots and immutable output storage for marketing optimization."""

from __future__ import annotations

import copy
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from marketing_optimization_contract import (
    EVIDENCE_REF_RE,
    MINIMUM_AGGREGATE_CELL_SIZE,
    MINIMUM_EXPERIMENT_CONVERSIONS_PER_VARIANT,
    MINIMUM_EXPERIMENT_RUNTIME_SECONDS,
    MINIMUM_EXPERIMENT_SAMPLE_PER_VARIANT,
    OptimizationError,
    OptimizationSnapshot,
    assert_public_safe,
    digest_document,
    identity_is_uncertain,
    parse_datetime,
    require_list,
    require_integer,
    require_object,
)
from marketing_optimization_event_validation import validate_normalized_event
from marketing_optimization_snapshot_validation import (
    subject_uncertainty_map,
    validate_source_summary,
    validate_subject_projection,
)
from marketing_optimization_storage import ensure_directory as ensure_storage_directory
from marketing_optimization_storage import immutable_bytes
from marketing_optimization_storage import read_bytes as read_storage_bytes
from marketing_optimization_storage import read_optional_bytes as read_optional_storage_bytes
from marketing_optimization_validation_common import ASSIGNMENT_REF_RE
from performance_contract import SOURCE_KINDS, PerformanceContractError, canonical_json, parse_timestamp, require_alias
from performance_reporting import PerformanceReporting
from performance_store import MarketingPerformanceStore
from performance_store_schema import resolve_paths as resolve_performance_paths

MAX_JSON_BYTES = 16 * 1024 * 1024


@dataclass(frozen=True)
class OptimizationPaths:
    """Repo-local paths owned by the marketing optimization layer."""

    repo: Path
    marketing: Path
    config: Path
    attribution: Path
    experiments: Path
    recommendations: Path
    assignments: Path
    snapshots: Path
    work: Path
    report_drafts: Path


@dataclass(frozen=True)
class SnapshotRequest:
    """Input and scope for one deterministic snapshot read."""

    repo: Path
    input_path: Path | None
    as_of: str | None
    account_ref: str | None = None
    campaign_id: str | None = None
    source: str | None = None


def resolve_paths(repo: Path) -> OptimizationPaths:
    """Resolve optimization paths without creating them."""
    performance = resolve_performance_paths(repo.resolve())
    marketing = performance.marketing
    return OptimizationPaths(
        repo=performance.repo,
        marketing=marketing,
        config=marketing / "_config" / "optimization.json",
        attribution=marketing / "attribution",
        experiments=marketing / "experiments",
        recommendations=marketing / "recommendations",
        assignments=marketing / "index" / "optimization-assignments",
        snapshots=marketing / "index" / "optimization-snapshots",
        work=marketing / "optimization-work",
        report_drafts=performance.repo / "_reports" / "drafts",
    )


def _ensure_directory(paths: OptimizationPaths, directory: Path, mode: int = 0o755) -> None:
    """Create a checked directory and reject symlink substitution."""
    ensure_storage_directory(paths.repo, directory, mode)


def read_json(path: Path, label: str) -> dict[str, Any]:
    """Read one bounded regular JSON object."""
    if path.is_symlink() or not path.is_file():
        raise OptimizationError(f"{label} must be a regular file")
    if path.stat().st_size > MAX_JSON_BYTES:
        raise OptimizationError(f"{label} exceeds the size limit")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise OptimizationError(f"{label} must contain valid UTF-8 JSON") from exc
    return require_object(value, label)


def read_immutable_json(paths: OptimizationPaths, path: Path, label: str) -> dict[str, Any]:
    """Read one registered artifact without following replaceable path components."""
    try:
        value = json.loads(read_storage_bytes(paths.repo, path).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise OptimizationError(f"{label} must contain valid UTF-8 JSON") from exc
    return require_object(value, label)


def read_optional_immutable_json(
    paths: OptimizationPaths,
    path: Path,
    label: str,
) -> dict[str, Any] | None:
    """Read an optional registered artifact through pinned path components."""
    payload = read_optional_storage_bytes(paths.repo, path)
    if payload is None:
        return None
    try:
        value = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise OptimizationError(f"{label} must contain valid UTF-8 JSON") from exc
    return require_object(value, label)


def immutable_json(paths: OptimizationPaths, path: Path, document: dict[str, Any]) -> Path:
    """Validate and atomically publish canonical JSON."""
    assert_public_safe(document)
    payload = (canonical_json(document) + "\n").encode("utf-8")
    return immutable_bytes(paths.repo, path, payload)


def immutable_private_json(paths: OptimizationPaths, path: Path, document: dict[str, Any]) -> Path:
    """Publish canonical pseudonymous evidence with owner-only permissions."""
    assert_public_safe(document)
    payload = (canonical_json(document) + "\n").encode("utf-8")
    return immutable_bytes(
        paths.repo,
        path,
        payload,
        file_mode=0o600,
        directory_mode=0o700,
    )


def immutable_text(paths: OptimizationPaths, path: Path, text: str) -> Path:
    """Publish one bounded public-safe text artifact."""
    assert_public_safe(text)
    return immutable_bytes(paths.repo, path, text.encode("utf-8"))


def ensure_layout(paths: OptimizationPaths) -> None:
    """Provision versioned derived-output paths and the optimization policy."""
    for directory in (
        paths.attribution,
        paths.experiments,
        paths.recommendations,
    ):
        _ensure_directory(paths, directory)
    for directory in (paths.assignments, paths.snapshots, paths.work):
        _ensure_directory(paths, directory, 0o700)
    template = Path(__file__).resolve().parent.parent / "configs" / "marketing-optimization.json.txt"
    policy = read_json(template, "marketing optimization config template")
    immutable_json(paths, paths.config, policy)


def load_policy(paths: OptimizationPaths, *, provision: bool) -> dict[str, Any]:
    """Load the local policy, optionally provisioning the canonical default."""
    if provision:
        ensure_layout(paths)
    if not paths.config.exists():
        raise OptimizationError("marketing optimization is not initialized")
    policy = read_json(paths.config, "marketing optimization config")
    if policy.get("schema") != "aidevops.marketing-optimization-config/v1" or policy.get("schema_version") != 1:
        raise OptimizationError("marketing optimization config schema is unsupported")
    floors = (
        ("default_minimum_cell_size", MINIMUM_AGGREGATE_CELL_SIZE, 1000000),
        ("default_minimum_sample_per_variant", MINIMUM_EXPERIMENT_SAMPLE_PER_VARIANT, 1000000000),
        (
            "default_minimum_conversions_per_variant",
            MINIMUM_EXPERIMENT_CONVERSIONS_PER_VARIANT,
            1000000000,
        ),
        ("default_minimum_runtime_seconds", MINIMUM_EXPERIMENT_RUNTIME_SECONDS, 31536000),
    )
    for field, minimum, maximum in floors:
        require_integer(policy.get(field), field, minimum, maximum)
    return policy


def artifact_path(paths: OptimizationPaths, kind: str, reference: str) -> Path:
    """Return a safe immutable artifact path for one typed reference."""
    filename = reference.replace(":", "-") + ".json"
    directories = {
        "attribution": paths.attribution,
        "experiment": paths.experiments,
        "recommendation": paths.recommendations,
    }
    if kind not in directories:
        raise OptimizationError("unknown optimization artifact kind")
    return directories[kind] / filename


def report_artifact_path(paths: OptimizationPaths, reference: str) -> Path:
    """Return the canonical immutable JSON path for one report reference."""
    return paths.report_drafts / reference.replace(":", "-") / "report.json"


def snapshot_artifact_path(paths: OptimizationPaths, reference: str) -> Path:
    """Return the private immutable path for one source snapshot digest."""
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", reference):
        raise OptimizationError("snapshot reference is invalid")
    return paths.snapshots / (reference.replace(":", "-") + ".json")


def assignment_artifact_path(paths: OptimizationPaths, reference: str) -> Path:
    """Return the private immutable path for pseudonymous assignment rows."""
    if not ASSIGNMENT_REF_RE.fullmatch(reference):
        raise OptimizationError("assignment reference is invalid")
    return paths.assignments / (reference.replace(":", "-") + ".json")


def _validate_event(value: Any, index: int) -> dict[str, Any]:
    """Validate the bounded event fields consumed by this layer."""
    event = require_object(value, f"events[{index}]")
    assert_public_safe(event, f"events[{index}]")
    try:
        return validate_normalized_event(event)
    except PerformanceContractError as exc:
        raise OptimizationError(f"events[{index}] violates the normalized event contract: {exc}") from exc


def _validate_subject(value: Any, index: int) -> dict[str, Any]:
    """Validate one projected pseudonymous subject."""
    return validate_subject_projection(value, index)


def _event_order_key(event: dict[str, Any]) -> tuple[Any, str]:
    """Return a chronological event key with a stable record tie-break."""
    occurred = parse_datetime(event["event"]["occurred_at"], "event occurred_at")
    return occurred, str(event["record_ref"])


def _filter_events(
    events: list[dict[str, Any]],
    as_of: str,
    source: str | None,
    account_ref: str | None,
    campaign_id: str | None,
) -> list[dict[str, Any]]:
    """Apply deterministic time and scope filters."""
    boundary = parse_datetime(as_of, "snapshot as_of")
    filtered: list[dict[str, Any]] = []
    for event in events:
        occurred = parse_datetime(event["event"]["occurred_at"], "event occurred_at")
        recorded = parse_datetime(event["source"]["recorded_at"], "source recorded_at")
        kind_matches = source is None or event["source"]["kind"] == source
        source_matches = account_ref is None or event["source"]["account_ref"] == account_ref
        campaign_matches = campaign_id is None or event["scope"]["campaign_id"] == campaign_id
        if max(occurred, recorded) <= boundary and kind_matches and source_matches and campaign_matches:
            filtered.append(event)
    return sorted(filtered, key=_event_order_key)


def _effective_events(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Resolve corrections and reject duplicate identities in one hermetic snapshot."""
    by_event_ref: dict[str, dict[str, Any]] = {}
    record_refs: set[str] = set()
    for event in events:
        event_ref = str(event["event_ref"])
        record_ref = str(event["record_ref"])
        if event_ref in by_event_ref:
            raise OptimizationError("optimization snapshot contains duplicate event_ref values")
        if record_ref in record_refs:
            raise OptimizationError("optimization snapshot contains duplicate record_ref values")
        by_event_ref[event_ref] = event
        record_refs.add(record_ref)

    corrected_refs: set[str] = set()
    for event in events:
        target_ref = event["event"].get("correction_of")
        if target_ref is None:
            continue
        target = by_event_ref.get(str(target_ref))
        if target is None:
            raise OptimizationError("optimization snapshot correction target is unavailable")
        if str(target_ref) in corrected_refs:
            raise OptimizationError("optimization snapshot correction target is ambiguous")
        if (
            event["source"]["kind"] != target["source"]["kind"]
            or event["source"]["account_ref"] != target["source"]["account_ref"]
            or event["subject"] != target["subject"]
            or event["scope"] != target["scope"]
            or {
                key: value
                for key, value in event["measurement"].items()
                if key != "value"
            }
            != {
                key: value
                for key, value in target["measurement"].items()
                if key != "value"
            }
        ):
            raise OptimizationError("optimization snapshot correction target semantics do not match")
        corrected_refs.add(str(target_ref))

    def resolved_semantics(event: dict[str, Any], seen: set[str]) -> tuple[str, str]:
        event_ref = str(event["event_ref"])
        if event_ref in seen:
            raise OptimizationError("optimization snapshot correction chain contains a cycle")
        if event["event"]["type"] != "correction":
            return str(event["event"]["type"]), str(event["event"]["occurred_at"])
        target = by_event_ref[str(event["event"]["correction_of"])]
        return resolved_semantics(target, seen | {event_ref})

    for event in events:
        if event["event"]["type"] == "correction":
            resolved_semantics(event, set())

    output: list[dict[str, Any]] = []
    for event in events:
        if str(event["event_ref"]) in corrected_refs:
            continue
        if event["event"]["type"] != "correction":
            output.append(event)
            continue
        replacement = copy.deepcopy(event)
        event_type, occurred_at = resolved_semantics(event, set())
        replacement["event"]["type"] = event_type
        replacement["event"]["occurred_at"] = occurred_at
        replacement["event"]["correction_of"] = None
        output.append(_validate_event(replacement, len(output)))
    return sorted(output, key=_event_order_key)


def _filter_sources(
    sources: list[dict[str, Any]],
    source: str | None,
    account_ref: str | None,
) -> list[dict[str, Any]]:
    """Keep source quality summaries inside the explicitly requested scope."""
    return [
        item
        for item in sources
        if (source is None or item["source"] == source)
        and (account_ref is None or item["account_ref"] == account_ref)
    ]


def _snapshot(
    as_of: str,
    events: list[dict[str, Any]],
    subjects: list[dict[str, Any]],
    sources: list[dict[str, Any]],
) -> OptimizationSnapshot:
    """Construct one scoped and canonically ordered snapshot."""
    ordered_events = copy.deepcopy(events)
    subject_ids = {event["subject"]["subject_id"] for event in ordered_events if event["subject"]["subject_id"]}
    scoped_subjects = copy.deepcopy(
        [subject for subject in subjects if subject_ids.intersection(subject["aliases"])]
    )
    ordered_subjects = sorted(scoped_subjects, key=lambda item: item["subject_id"])
    ordered_sources = sorted(
        copy.deepcopy(sources),
        key=lambda item: (str(item.get("source")), str(item.get("account_ref"))),
    )
    body = {"as_of": as_of, "events": ordered_events, "subjects": ordered_subjects, "sources": ordered_sources}
    return OptimizationSnapshot(
        as_of=as_of,
        events=tuple(ordered_events),
        subjects=tuple(ordered_subjects),
        sources=tuple(ordered_sources),
        digest=digest_document(body),
    )


def _validate_subject_coverage(
    events: list[dict[str, Any]],
    subjects: list[dict[str, Any]],
) -> None:
    """Require subject events to match one projection and uncertainty class."""
    uncertain_by_alias = subject_uncertainty_map(subjects)
    for event in events:
        subject_id = event["subject"].get("subject_id")
        if subject_id is None:
            continue
        subject_ref = str(subject_id)
        if subject_ref not in uncertain_by_alias:
            raise OptimizationError("event subject reference lacks a subject projection")
        if identity_is_uncertain(event["subject"].get("identity_state")) != uncertain_by_alias[subject_ref]:
            raise OptimizationError("event identity uncertainty conflicts with its subject projection")


def snapshot_from_document(
    document: dict[str, Any],
    *,
    source: str | None = None,
    account_ref: str | None = None,
    campaign_id: str | None = None,
) -> OptimizationSnapshot:
    """Load one hermetic normalized-event snapshot."""
    if document.get("schema") != "aidevops.marketing-optimization-snapshot/v1":
        raise OptimizationError("optimization snapshot schema is unsupported")
    if set(document) != {"schema", "as_of", "events", "subjects", "sources"}:
        raise OptimizationError("optimization snapshot fields are invalid")
    as_of = parse_timestamp(document.get("as_of"), "snapshot as_of")
    events = [_validate_event(item, index) for index, item in enumerate(require_list(document.get("events"), "events"))]
    subjects = [_validate_subject(item, index) for index, item in enumerate(require_list(document.get("subjects"), "subjects"))]
    sources = [validate_source_summary(item, index) for index, item in enumerate(require_list(document.get("sources"), "sources"))]
    filtered = _filter_events(events, as_of, source, account_ref, campaign_id)
    effective = _effective_events(filtered)
    _validate_subject_coverage(effective, subjects)
    return _snapshot(as_of, effective, subjects, _filter_sources(sources, source, account_ref))


def snapshot_document(snapshot: OptimizationSnapshot) -> dict[str, Any]:
    """Render the exact private source document committed by a snapshot digest."""
    return {
        "schema": "aidevops.marketing-optimization-snapshot/v1",
        "as_of": snapshot.as_of,
        "events": copy.deepcopy(list(snapshot.events)),
        "subjects": copy.deepcopy(list(snapshot.subjects)),
        "sources": copy.deepcopy(list(snapshot.sources)),
    }


def publish_snapshot(
    paths: OptimizationPaths,
    snapshot: OptimizationSnapshot,
    *,
    dry_run: bool,
) -> str:
    """Persist one private immutable source snapshot for later recomputation."""
    document = snapshot_document(snapshot)
    canonical = snapshot_from_document(document)
    if canonical.digest != snapshot.digest:
        raise OptimizationError("snapshot digest does not match its source evidence")
    if not dry_run:
        immutable_private_json(paths, snapshot_artifact_path(paths, snapshot.digest), document)
    return snapshot.digest


def registered_snapshot(paths: OptimizationPaths, reference: str) -> OptimizationSnapshot:
    """Resolve one source snapshot and verify its complete canonical digest."""
    document = read_immutable_json(
        paths,
        snapshot_artifact_path(paths, reference),
        "registered optimization snapshot",
    )
    snapshot = snapshot_from_document(document)
    if snapshot.digest != reference:
        raise OptimizationError("registered optimization snapshot digest does not match its content")
    return snapshot


def snapshot_from_repo(
    repo: Path,
    *,
    as_of: str,
    source: str | None = None,
    account_ref: str | None = None,
    campaign_id: str | None = None,
) -> OptimizationSnapshot:
    """Read effective events and current governance from the performance plane."""
    canonical_as_of = parse_timestamp(as_of, "snapshot as_of")
    boundary_epoch = parse_datetime(canonical_as_of, "snapshot as_of").timestamp()
    with MarketingPerformanceStore.open(repo.resolve()) as store:
        reporting = PerformanceReporting(store)
        event_records = reporting.event_records(
            source=source,
            account_ref=account_ref,
            campaign_id=campaign_id,
            now_epoch=boundary_epoch,
        )
        subject_records = reporting.subject_records(boundary_epoch)
        source_records = reporting.status(boundary_epoch)["sources"]
    events = [_validate_event(item, index) for index, item in enumerate(event_records)]
    subjects = [_validate_subject(item, index) for index, item in enumerate(subject_records)]
    sources = [validate_source_summary(item, index) for index, item in enumerate(source_records)]
    filtered = _filter_events(events, canonical_as_of, source, account_ref, campaign_id)
    effective = _effective_events(filtered)
    _validate_subject_coverage(effective, subjects)
    return _snapshot(canonical_as_of, effective, subjects, _filter_sources(sources, source, account_ref))


def load_snapshot(request: SnapshotRequest) -> OptimizationSnapshot:
    """Load a hermetic fixture or one live local performance snapshot."""
    safe_account = require_alias(request.account_ref, "account_ref") if request.account_ref is not None else None
    safe_campaign = require_alias(request.campaign_id, "campaign_id") if request.campaign_id is not None else None
    safe_source = require_alias(request.source, "source") if request.source is not None else None
    if safe_source is not None and safe_source not in SOURCE_KINDS:
        raise OptimizationError("source is unsupported")
    if request.input_path is not None:
        document = read_json(request.input_path.absolute(), "optimization snapshot")
        if request.as_of is not None and parse_timestamp(request.as_of, "as_of") != document.get("as_of"):
            raise OptimizationError("--as-of must match the fixture snapshot")
        return snapshot_from_document(
            document,
            source=safe_source,
            account_ref=safe_account,
            campaign_id=safe_campaign,
        )
    if request.as_of is None:
        raise OptimizationError("--as-of is required when reading the live performance plane")
    return snapshot_from_repo(
        request.repo,
        as_of=request.as_of,
        source=safe_source,
        account_ref=safe_account,
        campaign_id=safe_campaign,
    )


def evidence_refs(snapshot: OptimizationSnapshot) -> list[str]:
    """Return unique evidence refs without event- or subject-level output."""
    refs = {
        str(event["quality"]["evidence_ref"])
        for event in snapshot.events
        if EVIDENCE_REF_RE.fullmatch(str(event["quality"].get("evidence_ref", "")))
    }
    return sorted(refs)
