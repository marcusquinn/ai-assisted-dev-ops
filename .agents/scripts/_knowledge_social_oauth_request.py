#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared immutable request envelope for identity-bound social pages."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from typing import Any, Callable, ClassVar

from knowledge_social_import import canonical_json, reject_credentials


@dataclass(frozen=True)
class OAuthPageResponseCodec:
    """Validate the response envelope and opaque mapping cursor for one provider."""

    display_name: str
    cursor_prefix: str
    error_type: type[Exception]
    max_cursor_bytes: int = 4096

    def encode_cursor(self, cursor: dict[str, Any]) -> str:
        reject_credentials(cursor)
        payload = canonical_json(cursor).encode("utf-8")
        if len(payload) > self.max_cursor_bytes:
            raise self.error_type(
                f"{self.display_name} checkpoint exceeds the safety limit"
            )
        encoded = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
        return f"{self.cursor_prefix}{encoded}"

    def decode_cursor(self, cursor: str) -> dict[str, Any]:
        if not cursor.startswith(self.cursor_prefix):
            raise self.error_type(
                f"stored {self.display_name} cursor has an unsupported version"
            )
        encoded = cursor.removeprefix(self.cursor_prefix)
        try:
            padding = "=" * (-len(encoded) % 4)
            parsed = json.loads(base64.urlsafe_b64decode(encoded + padding))
        except (ValueError, UnicodeError, json.JSONDecodeError) as error:
            raise self.error_type(
                f"stored {self.display_name} cursor is invalid"
            ) from error
        if not isinstance(parsed, dict):
            raise self.error_type(
                f"stored {self.display_name} cursor has an invalid shape"
            )
        reject_credentials(parsed)
        return parsed

    def response_status(self, payload: dict[str, Any]) -> int:
        status = payload.get("status", 200)
        if isinstance(status, bool) or not isinstance(status, int):
            raise self.error_type(
                f"{self.display_name} response status must be an integer"
            )
        return status

    def page_data(self, payload: dict[str, Any]) -> list[dict[str, Any]]:
        data = payload.get("data", [])
        if not isinstance(data, list) or any(
            not isinstance(item, dict) for item in data
        ):
            raise self.error_type(f"{self.display_name} page data must be an array")
        return data


@dataclass(frozen=True)
class OAuthPageRequest:
    """Provider-neutral request fields with a provider-specific handle key."""

    HANDLE_KEY: ClassVar[str]

    stream: str
    account_id: str
    provider_account_id: str
    handle: str
    instance_id: str
    position: int
    stop_at: str | None
    limit: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "account_id": self.account_id,
            "provider_account_id": self.provider_account_id,
            self.HANDLE_KEY: self.handle,
            "instance_id": self.instance_id,
            "position": self.position,
            "stop_at": self.stop_at,
            "limit": self.limit,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


@dataclass(frozen=True)
class OAuthRequestCodec:
    """Build and validate one provider's standard OAuth page envelope."""

    display_name: str
    cursor_prefix: str
    cursor_key: str
    handle_key: str
    max_page_size: int
    max_text_bytes: int
    streams: frozenset[str]
    request_type: type[OAuthPageRequest]
    error_type: type[Exception]
    account_validator: Callable[[Any], str]
    handle_validator: Callable[[Any], str]
    instance_validator: Callable[[Any], str]

    @property
    def request_keys(self) -> frozenset[str]:
        return frozenset(
            {
                "action",
                "stream",
                "account_id",
                "provider_account_id",
                self.handle_key,
                "instance_id",
                "position",
                "stop_at",
                "limit",
            }
        )

    def _error(self, message: str) -> Exception:
        return self.error_type(f"{self.display_name} {message}")

    def text(self, value: Any, field: str, *, optional: bool = False) -> str | None:
        if value is None:
            if optional:
                return None
            raise self._error(f"{field} is invalid")
        if not isinstance(value, str) or not value or "\x00" in value:
            raise self._error(f"{field} is invalid")
        if len(value.encode()) > self.max_text_bytes:
            raise self._error(f"{field} is invalid")
        return value

    def _position(self, value: Any) -> int:
        if isinstance(value, bool) or not isinstance(value, int):
            raise self._error("page position must be positive")
        if value < 1:
            raise self._error("page position must be positive")
        return value

    def _stream(self, value: Any) -> str:
        if not isinstance(value, str) or value not in self.streams:
            raise self._error("stream is unsupported")
        return value

    def _limit(self, value: Any) -> int:
        if isinstance(value, bool) or not isinstance(value, int):
            raise self._error("page size is invalid")
        if not 1 <= value <= self.max_page_size:
            raise self._error("page size is invalid")
        return value

    def encode_cursor(self, position: int, state: str) -> str:
        payload = canonical_json({"position": position, self.cursor_key: state}).encode()
        encoded = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
        return f"{self.cursor_prefix}{encoded}"

    def decode_cursor(self, cursor: str) -> tuple[int, str]:
        if not cursor.startswith(self.cursor_prefix):
            raise self._error("stored cursor has an unsupported version")
        try:
            raw = cursor.removeprefix(self.cursor_prefix)
            parsed = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
        except (ValueError, UnicodeError, json.JSONDecodeError) as error:
            raise self._error("stored cursor is invalid") from error
        expected = {"position", self.cursor_key}
        if not isinstance(parsed, dict) or set(parsed) != expected:
            raise self._error("stored cursor has an invalid shape")
        reject_credentials(parsed)
        state = self.text(parsed.get(self.cursor_key), "stored cursor")
        if state is None:
            raise self._error("stored cursor is invalid")
        return self._position(parsed.get("position")), state

    def collection_request(
        self,
        stream: str,
        account: dict[str, Any],
        cursor: str | None,
        limit: int,
    ) -> OAuthPageRequest:
        checked_stream = self._stream(stream)
        position, state = self.decode_cursor(cursor) if cursor else (1, None)
        selected = self.text(account.get("id"), "selected account ID")
        if selected is None:
            raise self._error("verified identity is incomplete")
        return self.request_type(
            checked_stream,
            selected,
            self.account_validator(account.get("provider_account_id")),
            self.handle_validator(account.get(self.handle_key)),
            self.instance_validator(account.get("instance_id")),
            position,
            state,
            self._limit(limit),
        )

    def provider_request(self, payload: dict[str, Any]) -> OAuthPageRequest:
        if set(payload) != self.request_keys:
            raise self._error("read request has an invalid action shape")
        if payload.get("action") != "page":
            raise self._error("read request has an invalid action shape")
        selected = self.text(payload.get("account_id"), "selected account ID")
        if selected is None:
            raise self._error("selected account ID is required")
        return self.request_type(
            self._stream(payload.get("stream")),
            selected,
            self.account_validator(payload.get("provider_account_id")),
            self.handle_validator(payload.get(self.handle_key)),
            self.instance_validator(payload.get("instance_id")),
            self._position(payload.get("position")),
            self.text(payload.get("stop_at"), "cursor state", optional=True),
            self._limit(payload.get("limit")),
        )
