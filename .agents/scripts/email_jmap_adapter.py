#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_jmap_adapter.py - JMAP adapter for mailbox operations (RFC 8620/8621).

Provides JMAP connection, header fetching, body fetching, search, move,
flag, and push notification operations. Designed for Fastmail and other
JMAP-compatible providers (Cyrus 3.x, Apache James, Stalwart).

Part of the email mailbox helper (t1525). Called by email-mailbox-helper.sh.

Usage:
    python3 email_jmap_adapter.py connect --session-url URL --user USER
    python3 email_jmap_adapter.py fetch_headers --mailbox INBOX [--limit 50] [--position 0]
    python3 email_jmap_adapter.py fetch_body --email-id ID
    python3 email_jmap_adapter.py search --filter '{"from":"sender@example.com"}' [--mailbox INBOX]
    python3 email_jmap_adapter.py list_mailboxes
    python3 email_jmap_adapter.py create_mailbox --name "Archive/Projects/acme"
    python3 email_jmap_adapter.py move_email --email-id ID --dest-mailbox "Archive"
    python3 email_jmap_adapter.py set_keyword --email-id ID --keyword "$Task"
    python3 email_jmap_adapter.py clear_keyword --email-id ID --keyword "$Task"
    python3 email_jmap_adapter.py index_sync --mailbox INBOX [--full]
    python3 email_jmap_adapter.py push --types mail [--timeout 300]

Credentials: read from JMAP_TOKEN environment variable (never from argv).
    For Fastmail: use an app-specific password or API token.
    For basic auth: set JMAP_PASSWORD instead (used with --user for HTTP Basic).

Output: JSON to stdout. Errors to stderr.
"""

import argparse
import sys

__all__ = (
    "INDEX_DIR",
    "INDEX_DB",
    "_init_index_db",
    "_upsert_jmap_email",
    "_first_or_empty",
    "_get_auth",
    "_make_auth_header",
    "_jmap_request",
    "_get_session",
    "_get_primary_account",
    "_session_context",
    "_find_response",
    "_resolve_mailbox_id",
    "_build_mailbox_path",
    "_format_email_header",
    "_format_addresses",
    "HEADER_PROPERTIES",
    "BODY_PROPERTIES",
    "KEYWORD_TAXONOMY",
    "cmd_connect",
    "cmd_fetch_headers",
    "cmd_fetch_body",
    "cmd_search",
    "cmd_list_mailboxes",
    "cmd_create_mailbox",
    "cmd_move_email",
    "cmd_set_keyword",
    "cmd_clear_keyword",
    "SyncContext",
    "cmd_index_sync",
    "cmd_push",
)

# Re-export public surface from decomposed modules for backwards compatibility.
# Other scripts importing from email_jmap_adapter continue to work unchanged.
from email_jmap_index import (
    INDEX_DIR,
    INDEX_DB,
    _init_index_db,
    _upsert_jmap_email,
    _first_or_empty,
)
from email_jmap_transport import (
    _get_auth,
    _make_auth_header,
    _jmap_request,
    _get_session,
    _get_primary_account,
    _session_context,
)
from email_jmap_helpers import (
    _find_response,
    _resolve_mailbox_id,
    _build_mailbox_path,
    _format_email_header,
    _format_addresses,
)
from email_jmap_commands import (
    HEADER_PROPERTIES,
    BODY_PROPERTIES,
    KEYWORD_TAXONOMY,
    cmd_connect,
    cmd_fetch_headers,
    cmd_fetch_body,
    cmd_search,
    cmd_list_mailboxes,
    cmd_create_mailbox,
    cmd_move_email,
    cmd_set_keyword,
    cmd_clear_keyword,
)
from email_jmap_sync import (
    SyncContext,
    cmd_index_sync,
)
from email_jmap_push import (
    cmd_push,
)


# Standard JMAP keywords (RFC 8621 Section 2.1)
STANDARD_KEYWORDS = {
    "$seen": "Message has been read",
    "$flagged": "Message is flagged/starred",
    "$answered": "Message has been replied to",
    "$draft": "Message is a draft",
    "$forwarded": "Message has been forwarded",
}


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def build_parser():
    """Build the argument parser with all subcommands."""
    parser = argparse.ArgumentParser(
        description="JMAP adapter for email mailbox operations (RFC 8620/8621)"
    )

    # Common connection arguments
    parser.add_argument(
        "--session-url",
        help="JMAP session URL (e.g., https://api.fastmail.com/jmap/session)",
    )
    parser.add_argument("--user", help="Username (email address)")

    subparsers = parser.add_subparsers(dest="command", help="Command to execute")

    # connect
    subparsers.add_parser("connect", help="Test JMAP connectivity")

    # fetch_headers
    fh = subparsers.add_parser("fetch_headers", help="Fetch email headers")
    fh.add_argument(
        "--mailbox", default="INBOX", help="Mailbox name or role"
    )
    fh.add_argument(
        "--limit", type=int, default=50, help="Max emails to fetch"
    )
    fh.add_argument(
        "--position", type=int, default=0, help="Offset from start"
    )

    # fetch_body
    fb = subparsers.add_parser("fetch_body", help="Fetch an email body by ID")
    fb.add_argument("--email-id", required=True, help="JMAP email ID")
    fb.add_argument("--filter-config", help="Version 2 rules checked locally before output")
    fb.add_argument("--rule-id", help="Rule ID required with --filter-config")
    fb.add_argument("--account-identity", action="append", default=[])

    # search
    sr = subparsers.add_parser("search", help="Search emails")
    sr.add_argument(
        "--filter",
        required=True,
        help='JMAP filter as JSON string or plain text for full-text search',
    )
    sr.add_argument("--mailbox", help="Restrict search to this mailbox")
    sr.add_argument("--limit", type=int, default=50, help="Max results")

    # list_mailboxes
    subparsers.add_parser("list_mailboxes", help="List all JMAP mailboxes")

    # create_mailbox
    cm = subparsers.add_parser("create_mailbox", help="Create a mailbox")
    cm.add_argument(
        "--name", required=True, help="Mailbox name or path (e.g., Archive/Projects)"
    )

    # move_email
    mv = subparsers.add_parser(
        "move_email", help="Move an email to another mailbox"
    )
    mv.add_argument("--email-id", required=True, help="JMAP email ID")
    mv.add_argument(
        "--dest-mailbox", required=True, help="Destination mailbox name"
    )

    # set_keyword
    sk = subparsers.add_parser("set_keyword", help="Set a keyword on an email")
    sk.add_argument("--email-id", required=True, help="JMAP email ID")
    sk.add_argument(
        "--keyword",
        required=True,
        help="Keyword (taxonomy name or JMAP keyword)",
    )

    # clear_keyword
    ck = subparsers.add_parser(
        "clear_keyword", help="Clear a keyword from an email"
    )
    ck.add_argument("--email-id", required=True, help="JMAP email ID")
    ck.add_argument("--keyword", required=True, help="Keyword to clear")

    # index_sync
    ix = subparsers.add_parser(
        "index_sync", help="Sync mailbox to local index"
    )
    ix.add_argument(
        "--mailbox", default="INBOX", help="Mailbox to sync"
    )
    ix.add_argument(
        "--full", action="store_true", help="Full sync (not incremental)"
    )
    ix.add_argument(
        "--filter-config",
        help="Version 2 rules for locally-authoritative knowledge collection",
    )
    ix.add_argument(
        "--collection-mailbox-id",
        help="Private rule mailbox selector (defaults to --user)",
    )
    ix.add_argument("--state", help="Content-free collection checkpoint file")
    ix.add_argument("--inbox", help="Knowledge inbox for matched .eml files")
    ix.add_argument("--account-identity", action="append", default=[])
    ix.add_argument(
        "--dry-run",
        action="store_true",
        help="Match candidates without writing evidence or checkpoints",
    )

    # push
    ps = subparsers.add_parser(
        "push", help="Listen for push notifications via EventSource"
    )
    ps.add_argument(
        "--types",
        default="mail",
        help="Comma-separated event types (default: mail)",
    )
    ps.add_argument(
        "--timeout",
        type=int,
        default=300,
        help="Timeout in seconds (default: 300)",
    )

    return parser


def main():
    """Entry point."""
    parser = build_parser()
    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return 1

    # Validate required connection args
    if args.command != "help":
        if not args.session_url or not args.user:
            print(
                "ERROR: --session-url and --user are required",
                file=sys.stderr,
            )
            return 1

    commands = {
        "connect": cmd_connect,
        "fetch_headers": cmd_fetch_headers,
        "fetch_body": cmd_fetch_body,
        "search": cmd_search,
        "list_mailboxes": cmd_list_mailboxes,
        "create_mailbox": cmd_create_mailbox,
        "move_email": cmd_move_email,
        "set_keyword": cmd_set_keyword,
        "clear_keyword": cmd_clear_keyword,
        "index_sync": cmd_index_sync,
        "push": cmd_push,
    }

    handler = commands.get(args.command)
    if handler:
        return handler(args)

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
