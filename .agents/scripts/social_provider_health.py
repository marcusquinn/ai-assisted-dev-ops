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
from _social_provider_health_actions import (
    ActionContext,
    DimensionState,
    aggregate_dimensions as _aggregate_dimensions,
    aggregate_status as _aggregate_status,
    dimensions as _dimensions,
    fallback as _fallback,
    next_action as _next_action,
    read_action_record as _read_action_record,
    readiness_status as _readiness_status,
    write_action_record as _write_action_record,
)
from _social_provider_health_evidence import (
    QUEUE_STATES,
    authentication as _authentication,
    connections as _connections,
    evidence as _evidence,
    freshness as _freshness,
    json_array as _json_array,
    latest_sync as _latest_sync,
    queue as _queue,
    stale_seconds as _stale_seconds,
)
from knowledge_social_registry import (
    PROVIDERS,
    ProviderRegistryError,
    resolve_provider,
)
from knowledge_social_store import SCHEMA_VERSION, SocialStoreError

SCHEMA = "aidevops.social-provider-health/v1"
DEFAULT_STALE_SECONDS = 86_400
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


def _canonical_provider(provider: str) -> str:
    try:
        return resolve_provider(provider).provider
    except ProviderRegistryError:
        return provider


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
    action_context = ActionContext(
        now=now,
        configured=configured,
        enabled=enabled,
        cooldown=cooldown,
        quota=quota,
        stale_after=stale_after,
    )
    actions = [
        _read_action_record(
            database,
            str(row["connection_id"]),
            action,
            action_context,
        )
        for action in read_actions
    ]
    actions.extend(
        _write_action_record(
            provider,
            action,
            operations,
            action_context,
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
            DimensionState(
                configured=configured,
                enabled=enabled,
                authenticated=authenticated,
                authorized=False,
                reachable=reachable,
                usable=False,
            )
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
            DimensionState(
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


def _validate_options(
    values: Mapping[str, Any], allowed: set[str], function_name: str
) -> None:
    unknown = set(values) - allowed
    if unknown:
        name = sorted(unknown)[0]
        raise TypeError(
            f"{function_name}() got an unexpected keyword argument '{name}'"
        )


def build_health_report(
    database: sqlite3.Connection,
    principal_id: str,
    now_epoch: int,
    **options: Any,
) -> dict[str, Any]:
    """Build one deterministic report from existing local content-free evidence."""
    _validate_options(options, {"stale_seconds", "provider"}, "build_health_report")
    stale_seconds = options.get("stale_seconds", DEFAULT_STALE_SECONDS)
    provider = options.get("provider")
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
    **options: Any,
) -> dict[str, Any]:
    """Run one bounded local reconciliation pass without provider mutation."""
    _validate_options(
        options,
        {"decisions", "cooldowns", "limit", "per_provider_limit"},
        "reconcile_provider_receipts",
    )
    decisions = options.get("decisions", ())
    cooldowns = options.get("cooldowns")
    limit = options.get("limit", 10)
    per_provider_limit = options.get("per_provider_limit", 3)
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
