#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Auto-Update Check Sub-Library -- Lock management, version checking, and
# update operations (git pull, setup.sh deploy, verify).
# =============================================================================
# Extracted from auto-update-helper.sh to keep the orchestrator under the
# 1500-line file-size-debt threshold.
#
# Usage: source "${SCRIPT_DIR}/auto-update-helper-check.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, _is_process_alive_and_matches, etc.)
#   - auto-update-freshness-lib.sh (run_freshness_checks)
#   - Orchestrator constants: INSTALL_DIR, LOCK_DIR, LOCK_FILE, LOG_FILE,
#     STATE_FILE, SCRIPT_DIR
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_AUTO_UPDATE_CHECK_LIB_LOADED:-}" ]] && return 0
_AUTO_UPDATE_CHECK_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi

# --- Functions ---

#######################################
# _lock_holder_is_wedged
# Returns 0 if the lock holder is wedged (process alive but no log progress
# for more than WEDGE_THRESHOLD_SECONDS), 1 otherwise.
# Conservative: treats absence of log file as "not wedged" (can't tell).
# Uses log file mtime as a proxy for "last sign of life" — more accurate than
# lock directory mtime which only reflects lock acquisition time.
# t2912
#######################################
_lock_holder_is_wedged() {
	local _pid="$1"
	local _threshold="${WEDGE_THRESHOLD_SECONDS:-1800}"  # 30 min default
	local _log="${LOG_FILE:-$HOME/.aidevops/logs/auto-update.log}"

	# Belt-and-braces: process must be alive for a wedge to be possible.
	kill -0 "$_pid" 2>/dev/null || return 1

	# No log file = nothing to measure progress against.
	# Conservative: assume not wedged rather than force-killing blindly.
	[[ -f "$_log" ]] || return 1

	# Modification time of the log file proxies "last sign of life".
	# Use Darwin without quotes in [[ ]] — RHS is not word-split, no SC warning.
	local _log_mtime
	local _now
	local _idle
	_log_mtime=$(_file_mtime_epoch "$_log")
	_now=$(date +%s)
	_idle=$(( _now - _log_mtime ))

	if [[ "$_idle" -gt "$_threshold" ]]; then
		return 0
	fi
	return 1
}

acquire_lock() {
	local max_wait=30
	local waited=0

	while [[ $waited -lt $max_wait ]]; do
		if mkdir "$LOCK_FILE" 2>/dev/null; then
			echo $$ >"$LOCK_FILE/pid"
			return 0
		fi

		# Check for stale lock
		if [[ -f "$LOCK_FILE/pid" ]]; then
			local lock_pid
			lock_pid=$(cat "$LOCK_FILE/pid" 2>/dev/null || echo "")
			# t2421: command-aware liveness — bare kill -0 lies on macOS PID reuse
			if [[ -n "$lock_pid" ]] && ! _is_process_alive_and_matches "$lock_pid" "${FRAMEWORK_PROCESS_PATTERN:-}"; then
				log_warn "Removing stale lock (PID $lock_pid dead or reused, t2421)"
				rm -rf "$LOCK_FILE"
				continue
			# t2912: wedge detection — process alive but log has had no activity
			# beyond WEDGE_THRESHOLD_SECONDS (default 1800s / 30 min).
			elif [[ -n "$lock_pid" ]] && _lock_holder_is_wedged "$lock_pid"; then
				local _wedge_thr="${WEDGE_THRESHOLD_SECONDS:-1800}"
				log_warn "Wedged lock holder detected (PID $lock_pid alive but no log progress in ${_wedge_thr}s) — force-releasing (t2912)"
				kill -TERM "$lock_pid" 2>/dev/null || true
				sleep 2
				kill -KILL "$lock_pid" 2>/dev/null || true
				rm -rf "$LOCK_FILE"
				"${SCRIPT_DIR}/audit-log-helper.sh" log "lock.wedge-recovery" "auto-update wedged lock (PID $lock_pid) force-released after ${_wedge_thr}s with no log progress" 2>/dev/null || true
				continue
			fi
		fi

		# Check lock age (safety net for orphaned locks)
		if [[ -d "$LOCK_FILE" ]]; then
			local lock_age
			lock_age=$(($(date +%s) - $(_file_mtime_epoch "$LOCK_FILE")))
			if [[ $lock_age -gt 300 ]]; then
				log_warn "Removing stale lock (age ${lock_age}s > 300s)"
				rm -rf "$LOCK_FILE"
				continue
			fi
		fi

		sleep 1
		waited=$((waited + 1))
	done

	log_error "Failed to acquire lock after ${max_wait}s"
	return 1
}

release_lock() {
	rm -rf "$LOCK_FILE"
	return 0
}

#######################################
# Get local version
#######################################
get_local_version() {
	local version_file="$INSTALL_DIR/VERSION"
	if [[ -r "$version_file" ]]; then
		cat "$version_file"
	else
		echo "unknown"
	fi
	return 0
}

#######################################
# Get remote version (from GitHub API)
# Tries authenticated gh api first (5000 req/hr), then unauthenticated curl
# (60 req/hr), then raw.githubusercontent.com CDN fallback.
# See: #4142 — 106 "remote=unknown" failures from rate-limited unauth API
#######################################
get_remote_version() {
	local version=""

	# Prefer authenticated gh api (higher rate limit: 5000/hr vs 60/hr)
	# This avoids the "remote=unknown" failures seen during overnight polling
	# when unauthenticated API quota is exhausted.
	# See: https://github.com/marcusquinn/aidevops/issues/4142
	if command -v gh &>/dev/null && gh auth status &>/dev/null; then
		version=$(gh api repos/marcusquinn/aidevops/contents/VERSION \
			--jq '.content' 2>/dev/null |
			base64 -d 2>/dev/null |
			tr -d '\n')
		if [[ -n "$version" ]]; then
			echo "$version"
			return 0
		fi
	fi

	# Fallback: unauthenticated curl (60 req/hr limit)
	if command -v jq &>/dev/null; then
		version=$(curl --proto '=https' -fsSL --max-time 10 \
			"https://api.github.com/repos/marcusquinn/aidevops/contents/VERSION" 2>/dev/null |
			jq -r '.content // empty' 2>/dev/null |
			base64 -d 2>/dev/null |
			tr -d '\n')
		if [[ -n "$version" ]]; then
			echo "$version"
			return 0
		fi
	fi

	# Last resort: raw.githubusercontent.com (CDN-cached, may be up to 5 min stale)
	curl --proto '=https' -fsSL --max-time 10 \
		"https://raw.githubusercontent.com/marcusquinn/aidevops/main/VERSION" 2>/dev/null |
		tr -d '\n' || echo "unknown"
	return 0
}

#######################################
# Check if setup.sh or aidevops update is already running
#######################################
is_update_running() {
	# Check for running setup.sh processes (not our own)
	# Use full path to avoid matching unrelated projects' setup.sh scripts
	if pgrep -f "${INSTALL_DIR}/setup\.sh" >/dev/null 2>&1; then
		return 0
	fi
	# Check for running aidevops update
	if pgrep -f "aidevops update" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

#######################################
# Update state file with last check/update info
#######################################
update_state() {
	local action="$1"
	local version="${2:-}"
	local status="${3:-success}"
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	if command -v jq &>/dev/null; then
		local tmp_state
		tmp_state=$(mktemp)
		trap 'rm -f "${tmp_state:-}"' RETURN

		if [[ -f "$STATE_FILE" ]]; then
			jq --arg action "$action" \
				--arg version "$version" \
				--arg status "$status" \
				--arg ts "$timestamp" \
				'. + {
                   last_action: $action,
                   last_version: $version,
                   last_status: $status,
                   last_timestamp: $ts
               } | if $action == "update" and $status == "success" then
                   . + {last_update: $ts, last_update_version: $version}
               else . end' "$STATE_FILE" >"$tmp_state" 2>/dev/null && mv "$tmp_state" "$STATE_FILE"
		else
			jq -n --arg action "$action" \
				--arg version "$version" \
				--arg status "$status" \
				--arg ts "$timestamp" \
				'{
                      enabled: true,
                      last_action: $action,
                      last_version: $version,
                      last_status: $status,
                      last_timestamp: $ts,
                      last_skill_check: null,
                      skill_updates_applied: 0
                  }' >"$STATE_FILE"
		fi
	fi
	return 0
}

_run_setup_ai_session_with_fallback() {
	local setup_script="${INSTALL_DIR}/setup.sh"
	if bash "$setup_script" --stage ai-session >>"$LOG_FILE" 2>&1; then
		return 0
	fi
	log_warn "AI-session incremental setup failed or is unavailable; retrying full setup"
	bash "$setup_script" --non-interactive >>"$LOG_FILE" 2>&1
	return $?
}

#######################################
# Handle stale deployed agents when repo version matches remote.
# Checks VERSION mismatch and sentinel script hash drift; re-deploys if needed.
# Args: $1 = current version string
#######################################
_cmd_check_stale_agent_redeploy() {
	local current="$1"

	# Even when repo matches remote, deployed agents may be stale
	# (e.g., previous setup.sh was interrupted or failed silently)
	# See: https://github.com/marcusquinn/aidevops/issues/3980
	local deployed_version
	deployed_version=$(cat "$HOME/.aidevops/agents/VERSION" 2>/dev/null || echo "none")
	if [[ "$current" != "$deployed_version" ]]; then
		log_warn "Deployed agents stale ($deployed_version), re-deploying..."
		if _run_setup_ai_session_with_fallback; then
			local redeployed_version
			redeployed_version=$(cat "$HOME/.aidevops/agents/VERSION" 2>/dev/null || echo "none")
			if [[ "$current" == "$redeployed_version" ]]; then
				log_info "Agents re-deployed successfully ($deployed_version -> $redeployed_version)"
			else
				log_error "Agent re-deploy incomplete: repo=$current, deployed=$redeployed_version"
			fi
		else
			log_error "setup.sh failed during stale-agent re-deploy (exit code: $?)"
		fi
		return 0
	fi

	# t2706: VERSION matches but scripts may still differ — a script fix merged
	# without a version bump leaves the deployed copy stale until setup.sh is
	# run manually. Previous implementation checked SHA-256 of a single sentinel
	# file (gh-failure-miner-helper.sh); that missed drift in any OTHER file
	# (e.g., PR #20323 fixed pulse-batch-prefetch-helper.sh — sentinel was blind
	# to it, and the pulse kept hitting the bug for ~14h while VERSION matched).
	# Replacement: compare the canonical HEAD SHA against ~/.aidevops/.deployed-sha
	# (written by .agents/scripts/setup/modules/agent-deploy.sh on every successful deploy).
	# Docs-only drift (reference/, *.md) is intentionally skipped — no runtime
	# impact and redeploying for docs wastes cycles.
	# GH#4727: Codacy not_collected false-positive recurred because the fix in
	# PR #4704 was not deployed to ~/.aidevops/ before the next pulse cycle.
	local stamp_file="$HOME/.aidevops/.deployed-sha"
	if [[ -f "$stamp_file" && -d "$INSTALL_DIR/.git" ]]; then
		local deployed_sha head_sha
		deployed_sha=$(tr -d '[:space:]' <"$stamp_file" 2>/dev/null) || deployed_sha=""
		head_sha=$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null) || head_sha=""
		if [[ -n "$deployed_sha" && -n "$head_sha" && "$deployed_sha" != "$head_sha" ]]; then
			local has_code_drift=0
			# Per Gemini code-review on PR #20342: use git's path filter +
			# `grep -q .` to detect drift across the full set of deploy-affecting
			# paths (not just .agents/ subdirs — also setup.sh, .agents/scripts/setup/modules/,
			# and aidevops.sh itself, which are deployed/sourced by setup).
			if git -C "$INSTALL_DIR" diff --name-only "$deployed_sha" "$head_sha" -- \
				.agents/scripts/ .agents/agents/ .agents/workflows/ .agents/prompts/ .agents/hooks/ \
				setup.sh .agents/scripts/setup/modules/ aidevops.sh 2>/dev/null | grep -q .; then
				has_code_drift=1
			fi
			if [[ "$has_code_drift" -eq 1 ]]; then
				log_warn "Script drift detected (${deployed_sha:0:7}→${head_sha:0:7} at v$current) — re-deploying agents..."
				if _run_setup_ai_session_with_fallback; then
					log_info "Agents re-deployed after script drift (${deployed_sha:0:7}→${head_sha:0:7})"
				else
					log_error "setup.sh failed during script-drift re-deploy (exit code: $?)"
				fi
			fi
		fi
	fi
	return 0
}

#######################################
# Fetch and fast-forward INSTALL_DIR to the exact origin/main commit.
# Fails closed on tracked work, local history, branch, or merge problems.
# Args: $1 = remote version (for state updates on failure)
# Returns: 0 on success, 1 on unrecoverable failure
#######################################
_cmd_check_git_update() {
	local remote="$1"

	# Fetch before evaluating local blockers. A same-version release can still
	# contain merged script fixes, so VERSION equality is not freshness proof.
	if ! git -C "$INSTALL_DIR" fetch origin main --quiet 2>>"$LOG_FILE"; then
		log_error "git fetch failed"
		update_state "update" "$remote" "fetch_failed"
		return 1
	fi
	local local_hash=""
	local remote_hash=""
	local_hash=$(git -C "$INSTALL_DIR" rev-parse HEAD 2>>"$LOG_FILE") || return 1
	remote_hash=$(git -C "$INSTALL_DIR" rev-parse origin/main 2>>"$LOG_FILE") || return 1
	# The install checkout may contain deliberate local fixes or diagnostics.
	# Preserve them and record that they are blocking activation of upstream.
	if ! git -C "$INSTALL_DIR" diff --quiet 2>/dev/null || ! git -C "$INSTALL_DIR" diff --cached --quiet 2>/dev/null; then
		local dirty_status="local_changes"
		if [[ "$local_hash" != "$remote_hash" ]]; then
			dirty_status="runtime_stale_local_changes"
		fi
		log_warn "Skipping update because tracked local changes exist in the canonical checkout"
		git -C "$INSTALL_DIR" status --short >>"$LOG_FILE" 2>&1 || true
		update_state "update" "$remote" "$dirty_status"
		return 1
	fi
	local current_branch=""
	current_branch=$(git -C "$INSTALL_DIR" branch --show-current 2>/dev/null || true)
	if [[ "$current_branch" != "main" ]]; then
		log_error "Runtime is stale because the canonical checkout is not on main"
		update_state "update" "$remote" "runtime_stale_branch"
		return 1
	fi
	if [[ "$local_hash" == "$remote_hash" ]]; then
		return 0
	fi

	if git -C "$INSTALL_DIR" merge-base --is-ancestor "$remote_hash" "$local_hash" 2>/dev/null; then
		log_error "Local commits exist on main; refusing unattended update"
		update_state "update" "$remote" "runtime_stale_local_commits"
		return 1
	fi
	if ! git -C "$INSTALL_DIR" merge-base --is-ancestor "$local_hash" "$remote_hash" 2>/dev/null; then
		log_error "Canonical main has diverged from origin/main; refusing unattended update"
		update_state "update" "$remote" "runtime_stale_diverged"
		return 1
	fi

	if ! git -C "$INSTALL_DIR" merge --ff-only "$remote_hash" --quiet 2>>"$LOG_FILE"; then
		log_error "git merge --ff-only failed; preserving local history"
		update_state "update" "$remote" "pull_failed"
		return 1
	fi
	local_hash=$(git -C "$INSTALL_DIR" rev-parse HEAD 2>>"$LOG_FILE") || return 1
	if [[ "$local_hash" != "$remote_hash" ]]; then
		log_error "Updated HEAD does not match fetched origin/main; refusing to run setup"
		update_state "update" "$remote" "history_mismatch"
		return 1
	fi
	return 0
}

#######################################
# Perform the actual update: fast-forward, setup.sh deploy, verify, cleanup.
# Args: $1 = current version, $2 = remote version
# Returns: 0 on success, 1 on failure
#######################################
_cmd_check_perform_update() {
	local current="$1"
	local remote="$2"

	log_info "Update available: v$current -> v$remote"
	update_state "update_start" "$remote" "in_progress"

	# Verify install directory exists and is a git repo
	if [[ ! -d "$INSTALL_DIR/.git" ]]; then
		log_error "Install directory is not a git repo: $INSTALL_DIR"
		update_state "update" "$remote" "no_git_repo"
		return 1
	fi

	if ! _cmd_check_git_update "$remote"; then
		return 1
	fi

	# Run setup with an incremental first pass; setup.sh falls back to full setup
	# when changed setup logic cannot be applied safely.
	log_info "Running setup.sh --stage ai-session..."
	local _setup_exit=0
	_run_setup_ai_session_with_fallback || _setup_exit=$?

	# GH#21060 / t2911: Log slowest 5 stages from this run so that
	# "tail -50 ~/.aidevops/logs/auto-update.log | grep Slowest" is
	# sufficient to diagnose which stage hung, without bash -x re-runs.
	local _stl="$HOME/.aidevops/logs/setup-stage-timings.log"
	if [[ -f "$_stl" ]]; then
		log_info "Slowest stages this cycle:"
		sort -k3 -t$'\t' -rn "$_stl" | head -5 | while IFS=$'\t' read -r _ts _name _dur _exit_code; do
			log_info "  ${_dur}s ${_name} (exit=${_exit_code})"
		done
	fi

	# GH#18492 / t2026: verify the completion sentinel regardless of exit
	# code. "exit non-zero AND no sentinel" is the t2022-class silent
	# termination (e.g., a sourced helper's set -e propagates a readonly
	# assignment failure that kills the parent script mid-run). "exit 0 but
	# no sentinel" would indicate a subshell swallowed a failure — rare but
	# possible, and we want to catch it as a distinct anomaly.
	#
	# Capture the verifier's combined output into a variable first, then
	# append to the log file, to avoid a read-write-in-pipeline warning
	# (SC2094). The verifier reads $LOG_FILE; setup.sh has already finished
	# writing to it by this point so there's no real race, but capturing
	# keeps shellcheck happy and is clearer.
	local _sentinel_ok=0
	local _verifier="$INSTALL_DIR/.agents/scripts/verify-setup-log.sh"
	if [[ -x "$_verifier" ]]; then
		local _verify_out=""
		_verify_out=$(bash "$_verifier" "$LOG_FILE" 2>&1) || _sentinel_ok=$?
		if [[ -n "$_verify_out" ]]; then
			printf '%s\n' "$_verify_out" >>"$LOG_FILE"
		fi
	fi

	if [[ "$_setup_exit" -ne 0 ]]; then
		log_error "setup.sh failed (exit code: $_setup_exit)"
		if [[ "$_sentinel_ok" -ne 0 ]]; then
			log_error "setup.sh did not reach completion sentinel — forensic tail written to $LOG_FILE by verify-setup-log.sh"
		fi
		update_state "update" "$remote" "setup_failed"
		return 1
	fi

	if [[ "$_sentinel_ok" -ne 0 ]]; then
		log_error "setup.sh exited 0 but did not reach completion sentinel — silent termination, forensic tail in $LOG_FILE"
		update_state "update" "$remote" "setup_sentinel_missing"
		return 1
	fi

	# Verify agents were actually deployed (setup.sh may exit 0 without deploying)
	# See: https://github.com/marcusquinn/aidevops/issues/3980
	local new_version deployed_version
	new_version=$(get_local_version)
	deployed_version=$(cat "$HOME/.aidevops/agents/VERSION" 2>/dev/null || echo "none")
	if [[ "$new_version" != "$deployed_version" ]]; then
		log_warn "Update pulled v$new_version but agents at v$deployed_version — deployment incomplete"
		update_state "update" "$new_version" "agents_stale"
	else
		log_info "Update complete: v$current -> v$new_version (agents deployed)"
		update_state "update" "$new_version" "success"
	fi

	return 0
}

#######################################
# One-shot check and update
# This is what the cron job calls
#######################################
#######################################
# Acquire lock and verify preconditions for cmd_check.
# Returns: 0 if ready to proceed, 1 if should skip
#######################################
_cmd_check_acquire() {
	# Respect config (env var or config file)
	if ! is_feature_enabled auto_update 2>/dev/null; then
		log_info "Auto-update disabled via config (updates.auto_update)"
		return 1
	fi

	# Skip if another update is already running
	if is_update_running; then
		log_info "Another update process is running, skipping"
		return 1
	fi

	# Acquire lock
	if ! acquire_lock; then
		log_warn "Could not acquire lock, skipping check"
		return 1
	fi
	return 0
}

cmd_check() {
	ensure_dirs

	if ! _cmd_check_acquire; then
		return 0
	fi
	trap 'release_lock' EXIT

	local current remote
	current=$(get_local_version)
	remote=$(get_remote_version)
	log_info "Version check: local=$current remote=$remote"

	if [[ "$current" == "unknown" || "$remote" == "unknown" ]]; then
		log_warn "Could not determine versions (local=$current, remote=$remote)"
		update_state "check" "$current" "version_unknown"
		run_freshness_checks
		return 0
	fi

	if [[ "$current" == "$remote" ]]; then
		log_info "Version matches upstream (v$current); verifying commit freshness"
		if ! _cmd_check_git_update "$remote"; then
			run_freshness_checks
			return 1
		fi
		update_state "check" "$current" "up_to_date"
		_cmd_check_stale_agent_redeploy "$current"
		run_freshness_checks
		return 0
	fi

	if ! _cmd_check_perform_update "$current" "$remote"; then
		run_freshness_checks
		return 1
	fi

	run_freshness_checks
	return 0
}
