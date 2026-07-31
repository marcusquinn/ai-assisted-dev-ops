#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deterministic, transport-neutral matching for filtered email collection.

Server-side IMAP/JMAP predicates may reduce candidate reads, but this module is
the final authority before a message is written to the knowledge inbox.
Diagnostics intentionally expose rule IDs and field names, never rule literals
or message content.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import sys
from dataclasses import dataclass, field
from email import policy
from email.message import Message
from email.parser import BytesParser
from email.utils import getaddresses
from pathlib import Path
from typing import Any, Iterable, Mapping

from email_match_evaluator import condition_dependencies, condition_matches, groups_match
from email_match_validation import (
    ADDRESS_FIELDS,
    RULESET_VERSION,
    RuleValidationError,
    conditions,
    match_block,
    normalize_address,
    validate_rule,
)


@dataclass(frozen=True)
class MessageFields:
    """Normalized fields used by both IMAP and JMAP candidates."""

    addresses: dict[str, tuple[str, ...]]
    subject: str = ""
    body: str = ""
    headers: dict[str, str] = field(default_factory=dict)
    attachment_names: tuple[str, ...] = ()
    unavailable_fields: tuple[str, ...] = ()


@dataclass(frozen=True)
class MatchResult:
    """Content-free result suitable for logs and checkpoint coverage."""

    matched: bool
    rule_id: str
    matched_fields: tuple[str, ...] = ()
    unavailable_fields: tuple[str, ...] = ()

    def explanation(self) -> dict[str, Any]:
        """Return a diagnostic that cannot disclose private match literals."""
        return {
            "matched": self.matched,
            "rule_id": self.rule_id,
            "matched_fields": list(self.matched_fields),
            "unavailable_fields": list(self.unavailable_fields),
        }


def _parsed_addresses(values: list[str]) -> list[str]:
    return [address for _name, address in getaddresses(values)]


def _list_address_candidates(values: list[object]) -> list[object]:
    mapped: list[object] = []
    header_values: list[str] = []
    for item in values:
        if isinstance(item, Mapping):
            mapped.append(item.get("email", ""))
        else:
            header_values.append(str(item))
    return mapped + _parsed_addresses(header_values)


def _address_candidates(value: object) -> list[object]:
    if isinstance(value, list):
        return _list_address_candidates(value)
    return _parsed_addresses([str(value or "")])


def _addresses(value: object) -> tuple[str, ...]:
    candidates = _address_candidates(value)
    normalized = (normalize_address(candidate) for candidate in candidates)
    return tuple(dict.fromkeys(address for address in normalized if address))


def _decode_part(part: Message) -> str:
    try:
        content = part.get_content()
    except (LookupError, UnicodeError):
        payload = part.get_payload(decode=True) or b""
        content = payload.decode(part.get_content_charset() or "utf-8", errors="replace")
    return content if isinstance(content, str) else ""


def _message_content(message: Message) -> tuple[str, tuple[str, ...]]:
    body_parts: list[str] = []
    attachment_names: list[str] = []
    parts: Iterable[Message] = message.walk() if message.is_multipart() else (message,)
    for part in parts:
        filename = part.get_filename()
        if filename:
            attachment_names.append(filename)
            continue
        if part.get_content_type() in {"text/plain", "text/html"}:
            text = _decode_part(part)
            if part.get_content_type() == "text/html":
                text = html.unescape(re.sub(r"<[^>]+>", " ", text))
            body_parts.append(text)
    return "\n".join(body_parts), tuple(attachment_names)


def fields_from_bytes(raw_message: bytes) -> MessageFields:
    """Decode an RFC-822 candidate without making any provider mutation."""
    message = BytesParser(policy=policy.default).parsebytes(raw_message)
    if any(part.defects for part in message.walk()):
        raise ValueError("malformed RFC-822 message")
    addresses = {name: _addresses(message.get_all(name, [])) for name in ADDRESS_FIELDS}
    unavailable = ("bcc",) if "bcc" not in message else ()
    body, attachment_names = _message_content(message)
    headers = {name.casefold(): "\n".join(message.get_all(name, [])) for name in message.keys()}
    return MessageFields(
        addresses=addresses,
        subject=str(message.get("subject", "")),
        body=body,
        headers=headers,
        attachment_names=attachment_names,
        unavailable_fields=unavailable,
    )


def _attachment_names(message: Mapping[str, Any]) -> tuple[str, ...]:
    attachments = message.get("attachments") or []
    return tuple(
        str(item.get("name") or item.get("filename") or item.get("attachment_filename") or "")
        for item in attachments
        if isinstance(item, Mapping)
    )


def _mapping_headers(message: Mapping[str, Any]) -> dict[str, str]:
    raw_headers = message.get("headers") or {}
    if not isinstance(raw_headers, Mapping):
        return {}
    return {str(name).casefold(): str(value) for name, value in raw_headers.items()}


def _mapping_body(message: Mapping[str, Any]) -> str:
    body = next(filter(None, map(message.get, ("body", "text_body"))), "")
    html_body = html.unescape(
        re.sub(r"<[^>]+>", " ", str(message.get("html_body") or ""))
    )
    preview = next(filter(None, map(message.get, ("body_preview", "preview"))), "")
    return str(next(filter(None, (body, html_body, preview)), ""))


def fields_from_mapping(message: Mapping[str, Any]) -> MessageFields:
    """Build fields from JMAP data or an ingested ``meta.json`` mapping."""
    unavailable = tuple(name for name in ADDRESS_FIELDS if name not in message)
    addresses = {name: _addresses(message.get(name, "")) for name in ADDRESS_FIELDS}
    return MessageFields(
        addresses=addresses,
        subject=str(message.get("subject") or message.get("title") or ""),
        body=_mapping_body(message),
        headers=_mapping_headers(message),
        attachment_names=_attachment_names(message),
        unavailable_fields=unavailable,
    )


def load_rule_config(source: str | Path | Mapping[str, Any]) -> dict[str, Any]:
    """Load and strictly validate a version 2 private filter configuration."""
    if isinstance(source, Mapping):
        config = dict(source)
    else:
        with Path(source).open(encoding="utf-8") as handle:
            config = json.load(handle)
    if set(config) - {"version", "rules", "_comment", "_doc"}:
        raise RuleValidationError("ruleset has unsupported keys")
    if config.get("version") != RULESET_VERSION:
        raise RuleValidationError(f"filtered collection requires ruleset version {RULESET_VERSION}")
    rules = config.get("rules")
    if not isinstance(rules, list):
        raise RuleValidationError("rules must be an array")
    seen: set[str] = set()
    for rule in rules:
        if not isinstance(rule, Mapping):
            raise RuleValidationError("each rule must be an object")
        validate_rule(rule)
        rule_id = str(rule["id"])
        if rule_id in seen:
            raise RuleValidationError(f"duplicate rule id '{rule_id}'")
        seen.add(rule_id)
    return config


def rule_digest(rule: Mapping[str, Any]) -> str:
    """Return a stable lineage digest without exposing private literals."""
    material = {
        "match": match_block(rule),
        "mailboxes": rule.get("mailboxes", []),
        "folders": rule.get("folders", []),
        "backfill": rule.get("backfill", {}),
    }
    encoded = json.dumps(material, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(encoded).hexdigest()[:16]


def select_rules(config: Mapping[str, Any], mailbox_id: str, folder: str) -> list[dict[str, Any]]:
    """Select enabled collection rules for a mailbox/folder pair."""
    selected = []
    for raw_rule in config.get("rules", []):
        rule = dict(raw_rule)
        if rule.get("enabled", True) is False or rule.get("collection", True) is False:
            continue
        if rule.get("mailboxes") and mailbox_id not in rule["mailboxes"]:
            continue
        if rule.get("folders") and folder not in rule["folders"]:
            continue
        selected.append(rule)
    return selected


def _normalized_identities(account_identities: Iterable[str]) -> tuple[str, ...]:
    normalized = (normalize_address(value) for value in account_identities)
    return tuple(address for address in normalized if address)


def _evaluate_conditions(
    rule_conditions: list[Mapping[str, Any]],
    fields: MessageFields,
    identities: tuple[str, ...],
) -> list[bool]:
    return [condition_matches(item, fields, identities) for item in rule_conditions]


def _match_details(
    evaluated: list[tuple[Mapping[str, Any], bool]], unavailable_fields: tuple[str, ...]
) -> tuple[tuple[str, ...], tuple[str, ...]]:
    matched_fields = tuple(dict.fromkeys(str(condition["field"]) for condition, result in evaluated if result))
    condition_fields = set().union(*(condition_dependencies(condition) for condition, _ in evaluated))
    unavailable = tuple(sorted(set(unavailable_fields) & condition_fields))
    return matched_fields, unavailable


def match_rule(
    rule: Mapping[str, Any],
    fields: MessageFields,
    account_identities: Iterable[str] = (),
) -> MatchResult:
    """Evaluate ``all`` and ``any`` groups and return a redacted result."""
    validate_rule(rule)
    rule_id = str(rule["id"])
    identities = _normalized_identities(account_identities)
    block = match_block(rule)
    all_conditions = conditions(block, "all")
    any_conditions = conditions(block, "any")
    all_results = _evaluate_conditions(all_conditions, fields, identities)
    any_results = _evaluate_conditions(any_conditions, fields, identities)
    matched = groups_match(all_results, any_results)
    evaluated = list(zip(all_conditions + any_conditions, all_results + any_results))
    matched_fields, unavailable = _match_details(evaluated, fields.unavailable_fields)
    return MatchResult(matched, rule_id, matched_fields, unavailable)


def _load_meta_fields(meta_path: Path) -> MessageFields:
    with meta_path.open(encoding="utf-8") as handle:
        meta = json.load(handle)
    text_path = meta_path.parent / "text.txt"
    if text_path.is_file():
        meta["body"] = text_path.read_text(encoding="utf-8", errors="replace")
    return fields_from_mapping(meta)


def _cmd_match_meta(args: argparse.Namespace) -> int:
    try:
        rule_input = json.load(sys.stdin)
        rule = rule_input if "id" in rule_input or "name" in rule_input else {"id": "private-rule", "match": rule_input}
        result = match_rule(rule, _load_meta_fields(Path(args.meta)), args.account_identity)
    except (OSError, json.JSONDecodeError, RuleValidationError) as exc:
        print(json.dumps({"error": type(exc).__name__}), file=sys.stderr)
        return 2
    print(json.dumps(result.explanation(), sort_keys=True))
    return 0 if result.matched else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Deterministic private email-rule matcher")
    sub = parser.add_subparsers(dest="command", required=True)
    match_meta = sub.add_parser("match-meta", help="Match stdin rule JSON against an ingested email")
    match_meta.add_argument("--meta", required=True)
    match_meta.add_argument("--account-identity", action="append", default=[])
    args = parser.parse_args()
    if args.command == "match-meta":
        return _cmd_match_meta(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
