#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Strict schema validation and identity normalization for email match rules."""

from __future__ import annotations

import re
import unicodedata
from datetime import date
from email.utils import getaddresses
from typing import Any, Mapping

from email_match_header_validation import header_option_is_valid


RULESET_VERSION = 2
ADDRESS_FIELDS = {"from", "to", "cc", "bcc"}
TEXT_FIELDS = {"subject", "body", "header", "attachment_name", "reference", "keyword", "phrase"}
OPERATORS = {"exact", "exact_address", "exact_domain", "phrase", "keyword", "reference", "contains"}

RULE_KEYS = {
    "id", "name", "enabled", "collection", "mailboxes", "folders",
    "match", "actions", "backfill", "_comment",
}
CONDITION_KEYS = {"field", "operator", "mode", "value", "case_sensitive", "target", "header"}
TARGETS = {"subject_body", "subject", "body", "attachment_name"}


class RuleValidationError(ValueError):
    """Raised when a collection rule is ambiguous or unsafe."""


def normalize_address(value: object) -> str:
    """Normalize an addr-spec while preserving exact local/domain boundaries."""
    parsed = getaddresses([str(value or "")])
    address = parsed[0][1].strip() if parsed else ""
    if address.count("@") != 1:
        return ""
    local, domain = address.rsplit("@", 1)
    if not local or not domain:
        return ""
    try:
        normalized_domain = domain.rstrip(".").encode("idna").decode("ascii").casefold()
    except UnicodeError:
        return ""
    return f"{unicodedata.normalize('NFKC', local).casefold()}@{normalized_domain}"


def normalize_domain(value: object) -> str:
    """Normalize a standalone domain without allowing suffix matches."""
    domain = str(value or "").strip().lstrip("@").rstrip(".")
    try:
        return domain.encode("idna").decode("ascii").casefold()
    except UnicodeError:
        return ""


def match_block(rule: Mapping[str, Any]) -> Mapping[str, Any]:
    """Return the explicit match block, including legacy direct blocks."""
    block = rule.get("match", rule)
    if not isinstance(block, Mapping):
        raise RuleValidationError("rule match must be an object")
    return block


def conditions(block: Mapping[str, Any], group: str) -> list[Mapping[str, Any]]:
    """Return and type-check one condition group."""
    raw = block.get(group, [])
    if raw is None:
        return []
    if not isinstance(raw, list) or any(not isinstance(item, Mapping) for item in raw):
        raise RuleValidationError(f"match.{group} must be an array of conditions")
    return list(raw)


def _validated_rule_id(rule: Mapping[str, Any]) -> str:
    if set(rule) - RULE_KEYS:
        raise RuleValidationError("rule has unsupported keys")
    rule_id = rule.get("id")
    if not isinstance(rule_id, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", rule_id):
        raise RuleValidationError("rule requires a non-empty id")
    return rule_id


def _validate_rule_flags(rule: Mapping[str, Any], rule_id: str) -> None:
    if "name" in rule and not isinstance(rule["name"], str):
        raise RuleValidationError(f"rule '{rule_id}' name must be a string")
    for flag_name in ("enabled", "collection"):
        if flag_name in rule and not isinstance(rule[flag_name], bool):
            raise RuleValidationError(f"rule '{rule_id}' {flag_name} must be boolean")


def _validate_rule_selectors(rule: Mapping[str, Any], rule_id: str) -> None:
    for selector in ("mailboxes", "folders"):
        values = rule.get(selector, [])
        if not isinstance(values, list) or any(not isinstance(value, str) or not value for value in values):
            raise RuleValidationError(f"rule '{rule_id}' {selector} must contain strings")


def _validate_rule_metadata(rule: Mapping[str, Any]) -> str:
    rule_id = _validated_rule_id(rule)
    _validate_rule_flags(rule, rule_id)
    _validate_rule_selectors(rule, rule_id)
    return rule_id


def _validate_backfill(rule: Mapping[str, Any], rule_id: str) -> None:
    backfill = rule.get("backfill", {})
    if not isinstance(backfill, Mapping) or set(backfill) - {"since", "limit"}:
        raise RuleValidationError(f"rule '{rule_id}' has invalid backfill")
    limit = backfill.get("limit", 500)
    if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 5000:
        raise RuleValidationError(f"rule '{rule_id}' backfill limit must be 1..5000")
    if "since" not in backfill:
        return
    try:
        date.fromisoformat(str(backfill["since"]))
    except ValueError as exc:
        raise RuleValidationError(f"rule '{rule_id}' backfill since must be an ISO date") from exc


def _validate_actions(rule: Mapping[str, Any], rule_id: str) -> None:
    actions = rule.get("actions", [])
    if not isinstance(actions, list) or any(not isinstance(action, Mapping) for action in actions):
        raise RuleValidationError(f"rule '{rule_id}' actions must be objects")
    for action in actions:
        if set(action) - {"attach_to_case", "role", "set_sensitivity"}:
            raise RuleValidationError(f"rule '{rule_id}' action has unsupported keys")


def _validate_condition_shape(condition: Mapping[str, Any], rule_id: str) -> tuple[object, object]:
    if set(condition) - CONDITION_KEYS:
        raise RuleValidationError(f"rule '{rule_id}' condition has unsupported keys")
    field_name = condition.get("field")
    operator = condition.get("operator", condition.get("mode"))
    if field_name not in ADDRESS_FIELDS | TEXT_FIELDS | {"direction"}:
        raise RuleValidationError(f"rule '{rule_id}' has unsupported field")
    if operator not in OPERATORS | {"equals"}:
        raise RuleValidationError(f"rule '{rule_id}' has unsupported operator")
    value = condition.get("value")
    if not isinstance(value, str) or not " ".join(unicodedata.normalize("NFKC", value).split()):
        raise RuleValidationError(f"rule '{rule_id}' condition requires a value")
    return field_name, operator


def _validate_direction(field_name: object, operator: object, value: object) -> None:
    if field_name == "direction" and value not in {"sent", "received", "either"}:
        raise RuleValidationError("direction has an invalid value")
    if field_name == "direction" and operator not in {"exact", "equals"}:
        raise RuleValidationError("direction requires the equals operator")


def _validate_exact_address_operator(field_name: object, operator: object, value: object) -> None:
    if operator == "exact_address" and field_name not in ADDRESS_FIELDS:
        raise RuleValidationError("exact_address requires an address field")
    if operator == "exact_address" and not normalize_address(value):
        raise RuleValidationError("exact_address requires a valid addr-spec")


def _validate_exact_domain_operator(field_name: object, operator: object, value: object) -> None:
    if operator == "exact_domain" and field_name not in ADDRESS_FIELDS:
        raise RuleValidationError("exact_domain requires an address field")
    if operator == "exact_domain" and not normalize_domain(value):
        raise RuleValidationError("exact_domain requires a valid domain")


def _validate_condition_operator(
    condition: Mapping[str, Any], field_name: object, operator: object, collection: bool
) -> None:
    value = condition["value"]
    _validate_direction(field_name, operator, value)
    _validate_exact_address_operator(field_name, operator, value)
    _validate_exact_domain_operator(field_name, operator, value)
    if collection and field_name in ADDRESS_FIELDS and operator not in {"exact_address", "exact_domain"}:
        raise RuleValidationError("collection address fields require exact_address or exact_domain")


def _validate_condition_options(condition: Mapping[str, Any], field_name: object) -> None:
    if "case_sensitive" in condition and not isinstance(condition["case_sensitive"], bool):
        raise RuleValidationError("case_sensitive must be boolean")
    if condition.get("target", "subject_body") not in TARGETS:
        raise RuleValidationError("condition has unsupported target")
    if not header_option_is_valid(condition, field_name):
        raise RuleValidationError("header field requires an RFC header name")


def _validate_condition(condition: Mapping[str, Any], rule_id: str, collection: bool) -> None:
    field_name, operator = _validate_condition_shape(condition, rule_id)
    _validate_condition_operator(condition, field_name, operator, collection)
    _validate_condition_options(condition, field_name)


def validate_rule(rule: Mapping[str, Any]) -> None:
    """Validate one v2 rule without interpreting provider capabilities."""
    rule_id = _validate_rule_metadata(rule)
    _validate_backfill(rule, rule_id)
    _validate_actions(rule, rule_id)
    block = match_block(rule)
    if set(block) - {"all", "any"}:
        raise RuleValidationError(f"rule '{rule_id}' match has unsupported keys")
    all_conditions = conditions(block, "all")
    any_conditions = conditions(block, "any")
    if not all_conditions and not any_conditions:
        raise RuleValidationError(f"rule '{rule_id}' requires all and/or any conditions")
    for condition in all_conditions + any_conditions:
        _validate_condition(condition, rule_id, rule.get("collection", True) is not False)
