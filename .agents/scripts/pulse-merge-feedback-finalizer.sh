#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared, head-bound finalization for Pulse feedback routing.

[[ -n "${_PULSE_MERGE_FEEDBACK_FINALIZER_LOADED:-}" ]] && return 0
_PULSE_MERGE_FEEDBACK_FINALIZER_LOADED=1

PULSE_FEEDBACK_ROUTE_DEFERRED_RC=75
PULSE_FEEDBACK_ROUTE_MAINTAINER_RC=76
PULSE_FEEDBACK_ROUTE_HANDLED_RC=77
PULSE_FEEDBACK_ROUTE_CLOSED_STATE="CLOSED"
PULSE_FEEDBACK_ROUTE_HOLD_LABEL="hold-for-review"
PULSE_FEEDBACK_ROUTE_NMR_LABEL="needs-maintainer-review"
PULSE_FEEDBACK_ROUTE_OPEN_STATE="OPEN"

_feedback_route_gh_write() {
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout write gh "$@"
		return $?
	fi
	gh "$@"
	return $?
}

_feedback_route_labels_include() {
	local labels="$1"
	local expected_label="$2"
	[[ ",${labels}," == *",${expected_label},"* ]]
	return $?
}

_feedback_route_labels_block_routing() {
	local labels="$1"

	if _feedback_route_labels_include "$labels" "no-takeover" \
		|| _feedback_route_labels_include "$labels" "external-contributor" \
		|| _feedback_route_labels_include "$labels" "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL" \
		|| _feedback_route_labels_include "$labels" "$PULSE_FEEDBACK_ROUTE_NMR_LABEL"; then
		return 0
	fi
	if _feedback_route_labels_include "$labels" "origin:interactive" \
		&& ! _feedback_route_labels_include "$labels" "origin:worker-takeover"; then
		return 0
	fi
	return 1
}

_feedback_route_terminal_label_for_kind() {
	local kind="$1"
	case "$kind" in
	review) printf '%s\n' 'review-routed-to-issue' ;;
	conflict) printf '%s\n' 'conflict-feedback-routed' ;;
	ci) printf '%s\n' 'ci-feedback-routed' ;;
	*) return 1 ;;
	esac
	return 0
}

_feedback_route_body_has_other_head_evidence() {
	local issue_body="$1"
	local kind="$2"
	local pr_number="$3"
	local start_marker="$4"
	local completion_marker="$5"
	local start_prefix="<!-- feedback-route:start:${kind}:PR${pr_number}:SHA"
	local completion_prefix="<!-- feedback-route:complete:${kind}:PR${pr_number}:SHA"

	if printf '%s' "$issue_body" | grep -F "$start_prefix" | grep -qvF "$start_marker"; then
		return 0
	fi
	if printf '%s' "$issue_body" | grep -F "$completion_prefix" | grep -qvF "$completion_marker"; then
		return 0
	fi
	return 1
}

_feedback_route_issue_endpoint() {
	local repo_slug="$1"
	local linked_issue="$2"
	printf 'repos/%s/issues/%s' "$repo_slug" "$linked_issue"
	return 0
}

_feedback_route_release_marker() {
	local kind="$1"
	local pr_number="$2"
	local expected_head="$3"
	printf '<!-- feedback-route:dispatch-release:%s:PR%s:SHA%s -->' \
		"$kind" "$pr_number" "$expected_head"
	return 0
}

_feedback_route_release_comments() {
	local linked_issue="$1"
	local repo_slug="$2"
	local marker="$3"
	local endpoint="repos/${repo_slug}/issues/${linked_issue}/comments?per_page=100"
	local comments_json=""
	# #aidevops:trust-boundary — only trusted automation comments can satisfy or
	# win release-marker convergence; copied markers from untrusted users do not.
	# shellcheck disable=SC2016 # $marker is a jq variable supplied below.
	local filter='[
		(if type == "array" and ((.[0]? | type) == "array") then .[] else . end)[]?
		| select((.author_association // "") as $association
			| ["OWNER", "MEMBER", "COLLABORATOR"] | index($association))
		| select((.body // "") | startswith("CLAIM_RELEASED reason=feedback_route_") and contains($marker))
		| {id, created_at}
	] | sort_by([.created_at, .id])'

	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		comments_json=$(_gh_with_timeout read gh api "$endpoint" --paginate --slurp 2>/dev/null) || return 1
	else
		comments_json=$(gh api "$endpoint" --paginate --slurp 2>/dev/null) || return 1
	fi
	printf '%s' "$comments_json" | jq -c --arg marker "$marker" "$filter" 2>/dev/null
	return $?
}

_feedback_route_release_exists() {
	local linked_issue="$1"
	local repo_slug="$2"
	local marker="$3"
	local comments_json=""

	comments_json=$(_feedback_route_release_comments "$linked_issue" "$repo_slug" "$marker") || return 1
	printf '%s' "$comments_json" | jq -e 'length > 0' >/dev/null 2>&1
	return $?
}

_feedback_route_reconcile_release_comments() {
	local linked_issue="$1"
	local repo_slug="$2"
	local marker="$3"
	local comments_json=""
	local duplicate_id=""

	comments_json=$(_feedback_route_release_comments "$linked_issue" "$repo_slug" "$marker") || return 1
	while IFS= read -r duplicate_id; do
		[[ "$duplicate_id" =~ ^[0-9]+$ ]] || continue
		_feedback_route_gh_write api "repos/${repo_slug}/issues/comments/${duplicate_id}" \
			--method DELETE >/dev/null 2>&1 || true
	done < <(printf '%s' "$comments_json" | jq -r '.[1:][]?.id' 2>/dev/null)
	return 0
}

_feedback_route_release_dispatch_claim() {
	local kind="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local linked_issue="$4"
	local expected_head="$5"
	local marker=""
	local comment_body=""
	local comment_status=0

	marker=$(_feedback_route_release_marker "$kind" "$pr_number" "$expected_head")
	if _feedback_route_release_exists "$linked_issue" "$repo_slug" "$marker"; then
		_feedback_route_reconcile_release_comments "$linked_issue" "$repo_slug" "$marker" || true
		return 0
	fi
	comment_body="CLAIM_RELEASED reason=feedback_route_${kind} runner=pulse ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
${marker}"
	if declare -F gh_issue_comment >/dev/null 2>&1; then
		gh_issue_comment "$linked_issue" --repo "$repo_slug" --body "$comment_body" >/dev/null 2>&1 || comment_status=$?
	else
		_feedback_route_gh_write issue comment "$linked_issue" --repo "$repo_slug" \
			--body "$comment_body" >/dev/null 2>&1 || comment_status=$?
	fi
	[[ "$comment_status" -eq 0 ]] || return "$comment_status"
	_feedback_route_reconcile_release_comments "$linked_issue" "$repo_slug" "$marker" || true
	return 0
}

_feedback_route_marker() {
	local phase="$1"
	local kind="$2"
	local pr_number="$3"
	local expected_head="$4"
	local evidence_fingerprint="${5:-}"
	if [[ -n "$evidence_fingerprint" ]]; then
		printf '<!-- feedback-route:%s:%s:PR%s:SHA%s:EVIDENCE%s -->' \
			"$phase" "$kind" "$pr_number" "$expected_head" "$evidence_fingerprint"
		return 0
	fi
	printf '<!-- feedback-route:%s:%s:PR%s:SHA%s -->' "$phase" "$kind" "$pr_number" "$expected_head"
	return 0
}

# Return success only when every prior evidence-bound review start marker has
# an exact completion partner and every completion has an exact start partner.
# The current start marker may be incomplete because this call resumes it.
_feedback_route_review_generations_complete() {
	local issue_body="$1"
	local pr_number="$2"
	local current_start="$3"
	local start_prefix="<!-- feedback-route:start:review:PR${pr_number}:SHA"
	local completion_prefix="<!-- feedback-route:complete:review:PR${pr_number}:SHA"
	local marker=""
	local partner=""

	while IFS= read -r marker; do
		[[ -n "$marker" ]] || continue
		[[ "$marker" == *":EVIDENCE"*" -->" ]] || return 1
		[[ "$marker" == "$current_start" ]] && continue
		partner="${marker/feedback-route:start:/feedback-route:complete:}"
		printf '%s' "$issue_body" | grep -qF "$partner" || return 1
	done < <(printf '%s\n' "$issue_body" | grep -F "$start_prefix" || true)

	while IFS= read -r marker; do
		[[ -n "$marker" ]] || continue
		[[ "$marker" == *":EVIDENCE"*" -->" ]] || return 1
		partner="${marker/feedback-route:complete:/feedback-route:start:}"
		printf '%s' "$issue_body" | grep -qF "$partner" || return 1
	done < <(printf '%s\n' "$issue_body" | grep -F "$completion_prefix" || true)
	return 0
}

_feedback_route_review_evidence_completed() {
	local issue_body="$1"
	local pr_number="$2"
	local evidence_fingerprint="$3"
	local completion_prefix="<!-- feedback-route:complete:review:PR${pr_number}:SHA"
	local evidence_suffix=":EVIDENCE${evidence_fingerprint} -->"

	printf '%s\n' "$issue_body" | grep -F "$completion_prefix" | grep -qF "$evidence_suffix"
	return $?
}

_feedback_route_pr_snapshot() {
	local pr_number="$1"
	local repo_slug="$2"
	local endpoint="repos/${repo_slug}/pulls/${pr_number}"
	local filter='[if .merged_at != null then "MERGED" else ((.state // "") | ascii_upcase) end, (.head.sha // ""), ([.labels[].name] | join(","))] | @tsv'

	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read gh api "$endpoint" --jq "$filter" 2>/dev/null
		return $?
	fi
	gh api "$endpoint" --jq "$filter" 2>/dev/null
	return $?
}

_feedback_route_issue_body() {
	local linked_issue="$1"
	local repo_slug="$2"
	local endpoint=""
	endpoint=$(_feedback_route_issue_endpoint "$repo_slug" "$linked_issue")
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read gh api "$endpoint" --jq '.body // ""' 2>/dev/null
		return $?
	fi
	gh api "$endpoint" --jq '.body // ""' 2>/dev/null
	return $?
}

_feedback_route_issue_snapshot() {
	local linked_issue="$1"
	local repo_slug="$2"
	local endpoint=""
	endpoint=$(_feedback_route_issue_endpoint "$repo_slug" "$linked_issue")
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read gh api "$endpoint" \
			--jq '[([.labels[].name] | join(",")), ([.assignees[].login] | join(","))] | @tsv' 2>/dev/null
		return $?
	fi
	gh api "$endpoint" \
		--jq '[([.labels[].name] | join(",")), ([.assignees[].login] | join(","))] | @tsv' 2>/dev/null
	return $?
}

_feedback_route_issue_is_ready() {
	local linked_issue="$1"
	local repo_slug="$2"
	local source_label="$3"
	local snapshot=""
	local labels=""
	local assignees=""

	snapshot=$(_feedback_route_issue_snapshot "$linked_issue" "$repo_slug") || return 1
	IFS=$'\t' read -r labels assignees <<<"$snapshot"
	_feedback_route_labels_include "$labels" "status:available" || return 1
	_feedback_route_labels_include "$labels" "$source_label" || return 1
	_feedback_route_labels_include "$labels" "origin:worker" || return 1
	! _feedback_route_labels_include "$labels" "origin:interactive" || return 1
	! _feedback_route_labels_include "$labels" "origin:worker-takeover" || return 1
	! _feedback_route_labels_include "$labels" "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL" || return 1
	! _feedback_route_labels_include "$labels" "$PULSE_FEEDBACK_ROUTE_NMR_LABEL" || return 1
	[[ -z "$assignees" ]] || return 1
	return 0
}

_feedback_route_body_contains() {
	local linked_issue="$1"
	local repo_slug="$2"
	local marker="$3"
	local body=""
	body=$(_feedback_route_issue_body "$linked_issue" "$repo_slug") || return 1
	printf '%s' "$body" | grep -qF "$marker"
	return $?
}

_feedback_route_hold_for_maintainer() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local reason="$4"
	local issue_hold_rc=0
	local pr_hold_rc=0

	if declare -F set_issue_status >/dev/null 2>&1; then
		set_issue_status "$linked_issue" "$repo_slug" "in-review" \
			--add-label "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL" >/dev/null 2>&1 || issue_hold_rc=$?
	else
		_feedback_route_gh_write issue edit "$linked_issue" --repo "$repo_slug" \
			--add-label "status:in-review" --add-label "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL" \
			--remove-label "status:available" >/dev/null 2>&1 || issue_hold_rc=$?
	fi
	_feedback_route_gh_write pr edit "$pr_number" --repo "$repo_slug" \
		--add-label "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL" >/dev/null 2>&1 || pr_hold_rc=$?
	echo "[pulse-wrapper] feedback finalizer: preserving PR #${pr_number} and issue #${linked_issue} in ${repo_slug} for maintainer review — ${reason} (issue_hold_rc=${issue_hold_rc}, pr_hold_rc=${pr_hold_rc})" >>"$LOGFILE"
	return "$PULSE_FEEDBACK_ROUTE_MAINTAINER_RC"
}

_feedback_route_defer() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local reason="$4"
	echo "[pulse-wrapper] feedback finalizer: deferred PR #${pr_number} and issue #${linked_issue} in ${repo_slug} — ${reason}" >>"$LOGFILE"
	return "$PULSE_FEEDBACK_ROUTE_DEFERRED_RC"
}

_feedback_route_transition_and_verify() {
	local linked_issue="$1"
	local repo_slug="$2"
	local source_label="$3"
	local clear_hold="${4:-0}"

	_transition_issue_for_redispatch "$linked_issue" "$repo_slug" "$source_label" "$clear_hold" || return 1
	_feedback_route_issue_is_ready "$linked_issue" "$repo_slug" "$source_label"
	return $?
}

_feedback_route_apply_terminal_label() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head="$3"
	local terminal_label="$4"
	local snapshot=""
	local pr_state=""
	local current_head=""
	local labels=""

	_feedback_route_gh_write pr edit "$pr_number" --repo "$repo_slug" --add-label "$terminal_label" >/dev/null 2>&1 || return 1
	snapshot=$(_feedback_route_pr_snapshot "$pr_number" "$repo_slug") || return 1
	IFS=$'\t' read -r pr_state current_head labels <<<"$snapshot"
	[[ "$pr_state" == "$PULSE_FEEDBACK_ROUTE_CLOSED_STATE" && "$current_head" == "$expected_head" ]] || return 1
	_feedback_route_labels_include "$labels" "$terminal_label" || return 1
	_feedback_route_gh_write pr edit "$pr_number" --repo "$repo_slug" --remove-label "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL" >/dev/null 2>&1 || true
	return 0
}

_feedback_route_prepare_start() {
	local kind="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local linked_issue="$4"
	local expected_head="$5"
	local pr_state="$6"
	local issue_body="$7"
	local start_marker="$8"
	local legacy_marker="$9"
	local feedback_section="${10}"
	local caller="${11}"
	local legacy_match="${12:-$legacy_marker}"

	if printf '%s' "$issue_body" | grep -qF "$start_marker"; then
		return 0
	fi
	if printf '%s' "$issue_body" | grep -qF "$legacy_match"; then
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"legacy ${kind} route marker has no head-bound start evidence"
		return $?
	fi
	if [[ "$pr_state" != "$PULSE_FEEDBACK_ROUTE_OPEN_STATE" ]]; then
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"new ${kind} route expected OPEN at head ${expected_head}, observed ${pr_state:-unknown}"
		return $?
	fi

	_append_feedback_to_issue "$linked_issue" "$repo_slug" "$start_marker" \
		"${legacy_marker}
${feedback_section}" "$caller" || {
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "could not persist the head-bound ${kind} route start marker"
		return $?
	}
	if ! _feedback_route_body_contains "$linked_issue" "$repo_slug" "$start_marker"; then
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "head-bound ${kind} route start marker was not verifiable after write"
		return $?
	fi
	return 0
}

_feedback_route_restore_after_postclose_failure() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local expected_head="$4"
	local reason="$5"
	local snapshot=""
	local pr_state=""
	local current_head=""
	local labels=""

	_feedback_route_gh_write pr reopen "$pr_number" --repo "$repo_slug" >/dev/null 2>&1 || {
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"${reason}; compensating reopen failed"
		return $?
	}
	snapshot=$(_feedback_route_pr_snapshot "$pr_number" "$repo_slug") || snapshot=""
	IFS=$'\t' read -r pr_state current_head labels <<<"$snapshot"
	if [[ "$pr_state" != "$PULSE_FEEDBACK_ROUTE_OPEN_STATE" || "$current_head" != "$expected_head" ]]; then
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"${reason}; compensating reopen could not verify the original head"
		return $?
	fi
	_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "${reason}; restored OPEN state for retry"
	return $?
}

_feedback_route_finish_closed() {
	local kind="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local linked_issue="$4"
	local expected_head="$5"
	local terminal_label="$6"
	local completion_marker="$7"
	local caller="$8"
	local closed_by_this_call="$9"

	if ! _append_feedback_to_issue "$linked_issue" "$repo_slug" "$completion_marker" "" "$caller"; then
		if [[ "$closed_by_this_call" == "1" ]]; then
			_feedback_route_restore_after_postclose_failure "$pr_number" "$repo_slug" "$linked_issue" \
				"$expected_head" "could not persist ${kind} completion evidence"
			return $?
		fi
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"closed ${kind} route could not persist completion evidence"
		return $?
	fi
	if ! _feedback_route_body_contains "$linked_issue" "$repo_slug" "$completion_marker"; then
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"closed ${kind} route completion evidence could not be verified after write"
		return $?
	fi
	if ! _feedback_route_release_dispatch_claim "$kind" "$pr_number" "$repo_slug" \
		"$linked_issue" "$expected_head"; then
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" \
			"completed ${kind} route could not retire the prior dispatch claim"
		return $?
	fi

	if ! _feedback_route_apply_terminal_label "$pr_number" "$repo_slug" "$expected_head" "$terminal_label"; then
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"completed ${kind} route could not apply and verify terminal label ${terminal_label}"
		return $?
	fi
	echo "[pulse-wrapper] feedback finalizer: completed ${kind} route for PR #${pr_number} head ${expected_head} to issue #${linked_issue} in ${repo_slug}" >>"$LOGFILE"
	return 0
}

_feedback_route_resume_completed() {
	local kind="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local linked_issue="$4"
	local expected_head="$5"
	local pr_state="$6"
	local source_label="$7"
	local terminal_label="$8"
	local labels="$9"

	if [[ "$pr_state" == "$PULSE_FEEDBACK_ROUTE_OPEN_STATE" ]]; then
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"completed same-head ${kind} route was reopened; refusing automatic re-close"
		return $?
	fi
	if [[ "$pr_state" != "$PULSE_FEEDBACK_ROUTE_CLOSED_STATE" ]]; then
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"completed ${kind} route expected CLOSED at head ${expected_head}, observed ${pr_state:-unknown}"
		return $?
	fi
	if _feedback_route_labels_include "$labels" "$terminal_label"; then
		if _feedback_route_issue_is_ready "$linked_issue" "$repo_slug" "$source_label"; then
			_feedback_route_release_dispatch_claim "$kind" "$pr_number" "$repo_slug" \
				"$linked_issue" "$expected_head" || return "$PULSE_FEEDBACK_ROUTE_DEFERRED_RC"
			return 0
		fi
		if ! _feedback_route_transition_and_verify "$linked_issue" "$repo_slug" "$source_label" 1; then
			_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "completed ${kind} route could not restore redispatch issue state"
			return $?
		fi
		_feedback_route_release_dispatch_claim "$kind" "$pr_number" "$repo_slug" \
			"$linked_issue" "$expected_head" || return "$PULSE_FEEDBACK_ROUTE_DEFERRED_RC"
		return 0
	fi
	if ! _feedback_route_transition_and_verify "$linked_issue" "$repo_slug" "$source_label" 1; then
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "completed ${kind} route could not re-verify redispatch issue state"
		return $?
	fi
	if ! _feedback_route_release_dispatch_claim "$kind" "$pr_number" "$repo_slug" \
		"$linked_issue" "$expected_head"; then
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" \
			"completed ${kind} route could not retire the prior dispatch claim"
		return $?
	fi
	if ! _feedback_route_apply_terminal_label "$pr_number" "$repo_slug" "$expected_head" "$terminal_label"; then
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"completed ${kind} route could not recover terminal label ${terminal_label}"
		return $?
	fi
	return 0
}

_feedback_route_close_and_finish() {
	local kind="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local linked_issue="$4"
	local expected_head="$5"
	local terminal_label="$6"
	local completion_marker="$7"
	local caller="$8"
	local close_comment="$9"
	local pr_state="${10}"
	local start_marker="${11}"
	local snapshot=""
	local current_head=""
	local labels=""
	local close_rc=0
	local close_snapshot_rc=0
	local closed_by_this_call=0

	if [[ "$pr_state" == "$PULSE_FEEDBACK_ROUTE_OPEN_STATE" ]]; then
		_feedback_route_gh_write pr close "$pr_number" --repo "$repo_slug" \
			--comment "${close_comment}

${start_marker}" >/dev/null 2>&1 || close_rc=$?
		[[ "$close_rc" -eq 0 ]] && closed_by_this_call=1
		snapshot=$(_feedback_route_pr_snapshot "$pr_number" "$repo_slug") || close_snapshot_rc=$?
		if [[ "$close_snapshot_rc" -ne 0 || -z "$snapshot" ]]; then
			if [[ "$closed_by_this_call" -eq 1 ]]; then
				_feedback_route_restore_after_postclose_failure "$pr_number" "$repo_slug" "$linked_issue" \
					"$expected_head" "PR snapshot unavailable after acknowledged ${kind} close"
				return $?
			fi
			_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
				"${kind} close outcome is unknown after failed close and unavailable verification"
			return $?
		fi
		IFS=$'\t' read -r pr_state current_head labels <<<"$snapshot"
		if [[ "$current_head" != "$expected_head" ]]; then
			if [[ "$closed_by_this_call" -eq 1 ]]; then
				_feedback_route_restore_after_postclose_failure "$pr_number" "$repo_slug" "$linked_issue" \
					"$expected_head" "${kind} route head changed during close (${expected_head} to ${current_head:-unknown})"
				return $?
			fi
			_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
				"${kind} route head changed during an ambiguous close (${expected_head} to ${current_head:-unknown})"
			return $?
		fi
		if [[ "$pr_state" != "$PULSE_FEEDBACK_ROUTE_CLOSED_STATE" ]]; then
			_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "${kind} PR close was not verified (close_rc=${close_rc})"
			return $?
		fi
		if declare -F _pulse_merge_invalidate_pr_list_cache >/dev/null 2>&1; then
			_pulse_merge_invalidate_pr_list_cache "$repo_slug" "closed feedback-routed PR #${pr_number}"
		fi
		_feedback_route_finish_closed "$kind" "$pr_number" "$repo_slug" "$linked_issue" \
			"$expected_head" "$terminal_label" "$completion_marker" "$caller" "$closed_by_this_call"
		return $?
	fi
	if [[ "$pr_state" != "$PULSE_FEEDBACK_ROUTE_CLOSED_STATE" ]]; then
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"started ${kind} route expected OPEN or CLOSED at head ${expected_head}, observed ${pr_state:-unknown}"
		return $?
	fi
	_feedback_route_finish_closed "$kind" "$pr_number" "$repo_slug" "$linked_issue" \
		"$expected_head" "$terminal_label" "$completion_marker" "$caller" 0
	return $?
}

_feedback_route_existing_evidence_gate() {
	local kind="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local linked_issue="$4"
	local expected_head="$5"
	local source_label="$6"
	local terminal_label="$7"
	local evidence_fingerprint="$8"
	local start_marker="$9"
	local completion_marker="${10}"
	local issue_body="${11}"
	local pr_state="${12}"
	local labels="${13}"

	if printf '%s' "$issue_body" | grep -qF "$completion_marker"; then
		if ! printf '%s' "$issue_body" | grep -qF "$start_marker"; then
			_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
				"${kind} completion evidence has no matching start marker"
			return $?
		fi
		if [[ -n "$evidence_fingerprint" && "$pr_state" == "$PULSE_FEEDBACK_ROUTE_OPEN_STATE" ]]; then
			echo "[pulse-wrapper] feedback finalizer: review evidence ${evidence_fingerprint} for PR #${pr_number} was already routed at head ${expected_head}; leaving reopened PR unchanged" >>"$LOGFILE"
			return "$PULSE_FEEDBACK_ROUTE_HANDLED_RC"
		fi
		_feedback_route_resume_completed "$kind" "$pr_number" "$repo_slug" "$linked_issue" \
			"$expected_head" "$pr_state" "$source_label" "$terminal_label" "$labels" || return $?
		return "$PULSE_FEEDBACK_ROUTE_HANDLED_RC"
	fi
	if [[ -n "$evidence_fingerprint" ]]; then
		if _feedback_route_review_evidence_completed "$issue_body" "$pr_number" "$evidence_fingerprint"; then
			echo "[pulse-wrapper] feedback finalizer: review evidence ${evidence_fingerprint} for PR #${pr_number} was already routed on another head; skipping duplicate route" >>"$LOGFILE"
			return "$PULSE_FEEDBACK_ROUTE_HANDLED_RC"
		fi
		if ! _feedback_route_review_generations_complete "$issue_body" "$pr_number" "$start_marker"; then
			_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
				"existing review route generation is incomplete or ambiguous"
			return $?
		fi
	elif _feedback_route_body_has_other_head_evidence "$issue_body" "$kind" "$pr_number" \
		"$start_marker" "$completion_marker"; then
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"existing ${kind} route evidence belongs to a different PR head"
		return $?
	fi
	return 0
}

_finalize_feedback_route() {
	local kind="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local linked_issue="$4"
	local expected_head="$5"
	local source_label="$6"
	local terminal_label="$7"
	local legacy_marker="$8"
	local feedback_section="$9"
	local caller="${10}"
	local close_comment="${11}"
	local legacy_match="${12:-$legacy_marker}"
	local evidence_fingerprint="${13:-}"
	local start_marker=""
	local completion_marker=""
	local snapshot=""
	local pr_state=""
	local current_head=""
	local labels=""
	local issue_body=""
	local evidence_gate_rc=0

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "dry-run forbids ${kind} finalization writes"
		return $?
	fi
	[[ "$expected_head" =~ ^[0-9A-Za-z]{7,64}$ ]] || {
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "missing or malformed expected head for ${kind} route"
		return $?
	}
	if [[ -n "$evidence_fingerprint" ]] && \
		{ [[ "$kind" != "review" ]] || [[ ! "$evidence_fingerprint" =~ ^[0-9a-f]{64}$ ]]; }; then
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "malformed evidence identity for ${kind} route"
		return $?
	fi
	start_marker=$(_feedback_route_marker start "$kind" "$pr_number" "$expected_head" "$evidence_fingerprint")
	completion_marker=$(_feedback_route_marker complete "$kind" "$pr_number" "$expected_head" "$evidence_fingerprint")
	snapshot=$(_feedback_route_pr_snapshot "$pr_number" "$repo_slug") || {
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "current PR snapshot unavailable before ${kind} finalization"
		return $?
	}
	IFS=$'\t' read -r pr_state current_head labels <<<"$snapshot"
	if [[ "$current_head" != "$expected_head" ]]; then
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"${kind} route head drifted from ${expected_head} to ${current_head:-unknown}"
		return $?
	fi
	if _feedback_route_labels_block_routing "$labels"; then
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" \
			"current PR ownership labels prohibit ${kind} finalization"
		return $?
	fi
	issue_body=$(_feedback_route_issue_body "$linked_issue" "$repo_slug") || {
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "linked issue body unavailable before ${kind} finalization"
		return $?
	}
	_feedback_route_existing_evidence_gate "$kind" "$pr_number" "$repo_slug" "$linked_issue" \
		"$expected_head" "$source_label" "$terminal_label" "$evidence_fingerprint" \
		"$start_marker" "$completion_marker" "$issue_body" "$pr_state" "$labels" || evidence_gate_rc=$?
	[[ "$evidence_gate_rc" -eq 0 ]] || {
		[[ "$evidence_gate_rc" -eq "$PULSE_FEEDBACK_ROUTE_HANDLED_RC" ]] && return 0
		return "$evidence_gate_rc"
	}
	if [[ "$pr_state" != "$PULSE_FEEDBACK_ROUTE_OPEN_STATE" \
		&& "$pr_state" != "$PULSE_FEEDBACK_ROUTE_CLOSED_STATE" ]]; then
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"started ${kind} route expected OPEN or CLOSED at head ${expected_head}, observed ${pr_state:-unknown}"
		return $?
	fi
	_feedback_route_prepare_start "$kind" "$pr_number" "$repo_slug" "$linked_issue" \
		"$expected_head" "$pr_state" "$issue_body" "$start_marker" "$legacy_marker" \
		"$feedback_section" "$caller" "$legacy_match" || return $?
	if ! _feedback_route_transition_and_verify "$linked_issue" "$repo_slug" "$source_label"; then
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "${kind} issue transition was not fully verified"
		return $?
	fi
	snapshot=$(_feedback_route_pr_snapshot "$pr_number" "$repo_slug") || {
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "PR snapshot unavailable after ${kind} issue transition"
		return $?
	}
	IFS=$'\t' read -r pr_state current_head labels <<<"$snapshot"
	if [[ "$current_head" != "$expected_head" ]]; then
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"${kind} route head changed after issue transition (${expected_head} to ${current_head:-unknown})"
		return $?
	fi
	if _feedback_route_labels_block_routing "$labels"; then
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"PR ownership labels changed during ${kind} finalization"
		return $?
	fi
	_feedback_route_close_and_finish "$kind" "$pr_number" "$repo_slug" "$linked_issue" \
		"$expected_head" "$terminal_label" "$completion_marker" "$caller" \
		"$close_comment" "$pr_state" "$start_marker"
	return $?
}

_feedback_route_guard_existing_terminal_label() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local kind="$4"
	local snapshot=""
	local pr_state=""
	local current_head=""
	local labels=""
	local issue_body=""
	local start_marker=""
	local completion_marker=""
	local terminal_label=""
	local marker_prefix="<!-- feedback-route:start:${kind}:PR${pr_number}:SHA"

	snapshot=$(_feedback_route_pr_snapshot "$pr_number" "$repo_slug") || {
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "cannot inspect existing ${kind} terminal label"
		return $?
	}
	IFS=$'\t' read -r pr_state current_head labels <<<"$snapshot"
	terminal_label=$(_feedback_route_terminal_label_for_kind "$kind") || {
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "unknown feedback route kind ${kind}"
		return $?
	}
	if _feedback_route_labels_block_routing "$labels"; then
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" \
			"current PR ownership labels prohibit ${kind} route recovery"
		return $?
	fi
	if ! _feedback_route_labels_include "$labels" "$terminal_label"; then
		return 0
	fi
	issue_body=$(_feedback_route_issue_body "$linked_issue" "$repo_slug") || {
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "cannot inspect route evidence behind existing ${kind} terminal label"
		return $?
	}
	start_marker=$(_feedback_route_marker start "$kind" "$pr_number" "$current_head")
	completion_marker=$(_feedback_route_marker complete "$kind" "$pr_number" "$current_head")
	if [[ "$pr_state" == "$PULSE_FEEDBACK_ROUTE_OPEN_STATE" ]] && printf '%s' "$issue_body" | grep -qF "$completion_marker"; then
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"completed same-head ${kind} route was manually reopened"
		return $?
	fi
	if [[ "$pr_state" == "$PULSE_FEEDBACK_ROUTE_OPEN_STATE" ]] && printf '%s' "$issue_body" | grep -qF "$start_marker"; then
		return 0
	fi
	if printf '%s' "$issue_body" | grep -qF "$marker_prefix"; then
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"existing ${kind} route evidence belongs to a different PR head"
		return $?
	fi
	_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
		"legacy ${kind} terminal label has no unambiguous head-bound route evidence"
	return $?
}
