#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Local wake hints, not merge evidence. Polling and every action gate remain.

[[ -n "${_PULSE_MERGE_DIRTY_QUEUE_LOADED:-}" ]] && return 0
_PULSE_MERGE_DIRTY_QUEUE_LOADED=1
_PULSE_MERGE_DIRTY_HELPER="${BASH_SOURCE[0]%/*}/pulse-merge-dirty-queue.py"

_pulse_merge_queue_enabled() {
	# Runtime entrypoints opt in; sourcing merge helpers alone stays side-effect
	# free. Explicit zero is the rollback switch and is preserved by entrypoints.
	[[ "${AIDEVOPS_PULSE_MERGE_DIRTY_QUEUE_ENABLED:-0}" == 1 && "${DRY_RUN:-0}" != 1 ]] || return 1
	[[ -f "$_PULSE_MERGE_DIRTY_HELPER" ]] && command -v python3 >/dev/null 2>&1 || return 1
	return 0
}

_pulse_merge_queue_present() {
	[[ -s "${AIDEVOPS_PULSE_MERGE_DIRTY_QUEUE_DIR:-${HOME}/.aidevops/state/pulse-merge-dirty}/work.sqlite3" ]] || return 1
	return 0
}

_pulse_merge_queue_enqueue() {
	local repo="$1" pr="$2"
	if [[ "${AIDEVOPS_PULSE_MERGE_DIRTY_QUEUE_ENABLED:-0}" != 1 || "${DRY_RUN:-0}" == 1 ]]; then
		printf 'legacy\n'
		return 0
	fi
	_pulse_merge_queue_enabled || return 1
	python3 "$_PULSE_MERGE_DIRTY_HELPER" enqueue "$repo" "$pr"
	return $?
}

# Outputs are caller-local dynamic-scope variables. Context is deliberately not
# exported, and a borrowed claim must match the current Bash process and target.
_pulse_merge_queue_begin() {
	local repo="$1" pr="$2" mode="$3" borrowed="${4:-}"
	_PULSE_MERGE_QUEUE_CONTEXT=""
	_PULSE_MERGE_QUEUE_OWNED=0
	_PULSE_MERGE_QUEUE_DIRTY=0
	if [[ "${AIDEVOPS_PULSE_MERGE_DIRTY_QUEUE_ENABLED:-0}" != 1 || "${DRY_RUN:-0}" == 1 ]]; then
		return 0
	fi
	if ! _pulse_merge_queue_enabled; then
		[[ "$mode" == poll ]] && return 0
		return 4
	fi
	if [[ "$mode" == poll ]] && ! _pulse_merge_queue_present; then
		return 0
	fi
	repo=$(printf '%s' "$repo" | LC_ALL=C tr '[:upper:]' '[:lower:]') || return 4
	local owner_pid="${BASHPID:-}"
	[[ -n "$owner_pid" ]] || owner_pid=$(exec sh -c 'printf "%s" "$PPID"') || return 4
	if [[ -n "$borrowed" ]] && printf '%s' "$borrowed" | jq -e \
		--arg repo "$repo" --argjson pr "$pr" --argjson pid "$owner_pid" \
		'.repo == $repo and .pr == $pr and .pid == $pid and (.nonce | test("^[a-f0-9]{32}$"))' >/dev/null 2>&1; then
		_PULSE_MERGE_QUEUE_CONTEXT="$borrowed"
	else
		local receipt="" rc=0
		receipt=$(python3 "$_PULSE_MERGE_DIRTY_HELPER" claim "$repo" "$pr" "$owner_pid" 2>/dev/null) || rc=$?
		[[ "$rc" -ne 75 ]] || return 4
		if [[ "$rc" -ne 0 ]]; then
			# A failed optimization cannot disable the authoritative polling path.
			# Event fast paths, however, may not proceed without coordination.
			[[ "$mode" == poll ]] && return 0
			return 4
		fi
		if ! printf '%s' "$receipt" | jq -e --arg repo "$repo" --argjson pr "$pr" --argjson pid "$owner_pid" \
			'.repo == $repo and .pr == $pr and .pid == $pid and (.nonce | test("^[a-f0-9]{32}$"))' >/dev/null 2>&1; then
			return 4
		fi
		_PULSE_MERGE_QUEUE_CONTEXT="$receipt"
		_PULSE_MERGE_QUEUE_OWNED=1
	fi
	if printf '%s' "$_PULSE_MERGE_QUEUE_CONTEXT" | jq -e '.generation | length > 0' >/dev/null 2>&1; then
		_PULSE_MERGE_QUEUE_DIRTY=1
	fi
	return 0
}

_pulse_merge_queue_begin_object() {
	local repo="$1" object="$2" borrowed="${3:-}"
	_PULSE_MERGE_QUEUE_CONTEXT=""
	_PULSE_MERGE_QUEUE_OWNED=0
	_PULSE_MERGE_QUEUE_DIRTY=0
	# Unconfigured receivers add no subprocesses to ordinary polling.
	_pulse_merge_queue_enabled && _pulse_merge_queue_present || return 0
	local pr=""
	pr=$(printf '%s' "$object" | jq -r '.number // empty' 2>/dev/null) || return 4
	[[ "$pr" =~ ^[1-9][0-9]*$ ]] || return 4
	_pulse_merge_queue_begin "$repo" "$pr" poll "$borrowed"
	return $?
}

_pulse_merge_queue_refresh_object() {
	local repo="$1" output_var="$2"
	[[ "$output_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	local pr="" refreshed=""
	pr=$(printf '%s' "$_PULSE_MERGE_QUEUE_CONTEXT" | jq -r '.pr') || return 1
	refreshed=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 AIDEVOPS_GH_REST_FIRST_READS=1 \
		gh_pr_view "$pr" --repo "$repo" --json "$(_pulse_merge_ready_pr_json_fields)" 2>/dev/null) || return 1
	printf '%s' "$refreshed" | jq -e --argjson pr "$pr" 'type == "object" and .number == $pr' >/dev/null || return 1
	printf -v "$output_var" '%s' "$refreshed"
	return 0
}

_pulse_merge_queue_finish() {
	local result="$1" handled=0
	[[ "${_PULSE_MERGE_QUEUE_OWNED:-0}" == 1 && -n "${_PULSE_MERGE_QUEUE_CONTEXT:-}" ]] || return 0
	case "$result" in 0 | 2) handled=1 ;; esac
	python3 "$_PULSE_MERGE_DIRTY_HELPER" finish "$_PULSE_MERGE_QUEUE_CONTEXT" "$handled" >/dev/null 2>&1 || true
	_PULSE_MERGE_QUEUE_OWNED=0
	return 0
}

_pulse_merge_queue_priority_keys() {
	local repo="$1"
	_pulse_merge_queue_enabled && _pulse_merge_queue_present || return 0
	python3 "$_PULSE_MERGE_DIRTY_HELPER" priority "$repo" 2>/dev/null || true
	return 0
}

return 0
