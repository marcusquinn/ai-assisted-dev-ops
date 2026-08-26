#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pulse ancillary dispatch review validation and worker helpers.
# Sourced by pulse-ancillary-dispatch.sh; no caller-facing API changes.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_ANCILLARY_DISPATCH_REVIEW_SH_LOADED:-}" ]] && return 0
_PULSE_ANCILLARY_DISPATCH_REVIEW_SH_LOADED=1

#######################################
# Run the headless triage-review worker without implementation-worker authority.
#
# Arguments:
#   $1 - issue_num
#   $2 - repo_slug
#   $3 - repo_path
#   $4 - resolved model flag (empty or "--model ...")
#   $5 - prompt file
#   $6 - output file
#   $7 - canonical workload tier (default: thinking)
#
# Exit code: headless runtime status; contract failures return non-zero.
#######################################
_run_triage_review_worker() {
	local triage_issue_num="$1"
	local triage_repo_slug="$2"
	local triage_repo_path="$3"
	local model_flag="$4"
	local prefetch_file="$5"
	local review_output_file="$6"
	local resolved_tier="${7:-thinking}"

	if [[ -z "$review_output_file" ]]; then
		printf '%s\n' '[fatal] triage worker output file missing; aborting before model launch' >&2
		return 1
	fi
	if [[ -z "$prefetch_file" || ! -s "$prefetch_file" ]]; then
		printf '%s\n' '[fatal] triage worker env contract missing prefetch file; aborting before model launch' >"$review_output_file"
		return 1
	fi
	case "$resolved_tier" in
	simple | standard | thinking) ;;
	*)
		printf '%s\n' '[fatal] triage worker env contract has invalid workload tier; aborting before model launch' >"$review_output_file"
		return 1
		;;
	esac

	# Triage correlation lives in the session/title/prompt. WORKER_* variables
	# grant implementation claim, worktree, and cleanup authority and therefore
	# must be absent from this subprocess.
	local runtime_status=0
	(
		unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_WORKTREE_PATH \
			WORKER_GITHUB_LOGIN WORKER_SESSION_KEY AIDEVOPS_WORKER_GITHUB_LOGIN \
			DISPATCH_REPO_SLUG AIDEVOPS_DISPATCH_LEASE_TOKEN \
			AIDEVOPS_DISPATCH_LEASE_DEVICE AIDEVOPS_ATTEMPT_ID \
			AIDEVOPS_PARENT_WORKER_ID AIDEVOPS_ROOT_WORKER_ID AIDEVOPS_WORKER_ID \
			AIDEVOPS_PERMISSION_GRANT_FILE AIDEVOPS_PERMISSION_REQUEST_ID \
			AIDEVOPS_WORKTREE_OWNER_PID AIDEVOPS_WORKTREE_OWNER_SESSION \
			AIDEVOPS_WORKTREE_OWNER_TASK AIDEVOPS_WORKTREE_OWNER_PATH
		export HEADLESS=1
		# shellcheck disable=SC2086
		"$HEADLESS_RUNTIME_HELPER" run \
			--role triage \
			--session-key "triage-review-${triage_issue_num}" \
			--dir "$triage_repo_path" \
			$model_flag \
			--tier "$resolved_tier" \
			--agent triage-review \
			--title "Sandboxed triage review: Issue #${triage_issue_num}" \
			--prompt-file "$prefetch_file" </dev/null
	) >"$review_output_file" 2>&1 || runtime_status=$?

	return "$runtime_status"
}

_triage_review_result_fields() {
	local post_result="$1"
	local infrastructure_failure_reason="$2"
	local failure_reason="${post_result#FAILED:}"
	local outcome="$_PAD_TRIAGE_OUTCOME_REVIEW_FAILED"
	if [[ "$post_result" == "POSTED" ]]; then
		printf 'true||%s\n' "$_PAD_TRIAGE_OUTCOME_POSTED"
		return 0
	fi
	if [[ -n "$infrastructure_failure_reason" ]]; then
		outcome="$_PAD_TRIAGE_OUTCOME_INFRASTRUCTURE_FAILED"
	fi
	printf 'false|%s|%s\n' "$failure_reason" "$outcome"
	return 0
}

#######################################
# Dispatch a sandboxed triage review worker and post its output
#
# Runs the triage-review agent, posts the review comment (with safety filtering
# via _extract_and_post_triage_review), and updates triage labels and cache via
# _finalize_triage_state. Triage never acquires implementation-worker locks.
#
# Arguments:
#   $1 - issue_num
#   $2 - repo_slug
#   $3 - repo_path (passed to --dir of headless helper)
#   $4 - prompt_file (path to prefetch temp file; consumed and removed)
#   $5 - content_hash (for success/failure cache update)
#   $6 - resolved_model (empty = let helper choose)
#   $7 - verified item kind ("issue" or "pr")
#   $8 - expected immutable PR revision pair (empty for issues)
#   $9 - expected mutable issue/PR text snapshot hash
#   $10 - expected public evidence revision
#   $11 - canonical workload tier (default: thinking)
#
# Exit code: always 0
#######################################
_dispatch_triage_review_worker() {
	local issue_num="$1"
	local repo_slug="$2"
	local repo_path="$3"
	local prefetch_file="$4"
	local content_hash="$5"
	local resolved_model="${6:-}"
	local item_kind="$7"
	local expected_pr_revision="${8:-}"
	local expected_text_snapshot="${9:-}"
	local expected_public_revision="${10:-}"
	local resolved_tier="${11:-thinking}"
	_PAD_TRIAGE_LAST_OUTCOME="$_PAD_TRIAGE_OUTCOME_INFRASTRUCTURE_FAILED"

	local model_flag=""
	[[ -n "$resolved_model" ]] && model_flag="--model $resolved_model"

	# The caller supplies the explicit restricted triage-review agent; the
	# format-first prefetched prompt remains the primary constraint.
	local review_artifact_dir="${prefetch_file%/*}"
	local review_output_file="${review_artifact_dir}/review-output.ndjson"
	if ! (umask 077 && : >"$review_output_file"); then
		if ! _triage_cleanup_sensitive_artifact_dir "$review_artifact_dir"; then
			echo "[pulse-wrapper] Triage runtime artifact cleanup failed for #${issue_num} in ${repo_slug}; guardian retained" >>"$LOGFILE"
		fi
		_finalize_triage_state \
			"$issue_num" "$repo_slug" "$content_hash" \
			"false" "$_PAD_TRIAGE_RUNTIME_TEMP_FAILURE_REASON" "0"
		return 0
	fi

	# Run the no-tools triage-review agent under a distinct role so the
	# implementation-worker issue/worktree contract does not reject it before
	# model launch (GH#23854/GH#28705).
	local runtime_status=0
	_run_triage_review_worker \
		"$issue_num" "$repo_slug" "$repo_path" \
		"$model_flag" "$prefetch_file" "$review_output_file" \
		"$resolved_tier" || runtime_status=$?

	# t2019: Extract raw metrics and text content from the JSON stream.
	# The headless runtime emits line-delimited JSON; the model's markdown
	# is embedded in "text" fields — extract before filtering so header
	# detection works on decoded text, not raw JSON escaping.
	local raw_output_chars=0
	if [[ -f "$review_output_file" ]]; then
		raw_output_chars=$(wc -c <"$review_output_file" 2>/dev/null || echo 0)
		raw_output_chars="${raw_output_chars// /}"
	fi

	local review_text=""
	review_text=$(_extract_review_text_from_json "$review_output_file")
	local output_chars="${#review_text}"

	# Inspect a bounded sample in memory for deterministic infrastructure
	# classification only. Suppression diagnostics never retain this content.
	local raw_sample=""
	if [[ -f "$review_output_file" ]]; then
		raw_sample=$(head -c 1000 "$review_output_file" 2>/dev/null || true)
	fi
	local artifact_cleanup_status=0
	_triage_cleanup_sensitive_artifact_dir "$review_artifact_dir" \
		|| artifact_cleanup_status=$?

	# t2089/GH#23854: Detect runtime/prelaunch failures BEFORE finalising triage
	# state. The safety filter must still suppress any output, but infra
	# failures must not consume retry budget or cache the content hash.
	local infra_failure_reason=""
	infra_failure_reason=$(_triage_runtime_result_failure_reason \
		"$runtime_status" "$artifact_cleanup_status" "$raw_sample")
	if [[ -n "$infra_failure_reason" ]]; then
		echo "[pulse-wrapper] Triage runtime failure for #${issue_num} in ${repo_slug}: ${infra_failure_reason} — infrastructure/contract failure, not a review failure (GH#23854)" >>"$LOGFILE"
	fi

	# Validate output safety and post or suppress the review comment.
	local post_result=""
	if [[ -n "$infra_failure_reason" ]]; then
		post_result="FAILED:${infra_failure_reason}"
	else
		post_result=$(_extract_and_post_triage_review \
			"$issue_num" "$repo_slug" "$review_text" "$output_chars" \
			"$raw_output_chars" "$item_kind" "$expected_pr_revision" \
			"$expected_text_snapshot" "$expected_public_revision")
	fi

	local triage_posted="false" failure_reason="" outcome_fields=""
	outcome_fields=$(_triage_review_result_fields "$post_result" "$infra_failure_reason")
	IFS='|' read -r triage_posted failure_reason _PAD_TRIAGE_LAST_OUTCOME <<<"$outcome_fields"

	# Update labels and content-hash cache.
	_finalize_triage_state \
		"$issue_num" "$repo_slug" "$content_hash" \
		"$triage_posted" "$failure_reason" "$output_chars"

	return 0
}

_triage_outcome_json() {
	local attempted="$1"
	local posted="$2"
	local review_failed="$3"
	local infrastructure_failed="$4"
	local preparation_failed="$5"
	jq -cn \
		--arg schema "$_PAD_TRIAGE_OUTCOME_SCHEMA" \
		--argjson attempted "$attempted" \
		--argjson posted "$posted" \
		--argjson review_failed "$review_failed" \
		--argjson infrastructure_failed "$infrastructure_failed" \
		--argjson preparation_failed "$preparation_failed" \
		'{schema:$schema, attempted:$attempted, posted:$posted, review_failed:$review_failed, infrastructure_failed:$infrastructure_failed, preparation_failed:$preparation_failed}'
	return 0
}

#######################################
# Validate independently propagated prompt metadata before worker dispatch.
#######################################
_triage_prompt_metadata_is_valid() {
	local item_kind="$1"
	local expected_pr_revision="$2"
	local expected_text_snapshot="$3"
	local expected_public_revision="$4"
	[[ "$expected_public_revision" =~ ^[0-9a-f]{40,64}$ ]] || return 1

	case "$item_kind" in
	issue)
		[[ -z "$expected_pr_revision" && \
			"$expected_text_snapshot" =~ ^[0-9a-f]{64}$ ]] || return 1
		;;
	pr)
		[[ "$expected_pr_revision" =~ ^[0-9a-f]{40,64}:[0-9a-f]{40,64}$ && \
			"$expected_text_snapshot" =~ ^[0-9a-f]{64}$ && \
			"${expected_pr_revision#*:}" == "$expected_public_revision" ]] || return 1
		;;
	*) return 1 ;;
	esac
	return 0
}

_triage_review_candidates() {
	local triage_file="$1"
	local repos_json="$2"
	local line="" current_slug="" current_path="" issue_num="" author="" metadata_line=""
	local priority_candidates="" regular_candidates="" candidate_count=0
	local author_suffix_regex='\[author: @([A-Za-z0-9-]+)\]$'
	local review_suffix_regex='\[status: \*\*needs-review\*\*\] \[created: [^]]+\]$'
	while IFS= read -r line; do
		if [[ "$line" =~ ^##[[:space:]]+([^[:space:]]+/[^[:space:]]+) ]]; then
			current_slug="${BASH_REMATCH[1]}"
			current_path=$(jq -r --arg s "$current_slug" '.initialized_repos[]? | select(.slug == $s) | .path' "$repos_json" 2>/dev/null || printf '')
			current_path="${current_path/#\~/$HOME}"
			continue
		fi
		author=""
		metadata_line="$line"
		if [[ "$line" =~ $author_suffix_regex ]]; then
			author="${BASH_REMATCH[1]}"
			metadata_line="${line% \[author: @"${author}"\]}"
		fi
		if [[ "$metadata_line" =~ $review_suffix_regex && "$metadata_line" =~ Issue\ #([0-9]+) ]]; then
			issue_num="${BASH_REMATCH[1]}"
			if [[ -n "$current_slug" && -n "$current_path" ]]; then
				local candidate="${issue_num}|${current_slug}|${current_path}|${author}"
				if _triage_author_is_known_contributor "$author"; then
					priority_candidates="${priority_candidates}${candidate}"$'\n'
				else
					regular_candidates="${regular_candidates}${candidate}"$'\n'
				fi
				candidate_count=$((candidate_count + 1))
			fi
		fi
	done <"$triage_file"
	echo "[pulse-wrapper] dispatch_triage_reviews: parsed ${candidate_count} candidates from state file" >>"$LOGFILE"
	printf '%s%s' "$priority_candidates" "$regular_candidates"
	return 0
}

_triage_author_is_known_contributor() {
	local author="$1"
	local known_contributors="${PULSE_TRIAGE_KNOWN_CONTRIBUTORS:-}"
	local author_normalized="" known_normalized=""
	[[ "$author" =~ ^[A-Za-z0-9-]+$ && -n "$known_contributors" ]] || return 1
	author_normalized=$(printf '%s' "$author" | tr '[:upper:]' '[:lower:]')
	known_normalized=$(printf ',%s,' "$known_contributors" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	case "$known_normalized" in
	*,"$author_normalized",*) return 0 ;;
	*) return 1 ;;
	esac
}


#######################################
# Read a bounded PR diff for one immutable base/head commit pair.
#
# Arguments:
#   $1 - repo_slug
#   $2 - base SHA
#   $3 - head SHA
#
# Output: complete immutable diff text when it fits the review bound.
# Returns: 0=complete, 1=read/validation failure, 2=diff exceeds the bound.
#######################################
_triage_pr_diff_for_revision_rest() {
	local repo_slug="$1"
	local base_sha="$2"
	local head_sha="$3"
	local compare_diff=""

	[[ -n "$repo_slug" && "$base_sha" =~ ^[0-9a-f]{40,64}$ && \
		"$head_sha" =~ ^[0-9a-f]{40,64}$ ]] || return 1
	compare_diff=$(AIDEVOPS_GH_ROUTE_DECISION="pulse-triage-pr-diff-rest" \
		gh api -H 'Accept: application/vnd.github.v3.diff' \
			"repos/${repo_slug}/compare/${base_sha}...${head_sha}" \
			2>/dev/null) || return 1
	local diff_byte_count=""
	diff_byte_count=$(_triage_text_byte_count "$compare_diff") || return 1
	[[ "$diff_byte_count" -le "$_PAD_TRIAGE_MAX_DIFF_BYTES" ]] || return 2
	local diff_line_count=""
	diff_line_count=$(printf '%s\n' "$compare_diff" | awk 'END { print NR }') || return 1
	[[ "$diff_line_count" =~ ^[0-9]+$ ]] || return 1
	[[ "$diff_line_count" -le "$_PAD_TRIAGE_MAX_DIFF_LINES" ]] || return 2
	printf '%s\n' "$compare_diff"
	return 0
}

#######################################
# Read changed-file paths for one immutable base/head pair. GitHub caps the
# compare response at 300 files, so an exact-cap response fails closed rather
# than treating a potentially truncated list as complete.
#
# Arguments:
#   $1 - repo_slug
#   $2 - base SHA
#   $3 - head SHA
#
# Output: JSON array of changed-file paths.
#######################################
_triage_pr_file_paths_json_rest() {
	local repo_slug="$1"
	local base_sha="$2"
	local head_sha="$3"
	local pr_files=""

	[[ -n "$repo_slug" && "$base_sha" =~ ^[0-9a-f]{40,64}$ && \
		"$head_sha" =~ ^[0-9a-f]{40,64}$ ]] || return 1
	pr_files=$(AIDEVOPS_GH_ROUTE_DECISION="pulse-triage-pr-files-rest" \
		gh api "repos/${repo_slug}/compare/${base_sha}...${head_sha}" \
			--jq 'if ((.files | type) == "array" and (.files | length) < 300) then [.files[].filename] else error("incomplete compare files") end') || return 1
	local pr_files_bytes=""
	pr_files_bytes=$(_triage_text_byte_count "$pr_files") || return 1
	[[ "$pr_files_bytes" -le "$_PAD_TRIAGE_MAX_PR_FILES_BYTES" ]] || return 2
	printf '%s\n' "$pr_files"
	return 0
}

#######################################
# Read the immutable base/head commit pair for a PR.
# Output: "<base_sha>:<head_sha>"
# Returns: 0=valid pair, 1=API failure, 2=malformed response.
#######################################
_triage_pr_revision_pair_rest() {
	local pr_number="$1"
	local repo_slug="$2"
	local revision_pair=""

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 2
	revision_pair=$(gh api "repos/${repo_slug}/pulls/${pr_number}" \
		--jq '"\(.base.sha // ""):\(.head.sha // "")"' 2>/dev/null) || return 1
	[[ "$revision_pair" =~ ^[0-9a-f]{40,64}:[0-9a-f]{40,64}$ ]] || return 2
	printf '%s\n' "$revision_pair"
	return 0
}

#######################################
# Re-read mutable issue/PR text and any PR revision immediately before comment
# posting. Expected identities travel independently from the model prompt so a
# concurrent edit cannot attach a recommendation to different public content.
#
# Outputs a controlled infrastructure reason, or nothing when every mutable
# snapshot and public evidence revision is unchanged. Returns 0 always.
#######################################
_triage_post_snapshot_failure_reason() {
	local item_number="$1"
	local repo_slug="$2"
	local item_kind="$3"
	local expected_pair="$4"
	local expected_text_snapshot="$5"
	local expected_public_revision="${6:-}"

	if [[ ! "$expected_text_snapshot" =~ ^[0-9a-f]{64}$ ]]; then
		printf '%s\n' 'triage-current-snapshot-hash-failed'
		return 0
	fi
	local current_issue_json=""
	local current_issue_comments=""
	local current_issue_body=""
	if ! _triage_prefetch_issue "$item_number" "$repo_slug" \
		"current_issue_json" "current_issue_comments" "current_issue_body"; then
		printf '%s\n' 'github-current-snapshot-read-failed'
		return 0
	fi
	local current_text_snapshot=""
	if ! current_text_snapshot=$(_triage_current_text_snapshot_hash \
		"$current_issue_json" "$current_issue_comments"); then
		printf '%s\n' 'triage-current-snapshot-hash-failed'
		return 0
	fi
	if [[ "$current_text_snapshot" != "$expected_text_snapshot" ]]; then
		printf '%s\n' 'github-current-snapshot-changed-before-post'
		return 0
	fi

	if [[ ! "$expected_public_revision" =~ ^[0-9a-f]{40,64}$ ]]; then
		printf '%s\n' 'github-public-revision-read-malformed'
		return 0
	fi
	if [[ "$item_kind" == "issue" ]]; then
		local current_public_revision=""
		local public_revision_status=0
		current_public_revision=$(_triage_default_branch_revision_rest \
			"$repo_slug") || public_revision_status=$?
		if [[ "$public_revision_status" -ne 0 ]]; then
			if [[ "$public_revision_status" -eq 1 ]]; then
				printf '%s\n' 'github-public-revision-read-failed'
			else
				printf '%s\n' 'github-public-revision-read-malformed'
			fi
			return 0
		fi
		if [[ "$current_public_revision" != "$expected_public_revision" ]]; then
			printf '%s\n' 'github-public-revision-changed-before-post'
		fi
		return 0
	fi
	if [[ ! "$expected_pair" =~ ^[0-9a-f]{40,64}:[0-9a-f]{40,64}$ ]]; then
		printf '%s\n' 'github-pr-revision-read-malformed'
		return 0
	fi
	if [[ "${expected_pair#*:}" != "$expected_public_revision" ]]; then
		printf '%s\n' 'github-public-revision-read-malformed'
		return 0
	fi

	local current_pair=""
	local revision_status=0
	current_pair=$(_triage_pr_revision_pair_rest \
		"$item_number" "$repo_slug") || revision_status=$?
	if [[ "$revision_status" -ne 0 ]]; then
		if [[ "$revision_status" -eq 1 ]]; then
			printf '%s\n' 'github-pr-revision-read-failed'
		else
			printf '%s\n' 'github-pr-revision-read-malformed'
		fi
		return 0
	fi
	if [[ "$current_pair" != "$expected_pair" ]]; then
		printf '%s\n' 'github-pr-revision-changed-before-post'
	fi
	return 0
}

#######################################
# Fetch a PR diff/file snapshot and verify its revision pair did not change
# across the mutable GitHub reads. Named outputs receive base SHA, head SHA,
# bounded diff text, and changed-file JSON.
#######################################
_triage_fetch_pr_snapshot() {
	local pr_number="$1"
	local repo_slug="$2"
	local base_sha_var="$3"
	local head_sha_var="$4"
	local diff_var="$5"
	local files_var="$6"
	local _ps_pair=""
	local _ps_status=0

	_ps_pair=$(_triage_pr_revision_pair_rest "$pr_number" "$repo_slug") || _ps_status=$?
	if [[ "$_ps_status" -ne 0 ]]; then
		local _ps_reason="github-pr-revision-read-failed"
		[[ "$_ps_status" -eq 1 ]] || _ps_reason="github-pr-revision-read-malformed"
		_triage_mark_infrastructure_retry "$pr_number" "$repo_slug" "$_ps_reason"
		return 1
	fi
	local _ps_base_sha="${_ps_pair%%:*}"
	local _ps_head_sha="${_ps_pair#*:}"
	local _ps_diff=""
	local _ps_diff_status=0
	_ps_diff=$(_triage_pr_diff_for_revision_rest \
		"$repo_slug" "$_ps_base_sha" "$_ps_head_sha") || _ps_diff_status=$?
	if [[ "$_ps_diff_status" -ne 0 ]]; then
		local _ps_diff_reason="github-pr-diff-read-failed"
		[[ "$_ps_diff_status" -ne 2 ]] || _ps_diff_reason="github-pr-diff-too-large"
		_triage_mark_infrastructure_retry \
			"$pr_number" "$repo_slug" "$_ps_diff_reason"
		return 1
	fi
	local _ps_files=""
	local _ps_files_status=0
	_ps_files=$(_triage_pr_file_paths_json_rest \
		"$repo_slug" "$_ps_base_sha" "$_ps_head_sha" 2>/dev/null) \
		|| _ps_files_status=$?
	if [[ "$_ps_files_status" -ne 0 ]]; then
		local _ps_files_reason="github-pr-files-read-failed"
		[[ "$_ps_files_status" -ne 2 ]] || _ps_files_reason="github-pr-files-too-large"
		_triage_mark_infrastructure_retry \
			"$pr_number" "$repo_slug" "$_ps_files_reason"
		return 1
	fi
	if ! printf '%s' "$_ps_files" | jq -e \
		--arg array_type "$_PAD_JSON_ARRAY_TYPE" \
		--arg string_type "$_PAD_JSON_STRING_TYPE" \
		'type == $array_type and all(.[]; type == $string_type)' \
		>/dev/null 2>&1; then
		_triage_mark_infrastructure_retry \
			"$pr_number" "$repo_slug" "github-pr-files-read-malformed"
		return 1
	fi

	local _ps_verified_pair=""
	_ps_status=0
	_ps_verified_pair=$(_triage_pr_revision_pair_rest \
		"$pr_number" "$repo_slug") || _ps_status=$?
	if [[ "$_ps_status" -ne 0 ]]; then
		local _ps_verify_reason="github-pr-revision-read-failed"
		[[ "$_ps_status" -eq 1 ]] || _ps_verify_reason="github-pr-revision-read-malformed"
		_triage_mark_infrastructure_retry "$pr_number" "$repo_slug" "$_ps_verify_reason"
		return 1
	fi
	if [[ "$_ps_verified_pair" != "$_ps_pair" ]]; then
		_triage_mark_infrastructure_retry \
			"$pr_number" "$repo_slug" "github-pr-revision-changed"
		return 1
	fi

	printf -v "$base_sha_var" '%s' "$_ps_base_sha"
	printf -v "$head_sha_var" '%s' "$_ps_head_sha"
	printf -v "$diff_var" '%s' "$_ps_diff"
	printf -v "$files_var" '%s' "$_ps_files"
	return 0
}

#######################################
# Extract canonical cache metadata from a validated issue/PR payload.
#######################################
_triage_issue_cache_metadata() {
	local issue_json="$1"
	local issue_title_var="$2"
	local issue_labels_var="$3"
	local issue_title=""
	local issue_labels=""

	issue_title=$(printf '%s' "$issue_json" | jq -r '.title' 2>/dev/null) || return 1
	issue_labels=$(printf '%s' "$issue_json" \
		| jq -ceS '[.labels[].name] | sort' 2>/dev/null) || return 1
	printf -v "$issue_title_var" '%s' "$issue_title"
	printf -v "$issue_labels_var" '%s' "$issue_labels"
	return 0
}

#######################################
# Return whether the review follows the exact ordered schema for the verified
# item kind. This rejects extra/reordered headings, prose, code fences, invalid
# table choices, duplicate fields, cross-kind schemas, and trailing text.
#
# Arguments:
#   $1 - extracted review text
#   $2 - verified item kind ("issue" or "pr")
#######################################
_triage_review_structure_is_exact() {
	local review_text="$1"
	local item_kind="$2"
	# shellcheck disable=SC2016 # Embedded Python is intentionally literal.
	if python3 -c '
import re
import sys

lines = [line for line in sys.stdin.read().splitlines() if line]
item_kind = sys.argv[1]

def exact(value):
    return lambda line: line == value

def pattern(value):
    compiled = re.compile(value)
    return lambda line: compiled.fullmatch(line) is not None

issue = [
    pattern(r"## Review: Recommendation: (Approve|Request Changes|Decline)"),
    exact("### Issue Validation"),
    exact("| Check | Status | Notes |"),
    exact("|-------|--------|-------|"),
    pattern(r"\| Reproducible \| (Yes|No|Unclear) \| [^|\n]+ \|"),
    pattern(r"\| Not duplicate \| (Yes|No) \| [^|\n]+ \|"),
    pattern(r"\| Actual bug \| (Yes|No) \| [^|\n]+ \|"),
    pattern(r"\| In scope \| (Yes|No) \| [^|\n]+ \|"),
    pattern(r"\*\*Root Cause:\*\* .+"),
]
solution = [
    exact("### Solution Evaluation (PR only — omit section for issues)"),
    exact("| Criterion | Assessment | Notes |"),
    exact("|-----------|------------|-------|"),
    pattern(r"\| Simplicity \| (Good|Needs Work) \| [^|\n]+ \|"),
    pattern(r"\| Correctness \| (Good|Needs Work) \| [^|\n]+ \|"),
    pattern(r"\| Completeness \| (Good|Needs Work) \| [^|\n]+ \|"),
    pattern(r"\| Security \| (Good|Concern) \| [^|\n]+ \|"),
]
scope = [
    exact("### Scope & Recommendation"),
    pattern(r"- \*\*Scope creep:\*\* (Low|Medium|High)"),
    pattern(r"- \*\*Complexity tier:\*\* `tier:(simple|standard|thinking)`"),
    pattern(r"- \*\*Recommendation:\*\* (APPROVE|REQUEST CHANGES|DECLINE)"),
    pattern(r"- \*\*PR disposition:\*\* (MERGE|REPAIR|REPLACE|CLOSE|NOT APPLICABLE) — .+"),
    pattern(r"- \*\*Recommended labels:\*\* .+"),
    pattern(r"- \*\*Implementation guidance:\*\* .+"),
]

def matches(schema):
    return len(lines) == len(schema) and all(check(line) for check, line in zip(schema, lines))

if item_kind == "issue":
    schema = issue + scope
elif item_kind == "pr":
    schema = issue + solution + scope
else:
    raise SystemExit(1)
raise SystemExit(0 if matches(schema) else 1)
' "$item_kind" <<<"$review_text" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

#######################################
# Return a controlled failure tag when a triage review violates the exact
# recommendation template. A valid review has one literal first-line decision,
# every required section/field, no additional prose, a matching recommendation
# field, and <=800 words. Empty output is invalid.
#######################################
_triage_review_shape_failure_reason() {
	local review_text="$1"
	local item_kind="$2"
	local first_line="${review_text%%$'\n'*}"
	local expected_recommendation=""
	case "$first_line" in
	"## Review: Recommendation: Approve") expected_recommendation="APPROVE" ;;
	"## Review: Recommendation: Request Changes") expected_recommendation="REQUEST CHANGES" ;;
	"## Review: Recommendation: Decline") expected_recommendation="DECLINE" ;;
	*)
		printf '%s\n' 'invalid-review-first-line'
		return 0
		;;
	esac

	local word_count=0
	word_count=$(printf '%s' "$review_text" | wc -w | tr -d '[:space:]')
	[[ "$word_count" =~ ^[0-9]+$ ]] || word_count=0
	if [[ "$word_count" -gt 800 ]]; then
		printf '%s\n' 'review-word-limit'
		return 0
	fi

	local review_header_count=0
	review_header_count=$(printf '%s\n' "$review_text" | grep -cE '^## Review:' 2>/dev/null || true)
	if [[ "$review_header_count" -ne 1 ]]; then
		printf '%s\n' 'duplicate-review-header'
		return 0
	fi

	if ! _triage_review_structure_is_exact "$review_text" "$item_kind"; then
		printf '%s\n' 'invalid-review-shape'
		return 0
	fi
	if ! printf '%s\n' "$review_text" \
		| grep -qxF -- "- **Recommendation:** ${expected_recommendation}" 2>/dev/null; then
		printf '%s\n' 'recommendation-mismatch'
		return 0
	fi

	return 0
}

#######################################
# Produce a sanitized, bounded diagnostic for a failed triage comment write.
#
# Arguments:
#   $1 - gh exit status
#   $2 - stderr artifact path
#######################################
_triage_comment_write_failure_detail() {
	local post_status="$1"
	local stderr_file="$2"
	local stderr_text=""
	local category="gh-command-failed"
	local response_status=""

	if [[ -s "$stderr_file" ]]; then
		stderr_text=$(tr '\n' ' ' <"$stderr_file")
	fi
	if [[ "$stderr_text" =~ (HTTP[[:space:]]+|status[=:[:space:]]+)([1-5][0-9][0-9]) ]]; then
		response_status="${BASH_REMATCH[2]}"
	fi
	case "$stderr_text" in
	*"rate limit"* | *"Rate limit"* | *"rate-limit"*) category="api-rate-limited" ;;
	*"authentication"* | *"Authentication"* | *"Bad credentials"*) category="authentication-failed" ;;
	*"validation failed"* | *"Validation Failed"*) category="body-validation-failed" ;;
	*"permission"* | *"Permission"* | *"Resource not accessible"*) category="permission-denied" ;;
	*"timeout"* | *"Timeout"* | *"timed out"*) category="network-timeout" ;;
	*"connection"* | *"Connection"* | *"resolve host"*) category="network-failed" ;;
	esac
	if [[ -n "$response_status" ]]; then
		printf 'rc=%s category=%s status=%s\n' "$post_status" "$category" "$response_status"
	else
		printf 'rc=%s category=%s\n' "$post_status" "$category"
	fi
	return 0
}

#######################################
# Post a validated triage review through a body file. On transport failure,
# prints a sanitized diagnostic and returns the GitHub write status.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#   $3 - validated review text
#######################################
_post_triage_review_comment() {
	local issue_num="$1"
	local repo_slug="$2"
	local review_text="$3"
	local review_marker="${TRIAGE_REVIEW_COMMENT_MARKER:-<!-- aidevops:triage-review -->}"
	local signature_helper="${TRIAGE_SIGNATURE_HELPER:-${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh}"
	local signature_footer=""
	local comment_dir=""
	local error_dir=""
	comment_dir=$(_triage_create_sensitive_artifact_dir "comment") || return 1
	error_dir=$(_triage_create_sensitive_artifact_dir "comment-error") || {
		_triage_cleanup_sensitive_artifact_dir "$comment_dir" || true
		return 1
	}
	local body_file="${comment_dir}/comment.md"
	local stderr_file="${error_dir}/gh.stderr"
	if [[ ! -x "$signature_helper" ]] || \
		! signature_footer=$("$signature_helper" footer \
			--model "pulse-triage" --issue "${repo_slug}#${issue_num}" 2>/dev/null) || \
		[[ "$signature_footer" != *"<!-- aidevops:sig -->"* ]]; then
		_triage_cleanup_sensitive_artifact_dir "$comment_dir" || true
		_triage_cleanup_sensitive_artifact_dir "$error_dir" || true
		return 1
	fi
	(umask 077 && printf '%s\n\n%s\n%s\n' \
		"$review_text" "$review_marker" "$signature_footer" >"$body_file") || {
		if ! _triage_cleanup_sensitive_artifact_dir "$comment_dir"; then
			echo "[pulse-wrapper] Triage comment artifact cleanup failed for #${issue_num} in ${repo_slug}; guardian retained" >>"$LOGFILE"
		fi
		_triage_cleanup_sensitive_artifact_dir "$error_dir" || true
		return 1
	}
	local post_status=0
	local cleanup_status=0
	local error_cleanup_status=0
	local post_failure_detail=""
	# The exact gh shim validates the signed body and privacy policy while this
	# private pathname remains independently readable. Its explicit ephemeral
	# mode opens the body, removes and verifies the managed directory, and only
	# then starts the external write through /dev/fd/9. The wrapper disables its
	# REST retry because this transport is intentionally one-shot.
	AIDEVOPS_GH_EPHEMERAL_BODY_FILE="$body_file" \
		gh_issue_comment "$issue_num" --repo "$repo_slug" \
			--body-file "$body_file" >/dev/null 2>"$stderr_file" || post_status=$?
	if [[ "$post_status" -ne 0 ]]; then
		post_failure_detail=$(_triage_comment_write_failure_detail \
			"$post_status" "$stderr_file")
	fi
	_triage_cleanup_sensitive_artifact_dir "$comment_dir" || cleanup_status=$?
	_triage_cleanup_sensitive_artifact_dir "$error_dir" || error_cleanup_status=$?
	if [[ "$cleanup_status" -ne 0 ]]; then
		echo "[pulse-wrapper] Triage comment artifact cleanup failed for #${issue_num} in ${repo_slug}; post treated as failed, guardian retained" >>"$LOGFILE"
		printf 'rc=%s category=comment-artifact-cleanup-failed\n' "$post_status"
		return 1
	fi
	if [[ "$error_cleanup_status" -ne 0 ]]; then
		echo "[pulse-wrapper] Triage comment error artifact cleanup failed for #${issue_num} in ${repo_slug}; guardian retained" >>"$LOGFILE"
		printf 'rc=%s category=comment-error-artifact-cleanup-failed\n' "$post_status"
		return 1
	fi
	if [[ "$post_status" -ne 0 ]]; then
		printf '%s\n' "$post_failure_detail"
	fi
	return "$post_status"
}

#######################################
# Validate triage review output and post if safe.
#
# Checks for oversized output, infrastructure markers, exact first-line and
# structural shape, and the word ceiling. Posts only through the body-file
# helper after every deterministic check passes.
#
# Arguments:
#   $1 - issue_num
#   $2 - repo_slug
#   $3 - review_text (extracted from JSON stream output)
#   $4 - output_chars (char count of review_text)
#   $5 - raw_output_chars (char count of raw runtime output)
#   $6 - verified item kind ("issue" or "pr")
#   $7 - expected immutable PR revision pair (empty for issues)
#   $8 - expected mutable issue/PR text snapshot hash
#   $9 - expected public evidence revision
#
# Outputs to stdout: "POSTED" if posted, "FAILED:<reason>" if suppressed.
# Returns 0 always.
#######################################
_extract_and_post_triage_review() {
	local issue_num="$1"
	local repo_slug="$2"
	local review_text="$3"
	local output_chars="$4"
	local raw_output_chars="$5"
	local item_kind="$6"
	local expected_pr_revision="${7:-}"
	local expected_text_snapshot="${8:-}"
	local expected_public_revision="${9:-}"

	# t2019: Shape ceiling — a valid triage review is 1-3KB. Anything over
	# 20KB of extracted text is a malfunctioning worker (tool exploration,
	# runaway summarisation, format drift). Suppress fast so the retry cap
	# isn't wasted and the escalation comment is posted sooner.
	local TRIAGE_OUTPUT_MAX_CHARS="${TRIAGE_OUTPUT_MAX_CHARS:-20000}"
	if [[ -n "$review_text" && "$output_chars" -gt "$TRIAGE_OUTPUT_MAX_CHARS" ]]; then
		echo "[pulse-wrapper] Triage review for #${issue_num} produced oversized output (${output_chars} extracted chars / ${raw_output_chars} raw, ceiling=${TRIAGE_OUTPUT_MAX_CHARS}) — suppressed (t2019)" >>"$LOGFILE"
		_log_suppressed_triage_output "$issue_num" "$repo_slug" \
			"oversized-output" "$output_chars"
		printf 'FAILED:oversized-output\n'
		return 0
	fi

	if [[ -z "$review_text" || "${#review_text}" -le 50 ]]; then
		echo "[pulse-wrapper] Triage review for #${issue_num} produced no usable output (${#review_text} chars extracted / ${raw_output_chars} raw)" >>"$LOGFILE"
		_log_suppressed_triage_output "$issue_num" "$repo_slug" \
			"no-usable-output" "$output_chars"
		printf 'FAILED:no-usable-output\n'
		return 0
	fi

	# NEVER post raw sandbox/infrastructure output. A failed runtime may mix
	# startup logs, execution metadata, or internal paths into model text.
	if printf '%s\n' "$review_text" | grep -qE '\[SANDBOX\]|\[INFO\] Executing|timeout=[0-9]+s|network_blocked=|sandbox-exec-helper|/opt/homebrew/|opencode run ' 2>/dev/null; then
		echo "[pulse-wrapper] SECURITY: triage review for #${issue_num} contained raw sandbox output — suppressed (${#review_text} chars)" >>"$LOGFILE"
		_log_suppressed_triage_output "$issue_num" "$repo_slug" \
			"raw-sandbox-output" "$output_chars"
		printf 'FAILED:raw-sandbox-output\n'
		return 0
	fi

	local shape_failure=""
	shape_failure=$(_triage_review_shape_failure_reason "$review_text" "$item_kind")
	if [[ -n "$shape_failure" ]]; then
		echo "[pulse-wrapper] Triage review for #${issue_num} failed exact output validation (${shape_failure}; ${output_chars} extracted chars / ${raw_output_chars} raw) — suppressed" >>"$LOGFILE"
		_log_suppressed_triage_output "$issue_num" "$repo_slug" \
			"$shape_failure" "$output_chars"
		printf 'FAILED:%s\n' "$shape_failure"
		return 0
	fi

	local snapshot_failure=""
	snapshot_failure=$(_triage_post_snapshot_failure_reason \
		"$issue_num" "$repo_slug" "$item_kind" \
		"$expected_pr_revision" "$expected_text_snapshot" \
		"$expected_public_revision")
	if [[ -n "$snapshot_failure" ]]; then
		echo "[pulse-wrapper] Triage review for #${issue_num} suppressed before post (${snapshot_failure})" >>"$LOGFILE"
		printf 'FAILED:%s\n' "$snapshot_failure"
		return 0
	fi

	if ! _set_triage_recommendation_label "$issue_num" "$repo_slug" "$review_text"; then
		echo "[pulse-wrapper] Triage advisory label write failed for #${issue_num} in ${repo_slug} — comment suppressed, will retry" >>"$LOGFILE"
		printf 'FAILED:github-review-label-write-failed\n'
		return 0
	fi

	local comment_failure_detail=""
	if ! comment_failure_detail=$(_post_triage_review_comment "$issue_num" "$repo_slug" "$review_text"); then
		echo "[pulse-wrapper] Triage review comment write failed for #${issue_num} in ${repo_slug}: ${comment_failure_detail:-rc=unknown category=unknown} — infrastructure failure, will retry" >>"$LOGFILE"
		printf 'FAILED:github-comment-write-failed\n'
		return 0
	fi
	echo "[pulse-wrapper] Posted sandboxed triage review for #${issue_num} in ${repo_slug} (${output_chars} extracted chars)" >>"$LOGFILE"
	printf 'POSTED\n'
	return 0
}
