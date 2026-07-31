#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only, locally-authoritative JMAP collection for the knowledge inbox."""

from __future__ import annotations

import json
import shutil
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from email_jmap_collection_transport import (
    CollectionContext,
    RuleQuery,
    candidate_fields,
    commit_matches,
    fetch_bodies,
    query_rule,
    requested_headers,
    stage_matches,
)
from email_match_rules import (
    load_rule_config,
    match_rule,
    select_rules,
)


def _load_state(path_value: str) -> dict[str, Any]:
    path = Path(path_value)
    if not path.is_file():
        return {}
    with path.open(encoding="utf-8") as handle:
        state = json.load(handle)
    if not isinstance(state, dict):
        raise ValueError("collection state must be an object")
    return state


def _save_state(path_value: str, state: dict[str, Any]) -> None:
    path = Path(path_value)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("w", encoding="utf-8") as handle:
            json.dump(state, handle, indent=2, sort_keys=True)
            handle.write("\n")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def _filtering_enabled(rules: list[dict[str, Any]], mailbox_id: str) -> bool:
    return any(
        rule.get("collection", True) is not False
        and (not rule.get("mailboxes") or mailbox_id in rule["mailboxes"])
        for rule in rules
    )


def _evaluate_queries(
    queries: list[RuleQuery],
    emails: dict[str, dict[str, Any]],
    state: dict[str, Any],
    account_identities: tuple[str, ...],
) -> tuple[dict[str, list[dict[str, Any]]], dict[str, int], set[str]]:
    headers = requested_headers([query.rule for query in queries])
    field_cache = {
        email_id: candidate_fields(email, headers) for email_id, email in emails.items()
    }
    matched_rules_by_email: dict[str, list[dict[str, Any]]] = {}
    matched_rules: dict[str, int] = {}
    coverage_gaps: set[str] = set()
    now = datetime.now(timezone.utc).isoformat()
    for query in queries:
        prior = state.get(query.key, {})
        query_matches = 0
        query_gaps: set[str] = set()
        for email_id in query.ids:
            fields = field_cache.get(email_id)
            if fields is None:
                query_gaps.add("message")
                continue
            match = match_rule(query.rule, fields, account_identities)
            query_gaps.update(match.unavailable_fields)
            if match.matched:
                matched_rules_by_email.setdefault(email_id, []).append(query.rule)
                query_matches += 1
        rule_id = str(query.rule["id"])
        matched_rules[rule_id] = query_matches
        coverage_gaps.update(query_gaps)
        state[query.key] = {
            "transport": "jmap",
            "query_state": query.query_state,
            "last_polled_at": now,
            "scanned": int(prior.get("scanned", 0)) + len(query.ids),
            "matched": int(prior.get("matched", 0)) + query_matches,
            "coverage_gaps": sorted(set(prior.get("coverage_gaps", [])) | query_gaps),
            "candidate_total": query.total,
            "has_more": query.has_more,
            "backfill_truncated": bool(prior.get("backfill_truncated"))
            or (query.mode == "full" and query.has_more),
            "mode": query.mode,
        }
    return matched_rules_by_email, matched_rules, coverage_gaps


def collect_filtered(context: CollectionContext) -> dict[str, Any]:
    """Collect one JMAP folder with independent, bounded, content-free lineages."""
    state = _load_state(context.state_path)
    active_rules = select_rules(
        {"rules": context.rules}, context.collection_mailbox_id, context.folder_name
    )
    enabled = _filtering_enabled(context.rules, context.collection_mailbox_id)
    result: dict[str, Any] = {
        "status": "ok",
        "transport": "jmap",
        "mode": "filtered",
        "collection_state": (
            "active" if active_rules else ("paused" if enabled else "not_targeted")
        ),
        "lineages": len(active_rules),
        "scanned": 0,
        "candidate_total": 0,
        "unmatched_evaluations": 0,
        "fetched_count": 0,
        "matched_rules": {},
        "coverage_gaps": [],
        "has_more": False,
        "backfill_truncated": False,
    }
    if not active_rules:
        return result

    queries = [query_rule(context, state, rule) for rule in active_rules]
    candidate_ids = list(
        dict.fromkeys(email_id for query in queries for email_id in query.ids)
    )
    emails = fetch_bodies(context, candidate_ids, active_rules)
    matched_rules_by_email, matched_rules, coverage_gaps = _evaluate_queries(
        queries, emails, state, context.account_identities
    )

    result.update({
        "scanned": sum(len(query.ids) for query in queries),
        "candidate_total": sum(query.total for query in queries),
        "unmatched_evaluations": sum(len(query.ids) for query in queries)
        - sum(matched_rules.values()),
        "fetched_count": len(matched_rules_by_email),
        "matched_rules": matched_rules,
        "coverage_gaps": sorted(coverage_gaps),
        "has_more": any(query.has_more for query in queries),
        "backfill_truncated": any(
            query.mode == "full" and query.has_more for query in queries
        ),
    })
    if context.dry_run:
        return result

    stage: Path | None = None
    try:
        stage, pending = stage_matches(context, matched_rules_by_email, emails)
        commit_matches(pending)
        _save_state(context.state_path, state)
    finally:
        if stage is not None:
            shutil.rmtree(stage, ignore_errors=True)
    return result


def run_filtered_sync(
    args: Any,
    session_context: tuple[dict[str, Any], str, str],
    mailbox_context: tuple[str, str],
) -> int | None:
    """Validate CLI inputs and run locally-authoritative JMAP collection."""
    session, account_id, api_url = session_context
    mailbox_name, mailbox_id = mailbox_context
    try:
        rules = load_rule_config(args.filter_config).get("rules", [])
        collection_mailbox_id = (
            getattr(args, "collection_mailbox_id", "") or args.user
        )
        if not _filtering_enabled(rules, collection_mailbox_id):
            return None
        if not getattr(args, "state", "") or not getattr(args, "inbox", ""):
            print(
                "ERROR: filtered JMAP sync requires --state and --inbox",
                file=sys.stderr,
            )
            return 2
        identities = tuple(
            dict.fromkeys(
                (getattr(args, "account_identity", []) or []) + [args.user]
            )
        )
        context = CollectionContext(
            session=session,
            api_url=api_url,
            user=args.user,
            account_id=account_id,
            collection_mailbox_id=collection_mailbox_id,
            folder_name=mailbox_name,
            folder_id=mailbox_id,
            rules=rules,
            state_path=args.state,
            inbox_dir=args.inbox,
            account_identities=identities,
            force_full=bool(args.full),
            dry_run=bool(getattr(args, "dry_run", False)),
        )
        result = collect_filtered(context)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(
            json.dumps({"error": type(exc).__name__, "mode": "filtered"}),
            file=sys.stderr,
        )
        return 1
    print(json.dumps(result, indent=2))
    return 0
