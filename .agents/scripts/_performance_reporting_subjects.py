"""Privacy-safe subject projections for performance reporting."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

from performance_contract import timestamp_epoch, utc_now


@dataclass(frozen=True)
class SubjectContext:
    states: dict[str, str]
    identity_history: list[dict[str, Any]]
    kinds: dict[str, str]
    identity_states: dict[str, str]
    cycles: set[str]
    consent_rows: list[dict[str, Any]]
    suppression_rows: list[dict[str, Any]]
    boundary: float


def _now_timestamp(now_epoch: int | None) -> str:
    if now_epoch is None:
        return utc_now()
    return datetime.fromtimestamp(now_epoch, timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _facts(reporting: Any, identity_history: list[dict[str, Any]]) -> tuple[set[str], dict[str, str], dict[str, str]]:
    subjects: set[str] = set()
    kinds: dict[str, str] = {}
    states: dict[str, str] = {}
    for row in reporting.connection.execute("SELECT subject_id,subject_kind,identity_state FROM events WHERE subject_id IS NOT NULL"):
        subject_id = str(row["subject_id"])
        subjects.add(subject_id)
        kinds.setdefault(subject_id, str(row["subject_kind"]))
        states.setdefault(subject_id, str(row["identity_state"]))
    for row in identity_history:
        subjects.update((str(row["canonical_subject_id"]), str(row["member_subject_id"])))
    return subjects, kinds, states


def _groups(reporting: Any, subjects: set[str], links: dict[str, str]) -> tuple[dict[str, set[str]], set[str]]:
    groups: dict[str, set[str]] = defaultdict(set)
    cycles: set[str] = set()
    for subject_id in subjects:
        canonical, cycle = reporting._canonical(subject_id, links)
        groups[canonical].add(subject_id)
        if cycle:
            cycles.add(canonical)
    return groups, cycles


def _sorted_ledger(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(rows, key=lambda row: (timestamp_epoch(str(row["effective_at"])), timestamp_epoch(str(row["observed_at"])), str(row["ledger_ref"])))


def _consent_rows(reporting: Any) -> list[dict[str, Any]]:
    return _sorted_ledger([dict(row) for row in reporting.connection.execute("SELECT * FROM consent_ledger")])


def _suppression_rows(reporting: Any) -> list[dict[str, Any]]:
    return _sorted_ledger([dict(row) for row in reporting.connection.execute("SELECT * FROM suppression_ledger")])


def _latest_consent(rows: list[dict[str, Any]], boundary: float) -> dict[tuple[str, str], dict[str, Any]]:
    latest: dict[tuple[str, str], dict[str, Any]] = {}
    keys: dict[tuple[str, str], tuple[float, float, str]] = {}
    for row in rows:
        key = (str(row["subject_id"]), str(row["purpose"]))
        order = (timestamp_epoch(str(row["effective_at"])), timestamp_epoch(str(row["observed_at"])), str(row["ledger_ref"]))
        if order[0] <= boundary and order > keys.get(key, (float("-inf"), float("-inf"), "")):
            latest[key] = row
            keys[key] = order
    return latest


def _latest_suppression(rows: list[dict[str, Any]], boundary: float) -> dict[str, dict[str, Any]]:
    latest: dict[str, dict[str, Any]] = {}
    keys: dict[str, tuple[float, float, str]] = {}
    for row in rows:
        key = str(row["subject_id"])
        order = (timestamp_epoch(str(row["effective_at"])), timestamp_epoch(str(row["observed_at"])), str(row["ledger_ref"]))
        if order[0] <= boundary and order > keys.get(key, (float("-inf"), float("-inf"), "")):
            latest[key] = row
            keys[key] = order
    return latest


def _eligibility(cycle: bool, states: list[str], suppressions: dict[str, dict[str, Any]]) -> tuple[bool, str]:
    if cycle:
        return False, "identity_ambiguous"
    if any(str(row["state"]) == "suppressed" for row in suppressions.values()):
        return False, "suppressed"
    if "denied" in states:
        return False, "consent_denied"
    if states and all(state == "granted" for state in states):
        return True, "eligible"
    return False, "consent_unknown"


def _group_governance(context: SubjectContext, canonical: str, members: set[str]) -> tuple[list[dict[str, Any]], list[dict[str, Any]], bool, str]:
    consent_rows = [row for row in context.consent_rows if str(row["subject_id"]) in members]
    suppression_rows = [row for row in context.suppression_rows if str(row["subject_id"]) in members]
    latest_consent = _latest_consent(consent_rows, context.boundary)
    latest_suppression = _latest_suppression(suppression_rows, context.boundary)
    audience_states = [str(latest_consent[(member, "audience")]["state"]) if (member, "audience") in latest_consent else "unknown" for member in members]
    cycle = canonical in context.cycles
    eligible, reason = _eligibility(cycle, audience_states, latest_suppression)
    return consent_rows, suppression_rows, eligible, reason


def _group_identity(context: SubjectContext, canonical: str, members: set[str]) -> tuple[list[dict[str, Any]], str, str]:
    history = [row for row in context.identity_history if str(row["member_subject_id"]) in members]
    states = context.states
    identity_states = context.identity_states
    state = "ambiguous" if canonical in context.cycles else "linked" if len(members) > 1 else states.get(canonical, identity_states.get(canonical, "isolated"))
    kinds = context.kinds
    kind = kinds.get(canonical) or next((kinds[item] for item in sorted(members) if item in kinds), "anonymous")
    return history, state, kind


def _group_record(reporting: Any, canonical: str, members: set[str], context: SubjectContext) -> dict[str, Any]:
    consent_rows, suppression_rows, eligible, reason = _group_governance(context, canonical, members)
    history, state, kind = _group_identity(context, canonical, members)
    return {
        "schema_version": 1, "subject_id": canonical, "kind": kind,
        "identity_state": state, "canonical_subject_id": canonical, "aliases": sorted(members),
        "consent": [reporting._consent_record(row) for row in consent_rows],
        "suppression": [reporting._suppression_record(row) for row in suppression_rows],
        "identity_history": [reporting._identity_record(row) for row in history],
        "audience_eligible": eligible, "eligibility_reason": reason,
    }


def subject_records(reporting: Any, now_epoch: int | None = None) -> list[dict[str, Any]]:
    """Project subjects conservatively across explicit link/split history."""
    now_timestamp = _now_timestamp(now_epoch)
    links, states, identity_history = reporting._current_links(now_timestamp)
    subjects, kinds, identity_states = _facts(reporting, identity_history)
    groups, cycles = _groups(reporting, subjects, links)
    context = SubjectContext(
        states, identity_history, kinds, identity_states, cycles,
        _consent_rows(reporting), _suppression_rows(reporting), timestamp_epoch(now_timestamp),
    )
    return [_group_record(reporting, canonical, members, context) for canonical, members in sorted(groups.items())]
