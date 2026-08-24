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
PULSE_FEEDBACK_ROUTE_AVAILABLE_LABEL="status:available"
PULSE_FEEDBACK_ROUTE_JSON_ARRAY_TYPE="array"

_PULSE_FEEDBACK_ROUTE_CONTEXT_KIND=""
_PULSE_FEEDBACK_ROUTE_CONTEXT_HEAD=""

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
	local ignore_hold="${2:-0}"

	if _feedback_route_labels_include "$labels" "no-takeover" \
		|| _feedback_route_labels_include "$labels" "external-contributor" \
		|| _feedback_route_labels_include "$labels" "$PULSE_FEEDBACK_ROUTE_NMR_LABEL"; then
		return 0
	fi
	if [[ "$ignore_hold" != "1" ]] \
		&& _feedback_route_labels_include "$labels" "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL"; then
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
		(if type == $array_type and ((.[0]? | type) == $array_type) then .[] else . end)[]?
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
	printf '%s' "$comments_json" | jq -c --arg array_type "$PULSE_FEEDBACK_ROUTE_JSON_ARRAY_TYPE" \
		--arg marker "$marker" "$filter" 2>/dev/null
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

_feedback_route_hold_reason_key() {
	local reason="$1"
	local reason_key=""
	reason_key=$(printf '%s' "$reason" | tr -cs '[:alnum:]_.:-' '-')
	reason_key="${reason_key#-}"
	reason_key="${reason_key%-}"
	[[ -n "$reason_key" ]] || reason_key="unknown"
	printf '%.120s' "$reason_key"
	return 0
}

_feedback_route_actor_is_valid() {
	local actor="$1"
	[[ "$actor" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ \
		|| "$actor" =~ ^[A-Za-z0-9-]+\[bot\]$ ]]
	return $?
}

_feedback_route_authenticated_actor() {
	local actor=""
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		actor=$(_gh_with_timeout read gh api user --jq '.login // ""' 2>/dev/null) || return 1
	else
		actor=$(gh api user --jq '.login // ""' 2>/dev/null) || return 1
	fi
	_feedback_route_actor_is_valid "$actor" || return 1
	printf '%s' "$actor"
	return 0
}

_feedback_route_automation_hold_marker() {
	local kind="$1"
	local pr_number="$2"
	local expected_head="$3"
	local reason="$4"
	local issue_event_id="$5"
	local pr_event_id="$6"
	local automation_actor="$7"
	local reason_key=""
	reason_key=$(_feedback_route_hold_reason_key "$reason")
	printf '<!-- feedback-route:automation-hold:%s:PR%s:SHA%s:REASON%s:ISSUEEVENT%s:PREVENT%s:ACTOR%s -->' \
		"$kind" "$pr_number" "$expected_head" "$reason_key" "$issue_event_id" "$pr_event_id" "$automation_actor"
	return 0
}

_feedback_route_latest_hold_event() {
	local target_number="$1"
	local repo_slug="$2"
	local endpoint="repos/${repo_slug}/issues/${target_number}/timeline?per_page=100"
	local timeline_json=""
	# shellcheck disable=SC2016 # $hold_label is a jq variable supplied below.
	local filter='[
		(if type == $array_type and ((.[0]? | type) == $array_type) then .[] else . end)[]?
		| select((.event // "") == "labeled" and (.label.name // "") == $hold_label)
		| select((.id // 0) > 0)
		| {id, created_at, actor: (.actor.login // "")}
	] | sort_by([.created_at, .id]) | last
	| if . == null then empty else [(.id | tostring), .actor] | @tsv end'

	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		timeline_json=$(_gh_with_timeout read gh api "$endpoint" --paginate --slurp 2>/dev/null) || return 1
	else
		timeline_json=$(gh api "$endpoint" --paginate --slurp 2>/dev/null) || return 1
	fi
	printf '%s' "$timeline_json" | jq -r --arg array_type "$PULSE_FEEDBACK_ROUTE_JSON_ARRAY_TYPE" \
		--arg hold_label "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL" "$filter" 2>/dev/null
	return 0
}

_feedback_route_automation_hold_comments() {
	local linked_issue="$1"
	local repo_slug="$2"
	local marker_prefix="$3"
	local marker_suffix="${4:-}"
	local automation_actor="${5:-}"
	local endpoint="repos/${repo_slug}/issues/${linked_issue}/comments?per_page=100"
	local comments_json=""
	# #aidevops:trust-boundary — copied hold markers from untrusted comments do
	# not authorize automated removal of a maintainer-created hold.
	# shellcheck disable=SC2016 # $marker_prefix is a jq variable supplied below.
	local filter='[
		(if type == $array_type and ((.[0]? | type) == $array_type) then .[] else . end)[]?
		| select((.author_association // "") as $association
			| ["OWNER", "MEMBER", "COLLABORATOR"] | index($association))
		| select((.user.login // "") == $automation_actor)
		| select((.body // "") | contains($marker_prefix) and contains($marker_suffix))
		| {id, created_at}
	] | sort_by([.created_at, .id])'

	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		comments_json=$(_gh_with_timeout read gh api "$endpoint" --paginate --slurp 2>/dev/null) || return 1
	else
		comments_json=$(gh api "$endpoint" --paginate --slurp 2>/dev/null) || return 1
	fi
	printf '%s' "$comments_json" | jq -c --arg array_type "$PULSE_FEEDBACK_ROUTE_JSON_ARRAY_TYPE" \
		--arg marker_prefix "$marker_prefix" \
		--arg marker_suffix "$marker_suffix" --arg automation_actor "$automation_actor" "$filter" 2>/dev/null
	return $?
}

_feedback_route_automation_hold_exists() {
	local kind="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local linked_issue="$4"
	local expected_head="$5"
	local marker_prefix="<!-- feedback-route:automation-hold:${kind}:PR${pr_number}:SHA${expected_head}:REASON"
	local issue_event="" pr_event="" issue_event_id="" pr_event_id=""
	local issue_actor="" pr_actor="" authenticated_actor="" marker_suffix="" comments_json=""
	issue_event=$(_feedback_route_latest_hold_event "$linked_issue" "$repo_slug") || return 1
	pr_event=$(_feedback_route_latest_hold_event "$pr_number" "$repo_slug") || return 1
	IFS=$'\t' read -r issue_event_id issue_actor <<<"$issue_event"
	IFS=$'\t' read -r pr_event_id pr_actor <<<"$pr_event"
	[[ "$issue_event_id" =~ ^[0-9]+$ && "$pr_event_id" =~ ^[0-9]+$ ]] || return 1
	_feedback_route_actor_is_valid "$issue_actor" || return 1
	[[ "$issue_actor" == "$pr_actor" ]] || return 1
	authenticated_actor=$(_feedback_route_authenticated_actor) || return 1
	[[ "$issue_actor" == "$authenticated_actor" ]] || return 1
	marker_suffix=":ISSUEEVENT${issue_event_id}:PREVENT${pr_event_id}:ACTOR${issue_actor} -->"
	comments_json=$(_feedback_route_automation_hold_comments "$linked_issue" "$repo_slug" \
		"$marker_prefix" "$marker_suffix" "$issue_actor") || return 1
	printf '%s' "$comments_json" | jq -e 'length > 0' >/dev/null 2>&1
	return $?
}

_feedback_route_record_automation_hold() {
	local kind="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local linked_issue="$4"
	local expected_head="$5"
	local reason="$6"
	local issue_event_id="$7"
	local pr_event_id="$8"
	local automation_actor="$9"
	local marker="" safe_reason="" comment_body=""

	[[ "$issue_event_id" =~ ^[0-9]+$ && "$pr_event_id" =~ ^[0-9]+$ ]] || return 1
	_feedback_route_actor_is_valid "$automation_actor" || return 1
	marker=$(_feedback_route_automation_hold_marker "$kind" "$pr_number" "$expected_head" "$reason" \
		"$issue_event_id" "$pr_event_id" "$automation_actor")
	if _feedback_route_automation_hold_comments "$linked_issue" "$repo_slug" "$marker" \
		"" "$automation_actor" \
		| jq -e 'length > 0' >/dev/null 2>&1; then
		return 0
	fi
	safe_reason="${reason//$'\r'/ }"
	safe_reason="${safe_reason//$'\n'/ }"
	safe_reason="${safe_reason:0:500}"
	comment_body="AUTOMATION_HOLD_PROVENANCE route=${kind} pr=${pr_number} head=${expected_head} actor=${automation_actor}
reason=${safe_reason}
${marker}"
	_feedback_route_gh_write issue comment "$linked_issue" --repo "$repo_slug" \
		--body "$comment_body" >/dev/null 2>&1
	return $?
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
	_feedback_route_labels_include "$labels" "$PULSE_FEEDBACK_ROUTE_AVAILABLE_LABEL" || return 1
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
	local kind="${5:-${_PULSE_FEEDBACK_ROUTE_CONTEXT_KIND:-unknown}}"
	local expected_head="${6:-${_PULSE_FEEDBACK_ROUTE_CONTEXT_HEAD:-unknown}}"
	local issue_hold_rc=0
	local pr_hold_rc=0
	local provenance_rc=0
	local issue_snapshot="" issue_labels="" issue_assignees=""
	local pr_snapshot="" pr_state="" pr_head="" pr_labels=""
	local issue_hold_preexisting=1 pr_hold_preexisting=1
	local issue_event="" pr_event="" issue_event_id="" pr_event_id=""
	local issue_actor="" pr_actor="" authenticated_actor=""

	issue_snapshot=$(_feedback_route_issue_snapshot "$linked_issue" "$repo_slug" 2>/dev/null) || issue_snapshot=""
	if [[ -n "$issue_snapshot" ]]; then
		IFS=$'\t' read -r issue_labels issue_assignees <<<"$issue_snapshot"
		if ! _feedback_route_labels_include "$issue_labels" "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL"; then
			issue_hold_preexisting=0
		fi
	fi
	pr_snapshot=$(_feedback_route_pr_snapshot "$pr_number" "$repo_slug" 2>/dev/null) || pr_snapshot=""
	if [[ -n "$pr_snapshot" ]]; then
		IFS=$'\t' read -r pr_state pr_head pr_labels <<<"$pr_snapshot"
		if ! _feedback_route_labels_include "$pr_labels" "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL"; then
			pr_hold_preexisting=0
		fi
	fi
	: "$issue_assignees" "$pr_state" "$pr_head"

	if declare -F set_issue_status >/dev/null 2>&1; then
		set_issue_status "$linked_issue" "$repo_slug" "in-review" \
			--add-label "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL" >/dev/null 2>&1 || issue_hold_rc=$?
	else
		_feedback_route_gh_write issue edit "$linked_issue" --repo "$repo_slug" \
			--add-label "status:in-review" --add-label "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL" \
			--remove-label "$PULSE_FEEDBACK_ROUTE_AVAILABLE_LABEL" >/dev/null 2>&1 || issue_hold_rc=$?
	fi
	_feedback_route_gh_write pr edit "$pr_number" --repo "$repo_slug" \
		--add-label "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL" >/dev/null 2>&1 || pr_hold_rc=$?
	if [[ "$issue_hold_rc" -eq 0 && "$pr_hold_rc" -eq 0 \
		&& "$issue_hold_preexisting" -eq 0 && "$pr_hold_preexisting" -eq 0 ]]; then
		authenticated_actor=$(_feedback_route_authenticated_actor 2>/dev/null) || authenticated_actor=""
		issue_event=$(_feedback_route_latest_hold_event "$linked_issue" "$repo_slug" 2>/dev/null) || issue_event=""
		pr_event=$(_feedback_route_latest_hold_event "$pr_number" "$repo_slug" 2>/dev/null) || pr_event=""
		IFS=$'\t' read -r issue_event_id issue_actor <<<"$issue_event"
		IFS=$'\t' read -r pr_event_id pr_actor <<<"$pr_event"
		if [[ "$issue_event_id" =~ ^[0-9]+$ && "$pr_event_id" =~ ^[0-9]+$ \
			&& -n "$authenticated_actor" && "$issue_actor" == "$pr_actor" \
			&& "$issue_actor" == "$authenticated_actor" ]]; then
			_feedback_route_record_automation_hold "$kind" "$pr_number" "$repo_slug" \
				"$linked_issue" "$expected_head" "$reason" "$issue_event_id" "$pr_event_id" \
				"$issue_actor" || provenance_rc=$?
		else
			provenance_rc=1
		fi
	fi
	echo "[pulse-wrapper] feedback finalizer: preserving PR #${pr_number} and issue #${linked_issue} in ${repo_slug} for maintainer review — ${reason} (kind=${kind}, head=${expected_head}, provenance_rc=${provenance_rc}, issue_hold_rc=${issue_hold_rc}, pr_hold_rc=${pr_hold_rc})" >>"$LOGFILE"
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

_feedback_route_restore_unverified_hold() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local reason="$4"
	local issue_rc=0 pr_rc=0

	if declare -F set_issue_status >/dev/null 2>&1; then
		set_issue_status "$linked_issue" "$repo_slug" "in-review" \
			--add-label "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL" >/dev/null 2>&1 || issue_rc=$?
	else
		_feedback_route_gh_write issue edit "$linked_issue" --repo "$repo_slug" \
			--add-label "status:in-review" --add-label "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL" \
			--remove-label "$PULSE_FEEDBACK_ROUTE_AVAILABLE_LABEL" >/dev/null 2>&1 || issue_rc=$?
	fi
	_feedback_route_gh_write pr edit "$pr_number" --repo "$repo_slug" \
		--add-label "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL" >/dev/null 2>&1 || pr_rc=$?
	echo "[pulse-wrapper] feedback finalizer: restored unverified hold for PR #${pr_number} and issue #${linked_issue} in ${repo_slug} — ${reason} (issue_rc=${issue_rc}, pr_rc=${pr_rc})" >>"$LOGFILE"
	[[ "$issue_rc" -eq 0 && "$pr_rc" -eq 0 ]]
	return $?
}

_feedback_route_transition_and_verify() {
	local linked_issue="$1"
	local repo_slug="$2"
	local source_label="$3"
	local clear_hold="${4:-0}"
	local pr_number="${5:-}"
	local kind="${6:-}"
	local expected_head="${7:-}"
	local companion_source_label="${8:-}"

	if [[ "$clear_hold" == "1" ]]; then
		[[ "$pr_number" =~ ^[0-9]+$ && -n "$kind" && -n "$expected_head" ]] || return 1
		if ! _feedback_route_automation_hold_exists "$kind" "$pr_number" "$repo_slug" \
			"$linked_issue" "$expected_head"; then
			_feedback_route_restore_unverified_hold "$pr_number" "$repo_slug" "$linked_issue" \
				"automation hold generation changed before issue transition" || true
			return 1
		fi
	fi
	if ! _transition_issue_for_redispatch "$linked_issue" "$repo_slug" "$source_label" "$clear_hold" \
		"$companion_source_label"; then
		if [[ "$clear_hold" == "1" ]]; then
			_feedback_route_restore_unverified_hold "$pr_number" "$repo_slug" "$linked_issue" \
				"issue transition failed while clearing an automation hold" || true
		fi
		return 1
	fi
	if [[ "$clear_hold" == "1" ]] \
		&& ! _feedback_route_automation_hold_exists "$kind" "$pr_number" "$repo_slug" \
			"$linked_issue" "$expected_head"; then
		_feedback_route_restore_unverified_hold "$pr_number" "$repo_slug" "$linked_issue" \
			"automation hold generation changed while clearing it" || true
		return 1
	fi
	if ! _feedback_route_issue_is_ready "$linked_issue" "$repo_slug" "$source_label"; then
		if [[ "$clear_hold" == "1" ]]; then
			_feedback_route_restore_unverified_hold "$pr_number" "$repo_slug" "$linked_issue" \
				"issue readiness changed while clearing an automation hold" || true
		fi
		return 1
	fi
	return 0
}

_feedback_route_apply_terminal_label() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head="$3"
	local terminal_label="$4"
	local linked_issue="$5"
	local kind="$6"
	local snapshot=""
	local pr_state=""
	local current_head=""
	local labels=""

	_feedback_route_gh_write pr edit "$pr_number" --repo "$repo_slug" --add-label "$terminal_label" >/dev/null 2>&1 || return 1
	snapshot=$(_feedback_route_pr_snapshot "$pr_number" "$repo_slug") || return 1
	IFS=$'\t' read -r pr_state current_head labels <<<"$snapshot"
	[[ "$pr_state" == "$PULSE_FEEDBACK_ROUTE_CLOSED_STATE" && "$current_head" == "$expected_head" ]] || return 1
	_feedback_route_labels_include "$labels" "$terminal_label" || return 1
	if _feedback_route_automation_hold_exists "$kind" "$pr_number" "$repo_slug" "$linked_issue" "$expected_head"; then
		_feedback_route_recover_automation_pr_hold "$pr_number" "$repo_slug" "$linked_issue" \
			"$expected_head" "$kind" || return 1
	fi
	return 0
}

_feedback_route_recover_automation_pr_hold() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local expected_head="$4"
	local kind="$5"
	local snapshot="" pr_state="" current_head="" labels=""

	_feedback_route_automation_hold_exists "$kind" "$pr_number" "$repo_slug" \
		"$linked_issue" "$expected_head" || return 1
	_feedback_route_gh_write pr edit "$pr_number" --repo "$repo_slug" \
		--remove-label "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL" >/dev/null 2>&1 || return 1
	if ! snapshot=$(_feedback_route_pr_snapshot "$pr_number" "$repo_slug"); then
		_feedback_route_restore_unverified_hold "$pr_number" "$repo_slug" "$linked_issue" \
			"PR snapshot unavailable after automation hold removal" || true
		return 1
	fi
	IFS=$'\t' read -r pr_state current_head labels <<<"$snapshot"
	: "$pr_state"
	if [[ "$current_head" != "$expected_head" ]] \
		|| _feedback_route_labels_include "$labels" "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL"; then
		_feedback_route_restore_unverified_hold "$pr_number" "$repo_slug" "$linked_issue" \
			"automation PR hold removal could not be verified" || true
		return 1
	fi
	if ! _feedback_route_automation_hold_exists "$kind" "$pr_number" "$repo_slug" \
		"$linked_issue" "$expected_head"; then
		_feedback_route_restore_unverified_hold "$pr_number" "$repo_slug" "$linked_issue" \
			"automation PR hold generation changed during removal" || true
		return 1
	fi
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

	if ! _feedback_route_apply_terminal_label "$pr_number" "$repo_slug" "$expected_head" "$terminal_label" \
		"$linked_issue" "$kind"; then
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
	local issue_snapshot="" issue_labels="" issue_assignees="" clear_automation_hold=0

	issue_snapshot=$(_feedback_route_issue_snapshot "$linked_issue" "$repo_slug") || {
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" \
			"completed ${kind} route could not inspect linked issue hold provenance"
		return $?
	}
	IFS=$'\t' read -r issue_labels issue_assignees <<<"$issue_snapshot"
	if _feedback_route_labels_include "$issue_labels" "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL"; then
		if _feedback_route_automation_hold_exists "$kind" "$pr_number" "$repo_slug" "$linked_issue" "$expected_head"; then
			clear_automation_hold=1
		else
			_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" \
				"completed ${kind} route found hold-for-review without exact automation provenance; preserving maintainer hold"
			return $?
		fi
	fi
	: "$issue_assignees"

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
		if ! _feedback_route_transition_and_verify "$linked_issue" "$repo_slug" "$source_label" \
			"$clear_automation_hold" "$pr_number" "$kind" "$expected_head"; then
			_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "completed ${kind} route could not restore redispatch issue state"
			return $?
		fi
		_feedback_route_release_dispatch_claim "$kind" "$pr_number" "$repo_slug" \
			"$linked_issue" "$expected_head" || return "$PULSE_FEEDBACK_ROUTE_DEFERRED_RC"
		return 0
	fi
	if ! _feedback_route_transition_and_verify "$linked_issue" "$repo_slug" "$source_label" \
		"$clear_automation_hold" "$pr_number" "$kind" "$expected_head"; then
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "completed ${kind} route could not re-verify redispatch issue state"
		return $?
	fi
	if ! _feedback_route_release_dispatch_claim "$kind" "$pr_number" "$repo_slug" \
		"$linked_issue" "$expected_head"; then
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" \
			"completed ${kind} route could not retire the prior dispatch claim"
		return $?
	fi
	if ! _feedback_route_apply_terminal_label "$pr_number" "$repo_slug" "$expected_head" "$terminal_label" \
		"$linked_issue" "$kind"; then
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

_feedback_route_prepare_finalization_snapshot() {
	local kind="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local linked_issue="$4"
	local expected_head="$5"
	local snapshot=""
	local pr_state=""
	local current_head=""
	local labels=""
	local clear_automation_hold=0

	snapshot=$(_feedback_route_pr_snapshot "$pr_number" "$repo_slug") || {
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" \
			"current PR snapshot unavailable before ${kind} finalization"
		return $?
	}
	IFS=$'\t' read -r pr_state current_head labels <<<"$snapshot"
	if [[ "$current_head" != "$expected_head" ]]; then
		_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
			"${kind} route head drifted from ${expected_head} to ${current_head:-unknown}"
		return $?
	fi
	if _feedback_route_labels_block_routing "$labels" 1; then
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" \
			"current PR ownership labels prohibit ${kind} finalization"
		return $?
	fi
	if _feedback_route_labels_include "$labels" "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL"; then
		if ! _feedback_route_recover_automation_pr_hold "$pr_number" "$repo_slug" "$linked_issue" \
			"$expected_head" "$kind"; then
			_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" \
				"current ${kind} hold has no exact automation generation provenance; preserving maintainer hold"
			return $?
		fi
		clear_automation_hold=1
		snapshot=$(_feedback_route_pr_snapshot "$pr_number" "$repo_slug") || {
			_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" \
				"PR snapshot unavailable after exact automation hold recovery"
			return $?
		}
		IFS=$'\t' read -r pr_state current_head labels <<<"$snapshot"
		if [[ "$current_head" != "$expected_head" ]]; then
			_feedback_route_hold_for_maintainer "$pr_number" "$repo_slug" "$linked_issue" \
				"${kind} route head changed during automation hold recovery"
			return $?
		fi
	fi
	if _feedback_route_labels_block_routing "$labels"; then
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" \
			"current PR ownership labels prohibit ${kind} finalization"
		return $?
	fi
	printf '%s\t%s\t%s\t%s' "$pr_state" "$current_head" "$labels" "$clear_automation_hold"
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
	local companion_source_label="${14:-}"
	local start_marker=""
	local completion_marker=""
	local snapshot=""
	local pr_state=""
	local current_head=""
	local labels=""
	local issue_body=""
	local evidence_gate_rc=0
	local clear_automation_hold=0
	local preflight="" preflight_rc=0

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
	_PULSE_FEEDBACK_ROUTE_CONTEXT_KIND="$kind"
	_PULSE_FEEDBACK_ROUTE_CONTEXT_HEAD="$expected_head"
	preflight=$(_feedback_route_prepare_finalization_snapshot "$kind" "$pr_number" "$repo_slug" \
		"$linked_issue" "$expected_head") || preflight_rc=$?
	[[ "$preflight_rc" -eq 0 ]] || return "$preflight_rc"
	IFS=$'\t' read -r pr_state current_head labels clear_automation_hold <<<"$preflight"
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
	if ! _feedback_route_transition_and_verify "$linked_issue" "$repo_slug" "$source_label" \
		"$clear_automation_hold" "$pr_number" "$kind" "$expected_head" "$companion_source_label"; then
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
	_PULSE_FEEDBACK_ROUTE_CONTEXT_KIND="$kind"
	_PULSE_FEEDBACK_ROUTE_CONTEXT_HEAD="$current_head"
	terminal_label=$(_feedback_route_terminal_label_for_kind "$kind") || {
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "unknown feedback route kind ${kind}"
		return $?
	}
	if _feedback_route_labels_block_routing "$labels" 1; then
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" \
			"current PR ownership labels prohibit ${kind} route recovery"
		return $?
	fi
	if _feedback_route_labels_include "$labels" "$PULSE_FEEDBACK_ROUTE_HOLD_LABEL"; then
		if ! _feedback_route_recover_automation_pr_hold "$pr_number" "$repo_slug" "$linked_issue" \
			"$current_head" "$kind"; then
			_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" \
				"current ${kind} hold has no exact automation generation provenance; preserving maintainer hold"
			return $?
		fi
		snapshot=$(_feedback_route_pr_snapshot "$pr_number" "$repo_slug") || return "$PULSE_FEEDBACK_ROUTE_DEFERRED_RC"
		IFS=$'\t' read -r pr_state current_head labels <<<"$snapshot"
	fi
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
