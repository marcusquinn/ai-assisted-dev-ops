#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pulse ancillary dispatch core helpers and triage input safeguards.
# Sourced by pulse-ancillary-dispatch.sh; no caller-facing API changes.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_ANCILLARY_DISPATCH_CORE_SH_LOADED:-}" ]] && return 0
_PULSE_ANCILLARY_DISPATCH_CORE_SH_LOADED=1

_triage_recommendation_label_contract() {
	printf '%s\t%s\t%s\n' \
		"$_PAD_TRIAGE_REVIEW_APPROVE_LABEL" "$_PAD_TRIAGE_REVIEW_APPROVE_COLOR" \
		"Advisory automated triage recommendation: approve" \
		"$_PAD_TRIAGE_REVIEW_FEEDBACK_LABEL" "$_PAD_TRIAGE_REVIEW_FEEDBACK_COLOR" \
		"Advisory automated triage recommendation: request changes" \
		"$_PAD_TRIAGE_REVIEW_DECLINE_LABEL" "$_PAD_TRIAGE_REVIEW_DECLINE_COLOR" \
		"Advisory automated triage recommendation: decline"
	return 0
}

# Return a bounded JSON snapshot of repository labels. Explicit page numbers
# prevent a malformed pagination response from creating an unbounded read loop.
_triage_recommendation_labels_snapshot() {
	local repo_slug="$1"
	local page=1
	local page_size=100
	local max_pages=10
	local response=""
	local response_count=""
	local snapshot='[]'

	while [[ "$page" -le "$max_pages" ]]; do
		response=$(AIDEVOPS_GH_ROUTE_DECISION="pulse-triage-label-inventory-rest" \
			gh api -X GET "/repos/${repo_slug}/labels?per_page=${page_size}&page=${page}" 2>/dev/null) || return 1
		response_count=$(printf '%s' "$response" | jq -er --arg array_type "$_PAD_JSON_ARRAY_TYPE" \
			'if type == $array_type then length else error("labels response has an invalid type") end' \
			2>/dev/null) || return 1
		snapshot=$(jq -cn --argjson current "$snapshot" --argjson page "$response" '
			$current + [$page[] | {
				name: (.name // ""),
				color: ((.color // "") | ascii_downcase),
				description: (.description // "")
			}]') || return 1
		if [[ "$response_count" -lt "$page_size" ]]; then
			printf '%s\n' "$snapshot"
			return 0
		fi
		page=$((page + 1))
	done
	return 1
}

_triage_recommendation_label_state() {
	local snapshot="$1"
	local expected_name="$2"
	local expected_color="$3"
	local expected_description="$4"
	printf '%s' "$snapshot" | jq -er --arg name "$expected_name" --arg color "$expected_color" \
		--arg description "$expected_description" '
		[.[] | select((.name | ascii_downcase) == ($name | ascii_downcase))][0] as $label
		| if $label == null then "missing"
		elif (($label.color | ascii_downcase) == ($color | ascii_downcase)) and
			($label.description == $description) then "current"
		else "drifted"
		end'
	return $?
}

_triage_recommendation_label_write() {
	local action="$1"
	local repo_slug="$2"
	local label_name="$3"
	local color="$4"
	local description="$5"
	local encoded_name=""

	if [[ "$action" == "create" ]]; then
		AIDEVOPS_GH_ROUTE_DECISION="pulse-triage-label-create-rest" \
			gh api -X POST "/repos/${repo_slug}/labels" -f name="$label_name" \
			-f color="$color" -f description="$description" >/dev/null 2>&1
		return $?
	fi
	[[ "$action" == "update" ]] || return 1
	encoded_name=$(jq -rn --arg name "$label_name" '$name | @uri') || return 1
	AIDEVOPS_GH_ROUTE_DECISION="pulse-triage-label-update-rest" \
		gh api -X PATCH "/repos/${repo_slug}/labels/${encoded_name}" -f new_name="$label_name" \
		-f color="$color" -f description="$description" >/dev/null 2>&1
	return $?
}

_triage_terminal_snapshot_fingerprint() {
	local issue_json="$1"
	printf '%s' "$issue_json" | jq -cS \
		'{number,title,body,updatedAt,labels:([.labels[].name] | sort)}' 2>/dev/null | \
		python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
	local statuses=("${PIPESTATUS[@]}")
	[[ "${statuses[0]}" -eq 0 && "${statuses[1]}" -eq 0 ]] || return 1
	return 0
}

_triage_terminal_snapshot_file() {
	local issue_num="$1"
	local repo_slug="$2"
	local reason="$3"
	local slug_safe="${repo_slug//\//_}"
	printf '%s/%s-%s.%s.terminal\n' \
		"${TRIAGE_CACHE_DIR:-${HOME}/.aidevops/.agent-workspace/tmp/triage-cache}" \
		"$slug_safe" "$issue_num" "$reason"
	return 0
}

_triage_terminal_snapshot_active() {
	local issue_num="$1"
	local repo_slug="$2"
	local reason="$3"
	local issue_json="$4"
	local state_file="" fingerprint="" recorded=""
	state_file=$(_triage_terminal_snapshot_file "$issue_num" "$repo_slug" "$reason") || return 1
	[[ -f "$state_file" ]] || return 1
	fingerprint=$(_triage_terminal_snapshot_fingerprint "$issue_json") || return 1
	recorded=$(<"$state_file")
	[[ "$recorded" == "$fingerprint" ]] || return 1
	return 0
}

_triage_mark_terminal_snapshot() {
	local issue_num="$1"
	local repo_slug="$2"
	local reason="$3"
	local issue_json="$4"
	local state_file="" state_dir="" fingerprint="" tmp_file=""
	state_file=$(_triage_terminal_snapshot_file "$issue_num" "$repo_slug" "$reason") || return 1
	state_dir="${state_file%/*}"
	fingerprint=$(_triage_terminal_snapshot_fingerprint "$issue_json") || return 1
	mkdir -p "$state_dir" || return 1
	tmp_file=$(mktemp "${state_file}.XXXXXX") || return 1
	if ! printf '%s\n' "$fingerprint" >"$tmp_file" || ! mv "$tmp_file" "$state_file"; then
		rm -f "$tmp_file"
		return 1
	fi
	printf '[pulse-wrapper] Triage prefetch terminal for #%s in %s (reason=%s) — unchanged snapshot requires manual review\n' \
		"$issue_num" "$repo_slug" "$reason" >>"$LOGFILE"
	return 0
}


#######################################
# Expand a repo path that may start with `~` into an absolute path.
_expand_foss_repo_path() {
	local repo_path="$1"
	case "$repo_path" in
	"~")
		printf '%s\n' "$HOME"
		;;
	\~/*)
		printf '%s\n' "${repo_path/#\~/$HOME}"
		;;
	*)
		printf '%s\n' "$repo_path"
		;;
	esac
	return 0
}

#######################################
# List one open FOSS issue matching a configured label.
#
# GitHub CLI treats commas in --label values as multiple labels. Use quoted
# search syntax only for comma-containing label names so a single configured
# label such as "needs, triage" remains one label at the point of use.
#
# Arguments:
#   $1 - repo_slug (owner/repo)
#   $2 - label
#######################################
_foss_issue_list_for_label() {
	local repo_slug="$1"
	local label="$2"
	local selector_args=()

	if [[ "$label" == *,* ]]; then
		local search_label="${label//\\/\\\\}"
		search_label="${search_label//\"/\\\"}"
		selector_args=(--search "label:\"${search_label}\"")
	else
		selector_args=(--label "$label")
	fi

	gh_issue_list --repo "$repo_slug" --state open \
		"${selector_args[@]}" --limit 1 \
		--json number,title --jq '.[] | "\(.number // "")|\(.title // "")"'
	return $?
}

#######################################
# Resolve the authenticated GitHub login for FOSS PR ownership checks.
#
# stdout: login, or empty when unavailable.
# Returns: 0 always (missing auth must fail open for FOSS dispatch).
#######################################
_foss_current_gh_login() {
	if [[ -n "${FOSS_CURRENT_GH_LOGIN:-}" ]]; then
		printf '%s\n' "$FOSS_CURRENT_GH_LOGIN"
		return 0
	fi
	gh api user --jq '.login // ""' 2>/dev/null || true
	return 0
}

#######################################
# Check whether this account already has an open PR for a FOSS issue.
#
# Args:
#   $1 - repo_slug (owner/repo)
#   $2 - issue number
#   $3 - optional precomputed authenticated GitHub login
# Returns: 0 when an open PR exists, 1 otherwise.
#######################################
_foss_open_pr_exists_for_issue() {
	local repo_slug="$1"
	local issue_number="$2"
	local login="${3:-}"
	[[ -n "$login" ]] || login=$(_foss_current_gh_login)
	[[ -n "$login" ]] || return 1

	local count
	count=$(gh_pr_list --repo "$repo_slug" --state open --author "$login" \
		--search "$issue_number" --json number --jq 'length' 2>/dev/null || printf '%s' '0')
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	[[ "$count" -gt 0 ]] && return 0
	return 1
}

#######################################
# Check recent FOSS worker metrics for terminal evidence or local-error backoff.
#
# Args:
#   $1 - FOSS session key (foss-owner/repo-issue)
#   $2 - mode: local|terminal
# Returns: 0 when recent evidence exists, 1 otherwise.
#######################################
_foss_recent_runtime_evidence() {
	local session_key="$1"
	local mode="$2"
	local metrics_file="${FOSS_RUNTIME_METRICS_FILE:-${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl}"
	local backoff_seconds="${FOSS_LOCAL_ERROR_BACKOFF_SECONDS:-3600}"
	local terminal_seconds="${FOSS_TERMINAL_EVIDENCE_SECONDS:-604800}"
	local window_seconds="$backoff_seconds"
	[[ "$mode" == "terminal" ]] && window_seconds="$terminal_seconds"
	[[ -n "$session_key" && -f "$metrics_file" ]] || return 1
	[[ "$window_seconds" =~ ^[0-9]+$ ]] || window_seconds=3600

	local matches
	matches=$(jq -rs --arg key "$session_key" --arg mode "$mode" \
		--argjson window "$window_seconds" '
		def result_match:
			(.result // "") as $runtime_result
			| if $mode == "local" then ($runtime_result == "local_error")
			else ($runtime_result == "success" or $runtime_result == "blocked")
			end;
		[.[] | select((.session_key // "") == $key)
			| select(((.ts // 0) | tonumber) >= (now - $window))
			| select(result_match)] | length
	' "$metrics_file" || printf '%s' '0')
	[[ "$matches" =~ ^[0-9]+$ ]] || matches=0
	[[ "$matches" -gt 0 ]] && return 0
	return 1
}

#######################################
# Provision the three canonical, mutually exclusive advisory recommendation
# labels. Failure is propagated so no review comment can be posted without its
# matching label state.
#######################################
_ensure_triage_recommendation_labels() {
	local repo_slug="$1"
	local labels_snapshot=""
	local label_name=""
	local color=""
	local description=""
	local label_state=""
	[[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	labels_snapshot=$(_triage_recommendation_labels_snapshot "$repo_slug") || return 1

	while IFS=$'\t' read -r label_name color description; do
		[[ -n "$label_name" ]] || continue
		label_state=$(_triage_recommendation_label_state "$labels_snapshot" "$label_name" \
			"$color" "$description") || return 1
		case "$label_state" in
		current) continue ;;
		missing)
			_triage_recommendation_label_write create "$repo_slug" "$label_name" \
				"$color" "$description" || return 1
			;;
		drifted)
			_triage_recommendation_label_write update "$repo_slug" "$label_name" \
				"$color" "$description" || return 1
			;;
		*) return 1 ;;
		esac
	done < <(_triage_recommendation_label_contract)
	return 0
}

#######################################
# Apply the advisory label matching a validated review's first-line decision.
# #aidevops:trust-boundary — these labels never clear needs-maintainer-review
# and never grant claim, approval, implementation, merge, or release authority.
#######################################
_set_triage_recommendation_label() {
	local issue_num="$1"
	local repo_slug="$2"
	local review_text="$3"
	local first_line="${review_text%%$'\n'*}"
	local target_label="" remove_label_one="" remove_label_two=""
	case "$first_line" in
	"## Review: Recommendation: Approve")
		target_label="$_PAD_TRIAGE_REVIEW_APPROVE_LABEL"
		remove_label_one="$_PAD_TRIAGE_REVIEW_FEEDBACK_LABEL"
		remove_label_two="$_PAD_TRIAGE_REVIEW_DECLINE_LABEL"
		;;
	"## Review: Recommendation: Request Changes")
		target_label="$_PAD_TRIAGE_REVIEW_FEEDBACK_LABEL"
		remove_label_one="$_PAD_TRIAGE_REVIEW_APPROVE_LABEL"
		remove_label_two="$_PAD_TRIAGE_REVIEW_DECLINE_LABEL"
		;;
	"## Review: Recommendation: Decline")
		target_label="$_PAD_TRIAGE_REVIEW_DECLINE_LABEL"
		remove_label_one="$_PAD_TRIAGE_REVIEW_APPROVE_LABEL"
		remove_label_two="$_PAD_TRIAGE_REVIEW_FEEDBACK_LABEL"
		;;
	*) return 1 ;;
	esac

	_ensure_triage_recommendation_labels "$repo_slug" || return 1
	gh issue edit "$issue_num" --repo "$repo_slug" \
		--remove-label "$remove_label_one" \
		--remove-label "$remove_label_two" \
		--add-label "$target_label" >/dev/null 2>&1 || return 1
	return 0
}

#######################################
# Post a maintainer-visible escalation comment when automated triage
# has exhausted its retry budget.
#
# Idempotent via the `<!-- triage-escalation -->` HTML marker — if a
# comment containing the marker already exists, this is a no-op.
# This closes the observability gap identified in t2016 where the
# content-hash cache was written after N failures, silently locking
# the issue out of triage with no visible signal to maintainers.
#
# Arguments:
#   $1 - issue_num
#   $2 - repo_slug
#   $3 - failure_reason (short machine-readable tag)
#   $4 - attempts (integer count of retries used)
#   $5 - last_output_chars (integer)
#
# Returns 0 on success or when the marker already exists; non-zero
# is reserved for unexpected gh failures (best-effort — the caller
# should not block on this).
#######################################
_post_triage_escalation_comment() {
	local issue_num="$1"
	local repo_slug="$2"
	local failure_reason="${3:-unknown}"
	local attempts="${4:-0}"
	local last_output_chars="${5:-0}"

	[[ -n "$issue_num" && -n "$repo_slug" ]] || return 0

	# Idempotency guard — scan existing comments for our marker.
	local existing=""
	existing=$(gh api "repos/${repo_slug}/issues/${issue_num}/comments" \
		--jq '[.[] | select(.body | contains("<!-- triage-escalation -->"))] | length' \
		2>/dev/null) || existing=""
	if [[ "$existing" =~ ^[0-9]+$ && "$existing" -gt 0 ]]; then
		echo "[pulse-wrapper] triage escalation comment already present on #${issue_num} in ${repo_slug} — skipping (idempotent)" >>"$LOGFILE"
		return 0
	fi

	# Map failure_reason → human-readable explanation.
	local reason_human="${failure_reason}"
	case "$failure_reason" in
	no-review-header)
		reason_human="Worker produced output but it did not contain a \`## Review\` header (safety filter suppressed the post)."
		;;
	raw-sandbox-output)
		reason_human="Worker output contained infrastructure/sandbox markers (log lines, exec metadata). Suppressed to prevent leaking internal paths."
		;;
	no-usable-output)
		reason_human="Worker returned no usable output (empty or <50 chars)."
		;;
	infra-markers-after-extraction)
		reason_human="Extracted review block still contained infrastructure markers — suppressed as a belt-and-suspenders safety check."
		;;
	oversized-output)
		reason_human="Worker produced a suspiciously long output (>20KB of extracted text). Likely a malfunctioning worker — format drift, runaway tool exploration, or a prompt that failed to constrain the response. See \`~/.aidevops/logs/triage-review-debug.log\` for a redacted sample (t2019)."
		;;
	esac

	# Compose signature footer via the canonical helper.
	local footer=""
	if [[ -x "$HOME/.aidevops/agents/scripts/gh-signature-helper.sh" ]]; then
		footer=$("$HOME/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
			--model "pulse-triage" \
			--issue "${repo_slug}#${issue_num}" 2>/dev/null) || footer=""
	fi

	local body_file=""
	body_file=$(mktemp)
	cat >"$body_file" <<ESCALATION_EOF
<!-- triage-escalation -->
## Automated triage could not produce a review

The pulse attempted to post an automated triage review on this issue **${attempts}** time(s) but every attempt was suppressed by the safety filter. The content-hash cache has now been written to stop the lock/unlock churn, which means **this issue will no longer appear in the automated triage queue** until its body or comments change.

### What went wrong

- **Reason:** ${reason_human}
- **Last attempt output size:** ${last_output_chars} chars
- **Failure tag:** \`${failure_reason}\`

### What a maintainer should do

1. **Review manually** — run \`/review-issue-pr ${issue_num}\` in an interactive session, or open the issue and evaluate it by hand.
2. **Force a retry** (optional) — delete the cache entry to let the next pulse cycle re-attempt:

    \`\`\`bash
    rm -f ~/.aidevops/.agent-workspace/tmp/triage-cache/$(echo "$repo_slug" | tr '/' '_')-${issue_num}.hash
    gh issue edit ${issue_num} --repo ${repo_slug} --remove-label triage-failed
    \`\`\`

3. **Fix the worker** (if this keeps happening) — huge headerless outputs usually mean the triage-review agent prompt needs tightening. See \`.agents/workflows/triage-review.md\`.

*This escalation was posted automatically by \`_post_triage_escalation_comment\` in \`pulse-ancillary-dispatch.sh\` (t2016) because the retry budget was exhausted without a visible review.*${footer:+

}${footer:-}
ESCALATION_EOF

	if gh_issue_comment "$issue_num" --repo "$repo_slug" --body-file "$body_file" >/dev/null 2>&1; then
		echo "[pulse-wrapper] Posted triage escalation comment on #${issue_num} in ${repo_slug} (reason: ${failure_reason}, attempts: ${attempts})" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Failed to post triage escalation comment on #${issue_num} in ${repo_slug}" >>"$LOGFILE"
	fi
	rm -f "$body_file"
	return 0
}

#######################################
# Classify headless-runtime failures that happen before a triage model can
# produce a review. These are infrastructure/contract failures, not review
# content failures, so they must not consume the triage retry/cache budget.
#
# Arguments:
#   $1 - raw runtime output sample
#
# Outputs the infrastructure failure reason, or nothing when not recognised.
# Returns 0 always.
#######################################
_triage_runtime_infra_failure_reason() {
	local sample="$1"

	if printf '%s' "$sample" | grep -qE 'Canary test FAILED|Canary failed.*aborting dispatch' 2>/dev/null; then
		printf '%s\n' 'canary-unavailable'
		return 0
	fi

	if printf '%s' "$sample" | grep -qE 'WORKER_ISSUE_NUMBER unset|WORKER_WORKTREE_PATH unset|worker env contract missing|worker --dir does not match WORKER_WORKTREE_PATH|worker worktree repo mismatch|WORKER_WORKTREE_PATH does not exist|incomplete worker ownership contract|worker ownership unavailable|worker_ownership_lost|runtime ownership fence stopped|worker_prepare_failed|OpenCode version drift|Failed to restore OpenCode|opencode version mismatch|launch cwd is deleted' 2>/dev/null; then
		printf '%s\n' 'prelaunch-contract-failure'
		return 0
	fi

	return 0
}

_triage_runtime_result_failure_reason() {
	local runtime_status="$1"
	local artifact_cleanup_status="$2"
	local raw_sample="$3"
	local failure_reason=""

	failure_reason=$(_triage_runtime_infra_failure_reason "$raw_sample")
	if [[ "$artifact_cleanup_status" -ne 0 ]]; then
		failure_reason="$_PAD_TRIAGE_RUNTIME_TEMP_FAILURE_REASON"
	elif [[ "$runtime_status" -ne 0 && -z "$failure_reason" ]]; then
		failure_reason="triage-runtime-failed"
	fi
	[[ -z "$failure_reason" ]] || printf '%s\n' "$failure_reason"
	return 0
}

#######################################
# Return whether a triage failure reason is infrastructure-only. Keep this
# centralised so label/cache/retry policy cannot drift across call sites.
#
# Arguments:
#   $1 - failure reason tag
#
# Returns 0 when infrastructure-only, 1 otherwise.
#######################################
_triage_failure_is_infrastructure() {
	local failure_reason="$1"

	case "$failure_reason" in
	canary-unavailable | prelaunch-contract-failure | github-comment-write-failed | github-review-label-write-failed | triage-runtime-failed | triage-runtime-temp-failed | github-current-snapshot-* | github-pr-revision-* | github-public-revision-* | triage-current-snapshot-hash-failed | triage-evidence-* | triage-prompt-* | scanner-unavailable-* | scanner-tempfile-* | scanner-input-* | scanner-error-*) return 0 ;;
	*) return 1 ;;
	esac
}

#######################################
# Create a private managed directory for untrusted triage artifacts and start
# a detached cleanup guardian. Normal paths remove the directory immediately;
# the guardian covers SIGKILL and enforces bounded retention.
#
# Arguments:
#   $1 - purpose suffix
#
# Prints the directory path on success.
#######################################
_triage_create_sensitive_artifact_dir() {
	local purpose="$1"
	local artifact_dir=""
	local max_age_seconds="${TRIAGE_RUNTIME_TEMP_MAX_AGE_SECONDS:-25200}"
	local poll_seconds="${TRIAGE_RUNTIME_TEMP_GUARD_POLL_SECONDS:-2}"

	artifact_dir=$(aidevops_sensitive_temp_create_dir "triage-${purpose}") || return 1
	if ! aidevops_sensitive_temp_start_guardian \
		"$artifact_dir" "$$" "$max_age_seconds" "$poll_seconds"; then
		aidevops_sensitive_temp_cleanup "$artifact_dir" 2>/dev/null || true
		return 1
	fi
	printf '%s\n' "$artifact_dir"
	return 0
}

_triage_cleanup_sensitive_artifact_dir() {
	local artifact_dir="$1"
	[[ -n "$artifact_dir" ]] || return 0
	aidevops_sensitive_temp_cleanup "$artifact_dir" 2>/dev/null || return 1
	return 0
}

#######################################
# Scan untrusted prompt segments before they can reach a model. Normalization
# and full scanning are mandatory. Every non-clean result blocks the model;
# confirmed WARN/BLOCK findings create a security hold, while scanner
# infrastructure failures remain unlabeled retries.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#   $3 - controlled scan-stage tag
#   $4... - untrusted content segments
#
# Returns 0 only for an explicit CLEAN result, 1 otherwise.
#######################################
_triage_untrusted_content_is_safe() {
	local issue_num="$1"
	local repo_slug="$2"
	local scan_stage="$3"
	local cleanup_failure_log="[pulse-wrapper] SECURITY: triage scanner artifact cleanup failed for #${issue_num} in ${repo_slug}; guardian retained"
	shift 3

	if [[ ! -x "$TRIAGE_CONTENT_SCANNER" || ! -x "$TRIAGE_PROMPT_GUARD" ]]; then
		_triage_mark_infrastructure_retry "$issue_num" "$repo_slug" "scanner-unavailable-${scan_stage}"
		return 1
	fi

	local scan_dir=""
	scan_dir=$(_triage_create_sensitive_artifact_dir "scan") || {
		_triage_mark_infrastructure_retry "$issue_num" "$repo_slug" "scanner-tempfile-failed-${scan_stage}"
		return 1
	}
	local scan_file="${scan_dir}/untrusted-content.txt"
	if ! (umask 077 && : >"$scan_file"); then
		if ! _triage_cleanup_sensitive_artifact_dir "$scan_dir"; then
			echo "$cleanup_failure_log" >>"$LOGFILE"
		fi
		_triage_mark_infrastructure_retry "$issue_num" "$repo_slug" "scanner-tempfile-failed-${scan_stage}"
		return 1
	fi
	local segment=""
	for segment in "$@"; do
		printf '%s\n--- UNTRUSTED SEGMENT ---\n' "$segment" >>"$scan_file" || {
			if ! _triage_cleanup_sensitive_artifact_dir "$scan_dir"; then
				echo "$cleanup_failure_log" >>"$LOGFILE"
			fi
			_triage_mark_infrastructure_retry "$issue_num" "$repo_slug" "scanner-input-failed-${scan_stage}"
			return 1
		}
	done

	local scan_output=""
	local scan_status=0
	scan_output=$(CONTENT_SCANNER_QUIET=true CONTENT_SCANNER_SKIP_PREFILTER=true \
		PROMPT_GUARD_POLICY=moderate PROMPT_GUARD_PERSIST_CONTENT=false \
		"$TRIAGE_CONTENT_SCANNER" scan-file "$scan_file" \
		2>/dev/null) || scan_status=$?
	local cleanup_status=0
	_triage_cleanup_sensitive_artifact_dir "$scan_dir" || cleanup_status=$?

	if [[ "$scan_status" -eq 0 && "$scan_output" == "CLEAN" ]]; then
		if [[ "$cleanup_status" -ne 0 ]]; then
			_triage_mark_infrastructure_retry \
				"$issue_num" "$repo_slug" "$_PAD_TRIAGE_RUNTIME_TEMP_FAILURE_REASON"
			return 1
		fi
		return 0
	fi
	if [[ "$cleanup_status" -ne 0 ]]; then
		echo "$cleanup_failure_log" >>"$LOGFILE"
	fi
	if [[ "$scan_status" -eq 1 && "$scan_output" == "FLAGGED" ]]; then
		_triage_mark_security_hold \
			"$issue_num" "$repo_slug" "prompt-injection-detected-${scan_stage}"
	elif [[ "$scan_status" -eq 2 && "$scan_output" == "WARN" ]]; then
		_triage_mark_security_hold \
			"$issue_num" "$repo_slug" "prompt-injection-warning-${scan_stage}"
	else
		_triage_mark_infrastructure_retry \
			"$issue_num" "$repo_slug" "scanner-error-${scan_stage}"
	fi
	return 1
}

#######################################
# Append metadata for a suppressed triage review output. Model and runtime
# output is intentionally never retained: even redacted samples can preserve
# public prompt content or incomplete infrastructure secrets.
#
# Arguments:
#   $1 - issue_num
#   $2 - repo_slug
#   $3 - failure_reason tag (e.g., no-review-header, oversized-output)
#   $4 - output_chars (integer)
#######################################
_log_suppressed_triage_output() {
	local issue_num="$1"
	local repo_slug="$2"
	local failure_reason="$3"
	local output_chars="$4"

	local debug_log="${HOME}/.aidevops/logs/triage-review-debug.log"
	mkdir -p "$(dirname "$debug_log")" 2>/dev/null || return 0

	{
		printf -- '---\n'
		printf 'timestamp: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'issue: %s#%s\n' "$repo_slug" "$issue_num"
		printf 'failure_reason: %s\n' "$failure_reason"
		printf 'output_chars: %s\n' "$output_chars"
	} >>"$debug_log" 2>/dev/null || true
	return 0
}

#######################################
# Count the bytes in a shell string independently of the process locale.
_triage_text_byte_count() {
	local text="$1"
	local byte_count=""
	byte_count=$(printf '%s' "$text" | LC_ALL=C wc -c) || return 1
	byte_count="${byte_count//[[:space:]]/}"
	[[ "$byte_count" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$byte_count"
	return 0
}
