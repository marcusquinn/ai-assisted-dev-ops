"""Append-only owner reconciliation for performance reporting."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from typing import Any

from performance_contract import (
    PerformanceContractError,
    canonical_json,
    parse_timestamp,
    require_alias,
    utc_now,
)

SUBJECT_REF_RE = re.compile(r"^mkt-subj-v1:[a-f0-9]{64}$")
QUARANTINE_REF_RE = re.compile(r"^mkt-quarantine-v1:[a-f0-9]{64}$")
ACTION_FIELDS = {
    "link": {"action", "canonical_subject_id", "member_subject_id", "effective_at", "evidence_ref"},
    "split": {"action", "canonical_subject_id", "member_subject_id", "effective_at", "evidence_ref"},
    "resolve_quarantine": {"action", "quarantine_ref", "resolution", "effective_at", "evidence_ref"},
}


@dataclass(frozen=True)
class ActionResult:
    action_type: str
    target_ref: str
    resolution: str
    reference_parts: tuple[str, ...]
    effective_at: str
    evidence_ref: str


@dataclass(frozen=True)
class ReconciliationContext:
    action_type: str
    effective_at: str
    evidence_ref: str
    recorded_at: str


def _document_actions(document: Any) -> list[dict[str, Any]]:
    if not isinstance(document, dict) or document.get("schema") != "aidevops.marketing-performance-reconciliation/v1":
        raise PerformanceContractError("unsupported reconciliation schema")
    actions = document.get("actions")
    if not isinstance(actions, list) or not actions:
        raise PerformanceContractError("reconciliation actions must be a non-empty array")
    return actions


def _common(action: Any) -> tuple[str, str, str]:
    if not isinstance(action, dict):
        raise PerformanceContractError("reconciliation action must be an object")
    action_type = str(action.get("action"))
    expected = ACTION_FIELDS.get(action_type)
    if expected is None:
        raise PerformanceContractError("reconciliation action is unsupported")
    if set(action) != expected:
        raise PerformanceContractError("reconciliation action fields do not match the action contract")
    effective_at = parse_timestamp(action.get("effective_at"), "reconciliation.effective_at")
    evidence = require_alias(action.get("evidence_ref"), "reconciliation.evidence_ref")
    evidence_ref = "mkt-evidence-v1:sha256:" + hashlib.sha256(evidence.encode("utf-8")).hexdigest()
    return action_type, effective_at, evidence_ref


def _identity_refs(action: dict[str, Any]) -> tuple[str, str]:
    canonical = action.get("canonical_subject_id")
    member = action.get("member_subject_id")
    if not isinstance(canonical, str) or not SUBJECT_REF_RE.fullmatch(canonical):
        raise PerformanceContractError("canonical_subject_id is invalid")
    if not isinstance(member, str) or not SUBJECT_REF_RE.fullmatch(member):
        raise PerformanceContractError("member_subject_id is invalid")
    if canonical == member:
        raise PerformanceContractError("identity reconciliation requires distinct subjects")
    return canonical, member


def _require_known_subjects(reporting: Any, canonical: str, member: str) -> None:
    known = int(reporting.connection.execute("SELECT COUNT(DISTINCT subject_id) FROM events WHERE subject_id IN (?,?)", (canonical, member)).fetchone()[0])
    if known < 2:
        raise PerformanceContractError("identity reconciliation subjects must already exist")


def _reject_competing_link(reporting: Any, action_type: str, canonical: str, member: str, effective_at: str) -> None:
    competing = list(reporting.connection.execute("SELECT action,canonical_subject_id FROM identity_links WHERE member_subject_id=? AND effective_at=?", (member, effective_at)))
    conflict = any(str(row["action"]) != action_type or str(row["canonical_subject_id"]) != canonical for row in competing)
    if conflict:
        raise PerformanceContractError("identity reconciliation conflicts at the same effective time")


def _identity_action(reporting: Any, action: dict[str, Any], context: ReconciliationContext) -> ActionResult:
    action_type = context.action_type
    effective_at = context.effective_at
    evidence_ref = context.evidence_ref
    canonical, member = _identity_refs(action)
    _require_known_subjects(reporting, canonical, member)
    _reject_competing_link(reporting, action_type, canonical, member, effective_at)
    link_ref = reporting.store.pseudonym("mkt-link-v1", action_type, canonical, member, effective_at, evidence_ref)
    reporting.connection.execute(
        "INSERT OR IGNORE INTO identity_links(link_ref,action,canonical_subject_id,member_subject_id,evidence_ref,effective_at,recorded_at) VALUES(?,?,?,?,?,?,?)",
        (link_ref, action_type, canonical, member, evidence_ref, effective_at, context.recorded_at),
    )
    if action_type == "link":
        reporting._assert_identity_graph_acyclic_from(effective_at)
    return ActionResult(action_type, member, action_type, (action_type, canonical, member), effective_at, evidence_ref)


def _quarantine_action(reporting: Any, action: dict[str, Any], context: ReconciliationContext) -> ActionResult:
    action_type = context.action_type
    effective_at = context.effective_at
    evidence_ref = context.evidence_ref
    target_ref = action.get("quarantine_ref")
    resolution = action.get("resolution")
    if not isinstance(target_ref, str) or not QUARANTINE_REF_RE.fullmatch(target_ref):
        raise PerformanceContractError("quarantine_ref is invalid")
    if resolution not in {"discarded", "superseded"}:
        raise PerformanceContractError("quarantine resolution is unsupported")
    if reporting.connection.execute("SELECT 1 FROM quarantine WHERE quarantine_ref=?", (target_ref,)).fetchone() is None:
        raise PerformanceContractError("quarantine target does not exist")
    return ActionResult(action_type, target_ref, str(resolution), (action_type, target_ref, str(resolution)), effective_at, evidence_ref)


def _apply_action(reporting: Any, action: dict[str, Any], recorded_at: str) -> int:
    action_type, effective_at, evidence_ref = _common(action)
    context = ReconciliationContext(action_type, effective_at, evidence_ref, recorded_at)
    if action_type in {"link", "split"}:
        result = _identity_action(reporting, action, context)
    else:
        result = _quarantine_action(reporting, action, context)
    reconciliation_ref = reporting.store.pseudonym("mkt-reconciliation-v1", *result.reference_parts, effective_at, evidence_ref)
    payload = {key: value for key, value in action.items() if key != "evidence_ref"}
    cursor = reporting.connection.execute(
        "INSERT OR IGNORE INTO reconciliations(reconciliation_ref,action,target_ref,resolution,evidence_ref,effective_at,recorded_at,payload_json) VALUES(?,?,?,?,?,?,?,?)",
        (reconciliation_ref, action_type, result.target_ref, result.resolution, evidence_ref, effective_at, recorded_at, canonical_json(payload)),
    )
    return int(cursor.rowcount > 0)


def reconcile(reporting: Any, document: Any) -> dict[str, Any]:
    """Append explicit owner identity or quarantine decisions."""
    actions = _document_actions(document)
    recorded_at = utc_now()
    reporting.connection.execute("BEGIN IMMEDIATE")
    try:
        applied = sum(_apply_action(reporting, action, recorded_at) for action in actions)
        reporting.connection.commit()
    except Exception:
        reporting.connection.rollback()
        raise
    return {"schema": "aidevops.marketing-performance-reconciliation-result/v1", "applied": applied}
