#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
PostToolUse hook for Claude Code: transcript-side credential scrub (GH#20207).

Fires after every tool call. Scrubs known credential token prefixes from the
tool result before it reaches the model or is persisted to disk.

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

PEM_PRIVATE_KEY_PATTERN = re.compile(
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
    re.DOTALL,
)

REDACTION_TOKEN = "[redacted-credential]"
PEM_REDACTION_TOKEN = "[redacted-private-key]"


def scrub_credentials(text: str) -> tuple[str, int]:
    """Replace credential tokens in text. Returns (scrubbed_text, match_count)."""
    result, pem_count = PEM_PRIVATE_KEY_PATTERN.subn(PEM_REDACTION_TOKEN, text)
    result, token_count = CREDENTIAL_PATTERN.subn(REDACTION_TOKEN, result)
    return result, pem_count + token_count


def scrub_value(value):
    """Recursively scrub credentials from any JSON-serialisable value."""
    if isinstance(value, str):
        return scrub_credentials(value)[0]
    if isinstance(value, dict):
        return {k: scrub_value(v) for k, v in value.items()}
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

    # Fast path: no credential/private-key pattern anywhere in the raw payload.
    if not CREDENTIAL_PATTERN.search(raw) and not PEM_PRIVATE_KEY_PATTERN.search(raw):
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
