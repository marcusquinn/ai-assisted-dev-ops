#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded GET-only OAuth subprocess for Meta product reads."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from _knowledge_social_meta import (
    PRODUCTS,
    MetaAdapterError,
    account_id,
    graph_id,
    product_spec,
    provider_cursor,
)
from _knowledge_social_meta_contract import (
    ApiResult,
    MetaReadProviderError,
    decode_response,
    exact_keys,
    identity_payload,
    page_payload,
)

MAX_REQUEST_BYTES = 32 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
HTTP_TIMEOUT_SECONDS = 60
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
UrlOpen = Callable[..., Any]
PageValues = tuple[str, str, str, str | None, int]
READ_EDGES = {
    product: frozenset(stream.edge for stream in spec.streams.values())
    for product, spec in PRODUCTS.items()
}


def _profile_prefix(profile: str, product: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise MetaReadProviderError("Meta OAuth profile name is invalid")
    if product not in PRODUCTS:
        raise MetaReadProviderError("Meta product is unsupported")
    return f"META_{profile.upper()}_{product.upper()}"


def _access_token(profile: str, product: str) -> str:
    token = os.environ.get(f"{_profile_prefix(profile, product)}_ACCESS_TOKEN", "")
    if not token or "\x00" in token or len(token.encode("utf-8")) > 16 * 1024:
        raise MetaReadProviderError("Meta OAuth profile access token is missing")
    return token


def _http_exports() -> UrlOpen:
    if not callable(Request) or not callable(urlopen) or not callable(urlencode):
        raise MetaReadProviderError("Python urllib HTTP exports are unavailable")
    return urlopen


def _request() -> dict[str, Any]:
    payload = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if len(payload) > MAX_REQUEST_BYTES:
        raise MetaReadProviderError("Meta read request exceeds the safety limit")
    try:
        request = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise MetaReadProviderError("Meta read request is not valid JSON") from error
    if not isinstance(request, dict):
        raise MetaReadProviderError("Meta read request root must be an object")
    return request


def _retry_epoch(error: HTTPError) -> int | None:
    value = error.headers.get("Retry-After") if error.headers else None
    if not isinstance(value, str) or not value.isascii() or not value.isdigit():
        return None
    seconds = int(value)
    if seconds < 0 or seconds > 86400:
        return None
    return int(time.time()) + seconds


def _api(
    token: str,
    opener: UrlOpen,
    api_base: str,
    path: str,
    params: dict[str, str],
) -> ApiResult:
    url = f"{api_base}/{path}?{urlencode(params)}"
    request = Request(
        url,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "aidevops-meta-knowledge/1",
        },
        method="GET",
    )
    try:
        with opener(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise MetaReadProviderError("Meta HTTP status is invalid")
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes) or len(payload) > MAX_RESPONSE_BYTES:
                raise MetaReadProviderError("Meta HTTP response exceeds the safety limit")
            return ApiResult(status, decode_response(payload))
    except HTTPError as error:
        status = error.code
        if isinstance(status, bool) or not isinstance(status, int) or not 400 <= status <= 599:
            raise MetaReadProviderError("Meta HTTP status is invalid") from error
        return ApiResult(status, {}, _retry_epoch(error))
    except (TimeoutError, URLError, OSError) as error:
        raise MetaReadProviderError("Meta read provider request failed") from error


def _identity(
    api: Callable[[str, dict[str, str]], ApiResult],
    product: str,
    expected_id: str,
) -> dict[str, Any]:
    spec = product_spec(product)
    path = expected_id if spec.identity_path == "account" else "me"
    result = api(path, {"fields": ",".join(spec.identity_fields)})
    return identity_payload(result, spec, expected_id)


def _page_request(
    request: dict[str, Any],
) -> PageValues:
    exact_keys(
        request,
        {"action", "product", "stream", "account_id", "edge", "fields", "after", "limit"},
    )
    product = request.get("product")
    spec = product_spec(product)
    stream = request.get("stream")
    if not isinstance(stream, str) or stream not in spec.streams:
        raise MetaReadProviderError("Meta read stream is unsupported")
    stream_spec = spec.streams[stream]
    if request.get("edge") != stream_spec.edge:
        raise MetaReadProviderError("Meta read edge is not allowlisted")
    if request.get("fields") != ",".join(stream_spec.fields):
        raise MetaReadProviderError("Meta read fields are not allowlisted")
    try:
        selected_account_id = account_id(request.get("account_id"), "account ID")
    except Exception as error:
        raise MetaReadProviderError("Meta account ID is invalid") from error
    after = request.get("after")
    if after is not None:
        try:
            after = provider_cursor(after)
        except Exception as error:
            raise MetaReadProviderError("Meta page cursor is invalid") from error
    limit = request.get("limit")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 50:
        raise MetaReadProviderError("Meta read limit must be between 1 and 50")
    return product, stream, selected_account_id, after, limit


def _page(
    api: Callable[[str, dict[str, str]], ApiResult],
    values: PageValues,
) -> dict[str, Any]:
    product, stream, account_id, after, limit = values
    spec = product_spec(product)
    stream_spec = spec.streams[stream]
    identity = _identity(api, product, account_id)
    if identity.get("status") != 200:
        return identity
    leaf = account_id if spec.identity_path == "account" else "me"
    params = {"fields": ",".join(stream_spec.fields), "limit": str(limit)}
    if after is not None:
        params["after"] = after
    result = api(f"{leaf}/{stream_spec.edge}", params)
    return page_payload(result, spec, stream, account_id, limit)


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise MetaReadProviderError("Meta read response exceeds the safety limit")
    print(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        raw_request = _request()
        action = raw_request.get("action")
        if action not in ("identity", "page"):
            raise MetaReadProviderError("Meta read action is unsupported")
        product = raw_request.get("product")
        if not isinstance(product, str) or product not in PRODUCTS:
            raise MetaReadProviderError("Meta product is unsupported")
        token = _access_token(args.profile, product)
        opener = _http_exports()
        spec = product_spec(product)
        api = lambda path, params: _api(token, opener, spec.api_base, path, params)
        if action == "identity":
            exact_keys(raw_request, {"action", "product", "account_id"})
            selected_account_id = account_id(
                raw_request.get("account_id"), "account ID"
            )
            payload = _identity(api, product, selected_account_id)
        else:
            values = _page_request(raw_request)
            payload = _page(api, values)
        _emit(payload)
        return 0
    except (MetaReadProviderError, MetaAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: Meta read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
