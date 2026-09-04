#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# verify-operation-helper.sh — Cross-provider verification for high-stakes operations (t1364.2)
# Commands: verify | check | config | help
# Docs: tools/verification/parallel-verify.md
#
# Invokes a second AI provider to independently verify whether a high-stakes
# operation should proceed. Different providers have different failure modes,
# so cross-provider verification catches single-model hallucinations.
#
# Usage:
#   verify-operation-helper.sh verify --operation "cmd" --type "type" --risk-tier "critical"
#   verify-operation-helper.sh check --operation "cmd"
#   verify-operation-helper.sh config [--show|--set KEY=VALUE]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail
init_log_file

LOG_PREFIX="VERIFY"

# =============================================================================
# Constants
# =============================================================================

readonly VERIFY_DIR="${HOME}/.aidevops/.agent-workspace/observability"
readonly VERIFY_LOG="${VERIFY_DIR}/verifications.jsonl"
readonly VERIFY_CONFIG_DIR="${HOME}/.config/aidevops"
readonly VERIFY_CONFIG="${VERIFY_CONFIG_DIR}/verification.json"
readonly MAX_PROMPT_TOKENS=2000
readonly MAX_OUTPUT_TOKENS=500

# =============================================================================
# Provider Selection
# =============================================================================

# Detect the provider from a model ID string.
# Arguments: $1 — model ID (e.g., "claude-sonnet-4-6", "gemini-2.5-flash")
# Output: provider name on stdout (anthropic|google|openai|unknown)
detect_provider() {
	local model="$1"
	case "$model" in
	claude-* | anthropic/*) echo "anthropic" ;;
	gemini-* | google/*) echo "google" ;;
	gpt-* | openai/* | o1-* | o3-*) echo "openai" ;;
	*) echo "unknown" ;;
	esac
	return 0
}

# Select the cheapest verifier model from a different provider.
# Arguments: $1 — primary provider name
# Output: "provider|model" on stdout
# Returns: 0 if cross-provider found, 1 if same-provider fallback, 2 if none
select_verifier() {
	local primary_provider="$1"

	# Provider preference chains (cheapest tier of each)
	local -a anthropic_chain=("google|gemini-2.5-flash" "openai|gpt-4.1-mini")
	local -a google_chain=("anthropic|claude-haiku-4-5" "openai|gpt-4.1-mini")
	local -a openai_chain=("anthropic|claude-haiku-4-5" "google|gemini-2.5-flash")

	local -a chain
	case "$primary_provider" in
	anthropic) chain=("${anthropic_chain[@]}") ;;
	google) chain=("${google_chain[@]}") ;;
	openai) chain=("${openai_chain[@]}") ;;
	*)
		# Unknown primary — try anthropic first, then google
		chain=("anthropic|claude-haiku-4-5" "google|gemini-2.5-flash")
		;;
	esac

	# Try each provider in the chain
	local entry provider
	for entry in "${chain[@]}"; do
		provider="${entry%%|*}"
		if _check_provider_available "$provider"; then
			echo "$entry"
			return 0
		fi
	done

	# Same-provider fallback (less effective)
	local fallback_model
	fallback_model=$(_get_same_provider_fallback "$primary_provider")
	if [[ -n "$fallback_model" ]]; then
		log_warn "No cross-provider verifier available. Using same-provider fallback (reduced effectiveness)."
		echo "${primary_provider}|${fallback_model}"
		return 1
	fi

	log_error "No verification provider available"
	return 2
}

# Check if a provider has a valid API key configured.
# Arguments: $1 — provider name
# Returns: 0 if available, 1 if not
_check_provider_available() {
	local provider="$1"

	# Use model-availability-helper if available
	if [[ -x "${SCRIPT_DIR}/model-availability-helper.sh" ]]; then
		"${SCRIPT_DIR}/model-availability-helper.sh" check "$provider" >/dev/null 2>&1
		return $?
	fi

	# Fallback: check for API key in environment/gopass/credentials
	case "$provider" in
	anthropic) _has_api_key "ANTHROPIC_API_KEY" "aidevops/anthropic-api-key" ;;
	google) _has_api_key "GOOGLE_API_KEY" "aidevops/google-api-key" ;;
	openai) _has_api_key "OPENAI_API_KEY" "aidevops/openai-api-key" ;;
	*) return 1 ;;
	esac
}

# Check if an API key exists in env, gopass, or credentials.sh.
# Arguments: $1 — env var name, $2 — gopass path
# Returns: 0 if found, 1 if not
_has_api_key() {
	local env_var="$1"
	local gopass_path="$2"

	# Check environment
	if [[ -n "${!env_var:-}" ]]; then
		return 0
	fi

	# Check gopass
	if command -v gopass &>/dev/null; then
		if gopass show -o "$gopass_path" &>/dev/null; then
			return 0
		fi
	fi

	# Check credentials.sh
	local creds_file="${HOME}/.config/aidevops/credentials.sh"
	if [[ -f "$creds_file" ]] && grep -qE "^${env_var}=" "$creds_file" 2>/dev/null; then
		return 0
	fi

	return 1
}

# Get a same-provider fallback model (different model, same provider).
# Arguments: $1 — provider name
# Output: model ID on stdout (empty if none)
_get_same_provider_fallback() {
	local provider="$1"
	case "$provider" in
	anthropic) echo "claude-haiku-4-5" ;;
	google) echo "gemini-2.5-flash" ;;
	openai) echo "gpt-4.1-mini" ;;
	*) echo "" ;;
	esac
	return 0
}

# =============================================================================
# Risk Classification
# =============================================================================

# Known operation types and their default risk tiers.
# Format: "pattern|type|tier"
readonly -a RISK_PATTERNS=(
	"git push --force|git_force_push|critical"
	"git push -f |git_force_push|critical"
	"git reset --hard|git_hard_reset|critical"
	"DROP TABLE|db_drop|critical"
	"DROP DATABASE|db_drop|critical"
	"TRUNCATE|db_truncate|critical"
	"ALTER TABLE.*DROP|db_alter_drop|critical"
	"rm -rf /|destructive_delete|critical"
	"kubectl delete|k8s_delete|critical"
	"terraform destroy|infra_destroy|critical"
	"pulumi destroy|infra_destroy|critical"
	"terraform apply|infra_apply|high"
	"pulumi up|infra_apply|high"
	"npm publish|package_publish|high"
	"cargo publish|package_publish|high"
	"gh release create|release_create|high"
	"chmod 777|permission_change|high"
	"chown|permission_change|high"
)

# Classify GitHub REST API deletion commands that need endpoint-aware handling.
# Arguments: $1 — operation string
# Output: "type|tier" when the operation is a GitHub API DELETE
# Returns: 0 when classified, 1 when the operation is not a GitHub API DELETE
_classify_github_api_delete() {
	local operation="$1"

	if ! printf '%s\n' "$operation" | grep -qiE '(^|[[:space:]])gh[[:space:]]+api([[:space:]]|$)'; then
		return 1
	fi

	if ! printf '%s\n' "$operation" | grep -qiE '(^|[[:space:]])(--method|-X)[[:space:]]+DELETE([[:space:]]|$)'; then
		return 1
	fi

	# Deleting an issue comment is irreversible; other DELETE endpoints remain
	# high risk until their reversibility is explicitly understood and tested.
	if printf '%s\n' "$operation" | grep -qE "(^|[[:space:]/\\\"'])issues/comments/[0-9]+([[:space:]\\\"']|$)"; then
		echo "destructive_delete|critical"
		return 0
	fi

	echo "github_api_delete|high"
	return 0
}

# Classify an operation string into a risk tier.
# Arguments: $1 — operation string
# Output: "type|tier" on stdout (e.g., "git_force_push|critical")
classify_operation() {
	local operation="$1"
	local entry pattern op_type tier github_api_classification

	if github_api_classification=$(_classify_github_api_delete "$operation"); then
		echo "$github_api_classification"
		return 0
	fi

	for entry in "${RISK_PATTERNS[@]}"; do
		pattern="${entry%%|*}"
		local rest="${entry#*|}"
		op_type="${rest%%|*}"
		tier="${rest#*|}"

		if echo "$operation" | grep -qiE "$pattern" 2>/dev/null; then
			echo "${op_type}|${tier}"
			return 0
		fi
	done

	# No match — standard tier (verify on request only)
	echo "unknown|standard"
	return 0
}

# =============================================================================
# Verification Engine
# =============================================================================

# Build the verification prompt from operation details.
# Arguments: multiple named via locals
# Output: prompt text on stdout
_build_verification_prompt() {
	local operation="$1"
	local op_type="$2"
	local risk_tier="$3"
	local repo="${4:-unknown}"
	local branch="${5:-unknown}"
	local details="${6:-}"

	cat <<PROMPT
You are a safety verification agent. An AI assistant is about to perform the
following operation. Your job is to independently assess whether this operation
should proceed.

## Operation
${op_type}: ${operation}

## Context
- Repository: ${repo}
- Branch: ${branch}
- Risk tier: ${risk_tier}

## Specific Details
${details:-No additional details provided.}

## Your Assessment

Respond in exactly this JSON format (no markdown, no code fences):
{"verified":true,"confidence":0.95,"concerns":[],"recommendation":"proceed","reasoning":"explanation"}

Rules:
- "proceed": Operation looks safe, no concerns
- "warn": Operation has minor concerns but can proceed with caution
- "block": Operation has serious concerns and should NOT proceed without review
- Be conservative: when in doubt, recommend "warn" not "proceed"
- Focus on: data loss risk, security implications, reversibility, blast radius
PROMPT
	return 0
}

# Call the verifier model via ai-research-helper.sh.
# Arguments: $1 — prompt, $2 — model short name
# Output: JSON response on stdout
# Returns: 0 on success, 1 on failure
_call_verifier() {
	local prompt="$1"
	local model="${2:-simple}"

	if [[ ! -x "${SCRIPT_DIR}/ai-research-helper.sh" ]]; then
		log_error "ai-research-helper.sh not found or not executable"
		return 1
	fi

	local response
	response=$("${SCRIPT_DIR}/ai-research-helper.sh" \
		--prompt "$prompt" \
		--model "$model" \
		--max-tokens "$MAX_OUTPUT_TOKENS" 2>/dev/null) || {
		log_error "Verifier API call failed"
		return 1
	}

	echo "$response"
	return 0
}

# Parse the verifier's JSON response.
# Arguments: $1 — raw response text
# Output: "verified|confidence|recommendation|reasoning" on stdout
# Returns: 0 on success, 1 on parse failure
_parse_verification_response() {
	local response="$1"

	# Try to extract JSON from the response (may have surrounding text)
	local json_text
	json_text=$(echo "$response" | grep -oE '\{[^}]+\}' | head -1) || json_text=""

	if [[ -z "$json_text" ]]; then
		log_error "Could not extract JSON from verifier response"
		echo "false|0.0|block|Parse failure: no JSON in response"
		return 1
	fi

	if ! command -v jq &>/dev/null; then
		log_error "jq required for response parsing"
		echo "false|0.0|block|Parse failure: jq not available"
		return 1
	fi

	local verified confidence recommendation reasoning concerns
	verified=$(echo "$json_text" | jq -r '.verified // false' 2>/dev/null) || verified="false"
	confidence=$(echo "$json_text" | jq -r '.confidence // 0' 2>/dev/null) || confidence="0"
	recommendation=$(echo "$json_text" | jq -r '.recommendation // "block"' 2>/dev/null) || recommendation="block"
	reasoning=$(echo "$json_text" | jq -r '.reasoning // "No reasoning provided"' 2>/dev/null) || reasoning="No reasoning provided"
	concerns=$(echo "$json_text" | jq -r '(.concerns // []) | join("; ")' 2>/dev/null) || concerns=""

	echo "${verified}|${confidence}|${recommendation}|${reasoning}|${concerns}"
	return 0
}

# =============================================================================
# Observability Logging
# =============================================================================

# Log a verification decision to the JSONL log.
# Arguments: multiple named via locals
_log_verification() {
	local op_type="$1"
	local risk_tier="$2"
	local primary_provider="$3"
	local verifier_provider="$4"
	local verifier_model="$5"
	local result="$6"
	local confidence="$7"
	local concerns="$8"
	local was_overridden="$9"
	local override_reason="${10:-}"
	local session_id="${11:-}"
	local repo="${12:-}"
	local branch="${13:-}"

	mkdir -p "$VERIFY_DIR" 2>/dev/null || true

	if ! command -v jq &>/dev/null; then
		# Fallback: write raw line if jq unavailable
		echo "{\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"operation_type\":\"${op_type}\",\"result\":\"${result}\"}" >>"$VERIFY_LOG"
		return 0
	fi

	jq -c -n \
		--arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
		--arg ot "$op_type" \
		--arg rt "$risk_tier" \
		--arg pp "$primary_provider" \
		--arg vp "$verifier_provider" \
		--arg vm "$verifier_model" \
		--arg rs "$result" \
		--arg cf "$confidence" \
		--arg cn "$concerns" \
		--argjson wo "$was_overridden" \
		--arg or "$override_reason" \
		--arg si "$session_id" \
		--arg rp "$repo" \
		--arg br "$branch" \
		'{timestamp:$ts, operation_type:$ot, risk_tier:$rt,
		  primary_provider:$pp, verifier_provider:$vp, verifier_model:$vm,
		  result:$rs, confidence:($cf|tonumber), concerns:$cn,
		  was_overridden:$wo, override_reason:$or,
		  session_id:$si, repo:$rp, branch:$br}' >>"$VERIFY_LOG"

	# Also record to observability metrics for cost tracking
	if [[ -x "${SCRIPT_DIR}/observability-helper.sh" ]]; then
		"${SCRIPT_DIR}/observability-helper.sh" record \
			--provider "$verifier_provider" \
			--model "$verifier_model" \
			--project "$repo" \
			--session "$session_id" \
			--stop-reason "verification:${result}" >/dev/null 2>&1 || true
	fi

	return 0
}

# =============================================================================
# Commands
# =============================================================================

# _cmd_verify_parse_args — Parse verify command arguments into named variables.
# Sets: operation, op_type, risk_tier, repo, branch, details, primary_model,
#       session_id, skip_reason via caller's local variables (passed by name).
# Usage: call with "$@" from cmd_verify; variables must be declared local first.
_cmd_verify_parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--operation)
			operation="${2:-}"
			shift 2
			;;
		--type)
			op_type="${2:-}"
			shift 2
			;;
		--risk-tier)
			risk_tier="${2:-}"
			shift 2
			;;
		--repo)
			repo="${2:-}"
			shift 2
			;;
		--branch)
			branch="${2:-}"
			shift 2
			;;
		--details)
			details="${2:-}"
			shift 2
			;;
		--primary-model)
			primary_model="${2:-}"
			shift 2
			;;
		--session)
			session_id="${2:-}"
			shift 2
			;;
		--skip)
			skip_reason="${2:-}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done
	return 0
}

# _cmd_verify_check_skip — Handle skip conditions and auto-classify the operation.
# Arguments: $1=operation $2=op_type $3=risk_tier $4=session_id $5=repo $6=branch $7=skip_reason
# Outputs: "SKIPPED" or "PROCEED" on stdout if short-circuit applies; nothing otherwise.
# Returns: 0 to continue, 1 to short-circuit (caller should return 0).
_cmd_verify_check_skip() {
	local operation="$1"
	local op_type="$2"
	local risk_tier="$3"
	local session_id="$4"
	local repo="$5"
	local branch="$6"
	local skip_reason="$7"

	# Check global skip
	if [[ "${AIDEVOPS_SKIP_VERIFY:-}" == "1" ]]; then
		log_warn "Verification skipped (AIDEVOPS_SKIP_VERIFY=1)"
		_log_verification "${op_type:-unknown}" "${risk_tier:-unknown}" "unknown" "none" "none" \
			"skipped" "0" "" "true" "env:AIDEVOPS_SKIP_VERIFY" "$session_id" "$repo" "$branch"
		echo "SKIPPED"
		return 1
	fi

	# Check explicit skip
	if [[ -n "$skip_reason" ]]; then
		log_warn "Verification skipped: ${skip_reason}"
		_log_verification "${op_type:-unknown}" "${risk_tier:-unknown}" "unknown" "none" "none" \
			"skipped" "0" "" "true" "$skip_reason" "$session_id" "$repo" "$branch"
		echo "SKIPPED"
		return 1
	fi

	return 0
}

# _cmd_verify_select_verifier — Select a cross-provider verifier and resolve model details.
# Arguments: $1=primary_model $2=op_type $3=risk_tier $4=session_id $5=repo $6=branch
# Outputs on stdout: "verifier_provider|verifier_model|model_short" or "PROCEED_UNVERIFIED"
# Returns: 0 on success, 1 if no verifier available (caller should echo PROCEED_UNVERIFIED).
_cmd_verify_select_verifier() {
	local primary_model="$1"
	local op_type="$2"
	local risk_tier="$3"
	local session_id="$4"
	local repo="$5"
	local branch="$6"

	local primary_provider
	primary_provider=$(detect_provider "${primary_model:-claude-sonnet-4-6}")

	local verifier_entry verifier_provider verifier_model
	verifier_entry=$(select_verifier "$primary_provider") || {
		local rc=$?
		if [[ $rc -eq 2 ]]; then
			log_warn "No verification provider available — proceeding with warning"
			_log_verification "$op_type" "$risk_tier" "$primary_provider" "none" "none" \
				"unavailable" "0" "No verifier available" "false" "" "$session_id" "$repo" "$branch"
			echo "PROCEED_UNVERIFIED"
			return 1
		fi
		# rc=1 means same-provider fallback — continue with it
		true
	}
	verifier_provider="${verifier_entry%%|*}"
	verifier_model="${verifier_entry#*|}"

	# Determine model short name for ai-research-helper
	local model_short
	case "$verifier_model" in
	claude-haiku-*) model_short="simple" ;;
	claude-sonnet-*) model_short="standard" ;;
	claude-opus-*) model_short="thinking" ;;
	*) model_short="simple" ;;
	esac

	# For non-Anthropic verifiers, we still use ai-research-helper (Anthropic)
	# but log the intended cross-provider preference. Full multi-provider
	# support is a future enhancement (t1364.3).
	if [[ "$verifier_provider" != "anthropic" ]]; then
		log_info "Note: Using Anthropic API for verification call (multi-provider API support planned in t1364.3)"
		verifier_provider="anthropic"
		verifier_model="claude-haiku-4-5"
		model_short="simple"
	fi

	log_info "Verifying operation: ${op_type} (${risk_tier})"
	log_info "Primary: ${primary_provider} -> Verifier: ${verifier_provider} (${verifier_model})"

	echo "${verifier_provider}|${verifier_model}|${model_short}"
	return 0
}

# _cmd_verify_act_on_recommendation — Emit the result based on the verifier's recommendation.
# Arguments: $1=recommendation $2=confidence $3=reasoning $4=concerns
# Outputs: PROCEED / PROCEED_LOW_CONFIDENCE / WARN / BLOCK on stdout.
# Returns: 0 for proceed/warn, 1 for block.
_cmd_verify_act_on_recommendation() {
	local recommendation="$1"
	local confidence="$2"
	local reasoning="$3"
	local concerns="$4"

	case "$recommendation" in
	proceed)
		if awk "BEGIN {exit !($confidence < 0.8)}" 2>/dev/null; then
			log_warn "Verified with low confidence (${confidence}): ${reasoning}"
			echo "PROCEED_LOW_CONFIDENCE"
		else
			log_success "Verified (confidence: ${confidence}): ${reasoning}"
			echo "PROCEED"
		fi
		;;
	warn)
		log_warn "Verification concerns: ${reasoning}"
		if [[ -n "$concerns" ]]; then
			log_warn "Specific concerns: ${concerns}"
		fi
		echo "WARN"
		;;
	block)
		print_error "Verification BLOCKED: ${reasoning}"
		if [[ -n "$concerns" ]]; then
			print_error "Concerns: ${concerns}"
		fi
		echo "BLOCK"
		return 1
		;;
	*)
		log_warn "Unknown recommendation '${recommendation}' — treating as warn"
		echo "WARN"
		;;
	esac

	return 0
}

# verify — Perform cross-provider verification of an operation.
cmd_verify() {
	local operation="" op_type="" risk_tier="" repo="" branch="" details=""
	local primary_model="" skip_reason="" session_id=""

	_cmd_verify_parse_args "$@"

	# Validate required params
	if [[ -z "$operation" ]]; then
		print_error "Usage: verify-operation-helper.sh verify --operation \"command\" [options]"
		return 1
	fi

	# Handle skip conditions — short-circuit if applicable
	_cmd_verify_check_skip "$operation" "$op_type" "$risk_tier" \
		"$session_id" "$repo" "$branch" "$skip_reason" || return 0

	# Auto-classify if type/tier not provided
	if [[ -z "$op_type" || -z "$risk_tier" ]]; then
		local classification
		classification=$(classify_operation "$operation")
		op_type="${op_type:-${classification%%|*}}"
		risk_tier="${risk_tier:-${classification#*|}}"
	fi

	# Standard tier doesn't require verification unless explicitly requested
	if [[ "$risk_tier" == "standard" ]]; then
		log_info "Operation classified as standard risk — verification not required"
		echo "PROCEED"
		return 0
	fi

	# Select verifier — short-circuit if none available
	local verifier_info
	verifier_info=$(_cmd_verify_select_verifier "$primary_model" "$op_type" "$risk_tier" \
		"$session_id" "$repo" "$branch") || {
		echo "$verifier_info"
		return 0
	}
	local verifier_provider verifier_model model_short
	IFS='|' read -r verifier_provider verifier_model model_short <<<"$verifier_info"

	# Build prompt and call verifier
	local prompt
	prompt=$(_build_verification_prompt "$operation" "$op_type" "$risk_tier" "$repo" "$branch" "$details")

	local primary_provider
	primary_provider=$(detect_provider "${primary_model:-claude-sonnet-4-6}")

	local raw_response
	raw_response=$(_call_verifier "$prompt" "$model_short") || {
		log_warn "Verification call failed — proceeding with warning"
		_log_verification "$op_type" "$risk_tier" "$primary_provider" "$verifier_provider" "$verifier_model" \
			"error" "0" "API call failed" "false" "" "$session_id" "$repo" "$branch"
		echo "PROCEED_UNVERIFIED"
		return 0
	}

	# Parse response
	local parsed verified confidence recommendation reasoning concerns
	parsed=$(_parse_verification_response "$raw_response") || true
	IFS='|' read -r verified confidence recommendation reasoning concerns <<<"$parsed"

	# Log the decision
	_log_verification "$op_type" "$risk_tier" "$primary_provider" "$verifier_provider" "$verifier_model" \
		"$recommendation" "$confidence" "$concerns" "false" "" "$session_id" "$repo" "$branch"

	# Act on the recommendation
	_cmd_verify_act_on_recommendation "$recommendation" "$confidence" "$reasoning" "$concerns"
	return $?
}

# check — Determine if an operation needs verification (without performing it).
cmd_check() {
	local operation=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--operation)
			operation="${2:-}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$operation" ]]; then
		print_error "Usage: verify-operation-helper.sh check --operation \"command\""
		return 1
	fi

	local classification op_type risk_tier
	classification=$(classify_operation "$operation")
	op_type="${classification%%|*}"
	risk_tier="${classification#*|}"

	echo "operation: ${operation}"
	echo "type: ${op_type}"
	echo "risk_tier: ${risk_tier}"

	case "$risk_tier" in
	critical)
		echo "verification: required"
		echo "action: MUST verify before execution"
		;;
	high)
		echo "verification: recommended"
		echo "action: Verify unless explicitly skipped"
		;;
	standard)
		echo "verification: optional"
		echo "action: Verify on request only"
		;;
	esac

	return 0
}

# config — View or update verification configuration.
cmd_config() {
	local action="show"
	local key="" value=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--show)
			action="show"
			shift
			;;
		--set)
			action="set"
			if [[ "${2:-}" == *=* ]]; then
				key="${2%%=*}"
				value="${2#*=}"
				shift 2
			else
				print_error "Usage: --set KEY=VALUE"
				return 1
			fi
			;;
		--reset)
			action="reset"
			shift
			;;
		*)
			shift
			;;
		esac
	done

	case "$action" in
	show)
		if [[ -f "$VERIFY_CONFIG" ]]; then
			if command -v jq &>/dev/null; then
				jq '.' "$VERIFY_CONFIG"
			else
				cat "$VERIFY_CONFIG"
			fi
		else
			echo "No configuration file found. Using defaults."
			echo ""
			echo "Defaults:"
			echo "  verify_critical: true"
			echo "  verify_high: true"
			echo "  verify_standard: false"
			echo "  preferred_verifier: auto"
			echo "  max_prompt_tokens: ${MAX_PROMPT_TOKENS}"
			echo "  max_output_tokens: ${MAX_OUTPUT_TOKENS}"
			echo ""
			echo "Config path: ${VERIFY_CONFIG}"
		fi
		;;
	set)
		mkdir -p "$VERIFY_CONFIG_DIR" 2>/dev/null || true
		if [[ ! -f "$VERIFY_CONFIG" ]]; then
			echo '{"verify_critical":true,"verify_high":true,"verify_standard":false,"preferred_verifier":"auto"}' >"$VERIFY_CONFIG"
		fi
		if command -v jq &>/dev/null; then
			local tmp
			tmp=$(mktemp)
			trap 'rm -f "${tmp:-}"' RETURN
			jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$VERIFY_CONFIG" >"$tmp" && mv "$tmp" "$VERIFY_CONFIG"
			print_success "Set ${key}=${value}"
		else
			print_error "jq required for config updates"
			return 1
		fi
		;;
	reset)
		mkdir -p "$VERIFY_CONFIG_DIR" 2>/dev/null || true
		echo '{"verify_critical":true,"verify_high":true,"verify_standard":false,"preferred_verifier":"auto"}' >"$VERIFY_CONFIG"
		print_success "Configuration reset to defaults"
		;;
	esac

	return 0
}

# help — Show usage information.
cmd_help() {
	cat <<'HELP'
verify-operation-helper.sh — Cross-provider verification for high-stakes operations

Commands:
  verify    Verify an operation before execution
  check     Check if an operation needs verification (dry run)
  config    View or update verification configuration
  help      Show this help message

verify options:
  --operation TEXT     The operation/command to verify (required)
  --type TYPE         Operation type (e.g., git_force_push, db_migration)
  --risk-tier TIER    Risk tier: critical, high, standard (auto-detected if omitted)
  --repo SLUG         Repository slug (owner/repo)
  --branch NAME       Branch name
  --details TEXT      Additional context for the verifier
  --primary-model ID  Model that proposed the operation (provider detection)
  --session ID        Session identifier (traceability)
  --skip REASON       Skip verification with a logged reason

check options:
  --operation TEXT     The operation to classify (required)

config options:
  --show              Show current configuration (default)
  --set KEY=VALUE     Set a configuration value
  --reset             Reset configuration to defaults

Environment:
  AIDEVOPS_SKIP_VERIFY=1    Skip all verification (not recommended)

Exit codes:
  0  Verification passed (proceed/warn) or skipped
  1  Verification blocked or error

Examples:
  # Verify a force push
  verify-operation-helper.sh verify \
    --operation "git push --force origin main" \
    --repo "owner/repo" --branch "main"

  # Check if an operation needs verification
  verify-operation-helper.sh check --operation "git push origin feature/foo"

  # View configuration
  verify-operation-helper.sh config --show
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	verify) cmd_verify "$@" ;;
	check) cmd_check "$@" ;;
	config) cmd_config "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
