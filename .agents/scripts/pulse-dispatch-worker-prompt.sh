#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dispatch-worker-prompt.sh -- Worker prompt preparation and zero-attempt hold helpers.
#
# Sourced by pulse-dispatch-worker-launch.sh. Depends on shared-constants.sh
# plus dispatch state and GitHub helpers supplied by the pulse dispatcher.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_DISPATCH_WORKER_PROMPT_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_WORKER_PROMPT_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_dlw_prompt_path="${BASH_SOURCE[0]%/*}"
	[[ "$_dlw_prompt_path" == "${BASH_SOURCE[0]}" ]] && _dlw_prompt_path="."
	SCRIPT_DIR="$(cd "$_dlw_prompt_path" && pwd)"
	unset _dlw_prompt_path
fi

# shellcheck source=shared-constants.sh
# shellcheck disable=SC1091  # This module's directory is resolved at runtime.
source "${BASH_SOURCE[0]%/*}/shared-constants.sh"

_dlw_zero_output_failure_count() {
	local issue_number="$1"
	local repo_slug="$2"
	local precomputed_comment_count="${3:-}"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
	[[ -n "$repo_slug" ]] || { printf '0'; return 0; }
	local state_count=0 comment_count=0
	if [[ "$precomputed_comment_count" =~ ^[0-9]+$ ]]; then
		comment_count="$precomputed_comment_count"
	else
		comment_count=$(_dlw_zero_output_comment_count "$issue_number" "$repo_slug")
		[[ "$comment_count" =~ ^[0-9]+$ ]] || comment_count=0
	fi
	[[ -n "${FAST_FAIL_STATE_FILE:-}" && -f "$FAST_FAIL_STATE_FILE" ]] || {
		printf '%s' "$comment_count"
		return 0
	}

	local key="${repo_slug}/${issue_number}"
	local result=""
	result=$(jq -r --arg k "$key" 'def s: . // ""; .[$k] | if . then [(.count // 0 | tostring), (.reason | s), (.crash_type | s)] | @tsv else empty end' "$FAST_FAIL_STATE_FILE") || result=""
	if [[ -z "$result" ]]; then
		printf '%s' "$comment_count"
		return 0
	fi

	local reason="" crash_type="" count=""
	IFS=$'\t' read -r count reason crash_type <<<"$result"
	[[ "$count" =~ ^[0-9]+$ ]] || count=0

	case "${reason}:${crash_type}" in
	worker_noop_zero_output:* | *:no_work | no_work:*) state_count="$count" ;;
	*) state_count=0 ;;
	esac
	if [[ "$comment_count" -gt "$state_count" ]]; then
		printf '%s' "$comment_count"
	else
		printf '%s' "$state_count"
	fi
	return 0
}

_dlw_zero_output_comment_count() {
	local issue_number="$1"
	local repo_slug="$2"
	local zero_output_pattern="${_DLW_ZERO_OUTPUT_EVIDENCE_PATTERN}"

	[[ "${ZERO_OUTPUT_COMMENT_EVIDENCE_ENABLED:-1}" == "1" ]] || { printf '0'; return 0; }
	[[ "$issue_number" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
	[[ -n "$repo_slug" ]] || { printf '0'; return 0; }

	local count=""
	# shellcheck disable=SC2016  # jq program is intentionally single-quoted.
	count=$(gh api --paginate "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100" \
		--jq '[.[] | select((.body // "") | test("'"${zero_output_pattern}"'"; "i"))] | length' 2>/dev/null | \
		awk '{ if ($1 ~ /^[0-9]+$/) { total += $1 } } END { printf "%d", total + 0 }') || count=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	printf '%s' "$count"
	return 0
}

_dlw_comment_bloat_metrics() {
	local issue_number="$1"
	local repo_slug="$2"
	local zero_output_pattern="${_DLW_ZERO_OUTPUT_EVIDENCE_PATTERN}"
	local zero_attempt_pattern="${_DLW_ZERO_ATTEMPT_EVIDENCE_PATTERN}"

	[[ "${CLEAN_ROOM_COMMENT_EVIDENCE_ENABLED:-1}" == "1" ]] || { printf '0\t0\t0\t0\t0'; return 0; }
	[[ "$issue_number" =~ ^[0-9]+$ ]] || { printf '0\t0\t0\t0\t0'; return 0; }
	[[ -n "$repo_slug" ]] || { printf '0\t0\t0\t0\t0'; return 0; }

	local metrics=""
	# shellcheck disable=SC2016  # jq program is intentionally single-quoted.
	metrics=$(gh api --paginate "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100" \
		--jq '[.[] | {body: (.body // "")}] | {comments: length, ops: ([.[] | select(.body | test("ops:start|DISPATCH_CLAIM|CLAIM_RELEASED|dispatch-cooldown|Worker Watchdog Kill"; "i"))] | length), zero: ([.[] | select(.body | test("'"${zero_output_pattern}"'"; "i"))] | length), chars: ([.[].body | length] | add // 0), zero_attempt: ([.[] | select((.body | test("'"${zero_attempt_pattern}"'"; "i")) and (.body | test("session_count=0"; "i")))] | length)} | [.comments, .ops, .zero, .chars, .zero_attempt] | @tsv' \
		2>/dev/null | awk -F '\t' '{c+=$1; o+=$2; z+=$3; ch+=$4; za+=$5} END {printf "%d\t%d\t%d\t%d\t%d", c+0, o+0, z+0, ch+0, za+0}') || metrics="0	0	0	0	0"
	[[ -n "$metrics" ]] || metrics=$'0\t0\t0\t0\t0'
	printf '%s' "$metrics"
	return 0
}

_dlw_comment_bloat_requires_clean_room() {
	local issue_number="$1"
	local repo_slug="$2"
	local precomputed_metrics="${3:-}"

	local comments=""
	local ops=""
	local zero=""
	local chars=""
	local zero_attempt=""
	if [[ -z "$precomputed_metrics" ]]; then
		precomputed_metrics=$(_dlw_comment_bloat_metrics "$issue_number" "$repo_slug")
	fi
	IFS=$'\t' read -r comments ops zero chars zero_attempt \
		<<<"$precomputed_metrics"
	[[ "$comments" =~ ^[0-9]+$ ]] || comments=0
	[[ "$ops" =~ ^[0-9]+$ ]] || ops=0
	[[ "$zero" =~ ^[0-9]+$ ]] || zero=0
	[[ "$chars" =~ ^[0-9]+$ ]] || chars=0
	[[ "$zero_attempt" =~ ^[0-9]+$ ]] || zero_attempt=0
	local brief_zero_count=$((zero - zero_attempt))
	[[ "$brief_zero_count" -ge 0 ]] || brief_zero_count=0

	local comment_threshold="${CLEAN_ROOM_COMMENT_THRESHOLD:-100}"
	local ops_threshold="${CLEAN_ROOM_OPS_COMMENT_THRESHOLD:-50}"
	local zero_threshold="${CLEAN_ROOM_ZERO_OUTPUT_COMMENT_THRESHOLD:-10}"
	local chars_threshold="${CLEAN_ROOM_COMMENT_CHARS_THRESHOLD:-50000}"
	[[ "$comment_threshold" =~ ^[0-9]+$ ]] || comment_threshold=100
	[[ "$ops_threshold" =~ ^[0-9]+$ ]] || ops_threshold=50
	[[ "$zero_threshold" =~ ^[0-9]+$ ]] || zero_threshold=10
	[[ "$chars_threshold" =~ ^[0-9]+$ ]] || chars_threshold=50000

	if [[ "$comments" -ge "$comment_threshold" || "$ops" -ge "$ops_threshold" || "$brief_zero_count" -ge "$zero_threshold" || "$chars" -ge "$chars_threshold" ]]; then
		echo "[dispatch_with_dedup] #${issue_number} in ${repo_slug}: clean-room brief mode for comment-bloated issue comments=${comments} ops=${ops} zero=${zero} chars=${chars}" >>"$LOGFILE"
		return 0
	fi
	return 1
}

_dlw_fetch_issue_body_for_clean_room() {
	local issue_number="$1"
	local repo_slug="$2"
	local snapshot_helper="${ISSUE_BODY_SNAPSHOT_HELPER:-${BASH_SOURCE[0]%/*}/issue-body-snapshot-helper.sh}"
	local issue_json=""

	[[ -x "$snapshot_helper" ]] || return 1
	issue_json=$("$snapshot_helper" fetch "$repo_slug" "$issue_number") || return 1
	jq -rj '.body' <<<"$issue_json"
	return $?
}

_dlw_clean_room_prompt() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="$3"
	local issue_body="$4"

	cat <<EOF
You are assigned to work on issue #${issue_number} in ${repo_slug}.

This issue has a large audit/comment trail that is not implementation context. Use clean-room brief mode:

1. Do not read issue comments or timeline unless explicitly required by a maintainer.
2. Treat only the issue body below as the worker brief.
3. Ignore ops/provenance/audit comments, dispatch claims, release comments, watchdog comments, and cooldown comments.
4. Before editing, summarize the actionable task, files, and verification from the body below.
5. If the body is still not worker-ready, create a concise replacement child issue or add a maintainer-review comment instead of speculating.

Issue title: ${issue_title:-Issue #${issue_number}}

Clean issue body:

${issue_body:-No issue body was available. Read only the issue body with: gh issue view ${issue_number} --repo ${repo_slug} --json body --jq '.body'}
EOF
	return 0
}

_dlw_zero_output_evidence_count() {
	local issue_number="$1"
	local repo_slug="$2"
	local precomputed_comment_count="${3:-}"
	local precomputed_evidence_count="${4:-}"

	if [[ "$precomputed_evidence_count" =~ ^[0-9]+$ ]]; then
		printf '%s' "$precomputed_evidence_count"
		return 0
	fi

	local state_count="" comment_count=""
	if [[ "$precomputed_comment_count" =~ ^[0-9]+$ ]]; then
		comment_count="$precomputed_comment_count"
	else
		comment_count=$(_dlw_zero_output_comment_count "$issue_number" "$repo_slug")
	fi
	state_count=$(_dlw_zero_output_failure_count "$issue_number" "$repo_slug" "$comment_count")
	[[ "$state_count" =~ ^[0-9]+$ ]] || state_count=0
	[[ "$comment_count" =~ ^[0-9]+$ ]] || comment_count=0
	if [[ "$comment_count" -gt "$state_count" ]]; then
		printf '%s' "$comment_count"
	else
		printf '%s' "$state_count"
	fi
	return 0
}

_dlw_zero_output_fallback_prompt() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="$3"
	local snapshot_ready="${4:-0}"
	local snapshot_instruction=""

	if [[ "$snapshot_ready" == "1" ]]; then
		snapshot_instruction="2. If that live read is unavailable, read the bounded validated snapshot with: ~/.aidevops/agents/scripts/issue-body-snapshot-helper.sh fetch ${repo_slug} ${issue_number}"
	else
		snapshot_instruction="2. No validated snapshot was captured. If the live read fails, stop and report that implementation is not authorized without trusted issue context."
	fi

	cat <<EOF
You are assigned to work on issue #${issue_number} in ${repo_slug}.

Previous dispatch attempts for this issue launched a worker but produced zero session output. Do not rely on embedded issue content from the dispatcher.

First actions:
1. Read the issue body directly with: gh issue view ${issue_number} --repo ${repo_slug} --json body --jq '.body // ""'
${snapshot_instruction}
3. Ignore ops/provenance/audit comments as implementation context.
4. Summarize the actionable task, files, and verification before editing.
5. If the issue brief is malformed, too broad, or not worker-ready, rewrite the brief or split it into smaller worker-ready issues instead of attempting a speculative implementation.

Issue title: ${issue_title:-Issue #${issue_number}}
EOF
	return 0
}

_dlw_first_pass_completion_contract() {
	cat <<'EOF'

First-pass completion contract:
1. Before editing, verify the issue is still open and not already satisfied by the default branch, an open/closed PR, or a pushed issue branch. Reuse salvageable commits instead of restarting.
2. Treat prior structured CI/review feedback in the issue body as cumulative evidence. Address every terminal failing check, including advisory checks, not only the first required failure.
3. Validate the stated target files and verification commands against the current dependency/runtime versions before implementation.
4. After the first coherent commit, push and create a draft PR early so progress is durable and visible to every runner. Continue implementation and local verification on that PR; do not hand off while it is draft or has unpushed changes. Once the completed exact head is pushed, the PR is non-draft, its merge summary exists, and one immediate remote check shows no terminal failure, attempt merge once. If only asynchronous CI, bot review, human approval, or native auto-merge remains, exit and hand off to pulse. Never poll those gates or bypass approval, review, CI, branch-protection, or security controls.
5. Do not post routine dispatch, stale, or progress comments. Prefer commits, the PR, check runs, and one final completion or blocker dossier.
6. For routine tool discovery, use `command -v TOOL`, `TOOL --version`, or repository wrappers. Do not use file-reading tools to inspect `~/.bun/bin`, `~/.qlty/bin`, or `~/.local/bin`; unrelated external-directory reads still require maintainer approval.
EOF
	return 0
}

_dlw_validated_context_token() {
	local value="$1"
	if [[ "$value" =~ ^[A-Za-z0-9._:/-]{1,128}$ ]]; then
		printf '%s' "$value"
	else
		printf 'unknown'
	fi
	return 0
}

_dlw_prior_attempt_context() {
	local issue_number="$1"
	local repo_slug="$2"
	local helper="${OBJECTIVE_RECONCILIATION_HELPER:-${BASH_SOURCE[0]%/*}/objective-reconciliation-helper.sh}"
	local disposition=""
	local fields=""
	local empty_field="__AIDEVOPS_EMPTY_FIELD__"
	local source="" prior_attempt_id="" effective_outcome="" raw_result=""
	local status="" classification="" next_action=""
	local context=""
	local max_chars="${AIDEVOPS_RETRY_CONTEXT_MAX_CHARS:-1024}"

	[[ -x "$helper" ]] || return 0
	disposition=$("$helper" disposition --repo "$repo_slug" --issue "$issue_number" 2>/dev/null) || return 0
	fields=$(printf '%s' "$disposition" | jq -r --arg empty "$empty_field" \
		'[.source // "", .attempt_id // "", .effective_outcome // "", .raw_result // "", .status // "", .classification // "", .next_action // ""]
		| map(if . == "" then $empty else . end) | @tsv' 2>/dev/null) || return 0
	IFS=$'\t' read -r source prior_attempt_id effective_outcome raw_result status classification next_action <<<"$fields"
	[[ "$source" == "$empty_field" ]] && source=""
	[[ "$prior_attempt_id" == "$empty_field" ]] && prior_attempt_id=""
	[[ "$effective_outcome" == "$empty_field" ]] && effective_outcome=""
	[[ "$raw_result" == "$empty_field" ]] && raw_result=""
	[[ "$status" == "$empty_field" ]] && status=""
	[[ "$classification" == "$empty_field" ]] && classification=""
	[[ "$next_action" == "$empty_field" ]] && next_action=""
	case "$effective_outcome" in
	failed | deferred | escalated) ;;
	*) return 0 ;;
	esac
	source=$(_dlw_validated_context_token "$source")
	prior_attempt_id=$(_dlw_validated_context_token "$prior_attempt_id")
	effective_outcome=$(_dlw_validated_context_token "$effective_outcome")
	raw_result=$(_dlw_validated_context_token "$raw_result")
	status=$(_dlw_validated_context_token "$status")
	classification=$(_dlw_validated_context_token "$classification")
	next_action=$(_dlw_validated_context_token "$next_action")
	printf -v context '\nValidated prior-attempt state (machine-generated; prior model prose and issue comments are excluded):\n- source: %s\n- attempt_id: %s\n- effective_outcome: %s\n- raw_result: %s\n- status: %s\n- classification: %s\n- next_action: %s\nContinue from validated repository and PR state; do not repeat completed setup.' \
		"$source" "$prior_attempt_id" "$effective_outcome" "$raw_result" "$status" "$classification" "$next_action"
	[[ "$max_chars" =~ ^[0-9]+$ && "$max_chars" -ge 256 && "$max_chars" -le 4096 ]] || max_chars=1024
	if [[ "${#context}" -gt "$max_chars" ]]; then
		context="${context:0:max_chars}"
	fi
	printf '%s\n' "$context"
	return 0
}

_dlw_prepare_prompt_for_launch() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="$3"
	local original_prompt="$4"
	local precomputed_comment_metrics="${5:-}"
	local comment_metrics=""
	local comments=""
	local ops=""
	local metrics_zero_count=""
	local chars=""
	local zero_attempt_count=""
	local precomputed_zero_count=""
	local prior_attempt_context=""

	prior_attempt_context=$(_dlw_prior_attempt_context "$issue_number" "$repo_slug" || true)

	comment_metrics="$precomputed_comment_metrics"
	[[ -n "$comment_metrics" ]] || comment_metrics=$(_dlw_comment_bloat_metrics "$issue_number" "$repo_slug")
	IFS=$'\t' read -r comments ops metrics_zero_count chars zero_attempt_count <<<"$comment_metrics"
	[[ "$zero_attempt_count" =~ ^[0-9]+$ ]] || zero_attempt_count=0
	if [[ "${CLEAN_ROOM_COMMENT_EVIDENCE_ENABLED:-1}" == "1" && "$metrics_zero_count" =~ ^[0-9]+$ ]]; then
		precomputed_zero_count="$metrics_zero_count"
	fi

	if _dlw_comment_bloat_requires_clean_room "$issue_number" "$repo_slug" "$comment_metrics"; then
		local issue_body=""
		if ! issue_body=$(_dlw_fetch_issue_body_for_clean_room "$issue_number" "$repo_slug"); then
			echo "[dispatch_with_dedup] #${issue_number} in ${repo_slug}: clean-room issue body unavailable; implementation is not authorized" >>"$LOGFILE"
			_dlw_clean_room_prompt "$issue_number" "$repo_slug" "$issue_title" "BLOCKER: The live issue body and its validated durable snapshot are unavailable. Do not implement from this prompt. Retry the live gh issue view command and report the snapshot validation error if it remains unavailable."
			return 0
		fi
		_dlw_clean_room_prompt "$issue_number" "$repo_slug" "$issue_title" "$issue_body"
		printf '%s' "$prior_attempt_context"
		_dlw_first_pass_completion_contract
		return 0
	fi

	local zero_count=""
	zero_count=$(_dlw_zero_output_evidence_count "$issue_number" "$repo_slug" "$precomputed_zero_count")
	[[ "$zero_count" =~ ^[0-9]+$ ]] || zero_count=0
	local fallback_threshold="${ZERO_OUTPUT_URL_FALLBACK_THRESHOLD:-2}"
	[[ "$fallback_threshold" =~ ^[0-9]+$ ]] || fallback_threshold=2

	if [[ "$zero_count" -ge "$fallback_threshold" ]]; then
		local snapshot_helper="${ISSUE_BODY_SNAPSHOT_HELPER:-${BASH_SOURCE[0]%/*}/issue-body-snapshot-helper.sh}"
		local snapshot_ready=0
		if [[ -x "$snapshot_helper" ]] && "$snapshot_helper" fetch "$repo_slug" "$issue_number" >/dev/null 2>&1; then
			snapshot_ready=1
		fi
		echo "[dispatch_with_dedup] #${issue_number} in ${repo_slug}: using URL-only bootstrap prompt after ${zero_count} zero-output or zero-attempt failures (${zero_attempt_count} zero-attempt)" >>"$LOGFILE"
		_dlw_zero_output_fallback_prompt "$issue_number" "$repo_slug" "$issue_title" "$snapshot_ready"
		printf '%s' "$prior_attempt_context"
		_dlw_first_pass_completion_contract
		return 0
	fi

	printf '%s' "$original_prompt"
	printf '%s' "$prior_attempt_context"
	_dlw_first_pass_completion_contract
	return 0
}

_dlw_hold_repeated_zero_output() {
	local issue_number="$1"
	local repo_slug="$2"
	local precomputed_comment_metrics="${3:-}"
	local comment_metrics=""
	local comments=""
	local ops=""
	local metrics_zero_count=""
	local chars=""
	local zero_attempt_count=""
	local precomputed_zero_count=""

	comment_metrics="$precomputed_comment_metrics"
	[[ -n "$comment_metrics" ]] || comment_metrics=$(_dlw_comment_bloat_metrics "$issue_number" "$repo_slug")
	IFS=$'\t' read -r comments ops metrics_zero_count chars zero_attempt_count <<<"$comment_metrics"
	[[ "$zero_attempt_count" =~ ^[0-9]+$ ]] || zero_attempt_count=0
	if [[ "${CLEAN_ROOM_COMMENT_EVIDENCE_ENABLED:-1}" == "1" && "$metrics_zero_count" =~ ^[0-9]+$ ]]; then
		precomputed_zero_count="$metrics_zero_count"
	fi

	local hold_threshold="${ZERO_OUTPUT_BRIEF_REWRITE_HOLD_THRESHOLD:-4}"
	[[ "$hold_threshold" =~ ^[0-9]+$ ]] || hold_threshold=4
	if [[ "$zero_attempt_count" -lt "$hold_threshold" ]] &&
		_dlw_comment_bloat_requires_clean_room "$issue_number" "$repo_slug" "$comment_metrics"; then
		echo "[dispatch_with_dedup] #${issue_number} in ${repo_slug}: bypassing repeated zero-output brief-rewrite hold for clean-room brief mode" >>"$LOGFILE"
		return 1
	fi

	local zero_count=""
	zero_count=$(_dlw_zero_output_evidence_count "$issue_number" "$repo_slug" "$precomputed_zero_count")
	[[ "$zero_count" =~ ^[0-9]+$ ]] || zero_count=0
	if [[ "$zero_count" -lt "$hold_threshold" ]]; then
		return 1
	fi

	echo "[dispatch_with_dedup] Holding #${issue_number} in ${repo_slug}: ${zero_count} zero-output or zero-attempt failures; applying dispatch infrastructure hold" >>"$LOGFILE"
	if declare -F set_issue_status >/dev/null 2>&1; then
		set_issue_status "$issue_number" "$repo_slug" "blocked" >/dev/null 2>&1 || true
	else
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "status:blocked" \
			--remove-label "status:available" \
			--remove-label "status:queued" >/dev/null 2>&1 || true
	fi
	gh issue comment "$issue_number" --repo "$repo_slug" --body "<!-- dispatch-infrastructure-failure -->
## Dispatch infrastructure failure detected

This issue has accumulated ${zero_count} zero-output or zero-attempt worker failures. The brief may still be valid; repeated setup/runtime failures must be diagnosed before another automatic dispatch.

Next action: fix or wait out the worker/runtime failure family, then approve and requeue the issue so pulse can reconsider it afresh." >/dev/null 2>&1 || true
	return 0
}
