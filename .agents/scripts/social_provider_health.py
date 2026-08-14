#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Content-free social provider readiness and receipt reconciliation."""

from __future__ import annotations

import json
import os
import sqlite3
import tempfile
from pathlib import Path
from typing import Any, Iterable, Mapping

from _knowledge_social_outbound import OUTBOUND_PROVIDER_ACTIONS
from _knowledge_social_outbound_reconciliation import (
    ReconciliationRequest,
    bounded_reconcile,
)
from _knowledge_social_outbound_runtime import (
    active_connection_cooldown,
    outbound_health_rows,
)
from knowledge_social_registry import (
    PROVIDERS,
    ProviderRegistryError,
    resolve_provider,
)
from knowledge_social_store import SCHEMA_VERSION, SocialStoreError

SCHEMA = "aidevops.social-provider-health/v1"
DEFAULT_STALE_SECONDS = 86_400
UNWIRED_WRITE_PROVIDERS = frozenset(
    ("meta_facebook", "meta_instagram", "meta_threads", "tiktok")
)
QUEUE_STATES = (
    "draft",
    "approved",
    "claimed",
    "succeeded",
    "failed",
    "unknown",
    "cancelled",
)
DIMENSIONS = (
    "catalogued",
    "deployed",
    "installed",
    "configured",
    "enabled",
    "authenticated",
    "authorized",
    "reachable",
    "runtime_compatible",
    "tool_visible",
    "usable",
)
CATALOGUED_PROVIDER_IDS = frozenset((*PROVIDERS, *OUTBOUND_PROVIDER_ACTIONS))
MIN_HEALTH_SCHEMA_VERSION = 7


def require_health_schema(database: sqlite3.Connection) -> None:
    """Accept the read-compatible pre-reconciliation schema or current schema."""
    version = int(database.execute("PRAGMA user_version").fetchone()[0])
    if version < MIN_HEALTH_SCHEMA_VERSION or version > SCHEMA_VERSION:
        raise SocialStoreError(
            "social provider health requires schema version "
            f"{MIN_HEALTH_SCHEMA_VERSION} through {SCHEMA_VERSION}"
        )


def _json_object(value: str, label: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise SocialStoreError(f"stored social {label} is invalid") from error
    if not isinstance(parsed, dict):
        raise SocialStoreError(f"stored social {label} must be an object")
    return parsed


def _json_array(value: str, label: str) -> list[str]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise SocialStoreError(f"stored social {label} is invalid") from error
    if not isinstance(parsed, list) or any(not isinstance(item, str) for item in parsed):
        raise SocialStoreError(f"stored social {label} must be an array of text")
    return sorted(set(parsed))


def _stale_seconds(row: sqlite3.Row, fallback: int) -> int:
    policy = _json_object(str(row["policy_json"]), "health policy")
    value = policy.get("health_stale_seconds", fallback)
    if isinstance(value, bool) or not isinstance(value, int) or value < 60:
        raise SocialStoreError(
            "stored social health_stale_seconds must be an integer of at least 60"
        )
    return value


def _connections(database: sqlite3.Connection) -> list[sqlite3.Row]:
    return database.execute(
        "SELECT connection_id,provider,auth_profile_ref,enabled_streams,policy_json "
        "FROM connections ORDER BY provider,connection_id"
    ).fetchall()


def _latest_sync(
    database: sqlite3.Connection, connection_id: str
) -> sqlite3.Row | None:
    return database.execute(
        """SELECT status,failure_class,retry_after,started_at,completed_at
             FROM sync_runs WHERE connection_id=?
             ORDER BY COALESCE(completed_at,started_at,0) DESC,rowid DESC LIMIT 1""",
        (connection_id,),
    ).fetchone()


def _latest_stream_sync(
    database: sqlite3.Connection, connection_id: str, stream: str
) -> sqlite3.Row | None:
    return database.execute(
        """SELECT status,failure_class,retry_after,started_at,completed_at
             FROM sync_runs WHERE connection_id=? AND stream=?
             ORDER BY COALESCE(completed_at,started_at,0) DESC,rowid DESC LIMIT 1""",
        (connection_id, stream),
    ).fetchone()


def _canonical_provider(provider: str) -> str:
    try:
        return resolve_provider(provider).provider
    except ProviderRegistryError:
        return provider


def _queue(rows: list[dict[str, Any]], now: int) -> dict[str, int]:
    result = {state: 0 for state in QUEUE_STATES}
    for row in rows:
        state = str(row["state"])
        if state in result:
            result[state] += 1
    result["due"] = sum(
        row["state"] == "approved"
        and int(row["scheduled_at"]) <= now
        and bool(row["has_current_approval"])
        for row in rows
    )
    result["leased"] = sum(row["state"] == "claimed" for row in rows)
    result["total"] = len(rows)
    return result


def _evidence(
    sync: sqlite3.Row | None, rows: list[dict[str, Any]]
) -> dict[str, Any]:
    events: list[tuple[int, str, str | None, bool]] = []
    successes: list[int] = []
    failures: list[tuple[int, str]] = []
    if sync is not None:
        observed_at = int(sync["completed_at"] or sync["started_at"] or 0)
        status = str(sync["status"])
        failure = sync["failure_class"]
        reached = status in ("complete", "partial") or failure == "rate_limit"
        if observed_at:
            events.append((observed_at, status, failure, reached))
        if status in ("complete", "partial") and observed_at:
            successes.append(observed_at)
        if failure is not None and observed_at:
            failures.append((observed_at, str(failure)))
    for row in rows:
        observed_at = int(row["finished_at"] or 0)
        status = row["attempt_status"]
        failure = row["failure_class"]
        reached = status == "succeeded" or (
            failure == "rate_limit" and row["provider_started_at"] is not None
        )
        if status is not None and observed_at:
            events.append((observed_at, str(status), failure, reached))
        if status == "succeeded" and observed_at:
            successes.append(observed_at)
        if failure is not None and observed_at:
            failures.append((observed_at, str(failure)))
    latest = max(events, default=None, key=lambda event: event[0])
    latest_failure = max(failures, default=None, key=lambda event: event[0])
    return {
        "evidence_at": latest[0] if latest else None,
        "latest_status": latest[1] if latest else None,
        "latest_failure": latest[2] if latest else None,
        "latest_reached": latest[3] if latest else None,
        "last_success_at": max(successes, default=None),
        "last_failure_class": latest_failure[1] if latest_failure else None,
    }


def _dimensions(
    *,
    configured: bool,
    enabled: bool,
    authenticated: bool | None,
    authorized: bool,
    reachable: bool | None,
    usable: bool,
    catalogued: bool = True,
    deployed: bool = True,
    installed: bool = True,
    runtime_compatible: bool = True,
    tool_visible: bool = True,
) -> dict[str, bool | None]:
    return {
        "catalogued": catalogued,
        "deployed": deployed,
        "installed": installed,
        "configured": configured,
        "enabled": enabled,
        "authenticated": authenticated,
        "authorized": authorized,
        "reachable": reachable,
        "runtime_compatible": runtime_compatible,
        "tool_visible": tool_visible,
        "usable": usable,
    }


def _aggregate_dimensions(records: list[dict[str, Any]]) -> dict[str, bool | None]:
    result: dict[str, bool | None] = {}
    for dimension in DIMENSIONS:
        values = [record["dimensions"][dimension] for record in records]
        result[dimension] = (
            True if True in values else False if False in values else None
        )
    return result


def _readiness_status(
    dimensions: dict[str, bool | None],
    *,
    ambiguous: bool,
    cooldown: bool,
    stale: bool,
) -> str:
    if not dimensions["configured"]:
        return "unconfigured"
    if dimensions["authenticated"] is False:
        return "unauthenticated"
    if ambiguous:
        return "ambiguous"
    if cooldown:
        return "rate_limited"
    if dimensions["reachable"] is False:
        return "unreachable"
    if stale:
        return "stale"
    if dimensions["usable"]:
        return "usable"
    if dimensions["authenticated"] is None or dimensions["reachable"] is None:
        return "unknown"
    if not dimensions["authorized"]:
        return "awaiting_approval"
    return "ready"


def _next_action(status: str, mode: str = "aggregate") -> str:
    if status == "usable" and mode == "read":
        return "collect_enabled_stream"
    return {
        "unconfigured": "configure_selected_account",
        "unauthenticated": "refresh_authentication",
        "ambiguous": "reconcile_unknown_receipt",
        "rate_limited": "wait_for_provider_reset",
        "unreachable": "inspect_provider_availability",
        "stale": "refresh_provider_health",
        "usable": "execute_approved_intent",
        "awaiting_approval": "create_and_approve_intent",
        "ready": "wait_for_due_operation",
        "partial": "inspect_account_evidence",
        "unknown": "run_provider_preflight",
    }[status]


def _fallback(status: str) -> str:
    if status == "rate_limited":
        return "wait_without_retry"
    if status == "ambiguous":
        return "owner_reconciliation_required"
    return "gated_no_mutation"


def _authentication(
    configured: bool, evidence: dict[str, Any]
) -> tuple[bool | None, bool | None]:
    if not configured:
        return False, None
    failure = evidence["latest_failure"]
    if failure in ("authorization", "identity"):
        return False, None
    if evidence["latest_reached"] is True:
        return True, True
    if failure == "provider_unavailable":
        return None, False
    return None, None


def _freshness(
    evidence: dict[str, Any], now: int, stale_after: int
) -> tuple[dict[str, int | bool | None], bool]:
    evidence_at = evidence["evidence_at"]
    lag = max(0, now - evidence_at) if evidence_at is not None else None
    stale = lag is not None and lag > stale_after
    return (
        {
            "evidence_at": evidence_at,
            "lag_seconds": lag,
            "stale_after_seconds": stale_after,
            "stale": stale,
        },
        stale,
    )


def _read_action_record(
    database: sqlite3.Connection,
    connection_id: str,
    action: str,
    now: int,
    configured: bool,
    cooldown: bool,
    quota: dict[str, int | bool | None],
    stale_after: int,
) -> dict[str, Any]:
    evidence = _evidence(
        _latest_stream_sync(database, connection_id, action), []
    )
    authenticated, reachable = _authentication(configured, evidence)
    freshness, stale = _freshness(evidence, now, stale_after)
    authorized = authenticated is True and reachable is True
    usable = bool(authorized and not cooldown and not stale)
    dimensions = _dimensions(
        configured=configured,
        enabled=True,
        authenticated=authenticated,
        authorized=authorized,
        reachable=reachable,
        usable=usable,
    )
    status = _readiness_status(
        dimensions, ambiguous=False, cooldown=cooldown, stale=stale
    )
    return {
        "action": action,
        "mode": "read",
        "dimensions": dimensions,
        "queue": _queue([], now),
        "quota": dict(quota),
        "freshness": freshness,
        "status": status,
        "fallback": _fallback(status),
        "next_action": _next_action(status, "read"),
    }


def _write_action_record(
    provider: str,
    action: str,
    rows: list[dict[str, Any]],
    now: int,
    configured: bool,
    enabled: bool,
    cooldown: bool,
    quota: dict[str, int | bool | None],
    stale_after: int,
) -> dict[str, Any]:
    action_rows = [row for row in rows if row["action"] == action]
    queue = _queue(action_rows, now)
    evidence = _evidence(None, action_rows)
    authenticated, reachable = _authentication(configured, evidence)
    if provider in UNWIRED_WRITE_PROVIDERS:
        reachable = False
    freshness, stale = _freshness(evidence, now, stale_after)
    authorized = any(
        row["state"] in ("approved", "claimed") and row["has_current_approval"]
        for row in action_rows
    )
    usable = bool(
        queue["due"]
        and configured
        and authenticated is True
        and reachable is True
        and authorized
        and not cooldown
        and not stale
        and queue["unknown"] == 0
    )
    dimensions = _dimensions(
        configured=configured,
        enabled=enabled,
        authenticated=authenticated,
        authorized=authorized,
        reachable=reachable,
        usable=usable,
    )
    status = _readiness_status(
        dimensions,
        ambiguous=queue["unknown"] > 0,
        cooldown=cooldown,
        stale=stale,
    )
    return {
        "action": action,
        "mode": "write",
        "dimensions": dimensions,
        "queue": queue,
        "quota": dict(quota),
        "freshness": dict(freshness),
        "status": status,
        "fallback": _fallback(status),
        "next_action": _next_action(status),
    }


def _aggregate_status(records: list[dict[str, Any]]) -> str:
    statuses = {str(record["status"]) for record in records}
    if len(statuses) == 1:
        return next(iter(statuses))
    if statuses and statuses <= {"ready", "usable"}:
        return "usable" if "usable" in statuses else "ready"
    return "partial"


def _account_record(
    database: sqlite3.Connection,
    row: sqlite3.Row,
    operations: list[dict[str, Any]],
    now: int,
    fallback_stale_seconds: int,
) -> dict[str, Any]:
    read_actions = _json_array(str(row["enabled_streams"]), "enabled streams")
    provider = str(row["provider"])
    write_actions = list(OUTBOUND_PROVIDER_ACTIONS.get(provider, ()))
    configured = row["auth_profile_ref"] is not None
    enabled = bool(read_actions or write_actions or operations)
    sync = _latest_sync(database, str(row["connection_id"]))
    evidence = _evidence(sync, operations)
    stale_after = _stale_seconds(row, fallback_stale_seconds)
    freshness, stale = _freshness(evidence, now, stale_after)
    cooldown_until = active_connection_cooldown(
        database, str(row["connection_id"]), now
    )
    cooldown = cooldown_until is not None
    quota: dict[str, int | bool | None] = {
        "remaining": None,
        "limit": None,
        "reset_at": cooldown_until,
        "cooldown": cooldown,
    }
    actions = [
        _read_action_record(
            database,
            str(row["connection_id"]),
            action,
            now,
            configured,
            cooldown,
            quota,
            stale_after,
        )
        for action in read_actions
    ]
    actions.extend(
        _write_action_record(
            provider,
            action,
            operations,
            now,
            configured,
            enabled,
            cooldown,
            quota,
            stale_after,
        )
        for action in write_actions
    )
    queue = _queue(operations, now)
    if actions:
        dimensions = _aggregate_dimensions(actions)
        status = _aggregate_status(actions)
    else:
        authenticated, reachable = _authentication(configured, evidence)
        dimensions = _dimensions(
            configured=configured,
            enabled=enabled,
            authenticated=authenticated,
            authorized=False,
            reachable=reachable,
            usable=False,
        )
        status = _readiness_status(
            dimensions,
            ambiguous=queue["unknown"] > 0,
            cooldown=cooldown,
            stale=stale,
        )
    return {
        "account_alias": str(row["connection_id"]),
        "status": status,
        "dimensions": dimensions,
        "supported_actions": {
            "read": read_actions,
            "write": write_actions,
        },
        "actions": actions,
        "queue": queue,
        "quota": quota,
        "freshness": freshness,
        "last_success_at": evidence["last_success_at"],
        "last_failure_class": evidence["last_failure_class"],
        "fallback": _fallback(status),
        "next_action": _next_action(
            status, "read" if read_actions and not write_actions else "aggregate"
        ),
    }


def _sum_queues(accounts: list[dict[str, Any]]) -> dict[str, int]:
    keys = (*QUEUE_STATES, "due", "leased", "total")
    return {
        key: sum(int(account["queue"][key]) for account in accounts) for key in keys
    }


def _provider_dimensions(
    provider: str, accounts: list[dict[str, Any]]
) -> dict[str, bool | None]:
    if not accounts:
        spec = PROVIDERS.get(provider)
        deployed = provider in OUTBOUND_PROVIDER_ACTIONS or (
            spec is not None and spec.entrypoint is not None
        )
        return _dimensions(
            configured=False,
            enabled=False,
            authenticated=None,
            authorized=False,
            reachable=None,
            usable=False,
            deployed=deployed,
            installed=deployed,
            tool_visible=deployed,
        )
    return _aggregate_dimensions(accounts)


def _provider_status(accounts: list[dict[str, Any]]) -> str:
    if not accounts:
        return "unconfigured"
    return _aggregate_status(accounts)


def _provider_record(provider: str, accounts: list[dict[str, Any]]) -> dict[str, Any]:
    status = _provider_status(accounts)
    latest_account = max(
        accounts,
        default=None,
        key=lambda account: account["freshness"]["evidence_at"] or 0,
    )
    read_actions = sorted(
        {
            action
            for account in accounts
            for action in account["supported_actions"]["read"]
        }
    )
    reset_values = [
        account["quota"]["reset_at"]
        for account in accounts
        if account["quota"]["reset_at"] is not None
    ]
    return {
        "provider_id": provider,
        "status": status,
        "dimensions": _provider_dimensions(provider, accounts),
        "supported_actions": {
            "read": read_actions,
            "write": list(OUTBOUND_PROVIDER_ACTIONS.get(provider, ())),
        },
        "accounts": accounts,
        "queue": _sum_queues(accounts),
        "quota": {
            "remaining": None,
            "limit": None,
            "reset_at": max(reset_values, default=None),
            "cooldown": bool(reset_values),
        },
        "freshness": (
            dict(latest_account["freshness"])
            if latest_account
            else {
                "evidence_at": None,
                "lag_seconds": None,
                "stale_after_seconds": None,
                "stale": False,
            }
        ),
        "last_success_at": max(
            (
                account["last_success_at"]
                for account in accounts
                if account["last_success_at"] is not None
            ),
            default=None,
        ),
        "last_failure_class": (
            latest_account["last_failure_class"] if latest_account else None
        ),
        "fallback": _fallback(status),
        "next_action": _next_action(
            status,
            "read"
            if read_actions and provider not in OUTBOUND_PROVIDER_ACTIONS
            else "aggregate",
        ),
    }


def _global_status(providers: list[dict[str, Any]]) -> str:
    configured = [
        provider
        for provider in providers
        if provider["dimensions"]["configured"] is True
    ]
    if not configured:
        return "unconfigured"
    if any(provider["status"] == "partial" for provider in configured):
        return "partial"
    usable = [provider for provider in configured if provider["dimensions"]["usable"]]
    if len(usable) == len(configured):
        return "healthy"
    if usable or len({provider["status"] for provider in configured}) > 1:
        return "partial"
    return "blocked"


def build_health_report(
    database: sqlite3.Connection,
    principal_id: str,
    now_epoch: int,
    *,
    stale_seconds: int = DEFAULT_STALE_SECONDS,
    provider: str | None = None,
) -> dict[str, Any]:
    """Build one deterministic report from existing local content-free evidence."""
    if now_epoch < 0:
        raise SocialStoreError("health time must be a non-negative epoch")
    if stale_seconds < 60:
        raise SocialStoreError("health stale_seconds must be at least 60")
    operation_rows = outbound_health_rows(database, principal_id, now_epoch)
    by_connection: dict[str, list[dict[str, Any]]] = {}
    for operation in operation_rows:
        by_connection.setdefault(str(operation["connection_id"]), []).append(operation)
    connections = _connections(database)
    provider_catalogue = set(CATALOGUED_PROVIDER_IDS)
    provider_catalogue.update(
        _canonical_provider(str(connection["provider"])) for connection in connections
    )
    requested_provider = _canonical_provider(provider) if provider is not None else None
    if requested_provider is not None and requested_provider not in provider_catalogue:
        raise SocialStoreError("social health provider is unsupported")
    accounts_by_provider: dict[str, list[dict[str, Any]]] = {
        provider_id: [] for provider_id in provider_catalogue
    }
    for connection in connections:
        provider_id = _canonical_provider(str(connection["provider"]))
        account = _account_record(
            database,
            connection,
            by_connection.get(str(connection["connection_id"]), []),
            now_epoch,
            stale_seconds,
        )
        accounts_by_provider[provider_id].append(account)
    provider_ids = (
        [requested_provider]
        if requested_provider is not None
        else sorted(accounts_by_provider)
    )
    providers = [
        _provider_record(provider_id, accounts_by_provider[provider_id])
        for provider_id in provider_ids
    ]
    status = _global_status(providers)
    return {
        "schema": SCHEMA,
        "generated_at": now_epoch,
        "status": status,
        "partial": status == "partial",
        "summary": {
            "catalogued_providers": len(providers),
            "configured_providers": sum(
                provider_record["dimensions"]["configured"] is True
                for provider_record in providers
            ),
            "usable_providers": sum(
                provider_record["dimensions"]["usable"] is True
                for provider_record in providers
            ),
            "queued_operations": sum(
                provider_record["queue"]["total"] for provider_record in providers
            ),
            "unresolved_unknown_receipts": sum(
                provider_record["queue"]["unknown"] for provider_record in providers
            ),
        },
        "providers": providers,
    }


def connection_cooldowns(
    database: sqlite3.Connection, now_epoch: int
) -> dict[str, int]:
    """Return active persisted reset boundaries by exact account connection."""
    result: dict[str, int] = {}
    for connection in _connections(database):
        connection_id = str(connection["connection_id"])
        reset_at = active_connection_cooldown(
            database, connection_id, now_epoch
        )
        if reset_at is not None:
            result[connection_id] = reset_at
    return result


def reconcile_provider_receipts(
    database: sqlite3.Connection,
    principal_id: str,
    now_epoch: int,
    *,
    decisions: Iterable[ReconciliationRequest] = (),
    cooldowns: Mapping[str, int] | None = None,
    limit: int = 10,
    per_provider_limit: int = 3,
) -> dict[str, Any]:
    """Run one bounded local reconciliation pass without provider mutation."""
    active_cooldowns = (
        connection_cooldowns(database, now_epoch) if cooldowns is None else cooldowns
    )
    return bounded_reconcile(
        database,
        principal_id,
        now_epoch,
        decisions=decisions,
        cooldowns=active_cooldowns,
        limit=limit,
        per_provider_limit=per_provider_limit,
    )


def write_snapshot(path: Path, report: dict[str, Any]) -> None:
    """Atomically persist an owner-only health snapshot."""
    if path.exists() and path.is_symlink():
        raise SocialStoreError("social provider health snapshot cannot be a symlink")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    descriptor, temporary = tempfile.mkstemp(
        prefix=".social-provider-health-", dir=path.parent
    )
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(report, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def render_human(report: dict[str, Any]) -> str:
    """Render a compact content-free operator summary."""
    summary = report["summary"]
    lines = [
        f"Social provider health: {report['status']}",
        (
            "Providers: "
            f"{summary['usable_providers']} usable / "
            f"{summary['configured_providers']} configured / "
            f"{summary['catalogued_providers']} catalogued"
        ),
        (
            "Queue: "
            f"{summary['queued_operations']} operations, "
            f"{summary['unresolved_unknown_receipts']} unknown receipts"
        ),
    ]
    for provider in report["providers"]:
        lines.append(
            f"- {provider['provider_id']}: {provider['status']} "
            f"({provider['next_action']})"
        )
        for account in provider["accounts"]:
            lines.append(
                f"  - {account['account_alias']}: {account['status']} "
                f"({account['next_action']})"
            )
    return "\n".join(lines)
