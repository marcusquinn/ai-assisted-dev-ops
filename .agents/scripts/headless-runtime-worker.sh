#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Headless Runtime Worker -- Worker lifecycle, invocation support & preparation
# =============================================================================
# Worker-specific helpers: auth rotation, rate-limit monitoring, Claude CLI
# invocation, output preservation, output classification, orphan handling,
# run preparation/retry/finish, detach, and stall-cap checks.
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-worker.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning, etc.)
#   - headless-runtime-lib.sh (extract_provider, append_runtime_metric, etc.)
#   - shared-claim-lifecycle.sh (_attempt_orphan_recovery_pr, _release_dispatch_claim, etc.)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_WORKER_LIB_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_WORKER_LIB_LOADED=1

# Module-local string constants (avoid ratchet repeated-literal violations)
_HRW_STATUS_FAIL="fail"
_HRW_STATUS_FAILED="failed"
_HRW_STATUS_ESCALATED="escalated"
_HRW_STATUS_UNKNOWN="unknown"
_HRW_STATUS_PERMISSION_REQUIRED="permission_required"
_HRW_GIT_HEAD="HEAD"
_HRW_CRASH_NO_WORK="no_work"
_HRW_CRASH_OVERWHELMED="overwhelmed"
_HRW_REASON_WORKER_COMPLETE="worker_complete"
_HRW_TELEMETRY_SUCCESS="success"
_HRW_TELEMETRY_FAILED="failed"
_HRW_TELEMETRY_DEFERRED="deferred"
_HRW_REASON_DRAFT_CHECKPOINT="worker_draft_checkpoint"
_HRW_REASON_DRAFT_ESCALATION_FAILED="worker_draft_checkpoint_escalation_failed"
_HRW_REASON_CLOSED_UNMERGED="worker_closed_unmerged_pr"
_HRW_REASON_UNVERIFIED_HANDOFF="worker_post_pr_handoff_unverified"
_HRW_REASON_WORKTREE_CONTINUATION_STATE_REJECTED="worker_worktree_continuation_state_rejected"
_HRW_REASON_WORKTREE_OWNER_CONCURRENT_MUTATION="worker_worktree_owner_concurrent_mutation"
_HRW_REASON_OWNERSHIP_LOST="worker_ownership_lost"
_HRW_EVENT_FAILED="worker.failed"
_HRW_EVENT_DEFERRED="worker.deferred"
_HRW_NMR_LABEL="needs-maintainer-review"
_HRW_PERMISSION_PERSISTENCE_FAILED="permission_request_persistence_failed"
_HRW_SPOTLIGHT_MARKER=".metadata_never_index"
_HRW_RECOVERY_CLASSIFICATION=""
_HRW_CLAIM_RELEASE_PERSISTENCE_FAILED=0

# Defensive SCRIPT_DIR fallback (test harnesses may not set it)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# shellcheck source=shared-runner-identity.sh
source "${SCRIPT_DIR}/shared-runner-identity.sh"

# shellcheck source=./headless-runtime-worker-prepare.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-worker-prepare.sh"

#######################################
# Release a claim without allowing a GitHub comment persistence failure to
# bypass later terminal-lease emission and local cleanup. The underlying
# helper still returns non-zero to direct callers so the write is observable
# and retryable; worker lifecycle callers record the failure and continue.
#######################################
_hrw_release_dispatch_claim() {
	local session_key="$1"
	local reason="${2:-worker_failed}"
	local exit_code_arg="${3:-}"
	local session_count_arg="${4:-}"

	if _release_dispatch_claim "$session_key" "$reason" "$exit_code_arg" "$session_count_arg"; then
		return 0
	fi
	_HRW_CLAIM_RELEASE_PERSISTENCE_FAILED=1
	print_warning "[lifecycle] claim_release_persistence_failed session=${session_key} reason=${reason}; terminal lease/event cleanup remains active"
	return 0
}

# =============================================================================
# Runtime invocation support — auth rotation & rate-limit monitoring
# =============================================================================

# _maybe_rotate_isolated_auth: pre-dispatch OAuth rotation check for headless workers (t2249).
#
# When the account copied into the isolated auth.json is currently in
# cooldown per the SHARED pool metadata (recorded by a prior worker's
# mark-failure), rotate the isolated file to a healthy account BEFORE
# opencode spawns. This prevents wasted dispatches on known-dead accounts.
#
# Safe because OPENCODE_AUTH_FILE in oauth-pool-helper.sh is now
# XDG_DATA_HOME-aware (t2249): rotate writes to the ISOLATED file,
# not the shared interactive auth.json.
#
# Args: $1 = absolute path to the isolated auth.json
#       $2 = provider (e.g., "anthropic")
# Returns: 0 always — best-effort; rotation failure must not block dispatch.
_maybe_rotate_isolated_auth() {
	local isolated_auth="$1"
	local provider="$2"
	local pool_file="${AIDEVOPS_OAUTH_POOL_FILE:-${HOME}/.aidevops/oauth-pool.json}"
	local oauth_helper="${OAUTH_POOL_HELPER:-${HOME}/.aidevops/agents/scripts/oauth-pool-helper.sh}"

	# Skip silently when prerequisites are missing (jq, pool, isolated auth, helper).
	command -v jq >/dev/null 2>&1 || return 0
	[[ -f "$isolated_auth" ]] || return 0
	[[ -f "$pool_file" ]] || return 0
	[[ -x "$oauth_helper" ]] || return 0

	# Extract BOTH the email and access token currently written in the
	# isolated auth for this provider. build_auth_entry (in
	# oauth-pool-lib/_common.py) writes only {type, refresh, access, expires}
	# on rotation — NOT email. So after the first rotation, the isolated
	# auth.json has no email field and the previous email-only lookup here
	# returned early, defeating the rotation on every subsequent dispatch.
	# (CodeRabbit review #4135227617, verified against live production
	# ~/.local/share/opencode/auth.json 2026-04-19.)
	local current_email current_access
	current_email=$(jq -r --arg p "$provider" '.[$p].email // empty' "$isolated_auth" 2>/dev/null || true)
	current_access=$(jq -r --arg p "$provider" '.[$p].access // empty' "$isolated_auth" 2>/dev/null || true)
	[[ -n "$current_email" || -n "$current_access" ]] || return 0

	# Look up the account in the shared pool. Try email first (most common —
	# interactive auth with email was copied to isolated at worker startup).
	# Fall back to access-token match when email is absent (isolated auth
	# was already rotated at least once, dropping email per build_auth_entry).
	local pool_match=""
	if [[ -n "$current_email" ]]; then
		pool_match=$(jq -c --arg p "$provider" --arg e "$current_email" \
			'.[$p] | map(select(.email == $e)) | .[0] // empty' "$pool_file" 2>/dev/null || true)
	fi
	if [[ -z "$pool_match" && -n "$current_access" ]]; then
		pool_match=$(jq -c --arg p "$provider" --arg a "$current_access" \
			'.[$p] | map(select(.access == $a)) | .[0] // empty' "$pool_file" 2>/dev/null || true)
	fi
	[[ -n "$pool_match" ]] || return 0

	local cooldown_until now_ms identity_label
	cooldown_until=$(printf '%s' "$pool_match" | jq -r '.cooldownUntil // 0' 2>/dev/null || echo 0)
	[[ -n "$cooldown_until" ]] || cooldown_until=0
	# Log-friendly identity: private workloads suppress account identity, while
	# ordinary workers may use email. Never log access-token fragments.
	if [[ "${AIDEVOPS_PRIVATE_WORKLOAD:-0}" == "1" ]]; then
		identity_label="[private]"
	elif [[ -n "$current_email" ]]; then
		identity_label="$current_email"
	else
		identity_label="access credential"
	fi
	now_ms=$(($(date +%s) * 1000))

	# Only rotate when cooldown is still active (in the future).
	if [[ "$cooldown_until" -gt "$now_ms" ]]; then
		local isolated_dir
		isolated_dir="$(dirname "$(dirname "$isolated_auth")")"
		print_info "[lifecycle] pre_dispatch_rotate: ${provider} account=${identity_label} in cooldown; rotating isolated auth (dir=${isolated_dir})"
		# XDG_DATA_HOME is already exported by caller; passing it explicitly here
		# makes the intent explicit in logs and protects against env stripping.
		if XDG_DATA_HOME="$isolated_dir" "$oauth_helper" rotate "$provider" >/dev/null 2>&1; then
			local new_email new_access new_label
			new_email=$(jq -r --arg p "$provider" '.[$p].email // empty' "$isolated_auth" 2>/dev/null || echo "")
			new_access=$(jq -r --arg p "$provider" '.[$p].access // empty' "$isolated_auth" 2>/dev/null || echo "")
			if [[ "${AIDEVOPS_PRIVATE_WORKLOAD:-0}" == "1" ]]; then
				new_label="[private]"
			elif [[ -n "$new_email" ]]; then
				new_label="$new_email"
			elif [[ -n "$new_access" ]]; then
				new_label="access credential"
			else
				new_label="$_HRW_STATUS_UNKNOWN"
			fi
			print_info "[lifecycle] pre_dispatch_rotate: ${provider} ${identity_label} -> ${new_label}"
		else
			print_warning "[lifecycle] pre_dispatch_rotate failed for ${provider}; continuing with current account"
		fi
	fi

	return 0
}

#######################################
# _launch_rate_limit_fast_monitor: background 30s sentinel that detects
# Anthropic 429 / provider-overload patterns on the FIRST API call and
# kills the worker cleanly before the 20-min opencode retry zombie forms.
#
# GH#21578 / t3021 — Three simultaneous workers were killed at t=20min
# (exit 143, duration_ms ~1.2M) because opencode silently retried a 429
# for the full slot lifetime. Each zombie blocked one dispatch slot.
#
# Strategy: poll output_file every 5s for monitor_window seconds (default 30).
# If rate-limit / HTTP-5xx patterns appear AND the worker produced no LLM
# activity yet (JSON events), SIGTERM the worker, write exit_code=0 and the
# .rate_limit_fast sentinel next to exit_code_file, then exit.
# _execute_run_attempt reads the sentinel and routes to exit 80, which
# cmd_run handles without incrementing the fast-fail / NMR counter.
#
# Args:
#   $1 output_file      — tee'd worker output file to monitor
#   $2 worker_pid       — the worker subshell PID to kill on detection
#   $3 exit_code_file   — path for writing exit_code=0 + creating sentinel
#   $4 monitor_window   — seconds to watch (default: 30)
#
# Returns: 0 always (launched in background; caller captures PID via $!)
#######################################
_launch_rate_limit_fast_monitor() {
	local output_file="$1"
	local worker_pid="$2"
	local exit_code_file="$3"
	local monitor_window="${4:-30}"
	local poll_interval=5

	(
		set +e
		local elapsed=0
		local sentinel="${exit_code_file}.rate_limit_fast"

		while [[ "$elapsed" -lt "$monitor_window" ]]; do
			sleep "$poll_interval"
			elapsed=$((elapsed + poll_interval))

			# Exit cleanly if the worker already finished on its own.
			if ! kill -0 "$worker_pid" 2>/dev/null; then
				return 0
			fi

			# Only fire if no LLM activity has been produced yet.
			# If the model already started working (step_start, tool, etc.),
			# this is not a dead-on-arrival rate limit — let the watchdog handle it.
			if [[ -f "$output_file" ]] && grep -q '"type"' "$output_file" 2>/dev/null; then
				return 0
			fi

			# Check for rate-limit / provider-overload patterns in the output.
			# Patterns mirror classify_failure_reason() in headless-runtime-lib.sh.
			if [[ -f "$output_file" ]] && \
				grep -qiE '(429|rate.?limit|too.many.requests|overloaded|service.unavailable|internal.server.error|50[0-9] )' \
				"$output_file" 2>/dev/null; then
				# Kill the worker cleanly — this is a transient API condition.
				kill -TERM "$worker_pid" 2>/dev/null || true
				sleep 2
				kill -0 "$worker_pid" 2>/dev/null && kill -KILL "$worker_pid" 2>/dev/null || true
				# Signal _execute_run_attempt to route as rate_limit_fast (exit 80).
				printf '%s' "0" >"$exit_code_file" 2>/dev/null || true
				printf '%s' "1" >"$sentinel" 2>/dev/null || true
				return 0
			fi
		done
		return 0
	) &
	printf '%s' "$!"
	return 0
}

# =============================================================================
# Claude CLI invocation
# =============================================================================

# _invoke_claude: run the claude CLI command and capture output.
# Same interface shape as _invoke_opencode (output/exit_code first), with an
# additional work_dir slot so the caller can set the child cwd via shell
# rather than a CLI flag.
#
# GH#21886: Claude CLI has no --cwd / --directory / --working-directory
# flag. Setting cwd MUST happen via `cd` in the parent shell before exec.
# This function isolates the cd in a subshell so it does not pollute the
# caller's PWD. Empty work_dir is allowed (no-op cd) for callers that
# legitimately want to inherit the current cwd.
#
# Kept in sync with _invoke_claude in headless-runtime-helper.sh; both
# definitions exist because this file is sourced separately by some entry
# points and we want either path to behave identically.
#
# Args: output_file exit_code_file work_dir cmd_args...
_invoke_claude() {
	local output_file="$1"
	local exit_code_file="$2"
	local work_dir="$3"
	shift 3
	local -a cmd=("$@")

	(
		set +e
		local egress_mode="${AIDEVOPS_WORKER_EGRESS_MODE:-auto}"
		local egress_worker_id="${AIDEVOPS_WORKER_ID:-${_invoke_session_key:-headless}}"
		# Set child cwd via shell since claude CLI has no flag for it.
		if [[ -n "$work_dir" ]]; then
			if ! cd "$work_dir"; then
				print_error "_invoke_claude: cd '$work_dir' failed (GH#21886)"
				printf '%s' "1" >"$exit_code_file"
				exit 1
			fi
		fi
		if [[ -x "$SANDBOX_EXEC_HELPER" && "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" != "1" ]]; then
			local passthrough_csv
			passthrough_csv="$(build_sandbox_passthrough_csv)"
			if [[ -n "$passthrough_csv" ]]; then
				if [[ -n "${_HEADLESS_CLAUDE_STDIN_FILE:-}" && -f "${_HEADLESS_CLAUDE_STDIN_FILE:-}" ]]; then
					"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --egress-mode "$egress_mode" --worker-id "$egress_worker_id" --passthrough "$passthrough_csv" -- "${cmd[@]}" <"$_HEADLESS_CLAUDE_STDIN_FILE" 2>&1 | tee "$output_file"
				else
					"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --egress-mode "$egress_mode" --worker-id "$egress_worker_id" --passthrough "$passthrough_csv" -- "${cmd[@]}" 2>&1 | tee "$output_file"
				fi
			else
				if [[ -n "${_HEADLESS_CLAUDE_STDIN_FILE:-}" && -f "${_HEADLESS_CLAUDE_STDIN_FILE:-}" ]]; then
					"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --egress-mode "$egress_mode" --worker-id "$egress_worker_id" -- "${cmd[@]}" <"$_HEADLESS_CLAUDE_STDIN_FILE" 2>&1 | tee "$output_file"
				else
					"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --egress-mode "$egress_mode" --worker-id "$egress_worker_id" -- "${cmd[@]}" 2>&1 | tee "$output_file"
				fi
			fi
			printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
		else
			if [[ "$egress_mode" == "required" ]]; then
				print_error "Whole-process worker egress is required, but the sandbox launcher is disabled or unavailable"
				printf '%s' "126" >"$exit_code_file"
				exit 126
			fi
			if [[ "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" == "1" ]]; then
				print_info "AIDEVOPS_HEADLESS_SANDBOX_DISABLED=1 — using bare timeout (no privilege isolation) (GH#20146 audit)"
			fi
			if [[ -n "${_HEADLESS_CLAUDE_STDIN_FILE:-}" && -f "${_HEADLESS_CLAUDE_STDIN_FILE:-}" ]]; then
				timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" "${cmd[@]}" <"$_HEADLESS_CLAUDE_STDIN_FILE" 2>&1 | tee "$output_file"
			else
				timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" "${cmd[@]}" 2>&1 | tee "$output_file"
			fi
			printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
		fi
	) || true
	return 0
}

# =============================================================================
# Output preservation and classification
# =============================================================================

#######################################
# t2119: Preserve a worker output file on no_activity failure so operators
# can diagnose why the runtime exited without ever producing JSON events.
#
# Before t2119, _handle_run_result unconditionally `rm -f "$output_file"`
# on the no_activity path, erasing the only forensic evidence (opencode
# stderr via tee, plugin startup log lines, sandbox exec trace). This
# left the residual 30s failures observed in the t2116 session with zero
# diagnostic surface.
#
# Strategy: move (not copy — keeps disk usage bounded) the output file
# to ~/.aidevops/logs/worker-no-activity/<session>-<ts>.log. Size-cap
# each preserved file to 256KB (worker output files rarely exceed this;
# truncation is fine for forensic purposes). Retention-cap the directory
# to the 50 most recent files so the log directory doesn't grow
# unbounded on a looping failure.
#
# Best-effort throughout — a preservation failure must never propagate
# into the caller's error-handling path. The goal is forensics, not
# hard-guaranteed persistence.
#
# Args:
#   $1 - output_file path
#   $2 - session_key (e.g. issue-19114 or pulse)
#   $3 - model (for filename disambiguation; slashes stripped)
#######################################
_preserve_no_activity_output() {
	local output_file="$1"
	local session_key="${2:-unknown}"
	local model="${3:-unknown}"

	if [[ -z "$output_file" || ! -f "$output_file" ]]; then
		return 0
	fi
	if _headless_private_workload_enabled; then
		rm -f "$output_file" 2>/dev/null || true
		return 0
	fi

	local diag_dir="${HOME}/.aidevops/logs/worker-no-activity"
	if ! mkdir -p "$diag_dir" 2>/dev/null; then
		# Fall back to the original delete behaviour if the diagnostic
		# directory can't be created — we must not keep tmp files around.
		rm -f "$output_file" 2>/dev/null || true
		return 0
	fi

	# Sanitize session + model for use in a filename.
	local safe_session safe_model
	safe_session=$(printf '%s' "$session_key" | tr '/ ' '__' | tr -cd 'A-Za-z0-9._-' | cut -c1-64)
	safe_model=$(printf '%s' "$model" | tr '/ ' '__' | tr -cd 'A-Za-z0-9._-' | cut -c1-32)
	[[ -n "$safe_session" ]] || safe_session="$_HRW_STATUS_UNKNOWN"
	[[ -n "$safe_model" ]] || safe_model="$_HRW_STATUS_UNKNOWN"

	local ts
	ts=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)
	local dest="${diag_dir}/${ts}-${safe_session}-${safe_model}.log"

	# Size-cap: take the first 256KB of the output. For the no_activity
	# failure mode the interesting content (plugin init errors, opencode
	# startup logs, migration output, auth refresh messages) always
	# lands in the first few KB; anything past 256KB is noise.
	local max_bytes=262144
	if head -c "$max_bytes" "$output_file" >"$dest" 2>/dev/null; then
		local orig_size
		orig_size=$(wc -c <"$output_file" 2>/dev/null | tr -d ' ') || orig_size=0
		if [[ "$orig_size" -gt "$max_bytes" ]]; then
			printf '\n\n[...t2119 TRUNCATED at %d bytes, original %d bytes...]\n' \
				"$max_bytes" "$orig_size" >>"$dest" 2>/dev/null || true
		fi
	fi

	rm -f "$output_file" 2>/dev/null || true

	# Retention cap: keep the 50 most recent preserved files.
	# ls -t returns newest first; tail -n +51 selects everything beyond the cap.
	# Using find -print0 | sort would be more robust but ls is enough for
	# our flat directory of predictable filenames.
	local keep=50
	local prune_list
	prune_list=$(cd "$diag_dir" 2>/dev/null && ls -1t -- *.log 2>/dev/null | tail -n +$((keep + 1))) || prune_list=""
	if [[ -n "$prune_list" ]]; then
		while IFS= read -r _victim; do
			[[ -n "$_victim" ]] || continue
			rm -f "${diag_dir}/${_victim}" 2>/dev/null || true
		done <<<"$prune_list"
	fi

	return 0
}

# =============================================================================
# Worker output classification
# =============================================================================

#######################################
# Resolve the repository default branch for worker-output guards.
#
# Args:
#   $1 - work_dir (worktree root; must be a git repo)
#######################################
_hrw_resolve_default_branch() {
	local work_dir="$1"
	local default_branch=""

	default_branch=$(git -C "$work_dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
	if [[ "$default_branch" == origin/* ]]; then
		default_branch="${default_branch#origin/}"
	fi

	if [[ -z "$default_branch" ]]; then
		for default_branch in main master; do
			if git -C "$work_dir" show-ref --verify --quiet "refs/remotes/origin/${default_branch}" 2>/dev/null || \
				git -C "$work_dir" show-ref --verify --quiet "refs/heads/${default_branch}" 2>/dev/null; then
				printf '%s' "$default_branch"
				return 0
			fi
		done
		default_branch=""
	fi

	if [[ -n "$default_branch" ]]; then
		printf '%s' "$default_branch"
		return 0
	fi

	return 0
}

#######################################
# Resolve the comparison base and count commits beyond it.
# Output: <default-branch>|<count|unknown>
# Args: $1=work_dir
#######################################
_hrw_worker_base_commit_state() {
	local work_dir="$1"
	local default_branch=""
	local commit_count=""

	default_branch=$(_hrw_resolve_default_branch "$work_dir")
	[[ -z "$default_branch" ]] && default_branch="${DISPATCH_REPO_DEFAULT_BRANCH:-main}"
	if commit_count=$(git -C "$work_dir" rev-list --count "origin/${default_branch}..${_HRW_GIT_HEAD}" 2>/dev/null) && \
		[[ "$commit_count" =~ ^[0-9]+$ ]]; then
		printf '%s|%s' "$default_branch" "$commit_count"
	else
		printf '%s|unknown' "$default_branch"
	fi
	return 0
}

#######################################
# Detect whether a worker produced any tangible output.
#
# Checks three independent signals. Returns 0 (true — has output) if ANY
# signal is present; returns 1 (false — zero output) only when ALL are absent.
#
# Args:
#   $1 - session_key (e.g. "issue-20721")
#   $2 - work_dir    (worktree root; must be a git repo)
#
# Signals checked (in order of cheapness):
#   1. Commits on feature branch beyond the resolved remote default branch
#      (git rev-list --count origin/<default>..HEAD > 0)
#   2. Branch pushed to remote
#      (git ls-remote origin refs/heads/<branch> is non-empty)
#   3. PR linked to this issue via gh
#      (gh pr list --search "<issue_number>" returns at least one result)
#
# Design principle — fail-open: every check that errors (no remote, no gh,
# detached HEAD, network failure) returns 0 so false-negatives are impossible.
# Only a confirmed absence of all three signals triggers a noop classification.
#######################################
# _worker_produced_output — classify worker output quality (GH#20819)
#
# Returns a concrete lifecycle/output classification via stdout:
#   "pr_exists"             — PR confirmed, or fail-open (cannot evaluate signals)
#   "branch_orphan"         — branch pushed + commits exist BUT no PR found
#                             (requires DISPATCH_REPO_SLUG + gh to confirm absence)
#   "local_branch_unpushed" — local branch has commits but no remote branch or PR
#   "dirty_worktree"        — uncommitted/untracked edits exist after a crash
#   "draft_checkpoint"      — exact-head worker draft (durable, incomplete)
#   "protected_draft"       — interactive/held/NMR/non-worker draft
#   "closed_unmerged"       — exact-head PR closed without merge
#   "unverified_open_pr"    — issue-search fallback cannot prove exact head
#   "head_mismatch"         — local HEAD is not the open PR head
#   "ready_missing_summary" — exact-head ready PR lacks MERGE_SUMMARY
#   "merged_missing_summary" — exact-head merged PR lacks MERGE_SUMMARY
#   "noop"                  — no commits, no pushed branch, no PR
#
# Fail-open semantics are preserved: any condition that prevents confident
# signal evaluation echoes "pr_exists" so false-negatives (real work
# misclassified as orphan or noop) are impossible.  Only a confirmed
# absence of all signals (noop), a confirmed remote branch-without-PR
# (branch_orphan), or a confirmed local committed branch-without-PR
# (local_branch_unpushed) triggers those classifications.
#
# Always returns 0. Callers capture stdout:
#   local classification
#   classification=$(_worker_produced_output "$session_key" "$work_dir")
#######################################
_worker_produced_output() {
	local session_key="$1"
	local work_dir="$2"

	# Only applies to worker sessions (issue-* key pattern)
	if [[ "$session_key" != issue-* ]]; then
		printf 'pr_exists'  # fail-open for non-worker sessions
		return 0
	fi

	# Bail if work_dir is not a valid git repo — fail-open
	if [[ -z "$work_dir" ]] || ! git -C "$work_dir" rev-parse --git-dir >/dev/null 2>&1; then
		printf 'pr_exists'  # fail-open: cannot evaluate signals
		return 0
	fi

	# Compare against the resolved default, not an assumed main/master base.
	local base_commit_state=""
	local default_branch=""
	local commit_count=""
	local has_commits=0
	local commit_comparison_known=0
	base_commit_state=$(_hrw_worker_base_commit_state "$work_dir")
	default_branch="${base_commit_state%%|*}"
	commit_count="${base_commit_state#*|}"
	if [[ "$commit_count" =~ ^[0-9]+$ ]]; then
		commit_comparison_known=1
		[[ "$commit_count" -gt 0 ]] && has_commits=1
	fi

	# Signal 2: a remote feature ref is output evidence only off the resolved
	# default branch (t2899).
	local has_pushed_branch=0
	local branch_name=""
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	if [[ -n "$branch_name" && "$branch_name" != "$_HRW_GIT_HEAD" && "$branch_name" != "$default_branch" ]]; then
		local remote_ref=""
		remote_ref=$(git -C "$work_dir" ls-remote origin "refs/heads/$branch_name" 2>/dev/null || true)
		[[ -n "$remote_ref" ]] && has_pushed_branch=1
	fi

	# A successful zero-count comparison proves the branch has no PR-able output,
	# even when a same-SHA feature ref already exists remotely. Check for dirty
	# edits first so crash recovery still preserves uncommitted work.
	if [[ "$has_commits" -eq 0 ]]; then
		local task_status=""
		if ! task_status=$(_hrw_worktree_task_status "$work_dir"); then
			printf 'pr_exists' # fail-open: cannot safely classify local state
			return 0
		fi
		if [[ -n "$task_status" ]]; then
			printf 'dirty_worktree'
			return 0
		fi
		if [[ "$commit_comparison_known" -eq 1 ]]; then
			printf 'noop'
			return 0
		fi
		if [[ "$has_pushed_branch" -eq 0 ]]; then
			printf 'pr_exists' # fail-open: resolved base ref could not be compared
			return 0
		fi
	fi
	# t2899: HEAD on default branch with commits ahead but no feature branch pushed.
	# This is "worker landed on main with local commits" — not an orphan branch.
	# Without a feature branch to recover, Signal 1 alone cannot produce a meaningful
	# branch_orphan classification, so collapse to noop.
	if [[ "$has_pushed_branch" -eq 0 && "$branch_name" == "$default_branch" ]]; then
		printf 'noop'
		return 0
	fi

	# Signal 3: exact-head lifecycle first; issue search is inconclusive fallback.
	local issue_number=""
	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local pr_handoff="unknown|"
	local pr_state="unknown"
	local local_head=""
	local_head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null || true)
	[[ -n "$local_head" ]] || local_head="missing-local-head"
	pr_handoff=$(_pr_handoff_state_for_branch_or_issue "$branch_name" "$issue_number" "$repo_slug" \
		"branch-or-issue" "$local_head" 1)
	pr_state="${pr_handoff%%|*}"
	case "$pr_state" in
		ready | merged) printf 'pr_exists'; return 0 ;;
		draft_checkpoint | protected_draft | closed_unmerged | unverified_open_pr | head_mismatch | ready_missing_summary | merged_missing_summary)
			printf '%s' "$pr_state"
			return 0
			;;
		absent)
			if [[ "$has_pushed_branch" -eq 1 ]]; then
				printf 'branch_orphan'
			else
				printf 'local_branch_unpushed'
			fi
			return 0
			;;
		*) printf 'pr_exists'; return 0 ;; # unknown -> fail-open
	esac
}

#######################################
# Escalate an exhausted draft or terminally failed ready PR. The claim is only
# released after the blocking NMR label is applied and read back. Failed or
# invisible transitions retain ownership so ordinary dispatch cannot race.
# Args: $1=session key, $2=repo slug, $3=lifecycle state, $4=release reason
#######################################
_escalate_worker_pr_checkpoint() {
	local session_key="$1"
	local repo_slug="$2"
	local lifecycle_state="$3"
	local release_reason="${4:-$_HRW_REASON_DRAFT_CHECKPOINT}"
	local issue_number=""
	local runner_login=""
	local -a transition_args=(--add-label "$_HRW_NMR_LABEL" --remove-label "auto-dispatch")

	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)
	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		_HRW_RECOVERY_CLASSIFICATION="$_HRW_REASON_DRAFT_ESCALATION_FAILED"
		print_warning "[lifecycle] ${_HRW_RECOVERY_CLASSIFICATION} session=${session_key} — issue/repo unavailable; retaining claim"
		return 0
	fi
	if declare -F _hrff_resolve_release_runner_login >/dev/null 2>&1; then
		runner_login=$(_hrff_resolve_release_runner_login)
		[[ -n "$runner_login" ]] && transition_args+=(--remove-assignee "$runner_login")
	fi
	if declare -F set_issue_status >/dev/null 2>&1; then
		if ! set_issue_status "$issue_number" "$repo_slug" "" "${transition_args[@]}"; then
			_HRW_RECOVERY_CLASSIFICATION="$_HRW_REASON_DRAFT_ESCALATION_FAILED"
			print_warning "[lifecycle] ${_HRW_RECOVERY_CLASSIFICATION} session=${session_key} — blocking transition failed; retaining claim"
			return 0
		fi
	elif ! gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-label "$_HRW_NMR_LABEL" --remove-label "auto-dispatch" >/dev/null 2>&1; then
		_HRW_RECOVERY_CLASSIFICATION="$_HRW_REASON_DRAFT_ESCALATION_FAILED"
		print_warning "[lifecycle] ${_HRW_RECOVERY_CLASSIFICATION} session=${session_key} — blocking transition failed; retaining claim"
		return 0
	fi
	if ! _worker_pr_checkpoint_block_visible "$issue_number" "$repo_slug"; then
		_HRW_RECOVERY_CLASSIFICATION="$_HRW_REASON_DRAFT_ESCALATION_FAILED"
		print_warning "[lifecycle] ${_HRW_RECOVERY_CLASSIFICATION} session=${session_key} — blocking label not visible; retaining claim"
		return 0
	fi

	_hrw_release_dispatch_claim "$session_key" "$release_reason"
	_HRW_RECOVERY_CLASSIFICATION="$release_reason"
	print_warning "[lifecycle] worker_pr_checkpoint_escalated session=${session_key} state=${lifecycle_state} — maintainer review required"
	return 0
}

_worker_pr_checkpoint_block_visible() {
	local issue_number="$1"
	local repo_slug="$2"
	gh issue view "$issue_number" --repo "$repo_slug" --json labels 2>/dev/null \
		| jq -e --arg nmr "$_HRW_NMR_LABEL" '([.labels[]?.name] | index($nmr)) != null' >/dev/null 2>&1
	return $?
}

# =============================================================================
# Orphan handling
# =============================================================================

#######################################
# _increment_orphan_count_stat — increment worker_branch_orphan_count in pulse-stats.json
#
# Uses pulse_stats_increment if available (pulse-stats-helper.sh is sourced
# in pulse-wrapper.sh context); otherwise does an inline jq atomic update
# using the same timestamp-array format for consistency.
#
# Non-fatal: any file/jq failure is silently ignored.
#######################################
_increment_orphan_count_stat() {
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "worker_branch_orphan_count" 2>/dev/null || true
		return 0
	fi
	# Inline fallback: timestamp-array format (matches pulse-stats-helper.sh schema)
	local _stats_file="${PULSE_STATS_FILE:-${HOME}/.aidevops/logs/pulse-stats.json}"
	local _stats_dir
	_stats_dir="$(dirname "$_stats_file")"
	[[ -d "$_stats_dir" ]] || mkdir -p "$_stats_dir" 2>/dev/null || return 0
	[[ -f "$_stats_file" ]] || printf '{"counters":{}}\n' >"$_stats_file" 2>/dev/null || return 0
	local _ts _tmp
	_ts=$(date +%s 2>/dev/null) || _ts=0
	# t2997: drop .json — XXXXXX must be at end for BSD mktemp.
	_tmp=$(mktemp "${TMPDIR:-/tmp}/pulse-stats-orphan-XXXXXX") || return 0
	jq --argjson ts "$_ts" \
		'.counters.worker_branch_orphan_count += [$ts]' \
		"$_stats_file" >"$_tmp" 2>/dev/null \
		|| { rm -f "$_tmp"; return 0; }
	mv "$_tmp" "$_stats_file" 2>/dev/null || rm -f "$_tmp"
	return 0
}

#######################################
# _handle_worker_branch_orphan — recover from worker_branch_orphan state (GH#20819)
#
# Called from _cmd_run_finish when _worker_produced_output returns "branch_orphan":
# the worker pushed commits/branch but exited before opening a PR.
#
# Actions:
#   1. Increments worker_branch_orphan_count in pulse-stats.json (always)
#   2. Calls _attempt_orphan_recovery_pr to open a PR (GH#20819)
#   3. On PR success  → releases claim as "worker_complete" (audit note)
#   4. On PR failure  → releases claim as "worker_branch_orphan" + posts
#      structured ops comment on the issue so next dispatch can pick up
#
# Args: $1=session_key, $2=work_dir
#######################################
_handle_worker_branch_orphan() {
	local session_key="$1"
	local work_dir="$2"

	local branch_name=""
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local issue_number=""
	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)

	# t2899: extended diagnostic — surface what the worker actually produced so
	# the next regression in this classifier is debuggable from a single log line.
	# target_branch is the branch the worker was DISPATCHED to operate on
	# (set by the dispatch path via WORKER_TARGET_BRANCH env if present);
	# final_head is the HEAD SHA the worker exited on; ahead_count is commits
	# ahead of origin/$base_branch (configured PR base branch, fallback to
	# origin/master when the primary ref is missing); work_dir is the worktree path.
	local target_branch="${WORKER_TARGET_BRANCH:-<unset>}"
	local head_ref="HE""AD"
	local final_head=""
	final_head=$(git -C "$work_dir" rev-parse --short=12 "$head_ref" 2>/dev/null || printf '<unreadable>')
	local ahead_count=0
	local base_branch=""
	base_branch=$(_resolve_orphan_recovery_base_branch "$repo_slug" "$work_dir")
	local rev_output=""
	# Fallback to master only when the primary ref is MISSING (non-zero exit),
	# not when the count happens to be zero (worker exited on default branch).
	if rev_output=$(git -C "$work_dir" rev-list --count "origin/${base_branch}..HEAD" 2>/dev/null); then
		ahead_count=$rev_output
	else
		ahead_count=$(git -C "$work_dir" rev-list --count "origin/master..HEAD" 2>/dev/null || echo 0)
	fi
	[[ "$ahead_count" =~ ^[0-9]+$ ]] || ahead_count=0

	print_info "[lifecycle] worker_branch_orphan session=${session_key} branch=${branch_name:-<none>} target_branch=${target_branch} final_head=${final_head} ahead_count=${ahead_count} work_dir=${work_dir:-<unset>}"

	# Always increment counter — failure or success
	_increment_orphan_count_stat

	if _attempt_orphan_recovery_pr "$session_key" "$work_dir" "$branch_name" "$repo_slug"; then
		print_info "[lifecycle] Orphan PR auto-created for session=${session_key}"
		_hrw_release_dispatch_claim "$session_key" "$_HRW_REASON_WORKER_COMPLETE"
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_SUCCESS"
	else
		print_info "[lifecycle] Orphan recovery failed for session=${session_key}"
		_hrw_release_dispatch_claim "$session_key" "worker_branch_orphan"
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_FAILED"
		# Post structured ops comment so the next dispatch knows what happened
		if [[ -n "$issue_number" && -n "$repo_slug" && -n "$branch_name" ]]; then
			local _ops_comment
			local _orphan_key="${repo_slug}#${issue_number}#${branch_name}#worker_branch_orphan"
			local _orphan_base_branch="main"
			if declare -F _resolve_orphan_recovery_base_branch >/dev/null 2>&1; then
				_orphan_base_branch=$(_resolve_orphan_recovery_base_branch "$repo_slug" "$work_dir")
			fi
			# shellcheck disable=SC2016 # backticks are literal markdown, not command substitution
			_ops_comment=$(printf '<!-- ops:start -->\n<!-- worker-branch-orphan:key=%s -->\nWORKER_BRANCH_ORPHAN branch=%s session=%s ts=%s\n\nThis worker pushed branch `%s` but no PR could be opened automatically. To recover, open a PR manually against the configured PR base branch:\n\n```\ngh pr create --head %s --base %s --repo %s\n```\n<!-- ops:end -->' \
				"$_orphan_key" \
				"$branch_name" "$session_key" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
				"$branch_name" "$branch_name" "$_orphan_base_branch" "$repo_slug")
			gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
				--method POST \
				--field body="$_ops_comment" \
				>/dev/null 2>&1 || true
		fi
	fi
	return 0
}

#######################################
# _handle_worker_local_branch_unpushed — recover local-only committed branch.
#
# Called from _cmd_run_finish when _worker_produced_output returns
# "local_branch_unpushed": the worker has local commits on a feature branch,
# but no remote branch and no PR were found. The shared orphan recovery helper
# safely pushes the branch before creating the PR; failure leaves a distinct,
# non-misleading recovery diagnostic for manual intervention (GH#25374).
#
# Args: $1=session_key, $2=work_dir
#######################################
_handle_worker_local_branch_unpushed() {
	local session_key="$1"
	local work_dir="$2"

	local branch_name=""
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local issue_number=""
	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)

	local target_branch="${WORKER_TARGET_BRANCH:-<unset>}"
	local head_ref="HE""AD"
	local final_head=""
	final_head=$(git -C "$work_dir" rev-parse --short=12 "$head_ref" 2>/dev/null || printf '<unreadable>')
	local ahead_count=0
	local base_branch=""
	base_branch=$(_resolve_orphan_recovery_base_branch "$repo_slug" "$work_dir")
	local rev_output=""
	if rev_output=$(git -C "$work_dir" rev-list --count "origin/${base_branch}..${head_ref}" 2>/dev/null); then
		ahead_count=$rev_output
	else
		local fallback_base_ref="origin/""master"
		ahead_count=$(git -C "$work_dir" rev-list --count "${fallback_base_ref}..${head_ref}" 2>/dev/null || printf '0')
	fi
	[[ "$ahead_count" =~ ^[0-9]+$ ]] || ahead_count=0

	print_info "[lifecycle] worker_local_branch_unpushed session=${session_key} branch=${branch_name:-<none>} target_branch=${target_branch} final_head=${final_head} ahead_count=${ahead_count} work_dir=${work_dir:-<unset>}"

	_increment_orphan_count_stat

	if _attempt_orphan_recovery_pr "$session_key" "$work_dir" "$branch_name" "$repo_slug"; then
		print_info "[lifecycle] Local branch pushed and recovery PR auto-created for session=${session_key}"
		local complete_reason="worker_"
		_hrw_release_dispatch_claim "$session_key" "${complete_reason}complete"
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_SUCCESS"
	else
		print_info "[lifecycle] Local branch recovery failed for session=${session_key}"
		_hrw_release_dispatch_claim "$session_key" "worker_local_branch_unpushed"
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_FAILED"
		if [[ -n "$issue_number" && -n "$repo_slug" && -n "$branch_name" ]]; then
			local _ops_comment
			local _local_key="${repo_slug}#${issue_number}#${branch_name}#worker_local_branch_unpushed"
			local _local_base_branch="main"
			local _local_head_ref="HE""AD"
			if declare -F _resolve_orphan_recovery_base_branch >/dev/null 2>&1; then
				_local_base_branch=$(_resolve_orphan_recovery_base_branch "$repo_slug" "$work_dir")
			fi
			# shellcheck disable=SC2016 # backticks are literal markdown, not command substitution
			_ops_comment=$(printf '<!-- ops:start -->\n<!-- worker-local-branch-unpushed:key=%s -->\nWORKER_LOCAL_BRANCH_UNPUSHED branch=%s session=%s ts=%s\n\nThis worker committed local changes on branch `%s`, but no remote branch or PR could be confirmed and automatic recovery failed. To recover, inspect the worker worktree, push the local branch, then open a PR manually against the configured PR base branch:\n\n```\ngit -C %s push origin %s:%s\ngh pr create --head %s --base %s --repo %s\n```\n<!-- ops:end -->' \
				"$_local_key" \
				"$branch_name" "$session_key" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
				"$branch_name" "$work_dir" "$_local_head_ref" "$branch_name" "$branch_name" "$_local_base_branch" "$repo_slug")
			gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
				--method POST \
				--field body="$_ops_comment" \
				>/dev/null 2>&1 || true
		fi
	fi
	return 0
}

#######################################
# _handle_worker_dirty_worktree — preserve uncommitted worker edits after crash.
#
# Local runtime failures can interrupt OpenCode after file edits but before the
# worker commits or opens a PR. Do not redispatch blindly; publish a structured
# ops marker so maintainers can inspect the runner-local worktree and recover the
# edits before cleanup or duplicate workers overwrite context.
#
# Args: $1=session_key, $2=work_dir
#######################################
_handle_worker_dirty_worktree() {
	local session_key="$1"
	local work_dir="$2"
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local issue_number=""
	if declare -F _scl_worker_issue_number >/dev/null 2>&1; then
		issue_number=$(_scl_worker_issue_number "$session_key")
	fi

	local branch_name=""
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	local status_summary=""
	status_summary=$(git -C "$work_dir" status --short 2>/dev/null | sed -n '1,50p' || true)
	[[ -n "$status_summary" ]] || status_summary="<dirty state unavailable>"
	local runner_key=""
	runner_key=$(runner_identity_key)

	# Persist the full runner-local recovery context before any GitHub write.
	# The ledger retains the private worktree path; the public marker below uses
	# only a non-identifying runner key and repository-relative changed paths.
	if [[ -x "${DISPATCH_LEDGER_HELPER:-}" ]]; then
		"$DISPATCH_LEDGER_HELPER" record-recovery \
			--session-key "$session_key" \
			--runner-key "$runner_key" \
			--worktree "$work_dir" \
			--branch "$branch_name" \
			--changed-paths "$status_summary" \
			--recoverability "same-runner" 2>/dev/null || true
	fi

	print_info "[lifecycle] worker_dirty_worktree session=${session_key} branch=${branch_name:-<none>} work_dir_present=$([[ -d "$work_dir" ]] && printf 1 || printf 0)"

	# The finish path can classify dirty work before the EXIT trap runs. Give the
	# owning runner two bounded opportunities to checkpoint, push, and open the
	# recovery PR now instead of globally pausing all dispatchers.
	local previous_worktree_path="${_WORKER_WORKTREE_PATH:-}"
	local recovered=0
	_WORKER_WORKTREE_PATH="$work_dir"
	if declare -F _push_wip_commits_on_exit >/dev/null 2>&1 && declare -F _recover_dirty_worker_pr >/dev/null 2>&1; then
		local recovery_attempt=1
		while [[ "$recovery_attempt" -le 2 ]]; do
			_push_wip_commits_on_exit
			if _recover_dirty_worker_pr "$session_key"; then
				recovered=1
				break
			fi
			recovery_attempt=$((recovery_attempt + 1))
		done
	fi
	_WORKER_WORKTREE_PATH="$previous_worktree_path"

	if [[ "$recovered" -eq 1 ]]; then
		if [[ -x "${DISPATCH_LEDGER_HELPER:-}" ]]; then
			"$DISPATCH_LEDGER_HELPER" record-recovery \
				--session-key "$session_key" \
				--runner-key "$runner_key" \
				--worktree "$work_dir" \
				--branch "$branch_name" \
				--changed-paths "$status_summary" \
				--recoverability "checkpointed" 2>/dev/null || true
		fi
		_hrw_release_dispatch_claim "$session_key" "$_HRW_REASON_DRAFT_CHECKPOINT"
		_HRW_RECOVERY_CLASSIFICATION="$_HRW_REASON_DRAFT_CHECKPOINT"
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_DEFERRED"
		_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_DEFERRED"
		_HRW_FINAL_RUNTIME_STATUS="checkpointed"
		_HRW_FINAL_RUNTIME_CLASSIFICATION="$_HRW_REASON_DRAFT_CHECKPOINT"
		print_info "[lifecycle] worker_dirty_worktree_checkpointed session=${session_key} branch=${branch_name:-<none>}"
		return 0
	fi

	_hrw_release_dispatch_claim "$session_key" "worker_dirty_worktree"
	_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_FAILED"

	if [[ -n "$issue_number" && -n "$repo_slug" ]]; then
		local _ops_comment
		local _dirty_key="${repo_slug}#${issue_number}#${branch_name:-unknown}#worker_dirty_worktree"
		local _comments_endpoint="repos/${repo_slug}/issues/${issue_number}/com""ments"
		# shellcheck disable=SC2016 # backticks are literal markdown, not command substitution
		_ops_comment=$(printf '<!-- ops:start -->\n<!-- worker-dirty-worktree:key=%s -->\nWORKER_DIRTY_WORKTREE branch=%s session=%s runner_key=%s recoverability=same-runner ts=%s\n\nThe owning runner could not create a pushed checkpoint during bounded teardown recovery. Its dispatch ledger retains the private worktree path. Prefer same-runner resume while that worktree exists; cross-runner takeover is allowed only after the bounded recovery hold expires.\n\nChanged paths reported by git status on the owning runner:\n\n```\n%s\n```\n<!-- ops:end -->' \
			"$_dirty_key" \
			"${branch_name:-unknown}" "$session_key" "$runner_key" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			"$status_summary")
		local existing_marker_count="0"
		existing_marker_count=$(gh api "${_comments_endpoint}?per_page=100" 2>/dev/null | jq -r --arg key "worker-dirty-worktree:key=${_dirty_key}" '[.[] | select((.body // "") | contains($key))] | length' 2>/dev/null || printf '0')
		if [[ "$existing_marker_count" == "0" ]]; then
			gh api "$_comments_endpoint" \
				--method POST \
				--field body="$_ops_comment" \
				>/dev/null 2>&1 || true
		fi
	fi
	return 0
}

#######################################
# Recover tangible worker output on failure paths.
#
# Watchdog/SIGKILL exits can happen after a worker has already pushed a branch
# or opened a PR. The historical failure path released those as worker_failed,
# causing duplicate redispatch even though recoverable output existed. This
# helper mirrors the success-path output classifier, but only treats confirmed
# signals as recovered so fail-open/unknown checks still fall through to normal
# failure handling.
#
# Args: $1=session_key, $2=work_dir
# Returns: 0 if recovery released the claim, 1 if caller should continue failure.
#######################################
_recover_worker_output_on_failure() {
	local session_key="$1"
	local work_dir="$2"

	[[ -n "$work_dir" && -d "$work_dir" ]] || return 1
	[[ "$session_key" == issue-* ]] || return 1

	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local branch_name=""
	local issue_number=""
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)

	local default_branch=""
	default_branch=$(_hrw_resolve_default_branch "$work_dir")
	[[ -z "$default_branch" ]] && default_branch="${DISPATCH_REPO_DEFAULT_BRANCH:-main}"

	_HRW_RECOVERY_CLASSIFICATION=""
	if [[ -n "$repo_slug" && -n "$issue_number" && -n "$branch_name" && "$branch_name" != "$_HRW_GIT_HEAD" && "$branch_name" != "$default_branch" ]] && \
		declare -F _pr_handoff_state_for_branch_or_issue >/dev/null 2>&1; then
		local pr_handoff="unknown|"
		local local_head=""
		local_head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null || true)
		[[ -n "$local_head" ]] || local_head="missing-local-head"
		pr_handoff=$(_pr_handoff_state_for_branch_or_issue "$branch_name" "$issue_number" "$repo_slug" \
			"branch-or-issue" "$local_head" 1)
		local pr_state="${pr_handoff%%|*}"
		if [[ "$pr_state" == "ready" || "$pr_state" == "merged" ]]; then
			print_info "[lifecycle] worker_failure_recovered_existing_pr session=${session_key} branch=${branch_name}"
			_hrw_release_dispatch_claim "$session_key" "$_HRW_REASON_WORKER_COMPLETE"
			_HRW_RECOVERY_CLASSIFICATION="$_HRW_REASON_WORKER_COMPLETE"
			return 0
		fi
		if [[ "$pr_state" == "draft_checkpoint" ]]; then
			_escalate_worker_pr_checkpoint "$session_key" "$repo_slug" "$pr_state"
			return 0
		fi
		if [[ "$pr_state" == "protected_draft" || "$pr_state" == "unverified_open_pr" || \
			"$pr_state" == "head_mismatch" || "$pr_state" == "ready_missing_summary" || \
			"$pr_state" == "merged_missing_summary" ]]; then
			_HRW_RECOVERY_CLASSIFICATION="worker_${pr_state}"
			print_warning "[lifecycle] ${_HRW_RECOVERY_CLASSIFICATION} session=${session_key} — not completion evidence; retaining claim"
			return 0
		fi
	fi

	local output_class=""
	output_class=$(_worker_produced_output "$session_key" "$work_dir")
	if [[ "$output_class" == "branch_orphan" ]]; then
		print_info "[lifecycle] worker_failure_recovering_branch_orphan session=${session_key} branch=${branch_name:-<none>}"
		_handle_worker_branch_orphan "$session_key" "$work_dir"
		return 0
	fi
	if [[ "$output_class" == "local_branch_unpushed" ]]; then
		print_info "[lifecycle] worker_failure_recovering_local_branch_unpushed session=${session_key} branch=${branch_name:-<none>}"
		_handle_worker_local_branch_unpushed "$session_key" "$work_dir"
		return 0
	fi
	if [[ "$output_class" == "dirty_worktree" ]]; then
		print_info "[lifecycle] worker_failure_preserving_dirty_worktree session=${session_key} branch=${branch_name:-<none>}"
		_handle_worker_dirty_worktree "$session_key" "$work_dir"
		return 0
	fi

	return 1
}

#######################################
# Return success when GitHub already shows the worker target as terminal.
#
# A worker can be interrupted after it merged a PR and the linked issue closed.
# In that case the local process lacks a completion signal, but redispatching is
# noise. Only confirmed terminal GitHub state returns 0; unknown/API failures
# return 1 so normal failure handling remains conservative.
#
# Args: $1=session_key, $2=work_dir (optional, used to resolve branch)
#######################################
_worker_external_terminal_complete() {
	local session_key="$1"
	local work_dir="$2"
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local issue_number=""

	[[ "$session_key" == issue-* ]] || return 1
	[[ -n "$repo_slug" ]] || return 1

	if [[ "$session_key" =~ ([0-9]+)$ ]]; then
		issue_number="${BASH_REMATCH[1]}"
	fi
	[[ -n "$issue_number" ]] || return 1
	command -v gh >/dev/null 2>&1 || return 1

	local issue_state=""
	issue_state=$(gh issue view "$issue_number" --repo "$repo_slug" --json state --jq '.state // empty' 2>/dev/null || true)
	[[ "$issue_state" == "CLOSED" ]] || return 1

	local branch_name="${WORKER_TARGET_BRANCH:-}"
	if [[ -n "$work_dir" && -d "$work_dir" ]]; then
		local live_branch_name=""
		live_branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
		if [[ -n "$live_branch_name" && "$live_branch_name" != "$_HRW_GIT_HEAD" ]]; then
			branch_name="$live_branch_name"
		fi
	fi
	[[ -n "$branch_name" && "$branch_name" != "$_HRW_GIT_HEAD" ]] || return 1

	local branch_pr_numbers=""
	branch_pr_numbers=$(gh pr list --repo "$repo_slug" --head "$branch_name" --state merged --json number --jq '.[].number' 2>/dev/null || true)
	[[ -n "$branch_pr_numbers" ]] || return 1

	local issue_pr_numbers=""
	issue_pr_numbers=$(gh pr list --repo "$repo_slug" --state merged --search "$issue_number" --json number --jq '.[].number' 2>/dev/null || true)
	[[ -n "$issue_pr_numbers" ]] || return 1

	local branch_pr_number=""
	local padded_issue_prs=$'\n'"$issue_pr_numbers"$'\n'
	while IFS= read -r branch_pr_number; do
		[[ -n "$branch_pr_number" ]] || continue
		if [[ "$padded_issue_prs" == *$'\n'"$branch_pr_number"$'\n'* ]]; then
			print_info "[lifecycle] worker_external_terminal complete session=${session_key} issue=${issue_number} branch=${branch_name} pr=${branch_pr_number}"
			return 0
		fi
	done <<<"$branch_pr_numbers"

	return 1
}

# =============================================================================
# Run lifecycle — prepare, finish, retry, detach
# =============================================================================

_hrw_current_worktree_branch() {
	local work_dir="$1"
	local branch=""

	branch=$(git -C "$work_dir" branch --show-current 2>/dev/null || true)
	if [[ -z "$branch" ]]; then
		branch="detached"
	fi
	printf '%s\n' "$branch"
	return 0
}

_hrw_epoch_seconds_from_iso() {
	local iso_ts="$1"
	[[ -n "$iso_ts" ]] || return 1
	python3 - "$iso_ts" <<'PY' 2>/dev/null || return 1
import datetime
import sys

value = sys.argv[1].strip()
if value.endswith("Z"):
    value = value[:-1] + "+00:00"
print(int(datetime.datetime.fromisoformat(value).timestamp()))
PY
	return 0
}

_hrw_worktree_task_status() {
	local work_dir="$1"
	local status_output=""
	status_output=$(git -C "$work_dir" status --porcelain 2>/dev/null) || return 1

	# Heal markers created by the pre-t18098 exclusion helper. This exemption is
	# intentionally exact and macOS-only: every other untracked or modified path
	# remains task state and continues to block ownership transfer or trigger
	# recovery. An empty regular file proves the known Spotlight marker shape.
	if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" && \
		-f "${work_dir}/${_HRW_SPOTLIGHT_MARKER}" && ! -L "${work_dir}/${_HRW_SPOTLIGHT_MARKER}" && \
		! -s "${work_dir}/${_HRW_SPOTLIGHT_MARKER}" ]] && \
		printf '%s\n' "$status_output" | grep -Fqx "?? ${_HRW_SPOTLIGHT_MARKER}"; then
		local exclude_file=""
		exclude_file=$(git -C "$work_dir" rev-parse --git-path info/exclude 2>/dev/null) || return 1
		[[ -n "$exclude_file" ]] || return 1
		if [[ "$exclude_file" != /* ]]; then
			exclude_file="${work_dir}/${exclude_file}"
		fi
		[[ -f "$exclude_file" ]] || return 1
		if ! grep -Fqx "/${_HRW_SPOTLIGHT_MARKER}" "$exclude_file" 2>/dev/null; then
			printf '/%s\n' "$_HRW_SPOTLIGHT_MARKER" >>"$exclude_file" 2>/dev/null || return 1
		fi
		git -C "$work_dir" check-ignore --quiet --no-index -- "$_HRW_SPOTLIGHT_MARKER" 2>/dev/null || return 1
		status_output=$(git -C "$work_dir" status --porcelain 2>/dev/null) || return 1
	fi

	printf '%s' "$status_output"
	return 0
}

_hrw_worktree_clean_for_owner_reclaim() {
	local work_dir="$1"
	local status_output=""
	status_output=$(_hrw_worktree_task_status "$work_dir") || return 1
	[[ -z "$status_output" ]] || return 1

	local upstream_ref=""
	upstream_ref=$(git -C "$work_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
	if [[ -z "$upstream_ref" ]]; then
		if git -C "$work_dir" rev-parse --verify "origin/HEAD" >/dev/null 2>&1; then
			upstream_ref="origin/HEAD"
		elif git -C "$work_dir" rev-parse --verify "origin/main" >/dev/null 2>&1; then
			upstream_ref="origin/main"
		elif git -C "$work_dir" rev-parse --verify "origin/master" >/dev/null 2>&1; then
			upstream_ref="origin/master"
		else
			upstream_ref="$_HRW_GIT_HEAD"
		fi
	fi

	local upstream_ahead=""
	upstream_ahead=$(git -C "$work_dir" rev-list --count "${upstream_ref}..HEAD" 2>/dev/null) || return 1
	[[ "$upstream_ahead" =~ ^[0-9]+$ ]] || return 1
	[[ "$upstream_ahead" -eq 0 ]] || return 1

	return 0
}

_hrw_is_dispatch_precreate_owner() {
	local owner_session="$1"
	case "$owner_session" in
		dispatch-precreate | dispatch-precreate-*) return 0 ;;
	esac
	return 1
}

_hrw_transfer_worktree_owner_snapshot() {
	local session_key="$1"
	local work_dir="$2"
	local branch="$3"
	local owner_pid="$4"
	local owner_session="$5"
	local owner_batch="$6"
	local owner_task="$7"
	local created_at="$8"

	transfer_worktree_ownership_if_expected "$work_dir" "$branch" \
		--session "$session_key" \
		--task "${WORKER_ISSUE_NUMBER:-}" \
		--owner-pid "$$" \
		--expected-owner-pid "$owner_pid" \
		--expected-session "$owner_session" \
		--expected-batch "$owner_batch" \
		--expected-task "$owner_task" \
		--expected-created-at "$created_at" || return 1
	return 0
}

_hrw_transfer_authorized_continuation_owner() {
	local session_key="$1"
	local work_dir="$2"
	local branch="$3"
	local expected_owner_pid="${AIDEVOPS_WORKTREE_EXPECTED_OWNER_PID:-}"
	local expected_owner_session="${AIDEVOPS_WORKTREE_EXPECTED_OWNER_SESSION:-}"
	local expected_owner_batch="${AIDEVOPS_WORKTREE_EXPECTED_OWNER_BATCH:-}"
	local expected_owner_task="${AIDEVOPS_WORKTREE_EXPECTED_OWNER_TASK:-}"
	local expected_owner_created_at="${AIDEVOPS_WORKTREE_EXPECTED_OWNER_CREATED_AT:-}"

	_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_CONTINUATION_STATE_REJECTED"
	[[ "$expected_owner_pid" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$expected_owner_session" && -n "$expected_owner_task" && -n "$expected_owner_created_at" ]] || return 1

	local owner_info=""
	owner_info=$(check_worktree_owner "$work_dir" 2>/dev/null || true)
	[[ -n "$owner_info" ]] || {
		_WORKER_PRELAUNCH_FAILURE_REASON="worker_worktree_continuation_owner_mismatch"
		return 1
	}

	local owner_pid="" owner_session="" owner_batch="" owner_task="" created_at=""
	IFS='|' read -r owner_pid owner_session owner_batch owner_task created_at <<<"$owner_info"
	if [[ -z "${WORKER_ISSUE_NUMBER:-}" || "$expected_owner_task" != "${WORKER_ISSUE_NUMBER:-}" ||
		"$owner_task" != "${WORKER_ISSUE_NUMBER:-}" ]]; then
		_WORKER_PRELAUNCH_FAILURE_REASON="worker_worktree_continuation_task_mismatch"
		return 1
	fi
	if [[ "$owner_pid" != "$expected_owner_pid" || "$owner_session" != "$expected_owner_session" ||
		"$owner_batch" != "$expected_owner_batch" || "$created_at" != "$expected_owner_created_at" ]]; then
		_WORKER_PRELAUNCH_FAILURE_REASON="worker_worktree_continuation_owner_mismatch"
		return 1
	fi

	if ! _hrw_transfer_worktree_owner_snapshot "$session_key" "$work_dir" "$branch" \
		"$owner_pid" "$owner_session" "$owner_batch" "$owner_task" "$created_at"; then
		_WORKER_PRELAUNCH_FAILURE_REASON="worker_worktree_continuation_concurrent_mutation"
		return 1
	fi

	print_info "[lifecycle] worker_worktree_continuation_owner_transferred session=${session_key} branch=${branch} path=${work_dir} previous_pid=${owner_pid} previous_session=${owner_session}"
	unset _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true
	return 0
}

_hrw_export_worker_worktree_owner_proof() {
	local session_key="$1"
	local work_dir="$2"
	local resolved_work_dir=""
	resolved_work_dir=$(cd "$work_dir" 2>/dev/null && pwd -P) || return 1

	export AIDEVOPS_WORKTREE_OWNER_PID="$$"
	export AIDEVOPS_WORKTREE_OWNER_SESSION="$session_key"
	export AIDEVOPS_WORKTREE_OWNER_TASK="${WORKER_ISSUE_NUMBER:-}"
	export AIDEVOPS_WORKTREE_OWNER_PATH="$resolved_work_dir"
	return 0
}

_hrw_reclaim_stale_worker_worktree_owner() {
	local session_key="$1"
	local work_dir="$2"
	local branch="$3"
	local owner_info=""

	owner_info=$(check_worktree_owner "$work_dir" 2>/dev/null || true)
	[[ -n "$owner_info" ]] || return 1

	local owner_pid="" owner_session="" owner_batch="" owner_task="" created_at=""
	IFS='|' read -r owner_pid owner_session owner_batch owner_task created_at <<<"$owner_info"

	if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
		if ! unregister_worktree_if_owner_pid "$work_dir" "$owner_pid" 2>/dev/null; then
			_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_OWNER_CONCURRENT_MUTATION"
			return 1
		fi
		print_info "[lifecycle] worker_worktree_reclaimed_dead_owner session=${session_key} branch=${branch} path=${work_dir} previous_pid=${owner_pid}"
		return 0
	fi

	_WORKER_PRELAUNCH_FAILURE_REASON="worker_worktree_live_owner"
	[[ -n "${WORKER_ISSUE_NUMBER:-}" && "$owner_task" == "${WORKER_ISSUE_NUMBER:-}" ]] || return 1

	# Dispatcher worktree pre-creation registers ownership to a live pulse
	# process before the detached worker starts. That owner is intentionally
	# short-lived and transferable; otherwise every worker sees a live owner,
	# exits immediately, and pulse retries the same issue forever.
	if _hrw_is_dispatch_precreate_owner "$owner_session"; then
		# Heal only the exact legacy infrastructure marker when possible, but
		# never make task-state cleanliness a prerequisite for transferring the
		# dispatcher's same-task placeholder owner.
		_hrw_worktree_task_status "$work_dir" >/dev/null 2>&1 || true
		if ! _hrw_transfer_worktree_owner_snapshot "$session_key" "$work_dir" "$branch" \
			"$owner_pid" "$owner_session" "$owner_batch" "$owner_task" "$created_at"; then
			_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_OWNER_CONCURRENT_MUTATION"
			return 1
		fi
		print_info "[lifecycle] worker_worktree_reclaimed_dispatch_precreate_owner session=${session_key} branch=${branch} path=${work_dir} previous_pid=${owner_pid} previous_session=${owner_session}"
		unset _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true
		return 0
	fi

	if [[ "${AIDEVOPS_ALLOW_WORKER_WORKTREE_OWNER_TRANSFER:-0}" == "1" ]]; then
		if ! _hrw_worktree_clean_for_owner_reclaim "$work_dir"; then
			_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_CONTINUATION_STATE_REJECTED"
			return 1
		fi
		if ! _hrw_transfer_worktree_owner_snapshot "$session_key" "$work_dir" "$branch" \
			"$owner_pid" "$owner_session" "$owner_batch" "$owner_task" "$created_at"; then
			_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_OWNER_CONCURRENT_MUTATION"
			return 1
		fi
		print_info "[lifecycle] worker_worktree_reclaimed_authorized_owner session=${session_key} branch=${branch} path=${work_dir} previous_pid=${owner_pid} previous_session=${owner_session}"
		unset _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true
		return 0
	fi

	[[ -n "$created_at" ]] || return 1

	local now_epoch="" created_epoch=""
	now_epoch=$(date +%s 2>/dev/null || true)
	created_epoch=$(_hrw_epoch_seconds_from_iso "$created_at" 2>/dev/null || true)
	[[ "$now_epoch" =~ ^[0-9]+$ && "$created_epoch" =~ ^[0-9]+$ ]] || return 1

	local owner_age_s=$((now_epoch - created_epoch))
	local reclaim_age_s="${AIDEVOPS_WORKER_WORKTREE_OWNER_RECLAIM_AGE_SECONDS:-900}"
	[[ "$reclaim_age_s" =~ ^[0-9]+$ ]] || reclaim_age_s=900
	[[ "$owner_age_s" -ge "$reclaim_age_s" ]] || return 1

	if ! _hrw_worktree_clean_for_owner_reclaim "$work_dir"; then
		_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_CONTINUATION_STATE_REJECTED"
		return 1
	fi

	if ! _hrw_transfer_worktree_owner_snapshot "$session_key" "$work_dir" "$branch" \
		"$owner_pid" "$owner_session" "$owner_batch" "$owner_task" "$created_at"; then
		_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_OWNER_CONCURRENT_MUTATION"
		return 1
	fi
	print_warning "[lifecycle] worker_worktree_reclaimed_stale_live_owner session=${session_key} branch=${branch} path=${work_dir} previous_pid=${owner_pid} age_s=${owner_age_s}"
	unset _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true
	return 0
}

_hrw_claim_worker_worktree() {
	local session_key="$1"
	local work_dir="$2"

	# Only dispatcher-created issue workers need this transfer. Interactive
	# sessions already hold either a registry entry or an interactive claim stamp.
	if [[ -z "${WORKER_ISSUE_NUMBER:-}" || -z "$work_dir" || ! -d "$work_dir" ]]; then
		return 0
	fi

	local branch=""
	branch=$(_hrw_current_worktree_branch "$work_dir")
	local transfer_mode="${AIDEVOPS_WORKTREE_OWNER_TRANSFER_MODE:-}"
	if [[ -n "$transfer_mode" ]]; then
		if [[ "$transfer_mode" != "continuation" ]]; then
			_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_CONTINUATION_STATE_REJECTED"
			print_error "[fatal] unsupported worker worktree transfer mode: ${transfer_mode}"
			return 1
		fi
		if _hrw_transfer_authorized_continuation_owner "$session_key" "$work_dir" "$branch"; then
			_hrw_export_worker_worktree_owner_proof "$session_key" "$work_dir" || return 1
			print_info "[lifecycle] worker_worktree_claimed session=${session_key} branch=${branch} path=${work_dir} pid=$$ mode=continuation"
			return 0
		fi
		print_error "[fatal] worker worktree continuation transfer rejected: ${work_dir} reason=${_WORKER_PRELAUNCH_FAILURE_REASON:-worker_worktree_live_owner}"
		return 1
	fi

	# t3550: dispatcher pre-creation registers the worktree to a short-lived
	# pulse subshell. After that subshell exits, cleanup sees a dead owner and
	# can remove the worker's cwd while validators/merge-gate fixes still run.
	# Transfer ownership to the long-lived headless-runtime-helper PID so
	# worktree cleanup treats the active worker as the canonical owner.
	unset _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true
	if ! claim_worktree_ownership "$work_dir" "$branch" \
		--session "$session_key" \
		--task "${WORKER_ISSUE_NUMBER:-}" \
		--owner-pid "$$"; then
		if _hrw_reclaim_stale_worker_worktree_owner "$session_key" "$work_dir" "$branch" && \
			claim_worktree_ownership "$work_dir" "$branch" \
				--session "$session_key" \
				--task "${WORKER_ISSUE_NUMBER:-}" \
				--owner-pid "$$"; then
			_hrw_export_worker_worktree_owner_proof "$session_key" "$work_dir" || return 1
			print_info "[lifecycle] worker_worktree_claimed session=${session_key} branch=${branch} path=${work_dir} pid=$$"
			return 0
		fi
		print_error "[fatal] worker worktree already has a live owner: $work_dir"
		return 1
	fi

	_hrw_export_worker_worktree_owner_proof "$session_key" "$work_dir" || return 1
	print_info "[lifecycle] worker_worktree_claimed session=${session_key} branch=${branch} path=${work_dir} pid=$$"
	return 0
}

_hrw_renew_dispatch_prelaunch_lease() {
	local session_key="$1"

	if [[ -z "${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}" || -z "${WORKER_ISSUE_NUMBER:-}" || -z "${WORKER_REPO_SLUG:-}" ]]; then
		return 0
	fi
	"${SCRIPT_DIR}/dispatch-claim-helper.sh" transition prelaunch "$WORKER_ISSUE_NUMBER" \
		"$WORKER_REPO_SLUG" "$AIDEVOPS_DISPATCH_LEASE_TOKEN" "$session_key" \
		"${AIDEVOPS_DISPATCH_CLAIM_ORPHAN_GRACE:-120}" 2>/dev/null || return 1
	return 0
}

_hrw_release_worker_worktree() {
	local work_dir="$1"

	if [[ -z "${WORKER_ISSUE_NUMBER:-}" || -z "$work_dir" ]]; then
		return 0
	fi
	unregister_worktree "$work_dir" 2>/dev/null || true
	return 0
}

_hrw_run_finish_crash_type() {
	case "${_run_result_label:-}" in
	premature_exit | watchdog_stall_continue | watchdog_stall_killed)
		# Model attempted real work (read files, created worktree) but couldn't
		# produce commits/PR. This is "overwhelmed" — the model tried and failed
		# due to task complexity, not infra issues.
		printf '%s\n' "$_HRW_CRASH_OVERWHELMED"
		;;
	no_activity)
		# No LLM output at all — infra/setup failure.
		printf '%s\n' "$_HRW_CRASH_NO_WORK"
		;;
	*)
		# Provider errors, rate limits, auth failures — not a model capability
		# issue, don't classify for escalation purposes.
		printf '\n'
		;;
	esac
	return 0
}

_hrw_finish_failed_run() {
	local session_key="$1"
	local work_dir="$2"
	local external_terminal_confirmed="${3:-0}"
	local failure_recovered=0

	if [[ "$external_terminal_confirmed" -eq 1 ]] || \
		_worker_external_terminal_complete "$session_key" "$work_dir"; then
		_hrw_release_dispatch_claim "$session_key" "$_HRW_REASON_WORKER_COMPLETE"
		failure_recovered=1
	elif _recover_worker_output_on_failure "$session_key" "$work_dir"; then
		failure_recovered=1
	else
		_hrw_release_dispatch_claim "$session_key" "worker_failed"
	fi
	if [[ "$failure_recovered" -eq 1 && "${_HRW_RECOVERY_CLASSIFICATION:-$_HRW_REASON_WORKER_COMPLETE}" == "$_HRW_REASON_WORKER_COMPLETE" ]]; then
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_SUCCESS"
		_HRW_FINAL_RUNTIME_EVENT="worker.completed"
		_HRW_FINAL_RUNTIME_STATUS="recovered"
		_HRW_FINAL_RUNTIME_CLASSIFICATION="$_HRW_REASON_WORKER_COMPLETE"
	elif [[ -n "${_HRW_RECOVERY_CLASSIFICATION:-}" ]]; then
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_FAILED"
		_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_FAILED"
		_HRW_FINAL_RUNTIME_STATUS="$_HRW_STATUS_FAILED"
		if [[ "$_HRW_RECOVERY_CLASSIFICATION" == "$_HRW_REASON_DRAFT_CHECKPOINT" || \
			"$_HRW_RECOVERY_CLASSIFICATION" == "$_HRW_REASON_READY_FAILED" ]]; then
			_HRW_FINAL_RUNTIME_STATUS="$_HRW_STATUS_ESCALATED"
		fi
		_HRW_FINAL_RUNTIME_CLASSIFICATION="$_HRW_RECOVERY_CLASSIFICATION"
	else
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_FAILED"
		_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_FAILED"
		_HRW_FINAL_RUNTIME_STATUS="$_HRW_STATUS_FAILED"
		_HRW_FINAL_RUNTIME_CLASSIFICATION="${_run_failure_reason:-worker_failed}"
	fi

	# Classify crash type from worker session state.
	# _run_result_label is set by _handle_run_result:
	#   "premature_exit" = model had activity but no completion signal
	#   "no_activity"    = no LLM output at all
	#   "watchdog_stall_continue" = stall with prior activity (passive kill)
	#   "watchdog_stall_killed"   = stall + elapsed ≥ hard-kill cap (proactive)
	#   other            = provider/infra failures
	local crash_type=""
	crash_type=$(_hrw_run_finish_crash_type)

	# Self-report to the fast-fail counter so tier escalation fires immediately
	# instead of waiting 30+ min for the pulse to discover the orphaned assignment.
	# Uses the failure reason from the retry loop if available, otherwise defaults
	# to "worker_failed".
	if [[ "$failure_recovered" -eq 0 ]]; then
		_report_failure_to_fast_fail "$session_key" "${_run_failure_reason:-worker_failed}" "$crash_type"
	fi

	return 0
}

_hrw_finish_rate_limit_fast_run() {
	local session_key="$1"

	# GH#21578 / t3021: Transient API rate limit detected within first 30s.
	# Release the dispatch claim so the issue re-queues on the next pulse cycle.
	# Do NOT call _report_failure_to_fast_fail — this is a transient API condition
	# (Anthropic 429/overload), not a model capability failure. NMR backoff would
	# incorrectly penalise the issue for an infrastructure blip. Metric already
	# recorded by _execute_run_attempt with result=rate_limit_fast.
	_hrw_release_dispatch_claim "$session_key" "rate_limit_transient"
	return 0
}

_hrw_record_permission_blocker_failure() {
	local session_key="$1"
	local reason="$2"
	local logger="${SCRIPT_DIR}/worker-blocker-log.mjs"
	[[ -f "$logger" ]] || return 0
	command -v node >/dev/null 2>&1 || return 0
	node "$logger" append \
		--event "$_HRW_PERMISSION_PERSISTENCE_FAILED" \
		--status "blocked" \
		--reason "$reason" \
		--blocking "true" \
		--source "headless-runtime-worker" \
		--session-key "$session_key" \
		--detail "Worker could not persist the maintainer permission handoff" >/dev/null 2>&1 || true
	return 0
}

_hrw_reconcile_session_permission_blockers() {
	local session_key="$1"
	local terminal_reason="$2"
	local logger="${SCRIPT_DIR}/worker-blocker-log.mjs"
	local repo_slug="${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}"
	local issue_number="${WORKER_ISSUE_NUMBER:-}"
	[[ -f "$logger" && -n "$session_key" && -n "$repo_slug" ]] || return 0
	command -v node >/dev/null 2>&1 || return 0
	node "$logger" resolve-session \
		--repo-slug "$repo_slug" \
		--issue-number "$issue_number" \
		--session-key "$session_key" \
		--event "headless_session_terminal_reconciled" \
		--status "resolved" \
		--reason "$terminal_reason" \
		--source "headless-runtime-worker" \
		--detail "Headless runtime ended ownership of this permission blocker identity" >/dev/null 2>&1 || true
	return 0
}

_hrw_finish_permission_required_run() {
	local session_key="$1"
	local work_dir="$2"
	local helper="${SCRIPT_DIR}/worker-permission-helper.sh"
	local permission_status="$_HRW_STATUS_PERMISSION_REQUIRED"
	# Captured tool-request identities end with the runtime session. A successful
	# issue handoff appends its own aggregate request identity below, which stays
	# blocking until the scoped grant is applied.
	_hrw_reconcile_session_permission_blockers "$session_key" "permission_handoff_transition"
	if [[ ! -x "$helper" || -z "${_run_permission_request_file:-}" ]]; then
		_hrw_record_permission_blocker_failure "$session_key" "permission_capture_or_helper_unavailable"
		_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_PERMISSION_PERSISTENCE_FAILED"
		return 1
	fi
	if ! "$helper" request \
		--file "$_run_permission_request_file" \
		--issue "${WORKER_ISSUE_NUMBER:-}" \
		--repo "${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}" \
		--session "$session_key" \
		--work-dir "$work_dir"; then
		_hrw_record_permission_blocker_failure "$session_key" "permission_handoff_failed"
		_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_PERMISSION_PERSISTENCE_FAILED"
		return 1
	fi
	_hrw_release_dispatch_claim "$session_key" "$permission_status"
	_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_DEFERRED"
	_HRW_FINAL_RUNTIME_STATUS="$permission_status"
	_HRW_FINAL_RUNTIME_CLASSIFICATION="awaiting_maintainer_permission"
	_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_DEFERRED"
	rm -f "$_run_permission_request_file" 2>/dev/null || true
	return 0
}

_hrw_record_terminal_outcome() {
	local session_key="$1"
	local outcome="$2"
	local reason="$3"
	local ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"

	[[ -x "$ledger_helper" && -n "$outcome" ]] || return 0
	"$ledger_helper" record-outcome \
		--session-key "$session_key" \
		--lease-token "${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}" \
		--attempt-id "${AIDEVOPS_ATTEMPT_ID:-}" \
		--issue "${WORKER_ISSUE_NUMBER:-}" \
		--repo "${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}" \
		--outcome "$outcome" \
		--reason "$reason" 2>/dev/null || true
	return 0
}

_hrw_record_reconciled_outcome() {
	local session_key="$1"
	local raw_result="$2"
	local outcome="$3"
	local status="$4"
	local classification="$5"
	local helper="${OBJECTIVE_RECONCILIATION_HELPER:-${SCRIPT_DIR}/objective-reconciliation-helper.sh}"
	local issue_number="${WORKER_ISSUE_NUMBER:-}"
	local repo_slug="${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}"
	local next_action="narrow_redispatch"
	local write_attempt=1
	local max_write_attempts="${AIDEVOPS_OBJECTIVE_OUTCOME_WRITE_ATTEMPTS:-3}"
	[[ "$max_write_attempts" =~ ^[1-5]$ ]] || max_write_attempts=3

	case "$outcome" in
	success) next_action="monitor_pr" ;;
	deferred)
		if [[ "$status" == "$_HRW_STATUS_PERMISSION_REQUIRED" ]]; then
			next_action="await_maintainer_permission"
		else
			next_action="retry_infrastructure"
		fi
		;;
	escalated) next_action="decision_ready_human_packet" ;;
	esac
	[[ -x "$helper" && "$issue_number" =~ ^[1-9][0-9]*$ && -n "$repo_slug" && -n "${AIDEVOPS_ATTEMPT_ID:-}" ]] || return 0
	while [[ "$write_attempt" -le "$max_write_attempts" ]]; do
		if "$helper" record-outcome --repo "$repo_slug" --issue "$issue_number" \
			--attempt-id "$AIDEVOPS_ATTEMPT_ID" --run-id "${AIDEVOPS_RUN_ID:-}" \
			--attempt-started-at "${AIDEVOPS_ATTEMPT_STARTED_AT:-}" \
			--raw-result "$raw_result" --outcome "$outcome" --status "$status" \
			--classification "$classification" --next-action "$next_action" >/dev/null 2>&1; then
			return 0
		fi
		write_attempt=$((write_attempt + 1))
		[[ "$write_attempt" -le "$max_write_attempts" ]] && sleep 0.1
	done
	print_warning "[lifecycle] reconciled outcome persistence failed after ${max_write_attempts} attempts session=${session_key} attempt=${AIDEVOPS_ATTEMPT_ID}"
	return 0
}

_hrw_mark_failed_terminal_state() {
	local status="$1"
	local classification="$2"
	_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_FAILED"
	_HRW_FINAL_RUNTIME_STATUS="$status"
	_HRW_FINAL_RUNTIME_CLASSIFICATION="$classification"
	_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_FAILED"
	return 0
}

_hrw_finish_success_run() {
	local session_key="$1"
	local work_dir="$2"
	local release_needed=1
	local finish_status=0
	local permission_pending_file=""
	if [[ "${_run_result_label:-}" == "post_pr_handoff" ]] &&
		(! declare -F _worker_post_pr_handoff_confirmed >/dev/null 2>&1 ||
			! _worker_post_pr_handoff_confirmed "$session_key" "$work_dir"); then
		print_warning "[lifecycle] ${_HRW_REASON_UNVERIFIED_HANDOFF} session=${session_key} — exact-head non-draft PR handoff could not be verified; routing as failure"
		_hrw_release_dispatch_claim "$session_key" "$_HRW_REASON_UNVERIFIED_HANDOFF"
		_report_failure_to_fast_fail "$session_key" "$_HRW_REASON_UNVERIFIED_HANDOFF" "$_HRW_CRASH_OVERWHELMED"
		release_needed=0
		finish_status=1
		_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_REASON_UNVERIFIED_HANDOFF"
	fi

	# GH#20721 + GH#20819: Classify worker output quality.
	# _worker_produced_output distinguishes exact-head completion from drafts,
	# failed checks, closed PRs, and inconclusive issue-search matches.
	#   noop                  — no commits, no branch, no PR → fast-fail
	#   branch_orphan         — branch pushed but no PR → auto-recover
	#   local_branch_unpushed — local commits but no remote branch/PR → push+recover
	#   dirty_worktree        — local edits exist but no commit/PR → preserve marker
	#   draft_checkpoint      — durable but incomplete PR → explicit escalation
	#   pr_exists             — PR confirmed, or fail-open → worker_complete
	#
	# Fail-open semantics are preserved: when signals cannot be evaluated (no git
	# repo, no gh, no remote) the classification is "pr_exists", so false-negatives
	# (legit work misclassified) are impossible.
	if [[ "$release_needed" -eq 1 && -n "$work_dir" ]]; then
		local output_class="pr_exists"
		output_class=$(_worker_produced_output "$session_key" "$work_dir")
		case "$output_class" in
		noop)
			print_info "[lifecycle] worker_noop session=$session_key — zero commits, no pushed branch, no PR"
			_hrw_release_dispatch_claim "$session_key" "worker_noop"
			_report_failure_to_fast_fail "$session_key" "worker_noop_zero_output" "$_HRW_CRASH_NO_WORK"
			release_needed=0
			_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_CRASH_NO_WORK"
			;;
		branch_orphan)
			_handle_worker_branch_orphan "$session_key" "$work_dir"
			release_needed=0
			;;
		local_branch_unpushed)
			_handle_worker_local_branch_unpushed "$session_key" "$work_dir"
			release_needed=0
			;;
		dirty_worktree)
			_handle_worker_dirty_worktree "$session_key" "$work_dir"
			release_needed=0
			;;
		draft_checkpoint)
			_escalate_worker_pr_checkpoint "$session_key" "${DISPATCH_REPO_SLUG:-}" "$output_class"
			release_needed=0
			if [[ "$_HRW_RECOVERY_CLASSIFICATION" == "$_HRW_REASON_DRAFT_CHECKPOINT" ]]; then
				_hrw_mark_failed_terminal_state "$_HRW_STATUS_ESCALATED" "$_HRW_RECOVERY_CLASSIFICATION"
			else
				_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_RECOVERY_CLASSIFICATION"
			fi
			;;
		closed_unmerged)
			print_warning "[lifecycle] ${_HRW_REASON_CLOSED_UNMERGED} session=${session_key} — closed PR is not completion evidence"
			_hrw_release_dispatch_claim "$session_key" "$_HRW_REASON_CLOSED_UNMERGED"
			_report_failure_to_fast_fail "$session_key" "$_HRW_REASON_CLOSED_UNMERGED" "$_HRW_CRASH_OVERWHELMED"
			release_needed=0
			_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_REASON_CLOSED_UNMERGED"
			;;
		protected_draft | unverified_open_pr | head_mismatch | ready_missing_summary | merged_missing_summary)
			local noncomplete_reason="worker_${output_class}"
			print_warning "[lifecycle] ${noncomplete_reason} session=${session_key} — protected/inconclusive PR state is not completion evidence; retaining claim"
			release_needed=0
			_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$noncomplete_reason"
			;;
		esac
	fi

	if [[ "$release_needed" -eq 1 ]]; then
		# pr_exists or fail-open: normal success path. Post CLAIM_RELEASED with
		# reason=worker_complete so the audit trail shows the full lifecycle even
		# when no PR was created.
		_hrw_release_dispatch_claim "$session_key" "$_HRW_REASON_WORKER_COMPLETE"
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_SUCCESS"
	fi
	if [[ "$_HRW_TERMINAL_OUTCOME" == "$_HRW_TELEMETRY_SUCCESS" ]]; then
		permission_pending_file=$(_hrw_permission_pending_path "$work_dir" || true)
		rm -f "${AIDEVOPS_PERMISSION_GRANT_FILE:-}" "$permission_pending_file" 2>/dev/null || true
	fi

	return "$finish_status"
}

_hrw_finish_cleanup() {
	local session_key="$1"
	local ledger_status="$2"
	local work_dir="$3"

	_update_dispatch_ledger "$session_key" "$ledger_status"
	_release_session_lock "$session_key"
	_hrw_release_worker_worktree "$work_dir"
	if declare -F _cleanup_headless_runtime_temp_paths >/dev/null 2>&1; then
		_cleanup_headless_runtime_temp_paths
	fi
	aidevops_runtime_bundle_lease_release || print_warning "Failed to release the worker runtime bundle lease"
	trap - EXIT
	return 0
}

_cmd_run_finish() {
	local session_key="$1"
	local ledger_status="$2"
	# work_dir is optional ($3). When present and ledger_status != "fail",
	# _worker_produced_output() classifies tangible output to distinguish
	# worker_complete, worker_branch_orphan, and worker_noop (GH#20721, GH#20819).
	local work_dir="${3:-${_WORKER_WORKTREE_PATH:-}}"
	# Optional $4 carries a terminal-state proof already confirmed at a retry
	# boundary. Reusing it avoids a second GitHub query that could fail after the
	# first query already proved the issue and matching PR are terminal.
	local external_terminal_confirmed="${4:-0}"
	local finish_status=0
	if _headless_private_workload_enabled; then
		_private_workload_exit_trap "$session_key" "${_PRIVATE_WORKLOAD_LOCK_KEY:-}"
		_WORKER_WORKTREE_PATH=""
		WORKER_TARGET_BRANCH=""
		return 0
	fi
	_HRW_FINAL_RUNTIME_EVENT="worker.completed"
	_HRW_FINAL_RUNTIME_STATUS="${_run_result_label:-$ledger_status}"
	_HRW_FINAL_RUNTIME_CLASSIFICATION="${_run_failure_reason:-}"
	_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_SUCCESS"
	_HRW_RECOVERY_CLASSIFICATION=""

	# Release the dispatch claim so the issue is immediately available for
	# re-dispatch (next 2-min pulse cycle) instead of waiting for the
	# 30-min DISPATCH_COMMENT_MAX_AGE TTL to expire.
	#
	# Both success and failure paths post CLAIM_RELEASED — completion signal
	# consistency matters (GH#19836 follow-up). On success, the worker may
	# have exited without creating a PR (e.g., premise falsified and issue
	# closed, or worker completed an out-of-PR action). Relying only on
	# "PR with Closes #" or MERGE_SUMMARY to clear the claim leaves a 30-min
	# dead-zone where the issue is stuck with no audit trail. The
	# dispatch-dedup guard already treats any CLAIM_RELEASED as authoritative
	# (dispatch-dedup-helper.sh:1044), so this is safe — if a worker DID
	# create a PR with Closes, the PR-based dedup signal still wins and the
	# CLAIM_RELEASED comment is redundant operational metadata.
	if [[ "$ledger_status" == "$_HRW_STATUS_FAIL" && "${_run_failure_reason:-}" == "$_HRW_REASON_OWNERSHIP_LOST" ]]; then
		# Another owner took the issue after dispatch. Terminalize only this
		# worker's lease; do not run recovery or mutate the new owner's issue state.
		_hrw_release_dispatch_claim "$session_key" "$_HRW_REASON_OWNERSHIP_LOST"
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_FAILED"
		_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_FAILED"
		_HRW_FINAL_RUNTIME_STATUS="$_HRW_STATUS_FAILED"
		_HRW_FINAL_RUNTIME_CLASSIFICATION="$_HRW_REASON_OWNERSHIP_LOST"
	elif [[ "$ledger_status" == "$_HRW_STATUS_FAIL" ]]; then
		_hrw_finish_failed_run "$session_key" "$work_dir" "$external_terminal_confirmed"
	elif [[ "$ledger_status" == "rate_limit_fast" ]]; then
		_hrw_finish_rate_limit_fast_run "$session_key"
		_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_DEFERRED"
		_HRW_FINAL_RUNTIME_STATUS="rate_limit_fast"
		_HRW_FINAL_RUNTIME_CLASSIFICATION="rate_limit"
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_DEFERRED"
	elif [[ "$ledger_status" == "$_HRW_STATUS_PERMISSION_REQUIRED" ]]; then
		if ! _hrw_finish_permission_required_run "$session_key" "$work_dir"; then
			_run_failure_reason="$_HRW_PERMISSION_PERSISTENCE_FAILED"
			_hrw_finish_failed_run "$session_key" "$work_dir" "$external_terminal_confirmed"
			finish_status=1
			ledger_status="$_HRW_STATUS_FAIL"
		fi
		if [[ ! "${WORKER_ISSUE_NUMBER:-}" =~ ^[0-9]+$ ]]; then
			_hrw_reconcile_session_permission_blockers "$session_key" \
				"${_run_failure_reason:-permission_session_terminal}"
		fi
	else
		if ! _hrw_finish_success_run "$session_key" "$work_dir"; then
			finish_status=1
			ledger_status="$_HRW_STATUS_FAIL"
		fi
	fi
	_hrw_record_terminal_outcome "$session_key" "$_HRW_TERMINAL_OUTCOME" \
		"$_HRW_FINAL_RUNTIME_CLASSIFICATION"
	_emit_worker_runtime_event "$_HRW_FINAL_RUNTIME_EVENT" \
		"$_HRW_FINAL_RUNTIME_STATUS" "$_HRW_FINAL_RUNTIME_CLASSIFICATION"
	_hrw_record_reconciled_outcome "$session_key" "${_run_result_label:-$ledger_status}" \
		"$_HRW_TERMINAL_OUTCOME" "$_HRW_FINAL_RUNTIME_STATUS" "$_HRW_FINAL_RUNTIME_CLASSIFICATION"

	_hrw_finish_cleanup "$session_key" "$ledger_status" "$work_dir"
	return "$finish_status"
}
