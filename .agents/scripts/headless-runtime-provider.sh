#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Headless Runtime Provider — Auth & Backoff Functions (GH#19699)
# =============================================================================
# Provider authentication, signature computation, and backoff management
# extracted from headless-runtime-lib.sh to reduce file size.
#
# Covers two functional areas:
#   1. Provider Auth  — extract provider from model ID, compute auth signatures,
#                       check provider auth availability
#   2. Backoff        — parse retry-after headers, record/check/clear provider
#                       backoff state, attempt pool recovery
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-provider.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning, timeout_sec)
#   - headless-runtime-lib.sh Section 1 functions (db_query, sql_escape, trim_spaces)
#   - Constants from headless-runtime-helper.sh (OPENCODE_AUTH_FILE, OPENCODE_BIN_DEFAULT,
#     OAUTH_POOL_HELPER, DEFAULT_HEADLESS_MODELS)
#   - bash 3.2+, python3
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_PROVIDER_LOADED:-}" ]] && return 0
readonly _HEADLESS_RUNTIME_PROVIDER_LOADED=1

# --- Provider Auth ---

extract_provider() {
	local model="$1"
	if [[ "$model" == */* ]]; then
		printf '%s' "${model%%/*}"
		return 0
	fi
	return 1
}

provider_signature_override_var() {
	local provider="$1"
	case "$provider" in
	anthropic) printf '%s' "AIDEVOPS_HEADLESS_AUTH_SIGNATURE_ANTHROPIC" ;;
	openai) printf '%s' "AIDEVOPS_HEADLESS_AUTH_SIGNATURE_OPENAI" ;;
	*) printf '%s' "" ;;
	esac
	return 0
}

sha256_text() {
	local value="$1"
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$value" | shasum -a 256 | awk '{print $1}'
		return 0
	fi
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$value" | sha256sum | awk '{print $1}'
		return 0
	fi
	print_error "sha256_text requires 'shasum' or 'sha256sum'"
	return 1
}

file_mtime() {
	local path="$1"
	if [[ ! -e "$path" ]]; then
		printf '%s' "missing"
		return 0
	fi
	local mtime
	mtime=$(_file_mtime_epoch "$path")
	if [[ "$mtime" -eq 0 ]]; then
		printf '%s' "unknown"
	else
		printf '%s' "$mtime"
	fi
	return 0
}

get_auth_signature() {
	local provider="$1"
	local override_var
	override_var=$(provider_signature_override_var "$provider")
	if [[ -n "$override_var" && -n "${!override_var:-}" ]]; then
		printf '%s' "${!override_var}"
		return 0
	fi

	local auth_material="provider=${provider}"
	case "$provider" in
	anthropic)
		local auth_status auth_mtime
		auth_status=$(timeout_sec 10 "$OPENCODE_BIN_DEFAULT" auth status 2>/dev/null || true)
		auth_mtime=$(file_mtime "$OPENCODE_AUTH_FILE")
		auth_material="${auth_material}|status=${auth_status}|mtime=${auth_mtime}"
		;;
	openai)
		if [[ -n "${OPENAI_API_KEY:-}" ]]; then
			auth_material="${auth_material}|env=$(sha256_text "$OPENAI_API_KEY")"
		else
			# OpenAI can also be authenticated via OpenCode OAuth (no direct API key needed).
			# Include the OAuth auth status in the signature so backoff clears on re-auth.
			local auth_status auth_mtime
			auth_status=$(timeout_sec 10 "$OPENCODE_BIN_DEFAULT" auth status 2>/dev/null || true)
			auth_mtime=$(file_mtime "$OPENCODE_AUTH_FILE")
			auth_material="${auth_material}|status=${auth_status}|mtime=${auth_mtime}|env=missing"
		fi
		;;
	opencode)
		# Gateway models use OpenCode's OAuth session
		local auth_mtime
		auth_mtime=$(file_mtime "$OPENCODE_AUTH_FILE")
		auth_material="${auth_material}|mtime=${auth_mtime}"
		;;
	*)
		auth_material="${auth_material}|unknown=true"
		;;
	esac

	sha256_text "$auth_material"
	return 0
}

provider_auth_available() {
	local provider="$1"
	case "$provider" in
	anthropic)
		# Anthropic: API key env var OR OpenCode OAuth session
		if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
			return 0
		fi
		if opencode_auth_has_provider "$provider"; then
			return 0
		fi
		return 1
		;;
	openai)
		# OpenAI: API key env var OR OpenCode OAuth session (OAuth subscription includes Codex)
		if [[ -n "${OPENAI_API_KEY:-}" ]]; then
			return 0
		fi
		if opencode_auth_has_provider "$provider"; then
			return 0
		fi
		return 1
		;;
	zai-coding-plan)
		# Z.AI Coding Plan is an OpenCode-managed subscription provider.
		opencode_auth_has_provider "$provider"
		return $?
		;;
	opencode)
		# OpenCode gateway models use OpenCode's OAuth session
		if [[ -f "$OPENCODE_AUTH_FILE" ]]; then
			return 0
		fi
		return 1
		;;
	local | ollama)
		# Local/Ollama providers are always considered available (no auth needed -- local daemon)
		return 0
		;;
	*)
		# Unknown provider: assume available (don't silently drop unknown providers)
		return 0
		;;
	esac
}

provider_static_auth_available() {
	local provider="$1"
	case "$provider" in
	anthropic)
		[[ -n "${ANTHROPIC_API_KEY:-}" ]]
		return $?
		;;
	openai)
		[[ -n "${OPENAI_API_KEY:-}" && "${AIDEVOPS_OPENAI_API_KEY_SOURCE:-}" != "oauth-pool" ]]
		return $?
		;;
	*)
		return 1
		;;
	esac
}

# provider_oauth_pool_available: true when the OAuth pool has at least one
# immediately usable account for the provider. Static API keys bypass this gate;
# a missing provider pool also stays non-blocking for legacy auth-only setups.
provider_oauth_pool_available() {
	local provider="$1"
	local pool_file="${HOME}/.aidevops/oauth-pool.json"

	if provider_static_auth_available "$provider"; then
		return 0
	fi
	[[ -f "$pool_file" ]] || return 0

	POOL_FILE="$pool_file" PROVIDER="$provider" python3 <<'PY' >/dev/null 2>&1
import json
import os
import sys
import time

try:
    with open(os.environ["POOL_FILE"], encoding="utf-8") as fh:
        pool = json.load(fh)
except Exception:
    sys.exit(0)

accounts = pool.get(os.environ["PROVIDER"], [])
if not accounts:
    sys.exit(0)

now_ms = int(time.time() * 1000)
for account in accounts:
    status = account.get("status", "active")
    cooldown_until = int(account.get("cooldownUntil") or 0)
    if status in ("active", "idle") and cooldown_until <= now_ms:
        sys.exit(0)

sys.exit(1)
PY
	return $?
}

opencode_auth_has_provider() {
	local provider="$1"
	local auth_file="${OPENCODE_AUTH_FILE:-${HOME}/.local/share/opencode/auth.json}"

	[[ -f "$auth_file" ]] || return 1
	if command -v jq >/dev/null 2>&1; then
		jq -e --arg provider "$provider" '.[$provider] | type == "object" and ((.access // .refresh // .token // .apiKey // "") != "")' "$auth_file" >/dev/null 2>&1
		return $?
	fi
	python3 - "$auth_file" "$provider" <<'PY' >/dev/null 2>&1
import json
import sys

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
entry = data.get(sys.argv[2])
if isinstance(entry, dict) and any(entry.get(k) for k in ("access", "refresh", "token", "apiKey")):
    sys.exit(0)
sys.exit(1)
PY
	return $?
}

# --- Backoff Parsing/Recording ---

clear_provider_backoff() {
	local provider="$1"
	db_query "DELETE FROM provider_backoff WHERE provider = '$(sql_escape "$provider")';" >/dev/null
	return 0
}

parse_retry_after_seconds() {
	local file_path="$1"
	local provider="${2:-anthropic}"

	# t1835: Check if provider-auth.mjs already set a server-sourced cooldown
	# in oauth-pool.json. Only return a cooldown if ALL accounts for this
	# provider are rate-limited. A single exhausted account must NOT block
	# workers that can use another available account (GH#15489).
	local pool_file="${HOME}/.aidevops/oauth-pool.json"
	if [[ -f "$pool_file" ]]; then
		local remaining
		remaining=$(POOL_FILE="$pool_file" PROVIDER="$provider" python3 -c "
import json, os, time, sys
try:
    pool = json.load(open(os.environ['POOL_FILE']))
    now_ms = int(time.time() * 1000)
    accounts = pool.get(os.environ['PROVIDER'], [])
    if not accounts:
        print(0); sys.exit(0)
    # Only back off if ALL accounts are rate-limited with active cooldowns
    min_remaining = None
    for a in accounts:
        cd = a.get('cooldownUntil')
        if cd and int(cd) > now_ms and a.get('status') == 'rate-limited':
            remaining_s = max(1, (int(cd) - now_ms) // 1000)
            min_remaining = min(min_remaining, remaining_s) if min_remaining else remaining_s
        else:
            # At least one account is available -- no provider-level backoff
            print(0); sys.exit(0)
    print(min_remaining or 0)
except Exception:
    print(0)
" 2>/dev/null)
		if [[ "$remaining" -gt 0 ]]; then
			echo "$remaining"
			return 0
		fi
	fi

	# Fallback: parse worker log text for retry hints
	python3 - "$file_path" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(errors="ignore").lower()
patterns = [
    (r"retry after\s+(\d+)\s*(second|seconds|sec|secs|s)\b", 1),
    (r"retry after\s+(\d+)\s*(minute|minutes|min|mins|m)\b", 60),
    (r"retry after\s+(\d+)\s*(hour|hours|hr|hrs|h)\b", 3600),
    (r"retry after\s+(\d+)\s*(day|days|d)\b", 86400),
    (r"try again in\s+(\d+)\s*(second|seconds|sec|secs|s)\b", 1),
    (r"try again in\s+(\d+)\s*(minute|minutes|min|mins|m)\b", 60),
    (r"try again in\s+(\d+)\s*(hour|hours|hr|hrs|h)\b", 3600),
    (r"try again in\s+(\d+)\s*(day|days|d)\b", 86400),
]
for pattern, multiplier in patterns:
    match = re.search(pattern, text)
    if match:
        print(int(match.group(1)) * multiplier)
        sys.exit(0)

# t1835: Reduced from 900s -- Anthropic API rate limits clear in 10-60s.
# 900s was blocking interactive sessions for 15 minutes unnecessarily.
numeric = re.search(r"\b429\b", text)
if numeric:
    print(60)
    sys.exit(0)

print(0)
PY
	return 0
}

clamp_rate_limit_retry_seconds() {
	local reason="$1"
	local retry_seconds="$2"
	local max_seconds="${AIDEVOPS_OAUTH_POOL_MAX_RATE_LIMIT_COOLDOWN_SECONDS:-21600}"

	if [[ ! "$retry_seconds" =~ ^[0-9]+$ ]]; then
		printf '%s' "0"
		return 0
	fi
	if [[ ! "$max_seconds" =~ ^[0-9]+$ ]] || [[ "$max_seconds" -le 0 ]]; then
		max_seconds=21600
	fi
	case "$reason" in
	rate_limit | provider_error)
		if [[ "$retry_seconds" -gt "$max_seconds" ]]; then
			printf '%s' "$max_seconds"
		else
			printf '%s' "$retry_seconds"
		fi
		;;
	*)
		printf '%s' "$retry_seconds"
		;;
	esac
	return 0
}

attempt_pool_recovery() {
	local provider="$1"
	local reason="$2"
	local details_file="$3"

	# CRITICAL SAFETY GUARD: oauth-pool-helper.sh rotate OVERWRITES the shared
	# auth file (~/.local/share/opencode/auth.json) which is used by BOTH
	# interactive sessions AND headless workers. When a headless worker triggers
	# rotation, it kills the user's interactive session by swapping the token
	# out from under it. The user must then Esc+Esc, manually rotate in a
	# terminal, and type "continue" to recover.
	#
	# Fix: headless workers NEVER call pool rotation. They only record the
	# backoff so the pre-dispatch check skips the dead provider on the next
	# cycle. Token rotation is an INTERACTIVE-ONLY operation -- the user
	# decides when to switch accounts.
	#
	# The mark-failure call below is safe (only updates the pool JSON metadata,
	# does not touch auth.json). The rotate call is the dangerous one.
	case "$provider" in
	anthropic | openai | cursor | google) ;;
	*)
		return 1
		;;
	esac

	case "$reason" in
	rate_limit | auth_error) ;;
	*)
		return 1
		;;
	esac

	[[ -x "$OAUTH_POOL_HELPER" ]] || return 1

	local retry_seconds
	retry_seconds=$(parse_retry_after_seconds "$details_file" "$provider")
	if [[ "$retry_seconds" -le 0 ]]; then
		# t1835: Reduced rate_limit fallback from 900s to 60s.
		# Anthropic API rate limits clear in 10-60s; 900s was blocking
		# interactive sessions for 15 minutes unnecessarily.
		case "$reason" in
		rate_limit) retry_seconds=60 ;;
		auth_error) retry_seconds=3600 ;;
		*) retry_seconds=300 ;;
		esac
	fi
	retry_seconds=$(clamp_rate_limit_retry_seconds "$reason" "$retry_seconds")

	# Safe: mark the account as failed in pool metadata (no auth file mutation)
	"$OAUTH_POOL_HELPER" mark-failure "$provider" "$reason" "$retry_seconds" >/dev/null 2>&1 || true

	# DANGEROUS: rotate rewrites the shared auth.json -- SKIP for headless workers.
	# Only record backoff so the pre-dispatch check routes to the other provider.
	# Interactive sessions handle rotation explicitly via `oauth-pool-helper.sh rotate`.
	print_warning "${provider} ${reason} detected; recorded backoff (rotation skipped -- interactive-only)"
	return 1
}

record_provider_backoff() {
	local provider="$1"
	local reason="$2"
	local details_file="$3"
	local model="${4:-$provider}"
	local suppress_details="${5:-0}"
	local details retry_seconds auth_signature retry_after backoff_key

	# local_error = worker/sandbox/prompt issue, NOT provider's fault.
	# Skip backoff entirely -- recording it falsely flags healthy providers.
	if [[ "$reason" == "local_error" ]]; then
		return 0
	fi

	# Auth errors and account quota exhaustion back off at provider level
	# (shared credentials/account state). Rate limits and provider errors back
	# off at model level so other models from the same provider remain
	# available as fallbacks.
	if [[ "$reason" == "auth_error" || "$reason" == "quota_exceeded" ]]; then
		backoff_key="$provider"
	else
		backoff_key="$model"
	fi

	if _headless_private_workload_enabled || [[ "$suppress_details" == "1" ]]; then
		details="ephemeral workload details suppressed"
	else
		details=$(
			python3 - "$details_file" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(errors="ignore")
text = " ".join(text.split())
print(text[:400])
PY
		)
	fi
	auth_signature=$(get_auth_signature "$provider")
	retry_seconds=$(parse_retry_after_seconds "$details_file" "$provider")
	if [[ "$retry_seconds" -le 0 ]]; then
		# t1835: Reduced rate_limit fallback from 900s to 60s
		case "$reason" in
		rate_limit) retry_seconds=60 ;;
		auth_error) retry_seconds=3600 ;;
		*) retry_seconds=300 ;;
		esac
	fi
	retry_after=$(date -u -v+"${retry_seconds}"S '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "+${retry_seconds} seconds" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "")
	db_query "
INSERT INTO provider_backoff (provider, reason, retry_after, auth_signature, details, updated_at)
VALUES (
    '$(sql_escape "$backoff_key")',
    '$(sql_escape "$reason")',
    '$(sql_escape "$retry_after")',
    '$(sql_escape "$auth_signature")',
    '$(sql_escape "$details")',
    strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
)
ON CONFLICT(provider) DO UPDATE SET
    reason = excluded.reason,
    retry_after = excluded.retry_after,
    auth_signature = excluded.auth_signature,
    details = excluded.details,
    updated_at = excluded.updated_at;
" >/dev/null
	return 0
}

backoff_active_for_key() {
	local key="$1"
	local provider="$2"
	local row stored_retry_after stored_signature current_signature
	row=$(db_query "SELECT reason || '|' || retry_after || '|' || auth_signature FROM provider_backoff WHERE provider = '$(sql_escape "$key")';")
	if [[ -z "$row" ]]; then
		return 1
	fi

	IFS='|' read -r stored_reason stored_retry_after stored_signature <<<"$row"
	current_signature=$(get_auth_signature "$provider")
	if [[ -n "$stored_signature" && -n "$current_signature" && "$stored_signature" != "$current_signature" ]]; then
		clear_provider_backoff "$key"
		return 1
	fi

	if [[ -n "$stored_retry_after" ]]; then
		local now_epoch retry_epoch
		now_epoch=$(date -u '+%s')
		retry_epoch=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$stored_retry_after" '+%s' 2>/dev/null || date -u -d "$stored_retry_after" '+%s' 2>/dev/null || printf '%s' "0")
		if [[ "$retry_epoch" -le "$now_epoch" ]]; then
			clear_provider_backoff "$key"
			return 1
		fi
	fi

	return 0
}

model_backoff_active() {
	local model="$1"
	local provider
	provider=$(extract_provider "$model" 2>/dev/null || printf '%s' "")

	# Check model-level backoff (rate limits, provider errors)
	if backoff_active_for_key "$model" "$provider"; then
		return 0
	fi

	# Check provider-level backoff (auth errors affect all models)
	if [[ -n "$provider" && "$provider" != "$model" ]]; then
		if backoff_active_for_key "$provider" "$provider"; then
			return 0
		fi
	fi

	return 1
}

# Legacy wrapper -- kept for backward compatibility with cmd_backoff CLI
provider_backoff_active() {
	local provider="$1"
	backoff_active_for_key "$provider" "$provider"
	return $?
}

clear_startup_no_model_feedback() {
	local model="$1"
	local provider=""
	provider=$(extract_provider "$model" 2>/dev/null || printf '%s' "")
	[[ -n "$provider" ]] || return 0
	db_query "DELETE FROM provider_startup_failures WHERE provider = '$(sql_escape "$provider")';" >/dev/null || true
	return 0
}

record_startup_no_model_feedback() {
	local model="$1"
	local provider=""
	provider=$(extract_provider "$model" 2>/dev/null || printf '%s' "")
	[[ -n "$provider" ]] || return 0

	local threshold="${AIDEVOPS_STARTUP_NO_MODEL_FEEDBACK_THRESHOLD:-2}"
	local window_seconds="${AIDEVOPS_STARTUP_NO_MODEL_FEEDBACK_WINDOW_SECONDS:-900}"
	local cooldown_seconds="${AIDEVOPS_STARTUP_NO_MODEL_FEEDBACK_COOLDOWN_SECONDS:-300}"
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=2
	[[ "$window_seconds" =~ ^[0-9]+$ ]] || window_seconds=900
	[[ "$cooldown_seconds" =~ ^[0-9]+$ ]] || cooldown_seconds=300
	[[ "$threshold" -gt 0 ]] || threshold=2
	[[ "$window_seconds" -gt 0 ]] || window_seconds=900
	[[ "$cooldown_seconds" -gt 0 ]] || cooldown_seconds=300

	local existing_count="0"
	existing_count=$(db_query "
SELECT CASE
    WHEN (strftime('%s','now') - strftime('%s', updated_at)) <= $window_seconds THEN count
    ELSE 0
END
FROM provider_startup_failures
WHERE provider = '$(sql_escape "$provider")' AND model = '$(sql_escape "$model")';
" 2>/dev/null || printf '%s' "0")
	[[ "$existing_count" =~ ^[0-9]+$ ]] || existing_count=0
	local new_count=$((existing_count + 1))

	db_query "
INSERT INTO provider_startup_failures (provider, model, count, first_seen, updated_at)
VALUES (
    '$(sql_escape "$provider")',
    '$(sql_escape "$model")',
    $new_count,
    strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
    strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
)
ON CONFLICT(provider, model) DO UPDATE SET
    count = $new_count,
    first_seen = CASE WHEN $existing_count = 0 THEN excluded.first_seen ELSE provider_startup_failures.first_seen END,
    updated_at = excluded.updated_at;
" >/dev/null || true

	if [[ "$new_count" -lt "$threshold" ]]; then
		return 0
	fi

	local availability_helper="${MODEL_AVAILABILITY_HELPER:-${SCRIPT_DIR}/model-availability-helper.sh}"
	if [[ -x "$availability_helper" ]]; then
		"$availability_helper" mark-unavailable "$provider" "startup_no_model_activity" "$cooldown_seconds" --quiet >/dev/null 2>&1 || true
		print_warning "$provider startup_no_model_activity repeated ${new_count}x — marked provider unavailable for ${cooldown_seconds}s"
	fi
	return 0
}
