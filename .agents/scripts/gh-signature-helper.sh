#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh-signature-helper.sh — Generate signature footer for GitHub comments
# =============================================================================
#
# Orchestrator that sources focused sub-libraries and provides the CLI entry
# points (generate, footer, record-child, help).
#
# Produces a one-line signature footer for issues, PRs, and comments created
# by aidevops agents. Format:
#
#   ---
#   [OpenCode CLI](https://opencode.ai) v1.3.3, [aidevops.sh](https://aidevops.sh) v3.5.6, anthropic/opus-4-6, 1,234 tokens
#
# Usage:
#   gh-signature-helper.sh generate      [OPTIONS]
#   gh-signature-helper.sh footer        [OPTIONS]
#   gh-signature-helper.sh record-child  --child SESSION_ID [--parent ID] [--tokens N]
#   gh-signature-helper.sh help
#
# The "generate" command outputs just the signature line (no leading ---).
# The "footer" command outputs the full footer block (--- + newline + signature).
#
# Environment variables (override auto-detection):
#   AIDEVOPS_SIG_CLI          CLI name (e.g., "OpenCode CLI")
#   AIDEVOPS_SIG_CLI_VERSION  CLI version (e.g., "1.3.3")
#   AIDEVOPS_SIG_MODEL        Model ID (e.g., "anthropic/opus-4-6")
#   AIDEVOPS_SIG_TOKENS       Token count (e.g., "1234")
#
# Runtime-aware: OpenCode DB queries gated behind _is_opencode_runtime() (GH#17689).
# Dependencies: lib/version.sh (aidevops version), aidevops-update-check.sh (CLI detection)
#
# Sub-libraries (sourced below):
#   gh-signature-helper-detect.sh  — CLI/runtime detection (_cli_url, _detect_cli, etc.)
#   gh-signature-helper-session.sh — Session discovery & token/time metrics

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit

# shellcheck source=lib/version.sh
source "${SCRIPT_DIR}/lib/version.sh"

# --- Source sub-libraries (dependency order: detect first, session depends on detect) ---

# shellcheck source=./gh-signature-helper-detect.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/gh-signature-helper-detect.sh"

# shellcheck source=./gh-signature-helper-session.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/gh-signature-helper-session.sh"

# =============================================================================
# _parse_generate_args — parse CLI args for cmd_generate
# =============================================================================
# Outputs pipe-separated: model|tokens|cli_name|cli_version|issue_ref|issue_created|solved|no_session|session_type_override|time_secs

_parse_generate_args() {
	local model="${AIDEVOPS_SIG_MODEL:-}"
	local tokens="${AIDEVOPS_SIG_TOKENS:-}"
	local cli_name="${AIDEVOPS_SIG_CLI:-}"
	local cli_version="${AIDEVOPS_SIG_CLI_VERSION:-}"
	local issue_ref="" issue_created="" solved="false" no_session="false"
	local session_type_override="" time_secs=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--model)
			model="$2"
			shift 2
			;;
		--tokens)
			tokens="$2"
			shift 2
			;;
		--cli)
			cli_name="$2"
			shift 2
			;;
		--cli-version)
			cli_version="$2"
			shift 2
			;;
		--issue)
			issue_ref="$2"
			shift 2
			;;
		--issue-created)
			issue_created="$2"
			shift 2
			;;
		--solved)
			solved="true"
			shift
			;;
		--no-session)
			no_session="true"
			shift
			;;
		--session-type)
			session_type_override="$2"
			shift 2
			;;
		--time)
			time_secs="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
		"$model" "$tokens" "$cli_name" "$cli_version" \
		"$issue_ref" "$issue_created" "$solved" "$no_session" \
		"$session_type_override" "$time_secs"
	return 0
}

# =============================================================================
# _resolve_cli_inputs — auto-detect CLI name/version if not provided
# =============================================================================
# Outputs pipe-separated: cli_name|cli_version

_resolve_cli_inputs() {
	local cli_name="$1"
	local cli_version="$2"

	if [[ -z "$cli_name" ]]; then
		local detected
		detected=$(_detect_cli)
		cli_name="${detected%%|*}"
		if [[ -z "$cli_version" ]]; then
			cli_version="${detected#*|}"
			# If no pipe separator was present, cli_version == cli_name
			if [[ "$cli_version" == "$cli_name" ]]; then
				cli_version=""
			fi
		fi
	elif [[ -z "$cli_version" ]]; then
		local cli_lower
		cli_lower=$(printf '%s' "$cli_name" | tr '[:upper:]' '[:lower:]')
		if [[ "$cli_lower" == *opencode* ]]; then
			cli_version=$(_detect_opencode_version)
		fi
	fi

	printf '%s|%s\n' "$cli_name" "$cli_version"
	return 0
}

# =============================================================================
# _collect_time_metrics — gather session and total time strings
# =============================================================================
# Outputs pipe-separated: session_time_str|total_time_str

_collect_time_metrics() {
	local issue_ref="$1"
	local issue_created="$2"

	local session_time_str="" total_time_str=""

	local session_secs
	session_secs=$(_detect_session_time)

	if [[ -n "$session_secs" ]] && [[ "$session_secs" -gt 0 ]] 2>/dev/null; then
		session_time_str=$(_format_duration "$session_secs")
	fi

	if [[ -n "$issue_ref" ]] || [[ -n "$issue_created" ]]; then
		local total_secs
		total_secs=$(_detect_total_time "$issue_ref" "$issue_created")
		if [[ -n "$total_secs" ]] && [[ "$total_secs" -gt 0 ]] 2>/dev/null; then
			total_time_str=$(_format_duration "$total_secs")
		fi
	fi

	printf '%s|%s\n' "$session_time_str" "$total_time_str"
	return 0
}

# =============================================================================
# _build_signature — assemble the natural-language signature string
# =============================================================================
# Deliberately kept in the orchestrator to preserve the (file, fname) identity
# key for the function-complexity scanner. Moving it to a sub-library would
# register a new violation (see reference/large-file-split.md section 3).
#
# Args: model cli_name cli_version tokens session_time_str total_time_str solved issue_total_tokens session_type

_build_signature() {
	local model="$1"
	local cli_name="$2"
	local cli_version="$3"
	local tokens="$4"
	local session_time_str="$5"
	local total_time_str="$6"
	local solved="$7"
	local issue_total_tokens="${8:-}"
	local session_type="${9:-}"

	local aidevops_version
	aidevops_version=$(aidevops_find_version)

	# Strip provider prefix from model (anthropic/claude-opus-4-6 → claude-opus-4-6)
	local display_model="$model"
	if [[ "$display_model" == */* ]]; then
		display_model="${display_model##*/}"
	fi

	# Target: [aidevops.sh](...) v3.5.10 in [CLI](...) v1.3.3 with claude-opus-4-6 used N tokens for Xm, Zm since this issue was created.
	local sig="[aidevops.sh](https://aidevops.sh) v${aidevops_version}"

	# "plugin for [CLI] vX.Y.Z"
	if [[ -n "$cli_name" ]]; then
		local url
		url=$(_cli_url "$cli_name")
		if [[ -n "$url" ]]; then
			sig="${sig} plugin for [${cli_name}](${url})"
		else
			sig="${sig} plugin for ${cli_name}"
		fi
		if [[ -n "$cli_version" ]]; then
			sig="${sig} v${cli_version}"
		fi
	fi

	# "with model"
	if [[ -n "$display_model" ]]; then
		sig="${sig} with ${display_model}"
	fi

	# "spent Xm and N tokens on this." — time first, tokens second
	local has_time="" has_tokens=""
	if [[ -n "$session_time_str" ]]; then has_time="true"; fi
	if [[ -n "$tokens" ]] && [[ "$tokens" != "0" ]]; then has_tokens="true"; fi

	if [[ -n "$has_time" ]] || [[ -n "$has_tokens" ]]; then
		sig="${sig} spent"
		if [[ -n "$has_time" ]]; then
			sig="${sig} ${session_time_str}"
		fi
		if [[ -n "$has_time" ]] && [[ -n "$has_tokens" ]]; then
			sig="${sig} and"
		fi
		if [[ -n "$has_tokens" ]]; then
			local formatted
			formatted=$(_format_number "$tokens")
			sig="${sig} ${formatted} tokens"
		fi
		if [[ "$session_type" == "interactive" ]]; then
			sig="${sig} on this with the user in an interactive session."
		elif [[ "$session_type" == "worker" ]]; then
			sig="${sig} on this as a headless worker."
		elif [[ "$session_type" == "routine" ]]; then
			sig="${sig} on this as a headless bash routine."
		else
			sig="${sig} on this."
		fi
	fi

	local has_stats=""
	if [[ -n "$has_time" ]] || [[ -n "$has_tokens" ]] || [[ -n "$total_time_str" ]]; then
		has_stats="true"
	fi

	# Total time as a separate sentence
	if [[ -n "$total_time_str" ]]; then
		if [[ "$solved" == "true" ]]; then
			sig="${sig} Solved in ${total_time_str}."
		else
			sig="${sig} Overall, ${total_time_str} since this issue was created."
		fi
	fi

	# Issue total tokens (cumulative across all sessions on this issue)
	if [[ -n "$issue_total_tokens" ]] && [[ "$issue_total_tokens" != "0" ]]; then
		local formatted_total
		formatted_total=$(_format_number "$issue_total_tokens")
		sig="${sig} ${formatted_total} total tokens on this issue."
	fi

	# If signature is just the version (no CLI, model, tokens, or time),
	# append "automated scan" so it reads naturally on non-LLM issues
	if [[ -z "$cli_name" ]] && [[ -z "$display_model" ]] && [[ -z "$has_stats" ]] && [[ -z "$issue_total_tokens" ]]; then
		sig="${sig} automated scan."
	fi

	echo "$sig"
	return 0
}

# =============================================================================
# generate — produce the signature line
# =============================================================================

cmd_generate() {
	# Parse arguments
	local parsed
	parsed=$(_parse_generate_args "$@")
	local model tokens cli_name cli_version issue_ref issue_created solved no_session
	local session_type_override time_secs
	IFS='|' read -r model tokens cli_name cli_version issue_ref issue_created solved no_session \
		session_type_override time_secs <<<"$parsed"

	# Auto-detect CLI name/version
	local cli_resolved
	cli_resolved=$(_resolve_cli_inputs "$cli_name" "$cli_version")
	cli_name="${cli_resolved%%|*}"
	cli_version="${cli_resolved##*|}"
	if [[ -z "$cli_name" && -n "$issue_ref" ]]; then
		local issue_cli_context
		issue_cli_context=$(_detect_issue_cli_context "$issue_ref")
		if [[ -n "$issue_cli_context" ]]; then
			cli_name="${issue_cli_context%%|*}"
			cli_version="${issue_cli_context##*|}"
		fi
	fi

	# Skip session DB detection when --no-session is set (GH#13046).
	# Used by callers running outside OpenCode (e.g., pulse-wrapper via launchd)
	# where session DB lookups would return misleading data from unrelated sessions.
	local session_time_str="" total_time_str="" issue_total_tokens="" session_type=""

	if [[ "$no_session" != "true" ]]; then
		# Auto-detect model from session DB if not provided (GH#12965)
		if [[ -z "$model" ]]; then
			model=$(_detect_session_model)
		fi

		# Auto-detect tokens from session DB if not provided.
		# When issue context is provided, scope tokens to issue lifetime first
		# (prevents unrelated early-session work inflating issue/PR signatures).
		if [[ -z "$tokens" ]]; then
			if [[ -n "$issue_ref" ]] || [[ -n "$issue_created" ]]; then
				tokens=$(_detect_issue_scoped_tokens "$issue_ref" "$issue_created")
			fi
			if [[ -z "$tokens" ]]; then
				tokens=$(_detect_session_tokens)
			fi
		fi

		# Add child subagent tokens from ledger (t1897).
		# The ledger is populated by `record-child` calls after each Task tool
		# completion. This is runtime-agnostic — the ledger is a plain TSV file.
		local child_tokens_sum
		child_tokens_sum=$(_sum_child_tokens "")
		if [[ -n "$child_tokens_sum" ]] && [[ "$child_tokens_sum" -gt 0 ]] 2>/dev/null; then
			local parent_tokens="${tokens:-0}"
			parent_tokens=$(printf '%s' "$parent_tokens" | tr -cd '0-9')
			parent_tokens="${parent_tokens:-0}"
			tokens=$((parent_tokens + child_tokens_sum))
		fi

		# Collect time metrics
		local time_metrics
		time_metrics=$(_collect_time_metrics "$issue_ref" "$issue_created")
		IFS='|' read -r session_time_str total_time_str <<<"$time_metrics"

		# Sum issue total tokens (prior comments + current session) when --issue is set.
		# Only show when there are prior comments with tokens — otherwise the total
		# equals the current session's count, which is redundant.
		if [[ -n "$issue_ref" ]]; then
			local prior_tokens
			prior_tokens=$(_sum_issue_tokens "$issue_ref")
			if [[ -n "$prior_tokens" ]] && [[ "$prior_tokens" -gt 0 ]] 2>/dev/null; then
				local current_tokens="${tokens:-0}"
				current_tokens=$(printf '%s' "$current_tokens" | tr -cd '0-9')
				current_tokens="${current_tokens:-0}"
				issue_total_tokens=$((prior_tokens + current_tokens))
			fi
		fi

		# Detect session type (interactive vs worker)
		session_type=$(_detect_session_type)
	fi

	# Apply explicit overrides (--time and --session-type take precedence)
	if [[ -n "$time_secs" ]] && [[ "$time_secs" -gt 0 ]] 2>/dev/null; then
		session_time_str=$(_format_duration "$time_secs")
	fi
	if [[ -n "$session_type_override" ]]; then
		session_type="$session_type_override"
	fi

	# Build and emit the signature
	_build_signature \
		"$model" "$cli_name" "$cli_version" "$tokens" \
		"$session_time_str" "$total_time_str" "$solved" "$issue_total_tokens" "$session_type"
	return 0
}

# =============================================================================
# footer — produce the full footer block (--- + signature)
# =============================================================================

cmd_footer() {
	# Check for --body flag to enable dedup (skip if body already has signature)
	local args=() body_to_check=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--body)
			body_to_check="$2"
			shift 2
			;;
		*)
			args+=("$1")
			shift
			;;
		esac
	done

	# Dedup only on the canonical marker occupying its own complete line.
	# Root script references and inline marker documentation are body content,
	# not evidence that a signature footer has already been appended.
	if [[ -n "$body_to_check" ]] && grep -Fqx '<!-- aidevops:sig -->' <<<"$body_to_check"; then
		return 0
	fi

	local sig
	# ${args[@]+"${args[@]}"} handles empty array under set -u (Bash 3.2 compat)
	sig=$(cmd_generate ${args[@]+"${args[@]}"})
	# HTML comment marker lets workers/tooling identify and skip signature blocks
	# (see AGENTS.md — signature footer skip when reading)
	printf '\n<!-- aidevops:sig -->\n---\n%s\n' "$sig"
	return 0
}

# =============================================================================
# record-child — log a subagent's token usage to the parent session's ledger
# =============================================================================
# Called after a Task tool call completes. The task_id returned by the Task tool
# IS the child's session ID (verified for OpenCode; other runtimes pass --tokens).
#
# Usage:
#   gh-signature-helper.sh record-child --child SESSION_ID [--parent SESSION_ID] [--tokens N]
#
# If --parent is omitted, auto-detected from the runtime session DB.
# If --tokens is omitted, queried from the runtime DB using the child session ID.
# Idempotent: recording the same child twice is a no-op.

cmd_record_child() {
	local parent_session_id="" child_session_id="" child_tokens=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--parent)
			parent_session_id="$2"
			shift 2
			;;
		--child)
			child_session_id="$2"
			shift 2
			;;
		--tokens)
			child_tokens="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$child_session_id" ]]; then
		echo "Error: --child SESSION_ID is required" >&2
		return 1
	fi

	# Auto-detect parent session from runtime DB (OpenCode only — GH#17689)
	if [[ -z "$parent_session_id" ]] && _is_opencode_runtime; then
		local db_path
		db_path=$(_opencode_db_path)
		if [[ -r "$db_path" ]] && command -v sqlite3 &>/dev/null; then
			parent_session_id=$(_find_session_id "$db_path")
		fi
	fi

	if [[ -z "$parent_session_id" ]]; then
		echo "Error: could not determine parent session ID (pass --parent explicitly)" >&2
		return 1
	fi

	# Auto-detect child tokens from runtime DB if not provided (OpenCode only — GH#17689)
	if [[ -z "$child_tokens" ]] && _is_opencode_runtime; then
		local db_path
		db_path=$(_opencode_db_path)
		if [[ -r "$db_path" ]] && command -v sqlite3 &>/dev/null; then
			child_tokens=$(_sum_session_tokens_for_session "$db_path" "$child_session_id" "")
		fi
	fi

	# Default to 0 if detection failed (graceful degradation for non-OpenCode runtimes)
	if [[ -z "$child_tokens" ]] || ! [[ "$child_tokens" =~ ^[0-9]+$ ]]; then
		child_tokens="0"
	fi

	# Ensure ledger directory exists
	local ledger_dir
	ledger_dir=$(_child_token_ledger_dir)
	mkdir -p "$ledger_dir"

	local ledger_path
	ledger_path=$(_child_token_ledger_path "$parent_session_id")

	# Idempotent: skip if child already recorded
	if [[ -r "$ledger_path" ]] && grep -q "^${child_session_id}	" "$ledger_path" 2>/dev/null; then
		return 0
	fi

	# Append to ledger
	printf '%s\t%s\t%s\n' "$child_session_id" "$child_tokens" "$(date +%s)" >>"$ledger_path"
	return 0
}

# =============================================================================
# help
# =============================================================================

show_help() {
	cat <<'EOF'
gh-signature-helper.sh — Generate signature footer for GitHub comments

Usage:
  gh-signature-helper.sh generate      [OPTIONS]
  gh-signature-helper.sh footer        [OPTIONS]
  gh-signature-helper.sh record-child  --child SESSION_ID [--parent ID] [--tokens N]
  gh-signature-helper.sh help

Commands:
  generate      Output the signature line (no leading ---)
  footer        Output the full footer block (--- + newline + signature)
  record-child  Log a subagent's token usage to the parent session's ledger
  help          Show this help

Options (generate/footer):
  --model MODEL             Model ID (e.g., anthropic/claude-opus-4-6)
  --tokens N                Token count (auto-detected from OpenCode DB if omitted)
  --cli NAME                CLI name override (e.g., "OpenCode CLI")
  --cli-version VER         CLI version override (e.g., "1.3.3")
  --issue OWNER/REPO#NUM    GitHub issue ref for total time and token summing
  --issue-created ISO       Issue creation timestamp for total time
  --solved                  Use "Solved in Xm." instead of "Xm since this issue was created."

Options (record-child):
  --child SESSION_ID        Child session ID (task_id from Task tool) — required
  --parent SESSION_ID       Parent session ID (auto-detected if omitted)
  --tokens N                Child token count (auto-detected from DB if omitted)

Auto-detected fields (OpenCode sessions):
  - CLI name and version
  - Token count (input+output from session DB, plus child subagent tokens)
  - Child subagent tokens (from ledger written by record-child)
  - Session time (duration since session start)
  - Issue total tokens (sum of all signature footers by the authenticated
    GitHub user on the issue's comments, plus current session tokens).
    Lower bound — workers killed before commenting are not counted.

Auto-detected fields (Claude Code sessions — GH#17689):
  - Model (from ANTHROPIC_MODEL or CLAUDE_MODEL env vars)
  - Session type (worker if FULL_LOOP_HEADLESS=true, interactive otherwise)
  - Note: OpenCode DB is NOT queried in non-OpenCode runtimes.

Environment variables (override auto-detection):
  AIDEVOPS_SIG_CLI          CLI name
  AIDEVOPS_SIG_CLI_VERSION  CLI version
  AIDEVOPS_SIG_MODEL        Model ID
  AIDEVOPS_SIG_TOKENS       Token count

Examples:
  # Auto-detect everything, just specify model
  gh-signature-helper.sh generate --model anthropic/claude-opus-4-6

  # Record a subagent's tokens after Task tool returns task_id
  gh-signature-helper.sh record-child --child ses_abc123

  # With explicit tokens (non-OpenCode runtimes)
  gh-signature-helper.sh record-child --child ses_abc123 --tokens 1500

  # With issue ref for total time (queries GitHub API)
  gh-signature-helper.sh footer --model anthropic/claude-sonnet-4-6 --issue owner/repo#42

  # Use in a gh issue comment
  FOOTER=$(gh-signature-helper.sh footer --model anthropic/claude-sonnet-4-6 --issue owner/repo#42)
  gh issue comment 42 --repo owner/repo --body "Comment body${FOOTER}"
EOF
	return 0
}

# =============================================================================
# main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	generate) cmd_generate "$@" ;;
	footer) cmd_footer "$@" ;;
	record-child) cmd_record_child "$@" ;;
	help | --help | -h) show_help ;;
	*)
		echo "Error: Unknown command: $command" >&2
		show_help >&2
		return 1
		;;
	esac
}

main "$@"
