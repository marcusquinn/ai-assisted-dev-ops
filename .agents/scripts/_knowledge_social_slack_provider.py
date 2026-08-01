#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded read-only Slack Web API subprocess with exact method allowlisting."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from functools import partial
from typing import Any

from _knowledge_social_slack import (
    ALIAS,
    CONVERSATION_KINDS,
    PageRequest,
    SlackAdapterError,
    conversation_binding_sha256,
    conversation_id,
    parse_page_request,
    team_id,
    token_type,
)
from _knowledge_social_slack_contract import (
    ApiResult,
    IdentityBinding,
    SlackAuthorizationError,
    SlackReadProviderError,
    exact_keys,
    identity_value,
    object_value,
    observed_at,
    request_object,
    terminal_payload,
)
from _knowledge_social_slack_evidence_guard import reject_slack_credentials
from _knowledge_social_slack_http import MAX_RESPONSE_BYTES, Opener, _http_exports, api
from _knowledge_social_slack_routes import ConversationTarget, page

MAX_REQUEST_BYTES = 32 * 1024
MAX_CONVERSATION_CONFIG_BYTES = 64 * 1024
MAX_CONVERSATIONS = 500
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")


@dataclass(frozen=True)
class ProfileConfig:
    """Validated non-secret binding plus one isolated live credential."""

    token: str | None
    binding: IdentityBinding
    conversations: dict[str, ConversationTarget]
    conversation_binding_sha256: str


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise SlackReadProviderError("Slack profile name is invalid")
    return f"SLACK_{profile.upper()}"


def _required_profile_value(prefix: str, suffix: str, field: str, limit: int) -> str:
    value = os.environ.get(f"{prefix}_{suffix}", "")
    if not value or "\x00" in value or len(value.encode("utf-8")) > limit:
        raise SlackReadProviderError(f"Slack profile {field} is missing")
    return value


def _optional_profile_value(prefix: str, suffix: str, field: str, limit: int) -> str | None:
    value = os.environ.get(f"{prefix}_{suffix}")
    if value in (None, ""):
        return None
    if "\x00" in value or len(value.encode("utf-8")) > limit:
        raise SlackReadProviderError(f"Slack profile {field} is invalid")
    return value


def _conversation_target(alias: Any, value: Any) -> ConversationTarget:
    if not isinstance(alias, str) or ALIAS.fullmatch(alias) is None:
        raise SlackReadProviderError("Slack conversation alias is invalid")
    if not isinstance(value, dict) or set(value) != {"id", "kind"}:
        raise SlackReadProviderError("Slack conversation allowlist entry is invalid")
    native_id = conversation_id(value.get("id"))
    kind = value.get("kind")
    if kind not in CONVERSATION_KINDS:
        raise SlackReadProviderError("Slack conversation kind is unsupported")
    prefixes = {
        "public_channel": "C",
        "private_channel": "G",
        "im": "D",
        "mpim": "G",
    }
    if not native_id.startswith(prefixes[str(kind)]):
        raise SlackReadProviderError("Slack conversation ID and kind conflict")
    return ConversationTarget(alias, native_id, str(kind))


def _conversations(prefix: str) -> dict[str, ConversationTarget]:
    raw = _required_profile_value(
        prefix,
        "CONVERSATIONS",
        "conversation allowlist",
        MAX_CONVERSATION_CONFIG_BYTES,
    )
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as error:
        raise SlackReadProviderError(
            "Slack profile conversation allowlist is invalid"
        ) from error
    if not isinstance(parsed, dict) or len(parsed) > MAX_CONVERSATIONS:
        raise SlackReadProviderError("Slack profile conversation allowlist is invalid")
    targets = {
        str(alias): _conversation_target(alias, value)
        for alias, value in parsed.items()
    }
    if len({target.conversation_id for target in targets.values()}) != len(targets):
        raise SlackReadProviderError("Slack conversation allowlist contains duplicate IDs")
    return targets


def load_profile(
    profile: str, *, require_token: bool = True, include_token: bool = True
) -> ProfileConfig:
    """Load one exact workspace binding for API or approved-export collection."""
    prefix = _profile_prefix(profile)
    token = (
        _optional_profile_value(prefix, "ACCESS_TOKEN", "access token", 16 * 1024)
        if include_token
        else None
    )
    if require_token and token is None:
        raise SlackReadProviderError("Slack profile access token is missing")
    workspace = team_id(
        _required_profile_value(prefix, "WORKSPACE_ID", "workspace ID", 64)
    )
    enterprise_value = _optional_profile_value(
        prefix, "ENTERPRISE_ID", "enterprise ID", 64
    )
    from _knowledge_social_slack import enterprise_id

    enterprise = enterprise_id(enterprise_value)
    profile_token_type = token_type(
        _required_profile_value(prefix, "TOKEN_TYPE", "token type", 16)
    )
    conversations = _conversations(prefix)
    binding_value = {
        alias: {"id": target.conversation_id, "kind": target.kind}
        for alias, target in conversations.items()
    }
    return ProfileConfig(
        token,
        IdentityBinding(workspace, enterprise, profile_token_type),
        conversations,
        conversation_binding_sha256(binding_value),
    )


def _identity(
    config: ProfileConfig, opener: Opener, expected_id: str
) -> dict[str, Any]:
    if config.token is None:
        raise SlackReadProviderError("Slack profile access token is missing")
    result = api(config.token, opener, "auth.test", {})
    if result.status != 200:
        return terminal_payload(result)
    identity = identity_value(
        result.payload, expected_id, config.binding, result.scopes
    )
    identity["conversation_binding_sha256"] = config.conversation_binding_sha256
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": identity,
    }


def _verify_page_identity(
    request: PageRequest, identity: dict[str, Any], config: ProfileConfig
) -> None:
    observed = (
        identity.get("id"),
        identity.get("provider_account_id"),
        identity.get("workspace_id"),
        identity.get("enterprise_id"),
        request.workspace_id,
        request.enterprise_id,
        identity.get("token_type"),
    )
    expected = (
        request.account_id,
        request.provider_account_id,
        request.workspace_id,
        request.enterprise_id,
        config.binding.workspace_id,
        config.binding.enterprise_id,
        config.binding.token_type,
    )
    if observed != expected:
        raise SlackReadProviderError(
            "selected Slack workspace or account does not match the configured connection"
        )


def _dispatch(
    request: dict[str, Any], config: ProfileConfig, opener: Opener
) -> dict[str, Any]:
    action = request.get("action")
    if action == "identity":
        exact_keys(request, {"action", "account_id"})
        expected_id = request.get("account_id")
        if not isinstance(expected_id, str):
            raise SlackReadProviderError("Slack account ID is invalid")
        return _identity(config, opener, expected_id)
    if action != "page":
        raise SlackReadProviderError("Slack read action is unsupported")
    page_request = parse_page_request(request)
    identity_payload = _identity(config, opener, page_request.account_id)
    if identity_payload.get("status") != 200:
        return identity_payload
    identity = object_value(identity_payload.get("data"), "account verification")
    _verify_page_identity(page_request, identity, config)
    if config.token is None:
        raise SlackReadProviderError("Slack profile access token is missing")
    caller = partial(api, config.token, opener)
    try:
        result = page(caller, page_request, identity, config.conversations)
    except SlackAuthorizationError:
        return terminal_payload(ApiResult(403, {}, frozenset()))
    return terminal_payload(result) if isinstance(result, ApiResult) else result


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise SlackReadProviderError("Slack read response exceeds the safety limit")
    print(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        config = load_profile(args.profile)
        request = request_object(
            sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1), MAX_REQUEST_BYTES
        )
        response = _dispatch(request, config, _http_exports())
        reject_slack_credentials(response, exact_secret=config.token)
        _emit(response)
        return 0
    except (SlackReadProviderError, SlackAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: Slack read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
