#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# OAuth Pool Helper -- Account Management Sub-Library
# =============================================================================
# Provides pool management commands:
#   check     — health-check all accounts (token expiry + live validity)
#   list      — list accounts with per-account status
#   remove    — remove an account from the pool
#   rotate    — switch to next available account
#   refresh   — exchange refresh tokens for new access tokens
#   reset-cooldowns — clear rate-limit cooldowns
#   set-priority    — set rotation preference for an account
#   mark-failure    — mark current account failure for headless auto-rotation
#   status    — pool aggregate stats per provider
#   assign-pending  — assign a stranded pending token to a named account
#   import    — import account from Claude CLI auth
#
# Usage: source "${SCRIPT_DIR}/oauth-pool-manage.sh"
#
# Dependencies:
#   - oauth-pool-helper.sh must be sourced first (provides POOL_FILE, POOL_OPS,
#     USER_AGENT, provider constants, and core helper functions)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_OAUTH_POOL_MANAGE_LOADED:-}" ]] && return 0
_OAUTH_POOL_MANAGE_LOADED=1

# SCRIPT_DIR fallback — for defensive portability (sub-library may be sourced
# by test harnesses that don't pre-set SCRIPT_DIR).
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ---------------------------------------------------------------------------
# Check accounts — helpers
# ---------------------------------------------------------------------------

# Print formatted details for all accounts of a provider (stdin = pool JSON).
# Tests live token validity for anthropic and google via urllib (in-process).
# Usage: printf '%s' "$pool" | _check_print_provider_accounts "$prov" "$now_ms" "$ua"
# Print token expiry line for a single account.
# Args: expires_in (ms, may be negative)
_check_print_token_expiry() {
	local expires_in="$1"
	EXPIRES_IN="$expires_in" python3 "$POOL_OPS" check-expiry
	return 0
}

# Print status, cooldown, last-used, and refresh-token presence for one account.
# Reads account JSON from stdin; NOW_MS env var required.
_check_print_account_meta() {
	local now_ms="$1"
	NOW_MS="$now_ms" python3 "$POOL_OPS" check-meta
	return 0
}

# Perform a live HTTP validity check for a single token.
# Args: provider, expires_in (ms), access_token, user_agent
_check_validate_token() {
	local prov="$1"
	local expires_in="$2"
	local token="$3"
	local ua="$4"
	PROV="$prov" EXPIRES_IN="$expires_in" TOKEN="$token" UA="$ua" \
		python3 "$POOL_OPS" check-validate 2>/dev/null
	return 0
}

# Iterate all accounts for a provider and print a health summary.
# Pool JSON is read from stdin; args: provider, now_ms, user_agent.
_check_print_provider_accounts() {
	local prov="$1"
	local now_ms="$2"
	local ua="$3"
	local tmp_records
	tmp_records=$(mktemp)
	# Emit one JSON record per account (newline-delimited) to a temp file.
	NOW_MS="$now_ms" PROV="$prov" python3 "$POOL_OPS" check-accounts 2>/dev/null >"$tmp_records"
	while IFS= read -r record; do
		local email expires_in acc_json token
		email=$(printf '%s' "$record" | python3 -c "import sys,json; print(json.load(sys.stdin)['email'])" 2>/dev/null)
		expires_in=$(printf '%s' "$record" | python3 -c "import sys,json; print(json.load(sys.stdin)['expires_in'])" 2>/dev/null)
		acc_json=$(printf '%s' "$record" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['account']))" 2>/dev/null)
		token=$(printf '%s' "$acc_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access',''))" 2>/dev/null)
		printf '  %s:\n' "$email"
		_check_print_token_expiry "$expires_in"
		printf '%s' "$acc_json" | _check_print_account_meta "$now_ms"
		_check_validate_token "$prov" "$expires_in" "$token" "$ua"
	done <"$tmp_records"
	rm -f "$tmp_records"
	return 0
}

# ---------------------------------------------------------------------------
# Check accounts
# ---------------------------------------------------------------------------

cmd_check() {
	local provider="${1:-all}"

	# Validate provider to prevent injection into python3 inline code
	case "$provider" in
	all | anthropic | openai | cursor | google) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, google, all)"
		return 1
		;;
	esac

	# Auto-clear expired cooldowns before reporting
	auto_clear_expired_cooldowns

	local pool
	pool=$(load_pool)

	local normalized updated
	normalized=$(printf '%s' "$pool" | normalize_expired_cooldowns "$provider")
	updated=$(printf '%s' "$normalized" | jq -r '.updated // 0')
	pool=$(printf '%s' "$normalized" | jq -c '.pool')
	if [[ "$updated" != "0" ]]; then
		save_pool "$pool"
		print_info "Auto-cleared ${updated} expired cooldown(s)."
	fi

	local -a providers_to_check
	if [[ "$provider" == "all" ]]; then
		providers_to_check=(anthropic openai cursor google)
	else
		providers_to_check=("$provider")
	fi

	local found_any="false"
	local now_ms
	now_ms=$(get_now_ms)

	for prov in "${providers_to_check[@]}"; do
		local count
		count=$(printf '%s' "$pool" | count_provider_accounts "$prov")
		if [[ "$count" == "0" ]]; then
			continue
		fi
		found_any="true"

		printf '\n## %s (%s account%s)\n' "$prov" "$count" "$([ "$count" = "1" ] && echo "" || echo "s")"
		printf '%s' "$pool" | _check_print_provider_accounts "$prov" "$now_ms" "$USER_AGENT"
		printf '  Token endpoint: OK\n'
	done

	if [[ "$found_any" == "false" ]]; then
		print_info "No accounts in any pool."
		echo ""
		echo "To add an account:"
		echo "  oauth-pool-helper.sh add anthropic    # Claude Pro/Max"
		echo "  oauth-pool-helper.sh add openai       # ChatGPT Plus/Pro (device flow default)"
		echo "  oauth-pool-helper.sh add cursor       # Cursor Pro (reads from IDE)"
		echo "  oauth-pool-helper.sh add google       # Google AI Pro/Ultra/Workspace"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# List accounts
# ---------------------------------------------------------------------------

cmd_list() {
	local provider="${1:-all}"

	case "$provider" in
	all | anthropic | openai | cursor | google) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, google, all)"
		return 1
		;;
	esac

	# Auto-clear expired cooldowns before reporting
	auto_clear_expired_cooldowns

	local pool
	pool=$(load_pool)

	local normalized updated
	normalized=$(printf '%s' "$pool" | normalize_expired_cooldowns "$provider")
	updated=$(printf '%s' "$normalized" | jq -r '.updated // 0')
	pool=$(printf '%s' "$normalized" | jq -c '.pool')
	if [[ "$updated" != "0" ]]; then
		save_pool "$pool"
		print_info "Auto-cleared ${updated} expired cooldown(s)."
	fi

	local -a providers_to_list
	if [[ "$provider" == "all" ]]; then
		providers_to_list=(anthropic openai cursor google)
	else
		providers_to_list=("$provider")
	fi

	for prov in "${providers_to_list[@]}"; do
		local count
		count=$(printf '%s' "$pool" | count_provider_accounts "$prov")
		if [[ "$count" == "0" ]]; then
			continue
		fi

		printf '%s (%s account%s):\n' "$prov" "$count" "$([ "$count" = "1" ] && echo "" || echo "s")"
		printf '%s' "$pool" | PROVIDER="$prov" python3 "$POOL_OPS" list-accounts
	done
	return 0
}

# ---------------------------------------------------------------------------
# Remove account
# ---------------------------------------------------------------------------

cmd_remove() {
	local provider="${1:-}"
	local email="${2:-}"

	if [[ -z "$provider" || -z "$email" ]]; then
		print_error "Usage: oauth-pool-helper.sh remove <provider> <email>"
		return 1
	fi

	local pool
	pool=$(load_pool)

	local new_pool
	new_pool=$(printf '%s' "$pool" | PROVIDER="$provider" EMAIL="$email" \
		python3 "$POOL_OPS" remove-account) || {
		print_error "Account ${email} not found in ${provider} pool"
		return 1
	}

	save_pool "$new_pool"
	print_success "Removed ${email} from ${provider} pool"
	return 0
}

# ---------------------------------------------------------------------------
# Rotate active account — helpers
# ---------------------------------------------------------------------------

# Core rotation logic: find next account, auto-refresh if expired, write
# auth.json and pool atomically under an advisory lock.
# All token handling stays in-process — no secrets on argv or stdout.
# Prints three lines to stdout: status (OK|ERROR:*), prev_email, next_email.
# Prints REFRESHED or REFRESH_FAILED:* to stderr (informational only).
_rotate_execute() {
	local provider="$1"
	POOL_FILE_PATH="$POOL_FILE" AUTH_FILE_PATH="$OPENCODE_AUTH_FILE" \
		PROVIDER="$provider" UA_HEADER="$USER_AGENT" \
		python3 "$POOL_OPS" rotate
	return 0
}

# Parse the result lines from _rotate_execute and emit user-facing messages.
# Returns 0 on success, 1 on error.
_rotate_parse_result() {
	local result="$1"
	local provider="$2"
	local first_line
	first_line=$(printf '%s\n' "$result" | sed -n '1p')
	case "$first_line" in
	ERROR:need_accounts)
		print_error "Cannot rotate: need at least 2 accounts in ${provider} pool"
		return 1
		;;
	ERROR:no_alternate)
		print_error "No alternate account available for ${provider} (all others may be in cooldown)"
		return 1
		;;
	OK_COOLDOWN:*)
		local wait_mins prev_email next_email
		wait_mins="${first_line#OK_COOLDOWN:}"
		prev_email=$(printf '%s\n' "$result" | sed -n '2p')
		next_email=$(printf '%s\n' "$result" | sed -n '3p')
		print_warning "All ${provider} accounts are rate-limited"
		if [[ "$prev_email" == "$next_email" ]]; then
			print_info "Staying on ${next_email} (shortest cooldown: ~${wait_mins}m remaining)"
		else
			print_info "Switched to ${next_email} (shortest cooldown: ~${wait_mins}m remaining)"
		fi
		return 0
		;;
	OK)
		local prev_email next_email
		prev_email=$(printf '%s\n' "$result" | sed -n '2p')
		next_email=$(printf '%s\n' "$result" | sed -n '3p')
		print_success "Rotated ${provider}: ${prev_email} -> ${next_email}"
		print_info "Restart OpenCode sessions to pick up the new credentials."
		return 0
		;;
	*)
		print_error "Unexpected result from rotation"
		return 1
		;;
	esac
}

# ---------------------------------------------------------------------------
# Rotate active account
# ---------------------------------------------------------------------------

cmd_rotate() {
	local provider="${1:-anthropic}"

	case "$provider" in
	anthropic | openai | cursor | google) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, google)"
		return 1
		;;
	esac

	# Auto-clear expired cooldowns so rotate sees all available accounts
	auto_clear_expired_cooldowns

	local pool
	pool=$(load_pool)

	local account_count
	account_count=$(printf '%s' "$pool" | count_provider_accounts "$provider")

	if [[ "$account_count" -lt 2 ]]; then
		print_error "Cannot rotate: only ${account_count} account(s) in ${provider} pool. Need at least 2."
		print_info "Add more accounts: oauth-pool-helper.sh add ${provider}"
		return 1
	fi

	if [[ ! -f "$OPENCODE_AUTH_FILE" ]]; then
		print_error "OpenCode auth file not found: ${OPENCODE_AUTH_FILE}"
		print_info "Is OpenCode installed? The auth file is created on first login."
		return 1
	fi

	local result py_stderr_file
	py_stderr_file=$(mktemp "${TMPDIR:-/tmp}/oauth-rotate-err.XXXXXX")
	result=$(_rotate_execute "$provider" 2>"$py_stderr_file") || {
		local py_err
		py_err=$(cat "$py_stderr_file" 2>/dev/null)
		rm -f "$py_stderr_file"
		print_error "Rotation failed — python3 error"
		if [[ -n "${py_err:-}" ]]; then
			print_error "Detail: ${py_err}"
		fi
		return 1
	}
	rm -f "$py_stderr_file"

	_rotate_parse_result "$result" "$provider"
	return $?
}

# ---------------------------------------------------------------------------
# Refresh — exchange refresh tokens for new access tokens
# ---------------------------------------------------------------------------

OAUTH_REFRESH_FAILURE_SUPPRESSION_WINDOW_SECONDS="${OAUTH_REFRESH_FAILURE_SUPPRESSION_WINDOW_SECONDS:-900}"

_refresh_failure_state_dir() {
	printf '%s/oauth-refresh-failures\n' "${AIDEVOPS_CACHE_DIR:-${HOME}/.aidevops/cache}"
	return 0
}

_refresh_failure_state_name() {
	local provider="$1"
	local detail="$2"
	local safe_detail
	safe_detail=$(printf '%s' "$detail" | tr -c '[:alnum:].@_-' '_')
	printf '%s-%s.state\n' "$provider" "$safe_detail"
	return 0
}

# Print "new" for the first occurrence in the window and "repeat" after it.
# State contains only an epoch and repeat count; refresh tokens never enter it.
_refresh_failure_state_record() {
	local provider="$1"
	local detail="$2"
	local state_dir state_file now_epoch previous_epoch repeat_count state_line temp_file
	state_dir=$(_refresh_failure_state_dir)
	state_file="${state_dir}/$(_refresh_failure_state_name "$provider" "$detail")"
	now_epoch=$(date +%s)
	previous_epoch=0
	repeat_count=0

	if ! mkdir -p "$state_dir" || ! chmod 700 "$state_dir"; then
		printf 'new\n'
		return 0
	fi
	if [[ -f "$state_file" ]]; then
		state_line=$(<"$state_file")
		IFS='|' read -r previous_epoch repeat_count <<<"$state_line"
		[[ "$previous_epoch" =~ ^[0-9]+$ ]] || previous_epoch=0
		[[ "$repeat_count" =~ ^[0-9]+$ ]] || repeat_count=0
	fi

	if ((now_epoch - previous_epoch < OAUTH_REFRESH_FAILURE_SUPPRESSION_WINDOW_SECONDS)); then
		repeat_count=$((repeat_count + 1))
		temp_file=$(mktemp "${state_dir}/.refresh-failure.XXXXXX") || {
			printf 'new\n'
			return 0
		}
		printf '%s|%s\n' "$previous_epoch" "$repeat_count" >"$temp_file" && mv -f "$temp_file" "$state_file" || rm -f "$temp_file"
		printf 'repeat\n'
		return 0
	fi

	temp_file=$(mktemp "${state_dir}/.refresh-failure.XXXXXX") || {
		printf 'new\n'
		return 0
	}
	printf '%s|0\n' "$now_epoch" >"$temp_file" && mv -f "$temp_file" "$state_file" || rm -f "$temp_file"
	printf 'new\n'
	return 0
}

# Clear every failure class for a recovered account and print its suppressed count.
_refresh_failure_state_clear() {
	local provider="$1"
	local email="$2"
	local state_dir state_file state_line repeat_count total=0 safe_email
	state_dir=$(_refresh_failure_state_dir)
	safe_email=$(printf '%s' "$email" | tr -c '[:alnum:].@_-' '_')
	[[ -d "$state_dir" ]] || {
		printf '0\n'
		return 0
	}

	for state_file in "${state_dir}/${provider}-${safe_email}"*.state; do
		[[ -f "$state_file" ]] || continue
		state_line=$(<"$state_file")
		IFS='|' read -r _ repeat_count <<<"$state_line"
		[[ "$repeat_count" =~ ^[0-9]+$ ]] || repeat_count=0
		total=$((total + repeat_count))
		rm -f "$state_file"
	done
	printf '%s\n' "$total"
	return 0
}

cmd_refresh() {
	local provider="${1:-anthropic}"
	local target_email="${2:-all}"

	case "$provider" in
	anthropic | openai | google) ;;
	cursor)
		print_info "Cursor tokens are long-lived and don't use refresh flow"
		return 0
		;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, google)"
		return 1
		;;
	esac

	local pool
	pool=$(load_pool)

	# Refresh expired accounts that have refresh tokens
	local result
	result=$(POOL_FILE_PATH="$POOL_FILE" AUTH_FILE_PATH="$OPENCODE_AUTH_FILE" \
		PROVIDER="$provider" TARGET_EMAIL="$target_email" \
		UA_HEADER="$USER_AGENT" python3 "$POOL_OPS" refresh 2>/dev/null) || {
		print_error "Refresh failed — python3 error"
		return 1
	}

	# Parse results
	local had_refresh=false
	local had_failure=false
	local had_any_failure=false
	while IFS= read -r line; do
		case "$line" in
		REFRESHED:*)
			had_refresh=true
			local email suppressed_count
			email="${line#REFRESHED:}"
			suppressed_count=$(_refresh_failure_state_clear "$provider" "$email")
			print_success "Refreshed ${provider} token for ${email}"
			if ((suppressed_count > 0)); then
				print_info "Refresh recovered for ${email} after ${suppressed_count} suppressed repeated failure(s)"
			fi
			;;
		FAILED:*)
			local detail failure_state
			had_any_failure=true
			detail="${line#FAILED:}"
			failure_state=$(_refresh_failure_state_record "$provider" "$detail")
			if [[ "$failure_state" == "new" ]]; then
				had_failure=true
				print_error "Failed to refresh: ${detail}"
			fi
			;;
		NONE)
			print_info "No ${provider} accounts need refreshing"
			;;
		ERROR:no_endpoint)
			print_error "No token endpoint for provider: ${provider}"
			return 1
			;;
		esac
	done <<<"$result"

	if [[ "$had_refresh" == "true" ]]; then
		print_info "Restart OpenCode sessions to pick up refreshed credentials."
	fi
	if [[ "$had_failure" == "true" ]]; then
		print_warning "Some accounts failed to refresh — may need re-auth via: oauth-pool-helper.sh add ${provider}"
		return 2
	fi
	if [[ "$had_any_failure" == "true" ]]; then
		return 2
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Reset cooldowns — clear rate-limit cooldowns so all accounts are retried
# ---------------------------------------------------------------------------

cmd_reset_cooldowns() {
	local provider="${1:-all}"

	case "$provider" in
	all | anthropic | openai | cursor | google) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, google, all)"
		return 1
		;;
	esac

	local pool
	pool=$(load_pool)

	local result
	result=$(printf '%s' "$pool" | PROVIDER="$provider" python3 "$POOL_OPS" reset-cooldowns)

	local cleared new_pool
	cleared=$(printf '%s' "$result" | jq -r '.cleared')
	new_pool=$(printf '%s' "$result" | jq -c '.pool')

	save_pool "$new_pool"

	if [[ "$cleared" == "0" ]]; then
		print_info "No cooldowns to clear — all accounts already active."
	else
		print_success "Cleared cooldowns on ${cleared} account(s). All accounts set to idle."
	fi
	print_info "Restart OpenCode to pick up the reset state."
	return 0
}

# ---------------------------------------------------------------------------
# Set priority — set the priority field on an account
# ---------------------------------------------------------------------------

cmd_set_priority() {
	local provider="${1:-}"
	local email="${2:-}"
	local priority="${3:-}"

	if [[ -z "$provider" || -z "$email" || -z "$priority" ]]; then
		print_error "Usage: oauth-pool-helper.sh set-priority <provider> <email> <N>"
		print_info "  N is an integer; higher values are preferred during rotation."
		print_info "  Example: oauth-pool-helper.sh set-priority anthropic work@example.com 10"
		return 1
	fi

	case "$provider" in
	anthropic | openai | cursor | google) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, google)"
		return 1
		;;
	esac

	if ! [[ "$priority" =~ ^-?[0-9]+$ ]]; then
		print_error "Priority must be an integer (e.g. 0, 5, 10)"
		return 1
	fi

	local pool
	pool=$(load_pool)

	local new_pool
	new_pool=$(printf '%s' "$pool" | PROVIDER="$provider" EMAIL="$email" PRIORITY="$priority" \
		python3 "$POOL_OPS" set-priority 2>/dev/null)

	case "$new_pool" in
	ERROR:not_found)
		print_error "Account ${email} not found in ${provider} pool"
		print_info "Run 'oauth-pool-helper.sh list ${provider}' to see existing accounts"
		return 1
		;;
	esac

	save_pool "$new_pool"
	if [[ "$priority" == "0" ]]; then
		print_success "Cleared priority for ${email} in ${provider} pool (defaults to 0)"
	else
		print_success "Set priority ${priority} for ${email} in ${provider} pool"
	fi
	print_info "Higher priority accounts are preferred during rotation."
	return 0
}

# ---------------------------------------------------------------------------
# Mark current account failure state (for headless auto-rotation)
# ---------------------------------------------------------------------------

cmd_mark_failure() {
	local provider="${1:-}"
	local reason="${2:-rate_limit}"
	local retry_seconds="${3:-900}"

	case "$provider" in
	anthropic | openai | cursor | google) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, google)"
		return 1
		;;
	esac

	case "$reason" in
	rate_limit | auth_error | provider_error) ;;
	*)
		print_error "Invalid reason: $reason (valid: rate_limit, auth_error, provider_error)"
		return 1
		;;
	esac

	if [[ ! "$retry_seconds" =~ ^[0-9]+$ ]]; then
		print_error "retry_seconds must be an integer"
		return 1
	fi

	if [[ ! -f "$POOL_FILE" || ! -f "$OPENCODE_AUTH_FILE" ]]; then
		print_warning "Pool/auth file missing; skipping account failure mark"
		return 0
	fi

	local mark_result
	mark_result=$(POOL_FILE_PATH="$POOL_FILE" AUTH_FILE_PATH="$OPENCODE_AUTH_FILE" \
		PROVIDER="$provider" REASON="$reason" RETRY_SECONDS="$retry_seconds" \
		python3 "$POOL_OPS" mark-failure 2>/dev/null) || {
		print_warning "Failed to mark account failure state for ${provider}"
		return 1
	}

	case "$mark_result" in
	OK:*)
		print_info "Marked current ${provider} account as ${reason}"
		return 0
		;;
	SKIP:*)
		print_warning "No ${provider} accounts available to mark"
		return 0
		;;
	*)
		print_warning "Unexpected mark-failure result: ${mark_result}"
		return 1
		;;
	esac
}

# ---------------------------------------------------------------------------
# Status — pool aggregate stats per provider (distinct from list)
# ---------------------------------------------------------------------------

cmd_status() {
	local provider="${1:-all}"

	case "$provider" in
	all | anthropic | openai | cursor | google) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, google, all)"
		return 1
		;;
	esac

	# Auto-clear expired cooldowns before reporting
	auto_clear_expired_cooldowns

	local pool
	pool=$(load_pool)

	local normalized updated
	normalized=$(printf '%s' "$pool" | normalize_expired_cooldowns "$provider")
	updated=$(printf '%s' "$normalized" | jq -r '.updated // 0')
	pool=$(printf '%s' "$normalized" | jq -c '.pool')
	if [[ "$updated" != "0" ]]; then
		save_pool "$pool"
		print_info "Auto-cleared ${updated} expired cooldown(s)."
	fi

	local now_ms
	now_ms=$(python3 -c "import time; print(int(time.time() * 1000))")

	local -a providers_to_check
	if [[ "$provider" == "all" ]]; then
		providers_to_check=(anthropic openai cursor google)
	else
		providers_to_check=("$provider")
	fi

	local found_any="false"

	for prov in "${providers_to_check[@]}"; do
		local count
		count=$(printf '%s' "$pool" | count_provider_accounts "$prov")
		[[ "$count" == "0" ]] && continue
		found_any="true"

		printf '%s' "$pool" | NOW_MS="$now_ms" PROV="$prov" python3 "$POOL_OPS" status-stats 2>/dev/null
	done

	if [[ "$found_any" == "false" ]]; then
		print_info "No accounts in any pool."
		echo ""
		echo "Add an account:"
		echo "  aidevops model-accounts-pool add anthropic    # Claude Pro/Max"
		echo "  aidevops model-accounts-pool add openai       # ChatGPT Plus/Pro (device flow default)"
		echo "  aidevops model-accounts-pool add cursor       # Cursor Pro"
		echo "  aidevops model-accounts-pool add google       # Google AI Pro/Ultra/Workspace"
		echo "  aidevops model-accounts-pool import claude-cli"
	fi

	printf 'Pool file: %s\n' "$POOL_FILE"
	return 0
}

# ---------------------------------------------------------------------------
# Assign pending — assign a stranded _pending_ token to a named account
# ---------------------------------------------------------------------------

cmd_assign_pending() {
	local provider="${1:-anthropic}"
	local email="${2:-}"

	case "$provider" in
	anthropic | openai | cursor | google) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, google)"
		return 1
		;;
	esac

	local pool
	pool=$(load_pool)

	# Check whether a pending token exists for this provider
	local pending_info
	pending_info=$(printf '%s' "$pool" | PROVIDER="$provider" python3 "$POOL_OPS" check-pending 2>/dev/null)

	if [[ "$pending_info" == "NONE" ]]; then
		print_info "No pending token for ${provider}."
		print_info "Pending tokens are created when OAuth completes but the email cannot be identified."
		print_info "If you recently re-authenticated and it didn't take effect, try:"
		print_info "  aidevops model-accounts-pool add ${provider}"
		return 0
	fi

	local pending_added
	pending_added=$(printf '%s' "$pending_info" | cut -d: -f2-)

	if [[ -z "$email" ]]; then
		print_info "Pending ${provider} token found (added: ${pending_added})"
		print_info "Existing accounts to assign to:"
		printf '%s' "$pool" | PROVIDER="$provider" python3 "$POOL_OPS" list-pending 2>/dev/null
		echo ""
		echo "Usage: aidevops model-accounts-pool assign-pending ${provider} <email>"
		return 0
	fi

	local new_pool
	new_pool=$(printf '%s' "$pool" | PROVIDER="$provider" EMAIL="$email" \
		python3 "$POOL_OPS" assign-pending 2>/dev/null)

	case "$new_pool" in
	ERROR:no_pending)
		print_error "No pending token for ${provider}"
		return 1
		;;
	ERROR:not_found)
		print_error "Account ${email} not found in ${provider} pool"
		print_info "Run 'aidevops model-accounts-pool list' to see existing accounts"
		return 1
		;;
	esac

	save_pool "$new_pool"
	print_success "Assigned pending token to ${email} in ${provider} pool — account is now active."
	print_info "Restart OpenCode to pick up the new credentials."
	return 0
}

# ---------------------------------------------------------------------------
# Import from Claude CLI
# ---------------------------------------------------------------------------

cmd_import() {
	local source="${1:-claude-cli}"

	if [[ "$source" != "claude-cli" ]]; then
		print_error "Unsupported import source: $source (supported: claude-cli)"
		return 1
	fi

	# Check if claude CLI is installed
	if ! command -v claude &>/dev/null; then
		print_error "Claude CLI not found in PATH"
		print_info "Install it from https://claude.ai/code or run: npm install -g @anthropic-ai/claude-code"
		return 1
	fi

	# Get auth status from Claude CLI
	print_info "Checking Claude CLI auth status..."
	local auth_json
	auth_json=$(claude auth status --json 2>/dev/null) || {
		print_error "Failed to get Claude CLI auth status"
		print_info "Run 'claude auth login' first to authenticate the CLI"
		return 1
	}

	# Parse auth status (use env vars to avoid secrets on argv)
	local logged_in email sub_type
	logged_in=$(printf '%s' "$auth_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('loggedIn', False))" 2>/dev/null)
	email=$(printf '%s' "$auth_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('email', ''))" 2>/dev/null)
	sub_type=$(printf '%s' "$auth_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('subscriptionType', ''))" 2>/dev/null)

	if [[ "$logged_in" != "True" ]]; then
		print_error "Claude CLI is not logged in"
		print_info "Run 'claude auth login' first, then retry this import"
		return 1
	fi

	if [[ -z "$email" || "$email" == "None" ]]; then
		print_error "Could not determine email from Claude CLI auth"
		return 1
	fi

	if [[ "$sub_type" != "pro" && "$sub_type" != "max" ]]; then
		print_warning "Claude CLI subscription type is '${sub_type}' (expected 'pro' or 'max')"
		print_info "OAuth pool models require a Claude Pro or Max subscription"
		printf 'Continue anyway? [y/N] ' >&2
		local confirm
		read -r confirm
		if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
			print_info "Aborted"
			return 0
		fi
	fi

	# Check if this email already exists in the anthropic pool
	local pool
	pool=$(load_pool)
	local already_exists
	already_exists=$(printf '%s' "$pool" | EMAIL="$email" python3 "$POOL_OPS" import-check 2>/dev/null)

	if [[ "$already_exists" == "yes" ]]; then
		print_info "Account ${email} already exists in the Anthropic pool"
		print_info "Use 'oauth-pool-helper.sh check anthropic' to verify token health"
		return 0
	fi

	# Account not in pool — guide user through OAuth to add it
	print_success "Found Claude ${sub_type} account: ${email}"
	print_info "Adding to Anthropic OAuth pool..."
	print_info ""
	print_info "This will open your browser to authorize the same account."
	print_info "Since you're already logged in to claude.ai, it should be quick."
	print_info ""

	# Run the standard add flow with the email pre-filled
	cmd_add "anthropic" "$email"
	return $?
}
