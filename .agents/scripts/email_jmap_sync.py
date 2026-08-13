#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_jmap_sync.py - JMAP index sync and push notification operations.

Extracted from email_jmap_adapter.py to reduce file-level complexity.
Handles delta/full mailbox sync and EventSource (SSE) push notifications.
"""

import json
from collections import namedtuple

from email_jmap_collection import run_filtered_sync
from email_jmap_index import (
    _SYNC_STATE_UPSERT,
    _init_index_db,
    _upsert_jmap_email,
)
from email_jmap_transport import (
    _get_auth,
    _jmap_request,
    _make_auth_header,
    _session_context,
)
from email_jmap_helpers import _find_response, _resolve_mailbox_id
# ---------------------------------------------------------------------------
# Constants (re-exported from adapter for header fetching)
# ---------------------------------------------------------------------------

HEADER_PROPERTIES = [
    "id", "blobId", "threadId", "mailboxIds",
    "from", "to", "subject", "receivedAt",
    "sentAt", "size", "keywords", "messageId",
    "inReplyTo", "references", "preview",
]


# ---------------------------------------------------------------------------
# Sync context
# ---------------------------------------------------------------------------

SyncContext = namedtuple(
    "SyncContext",
    ["api_url", "user", "account_id", "account_key", "mailbox_id", "db_conn"],
)


# ---------------------------------------------------------------------------
# Sync state persistence
# ---------------------------------------------------------------------------

def _load_saved_sync_state(db_conn, account_key, mailbox_id):
    """Return the saved JMAP query state string, or None."""
    row = db_conn.execute(
        "SELECT state FROM jmap_sync_state "
        "WHERE account = ? AND mailbox_id = ?",
        (account_key, mailbox_id),
    ).fetchone()
    return row[0] if row else None


def _save_sync_state(db_conn, account_key, mailbox_id, state):
    """Persist a JMAP query/sync state string."""
    db_conn.execute(_SYNC_STATE_UPSERT, (account_key, mailbox_id, state))


# ---------------------------------------------------------------------------
# Email header batch fetch
# ---------------------------------------------------------------------------

def _fetch_email_headers_batch(api_url, user, account_id, email_ids):
    """Fetch header properties for a list of email IDs. Returns list or []."""
    get_calls = [
        [
            "Email/get",
            {
                "accountId": account_id,
                "ids": email_ids,
                "properties": HEADER_PROPERTIES,
            },
            "g0",
        ],
    ]
    get_response = _jmap_request(api_url, user, get_calls)
    get_result = _find_response(
        get_response.get("methodResponses", []), "Email/get", "g0"
    )
    return get_result.get("list", []) if get_result else []


# ---------------------------------------------------------------------------
# Delta sync
# ---------------------------------------------------------------------------

def _delta_sync(ctx, saved_state):
    """Attempt delta sync using Email/queryChanges.

    Args:
        ctx: SyncContext with connection and identity details.
        saved_state: Previous JMAP query state string.

    Returns (synced_count, removed_count, new_state) on success,
    or raises Exception to signal fallback to full sync.
    """
    method_calls = [
        [
            "Email/queryChanges",
            {
                "accountId": ctx.account_id,
                "filter": {"inMailbox": ctx.mailbox_id},
                "sort": [{"property": "receivedAt", "isAscending": False}],
                "sinceQueryState": saved_state,
            },
            "qc0",
        ],
    ]

    response = _jmap_request(ctx.api_url, ctx.user, method_calls)
    qc_result = _find_response(
        response.get("methodResponses", []), "Email/queryChanges", "qc0"
    )

    if not qc_result or "added" not in qc_result:
        raise ValueError("No queryChanges result")

    added_ids = [item["id"] for item in qc_result.get("added", [])]
    new_state = qc_result.get("newQueryState", "")
    removed_ids = qc_result.get("removed", [])

    synced = 0
    if added_ids:
        emails = _fetch_email_headers_batch(
            ctx.api_url, ctx.user, ctx.account_id, added_ids
        )
        for em in emails:
            _upsert_jmap_email(ctx.db_conn, ctx.account_key, em)
            synced += 1

    for rid in removed_ids:
        ctx.db_conn.execute(
            "DELETE FROM jmap_emails WHERE account = ? AND email_id = ?",
            (ctx.account_key, rid),
        )

    if new_state:
        _save_sync_state(ctx.db_conn, ctx.account_key, ctx.mailbox_id, new_state)

    ctx.db_conn.commit()
    return synced, len(removed_ids), new_state


# ---------------------------------------------------------------------------
# Full sync
# ---------------------------------------------------------------------------

def _query_all_email_ids(api_url, user, account_id, mailbox_id, batch_size=100):
    """Page through Email/query to collect all email IDs in a mailbox.

    Returns (all_ids, query_state).
    """
    all_ids = []
    position = 0
    query_state = ""

    while True:
        method_calls = [
            [
                "Email/query",
                {
                    "accountId": account_id,
                    "filter": {"inMailbox": mailbox_id},
                    "sort": [{"property": "receivedAt", "isAscending": False}],
                    "position": position,
                    "limit": batch_size,
                },
                "q0",
            ],
        ]

        response = _jmap_request(api_url, user, method_calls)
        query_result = _find_response(
            response.get("methodResponses", []), "Email/query", "q0"
        )

        if not query_result:
            break

        ids = query_result.get("ids", [])
        if not ids:
            break

        if position == 0:
            query_state = query_result.get("queryState", "")

        all_ids.extend(ids)
        position += len(ids)

        if position >= query_result.get("total", 0):
            break

    return all_ids, query_state


def _full_sync(ctx):
    """Full sync: fetch all email IDs then retrieve headers in batches.

    Args:
        ctx: SyncContext with connection and identity details.

    Returns (synced_count, query_state).
    """
    batch_size = 100
    all_ids, query_state = _query_all_email_ids(
        ctx.api_url, ctx.user, ctx.account_id, ctx.mailbox_id, batch_size
    )

    synced = 0
    for i in range(0, len(all_ids), batch_size):
        batch_ids = all_ids[i: i + batch_size]
        emails = _fetch_email_headers_batch(
            ctx.api_url, ctx.user, ctx.account_id, batch_ids
        )
        for em in emails:
            _upsert_jmap_email(ctx.db_conn, ctx.account_key, em)
            synced += 1

    if query_state:
        _save_sync_state(ctx.db_conn, ctx.account_key, ctx.mailbox_id, query_state)

    ctx.db_conn.commit()
    return synced, query_state


# ---------------------------------------------------------------------------
# cmd_index_sync
# ---------------------------------------------------------------------------

def cmd_index_sync(args):
    """Sync mailbox headers to the local SQLite metadata index.

    Uses JMAP state strings for efficient delta sync when available.
    """
    session, account_id, api_url = _session_context(args)

    mailbox_name = args.mailbox or "INBOX"
    mailbox_id = _resolve_mailbox_id(
        api_url, args.user, account_id, mailbox_name
    )
    if not mailbox_id:
        print(
            f"ERROR: Mailbox '{mailbox_name}' not found",
            file=sys.stderr,
        )
        return 1

    if getattr(args, "filter_config", ""):
        filtered_result = run_filtered_sync(
            args,
            (session, account_id, api_url),
            (mailbox_name, mailbox_id),
        )
        if filtered_result is not None:
            return filtered_result
    if getattr(args, "dry_run", False):
        print(
            "ERROR: --dry-run requires --filter-config for JMAP sync",
            file=sys.stderr,
        )
        return 2

    account_key = f"{args.user}@jmap"
    db_conn = _init_index_db()
    ctx = SyncContext(api_url, args.user, account_id, account_key,
                      mailbox_id, db_conn)

    if not args.full:
        saved_state = _load_saved_sync_state(db_conn, account_key, mailbox_id)
        if saved_state:
            try:
                synced, removed, new_state = _delta_sync(ctx, saved_state)
                db_conn.close()
                result = {
                    "mailbox": mailbox_name,
                    "mailbox_id": mailbox_id,
                    "synced": synced,
                    "removed": removed,
                    "mode": "delta",
                    "state": new_state,
                }
                print(json.dumps(result, indent=2))
                return 0
            except Exception:  # pylint: disable=broad-exception-caught
                # Delta sync failed (e.g., cannotCalculateChanges)
                # Fall through to full sync
                pass

    synced, query_state = _full_sync(ctx)
    db_conn.close()

    result = {
        "mailbox": mailbox_name,
        "mailbox_id": mailbox_id,
        "synced": synced,
        "mode": "full",
    }
    if query_state:
        result["state"] = query_state
    print(json.dumps(result, indent=2))
    return 0
