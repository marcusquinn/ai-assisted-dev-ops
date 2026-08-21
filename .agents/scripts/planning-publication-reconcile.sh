#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Reconcile issue-first planning only after its exact default-branch snapshot lands.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./issue-sync-lib.sh
source "${SCRIPT_DIR}/issue-sync-lib.sh"
# shellcheck source=./shared-gh-wrappers.sh
source "${SCRIPT_DIR}/shared-gh-wrappers.sh"

PUBLICATION_PENDING_LABEL="publication:pending"
PUBLICATION_AVAILABLE_LABEL="status:available"
PUBLICATION_BLOCKED_LABEL="status:blocked"
PUBLICATION_AUTO_LABEL="auto-dispatch"
PUBLICATION_LIMIT="${AIDEVOPS_PUBLICATION_RECONCILE_LIMIT:-100}"

_publication_usage() {
	printf 'Usage: planning-publication-reconcile.sh reconcile --repo owner/repo --sha SHA [--task tNNN]\n'
}

_publication_exact_default_snapshot() {
	local expected_sha="$1"
	local default_branch="$2"
	local head_sha="" remote_sha=""
	[[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
	head_sha=$(git rev-parse HEAD 2>/dev/null) || return 1
	[[ "$head_sha" == "$expected_sha" ]] || return 1
	remote_sha=$(git rev-parse "refs/remotes/origin/${default_branch}" 2>/dev/null) || return 1
	[[ "$remote_sha" == "$expected_sha" ]]
}

_publication_task_line() {
	local task_id="$1"
	local task_re="${task_id//./\\.}"
	local matches=""
	matches=$(grep -E "^[[:space:]]*-[[:space:]]+\[[ x]\][[:space:]]+${task_re}[[:space:]]" TODO.md || true)
	[[ "$(printf '%s\n' "$matches" | grep -c . || true)" -eq 1 ]] || return 1
	printf '%s\n' "$matches"
}

_publication_desired_labels() {
	local task_line="$1"
	local parsed="" tags="" labels=""
	parsed=$(parse_task_line "$task_line") || return 1
	tags=$(printf '%s\n' "$parsed" | grep '^tags=' | cut -d= -f2-)
	labels=$(map_tags_to_labels "$tags")
	{
		printf '%s\n' "$labels" | tr ',' '\n' |
		grep -v -E "^(${PUBLICATION_PENDING_LABEL}|${PUBLICATION_AVAILABLE_LABEL})$" |
		grep -v '^$' | LC_ALL=C sort -u | paste -sd, -
	} || true
	return 0
}

_publication_task_has_dependency() {
	local task_line="$1"
	local parsed="" blocked_by=""
	parsed=$(parse_task_line "$task_line") || return 1
	blocked_by=$(printf '%s\n' "$parsed" | grep '^blocked_by=' | cut -d= -f2-)
	[[ -n "$blocked_by" ]] || return 1
	return 0
}

_publication_issue_has_active_status() {
	local issue_json="$1"
	jq -e 'any(.labels[]?.name;
		. == "status:queued" or
		. == "status:claimed" or
		. == "status:in-progress" or
		. == "status:in-review" or
		. == "status:done")' <<<"$issue_json" >/dev/null || return 1
	return 0
}

_publication_issue_has_inactive_status() {
	local issue_json="$1"
	_publication_issue_has_labels "$issue_json" "$PUBLICATION_AVAILABLE_LABEL" && return 0
	_publication_issue_has_labels "$issue_json" "$PUBLICATION_BLOCKED_LABEL" && return 0
	return 1
}

_publication_remove_inactive_statuses() {
	local repo="$1"
	local issue_num="$2"
	gh_issue_edit_safe "$issue_num" --repo "$repo" \
		--remove-label "${PUBLICATION_AVAILABLE_LABEL},${PUBLICATION_BLOCKED_LABEL}" >/dev/null || return 1
	return 0
}

_publication_status_label() {
	local desired_labels="$1"
	local has_dependency="$2"
	local issue_json="$3"
	local fenced=",${desired_labels},"
	if [[ "$has_dependency" -eq 1 ]]; then
		if ! _publication_issue_has_active_status "$issue_json"; then
			printf '%s\n' "$PUBLICATION_BLOCKED_LABEL"
		fi
		return 0
	fi
	_publication_issue_has_active_status "$issue_json" && return 0
	if [[ "$fenced" == *",${PUBLICATION_AUTO_LABEL},"* &&
		"$fenced" != *",parent-task,"* && "$fenced" != *",meta,"* &&
		"$fenced" != *",${PUBLICATION_BLOCKED_LABEL},"* && "$fenced" != *",status:queued,"* &&
		"$fenced" != *",status:claimed,"* && "$fenced" != *",status:in-progress,"* &&
		"$fenced" != *",status:in-review,"* && "$fenced" != *",status:done,"* &&
		"$fenced" != *",no-auto-dispatch,"* && "$fenced" != *",hold-for-review,"* ]]; then
		printf '%s\n' "$PUBLICATION_AVAILABLE_LABEL"
	fi
	return 0
}

_publication_issue_has_labels() {
	local issue_json="$1"
	local labels_csv="$2"
	local label=""
	while IFS= read -r label; do
		[[ -n "$label" ]] || continue
		jq -e --arg label "$label" 'any(.labels[]?; .name == $label)' \
			<<<"$issue_json" >/dev/null || return 1
	done < <(printf '%s\n' "$labels_csv" | tr ',' '\n')
	return 0
}

_publication_validate_mapping() {
	local task_id="$1" issue_num="$2"
	local task_line="" brief_path="todo/tasks/${task_id}-brief.md"
	task_line=$(_publication_task_line "$task_id") || return 1
	[[ "$task_line" =~ (^|[[:space:]])ref:GH#${issue_num}($|[[:space:]]) ]] || return 1
	[[ -f "$brief_path" && ! -L "$brief_path" ]] || return 1
	"${SCRIPT_DIR}/verify-brief-helper.sh" check-readiness "$brief_path" >/dev/null 2>&1 || return 1
	printf '%s\n' "$task_line"
}

_publication_reconcile_one() {
	local repo="$1" task_id="$2" issue_num="$3"
	local task_line="" desired_labels="" status_label="" projected_labels="" issue_json="" has_dependency=0
	task_line=$(_publication_validate_mapping "$task_id" "$issue_num") || {
		print_warning "${task_id}/#${issue_num}: canonical task, ref, or brief validation failed; retaining ${PUBLICATION_PENDING_LABEL}"
		return 1
	}
	desired_labels=$(_publication_desired_labels "$task_line") || return 1
	_publication_task_has_dependency "$task_line" && has_dependency=1
	issue_json=$(gh issue view "$issue_num" --repo "$repo" --json number,title,state,labels) || return 1
	jq -e --arg task_prefix "${task_id}:" \
		'.state == "OPEN" and (.title | startswith($task_prefix))' \
		<<<"$issue_json" >/dev/null || return 1
	_publication_issue_has_labels "$issue_json" "$PUBLICATION_PENDING_LABEL" || return 1
	status_label=$(_publication_status_label "$desired_labels" "$has_dependency" "$issue_json")
	projected_labels="$desired_labels"
	[[ -n "$status_label" ]] && projected_labels="${projected_labels:+${projected_labels},}${status_label}"

	if [[ -n "$projected_labels" ]]; then
		# Keep audit provenance at the reconciler instead of the generic CLI shim.
		gh_issue_edit_safe "$issue_num" --repo "$repo" \
			--add-label "$projected_labels" >/dev/null || return 1
	fi
	# Dependency metadata is authoritative even before native relationship repair.
	# Remove stale availability only after blocked/active state is established, so
	# every intermediate failure remains pending or non-dispatchable.
	if [[ "$has_dependency" -eq 1 ]] || _publication_issue_has_active_status "$issue_json"; then
		gh_issue_edit_safe "$issue_num" --repo "$repo" \
			--remove-label "$PUBLICATION_AVAILABLE_LABEL" >/dev/null || return 1
	fi
	issue_json=$(gh issue view "$issue_num" --repo "$repo" --json number,title,state,labels) || return 1
	jq -e --arg task_prefix "${task_id}:" \
		'.state == "OPEN" and (.title | startswith($task_prefix))' \
		<<<"$issue_json" >/dev/null || return 1
	# Active lifecycle state wins if assignment races with label projection.
	if _publication_issue_has_active_status "$issue_json"; then
		_publication_remove_inactive_statuses "$repo" "$issue_num" || return 1
		issue_json=$(gh issue view "$issue_num" --repo "$repo" --json number,title,state,labels) || return 1
	fi
	_publication_issue_has_labels "$issue_json" "$desired_labels" || return 1
	_publication_issue_has_labels "$issue_json" "$PUBLICATION_PENDING_LABEL" || return 1
	if [[ "$has_dependency" -eq 1 ]]; then
		! _publication_issue_has_labels "$issue_json" "$PUBLICATION_AVAILABLE_LABEL" || return 1
		_publication_issue_has_active_status "$issue_json" || \
			_publication_issue_has_labels "$issue_json" "$PUBLICATION_BLOCKED_LABEL" || return 1
	elif [[ "$status_label" == "$PUBLICATION_AVAILABLE_LABEL" ]] && \
		! _publication_issue_has_active_status "$issue_json"; then
		_publication_issue_has_labels "$issue_json" "$PUBLICATION_AVAILABLE_LABEL" || return 1
	fi

	# The blocker is intentionally the final mutation. Every prior failure leaves
	# the issue undispatchable and safely retryable.
	gh_issue_edit_safe "$issue_num" --repo "$repo" \
		--remove-label "$PUBLICATION_PENDING_LABEL" >/dev/null || return 1
	issue_json=$(gh issue view "$issue_num" --repo "$repo" --json labels) || return 1
	if _publication_issue_has_labels "$issue_json" "$PUBLICATION_PENDING_LABEL"; then
		return 1
	fi
	if _publication_issue_has_active_status "$issue_json" && \
		_publication_issue_has_inactive_status "$issue_json"; then
		# A lifecycle transition raced with the final pending-label removal.
		# Restore the dispatch fence before cleanup; a failed cleanup therefore
		# remains safely retryable instead of leaving a conflicting live status.
		gh_issue_edit_safe "$issue_num" --repo "$repo" \
			--add-label "$PUBLICATION_PENDING_LABEL" >/dev/null || return 1
		_publication_remove_inactive_statuses "$repo" "$issue_num" || return 1
		return 1
	fi
	_publication_issue_has_labels "$issue_json" "$desired_labels" || return 1
	if [[ "$has_dependency" -eq 1 ]]; then
		! _publication_issue_has_labels "$issue_json" "$PUBLICATION_AVAILABLE_LABEL" || return 1
		_publication_issue_has_active_status "$issue_json" || \
			_publication_issue_has_labels "$issue_json" "$PUBLICATION_BLOCKED_LABEL" || return 1
	fi
	print_success "${task_id}/#${issue_num}: planning publication reconciled"
	return 0
}

cmd_reconcile() {
	local repo="" expected_sha="" task_filter="" default_branch=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo) repo="${2:-}"; shift 2 ;;
		--sha) expected_sha="${2:-}"; shift 2 ;;
		--task) task_filter="${2:-}"; shift 2 ;;
		*) _publication_usage >&2; return 2 ;;
		esac
	done
	[[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || return 2
	[[ -f TODO.md && ! -L TODO.md ]] || return 2
	default_branch=$(gh repo view "$repo" --json defaultBranchRef --jq '.defaultBranchRef.name') || return 2
	_publication_exact_default_snapshot "$expected_sha" "$default_branch" || {
		print_error "Refusing reconciliation: HEAD is not exact origin/${default_branch} SHA ${expected_sha}"
		return 1
	}

	local issues_json="" issue_num="" title="" task_id="" failed=0
	issues_json=$(gh issue list --repo "$repo" --state open --label "$PUBLICATION_PENDING_LABEL" \
		--limit "$PUBLICATION_LIMIT" --json number,title) || return 1
	while IFS=$'\t' read -r issue_num title; do
		[[ -n "$issue_num" ]] || continue
		task_id=$(printf '%s\n' "$title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || true)
		[[ -n "$task_id" ]] || { failed=$((failed + 1)); continue; }
		[[ -z "$task_filter" || "$task_id" == "$task_filter" ]] || continue
		_publication_reconcile_one "$repo" "$task_id" "$issue_num" || failed=$((failed + 1))
	done < <(jq -r '.[] | [.number, .title] | @tsv' <<<"$issues_json")
	[[ "$failed" -eq 0 ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	case "${1:-}" in
	reconcile) shift; cmd_reconcile "$@" ;;
	*) _publication_usage >&2; exit 2 ;;
	esac
fi
