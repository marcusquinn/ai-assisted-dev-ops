#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
PostToolUse hook for Claude Code: transcript-side credential scrub (GH#20207).

Fires after every tool call. Scrubs known credential token prefixes and values
under sensitive field names before results reach the model or transcript.

This is Layer 4 of t2458 credential sanitization:
  Layers 1-3 prevent framework helpers from emitting credentials.
  Layer 4 (this hook) catches credentials that reach the tool-result channel
  from other sources: user scripts, third-party CLIs, error backtraces.

Token prefix families scrubbed (mirrors shared-constants.sh scrub_credentials):
  sk-       OpenAI / Anthropic API keys
  GOCSPX-   Google OAuth client secrets
  ghp_      GitHub personal access tokens
  gho_      GitHub OAuth tokens
  ghs_      GitHub server-to-server tokens
  ghu_      GitHub user-to-server tokens
  github_pat_  GitHub fine-grained PATs
  glpat-    GitLab personal access tokens
  xoxb-     Slack bot tokens
  xoxp-     Slack user tokens

Unknown token formats are also scrubbed under unambiguous API key, token,
secret, and password field names.

Exit behavior:
  - Exit 0 always — this hook MUST NOT block tool execution, only sanitize.
  - Emits a JSON object to stdout with the scrubbed tool_response when a
    credential is detected. Claude Code reads this to replace the tool result.
  - Emits nothing (empty stdout) when no credential is found — allowing the
    original result through unchanged.

Input: JSON on stdin with Claude Code hook payload.
Output: JSON on stdout with sanitized result (only when scrubbing occurs).

Installed by: install-hooks-helper.sh
Location: ~/.aidevops/hooks/credential-transcript-scrub.py
Configured in: ~/.claude/settings.json (hooks.PostToolUse)

Performance target: <5ms per 10KB tool result.
"""
import json
import re
import sys
import time

# Regex mirrors shared-constants.sh scrub_credentials sed pattern exactly.
# Group 1: token prefix family (one of the 10 families).
# Suffix: 10+ alphanumeric / dash / underscore chars (token body).
#
# Word-boundary anchor `(?:^|(?<=[^A-Za-z0-9_-]))` prevents false positives
# where a credential prefix appears mid-word — e.g. `task-failure-handler`
# contains the literal `sk-failure-handler` (16 chars, matches the body) but
# is NOT a credential. Without this anchor the regex corrupts identifiers
# into `ta[redacted-credential]` and similar (see GH#21026 / t2892 for the
# canonical incident on example-repo/develop).
CREDENTIAL_PATTERN = re.compile(
    r"(?:^|(?<=[^A-Za-z0-9_-]))(sk-|GOCSPX-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}",
    re.ASCII,
)

NAMED_CREDENTIAL_ASSIGNMENT_PATTERN = re.compile(
    r"(^|[^A-Za-z0-9_])((?:\"[A-Za-z_][A-Za-z0-9_. -]*\"|'[A-Za-z_][A-Za-z0-9_. -]*'|(?:API[ \t]+KEY|PRIVATE[ \t]+KEY|SECRET[ \t]+KEY|ACCESS[ \t]+TOKEN|AUTH[ \t]+TOKEN|CLIENT[ \t]+SECRET|USER[ \t]+PASSWORD)|[A-Za-z_][A-Za-z0-9_.-]*))(\s*(?:=|:)\s*)(\"(?:\\.|[^\"\\])*\"[^\r\n\s,}\])&;|<>]*|'(?:\\.|[^'\\])*'[^\r\n\s,}\])&;|<>]*|\[[^\r\n\s,};&|<>]*\][^\r\n\s,}\])&;|<>]*|<[^>\r\n]*>[^\r\n\s,}\])&;|<>]*|\([^()\r\n]*\)[^\r\n\s,}\])&;|<>]*|not[ \t]+set(?=$|[\s,}\])&;|<>])|[^\s,}\])&;|<>]+)",
    re.IGNORECASE | re.MULTILINE,
)

REDACTION_TOKEN = "[redacted-credential]"
PEM_REDACTION_TOKEN = "[redacted-private-key]"
PEM_BEGIN_MARKER = "-----BEGIN "
PEM_KEY_SUFFIX = "PRIVATE KEY-----"
PEM_LABEL_PATTERN = re.compile(r"^[A-Z0-9 ]*$")
PLACEHOLDER_VALUES = {
    "",
    "***",
    "[redacted]",
    "[redacted-credential]",
    "[redacted-private-key]",
    "(not set)",
    "<redacted>",
    "missing",
    "none",
    "not set",
    "null",
    "undefined",
}


def unquote(value: str) -> str:
    """Trim matching quotes from a field name or assignment value."""
    trimmed = str(value).strip()
    if len(trimmed) >= 2 and trimmed[0] in {'"', "'"} and trimmed[-1] == trimmed[0]:
        return trimmed[1:-1]
    return trimmed


def normalize_field_name(name: str) -> str:
    """Normalize snake, kebab, dotted, and camel-case field names."""
    normalized = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", unquote(name))
    return re.sub(r"[-.\s]+", "_", normalized).upper()


def is_sensitive_field_name(name: str) -> bool:
    """Return whether a field name is unambiguously credential-bearing."""
    pattern = (
        r"(?:^|_)(?:API_?KEY|PRIVATE_KEY|SECRET_KEY|ACCESS_KEY|ACCESS_KEY_ID|"
        r"ENCRYPTION_KEY|SIGNING_KEY|TOKEN|SECRET|PASSWORD|PASSWD)$"
    )
    return bool(re.search(pattern, normalize_field_name(name)))


def is_placeholder_value(value: str) -> bool:
    """Keep empty and already-redacted values unchanged."""
    return unquote(value).lower() in PLACEHOLDER_VALUES


def preserves_sensitive_value(value) -> bool:
    """Keep absence and explicit string placeholders under sensitive keys."""
    return value is None or (isinstance(value, str) and is_placeholder_value(value))


def redact_named_assignment(match: re.Match) -> str:
    """Redact one sensitive assignment while preserving its key and quoting."""
    boundary, name, separator, value = match.groups()
    if not is_sensitive_field_name(name) or is_placeholder_value(value):
        return match.group(0)
    quote = value[0] if value and value[0] in {'"', "'"} and value.endswith(value[0]) else ""
    if quote:
        redacted = f"{quote}{REDACTION_TOKEN}{quote}"
    elif value.startswith("(") and value.endswith(")"):
        redacted = f"({REDACTION_TOKEN})"
    else:
        redacted = REDACTION_TOKEN
    return f"{boundary}{name}{separator}{redacted}"


def scrub_private_keys(text: str) -> tuple[str, int]:
    """Replace complete PEM private-key blocks using a linear marker scan."""
    chunks = []
    cursor = 0
    count = 0
    while cursor < len(text):
        start = text.find(PEM_BEGIN_MARKER, cursor)
        if start < 0:
            break
        label_start = start + len(PEM_BEGIN_MARKER)
        suffix_start = text.find(PEM_KEY_SUFFIX, label_start)
        if suffix_start < 0:
            break
        label = text[label_start:suffix_start]
        header_end = suffix_start + len(PEM_KEY_SUFFIX)
        if not PEM_LABEL_PATTERN.fullmatch(label):
            chunks.append(text[cursor:label_start])
            cursor = label_start
            continue
        end_marker = f"-----END {label}{PEM_KEY_SUFFIX}"
        next_start = text.find(PEM_BEGIN_MARKER, header_end)
        segment_end = len(text) if next_start < 0 else next_start
        end = text.find(end_marker, header_end, segment_end)
        if end < 0:
            chunks.append(text[cursor:header_end])
            cursor = header_end
            continue
        chunks.extend((text[cursor:start], PEM_REDACTION_TOKEN))
        cursor = end + len(end_marker)
        count += 1
    chunks.append(text[cursor:])
    return "".join(chunks), count


def scrub_credentials(text: str) -> tuple[str, int]:
    """Replace credential tokens in text. Returns (scrubbed_text, match_count)."""
    named_count = 0

    def redact_and_count(match: re.Match) -> str:
        nonlocal named_count
        redacted = redact_named_assignment(match)
        if redacted != match.group(0):
            named_count += 1
        return redacted

    result, pem_count = scrub_private_keys(text)
    result = NAMED_CREDENTIAL_ASSIGNMENT_PATTERN.sub(redact_and_count, result)
    result, token_count = CREDENTIAL_PATTERN.subn(REDACTION_TOKEN, result)
    return result, pem_count + named_count + token_count


def scrub_value(value):
    """Recursively scrub credentials from any JSON-serialisable value."""
    if isinstance(value, str):
        return scrub_credentials(value)[0]
    if isinstance(value, dict):
        scrubbed = {}
        for key, nested in value.items():
            if is_sensitive_field_name(key) and not preserves_sensitive_value(nested):
                scrubbed[key] = REDACTION_TOKEN
            else:
                scrubbed[key] = scrub_value(nested)
        return scrubbed
    if isinstance(value, list):
        return [scrub_value(item) for item in value]
    return value


def main() -> None:
    start_ns = time.monotonic_ns()

    try:
        raw = sys.stdin.read()
        data = json.loads(raw)
    except (json.JSONDecodeError, EOFError, ValueError):
        # Malformed input — allow through, never block.
        return

    tool_response = data.get("tool_response", "")

    # Fast path: no known prefix, private key, or named assignment in the payload.
    if (
        not CREDENTIAL_PATTERN.search(raw)
        and PEM_BEGIN_MARKER not in raw
        and not NAMED_CREDENTIAL_ASSIGNMENT_PATTERN.search(raw)
    ):
        return

    # Scrub the tool_response field (may be str or nested JSON object).
    if isinstance(tool_response, str):
        scrubbed, count = scrub_credentials(tool_response)
        if count == 0:
            return
    elif isinstance(tool_response, (dict, list)):
        scrubbed = scrub_value(tool_response)
        # Re-serialise to detect if anything actually changed.
        original_json = json.dumps(tool_response, ensure_ascii=False)
        scrubbed_json = json.dumps(scrubbed, ensure_ascii=False)
        if original_json == scrubbed_json:
            return
    else:
        return

    elapsed_ms = (time.monotonic_ns() - start_ns) / 1_000_000
    # Emit replacement payload to Claude Code.
    out = {
        "tool_response": scrubbed,
        "redacted_credential": True,
        "scrub_elapsed_ms": round(elapsed_ms, 2),
    }
    print(json.dumps(out))


if __name__ == "__main__":
    main()
