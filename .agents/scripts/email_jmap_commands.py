#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_jmap_commands.py - JMAP command implementations.

Extracted from email_jmap_adapter.py to reduce file-level complexity.
Contains connect, fetch, search, mailbox, move, and keyword commands.
"""

import json
import sys

from email_jmap_index import _init_index_db, _upsert_jmap_email, _first_or_empty
from email_jmap_transport import _jmap_request, _session_context
from email_match_rules import fields_from_mapping, load_rule_config, match_rule
from email_jmap_helpers import (
    _find_response,
    _resolve_mailbox_id,
    _build_mailbox_path,
    _format_email_header,
    _format_addresses,
)


# ---------------------------------------------------------------------------
# Constants (referenced by commands)
# ---------------------------------------------------------------------------

HEADER_PROPERTIES = [
    "id", "blobId", "threadId", "mailboxIds",
    "from", "to", "subject", "receivedAt",
    "sentAt", "size", "keywords", "messageId",
    "inReplyTo", "references", "preview",
]

BODY_PROPERTIES = HEADER_PROPERTIES + [
    "cc", "bcc", "replyTo", "textBody", "htmlBody",
    "attachments", "bodyValues", "hasAttachment",
]

# Custom keyword taxonomy mapping (from email-mailbox.md)
KEYWORD_TAXONOMY = {
    "Reminders": "$reminder",
    "Tasks": "$task",
    "Review": "$review",
    "Filing": "$filing",
    "Ideas": "$idea",
    "Add-to-Contacts": "$addcontact",
}


# ---------------------------------------------------------------------------
# Connect
# ---------------------------------------------------------------------------

def cmd_connect(args):
    """Test JMAP connectivity and report session capabilities."""
    session, account_id, _ = _session_context(args)
    account_info = session.get("accounts", {}).get(account_id, {})

    capabilities = list(session.get("capabilities", {}).keys())
    account_capabilities = list(
        account_info.get("accountCapabilities", {}).keys()
    )

    result = {
        "status": "connected",
        "session_url": args.session_url,
        "api_url": session.get("apiUrl", ""),
        "upload_url": session.get("uploadUrl", ""),
        "download_url": session.get("downloadUrl", ""),
        "event_source_url": session.get("eventSourceUrl", ""),
        "user": args.user,
        "account_id": account_id,
        "account_name": account_info.get("name", ""),
        "capabilities": capabilities,
        "account_capabilities": account_capabilities,
        "state": session.get("state", ""),
    }
    print(json.dumps(result, indent=2))
    return 0


# ---------------------------------------------------------------------------
# Fetch headers
# ---------------------------------------------------------------------------

def cmd_fetch_headers(args):
    """Fetch email headers from a mailbox using Email/query + Email/get."""
    _, account_id, api_url = _session_context(args)

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

    limit = args.limit or 50
    position = args.position or 0

    method_calls = [
        [
            "Email/query",
            {
                "accountId": account_id,
                "filter": {"inMailbox": mailbox_id},
                "sort": [{"property": "receivedAt", "isAscending": False}],
                "position": position,
                "limit": limit,
            },
            "q0",
        ],
        [
            "Email/get",
            {
                "accountId": account_id,
                "#ids": {
                    "resultOf": "q0",
                    "name": "Email/query",
                    "path": "/ids",
                },
                "properties": HEADER_PROPERTIES,
            },
            "g0",
        ],
    ]

    response = _jmap_request(api_url, args.user, method_calls)
    method_responses = response.get("methodResponses", [])

    query_result = _find_response(method_responses, "Email/query", "q0")
    get_result = _find_response(method_responses, "Email/get", "g0")

    if not query_result or not get_result:
        print("ERROR: Unexpected JMAP response structure", file=sys.stderr)
        return 1

    total = query_result.get("total", 0)
    emails = get_result.get("list", [])

    messages = [_format_email_header(em) for em in emails]

    # Update SQLite index
    account_key = f"{args.user}@jmap"
    db_conn = _init_index_db()
    for em in emails:
        _upsert_jmap_email(db_conn, account_key, em)
    db_conn.commit()
    db_conn.close()

    result = {
        "mailbox": mailbox_name,
        "mailbox_id": mailbox_id,
        "total": total,
        "position": position,
        "limit": limit,
        "returned": len(messages),
        "messages": messages,
    }
    print(json.dumps(result, indent=2))
    return 0


# ---------------------------------------------------------------------------
# Fetch body helpers
# ---------------------------------------------------------------------------

def _extract_text_body(em, body_values):
    """Extract concatenated text body from email parts."""
    text_body = ""
    for part in em.get("textBody") or []:
        part_id = part.get("partId", "")
        if part_id in body_values:
            text_body += body_values[part_id].get("value", "")
    return text_body


def _extract_html_body(em, body_values):
    """Extract concatenated HTML body from email parts."""
    html_body = ""
    for part in em.get("htmlBody") or []:
        part_id = part.get("partId", "")
        if part_id in body_values:
            html_body += body_values[part_id].get("value", "")
    return html_body


def _extract_attachments(em):
    """Return a list of attachment summary dicts."""
    return [
        {
            "filename": att.get("name") or "unnamed",
            "content_type": att.get("type", ""),
            "size": att.get("size", 0),
            "blob_id": att.get("blobId", ""),
        }
        for att in em.get("attachments") or []
    ]


# ---------------------------------------------------------------------------
# Fetch body
# ---------------------------------------------------------------------------

def cmd_fetch_body(args):
    """Fetch a single email body by JMAP email ID."""
    _, account_id, api_url = _session_context(args)

    method_calls = [
        [
            "Email/get",
            {
                "accountId": account_id,
                "ids": [args.email_id],
                "properties": BODY_PROPERTIES,
                "fetchTextBodyValues": True,
                "fetchHTMLBodyValues": True,
                "maxBodyValueBytes": 1048576,  # 1MB
            },
            "g0",
        ],
    ]

    response = _jmap_request(api_url, args.user, method_calls)
    get_result = _find_response(
        response.get("methodResponses", []), "Email/get", "g0"
    )

    if not get_result:
        print("ERROR: Unexpected JMAP response", file=sys.stderr)
        return 1

    emails = get_result.get("list", [])
    if not emails:
        not_found = get_result.get("notFound", [])
        if args.email_id in not_found:
            print(
                f"ERROR: Email ID '{args.email_id}' not found",
                file=sys.stderr,
            )
        else:
            print("ERROR: No email returned", file=sys.stderr)
        return 1

    em = emails[0]
    body_values = em.get("bodyValues", {})
    html_body = _extract_html_body(em, body_values)

    from_addrs = em.get("from") or []
    to_addrs = em.get("to") or []
    cc_addrs = em.get("cc") or []
    bcc_addrs = em.get("bcc") or []

    result = {
        "email_id": em.get("id", ""),
        "thread_id": em.get("threadId", ""),
        "blob_id": em.get("blobId", ""),
        "mailbox_ids": list((em.get("mailboxIds") or {}).keys()),
        "message_id": _first_or_empty(em.get("messageId")),
        "date": em.get("receivedAt", ""),
        "sent_at": em.get("sentAt", ""),
        "from": _format_addresses(from_addrs),
        "to": _format_addresses(to_addrs),
        "cc": _format_addresses(cc_addrs),
        "bcc": _format_addresses(bcc_addrs),
        "subject": em.get("subject", ""),
        "in_reply_to": _first_or_empty(em.get("inReplyTo")),
        "references": em.get("references") or [],
        "keywords": list((em.get("keywords") or {}).keys()),
        "text_body": _extract_text_body(em, body_values),
        "html_body_length": len(html_body),
        "has_attachment": em.get("hasAttachment", False),
        "attachments": _extract_attachments(em),
        "preview": em.get("preview", ""),
    }
    if args.filter_config:
        config = load_rule_config(args.filter_config)
        selected = [
            rule for rule in config["rules"]
            if str(rule.get("id") or rule.get("name")) == args.rule_id
        ]
        if not selected:
            print(json.dumps({"error": "rule_not_found", "rule_id": args.rule_id}), file=sys.stderr)
            return 2
        identities = args.account_identity or [args.user]
        match_candidate = dict(em)
        match_candidate["text_body"] = result["text_body"]
        match_candidate["html_body"] = html_body
        local_match = match_rule(selected[0], fields_from_mapping(match_candidate), identities)
        if not local_match.matched:
            print(json.dumps(local_match.explanation(), sort_keys=True))
            return 3
        result["local_match"] = local_match.explanation()
    print(json.dumps(result, indent=2))
    return 0


# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------

def _build_search_filter(args, api_url, account_id):
    """Parse and optionally scope a search filter to a mailbox."""
    try:
        filter_obj = json.loads(args.filter)
    except (json.JSONDecodeError, TypeError):
        filter_obj = {"text": args.filter}

    if not args.mailbox:
        return filter_obj

    mailbox_id = _resolve_mailbox_id(
        api_url, args.user, account_id, args.mailbox
    )
    if not mailbox_id:
        return filter_obj

    if "operator" in filter_obj:
        return {
            "operator": "AND",
            "conditions": [{"inMailbox": mailbox_id}, filter_obj],
        }
    filter_obj["inMailbox"] = mailbox_id
    return filter_obj


def cmd_search(args):
    """Search emails using JMAP Email/query with FilterCondition."""
    _, account_id, api_url = _session_context(args)

    filter_obj = _build_search_filter(args, api_url, account_id)
    limit = args.limit or 50

    method_calls = [
        [
            "Email/query",
            {
                "accountId": account_id,
                "filter": filter_obj,
                "sort": [{"property": "receivedAt", "isAscending": False}],
                "limit": limit,
            },
            "q0",
        ],
        [
            "Email/get",
            {
                "accountId": account_id,
                "#ids": {
                    "resultOf": "q0",
                    "name": "Email/query",
                    "path": "/ids",
                },
                "properties": HEADER_PROPERTIES,
            },
            "g0",
        ],
    ]

    response = _jmap_request(api_url, args.user, method_calls)
    method_responses = response.get("methodResponses", [])

    query_result = _find_response(method_responses, "Email/query", "q0")
    get_result = _find_response(method_responses, "Email/get", "g0")

    if not query_result or not get_result:
        print("ERROR: Unexpected JMAP response", file=sys.stderr)
        return 1

    emails = get_result.get("list", [])
    messages = [_format_email_header(em) for em in emails]

    result = {
        "mailbox": args.mailbox or "(all)",
        "filter": filter_obj,
        "total_matches": query_result.get("total", 0),
        "returned": len(messages),
        "messages": messages,
    }
    print(json.dumps(result, indent=2))
    return 0


# ---------------------------------------------------------------------------
# Mailbox operations
# ---------------------------------------------------------------------------

def cmd_list_mailboxes(args):
    """List all JMAP mailboxes with hierarchy."""
    _, account_id, api_url = _session_context(args)

    method_calls = [
        [
            "Mailbox/get",
            {
                "accountId": account_id,
                "properties": [
                    "id", "name", "parentId", "role",
                    "totalEmails", "unreadEmails", "sortOrder",
                    "myRights",
                ],
            },
            "m0",
        ],
    ]

    response = _jmap_request(api_url, args.user, method_calls)
    get_result = _find_response(
        response.get("methodResponses", []), "Mailbox/get", "m0"
    )

    if not get_result:
        print("ERROR: Unexpected JMAP response", file=sys.stderr)
        return 1

    mailboxes_raw = get_result.get("list", [])

    # Build hierarchy paths
    id_to_mailbox = {mb["id"]: mb for mb in mailboxes_raw}
    mailboxes = []
    for mb in mailboxes_raw:
        path = _build_mailbox_path(mb, id_to_mailbox)
        mailboxes.append({
            "id": mb.get("id", ""),
            "name": mb.get("name", ""),
            "path": path,
            "role": mb.get("role") or "",
            "parent_id": mb.get("parentId") or "",
            "total_emails": mb.get("totalEmails", 0),
            "unread_emails": mb.get("unreadEmails", 0),
            "sort_order": mb.get("sortOrder", 0),
        })

    mailboxes.sort(key=lambda m: m["path"])

    result = {
        "total": len(mailboxes),
        "mailboxes": mailboxes,
    }
    print(json.dumps(result, indent=2))
    return 0


def _resolve_parent_mailbox(api_url, user, account_id, name_parts):
    """Resolve parent mailbox for a nested path. Returns (parent_id, error_msg)."""
    if len(name_parts) <= 1:
        return None, None
    parent_path = "/".join(name_parts[:-1])
    parent_id = _resolve_mailbox_id(api_url, user, account_id, parent_path)
    if not parent_id:
        return None, (
            f"ERROR: Parent mailbox '{parent_path}' not found. "
            "Create parent mailboxes first."
        )
    return parent_id, None


def cmd_create_mailbox(args):
    """Create a JMAP mailbox, including nested paths."""
    _, account_id, api_url = _session_context(args)

    name = args.name
    if not name:
        print("ERROR: --name is required", file=sys.stderr)
        return 1

    parts = name.split("/")
    parent_id, err = _resolve_parent_mailbox(api_url, args.user, account_id, parts)
    if err:
        print(err, file=sys.stderr)
        return 1

    create_args = {
        "accountId": account_id,
        "create": {
            "new0": {
                "name": parts[-1],
            },
        },
    }
    if parent_id:
        create_args["create"]["new0"]["parentId"] = parent_id

    method_calls = [["Mailbox/set", create_args, "c0"]]

    response = _jmap_request(api_url, args.user, method_calls)
    set_result = _find_response(
        response.get("methodResponses", []), "Mailbox/set", "c0"
    )

    if not set_result:
        print("ERROR: Unexpected JMAP response", file=sys.stderr)
        return 1

    created = set_result.get("created", {})
    not_created = set_result.get("notCreated", {})

    if "new0" in created:
        result = {
            "status": "created",
            "mailbox": name,
            "id": created["new0"].get("id", ""),
        }
        print(json.dumps(result, indent=2))
        return 0

    err_detail = not_created.get("new0", {})
    err_msg = err_detail.get("description", err_detail) if err_detail else "Unknown creation result"
    print(f"ERROR: Mailbox creation failed: {err_msg}", file=sys.stderr)
    return 1


# ---------------------------------------------------------------------------
# Move email
# ---------------------------------------------------------------------------

def _fetch_email_mailbox_ids(api_url, user, account_id, email_id):
    """Return current mailboxIds dict for an email, or None on error."""
    get_calls = [
        [
            "Email/get",
            {
                "accountId": account_id,
                "ids": [email_id],
                "properties": ["mailboxIds"],
            },
            "g0",
        ],
    ]
    get_response = _jmap_request(api_url, user, get_calls)
    get_result = _find_response(
        get_response.get("methodResponses", []), "Email/get", "g0"
    )
    if not get_result or not get_result.get("list"):
        return None
    return get_result["list"][0].get("mailboxIds", {})


def _validate_move_targets(api_url, user, account_id, email_id, dest_name):
    """Validate move targets. Returns (dest_id, current_mailboxes, error_msg)."""
    dest_id = _resolve_mailbox_id(api_url, user, account_id, dest_name)
    if not dest_id:
        return None, None, f"ERROR: Destination mailbox '{dest_name}' not found"

    current_mailboxes = _fetch_email_mailbox_ids(api_url, user, account_id, email_id)
    if current_mailboxes is None:
        return None, None, f"ERROR: Email '{email_id}' not found"

    return dest_id, current_mailboxes, None


def cmd_move_email(args):
    """Move an email to a different mailbox by updating mailboxIds."""
    _, account_id, api_url = _session_context(args)

    dest_name = args.dest_mailbox
    if not dest_name:
        print("ERROR: --dest-mailbox is required", file=sys.stderr)
        return 1

    dest_id, current_mailboxes, err = _validate_move_targets(
        api_url, args.user, account_id, args.email_id, dest_name
    )
    if err:
        print(err, file=sys.stderr)
        return 1

    # Build update: remove from all current mailboxes, add to destination
    update_patch = {f"mailboxIds/{mb_id}": None for mb_id in current_mailboxes}
    update_patch[f"mailboxIds/{dest_id}"] = True

    set_calls = [
        [
            "Email/set",
            {
                "accountId": account_id,
                "update": {args.email_id: update_patch},
            },
            "s0",
        ],
    ]

    set_response = _jmap_request(api_url, args.user, set_calls)
    set_result = _find_response(
        set_response.get("methodResponses", []), "Email/set", "s0"
    )

    if not set_result:
        print("ERROR: Unexpected JMAP response", file=sys.stderr)
        return 1

    not_updated = set_result.get("notUpdated", {})
    if args.email_id in not_updated:
        err_detail = not_updated[args.email_id]
        print(
            f"ERROR: Move failed: {err_detail.get('description', err_detail)}",
            file=sys.stderr,
        )
        return 1

    result = {
        "status": "moved",
        "email_id": args.email_id,
        "from_mailboxes": list(current_mailboxes.keys()),
        "to_mailbox": dest_name,
        "to_mailbox_id": dest_id,
    }
    print(json.dumps(result, indent=2))
    return 0


# ---------------------------------------------------------------------------
# Keyword operations
# ---------------------------------------------------------------------------

def _apply_keyword_update(api_url, user, account_id, email_id, patch):
    """Send an Email/set keyword patch and return (set_result, error_msg)."""
    method_calls = [
        [
            "Email/set",
            {
                "accountId": account_id,
                "update": {email_id: patch},
            },
            "s0",
        ],
    ]
    response = _jmap_request(api_url, user, method_calls)
    set_result = _find_response(
        response.get("methodResponses", []), "Email/set", "s0"
    )
    return set_result


def cmd_set_keyword(args):
    """Set a keyword on an email."""
    _, account_id, api_url = _session_context(args)

    keyword = args.keyword
    if not keyword:
        print("ERROR: --keyword is required", file=sys.stderr)
        return 1

    # Map taxonomy name to JMAP keyword if needed
    jmap_keyword = KEYWORD_TAXONOMY.get(keyword, keyword)
    set_result = _apply_keyword_update(
        api_url, args.user, account_id, args.email_id,
        {f"keywords/{jmap_keyword}": True},
    )

    if not set_result:
        print("ERROR: Unexpected JMAP response", file=sys.stderr)
        return 1

    not_updated = set_result.get("notUpdated", {})
    if args.email_id in not_updated:
        err = not_updated[args.email_id]
        print(
            f"ERROR: Set keyword failed: {err.get('description', err)}",
            file=sys.stderr,
        )
        return 1

    result = {
        "status": "keyword_set",
        "email_id": args.email_id,
        "keyword": jmap_keyword,
        "taxonomy_name": keyword if keyword in KEYWORD_TAXONOMY else "",
    }
    print(json.dumps(result, indent=2))
    return 0


def cmd_clear_keyword(args):
    """Clear a keyword from an email."""
    _, account_id, api_url = _session_context(args)

    keyword = args.keyword
    if not keyword:
        print("ERROR: --keyword is required", file=sys.stderr)
        return 1

    jmap_keyword = KEYWORD_TAXONOMY.get(keyword, keyword)
    set_result = _apply_keyword_update(
        api_url, args.user, account_id, args.email_id,
        {f"keywords/{jmap_keyword}": None},
    )

    if not set_result:
        print("ERROR: Unexpected JMAP response", file=sys.stderr)
        return 1

    not_updated = set_result.get("notUpdated", {})
    if args.email_id in not_updated:
        err = not_updated[args.email_id]
        print(
            f"ERROR: Clear keyword failed: {err.get('description', err)}",
            file=sys.stderr,
        )
        return 1

    result = {
        "status": "keyword_cleared",
        "email_id": args.email_id,
        "keyword": jmap_keyword,
    }
    print(json.dumps(result, indent=2))
    return 0
