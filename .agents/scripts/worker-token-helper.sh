#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# worker-token-helper.sh — Scoped, short-lived GitHub tokens for worker agents
# Commands: create | validate | revoke | status | help
#
# Creates minimal-permission GitHub tokens for headless worker sessions.
# Each worker gets a token scoped to the target repo with only the permissions
# needed for its task (contents:write, pull_requests:write, issues:write).
#
# Token strategies (in priority order):
#   1. GitHub App installation token (repo-scoped, 1h TTL, enforced by GitHub)
#   2. Fine-grained PAT delegation (if user has configured a base token)
#   3. Fallback: existing gh auth token passed via env (advisory scoping only)
#
# Usage:
#   worker-token-helper.sh create --repo owner/repo [--ttl 3600] [--permissions contents:write,pull_requests:write]
#   worker-token-helper.sh validate --token-file /path/to/token
#   worker-token-helper.sh revoke --token-file /path/to/token
#   worker-token-helper.sh status
#   worker-token-helper.sh help
#
# Integration:
#   Called by dispatch.sh / cron-dispatch.sh before spawning a worker.
#   Token is written to a private file and exposed to Git only through AskPass.
#   Token file is cleaned up after worker exits.
#
# Part of t1412.2: Worker sandboxing — credential isolation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail

LOG_PREFIX="WORKER-TOKEN"

# =============================================================================
# Constants
# =============================================================================

readonly TOKEN_DIR="${HOME}/.aidevops/.agent-workspace/tokens"
readonly TOKEN_LOG="${TOKEN_DIR}/token-audit.jsonl"
readonly DEFAULT_TTL=3600 # 1 hour
readonly MAX_TTL=7200     # 2 hours hard cap
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/aidevops"
readonly GITHUB_ACCEPT_HEADER="Accept: application/vnd.github+json"
readonly TOKEN_STRATEGY_DELEGATED="delegated"
readonly APP_CONFIG="${CONFIG_DIR}/github-app.json"

# Default permissions for worker tokens — minimal set for PR workflow
readonly DEFAULT_PERMISSIONS="contents:write,pull_requests:write,issues:write"

# =============================================================================
# Logging
# =============================================================================

log_token() {
	local level="$1"
	local msg="$2"
	printf '[%s] [%s] [%s] %s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOG_PREFIX" "$level" "$msg" >&2
	return 0
}

# Audit log — records token lifecycle events (never token values)
log_audit() {
	local event="$1"
	local repo="$2"
	local strategy="$3"
	local ttl="${4:-}"
	local token_id="${5:-}"
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	mkdir -p "$(dirname "$TOKEN_LOG")"

	printf '{"ts":"%s","event":"%s","repo":"%s","strategy":"%s","ttl":%s,"token_id":"%s","pid":%d}\n' \
		"$timestamp" \
		"$event" \
		"$repo" \
		"$strategy" \
		"${ttl:-0}" \
		"$token_id" \
		"$$" \
		>>"$TOKEN_LOG"
	return 0
}

# =============================================================================
# Token Strategy 1: GitHub App Installation Token
# =============================================================================
# Requires: GitHub App installed on the repo's org/account
# Config: ~/.config/aidevops/github-app.json
#   {
#     "app_id": "123456",
#     "private_key_path": "~/.config/aidevops/github-app-key.pem",
#     "installation_id": "12345678"
#   }
#
# Creates a scoped installation access token via:
#   POST /app/installations/{id}/access_tokens
# Token is repo-scoped, permission-scoped, and expires in 1h (GitHub enforced).

generate_jwt() {
	local app_id="$1"
	local key_path="$2"

	# JWT requires: iat (issued at), exp (expiry, max 10 min), iss (app ID)
	local now
	now=$(date +%s)
	local iat=$((now - 60))  # 60s clock skew allowance
	local exp=$((now + 300)) # 5 min expiry (plenty for token creation)

	local header
	header=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

	local payload
	payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$app_id" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

	local unsigned="${header}.${payload}"

	local signature
	signature=$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$key_path" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

	printf '%s.%s' "$unsigned" "$signature"
	return 0
}

# Build a JSON permissions object from a comma-separated "name:level" list.
# e.g., "contents:write,pull_requests:write" -> {"contents":"write","pull_requests":"write"}
# Arguments:
#   $1 - comma-separated permissions string
# Returns: JSON object string via stdout
_build_permissions_json() {
	local permissions="$1"
	local perms_json="{"
	local first=true
	local perm
	while IFS= read -r perm; do
		perm="${perm#"${perm%%[![:space:]]*}"}"
		perm="${perm%"${perm##*[![:space:]]}"}"
		[[ -z "$perm" ]] && continue
		if [[ "$perm" != *:* ]] || [[ "$perm" == :* ]] || [[ "$perm" == *: ]]; then
			log_token "ERROR" "Invalid permission entry: ${perm} (expected name:level)"
			return 1
		fi
		local perm_name="${perm%%:*}"
		local perm_level="${perm##*:}"
		if [[ "$first" == true ]]; then
			first=false
		else
			perms_json+=","
		fi
		perms_json+="\"${perm_name}\":\"${perm_level}\""
	done < <(printf '%s\n' "$permissions" | tr ',' '\n')
	if [[ "$first" == true ]]; then
		log_token "ERROR" "At least one valid permission is required"
		return 1
	fi
	perms_json+="}"
	printf '%s' "$perms_json"
	return 0
}

_curl_with_bearer() {
	local token="$1"
	shift
	[[ -n "$token" && "$token" != *$'\r'* && "$token" != *$'\n'* ]] || return 1
	printf 'Authorization: Bearer %s\n' "$token" | curl "$@" -H @-
	return $?
}

# Request a scoped installation access token from the GitHub App API.
# Arguments:
#   $1 - repo (owner/name)
#   $2 - jwt
#   $3 - installation_id
#   $4 - perms_json (JSON object)
#   $5 - ttl
# Returns: token_file path via stdout, or exits non-zero on failure
_request_app_token() {
	local repo="$1"
	local jwt="$2"
	local installation_id="$3"
	local perms_json="$4"
	local ttl="$5"
	local app_slug="$6"

	local repo_name="${repo##*/}"

	local request_body
	request_body=$(jq -n \
		--argjson permissions "$perms_json" \
		--arg repo "$repo_name" \
		'{
			repositories: [$repo],
			permissions: $permissions
		}')

	local response
	response=$(_curl_with_bearer "$jwt" -sf -X POST \
		"https://api.github.com/app/installations/${installation_id}/access_tokens" \
		-H "$GITHUB_ACCEPT_HEADER" \
		-H "X-GitHub-Api-Version: 2022-11-28" \
		-d "$request_body" 2>/dev/null) || {
		log_token "WARN" "GitHub App token creation failed (API error)"
		return 1
	}

	local token expires_at
	token=$(printf '%s' "$response" | jq -r '.token // empty')
	expires_at=$(printf '%s' "$response" | jq -r '.expires_at // empty')

	if [[ -z "$token" ]]; then
		log_token "WARN" "GitHub App token creation returned empty token"
		return 1
	fi

	local token_file
	token_file=$(create_token_file "$token" "$repo" "github-app" "$expires_at" "$app_slug") || {
		log_token "ERROR" "Failed to persist GitHub App token for ${repo}"
		return 1
	}

	if [[ -z "$token_file" ]] || [[ ! -f "$token_file" ]]; then
		log_token "ERROR" "Failed to create token file for GitHub App token (repo: ${repo})"
		return 1
	fi

	log_token "INFO" "Created GitHub App installation token for ${repo} (expires: ${expires_at})"
	log_audit "create" "$repo" "github-app" "$ttl" "app-${installation_id}"

	printf '%s' "$token_file"
	return 0
}

_resolve_app_slug() {
	local jwt="$1"
	local configured_slug=""
	configured_slug=$(jq -r '.app_slug // .slug // empty' "$APP_CONFIG" 2>/dev/null || true)
	if [[ -n "$configured_slug" ]]; then
		[[ "$configured_slug" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || return 1
		printf '%s' "$configured_slug"
		return 0
	fi
	local app_json="" app_slug=""
	app_json=$(_curl_with_bearer "$jwt" -sf "https://api.github.com/app" \
		-H "$GITHUB_ACCEPT_HEADER" \
		-H "X-GitHub-Api-Version: 2022-11-28" 2>/dev/null) || return 1
	app_slug=$(printf '%s' "$app_json" | jq -r '.slug // empty')
	[[ "$app_slug" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || return 1
	printf '%s' "$app_slug"
	return 0
}

create_app_token() {
	local repo="$1"
	local permissions="$2"
	local ttl="$3"

	# Check if GitHub App is configured
	if [[ ! -f "$APP_CONFIG" ]]; then
		log_token "DEBUG" "No GitHub App config at ${APP_CONFIG}"
		return 1
	fi

	local app_id private_key_path installation_id
	app_id=$(jq -r '.app_id // empty' "$APP_CONFIG" 2>/dev/null)
	private_key_path=$(jq -r '.private_key_path // empty' "$APP_CONFIG" 2>/dev/null)
	installation_id=$(jq -r '.installation_id // empty' "$APP_CONFIG" 2>/dev/null)

	# Expand ~ in key path
	private_key_path="${private_key_path/#\~/$HOME}"

	if [[ -z "$app_id" || -z "$private_key_path" || -z "$installation_id" ]]; then
		log_token "DEBUG" "GitHub App config incomplete (need app_id, private_key_path, installation_id)"
		return 1
	fi

	if [[ ! -f "$private_key_path" ]]; then
		log_token "WARN" "GitHub App private key not found: ${private_key_path}"
		return 1
	fi

	# Generate JWT for App authentication
	local jwt
	jwt=$(generate_jwt "$app_id" "$private_key_path")
	if [[ -z "$jwt" ]]; then
		log_token "ERROR" "Failed to generate JWT"
		return 1
	fi

	# Build permissions JSON and request the installation token
	local perms_json
	perms_json=$(_build_permissions_json "$permissions") || return 1
	local app_slug=""
	app_slug=$(_resolve_app_slug "$jwt") || {
		log_token "ERROR" "Failed to resolve GitHub App slug"
		return 1
	}

	_request_app_token "$repo" "$jwt" "$installation_id" "$perms_json" "$ttl" "$app_slug"
	return $?
}

# =============================================================================
# Token Strategy 2: Fine-Grained PAT Delegation
# =============================================================================
# Uses the GitHub API to check if the current token is a fine-grained PAT
# and if so, creates a scoped version. This is advisory — GitHub doesn't
# support creating new fine-grained PATs via API (only via web UI).
# Instead, we validate the existing token's scope and pass it through
# with documented restrictions.

create_delegated_token() {
	local repo="$1"
	local permissions="$2"
	local ttl="$3"

	# Get the current gh auth token
	local current_token
	current_token=$(gh auth token 2>/dev/null) || {
		log_token "WARN" "Cannot get current gh auth token"
		return 1
	}

	if [[ -z "$current_token" ]]; then
		log_token "WARN" "gh auth token returned empty"
		return 1
	fi

	# Check token type and scopes
	_curl_with_bearer "$current_token" -sf \
		"https://api.github.com/user" \
		-H "$GITHUB_ACCEPT_HEADER" \
		-D /dev/stderr >/dev/null 2>&1 || {
		log_token "WARN" "Cannot validate current token"
		return 1
	}

	# Check if the token has access to the target repo
	_curl_with_bearer "$current_token" -sf \
		"https://api.github.com/repos/${repo}" \
		-H "$GITHUB_ACCEPT_HEADER" >/dev/null 2>/dev/null || {
		log_token "WARN" "Current token cannot access repo ${repo}"
		return 1
	}

	# Token is valid and has repo access — create a scoped wrapper
	# Since we can't create a new fine-grained PAT via API, we pass the
	# existing token but with metadata tracking what it's scoped for.
	local expires_at
	expires_at=$(date -u -v+"${ttl}S" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "+${ttl} seconds" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u +"%Y-%m-%dT%H:%M:%SZ")

	local token_file
	token_file=$(create_token_file "$current_token" "$repo" "$TOKEN_STRATEGY_DELEGATED" "$expires_at")

	if [[ -z "$token_file" ]] || [[ ! -f "$token_file" ]]; then
		log_token "ERROR" "Failed to create token file for delegated token (repo: ${repo})"
		return 1
	fi

	log_token "INFO" "Created delegated token for ${repo} (advisory TTL: ${ttl}s)"
	log_audit "create" "$repo" "$TOKEN_STRATEGY_DELEGATED" "$ttl" "delegated-$$"

	printf '%s' "$token_file"
	return 0
}

# =============================================================================
# Token File Management
# =============================================================================

create_token_file() {
	local token="$1"
	local repo="$2"
	local strategy="$3"
	local expires_at="$4"
	local app_slug="${5:-}"

	mkdir -p "$TOKEN_DIR"
	[[ -d "$TOKEN_DIR" && ! -L "$TOKEN_DIR" ]] || return 1
	chmod 700 "$TOKEN_DIR"
	local token_dir_real="" token_dir_uid=""
	token_dir_real=$(realpath "$TOKEN_DIR" 2>/dev/null) || return 1
	token_dir_uid=$(_file_uid "$TOKEN_DIR") || return 1
	[[ "$token_dir_real" == "$TOKEN_DIR" && "$token_dir_uid" == "$(id -u)" ]] || return 1

	# Create a unique token file
	local token_id
	token_id="worker-$(date +%s)-$$"
	local token_file="${TOKEN_DIR}/${token_id}.token"
	local meta_file="${TOKEN_DIR}/${token_id}.meta"

	# Write token (value only, no metadata)
	printf '%s' "$token" >"$token_file"
	chmod 600 "$token_file"

	# Write metadata (no token value — safe to log/inspect).
	if ! jq -n \
		--arg token_id "$token_id" \
		--arg repo "$repo" \
		--arg strategy "$strategy" \
		--arg expires_at "$expires_at" \
		--arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg app_slug "$app_slug" \
		--argjson pid "$$" \
		'{token_id: $token_id, repo: $repo, strategy: $strategy,
		  expires_at: $expires_at, created_at: $created_at, pid: $pid}
		 + (if $app_slug == "" then {} else {app_slug: $app_slug} end)' >"$meta_file"; then
		rm -f "$token_file" "$meta_file"
		return 1
	fi
	chmod 600 "$meta_file"

	printf '%s' "$token_file"
	return 0
}

_file_uid() {
	local path="$1"
	stat -f '%u' "$path" 2>/dev/null || stat -c '%u' "$path" 2>/dev/null
	return $?
}

_validate_token_artifacts() {
	local token_file="$1"
	local token_dir_real="" token_real="" meta_file="" meta_real=""
	local expected_uid="" token_uid="" meta_uid="" dir_uid=""
	local token_mode="" meta_mode="" dir_mode=""

	[[ -d "$TOKEN_DIR" && ! -L "$TOKEN_DIR" ]] || return 1
	[[ -f "$token_file" && ! -L "$token_file" && "$token_file" == *.token ]] || return 1
	token_dir_real=$(realpath "$TOKEN_DIR" 2>/dev/null) || return 1
	token_real=$(realpath "$token_file" 2>/dev/null) || return 1
	[[ "$token_real" == "${token_dir_real}/"* && "$token_real" == "$token_file" ]] || return 1
	meta_file="${token_file%.token}.meta"
	[[ -f "$meta_file" && ! -L "$meta_file" ]] || return 1
	meta_real=$(realpath "$meta_file" 2>/dev/null) || return 1
	[[ "$meta_real" == "${token_dir_real}/"* && "$meta_real" == "$meta_file" ]] || return 1

	expected_uid=$(id -u)
	token_uid=$(_file_uid "$token_file") || return 1
	meta_uid=$(_file_uid "$meta_file") || return 1
	dir_uid=$(_file_uid "$TOKEN_DIR") || return 1
	token_mode=$(_file_perms "$token_file")
	meta_mode=$(_file_perms "$meta_file")
	dir_mode=$(_file_perms "$TOKEN_DIR")
	[[ "$token_uid" == "$expected_uid" && "$meta_uid" == "$expected_uid" && "$dir_uid" == "$expected_uid" ]] || return 1
	[[ "$token_mode" == "600" && "$meta_mode" == "600" && "$dir_mode" == "700" ]] || return 1
	jq -e 'type == "object" and (.repo | type == "string") and
		(.strategy == "github-app" or .strategy == "delegated") and
		(.expires_at | type == "string")' "$meta_file" >/dev/null 2>&1 || return 1

	_WORKER_TOKEN_REAL_PATH="$token_real"
	_WORKER_TOKEN_META_FILE="$meta_real"
	return 0
}

# Read token value from file (for passing to worker env)
read_token_file() {
	local token_file="$1"

	if ! _validate_token_artifacts "$token_file"; then
		log_token "ERROR" "Token file or metadata failed canonical path, ownership, or mode validation"
		return 1
	fi

	cat "$_WORKER_TOKEN_REAL_PATH"
	return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_create() {
	local repo=""
	local ttl="$DEFAULT_TTL"
	local permissions="$DEFAULT_PERMISSIONS"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo | -r)
			repo="$2"
			shift 2
			;;
		--ttl | -t)
			ttl="$2"
			# Validate TTL is numeric to prevent arithmetic injection
			if ! [[ "$ttl" =~ ^[0-9]+$ ]]; then
				log_token "ERROR" "TTL must be a positive integer: ${ttl}"
				return 1
			fi
			if ((ttl > MAX_TTL)); then
				log_token "WARN" "TTL capped at ${MAX_TTL}s (requested ${ttl}s)"
				ttl=$MAX_TTL
			fi
			shift 2
			;;
		--permissions | -p)
			permissions="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$repo" ]]; then
		log_token "ERROR" "Repository required: --repo owner/repo"
		return 1
	fi

	# Validate repo format
	if [[ ! "$repo" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
		log_token "ERROR" "Invalid repo format: ${repo} (expected owner/repo)"
		return 1
	fi

	log_token "INFO" "Creating scoped token for ${repo} (TTL: ${ttl}s, permissions: ${permissions})"

	# Strategy 1: GitHub App installation token (best — enforced by GitHub)
	local token_file
	token_file=$(create_app_token "$repo" "$permissions" "$ttl") && {
		log_token "INFO" "Strategy: GitHub App installation token (enforced scoping)"
		printf '%s' "$token_file"
		return 0
	}

	# Strategy 2: Delegated token (fallback — advisory scoping)
	token_file=$(create_delegated_token "$repo" "$permissions" "$ttl") && {
		log_token "INFO" "Strategy: Delegated token (advisory scoping)"
		printf '%s' "$token_file"
		return 0
	}

	# All strategies failed
	log_token "ERROR" "All token creation strategies failed for ${repo}"
	log_audit "create_failed" "$repo" "none" "$ttl" "none"
	return 1
}

cmd_validate() {
	local token_file=""
	local expected_repo=""
	local local_only=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--token-file | -f)
			[[ $# -ge 2 ]] || return 1
			token_file="$2"
			shift 2
			;;
		--repo | -r)
			[[ $# -ge 2 ]] || return 1
			expected_repo="$2"
			shift 2
			;;
		--local-only)
			local_only=1
			shift
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$token_file" ]]; then
		log_token "ERROR" "Token file required: --token-file /path/to/token"
		return 1
	fi

	if ! _validate_token_artifacts "$token_file"; then
		log_token "ERROR" "Token file or metadata failed canonical path, ownership, or mode validation"
		return 1
	fi

	# Check metadata for expiry
	local meta_file="$_WORKER_TOKEN_META_FILE"
	local expires_at strategy repo
	expires_at=$(jq -r '.expires_at // empty' "$meta_file" 2>/dev/null)
	strategy=$(jq -r '.strategy // empty' "$meta_file" 2>/dev/null)
	repo=$(jq -r '.repo // empty' "$meta_file" 2>/dev/null)
	[[ "$repo" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]] || return 1
	if [[ -n "$expected_repo" && "$repo" != "$expected_repo" ]]; then
		log_token "ERROR" "Token repository metadata does not match the requested repository"
		return 1
	fi

	log_token "INFO" "Token: strategy=${strategy}, repo=${repo}, expires=${expires_at}"

	local expires_epoch now_epoch
	expires_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$expires_at" +%s 2>/dev/null ||
		date -d "$expires_at" +%s 2>/dev/null || echo "0")
	now_epoch=$(date +%s)

	if [[ "$expires_epoch" -le 0 || "$now_epoch" -gt "$expires_epoch" ]]; then
		log_token "WARN" "Token has expired or has invalid expiry metadata"
		return 1
	fi
	[[ "$local_only" -eq 0 ]] || return 0

	# Validate token against GitHub API (without exposing the value)
	local token
	token=$(cat "$_WORKER_TOKEN_REAL_PATH") || return 1

	local http_code
	local validation_url="https://api.github.com/user"
	if [[ "$strategy" == "github-app" ]]; then
		validation_url="https://api.github.com/repos/${repo}"
	fi
	http_code=$(_curl_with_bearer "$token" -s -o /dev/null -w '%{http_code}' \
		"$validation_url" \
		-H "$GITHUB_ACCEPT_HEADER")

	if [[ "$http_code" == "200" ]]; then
		log_token "INFO" "Token is valid for ${repo} (HTTP ${http_code})"
		return 0
	else
		log_token "WARN" "Token validation failed (HTTP ${http_code})"
		return 1
	fi
}

cmd_revoke() {
	local token_file=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--token-file | -f)
			token_file="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$token_file" ]]; then
		log_token "ERROR" "Token file required: --token-file /path/to/token"
		return 1
	fi

	# Validate token file path is within TOKEN_DIR to prevent path traversal
	# Resolve parent directory instead of the file itself — the token file may
	# already be deleted (only .meta remains), and realpath fails on missing files.
	local token_dir_real token_parent_real token_base
	token_dir_real=$(realpath "$TOKEN_DIR" 2>/dev/null) || {
		log_token "ERROR" "Cannot resolve token directory: ${TOKEN_DIR}"
		return 1
	}
	token_parent_real=$(realpath "$(dirname "$token_file")" 2>/dev/null) || {
		log_token "ERROR" "Cannot resolve token file path: ${token_file}"
		return 1
	}
	token_base=$(basename "$token_file")
	if [[ "$token_parent_real" != "$token_dir_real" || "$token_base" != *.token ]]; then
		log_token "ERROR" "Token file must be within ${TOKEN_DIR}: ${token_file}"
		return 1
	fi

	local meta_file="${token_file%.token}.meta"
	local strategy=""
	local repo=""

	if [[ -f "$meta_file" ]]; then
		strategy=$(jq -r '.strategy // empty' "$meta_file" 2>/dev/null)
		repo=$(jq -r '.repo // empty' "$meta_file" 2>/dev/null)
	fi

	# For GitHub App tokens, we can revoke via API
	if [[ "$strategy" == "github-app" ]] && [[ -f "$token_file" ]]; then
		local token
		token=$(read_token_file "$token_file") || true

		if [[ -n "$token" ]]; then
			# Revoke the installation token
			local http_code
			http_code=$(_curl_with_bearer "$token" -s -o /dev/null -w '%{http_code}' \
				-X DELETE \
				"https://api.github.com/installation/token" \
				-H "$GITHUB_ACCEPT_HEADER" \
				-H "X-GitHub-Api-Version: 2022-11-28")

			if [[ "$http_code" == "204" ]]; then
				log_token "INFO" "Revoked GitHub App token via API"
			else
				log_token "WARN" "GitHub App token revocation returned HTTP ${http_code} (may already be expired)"
			fi
		fi
	fi

	# Always delete local files regardless of strategy
	if [[ -f "$token_file" ]]; then
		# Overwrite before delete (defense in depth)
		dd if=/dev/urandom bs=64 count=1 2>/dev/null | head -c 64 >"$token_file" 2>/dev/null || true
		rm -f "$token_file"
		log_token "INFO" "Deleted token file: ${token_file}"
	fi

	if [[ -f "$meta_file" ]]; then
		rm -f "$meta_file"
		log_token "INFO" "Deleted metadata file: ${meta_file}"
	fi

	log_audit "revoke" "${repo:-unknown}" "${strategy:-unknown}" "0" "$(basename "${token_file%.token}")"
	return 0
}

cmd_cleanup() {
	# Clean up expired tokens
	local cleaned=0

	if [[ ! -d "$TOKEN_DIR" ]]; then
		log_token "INFO" "No token directory to clean"
		return 0
	fi

	local meta_file
	for meta_file in "${TOKEN_DIR}"/*.meta; do
		[[ -f "$meta_file" ]] || continue

		local expires_at
		expires_at=$(jq -r '.expires_at // empty' "$meta_file" 2>/dev/null)

		if [[ -n "$expires_at" ]]; then
			local expires_epoch now_epoch
			expires_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$expires_at" +%s 2>/dev/null ||
				date -d "$expires_at" +%s 2>/dev/null || echo "0")
			now_epoch=$(date +%s)

			if [[ "$expires_epoch" -gt 0 ]] && [[ "$now_epoch" -gt "$expires_epoch" ]]; then
				local token_file="${meta_file%.meta}.token"
				cmd_revoke --token-file "$token_file" 2>/dev/null || true
				((++cleaned))
			fi
		fi
	done

	log_token "INFO" "Cleaned up ${cleaned} expired token(s)"
	return 0
}

cmd_status() {
	echo ""
	print_info "Worker Token Status"
	echo "===================="
	echo ""

	# Check GitHub App configuration
	if [[ -f "$APP_CONFIG" ]]; then
		local app_id
		app_id=$(jq -r '.app_id // "not set"' "$APP_CONFIG" 2>/dev/null)
		echo "  GitHub App: configured (app_id: ${app_id})"

		local key_path
		key_path=$(jq -r '.private_key_path // ""' "$APP_CONFIG" 2>/dev/null)
		key_path="${key_path/#\~/$HOME}"
		if [[ -f "$key_path" ]]; then
			echo "  Private key: present"
		else
			echo "  Private key: MISSING (${key_path})"
		fi
	else
		echo "  GitHub App: not configured"
		echo "  (Using delegated token fallback)"
	fi

	echo ""

	# Check gh auth
	if command -v gh &>/dev/null; then
		local gh_user
		gh_user=$(gh api /user --jq '.login' 2>/dev/null || echo "not authenticated")
		echo "  gh auth: ${gh_user}"
	else
		echo "  gh CLI: not installed"
	fi

	echo ""

	# Active tokens
	local active_count=0
	local expired_count=0
	if [[ -d "$TOKEN_DIR" ]]; then
		local meta_file
		for meta_file in "${TOKEN_DIR}"/*.meta; do
			[[ -f "$meta_file" ]] || continue

			local expires_at strategy repo
			expires_at=$(jq -r '.expires_at // ""' "$meta_file" 2>/dev/null)
			strategy=$(jq -r '.strategy // ""' "$meta_file" 2>/dev/null)
			repo=$(jq -r '.repo // ""' "$meta_file" 2>/dev/null)

			local now_epoch expires_epoch
			now_epoch=$(date +%s)
			expires_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$expires_at" +%s 2>/dev/null ||
				date -d "$expires_at" +%s 2>/dev/null || echo "0")

			if [[ "$expires_epoch" -gt 0 ]] && [[ "$now_epoch" -gt "$expires_epoch" ]]; then
				((++expired_count))
			else
				((++active_count))
				echo "  Active: ${repo} (${strategy}, expires: ${expires_at})"
			fi
		done
	fi

	echo ""
	echo "  Active tokens: ${active_count}"
	echo "  Expired tokens: ${expired_count} (run 'worker-token-helper.sh cleanup' to remove)"

	# Audit log stats
	if [[ -f "$TOKEN_LOG" ]]; then
		local total_events
		total_events=$(wc -l <"$TOKEN_LOG" | xargs)
		echo "  Audit events: ${total_events}"
	fi

	echo ""
	return 0
}

cmd_help() {
	cat <<'HELP'
worker-token-helper.sh — Scoped, short-lived GitHub tokens for worker agents

Commands:
  create    Create a scoped token for a worker session
  validate  Check if a token is still valid
  revoke    Revoke and delete a token
  cleanup   Remove all expired tokens
  status    Show token configuration and active tokens
  help      Show this help

Create options:
  --repo owner/repo          Target repository (required)
  --ttl N                    Token TTL in seconds (default: 3600, max: 7200)
  --permissions perms        Comma-separated permissions (default: contents:write,pull_requests:write,issues:write)

Validate/Revoke options:
  --token-file /path         Path to token file

Token strategies (tried in order):
  1. GitHub App installation token
     - Best: enforced by GitHub, repo-scoped, 1h TTL
     - Requires: GitHub App installed, config at ~/.config/aidevops/github-app.json
  2. Delegated token
     - Fallback: uses existing gh auth token with advisory scoping
	 - Token remains in a private file and is exposed to Git only through AskPass
     - TTL is advisory (tracked locally, not enforced by GitHub)

Setup for GitHub App (recommended):
  1. Create a GitHub App at https://github.com/settings/apps/new
     - Name: aidevops-worker (or similar)
     - Permissions: Contents (Read & Write), Pull requests (Read & Write), Issues (Read & Write)
     - No webhook URL needed
  2. Install the App on your account/org
  3. Note the App ID and Installation ID
  4. Generate and download a private key
  5. Configure:
     mkdir -p ~/.config/aidevops
     cat > ~/.config/aidevops/github-app.json << EOF
     {
       "app_id": "YOUR_APP_ID",
       "private_key_path": "~/.config/aidevops/github-app-key.pem",
       "installation_id": "YOUR_INSTALLATION_ID"
     }
     EOF
     chmod 600 ~/.config/aidevops/github-app.json
     chmod 600 ~/.config/aidevops/github-app-key.pem

Integration with dispatch:
  # In dispatch wrapper:
  TOKEN_FILE=$(worker-token-helper.sh create --repo owner/repo --ttl 3600)
  AIDEVOPS_GIT_AUTH_TOKEN_FILE="$TOKEN_FILE" opencode run "task..."
  worker-token-helper.sh revoke --token-file "$TOKEN_FILE"

Security:
  - Token files: 600 permissions, overwritten before deletion
  - Metadata files: no token values, safe to inspect
  - Audit log: JSONL, records create/revoke events (no token values)
  - GitHub App tokens: revoked via API on cleanup
  - Delegated tokens: local file deleted (token itself remains valid until gh auth logout)
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	create) cmd_create "$@" ;;
	validate) cmd_validate "$@" ;;
	revoke) cmd_revoke "$@" ;;
	cleanup) cmd_cleanup "$@" ;;
	status) cmd_status "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_token "ERROR" "Unknown command: ${cmd}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
