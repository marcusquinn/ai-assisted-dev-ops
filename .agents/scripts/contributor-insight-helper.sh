#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# contributor-insight-helper.sh — File privacy-sanitized upstream issues from
# session-miner output for contributor-role repos (t2147).
# Uses gh_create_issue wrapper (shared-constants.sh) for origin labelling.
#
# When a contributor runs aidevops with a repo they don't own in repos.json
# (role: contributor), the session-miner still runs locally and detects
# instruction candidates, steerage patterns, and error trends. This helper
# takes the compressed_signals.json output and:
#   1. Filters for framework-relevant signals (not project-specific)
#   2. Privacy-sanitizes: strips private repo slugs, file paths outside
#      ~/.aidevops/agents/, client/project names, credential patterns
#   3. Deduplicates against existing open issues on the target repo
#   4. Files upstream issues tagged origin:contributor-insight
#
# Usage:
#   contributor-insight-helper.sh file <compressed_signals.json> <target_slug>
#   contributor-insight-helper.sh file --dry-run <compressed_signals.json> <target_slug>
#   contributor-insight-helper.sh sanitize <text>    # test sanitization
#
# Env:
#   CONTRIBUTOR_INSIGHT_MAX_ISSUES (default 3) — cap per run
#   CONTRIBUTOR_INSIGHT_MIN_CONFIDENCE (default 0.65) — instruction candidate threshold
#
# Called by: session-miner-pulse.sh (for contributor-role repos)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=lib/issue-fingerprint.sh
[[ -f "${SCRIPT_DIR}/lib/issue-fingerprint.sh" ]] && source "${SCRIPT_DIR}/lib/issue-fingerprint.sh"

REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
MAX_ISSUES="${CONTRIBUTOR_INSIGHT_MAX_ISSUES:-3}"
MIN_CONFIDENCE="${CONTRIBUTOR_INSIGHT_MIN_CONFIDENCE:-0.65}"
CONTRIBUTOR_INSIGHT_LABEL="contributor-insight"

# --- Logging ---

_ci_log() {
	local level="$1"
	local msg="$2"
	printf '[contributor-insight] %s: %s\n' "$level" "$msg" >&2
	return 0
}

_print_deferred_json() {
	local error_class="$1"
	jq -cn --arg error_class "$error_class" \
		'{status:"deferred", fingerprints:[], error_class:$error_class}'
	return 0
}

# --- Privacy sanitization ---

# _load_private_slugs outputs one slug per line from repos.json entries
# that have mirror_upstream or local_only (same logic as privacy-guard).
_load_private_slugs() {
	if [[ ! -f "$REPOS_JSON" ]]; then
		return 0
	fi
	jq -r '.initialized_repos[]
		| select((.mirror_upstream // false) == true or (.local_only // false) == true)
		| .slug // empty' "$REPOS_JSON" 2>/dev/null || true
	# Also load extra slugs file if present
	local extras="${HOME}/.aidevops/configs/privacy-guard-extra-slugs.txt"
	if [[ -f "$extras" ]]; then
		grep -v '^#' "$extras" 2>/dev/null | grep -v '^$' || true
	fi
	return 0
}

# sanitize_text strips private slugs, non-framework file paths,
# credential patterns, and home directory references from text.
# Arguments: $1 — text to sanitize, $2 — optional preloaded private slugs
# Outputs: sanitized text to stdout
sanitize_text() {
	local text="$1"
	local private_slugs="${2-}"

	if [[ -z "$private_slugs" ]]; then
		private_slugs=$(_load_private_slugs)
	fi

	# 1. Strip private repo slugs
	local slug
	while IFS= read -r slug; do
		[[ -z "$slug" ]] && continue
		# Escape for sed
		local escaped
		escaped=$(printf '%s' "$slug" | sed 's/[.[\/*^$]/\\&/g')
		text=$(printf '%s' "$text" | sed "s|${escaped}|[private-repo]|g")
	done <<<"$private_slugs"

	# 2. Strip absolute file paths outside .agents/ (user project paths)
	text=$(printf '%s' "$text" | sed -E 's|/Users/[^ ]*|[local-path]|g')
	text=$(printf '%s' "$text" | sed -E 's|/home/[^ ]*|[local-path]|g')
	text=$(printf '%s' "$text" | sed -E 's|~/Git/[^ ]*|[local-path]|g')

	# 3. Strip credential patterns (API keys, tokens)
	# Word-boundary anchor — see shared-constants.sh::scrub_credentials for the
	# t2892 rationale. Mid-word matches like `task-failure-handler` must not be
	# corrupted into `ta[redacted-credential]`.
	text=$(printf '%s' "$text" | sed -E 's/(^|[^A-Za-z0-9_-])(sk-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}/\1[redacted-credential]/g')

	# 4. Strip email addresses
	text=$(printf '%s' "$text" | sed -E 's/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/[email]/g')

	printf '%s' "$text"
	return 0
}

# --- Issue body composition ---

# _compose_instruction_issue builds an anonymous summary for one qualified candidate.
# Raw session text, titles, identities, and local paths are intentionally omitted.
_compose_instruction_issue() {
	local candidate_json="$1"
	local fingerprint="$2"
	local target_file category support qualification
	target_file=$(printf '%s' "$candidate_json" | jq -r '.target_file') || return 1
	category=$(printf '%s' "$candidate_json" | jq -r '.category // "general"') || return 1
	support=$(printf '%s' "$candidate_json" | jq -r '.support // 0') || return 1
	qualification=$(printf '%s' "$candidate_json" | jq -r '.qualification_basis') || return 1

	local body=""
	body+="## Contributor Insight: Instruction Candidates"$'\n\n'
	body+="A de-identified, target-scoped usage pattern qualified for maintainer review."$'\n'
	body+="No contributor identity, session title, repository path, or raw excerpt is included."$'\n\n'
	body+="<!-- aidevops:generator=contributor-insight-helper -->"$'\n\n'
	body+="- Target file: \`${target_file}\`"$'\n'
	body+="- Category: \`${category}\`"$'\n'
	body+="- Qualification: \`${qualification}\`"$'\n'
	body+="- Distinct-session support: ${support}"$'\n'
	body+="- Stable fingerprint: \`${fingerprint}\`"$'\n\n'
	body+="## Requested Maintainer Review"$'\n\n'
	body+="- Inspect target-specific evidence available to project maintainers."$'\n'
	body+="- Decide whether the recurring pattern indicates a documentation, workflow, or tooling gap."$'\n'
	body+="- Verify any change with the target project's normal focused checks."$'\n\n'
	body+="<!-- aidevops:session-miner-fingerprint=${fingerprint} -->"$'\n\n'
	body+="---"$'\n'
	body+="*Filed automatically from de-identified recurring evidence.*"

	printf '%s' "$body"
	return 0
}

# _compose_error_pattern_issue builds an issue body from error patterns.
_compose_error_pattern_issue() {
	local patterns_json="$1"
	local fingerprint="$2"

	local body=""
	body+="## Contributor Insight: Error Patterns"$'\n\n'
	body+="De-identified recurring tool failure counts may indicate project-level gaps."$'\n'
	body+="No contributor identity, raw error, command, response, or local path is included."$'\n\n'
	body+="<!-- aidevops:generator=contributor-insight-helper -->"$'\n\n'

	local count
	count=$(printf '%s' "$patterns_json" | jq -r 'length' 2>/dev/null) || count=0
	local i=0
	while [[ "$i" -lt "$count" && "$i" -lt 10 ]]; do
		local tool category pcount models
		local pattern_fields
		pattern_fields=$(printf '%s' "$patterns_json" | jq -r --argjson idx "$i" '
			.[$idx] as $pattern
			| [
				($pattern.tool // "unknown"),
				($pattern.error_category // "other"),
				($pattern.count // 0),
				($pattern.model_count // 0)
			]
			| @tsv' 2>/dev/null) || pattern_fields=$'unknown\tother\t0\t0'
		IFS=$'\t' read -r tool category pcount models <<<"$pattern_fields"

		body+="- \`${tool}:${category}\` — ${pcount}x across ${models} model(s)"$'\n'
		i=$((i + 1))
	done

	body+=$'\n'"<!-- aidevops:session-miner-fingerprint=${fingerprint} -->"$'\n'
	body+=$'\n'"---"$'\n'
	body+="*Filed automatically from de-identified recurring evidence.*"

	printf '%s' "$body"
	return 0
}

# --- Dedup ---

# _issue_exists checks for the exact stable fingerprint marker.
_issue_exists() {
	local slug="$1"
	local fingerprint="$2"

	local existing
	existing=$(gh issue list --repo "$slug" --state open \
		--label "$CONTRIBUTOR_INSIGHT_LABEL" \
		--search "\"aidevops:session-miner-fingerprint=${fingerprint}\" in:body" \
		--limit 1 --json number --jq 'length' 2>/dev/null) || existing="0"
	[[ "$existing" != "0" ]]
	return $?
}

_target_is_confirmed_public() {
	local slug="$1"
	local visibility=""
	visibility=$(gh repo view "$slug" --json visibility,isPrivate \
		--jq 'select(.visibility == "PUBLIC" and .isPrivate == false) | "public"' 2>/dev/null) || visibility=""
	[[ "$visibility" == "public" ]]
	return $?
}

_target_is_registered_contributor() {
	local slug="$1"
	jq -e --arg slug "$slug" '
		[.initialized_repos[]? | select(.slug == $slug)] as $entries
		| ($entries | length) == 1
		and $entries[0].role == "contributor"
		and ($entries[0].local_only // false) == false
		and ($entries[0].mirror_upstream // false) == false
	' "$REPOS_JSON" >/dev/null 2>&1
	return $?
}

_candidate_public_fingerprint() {
	local target_file="$1"
	local raw_fingerprint="$2"
	_compute_issue_fingerprint "$target_file" "$raw_fingerprint"
	return $?
}

_candidate_target_is_known() {
	local target_file="$1"
	[[ -n "$target_file" && "$target_file" != /* && "$target_file" != *".."* ]] || return 1
	[[ -n "${_CI_TARGET_REPO_PATH:-}" && -d "$_CI_TARGET_REPO_PATH" ]] || return 1
	git -C "$_CI_TARGET_REPO_PATH" ls-files --error-unmatch "$target_file" >/dev/null 2>&1
	return $?
}

# --- Main commands ---

# _CI_INSIGHT_CREATED: set to 1 by filing helpers when an issue is created or
# would be created (dry-run). Callers must reset to 0 before each call.
_CI_INSIGHT_CREATED=0
_CI_FINGERPRINTS='[]'

# _file_instruction_candidates — extract and file high-confidence instruction
# candidates. Writes to stdout (dry-run: body; live: log). Sets
# _CI_INSIGHT_CREATED=1 on success.
_file_instruction_candidates() {
	local compressed_file="$1"
	local target_slug="$2"
	local dry_run="$3"
	local remaining="$4"
	_CI_INSIGHT_CREATED=0

	local candidates
	candidates=$(jq -c '
		[
			.instruction_candidates // {}
			| to_entries[] as $entry
			| $entry.value[]
			| select(
				(.confidence >= '"$MIN_CONFIDENCE"') and
				(.requires_judgment == false) and
				((.qualification_basis == "recurring") or (.qualification_basis == "explicit_persistence")) and
				((.fingerprint // "") | length) > 0
			)
			| . + {target_file: $entry.key}
		]
		| sort_by(-.support, -.confidence)
	' "$compressed_file" 2>/dev/null) || candidates="[]"

	local candidate_count
	candidate_count=$(printf '%s' "$candidates" | jq -r 'length' 2>/dev/null) || candidate_count=0
	[[ "$candidate_count" -gt 0 ]] || return 0

	local i=0
	while [[ "$i" -lt "$candidate_count" && "$_CI_INSIGHT_CREATED" -lt "$remaining" ]]; do
		local candidate target_file raw_fingerprint fingerprint title body
		candidate=$(printf '%s' "$candidates" | jq -c --argjson index "$i" '.[$index]') || return 1
		target_file=$(printf '%s' "$candidate" | jq -r '.target_file') || return 1
		if ! _candidate_target_is_known "$target_file"; then
			i=$((i + 1))
			continue
		fi
		raw_fingerprint=$(printf '%s' "$candidate" | jq -r '.fingerprint') || return 1
		fingerprint=$(_candidate_public_fingerprint "$target_file" "$raw_fingerprint") || return 1
		if _issue_exists "$target_slug" "$fingerprint"; then
			_CI_FINGERPRINTS=$(printf '%s' "$_CI_FINGERPRINTS" | jq -c --arg fingerprint "$fingerprint" '. + [$fingerprint] | unique') || return 1
			i=$((i + 1))
			continue
		fi
		title="Contributor insight: recurring guidance (${fingerprint:0:12})"
		body=$(_compose_instruction_issue "$candidate" "$fingerprint") || return 1
		if [[ "$dry_run" == true ]]; then
			_ci_log INFO "DRY RUN: would create issue: ${title}"
			printf '%s\n' "$body"
		elif gh_create_issue --repo "$target_slug" \
			--title "$title" --body "$body" \
			--label "$CONTRIBUTOR_INSIGHT_LABEL" 2>/dev/null; then
			_ci_log INFO "Created issue: ${title}"
		else
			_ci_log ERROR "Failed to create instruction candidate issue"
			return 1
		fi
		_CI_INSIGHT_CREATED=$((_CI_INSIGHT_CREATED + 1))
		_CI_FINGERPRINTS=$(printf '%s' "$_CI_FINGERPRINTS" | jq -c --arg fingerprint "$fingerprint" '. + [$fingerprint] | unique') || return 1
		i=$((i + 1))
	done
	return 0
}

# _file_error_patterns — extract and file high-frequency cross-model error
# patterns. Writes to stdout (dry-run: body; live: log). Sets
# _CI_INSIGHT_CREATED=1 on success.
_file_error_patterns() {
	local compressed_file="$1"
	local target_slug="$2"
	local dry_run="$3"
	_CI_INSIGHT_CREATED=0

	local error_patterns
	error_patterns=$(jq -c '
		[
			.errors.patterns[]
			| select(.count >= 20 and .model_count >= 2)
		]
		| sort_by(-.count)
		| .[:10]
	' "$compressed_file" 2>/dev/null) || error_patterns="[]"

	local error_count
	error_count=$(printf '%s' "$error_patterns" | jq -r 'length' 2>/dev/null) || error_count=0
	[[ "$error_count" -gt 0 ]] || return 0

	local canonical fingerprint
	canonical=$(printf '%s' "$error_patterns" | jq -c 'map({tool, error_category}) | sort_by(.tool, .error_category)') || return 1
	fingerprint=$(_candidate_public_fingerprint "error-patterns" "$canonical") || return 1
	local error_title="Contributor insight: ${error_count} recurring error pattern(s) (${fingerprint:0:12})"
	if _issue_exists "$target_slug" "$fingerprint"; then
		_ci_log INFO "Error patterns issue already exists — skipping"
		_CI_FINGERPRINTS=$(printf '%s' "$_CI_FINGERPRINTS" | jq -c --arg fingerprint "$fingerprint" '. + [$fingerprint] | unique') || return 1
		return 0
	fi

	local error_body
	error_body=$(_compose_error_pattern_issue "$error_patterns" "$fingerprint") || return 1
	if [[ "$dry_run" == true ]]; then
		_ci_log INFO "DRY RUN: would create issue: ${error_title}"
		printf '%s\n' "$error_body"
		_CI_INSIGHT_CREATED=1
	elif gh_create_issue --repo "$target_slug" \
		--title "$error_title" --body "$error_body" \
		--label "$CONTRIBUTOR_INSIGHT_LABEL" 2>/dev/null; then
		_ci_log INFO "Created issue: ${error_title}"
		_CI_INSIGHT_CREATED=1
	else
		_ci_log ERROR "Failed to create error patterns issue"
		return 1
	fi
	_CI_FINGERPRINTS=$(printf '%s' "$_CI_FINGERPRINTS" | jq -c --arg fingerprint "$fingerprint" '. + [$fingerprint] | unique') || return 1
	return 0
}

cmd_file() {
	local dry_run=false
	local json_output=false
	while [[ "${1:-}" == "--dry-run" || "${1:-}" == "--json" ]]; do
		case "$1" in
		--dry-run) dry_run=true ;;
		--json) json_output=true ;;
		esac
		shift
	done

	local compressed_file="${1:-}" target_slug="${2:-}"
	if [[ -z "$compressed_file" || -z "$target_slug" ]]; then
		_ci_log ERROR "Usage: contributor-insight-helper.sh file [--dry-run] <compressed_signals.json> <target_slug>"
		return 1
	fi
	if [[ ! -f "$compressed_file" ]]; then
		_ci_log ERROR "Compressed signals file not found: ${compressed_file}"
		return 1
	fi
	if ! command -v gh >/dev/null 2>&1; then
		_ci_log ERROR "gh CLI not found"
		return 1
	fi
	if ! _target_is_registered_contributor "$target_slug"; then
		_ci_log ERROR "Target role is not an explicit public contributor registration"
		[[ "$json_output" == true ]] && _print_deferred_json "unknown_or_private_role"
		return 1
	fi
	if ! _target_is_confirmed_public "$target_slug"; then
		_ci_log ERROR "Target repository visibility is not confirmed public"
		[[ "$json_output" == true ]] && _print_deferred_json "public_target_unconfirmed"
		return 1
	fi
	_CI_TARGET_REPO_PATH=$(jq -r --arg slug "$target_slug" '
		[.initialized_repos[]? | select(.slug == $slug and .role == "contributor")]
		| if length == 1 then .[0].path // "" else "" end
	' "$REPOS_JSON" 2>/dev/null) || _CI_TARGET_REPO_PATH=""
	if [[ -z "$_CI_TARGET_REPO_PATH" || ! -d "$_CI_TARGET_REPO_PATH" ]]; then
		_ci_log ERROR "Registered contributor path is unavailable"
		[[ "$json_output" == true ]] && _print_deferred_json "contributor_path_unavailable"
		return 1
	fi

	local issues_created=0
	_CI_FINGERPRINTS='[]'

	if [[ "$issues_created" -lt "$MAX_ISSUES" ]]; then
		_file_instruction_candidates "$compressed_file" "$target_slug" "$dry_run" "$((MAX_ISSUES - issues_created))" || return 1
		issues_created=$((issues_created + _CI_INSIGHT_CREATED))
	fi
	if [[ "$issues_created" -lt "$MAX_ISSUES" ]]; then
		_file_error_patterns "$compressed_file" "$target_slug" "$dry_run" || return 1
		issues_created=$((issues_created + _CI_INSIGHT_CREATED))
	fi

	_ci_log INFO "Complete: ${issues_created} issue(s) created (cap=${MAX_ISSUES})"
	if [[ "$json_output" == true ]]; then
		jq -cn --argjson created "$issues_created" --argjson fingerprints "$_CI_FINGERPRINTS" \
			'{status:"healthy", created:$created, fingerprints:$fingerprints}'
	fi
	return 0
}

cmd_sanitize() {
	local text="${1:-}"
	if [[ -z "$text" ]]; then
		_ci_log ERROR "Usage: contributor-insight-helper.sh sanitize <text>"
		return 1
	fi
	sanitize_text "$text"
	printf '\n'
	return 0
}

# --- Entry point ---

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	file)
		cmd_file "$@"
		;;
	sanitize)
		cmd_sanitize "$@"
		;;
	help | --help | -h)
		printf 'Usage: contributor-insight-helper.sh {file|sanitize|help}\n'
		printf '  file [--dry-run] [--json] <compressed_signals.json> <target_slug>\n'
		printf '  sanitize <text>\n'
		return 0
		;;
	*)
		_ci_log ERROR "Unknown command: ${cmd}"
		return 1
		;;
	esac
}

main "$@"
