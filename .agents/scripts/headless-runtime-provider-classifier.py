#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

"""Classify trusted provider failures from one OpenCode output file."""

import json
import re
import sys
from pathlib import Path

RUNTIME_LINE = re.compile(r"\[(worker_exit_diagnostics|provider_error|runtime_error)\]", re.I)
AUTH_RUNTIME_LINE = re.compile(r"\b(token refresh failed|invalid_grant|invalid refresh token)\b", re.I)
PROVIDER_RUNTIME_LINE = re.compile(
    r"^(?:(?:openai|anthropic|claude) (?:provider )?(?:error|authentication failed)|provider returned http \d{3}:)",
    re.I,
)
PROVIDER_STATUS_LINE = re.compile(
    r"^(?:openai|anthropic|claude)\s+(?:http\s+)?(?:429|5\d\d)\b.*(?:rate limit|service unavailable|server error|overloaded)",
    re.I,
)
OPENCODE_ERROR_LOG = re.compile(r"^timestamp=.*\blevel=error\b.*\bproviderid=", re.I)
GATEWAY_DISPLAY = re.compile(r"^forbidden: request was blocked by a gateway or proxy\.?", re.I)


def structured_api_error(obj):
    error = obj.get("error")
    if obj.get("type") != "error" or not isinstance(error, dict):
        return None
    error_name = error.get("name") or error.get("type")
    data = error.get("data") if isinstance(error.get("data"), dict) else {}
    status = data.get("statusCode")
    if error_name != "APIError" or not isinstance(status, int) or isinstance(status, bool):
        return None
    body = data.get("responseBody")
    body_kind = "unavailable"
    if isinstance(body, str):
        stripped = body.lstrip().lower()
        body_kind = "html" if stripped.startswith(("<!doctype", "<html")) else "other"
    return {
        "status": status,
        "message": data.get("message", "") if isinstance(data.get("message"), str) else "",
        "body": body if isinstance(body, str) else "",
        "body_kind": body_kind,
    }


def trusted_plaintext(line):
    return any(pattern.search(line) for pattern in (
        RUNTIME_LINE,
        AUTH_RUNTIME_LINE,
        PROVIDER_RUNTIME_LINE,
        PROVIDER_STATUS_LINE,
        OPENCODE_ERROR_LOG,
        GATEWAY_DISPLAY,
    ))


def trusted_legacy_record(obj):
    has_provider = bool(obj.get("provider") or obj.get("provider_error_type") or obj.get("provider_status"))
    has_error = any(key in obj for key in ("error", "status", "provider_error_type", "provider_status"))
    return has_provider and has_error


def collect(path):
    trusted_chunks = []
    structured_errors = []
    for raw_line in path.read_text(errors="ignore").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("{"):
            try:
                obj = json.loads(line)
            except Exception:
                obj = None
            if isinstance(obj, dict):
                structured = structured_api_error(obj)
                if structured:
                    structured_errors.append(structured)
                    continue
                if trusted_legacy_record(obj):
                    trusted_chunks.append(line)
            continue
        if trusted_plaintext(line):
            trusted_chunks.append(line)
    return trusted_chunks, structured_errors


def emit(reason, provider_type, status, pattern):
    print("\t".join([reason, provider_type, status, "trusted_provider", pattern]))


def classify_structured(record):
    status = record["status"]
    details = f"{record['message']}\n{record['body']}".lower()
    if status == 403:
        if record["body_kind"] == "html" or any(token in details for token in ("gateway", "proxy")):
            return "provider_error", "gateway_denied", "403", "structured_api_error|html_403"
        return "access_denied", "access_denied", "403", "structured_api_error|403"
    if status == 401:
        return "auth_error", "auth_error", "401", "structured_api_error|401"
    if status == 429:
        quota_tokens = (
            "insufficient_quota", "insufficient quota", "quota_exceeded", "quota exceeded",
            "credit_exhausted", "credit exhausted", "exhausted your credit",
        )
        if any(token in details for token in quota_tokens):
            return "quota_exceeded", "quota_exceeded", "429", "structured_api_error|quota"
        return "rate_limit", "rate_limit", "429", "structured_api_error|429"
    if 500 <= status <= 599:
        return "provider_error", "server_error", str(status), "structured_api_error|5xx"
    return "provider_error", "api_error", str(status), "structured_api_error|http_status"


def classify_plaintext(text):
    quota = (
        "insufficient_quota", "insufficient quota", "quota_exceeded", "quota exceeded",
        "exceeded your current quota", "credit_exhausted", "credit exhausted", "exhausted your credit",
    )
    if any(token in text for token in quota):
        return "quota_exceeded", "quota_exceeded", "429", "trusted_quota|insufficient_quota|quota_exceeded|credit_exhausted"
    if any(token in text for token in ("rate limit", "rate_limit", "too many requests")) or re.search(r"\b429\b", text):
        return "rate_limit", "rate_limit", "429", "trusted_rate_limit|429|too_many_requests"
    if any(token in text for token in ("blocked by a gateway or proxy", "html gateway response")):
        return "provider_error", "gateway_denied", "403", "trusted_gateway_denied|html_403"
    if re.search(r"\b403\b", text) or any(token in text for token in ("forbidden", "access_denied", "access denied")):
        return "access_denied", "access_denied", "403", "trusted_access_denied|403|forbidden"
    server = re.search(r"\b(500|502|503|504)\b", text)
    if server or any(token in text for token in ("server_error", "internal server error", "service unavailable", "bad gateway", "gateway timeout", "connection refused", "connection reset", "overloaded")):
        status = "500"
        if "504" in text or "gateway timeout" in text:
            status = "504"
        elif "503" in text or "service unavailable" in text:
            status = "503"
        elif "502" in text or "bad gateway" in text:
            status = "502"
        return "provider_error", "server_error", status, "trusted_server_error|5xx|connection_failure|overloaded"
    auth = ("unauthorized", "invalid api key", "authentication failed", "token refresh failed", "invalid_grant", "invalid refresh token")
    if re.search(r"\b401\b", text) or any(token in text for token in auth) or ("auth" in text and "failed" in text):
        return "auth_error", "auth_error", "401", "trusted_auth_error|401|token_refresh|invalid_grant"
    return None


def main(argv):
    if len(argv) != 2:
        return 2
    trusted_chunks, structured_errors = collect(Path(argv[1]))
    result = classify_structured(structured_errors[-1]) if structured_errors else classify_plaintext("\n".join(trusted_chunks).lower())
    if result:
        emit(*result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
