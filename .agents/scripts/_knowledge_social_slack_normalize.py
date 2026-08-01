#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize allowlisted Slack API/export records into canonical evidence."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_slack import PROVIDER, RETENTION_LIMIT, SlackAdapterError, namespaced_id
from _knowledge_social_slack_activities import record_activities as _record_activities
from _knowledge_social_slack_evidence_guard import reject_slack_credentials
from _knowledge_social_slack_fields import optional as _optional
from _knowledge_social_slack_fields import required as _required
from _knowledge_social_slack_records import validate_record

API_SOURCE = "slack_web_api"
EXPORT_SOURCE = "slack_admin_json_export"
OBJECT_KINDS = frozenset({"workspace", "conversation", "message", "bookmark", "pin", "file"})
API_GAPS = (
    ("api_unallowlisted_conversations", "conversation_allowlist_excludes_other_workspace_content"),
    ("api_retention_history", "workspace_plan_retention_and_membership_bound_results"),
    ("api_deleted_content", "deleted_or_purged_content_is_not_guaranteed"),
    ("api_file_binaries", "file_binary_hydration_is_disabled"),
    ("api_reaction_actors", "reaction_actor_lists_may_be_truncated"),
    ("api_historical_edits", "incremental_refresh_uses_a_seven_day_overlap"),
    (
        "api_snapshot_removals",
        "removed_reactions_pins_bookmarks_memberships_and_files_are_not_reconciled",
    ),
    ("api_rich_message_surfaces", "blocks_attachments_canvases_and_huddles_are_not_normalized"),
)
IMMUTABLE_POLICY_FIELDS = (
    "slack_workspace_id",
    "slack_enterprise_id",
    "slack_token_type",
    "slack_conversation_binding_sha256",
)


@dataclass(frozen=True)
class PageContext:
    """Validated connection policy needed to normalize one Slack page."""

    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


@dataclass(frozen=True)
class NormalizationBatch:
    """Observation metadata applied to one bounded record batch."""

    observed_at: str
    source: str
    coverage: tuple[dict[str, Any], ...] = ()


def canonical_observed_at(value: Any, field: str = "page observed_at") -> str:
    """Normalize one zoned observation time for sortable durable comparisons."""
    if (
        not isinstance(value, str)
        or not value
        or "\x00" in value
        or len(value) > 64
    ):
        raise SlackAdapterError(f"Slack {field} must be ISO-8601 text")
    text = f"{value[:-1]}+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as error:
        raise SlackAdapterError(f"Slack {field} must be ISO-8601 text") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise SlackAdapterError(f"Slack {field} requires a timezone")
    return (
        parsed.astimezone(UTC)
        .isoformat(timespec="microseconds")
        .replace("+00:00", "Z")
    )


def _observed_at(payload: dict[str, Any]) -> str:
    return canonical_observed_at(payload.get("observed_at"))


def _source(payload: dict[str, Any]) -> str:
    meta = payload.get("meta")
    if not isinstance(meta, dict) or meta.get("source") not in {API_SOURCE, EXPORT_SOURCE}:
        raise SlackAdapterError("Slack page provenance is invalid")
    return str(meta["source"])


def _text(record: dict[str, Any]) -> str | None:
    values = [
        value
        for key in ("text", "title", "name", "topic", "purpose")
        if (value := _optional(record, key))
    ]
    return "\n\n".join(values) or None


def _provider_json(record: dict[str, Any], source: str) -> dict[str, Any]:
    value = {"source": source, "record": record}
    reject_slack_credentials(value)
    return value


def _object_row(
    record: dict[str, Any], selected_id: str, observed_at: str, source: str
) -> dict[str, Any] | None:
    kind = _required(record, "kind")
    if kind not in OBJECT_KINDS:
        return None
    actor = _optional(record, "actor_remote_id")
    evidence_class = "authored" if actor == selected_id and kind == "message" else "observed"
    return {
        "object_type": kind,
        "remote_id": _required(record, "remote_id"),
        "account_remote_id": actor,
        "text": _text(record),
        "created_at": _optional(record, "created_at"),
        "observed_at": observed_at,
        "evidence_class": evidence_class,
        "provider_json": _provider_json(record, source),
    }


def _account_rows(
    records: list[dict[str, Any]], context: PageContext, observed_at: str, source: str
) -> list[dict[str, Any]]:
    selected_id = _required(context.account, "id")
    workspace = _required(context.account, "workspace_id")
    rows: dict[str, dict[str, Any]] = {
        selected_id: {
            "remote_id": selected_id,
            "handle": context.account.get("username"),
            "display_name": context.account.get("username"),
            "observed_at": observed_at,
            "provider_json": {"source": source, "selected": True},
        },
        namespaced_id(workspace, "workspace_actor", workspace): {
            "remote_id": namespaced_id(workspace, "workspace_actor", workspace),
            "handle": None,
            "display_name": context.account.get("workspace_name"),
            "observed_at": observed_at,
            "provider_json": {"source": source, "workspace_actor": True},
        },
    }
    for record in records:
        if record.get("kind") == "user":
            remote_id = _required(record, "remote_id")
            rows[remote_id] = {
                "remote_id": remote_id,
                "handle": record.get("handle"),
                "display_name": record.get("display_name"),
                "observed_at": observed_at,
                "provider_json": _provider_json(record, source),
            }
        actors = [record.get("actor_remote_id"), record.get("editor_remote_id")]
        reactions = record.get("reactions", [])
        if isinstance(reactions, list):
            actors.extend(
                actor
                for reaction in reactions
                if isinstance(reaction, dict)
                for actor in reaction.get("actor_remote_ids", [])
                if isinstance(actor, str)
            )
        for actor in actors:
            if isinstance(actor, str) and actor not in rows:
                rows[actor] = {
                    "remote_id": actor,
                    "handle": None,
                    "display_name": None,
                    "observed_at": observed_at,
                    "provider_json": {"source": source, "stub": True},
                }
    return list(rows.values())


def _media_rows(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "remote_id": _required(record, "remote_id"),
            "object_remote_id": record.get("object_remote_id") or record.get("remote_id"),
            "content_sha256": None,
            "mime_type": record.get("mimetype"),
            "byte_size": record.get("size"),
            "blob_ref": None,
            "hydration_state": "metadata_only",
        }
        for record in records
        if record.get("kind") == "file"
    ]


def _connection_policy(context: PageContext, source: str) -> dict[str, Any]:
    incoming = {
        "slack_workspace_id": _required(context.account, "workspace_id"),
        "slack_enterprise_id": context.account.get("enterprise_id"),
        "slack_token_type": _required(context.account, "token_type"),
        "slack_conversation_binding_sha256": _required(
            context.account, "conversation_binding_sha256"
        ),
    }
    policy = dict(context.policy)
    present = [field for field in IMMUTABLE_POLICY_FIELDS if field in policy]
    if present and len(present) != len(IMMUTABLE_POLICY_FIELDS):
        raise SlackAdapterError("stored Slack identity policy is incomplete")
    if any(policy.get(field) != incoming[field] for field in present):
        raise SlackAdapterError("stored Slack identity policy was rebound")
    policy.update(incoming)
    policy.update(
        {
            "slack_read_scopes": context.account.get("scopes", []),
            "slack_provenance": source,
            "slack_file_hydration": "disabled",
        }
    )
    return policy


def _api_gap_coverage(observed_at: str, source: str) -> list[dict[str, Any]]:
    if source != API_SOURCE:
        return []
    return [
        {
            "stream": stream,
            "earliest_at": None,
            "latest_at": None,
            "cursor_exhausted": False,
            "retention_limit": RETENTION_LIMIT,
            "unavailable_reason": reason,
            "status": "unavailable" if stream == "api_file_binaries" else "partial",
            "observed_at": observed_at,
        }
        for stream, reason in API_GAPS
    ]


def normalize_records(
    records: list[dict[str, Any]],
    context: PageContext,
    batch: NormalizationBatch,
) -> dict[str, Any]:
    """Build one canonical Slack archive from shared API/export records."""
    source = batch.source
    if source not in {API_SOURCE, EXPORT_SOURCE}:
        raise SlackAdapterError("Slack normalization source is unsupported")
    observed_at = canonical_observed_at(batch.observed_at)
    records = [validate_record(record) for record in records]
    selected_id = _required(context.account, "id")
    objects = [
        row
        for record in records
        if (row := _object_row(record, selected_id, observed_at, source)) is not None
    ]
    activities = [
        activity
        for record in records
        for activity in _record_activities(record, selected_id, observed_at, source)
    ]
    policy = _connection_policy(context, source)
    archive = {
        "provider": PROVIDER,
        "connection_id": context.connection_id,
        "remote_account_id": selected_id,
        "exported_at": observed_at,
        "enabled_streams": list(context.enabled_streams),
        "policy": policy,
        "accounts": _account_rows(records, context, observed_at, source),
        "objects": objects,
        "activities": activities,
        "media": _media_rows(records),
        "coverage": [*_api_gap_coverage(observed_at, source), *batch.coverage],
    }
    reject_slack_credentials(archive)
    return archive


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    """Normalize one successful isolated Slack API page."""
    reject_slack_credentials(payload)
    records = payload.get("data")
    if not isinstance(records, list) or any(not isinstance(item, dict) for item in records):
        raise SlackAdapterError("Slack page data must be an array of objects")
    batch = NormalizationBatch(_observed_at(payload), _source(payload))
    return normalize_records(records, context, batch)
