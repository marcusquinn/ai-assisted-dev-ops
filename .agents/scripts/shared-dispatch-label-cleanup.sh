#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shared-dispatch-label-cleanup.sh — terminal issue dispatch-label hygiene.

[[ -n "${_SHARED_DISPATCH_LABEL_CLEANUP_LOADED:-}" ]] && return 0
_SHARED_DISPATCH_LABEL_CLEANUP_LOADED=1

: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
: "${REPOS_JSON:=${HOME}/.config/aidevops/repos.json}"
: "${PULSE_STALE_DISPATCH_LABEL_SWEEP_INTERVAL:=86400}"
: "${PULSE_STALE_DISPATCH_LABEL_SWEEP_LIMIT_PER_REPO:=50}"

_DISPATCH_LABEL_CLEANUP_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_DISPATCH_LABEL_CLEANUP_DIR" == "${BASH_SOURCE[0]}" ]] && _DISPATCH_LABEL_CLEANUP_DIR="."
: "${DISPATCH_LABEL_CLEANUP_BLOCKER_LOGGER:=${_DISPATCH_LABEL_CLEANUP_DIR}/worker-blocker-log.mjs}"

_TERMINAL_DISPATCH_LABELS=(
	"auto-dispatch"
	"status:available"
	"status:queued"
	"status:claimed"
	"status:in-progress"
	"status:in-review"
	"needs-maintainer-permissions"
)

_dispatch_label_cleanup_stamp_file() {
	printf '%s\n' "${HOME}/.aidevops/logs/pulse-stale-dispatch-label-sweep.last"
	return 0
}

clear_terminal_issue_dispatch_labels() {
	local issue_number="$1"
	local repo_slug="$2"
	local context="${3:-terminal}"
	local current_labels="${4:-}"
	local labels_fetched="${5:-false}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ || -z "$repo_slug" ]]; then
		return 1
	fi

	if [[ -z "$current_labels" && "$labels_fetched" != "true" ]] && ! current_labels=$(gh issue view "$issue_number" --repo "$repo_slug" --json labels --jq '.labels[].name'); then
		echo "[pulse-wrapper] dispatch-label-cleanup: failed to fetch labels for ${repo_slug}#${issue_number} (${context})" >>"$LOGFILE"
		return 1
	fi

	local -a edit_args=("issue" "edit" "$issue_number" "--repo" "$repo_slug")
	local label labels_blob found=0
	labels_blob=$'\n'"$current_labels"$'\n'
	for label in "${_TERMINAL_DISPATCH_LABELS[@]}"; do
		if [[ "$labels_blob" == *$'\n'"$label"$'\n'* ]]; then
			edit_args+=("--remove-label" "$label")
			found=1
		fi
	done

	if [[ "$found" -eq 0 ]]; then
		return 0
	fi

	local exit_code=0
	gh "${edit_args[@]}" >/dev/null 2>&1 || exit_code=$?
	if [[ "$exit_code" -eq 0 ]]; then
		echo "[pulse-wrapper] dispatch-label-cleanup: stripped terminal dispatch labels from ${repo_slug}#${issue_number} (${context})" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-wrapper] dispatch-label-cleanup: failed to strip terminal dispatch labels from ${repo_slug}#${issue_number} (${context}) [exit: ${exit_code}]" >>"$LOGFILE"
	return "$exit_code"
}

reconcile_terminal_issue_worker_blockers() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="${3:-issue_terminal}"
	local source="${4:-dispatch-label-cleanup}"
	local logger="${DISPATCH_LABEL_CLEANUP_BLOCKER_LOGGER}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ || -z "$repo_slug" || ! -f "$logger" || -L "$logger" ]]; then
		return 1
	fi
	command -v node >/dev/null 2>&1 || return 1
	if node "$logger" resolve-issue \
		--issue-number "$issue_number" \
		--repo-slug "$repo_slug" \
		--event "issue_terminal_reconciled" \
		--status "resolved" \
		--reason "$reason" \
		--source "$source" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

_dispatch_blocker_active_issue_candidates() {
	local repo_slug="$1"
	local limit="$2"
	local logger="${DISPATCH_LABEL_CLEANUP_BLOCKER_LOGGER}"

	if [[ -z "$repo_slug" || ! "$limit" =~ ^[1-9][0-9]*$ || ! -f "$logger" || -L "$logger" ]]; then
		return 1
	fi
	command -v node >/dev/null 2>&1 || return 1
	if node "$logger" list-active-issues --repo-slug "$repo_slug" --limit "$limit"; then
		return 0
	fi
	return 1
}

_dispatch_terminal_issue_snapshot() {
	local issue_number="$1"
	local repo_slug="$2"
	local snapshot=""
	local state=""

	if [[ ! "$issue_number" =~ ^[0-9]+$ || -z "$repo_slug" ]]; then
		return 1
	fi
	snapshot=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json state,stateReason,labels \
		--jq '[.state, (.stateReason // ""), ([.labels[].name] | join("|"))] | @tsv' 2>/dev/null) || return 1
	IFS=$'\t' read -r state _ <<<"$snapshot"
	if [[ "$state" != "OPEN" && "$state" != "CLOSED" ]]; then
		return 1
	fi
	printf '%s\n' "$snapshot"
	return 0
}

_dispatch_label_sweep_due() {
	if [[ "${PULSE_STALE_DISPATCH_LABEL_SWEEP_FORCE:-0}" == "1" ]]; then
		return 0
	fi

	local stamp_file
	stamp_file=$(_dispatch_label_cleanup_stamp_file)
	[[ -f "$stamp_file" ]] || return 0

	local now_epoch stamp_epoch age
	now_epoch=$(date +%s 2>/dev/null || echo "0")
	stamp_epoch=$(cat "$stamp_file" 2>/dev/null || echo "0")
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=0
	[[ "$stamp_epoch" =~ ^[0-9]+$ ]] || stamp_epoch=0
	age=$((now_epoch - stamp_epoch))

	if [[ "$age" -ge "$PULSE_STALE_DISPATCH_LABEL_SWEEP_INTERVAL" ]]; then
		return 0
	fi
	return 1
}

_dispatch_label_sweep_mark_run() {
	local stamp_file
	stamp_file=$(_dispatch_label_cleanup_stamp_file)
	mkdir -p "$(dirname "$stamp_file")" 2>/dev/null || true
	date +%s >"$stamp_file" 2>/dev/null || true
	return 0
}

_dispatch_label_sweep_repos() {
	local repos_json="${1:-$REPOS_JSON}"
	[[ -f "$repos_json" ]] || return 1
	jq -r '
		.initialized_repos[]? |
		select((.local_only // false) == false) |
		.slug // empty
	' "$repos_json" 2>/dev/null
	return 0
}

sweep_closed_auto_dispatch_issues() {
	if ! _dispatch_label_sweep_due; then
		return 0
	fi

	local repos_json="${1:-$REPOS_JSON}"
	local limit="${PULSE_STALE_DISPATCH_LABEL_SWEEP_LIMIT_PER_REPO:-50}"
	[[ "$limit" =~ ^[0-9]+$ ]] || limit=50
	[[ "$limit" -gt 0 ]] || limit=50

	local total=0 checked=0 open=0 ambiguous=0 logger_failed=0 label_failed=0
	local repo_slug issue_number issue_rows snapshot state state_reason labels_csv reason
	while IFS= read -r repo_slug; do
		[[ -n "$repo_slug" ]] || continue
		if ! declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 \
			|| ! repo_allows_pulse_write_actions "$repo_slug"; then
			continue
		fi
		issue_rows=$(_dispatch_blocker_active_issue_candidates "$repo_slug" "$limit") || {
			logger_failed=$((logger_failed + 1))
			continue
		}
		[[ -n "$issue_rows" ]] || continue
		while IFS= read -r issue_number; do
			[[ "$issue_number" =~ ^[0-9]+$ ]] || continue
			snapshot=$(_dispatch_terminal_issue_snapshot "$issue_number" "$repo_slug") || {
				ambiguous=$((ambiguous + 1))
				continue
			}
			IFS=$'\t' read -r state state_reason labels_csv <<<"$snapshot"
			checked=$((checked + 1))
			if [[ "$state" == "OPEN" ]]; then
				open=$((open + 1))
				continue
			fi
			reason="issue_closed_completed"
			[[ "$state_reason" == "NOT_PLANNED" ]] && reason="issue_closed_not_planned"
			clear_terminal_issue_dispatch_labels "$issue_number" "$repo_slug" \
				"closed-blocker-sweep" "${labels_csv//|/$'\n'}" "true" || label_failed=$((label_failed + 1))
			if reconcile_terminal_issue_worker_blockers "$issue_number" "$repo_slug" "$reason" "dispatch-label-cleanup-sweep"; then
				total=$((total + 1))
			else
				logger_failed=$((logger_failed + 1))
			fi
		done <<<"$issue_rows"
	done < <(_dispatch_label_sweep_repos "$repos_json" || true)

	_dispatch_label_sweep_mark_run
	echo "[pulse-wrapper] dispatch-label-cleanup: blocker sweep resolved=${total} checked=${checked} open=${open} ambiguous=${ambiguous} logger_failed=${logger_failed} label_failed=${label_failed}" >>"$LOGFILE"
	return 0
}
