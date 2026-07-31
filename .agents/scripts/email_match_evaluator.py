#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Low-level condition evaluation for deterministic email matching."""

from __future__ import annotations

import re
import unicodedata
from typing import Any, Mapping

from email_match_validation import ADDRESS_FIELDS, normalize_address, normalize_domain


def condition_dependencies(condition: Mapping[str, Any]) -> set[str]:
    """Return normalized message fields needed to evaluate a condition."""
    field_name = str(condition["field"])
    if field_name not in {"reference", "keyword", "phrase"}:
        return {field_name}
    targets = {
        "subject": {"subject"},
        "body": {"body"},
        "attachment_name": {"attachment_name"},
        "subject_body": {"subject", "body"},
    }
    return targets[str(condition.get("target", "subject_body"))]


def groups_match(all_results: list[bool], any_results: list[bool]) -> bool:
    """Combine deterministic ``all`` and ``any`` condition groups."""
    return all(all_results) and (any(any_results) if any_results else True)


def normalize_text(value: object, *, case_sensitive: bool = False) -> str:
    """Apply deterministic Unicode and whitespace normalization."""
    normalized = unicodedata.normalize("NFKC", str(value or ""))
    normalized = " ".join(normalized.split())
    return normalized if case_sensitive else normalized.casefold()


def _field_values(condition: Mapping[str, Any], fields: Any) -> tuple[str, ...]:
    field_name = str(condition["field"])
    if field_name in ADDRESS_FIELDS:
        values = fields.addresses.get(field_name, ())
    elif field_name == "subject":
        values = (fields.subject,)
    elif field_name == "body":
        values = (fields.body,)
    elif field_name == "attachment_name":
        values = fields.attachment_names
    elif field_name == "header":
        header_name = str(condition.get("header", "")).casefold()
        values = (fields.headers.get(header_name, ""),)
    else:
        target = str(condition.get("target", "subject_body"))
        targets = {
            "subject": (fields.subject,),
            "body": (fields.body,),
            "attachment_name": fields.attachment_names,
            "subject_body": (fields.subject, fields.body),
        }
        values = targets[target]
    return values


def _text_match(value: str, literal: str, operator: str, case_sensitive: bool) -> bool:
    haystack = normalize_text(value, case_sensitive=case_sensitive)
    needle = normalize_text(literal, case_sensitive=case_sensitive)
    if operator in {"exact", "equals"}:
        return haystack == needle
    if operator in {"contains", "phrase"}:
        return needle in haystack
    boundary = r"\w" if operator == "keyword" else r"\w-"
    return re.search(rf"(?<![{boundary}]){re.escape(needle)}(?![{boundary}])", haystack) is not None


def _direction_matches(literal: str, fields: Any, account_identities: tuple[str, ...]) -> bool:
    senders = set(fields.addresses.get("from", ()))
    recipients = set().union(*(set(fields.addresses.get(name, ())) for name in ("to", "cc", "bcc")))
    identities = set(account_identities)
    sent = literal in {"sent", "either"} and bool(senders & identities)
    received = literal in {"received", "either"} and bool(recipients & identities)
    return sent or received


def _exact_address_match(operator: str, literal: str, values: tuple[str, ...]) -> bool | None:
    if operator == "exact_address":
        needle = normalize_address(literal)
        return bool(needle) and needle in values
    if operator == "exact_domain":
        domain = normalize_domain(literal)
        return bool(domain) and any(value.rsplit("@", 1)[-1] == domain for value in values)
    return None


def condition_matches(
    condition: Mapping[str, Any], fields: Any, account_identities: tuple[str, ...]
) -> bool:
    """Evaluate one already-validated condition against normalized fields."""
    field_name = str(condition["field"])
    operator = str(condition.get("operator", condition.get("mode")))
    literal = str(condition["value"])
    if field_name == "direction":
        return _direction_matches(literal, fields, account_identities)
    values = _field_values(condition, fields)
    exact_match = _exact_address_match(operator, literal, values)
    if exact_match is not None:
        return exact_match
    case_sensitive = bool(condition.get("case_sensitive", False))
    return any(_text_match(value, literal, operator, case_sensitive) for value in values)
