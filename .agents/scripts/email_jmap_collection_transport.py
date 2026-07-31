#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""JMAP query, body-fetch, and raw-message staging for filtered collection."""

from __future__ import annotations

import hashlib
import re
import shutil
import urllib.request
import uuid
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlsplit

from email_collection_receipts import (
    ReceiptContext,
    stage_collection_receipt,
)
from email_jmap_commands import (
    BODY_PROPERTIES,
    _extract_html_body,
    _extract_text_body,
)
from email_jmap_helpers import _find_response
from email_jmap_transport import _get_auth, _jmap_request, _make_auth_header
from email_match_rules import (
    MessageFields,
    fields_from_bytes,
    fields_from_mapping,
    rule_digest,
)


_BATCH_SIZE = 100
_MAX_BODY_BYTES = 1048576


@dataclass(frozen=True)
class CollectionContext:
    """Immutable authority and storage context for one JMAP folder scan."""

    session: dict[str, Any]
    api_url: str
    user: str
    account_id: str
    collection_mailbox_id: str
    folder_name: str
    folder_id: str
    rules: list[dict[str, Any]]
    state_path: str
    inbox_dir: str
    account_identities: tuple[str, ...]
    force_full: bool = False
    dry_run: bool = False


@dataclass(frozen=True)
class RuleQuery:
    """One bounded rule lineage query and its uncommitted next state."""

    key: str
    rule: dict[str, Any]
    ids: tuple[str, ...]
    query_state: str
    total: int
    has_more: bool
    mode: str


@dataclass(frozen=True)
class StagedMatch:
    """One staged raw message and its content-free collection receipt."""

    raw_path: Path | None
    destination: Path
    receipt_path: Path
    receipt_destination: Path


def _safe_component(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]", "_", value)


def _lineage_key(context: CollectionContext, rule: dict[str, Any]) -> str:
    rule_id = _safe_component(str(rule.get("id") or rule.get("name")))
    folder = _safe_component(context.folder_name)
    return (
        f"{context.collection_mailbox_id}/{folder}/jmap/filter/"
        f"{rule_id}/{rule_digest(rule)}"
    )


def _query_filter(context: CollectionContext, rule: dict[str, Any]) -> dict[str, Any]:
    query_filter: dict[str, Any] = {"inMailbox": context.folder_id}
    since_date = str((rule.get("backfill") or {}).get("since") or "")
    if since_date:
        query_filter["after"] = f"{since_date}T00:00:00Z"
    return query_filter


def _query_initial(
    context: CollectionContext, rule: dict[str, Any], key: str, limit: int
) -> RuleQuery:
    method_calls = [[
        "Email/query",
        {
            "accountId": context.account_id,
            "filter": _query_filter(context, rule),
            "sort": [{"property": "receivedAt", "isAscending": False}],
            "position": 0,
            "limit": limit,
        },
        "q0",
    ]]
    response = _jmap_request(context.api_url, context.user, method_calls)
    result = _find_response(response.get("methodResponses", []), "Email/query", "q0")
    if not result or not result.get("queryState"):
        raise ValueError("JMAP query did not return a checkpoint")
    ids = tuple(str(item) for item in result.get("ids", []))
    total = int(result.get("total", len(ids)))
    return RuleQuery(
        key, rule, ids, str(result["queryState"]), total, total > len(ids), "full"
    )


def _query_changes(
    context: CollectionContext,
    rule: dict[str, Any],
    key: str,
    saved_state: str,
    limit: int,
) -> RuleQuery:
    method_calls = [[
        "Email/queryChanges",
        {
            "accountId": context.account_id,
            "filter": _query_filter(context, rule),
            "sort": [{"property": "receivedAt", "isAscending": False}],
            "sinceQueryState": saved_state,
            "maxChanges": limit,
        },
        "qc0",
    ]]
    response = _jmap_request(context.api_url, context.user, method_calls)
    result = _find_response(
        response.get("methodResponses", []), "Email/queryChanges", "qc0"
    )
    if not result or not result.get("newQueryState"):
        raise ValueError("JMAP queryChanges did not return a checkpoint")
    ids = tuple(
        str(item["id"])
        for item in result.get("added", [])
        if isinstance(item, dict) and item.get("id")
    )
    return RuleQuery(
        key,
        rule,
        ids,
        str(result["newQueryState"]),
        len(ids),
        bool(result.get("hasMoreChanges")),
        "delta",
    )


def query_rule(
    context: CollectionContext, state: dict[str, Any], rule: dict[str, Any]
) -> RuleQuery:
    """Return one initial or incremental bounded candidate page."""
    key = _lineage_key(context, rule)
    limit = int((rule.get("backfill") or {}).get("limit", 500))
    saved_state = str(state.get(key, {}).get("query_state") or "")
    if saved_state and not context.force_full:
        return _query_changes(context, rule, key, saved_state, limit)
    return _query_initial(context, rule, key, limit)


def requested_headers(rules: list[dict[str, Any]]) -> tuple[str, ...]:
    """Return unique custom headers required by the active rules."""
    names: list[str] = []
    for rule in rules:
        block = rule.get("match") or {}
        for group in ("all", "any"):
            for condition in block.get(group) or []:
                if condition.get("field") == "header" and condition.get("header"):
                    names.append(str(condition["header"]))
    return tuple(dict.fromkeys(names))


def _body_properties(rules: list[dict[str, Any]]) -> list[str]:
    properties = list(BODY_PROPERTIES)
    properties.extend(f"header:{name}:asText" for name in requested_headers(rules))
    return list(dict.fromkeys(properties))


def fetch_bodies(
    context: CollectionContext, email_ids: list[str], rules: list[dict[str, Any]]
) -> dict[str, dict[str, Any]]:
    """Fetch complete local-match fields for a bounded candidate union."""
    fetched: dict[str, dict[str, Any]] = {}
    properties = _body_properties(rules)
    for start in range(0, len(email_ids), _BATCH_SIZE):
        batch = email_ids[start:start + _BATCH_SIZE]
        method_calls = [[
            "Email/get",
            {
                "accountId": context.account_id,
                "ids": batch,
                "properties": properties,
                "fetchTextBodyValues": True,
                "fetchHTMLBodyValues": True,
                "maxBodyValueBytes": _MAX_BODY_BYTES,
            },
            "g0",
        ]]
        response = _jmap_request(context.api_url, context.user, method_calls)
        result = _find_response(response.get("methodResponses", []), "Email/get", "g0")
        if result is None:
            raise ValueError("JMAP Email/get did not return candidate bodies")
        for email in result.get("list", []):
            email_id = str(email.get("id") or "")
            if email_id:
                fetched[email_id] = email
    return fetched


def candidate_fields(
    email: dict[str, Any], headers: tuple[str, ...]
) -> MessageFields:
    """Map a JMAP Email/get object into shared deterministic match fields."""
    body_values = email.get("bodyValues") or {}
    candidate = dict(email)
    candidate["text_body"] = _extract_text_body(email, body_values)
    candidate["html_body"] = _extract_html_body(email, body_values)
    candidate["headers"] = {
        name: email.get(f"header:{name}:asText", "") for name in headers
    }
    fields = fields_from_mapping(candidate)
    unavailable = set(fields.unavailable_fields)
    if any(value.get("isTruncated") for value in body_values.values()):
        unavailable.add("body")
    if any(f"header:{name}:asText" not in email for name in headers):
        unavailable.add("header")
    return replace(fields, unavailable_fields=tuple(sorted(unavailable)))


def _download_url(template: str, account_id: str, email: dict[str, Any]) -> str:
    values = {
        "accountId": account_id,
        "blobId": str(email.get("blobId") or ""),
        "name": f"{email.get('id', 'message')}.eml",
        "type": "message/rfc822",
    }
    if not template or not values["blobId"]:
        raise ValueError("JMAP raw-message download is unavailable")
    url = template
    for key, value in values.items():
        url = url.replace("{" + key + "}", quote(value, safe=""))
    parsed = urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("JMAP raw-message download URL must use HTTP(S)")
    return url


def _download_raw_email(context: CollectionContext, email: dict[str, Any]) -> bytes:
    url = _download_url(
        str(context.session.get("downloadUrl") or ""), context.account_id, email
    )
    auth_type, credential = _get_auth()
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": _make_auth_header(context.user, auth_type, credential),
            "Accept": "message/rfc822",
        },
        method="GET",
    )
    # The scheme and authority are validated by _download_url above.
    with urllib.request.urlopen(request, timeout=30) as response:  # nosec B310
        raw_message = response.read()
    if not raw_message:
        raise ValueError("JMAP raw-message download was empty")
    fields_from_bytes(raw_message)
    return raw_message


def _output_path(context: CollectionContext, email_id: str) -> Path:
    mailbox = _safe_component(context.collection_mailbox_id)
    folder = _safe_component(context.folder_name)
    opaque_id = hashlib.sha256(email_id.encode("utf-8")).hexdigest()[:20]
    return Path(context.inbox_dir) / f"email-{mailbox}-{folder}-jmap-{opaque_id}.eml"


def stage_matches(
    context: CollectionContext,
    matched_rules_by_email: dict[str, list[dict[str, Any]]],
    emails: dict[str, dict[str, Any]],
) -> tuple[Path, list[StagedMatch]]:
    """Download matched raw messages to an incomplete private staging folder."""
    inbox = Path(context.inbox_dir)
    inbox.mkdir(parents=True, exist_ok=True)
    stage = inbox / f".jmap-stage-{uuid.uuid4().hex}"
    stage.mkdir()
    pending: list[StagedMatch] = []
    try:
        for email_id in sorted(matched_rules_by_email):
            destination = _output_path(context, email_id)
            raw_path: Path | None = None
            receipt_base = stage / destination.name
            if not destination.is_file():
                raw_path = receipt_base
                raw_path.write_bytes(_download_raw_email(context, emails[email_id]))
            receipt_path, receipt_destination = stage_collection_receipt(
                receipt_base,
                destination,
                ReceiptContext(
                    "jmap",
                    context.collection_mailbox_id,
                    context.folder_name,
                    email_id,
                ),
                matched_rules_by_email[email_id],
            )
            pending.append(
                StagedMatch(
                    raw_path,
                    destination,
                    receipt_path,
                    receipt_destination,
                )
            )
    except Exception:
        shutil.rmtree(stage, ignore_errors=True)
        raise
    return stage, pending


def commit_matches(pending: list[StagedMatch]) -> None:
    """Publish fully downloaded raw messages using atomic same-volume renames."""
    for match in pending:
        match.receipt_path.replace(match.receipt_destination)
        if match.raw_path is not None:
            match.raw_path.replace(match.destination)
