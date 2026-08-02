#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize Readwise Reader records into neutral evidence."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_readwise_reader import (
    PROVIDER,
    RETENTION_LIMIT,
    ReadwiseReaderAdapterError,
    page_data,
)
from knowledge_social_import import reject_credentials

PROVENANCE = "readwise_reader_api_v3"
GAPS = (
    ("provider_account_identity", "official_token_validation_has_no_stable_account_id"),
    ("deleted_documents", "list_api_does_not_prove_complete_deletion_history"),
    ("complete_export", "api_is_not_documented_as_a_complete_account_export"),
    ("pre_retention_history", "service_storage_practices_may_change"),
)
OBJECT_TYPES = frozenset({"document", "tag", "note", "document_state", "reading_progress", "location"})


@dataclass(frozen=True)
class PageContext:
    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


def _text(record: dict[str, Any], key: str, required: bool = False) -> str | None:
    value = record.get(key)
    if value is None and not required:
        return None
    if not isinstance(value, str) or (required and not value) or "\x00" in value:
        raise ReadwiseReaderAdapterError(f"Readwise Reader record {key} is invalid")
    return value


def _observed(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise ReadwiseReaderAdapterError("Readwise Reader observed_at is invalid")
    return value


def _coverage(observed: str) -> list[dict[str, Any]]:
    return [{
        "stream": stream, "earliest_at": None, "latest_at": None,
        "cursor_exhausted": False, "retention_limit": RETENTION_LIMIT,
        "unavailable_reason": reason, "status": "unavailable", "observed_at": observed,
    } for stream, reason in GAPS]


def _object(item: dict[str, Any], context: PageContext, observed: str) -> dict[str, Any]:
    kind = item.get("kind")
    if kind not in OBJECT_TYPES:
        raise ReadwiseReaderAdapterError("Readwise Reader item kind is unsupported")
    remote = _text(item, "remote_id", True)
    body = "\n\n".join(value for key in ("title", "body", "notes", "html", "author") if (value := _text(item, key))) or None
    provider_json = {"source": PROVENANCE, "stream": context.stream, "record": item}
    reject_credentials(provider_json)
    return {
        "object_type": kind, "remote_id": remote,
        "account_remote_id": context.account.get("id"), "text": body,
        "created_at": _text(item, "created_at") or _text(item, "saved_at"),
        "observed_at": observed, "evidence_class": "observed",
        "provider_json": provider_json,
    }


def _activity(item: dict[str, Any], context: PageContext, observed: str) -> dict[str, Any]:
    selected = _text(context.account, "id", True)
    remote = _text(item, "remote_id", True)
    return {
        "activity_type": context.stream.removesuffix("s"),
        "remote_id": f"{selected}_{context.stream}_{remote}",
        "actor_remote_id": selected, "object_remote_id": remote,
        "occurred_at": _text(item, "updated_at") or observed,
        "observed_at": observed, "state": "active",
        "provider_json": {"source": PROVENANCE, "stream": context.stream},
    }


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    reject_credentials(payload)
    observed = _observed(payload)
    items = page_data(payload)
    policy = dict(context.policy)
    policy.update({
        "reader_identity": "deployment_account_id_plus_hmac_token_binding",
        "reader_pagination": "opaque_page_cursor_with_updated_after_overlap",
        "reader_transport": "fixed_origin_stdlib_urllib_get_only",
        "reader_rate_limit": "maximum_19_requests_per_invocation_then_429_retry_after",
    })
    archive = {
        "provider": PROVIDER, "connection_id": context.connection_id,
        "remote_account_id": context.account.get("id"), "exported_at": observed,
        "enabled_streams": list(context.enabled_streams), "policy": policy,
        "accounts": [{
            "remote_id": context.account.get("id"), "handle": None,
            "display_name": None, "observed_at": observed,
            "provider_json": {"source": PROVENANCE, "binding": "deployment_owned"},
        }],
        "objects": [_object(item, context, observed) for item in items],
        "activities": [_activity(item, context, observed) for item in items],
        "media": [], "coverage": _coverage(observed),
    }
    reject_credentials(archive)
    return archive
