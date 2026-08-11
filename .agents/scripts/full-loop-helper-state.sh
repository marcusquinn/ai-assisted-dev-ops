#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop State & Lifecycle -- state management, phase emission, lifecycle commands
# =============================================================================
# Sub-library for full-loop-helper.sh orchestrator. Contains state persistence
# (save/load), phase emitters, gate checks, and lifecycle commands
# (start/resume/status/cancel/logs/complete).
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-state.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning, etc.)
#   - full-loop-helper-evidence.sh (fresh merged-PR evidence)
#   - Globals: STATE_DIR, STATE_FILE, DEFAULT_MAX_*, HEADLESS, _FG_PID_FILE
#   - Functions: is_headless, print_phase (defined in orchestrator before sourcing)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_STATE_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_STATE_LIB_LOADED=1
_FULL_LOOP_RELEASE_NOT_REQUESTED="not-requested"
_FULL_LOOP_RELEASE_PUBLISHED="published"
_FULL_LOOP_RELEASE_SUPERSEDED="superseded"
_FULL_LOOP_RELEASE_STRICT="strict"
_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED="published-reconcile"
_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED="authorized-published-reconcile"
_FULL_LOOP_RELEASE_EVIDENCE_RECEIPT_CONFLICT="receipt-conflict"
_FULL_LOOP_RELEASE_ROLE_AGGREGATED="aggregated"
_FULL_LOOP_SHA40_REGEX='^[0-9a-f]{40}$'
_FULL_LOOP_VERSION_TAG_REGEX='^v[0-9]+\.[0-9]+\.[0-9]+$'
_FULL_LOOP_JSON_NUMBER_TYPE="number"
_FULL_LOOP_EXECUTOR_INITIALIZED="initialized-only"
_FULL_LOOP_EXECUTOR_IN_PROGRESS="in-progress"
_FULL_LOOP_PHASE_FAILED="failed"
_FULL_LOOP_PHASE_RUNNING="running"
_FULL_LOOP_PHASE_WAITING="waiting"
_FULL_LOOP_PHASE_COMPLETED="completed"
_FULL_LOOP_PHASE_TASK="task"
_FULL_LOOP_RESOURCE_NONE="none"
FULL_LOOP_TRANSITION_LOCK_TOKEN=""
FULL_LOOP_TRANSITION_LOCK_DEPTH=0

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# shellcheck source=release-authorization-manifest-helper.sh
source "${SCRIPT_DIR}/release-authorization-manifest-helper.sh"

if [[ -f "${SCRIPT_DIR}/full-loop-cleanup-receipt.sh" ]]; then
	# shellcheck source=./full-loop-cleanup-receipt.sh
	source "${SCRIPT_DIR}/full-loop-cleanup-receipt.sh"
fi

# shellcheck source=./full-loop-helper-evidence.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via SCRIPT_DIR
source "${SCRIPT_DIR}/full-loop-helper-evidence.sh"

# --- State Management ---

save_state() {
	local phase="$1" prompt="$2" pr_number="${3:-}" started_at="${4:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
	local now
	now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	local tmp_file="${STATE_FILE}.tmp.$$"
	RUN_ID="${RUN_ID:-run-$(date -u '+%Y%m%dT%H%M%SZ')-$$}"
	STATE_REVISION=$((${STATE_REVISION:-0} + 1))
	mkdir -p "$STATE_DIR"
	cat >"$tmp_file" <<EOF
---
schema_version: 2
active: true
run_id: "${RUN_ID}"
state_revision: ${STATE_REVISION}
phase: ${phase}
phase_status: ${PHASE_STATUS:-initialized}
phase_attempt: ${PHASE_ATTEMPT:-0}
phase_started_at: "${PHASE_STARTED_AT:-}"
phase_ended_at: "${PHASE_ENDED_AT:-}"
next_action: "${NEXT_ACTION:-resume}"
terminal_evidence: "${TERMINAL_EVIDENCE:-}"
executor_status: ${EXECUTOR_STATUS:-$_FULL_LOOP_EXECUTOR_INITIALIZED}
executor_pid: "${EXECUTOR_PID:-}"
executor_identity: "${EXECUTOR_IDENTITY:-}"
heartbeat_at: "${HEARTBEAT_AT:-}"
pr_check_status: "${PR_CHECK_STATUS:-}"
pr_check_head: "${PR_CHECK_HEAD:-}"
pr_check_evidence: "${PR_CHECK_EVIDENCE:-}"
manual_resume_count: ${MANUAL_RESUME_COUNT:-0}
reused_subagent_units: ${REUSED_SUBAGENT_UNITS:-0}
duplicate_work_avoided: ${DUPLICATE_WORK_AVOIDED:-0}
started_at: "${started_at}"
updated_at: "${now}"
pr_number: "${pr_number}"
max_task_iterations: ${MAX_TASK_ITERATIONS:-$DEFAULT_MAX_TASK_ITERATIONS}
max_preflight_iterations: ${MAX_PREFLIGHT_ITERATIONS:-$DEFAULT_MAX_PREFLIGHT_ITERATIONS}
max_pr_iterations: ${MAX_PR_ITERATIONS:-$DEFAULT_MAX_PR_ITERATIONS}
skip_preflight: ${SKIP_PREFLIGHT:-false}
skip_postflight: ${SKIP_POSTFLIGHT:-false}
skip_runtime_testing: ${SKIP_RUNTIME_TESTING:-false}
no_auto_pr: ${NO_AUTO_PR:-false}
no_auto_deploy: ${NO_AUTO_DEPLOY:-false}
release_intent: ${RELEASE_INTENT:-false}
release_type: ${RELEASE_TYPE:-patch}
deployment_scope: ${DEPLOYMENT_SCOPE:-incremental}
release_expected_sources: "${RELEASE_EXPECTED_SOURCES:-}"
release_status: ${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}
headless: ${HEADLESS:-false}
---

${prompt}
EOF
	mv "$tmp_file" "$STATE_FILE"
	return 0
}

_full_loop_append_event() {
	local event_type="$1"
	local status="$2"
	local event_file="${STATE_DIR}/full-loop-events.jsonl"
	local now
	now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	mkdir -p "$STATE_DIR" || return 0
	if command -v jq >/dev/null 2>&1; then
		jq -cn --arg event_type "$event_type" --arg run_id "${RUN_ID:-unknown}" \
			--arg phase "${CURRENT_PHASE:-${PHASE:-unknown}}" --arg status "$status" \
			--arg timestamp "$now" --argjson attempt "${PHASE_ATTEMPT:-0}" \
			'{event_type:$event_type,run_id:$run_id,phase:$phase,status:$status,attempt:$attempt,timestamp:$timestamp}' \
			>>"$event_file" 2>/dev/null || true
	fi
	return 0
}

load_state() {
	[[ -f "$STATE_FILE" ]] || return 1
	# Pre-initialize all state variables with safe defaults so that set -u does
	# not abort when the state file is incomplete (missing fields are never set
	# by the awk parse loop, leaving variables unbound).
	PHASE=""
	RUN_ID=""
	STATE_REVISION="0"
	PHASE_STATUS="initialized"
	PHASE_ATTEMPT="0"
	PHASE_STARTED_AT=""
	PHASE_ENDED_AT=""
	NEXT_ACTION="resume"
	TERMINAL_EVIDENCE=""
	EXECUTOR_STATUS="$_FULL_LOOP_EXECUTOR_INITIALIZED"
	EXECUTOR_PID=""
	EXECUTOR_IDENTITY=""
	HEARTBEAT_AT=""
	PR_CHECK_STATUS=""
	PR_CHECK_HEAD=""
	PR_CHECK_EVIDENCE=""
	MANUAL_RESUME_COUNT="0"
	REUSED_SUBAGENT_UNITS="0"
	DUPLICATE_WORK_AVOIDED="0"
	ACTIVE=""
	ITERATION=""
	STARTED_AT="unknown"
	UPDATED_AT=""
	PR_NUMBER=""
	MAX_TASK_ITERATIONS="$DEFAULT_MAX_TASK_ITERATIONS"
	MAX_PREFLIGHT_ITERATIONS="$DEFAULT_MAX_PREFLIGHT_ITERATIONS"
	MAX_PR_ITERATIONS="$DEFAULT_MAX_PR_ITERATIONS"
	SKIP_PREFLIGHT="false"
	SKIP_POSTFLIGHT="false"
	SKIP_RUNTIME_TESTING="false"
	NO_AUTO_PR="false"
	NO_AUTO_DEPLOY="false"
	RELEASE_INTENT="false"
	RELEASE_TYPE="patch"
	DEPLOYMENT_SCOPE="incremental"
	RELEASE_EXPECTED_SOURCES=""
	RELEASE_STATUS="$_FULL_LOOP_RELEASE_NOT_REQUESTED"
	HEADLESS="${FULL_LOOP_HEADLESS:-false}"
	SAVED_PROMPT=""
	# Single-pass parse of YAML frontmatter — safe variable assignment via printf -v
	local _key _val _line
	while IFS= read -r _line; do
		_key="${_line%%=*}"
		_val="${_line#*=}"
		# Allowlist: only set known state variables
		case "$_key" in
		PHASE | ACTIVE | ITERATION | STARTED_AT | UPDATED_AT | RUN_ID | STATE_REVISION | \
			PHASE_STATUS | PHASE_ATTEMPT | PHASE_STARTED_AT | PHASE_ENDED_AT | NEXT_ACTION | TERMINAL_EVIDENCE | \
			EXECUTOR_STATUS | EXECUTOR_PID | EXECUTOR_IDENTITY | HEARTBEAT_AT | PR_CHECK_STATUS | PR_CHECK_HEAD | PR_CHECK_EVIDENCE | \
			MANUAL_RESUME_COUNT | REUSED_SUBAGENT_UNITS | DUPLICATE_WORK_AVOIDED | \
			MAX_TASK_ITERATIONS | MAX_PREFLIGHT_ITERATIONS | \
			MAX_PR_ITERATIONS | SKIP_PREFLIGHT | SKIP_POSTFLIGHT | SKIP_RUNTIME_TESTING | \
			NO_AUTO_PR | NO_AUTO_DEPLOY | RELEASE_INTENT | RELEASE_TYPE | DEPLOYMENT_SCOPE | RELEASE_EXPECTED_SOURCES | RELEASE_STATUS | HEADLESS | PR_NUMBER)
			printf -v "$_key" '%s' "$_val"
			;;
		esac
	done < <(awk -F': ' '/^---$/{n++;next} n==1 && NF>=2{
		gsub(/[" ]/, "", $2); k=$1; gsub(/-/, "_", k)
		print toupper(k) "=" $2
	}' "$STATE_FILE")
	CURRENT_PHASE="${PHASE:-}"
	SAVED_PROMPT=$(sed -n '/^---$/,/^---$/d; p' "$STATE_FILE")
	return 0
}

is_loop_active() { [[ -f "$STATE_FILE" ]] && grep -q '^active: true' "$STATE_FILE"; }

# --- Utility Functions ---

is_aidevops_repo() {
	local r
	r=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
	[[ "$r" == *"/aidevops"* ]] || [[ -f "$r/.aidevops-repo" ]]
}
get_current_branch() { git branch --show-current 2>/dev/null || echo ""; }
is_on_feature_branch() {
	local b
	b=$(get_current_branch)
	[[ -n "$b" && "$b" != "main" && "$b" != "master" ]]
}

# --- Phase Emitters ---
# Drive the AI loop per full-loop.md

emit_task_phase() {
	print_phase "Task Development" "AI will iterate on task until TASK_COMPLETE"
	echo "PROMPT: $1"
	echo "When complete, emit: <promise>TASK_COMPLETE</promise>"
}
emit_preflight_phase() {
	print_phase "Preflight" "AI runs quality checks"
	[[ "${SKIP_PREFLIGHT:-false}" == "true" ]] && {
		print_warning "Preflight skipped"
		echo "<promise>PREFLIGHT_SKIPPED</promise>"
		return 0
	}
	echo "Run quality checks per full-loop.md guidance."
}
emit_pr_create_phase() {
	print_phase "PR Creation" "AI creates pull request"
	[[ "${NO_AUTO_PR:-false}" == "true" ]] && ! is_headless && {
		print_warning "Auto PR disabled"
		return 0
	}
	echo "Create PR per full-loop.md guidance."
}
emit_pr_review_phase() {
	print_phase "PR Review" "AI monitors CI and reviews"
	echo "Monitor PR per full-loop.md guidance."
}
emit_postflight_phase() {
	print_phase "Postflight" "AI verifies release health"
	[[ "${RELEASE_INTENT:-false}" == "true" ]] || {
		RELEASE_STATUS="$_FULL_LOOP_RELEASE_NOT_REQUESTED"
		_full_loop_persist_release_status "$RELEASE_STATUS"
		print_info "release:not-requested — publication was not explicitly authorized"
		return 0
	}
	if [[ "$RELEASE_STATUS" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$RELEASE_STATUS" == "$_FULL_LOOP_RELEASE_SUPERSEDED" ]]; then
		print_info "release:${RELEASE_STATUS} — publication gate already completed"
		return 0
	fi
	if ! _full_loop_invoke_authorized_release; then
		RELEASE_STATUS="$_FULL_LOOP_PHASE_FAILED"
		_full_loop_persist_release_status "$RELEASE_STATUS"
		print_error "release:failed"
		return 1
	fi
	if ! _full_loop_reconcile_detached_publication_receipt; then
		RELEASE_STATUS="$_FULL_LOOP_PHASE_FAILED"
		_full_loop_persist_release_status "$RELEASE_STATUS"
		print_error "release:failed — terminal detached receipt is missing"
		return 1
	fi
	print_success "release:${RELEASE_STATUS}"
	[[ "${SKIP_POSTFLIGHT:-false}" == "true" ]] && {
		print_warning "Postflight skipped"
		echo "<promise>POSTFLIGHT_SKIPPED</promise>"
		return 0
	}
	echo "Verify release per full-loop.md guidance."
}

_full_loop_release_receipt_path() {
	local repo="$1"
	local pr_number="$2"
	local receipt_dir="${AIDEVOPS_FULL_LOOP_RECEIPT_DIR:-${HOME}/.aidevops/state/full-loop-release}"
	local safe_repo="${repo//\//_}"
	printf '%s/%s-%s.status\n' "$receipt_dir" "$safe_repo" "$pr_number"
	return 0
}

_full_loop_release_evidence_path() {
	local repo="$1"
	local pr_number="$2"
	local evidence_type="$3"
	local receipt_path=""
	case "$evidence_type" in aggregate | authorization-gap | failure | receipt-conflict | successor) ;; *) return 1 ;; esac
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	printf '%s.%s.json\n' "${receipt_path%.status}" "$evidence_type"
	return 0
}

_full_loop_release_authorization_path() {
	local repo="$1"
	local pr_number="$2"
	local receipt_path=""
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	printf '%s.authorization.json\n' "${receipt_path%.status}"
	return 0
}

_full_loop_read_release_authorization() {
	local repo="$1"
	local pr_number="$2"
	local authorization_path=""
	authorization_path=$(_full_loop_release_authorization_path "$repo" "$pr_number") || return 1
	[[ -f "$authorization_path" ]] || return 2
	jq -er --arg repo "$repo" --argjson pr "$pr_number" '
		select(.schema_version == 1 and .repository == $repo and .requested_pr == $pr)
		| .expected_sources
		| sort_by(.pr)
		| map("\(.pr)@\(.merge)")
		| join(",")
	' "$authorization_path"
	return $?
}

_full_loop_read_release_authorization_record() {
	local repo="$1"
	local pr_number="$2"
	local authorization_path=""
	authorization_path=$(_full_loop_release_authorization_path "$repo" "$pr_number") || return 1
	[[ -f "$authorization_path" ]] || return 2
	jq -ce --arg repo "$repo" --argjson pr "$pr_number" '
		select(.schema_version == 1 and .repository == $repo and .requested_pr == $pr)
	' "$authorization_path"
	return $?
}

_full_loop_write_release_authorization_snapshot() {
	local repo="$1"
	local pr_number="$2"
	local snapshot_json="$3"
	local authorization_path=""
	jq -e --arg repo "$repo" --argjson pr "$pr_number" '
		.schema_version == 1 and .repository == $repo and .requested_pr == $pr
	' <<<"$snapshot_json" >/dev/null || return 1
	authorization_path=$(_full_loop_release_authorization_path "$repo" "$pr_number") || return 1
	mkdir -p "${authorization_path%/*}" || return 1
	printf '%s\n' "$snapshot_json" >"${authorization_path}.tmp.$$" || return 1
	mv "${authorization_path}.tmp.$$" "$authorization_path" || return 1
	return 0
}

_full_loop_persist_release_authorization() {
	local repo="$1"
	local pr_number="$2"
	local expected_sources="$3"
	local authorization_path=""
	local expected_json=""
	local existing=""
	local now=""
	[[ -n "$repo" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	expected_sources=$(release_authorization_manifest_string "$expected_sources") || return 1
	expected_json=$(release_authorization_manifest_json "$expected_sources") || return 1
	authorization_path=$(_full_loop_release_authorization_path "$repo" "$pr_number") || return 1
	if [[ -f "$authorization_path" ]]; then
		existing=$(_full_loop_read_release_authorization "$repo" "$pr_number") || return 1
		[[ "$existing" == "$expected_sources" ]] || {
			printf 'Persisted release authorization for PR #%s conflicts with the requested source set\n' "$pr_number" >&2
			return 1
		}
		return 0
	fi
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	mkdir -p "${authorization_path%/*}" || return 1
	jq -cn --arg repo "$repo" --argjson requested_pr "$pr_number" --argjson expected "$expected_json" --arg now "$now" \
		'{schema_version:1,repository:$repo,requested_pr:$requested_pr,expected_sources:$expected,recorded_at:$now}' \
		>"${authorization_path}.tmp.$$" || return 1
	mv "${authorization_path}.tmp.$$" "$authorization_path" || return 1
	return 0
}

_full_loop_write_release_authorization_record() {
	local repo="$1"
	local pr_number="$2"
	local expected_sources="$3"
	local previous_record="${4:-null}"
	local authorization_path=""
	local expected_json=""
	expected_json=$(release_authorization_manifest_json "$expected_sources") || return 1
	if [[ "$previous_record" != "null" ]]; then
		jq -e --arg repo "$repo" --argjson pr "$pr_number" '
			.schema_version == 1 and .repository == $repo and .requested_pr == $pr
		' <<<"$previous_record" >/dev/null || return 1
	fi
	authorization_path=$(_full_loop_release_authorization_path "$repo" "$pr_number") || return 1
	mkdir -p "${authorization_path%/*}" || return 1
	jq -cn --arg repo "$repo" --argjson requested_pr "$pr_number" --argjson expected "$expected_json" \
		--argjson previous "$previous_record" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
		{schema_version:1,repository:$repo,requested_pr:$requested_pr,expected_sources:$expected,recorded_at:$now}
		+ (if $previous == null then {} else {aggregate_recovery:{previous_authorization:$previous}} end)
	' >"${authorization_path}.tmp.$$" || return 1
	mv "${authorization_path}.tmp.$$" "$authorization_path" || return 1
	return 0
}

_full_loop_read_release_authorization_recovery_snapshot() {
	local repo="$1"
	local pr_number="$2"
	local record=""
	record=$(_full_loop_read_release_authorization_record "$repo" "$pr_number") || return 1
	jq -ce --arg repo "$repo" --argjson pr "$pr_number" '
		.aggregate_recovery.previous_authorization
		| select(.schema_version == 1 and .repository == $repo and .requested_pr == $pr)
	' <<<"$record"
	return $?
}

_full_loop_expand_release_authorization_for_aggregate() {
	local repo="$1"
	local pr_number="$2"
	local previous_sources="$3"
	local expected_sources="$4"
	local existing=""
	local previous_record=""
	previous_sources=$(release_authorization_manifest_string "$previous_sources") || return 1
	expected_sources=$(release_authorization_manifest_string "$expected_sources") || return 1
	existing=$(_full_loop_read_release_authorization "$repo" "$pr_number") || return 1
	[[ "$existing" == "$previous_sources" ]] || return 1
	release_authorization_subset "$previous_sources" "$expected_sources" || return 1
	previous_record=$(_full_loop_read_release_authorization_record "$repo" "$pr_number") || return 1
	_full_loop_write_release_authorization_record "$repo" "$pr_number" "$expected_sources" "$previous_record"
	return $?
}

_full_loop_restore_release_authorization_after_aggregate() {
	local repo="$1"
	local pr_number="$2"
	local recovery_sources="$3"
	local previous_sources="$4"
	local existing=""
	local snapshot=""
	local snapshot_sources=""
	recovery_sources=$(release_authorization_manifest_string "$recovery_sources") || return 1
	previous_sources=$(release_authorization_manifest_string "$previous_sources") || return 1
	existing=$(_full_loop_read_release_authorization "$repo" "$pr_number") || return 1
	[[ "$existing" == "$recovery_sources" ]] || return 1
	snapshot=$(_full_loop_read_release_authorization_recovery_snapshot "$repo" "$pr_number") || return 1
	snapshot_sources=$(jq -r '.expected_sources | sort_by(.pr) | map("\(.pr)@\(.merge)") | join(",")' \
		<<<"$snapshot") || return 1
	[[ "$snapshot_sources" == "$previous_sources" ]] || return 1
	_full_loop_write_release_authorization_snapshot "$repo" "$pr_number" "$snapshot"
	return $?
}

_full_loop_write_release_authorization_gap_evidence() {
	local repo="$1"
	local requested_pr="$2"
	local expected_sources="$3"
	local observed_sources="$4"
	local tag_object="$5"
	local release_commit="$6"
	local reason="$7"
	local evidence_path=""
	local expected_json=""
	local observed_json=""
	local now=""
	[[ "$requested_pr" =~ ^[0-9]+$ && "$tag_object" =~ $_FULL_LOOP_SHA40_REGEX && "$release_commit" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	[[ -n "$reason" ]] || return 1
	expected_json=$(release_authorization_manifest_json "$expected_sources") || return 1
	observed_json=$(release_authorization_manifest_json "$observed_sources") || return 1
	evidence_path=$(_full_loop_release_evidence_path "$repo" "$requested_pr" authorization-gap) || return 1
	if [[ -f "$evidence_path" ]]; then
		jq -e --arg repo "$repo" --argjson requested_pr "$requested_pr" --argjson expected "$expected_json" \
			--argjson observed "$observed_json" --arg tag_object "$tag_object" --arg release_commit "$release_commit" \
			--arg reason "$reason" '
			.schema_version == 1 and .status == "authorization-gap" and .repository == $repo
			and .requested_pr == $requested_pr and .expected_sources == $expected and .observed_sources == $observed
			and .tag_object == $tag_object and .release_commit == $release_commit and .reason == $reason
			and .terminal_cleanup_evidence == false
		' "$evidence_path" >/dev/null 2>&1
		return $?
	fi
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	mkdir -p "${evidence_path%/*}" || return 1
	jq -cn --arg repo "$repo" --argjson requested_pr "$requested_pr" --argjson expected "$expected_json" \
		--argjson observed "$observed_json" --arg tag_object "$tag_object" --arg release_commit "$release_commit" \
		--arg reason "$reason" --arg now "$now" \
		'{schema_version:1,status:"authorization-gap",repository:$repo,requested_pr:$requested_pr,
		  expected_sources:$expected,observed_sources:$observed,tag_object:$tag_object,release_commit:$release_commit,
		  reason:$reason,recorded_at:$now,terminal_cleanup_evidence:false}' \
		>"${evidence_path}.tmp.$$" || return 1
	mv "${evidence_path}.tmp.$$" "$evidence_path" || return 1
	return 0
}

_full_loop_release_candidate_evidence_matches() {
	local repo="$1"
	local pr_number="$2"
	local source_merge="$3"
	local aggregate_pr="$4"
	local aggregate_merge="$5"
	local tag_name="$6"
	local tag_commit="$7"
	local evidence_type="$8"
	local evidence_path=""
	evidence_path=$(_full_loop_release_evidence_path "$repo" "$pr_number" "$evidence_type") || return 1
	[[ -f "$evidence_path" ]] || return 1
	if [[ "$evidence_type" == "aggregate" ]]; then
		_full_loop_verify_aggregate_superseded_release_evidence \
			"$evidence_path" "$repo" "$pr_number" || return 1
	elif [[ "$evidence_type" == "$_FULL_LOOP_RELEASE_EVIDENCE_RECEIPT_CONFLICT" ]]; then
		jq -e --arg repo "$repo" --argjson pr_number "$pr_number" \
			--arg source_merge "$source_merge" --argjson aggregate_pr "$aggregate_pr" \
			--arg aggregate_merge "$aggregate_merge" --arg tag_name "$tag_name" \
			--arg tag_commit "$tag_commit" --arg evidence_status "$_FULL_LOOP_RELEASE_EVIDENCE_RECEIPT_CONFLICT" \
			--arg preserved_status "$_FULL_LOOP_RELEASE_NOT_REQUESTED" '
			.schema_version == 1 and .evidence_type == "published-aggregate-terminal-receipt-conflict"
			and .status == $evidence_status and .repository == $repo and .pr_number == $pr_number
			and .source_merge == $source_merge and .aggregate_pr == $aggregate_pr
			and .aggregate_merge == $aggregate_merge and .release_tag == $tag_name
			and .release_commit == $tag_commit and .preserved_receipt_status == $preserved_status
			and (.terminal_cleanup_evidence | not)
		' "$evidence_path" >/dev/null 2>&1
		return $?
	else
		return 1
	fi
	jq -e --arg source_merge "$source_merge" --argjson aggregate_pr "$aggregate_pr" \
		--arg aggregate_merge "$aggregate_merge" --arg tag_name "$tag_name" \
		--arg tag_commit "$tag_commit" '
		.source_merge == $source_merge and .aggregate_pr == $aggregate_pr
		and .aggregate_merge == $aggregate_merge and .release_tag == $tag_name
		and .release_commit == $tag_commit
	' "$evidence_path" >/dev/null 2>&1
	return $?
}

_full_loop_write_release_receipt_conflict_evidence() {
	local repo="$1"
	local pr_number="$2"
	local source_merge="$3"
	local aggregate_pr="$4"
	local aggregate_merge="$5"
	local tag_name="$6"
	local tag_commit="$7"
	local receipt_path=""
	local receipt_status=""
	local evidence_path=""
	local now=""
	[[ "$pr_number" =~ ^[0-9]+$ && "$aggregate_pr" =~ ^[0-9]+$ ]] || return 1
	[[ "$source_merge" =~ $_FULL_LOOP_SHA40_REGEX && "$aggregate_merge" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	[[ "$tag_name" =~ $_FULL_LOOP_VERSION_TAG_REGEX && "$tag_commit" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	[[ -f "$receipt_path" ]] || return 1
	IFS= read -r receipt_status <"$receipt_path" || return 1
	[[ "$receipt_status" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" ]] || return 1
	evidence_path=$(_full_loop_release_evidence_path "$repo" "$pr_number" "$_FULL_LOOP_RELEASE_EVIDENCE_RECEIPT_CONFLICT") || return 1
	if [[ -f "$evidence_path" ]]; then
		_full_loop_release_candidate_evidence_matches "$repo" "$pr_number" "$source_merge" \
			"$aggregate_pr" "$aggregate_merge" "$tag_name" "$tag_commit" \
			"$_FULL_LOOP_RELEASE_EVIDENCE_RECEIPT_CONFLICT"
		return $?
	fi
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	mkdir -p "${evidence_path%/*}" || return 1
	jq -cn --arg repo "$repo" --argjson pr_number "$pr_number" --arg source_merge "$source_merge" \
		--argjson aggregate_pr "$aggregate_pr" --arg aggregate_merge "$aggregate_merge" \
		--arg tag_name "$tag_name" --arg tag_commit "$tag_commit" \
		--arg evidence_status "$_FULL_LOOP_RELEASE_EVIDENCE_RECEIPT_CONFLICT" \
		--arg preserved_status "$_FULL_LOOP_RELEASE_NOT_REQUESTED" --argjson terminal_cleanup_evidence false \
		--arg now "$now" '
		{schema_version:1,evidence_type:"published-aggregate-terminal-receipt-conflict",
		 status:$evidence_status,repository:$repo,pr_number:$pr_number,source_merge:$source_merge,
		 aggregate_pr:$aggregate_pr,aggregate_merge:$aggregate_merge,release_tag:$tag_name,
		 release_commit:$tag_commit,preserved_receipt_status:$preserved_status,recorded_at:$now,
		 terminal_cleanup_evidence:$terminal_cleanup_evidence}
	' >"${evidence_path}.tmp.$$" || return 1
	mv "${evidence_path}.tmp.$$" "$evidence_path" || return 1
	return 0
}

_full_loop_read_release_receipt_status() {
	local receipt_path="$1"
	local receipt_status=""
	[[ -n "$receipt_path" ]] || return 1
	if [[ ! -e "$receipt_path" && ! -L "$receipt_path" ]]; then
		printf '\n'
		return 0
	fi
	[[ -f "$receipt_path" ]] || return 1
	IFS= read -r receipt_status <"$receipt_path" || return 1
	[[ -n "$receipt_status" ]] || return 1
	printf '%s\n' "$receipt_status"
	return 0
}

_full_loop_validate_release_candidates() {
	local repo="$1"
	local source_json="$2"
	local mode="${3:-$_FULL_LOOP_RELEASE_STRICT}"
	local tag_name="${4:-}"
	local tag_commit="${5:-}"
	local source_pr=""
	local source_merge=""
	local candidate_rows=""
	local candidate_pr=""
	local candidate_merge=""
	local candidate_role=""
	local candidate_status=""
	local candidate_receipt=""
	local conflict_path=""
	source_pr=$(jq -er '.source_pr' <<<"$source_json") || return 1
	source_merge=$(jq -er '.source_merge' <<<"$source_json") || return 1
	candidate_rows=$(jq -er --arg aggregate_role "$_FULL_LOOP_RELEASE_ROLE_AGGREGATED" \
		'[{pr:.source_pr,merge:.source_merge,role:"source"}]
		+ [.aggregated_sources[] | {pr,merge,role:$aggregate_role}]
		| .[] | [.pr,.merge,.role] | @tsv' <<<"$source_json") || return 1
	if [[ "$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" ||
		"$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED" ]]; then
		[[ "$tag_name" =~ $_FULL_LOOP_VERSION_TAG_REGEX && "$tag_commit" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	elif [[ "$mode" != "$_FULL_LOOP_RELEASE_STRICT" ]]; then
		return 1
	fi
	while IFS=$'\t' read -r candidate_pr candidate_merge candidate_role; do
		[[ "$candidate_pr" =~ ^[0-9]+$ && "$candidate_merge" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
		candidate_receipt=$(_full_loop_release_receipt_path "$repo" "$candidate_pr") || return 1
		candidate_status=$(_full_loop_read_release_receipt_status "$candidate_receipt") || return 1
		case "$candidate_status" in
		"" | "$_FULL_LOOP_PHASE_FAILED") ;;
		"$_FULL_LOOP_RELEASE_NOT_REQUESTED")
			[[ "$mode" == "$_FULL_LOOP_RELEASE_STRICT" ||
				(("$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" ||
					"$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED") &&
					"$candidate_role" == "$_FULL_LOOP_RELEASE_ROLE_AGGREGATED") ]] || {
				printf 'Cannot aggregate terminal release:%s evidence for PR #%s\n' "$candidate_status" "$candidate_pr" >&2
				return 1
			}
			conflict_path=$(_full_loop_release_evidence_path "$repo" "$candidate_pr" "$_FULL_LOOP_RELEASE_EVIDENCE_RECEIPT_CONFLICT") || return 1
			if [[ -f "$conflict_path" ]]; then
				_full_loop_release_candidate_evidence_matches "$repo" "$candidate_pr" "$candidate_merge" \
					"$source_pr" "$source_merge" "$tag_name" "$tag_commit" \
					"$_FULL_LOOP_RELEASE_EVIDENCE_RECEIPT_CONFLICT" || return 1
			fi
			;;
		"$_FULL_LOOP_RELEASE_SUPERSEDED")
			[[ ( "$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" ||
				"$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED" ) &&
				"$candidate_role" == "$_FULL_LOOP_RELEASE_ROLE_AGGREGATED" ]] || return 1
			_full_loop_release_candidate_evidence_matches "$repo" "$candidate_pr" "$candidate_merge" \
				"$source_pr" "$source_merge" "$tag_name" "$tag_commit" aggregate || return 1
			;;
		"$_FULL_LOOP_RELEASE_PUBLISHED")
			[[ ( "$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" ||
				"$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED" ) &&
				"$candidate_role" == "source" ]] || return 1
			;;
		*)
			printf 'Cannot aggregate terminal release:%s evidence for PR #%s\n' "$candidate_status" "$candidate_pr" >&2
			return 1
			;;
		esac
	done <<<"$candidate_rows"
	return 0
}

_full_loop_persist_release_success() {
	local repo="$1"
	local release_path="$2"
	local source_json="$3"
	local release_source_pr="$4"
	local release_source_merge="$5"
	local mode="${6:-strict}"
	local version=""
	local tag_name=""
	local tag_commit=""
	local aggregated_rows=""
	local aggregated_pr=""
	local aggregated_merge=""
	local receipt_path=""
	local receipt_status=""
	IFS= read -r version <"$release_path/VERSION" || return 1
	tag_name="v${version}"
	tag_commit=$(git -C "$release_path" rev-parse "refs/tags/${tag_name}^{commit}" 2>/dev/null) || return 1
	aggregated_rows=$(jq -r '.aggregated_sources[] | [.pr,.merge] | @tsv' <<<"$source_json") || return 1
	while IFS=$'\t' read -r aggregated_pr aggregated_merge; do
		[[ -n "$aggregated_pr" ]] || continue
		receipt_path=$(_full_loop_release_receipt_path "$repo" "$aggregated_pr") || return 1
		receipt_status=$(_full_loop_read_release_receipt_status "$receipt_path") || return 1
		case "$receipt_status" in
		"" | "$_FULL_LOOP_PHASE_FAILED")
			_full_loop_write_superseded_release_receipt "$repo" "$aggregated_pr" "$aggregated_merge" \
				"$release_source_pr" "$release_source_merge" "$tag_name" "$tag_commit" || return 1
			;;
		"$_FULL_LOOP_RELEASE_NOT_REQUESTED")
			if [[ "$mode" == "$_FULL_LOOP_RELEASE_STRICT" ||
				"$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED" ]]; then
				_full_loop_write_superseded_release_receipt "$repo" "$aggregated_pr" "$aggregated_merge" \
					"$release_source_pr" "$release_source_merge" "$tag_name" "$tag_commit" || return 1
			else
				_full_loop_write_release_receipt_conflict_evidence "$repo" "$aggregated_pr" "$aggregated_merge" \
					"$release_source_pr" "$release_source_merge" "$tag_name" "$tag_commit" || return 1
			fi
			;;
		"$_FULL_LOOP_RELEASE_SUPERSEDED")
			[[ "$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" ||
				"$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED" ]] || return 1
			_full_loop_release_candidate_evidence_matches "$repo" "$aggregated_pr" "$aggregated_merge" \
				"$release_source_pr" "$release_source_merge" "$tag_name" "$tag_commit" aggregate || return 1
			_full_loop_update_superseded_cleanup_receipt "$repo" "$aggregated_pr" || return 1
			;;
		*) return 1 ;;
		esac
	done <<<"$aggregated_rows"
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$release_source_pr") || return 1
	receipt_status=$(_full_loop_read_release_receipt_status "$receipt_path") || return 1
	case "$receipt_status" in
	"" | "$_FULL_LOOP_PHASE_FAILED")
		_full_loop_write_release_receipt "$repo" "$release_source_pr" "$_FULL_LOOP_RELEASE_PUBLISHED" || return 1
		;;
	"$_FULL_LOOP_RELEASE_NOT_REQUESTED")
		[[ "$mode" == "$_FULL_LOOP_RELEASE_STRICT" ]] || return 1
		_full_loop_write_release_receipt "$repo" "$release_source_pr" "$_FULL_LOOP_RELEASE_PUBLISHED" || return 1
		full_loop_update_cleanup_release_status "$repo" "$release_source_pr" "$_FULL_LOOP_RELEASE_PUBLISHED" || return 1
		;;
	"$_FULL_LOOP_RELEASE_PUBLISHED")
		[[ "$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" ||
			"$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED" ]] || return 1
		;;
	*) return 1 ;;
	esac
	return 0
}

_full_loop_write_release_receipt() {
	local repo="$1"
	local pr_number="$2"
	local status="$3"
	[[ -n "$repo" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	[[ "$status" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" || "$status" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" || "$status" == "$_FULL_LOOP_PHASE_FAILED" ]] || return 1
	local receipt_path=""
	local current_status=""
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	mkdir -p "${receipt_path%/*}" || return 1
	current_status=$(_full_loop_read_release_receipt_status "$receipt_path") || return 1
	case "${current_status}:${status}" in
	"${_FULL_LOOP_RELEASE_NOT_REQUESTED}:${_FULL_LOOP_RELEASE_NOT_REQUESTED}" | \
		"${_FULL_LOOP_RELEASE_NOT_REQUESTED}:${_FULL_LOOP_RELEASE_PUBLISHED}" | \
		"${_FULL_LOOP_RELEASE_NOT_REQUESTED}:${_FULL_LOOP_RELEASE_SUPERSEDED}" | \
		"${_FULL_LOOP_RELEASE_PUBLISHED}:${_FULL_LOOP_RELEASE_PUBLISHED}" | \
		"${_FULL_LOOP_RELEASE_SUPERSEDED}:${_FULL_LOOP_RELEASE_SUPERSEDED}") ;;
	"${_FULL_LOOP_RELEASE_NOT_REQUESTED}:"* | \
		"${_FULL_LOOP_RELEASE_PUBLISHED}:"* | \
		"${_FULL_LOOP_RELEASE_SUPERSEDED}:"*)
		return 1
		;;
	esac
	printf '%s\n' "$status" >"${receipt_path}.tmp.$$" || return 1
	mv "${receipt_path}.tmp.$$" "$receipt_path" || return 1
	if [[ "$status" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" ]]; then
		local failure_path=""
		failure_path=$(_full_loop_release_evidence_path "$repo" "$pr_number" failure) || return 1
		rm -f "$failure_path" || return 1
	fi
	return 0
}

_full_loop_write_release_failure_evidence() {
	local repo="$1"
	local requested_pr="$2"
	local requested_merge="$3"
	local current_head="$4"
	local release_source_pr="${5:-}"
	local evidence_path=""
	local now=""
	[[ "$requested_pr" =~ ^[0-9]+$ ]] || return 1
	[[ -z "$release_source_pr" || "$release_source_pr" =~ ^[0-9]+$ ]] || return 1
	[[ "$requested_merge" =~ $_FULL_LOOP_SHA40_REGEX && "$current_head" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	evidence_path=$(_full_loop_release_evidence_path "$repo" "$requested_pr" failure) || return 1
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	mkdir -p "${evidence_path%/*}" || return 1
	jq -cn --arg repo "$repo" --argjson requested_pr "$requested_pr" --arg requested_merge "$requested_merge" \
		--arg release_source_pr "$release_source_pr" --arg current_head "$current_head" --arg now "$now" \
		'{schema_version:1,status:"failed",repository:$repo,requested_pr:$requested_pr,requested_merge:$requested_merge,
		  release_source_pr:(if $release_source_pr == "" then null else ($release_source_pr | tonumber) end),current_head:$current_head,recorded_at:$now}' \
		>"${evidence_path}.tmp.$$" || return 1
	mv "${evidence_path}.tmp.$$" "$evidence_path" || return 1
	_full_loop_write_release_receipt "$repo" "$requested_pr" "$_FULL_LOOP_PHASE_FAILED"
	return $?
}

_full_loop_write_superseded_release_receipt() {
	local repo="$1"
	local pr_number="$2"
	local source_merge="$3"
	local aggregate_pr="$4"
	local aggregate_merge="$5"
	local tag_name="$6"
	local tag_commit="$7"
	local evidence_path=""
	local successor_path=""
	local now=""
	[[ "$pr_number" =~ ^[0-9]+$ && "$aggregate_pr" =~ ^[0-9]+$ ]] || return 1
	[[ "$source_merge" =~ $_FULL_LOOP_SHA40_REGEX && "$aggregate_merge" =~ $_FULL_LOOP_SHA40_REGEX && "$tag_commit" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	[[ "$tag_name" =~ $_FULL_LOOP_VERSION_TAG_REGEX ]] || return 1
	evidence_path=$(_full_loop_release_evidence_path "$repo" "$pr_number" aggregate) || return 1
	successor_path=$(_full_loop_release_evidence_path "$repo" "$pr_number" successor) || return 1
	[[ ! -e "$successor_path" ]] || return 1
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	mkdir -p "${evidence_path%/*}" || return 1
	jq -cn --arg repo "$repo" --arg status "$_FULL_LOOP_RELEASE_SUPERSEDED" --argjson pr_number "$pr_number" --arg source_merge "$source_merge" \
		--argjson aggregate_pr "$aggregate_pr" --arg aggregate_merge "$aggregate_merge" \
		--arg tag "$tag_name" --arg tag_commit "$tag_commit" --arg now "$now" \
		'{schema_version:1,status:$status,repository:$repo,pr_number:$pr_number,source_merge:$source_merge,
		  aggregate_pr:$aggregate_pr,aggregate_merge:$aggregate_merge,release_tag:$tag,release_commit:$tag_commit,recorded_at:$now}' \
		>"${evidence_path}.tmp.$$" || return 1
	mv "${evidence_path}.tmp.$$" "$evidence_path" || return 1
	_full_loop_write_release_receipt "$repo" "$pr_number" "$_FULL_LOOP_RELEASE_SUPERSEDED" || return 1
	_full_loop_update_superseded_cleanup_receipt "$repo" "$pr_number"
	return $?
}

_full_loop_update_superseded_cleanup_receipt() {
	local repo="$1"
	local pr_number="$2"
	if declare -F full_loop_update_cleanup_release_status >/dev/null 2>&1; then
		full_loop_update_cleanup_release_status "$repo" "$pr_number" "$_FULL_LOOP_RELEASE_SUPERSEDED" || return 1
	fi
	return 0
}

_full_loop_verify_aggregate_superseded_release_evidence() {
	local evidence_path="$1"
	local repo="$2"
	local pr_number="$3"
	[[ "$evidence_path" == *.aggregate.json ]] || return 1
	_full_loop_validate_superseded_evidence "$evidence_path" "$repo" "$pr_number"
	return $?
}

_full_loop_verify_successor_superseded_release_evidence() {
	local evidence_path="$1"
	local repo="$2"
	local pr_number="$3"
	[[ "$evidence_path" == *.successor.json ]] || return 1
	_full_loop_validate_superseded_evidence "$evidence_path" "$repo" "$pr_number"
	return $?
}

_full_loop_superseded_release_evidence_path() {
	local repo="$1"
	local pr_number="$2"
	local aggregate_path=""
	local successor_path=""
	local evidence_path=""
	aggregate_path=$(_full_loop_release_evidence_path "$repo" "$pr_number" aggregate) || return 1
	successor_path=$(_full_loop_release_evidence_path "$repo" "$pr_number" successor) || return 1
	if [[ -f "$aggregate_path" ]]; then
		_full_loop_verify_aggregate_superseded_release_evidence \
			"$aggregate_path" "$repo" "$pr_number" || return 1
		evidence_path="$aggregate_path"
	fi
	if [[ -f "$successor_path" ]]; then
		[[ -z "$evidence_path" ]] || return 1
		_full_loop_verify_successor_superseded_release_evidence \
			"$successor_path" "$repo" "$pr_number" || return 1
		evidence_path="$successor_path"
	fi
	[[ -n "$evidence_path" ]] || return 1
	printf '%s\n' "$evidence_path"
	return 0
}

_full_loop_verify_superseded_release_receipt() {
	local repo="$1"
	local pr_number="$2"
	_full_loop_superseded_release_evidence_path "$repo" "$pr_number" >/dev/null
	return $?
}

_full_loop_write_successor_release_receipt() {
	local repo="$1"
	local source_pr="$2"
	local source_merge="$3"
	local source_tag="$4"
	local source_commit="$5"
	local source_run="$6"
	local successor_pr="$7"
	local successor_merge="$8"
	local release_tag="$9"
	shift 9
	local release_commit="$1"
	local release_run="$2"
	local aggregate_path=""
	local evidence_path=""
	local now=""
	[[ "$source_pr" =~ ^[0-9]+$ && "$successor_pr" =~ ^[0-9]+$ && "$source_pr" != "$successor_pr" ]] || return 1
	[[ "$source_merge" =~ $_FULL_LOOP_SHA40_REGEX && "$successor_merge" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	[[ "$source_commit" =~ $_FULL_LOOP_SHA40_REGEX && "$release_commit" =~ $_FULL_LOOP_SHA40_REGEX && "$source_commit" != "$release_commit" ]] || return 1
	[[ "$source_tag" =~ $_FULL_LOOP_VERSION_TAG_REGEX && "$release_tag" =~ $_FULL_LOOP_VERSION_TAG_REGEX && "$source_tag" != "$release_tag" ]] || return 1
	[[ "$source_run" =~ ^[0-9]+$ && "$release_run" =~ ^[0-9]+$ && "$source_run" -gt 0 && "$release_run" -gt 0 && "$source_run" != "$release_run" ]] || return 1
	aggregate_path=$(_full_loop_release_evidence_path "$repo" "$source_pr" aggregate) || return 1
	evidence_path=$(_full_loop_release_evidence_path "$repo" "$source_pr" successor) || return 1
	[[ ! -e "$aggregate_path" ]] || return 1
	if [[ -f "$evidence_path" ]]; then
		_full_loop_verify_successor_superseded_release_evidence \
			"$evidence_path" "$repo" "$source_pr" || return 1
		jq -e --arg source_merge "$source_merge" --arg source_tag "$source_tag" \
			--arg source_commit "$source_commit" --argjson source_run "$source_run" \
			--argjson successor_pr "$successor_pr" --arg successor_merge "$successor_merge" \
			--arg release_tag "$release_tag" --arg release_commit "$release_commit" \
			--argjson release_run "$release_run" '
			.source_merge == $source_merge and .source_release_tag == $source_tag
			and .source_release_commit == $source_commit and .source_workflow_run == $source_run
			and .successor_pr == $successor_pr and .successor_merge == $successor_merge
			and .release_tag == $release_tag and .release_commit == $release_commit
			and .release_workflow_run == $release_run
		' "$evidence_path" >/dev/null 2>&1 || return 1
	else
		now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
		mkdir -p "${evidence_path%/*}" || return 1
		jq -cn --arg repo "$repo" --arg status "$_FULL_LOOP_RELEASE_SUPERSEDED" \
			--arg evidence_type "post-publication-supersession" --argjson source_pr "$source_pr" \
			--arg source_merge "$source_merge" --arg source_tag "$source_tag" \
			--arg source_commit "$source_commit" --argjson source_run "$source_run" \
			--argjson successor_pr "$successor_pr" --arg successor_merge "$successor_merge" \
			--arg release_tag "$release_tag" --arg release_commit "$release_commit" \
			--argjson release_run "$release_run" --arg now "$now" '
			{schema_version:1,evidence_type:$evidence_type,status:$status,repository:$repo,
			 pr_number:$source_pr,source_pr:$source_pr,source_merge:$source_merge,
			 source_release_tag:$source_tag,source_release_commit:$source_commit,
			 source_workflow_run:$source_run,successor_pr:$successor_pr,successor_merge:$successor_merge,
			 release_tag:$release_tag,release_commit:$release_commit,
			 release_workflow_run:$release_run,recorded_at:$now}
		' >"${evidence_path}.tmp.$$" || return 1
		mv "${evidence_path}.tmp.$$" "$evidence_path" || return 1
	fi
	_full_loop_write_release_receipt "$repo" "$source_pr" "$_FULL_LOOP_RELEASE_SUPERSEDED" || return 1
	_full_loop_update_superseded_cleanup_receipt "$repo" "$source_pr"
	return $?
}

_full_loop_persist_release_status() {
	local status="$1"
	local repo=""
	[[ "$status" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" || "$status" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" || "$status" == "$_FULL_LOOP_PHASE_FAILED" ]] || return 1
	if [[ -f "$STATE_FILE" ]]; then
		save_state "${CURRENT_PHASE:-${PHASE:-postflight}}" "$SAVED_PROMPT" "${PR_NUMBER:-}" "${STARTED_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
	fi
	[[ "${PR_NUMBER:-}" =~ ^[0-9]+$ ]] || return 0
	repo=$(_full_loop_resolve_repo "${AIDEVOPS_FULL_LOOP_REPO:-}") || return 1
	_full_loop_write_release_receipt "$repo" "$PR_NUMBER" "$status"
	return $?
}

_full_loop_invoke_authorized_release() {
	[[ "${PR_NUMBER:-}" =~ ^[0-9]+$ ]] || {
		print_error "Authorized release requires a persisted PR number"
		return 1
	}
	local reconciliation_status=0
	_full_loop_reconcile_detached_publication_receipt || reconciliation_status=$?
	case "$reconciliation_status" in
	0) return 0 ;;
	2)
		print_error "release:published receipt could not be reconciled into lifecycle state"
		return 1
		;;
	esac
	local runner="${AIDEVOPS_FULL_LOOP_RELEASE_RUNNER:-${SCRIPT_DIR}/full-loop-release-helper.sh}"
	[[ -x "$runner" ]] || {
		print_error "Authorized release runner is unavailable: $runner"
		return 1
	}
	AIDEVOPS_RELEASE_INTENT_TRUSTED=1 \
		AIDEVOPS_TRUSTED_ISSUE_PRIORITY="${AIDEVOPS_TRUSTED_ISSUE_PRIORITY:-}" \
		AIDEVOPS_RELEASE_EXPECTED_SOURCES="${RELEASE_EXPECTED_SOURCES:-}" \
		"$runner" "$RELEASE_TYPE" "$PR_NUMBER" "$DEPLOYMENT_SCOPE"
	return $?
}
emit_deploy_phase() {
	print_phase "Deploy" "AI deploys changes"
	[[ "${RELEASE_INTENT:-false}" == "true" ]] || {
		print_info "release:not-requested — deployment skipped"
		return 0
	}
	[[ "$RELEASE_STATUS" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$RELEASE_STATUS" == "$_FULL_LOOP_RELEASE_SUPERSEDED" ]] && {
		print_info "release:${RELEASE_STATUS} — deployment completed by the release runner"
		return 0
	}
	! is_aidevops_repo && {
		print_info "Not aidevops repo, skipping deploy"
		return 0
	}
	[[ "${NO_AUTO_DEPLOY:-false}" == "true" ]] && {
		print_warning "Auto deploy disabled"
		return 0
	}
	echo "Run setup.sh per full-loop.md guidance."
}

# --- Gate Checks ---

_issue_thread_is_trusted_maintainer_only() {
	local issue_num="$1"
	local repo="$2"
	local issue_author_association="${3:-}"

	[[ -n "$issue_num" && -n "$repo" ]] || return 1
	case "$issue_author_association" in
	OWNER | MEMBER) ;;
	*)
		return 1
		;;
	esac

	local comments_json
	comments_json=$(gh api "repos/${repo}/issues/${issue_num}/comments" \
		--paginate --slurp 2>/dev/null) || return 1
	[[ -n "$comments_json" && "$comments_json" != "null" ]] || comments_json="[]"

	local untrusted_comment_count
	untrusted_comment_count=$(printf '%s' "$comments_json" | jq -r --arg array_type "array" '
		(if type == $array_type and (.[0]? | type) == $array_type then [.[][]]
		elif type == $array_type then .
		else [] end)
		| [ .[] | select((.author_association // "") as $a | ($a != "OWNER" and $a != "MEMBER")) ]
		| length
	' 2>/dev/null) || return 1
	[[ "$untrusted_comment_count" =~ ^[0-9]+$ ]] || return 1

	if [[ "$untrusted_comment_count" -eq 0 ]]; then
		return 0
	fi

	return 1
}

_linked_issue_author_allows_start() {
	local issue_num="$1"
	local repo="$2"
	local raw_issue="$3"
	local author_meta="" author_association="NONE" author_type="" author_login="" external_source="false"

	author_meta=$(printf '%s' "$raw_issue" | jq -r \
		'[.author_association // "NONE", .user.type // "", .user.login // "", (([.labels[]?.name] | index("external-contributor") != null) | tostring)] | join("|")' 2>/dev/null) || author_meta=""
	if [[ -n "$author_meta" ]]; then
		IFS='|' read -r author_association author_type author_login external_source <<<"$author_meta"
	fi
	[[ -n "$author_association" ]] || author_association="NONE"
	if [[ "$author_type" == "Bot" && "$external_source" != "true" ]]; then
		return 0
	fi

	local authority_rc=1
	if [[ "$external_source" != "true" ]] && declare -F _gh_actor_has_repo_write_authority >/dev/null 2>&1; then
		authority_rc=0
		_gh_actor_has_repo_write_authority "$repo" "$author_login" "$author_association" || authority_rc=$?
	elif [[ "$external_source" != "true" ]]; then
		authority_rc=2
	fi
	if [[ "$authority_rc" -eq 0 ]]; then
		return 0
	fi

	local approval_helper="${SCRIPT_DIR}/approval-helper.sh"
	local verification=""
	if [[ -x "$approval_helper" ]]; then
		verification=$("$approval_helper" verify "$issue_num" "$repo" 2>/dev/null) || true
	fi
	if [[ "$verification" == "VERIFIED" ]]; then
		return 0
	fi
	if [[ "$verification" == "NO_APPROVAL" ]]; then
		#aidevops:trust-boundary -- containment is best-effort; this live gate is authoritative.
		if declare -F gh_issue_edit_safe >/dev/null 2>&1; then
			gh_issue_edit_safe "$issue_num" --repo "$repo" \
				--add-label "needs-maintainer-review" >/dev/null 2>&1 || true
		else
			gh issue edit "$issue_num" --repo "$repo" \
				--add-label "needs-maintainer-review" >/dev/null 2>&1 || true
		fi
	fi

	_FULL_LOOP_LINKED_AUTHOR_GATE_REASON="author_association=${author_association}, external_source=${external_source}, authority=${AIDEVOPS_GH_ACTOR_AUTHORITY_REASON:-unknown}, approval=${verification:-unavailable}"
	return 1
}

_linked_issue_trust_blocks_start() {
	local issue_num="$1"
	local repo="$2"
	local raw_issue="$3"
	local labels="$4"
	local issue_author_association="$5"
	_FULL_LOOP_LINKED_TRUST_BLOCKER_REASON=""

	if printf '%s\n' "$labels" | grep -qxF 'needs-maintainer-review'; then
		if ! is_headless && _issue_thread_is_trusted_maintainer_only \
			"$issue_num" "$repo" "$issue_author_association"; then
			print_info "Issue #${issue_num} has needs-maintainer-review, but this interactive thread is maintainer-only; continuing without treating NMR as a maintainer hold."
			return 1
		fi
		_FULL_LOOP_LINKED_TRUST_BLOCKER_REASON="Issue #${issue_num} has \`needs-maintainer-review\` label and is not a trusted maintainer-only interactive thread — a maintainer must approve before work begins.\n"
		return 0
	fi

	if ! _linked_issue_author_allows_start "$issue_num" "$repo" "$raw_issue"; then
		_FULL_LOOP_LINKED_TRUST_BLOCKER_REASON="Issue #${issue_num} does not have trusted author authority or verified maintainer approval (${_FULL_LOOP_LINKED_AUTHOR_GATE_REASON:-unknown}) — work cannot begin merely because the review label is absent.\n"
		return 0
	fi
	return 1
}

_linked_issue_structural_blocker_reasons() {
	local issue_num="$1"
	local repo="$2"
	local dedup_helper="${SCRIPT_DIR}/dispatch-dedup-helper.sh"
	local found=false

	[[ -x "$dedup_helper" ]] || return 1

	local dedup_out
	dedup_out=$("$dedup_helper" enumerate-blockers "$issue_num" "$repo" "${AIDEVOPS_SESSION_USER:-${USER:-}}" 2>/dev/null || true)
	local _blocker_line
	while IFS= read -r _blocker_line; do
		[[ -z "$_blocker_line" ]] && continue
		case "$_blocker_line" in
		*PARENT_TASK_BLOCKED*)
			found=true
			printf 'Issue #%s carries the %s label (decomposition tracker, not a worker target). Decompose into child phase issues, or remove the label if this is no longer a parent.\n' "$issue_num" "\`parent-task\`"
			;;
		*NO_AUTO_DISPATCH_BLOCKED*)
			# no-auto-dispatch is a worker-routing hold, not a prohibition on
			# explicitly authorized interactive implementation. Keep the hold intact
			# so Pulse cannot dispatch a parallel worker while local work proceeds.
			if [[ "${AIDEVOPS_INTERACTIVE_ISSUE_IMPLEMENTATION:-0}" == "1" ]] && ! is_headless; then
				continue
			fi
			found=true
			printf 'Issue #%s carries the %s label (explicit worker-dispatch hold). Remove the label only if you intentionally want worker dispatch, or use the interactive issue-start implementation path.\n' "$issue_num" "\`no-auto-dispatch\`"
			;;
		*HOLD_FOR_REVIEW_BLOCKED*)
			found=true
			printf 'Issue #%s carries the %s label (maintainer-requested review hold). Remove the label when the hold is resolved.\n' "$issue_num" "\`hold-for-review\`"
			;;
		esac
	done <<<"$dedup_out"

	[[ "$found" == "true" ]] || return 1
	return 0
}

# Pre-start maintainer gate check (GH#17810, t2890).
# Extracts the first issue number from the prompt and verifies the linked
# issue does not have needs-maintainer-review label or, for headless workers,
# a missing assignee (GH#17810). Interactive maintainer sessions may self-claim
# an unassigned issue supplied directly in the prompt (GH#22854). Then inherits
# the pulse-side structural dispatch gates via
# dispatch-dedup-helper.sh::enumerate-blockers so /full-loop honors hard
# structural holds. no-auto-dispatch remains enforced for workers while the
# explicit interactive issue-start path may implement locally without removing
# the worker-routing hold. Mirrors .github/workflows/maintainer-gate.yml.
#
# Returns:
#   0 — gate passes (safe to start)
#   1 — gate blocked (do NOT start work)
#
# Skips gracefully when:
#   - No issue number found in prompt (not all tasks have linked issues)
#   - Issue is closed (already reviewed)
# Once a prompt resolves to an issue and repository, metadata lookup failures
# block rather than silently converting unknown input into trusted input.
_check_linked_issue_gate() {
	local prompt="$1"
	local repo="${2:-}"

	# Extract first issue number from prompt — look for #NNN or issue/NNN patterns
	local issue_num
	issue_num=$(echo "$prompt" | grep -oE '#[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
	if [[ -z "$issue_num" ]]; then
		# No issue number in prompt — skip gate (not all tasks reference issues)
		return 0
	fi

	# Resolve repo from git remote if not provided
	if [[ -z "$repo" ]]; then
		repo=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||;s|\.git$||' || true)
	fi
	if [[ -z "$repo" ]]; then
		if is_headless; then
			print_error "Maintainer gate pre-check: cannot resolve repository for linked issue #${issue_num}"
			return 1
		fi
		return 0
	fi

	# Fetch issue data. Every mode fails closed because the prompt has already
	# supplied both an issue reference and repository context.
	local raw_issue
	raw_issue=$(gh api "repos/${repo}/issues/${issue_num}" 2>/dev/null) || {
		print_error "Maintainer gate pre-check: could not fetch linked issue #${issue_num} — refusing start"
		return 1
	}

	local state labels assignees issue_author_association
	state=$(echo "$raw_issue" | jq -r '.state' 2>/dev/null || echo "unknown")
	labels=$(echo "$raw_issue" | jq -r '[.labels[]?.name] | .[]' 2>/dev/null || true)
	assignees=$(echo "$raw_issue" | jq -r '[.assignees[]?.login] | .[]' 2>/dev/null || true)
	issue_author_association=$(echo "$raw_issue" | jq -r '.author_association // ""' 2>/dev/null || true)

	# Skip closed issues — they've already been reviewed
	if [[ "$state" == "closed" ]]; then
		return 0
	fi

	local blocked=false reasons=""

	# Check 1: labels are advisory; author authority or signed approval is also
	# required when the creation-time review label is absent.
	if _linked_issue_trust_blocks_start "$issue_num" "$repo" "$raw_issue" \
		"$labels" "$issue_author_association"; then
		blocked=true
		reasons="${reasons}${_FULL_LOOP_LINKED_TRUST_BLOCKER_REASON}"
	fi

	# Check 2: no assignee (exempt quality-debt issues per GH#6623).
	# GH#22854: OWNER/MEMBER interactive sessions can fix an unassigned issue by
	# claiming it immediately after this gate. Keep the stricter block for
	# headless workers so dispatched automation still requires an explicit claim.
	if [[ -z "$assignees" ]]; then
		if ! is_headless; then
			: # interactive self-claim path handles this below
		elif echo "$labels" | grep -q 'quality-debt'; then
			: # exempt
		else
			blocked=true
			reasons="${reasons}Issue #${issue_num} has no assignee — assign the issue before starting work.\n"
		fi
	fi

	# Check 3 (t2890, t2894): inherit pulse-side structural dispatch gates by
	# calling dispatch-dedup-helper.sh::enumerate-blockers — which runs ALL
	# unconditional label checks in a single pass and emits each matching
	# signal on a separate line. Replaces the former is-assigned call + case
	# statement that short-circuited on the first match, so users now see
	# every blocker in one /full-loop invocation instead of one per retry.
	# Cost-budget, hydration window, and ownership-by-other are intentionally
	# out of scope (need nuanced interactive UX). Fail-open on missing helper
	# or empty stdout. Author/API trust checks above remain independently fail-closed.
	local structural_reasons
	if structural_reasons=$(_linked_issue_structural_blocker_reasons "$issue_num" "$repo"); then
		blocked=true
		reasons="${reasons}${structural_reasons}"
	fi

	if [[ "$blocked" == "true" ]]; then
		print_error "Maintainer gate pre-check BLOCKED — cannot start work:"
		printf '%b' "$reasons" >&2
		printf "To unblock: address the blocker labels above; use signed approval only for \`needs-maintainer-review\`, and remove \`hold-for-review\` only when the maintainer hold is resolved.\n" >&2
		return 1
	fi

	return 0
}

# Interactive claim (t2056 hardening): structurally enforce issue ownership
# when an interactive session starts a full-loop. Extracts issue number from
# the prompt and calls interactive-session-helper.sh claim, which applies
# status:in-review + self-assigns + posts a claim comment. This replaces
# prompt-only enforcement that was missed in practice (GH#18775 incident).
#
# Skips silently when:
#   - Headless mode (workers have their own dispatch claim)
#   - No issue number in prompt
#   - interactive-session-helper.sh not available
#
# Always returns 0 — claim failure is non-blocking (warn-and-continue).
_auto_claim_interactive() {
	local prompt="$1"

	# Skip in headless — workers use dispatch claims, not interactive claims
	if is_headless; then
		return 0
	fi
	# Opt-out for scripted bulk worktree operations
	if [[ -n "${AIDEVOPS_SKIP_AUTO_CLAIM:-}" ]]; then
		return 0
	fi

	# Extract issue number (same pattern as _check_linked_issue_gate)
	local issue_num
	issue_num=$(echo "$prompt" | grep -oE '#[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
	if [[ -z "$issue_num" ]]; then
		return 0
	fi

	# Resolve repo slug
	local repo
	repo=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||;s|\.git$||' || true)
	if [[ -z "$repo" ]]; then
		return 0
	fi

	# Call the interactive claim helper — it handles offline, idempotency,
	# maintainer-permission checks, self-assign, status label, stamp, and
	# claim comment internally. External upstream repos skip the claim path.
	local helper="${SCRIPT_DIR}/interactive-session-helper.sh"
	if [[ -x "$helper" ]]; then
		local -a claim_args=(claim "$issue_num" "$repo" --worktree "$(pwd)")
		if [[ "${AIDEVOPS_INTERACTIVE_ISSUE_IMPLEMENTATION:-0}" == "1" ]]; then
			claim_args+=(--implementing)
		fi
		"$helper" "${claim_args[@]}" || true
		print_info "Interactive claim checked: #${issue_num} in ${repo}"
	else
		print_warning "interactive-session-helper.sh not found — skipping interactive claim"
	fi
	return 0
}

# --- Start/Resume Infrastructure ---

# Initialize option variables with defaults so set -u doesn't crash on
# export when flags are not passed.
_init_start_defaults() {
	MAX_TASK_ITERATIONS="${MAX_TASK_ITERATIONS:-$DEFAULT_MAX_TASK_ITERATIONS}"
	MAX_PREFLIGHT_ITERATIONS="${MAX_PREFLIGHT_ITERATIONS:-$DEFAULT_MAX_PREFLIGHT_ITERATIONS}"
	MAX_PR_ITERATIONS="${MAX_PR_ITERATIONS:-$DEFAULT_MAX_PR_ITERATIONS}"
	SKIP_PREFLIGHT="${SKIP_PREFLIGHT:-false}"
	SKIP_POSTFLIGHT="${SKIP_POSTFLIGHT:-false}"
	SKIP_RUNTIME_TESTING="${SKIP_RUNTIME_TESTING:-false}"
	NO_AUTO_PR="${NO_AUTO_PR:-false}"
	NO_AUTO_DEPLOY="${NO_AUTO_DEPLOY:-false}"
	if [[ "${AIDEVOPS_RELEASE_INTENT_TRUSTED:-}" == "1" ]]; then
		RELEASE_INTENT="true"
	else
		RELEASE_INTENT="${RELEASE_INTENT:-false}"
	fi
	RELEASE_TYPE="${RELEASE_TYPE:-${AIDEVOPS_RELEASE_TYPE:-patch}}"
	DEPLOYMENT_SCOPE="${DEPLOYMENT_SCOPE:-${AIDEVOPS_RELEASE_DEPLOY_SCOPE:-incremental}}"
	RELEASE_EXPECTED_SOURCES="${RELEASE_EXPECTED_SOURCES:-${AIDEVOPS_RELEASE_EXPECTED_SOURCES:-}}"
	RELEASE_STATUS="${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}"
	DRY_RUN="${DRY_RUN:-false}"
	_BACKGROUND=false
	return 0
}

# Parse start subcommand options. Sets global option variables and _BACKGROUND.
# Arguments: all remaining args after the prompt string.
# Returns: 0 on success, 1 on unknown option.
_parse_start_options() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--max-task-iterations)
			MAX_TASK_ITERATIONS="$2"
			shift 2
			;;
		--max-preflight-iterations)
			MAX_PREFLIGHT_ITERATIONS="$2"
			shift 2
			;;
		--max-pr-iterations)
			MAX_PR_ITERATIONS="$2"
			shift 2
			;;
		--skip-preflight)
			SKIP_PREFLIGHT=true
			shift
			;;
		--skip-postflight)
			SKIP_POSTFLIGHT=true
			shift
			;;
		--skip-runtime-testing)
			SKIP_RUNTIME_TESTING=true
			shift
			;;
		--no-auto-pr)
			NO_AUTO_PR=true
			shift
			;;
		--no-auto-deploy)
			NO_AUTO_DEPLOY=true
			shift
			;;
		--release-intent)
			RELEASE_INTENT=true
			RELEASE_STATUS=authorized
			shift
			;;
		--release-type)
			RELEASE_TYPE="${2:-}"
			case "$RELEASE_TYPE" in patch | minor | major) ;; *)
				print_error "Invalid release type: $RELEASE_TYPE"
				return 1
				;;
			esac
			RELEASE_INTENT=true
			RELEASE_STATUS=authorized
			shift 2
			;;
		--deployment-scope)
			DEPLOYMENT_SCOPE="${2:-}"
			case "$DEPLOYMENT_SCOPE" in incremental | full) ;; *)
				print_error "Invalid deployment scope: $DEPLOYMENT_SCOPE"
				return 1
				;;
			esac
			shift 2
			;;
		--release-expected-sources)
			RELEASE_EXPECTED_SOURCES="${2:-}"
			[[ -n "$RELEASE_EXPECTED_SOURCES" ]] || {
				print_error "Release expected sources cannot be empty"
				return 1
			}
			RELEASE_INTENT=true
			RELEASE_STATUS=authorized
			shift 2
			;;
		--headless)
			HEADLESS=true
			shift
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--background | --bg)
			_BACKGROUND=true
			shift
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done
	return 0
}

# Launch the loop asynchronously in the local session via nohup.
# Arguments: $1 — prompt string.
_launch_background() {
	local prompt="$1"
	mkdir -p "$STATE_DIR"
	# The shell helper is a lifecycle coordinator, not an AI executor. Unless a
	# runtime adapter explicitly supplies an executor, persist an honest
	# initialized-only checkpoint instead of launching a child that prints one
	# prompt, exits, and is then incorrectly reported as a running loop.
	if [[ -z "${AIDEVOPS_FULL_LOOP_EXECUTOR:-}" ]]; then
		EXECUTOR_STATUS="$_FULL_LOOP_EXECUTOR_INITIALIZED"
		EXECUTOR_PID=""
		NEXT_ACTION="attach-executor-or-resume"
		PHASE_STATUS="$_FULL_LOOP_PHASE_WAITING"
		save_state "$_FULL_LOOP_PHASE_TASK" "$prompt" "" "${STARTED_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
		_full_loop_append_event "executor.initialized" "$_FULL_LOOP_EXECUTOR_INITIALIZED"
		print_warning "Background loop initialized, but no executor was launched."
		printf 'FULL_LOOP_START_RESULT=initialized-only\n'
		return 0
	fi
	export AIDEVOPS_RELEASE_TYPE="$RELEASE_TYPE" AIDEVOPS_RELEASE_DEPLOY_SCOPE="$DEPLOYMENT_SCOPE"
	export MAX_TASK_ITERATIONS MAX_PREFLIGHT_ITERATIONS MAX_PR_ITERATIONS
	export SKIP_PREFLIGHT SKIP_POSTFLIGHT SKIP_RUNTIME_TESTING NO_AUTO_PR NO_AUTO_DEPLOY RELEASE_INTENT RELEASE_TYPE DEPLOYMENT_SCOPE RELEASE_STATUS FULL_LOOP_HEADLESS="$HEADLESS"
	local heartbeat_file="${STATE_DIR}/full-loop.heartbeat"
	export AIDEVOPS_FULL_LOOP_RUN_ID="$RUN_ID"
	export AIDEVOPS_FULL_LOOP_HEARTBEAT_FILE="$heartbeat_file"
	nohup "$AIDEVOPS_FULL_LOOP_EXECUTOR" "$0" "$prompt" >"${STATE_DIR}/full-loop.log" 2>&1 &
	EXECUTOR_PID="$!"
	EXECUTOR_IDENTITY="${AIDEVOPS_FULL_LOOP_EXECUTOR##*/}"
	echo "$EXECUTOR_PID" >"${STATE_DIR}/full-loop.pid"
	local handshake_attempt=0
	local handshake_limit="${AIDEVOPS_FULL_LOOP_HANDSHAKE_ATTEMPTS:-100}"
	[[ "$handshake_limit" =~ ^[1-9][0-9]*$ ]] || handshake_limit=100
	local heartbeat_run=""
	while [[ "$handshake_attempt" -lt "$handshake_limit" ]]; do
		handshake_attempt=$((handshake_attempt + 1))
		if [[ -f "$heartbeat_file" ]]; then
			read -r heartbeat_run HEARTBEAT_AT <"$heartbeat_file" || true
			[[ "$heartbeat_run" == "$RUN_ID" ]] && break
		fi
		kill -0 "$EXECUTOR_PID" 2>/dev/null || break
		sleep 0.1
	done
	if kill -0 "$EXECUTOR_PID" 2>/dev/null && [[ "$heartbeat_run" == "$RUN_ID" ]]; then
		EXECUTOR_STATUS="$_FULL_LOOP_PHASE_RUNNING"
		HEARTBEAT_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		NEXT_ACTION="monitor"
		PHASE_STATUS="$_FULL_LOOP_PHASE_RUNNING"
		save_state "$_FULL_LOOP_PHASE_TASK" "$prompt" "" "${STARTED_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
		_full_loop_append_event "executor.started" "$_FULL_LOOP_PHASE_RUNNING"
		print_success "Background executor started (PID: ${EXECUTOR_PID}). Use 'status' or 'logs' to monitor."
		printf 'FULL_LOOP_START_RESULT=running\n'
		return 0
	fi
	kill "$EXECUTOR_PID" 2>/dev/null || true
	EXECUTOR_STATUS="$_FULL_LOOP_EXECUTOR_INITIALIZED"
	EXECUTOR_PID=""
	NEXT_ACTION="attach-executor-or-resume"
	PHASE_STATUS="$_FULL_LOOP_PHASE_WAITING"
	save_state "$_FULL_LOOP_PHASE_TASK" "$prompt" "" "${STARTED_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
	_full_loop_append_event "executor.start_failed" "$_FULL_LOOP_EXECUTOR_INITIALIZED"
	print_warning "Background executor exited before liveness could be verified."
	printf 'FULL_LOOP_START_RESULT=initialized-only\n'
	return 0
}

_full_loop_iso_epoch() {
	local timestamp="$1"
	local epoch=""
	epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$timestamp" '+%s' 2>/dev/null || true)
	if [[ -z "$epoch" ]]; then
		epoch=$(date -u -d "$timestamp" '+%s' 2>/dev/null || true)
	fi
	[[ "$epoch" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$epoch"
	return 0
}

_full_loop_acquire_transition_lock() {
	local lock_file="${STATE_DIR}/full-loop-transition.lock"
	local reclaim_dir="${lock_file}.reclaim"
	local current_token=""
	if [[ -n "$FULL_LOOP_TRANSITION_LOCK_TOKEN" && -f "$lock_file" ]]; then
		current_token=$(<"$lock_file")
		if [[ "$current_token" == "$FULL_LOOP_TRANSITION_LOCK_TOKEN" ]]; then
			FULL_LOOP_TRANSITION_LOCK_DEPTH=$((FULL_LOOP_TRANSITION_LOCK_DEPTH + 1))
			return 0
		fi
	fi
	mkdir -p "$STATE_DIR" || return 1
	local attempt=0 candidate="" token="" owner_pid=""
	while [[ "$attempt" -lt 2 ]]; do
		attempt=$((attempt + 1))
		candidate=$(mktemp "${STATE_DIR}/.full-loop-transition.XXXXXX") || return 1
		token="$$:$(date +%s):${RANDOM}"
		printf '%s\n' "$token" >"$candidate"
		if ln "$candidate" "$lock_file" 2>/dev/null; then
			rm -f "$candidate"
			FULL_LOOP_TRANSITION_LOCK_TOKEN="$token"
			FULL_LOOP_TRANSITION_LOCK_DEPTH=1
			return 0
		fi
		rm -f "$candidate"
		current_token=$(cat "$lock_file" 2>/dev/null || true)
		owner_pid=${current_token%%:*}
		if [[ "$current_token" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
			print_error "Another lifecycle transition owns the full-loop state lock (PID: ${owner_pid})"
			return 1
		fi
		mkdir "$reclaim_dir" 2>/dev/null || return 1
		if [[ "$(cat "$lock_file" 2>/dev/null || true)" == "$current_token" ]]; then
			rm -f "$lock_file"
		fi
		rmdir "$reclaim_dir" 2>/dev/null || true
	done
	print_error "Could not acquire the full-loop state transition lock"
	return 1
}

_full_loop_release_transition_lock() {
	local lock_file="${STATE_DIR}/full-loop-transition.lock"
	[[ "$FULL_LOOP_TRANSITION_LOCK_DEPTH" -gt 0 ]] || return 0
	FULL_LOOP_TRANSITION_LOCK_DEPTH=$((FULL_LOOP_TRANSITION_LOCK_DEPTH - 1))
	[[ "$FULL_LOOP_TRANSITION_LOCK_DEPTH" -eq 0 ]] || return 0
	local current_token=""
	[[ -f "$lock_file" ]] && current_token=$(<"$lock_file")
	if [[ -n "$FULL_LOOP_TRANSITION_LOCK_TOKEN" && "$current_token" == "$FULL_LOOP_TRANSITION_LOCK_TOKEN" ]]; then
		rm -f "$lock_file"
	fi
	FULL_LOOP_TRANSITION_LOCK_TOKEN=""
	return 0
}

# --- Lifecycle Commands ---

_cmd_start_locked() {
	local prompt="$1"
	shift

	_init_start_defaults
	_parse_start_options "$@" || return 1
	if [[ "$RELEASE_INTENT" == "true" && "$HEADLESS" != "true" ]]; then
		export AIDEVOPS_RELEASE_INTENT_TRUSTED=1
	fi
	export AIDEVOPS_RELEASE_TYPE="$RELEASE_TYPE" AIDEVOPS_RELEASE_DEPLOY_SCOPE="$DEPLOYMENT_SCOPE"

	if [[ "${AIDEVOPS_INTERACTIVE_ISSUE_IMPLEMENTATION:-0}" == "1" ]] && is_headless; then
		print_error "Interactive issue implementation cannot enter headless/remote worker routing"
		return 1
	fi

	[[ -z "$prompt" ]] && {
		print_error "Usage: full-loop-helper.sh start \"<prompt>\" [options]"
		return 1
	}
	is_loop_active && {
		print_warning "Loop already active. Use 'resume' or 'cancel'."
		return 1
	}
	is_on_feature_branch || {
		print_error "Must be in a safe linked worktree"
		return 1
	}

	# Pre-start maintainer gate check (GH#17810/GH#22854): block if linked issue
	# has needs-maintainer-review label; in headless mode also block missing
	# assignee. Interactive sessions may claim an unassigned maintainer-supplied
	# issue below instead of treating the missing assignment as fatal.
	_check_linked_issue_gate "$prompt" || return 1

	# Interactive claim (t2056 hardening): when not headless, automatically
	# claim the linked issue so the pulse cannot dispatch a parallel worker
	# during the window between start and PR creation. This closes the race
	# that prompt-only enforcement missed (GH#18775 incident).
	_auto_claim_interactive "$prompt"

	printf "\n${BOLD}${BLUE}=== FULL DEVELOPMENT LOOP - STARTING ===${NC}\n  Task: %s\n  Branch: %s | Headless: %s\n\n" \
		"$prompt" "$(get_current_branch)" "$HEADLESS"
	[[ "${DRY_RUN:-false}" == "true" ]] && {
		print_info "Dry run - no changes made"
		return 0
	}

	PHASE_STATUS="$_FULL_LOOP_PHASE_WAITING"
	PHASE_ATTEMPT=1
	PHASE_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	NEXT_ACTION="complete-task-development"
	EXECUTOR_STATUS="$_FULL_LOOP_EXECUTOR_INITIALIZED"
	save_state "$_FULL_LOOP_PHASE_TASK" "$prompt"
	SAVED_PROMPT="$prompt"
	_full_loop_append_event "phase.started" "$_FULL_LOOP_PHASE_WAITING"

	if [[ "$_BACKGROUND" == "true" ]]; then
		_launch_background "$prompt"
		return 0
	fi
	emit_task_phase "$prompt"
}

cmd_start() {
	_full_loop_acquire_transition_lock || return 1
	local status=0
	_cmd_start_locked "$@" || status=$?
	_full_loop_release_transition_lock
	return "$status"
}

# Phase transition map: current -> next phase + emit function
_next_phase() {
	case "$1" in
	task) echo "preflight emit_preflight_phase" ;;
	preflight) echo "pr-create emit_pr_create_phase" ;;
	pr-create) echo "pr-review emit_pr_review_phase" ;;
	pr-review) echo "postflight emit_postflight_phase" ;;
	postflight) echo "deploy emit_deploy_phase" ;;
	deploy) echo "complete cmd_complete" ;;
	complete) echo "complete cmd_complete" ;;
	*) return 1 ;;
	esac
}

cmd_resume() {
	is_loop_active || {
		print_error "No active loop to resume"
		return 1
	}
	_full_loop_acquire_transition_lock || return 1
	load_state || {
		_full_loop_release_transition_lock
		return 1
	}
	print_info "Resuming from phase: $CURRENT_PHASE"
	MANUAL_RESUME_COUNT=$((MANUAL_RESUME_COUNT + 1))
	PHASE_STATUS="$_FULL_LOOP_PHASE_COMPLETED"
	PHASE_ENDED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	TERMINAL_EVIDENCE="manual-resume"
	_full_loop_append_event "phase.completed" "$_FULL_LOOP_PHASE_COMPLETED"
	local transition
	transition=$(_next_phase "$CURRENT_PHASE") || {
		print_error "Unknown phase: $CURRENT_PHASE"
		_full_loop_release_transition_lock
		return 1
	}
	local next_phase="${transition%% *}" emit_fn="${transition#* }"
	PHASE_STATUS="$_FULL_LOOP_PHASE_RUNNING"
	PHASE_ATTEMPT=1
	PHASE_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	PHASE_ENDED_AT=""
	NEXT_ACTION="run-${next_phase}"
	TERMINAL_EVIDENCE=""
	save_state "$next_phase" "$SAVED_PROMPT" "${PR_NUMBER:-}" "$STARTED_AT"
	CURRENT_PHASE="$next_phase"
	_full_loop_append_event "phase.started" "$_FULL_LOOP_PHASE_RUNNING"
	if ! "$emit_fn"; then
		PHASE_STATUS="$_FULL_LOOP_PHASE_FAILED"
		NEXT_ACTION="retry-${next_phase}"
		_full_loop_append_event "phase.failed" "$_FULL_LOOP_PHASE_FAILED"
		save_state "$next_phase" "$SAVED_PROMPT" "${PR_NUMBER:-}" "$STARTED_AT"
		_full_loop_release_transition_lock
		return 1
	fi
	PHASE_STATUS="$_FULL_LOOP_PHASE_WAITING"
	NEXT_ACTION="complete-${next_phase}"
	save_state "$next_phase" "$SAVED_PROMPT" "${PR_NUMBER:-}" "$STARTED_AT"
	_full_loop_release_transition_lock
	return 0
}

_full_loop_record_phase() {
	local phase="$1"
	local pr_number="$2"
	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 1
	[[ -f "$STATE_FILE" ]] || return 0
	_full_loop_acquire_transition_lock || return 1
	load_state || {
		_full_loop_release_transition_lock
		return 1
	}
	PR_NUMBER="$pr_number"
	if ! save_state "$phase" "$SAVED_PROMPT" "$PR_NUMBER" "$STARTED_AT"; then
		_full_loop_release_transition_lock
		return 1
	fi
	_full_loop_release_transition_lock
	return 0
}

_full_loop_record_merged_pr() {
	local pr_number="$1"
	_full_loop_record_phase "pr-review" "$pr_number"
	return $?
}

cmd_status() {
	is_loop_active || {
		if [[ "${1:-}" == "--json" ]]; then
			printf '{"active":false,"executor_status":"inactive","executor_completion_state":"inactive","resource_cleanup_state":"%s"}\n' "$_FULL_LOOP_RESOURCE_NONE"
			return 0
		fi
		echo "No active full loop"
		return 0
	}
	load_state
	local observed_status="$EXECUTOR_STATUS"
	local executor_completion_state="$_FULL_LOOP_EXECUTOR_IN_PROGRESS"
	local resource_cleanup_state="$_FULL_LOOP_RESOURCE_NONE"
	local cleanup_worktree=""
	local cleanup_receipt=""
	if [[ "$observed_status" == "$_FULL_LOOP_PHASE_RUNNING" ]]; then
		local observed_command=""
		local heartbeat_file="${STATE_DIR}/full-loop.heartbeat"
		local heartbeat_run="" heartbeat_timestamp=""
		local heartbeat_epoch=0 now_epoch=0 max_heartbeat_age="${AIDEVOPS_FULL_LOOP_HEARTBEAT_MAX_AGE_SECONDS:-120}"
		[[ -f "$heartbeat_file" ]] && read -r heartbeat_run heartbeat_timestamp <"$heartbeat_file" || true
		heartbeat_epoch=$(_full_loop_iso_epoch "$heartbeat_timestamp" 2>/dev/null || printf '0')
		now_epoch=$(date +%s)
		[[ "$max_heartbeat_age" =~ ^[1-9][0-9]*$ ]] || max_heartbeat_age=120
		[[ "$EXECUTOR_PID" =~ ^[0-9]+$ ]] && observed_command=$(ps -p "$EXECUTOR_PID" -o command= 2>/dev/null || true)
		if [[ ! "$EXECUTOR_PID" =~ ^[0-9]+$ ]] || ! kill -0 "$EXECUTOR_PID" 2>/dev/null ||
			[[ -z "$EXECUTOR_IDENTITY" || "$observed_command" != *"$EXECUTOR_IDENTITY"* || "$heartbeat_run" != "$RUN_ID" ]] ||
			[[ "$heartbeat_epoch" -eq 0 || $((now_epoch - heartbeat_epoch)) -gt "$max_heartbeat_age" ]]; then
			observed_status="stale"
		fi
	fi
	if [[ "${PR_NUMBER:-}" =~ ^[0-9]+$ ]]; then
		local status_repo=""
		status_repo=$(_full_loop_resolve_repo "${AIDEVOPS_FULL_LOOP_REPO:-}" 2>/dev/null || true)
		if [[ -n "$status_repo" ]] && declare -F _full_loop_cleanup_receipt_path >/dev/null 2>&1; then
			cleanup_receipt=$(_full_loop_cleanup_receipt_path "$status_repo" "$PR_NUMBER" 2>/dev/null || true)
		fi
	fi
	if [[ -n "$cleanup_receipt" && -f "$cleanup_receipt" ]]; then
		executor_completion_state=$(jq -r --arg fallback "$_FULL_LOOP_EXECUTOR_IN_PROGRESS" '.executor_completion_state // $fallback' "$cleanup_receipt" 2>/dev/null || printf '%s' "$_FULL_LOOP_EXECUTOR_IN_PROGRESS")
		resource_cleanup_state=$(jq -r --arg fallback "$_FULL_LOOP_RESOURCE_NONE" '.resource_cleanup_state // $fallback' "$cleanup_receipt" 2>/dev/null || printf '%s' "$_FULL_LOOP_RESOURCE_NONE")
		cleanup_worktree=$(jq -r '.worktree // empty' "$cleanup_receipt" 2>/dev/null || true)
	fi
	if [[ "${1:-}" == "--json" ]]; then
		jq -cn --arg run_id "$RUN_ID" --arg phase "$CURRENT_PHASE" --arg phase_status "$PHASE_STATUS" \
			--arg executor_status "$observed_status" --arg next_action "$NEXT_ACTION" --arg pr_number "${PR_NUMBER:-}" \
			--arg executor_completion_state "$executor_completion_state" --arg resource_cleanup_state "$resource_cleanup_state" \
			--arg cleanup_worktree "$cleanup_worktree" \
			--arg heartbeat_at "${heartbeat_timestamp:-${HEARTBEAT_AT:-}}" \
			--argjson revision "$STATE_REVISION" --argjson attempts "$PHASE_ATTEMPT" --argjson manual_resumes "$MANUAL_RESUME_COUNT" \
			'{run_id:$run_id,phase:$phase,phase_status:$phase_status,executor_status:$executor_status,executor_completion_state:$executor_completion_state,resource_cleanup_state:$resource_cleanup_state,cleanup_worktree:$cleanup_worktree,heartbeat_at:$heartbeat_at,next_action:$next_action,pr_number:$pr_number,state_revision:$revision,phase_attempts:$attempts,manual_resumes:$manual_resumes}'
		return 0
	fi
	printf "\n${BOLD}Full Loop Status${NC}\nPhase: ${CYAN}%s${NC} | Started: %s | PR: %s | Headless: %s\nPrompt: %s\n\n" \
		"$CURRENT_PHASE" "$STARTED_AT" "${PR_NUMBER:-none}" "$HEADLESS" "$(echo "$SAVED_PROMPT" | head -3)"
	printf 'Executor: %s (%s) | Resource cleanup: %s | Phase status: %s | Attempts: %s | Next: %s\n' \
		"$observed_status" "$executor_completion_state" "$resource_cleanup_state" "$PHASE_STATUS" "$PHASE_ATTEMPT" "$NEXT_ACTION"
	return 0
}

_cmd_cancel_locked() {
	is_loop_active || {
		print_warning "No active loop to cancel"
		return 0
	}
	local pid_file="${STATE_DIR}/full-loop.pid"
	if [[ -f "$pid_file" ]]; then
		local pid
		pid=$(cat "$pid_file")
		kill -0 "$pid" 2>/dev/null && {
			kill "$pid" 2>/dev/null || true
			sleep 1
			kill -9 "$pid" 2>/dev/null || true
		}
		rm -f "$pid_file"
	fi
	rm -f "$STATE_FILE" ".agents/loop-state/ralph-loop.local.state" ".agents/loop-state/quality-loop.local.state" 2>/dev/null
	print_success "Full loop cancelled"
	return 0
}

cmd_cancel() {
	_full_loop_acquire_transition_lock || return 1
	local status=0
	_cmd_cancel_locked "$@" || status=$?
	_full_loop_release_transition_lock
	return "$status"
}

cmd_logs() {
	local log_file="${STATE_DIR}/full-loop.log" lines="${1:-50}"
	[[ -f "$log_file" ]] || {
		print_warning "No log file. Start with --background first."
		return 1
	}
	local pid_file="${STATE_DIR}/full-loop.pid"
	if [[ -f "$pid_file" ]]; then
		local pid
		pid=$(cat "$pid_file")
		kill -0 "$pid" 2>/dev/null && print_info "Running (PID: $pid)" || print_warning "Not running (was PID: $pid)"
	fi
	printf "\n${BOLD}Full Loop Logs (last %d lines)${NC}\n" "$lines"
	tail -n "$lines" "$log_file"
}

_full_loop_reconcile_published_release_receipt() {
	local repo="$1"
	local pr_number="$2"
	local receipt_path=""
	local receipt_status=""
	local previous_status="${RELEASE_STATUS:-}"
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	[[ -f "$receipt_path" ]] || return 1
	IFS= read -r receipt_status <"$receipt_path" || return 1
	[[ "$receipt_status" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$receipt_status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" ]] || return 1
	if [[ "$receipt_status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" ]]; then
		_full_loop_verify_superseded_release_receipt "$repo" "$pr_number" || return 1
	fi
	if declare -F full_loop_update_cleanup_release_status >/dev/null 2>&1; then
		full_loop_update_cleanup_release_status "$repo" "$pr_number" "$receipt_status" || return 1
	fi
	RELEASE_STATUS="$receipt_status"
	if ! save_state "${CURRENT_PHASE:-${PHASE:-complete}}" "$SAVED_PROMPT" "$pr_number" \
		"${STARTED_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"; then
		RELEASE_STATUS="$previous_status"
		return 1
	fi
	return 0
}

_full_loop_reconcile_completion_release_receipt() {
	local repo="$1"
	local pr_number="$2"
	local local_status="$3"
	local receipt_path=""
	local receipt_status=""
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	if [[ ! -f "$receipt_path" ]]; then
		[[ "$local_status" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" ]]
		return $?
	fi
	IFS= read -r receipt_status <"$receipt_path" || return 1
	case "$receipt_status" in
	"$_FULL_LOOP_RELEASE_PUBLISHED" | "$_FULL_LOOP_RELEASE_SUPERSEDED")
		_full_loop_reconcile_published_release_receipt "$repo" "$pr_number"
		return $?
		;;
	"$_FULL_LOOP_RELEASE_NOT_REQUESTED")
		[[ "$local_status" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" ]]
		return $?
		;;
	*) return 1 ;;
	esac
}

_full_loop_reconcile_detached_publication_receipt() {
	local receipt_repo=""
	local receipt_path=""
	local receipt_status=""
	[[ "${PR_NUMBER:-}" =~ ^[0-9]+$ ]] || return 1
	receipt_repo=$(_full_loop_resolve_repo "${AIDEVOPS_FULL_LOOP_REPO:-}" 2>/dev/null || true)
	[[ -n "$receipt_repo" ]] || return 1
	receipt_path=$(_full_loop_release_receipt_path "$receipt_repo" "$PR_NUMBER") || return 1
	[[ -f "$receipt_path" ]] || return 1
	IFS= read -r receipt_status <"$receipt_path" || return 1
	[[ "$receipt_status" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$receipt_status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" ]] || return 1
	_full_loop_reconcile_published_release_receipt "$receipt_repo" "$PR_NUMBER" || return 2
	return 0
}

cmd_complete() {
	load_state 2>/dev/null || {
		print_error "Cannot complete full loop without persisted lifecycle state"
		return 1
	}
	if [[ ! "${PR_NUMBER:-}" =~ ^[0-9]+$ ]]; then
		print_error "Cannot complete full loop without a verified PR number"
		return 1
	fi
	local repo=""
	repo=$(_full_loop_resolve_repo "${AIDEVOPS_FULL_LOOP_REPO:-}") || {
		print_error "Cannot resolve repository for deferred cleanup handoff"
		return 1
	}
	if [[ "${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}" == "authorized" || "${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" ]]; then
		_full_loop_reconcile_completion_release_receipt "$repo" "$PR_NUMBER" "${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}" || {
			print_error "Cleanup blocked: release:${RELEASE_STATUS} is not terminal-success"
			return 1
		}
	fi
	case "${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}" in
	failed | authorized)
		print_error "Cleanup blocked: release:${RELEASE_STATUS} is not terminal-success"
		return 1
		;;
	"$_FULL_LOOP_RELEASE_PUBLISHED" | "$_FULL_LOOP_RELEASE_SUPERSEDED" | "$_FULL_LOOP_RELEASE_NOT_REQUESTED") ;;
	*)
		print_error "Cleanup blocked: unknown release status ${RELEASE_STATUS:-missing}"
		return 1
		;;
	esac
	local current_root=""
	current_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
	local current_branch=""
	local owner_pid=""
	local owner_session="${AIDEVOPS_SESSION_ID:-${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-$_FULL_LOOP_OWNER_SESSION_FALLBACK}}}"
	local receipt_path=""
	current_branch=$(git branch --show-current 2>/dev/null || true)
	owner_pid="${PPID:-}"
	if declare -F _resolve_worktree_owner_pid >/dev/null 2>&1; then
		owner_pid=$(_resolve_worktree_owner_pid "" 2>/dev/null || printf '%s' "${PPID:-}")
	fi
	if [[ -n "$current_root" && -n "$current_branch" ]] && declare -F full_loop_write_cleanup_deferred >/dev/null 2>&1; then
		receipt_path=$(_full_loop_cleanup_receipt_path "$repo" "$PR_NUMBER") || return 1
		if [[ -f "$receipt_path" ]]; then
			full_loop_finalize_cleanup_receipt "$repo" "$PR_NUMBER" \
				"${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}" "$current_root" "$current_branch" \
				"$owner_pid" "$owner_session" || {
				print_error "Cannot finalize durable deferred-cleanup handoff"
				return 1
			}
		elif ! full_loop_write_cleanup_deferred "$repo" "$PR_NUMBER" "$current_root" "$current_branch" \
			"$owner_pid" "$owner_session" "${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}" >/dev/null; then
			# A merge process may have created the receipt after the existence check.
			full_loop_finalize_cleanup_receipt "$repo" "$PR_NUMBER" \
				"${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}" "$current_root" "$current_branch" \
				"$owner_pid" "$owner_session" || {
				print_error "Cannot persist durable deferred-cleanup handoff"
				return 1
			}
		fi
	else
		print_error "Cannot persist durable deferred-cleanup handoff without worktree and branch evidence"
		return 1
	fi
	print_warning "LIFECYCLE_STATE=CLEANUP_DEFERRED worktree=${current_root}"
	print_info "Executor complete; guarded cleanup supervisor owns the remaining CLEANED transition"
	echo "<promise>FULL_LOOP_CLEANUP_DEFERRED</promise>"
	return 0
}

_full_loop_resolve_repo() {
	local repo_arg="${1:-}"
	if [[ -n "$repo_arg" ]]; then
		printf '%s\n' "$repo_arg"
		return 0
	fi
	repo_arg=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
	[[ -n "$repo_arg" ]] || return 1
	printf '%s\n' "$repo_arg"
	return 0
}

_full_loop_verify_merged_pr() {
	local pr_number="$1"
	local repo="$2"
	_full_loop_read_fresh_merged_pr_json "$pr_number" "$repo" >/dev/null
	return $?
}

_full_loop_resolve_remote_release_tag_commit() {
	local repo="$1"
	local tag_name="$2"
	local ref_json=""
	local object_type=""
	local object_sha=""
	local tag_json=""

	[[ "$repo" == */* && "$tag_name" =~ $_FULL_LOOP_VERSION_TAG_REGEX ]] || return 1
	ref_json=$(gh api "repos/${repo}/git/ref/tags/${tag_name}" 2>/dev/null) || return 1
	object_type=$(jq -er 'select(.ref == ("refs/tags/" + $tag_name) and (.object.type == "commit" or .object.type == "tag")) | .object.type' \
		--arg tag_name "$tag_name" <<<"$ref_json") || return 1
	object_sha=$(jq -er '.object.sha' <<<"$ref_json") || return 1
	[[ "$object_sha" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	if [[ "$object_type" == "tag" ]]; then
		tag_json=$(gh api "repos/${repo}/git/tags/${object_sha}" 2>/dev/null) || return 1
		object_sha=$(jq -er '.object.type == "commit" | .object.sha' <<<"$tag_json") || return 1
	fi
	[[ "$object_sha" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	printf '%s\n' "$object_sha"
	return 0
}

_full_loop_verify_published_release() {
	local repo="$1"
	local tag_name="$2"
	local merge_commit="$3"
	local tag_commit=""
	local release_json=""
	local workflow_runs_json=""

	[[ "$repo" == */* && "$tag_name" =~ $_FULL_LOOP_VERSION_TAG_REGEX && "$merge_commit" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	tag_commit=$(_full_loop_resolve_remote_release_tag_commit "$repo" "$tag_name") || return 1
	[[ "$tag_commit" == "$merge_commit" ]] || return 1
	release_json=$(gh api "repos/${repo}/releases/tags/${tag_name}" 2>/dev/null) || return 1
	jq -e --arg tag_name "$tag_name" '.tag_name == $tag_name and .draft == false' <<<"$release_json" >/dev/null || return 1
	workflow_runs_json=$(gh api "repos/${repo}/actions/runs?event=release&status=success&per_page=100" 2>/dev/null) || return 1
	jq -e --arg tag_name "$tag_name" --arg merge_commit "$merge_commit" --arg completed "$_FULL_LOOP_PHASE_COMPLETED" '
		[.workflow_runs[]? | select(
			.event == "release" and .status == $completed and .conclusion == "success"
			and .head_branch == $tag_name and .head_sha == $merge_commit
		)] | length > 0
	' <<<"$workflow_runs_json" >/dev/null || return 1
	return 0
}

cmd_record_no_release() {
	local pr_number="${1:-}"
	local repo_arg="${2:-}"
	local repo=""
	local receipt_path=""
	local release_status=""
	if [[ $# -lt 1 || $# -gt 2 ]] || [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
		print_error "Usage: full-loop-helper.sh record-no-release <PR> [REPO]"
		return 1
	fi
	repo=$(_full_loop_resolve_repo "$repo_arg") || {
		print_error "Cannot resolve repository for release evidence"
		return 1
	}
	_full_loop_verify_merged_pr "$pr_number" "$repo" || {
		print_error "Cannot record release:not-requested: PR #${pr_number} lacks merged evidence"
		return 1
	}
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	if [[ -f "$receipt_path" ]]; then
		IFS= read -r release_status <"$receipt_path" || true
	fi
	case "$release_status" in
	"$_FULL_LOOP_RELEASE_NOT_REQUESTED")
		if declare -F full_loop_update_cleanup_release_status >/dev/null 2>&1; then
			full_loop_update_cleanup_release_status "$repo" "$pr_number" "$_FULL_LOOP_RELEASE_NOT_REQUESTED" || return 1
		fi
		print_info "release:not-requested already recorded for PR #${pr_number}"
		return 0
		;;
	"$_FULL_LOOP_RELEASE_PUBLISHED" | "$_FULL_LOOP_RELEASE_SUPERSEDED" | "$_FULL_LOOP_PHASE_FAILED")
		print_error "Cannot replace terminal release:${release_status} evidence for PR #${pr_number}"
		return 1
		;;
	"") ;;
	*)
		print_error "Cannot replace unknown release:${release_status} evidence for PR #${pr_number}"
		return 1
		;;
	esac
	_full_loop_write_release_receipt "$repo" "$pr_number" "$_FULL_LOOP_RELEASE_NOT_REQUESTED" || return 1
	if declare -F full_loop_update_cleanup_release_status >/dev/null 2>&1; then
		full_loop_update_cleanup_release_status "$repo" "$pr_number" "$_FULL_LOOP_RELEASE_NOT_REQUESTED" || return 1
	fi
	print_success "release:not-requested recorded for merged PR #${pr_number}"
	return 0
}

cmd_record_published_release() {
	local pr_number="${1:-}"
	local tag_name="${2:-}"
	local repo_arg="${3:-}"
	local repo=""
	local pr_json=""
	local merge_commit=""
	local receipt_path=""
	local release_status=""
	local status=0
	if [[ $# -lt 2 || $# -gt 3 ]] || [[ ! "$pr_number" =~ ^[0-9]+$ ]] || [[ ! "$tag_name" =~ $_FULL_LOOP_VERSION_TAG_REGEX ]]; then
		print_error "Usage: full-loop-helper.sh record-published-release <PR> <TAG> [REPO]"
		return 1
	fi
	repo=$(_full_loop_resolve_repo "$repo_arg") || {
		print_error "Cannot resolve repository for release evidence"
		return 1
	}
	pr_json=$(_full_loop_read_fresh_merged_pr_json "$pr_number" "$repo") || {
		print_error "Cannot record release:published: PR #${pr_number} lacks merged evidence"
		return 1
	}
	merge_commit=$(jq -er '.mergeCommit.oid' <<<"$pr_json") || return 1
	[[ "$merge_commit" =~ $_FULL_LOOP_SHA40_REGEX ]] || {
		print_error "Cannot record release:published: PR #${pr_number} merge commit is invalid"
		return 1
	}
	_full_loop_verify_published_release "$repo" "$tag_name" "$merge_commit" || {
		print_error "Cannot record release:published: release, tag, and successful release workflow evidence do not match PR #${pr_number}"
		return 1
	}
	_full_loop_acquire_transition_lock || return 1
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || status=1
	if [[ "$status" -eq 0 && -f "$receipt_path" ]]; then
		IFS= read -r release_status <"$receipt_path" || status=1
	fi
	if [[ "$status" -eq 0 ]]; then
		case "$release_status" in
		"" | "$_FULL_LOOP_PHASE_FAILED" | "$_FULL_LOOP_RELEASE_PUBLISHED") ;;
		*)
			print_error "Cannot replace terminal release:${release_status} evidence for PR #${pr_number}"
			status=1
			;;
		esac
	fi
	if [[ "$status" -eq 0 ]]; then
		_full_loop_write_release_receipt "$repo" "$pr_number" "$_FULL_LOOP_RELEASE_PUBLISHED" || status=1
	fi
	if [[ "$status" -eq 0 ]] && declare -F full_loop_update_cleanup_release_status >/dev/null 2>&1; then
		full_loop_update_cleanup_release_status "$repo" "$pr_number" "$_FULL_LOOP_RELEASE_PUBLISHED" || status=1
	fi
	_full_loop_release_transition_lock
	[[ "$status" -eq 0 ]] || return 1
	print_success "release:published recorded for merged PR #${pr_number} (tag=${tag_name})"
	return 0
}

_full_loop_terminal_release_status() {
	local repo="$1"
	local pr_number="$2"
	local receipt_path=""
	local release_status=""
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	[[ -f "$receipt_path" ]] || return 1
	IFS= read -r release_status <"$receipt_path" || return 1
	[[ "$release_status" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$release_status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" || "$release_status" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" ]] || return 1
	if [[ "$release_status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" ]]; then
		_full_loop_verify_superseded_release_receipt "$repo" "$pr_number" || return 1
	fi
	printf '%s\n' "$release_status"
	return 0
}

cmd_finalize_receipt() {
	local pr_number="${1:-}"
	local repo=""
	local release_status=""
	[[ $# -ge 1 && $# -le 2 && "$pr_number" =~ ^[0-9]+$ ]] || {
		print_error "Usage: full-loop-helper.sh finalize-receipt <PR> [REPO]"
		return 1
	}
	repo=$(_full_loop_resolve_repo "${2:-}") || return 1
	_full_loop_verify_merged_pr "$pr_number" "$repo" || {
		print_error "Finalization blocked: PR #${pr_number} lacks merged evidence"
		return 1
	}
	release_status=$(_full_loop_terminal_release_status "$repo" "$pr_number") || {
		print_error "Finalization blocked: terminal release evidence is missing"
		return 1
	}
	full_loop_finalize_cleanup_receipt "$repo" "$pr_number" "$release_status" || {
		print_error "Finalization blocked: cleanup receipt is missing or conflicts with terminal evidence"
		return 1
	}
	print_success "Cleanup receipt finalized for merged PR #${pr_number} (release:${release_status})"
	return 0
}

cmd_migrate_repository_receipt() {
	local pr_number="${1:-}"
	local old_repo="${2:-}"
	local new_repo="${3:-}"
	local source_release=""
	local destination_release=""
	local release_status=""
	if [[ $# -ne 3 || ! "$pr_number" =~ ^[0-9]+$ || "$old_repo" != */* || "$new_repo" != */* || "$old_repo" == "$new_repo" ]]; then
		print_error "Usage: full-loop-helper.sh migrate-repository-receipt <PR> <OLD_REPO> <NEW_REPO>"
		return 1
	fi
	_full_loop_verify_merged_pr "$pr_number" "$new_repo" || {
		print_error "Migration blocked: PR #${pr_number} lacks merged evidence in ${new_repo}"
		return 1
	}
	source_release=$(_full_loop_release_receipt_path "$old_repo" "$pr_number") || return 1
	destination_release=$(_full_loop_release_receipt_path "$new_repo" "$pr_number") || return 1
	if [[ -f "$source_release" ]]; then
		IFS= read -r release_status <"$source_release" || true
	elif [[ -f "$destination_release" ]]; then
		IFS= read -r release_status <"$destination_release" || true
	fi
	[[ "$release_status" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$release_status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" || "$release_status" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" ]] || {
		print_error "Migration blocked: terminal release evidence is missing"
		return 1
	}
	full_loop_migrate_cleanup_receipt "$old_repo" "$new_repo" "$pr_number" \
		"$source_release" "$destination_release" "$release_status" || {
		print_error "Migration blocked: source evidence is missing or destination evidence conflicts"
		return 1
	}
	print_success "Migrated full-loop receipts from ${old_repo} to ${new_repo} for PR #${pr_number}"
	return 0
}

_full_loop_verify_aidevops_release_deploy() {
	local repo="$1"
	local pr_number="$2"
	local receipt_path=""
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	local release_status=""
	[[ -f "$receipt_path" ]] && IFS= read -r release_status <"$receipt_path"
	[[ "$repo" == "marcusquinn/aidevops" ]] || return 0
	[[ "$release_status" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" ]] && return 0
	local repo_root=""
	local version=""
	local tag_name=""
	local expected_release_sha=""
	if [[ "$release_status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" ]]; then
		_full_loop_verify_superseded_release_receipt "$repo" "$pr_number" || return 1
		local superseded_evidence=""
		superseded_evidence=$(_full_loop_superseded_release_evidence_path "$repo" "$pr_number") || return 1
		tag_name=$(jq -er '.release_tag' "$superseded_evidence") || return 1
		expected_release_sha=$(jq -er '.release_commit' "$superseded_evidence") || return 1
		version="${tag_name#v}"
	else
		[[ "$release_status" == "$_FULL_LOOP_RELEASE_PUBLISHED" ]] || return 1
		repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
		[[ -n "$repo_root" && -f "${repo_root}/VERSION" ]] && IFS= read -r version <"${repo_root}/VERSION"
		[[ -n "$version" ]] || return 1
		tag_name="v${version}"
	fi
	local release_sha=""
	release_sha=$(git ls-remote --exit-code --tags origin "refs/tags/${tag_name}^{}" | cut -f1 || true)
	if [[ -z "$release_sha" ]]; then
		release_sha=$(git ls-remote --exit-code --tags origin "refs/tags/${tag_name}" | cut -f1 || true)
	fi
	[[ -n "$release_sha" ]] || return 1
	[[ -z "$expected_release_sha" || "$release_sha" == "$expected_release_sha" ]] || return 1
	gh release view "$tag_name" --repo "$repo" >/dev/null 2>&1 || return 1
	local deployed_version=""
	[[ -f "${HOME}/.aidevops/agents/VERSION" ]] && IFS= read -r deployed_version <"${HOME}/.aidevops/agents/VERSION"
	[[ "$deployed_version" == "$version" ]] || return 1
	local postflight="${SCRIPT_DIR}/postflight-check.sh"
	[[ -f "$postflight" ]] || return 1
	bash "$postflight" --quick --sha "$release_sha" --tag "$tag_name" >/dev/null 2>&1 || return 1
	return 0
}

_full_loop_verify_cleanup_audit() {
	local removed_worktree="$1"
	local cleanup_log="${AIDEVOPS_CLEANUP_LOG:-${HOME}/.aidevops/logs/cleanup_worktrees.log}"
	[[ -f "$cleanup_log" ]] || return 1
	grep -Fq "worktree-removed: ${removed_worktree} —" "$cleanup_log"
	return $?
}

cmd_complete_after_cleanup() {
	local pr_number="${1:-}"
	local removed_worktree="${2:-}"
	local repo=""
	local release_status=""
	[[ "$pr_number" =~ ^[0-9]+$ && -n "$removed_worktree" ]] || {
		print_error "Usage: full-loop-helper.sh complete-after-cleanup <PR> <removed-worktree-path> [REPO]"
		return 1
	}
	repo=$(_full_loop_resolve_repo "${3:-}") || {
		print_error "Cannot resolve repository for completion evidence"
		return 1
	}
	if [[ -e "$removed_worktree" ]] || git worktree list --porcelain 2>/dev/null | grep -Fq "worktree ${removed_worktree}"; then
		print_error "LIFECYCLE_STATE=CLEANUP_PENDING worktree=${removed_worktree}"
		return 1
	fi
	_full_loop_verify_cleanup_audit "$removed_worktree" || {
		print_error "Completion blocked: no removal audit evidence for ${removed_worktree}"
		return 1
	}
	declare -F full_loop_mark_cleanup_cleaned_for_identity >/dev/null 2>&1 || {
		print_error "Completion blocked: exact cleanup-receipt verifier is unavailable"
		return 1
	}
	full_loop_mark_cleanup_cleaned_for_identity "$repo" "$pr_number" "$removed_worktree" || {
		print_error "Completion blocked: durable cleanup receipt identity is not CLEANED for ${repo}#${pr_number} at ${removed_worktree}"
		return 1
	}
	_full_loop_verify_merged_pr "$pr_number" "$repo" || {
		print_error "Completion blocked: PR #${pr_number} lacks merged evidence"
		return 1
	}
	release_status=$(_full_loop_terminal_release_status "$repo" "$pr_number") || {
		print_error "Completion blocked: terminal release evidence is missing"
		return 1
	}
	_full_loop_verify_aidevops_release_deploy "$repo" "$pr_number" || {
		print_error "Completion blocked: release, deployment, or postflight evidence is missing"
		return 1
	}
	full_loop_finalize_cleanup_receipt "$repo" "$pr_number" "$release_status" || {
		print_error "Completion blocked: cleanup receipt conflicts with terminal release evidence"
		return 1
	}
	printf "\n${BOLD}${GREEN}=== FULL DEVELOPMENT LOOP - COMPLETE ===${NC}\n"
	printf "PR: #%s | Lifecycle: CLEANED | release:%s\n\n" "$pr_number" "$release_status"
	echo "<promise>FULL_LOOP_COMPLETE</promise>"
	return 0
}
