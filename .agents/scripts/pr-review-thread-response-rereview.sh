#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Trusted, head-bound re-review finalization for PR review-thread remediation.

_prrts_rereview_state_file() {
	local repo_slug="$1"
	local pr_number="$2"
	local safe_slug=""
	safe_slug="$(_prrts_safe_slug "$repo_slug")"
	printf '%s/%s-%s.rereview\n' "$STATE_DIR" "$safe_slug" "$pr_number"
	return 0
}

_prrts_rereview_dispatch_head() {
	local state_file="$1"
	local key="" value=""
	[[ -f "$state_file" ]] || return 1
	while IFS='=' read -r key value; do
		if [[ "$key" == "last_head_sha" && "$value" =~ ^[0-9a-fA-F]{40}$ ]]; then
			printf '%s\n' "$value"
			return 0
		fi
	done <"$state_file"
	return 1
}

_prrts_rereview_read_state() {
	local state_file="$1"
	local head_var="$2"
	local reviewers_var="$3"
	local key="" value="" stored_head="" stored_reviewers=""
	if [[ -f "$state_file" ]]; then
		while IFS='=' read -r key value; do
			case "$key" in
			head_sha) stored_head="$value" ;;
			reviewers) stored_reviewers="$value" ;;
			esac
		done <"$state_file"
	fi
	[[ "$stored_head" =~ ^[0-9a-fA-F]{40}$ ]] || stored_head=""
	printf -v "$head_var" '%s' "$stored_head"
	printf -v "$reviewers_var" '%s' "$stored_reviewers"
	return 0
}

_prrts_rereview_write_state() {
	local state_file="$1"
	local head_sha="$2"
	local reviewers="$3"
	local tmp_file="${state_file}.tmp.$$"
	[[ "$state_file" == "${STATE_DIR}/"*.rereview && ! -L "$state_file" ]] || return 1
	[[ "$head_sha" =~ ^[0-9a-fA-F]{40}$ && -n "$reviewers" ]] || return 1
	if ! {
		printf 'head_sha=%s\n' "$head_sha"
		printf 'reviewers=%s\n' "$reviewers"
	} >"$tmp_file"; then
		rm -f "$tmp_file"
		return 1
	fi
	if ! mv -f "$tmp_file" "$state_file"; then
		rm -f "$tmp_file"
		return 1
	fi
	chmod 600 "$state_file" 2>/dev/null || true
	return 0
}

_prrts_rereview_pull_snapshot() {
	local repo_slug="$1"
	local pr_number="$2"
	local response=""
	response=$(AIDEVOPS_GH_QUOTA_COST_ON_SUCCESS=1 \
		AIDEVOPS_GH_ROUTE_DECISION="review-thread-rereview-pr-rest" \
		_prrts_gh_call read gh api "repos/${repo_slug}/pulls/${pr_number}" 2>/dev/null) || return 1
	printf '%s' "$response" | jq -er '
		select(type == "object")
		| select((.state // "") != "" and (.draft | type) == "boolean")
		| [(.state // ""), (.draft | tostring), (.head.sha // "")] | @tsv
	' 2>/dev/null
	return $?
}

_prrts_rereview_trusted_reviewers() {
	local repo_slug="$1"
	local pr_number="$2"
	local reviewed_head="$3"
	local response=""
	response=$(_prrts_gh_call read gh api "repos/${repo_slug}/pulls/${pr_number}/reviews?per_page=100" \
		--paginate --slurp 2>/dev/null) || return 1
	printf '%s' "$response" | jq -er --arg reviewed_head "$reviewed_head" '
		select(type == "array" and all(.[]; type == "array"))
		| [
			.[][]?
			| select((.user.type // "") == "User")
			| select((.user.login // "") | test("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$"))
		]
		| group_by(.user.login)
		| map(sort_by((.submitted_at // ""), (.id // 0)) | last)
		| map(select(
			(.state // "") == "CHANGES_REQUESTED"
			and (.commit_id // "") == $reviewed_head
			and ((.author_association // "") == "OWNER"
				or (.author_association // "") == "MEMBER"
				or (.author_association // "") == "COLLABORATOR")
		))
		| map(.user.login) | unique | join(",")
	' 2>/dev/null
	return $?
}

_prrts_rereview_pending_reviewers() {
	local reviewers="$1"
	local recorded_reviewers="$2"
	local output_var="$3"
	local remaining="$reviewers" reviewer="" pending_list=""
	while [[ -n "$remaining" ]]; do
		case "$remaining" in
		*,*) reviewer="${remaining%%,*}"; remaining="${remaining#*,}" ;;
		*) reviewer="$remaining"; remaining="" ;;
		esac
		[[ "$reviewer" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]] || return 1
		case ",${recorded_reviewers}," in
		*",${reviewer},"*) ;;
		*) pending_list="${pending_list:+${pending_list},}${reviewer}" ;;
		esac
	done
	printf -v "$output_var" '%s' "$pending_list"
	return 0
}

_prrts_rereview_union() {
	local existing="$1"
	local added="$2"
	local output_var="$3"
	local combined="$existing" pending=""
	_prrts_rereview_pending_reviewers "$added" "$existing" pending || return 1
	[[ -n "$pending" ]] && combined="${combined:+${combined},}${pending}"
	printf -v "$output_var" '%s' "$combined"
	return 0
}

_prrts_rereview_threads_converged() {
	local repo_slug="$1"
	local pr_number="$2"
	local summary="" thread_count="" unused=""
	summary=$(PR_REVIEW_THREAD_RESPONSE_INCLUDE_HUMAN=true \
		_prrts_review_thread_summary "$repo_slug" "$pr_number") || return 1
	IFS="$PRRTS_TSV_FIELD_SEPARATOR" read -r thread_count unused \
		<<<"${summary//$'\t'/$PRRTS_TSV_FIELD_SEPARATOR}"
	[[ "$thread_count" =~ ^[0-9]+$ ]] || return 1
	[[ "$thread_count" -eq 0 ]] || return 2
	return 0
}

_prrts_finalize_rereview_request() {
	local repo_slug="$1"
	local pr_number="$2"
	local dispatch_state="" rereview_state="" prior_head="" snapshot=""
	local pr_state="" is_draft="" current_head="" reviewers=""
	local recorded_head="" recorded_reviewers="" pending_reviewers="" stored_reviewers=""
	local threads_rc=0
	dispatch_state="$(_prrts_state_file "$repo_slug" "$pr_number")"
	prior_head="$(_prrts_rereview_dispatch_head "$dispatch_state" 2>/dev/null || true)"
	if [[ ! "$prior_head" =~ ^[0-9a-fA-F]{40}$ ]]; then
		_prrts_log "rereview: ${repo_slug}#${pr_number} skipped — dispatch head unavailable"
		return 0
	fi
	snapshot="$(_prrts_rereview_pull_snapshot "$repo_slug" "$pr_number")" || return 1
	IFS="$PRRTS_TSV_FIELD_SEPARATOR" read -r pr_state is_draft current_head \
		<<<"${snapshot//$'\t'/$PRRTS_TSV_FIELD_SEPARATOR}"
	if [[ "$pr_state" != "open" || "$is_draft" != "$PRRTS_BOOL_FALSE" || ! "$current_head" =~ ^[0-9a-fA-F]{40}$ ]]; then
		_prrts_log "rereview: ${repo_slug}#${pr_number} skipped — PR is not an open ready head"
		return 0
	fi
	if [[ "$current_head" == "$prior_head" ]]; then
		_prrts_log "rereview: ${repo_slug}#${pr_number} skipped — remediation produced no changed head"
		return 0
	fi
	_prrts_rereview_threads_converged "$repo_slug" "$pr_number" || threads_rc=$?
	if [[ "$threads_rc" -eq 2 ]]; then
		_prrts_log "rereview: ${repo_slug}#${pr_number} deferred — unresolved review threads remain"
		return 0
	fi
	[[ "$threads_rc" -eq 0 ]] || return 1
	reviewers="$(_prrts_rereview_trusted_reviewers "$repo_slug" "$pr_number" "$prior_head")" || return 1
	if [[ -z "$reviewers" ]]; then
		_prrts_log "rereview: ${repo_slug}#${pr_number} skipped — no trusted head-bound change-request reviewer"
		return 0
	fi
	rereview_state="$(_prrts_rereview_state_file "$repo_slug" "$pr_number")"
	_prrts_rereview_read_state "$rereview_state" recorded_head recorded_reviewers
	[[ "$recorded_head" == "$current_head" ]] || recorded_reviewers=""
	_prrts_rereview_pending_reviewers "$reviewers" "$recorded_reviewers" pending_reviewers || return 1
	if [[ -z "$pending_reviewers" ]]; then
		_prrts_log "rereview: ${repo_slug}#${pr_number} already requested for head ${current_head}"
		return 0
	fi
	if ! _prrts_gh_call write gh pr edit "$pr_number" --repo "$repo_slug" \
		--add-reviewer "$pending_reviewers" >/dev/null 2>&1; then
		_prrts_log "rereview: ${repo_slug}#${pr_number} request failed for head ${current_head}"
		return 1
	fi
	_prrts_rereview_union "$recorded_reviewers" "$pending_reviewers" stored_reviewers || return 1
	_prrts_rereview_write_state "$rereview_state" "$current_head" "$stored_reviewers" || return 1
	_prrts_log "rereview: ${repo_slug}#${pr_number} requested trusted reviewer(s) for changed head ${current_head}"
	return 0
}
