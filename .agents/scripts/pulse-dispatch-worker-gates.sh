#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dispatch-worker-gates.sh -- Worker launch gates and post-launch bookkeeping helpers.
#
# Sourced by pulse-dispatch-worker-launch.sh. Depends on shared-constants.sh
# plus lifecycle, dispatch ledger, status, and dedup helpers supplied by pulse.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_DISPATCH_WORKER_GATES_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_WORKER_GATES_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_dlw_gates_path="${BASH_SOURCE[0]%/*}"
	[[ "$_dlw_gates_path" == "${BASH_SOURCE[0]}" ]] && _dlw_gates_path="."
	SCRIPT_DIR="$(cd "$_dlw_gates_path" && pwd)"
	unset _dlw_gates_path
fi

# shellcheck source=shared-constants.sh
# shellcheck disable=SC1091  # This module's directory is resolved at runtime.
source "${BASH_SOURCE[0]%/*}/shared-constants.sh"

#######################################
# Transition a durably registered live worker from queued to in-progress.
#
# Args: issue_number, repo_slug, self_login, worker_pid
# Returns: 0=transition confirmed by mutation command, 1=worker/status unavailable
#######################################
_dlw_mark_worker_in_progress() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local worker_pid="$4"

	[[ "$worker_pid" =~ ^[0-9]+$ ]] || return 1
	if ! kill -0 "$worker_pid" 2>/dev/null; then
		echo "[dispatch_with_dedup] Worker registration for #${issue_number} has non-live PID ${worker_pid}; retaining status:queued for recovery" >>"$LOGFILE"
		return 1
	fi
	if ! declare -F transition_owned_issue_status >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Cannot transition #${issue_number} to status:in-progress: ownership-transition helper unavailable" >>"$LOGFILE"
		return 1
	fi
	if ! transition_owned_issue_status "$issue_number" "$repo_slug" "$self_login" \
		"queued" "in-progress" >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Failed to transition registered worker #${issue_number} to status:in-progress; retaining queued recovery signal" >>"$LOGFILE"
		return 1
	fi
	echo "[dispatch_with_dedup] Registered live worker PID ${worker_pid} for #${issue_number}; transitioned status:queued to status:in-progress" >>"$LOGFILE"
	return 0
}

#######################################
# Post-launch bookkeeping: dispatch-ledger registration, the deterministic
# "Dispatching worker" comment on the issue, stagger delay, and claim-comment
# retention logging.
#
# Stagger (GH#17549): reduces SQLite write contention on opencode.db
# (busy_timeout=0). Without it, batches of 8+ workers all hit the DB
# simultaneously, causing SQLITE_BUSY → silent mid-turn death. The stagger
# happens after the dispatch comment is posted. A fast worker can publish its
# terminal lease before this parent reaches the audit write, so the marker
# carries the exact dispatch identity for order-independent reconciliation.
#
# Dispatch comment (GH#15317): posted from the dispatcher, NOT from the
# worker LLM session. Previously, the worker was responsible for posting
# this comment — but workers could crash before posting, leaving no
# persistent signal. Without this signal, Layer 5 (has_dispatch_comment)
# had nothing to find, and the issue would be re-dispatched every pulse
# cycle. Evidence: webapp #2051 accumulated 29 DISPATCH_CLAIM comments
# over 6 hours because workers kept dying before posting.
#
# Claim comment retention (GH#17503): claim comments are NEVER deleted —
# they form the persistent audit trail and are respected as the primary
# dedup lock for 30 minutes. The deferred deletion that previously ran
# here (GH#17497) was the root cause of duplicate dispatches. Evidence:
# GH#17503 — 6 dispatches from marcusquinn + 1 from alex-solovyev,
# producing 2 duplicate PRs (#17512, #17513). This helper clears
# `_claim_comment_id` (dynamically-scoped from dispatch_with_dedup) once
# the retention message is logged so subsequent dispatches start fresh.
#
# Arguments: issue_number, repo_slug, self_login, worker_pid, session_key,
#            dispatch_tier, selected_model, worker_worktree_path
#######################################
_dlw_post_launch_hooks() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local worker_pid="$4"
	local session_key="$5"
	local dispatch_tier="$6"
	local selected_model="$7"
	local worker_worktree_path="${8:-}"
	local attempt_id="${9:-}"

	# Record in dispatch ledger (with tier telemetry)
	local ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	local ledger_registered=0
	if [[ -x "$ledger_helper" ]]; then
		if "$ledger_helper" register --session-key "$session_key" \
			--issue "$issue_number" --repo "$repo_slug" \
			--pid "$worker_pid" --tier "$dispatch_tier" \
			--model "$selected_model" --lease-token "${_claim_lease_token:-}" \
			--attempt-id "$attempt_id" \
			--device-id "${_claim_lease_device:-}" --worktree "$worker_worktree_path" 2>/dev/null; then
			ledger_registered=1
		else
			echo "[dispatch_with_dedup] Failed to register worker PID ${worker_pid} for #${issue_number}; retaining status:queued for recovery" >>"$LOGFILE"
		fi
	else
		echo "[dispatch_with_dedup] Dispatch ledger helper unavailable for #${issue_number}; retaining status:queued for recovery" >>"$LOGFILE"
	fi
	if [[ "$ledger_registered" -eq 1 ]]; then
		_dlw_mark_worker_in_progress "$issue_number" "$repo_slug" "$self_login" "$worker_pid" || true
	fi

	local dispatch_comment_body
	local display_model="${selected_model:-auto-select (round-robin)}"
	local aidevops_version="$AIDEVOPS_UNKNOWN_VERSION" opencode_version="$AIDEVOPS_UNKNOWN_VERSION"
	if declare -F aidevops_find_version >/dev/null 2>&1; then
		aidevops_version=$(aidevops_find_version 2>/dev/null || printf '%s' "$AIDEVOPS_UNKNOWN_VERSION")
	fi
	if declare -F _detect_opencode_version >/dev/null 2>&1; then
		opencode_version=$(_detect_opencode_version 2>/dev/null || printf '%s' "")
		opencode_version="${opencode_version:-$AIDEVOPS_UNKNOWN_VERSION}"
	fi
	dispatch_comment_body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
Dispatching worker (deterministic).
<!-- aidevops:dispatch lease_token=${_claim_lease_token:-legacy} device=${_claim_lease_device:-legacy} session=${session_key} attempt_id=${attempt_id:-unknown} claim_id=${_claim_comment_id:-0} -->
- **Worker PID**: ${worker_pid}
- **Model**: ${display_model}
- **Tier**: ${dispatch_tier}
- **Runner**: ${self_login}
- **aidevops**: $(_dlw_display_version_or_unknown "$aidevops_version")
- **OpenCode**: $(_dlw_display_version_or_unknown "$opencode_version")
- **Issue**: #${issue_number}
<!-- ops:end -->"
	gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--method POST --field body="$dispatch_comment_body" \
		>/dev/null 2>>"$LOGFILE" || {
		echo "[dispatch_with_dedup] Warning: failed to post deterministic dispatch comment for #${issue_number}" >>"$LOGFILE"
	}

	# _claim_comment_id is dynamically scoped from dispatch_with_dedup through
	# _dispatch_launch_worker into this helper — assignment without `local`
	# propagates up the stack, matching the pre-GH#18654 behavior.
	if [[ -n "$_claim_comment_id" ]]; then
		echo "[dispatch_with_dedup] Claim comment ${_claim_comment_id} retained for audit trail on #${issue_number} (GH#17503)" >>"$LOGFILE"
		_claim_comment_id=""
	fi

	local stagger_delay="${PULSE_DISPATCH_STAGGER_SECONDS:-8}"
	sleep "$stagger_delay"
	return 0
}

#######################################
# Hold dispatch when a reused worker branch repeatedly orphaned.
#
# The branch-specific check lives in dispatch-dedup-helper.sh so tests and
# ad-hoc diagnosis can exercise it directly. It runs after worktree
# pre-creation because only then do we know whether dispatch is reusing the same
# issue-linked branch or creating a fresh branch. A new branch therefore does
# not inherit an old branch's orphan count.
#
# Args: $1 = issue number, $2 = repo slug, $3 = worker worktree branch,
#       $4 = 1 when the branch was reused, 0 for a freshly-created branch,
#       $5 = TODO.md path for remote-child reconciliation (optional),
#       $6 = worker worktree path for orphan recovery probes (optional)
# Returns: exit 0 if dispatch should be held, exit 1 if safe to continue
#######################################
_dlw_check_worker_branch_orphan_loop() {
	local issue_number="$1"
	local repo_slug="$2"
	local worker_worktree_branch="$3"
	local worker_worktree_reused="${4:-0}"
	local todo_file="${5:-TODO.md}"
	local worker_worktree_path="${6:-}"

	[[ "$worker_worktree_reused" == "1" ]] || return 1
	[[ -n "$worker_worktree_branch" ]] || return 1

	local dedup_helper="${SCRIPT_DIR}/dispatch-dedup-helper.sh"
	[[ -x "$dedup_helper" ]] || return 1

	local orphan_loop_out=""
	if orphan_loop_out=$("$dedup_helper" check-orphan-loop "$issue_number" "$repo_slug" "$worker_worktree_branch" "$todo_file" "$worker_worktree_path" 2>/dev/null); then
		if [[ "$orphan_loop_out" == *"WORKER_BRANCH_ORPHAN_AUTO_RECOVERED"* ]]; then
			echo "[dispatch_with_dedup] Auto-recovered orphan branch for #${issue_number} in ${repo_slug}: ${orphan_loop_out}" >>"$LOGFILE"
			return 1
		fi
		echo "[dispatch_with_dedup] Dispatch held for #${issue_number} in ${repo_slug}: ${orphan_loop_out}" >>"$LOGFILE"
		return 0
	fi

	return 1
}

_dlw_min_worker_floor_active() {
	local active_workers="" min_worker_floor=""
	active_workers=$(count_active_workers 2>/dev/null || echo 0)
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	min_worker_floor="${AIDEVOPS_MIN_WORKER_CONCURRENCY:-}"
	if [[ -z "$min_worker_floor" ]] && declare -F config_get >/dev/null 2>&1; then
		min_worker_floor=$(config_get "orchestration.min_worker_concurrency" "6")
	fi
	[[ -n "$min_worker_floor" ]] || min_worker_floor=6
	if ! [[ "$min_worker_floor" =~ ^[0-9]+$ ]]; then
		min_worker_floor=6
	fi
	((min_worker_floor > 0 && active_workers < min_worker_floor)) && return 0
	return 1
}

_dlw_headless_state_dir() {
	printf '%s' "${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
	return 0
}

_dlw_canary_last_failure_reason() {
	local state_dir="" reason_file="" reason=""
	state_dir=$(_dlw_headless_state_dir)
	reason_file="${state_dir}/canary-last-fail.reason"
	reason=$(cat "$reason_file" 2>/dev/null || printf '%s' "transient")
	printf '%s' "$reason"
	return 0
}

_dlw_canary_failure_is_soft() {
	local reason="$1"
	case "$reason" in
		overload | provider_error | rate_limit | timeout | transient)
			return 0
			;;
	esac
	return 1
}

_dlw_recent_worker_evidence() {
	local ttl="" ledger_file=""
	ttl="${CANARY_SOFT_FAILURE_RECENT_SUCCESS_TTL_SECONDS:-900}"
	[[ "$ttl" =~ ^[0-9]+$ ]] || ttl=900
	ledger_file="${AIDEVOPS_DISPATCH_LEDGER_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/dispatch-ledger.jsonl"
	[[ -f "$ledger_file" ]] || return 1
	python3 - "$ledger_file" "$ttl" <<'PY'
import json
import sys
from datetime import datetime, timezone

ledger_path = sys.argv[1]
ttl = int(sys.argv[2])
now = datetime.now(timezone.utc).timestamp()
allowed = {"in-flight", "completed"}

def parse_ts(value):
    if not value:
        return 0
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0

try:
    with open(ledger_path, "r", encoding="utf-8") as handle:
        for raw in handle:
            try:
                entry = json.loads(raw)
            except Exception:
                continue
            if entry.get("status") not in allowed:
                continue
            stamp = parse_ts(entry.get("updated_at") or entry.get("dispatched_at"))
            if stamp and 0 <= now - stamp <= ttl:
                sys.exit(0)
except FileNotFoundError:
    pass
sys.exit(1)
PY
	return $?
}

_dlw_allow_soft_canary_failure() {
	local reason="$1"
	_dlw_canary_failure_is_soft "$reason" || return 1
	_dlw_recent_worker_evidence || return 1
	return 0
}

_dlw_claim_lock_after_canary() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local _ds_t0

	# t3549: acquire the cross-runner GitHub claim only after the canary proves
	# this runtime can start. Otherwise canary timeout storms publish persistent
	# DISPATCH_CLAIM audit noise even though no worker process will exist.
	_ds_t0=$(_ds_now_ns)
	if _dedup_layer7_claim_lock "$issue_number" "$repo_slug" "$self_login"; then
		_ds_record "$issue_number" "$repo_slug" "claim_lock" "$_ds_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "claim_lock" "$_ds_t0"
	return 0
}

_dlw_canary_preflight() {
	local issue_number="$1"
	local repo_slug="$2"
	local worker_log="$3"
	local dispatch_model_tier="$4"
	local selected_model="$5"

	local -a _canary_cmd=("$HEADLESS_RUNTIME_HELPER" canary --role worker --tier "$dispatch_model_tier")
	if [[ -n "$selected_model" ]]; then
		_canary_cmd+=(--model "$selected_model")
	fi
	local -a _canary_env=()
	if _dlw_min_worker_floor_active; then
		_canary_env+=(AIDEVOPS_MIN_WORKER_FLOOR_BYPASS_ACTIVE=1)
		echo "[dispatch_with_dedup] #${issue_number} in ${repo_slug}: minimum worker floor active — canary still checks runtime/model health only" >>"$LOGFILE"
	fi

	if env "${_canary_env[@]}" "${_canary_cmd[@]}" >>"$worker_log" 2>&1; then
		return 0
	fi

	local canary_reason
	canary_reason=$(_dlw_canary_last_failure_reason)
	if _dlw_allow_soft_canary_failure "$canary_reason"; then
		echo "[dispatch_with_dedup] #${issue_number} in ${repo_slug}: soft worker canary failure reason=${canary_reason} bypassed because recent worker evidence exists (bounded t3449)" >>"$LOGFILE"
		return 0
	fi

	pulse_stats_increment "worker_canary_preflight_failed_count" 2>/dev/null || true
	echo "[dispatch_with_dedup] Skipping #${issue_number} in ${repo_slug} — worker canary preflight failed before worktree pre-creation; will retry next cycle" >>"$LOGFILE"
	return 1
}

_dlw_opencode_storage_preflight() {
	local issue_number="$1"
	local repo_slug="$2"
	local state_dir="${HOME}/.local/share/opencode"
	local db_path="${state_dir}/opencode.db"
	local tmp_parent="${TMPDIR:-/tmp}"
	local probe_dir=""

	[[ "${AIDEVOPS_OPENCODE_STORAGE_PREFLIGHT:-1}" != "0" ]] || return 0
	[[ -d "$state_dir" ]] || return 0
	[[ -w "$state_dir" ]] || {
		echo "[dispatch_with_dedup] Skipping #${issue_number} in ${repo_slug} — OpenCode state dir is not writable: ${state_dir}" >>"$LOGFILE"
		return 1
	}
	if [[ -e "$db_path" && ! -w "$db_path" ]]; then
		echo "[dispatch_with_dedup] Skipping #${issue_number} in ${repo_slug} — OpenCode session DB is not writable" >>"$LOGFILE"
		return 1
	fi
	probe_dir=$(mktemp -d "${tmp_parent%/}/aidevops-opencode-snapshot-preflight.XXXXXX" 2>/dev/null) || {
		echo "[dispatch_with_dedup] Skipping #${issue_number} in ${repo_slug} — unable to create OpenCode snapshot temp dir under ${tmp_parent}" >>"$LOGFILE"
		return 1
	}
	if ! git -C "$probe_dir" init -q >/dev/null 2>&1; then
		rm -rf "$probe_dir" 2>/dev/null || true
		echo "[dispatch_with_dedup] Skipping #${issue_number} in ${repo_slug} — git cannot initialise temp snapshot probe" >>"$LOGFILE"
		return 1
	fi
	rm -rf "$probe_dir" 2>/dev/null || true
	return 0
}

_dlw_load_preflight() {
	local issue_number="$1"
	local repo_slug="$2"
	local max_load_per_cpu="${AIDEVOPS_DISPATCH_MAX_LOAD_PER_CPU:-3.0}"
	local current_ratio=""

	[[ "${AIDEVOPS_DISPATCH_LOAD_PREFLIGHT:-1}" != "0" ]] || return 0
	current_ratio=$(python3 - <<'PY' 2>/dev/null || true
import os
try:
    load = os.getloadavg()[0]
    cpus = os.cpu_count() or 1
    print(f"{load / cpus:.3f}")
except Exception:
    print("")
PY
)
	[[ -n "$current_ratio" ]] || return 0
	if ! python3 - "$current_ratio" "$max_load_per_cpu" >/dev/null 2>&1 <<'PY'
import sys
current = float(sys.argv[1])
maximum = float(sys.argv[2])
sys.exit(0 if current <= maximum else 1)
PY
	then
		echo "[dispatch_with_dedup] Skipping #${issue_number} in ${repo_slug} — local load_per_cpu=${current_ratio} exceeds dispatch threshold ${max_load_per_cpu}" >>"$LOGFILE"
		return 1
	fi
	return 0
}

_dlw_blocked_by_hard_stop() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_meta_json="$3"
	local repo_path="${4:-}"
	_DLW_HARD_STOP_REASON=""

	if [[ "$(type -t is_blocked_by_unresolved 2>/dev/null)" != "function" ]]; then
		_DLW_HARD_STOP_REASON="dependency-verifier-unavailable"
		echo "[dispatch_with_dedup] Hard-stop before worker bootstrap for #${issue_number} in ${repo_slug}: dependency verifier unavailable" >>"$LOGFILE"
		return 0
	fi

	local issue_body=""
	issue_body=$(printf '%s' "$issue_meta_json" | jq -r '.body // ""' 2>/dev/null) || issue_body=""
	if PULSE_DEP_GRAPH_REPO_PATH="$repo_path" is_blocked_by_unresolved "$issue_body" "$repo_slug" "$issue_number"; then
		_DLW_HARD_STOP_REASON="dependency-unresolved"
		echo "[dispatch_with_dedup] Hard-stop before worker bootstrap for #${issue_number} in ${repo_slug}: unresolved blocked-by dependency (GH#23932)" >>"$LOGFILE"
		return 0
	fi

	_DLW_HARD_STOP_REASON="clear"
	return 1
}

_dlw_record_efficiency_guardrail() {
	local name="$1"
	case "$name" in
	guardrails.stale_positive_decisions | guardrails.dispatch_dependency_violations) ;;
	*) return 1 ;;
	esac
	if declare -F gh_record_efficiency_evidence >/dev/null 2>&1; then
		gh_record_efficiency_evidence "$name" 1 2>/dev/null || true
	fi
	return 0
}

_dlw_final_dependency_attestation() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_meta_json="$3"
	local repo_path="$4"
	if _dlw_blocked_by_hard_stop "$issue_number" "$repo_slug" "$issue_meta_json" "$repo_path"; then
		if [[ "${_DLW_HARD_STOP_REASON:-}" == "dependency-unresolved" ]]; then
			# The prebootstrap dependency decision was positive, but the live
			# action-boundary recheck now blocks. Record that stale positive while
			# still preventing the worker process from starting.
			_dlw_record_efficiency_guardrail guardrails.stale_positive_decisions
		fi
		return 1
	fi
	return 0
}

_dlw_require_dependency_attestation() {
	local attested="$1"
	local issue_number="$2"
	local repo_slug="$3"
	if [[ "$attested" == "1" ]]; then
		return 0
	fi
	_dlw_record_efficiency_guardrail guardrails.dispatch_dependency_violations
	echo "[dispatch_with_dedup] Worker spawn blocked for #${issue_number} in ${repo_slug}: final dependency attestation missing" >>"$LOGFILE"
	return 1
}

_dlw_hold_repeated_recovery_failures() {
	local issue_number="$1"
	local repo_slug="$2"
	local dedup_helper="${SCRIPT_DIR}/dispatch-dedup-helper.sh"
	local recovery_loop_out=""

	[[ -x "$dedup_helper" ]] || return 1
	if recovery_loop_out=$("$dedup_helper" check-recovery-loop "$issue_number" "$repo_slug" 2>/dev/null); then
		echo "[dispatch_with_dedup] Dispatch held for #${issue_number} in ${repo_slug}: ${recovery_loop_out}" >>"$LOGFILE"
		return 0
	fi
	return 1
}

_dlw_prebootstrap_gates() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_meta_json="$3"
	local repo_path="$4"

	if _dlw_blocked_by_hard_stop "$issue_number" "$repo_slug" "$issue_meta_json" "$repo_path"; then
		return 1
	fi
	if ! _dlw_opencode_storage_preflight "$issue_number" "$repo_slug"; then
		return 1
	fi
	if ! _dlw_load_preflight "$issue_number" "$repo_slug"; then
		return 1
	fi
	if _dlw_hold_repeated_recovery_failures "$issue_number" "$repo_slug"; then
		return 1
	fi
	return 0
}

_dlw_issue_still_open_before_claim() {
	local issue_number="$1"
	local repo_slug="$2"
	local refreshed_state=""

	# GH#24437: the canonical metadata bundle is fetched before canary/model
	# preflight and may be stale by the time the dispatcher is about to publish a
	# persistent DISPATCH_CLAIM. Refresh just the issue state immediately before
	# cross-runner claim/label/worktree mutation so auto-resolved meta-issues do
	# not consume worker capacity after they close.
	refreshed_state=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json state --jq '.state // ""' | tr '[:lower:]' '[:upper:]') || refreshed_state=""
	if [[ -z "$refreshed_state" ]]; then
		echo "[dispatch_with_dedup] Warning: unable to refresh issue state for #${issue_number} in ${repo_slug} before claim; proceeding with prior dispatch gates" >>"$LOGFILE"
		return 0
	fi
	if [[ "$refreshed_state" != "OPEN" ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: refreshed issue state before claim is ${refreshed_state} (GH#24437)" >>"$LOGFILE"
		return 1
	fi

	return 0
}

_dlw_preclaim_state_refresh_or_skip() {
	local issue_number="$1"
	local repo_slug="$2"
	local _ds_t0

	_ds_t0=$(_ds_now_ns)
	if ! _dlw_issue_still_open_before_claim "$issue_number" "$repo_slug"; then
		_ds_record "$issue_number" "$repo_slug" "preclaim_state_refresh" "$_ds_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "preclaim_state_refresh" "$_ds_t0"

	return 0
}

#######################################
# Record why dispatch stopped before the canonical worker runtime started.
# Canonical runtime metrics must not include attempts that never crossed the
# runtime boundary, so this evidence remains in the issue-correlated dispatch
# stage stream and pulse log.
# Args: issue number, repo slug, low-cardinality reason, return code
#######################################
_dlw_pre_runtime_failure() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="$3"
	local return_code="${4:-2}"
	_DLW_LAST_PRE_RUNTIME_FAILURE="$reason"
	local failure_started_ns=""
	failure_started_ns=$(_ds_now_ns)
	_ds_record "$issue_number" "$repo_slug" "pre_runtime_failure:${reason}" "$failure_started_ns"
	echo "[dispatch_with_dedup] PRE_RUNTIME_FAILURE issue=${issue_number} repo=${repo_slug} reason=${reason}" >>"$LOGFILE"
	return "$return_code"
}

_dlw_final_worker_spawn_gates() {
	local issue_number="$1"
	local repo_slug="$2"
	local worker_worktree_branch="$3"
	local worker_worktree_reused="$4"
	local todo_path="$5"
	local worker_worktree_path="$6"
	local issue_meta_json="$7"
	local repo_path="$8"
	local dependency_attested=0

	if _dlw_check_worker_branch_orphan_loop "$issue_number" "$repo_slug" "$worker_worktree_branch" \
		"$worker_worktree_reused" "$todo_path" "$worker_worktree_path"; then
		_dlw_pre_runtime_failure "$issue_number" "$repo_slug" "worker_branch_orphan_hold" 2 || return $?
	fi
	if ! _dlw_final_dependency_attestation "$issue_number" "$repo_slug" "$issue_meta_json" "$repo_path"; then
		_dlw_pre_runtime_failure "$issue_number" "$repo_slug" "final_dependency_recheck" 2 || return $?
	fi
	dependency_attested=1
	if ! _dlw_require_dependency_attestation "$dependency_attested" "$issue_number" "$repo_slug"; then
		_dlw_pre_runtime_failure "$issue_number" "$repo_slug" "dependency_attestation_missing" 2 || return $?
	fi
	return 0
}

DLW_STAGE_CANARY_PREFLIGHT="canary_preflight"
