#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_poll.py - IMAP polling script for the aidevops knowledge plane.

Polls configured IMAP mailboxes, fetches new messages since the last-seen UID,
and drops each message as an .eml file into _knowledge/inbox/.

Part of aidevops email-poll system (t2855).

Usage:
    python3 email_poll.py tick --config CONFIG --state STATE --inbox INBOX
    python3 email_poll.py backfill --config CONFIG --state STATE --inbox INBOX
                                   --mailbox-id ID --since 2026-01-01
    python3 email_poll.py test --config CONFIG --mailbox-id ID
    python3 email_poll.py list --config CONFIG [--state STATE]

Credentials: resolved via gopass or environment variable (see _resolve_password).
Config:      ~/.config/aidevops/mailboxes.json or _config/mailboxes.json
State:       _knowledge/.imap-state.json (per-mailbox high-watermark UIDs)
Inbox:       _knowledge/inbox/ (output .eml files)

Output: JSON summary to stdout. Errors to stderr.
"""

import argparse
import email as email_lib
import imaplib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field, replace
from datetime import datetime, timezone
from pathlib import Path

from email_collection_receipts import ReceiptContext, write_collection_receipt
from email_match_rules import (
    MatchResult,
    fields_from_bytes,
    load_rule_config,
    match_rule,
    rule_digest,
    select_rules,
)


# ---------------------------------------------------------------------------
# Poll configuration
# ---------------------------------------------------------------------------

@dataclass
class PollConfig:
    """Options controlling how a single mailbox poll run behaves.

    Bundling these into one object keeps poll_mailbox and _poll_folder
    at a low parameter count while remaining easy to extend.
    """

    inbox_dir: str = ""
    dry_run: bool = False
    rate_limit_per_min: int = 0
    max_messages: int = 0
    rules: list[dict] = field(default_factory=list)
    account_identities: tuple[str, ...] = ()


@dataclass
class BackfillConfig:
    """Options for one bounded mailbox backfill."""

    inbox_dir: str
    since_date: str
    rate_limit_per_min: int = 100
    rules: list[dict] = field(default_factory=list)


@dataclass(frozen=True)
class EmlWriteTarget:
    """Private inbox destination for one staged IMAP message."""

    inbox_dir: str
    mailbox_id: str
    folder: str
    uid: int


@dataclass
class RuleScanContext:
    """Prepared rule state for one folder poll."""

    rule_keys: dict[str, dict]
    rule_cursors: dict[str, int]
    pending_states: dict[str, dict]
    account_identities: tuple[str, ...]
    filtering_enabled: bool = False
    candidate_uids: dict[str, set[int]] = field(default_factory=dict)
    candidate_evidence: dict[str, dict[str, object]] = field(default_factory=dict)
    matched_rules_by_uid: dict[int, list[dict]] = field(default_factory=dict)


@dataclass
class BackfillContext:
    """Mailbox and rule state shared while scanning one backfill folder."""

    mailbox_id: str
    folder: str
    state: dict
    config: BackfillConfig
    active_rules: list[dict]
    account_identities: tuple[str, ...]
    filtering_enabled: bool = False
    candidate_uids: dict[str, set[int]] = field(default_factory=dict)
    candidate_evidence: dict[str, dict[str, object]] = field(default_factory=dict)
    matched_rules_by_uid: dict[int, list[dict]] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Credential resolution
# ---------------------------------------------------------------------------

def _resolve_password(password_ref: str) -> str:
    """Resolve a password reference to a plaintext password.

    Supports two forms:
      - Starts with 'gopass:' → calls `gopass show -o <path>` silently.
      - Anything else         → treated as an environment variable name.

    Never logs the resolved password value.
    """
    if not password_ref:
        raise ValueError("password_ref is empty")

    if password_ref.startswith("gopass:"):
        gopass_path = password_ref[len("gopass:"):]
        try:
            result = subprocess.run(
                ["gopass", "show", "-o", gopass_path],
                capture_output=True,
                text=True,
                check=True,
            )
            return result.stdout.strip()
        except subprocess.CalledProcessError as exc:
            raise RuntimeError(
                f"gopass show failed for path '{gopass_path}': {exc.stderr.strip()}"
            ) from exc
        except FileNotFoundError as exc:
            raise RuntimeError(
                "gopass is not installed or not in PATH"
            ) from exc

    # Treat as environment variable name
    value = os.environ.get(password_ref)
    if value is None:
        raise RuntimeError(
            f"Environment variable '{password_ref}' is not set"
        )
    return value


# ---------------------------------------------------------------------------
# Mailboxes config
# ---------------------------------------------------------------------------

def load_mailboxes_config(config_path: str) -> dict:
    """Load and validate mailboxes.json config."""
    path = Path(config_path)
    if not path.exists():
        raise FileNotFoundError(f"mailboxes config not found: {config_path}")
    with path.open() as f:
        data = json.load(f)
    if "mailboxes" not in data:
        raise ValueError("mailboxes config must have a 'mailboxes' key")
    return data


def get_mailbox_config(config: dict, mailbox_id: str) -> dict:
    """Return config entry for a specific mailbox ID."""
    for mb in config.get("mailboxes", []):
        if mb.get("id") == mailbox_id:
            return mb
    raise KeyError(f"Mailbox '{mailbox_id}' not found in config")


# ---------------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------------

def load_state(state_path: str) -> dict:
    """Load per-mailbox IMAP polling state (last-seen UIDs)."""
    path = Path(state_path)
    if not path.exists():
        return {}
    with path.open() as f:
        return json.load(f)


def save_state(state_path: str, state: dict) -> None:
    """Persist per-mailbox IMAP polling state atomically."""
    path = Path(state_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(".tmp")
    with tmp_path.open("w") as f:
        json.dump(state, f, indent=2)
        f.write("\n")
    tmp_path.replace(path)


def _state_key(mailbox_id: str, folder: str) -> str:
    """Canonical state dictionary key for a mailbox+folder pair."""
    safe_folder = re.sub(r"[^a-zA-Z0-9_/-]", "_", folder)
    return f"{mailbox_id}/{safe_folder}"


def _filter_state_key(mailbox_id: str, folder: str, rule: dict) -> str:
    """Content-free checkpoint key for one mailbox/folder/rule lineage."""
    rule_id = re.sub(r"[^a-zA-Z0-9_.-]", "_", str(rule.get("id") or rule.get("name")))
    return f"{_state_key(mailbox_id, folder)}/imap/filter/{rule_id}/{rule_digest(rule)}"


def _mailbox_filtering_enabled(rules: list[dict], mailbox_id: str) -> bool:
    """Return whether collection-rule configuration makes a mailbox fail closed."""
    return any(
        rule.get("collection", True) is not False
        and (not rule.get("mailboxes") or mailbox_id in rule["mailboxes"])
        for rule in rules
    )


def _backfill_state_key(
    mailbox_id: str, folder: str, rule: dict, since_date: str = ""
) -> str:
    """Keep bounded replay receipts separate from the live high watermark."""
    lineage_date = since_date or str((rule.get("backfill") or {}).get("since") or "all")
    return f"{_filter_state_key(mailbox_id, folder, rule)}/backfill/{lineage_date}"


# ---------------------------------------------------------------------------
# IMAP connection helpers
# ---------------------------------------------------------------------------

def _connect_imap(host: str, port: int, user: str, password: str) -> imaplib.IMAP4_SSL:
    """Open an IMAP4_SSL connection and authenticate."""
    conn = imaplib.IMAP4_SSL(host, port)
    conn.login(user, password)
    return conn


def _search_uids_since(
    conn: imaplib.IMAP4_SSL,
    folder: str,
    last_uid: int,
    max_uids: int = 0,
    since_date: str = "",
) -> tuple[list[int], dict[str, object]]:
    """SELECT folder and return UIDs > last_uid, optionally capped at max_uids.

    Returns selected UIDs and content-free scan evidence. Raises RuntimeError on
    IMAP errors.
    """
    status, _ = conn.select(f'"{folder}"', readonly=True)
    if status != "OK":
        raise RuntimeError(f"SELECT '{folder}' failed: {status}")

    start_uid = last_uid + 1
    criteria = f"UID {start_uid}:*"
    if since_date:
        imap_date = datetime.strptime(since_date, "%Y-%m-%d").strftime("%d-%b-%Y")
        criteria = f"{criteria} SINCE {imap_date}"
    status, data = conn.uid("SEARCH", None, criteria)  # type: ignore[arg-type]
    if status != "OK":
        raise RuntimeError(f"UID SEARCH failed: {status}")

    uid_list_raw = data[0] if data else b""
    uid_strings = uid_list_raw.decode().split() if uid_list_raw else []
    # Filter: server may return * = UIDNEXT-1 when the range is empty
    valid_uids = [int(u) for u in uid_strings if int(u) > last_uid]
    candidate_total = len(valid_uids)
    has_more = max_uids > 0 and candidate_total > max_uids
    evidence: dict[str, object] = {
        "candidate_total": candidate_total,
        "has_more": has_more,
        "backfill_truncated": last_uid == 0 and has_more,
        "mode": "initial" if last_uid == 0 else "incremental",
    }

    if max_uids > 0:
        # A new rule lineage performs one bounded recent-history replay, then
        # checkpoints the high UID so later ticks collect only new mail.
        valid_uids = valid_uids[-max_uids:] if last_uid == 0 else valid_uids[:max_uids]

    return valid_uids, evidence


def _uid_fetch_selected(
    conn: imaplib.IMAP4_SSL, valid_uids: list[int]
) -> list[tuple[int, bytes]]:
    """Fetch one sorted union of already-selected candidate UIDs."""
    if not valid_uids:
        return []
    uid_set = ",".join(str(uid) for uid in valid_uids)
    status, fetch_data = conn.uid("FETCH", uid_set, "(BODY.PEEK[])")  # type: ignore[arg-type]
    if status != "OK":
        raise RuntimeError(f"UID FETCH failed: {status}")
    return _parse_fetch_response(fetch_data, valid_uids)


def _parse_fetch_response(
    fetch_data: list, valid_uids: list, last_uid: int = 0
) -> list[tuple[int, bytes]]:
    """Parse an imaplib RFC822 FETCH response into (uid, raw_bytes) tuples.

    Returns list[tuple[int, bytes]], sorted by UID ascending.
    Only includes messages with UID > last_uid (use last_uid=0 for all).
    """
    messages = []
    i = 0
    while i < len(fetch_data):
        item = fetch_data[i]
        if isinstance(item, tuple):
            header_part = item[0]
            raw_msg = item[1]
            uid_match = re.search(rb"UID\s+(\d+)", header_part)
            if uid_match:
                uid = int(uid_match.group(1))
            else:
                # Fallback: infer from position in valid_uids
                uid = valid_uids[len(messages)] if len(messages) < len(valid_uids) else 0
            if uid > last_uid:
                messages.append((uid, raw_msg))
        i += 1

    messages.sort(key=lambda t: t[0])
    return messages


def _uid_fetch_since(
    conn: imaplib.IMAP4_SSL, folder: str, last_uid: int, max_uids: int = 0
) -> list[tuple[int, bytes]]:
    """Fetch messages with UID > last_uid in folder.

    Args:
        max_uids: If > 0, fetch at most this many messages (oldest first).
                  Used by cmd_test to avoid fetching entire mailboxes.

    Returns a list of (uid, raw_rfc822_bytes) tuples sorted by UID ascending.
    """
    valid_uids, _evidence = _search_uids_since(conn, folder, last_uid, max_uids)
    if not valid_uids:
        return []

    return _uid_fetch_selected(conn, valid_uids)


def _uid_fetch_since_date(
    conn: imaplib.IMAP4_SSL, folder: str, since_date: str, max_uids: int = 0
) -> list[tuple[int, bytes]]:
    """Fetch all messages in folder with INTERNALDATE >= since_date.

    since_date: ISO date string, e.g. '2026-01-01'.
    Returns (uid, raw_rfc822) tuples sorted by UID ascending.
    """
    status, _ = conn.select(f'"{folder}"', readonly=True)
    if status != "OK":
        raise RuntimeError(f"SELECT '{folder}' failed: {status}")

    # IMAP SEARCH date format: DD-Mon-YYYY (e.g. 01-Jan-2026)
    dt = datetime.strptime(since_date, "%Y-%m-%d")
    imap_date = dt.strftime("%d-%b-%Y")

    status, data = conn.uid("SEARCH", None, f"SINCE {imap_date}")  # type: ignore[arg-type]
    if status != "OK":
        raise RuntimeError(f"UID SEARCH SINCE failed: {status}")

    uid_list_raw = data[0]
    if not uid_list_raw:
        return []

    uid_strings = uid_list_raw.decode().split()
    if not uid_strings:
        return []

    valid_uids = [int(u) for u in uid_strings]
    if not valid_uids:
        return []
    if max_uids > 0:
        valid_uids = valid_uids[-max_uids:]

    uid_set = ",".join(str(u) for u in valid_uids)
    status, fetch_data = conn.uid("FETCH", uid_set, "(BODY.PEEK[])")  # type: ignore[arg-type]
    if status != "OK":
        raise RuntimeError(f"UID FETCH failed: {status}")

    # last_uid=0 → keep all messages (UIDs are always >= 1)
    return _parse_fetch_response(fetch_data, valid_uids, last_uid=0)


# ---------------------------------------------------------------------------
# .eml file output
# ---------------------------------------------------------------------------

def _write_eml(
    target: EmlWriteTarget,
    raw_msg: bytes,
    receipt: tuple[ReceiptContext, list[dict]] | None = None,
) -> Path:
    """Write raw RFC-822 bytes to inbox_dir/email-<mailbox_id>-<folder>-<uid>.eml.

    Folder is included to prevent UID collisions across folders (UIDs are
    per-folder on IMAP servers, so the same UID can exist in multiple folders).
    """
    Path(target.inbox_dir).mkdir(parents=True, exist_ok=True)
    safe_id = re.sub(r"[^a-zA-Z0-9_-]", "_", target.mailbox_id)
    safe_folder = re.sub(r"[^a-zA-Z0-9_-]", "_", target.folder)
    filename = f"email-{safe_id}-{safe_folder}-{target.uid}.eml"
    out_path = Path(target.inbox_dir) / filename
    staging_path = out_path.with_suffix(".eml.tmp")
    try:
        staging_path.write_bytes(raw_msg)
        if receipt is not None:
            context, rules = receipt
            write_collection_receipt(out_path, context, rules)
        staging_path.replace(out_path)
    finally:
        staging_path.unlink(missing_ok=True)
    return out_path


# ---------------------------------------------------------------------------
# Folder-level polling helper
# ---------------------------------------------------------------------------

def _prepare_rule_scan(
    mb_id: str, folder: str, state: dict, config: PollConfig
) -> tuple[RuleScanContext, int]:
    """Prepare independent rule cursors and the bounded fetch window."""
    rules = select_rules({"rules": config.rules}, mb_id, folder) if config.rules else []
    rule_keys = {_filter_state_key(mb_id, folder, rule): rule for rule in rules}
    rule_cursors = {
        rule_key: state.get(rule_key, {}).get("last_uid_seen", 0)
        for rule_key in rule_keys
    }
    last_uid = min(rule_cursors.values()) if rule_cursors else state.get(_state_key(mb_id, folder), {}).get("last_uid_seen", 0)
    context = RuleScanContext(
        rule_keys=rule_keys,
        rule_cursors=rule_cursors,
        pending_states={rule_key: dict(state.get(rule_key, {})) for rule_key in rule_keys},
        account_identities=config.account_identities,
        filtering_enabled=_mailbox_filtering_enabled(config.rules, mb_id),
    )
    return context, last_uid


def _rule_candidate_uids(
    conn: imaplib.IMAP4_SSL,
    folder: str,
    entries: dict[str, tuple[dict, int]],
    minimum_since: str = "",
    max_uids: int = 0,
) -> tuple[dict[str, set[int]], dict[str, dict[str, object]]]:
    """Select a bounded candidate window independently for each rule lineage."""
    selected: dict[str, set[int]] = {}
    evidence: dict[str, dict[str, object]] = {}
    for rule_key, (rule, cursor) in entries.items():
        backfill = rule.get("backfill") or {}
        limit = int(backfill.get("limit", 500))
        if max_uids > 0:
            limit = min(limit, max_uids)
        since_date = max(minimum_since, str(backfill.get("since") or ""))
        candidate_uids, evidence[rule_key] = _search_uids_since(
            conn,
            folder,
            cursor,
            max_uids=limit,
            since_date=since_date,
        )
        selected[rule_key] = set(candidate_uids)
    return selected, evidence


def _fetch_poll_candidates(
    conn: imaplib.IMAP4_SSL,
    folder: str,
    context: RuleScanContext,
    last_uid: int,
    max_uids: int,
) -> list[tuple[int, bytes]]:
    if not context.rule_keys:
        if context.filtering_enabled:
            return []
        return _uid_fetch_since(conn, folder, last_uid, max_uids=max_uids)
    entries = {
        rule_key: (rule, context.rule_cursors[rule_key])
        for rule_key, rule in context.rule_keys.items()
    }
    context.candidate_uids, context.candidate_evidence = _rule_candidate_uids(
        conn,
        folder,
        entries,
        max_uids=max_uids,
    )
    union = sorted(set().union(*context.candidate_uids.values()))
    return _uid_fetch_selected(conn, union)


def _scan_poll_message(
    uid: int, raw_msg: bytes, context: RuleScanContext, folder_result: dict
) -> bool:
    """Apply each unseen rule and update only content-free pending receipts."""
    if not context.rule_keys:
        if context.filtering_enabled:
            return False
        folder_result["scanned"] += 1
        return True
    fields = fields_from_bytes(raw_msg)
    should_write = False
    for rule_key, rule in context.rule_keys.items():
        if uid not in context.candidate_uids[rule_key]:
            continue
        match = match_rule(rule, fields, context.account_identities)
        folder_result["scanned"] += 1
        folder_result["coverage_gaps"].extend(match.unavailable_fields)
        if match.matched:
            should_write = True
            context.matched_rules_by_uid.setdefault(uid, []).append(rule)
            current = folder_result["matched_rules"].get(match.rule_id, 0)
            folder_result["matched_rules"][match.rule_id] = current + 1
        prior = context.pending_states[rule_key]
        candidate_evidence = context.candidate_evidence.get(rule_key, {})
        context.pending_states[rule_key] = {
            "last_uid_seen": uid,
            "last_polled_at": folder_result["last_polled_at"],
            "scanned": prior.get("scanned", 0) + 1,
            "matched": prior.get("matched", 0) + int(match.matched),
            "coverage_gaps": sorted(
                set(prior.get("coverage_gaps", [])) | set(match.unavailable_fields)
            ),
            "candidate_total": candidate_evidence.get("candidate_total", 0),
            "has_more": bool(candidate_evidence.get("has_more")),
            "backfill_truncated": bool(prior.get("backfill_truncated"))
            or bool(candidate_evidence.get("backfill_truncated")),
            "mode": candidate_evidence.get("mode", "incremental"),
        }
    return should_write


def _poll_folder(
    conn: imaplib.IMAP4_SSL,
    mb_id: str,
    folder: str,
    state: dict,
    config: PollConfig,
) -> dict:
    """Poll a single IMAP folder; update state in place.

    Returns a folder-result dict: {folder, fetched, new_high_uid, error}.
    Separated from poll_mailbox to keep cyclomatic complexity low.
    """
    import time  # noqa: PLC0415

    key = _state_key(mb_id, folder)
    scan_context, last_uid = _prepare_rule_scan(mb_id, folder, state, config)
    now_iso = datetime.now(timezone.utc).isoformat()
    folder_result: dict = {
        "folder": folder,
        "fetched": 0,
        "scanned": 0,
        "matched_rules": {},
        "coverage_gaps": [],
        "candidate_total": 0,
        "has_more": False,
        "backfill_truncated": False,
        "error": None,
        "last_polled_at": now_iso,
    }

    try:
        messages = _fetch_poll_candidates(
            conn, folder, scan_context, last_uid, config.max_messages
        )
        evidence = list(scan_context.candidate_evidence.values())
        folder_result["candidate_total"] = sum(
            int(item.get("candidate_total", 0)) for item in evidence
        )
        folder_result["has_more"] = any(item.get("has_more") for item in evidence)
        folder_result["backfill_truncated"] = any(
            item.get("backfill_truncated") for item in evidence
        )
    except Exception as exc:
        folder_result["error"] = str(exc)
        folder_result["new_high_uid"] = last_uid
        return folder_result

    new_high_uid = last_uid
    delay = (60.0 / config.rate_limit_per_min) if config.rate_limit_per_min > 0 else 0
    pending_writes: list[tuple[int, bytes]] = []

    try:
        for uid, raw_msg in messages:
            should_write = _scan_poll_message(uid, raw_msg, scan_context, folder_result)
            if should_write:
                pending_writes.append((uid, raw_msg))
            new_high_uid = max(new_high_uid, uid)
            folder_result["fetched"] += int(should_write)
            if delay > 0:
                time.sleep(delay)

        if not config.dry_run:
            for uid, raw_msg in pending_writes:
                rules = scan_context.matched_rules_by_uid.get(uid, [])
                collection_receipt = None
                if rules:
                    receipt_context = ReceiptContext("imap", mb_id, folder, str(uid))
                    collection_receipt = (receipt_context, rules)
                _write_eml(
                    EmlWriteTarget(config.inbox_dir, mb_id, folder, uid),
                    raw_msg,
                    collection_receipt,
                )
            if scan_context.rule_keys:
                state.update(scan_context.pending_states)
            elif new_high_uid > last_uid:
                state[key] = {"last_uid_seen": new_high_uid, "last_polled_at": now_iso}
    except Exception as exc:
        folder_result["error"] = type(exc).__name__
        folder_result["new_high_uid"] = last_uid
        return folder_result

    folder_result["coverage_gaps"] = sorted(set(folder_result["coverage_gaps"]))
    folder_result.pop("last_polled_at")
    folder_result["new_high_uid"] = new_high_uid
    return folder_result


# ---------------------------------------------------------------------------
# Core polling logic
# ---------------------------------------------------------------------------

def poll_mailbox(mb_config: dict, state: dict, config: "PollConfig | None" = None) -> dict:
    """Poll a single mailbox; return a per-mailbox result dict.

    Args:
        mb_config: Entry from mailboxes.json 'mailboxes' array.
        state:     Full state dict (mutated in place on success).
        config:    PollConfig with inbox_dir, dry_run, rate_limit_per_min,
                   max_messages.  Defaults to PollConfig() (empty inbox_dir,
                   no limits) when None.

    Returns:
        {mailbox_id, status, fetched_count, folders, error?}
    """
    if config is None:
        config = PollConfig()

    mb_id = mb_config["id"]
    host = mb_config["host"]
    port = int(mb_config.get("port", 993))
    user = mb_config["user"]
    password_ref = mb_config.get("password_ref", "")
    folders = mb_config.get("folders", ["INBOX"])
    now_iso = datetime.now(timezone.utc).isoformat()

    result: dict = {
        "mailbox_id": mb_id,
        "status": "ok",
        "fetched_count": 0,
        "folders": {},
    }

    try:
        password = _resolve_password(password_ref)
    except Exception as exc:
        result["status"] = "credential_error"
        result["error"] = str(exc)
        state.setdefault(mb_id, {})["last_error"] = str(exc)
        state[mb_id]["last_polled_at"] = now_iso
        return result

    try:
        conn = _connect_imap(host, port, user, password)
    except Exception as exc:
        result["status"] = "connection_error"
        result["error"] = str(exc)
        state.setdefault(mb_id, {})["last_error"] = str(exc)
        state[mb_id]["last_polled_at"] = now_iso
        return result

    total_fetched = 0
    identities = tuple(mb_config.get("identities") or ()) + (user,)
    folder_config = replace(config, account_identities=identities)
    try:
        for folder in folders:
            folder_result = _poll_folder(conn, mb_id, folder, state, folder_config)
            if folder_result.get("error"):
                result["status"] = "partial_error"
            total_fetched += folder_result["fetched"]
            result["folders"][folder] = folder_result
    finally:
        try:
            conn.logout()
        except Exception:
            pass

    result["fetched_count"] = total_fetched
    if not config.dry_run:
        state.setdefault(mb_id, {})["last_polled_at"] = now_iso
        state[mb_id].pop("last_error", None)

    return result


def _record_backfill_match(
    context: BackfillContext, rule: dict, uid: int, match: MatchResult
) -> None:
    """Record one sanitized rule receipt without persisting message content."""
    receipt_key = _backfill_receipt_key(context, rule)
    prior = context.state.get(receipt_key, {})
    candidate_evidence = context.candidate_evidence.get(receipt_key, {})
    context.state[receipt_key] = {
        "last_uid_seen": uid,
        "last_scanned_at": datetime.now(timezone.utc).isoformat(),
        "since": context.config.since_date,
        "scanned": prior.get("scanned", 0) + 1,
        "matched": prior.get("matched", 0) + int(match.matched),
        "coverage_gaps": sorted(
            set(prior.get("coverage_gaps", [])) | set(match.unavailable_fields)
        ),
        "candidate_total": candidate_evidence.get("candidate_total", 0),
        "has_more": bool(candidate_evidence.get("has_more")),
        "backfill_truncated": bool(prior.get("backfill_truncated"))
        or bool(candidate_evidence.get("backfill_truncated")),
        "mode": candidate_evidence.get("mode", "initial"),
    }
    if match.matched:
        context.matched_rules_by_uid.setdefault(uid, []).append(rule)


def _backfill_receipt_key(context: BackfillContext, rule: dict) -> str:
    rule_since = str((rule.get("backfill") or {}).get("since") or "")
    effective_since = max(context.config.since_date, rule_since)
    return _backfill_state_key(
        context.mailbox_id, context.folder, rule, effective_since
    )


def _scan_backfill_message(context: BackfillContext, uid: int, raw_msg: bytes) -> bool:
    if not context.active_rules:
        return not context.filtering_enabled
    fields = fields_from_bytes(raw_msg)
    should_write = False
    for rule in context.active_rules:
        receipt_key = _backfill_receipt_key(context, rule)
        if uid not in context.candidate_uids[receipt_key]:
            continue
        match = match_rule(rule, fields, context.account_identities)
        _record_backfill_match(context, rule, uid, match)
        should_write = should_write or match.matched
    return should_write


def _backfill_messages(
    conn: imaplib.IMAP4_SSL, context: BackfillContext
) -> list[tuple[int, bytes]]:
    if not context.active_rules:
        if context.filtering_enabled:
            return []
        return _uid_fetch_since_date(conn, context.folder, context.config.since_date)
    entries = {
        key: (rule, context.state.get(key, {}).get("last_uid_seen", 0))
        for rule in context.active_rules
        for key in [_backfill_receipt_key(context, rule)]
    }
    context.candidate_uids, context.candidate_evidence = _rule_candidate_uids(
        conn,
        context.folder,
        entries,
        minimum_since=context.config.since_date,
    )
    union = sorted(set().union(*context.candidate_uids.values()))
    return _uid_fetch_selected(conn, union)


def _process_backfill_messages(
    context: BackfillContext, messages: list[tuple[int, bytes]], result: dict
) -> None:
    import time  # noqa: PLC0415

    delay = 60.0 / context.config.rate_limit_per_min if context.config.rate_limit_per_min > 0 else 0
    for uid, raw_msg in messages:
        should_write = _scan_backfill_message(context, uid, raw_msg)
        if should_write:
            rules = context.matched_rules_by_uid.get(uid, [])
            collection_receipt = None
            if rules:
                receipt_context = ReceiptContext(
                    "imap", context.mailbox_id, context.folder, str(uid)
                )
                collection_receipt = (receipt_context, rules)
            _write_eml(
                EmlWriteTarget(
                    context.config.inbox_dir,
                    context.mailbox_id,
                    context.folder,
                    uid,
                ),
                raw_msg,
                collection_receipt,
            )
            result["fetched"] += 1
        result["scanned"] += 1
        if delay > 0:
            time.sleep(delay)
    result["message_count"] = len(messages)


def _backfill_folder(conn: imaplib.IMAP4_SSL, context: BackfillContext) -> dict:
    result = {
        "folder": context.folder,
        "fetched": 0,
        "scanned": 0,
        "candidate_total": 0,
        "has_more": False,
        "backfill_truncated": False,
        "error": None,
    }
    try:
        messages = _backfill_messages(conn, context)
    except Exception as exc:
        result["error"] = str(exc)
        return result
    evidence = list(context.candidate_evidence.values())
    result["candidate_total"] = sum(
        int(item.get("candidate_total", 0)) for item in evidence
    )
    result["has_more"] = any(item.get("has_more") for item in evidence)
    result["backfill_truncated"] = any(
        item.get("backfill_truncated") for item in evidence
    )
    _process_backfill_messages(context, messages, result)
    return result


def _backfill_mailbox_folders(
    conn: imaplib.IMAP4_SSL,
    mb_config: dict,
    state: dict,
    config: BackfillConfig,
    result: dict,
) -> int:
    mailbox_id = mb_config["id"]
    identities = tuple(mb_config.get("identities") or ()) + (mb_config["user"],)
    total_fetched = 0
    for folder in mb_config.get("folders", ["INBOX"]):
        active_rules = select_rules({"rules": config.rules}, mailbox_id, folder) if config.rules else []
        context = BackfillContext(
            mailbox_id,
            folder,
            state,
            config,
            active_rules,
            identities,
            _mailbox_filtering_enabled(config.rules, mailbox_id),
        )
        folder_result = _backfill_folder(conn, context)
        if folder_result["error"]:
            result["status"] = "partial_error"
        total_fetched += folder_result["fetched"]
        result["folders"][folder] = folder_result
    return total_fetched


def _safe_logout(conn: imaplib.IMAP4_SSL) -> None:
    try:
        conn.logout()
    except Exception:
        pass


def backfill_mailbox(mb_config: dict, state: dict, config: BackfillConfig) -> dict:
    """Back-fill a single mailbox from since_date (bypasses last-seen UID).

    Rate-limited to avoid IMAP-server abuse (default: 100 msgs/min).
    Does NOT update the high-watermark UID (backfill is additive, not a tick).
    """
    mb_id = mb_config["id"]
    host = mb_config["host"]
    port = int(mb_config.get("port", 993))
    user = mb_config["user"]
    password_ref = mb_config.get("password_ref", "")
    result: dict = {
        "mailbox_id": mb_id,
        "status": "ok",
        "fetched_count": 0,
        "since_date": config.since_date,
        "folders": {},
    }

    try:
        password = _resolve_password(password_ref)
    except Exception as exc:
        result["status"] = "credential_error"
        result["error"] = str(exc)
        return result

    try:
        conn = _connect_imap(host, port, user, password)
    except Exception as exc:
        result["status"] = "connection_error"
        result["error"] = str(exc)
        return result

    try:
        total_fetched = _backfill_mailbox_folders(conn, mb_config, state, config, result)
    finally:
        _safe_logout(conn)

    result["fetched_count"] = total_fetched
    return result


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_tick(args: argparse.Namespace) -> int:
    """Tick: poll all mailboxes, write new messages to inbox."""
    config = load_mailboxes_config(args.config)
    state = load_state(args.state)
    rules = load_rule_config(args.filters).get("rules", []) if args.filters else []
    poll_cfg = PollConfig(inbox_dir=args.inbox, rules=rules)
    results = []
    overall_ok = True

    for mb_config in config.get("mailboxes", []):
        try:
            res = poll_mailbox(mb_config, state, poll_cfg)
        except Exception as exc:  # noqa: BLE001
            res = {
                "mailbox_id": mb_config.get("id", "unknown"),
                "status": "exception",
                "error": str(exc),
                "fetched_count": 0,
            }
        results.append(res)
        if res["status"] not in ("ok",):
            overall_ok = False

    save_state(args.state, state)

    output = {
        "tick": datetime.now(timezone.utc).isoformat(),
        "results": results,
        "overall_status": "ok" if overall_ok else "partial_error",
    }
    print(json.dumps(output, indent=2))
    return 0 if overall_ok else 1


def cmd_backfill(args: argparse.Namespace) -> int:
    """Backfill a specific mailbox from a given date."""
    config = load_mailboxes_config(args.config)
    mb_config = get_mailbox_config(config, args.mailbox_id)
    state = load_state(args.state)
    rules = load_rule_config(args.filters).get("rules", []) if args.filters else []

    backfill_config = BackfillConfig(
        inbox_dir=args.inbox,
        since_date=args.since,
        rate_limit_per_min=args.rate_limit,
        rules=rules,
    )
    res = backfill_mailbox(mb_config, state, backfill_config)
    save_state(args.state, state)
    print(json.dumps(res, indent=2))
    return 0 if res["status"] == "ok" else 1


def cmd_test(args: argparse.Namespace) -> int:
    """Dry-run: fetch 1 message from each folder, do NOT write .eml or update state."""
    config = load_mailboxes_config(args.config)
    mb_config = get_mailbox_config(config, args.mailbox_id)
    state: dict = {}

    poll_cfg = PollConfig(inbox_dir="/dev/null", dry_run=True, max_messages=1)
    res = poll_mailbox(mb_config, state, poll_cfg)
    print(json.dumps(res, indent=2))
    return 0 if res["status"] in ("ok", "partial_error") else 1


def cmd_list(args: argparse.Namespace) -> int:
    """List configured mailboxes with last-polled-at and last-error."""
    config = load_mailboxes_config(args.config)
    state: dict = {}
    if args.state and Path(args.state).exists():
        state = load_state(args.state)

    rows = []
    for mb in config.get("mailboxes", []):
        mb_id = mb["id"]
        folders = mb.get("folders", ["INBOX"])
        folder_states = {}
        for f in folders:
            key = _state_key(mb_id, f)
            fs = state.get(key, {})
            folder_states[f] = {
                "last_uid_seen": fs.get("last_uid_seen", 0),
                "last_polled_at": fs.get("last_polled_at"),
            }
        mb_state = state.get(mb_id, {})
        rows.append({
            "id": mb_id,
            "provider": mb.get("provider"),
            "host": mb["host"],
            "user": mb["user"],
            "folders": folders,
            "last_polled_at": mb_state.get("last_polled_at"),
            "last_error": mb_state.get("last_error"),
            "folder_state": folder_states,
        })

    print(json.dumps({"mailboxes": rows}, indent=2))
    return 0


# ---------------------------------------------------------------------------
# Argument parsing and main
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="IMAP polling for aidevops knowledge plane (t2855)"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # tick
    p_tick = sub.add_parser("tick", help="Poll all mailboxes for new messages")
    p_tick.add_argument("--config", required=True, help="Path to mailboxes.json")
    p_tick.add_argument("--state", required=True, help="Path to .imap-state.json")
    p_tick.add_argument("--inbox", required=True, help="Directory to write .eml files")
    p_tick.add_argument("--filters", help="Optional version 2 email filter config")

    # backfill
    p_bf = sub.add_parser("backfill", help="Backfill a mailbox from a given date")
    p_bf.add_argument("--config", required=True)
    p_bf.add_argument("--state", required=True)
    p_bf.add_argument("--inbox", required=True)
    p_bf.add_argument("--mailbox-id", required=True, help="Mailbox ID to backfill")
    p_bf.add_argument("--filters", help="Optional version 2 email filter config")
    p_bf.add_argument("--since", required=True, help="ISO date, e.g. 2026-01-01")
    p_bf.add_argument(
        "--rate-limit", type=int, default=100,
        help="Max messages per minute (default: 100)"
    )

    # test
    p_test = sub.add_parser("test", help="Dry-run: connect + fetch without writing files")
    p_test.add_argument("--config", required=True)
    p_test.add_argument("--mailbox-id", required=True)

    # list
    p_list = sub.add_parser("list", help="List configured mailboxes and their state")
    p_list.add_argument("--config", required=True)
    p_list.add_argument("--state", default="", help="Optional path to .imap-state.json")

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    dispatch = {
        "tick": cmd_tick,
        "backfill": cmd_backfill,
        "test": cmd_test,
        "list": cmd_list,
    }

    handler = dispatch.get(args.command)
    if handler is None:
        print(f"Unknown command: {args.command}", file=sys.stderr)
        return 2

    try:
        return handler(args)
    except KeyboardInterrupt:
        return 130
    except Exception as exc:  # noqa: BLE001
        print(f"Fatal error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
