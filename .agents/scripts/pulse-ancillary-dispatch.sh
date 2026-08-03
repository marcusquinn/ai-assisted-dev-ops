#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-ancillary-dispatch.sh — Ancillary worker dispatch — triage reviews, needs-info relabel, routine comment responses, FOSS workers.
#
# Extracted from pulse-wrapper.sh in Phase 10 (FINAL) of the phased
# decomposition (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# Phase 12 (t2000, GH#18448): dispatch_triage_reviews() split into three
# functions to reduce size from 291 to <80 lines and improve testability.
#
# Focused helper groups live in pulse-ancillary-dispatch-{core,evidence,review}.sh.
# This orchestrator retains the public entry points and functions whose original
# file identity must remain stable for complexity-regression measurements.

[[ -n "${_PULSE_ANCILLARY_DISPATCH_LOADED:-}" ]] && return 0
_PULSE_ANCILLARY_DISPATCH_LOADED=1

# t2863: Module-level variable defaults (set -u guards).
# Ensures bare var refs are safe when this module is sourced outside the full
# pulse-wrapper.sh bootstrap (e.g. test harnesses, standalone dispatch calls).
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
_pad_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${HEADLESS_RUNTIME_HELPER:=${_pad_script_dir}/headless-runtime-helper.sh}"
: "${MODEL_AVAILABILITY_HELPER:=${_pad_script_dir}/model-availability-helper.sh}"
: "${TRIAGE_CONTENT_SCANNER:=${_pad_script_dir}/content-scanner-helper.sh}"
: "${TRIAGE_PROMPT_GUARD:=${_pad_script_dir}/prompt-guard-helper.sh}"
# shellcheck source=./sensitive-temp-helper.sh
# shellcheck disable=SC1091  # helper path resolves from this module at runtime
source "${_pad_script_dir}/sensitive-temp-helper.sh"
_PAD_JSON_ARRAY_TYPE="array"
_PAD_JSON_STRING_TYPE="string"
_PAD_TRIAGE_RUNTIME_TEMP_FAILURE_REASON="triage-runtime-temp-failed"
_PAD_TRIAGE_OUTCOME_SCHEMA="aidevops.pulse-triage-outcome/v1"
_PAD_TRIAGE_OUTCOME_POSTED="posted"
_PAD_TRIAGE_OUTCOME_REVIEW_FAILED="review_failed"
_PAD_TRIAGE_OUTCOME_INFRASTRUCTURE_FAILED="infrastructure_failed"
_PAD_TRIAGE_LAST_OUTCOME=""
_PAD_REVIEW_HOLD_LABEL="hold-for-review"
_PAD_GITHUB_COMMENTS_READ_MALFORMED_REASON="github-comments-read-malformed"
_PAD_GITHUB_COMMENTS_SNAPSHOT_TOO_LARGE_REASON="github-comments-snapshot-too-large"
_PAD_TRIAGE_MAX_COMMENTS=100
_PAD_TRIAGE_MAX_COMMENT_BYTES=1048576
_PAD_TRIAGE_MAX_PROMPT_COMMENT_BYTES=8192
_PAD_TRIAGE_MAX_DIFF_LINES=500
_PAD_TRIAGE_MAX_DIFF_BYTES=65536
_PAD_TRIAGE_MAX_CITED_BLOB_BYTES=1048576
_PAD_TRIAGE_MAX_CITED_SNIPPET_BYTES=16384
_PAD_TRIAGE_MAX_FILE_EVIDENCE_BYTES=65536
_PAD_TRIAGE_MAX_PUBLIC_HISTORY_BYTES=65536
_PAD_TRIAGE_MAX_PR_FILES_BYTES=65536
_PAD_TRIAGE_MAX_PROMPT_BYTES=2097152

# Focused sub-libraries keep this orchestrator below the file-size gate.
# shellcheck source=./pulse-ancillary-dispatch-core.sh
# shellcheck disable=SC1091  # sub-library resolved from this module at runtime
source "${_pad_script_dir}/pulse-ancillary-dispatch-core.sh"
# shellcheck source=./pulse-ancillary-dispatch-evidence.sh
# shellcheck disable=SC1091  # sub-library resolved from this module at runtime
source "${_pad_script_dir}/pulse-ancillary-dispatch-evidence.sh"
# shellcheck source=./pulse-ancillary-dispatch-review.sh
# shellcheck disable=SC1091  # sub-library resolved from this module at runtime
source "${_pad_script_dir}/pulse-ancillary-dispatch-review.sh"
unset _pad_script_dir

_PAD_TRIAGE_REVIEW_APPROVE_LABEL="${_PAD_TRIAGE_REVIEW_APPROVE_LABEL:-review:approve}"
_PAD_TRIAGE_REVIEW_FEEDBACK_LABEL="${_PAD_TRIAGE_REVIEW_FEEDBACK_LABEL:-review:feedback}"
_PAD_TRIAGE_REVIEW_DECLINE_LABEL="${_PAD_TRIAGE_REVIEW_DECLINE_LABEL:-review:decline}"
_PAD_TRIAGE_REVIEW_APPROVE_COLOR="${_PAD_TRIAGE_REVIEW_APPROVE_COLOR:-0E8A16}"
_PAD_TRIAGE_REVIEW_FEEDBACK_COLOR="${_PAD_TRIAGE_REVIEW_FEEDBACK_COLOR:-FBCA04}"
_PAD_TRIAGE_REVIEW_DECLINE_COLOR="${_PAD_TRIAGE_REVIEW_DECLINE_COLOR:-D73A4A}"

#######################################
# Ensure the triage-failed label exists in the target repo.
#
# Uses gh label create --force (idempotent — creates if missing,
# refreshes colour/description if present). This fixes t2016 where
# the label was never provisioned in any repo and every
# `gh issue edit --add-label "triage-failed"` call failed silently.
#
# Arguments:
#   $1 - repo_slug (owner/repo)
#######################################
_ensure_triage_failed_label() {
	local repo_slug="$1"
	[[ -n "$repo_slug" ]] || return 0
	gh label create "triage-failed" \
		--repo "$repo_slug" \
		--color "E11D21" \
		--description "Automated triage could not produce a review — needs manual attention" \
		--force >/dev/null 2>&1 || true
	return 0
}

#######################################
# Extract the model's text response from a raw headless-runtime output file.
#
# t2019: The dispatcher previously ran a plain-text regex on the raw output
# file, but headless-runtime-helper.sh passes --format json to OpenCode
# and --output-format stream-json to Claude CLI. Both runtimes emit
# newline-delimited JSON events where the model's markdown response is
# embedded inside "text" fields of JSON objects — on a single physical
# line. A `sed '/^## .*Review/,$'` pattern therefore never matched any
# real triage review, producing the 60-80KB headerless-output symptom
# documented in #18482 / pulse-wrapper.log for #18428.
#
# This helper concatenates all text events from both formats:
#   OpenCode:     {"type":"text","text":"..."}
#                 {"part":{"type":"text","text":"..."}}
#   Claude CLI:   {"type":"assistant","message":{"content":[{"type":"text","text":"..."}]}}
#
# Falls back to the raw file content if no JSON events parse (so legacy
# callers passing already-extracted text still work).
#
# Arguments:
#   $1 - path to raw output file
#
# Outputs the extracted text to stdout. Returns 0 always.
#######################################
_extract_review_text_from_json() {
	local file_path="$1"
	[[ -f "$file_path" ]] || return 0
	python3 - "$file_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    raw = path.read_text(errors="ignore")
except Exception:
    print("")
    sys.exit(0)

texts = []
saw_json = False

for line in raw.splitlines():
    stripped = line.strip()
    if not stripped or not stripped.startswith("{"):
        continue
    try:
        obj = json.loads(stripped)
    except Exception:
        continue
    saw_json = True
    # OpenCode direct text event: {"type":"text","text":"..."}
    if obj.get("type") == "text" and isinstance(obj.get("text"), str):
        texts.append(obj["text"])
        continue
    # OpenCode part-wrapped: {"part":{"type":"text","text":"..."}}
    part = obj.get("part") or {}
    if isinstance(part, dict) and part.get("type") == "text" and isinstance(part.get("text"), str):
        texts.append(part["text"])
        continue
    # Claude CLI stream-json assistant event:
    #   {"type":"assistant","message":{"content":[{"type":"text","text":"..."}, ...]}}
    if obj.get("type") == "assistant":
        msg = obj.get("message") or {}
        content = msg.get("content") or []
        if isinstance(content, list):
            for sub in content:
                if isinstance(sub, dict) and sub.get("type") == "text" and isinstance(sub.get("text"), str):
                    texts.append(sub["text"])
        continue
    # Claude CLI top-level final-result event uses one key for type and payload.
    result_key = "result"
    if obj.get("type") == result_key and isinstance(obj.get(result_key), str):
        texts.append(obj[result_key])
        continue

if not saw_json:
    # Legacy or error path: runtime printed plain text (or infra leak).
    # Return raw content so downstream safety filters can inspect it.
    sys.stdout.write(raw)
    sys.exit(0)

sys.stdout.write("\n".join(texts))
PY
	return 0
}

#######################################
# Record a controlled prefetch infrastructure failure without consuming the
# content retry budget. Public data is never copied into this diagnostic.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#   $3 - controlled reason tag
#######################################
_triage_mark_infrastructure_retry() {
	local issue_num="$1"
	local repo_slug="$2"
	local reason="$3"

	gh issue edit "$issue_num" --repo "$repo_slug" \
		--remove-label "triage-failed" >/dev/null 2>&1 || true
	echo "[pulse-wrapper] Triage prefetch blocked for #${issue_num} in ${repo_slug} (reason=${reason}) — infrastructure failure, will retry without invoking the model" >>"$LOGFILE"
	return 0
}

#######################################
# Put an issue on an explicit security hold without copying untrusted content
# into labels, logs, or comments. Label writes are idempotent and best-effort;
# the caller still blocks model invocation if GitHub is unavailable.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#   $3 - controlled reason tag
#######################################
_triage_mark_security_hold() {
	local issue_num="$1"
	local repo_slug="$2"
	local reason="$3"

	[[ -n "$issue_num" && -n "$repo_slug" ]] || return 0
	gh label create "security-review" --repo "$repo_slug" --color "D73A4A" \
		--description "Requires security review — suspicious AI request" --force \
		>/dev/null 2>&1 || true
	gh label create "$_PAD_REVIEW_HOLD_LABEL" --repo "$repo_slug" --color "D73A4A" \
		--description "Opt-out: block issue auto-dispatch or PR auto-merge for maintainer review" --force \
		>/dev/null 2>&1 || true
	if ! gh issue edit "$issue_num" --repo "$repo_slug" \
		--add-label "security-review" --add-label "$_PAD_REVIEW_HOLD_LABEL" \
		>/dev/null 2>&1; then
		echo "[pulse-wrapper] SECURITY: failed to persist triage security hold for #${issue_num} in ${repo_slug}; model invocation remains blocked (reason=${reason})" >>"$LOGFILE"
	fi
	gh issue edit "$issue_num" --repo "$repo_slug" \
		--remove-label "triage-failed" >/dev/null 2>&1 || true
	echo "[pulse-wrapper] SECURITY: blocked triage model invocation for #${issue_num} in ${repo_slug} (reason=${reason})" >>"$LOGFILE"
	return 0
}

#######################################
# Validate the GitHub issue/PR payload fields consumed by triage identities.
_triage_issue_json_is_valid() {
	local issue_json="$1"
	local issue_num="$2"

	if ! printf '%s' "$issue_json" | jq -e --argjson expected "$issue_num" \
		--arg array_type "$_PAD_JSON_ARRAY_TYPE" \
		--arg string_type "$_PAD_JSON_STRING_TYPE" \
		'.number == $expected and (.title | type == $string_type) and (.title | length > 0) and
		 ((.body | type) == $string_type or (.body | type) == "null") and
		 (.labels | type == $array_type) and
		 all(.labels[]; (.name | type) == $string_type) and
		 (.createdAt | type == $string_type) and
		 (.updatedAt | type == $string_type)' \
		>/dev/null 2>&1; then
		return 1
	fi
	return 0
}

#######################################
# Validate the repository prerequisites used to resolve public evidence.
# Records a controlled infrastructure retry reason when validation fails.
#######################################
_triage_local_context_is_usable() {
	local issue_num="$1"
	local repo_slug="$2"
	local repo_path="$3"

	if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "local-repository-unavailable"
		return 1
	fi
	if ! command -v python3 >/dev/null 2>&1 || ! command -v rg >/dev/null 2>&1; then
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "triage-local-tool-unavailable"
		return 1
	fi
	local repo_is_worktree=""
	if ! repo_is_worktree=$(git -C "$repo_path" rev-parse \
		--is-inside-work-tree 2>/dev/null) || [[ "$repo_is_worktree" != "true" ]]; then
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "local-git-context-unavailable"
		return 1
	fi
	return 0
}

#######################################
# Update triage-failed label and content-hash cache after a dispatch.
#
# Manages the triage-failed label (remove on success, add on failure), then
# updates the content-hash cache. On success the hash is cached immediately;
# on failure, the retry counter is incremented and the hash is only cached when
# the retry cap is hit.
#
# Arguments:
#   $1 - issue_num
#   $2 - repo_slug
#   $3 - content_hash
#   $4 - triage_posted ("true" or "false")
#   $5 - failure_reason (empty string if posted successfully)
#   $6 - output_chars
#######################################
_finalize_triage_state() {
	local issue_num="$1"
	local repo_slug="$2"
	local content_hash="$3"
	local triage_posted="$4"
	local failure_reason="$5"
	local output_chars="$6"

	# GH#17829: Surface triage failures visibly. Add label so maintainers
	# can identify issues needing manual triage; remove on success.
	# t2016: Ensure the label exists first (gh label create --force is
	# idempotent) and only log "Added" when the add command succeeds.
	# t2089/GH#23854/GH#28705: infrastructure failures are not triage content
	# failures. Remove any stale triage-failed label and retry transparently
	# without consuming the content budget.
	if [[ "$triage_posted" == "true" ]] || _triage_failure_is_infrastructure "$failure_reason"; then
		gh issue edit "$issue_num" --repo "$repo_slug" \
			--remove-label "triage-failed" >/dev/null 2>&1 || true
	elif ! _triage_failure_is_infrastructure "$failure_reason"; then
		_ensure_triage_failed_label "$repo_slug"
		if gh issue edit "$issue_num" --repo "$repo_slug" \
			--add-label "triage-failed" >/dev/null 2>&1; then
			echo "[pulse-wrapper] Added triage-failed label to #${issue_num} in ${repo_slug}" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] FAILED to add triage-failed label to #${issue_num} in ${repo_slug} (gh issue edit returned non-zero)" >>"$LOGFILE"
		fi
	fi

	# GH#17873: Only cache content hash on successful post.
	# GH#17827: If failures are persistent (>= TRIAGE_MAX_RETRIES on the
	# same content hash), cache to break the infinite lock→agent→fail→unlock
	# loop. The triage-failed label remains for maintainer visibility.
	# t2016: When the retry cap is hit, post a structured escalation comment
	# BEFORE writing the cache, so the maintainer has a visible signal
	# instead of a silently-cached issue that disappears from triage forever.
	# t2089/GH#23854: infrastructure failures skip BOTH the retry counter AND the
	# cache write — the issue content hasn't changed; the runtime/contract was
	# unavailable. Incrementing the counter would cause the next infra failure
	# to hit the cap and permanently lock the issue out of triage.
	if [[ "$triage_posted" == "true" ]]; then
		_triage_update_cache "$issue_num" "$repo_slug" "$content_hash"
	elif _triage_failure_is_infrastructure "$failure_reason"; then
		echo "[pulse-wrapper] Triage skipped for #${issue_num} — ${failure_reason}, will retry next cycle without consuming retry budget (GH#23854)" >>"$LOGFILE"
	elif _triage_increment_failure "$issue_num" "$repo_slug" "$content_hash"; then
		echo "[pulse-wrapper] Triage retry cap reached for #${issue_num} in ${repo_slug} — caching hash to stop lock/unlock loop (GH#17827)" >>"$LOGFILE"
		local cap_attempts="${TRIAGE_MAX_RETRIES:-1}"
		_post_triage_escalation_comment \
			"$issue_num" "$repo_slug" \
			"$failure_reason" "$cap_attempts" "$output_chars"
		_triage_update_cache "$issue_num" "$repo_slug" "$content_hash"
	else
		echo "[pulse-wrapper] Skipping triage cache for #${issue_num} — review not posted, will retry on next cycle" >>"$LOGFILE"
	fi
	return 0
}


#######################################
# Fetch issue data for later snapshot and skip-condition checks.
#
# Fetches and validates issue JSON, comments, and body. Cache decisions happen
# only after PR revision, diff, and file inputs have also been fetched.
# Writes results to caller-supplied named variables via printf -v so the
# function's "return" values are explicit in the signature (GH#18865).
#
# Arguments:
#   $1 - issue_num
#   $2 - repo_slug
#   $3 - name of variable to receive raw issue JSON
#   $4 - name of variable to receive raw comments JSON array
#   $5 - name of variable to receive issue body text
#
# Returns:
#   0 — proceed with triage (named variables are populated)
#   1 — infrastructure failure (named variables unset)
#######################################
_triage_prefetch_issue() {
	local issue_num="$1"
	local repo_slug="$2"
	local issue_json_var="$3"
	local issue_comments_var="$4"
	local issue_body_var="$5"

	# ── GH#17746: Fetch body+comments early — needed for dedup AND prompt ──
	local issue_json=""
	if ! issue_json=$(gh issue view "$issue_num" --repo "$repo_slug" \
		--json number,title,body,author,labels,createdAt,updatedAt 2>/dev/null); then
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "github-issue-read-failed"
		return 1
	fi
	if ! _triage_issue_json_is_valid "$issue_json" "$issue_num"; then
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "github-issue-read-malformed"
		return 1
	fi
	if _triage_terminal_snapshot_active "$issue_num" "$repo_slug" \
		"$_PAD_GITHUB_COMMENTS_SNAPSHOT_TOO_LARGE_REASON" "$issue_json"; then
		return 1
	fi

	local issue_comment_pages=""
	if ! issue_comment_pages=$(gh api \
		"repos/${repo_slug}/issues/${issue_num}/comments?per_page=100" \
		--paginate --slurp 2>/dev/null); then
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "github-comments-read-failed"
		return 1
	fi
	if ! printf '%s' "$issue_comment_pages" | jq -e \
		--arg array_type "$_PAD_JSON_ARRAY_TYPE" \
		'type == $array_type and all(.[]; type == $array_type)' \
		>/dev/null 2>&1; then
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "$_PAD_GITHUB_COMMENTS_READ_MALFORMED_REASON"
		return 1
	fi
	local issue_comment_count=""
	if ! issue_comment_count=$(printf '%s' "$issue_comment_pages" \
		| jq -r '[.[][]?] | length' 2>/dev/null) || \
		[[ ! "$issue_comment_count" =~ ^[0-9]+$ ]]; then
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "$_PAD_GITHUB_COMMENTS_READ_MALFORMED_REASON"
		return 1
	fi
	if [[ "$issue_comment_count" -gt "$_PAD_TRIAGE_MAX_COMMENTS" ]]; then
		_triage_mark_terminal_snapshot "$issue_num" "$repo_slug" \
			"$_PAD_GITHUB_COMMENTS_SNAPSHOT_TOO_LARGE_REASON" "$issue_json" || true
		return 1
	fi

	local issue_comments=""
	if ! issue_comments=$(printf '%s' "$issue_comment_pages" | jq -ce '
		[.[][]? | {
			id: .id,
			author: (.user.login // ""),
			association: (.author_association // ""),
			body: (.body // ""),
			created: (.created_at // ""),
			updated: (.updated_at // .created_at // "")
		}]
		| if all(.[];
			((.id | type) == "number") and
			((.author | type) == "string") and
			((.association | type) == "string") and
			((.body | type) == "string") and
			((.created | type) == "string") and
			((.updated | type) == "string"))
		then . else error("malformed comment snapshot") end' 2>/dev/null); then
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "$_PAD_GITHUB_COMMENTS_READ_MALFORMED_REASON"
		return 1
	fi
	local issue_comment_bytes=""
	issue_comment_bytes=$(_triage_text_byte_count "$issue_comments") || return 1
	if [[ "$issue_comment_bytes" -gt "$_PAD_TRIAGE_MAX_COMMENT_BYTES" ]]; then
		_triage_mark_terminal_snapshot "$issue_num" "$repo_slug" \
			"$_PAD_GITHUB_COMMENTS_SNAPSHOT_TOO_LARGE_REASON" "$issue_json" || true
		return 1
	fi

	local issue_body=""
	if ! issue_body=$(printf '%s' "$issue_json" \
		| jq -r '.body // "No body"' 2>/dev/null); then
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "github-issue-body-malformed"
		return 1
	fi

	# Write results to caller's named variables (explicit data flow — GH#18865)
	printf -v "$issue_json_var" '%s' "$issue_json"
	printf -v "$issue_comments_var" '%s' "$issue_comments"
	printf -v "$issue_body_var" '%s' "$issue_body"
	return 0
}

#######################################
# Write the triage review prompt to a temp file.
#
# Rejects issue-comment snapshots above the complete review bound, fetches
# recent closed issues and git log, then writes the format-first prompt.
#
# t2019: format-first prompt structure — rules FIRST, context second.
# The fix is independent of runtime (Claude CLI, OpenCode, etc.):
#   (1) puts format rules FIRST (before any context data)
#   (2) explicitly forbids tool exploration
#   (3) caps output to 800 words
#
# Arguments:
#   $1 - issue_num
#   $2 - repo_slug
#   $3 - repo_path
#   $4 - issue_json
#   $5 - issue_body
#   $6 - issue_comments (uncapped; capped internally)
#   $7 - pr_diff
#   $8 - pr_files
#   $9 - is_pr (non-empty if this item is a PR)
#   $10 - immutable PR base SHA (empty for issues)
#   $11 - immutable PR head SHA (empty for issues)
#   $12 - GitHub-verified public evidence revision
#
# Prints the temp file path to stdout. Returns 0.
#######################################
_triage_write_prompt_file() {
	local issue_num="$1"
	local repo_slug="$2"
	local repo_path="$3"
	local issue_json="$4"
	local issue_body="$5"
	local issue_comments="$6"
	local pr_diff="$7"
	local pr_files="$8"
	local is_pr="$9"
	local pr_base_sha="${10:-}"
	local pr_head_sha="${11:-}"
	local public_revision="${12:-}"
	[[ "$public_revision" =~ ^[0-9a-f]{40,64}$ ]] || return 1

	# #aidevops:trust-boundary — never silently truncate a public conversation.
	# The model may recommend approval only when every fetched comment fits the
	# bounded prompt. Oversized threads remain unreviewed and retry fail closed.
	local issue_comments_capped="$issue_comments"
	local prompt_comment_bytes=""
	prompt_comment_bytes=$(_triage_text_byte_count "$issue_comments_capped") || return 1
	if [[ "$prompt_comment_bytes" -gt "$_PAD_TRIAGE_MAX_PROMPT_COMMENT_BYTES" ]]; then
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "$_PAD_GITHUB_COMMENTS_SNAPSHOT_TOO_LARGE_REASON"
		return 1
	fi

	local recent_closed=""
	if ! recent_closed=$(gh_issue_list --repo "$repo_slug" --state closed \
		--json number,title --limit 15 --jq '.[].title' 2>/dev/null); then
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "github-recent-closed-read-failed"
		return 1
	fi

	local git_log_context=""
	local git_log_status=0
	git_log_context=$(_triage_recent_public_commits_rest \
		"$repo_slug" "$public_revision") || git_log_status=$?
	if [[ "$git_log_status" -ne 0 ]]; then
		local git_log_reason="github-public-commits-read-failed"
		[[ "$git_log_status" -ne 2 ]] || git_log_reason="github-public-commits-too-large"
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "$git_log_reason"
		return 1
	fi

	# t2886: Fetch evidence-verification data for file:line claim validation.
	local evidence_merged_prs=""
	local evidence_recent_commits=""
	local evidence_file_contents=""
	local evidence_status=0
	_triage_fetch_evidence_sections \
		"$issue_body" "$issue_json" "$repo_slug" "$repo_path" "$public_revision" \
		"evidence_merged_prs" "evidence_recent_commits" "evidence_file_contents" \
		|| evidence_status=$?
	if [[ "$evidence_status" -ne 0 ]]; then
		local evidence_reason="triage-evidence-read-failed"
		[[ "$evidence_status" -ne 2 ]] || evidence_reason="triage-evidence-too-large"
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "$evidence_reason"
		return 1
	fi

	# Recent issue/PR titles are public contributor-controlled data too. Keep
	# them outside the model boundary unless the deterministic scanner returns
	# an explicit clean result.
	if ! _triage_untrusted_content_is_safe "$issue_num" "$repo_slug" \
		"public-history" "$recent_closed" "$git_log_context" \
		"$evidence_merged_prs" "$evidence_recent_commits" \
		"$evidence_file_contents"; then
		return 1
	fi

	local prefetch_dir=""
	if ! prefetch_dir=$(_triage_create_sensitive_artifact_dir "review"); then
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "$_PAD_TRIAGE_RUNTIME_TEMP_FAILURE_REASON"
		return 1
	fi
	local prefetch_file="${prefetch_dir}/prompt.md"

	if ! _triage_write_prompt_rules "$prefetch_file" || \
		! _triage_append_prompt_context \
			"$prefetch_file" "$issue_num" "$repo_slug" "$issue_json" \
			"$issue_body" "$issue_comments_capped" "$pr_diff" "$pr_files" \
			"$recent_closed" "$git_log_context" "$evidence_merged_prs" \
			"$evidence_recent_commits" "$evidence_file_contents" \
			"$pr_base_sha" "$pr_head_sha"; then
		_triage_cleanup_sensitive_artifact_dir "$prefetch_dir" || true
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "$_PAD_TRIAGE_RUNTIME_TEMP_FAILURE_REASON"
		return 1
	fi
	local prompt_status=0
	_triage_prompt_file_is_bounded "$prefetch_file" || prompt_status=$?
	if [[ "$prompt_status" -ne 0 ]]; then
		local prompt_reason="triage-prompt-size-failed"
		[[ "$prompt_status" -ne 2 ]] || prompt_reason="triage-prompt-too-large"
		_triage_cleanup_sensitive_artifact_dir "$prefetch_dir" || true
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "$prompt_reason"
		return 1
	fi

	printf '%s\n' "$prefetch_file"
	return 0
}

#######################################
# Build the triage review prompt for a given issue/PR.
#
# Orchestrates: issue prefetch + skip checks, PR context fetch,
# and prompt file construction. Delegates data fetching and prompt
# writing to focused helpers (_triage_prefetch_issue,
# _triage_write_prompt_file). Receives prefetched data via local
# variables populated by _triage_prefetch_issue using printf -v.
#
# Arguments:
#   $1 - issue_num
#   $2 - repo_slug
#   $3 - repo_path
#
# Prints "<prefetch_file>|<content_hash>|<item_kind>|<pr_revision_pair>|<text_snapshot_hash>|<public_revision>".
# Returns 0 on success, 1 if triage should be skipped.
#######################################
_build_triage_review_prompt() {
	local issue_num="$1"
	local repo_slug="$2"
	local repo_path="$3"
	_triage_local_context_is_usable "$issue_num" "$repo_slug" "$repo_path" || return 1

	# Declare receiving variables; populated by _triage_prefetch_issue via printf -v.
	local __TRIAGE_ISSUE_JSON=""
	local __TRIAGE_ISSUE_COMMENTS=""
	local __TRIAGE_ISSUE_BODY=""

	# Fetch issue data; cache checks wait until all PR snapshot inputs are known.
	_triage_prefetch_issue "$issue_num" "$repo_slug" \
		"__TRIAGE_ISSUE_JSON" \
		"__TRIAGE_ISSUE_COMMENTS" \
		"__TRIAGE_ISSUE_BODY" || return 1
	local __TRIAGE_TEXT_SNAPSHOT_HASH=""
	if ! __TRIAGE_TEXT_SNAPSHOT_HASH=$(_triage_current_text_snapshot_hash \
		"$__TRIAGE_ISSUE_JSON" "$__TRIAGE_ISSUE_COMMENTS"); then
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "triage-current-snapshot-hash-failed"
		return 1
	fi
	local __TRIAGE_ISSUE_TITLE="" __TRIAGE_ISSUE_LABELS=""
	if ! _triage_issue_cache_metadata "$__TRIAGE_ISSUE_JSON" \
		"__TRIAGE_ISSUE_TITLE" "__TRIAGE_ISSUE_LABELS"; then
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "github-issue-read-malformed"
		return 1
	fi

	local pr_diff="" pr_files="" is_pr="" pr_base_sha="" pr_head_sha="" item_kind=""
	if ! item_kind=$(gh api "repos/${repo_slug}/issues/${issue_num}" \
		--jq 'if .pull_request then "pr" else "issue" end' 2>/dev/null); then
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "github-item-kind-read-failed"
		return 1
	fi
	case "$item_kind" in
	pr) is_pr="$issue_num" ;;
	issue) ;;
	*)
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "github-item-kind-read-malformed"
		return 1
		;;
	esac
	if [[ -n "$is_pr" ]]; then
		_triage_fetch_pr_snapshot "$issue_num" "$repo_slug" \
			"pr_base_sha" "pr_head_sha" "pr_diff" "pr_files" || return 1
	fi
	local public_revision=""
	_triage_resolve_public_revision "$issue_num" "$repo_slug" "$item_kind" "$pr_head_sha" "public_revision" || return 1

	# Cache identity covers the exact PR base/head pair and the fetched diff/file
	# snapshot, so code pushes cannot reuse a body/comment-only recommendation.
	local __TRIAGE_CONTENT_HASH=""
	if ! __TRIAGE_CONTENT_HASH=$(_triage_content_hash \
		"$issue_num" "$repo_slug" "$__TRIAGE_ISSUE_BODY" \
		"$__TRIAGE_ISSUE_COMMENTS" "$item_kind" "$pr_base_sha" \
		"$pr_head_sha" "$pr_diff" "$pr_files" "$public_revision" \
		"$__TRIAGE_ISSUE_TITLE" "$__TRIAGE_ISSUE_LABELS"); then
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "triage-content-hash-failed"
		return 1
	fi
	if _triage_is_cached "$issue_num" "$repo_slug" "$__TRIAGE_CONTENT_HASH"; then
		echo "[pulse-wrapper] triage dedup: skipping #${issue_num} in ${repo_slug} — reviewed snapshot unchanged since last triage" >>"$LOGFILE"
		return 1
	fi

	# GH#17827: cache the complete snapshot only while the latest human reply is
	# still from a maintainer. Any contributor reply or PR revision change reruns.
	if _triage_awaiting_contributor_reply "$__TRIAGE_ISSUE_COMMENTS" "$repo_slug"; then
		echo "[pulse-wrapper] triage skip: #${issue_num} in ${repo_slug} — awaiting contributor reply (GH#17827)" >>"$LOGFILE"
		_triage_update_cache "$issue_num" "$repo_slug" "$__TRIAGE_CONTENT_HASH"
		return 1
	fi

	# The current issue/PR payload is the primary public trust boundary. Scan it
	# before constructing a prompt file so non-clean content can never reach the
	# model, even if the sandboxed agent would otherwise treat it as data.
	if ! _triage_untrusted_content_is_safe "$issue_num" "$repo_slug" \
		"current-item" "$__TRIAGE_ISSUE_JSON" "$__TRIAGE_ISSUE_COMMENTS" \
		"$pr_diff" "$pr_files"; then
		return 1
	fi

	local prefetch_file=""
	prefetch_file=$(_triage_write_prompt_file \
		"$issue_num" "$repo_slug" "$repo_path" \
		"$__TRIAGE_ISSUE_JSON" "$__TRIAGE_ISSUE_BODY" "$__TRIAGE_ISSUE_COMMENTS" \
		"$pr_diff" "$pr_files" "$is_pr" "$pr_base_sha" "$pr_head_sha" \
		"$public_revision") || return 1

	local pr_revision_pair="${pr_base_sha:+${pr_base_sha}:${pr_head_sha}}"
	printf '%s|%s|%s|%s|%s|%s\n' \
		"$prefetch_file" "$__TRIAGE_CONTENT_HASH" "$item_kind" \
		"$pr_revision_pair" "$__TRIAGE_TEXT_SNAPSHOT_HASH" "$public_revision"
	return 0
}

#######################################
# Dispatch triage review workers for needs-maintainer-review issues
#
# Reads the pre-fetched triage status from the triage state file and
# dispatches thinking-tier review workers for issues marked needs-review.
# Respects an independent per-cycle triage budget. Triage outcomes never consume
# implementation-worker slots and are returned as typed JSON.
#
# Arguments:
#   $1 - requested triage budget (clamped to PULSE_TRIAGE_BUDGET_PER_CYCLE)
#   $2 - repos JSON path (default: REPOS_JSON)
#
# Outputs: aidevops.pulse-triage-outcome/v1 JSON
# Exit code: always 0
#######################################
dispatch_triage_reviews() {
	local requested_budget="${1:-${PULSE_TRIAGE_BUDGET_PER_CYCLE:-2}}"
	local repos_json="${2:-${REPOS_JSON:-~/.config/aidevops/repos.json}}"
	local triage_count=0
	local triage_max="${PULSE_TRIAGE_BUDGET_PER_CYCLE:-2}"
	local posted=0 review_failed=0 infrastructure_failed=0 preparation_failed=0

	[[ "$requested_budget" =~ ^[0-9]+$ ]] || requested_budget=0
	[[ "$triage_max" =~ ^[0-9]+$ ]] || triage_max=2
	((requested_budget < triage_max)) && triage_max="$requested_budget"
	[[ "$triage_max" -gt 0 ]] || {
		_triage_outcome_json 0 0 0 0 0
		return 0
	}

	# NMR data is in a dedicated triage state file, not the LLM's STATE_FILE (t1894).
	local triage_file="${TRIAGE_STATE_FILE:-${STATE_FILE%.txt}-triage.txt}"
	[[ -f "$triage_file" ]] || {
		echo "[pulse-wrapper] dispatch_triage_reviews: no triage state file" >>"$LOGFILE"
		_triage_outcome_json 0 0 0 0 0
		return 0
	}

	# Resolve model: prefer opus, fall back to sonnet, then omit --model
	local resolved_model=""
	resolved_model=$("$MODEL_AVAILABILITY_HELPER" resolve thinking || echo "")
	if [[ -z "$resolved_model" ]]; then
		resolved_model=$("$MODEL_AVAILABILITY_HELPER" resolve standard || echo "")
	fi
	[[ -n "$resolved_model" ]] || echo "[pulse-wrapper] dispatch_triage_reviews: model resolution failed (opus and sonnet unavailable)" >>"$LOGFILE"

	# Parse "## owner/repo" headers and "- Issue #N: ... [status: **needs-review**]" lines.
	local candidates=""
	candidates=$(_triage_review_candidates "$triage_file" "$repos_json")

	[[ -n "$candidates" ]] || {
		echo "[pulse-wrapper] dispatch_triage_reviews: 0 candidates found in state file" >>"$LOGFILE"
		_triage_outcome_json 0 0 0 0 0
		return 0
	}

	# t1916: Triage is exempt from the cryptographic approval gate.
	while IFS='|' read -r issue_num repo_slug repo_path candidate_author; do
		: "$candidate_author"
		[[ -n "$issue_num" && -n "$repo_slug" ]] || continue
		[[ "$triage_count" -lt "$triage_max" ]] || break

		local prompt_result=""
		prompt_result=$(_build_triage_review_prompt "$issue_num" "$repo_slug" "$repo_path") || continue
		local prompt_file="${prompt_result%%|*}"
		local prompt_metadata="${prompt_result#*|}"
		local content_hash="${prompt_metadata%%|*}"
		local item_metadata="${prompt_metadata#*|}"
		local item_kind="${item_metadata%%|*}"
		local snapshot_metadata="${item_metadata#*|}"
		local expected_pr_revision="${snapshot_metadata%%|*}"
		local revision_metadata="${snapshot_metadata#*|}"
		local expected_text_snapshot="${revision_metadata%%|*}"
		local expected_public_revision="${revision_metadata#*|}"
		if ! _triage_prompt_metadata_is_valid \
			"$item_kind" "$expected_pr_revision" "$expected_text_snapshot" \
			"$expected_public_revision"; then
			local propagation_reason="triage-item-kind-propagation-failed"
			if ! _triage_cleanup_sensitive_artifact_dir "${prompt_file%/*}"; then
				propagation_reason="$_PAD_TRIAGE_RUNTIME_TEMP_FAILURE_REASON"
			fi
			_triage_mark_infrastructure_retry \
				"$issue_num" "$repo_slug" "$propagation_reason"
			preparation_failed=$((preparation_failed + 1))
			continue
		fi
		_PAD_TRIAGE_LAST_OUTCOME=""
		_dispatch_triage_review_worker \
			"$issue_num" "$repo_slug" "$repo_path" \
			"$prompt_file" "$content_hash" "$resolved_model" "$item_kind" \
			"$expected_pr_revision" "$expected_text_snapshot" \
			"$expected_public_revision"

		sleep 2
		triage_count=$((triage_count + 1))
		case "$_PAD_TRIAGE_LAST_OUTCOME" in
		"$_PAD_TRIAGE_OUTCOME_POSTED") posted=$((posted + 1)) ;;
		"$_PAD_TRIAGE_OUTCOME_INFRASTRUCTURE_FAILED") infrastructure_failed=$((infrastructure_failed + 1)) ;;
		*) review_failed=$((review_failed + 1)) ;;
		esac
	done <<<"$candidates"

	echo "[pulse-wrapper] dispatch_triage_reviews: budget=${triage_max} attempted=${triage_count} posted=${posted} review_failed=${review_failed} infrastructure_failed=${infrastructure_failed} preparation_failed=${preparation_failed} implementation_slots_consumed=0" >>"$LOGFILE"
	_triage_outcome_json "$triage_count" "$posted" "$review_failed" "$infrastructure_failed" "$preparation_failed"
	return 0
}

#######################################
# Relabel status:needs-info issues where contributor has replied
#
# Reads the pre-fetched needs-info reply status from STATE_FILE and transitions
# replied issues according to live author authority: external/unknown authors
# return to NMR triage; trusted authors use hold-for-review without self-approval.
#
# Arguments:
#   $1 - repos JSON path (default: REPOS_JSON)
#
# Exit code: always 0
#######################################
relabel_needs_info_replies() {
	local repos_json="${1:-${REPOS_JSON:-~/.config/aidevops/repos.json}}"
	local state_file="${STATE_FILE:-}"
	[[ -f "$state_file" ]] || return 0

	# Parse replied items from pre-fetched state (format: number|slug)
	while IFS='|' read -r issue_num repo_slug; do
		[[ -n "$issue_num" && -n "$repo_slug" ]] || continue

		local author_meta="" author_association="NONE" author_type="" author_login="" external_source="false"
		author_meta=$(gh api "repos/${repo_slug}/issues/${issue_num}" \
			--jq '[.author_association // "NONE", .user.type // "", .user.login // "", (([.labels[]?.name] | index("external-contributor") != null) | tostring)] | join("|")' \
			2>/dev/null) || author_meta=""
		if [[ -z "$author_meta" ]]; then
			echo "[pulse-wrapper] relabel_needs_info_replies: authority lookup failed for #${issue_num} in ${repo_slug}; preserving status:needs-info" >>"$LOGFILE"
			continue
		fi
		IFS='|' read -r author_association author_type author_login external_source <<<"$author_meta"

		local authority_rc=1 review_label="needs-maintainer-review"
		if [[ "$external_source" != "true" ]]; then
			authority_rc=2
			if [[ "$author_type" == "Bot" ]]; then
				authority_rc=0
			elif declare -F _gh_actor_has_repo_write_authority >/dev/null 2>&1; then
				authority_rc=0
				_gh_actor_has_repo_write_authority "$repo_slug" "$author_login" "$author_association" || authority_rc=$?
			fi
		fi
		if [[ "$authority_rc" -eq 0 ]]; then
			review_label="$_PAD_REVIEW_HOLD_LABEL"
		elif [[ "$authority_rc" -eq 2 ]]; then
			echo "[pulse-wrapper] relabel_needs_info_replies: author authority uncertain for #${issue_num} in ${repo_slug}; failing closed to NMR (${AIDEVOPS_GH_ACTOR_AUTHORITY_REASON:-unknown})" >>"$LOGFILE"
		fi

		local edit_rc=0
		if declare -F gh_issue_edit_safe >/dev/null 2>&1; then
			gh_issue_edit_safe "$issue_num" --repo "$repo_slug" \
				--remove-label "status:needs-info" --add-label "$review_label" >/dev/null 2>&1 || edit_rc=$?
		else
			gh issue edit "$issue_num" --repo "$repo_slug" \
				--remove-label "status:needs-info" --add-label "$review_label" >/dev/null 2>&1 || edit_rc=$?
		fi
		if [[ "$edit_rc" -ne 0 ]]; then
			echo "[pulse-wrapper] relabel_needs_info_replies: transition failed for #${issue_num} in ${repo_slug} (target=${review_label}, rc=${edit_rc})" >>"$LOGFILE"
			continue
		fi
		gh_issue_comment "$issue_num" --repo "$repo_slug" \
			--body "The issue author replied to the information request. Relabeled to \`${review_label}\` for re-evaluation." \
			2>/dev/null || echo "[pulse-wrapper] relabel_needs_info_replies: transition comment failed for #${issue_num} in ${repo_slug}" >>"$LOGFILE"
	done < <(sed -n 's/^replied|//p' "$state_file" 2>/dev/null || true)

	return 0
}

#######################################
# dispatch_routine_comment_responses
#
# Scans routine-tracking issues across pulse-enabled repos for unanswered
# user comments. Dispatches lightweight Haiku workers to respond.
# Max 2 dispatches per cycle to avoid flooding.
#
# Exit code: always 0 (non-fatal)
#######################################
dispatch_routine_comment_responses() {
	local responder="${SCRIPT_DIR}/routine-comment-responder.sh"
	if [[ ! -x "$responder" ]]; then
		return 0
	fi

	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local max_dispatches="${ROUTINE_COMMENT_MAX_PER_CYCLE:-2}"
	local dispatched=0

	# Iterate pulse-enabled repos
	local slug repo_path
	while IFS='|' read -r slug repo_path; do
		[[ -n "$slug" && -n "$repo_path" ]] || continue
		[[ "$dispatched" -lt "$max_dispatches" ]] || break

		# Scan for unanswered comments
		local scan_output
		scan_output=$(bash "$responder" scan "$slug" "$repo_path" 2>/dev/null) || continue
		[[ -n "$scan_output" ]] || continue

		while IFS='|' read -r issue_number comment_id author body_preview; do
			[[ -n "$issue_number" && -n "$comment_id" ]] || continue
			[[ "$dispatched" -lt "$max_dispatches" ]] || break

			echo "[pulse-wrapper] Routine comment response: dispatching for #${issue_number} comment ${comment_id} by @${author} in ${slug}" >>"$LOGFILE"
			bash "$responder" dispatch "$slug" "$repo_path" "$issue_number" "$comment_id" 2>>"$LOGFILE" || true
			dispatched=$((dispatched + 1))
		done <<<"$scan_output"
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false) | select(.pulse == true) | select(.local_only != true) | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null)

	if [[ "$dispatched" -gt 0 ]]; then
		echo "[pulse-wrapper] Routine comment responses: dispatched ${dispatched} workers" >>"$LOGFILE"
	fi

	return 0
}

dispatch_foss_workers() {
	local available="$1"
	local repos_json="${2:-${REPOS_JSON:-~/.config/aidevops/repos.json}}"
	local foss_count=0
	local foss_max="${FOSS_MAX_DISPATCH_PER_CYCLE:-2}"
	local foss_session_keys_seen=$'\n'
	local foss_slug="" foss_path="" disclosure="" labels_filter_json="" foss_login=""
	foss_login=$(_foss_current_gh_login)

	[[ "$available" =~ ^[0-9]+$ ]] || available=0

	while IFS=$'\t' read -r foss_slug foss_path disclosure labels_filter_json; do
		[[ -n "$foss_slug" && -n "$foss_path" ]] || continue
		[[ "$available" -gt 0 && "$foss_count" -lt "$foss_max" ]] || break

		# Pre-dispatch eligibility check (budget + rate limit)
		"${SCRIPT_DIR}/foss-contribution-helper.sh" check "$foss_slug" >/dev/null || continue

		# labels_filter_json keeps configured labels as JSON array elements,
		# including commas, while avoiding a second repos.json parse per repo.
		local foss_issue foss_issue_num foss_issue_title
		local foss_label_candidates=()
		local foss_label
		while IFS= read -r foss_label; do
			[[ -n "$foss_label" ]] || continue
			foss_label_candidates+=("$foss_label")
		done < <(jq -r '.[]' <<<"$labels_filter_json" 2>/dev/null || printf '%s\n' 'help wanted' 'good first issue' 'bug')
		for foss_label in "${foss_label_candidates[@]}"; do
			[[ -n "$foss_label" ]] || continue
			foss_issue=$(_foss_issue_list_for_label "$foss_slug" "$foss_label") || foss_issue=""
			[[ -n "$foss_issue" ]] && break
		done
		if [[ -z "$foss_issue" ]]; then
			echo "[pulse-wrapper] FOSS dispatch skipped no issue selection for ${foss_slug}: gh_issue_list returned empty output" >>"$LOGFILE"
			continue
		fi

		foss_issue_num="${foss_issue%%|*}"
		foss_issue_title="${foss_issue#*|}"
		if [[ ! "$foss_issue_num" =~ ^[0-9]+$ || -z "$foss_issue_title" ]]; then
			echo "[pulse-wrapper] FOSS dispatch skipped invalid issue selection for ${foss_slug}: number='${foss_issue_num}' title='${foss_issue_title}'" >>"$LOGFILE"
			continue
		fi

		local foss_session_key="foss-${foss_slug}-${foss_issue_num}"
		if [[ "${foss_session_keys_seen}" == *$'\n'"${foss_session_key}"$'\n'* ]]; then
			echo "[pulse-wrapper] FOSS dispatch skipped duplicate session key ${foss_session_key} in this cycle" >>"$LOGFILE"
			continue
		fi
		if _foss_open_pr_exists_for_issue "$foss_slug" "$foss_issue_num" "$foss_login"; then
			echo "[pulse-wrapper] FOSS dispatch skipped ${foss_session_key}: authenticated account already has an open PR for issue #${foss_issue_num}" >>"$LOGFILE"
			continue
		fi
		if _foss_recent_runtime_evidence "$foss_session_key" "terminal"; then
			echo "[pulse-wrapper] FOSS dispatch skipped ${foss_session_key}: recent success/blocked runtime evidence already exists" >>"$LOGFILE"
			continue
		fi
		if _foss_recent_runtime_evidence "$foss_session_key" "local"; then
			echo "[pulse-wrapper] FOSS dispatch skipped ${foss_session_key}: recent local runtime failure is in backoff" >>"$LOGFILE"
			continue
		fi
		foss_session_keys_seen="${foss_session_keys_seen}${foss_session_key}"$'\n'

		local disclosure_flag=""
		[[ "$disclosure" == "true" ]] && disclosure_flag=" Include AI disclosure note in the PR."
		local foss_path_expanded
		foss_path_expanded=$(_expand_foss_repo_path "$foss_path")

		env \
			HEADLESS=1 \
			FULL_LOOP_HEADLESS=true \
			AIDEVOPS_SESSION_ORIGIN=worker \
			AIDEVOPS_HEADLESS=true \
			WORKER_ISSUE_NUMBER="$foss_issue_num" \
			WORKER_REPO_SLUG="$foss_slug" \
			WORKER_WORKTREE_PATH="$foss_path_expanded" \
		"$HEADLESS_RUNTIME_HELPER" run \
			--role worker \
			--session-key "$foss_session_key" \
			--dir "$foss_path_expanded" \
			--title "FOSS: ${foss_slug} #${foss_issue_num}: ${foss_issue_title}" \
			--prompt "/full-loop Implement issue #${foss_issue_num} (https://github.com/${foss_slug}/issues/${foss_issue_num}) -- ${foss_issue_title}. This is a FOSS contribution.${disclosure_flag} After completion, run: foss-contribution-helper.sh record ${foss_slug} <tokens_used>" \
			</dev/null >>"${HOME}/.aidevops/logs/pulse-foss-${foss_issue_num}.log" 2>&1 &
		sleep 2

		foss_count=$((foss_count + 1))
		available=$((available - 1))
	done < <(jq -r '.initialized_repos[]
		| select(.maintenance != false and (.local_only // false) == false and .foss == true and (.foss_config.blocklist // false) == false)
		| [
			.slug,
			.path,
			((.foss_config.disclosure != false) | tostring),
			((.foss_config.labels_filter // ["help wanted","good first issue","bug"]) | @json)
		]
		| @tsv' \
		"$repos_json" 2>/dev/null || true)

	printf '%d\n' "$available"
	return 0
}
