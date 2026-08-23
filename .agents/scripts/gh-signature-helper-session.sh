#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh-signature-helper-session.sh -- Session Discovery & Token/Time Metrics
# =============================================================================
# Provides OpenCode session identification, token counting (session, issue-scoped,
# child subagent), model and session-type detection, time/duration tracking,
# issue token aggregation, and number/duration formatting utilities.
#
# Usage: source "${SCRIPT_DIR}/gh-signature-helper-session.sh"
#
# Dependencies:
#   - gh-signature-helper-detect.sh (_is_opencode_runtime, _detect_claude_code_model)
#   - shared-constants.sh (print_error, print_info, etc.) -- optional
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_GH_SIG_SESSION_LIB_LOADED:-}" ]] && return 0
_GH_SIG_SESSION_LIB_LOADED=1

# Module-level constant: ISO 8601 date format for BSD date -j parsing
_GH_SIG_ISO_FMT="%Y-%m-%dT%H:%M:%SZ"

# Defensive SCRIPT_DIR fallback (test harnesses / direct sourcing)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Resolve OpenCode DB path (XDG_DATA_HOME-aware)
# =============================================================================
# Headless workers run with XDG_DATA_HOME redirected to an isolated temp dir
# (headless-runtime-helper.sh auth isolation). The session DB is created there,
# not at the default ~/.local/share/opencode/opencode.db. Without this, the
# signature helper can't find the worker's session data and footers show time
# but no tokens (GH#15486).

_opencode_db_path() {
	printf '%s' "${XDG_DATA_HOME:-${HOME}/.local/share}/opencode/opencode.db"
	return 0
}

# =============================================================================
# Auto-detect session token count from runtime DB
# =============================================================================
# Queries the runtime's session database for cumulative token usage.
# Currently supports OpenCode (SQLite DB, path resolved via _opencode_db_path).
# Returns total input+output tokens for the most recent session in the current
# working directory, or empty string if unavailable.

# =============================================================================
# _build_session_dir_list -- resolve project directories for session matching
# =============================================================================
# Builds a SQL-safe comma-separated list of quoted directory paths for use in
# SQLite IN() clauses. Excludes root and temp paths that would match stale
# sessions from unrelated contexts (GH#13046 -- pulse runs from / via launchd).
# Output: SQL fragment like "'path1', 'path2'" or empty string.

_build_session_dir_list() {
	local cwd repo_root canonical_dir main_worktree
	cwd=$(pwd 2>/dev/null || echo "")
	if [[ -z "$cwd" ]]; then
		echo ""
		return 0
	fi

	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$cwd")
	canonical_dir="${repo_root%%.*}"

	# Resolve the main worktree path (first entry in git worktree list).
	# In linked worktrees, cwd/repo_root differ from the canonical repo path
	# where sessions are typically stored (GH#12965).
	main_worktree=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //' || echo "")

	local dir_list="" d
	for d in "$cwd" "$repo_root" "$canonical_dir" "$main_worktree"; do
		case "$d" in
		"" | "/" | "/tmp" | "/private/tmp" | "/var/tmp") continue ;;
		esac
		if [[ -n "$dir_list" ]]; then
			dir_list="${dir_list}, '${d}'"
		else
			dir_list="'${d}'"
		fi
	done

	echo "$dir_list"
	return 0
}

# =============================================================================
# _find_opencode_pid -- locate the OpenCode process PID
# =============================================================================
# Returns the PID of the running OpenCode process, or empty string.
# Strategy 1: OPENCODE_PID env var (set in interactive TUI sessions).
# Strategy 2: Walk PPID chain up to 10 levels, matching "opencode" in comm or
#   args. Checks both because on Linux ps -o comm= truncates to 15 chars and
#   may show "node" instead of "opencode" when run via Node.js (GH#13012).

_find_opencode_pid() {
	if [[ -n "${OPENCODE_PID:-}" ]]; then
		echo "$OPENCODE_PID"
		return 0
	fi

	local walk_pid="${PPID:-0}"
	local walk_depth=0
	while [[ "$walk_pid" -gt 1 ]] && [[ "$walk_depth" -lt 10 ]] 2>/dev/null; do
		local walk_comm walk_args walk_lower
		walk_comm=$(ps -o comm= -p "$walk_pid" 2>/dev/null || echo "")
		walk_args=$(ps -o args= -p "$walk_pid" 2>/dev/null || echo "")
		walk_lower=$(printf '%s %s' "$walk_comm" "$walk_args" | tr '[:upper:]' '[:lower:]')
		if [[ "$walk_lower" == *opencode* ]]; then
			echo "$walk_pid"
			return 0
		fi
		walk_pid=$(ps -o ppid= -p "$walk_pid" 2>/dev/null | tr -d ' ' || echo "0")
		walk_depth=$((walk_depth + 1))
	done

	echo ""
	return 0
}

# =============================================================================
# _pid_start_epoch -- convert a PID's start time to Unix epoch seconds
# =============================================================================
# Uses GNU date -d (Linux) with BSD date -j fallback (macOS).
# Returns epoch integer, or empty string if conversion fails.

_pid_start_epoch() {
	local pid="$1"
	local lstart
	lstart=$(ps -o lstart= -p "$pid" 2>/dev/null || echo "")
	if [[ -z "$lstart" ]]; then
		echo ""
		return 0
	fi
	# Try GNU date first (Linux), then BSD date (macOS)
	date -d "$lstart" "+%s" 2>/dev/null ||
		date -j -f "%a %b %d %H:%M:%S %Y" "$lstart" "+%s" 2>/dev/null ||
		echo ""
	return 0
}

_sql_quote() {
	local value="$1"
	value=${value//\'/\'\'}
	printf "'%s'" "$value"
	return 0
}

_find_explicit_session_id() {
	local db_path="$1"
	local explicit_session_id="${AIDEVOPS_SIG_SESSION_ID:-${OPENCODE_SESSION_ID:-}}"

	if [[ -z "$explicit_session_id" ]]; then
		echo ""
		return 0
	fi

	local quoted_id
	quoted_id=$(_sql_quote "$explicit_session_id")
	sqlite3 "$db_path" "
		SELECT id FROM session
		WHERE id=${quoted_id}
		LIMIT 1
	" 2>/dev/null || echo ""
	return 0
}

_allow_pid_session_match() {
	if [[ "${AIDEVOPS_SIG_ALLOW_PID_SESSION_MATCH:-}" == "1" ]]; then
		return 0
	fi

	# OpenCode processes can outlive many chat sessions. PID-start matching is
	# available only as an explicit compatibility escape hatch, never by default.
	return 1
}

# =============================================================================
# _find_session_id -- shared session identification for all detectors
# =============================================================================
# Finds the current OpenCode session ID using multiple heuristics:
# 1. Explicit session env (AIDEVOPS_SIG_SESSION_ID / OPENCODE_SESSION_ID)
# 2. Most recently created session in this directory
# 3. Most recently created session globally (within 10 minutes)
# 4. Optional PID-start fallback for explicit opt-in compatibility contexts
#
# Delegates directory resolution to _build_session_dir_list,
# PID detection to _find_opencode_pid, and epoch conversion to _pid_start_epoch.

_find_session_id() {
	local db_path="$1"

	local dir_list
	dir_list=$(_build_session_dir_list)

	local session_id=""

	# Strategy 1: explicit current session metadata from the runtime/plugin.
	session_id=$(_find_explicit_session_id "$db_path")

	# Strategy 2: most recently created session matching directory
	# (not updated -- avoids picking long-running supervisor sessions)
	if [[ -z "$session_id" ]] && [[ -n "$dir_list" ]]; then
		session_id=$(sqlite3 "$db_path" "
			SELECT id FROM session
			WHERE directory IN (${dir_list})
			ORDER BY time_created DESC LIMIT 1
		" 2>/dev/null || echo "")
	fi

	# Strategy 3: most recently created session globally (within 10 minutes).
	# Fallback when directory matching fails -- e.g., workers in worktrees
	# not yet in the DB, or scripts running from non-project directories.
	# 10-minute window (tightened from 1h) limits false matches to concurrent
	# sessions on the same machine (GH#13012, GH#13046).
	if [[ -z "$session_id" ]]; then
		session_id=$(sqlite3 "$db_path" "
			SELECT id FROM session
			WHERE time_created > (strftime('%s','now') - 600) * 1000
			ORDER BY time_created DESC LIMIT 1
		" 2>/dev/null || echo "")
	fi

	# Strategy 4: legacy PID-start fallback, demoted because OpenCode's
	# interactive app process can outlive many sessions (GH#22003).
	local target_pid
	target_pid=""
	if [[ -z "$session_id" ]] && _allow_pid_session_match && [[ -n "$dir_list" ]]; then
		target_pid=$(_find_opencode_pid)
	fi
	if [[ -z "$session_id" ]] && [[ -n "$target_pid" ]] && [[ -n "$dir_list" ]]; then
		local epoch
		epoch=$(_pid_start_epoch "$target_pid")
		if [[ -n "$epoch" ]]; then
			local pid_start_ms=$((epoch * 1000))
			session_id=$(sqlite3 "$db_path" "
				SELECT id FROM session
				WHERE directory IN (${dir_list})
				ORDER BY ABS(time_created - ${pid_start_ms}) ASC LIMIT 1
			" 2>/dev/null || echo "")
		fi
	fi

	echo "$session_id"
	return 0
}

# Sum non-cached input + output tokens for a session.
# Args:
#   $1 - sqlite db path
#   $2 - session ID
#   $3 - since milliseconds epoch (optional; include messages >= this time)
# Output: integer token count (may be 0)
_sum_session_tokens_for_session() {
	local db_path="$1"
	local session_id="$2"
	local since_ms="${3:-}"

	local since_filter=""
	if [[ -n "$since_ms" ]] && [[ "$since_ms" =~ ^[0-9]+$ ]] && [[ "$since_ms" -gt 0 ]]; then
		since_filter="AND time_created >= ${since_ms}"
	fi

	sqlite3 "$db_path" "
		SELECT COALESCE(SUM(
			CASE
				WHEN json_extract(data, '$.tokens.input') >
				     COALESCE(json_extract(data, '$.tokens.cache.read'), 0)
				THEN MAX(
					json_extract(data, '$.tokens.input')
					- COALESCE(json_extract(data, '$.tokens.cache.read'), 0)
					- COALESCE(json_extract(data, '$.tokens.cache.write'), 0),
					0)
				ELSE json_extract(data, '$.tokens.input')
			END
			+ json_extract(data, '$.tokens.output')
		), 0)
		FROM message
		WHERE session_id='${session_id}'
		  AND json_extract(data, '$.tokens.input') > 0
		  ${since_filter}
	" 2>/dev/null || echo ""
	return 0
}

_detect_session_tokens_with_since() {
	local since_epoch="${1:-}"

	# Guard: only query OpenCode DB in OpenCode runtime (GH#17689)
	if ! _is_opencode_runtime; then
		echo ""
		return 0
	fi

	local db_path
	db_path=$(_opencode_db_path)

	if [[ ! -r "$db_path" ]] || ! command -v sqlite3 &>/dev/null; then
		echo ""
		return 0
	fi

	local session_id
	session_id=$(_find_session_id "$db_path")

	if [[ -z "$session_id" ]]; then
		echo ""
		return 0
	fi

	local since_ms=""
	if [[ -n "$since_epoch" ]] && [[ "$since_epoch" =~ ^[0-9]+$ ]] && [[ "$since_epoch" -gt 0 ]]; then
		since_ms=$((since_epoch * 1000))
	fi

	local total_tokens
	total_tokens=$(_sum_session_tokens_for_session "$db_path" "$session_id" "$since_ms")

	if [[ -n "$total_tokens" ]] && [[ "$total_tokens" =~ ^[0-9]+$ ]]; then
		echo "$total_tokens"
	else
		echo ""
	fi
	return 0
}

_detect_session_tokens() {
	_detect_session_tokens_with_since ""
	return 0
}

# Resolve issue creation time to epoch seconds.
# Args: issue_ref (OWNER/REPO#NUM), issue_created ISO timestamp
# Output: epoch seconds, or empty string if unavailable
_resolve_issue_created_epoch() {
	local issue_ref="$1"
	local issue_created="$2"

	if [[ -n "$issue_created" ]]; then
		local parsed_epoch=""
		if date -j -u -f "$_GH_SIG_ISO_FMT" "$issue_created" "+%s" &>/dev/null 2>&1; then
			parsed_epoch=$(date -j -u -f "$_GH_SIG_ISO_FMT" "$issue_created" "+%s" 2>/dev/null || echo "")
		elif date -d "$issue_created" "+%s" &>/dev/null 2>&1; then
			parsed_epoch=$(date -d "$issue_created" "+%s" 2>/dev/null || echo "")
		fi

		if [[ -n "$parsed_epoch" ]]; then
			echo "$parsed_epoch"
			return 0
		fi
	fi

	if [[ -n "$issue_ref" ]] && command -v gh &>/dev/null; then
		local repo_slug issue_number created_at
		repo_slug="${issue_ref%%#*}"
		issue_number="${issue_ref##*#}"
		if [[ -n "$repo_slug" ]] && [[ -n "$issue_number" ]] && [[ "$issue_number" =~ ^[0-9]+$ ]]; then
			created_at=$(gh api "repos/${repo_slug}/issues/${issue_number}" --jq '.created_at' 2>/dev/null || echo "")
			if [[ -n "$created_at" ]]; then
				_resolve_issue_created_epoch "" "$created_at"
				return 0
			fi
		fi
	fi

	echo ""
	return 0
}

# Detect session tokens scoped to issue creation time when issue context is known.
# Args: issue_ref (OWNER/REPO#NUM), issue_created ISO timestamp
# Output: scoped token count, or empty when issue timestamp/session unavailable.
_detect_issue_scoped_tokens() {
	local issue_ref="$1"
	local issue_created="$2"

	local issue_created_epoch
	issue_created_epoch=$(_resolve_issue_created_epoch "$issue_ref" "$issue_created")
	if [[ -z "$issue_created_epoch" ]] || ! [[ "$issue_created_epoch" =~ ^[0-9]+$ ]] || [[ "$issue_created_epoch" -le 0 ]]; then
		echo ""
		return 0
	fi

	_detect_session_tokens_with_since "$issue_created_epoch"
	return 0
}

# =============================================================================
# Detect model from runtime DB or environment (GH#17689)
# =============================================================================
# Queries the OpenCode session DB for the model used in the current session,
# but ONLY when running in OpenCode. For Claude Code and other runtimes, falls
# back to environment variables (ANTHROPIC_MODEL, CLAUDE_MODEL).
# Returns "provider/model" (e.g., "anthropic/claude-sonnet-4-6") or empty.
# This eliminates the need for callers to pass --model explicitly (GH#12965).

_detect_session_model() {
	# Guard: only query OpenCode DB in OpenCode runtime (GH#17689)
	if ! _is_opencode_runtime; then
		_detect_claude_code_model
		return 0
	fi

	local db_path
	db_path=$(_opencode_db_path)

	if [[ ! -r "$db_path" ]] || ! command -v sqlite3 &>/dev/null; then
		echo ""
		return 0
	fi

	local session_id
	session_id=$(_find_session_id "$db_path")

	if [[ -z "$session_id" ]]; then
		echo ""
		return 0
	fi

	# Extract provider/model from the first message that has model data
	local provider model_id
	provider=$(sqlite3 "$db_path" "
		SELECT COALESCE(json_extract(data, '\$.providerID'),
		                json_extract(data, '\$.model.providerID'))
		FROM message
		WHERE session_id='${session_id}'
		  AND COALESCE(json_extract(data, '\$.modelID'),
		               json_extract(data, '\$.model.modelID')) IS NOT NULL
		LIMIT 1
	" 2>/dev/null || echo "")

	model_id=$(sqlite3 "$db_path" "
		SELECT COALESCE(json_extract(data, '\$.modelID'),
		                json_extract(data, '\$.model.modelID'))
		FROM message
		WHERE session_id='${session_id}'
		  AND COALESCE(json_extract(data, '\$.modelID'),
		               json_extract(data, '\$.model.modelID')) IS NOT NULL
		LIMIT 1
	" 2>/dev/null || echo "")

	if [[ -n "$provider" ]] && [[ -n "$model_id" ]]; then
		echo "${provider}/${model_id}"
	elif [[ -n "$model_id" ]]; then
		echo "$model_id"
	else
		echo ""
	fi
	return 0
}

# =============================================================================
# Detect session type: explicit headless markers, then interactive runtime,
# then legacy DB heuristic ("interactive" >1 user messages, "worker" 0-1).
# =============================================================================

_gh_sig_env_truthy() {
	local value="$1"
	case "$value" in
	"" | "0" | "false" | "FALSE" | "no" | "NO") return 1 ;;
	*) return 0 ;;
	esac
}

_detect_explicit_session_type() {
	case "${AIDEVOPS_SESSION_ORIGIN:-}" in
	worker)
		echo "worker"
		return 0
		;;
	interactive)
		echo "interactive"
		return 0
		;;
	esac

	if _gh_sig_env_truthy "${FULL_LOOP_HEADLESS:-}" ||
		_gh_sig_env_truthy "${AIDEVOPS_HEADLESS:-}" ||
		_gh_sig_env_truthy "${OPENCODE_HEADLESS:-}" ||
		_gh_sig_env_truthy "${GITHUB_ACTIONS:-}"; then
		echo "worker"
		return 0
	fi

	if _gh_sig_env_truthy "${OPENCODE:-}" || [[ -n "${OPENCODE_SESSION_ID:-}" ]] ||
		_gh_sig_env_truthy "${CLAUDE_CODE:-}" || [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
		echo "interactive"
		return 0
	fi

	echo ""
	return 0
}

_detect_session_type() {
	local explicit_type
	explicit_type=$(_detect_explicit_session_type)
	if [[ -n "$explicit_type" ]]; then
		echo "$explicit_type"
		return 0
	fi

	# Guard: only query OpenCode DB in OpenCode runtime (GH#17689)
	if ! _is_opencode_runtime; then
		echo ""
		return 0
	fi

	local db_path
	db_path=$(_opencode_db_path)

	if [[ ! -r "$db_path" ]] || ! command -v sqlite3 &>/dev/null; then
		echo ""
		return 0
	fi

	local session_id
	session_id=$(_find_session_id "$db_path")

	if [[ -z "$session_id" ]]; then
		echo ""
		return 0
	fi

	local user_msg_count
	user_msg_count=$(sqlite3 "$db_path" "
		SELECT COUNT(*) FROM message
		WHERE session_id='${session_id}'
		  AND json_extract(data, '$.role') = 'user'
	" 2>/dev/null || echo "0")

	if [[ "$user_msg_count" -gt 1 ]] 2>/dev/null; then
		echo "interactive"
	else
		echo "worker"
	fi
	return 0
}

# =============================================================================
# Child-token ledger -- runtime-agnostic subagent token tracking (t1897)
# =============================================================================
# When a parent session spawns subagents via the Task tool, each subagent runs
# as a separate session whose tokens are NOT included in the parent's count.
# The ledger bridges this gap: after each Task call completes, `record-child`
# writes the child's token count to a TSV file keyed by parent session ID.
# At signature-generation time, `_sum_child_tokens` reads the ledger and adds
# child tokens to the parent total.
#
# Ledger format (TSV): child_session_id \t tokens \t epoch
# File path: ~/.aidevops/.agent-workspace/tmp/{parent_session_id}.children.tsv
#
# Runtime adapters:
#   OpenCode: task_id from Task tool IS the session ID in SQLite -- query directly
#   Claude Code: task_id may map to JSONL transcripts -- pass --tokens explicitly
#   Other: pass --tokens explicitly; graceful degradation (0 tokens recorded)

_child_token_ledger_dir() {
	printf '%s' "${HOME}/.aidevops/.agent-workspace/tmp"
	return 0
}

_child_token_ledger_path() {
	local parent_session_id="$1"
	printf '%s/%s.children.tsv' "$(_child_token_ledger_dir)" "$parent_session_id"
	return 0
}

# Sum all child subagent tokens from the ledger for a given parent session.
# Args: $1 - parent session ID (optional; auto-detected if empty)
# Output: integer token count, or empty string if no ledger/no children
_sum_child_tokens() {
	local parent_session_id="${1:-}"

	# Auto-detect parent session if not provided (OpenCode only -- GH#17689)
	if [[ -z "$parent_session_id" ]] && _is_opencode_runtime; then
		local db_path
		db_path=$(_opencode_db_path)
		if [[ -r "$db_path" ]] && command -v sqlite3 &>/dev/null; then
			parent_session_id=$(_find_session_id "$db_path")
		fi
	fi

	if [[ -z "$parent_session_id" ]]; then
		echo ""
		return 0
	fi

	local ledger_path
	ledger_path=$(_child_token_ledger_path "$parent_session_id")

	if [[ ! -r "$ledger_path" ]]; then
		echo ""
		return 0
	fi

	local total=0
	local child_id child_tokens epoch
	while IFS=$'\t' read -r child_id child_tokens epoch; do
		# Skip empty lines and malformed entries
		if [[ -n "$child_tokens" ]] && [[ "$child_tokens" =~ ^[0-9]+$ ]]; then
			total=$((total + child_tokens))
		fi
	done <"$ledger_path"

	if [[ "$total" -gt 0 ]]; then
		echo "$total"
	else
		echo ""
	fi
	return 0
}

# =============================================================================
# Detect session time from runtime DB
# =============================================================================
# Returns session duration in seconds (now - session.time_created), or empty.

_detect_session_time() {
	# Guard: only query OpenCode DB in OpenCode runtime (GH#17689)
	if ! _is_opencode_runtime; then
		echo ""
		return 0
	fi

	local db_path
	db_path=$(_opencode_db_path)

	if [[ ! -r "$db_path" ]] || ! command -v sqlite3 &>/dev/null; then
		echo ""
		return 0
	fi

	local session_id
	session_id=$(_find_session_id "$db_path")

	if [[ -z "$session_id" ]]; then
		echo ""
		return 0
	fi

	local session_seconds
	session_seconds=$(sqlite3 "$db_path" "
		SELECT (strftime('%s','now') * 1000 - time_created) / 1000
		FROM session WHERE id='${session_id}'
	" 2>/dev/null || echo "")

	if [[ -n "$session_seconds" ]] && [[ "$session_seconds" -gt 0 ]] 2>/dev/null; then
		echo "$session_seconds"
	else
		echo ""
	fi
	return 0
}

# =============================================================================
# Sum token counts from all signature footers on an issue's comments
# =============================================================================
# Fetches issue comments, filters to the authenticated GitHub user, extracts
# token counts from signature footers ("spent N tokens" or "has used N tokens"),
# and returns the sum. This is a lower bound -- workers killed before commenting
# are not counted.
#
# Args: $1 - issue_ref (OWNER/REPO#NUMBER)
# Output: total token count (integer), or empty string if unavailable

_sum_issue_tokens() {
	local issue_ref="$1"

	if [[ -z "$issue_ref" ]] || ! command -v gh &>/dev/null; then
		echo ""
		return 0
	fi

	local repo_slug issue_number
	repo_slug="${issue_ref%%#*}"
	issue_number="${issue_ref##*#}"

	if [[ -z "$repo_slug" ]] || [[ -z "$issue_number" ]] || ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		echo ""
		return 0
	fi

	# Get the authenticated user's login
	local gh_user
	gh_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$gh_user" ]]; then
		echo ""
		return 0
	fi

	# Fetch comments by this user, excluding interactive-session footers, and
	# extract token counts from remaining signature footers.
	# Patterns: "spent 1,234 tokens" (current) and "has used 1,234 tokens" (older).
	# The interactive-session filter prevents the cumulative-tokens display in
	# new footers from counting the same user's maintainer triage/review
	# activity toward per-issue spend (t2425 / GH#20047). Mirrors the filter
	# applied in dispatch-dedup-cost.sh::_sum_issue_token_spend.
	local token_values
	token_values=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--paginate --jq ".[]
			| select(.user.login == \"${gh_user}\")
			| select((.body // \"\") | contains(\"with the user in an interactive session\") | not)
			| .body" 2>/dev/null |
		grep -oE '(spent|has used) [0-9,]+ tokens' |
		grep -oE '[0-9,]+' |
		tr -d ',' || echo "")

	if [[ -z "$token_values" ]]; then
		echo ""
		return 0
	fi

	# Sum all extracted values
	local total=0
	local val
	while IFS= read -r val; do
		if [[ -n "$val" ]] && [[ "$val" =~ ^[0-9]+$ ]]; then
			total=$((total + val))
		fi
	done <<<"$token_values"

	if [[ "$total" -gt 0 ]]; then
		echo "$total"
	else
		echo ""
	fi
	return 0
}

# =============================================================================
# Detect prior OpenCode version context from issue signature footers
# =============================================================================
# Used by automation (for example GitHub Actions close comments) that is not
# itself running inside OpenCode but is summarising work that was done by an
# OpenCode worker. Returns "OpenCode|VERSION" or an empty string.

_detect_issue_cli_context() {
	local issue_ref="$1"

	if [[ -z "$issue_ref" ]] || ! command -v gh &>/dev/null; then
		echo ""
		return 0
	fi

	local repo_slug issue_number
	repo_slug="${issue_ref%%#*}"
	issue_number="${issue_ref##*#}"

	if [[ -z "$repo_slug" ]] || [[ -z "$issue_number" ]] || ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		echo ""
		return 0
	fi

	local version
	version=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--paginate --jq '.[].body // ""' 2>/dev/null |
		grep -oE 'plugin for \[OpenCode\]\([^)]*\) v[0-9]+\.[0-9]+\.[0-9]+' |
		grep -oE '[0-9]+\.[0-9]+\.[0-9]+' |
		tail -1 || echo "")

	if [[ -n "$version" ]]; then
		printf 'OpenCode|%s\n' "$version"
	else
		echo ""
	fi
	return 0
}

# =============================================================================
# Detect total time from issue creation to now
# =============================================================================
# Accepts --issue OWNER/REPO#NUMBER or --issue-created ISO-TIMESTAMP.

_detect_total_time() {
	local issue_ref="$1"
	local issue_created="$2"

	if [[ -n "$issue_created" ]]; then
		local created_epoch now_epoch
		if date -j -u -f "$_GH_SIG_ISO_FMT" "$issue_created" "+%s" &>/dev/null 2>&1; then
			created_epoch=$(date -j -u -f "$_GH_SIG_ISO_FMT" "$issue_created" "+%s" 2>/dev/null || echo "")
		else
			created_epoch=$(date -d "$issue_created" "+%s" 2>/dev/null || echo "")
		fi
		if [[ -n "$created_epoch" ]]; then
			now_epoch=$(date "+%s")
			echo $((now_epoch - created_epoch))
			return 0
		fi
	fi

	if [[ -n "$issue_ref" ]] && command -v gh &>/dev/null; then
		local repo_slug issue_number created_at
		repo_slug="${issue_ref%%#*}"
		issue_number="${issue_ref##*#}"
		if [[ -n "$repo_slug" ]] && [[ -n "$issue_number" ]] && [[ "$issue_number" =~ ^[0-9]+$ ]]; then
			created_at=$(gh api "repos/${repo_slug}/issues/${issue_number}" --jq '.created_at' 2>/dev/null || echo "")
			if [[ -n "$created_at" ]]; then
				_detect_total_time "" "$created_at"
				return $?
			fi
		fi
	fi

	echo ""
	return 0
}

# =============================================================================
# Format duration in seconds to human-readable
# =============================================================================
# Examples: 45 -> "45s", 120 -> "2m", 3700 -> "1h 1m", 90061 -> "1d 1h"

_format_duration() {
	local seconds="$1"
	if [[ -z "$seconds" ]] || [[ "$seconds" -le 0 ]] 2>/dev/null; then
		echo ""
		return 0
	fi

	local days hours minutes
	days=$((seconds / 86400))
	hours=$(((seconds % 86400) / 3600))
	minutes=$(((seconds % 3600) / 60))

	if [[ $days -gt 0 ]]; then
		if [[ $hours -gt 0 ]]; then
			echo "${days}d ${hours}h"
		else
			echo "${days}d"
		fi
	elif [[ $hours -gt 0 ]]; then
		if [[ $minutes -gt 0 ]]; then
			echo "${hours}h ${minutes}m"
		else
			echo "${hours}h"
		fi
	elif [[ $minutes -gt 0 ]]; then
		echo "${minutes}m"
	else
		echo "${seconds}s"
	fi
	return 0
}

# =============================================================================
# Format number with commas (Bash 3.2 compatible)
# =============================================================================

_format_number() {
	local num="$1"
	# Strip non-digits
	num=$(printf '%s' "$num" | tr -cd '0-9')
	if [[ -z "$num" ]]; then
		echo "0"
		return 0
	fi
	# Pure bash comma insertion (macOS BSD sed lacks label loops)
	local formatted=""
	local len=${#num}
	local i=0
	while [[ $i -lt $len ]]; do
		local remaining=$((len - i))
		if [[ $i -gt 0 ]] && [[ $((remaining % 3)) -eq 0 ]]; then
			formatted="${formatted},"
		fi
		formatted="${formatted}${num:$i:1}"
		i=$((i + 1))
	done
	echo "$formatted"
	return 0
}
