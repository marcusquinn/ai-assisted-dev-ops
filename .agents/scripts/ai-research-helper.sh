#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# ai-research-helper.sh — Lightweight multi-provider API wrapper for AI judgments
# Provides cheap simple-tier AI calls for threshold decisions, classification,
# and short-form reasoning tasks.
#
# Part of the Intelligence Over Determinism principle: use AI judgment where
# fixed thresholds would fail on outliers.
#
# Usage:
#   ai-research-helper.sh --prompt "Is this conversation idle?" [--provider auto|anthropic|opencode] [--model simple|standard|thinking] [--max-tokens 100]
#   echo "prompt text" | ai-research-helper.sh --stdin [--provider opencode] [--model simple]
#
# Environment:
#   AIDEVOPS_AI_RESEARCH_PROVIDER — auto (default), anthropic, or opencode
#   AIDEVOPS_AI_RESEARCH_OPENCODE_MODEL — OpenCode model for default runtime path
#   ANTHROPIC_API_KEY — env, gopass, credentials.sh, or OAuth pool
#
# Exit codes: 0=success (response on stdout), 1=error, 2=no usable provider credentials

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

LOG_PREFIX="AI-RESEARCH"

resolve_model_id() {
	local name="${1:-simple}"
	case "$name" in
	simple) echo "claude-haiku-4-5-20251001" ;;
	standard) echo "claude-sonnet-4-6" ;;
	thinking) echo "claude-opus-4-6" ;;
	anthropic/*) echo "${name#anthropic/}" ;;
	*) echo "claude-haiku-4-5-20251001" ;;
	esac
	return 0
}

resolve_opencode_model_id() {
	local name="${1:-simple}"
	case "$name" in
	simple | standard | thinking) model_tier_candidate_for_provider "$name" openai || return 1 ;;
	local) echo "openai/gpt-5.4-mini" ;;
	openai/* | anthropic/* | google/*) echo "$name" ;;
	*) echo "$name" ;;
	esac
	return 0
}

resolve_opencode_variant() {
	local name="${1:-simple}"
	local model="${2:-}"
	[[ -n "$model" ]] || model=$(resolve_opencode_model_id "$name") || return 1
	case "$name" in
	simple | standard | thinking) model_tier_variant "$name" "$model" || true ;;
	*) echo "" ;;
	esac
	return 0
}

provider_key_var() {
	local provider="$1"
	case "$provider" in
	anthropic) printf 'ANTHROPIC_API_KEY\n' ;;
	*) return 1 ;;
	esac
	return 0
}

provider_gopass_secret() {
	local provider="$1"
	case "$provider" in
	anthropic) printf 'aidevops/anthropic-api-key\n' ;;
	*) return 1 ;;
	esac
	return 0
}

now_ms() {
	local value
	value=$(date +%s%3N 2>/dev/null) || value="0"
	[[ "$value" =~ ^[0-9]+$ ]] || value="0"
	if [[ "${#value}" -lt 10 ]]; then
		value=$(($(date +%s) * 1000))
	fi
	printf '%s\n' "$value"
	return 0
}

resolve_oauth_pool_token() {
	local provider="${1:-anthropic}"
	local pool_file="${HOME}/.aidevops/oauth-pool.json"
	[[ -f "$pool_file" ]] || return 1
	command -v jq &>/dev/null || return 1

	local current_ms
	current_ms=$(now_ms)

	local token
	token=$(jq -r --arg provider "$provider" --argjson now "$current_ms" '
		(.[$provider] // [])
		| map(select(
			(.access // "") != ""
			and ((.status // "") == "active" or (.status // "") == "idle")
			and ((.expires // 0) > $now)
			and ((.cooldownUntil // 0) <= $now)
		))
		| .[0].access // ""
	' "$pool_file" 2>/dev/null) || return 1

	[[ -n "$token" ]] || return 1
	printf '%s\n' "$token"
	return 0
}

_AI_RESEARCH_CREDENTIAL_KIND=""
_AI_RESEARCH_CREDENTIAL_VALUE=""
_AI_RESEARCH_CREDENTIAL_KIND_API_KEY="api-key"

resolve_provider_credential_typed() {
	local provider="${1:-anthropic}"
	local key_var=""
	local secret_path=""
	local credential=""
	local oauth_token=""
	_AI_RESEARCH_CREDENTIAL_KIND=""
	_AI_RESEARCH_CREDENTIAL_VALUE=""
	key_var=$(provider_key_var "$provider") || return 1

	if [[ -n "${!key_var:-}" ]]; then
		_AI_RESEARCH_CREDENTIAL_KIND="$_AI_RESEARCH_CREDENTIAL_KIND_API_KEY"
		_AI_RESEARCH_CREDENTIAL_VALUE="${!key_var}"
		return 0
	fi

	if command -v gopass &>/dev/null; then
		secret_path=$(provider_gopass_secret "$provider") || secret_path=""
		if [[ -n "$secret_path" ]]; then
			credential=$(gopass show -o "$secret_path" 2>/dev/null) || true
			if [[ -n "$credential" ]]; then
				_AI_RESEARCH_CREDENTIAL_KIND="$_AI_RESEARCH_CREDENTIAL_KIND_API_KEY"
				_AI_RESEARCH_CREDENTIAL_VALUE="$credential"
				return 0
			fi
		fi
	fi

	local creds_file="${HOME}/.config/aidevops/credentials.sh"
	if [[ -f "$creds_file" ]]; then
		credential=$(grep -E "^${key_var}=" "$creds_file" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
		if [[ -n "$credential" ]]; then
			_AI_RESEARCH_CREDENTIAL_KIND="$_AI_RESEARCH_CREDENTIAL_KIND_API_KEY"
			_AI_RESEARCH_CREDENTIAL_VALUE="$credential"
			return 0
		fi
	fi

	if oauth_token=$(resolve_oauth_pool_token "$provider"); then
		_AI_RESEARCH_CREDENTIAL_KIND="oauth-pool"
		_AI_RESEARCH_CREDENTIAL_VALUE="$oauth_token"
		return 0
	fi

	return 1
}

resolve_provider_credential() {
	local provider="${1:-anthropic}"
	local credential_value=""
	resolve_provider_credential_typed "$provider" || return 1
	credential_value="$_AI_RESEARCH_CREDENTIAL_VALUE"
	_AI_RESEARCH_CREDENTIAL_KIND=""
	_AI_RESEARCH_CREDENTIAL_VALUE=""
	printf '%s\n' "$credential_value"
	return 0
}

# Backwards-compatible Anthropic resolver used by existing sourced tests/callers.
resolve_api_key() {
	local provider="${1:-anthropic}"
	resolve_provider_credential "$provider"
	return $?
}

json_payload() {
	local provider="$1"
	if [[ "$provider" != "anthropic" ]]; then
		return 1
	fi
	local prompt="$2"
	local model_id="$3"
	local max_tokens="$4"
	PROVIDER="$provider" PROMPT_TEXT="$prompt" MODEL_ID="$model_id" MAX_TOKENS="$max_tokens" python3 - <<'PY'
import json, os
provider = os.environ["PROVIDER"]
prompt = os.environ["PROMPT_TEXT"]
model = os.environ["MODEL_ID"]
max_tokens = int(os.environ["MAX_TOKENS"])
print(json.dumps({
    "model": model,
    "max_tokens": max_tokens,
    "messages": [{"role": "user", "content": prompt}],
}))
PY
	return $?
}

extract_anthropic_text() {
	local response="$1"
	if command -v jq &>/dev/null; then
		printf '%s' "$response" | jq -r '.content[0].text // empty' 2>/dev/null
		return $?
	fi
	printf '%s' "$response" | python3 -c 'import sys,json; data=json.load(sys.stdin); print(data["content"][0]["text"])' 2>/dev/null
	return $?
}

extract_error_message() {
	local response="$1"
	if command -v jq &>/dev/null; then
		printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null || true
	else
		printf ''
	fi
	return 0
}

strip_ansi() {
	python3 -c 'import re,sys; print(re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", sys.stdin.read()), end="")'
	return $?
}

extract_opencode_text() {
	local raw_output="$1"
	printf '%s' "$raw_output" | strip_ansi | python3 -c '
import json, sys
lines = [line.strip() for line in sys.stdin.read().splitlines()]
json_texts = []
filtered = []
text_key = "text"
for line in lines:
    if not line:
        continue
    try:
        event = json.loads(line)
        part = event.get("part") or {}
        if part.get("type") == text_key and part.get(text_key):
            json_texts.append(str(part[text_key]).strip())
        continue
    except Exception:
        pass
    if line.startswith("> "):
        continue
    if line.startswith("!") and "agent" in line and "Falling back" in line:
        continue
    filtered.append(line)
if json_texts:
    print(json_texts[-1])
elif filtered:
    print(filtered[-1])
'
	return $?
}

call_anthropic() {
	local prompt="$1"
	local model_name="${2:-simple}"
	local max_tokens="${3:-150}"

	local credential_kind=""
	local credential_value=""
	local -a auth_headers=()
	if ! resolve_provider_credential_typed anthropic; then
		log_error "No Anthropic API key found (env, gopass, credentials.sh, or OAuth pool)"
		return 2
	fi
	credential_kind="$_AI_RESEARCH_CREDENTIAL_KIND"
	credential_value="$_AI_RESEARCH_CREDENTIAL_VALUE"
	_AI_RESEARCH_CREDENTIAL_KIND=""
	_AI_RESEARCH_CREDENTIAL_VALUE=""
	case "$credential_kind" in
	"$_AI_RESEARCH_CREDENTIAL_KIND_API_KEY") auth_headers=(-H "x-api-key: ${credential_value}") ;;
	oauth-pool)
		auth_headers=(-H "Authorization: Bearer ${credential_value}" -H "anthropic-beta: oauth-2025-04-20")
		;;
	*)
		log_error "Unsupported Anthropic credential kind"
		return 2
		;;
	esac

	local model_id payload response text
	model_id=$(resolve_model_id "$model_name")
	payload=$(json_payload anthropic "$prompt" "$model_id" "$max_tokens") || return 1
	response=$(curl -sS --max-time 30 \
		"${auth_headers[@]}" \
		-H "anthropic-version: 2023-06-01" \
		-H "${CONTENT_TYPE_JSON}" \
		-d "$payload" \
		"https://api.anthropic.com/v1/messages" 2>/dev/null) || {
		log_error "Anthropic API call failed"
		return 1
	}

	text=$(extract_anthropic_text "$response") || text=""
	if [[ -z "$text" ]]; then
		local error_msg
		error_msg=$(extract_error_message "$response")
		[[ -n "$error_msg" ]] && log_error "Anthropic API error: $error_msg" || log_error "Empty response from Anthropic API"
		return 1
	fi

	printf '%s\n' "$text"
	return 0
}

call_opencode() {
	local prompt="$1"
	local model_name="${2:-simple}"
	local max_tokens="${3:-150}"
	: "$max_tokens"

	if ! command -v opencode &>/dev/null; then
		log_error "OpenCode CLI not found for AI research runtime provider"
		return 2
	fi

	local model_id variant_id raw text timeout_cmd wrapped_prompt
	local -a variant_args=()
	local run_dir="${AIDEVOPS_AI_RESEARCH_OPENCODE_DIR:-/tmp/opencode}"
	model_id="${AIDEVOPS_AI_RESEARCH_OPENCODE_MODEL:-}"
	if [[ -z "$model_id" ]]; then
		model_id=$(resolve_opencode_model_id "$model_name") || return 2
	fi
	variant_id=$(resolve_opencode_variant "$model_name" "$model_id")
	if [[ -n "$variant_id" ]]; then
		variant_args=(--variant "$variant_id")
	fi
	timeout_cmd=""
	if command -v timeout &>/dev/null; then
		timeout_cmd="timeout 90"
	elif command -v gtimeout &>/dev/null; then
		timeout_cmd="gtimeout 90"
	fi
	mkdir -p "$run_dir" 2>/dev/null || run_dir="/tmp"
	wrapped_prompt="You are a non-interactive AI research helper. Do not use tools. Do not ask follow-up questions. Do not greet. Return only the requested answer text, with no preamble or markdown. Task:\n${prompt}"

	if [[ -n "$timeout_cmd" ]]; then
		raw=$(cd "$run_dir" && AIDEVOPS_HEADLESS=1 $timeout_cmd opencode run --format json -m "$model_id" "${variant_args[@]}" "$wrapped_prompt" 2>&1) || {
			log_error "OpenCode AI research call failed"
			return 1
		}
	else
		raw=$(cd "$run_dir" && AIDEVOPS_HEADLESS=1 opencode run --format json -m "$model_id" "${variant_args[@]}" "$wrapped_prompt" 2>&1) || {
			log_error "OpenCode AI research call failed"
			return 1
		}
	fi

	text=$(extract_opencode_text "$raw") || text=""
	if [[ -z "$text" ]]; then
		log_error "Empty response from OpenCode AI research provider"
		return 1
	fi

	printf '%s\n' "$text"
	return 0
}

call_ai() {
	local provider="$1"
	local prompt="$2"
	local model="$3"
	local max_tokens="$4"

	case "$provider" in
	anthropic)
		call_anthropic "$prompt" "$model" "$max_tokens"
		return $?
		;;
	opencode | openai)
		call_opencode "$prompt" "$model" "$max_tokens"
		return $?
		;;
	auto)
		if command -v opencode &>/dev/null; then
			call_opencode "$prompt" "$model" "$max_tokens"
			return $?
		fi
		call_anthropic "$prompt" "$model" "$max_tokens"
		return $?
		;;
	*)
		log_error "Unsupported provider: $provider"
		return 1
		;;
	esac
}

main() {
	local prompt=""
	local model="simple"
	local max_tokens="150"
	local provider="${AIDEVOPS_AI_RESEARCH_PROVIDER:-auto}"
	local use_stdin=false

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		local value="${2:-}"
		case "$arg" in
		--prompt)
			prompt="$value"
			shift 2
			;;
		--model)
			model="$value"
			shift 2
			;;
		--max-tokens)
			max_tokens="$value"
			shift 2
			;;
		--provider)
			provider="$value"
			shift 2
			;;
		--stdin)
			use_stdin=true
			shift
			;;
		--help | -h)
			echo "Usage: ai-research-helper.sh --prompt \"PROMPT\" [--provider auto|anthropic|opencode] [--model simple|standard|thinking] [--max-tokens 150]"
			echo "       printf '%s' \"PROMPT\" | ai-research-helper.sh --stdin [--provider opencode] [--model simple]"
			echo ""
			echo "Lightweight multi-provider API wrapper for AI threshold judgments."
			echo "Default provider: auto (OpenCode runtime first, then Anthropic direct API)."
			return 0
			;;
		*)
			shift
			;;
		esac
	done

	if [[ "$use_stdin" == true ]]; then
		prompt=$(cat)
	fi

	if [[ -z "$prompt" ]]; then
		log_error "No prompt provided. Use --prompt \"PROMPT\" or --stdin"
		return 1
	fi

	call_ai "$provider" "$prompt" "$model" "$max_tokens"
	return $?
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
	main "$@"
fi
