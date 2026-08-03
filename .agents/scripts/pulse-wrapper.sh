#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-wrapper.sh - Wrapper for supervisor pulse with dedup and lifecycle management
#
# Solves: opencode run enters idle state after completing the pulse prompt
# but never exits, blocking all future pulses via the pgrep dedup guard.
#
# This wrapper:
#   1. mkdir-based atomic instance lock prevents concurrent pulses (GH#4513)
#      mkdir is POSIX-guaranteed atomic on all filesystems (APFS, HFS+, ext4)
#      and is the only lock primitive — flock was removed in GH#18668 after
#      recurring FD-inheritance deadlocks. See reference/bash-fd-locking.md.
#   2. Uses a PID file with staleness check (not pgrep) for dedup
#   3. Cleans up orphaned opencode processes before each pulse
#   4. Kills runaway processes exceeding RSS or runtime limits (t1398.1)
#   5. Calculates dynamic worker concurrency from available RAM
#   6. Internal watchdog kills stuck pulses after PULSE_STALE_THRESHOLD (t1397)
#   7. Self-watchdog: idle detection kills pulse when CPU drops to zero (t1398.3)
#   8. Progress-based watchdog: kills if log output stalls for PULSE_PROGRESS_TIMEOUT (GH#2958)
#   9. Provider-aware pulse sessions via headless-runtime-helper.sh
#  10. Per-issue fast-fail counter skips issues with repeated launch deaths (t1888)
#
# Lifecycle: launchd fires every 180s (StartInterval in the supervisor-pulse
# plist). If a pulse is still running, the dedup check skips.
# run_pulse() has an internal watchdog that polls every
# 60s and checks three conditions:
#   a) Wall-clock timeout: kills if elapsed > PULSE_STALE_THRESHOLD (60 min)
#   b) Idle detection: kills if CPU usage stays below PULSE_IDLE_CPU_THRESHOLD
#      for PULSE_IDLE_TIMEOUT consecutive seconds (default 5 min). This catches
#      the opencode idle-state bug where the process completes but sits in a
#      file watcher consuming no CPU. Without this, zombies persist until the
#      next launchd invocation detects staleness — which fails if launchd
#      stops firing (sleep, plist unloaded).
#   c) Progress detection (GH#2958): kills if the log file hasn't grown for
#      PULSE_PROGRESS_TIMEOUT seconds. A process that's running but producing
#      no output is stuck — not productive. This catches cases where CPU is
#      nonzero (network I/O, spinning) but no actual work is being done.
# check_dedup() serves as a secondary safety net for edge cases where the
# wrapper itself gets stuck.
#
# PID file sentinel protocol (GH#4324):
#   The PID file is NEVER deleted at run end. Instead it is overwritten with
#   an "IDLE:<timestamp>" sentinel. check_dedup() treats any content that is
#   not a live numeric PID as "safe to proceed". This closes the race window
#   where launchd fires between rm -f and the next write, which caused the
#   82-concurrent-pulse incident (2026-03-13T02:06:01Z, issue #4318).
#
# Instance lock protocol (GH#4513, GH#18668):
#   Uses mkdir atomicity as the ONLY lock primitive. mkdir is guaranteed
#   atomic by POSIX on all local filesystems — the kernel ensures only one
#   process succeeds even under concurrent invocations. The lock directory
#   contains a PID file so stale locks (from SIGKILL/power loss) can be
#   detected and cleared on the next startup. A trap ensures cleanup on
#   normal exit and SIGTERM.
#
#   flock was previously layered on top as a secondary guard, but four
#   recurring deadlock incidents (GH#18094, GH#18141, GH#18264, GH#18668)
#   all traced to FD 9 being inherited by daemonising git hooks and
#   ancillary workers. bash has no built-in fcntl(F_SETFD, FD_CLOEXEC),
#   and annotation-based `9>&-` coverage is a structurally incomplete
#   blocklist. flock was removed entirely in GH#18668 (Path A) — see
#   reference/bash-fd-locking.md for the full rationale and policy.
#
# Called by launchd every 180s via the supervisor-pulse plist.

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf '[pulse-wrapper] must be run by bash; use: bash -lc '\''source ~/.aidevops/agents/scripts/pulse-wrapper.sh; <command>'\''\n' >&2
	return 2 2>/dev/null || exit 2
fi

set -euo pipefail

_pulse_wrapper_deployed_scripts_dir() {
	local agents_dir="${AIDEVOPS_AGENTS_DIR:-}"
	local home_dir="${HOME:-}"

	if [[ -n "$agents_dir" && -d "${agents_dir}/scripts" ]]; then
		(cd "${agents_dir}/scripts" && pwd -P) || return 1
		return 0
	fi

	if [[ -n "$home_dir" && -d "${home_dir}/.aidevops/agents/scripts" ]]; then
		(cd "${home_dir}/.aidevops/agents/scripts" && pwd -P) || return 1
		return 0
	fi

	return 1
}

_pulse_wrapper_resolve_script_dir() {
	local source_path="${1:-}"
	local source_dir=""
	local resolved_dir=""

	if [[ -n "$source_path" ]]; then
		source_dir="${source_path%/*}"
		if [[ "$source_dir" == "$source_path" ]]; then
			source_dir="."
		fi

		if [[ -d "$source_dir" ]]; then
			(cd "$source_dir" && pwd -P) || return 1
			return 0
		fi
	fi

	if resolved_dir="$(_pulse_wrapper_deployed_scripts_dir)"; then
		printf '[pulse-wrapper] WARN: script directory unavailable (%s); recovering with deployed scripts directory: %s\n' \
			"${source_dir:-<unknown>}" "$resolved_dir" >&2
		printf '%s\n' "$resolved_dir"
		return 0
	fi

	return 1
}

#######################################
# PATH normalisation
# The MCP shell environment may have a minimal PATH that excludes /bin
# and other standard directories, causing `env bash` to fail. Ensure
# essential directories are always present.
#######################################
_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/bin:/usr/bin"
if [[ "$(uname -s 2>/dev/null || true)" != "Darwin" && -d "/home/linuxbrew/.linuxbrew/bin" ]]; then
	_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin"
fi
export PATH="${_aidevops_path_prefix}:${PATH}"
unset _aidevops_path_prefix

#######################################
# FD budget: raise soft limit to avoid exhaustion (GH#19044)
#
# The launchd plist inherits macOS default maxfiles (256 soft, unlimited
# hard). The pulse sources ~20 modules and spawns gh/jq/git subprocesses
# per repo per cycle — 256 FDs is structurally insufficient. Raise the
# soft limit to 4096 (well within the hard limit) BEFORE sourcing any
# modules or spawning any subprocesses.
#
# This is the primary fix for the FD exhaustion observed in GH#18787:
#   pulse-simplification-state.sh: redirection error: cannot duplicate fd: Too many open files
#
# Defence-in-depth: .agents/scripts/setup/modules/schedulers.sh also sets
# SoftResourceLimits.NumberOfFiles=4096 in the launchd plist, but the
# ulimit raise here is the runtime safety net in case the plist is stale.
#######################################
ulimit -n 4096 2>/dev/null || ulimit -n 1024 2>/dev/null || true

# Regression guard: assert FD budget is adequate. Log loudly if not.
_pulse_fd_limit=$(ulimit -n 2>/dev/null || echo "256")
if [[ "$_pulse_fd_limit" =~ ^[0-9]+$ ]] && [[ "$_pulse_fd_limit" -lt 1024 ]]; then
	printf '[pulse-wrapper] WARNING: FD soft limit is %s (< 1024). Pulse may hit FD exhaustion. Run: ulimit -n 4096 or update the launchd plist SoftResourceLimits.NumberOfFiles (GH#19044)\n' "$_pulse_fd_limit" >&2
fi
unset _pulse_fd_limit

#######################################
# Startup jitter — desynchronise concurrent pulse instances
#
# When multiple runners share the same launchd interval (120s), their
# pulses fire simultaneously, creating a race window where both evaluate
# the same issue before either can self-assign. A random 0-30s delay at
# startup staggers the pulses so the first runner to wake assigns the
# issue before the second runner evaluates it.
#
# PULSE_JITTER_MAX: max jitter in seconds (default 30, set to 0 to disable)
#######################################
PULSE_JITTER_MAX="${PULSE_JITTER_MAX:-30}"
# Phase 0 (t1963): diagnostic flags must return instantly. Skip jitter
# when --self-check, --dry-run, --merge-only, or --refill-only appears anywhere in the
# argument list (or PULSE_DRY_RUN=1 is set) so CI, post-install
# verification, and interactive debugging aren't delayed by up to 30 s of
# random sleep. --merge-only skips jitter because the 60s plist interval is
# tight; adding up to 30s jitter would inflate the worst-case merge latency
# to 90s+, defeating the <=90s PR-landing target (t21247, GH#21247).
# GH#18614: iterate through all args — not just $1 — so diagnostic
# flags are detected regardless of their position in the invocation.
_pulse_skip_jitter=0
if [[ "${PULSE_DRY_RUN:-0}" == "1" ]]; then
	_pulse_skip_jitter=1
else
	for _pulse_arg in "$@"; do
		if [[ "$_pulse_arg" == "--self-check" || "$_pulse_arg" == "--dry-run" || "$_pulse_arg" == "--merge-only" || "$_pulse_arg" == "--refill-only" ]]; then
			_pulse_skip_jitter=1
			break
		fi
	done
	unset _pulse_arg
fi

# GH#21471: Pre-jitter fast-fail (t3010).
# If another pulse instance holds the lock, exit 0 BEFORE sleeping the
# jitter. Prevents launchd-respawn pile-up when cycles exceed StartInterval:
# each new instance was sleeping 0-30s of jitter before the is-running
# check in main(), causing 5+ queued instances during long cycles.
# Uses hardcoded paths — pulse-wrapper-config.sh is not yet sourced here.
# Biased toward false negatives: if PID file is absent, stat fails, or the
# holder exceeds the max-age ceiling, fall through to main() where
# acquire_instance_lock handles stale-lock reclaim properly.
# Early source: _file_mtime_epoch needed before shared-constants.sh is loaded.
# shellcheck source=./portable-stat.sh
_pw_source_path="${BASH_SOURCE[0]:-$0}"
_pw_bootstrap_script_dir="$(_pulse_wrapper_resolve_script_dir "$_pw_source_path")" || {
	printf '[pulse-wrapper] FATAL: cannot resolve script directory for %s\n' "$_pw_source_path" >&2
	return 2 2>/dev/null || exit 2
}
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" && -r "${_pw_bootstrap_script_dir}/pulse-runtime-pin.sh" ]]; then
	# shellcheck source=./pulse-runtime-pin.sh
	source "${_pw_bootstrap_script_dir}/pulse-runtime-pin.sh"
	pulse_runtime_pin_reexec "${_pw_bootstrap_script_dir%/scripts}" "scripts/pulse-wrapper.sh" "$@" || {
		_pw_pin_rc=$?
		return "$_pw_pin_rc" 2>/dev/null || exit "$_pw_pin_rc"
	}
	unset _pw_pin_rc
fi
source "${_pw_bootstrap_script_dir}/portable-stat.sh"
# shellcheck source=./runtime-bundle-lease.sh
source "${_pw_bootstrap_script_dir}/runtime-bundle-lease.sh"
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
	if ! aidevops_runtime_bundle_lease_acquire "${_pw_bootstrap_script_dir%/scripts}"; then
		printf '[pulse-wrapper] FATAL: could not acquire runtime bundle lease for %s\n' "${_pw_bootstrap_script_dir%/scripts}" >&2
		return 2 2>/dev/null || exit 2
	fi
	trap 'aidevops_runtime_bundle_lease_release' EXIT
fi
unset _pw_source_path _pw_bootstrap_script_dir
if [[ "$_pulse_skip_jitter" -eq 0 ]]; then
	_pw_ffjit_lockdir="${HOME}/.aidevops/logs/pulse-wrapper.lockdir"
	_pw_ffjit_pid_file="${_pw_ffjit_lockdir}/pid"
	if [[ -f "$_pw_ffjit_pid_file" ]]; then
		_pw_ffjit_pid=$(cat "$_pw_ffjit_pid_file" 2>/dev/null || true)
		if [[ "$_pw_ffjit_pid" =~ ^[0-9]+$ ]] && kill -0 "$_pw_ffjit_pid" 2>/dev/null; then
			# Age check mirrors main()'s is-running short-circuit (t2829).
			# Use lockdir mtime as lock-acquired timestamp (mkdir is atomic).
			_pw_ffjit_mtime=$(_file_mtime_epoch "$_pw_ffjit_lockdir")
			_pw_ffjit_now=$(date +%s)
			_pw_ffjit_age=$((_pw_ffjit_now - _pw_ffjit_mtime))
			if [[ "$_pw_ffjit_age" -le "${PULSE_LOCK_MAX_AGE_S:-1800}" ]]; then
				printf '[pulse-wrapper] another instance running (PID %s, age %ss), skipping\n' \
					"$_pw_ffjit_pid" "$_pw_ffjit_age" \
					>>"${HOME}/.aidevops/logs/pulse-wrapper.log" 2>/dev/null || true
				exit 0
			fi
			# Holder exceeds age ceiling — fall through to main() for stale-lock reclaim.
		fi
	fi
	unset _pw_ffjit_lockdir _pw_ffjit_pid_file _pw_ffjit_pid \
		_pw_ffjit_mtime _pw_ffjit_now _pw_ffjit_age
fi

if [[ "$_pulse_skip_jitter" -eq 0 && "$PULSE_JITTER_MAX" =~ ^[0-9]+$ && "$PULSE_JITTER_MAX" -gt 0 ]]; then
	# $RANDOM is 0-32767; modulo gives 0 to PULSE_JITTER_MAX
	jitter_seconds=$((RANDOM % (PULSE_JITTER_MAX + 1)))
	if [[ "$jitter_seconds" -gt 0 ]]; then
		sleep "$jitter_seconds"
	fi
fi
unset _pulse_skip_jitter

# Track pulse start time for signature footer elapsed time (GH#13099)
PULSE_START_EPOCH=$(date +%s)

# Use ${BASH_SOURCE[0]:-$0} for shell portability — BASH_SOURCE is undefined
# in zsh, which is the MCP shell environment. This fallback ensures SCRIPT_DIR
# resolves correctly whether the script is executed directly (bash) or sourced
# from zsh. See GH#3931.
SCRIPT_DIR="$(_pulse_wrapper_resolve_script_dir "${BASH_SOURCE[0]:-$0}")" || return 2>/dev/null || exit
AIDEVOPS_AGENTS_DIR="${SCRIPT_DIR%/scripts}"
AGENTS_DIR="$AIDEVOPS_AGENTS_DIR"
export AIDEVOPS_AGENTS_DIR AGENTS_DIR

# GH#24900: PATH normalisation above restores system bins for minimal
# launchd/MCP environments, but it must not let the real gh binary outrank the
# aidevops gh shim. Re-prioritise the framework scripts directory once it is
# resolved so every subprocess inherits instrumentation and budget routing.
export PATH="${SCRIPT_DIR}:${PATH}"
# Source shared-constants.sh BEFORE config-helper.sh so the bash 4+ re-exec
# guard (t2087/t2176) fires at BASH_SOURCE depth 1, where the outermost caller
# is unambiguously pulse-wrapper.sh. If config-helper.sh is sourced first and it
# sources shared-constants.sh, the guard would see the intermediate helper at
# BASH_SOURCE[1] and re-exec the wrong script. (GH#19632)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config-helper.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"

# Phase 1 (t1966, GH#18364): sourced leaf modules extracted from this file.
# Each module has an _PULSE_<CLUSTER>_LOADED include guard so re-sourcing is a no-op.
# Order does not matter for correctness (bash defers function resolution until
# call time). Listed in plan §3 cluster order for readability.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-model-routing.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-instance-lock.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-meta-parse.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-repo-meta.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-routines.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dependabot-alert-monitor.sh"
# GH#23604: semantics-preserving exact-output PR-list provider cache used by
# pulse hot paths that need GraphQL-only fields such as reviewDecision.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-pr-list-cache.sh"
# Phase 2 (t1967, GH#18367): 4 leaves-with-fan-in extracted from this file.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-queue-governor.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-nmr-approval.sh"
# GH#28717: bounded exact-target recovery for cryptographically approved NMR
# targets that Actions conservatively re-blocks after a transient API failure.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-approval-reconcile.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-dep-graph.sh"
# shellcheck source=./dependency-event-reconciler.sh
source "${SCRIPT_DIR}/dependency-event-reconciler.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-fast-fail.sh"
# Phase 3 (t1971, GH#18372): 4 operational plumbing clusters extracted from this file.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-capacity.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-logging.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-watchdog.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-capacity-alloc.sh"
# Phase 4 (t1972, GH#18378): pr-gates + merge cycle co-extracted into one module.
# GH#19836: further split — downstream conflict + feedback clusters into separate
# modules. Source order matters: pulse-merge.sh first (defines the dispatcher
# callers), then the two downstream modules. Bash's lazy function resolution
# handles the runtime cross-module calls (e.g., _check_pr_merge_gates →
# _dispatch_pr_fix_worker in pulse-merge-feedback.sh) without issue.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-merge.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-merge-conflict.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-merge-feedback.sh"
# t3193 (GH#21895): stuck-merge detector + zero-progress circuit breaker.
# Sourced AFTER pulse-merge.sh so its functions can call _extract_linked_issue
# at runtime via bash lazy resolution (matches the conflict/feedback pattern).
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-merge-stuck.sh"
# Phase 5 (t1973, GH#18380): cleanup + issue-reconcile extracted into two modules.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-cleanup.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-issue-reconcile.sh"
# GH#21604 (t3035): orphan worker reaper — detects and reattaches workers that
# survived a pulse restart. Called once per cycle in _pulse_run_deterministic_pipeline.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/orphan-worker-reaper.sh"
# Phase 6 (t1974, GH#18382): simplification cluster extracted (largest single extraction).
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-simplification.sh"
# t2020 (GH#18483): state sub-cluster split out to clear the 2,000-line gate
# that was blocking #18420 (t1993). Must be sourced AFTER pulse-simplification.sh
# because _simplification_state_backfill_closed in the state module calls
# _complexity_scan_has_existing_issue which stays in the parent module. Bash
# resolves function names at call time, so source order is informational
# rather than strict, but this order reads "parent, then state sub-cluster".
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-simplification-state.sh"
# Phase 7 (t1975, GH#18385): prefetch cluster extracted.
# GH#18400/t1987: pulse-prefetch.sh now sources focused sub-clusters.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-prefetch.sh"
# Phase 8 (t1976, GH#18387): triage cluster extracted.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-triage.sh"
# Phase 9 (t1977, GH#18389): dispatch-core + dispatch-engine extracted.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-dispatch-core.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"
# Phase 10 (t1978, GH#18391): FINAL — quality-debt + ancillary-dispatch extracted.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-quality-debt.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-ancillary-dispatch.sh"
# GH#19949: canonical-repo fast-forward + stale worktree sweep (30min cadence).
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-canonical-maintenance.sh"
# t2350 (GH#19948): DIRTY-PR sweep runs every 30min after the merge pass.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-dirty-pr-sweep.sh"
# t2865 (GH#20922): canonical-worktree pull conflict auto-recovery.
# Called from _pulse_refresh_repo on git pull --ff-only failure.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-canonical-recovery.sh"

#######################################
# SSH agent integration for commit signing (t1882)
# Source the persisted agent.env so headless workers can sign commits
# without a passphrase prompt. Safe to source even if the file doesn't
# exist — the conditional guard prevents errors.
#######################################
if [[ -f "$HOME/.ssh/agent.env" ]]; then
	# shellcheck source=/dev/null
	. "$HOME/.ssh/agent.env" >/dev/null 2>&1 || true
fi

#######################################
# Source credentials.sh for API keys (GH#17546)
# Launchd plists bake env vars at setup time — they go stale when
# credentials.sh is later updated. Sourcing at runtime ensures the
# pulse always uses the current provider API keys, regardless of what
# the plist embedded. Model config is now derived from the pool +
# routing table (GH#17769), not env vars.
#######################################
if [[ -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
	# shellcheck source=/dev/null
	if ! . "${HOME}/.config/aidevops/credentials.sh" 2>/dev/null; then
		printf '[pulse-wrapper] WARN: credentials.sh exists but failed to source; API keys may be unavailable\n' >&2
	fi
fi

if ! type config_get >/dev/null 2>&1; then
	CONFIG_GET_FALLBACK_WARNED=0
	config_get() {
		local requested_key="$1"
		local default_value="$2"
		if [[ "$CONFIG_GET_FALLBACK_WARNED" -eq 0 ]]; then
			printf '[pulse-wrapper] WARN: config_get fallback active; config-helper unavailable, so default config values are being applied starting with key "%s"\n' "$requested_key" >&2
			CONFIG_GET_FALLBACK_WARNED=1
		fi
		printf '%s\n' "$default_value"
		return 0
	}
fi

# ---------------------------------------------------------------------------
# GraphQL budget priority scheduler (GH#22479)
#
# Defines lightweight helpers before the extracted pulse modules are sourced so
# modules such as pulse-dispatch-engine.sh can call them at runtime. Low budget
# reserves GraphQL for merge readiness, dispatch capacity checks, and worker
# launch safety gates; optional enrichment/dashboard/routine/cache stages defer.
# ---------------------------------------------------------------------------
_pulse_gh_rate_limit_json() {
	local _rate_json=""
	local _rc=0
	local _secs="${AIDEVOPS_GH_READ_TIMEOUT:-15}"
	[[ "$_secs" =~ ^[0-9]+$ ]] || _secs=15

	if declare -F _cb_rate_limit_json >/dev/null 2>&1; then
		_rate_json=$(_cb_rate_limit_json normal 2>/dev/null) || _rc=$?
	elif declare -F _gh_with_timeout >/dev/null 2>&1; then
		_rate_json=$(_gh_with_timeout read gh api rate_limit 2>/dev/null) || _rc=$?
	elif declare -F timeout_sec >/dev/null 2>&1; then
		_rate_json=$(timeout_sec "$_secs" gh api rate_limit 2>/dev/null) || _rc=$?
	elif command -v timeout >/dev/null 2>&1; then
		_rate_json=$(timeout "$_secs" gh api rate_limit 2>/dev/null) || _rc=$?
	elif command -v gtimeout >/dev/null 2>&1; then
		_rate_json=$(gtimeout "$_secs" gh api rate_limit 2>/dev/null) || _rc=$?
	else
		return 1
	fi

	[[ "$_rc" -eq 0 ]] || return "$_rc"
	[[ -n "$_rate_json" ]] || return 1
	printf '%s\n' "$_rate_json"
	return 0
}

_pulse_graphql_budget_priority_decision() {
	local _threshold="${AIDEVOPS_PULSE_OPTIONAL_BUDGET_THRESHOLD:-${AIDEVOPS_PULSE_PREFETCH_BUDGET_THRESHOLD:-1250}}"
	[[ "$_threshold" =~ ^[0-9]+$ ]] || _threshold=1250
	local _rate_json=""
	_rate_json=$(_pulse_gh_rate_limit_json) || _rate_json=""
	if [[ -z "$_rate_json" ]]; then
		printf 'unknown ? ? %s\n' "$_threshold"
		return 0
	fi
	local _remaining="" _limit=""
	_remaining=$(printf '%s' "$_rate_json" | jq -r '.resources.graphql.remaining // ""' 2>/dev/null) || _remaining=""
	_limit=$(printf '%s' "$_rate_json" | jq -r '.resources.graphql.limit // ""' 2>/dev/null) || _limit=""
	if [[ ! "$_remaining" =~ ^[0-9]+$ ]] || [[ ! "$_limit" =~ ^[0-9]+$ ]]; then
		printf 'unknown ? ? %s\n' "$_threshold"
		return 0
	fi
	if [[ "$_remaining" -lt "$_threshold" ]]; then
		printf 'reserve %s %s %s\n' "$_remaining" "$_limit" "$_threshold"
		return 0
	fi
	printf 'normal %s %s %s\n' "$_remaining" "$_limit" "$_threshold"
	return 0
}

_pulse_set_graphql_budget_priority() {
	local _decision="" _class="" _remaining="" _limit="" _threshold=""
	_decision=$(_pulse_graphql_budget_priority_decision)
	read -r _class _remaining _limit _threshold <<<"$_decision"
	[[ -n "$_class" ]] || _class="unknown"
	export AIDEVOPS_PULSE_GRAPHQL_BUDGET_CLASS="$_class"
	export AIDEVOPS_PULSE_GRAPHQL_BUDGET_REMAINING="$_remaining"
	export AIDEVOPS_PULSE_GRAPHQL_BUDGET_LIMIT="$_limit"
	export AIDEVOPS_PULSE_GRAPHQL_BUDGET_THRESHOLD="$_threshold"
	if [[ "$_class" == "reserve" ]]; then
		echo "[pulse-wrapper] GraphQL budget reserve mode: remaining=${_remaining}/${_limit} < optional_threshold=${_threshold}; deferring optional stages, preserving merge/dispatch budget (GH#22479)" >>"$LOGFILE"
		if declare -F pulse_stats_increment >/dev/null 2>&1; then
			pulse_stats_increment "pulse_graphql_budget_reserve_mode" 2>/dev/null || true
		fi
	elif [[ "$_class" == "unknown" ]]; then
		echo "[pulse-wrapper] GraphQL budget priority unknown — proceeding fail-open for optional stages (GH#22479)" >>"$LOGFILE"
	fi
	return 0
}

_pulse_should_defer_budget_priority_stage() {
	local _stage="$1"
	[[ "${AIDEVOPS_PULSE_GRAPHQL_BUDGET_CLASS:-normal}" == "reserve" ]] || return 1
	case "$_stage" in
	cache_prime | fix_the_fixer_detector | coderabbit_review | post_merge_scanner | pr_review_thread_response | auto_decomposer_scanner | dedup_cleanup | fast_fail_prune_expired | evaluate_routines | dependabot_alert_monitor | canonical_maintenance | dashboard_freshness_check | llm_supervisor)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

_pulse_defer_budget_priority_stage() {
	local _stage="$1"
	echo "[pulse-wrapper] budget-priority: deferred optional stage '${_stage}' (class=${AIDEVOPS_PULSE_GRAPHQL_BUDGET_CLASS:-unknown}, remaining=${AIDEVOPS_PULSE_GRAPHQL_BUDGET_REMAINING:-?}/${AIDEVOPS_PULSE_GRAPHQL_BUDGET_LIMIT:-?}, threshold=${AIDEVOPS_PULSE_GRAPHQL_BUDGET_THRESHOLD:-?})" >>"$LOGFILE"
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "pulse_graphql_budget_stage_deferred" 2>/dev/null || true
		pulse_stats_increment "pulse_graphql_budget_stage_deferred_${_stage}" 2>/dev/null || true
	fi
	return 0
}

_pulse_run_optional_stage() {
	local _stage="$1"
	shift
	if _pulse_should_defer_budget_priority_stage "$_stage"; then
		_pulse_defer_budget_priority_stage "$_stage"
		return 0
	fi
	"$@"
	return $?
}

_pulse_run_optional_stage_with_timeout() {
	local _stage="$1"
	local _timeout="$2"
	shift 2
	if _pulse_should_defer_budget_priority_stage "$_stage"; then
		_pulse_defer_budget_priority_stage "$_stage"
		return 0
	fi
	run_stage_with_timeout "$_stage" "$_timeout" "$@"
	return $?
}

# Configuration defaults, validation, path constants, and per-cycle health
# counters extracted to pulse-wrapper-config.sh (GH#20781).
# shellcheck source=./pulse-wrapper-config.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-wrapper-config.sh"

# Cycle-running helpers + bootstrap helpers extracted to two sub-libraries
# (GH#21311 / t2936-child). Order matters only insofar as
# pulse-wrapper-config.sh must be sourced first (already done above) so
# LOGFILE/PULSE_DIR/_PULSE_REFRESHED_THIS_CYCLE are in scope when the
# cycle library declares its functions. Bash's lazy function resolution
# handles cross-module calls (e.g. _pulse_handle_self_check →
# _pulse_execute_self_check) regardless of source order.
# shellcheck source=./pulse-wrapper-cycle.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-wrapper-cycle.sh"
# shellcheck source=./pulse-wrapper-bootstrap.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-wrapper-bootstrap.sh"
source "${SCRIPT_DIR}/pulse-event-refill.sh"
if [[ ! -x "$HEADLESS_RUNTIME_HELPER" ]]; then
	printf '[pulse-wrapper] ERROR: headless runtime helper is missing or not executable: %s (SCRIPT_DIR=%s)\n' "$HEADLESS_RUNTIME_HELPER" "$SCRIPT_DIR" >&2
	exit 1
fi

#######################################
# Ensure log and workspace directories exist
#######################################
mkdir -p "$(dirname "$PIDFILE")"
mkdir -p "$PULSE_DIR"

# Provided by worker-lifecycle-common.sh: _kill_tree, _force_kill_tree,
# _get_process_age, _get_pid_cpu, _get_process_tree_cpu,
# _compute_struggle_ratio, check_session_count.
# Provided by pulse-prefetch.sh (GH#15286): delta prefetch cache helpers.
# Provided by pulse-wrapper-cycle.sh (GH#21311 / t2936-child):
# _pulse_refresh_repo, run_pulse.

#######################################
# Check if the pulse is allowed to run.
#
# Consent model (layered, highest priority first):
#   1. Session stop flag — `aidevops pulse stop` creates this to pause
#      the pulse without uninstalling it. Checked first so stop always wins.
#   2. Session start flag — `aidevops pulse start` creates this. If present,
#      the pulse runs regardless of config (explicit user action).
#   3. Config consent — setup.sh writes orchestration.supervisor_pulse=true
#      when the user consents. This is the persistent, reboot-surviving gate.
#
# If none of the above are set, the pulse was installed without config
# consent (shouldn't happen after GH#2926) — skip as a safety fallback.
#
# Returns: 0 if pulse should run, 1 if not
#######################################
check_session_gate() {
	# Stop flag takes priority — user explicitly paused
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Pulse paused (stop flag present) — resume with: aidevops pulse start" >>"$LOGFILE"
		return 1
	fi

	# Session start flag — explicit user action, always allowed
	if [[ -f "$SESSION_FLAG" ]]; then
		return 0
	fi

	# Config consent — the persistent gate that survives reboots.
	# Delegates to config_enabled from config-helper.sh (sourced via
	# shared-constants.sh), which handles: env var override
	# (AIDEVOPS_SUPERVISOR_PULSE) > user JSONC config > defaults.
	# Single canonical implementation shared with pulse-session-helper.sh.
	if type config_enabled &>/dev/null && config_enabled "orchestration.supervisor_pulse"; then
		return 0
	fi

	echo "[pulse-wrapper] Pulse not enabled — set orchestration.supervisor_pulse=true in config or run: aidevops pulse start" >>"$LOGFILE"
	return 1
}

#######################################
# Daily complexity scan helpers (GH#5628, GH#15285)
#######################################

#######################################
# Simplification state tracking — git-committed registry of simplified files.
#
# State file: .agents/configs/simplification-state.json (in repo, on main)
# Format: { "files": { "path": { "hash": "<git blob sha>", "at": "ISO", "pr": N } } }
#
# - "hash" is the git blob SHA of the file at simplification time
# - When scan sees a file in state with matching hash → skip (already done)
# - When hash differs → file changed since simplification → create recheck issue
# - State is committed to main and pushed, so all users share it
#######################################

#######################################
# Complexity scan (GH#5628, GH#15285)
#
# Deterministic scan using shell-based heuristics via complexity-scan-helper.sh:
# - Batch hash comparison against simplification-state.json (skip unchanged files)
# - Shell heuristics: line count, function count, nesting depth
# - No per-file LLM analysis — LLM reserved for daily deep sweep only
#
# Scans both shell scripts (.sh) and agent docs (.md) for complexity:
# - .sh files: functions exceeding COMPLEXITY_FUNC_LINE_THRESHOLD lines
# - .md files: agent docs at/above COMPLEXITY_MD_MIN_LINES (default 500);
#   classification determines compress-vs-split action.
#
# Protected files (build.txt, AGENTS.md, pulse.md, pulse-sweep.md) are excluded.
# Results processed longest-first. .md issues get tier:standard by default.
#
# Daily LLM sweep (GH#15285): if simplification debt hasn't decreased in 6h,
# creates a tier:thinking issue for LLM-powered deep review of stalled debt.
#
# Runs at most once per COMPLEXITY_SCAN_INTERVAL (default 15 min).
# Creates up to 5 issues per run; open cap (500) prevents backlog flooding.
#
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################

# count_active_workers: now provided by worker-lifecycle-common.sh (sourced above).
# Removed from pulse-wrapper.sh to eliminate divergence with stats-functions.sh.

#######################################
# Triage content-hash dedup (GH#17746).
#
# Without dedup, NMR issues are re-triaged every pulse cycle:
# lock → agent → no output → unlock → repeat. This wastes tokens,
# API calls, and pollutes the issue timeline with lock/unlock events.
#
# Strategy: hash the issue body + human comments (excluding bot and
# review comments). Cache the hash. Skip triage when content is
# unchanged. Re-triage when the author edits the body or adds a
# new comment.
#######################################
TRIAGE_CACHE_DIR="${TRIAGE_CACHE_DIR:-${HOME}/.aidevops/.agent-workspace/tmp/triage-cache}"

#######################################
# GH#17827, t2014: Triage failure retry cap (default 1 — single attempt).
#
# When triage fails (no review posted), the GH#17873 fix intentionally
# skips caching the content hash so the next cycle retries. But failing
# triages are overwhelmingly deterministic (format-validation rejections,
# not transient model quota) — three retries per content version burn
# three full opus agent invocations (~100K chars each) and three
# lock/unlock pairs on the issue timeline, all to reach the same outcome.
#
# Solution: cap retries at 1. The FIRST failure increments the counter
# to 1, sees 1 >= TRIAGE_MAX_RETRIES, caches the hash, and marks the
# issue with triage-failed. Subsequent cycles skip via the content-hash
# cache — zero lock/unlock, zero agent invocations. A new human comment
# changes the hash and resets the counter, giving another attempt.
#
# Transient failures (network, gh API, model rate-limit) are caught
# earlier in the dispatch loop (before lock_issue_for_worker) or
# handled by the model rotation pool, so the retry budget here adds no
# value for transients — only cost for deterministic failures.
#
# Maintainers can force a re-triage by removing the triage-failed label
# and the corresponding .failures/.hash files in TRIAGE_CACHE_DIR.
#######################################
TRIAGE_MAX_RETRIES="${TRIAGE_MAX_RETRIES:-1}"

#######################################
# Atomic dispatch: dedup guard + assign + launch in a single call (GH#12436)
#
# Root cause of GH#12141 and GH#12155: the pulse.md instructed the LLM to
# run check_dispatch_dedup, then gh issue edit, then headless-runtime-helper.sh
# as three separate steps. The LLM skipped check_dispatch_dedup entirely in
# both incidents — zero DISPATCH_CLAIM comments were posted. This function
# makes the dedup guard non-skippable by wrapping all three steps into a
# single deterministic call. The LLM calls one function; the function
# enforces all 7 dedup layers before assigning and launching.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - dispatch_title (e.g., "Issue #42: Fix auth")
#   $4 - issue_title (e.g., "t042: Fix auth" — for merged-PR fallback)
#   $5 - self_login (runner's GitHub login)
#   $6 - repo_path (local path to the repo for the worker)
#   $7 - prompt (full prompt string for the worker, e.g., "/full-loop ...")
#   $8 - session_key (optional; defaults to "issue-${issue_number}")
#
# Exit codes:
#   0 - dispatched successfully
#   1 - dedup guard blocked dispatch (duplicate detected)
#   2 - dispatch failed after passing dedup (assign or launch error)
#######################################

#######################################
# Issue consolidation: detect multi-comment issues where substantive
# comments (not dispatch/approval machinery) have materially changed
# the issue's scope since the body was written.
#
# Threshold: ISSUE_CONSOLIDATION_COMMENT_THRESHOLD (default 2) substantive
# comments with >500 chars each (excludes dispatch claims, approval sigs,
# bot comments, and recovery comments).
#
# When triggered, adds a "needs-consolidation" label and posts a comment
# explaining the action. The issue is skipped for dispatch until a
# consolidation worker merges the comment thread into a clean issue.
#
# Arguments: $1 issue_number, $2 repo_slug
# Returns: 0 if consolidation is needed, 1 if not
#
# Defaults are owned by pulse-triage.sh (module-level := block) which is
# sourced above. Declarations removed from here to eliminate duplicate-default
# drift (t2143). Override via env before sourcing pulse-triage.sh if needed.
#######################################

#######################################
# Large-file simplification gate: check if an issue body references
# files that exceed a line count threshold, indicating the worker will
# spend most of its context budget just reading the target file.
#
# When a large file is detected, the function:
#   1. Checks if a simplification task already exists for that file
#   2. If not, logs the finding for the simplification routine to pick up
#   3. Adds a label so the issue is held until simplification runs
#
# Arguments: $1 issue_number, $2 repo_slug, $3 issue_body, $4 repo_path
# Returns: 0 if gate triggered (hold dispatch), 1 if clear
#######################################
LARGE_FILE_LINE_THRESHOLD="${LARGE_FILE_LINE_THRESHOLD:-2000}"

# t2024: Scoped-range exemption for the large-file gate.
#
# The gate's purpose is to prevent a worker from paying the complexity tax
# of navigating a huge file when it only needs to understand a small section.
# If the issue body cites an explicit line range (e.g., "EDIT: file.sh:221-253")
# and the range is at most SCOPED_RANGE_THRESHOLD lines, the worker can
# navigate the cited range directly without reading the whole file — so we
# pass the gate regardless of the enclosing file's total line count.
#
# Single-line citations (e.g., "file.sh:1477") are treated as context references
# for the human reader, not implementation targets, and are excluded from
# gate evaluation entirely. A worker never "edits line 1477" — they edit a
# function or a range; a bare line number is documentation, not a target.
#
# File references without any line qualifier (e.g., "file.sh") fall through
# to the existing file-size check — this preserves the original safety for
# whole-file rewrites where the worker really does need to understand everything.
SCOPED_RANGE_THRESHOLD="${SCOPED_RANGE_THRESHOLD:-300}"

#######################################
# Per-issue retry state (t1888, GH#2076, GH#17384)
#
# Cause-aware retry backoff. See config block at line ~205 for the full
# decision tree. Key invariant: rate-limit failures with available accounts
# do NOT increment the counter or delay retry — they rotate immediately.
# Only exhaustion of all accounts or non-rate-limit failures trigger backoff.
#
# State file: FAST_FAIL_STATE_FILE (JSON, ~200 bytes per entry)
# Format: { "slug/number": { "count": N, "ts": epoch, "reason": "...",
#            "retry_after": epoch, "backoff_secs": N } }
#
# Integration points:
#   - pulse-wrapper.sh: fast_fail_record() on launch failure (recover_failed_launch_state)
#   - worker-watchdog.sh: _watchdog_record_failure_and_escalate() on worker kill
#   - pulse-wrapper.sh: fast_fail_reset() on PR merge / issue close
#   - pulse-wrapper.sh: fast_fail_is_skipped() in deterministic dispatch loop
#
# All functions are best-effort — failures are logged but never fatal.
#######################################

# dispatch_count_exceeded removed (t1927). An arbitrary hard cap on dispatch
# attempts gives up instead of solving. The correct approach is:
#   1. fast_fail with exponential backoff (already implemented) — gives the
#      system breathing room between attempts
#   2. escalate_issue_tier (already implemented) — moves to higher-capability
#      models after consecutive failures
#   3. stale recovery records fast-fail (already implemented) — silent timeouts
#      count as failures and feed into backoff + escalation
#   4. blocked-by enforcement (already implemented) — skips genuinely blocked work
#
# Together, these ensure the system keeps trying with progressively more
# capable models and longer backoff intervals, rather than giving up at an
# arbitrary number. The measure of success is issues getting solved, not
# issues getting labeled "stuck".

#######################################
# Apply dispatch_max after a pulse pass.
#######################################
# Deterministic merge pass: approve and merge all ready PRs.
#
# Runs every pulse cycle as a wrapper-level stage (not LLM-dependent).
# This prevents PR backlogs from accumulating when the LLM fails to
# execute merge steps or the prefetch was broken.
#
# A PR is merge-ready when ALL of:
#   1. mergeable == MERGEABLE (not conflicting)
#   2. Author is a collaborator (admin/maintain/write permission)
#   3. Not modifying .github/workflows/ without workflow token scope
#   4. No linked issue with needs-maintainer-review label
#   5. Not from an external contributor
#
# REVIEW_REQUIRED is not a blocker — the pulse user auto-approves
# collaborator PRs via approve_collaborator_pr().
#
# Conflicting PRs are closed with a comment (they will be superseded
# by workers re-dispatching the issue).
#
# Returns: 0 always (non-fatal — merge failures don't block the pulse)
#######################################
PULSE_MERGE_BATCH_LIMIT="${PULSE_MERGE_BATCH_LIMIT:-50}"
PULSE_MERGE_CLOSE_CONFLICTING="${PULSE_MERGE_CLOSE_CONFLICTING:-true}"

#######################################
# Decide whether to invoke the LLM supervisor this cycle.
#
# Returns 0 (true = run LLM) when:
#   - Last LLM run was >24h ago (daily sweep)
#   - Backlog is stalled: issue+PR count unchanged for 30+ min
#   - No backlog snapshot exists yet (first run)
#
# Returns 1 (false = skip LLM) when:
#   - Backlog is progressing (counts are decreasing)
#   - Daily sweep not yet due
#
# Side effect: writes the trigger mode to ${PULSE_DIR}/llm_trigger_mode
#   Values: "daily_sweep" | "stall" | "first_run"
#   Callers read this file to select the correct agent prompt
#   (pulse-sweep.md for daily_sweep, pulse.md for stall/first_run).
#
# State files:
#   ${PULSE_DIR}/last_llm_run_epoch     — epoch of last LLM invocation
#   ${PULSE_DIR}/backlog_snapshot.txt    — "epoch issues_count prs_count"
#   ${PULSE_DIR}/llm_trigger_mode        — last trigger reason (daily_sweep|stall|first_run)
#######################################
PULSE_LLM_STALL_THRESHOLD="${PULSE_LLM_STALL_THRESHOLD:-$(config_get "orchestration.llm_stall_threshold" "3600")}" # 1h (was 30 min; dispatch_max handles routine dispatch)
PULSE_LLM_DAILY_INTERVAL="${PULSE_LLM_DAILY_INTERVAL:-86400}"                                                      # 24h

#######################################
# Routine evaluation (t1925)
#
# Evaluates repeat: fields in TODO.md routines sections across pulse-enabled
# repos. Dispatches due routines:
#   - run: → execute script directly (zero LLM tokens)
#   - agent: → dispatch via headless-runtime-helper.sh
#
# State file: ~/.aidevops/.agent-workspace/routine-state.json
# Schedule parser: routine-schedule-helper.sh
#######################################
ROUTINE_STATE_FILE="${HOME}/.aidevops/.agent-workspace/routine-state.json"
ROUTINE_SCHEDULE_HELPER="${SCRIPT_DIR}/routine-schedule-helper.sh"
ROUTINE_LOG_HELPER="${SCRIPT_DIR}/routine-log-helper.sh"

# ---------------------------------------------------------------------------
# _pulse_execute_self_check
#
# Phase 0 (t1963, GH#18357): validate that all expected functions and module
# include-guards are present. Extracted from main() (GH#18689) to reduce
# cyclomatic complexity — the self-check body was ~100 lines inside main().
#
# Exit 0: all functions and guards present.
# Exit 1: at least one expected symbol is missing (names printed to stderr).
# ---------------------------------------------------------------------------
_pulse_execute_self_check() {
	local _sc_missing=()
	local _sc_fn
	local _sc_expected_fns=(
		resolve_dispatch_model_for_labels
		acquire_instance_lock
		check_dedup
		prefetch_state
		_extract_frontmatter_field
		check_external_contributor_pr
		run_cmd_with_timeout
		run_pulse
		cleanup_worktrees
		normalize_active_issue_assignments
		issue_has_required_approval
		run_weekly_complexity_scan
		get_repo_path_by_slug
		get_repo_role_by_slug
		dispatch_with_dedup
		_triage_content_hash
		normalize_count_output
		_ff_key
		build_dependency_graph_cache
		dependabot_alert_monitor_scan_repos
		dispatch_max
		merge_ready_prs_all_repos
		rotate_pulse_log
		evaluate_routines
		main
		write_pulse_health_file
		calculate_max_workers
		dispatch_enrichment_workers
		dispatch_triage_reviews
		sync_todo_refs_for_repo
		sync_todo_refs_all_repos
		_pulse_execute_self_check
		_pulse_handle_self_check
		_pulse_setup_dry_run_mode
		_pulse_run_deterministic_pipeline
		_pulse_maybe_run_llm_supervisor
		_pulse_set_graphql_budget_priority
		_pulse_run_optional_stage
		_pulse_run_optional_stage_with_timeout
		_carry_forward_pr_diff
		_dispatch_pr_fix_worker
		_close_conflicting_pr
		_interactive_pr_is_stale
		_interactive_pr_trigger_handover
		_dispatch_ci_fix_worker
		_dispatch_conflict_fix_worker
		run_canonical_maintenance
		dirty_pr_sweep_all_repos
		_pulse_refresh_repo
		pulse_canonical_recover
		check_dispatch_backoff
	)
	for _sc_fn in "${_sc_expected_fns[@]}"; do
		if ! declare -F "$_sc_fn" >/dev/null 2>&1; then
			_sc_missing+=("$_sc_fn")
		fi
	done
	# Module include guards. Appended as each phase lands.
	# Phase 1 (t1966, GH#18364): 5 leaf modules
	# Phase 2 (t1967, GH#18367): 4 leaves with fan-in
	# Phase 3 (t1971, GH#18372): 4 operational plumbing clusters
	# Phase 4 (t1972, GH#18378): pr-gates + merge cycle co-extracted
	# Phase 5 (t1973, GH#18380): cleanup + issue-reconcile extracted
	# Phase 6 (t1974, GH#18382): simplification cluster (29 fns, largest)
	# Phase 7 (t1975, GH#18385): prefetch cluster (26 fns)
	# Phase 8 (t1976, GH#18387): triage cluster (10 fns)
	# Phase 9 (t1977, GH#18389): dispatch-core + dispatch-engine (26 fns)
	# Phase 10 (t1978, GH#18391): quality-debt + ancillary-dispatch (FINAL — clears 2K gate)
	# GH#19836: pulse-merge.sh further split into three modules (conflict + feedback extracted).
	# GH#20781: config block extracted to pulse-wrapper-config.sh.
	local _sc_expected_guards=(
		_PULSE_WRAPPER_CONFIG_LOADED
		_PULSE_MODEL_ROUTING_LOADED
		_PULSE_INSTANCE_LOCK_LOADED
		_PULSE_META_PARSE_LOADED
		_PULSE_REPO_META_LOADED
		_PULSE_ROUTINES_LOADED
		_PULSE_QUEUE_GOVERNOR_LOADED
		_PULSE_NMR_APPROVAL_LOADED
		_PULSE_DEP_GRAPH_LOADED
		_PULSE_FAST_FAIL_LOADED
		_PULSE_CAPACITY_LOADED
		_PULSE_LOGGING_LOADED
		_PULSE_WATCHDOG_LOADED
		_PULSE_CAPACITY_ALLOC_LOADED
		_PULSE_MERGE_LOADED
		_PULSE_MERGE_CONFLICT_LOADED
		_PULSE_MERGE_FEEDBACK_LOADED
		_PULSE_CLEANUP_LOADED
		_PULSE_ISSUE_RECONCILE_LOADED
		_PULSE_SIMPLIFICATION_LOADED
		_PULSE_SIMPLIFICATION_STATE_LOADED
		_PULSE_PREFETCH_LOADED
		_PULSE_PREFETCH_INFRA_LOADED
		_PULSE_PREFETCH_FETCH_LOADED
		_PULSE_PREFETCH_REPO_LOADED
		_PULSE_PREFETCH_ORCHESTRATION_LOADED
		_PULSE_PREFETCH_SECONDARY_LOADED
		_PULSE_PREFETCH_WORKERS_LOADED
		_PULSE_TRIAGE_LOADED
		_PULSE_DISPATCH_CORE_LOADED
		_PULSE_DISPATCH_ENGINE_LOADED
		_PULSE_QUALITY_DEBT_LOADED
		_PULSE_ANCILLARY_DISPATCH_LOADED
		_PULSE_CANONICAL_MAINTENANCE_LOADED
		_PULSE_DIRTY_PR_SWEEP_LOADED
		_PULSE_CANONICAL_RECOVERY_LOADED
	)
	local _sc_guard="" _sc_val=""
	# The `${array[@]+"${array[@]}"}` pattern is safe under `set -u`
	# when the array is empty — required in Phase 0 where no module
	# guards exist yet.
	# GH#18614: all guard names in _sc_expected_guards are simple scalar
	# variables (e.g. _PULSE_MODEL_ROUTING_LOADED="1"). The indirect
	# expansion ${!_sc_guard:-} is therefore safe — it will never silently
	# read only the first element of an array. Never add array names to
	# _sc_expected_guards; use a dedicated scalar for each module.
	for _sc_guard in ${_sc_expected_guards[@]+"${_sc_expected_guards[@]}"}; do
		_sc_val="${!_sc_guard:-}"
		if [[ -z "$_sc_val" ]]; then
			_sc_missing+=("${_sc_guard} (module not loaded)")
		fi
	done
	if [[ ${#_sc_missing[@]} -eq 0 ]]; then
		printf 'self-check: ok (%d canonical functions defined, %d module guards verified)\n' \
			"${#_sc_expected_fns[@]}" "${#_sc_expected_guards[@]}"
		return 0
	fi
	printf 'self-check: FAIL: %d missing:\n' "${#_sc_missing[@]}" >&2
	local _sc_item
	for _sc_item in "${_sc_missing[@]}"; do
		printf '  - %s\n' "$_sc_item" >&2
	done
	return 1
}

#######################################
# is_no_work_rate_acceptable — cross-issue no_work rate circuit breaker.
# t2770 (GH#20640): pulse-level rate breaker for no_work storms.
#
# Counts fast_fail_record crash_type=no_work events in a rolling window
# (default: 10 events in 10 minutes). If exceeded, pauses all dispatch for
# this cycle with one alert line — prevents chasing an infrastructure outage
# with more workers that will also fail.
#
# Unlike the per-issue no_work escalation (GH#20639), this fires on population-
# wide anomalies: many DIFFERENT issues returning no_work simultaneously,
# signalling auth outage, GraphQL exhaustion, or wrapper stall recurrence.
#
# State file: ~/.aidevops/logs/pulse-no-work-breaker.state
# Format: line 1 = "EPOCH TOTAL_LOG_COUNT"; line 2+ = epoch timestamps of
# no_work events in the rolling window (pruned on each check).
#
# Counter: pulse_dispatch_no_work_breaker_tripped in pulse-stats.json
#
# Exit codes:
#   0 — rate acceptable; dispatch may proceed
#   1 — no_work rate exceeded; dispatch should be deferred this cycle
#
# Environment overrides:
#   AIDEVOPS_NO_WORK_WINDOW_SECS  — rolling window duration (default 600)
#   AIDEVOPS_NO_WORK_WINDOW_MAX   — max events in window (default 10; 0=disable)
#   AIDEVOPS_SKIP_NO_WORK_BREAKER=1 — emergency bypass
#######################################
is_no_work_rate_acceptable() {
	# Emergency bypass.
	if [[ "${AIDEVOPS_SKIP_NO_WORK_BREAKER:-0}" == "1" ]]; then
		echo "[pulse-wrapper] AIDEVOPS_SKIP_NO_WORK_BREAKER=1 — bypassing no_work rate check (t2770)" >>"$LOGFILE"
		return 0
	fi

	local window_secs="${NO_WORK_WINDOW_SECS:-600}"
	local max_events="${NO_WORK_WINDOW_MAX:-10}"
	window_secs="${AIDEVOPS_NO_WORK_WINDOW_SECS:-$window_secs}"
	max_events="${AIDEVOPS_NO_WORK_WINDOW_MAX:-$max_events}"

	# Disabled if max is 0.
	if [[ "$max_events" -eq 0 ]]; then
		return 0
	fi

	local state_file="${HOME}/.aidevops/logs/pulse-no-work-breaker.state"
	local logfile="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"
	local now
	now=$(date +%s)
	local cutoff=$((now - window_secs))

	# Count total no_work events in pulse.log (grep -c exits 1 on zero matches).
	local current_count=0
	if [[ -f "$logfile" ]]; then
		current_count=$(grep -c "crash_type=no_work" "$logfile" 2>/dev/null) || current_count=0
		[[ "$current_count" =~ ^[0-9]+$ ]] || current_count=0
	fi

	# Read state file: line 1 = last_scan_epoch last_total_count;
	# subsequent lines = epoch timestamps of recent no_work events.
	local last_total=0
	local -a window_timestamps=()
	if [[ -f "$state_file" ]]; then
		local sf_epoch="" sf_count=""
		read -r sf_epoch sf_count <"$state_file" 2>/dev/null || true
		[[ "$sf_epoch" =~ ^[0-9]+$ ]] || sf_epoch="0"
		[[ "$sf_count" =~ ^[0-9]+$ ]] || sf_count="0"
		last_total="$sf_count"

		# Load timestamps from state file (lines 2+), pruning those outside window.
		local ts_line
		while IFS= read -r ts_line; do
			[[ "$ts_line" =~ ^[0-9]+$ ]] || continue
			[[ "$ts_line" -ge "$cutoff" ]] && window_timestamps+=("$ts_line")
		done < <(tail -n +2 "$state_file" 2>/dev/null) || true
	fi

	# Compute new events since last check.
	local new_events=0
	if [[ "$current_count" -lt "$last_total" ]]; then
		# Log was rotated — reset baseline, treat all current events as new.
		last_total=0
	fi
	if [[ "$current_count" -gt "$last_total" ]]; then
		new_events=$((current_count - last_total))
	fi
	# Cap to max_events to bound state file growth.
	if [[ "$new_events" -gt "$max_events" ]]; then
		new_events="$max_events"
	fi

	# Append current timestamp for each new event.
	local i=0
	while [[ "$i" -lt "$new_events" ]]; do
		window_timestamps+=("$now")
		i=$((i + 1))
	done

	local window_count=${#window_timestamps[@]}

	# Write updated state file (atomic via temp file).
	local tmp_state="${state_file}.tmp.$$"
	{
		printf '%s %s\n' "$now" "$current_count"
		local ts
		for ts in ${window_timestamps[@]+"${window_timestamps[@]}"}; do
			printf '%s\n' "$ts"
		done
	} >"$tmp_state" 2>/dev/null && mv "$tmp_state" "$state_file" 2>/dev/null || rm -f "$tmp_state" 2>/dev/null || true

	# Check threshold.
	if [[ "$window_count" -ge "$max_events" ]]; then
		echo "[pulse-wrapper] no_work rate circuit breaker TRIPPED: ${window_count} events in ${window_secs}s window (max=${max_events}) — deferring dispatch this cycle (t2770)" >>"$LOGFILE"

		# Increment stats counter.
		if declare -F pulse_stats_increment >/dev/null 2>&1; then
			pulse_stats_increment "pulse_dispatch_no_work_breaker_tripped" 2>/dev/null || true
		fi

		return 1
	fi

	return 0
}

# ---------------------------------------------------------------------------
# _pulse_check_idle_backoff_gate (t3027 / GH#21584)
#
# Consults pulse-idle-backoff-helper.sh to decide whether this cycle should
# be skipped due to accumulated consecutive idle cycles. Operates as an
# ADDITIVE gate AFTER the rate-limit floor at L1257-1290 — at idle=0..4 the
# effective interval is identical to PULSE_MIN_INTERVAL_S (90s, no-op);
# only at idle≥5 does the gate extend the interval (180s/300s/600s/1800s).
#
# Reuses the existing rate-limit timestamp file as the single source of
# truth for "last cycle ran at".
#
# Returns:
#   0 — proceed with cycle (no backoff active OR interval elapsed)
#   1 — skip cycle (caller should return 0 from main())
#
# Bypass: AIDEVOPS_SKIP_PULSE_IDLE_BACKOFF=1
#
# Counter side effect: increments _PULSE_HEALTH_IDLE_CYCLE_SKIPPED on skip.
# ---------------------------------------------------------------------------
# Cycle gate, idle-backoff, prefetch-counter, and cycle-outcome helpers were
# extracted to keep this orchestrator below the large-file gate (GH#24930).
# shellcheck source=./pulse-wrapper-cycle-gates.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-wrapper-cycle-gates.sh"

# ---------------------------------------------------------------------------
# _pulse_run_deterministic_pipeline
#
# Deterministic cycle stages: merge pass, dependency graph, blocked-status
# refresh, fill floor, and routine evaluation. Extracted
# from main() (GH#18689) to reduce function length below the 100-line threshold.
#
# Side effects:
#   - merges ready PRs across all repos
#
# Exit code: always 0
# ---------------------------------------------------------------------------
_pulse_run_deterministic_pipeline() {
	_pulse_drain_prefetch_counters # t3027: bridge subshell counters
	if [[ -f "$STOP_FLAG" ]]; then
		_pulse_cycle_state_note_blocker stop-requested pulse-wrapper stop-flag || true
	fi

	# GH#21604 (t3035): Orphan worker reaper — runs at the start of every cycle
	# to detect workers that survived a pulse restart (no ledger entry) and
	# either reattach them to the new pulse instance or kill stuck ones (>2h).
	# Non-fatal: a failure here never blocks the pulse cycle.
	if [[ ! -f "$STOP_FLAG" ]]; then
		run_stage_with_timeout "reap_orphan_workers" "$PRE_RUN_STAGE_TIMEOUT" \
			reap_orphan_workers || true
	fi

	# Deterministic merge pass: approve and merge all ready PRs across pulse
	# repos. This runs BEFORE the LLM session because merging is free (no
	# worker slot) and deterministic (no judgment needed). Previously merging
	# was LLM-only, which meant backlogs of 100+ PRs accumulated when the
	# LLM failed to execute merge steps or the prefetch showed 0 PRs.
	#
	# t2862 (GH#20919): short-circuit if pulse-merge-routine.sh (the fast
	# 120s standalone runner) is already running or ran recently. This avoids
	# double-execution while keeping the in-cycle call as defense-in-depth
	# for environments where the launchd/cron schedule is not installed.
	# GH#24962: the standalone routine can run up to
	# PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS (default 600s), so the in-cycle guard
	# must honour the live PID lock first and use the same timeout window for the
	# timestamp fallback instead of the old 60s window.
	local _pulse_merge_routine_last_run="${HOME}/.aidevops/logs/pulse-merge-routine-last-run"
	local _pulse_merge_routine_lock_dir="${HOME}/.aidevops/.agent-workspace/locks/pulse-merge-routine.lock"
	local _pmr_skip=0
	if [[ -d "$_pulse_merge_routine_lock_dir" && -f "${_pulse_merge_routine_lock_dir}/pid" ]]; then
		local _pmr_lock_pid=""
		_pmr_lock_pid=$(cat "${_pulse_merge_routine_lock_dir}/pid" 2>/dev/null || true)
		if [[ "$_pmr_lock_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$_pmr_lock_pid" 2>/dev/null; then
			echo "[pulse-wrapper] deterministic_merge_pass: skipping (pulse-merge-routine pid=${_pmr_lock_pid} still running)" >>"$LOGFILE"
			_pmr_skip=1
		fi
	fi
	if [[ "$_pmr_skip" -eq 0 && -f "$_pulse_merge_routine_last_run" ]]; then
		local _pmr_last="" _pmr_now="" _pmr_elapsed=""
		local _pmr_recent_window="${PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS:-600}"
		[[ "$_pmr_recent_window" =~ ^[0-9]+$ ]] || _pmr_recent_window=600
		[[ "$_pmr_recent_window" -lt 1 ]] && _pmr_recent_window=600
		_pmr_last=$(cat "$_pulse_merge_routine_last_run" 2>/dev/null || echo "0")
		_pmr_now=$(date +%s 2>/dev/null || echo "0")
		[[ "$_pmr_last" =~ ^[0-9]+$ ]] || _pmr_last=0
		[[ "$_pmr_now" =~ ^[0-9]+$ ]] || _pmr_now=0
		_pmr_elapsed=$((_pmr_now - _pmr_last))
		if [[ "$_pmr_elapsed" -lt "$_pmr_recent_window" ]]; then
			echo "[pulse-wrapper] deterministic_merge_pass: skipping (pulse-merge-routine ran ${_pmr_elapsed}s ago, window=${_pmr_recent_window}s)" >>"$LOGFILE"
			_pmr_skip=1
		fi
	fi
	if [[ "$_pmr_skip" -eq 0 ]]; then
		run_stage_with_timeout "deterministic_merge_pass" "$PRE_RUN_STAGE_TIMEOUT" \
			merge_ready_prs_all_repos || true
	fi

	# t2350 (GH#19948): DIRTY-PR sweep — auto-rebase young + TODO-only conflicts,
	# auto-close stale abandoned PRs, escalate anything else. Internally gated
	# on DIRTY_PR_SWEEP_INTERVAL (default 30min) so this is cheap to call every
	# cycle. Runs AFTER merge pass so we never sweep a PR that was already
	# about to be merged. Failures are non-fatal — the sweep is advisory.
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared — skipping dirty-pr-sweep" >>"$LOGFILE"
	else
		run_stage_with_timeout "dirty_pr_sweep" "$PRE_RUN_STAGE_TIMEOUT" \
			dirty_pr_sweep_all_repos || true
	fi
	# Accumulate health counters written by merge_ready_prs_all_repos (GH#18571, GH#15107).
	# The function runs in a subshell via run_stage_with_timeout, so variable
	# updates are lost. Read the temp file it writes and accumulate here.
	local _merge_health_file="${TMPDIR:-/tmp}/pulse-health-merge-$$.tmp"
	if [[ -f "$_merge_health_file" ]]; then
		local _mhf_merged=0 _mhf_closed=0 _mhf_blocker_kind="none" _mhf_blocker_fingerprint="-"
		read -r _mhf_merged _mhf_closed _mhf_blocker_kind _mhf_blocker_fingerprint <"$_merge_health_file" || true
		[[ "$_mhf_merged" =~ ^[0-9]+$ ]] || _mhf_merged=0
		[[ "$_mhf_closed" =~ ^[0-9]+$ ]] || _mhf_closed=0
		_PULSE_HEALTH_PRS_MERGED=$((_PULSE_HEALTH_PRS_MERGED + _mhf_merged))
		_PULSE_HEALTH_PRS_CLOSED_CONFLICTING=$((_PULSE_HEALTH_PRS_CLOSED_CONFLICTING + _mhf_closed))
		if [[ "$_mhf_blocker_kind" != "none" && "$_mhf_blocker_fingerprint" != "-" ]]; then
			_pulse_cycle_state_set_blocker "$_mhf_blocker_kind" "$_mhf_blocker_fingerprint" || true
		fi
		rm -f "$_merge_health_file" || true
	fi

	# GitHub issue-state sync: reconcile local TODO.md refs and
	# closed/reopened issue state before constructing the dependency graph.
	# Without this, a closed blocker can leave stale TODO.md/cache state that
	# keeps child issues permanently dispatch-blocked.
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared — skipping GitHub issue-state sync" >>"$LOGFILE"
	else
		run_stage_with_timeout "sync_todo_refs_all_repos" "$PRE_RUN_STAGE_TIMEOUT" \
			sync_todo_refs_all_repos || true
	fi

	# Dependency graph cache (t1935): build once per cycle so that
	# is_blocked_by_unresolved() can resolve blocker state without API calls.
	# Runs before the dispatch so the cache is warm when dispatch checks run.
	# Force the post-sync build so closed/open issue changes are reflected in
	# the same pulse cycle rather than waiting for TTL expiry.
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared — skipping dependency graph cache build" >>"$LOGFILE"
	else
		PULSE_DEP_GRAPH_FORCE_REBUILD=1 run_stage_with_timeout "build_dependency_graph_cache" "$PRE_RUN_STAGE_TIMEOUT" \
			build_dependency_graph_cache || true
	fi

	# Blocked-status refresh (t1935): relabel status:blocked → status:available
	# for issues whose blockers are now closed. Uses the freshly built cache —
	# zero API calls for the resolution check, one API call per unblocked issue.
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared — skipping blocked-status refresh" >>"$LOGFILE"
	else
		run_stage_with_timeout "refresh_blocked_status_from_graph" "$PRE_RUN_STAGE_TIMEOUT" \
			refresh_blocked_status_from_graph || true
	fi

	# Dispatch_max runs EVERY cycle — before the LLM session,
	# not after. This ensures workers are dispatched every 2-min cycle
	# regardless of whether the LLM supervisor is running.
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared — skipping dispatch_max" >>"$LOGFILE"
	else
		# t2770: cross-issue no_work rate circuit breaker check.
		# Pauses dispatch when many different issues return no_work in a short
		# window — symptomatic of auth outage, GraphQL exhaustion, or wrapper
		# stall. Complementary to the per-issue no_work escalation (GH#20639).
		local _nw_rc=0
		is_no_work_rate_acceptable || _nw_rc=$?
		# t2897: per-runner zero-attempt circuit breaker check.
		# Pauses dispatch ONLY on this runner when N consecutive zero-attempt
		# worker dispatches signal a stale or broken local install. The
		# breaker auto-trips an `aidevops update`; if VERSION changed, the
		# t2579 restart hook refreshes code on the next cycle and the
		# breaker reopens on the first non-zero-attempt outcome.
		local _rh_rc=1
		local _rh_helper="${SCRIPT_DIR}/pulse-runner-health-helper.sh"
		if [[ -x "$_rh_helper" ]]; then
			"$_rh_helper" is-paused >/dev/null 2>&1 && _rh_rc=0 || _rh_rc=1
		fi
		if [[ "$_nw_rc" -eq 1 ]]; then
			echo "[pulse-wrapper] Dispatch_max skipped: no_work rate circuit breaker tripped (t2770)" >>"$LOGFILE"
			_pulse_cycle_state_note_blocker dispatch-no-work-rate pulse-wrapper no-work-rate || true
		elif [[ "$_rh_rc" -eq 0 ]]; then
			echo "[pulse-wrapper] Dispatch_max skipped: runner-health circuit breaker tripped (t2897)" >>"$LOGFILE"
			_pulse_cycle_state_note_blocker runner-health pulse-wrapper runner-health || true
			if declare -F pulse_stats_increment >/dev/null 2>&1; then
				pulse_stats_increment "pulse_dispatch_runner_health_breaker_tripped" 2>/dev/null || true
				pulse_stats_increment "dispatch_candidate_failed" 2>/dev/null || true
				pulse_stats_increment "dispatch_candidate_failed_reason_runner_health_circuit_breaker" 2>/dev/null || true
			fi
		else
			apply_dispatch_max
		fi
	fi

	# Routine evaluation (t1925): check repeat: fields in TODO.md routines
	# and dispatch due routines. Script-only (run:) routines execute directly
	# with zero LLM tokens. Agent routines dispatch via headless runtime.
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared — skipping routine evaluation" >>"$LOGFILE"
	else
		run_stage_with_timeout "evaluate_routines" "$PRE_RUN_STAGE_TIMEOUT" \
			evaluate_routines || true
	fi

	# Dependency-alert monitor: create grouped worker-ready issues for open
	# Dependabot alerts across managed pulse repos. The helper dedupes by
	# package/ecosystem/patched-version and uses neutral issue wording.
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared — skipping Dependabot alert monitor" >>"$LOGFILE"
	else
		_pulse_run_optional_stage_with_timeout "dependabot_alert_monitor" "$PRE_RUN_STAGE_TIMEOUT" \
			dependabot_alert_monitor_scan_repos || true
	fi

	# GH#19949: Canonical-repo fast-forward + stale worktree sweep.
	# Cadence-gated (~30 min) — the function's internal cadence check skips
	# if too soon. Runs after routine evaluation and before health snapshot
	# so the snapshot reflects the maintenance outcome.
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared — skipping canonical maintenance" >>"$LOGFILE"
	else
		run_stage_with_timeout "canonical_maintenance" "$PRE_RUN_STAGE_TIMEOUT" \
			run_canonical_maintenance || true
	fi

	# t2418 (GH#20016): Dashboard freshness watchdog. Detects when the
	# supervisor health dashboard issue has not been refreshed within the
	# threshold (default 48h) and files a `review-followup` + `priority:high`
	# alert. Cadence-gated internally (default 1h) so this is cheap to call
	# every cycle. Non-fatal — failures (gh offline, no dashboards cached)
	# log and return 0.
	#
	# Structure note: two single-arm `if`s (early-return pattern) rather than
	# `if ... elif ...` because the nesting-depth AWK counter in
	# code-quality.yml mis-counts `elif` as opening a new nesting level (the
	# loose regex `(if|for|while|until|case)` matches `if ` inside `elif `).
	local _dfc_script="${SCRIPT_DIR}/dashboard-freshness-check.sh"
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared — skipping dashboard freshness check" >>"$LOGFILE"
	fi
	if [[ ! -f "$STOP_FLAG" && -x "$_dfc_script" ]]; then
		run_stage_with_timeout "dashboard_freshness_check" "$PRE_RUN_STAGE_TIMEOUT" \
			bash "$_dfc_script" scan || true
	fi

	return 0
}

# ---------------------------------------------------------------------------
# _pulse_maybe_run_llm_supervisor
#
# Conditional LLM supervisor: the deterministic layer (merge pass, fill
# floor, stalled worker cleanup) handles the common case every cycle.
# The LLM supervisor adds value only for edge cases (CHANGES_REQUESTED
# PRs, external contributor triage, semantic dedup, stale coaching).
#
# Skip the LLM session unless:
#   1. Backlog is stalled (issue+PR count unchanged for PULSE_LLM_STALL_THRESHOLD)
#   2. Daily sweep is due (last LLM run was >24h ago)
#   3. PULSE_FORCE_LLM=1 is set (manual override)
#
# Trigger mode routing (GH#15287):
#   daily_sweep → /pulse-sweep (full edge-case triage, quality review, mission awareness)
#   stall / first_run → /pulse (lightweight dispatch+merge, unblocks the stall faster)
#
# Extracted from main() (GH#18689) to reduce function length.
# Exit code: always 0
# ---------------------------------------------------------------------------
# _pulse_maybe_run_llm_supervisor and _pulse_prime_caches_if_stale
# provided by pulse-wrapper-cycle.sh.
# _pulse_handle_self_check, _pulse_setup_dry_run_mode,
# _pulse_setup_canary_mode, _detect_invocation_source, and
# _record_invocation_source provided by pulse-wrapper-bootstrap.sh
# (GH#21311 / t2936-child).

main() {
	# GH#18670: declare this process as headless BEFORE anything else runs
	# so every child shell stage sees AIDEVOPS_HEADLESS and
	# detect_session_origin() returns "worker". Without this, shell stages
	# default to "interactive", label new issues with origin:interactive,
	# and trigger GH#18352's dedup guard (origin:interactive + maintainer
	# assignee → blocked), draining the queue indefinitely. Scoped to
	# main() so callers sourcing pulse-wrapper.sh for testing do not
	# inherit the env var.
	export AIDEVOPS_HEADLESS=true

	# t3033: capture script path and load-time mtime for post-cycle self-respawn.
	# If the source file changes during a cycle (e.g. aidevops update / setup.sh),
	# we exec at cycle end so the next iteration runs fresh code without waiting
	# for the next launchd tick. Captured here — before any cycle work — so the
	# comparison at cycle end detects changes made DURING the cycle, not changes
	# that were present before it started. Uses BSD stat (-f '%m') with GNU fallback
	# (-c '%Y'), consistent with the pre-jitter fast-fail stat calls at line ~151.
	local _pw_self="${BASH_SOURCE[0]:-$0}"
	local _pw_mtime_loaded
	_pw_mtime_loaded=$(_file_mtime_epoch "$_pw_self")

	# GH#18689: --self-check and --dry-run arg scanning extracted to helpers.
	# GH#18770: the `_sc_rc=$?` capture MUST be guarded by `|| _sc_rc=$?`
	# on the call itself — otherwise, under `set -euo pipefail` (line 42),
	# any non-zero return from _pulse_handle_self_check (which is the
	# normal path when --self-check is not requested: returns 2 as the
	# "not a self-check invocation" signal) kills the script at the call
	# site BEFORE `_sc_rc=$?` can capture it. The pulse then dies with
	# exit 2 on every launchd restart, never acquiring the instance lock,
	# never dispatching. Regressed in PR #18712 which extracted the
	# handler without reviewing the set -e exit-code propagation. Same
	# bug class as the aidevops.sh getent regression (GH#18784) and the
	# interactive-session-helper set -e kill (GH#18786). See the pre-merge
	# checklist item 4 in `.agents/reference/bash-compat.md`.
	local _sc_rc=0
	_pulse_handle_self_check "$@" || _sc_rc=$?
	[[ "$_sc_rc" -ne 2 ]] && return "$_sc_rc"
	_pulse_setup_dry_run_mode "$@"
	_pulse_setup_canary_mode "$@"

	# Event refill skips preflight/LLM but keeps the main lock and dispatch gates.
	_pulse_setup_refill_only_mode "$@"
	if [[ "${PULSE_REFILL_ONLY:-0}" == "1" ]]; then
		_pulse_run_refill_only
		return $?
	fi
	_pulse_setup_merge_only_mode "$@"
	if [[ "${PULSE_MERGE_ONLY:-0}" == "1" ]]; then
		_pulse_run_merge_only
		return $?
	fi

	# GH#20580: Detect and record invocation source before acquiring the lock
	# so every invocation — including those that fail the lock — is counted.
	local _invocation_source="unknown"
	_detect_invocation_source
	_record_invocation_source "$_invocation_source"

	# GH#20611: Is-running short-circuit — exit 0 immediately before attempting
	# mkdir lock acquisition when a pulse process is already alive. Eliminates
	# lock contention for the common launchd-fires-while-running case.
	#
	# Reads the PID file that acquire_instance_lock writes (LOCKDIR/pid) and
	# verifies liveness with `kill -0`. POSIX, identical on macOS and Linux.
	#
	# Replaces the GH#20579 pgrep+pipe approach which had a 100% false-positive
	# rate on Linux: bash's `$(pgrep | grep)` subshell transiently inherited
	# the parent script's argv, so `pgrep -f pulse-wrapper.sh` matched its own
	# subshell PIDs that `grep -v "^$$\$"` couldn't filter (different PIDs).
	# macOS doesn't expose argv this way for transient subshells, which is why
	# the bug was Linux-only and missed in PR #20584's testing. See GH#20611.
	#
	# Biased toward false negatives: missing PID file, malformed PID, or
	# apparently-dead owner all DEFER to acquire_instance_lock rather than try
	# to reclaim here. The lock has its own stale + PID-reuse handling
	# (_handle_existing_lock at pulse-instance-lock.sh). This short-circuit
	# is an optimization, not a replacement.
	#
	# Bypassed in --canary and --dry-run: those modes exercise the full path.
	if [[ "${PULSE_CANARY_MODE:-0}" != "1" && "${PULSE_DRY_RUN:-0}" != "1" ]]; then
		if [[ -f "${LOCKDIR}/pid" ]]; then
			local _ir_pid
			_ir_pid=$(cat "${LOCKDIR}/pid" 2>/dev/null || true)
			if [[ "$_ir_pid" =~ ^[0-9]+$ ]] && [[ "$_ir_pid" != "$$" ]] && kill -0 "$_ir_pid" 2>/dev/null; then
				# t2829: Age check — without this, a wedged-but-alive pulse (no log
				# progress, kill -0 returns true) bypasses _handle_existing_lock's
				# 30-min stale-lock reclaim entirely. The short-circuit was designed
				# to be biased toward false negatives (defer to acquire_instance_lock
				# when uncertain), but the alive-but-stale case was missed: kill -0
				# alone cannot distinguish a healthy mid-cycle pulse from one that
				# died-internally-but-the-bash-shell-is-still-alive. Real-world
				# wedge: PID held lock 80+min with no log activity, 100+ launchd
				# ticks all returned 0 here without ever attempting reclaim.
				# Fix: enforce PULSE_LOCK_MAX_AGE_S as a fall-through trigger so
				# stale-but-alive locks reach the proper reclaim path below.
				local _ir_age="" _ir_max=""
				_ir_age=$(_get_process_age "$_ir_pid" 2>/dev/null || true)
				_ir_max="${PULSE_LOCK_MAX_AGE_S:-1800}"
				if [[ "$_ir_age" =~ ^[0-9]+$ ]] && [[ "$_ir_age" -le "$_ir_max" ]]; then
					echo "[pulse-wrapper] Pulse already running (PID: ${_ir_pid}, age ${_ir_age}s), skipping" >>"$WRAPPER_LOGFILE"
					return 0
				fi
				echo "[pulse-wrapper] Lock holder PID ${_ir_pid} age ${_ir_age}s > ceiling ${_ir_max}s — deferring to acquire_instance_lock for reclaim (t2829)" >>"$WRAPPER_LOGFILE"
				# Fall through (no return) — acquire_instance_lock will detect the
				# stale lock via _handle_existing_lock and force-reclaim with kill.
			fi
		fi
	fi

	# GH#20578: Entry-point rate-limit cooldown. Short-circuit BEFORE the
	# mkdir instance lock to eliminate unnecessary lock contention from
	# redundant scheduler invocations (launchd ThrottleInterval edge cases,
	# manual restarts). A single stat-equivalent read is the entire cost of
	# a rate-limited invocation instead of mkdir attempt + stale-lock check
	# + PID file read. --canary and --dry-run bypass (diagnostic modes).
	#
	# t3018 (GH#21570) self-healing: the timestamp is written BEFORE the
	# cycle does any real work (line below). If the cycle then crashes
	# silently (mid-stage exit, set -e abort, source-gate regression like
	# GH#21557), the stamp persists but no live cycle exists — and every
	# launchd respawn for the next PULSE_MIN_INTERVAL_S seconds short-circuits
	# here ("Rate-limited: last run 30s ago"), masking the dead pulse as
	# "rate-limited" instead of "broken". Defense-in-depth: when the rate
	# limit fires, also peek at the instance lock. Stamp present + no live
	# lock holder = stale stamp from a crashed cycle. Clear it and proceed
	# rather than perpetuating the lockout. Steady-state behaviour (lock
	# held by a real running pulse) is unchanged. Pattern mirrors the
	# kill -0 lock check at lines ~1208-1234 above.
	if [[ "${PULSE_DRY_RUN:-0}" != "1" && "${PULSE_CANARY_MODE:-0}" != "1" ]]; then
		# t3027 (GH#21584): idle-backoff gate (helper has full docs).
		_pulse_check_idle_backoff_gate || return 0

		local _rl_ts_file="${HOME}/.aidevops/logs/pulse-wrapper-last-run.ts"
		local _rl_now
		local _rl_last
		local _rl_elapsed
		_rl_now=$(date +%s)
		_rl_last=0
		if [[ -f "$_rl_ts_file" ]]; then
			read -r _rl_last <"$_rl_ts_file" || _rl_last=0
			# Treat corrupt/non-numeric content as 0 (stale) — continue normally
			[[ "$_rl_last" =~ ^[0-9]+$ ]] || _rl_last=0
		fi
		_rl_elapsed=$((_rl_now - _rl_last))
		if ((_rl_elapsed < PULSE_MIN_INTERVAL_S)); then
			# t3018: peek at instance lock. No live holder = stale stamp.
			local _rl_lock_pid=""
			if [[ -f "${LOCKDIR}/pid" ]]; then
				read -r _rl_lock_pid <"${LOCKDIR}/pid" 2>/dev/null || _rl_lock_pid=""
			fi
			if [[ "$_rl_lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$_rl_lock_pid" 2>/dev/null; then
				echo "[pulse-wrapper] Rate-limited: last run ${_rl_elapsed}s ago < ${PULSE_MIN_INTERVAL_S}s threshold — skipping cycle (GH#20578)" >>"$WRAPPER_LOGFILE"
				return 0
			fi
			# Stale stamp recovery: no live lock holder. Clear stamp and
			# fall through to acquire the lock and run a real cycle.
			# Failsafe: any I/O error here defaults to "proceed", since the
			# cost of a false-proceed (occasional tighter cycle interval)
			# is far smaller than the cost of false-skip (the bug being fixed).
			echo "[pulse-wrapper] Rate-limit stamp ${_rl_elapsed}s old but no live lock holder (pid='${_rl_lock_pid:-<missing>}') — clearing stale stamp and proceeding (GH#21570 self-heal)" >>"$WRAPPER_LOGFILE"
			: >"$_rl_ts_file" 2>/dev/null || true
			_rl_elapsed=$((_rl_now - 0))
		fi
		printf '%s\n' "$_rl_now" >"$_rl_ts_file" || true
	fi

	# GH#4513: Acquire exclusive instance lock FIRST — before any other
	# check. Uses mkdir atomicity as the ONLY primitive (POSIX-guaranteed,
	# works identically on macOS APFS/HFS+ and Linux ext4/btrfs/xfs).
	#
	# flock was removed in GH#18668 after recurring FD 9 inheritance
	# deadlocks. bash has no built-in fcntl(F_SETFD, FD_CLOEXEC), so any
	# persistent FD held by the parent is inherited by every daemonising
	# descendant (git hooks, ancillary workers). See the module header of
	# pulse-instance-lock.sh and reference/bash-fd-locking.md for history.
	#
	# Register EXIT trap BEFORE acquiring the lock so the lock is always
	# released on exit — including set -e aborts, SIGTERM, and return paths.
	# SIGKILL cannot be trapped; stale-lock detection handles that case.
	trap '_dispatch_cleanup_benign_blocks_cycle; _dispatch_cleanup_cycle_cache; _pulse_release_llm_lock; _pulse_cycle_state_finish_interrupted; _pulse_efficiency_cycle_finish; release_instance_lock; aidevops_runtime_bundle_lease_release' EXIT

	if ! acquire_instance_lock; then
		return 0
	fi
	_dispatch_cleanup_stale_benign_blocks || true

	# GH#22525: enable REST-first read routing before any post-lock pulse gate
	# runs. GH#22507 originally flipped this after session/dedup gates, leaving
	# early-cycle issue/pr list/view reads on GraphQL and visible as top pressure
	# callers in pulse-current-state-helper. The env var is inherited by raw gh
	# shim invocations and sourced gh_* wrappers; semantic-safety checks still
	# keep GraphQL-only fields on GraphQL.
	unset AIDEVOPS_GH_REST_FIRST_READS
	if [[ "${AIDEVOPS_PULSE_REST_FIRST_READS:-1}" == "1" ]]; then
		export AIDEVOPS_GH_REST_FIRST_READS=1
		echo "[pulse-wrapper] REST-first read routing enabled for REST-equivalent gh issue/pr list/view calls (GH#22525)" >>"$LOGFILE"
	fi

	# GH#23433/GH#23604/GH#26241: reuse PR metadata within and across pulse
	# cycles. The wrapper caches are opt-in so standalone tests/debugging keep
	# exact read semantics, but pulse can avoid re-fetching the same PR list/view
	# data across gates. PR view caches use TTL-based freshness and a stable cache
	# directory so repeated daemon restarts do not create cold PID-scoped caches.
	local _pulse_pr_cache_cleanup_scope=0
	local _pulse_rm_rf="rm -rf"
	unset AIDEVOPS_GH_PR_VIEW_CACHE
	unset AIDEVOPS_GH_PR_VIEW_CACHE_DIR
	unset AIDEVOPS_GH_PR_VIEW_CACHE_TTL
	unset AIDEVOPS_GH_PR_LIST_CACHE_DIR
	unset AIDEVOPS_GH_PR_LIST_CACHE_TTL
	unset PULSE_PR_LIST_PROVIDER_CACHE_DISABLE
	unset PULSE_PR_LIST_PROVIDER_CACHE_DIR
	unset PULSE_PR_LIST_PROVIDER_CACHE_TTL
	if [[ "${AIDEVOPS_PULSE_PR_VIEW_CACHE:-1}" == "1" ]]; then
		export AIDEVOPS_GH_PR_VIEW_CACHE=1
		export AIDEVOPS_GH_PR_VIEW_CACHE_DIR="${AIDEVOPS_PULSE_PR_VIEW_CACHE_DIR:-${HOME}/.aidevops/cache/pulse-pr-view-cache}"
		export AIDEVOPS_GH_PR_VIEW_CACHE_TTL="${AIDEVOPS_PULSE_PR_VIEW_CACHE_TTL:-3600}"
		_save_cleanup_scope
		# Register process-lifetime resources first so LIFO cleanup removes
		# per-cycle caches, records the cycle, releases the lock, then drops the
		# runtime bundle lease last.
		push_cleanup 'aidevops_runtime_bundle_lease_release'
		push_cleanup 'release_instance_lock'
		push_cleanup '_pulse_efficiency_cycle_finish'
		push_cleanup '_pulse_cycle_state_finish_interrupted'
		push_cleanup '_pulse_release_llm_lock'
		push_cleanup '_dispatch_cleanup_benign_blocks_cycle'
		# GH#23728: keep EXIT (not RETURN) for SIGTERM/set -e lock safety, but
		# register release_instance_lock before replacing the direct EXIT trap.
		trap '_run_cleanups' EXIT
		_pulse_pr_cache_cleanup_scope=1
		if ! mkdir -p "$AIDEVOPS_GH_PR_VIEW_CACHE_DIR"; then
			printf '[pulse-wrapper] Failed to create REST PR view cache directory: %s\n' "$AIDEVOPS_GH_PR_VIEW_CACHE_DIR" >&2
		fi
		echo "[pulse-wrapper] Persistent PR view cache enabled for duplicate repo#PR reads dir=${AIDEVOPS_GH_PR_VIEW_CACHE_DIR} ttl=${AIDEVOPS_GH_PR_VIEW_CACHE_TTL}s (GH#23433/GH#23604/GH#26241)" >>"$LOGFILE"
	fi

	if [[ "${AIDEVOPS_PULSE_PR_LIST_CACHE:-1}" == "1" ]]; then
		export AIDEVOPS_GH_PR_LIST_CACHE_DIR="${TMPDIR:-/tmp}/aidevops-pulse-pr-list-cache-${$}"
		export AIDEVOPS_GH_PR_LIST_CACHE_TTL="${AIDEVOPS_PULSE_PR_LIST_CACHE_TTL:-3600}"
		export PULSE_PR_LIST_PROVIDER_CACHE_DIR="${TMPDIR:-/tmp}/aidevops-pulse-pr-list-provider-cache-${$}"
		export PULSE_PR_LIST_PROVIDER_CACHE_TTL="${AIDEVOPS_PULSE_PR_LIST_CACHE_TTL:-3600}"
		if [[ "$_pulse_pr_cache_cleanup_scope" -eq 0 ]]; then
			_save_cleanup_scope
			push_cleanup 'aidevops_runtime_bundle_lease_release'
			push_cleanup 'release_instance_lock'
			push_cleanup '_pulse_efficiency_cycle_finish'
			push_cleanup '_pulse_cycle_state_finish_interrupted'
			push_cleanup '_pulse_release_llm_lock'
			push_cleanup '_dispatch_cleanup_benign_blocks_cycle'
			# GH#23728: keep EXIT (not RETURN) for SIGTERM/set -e lock safety, but
			# register release_instance_lock before replacing the direct EXIT trap.
			trap '_run_cleanups' EXIT
			_pulse_pr_cache_cleanup_scope=1
		fi
		push_cleanup "${_pulse_rm_rf} \"${AIDEVOPS_GH_PR_LIST_CACHE_DIR}\""
		push_cleanup "${_pulse_rm_rf} \"${PULSE_PR_LIST_PROVIDER_CACHE_DIR}\""
		if ! rm -rf "$AIDEVOPS_GH_PR_LIST_CACHE_DIR"; then
			printf '[pulse-wrapper] Failed to reset PR list cache directory: %s\n' "$AIDEVOPS_GH_PR_LIST_CACHE_DIR" >&2
		fi
		if ! mkdir -p "$AIDEVOPS_GH_PR_LIST_CACHE_DIR"; then
			printf '[pulse-wrapper] Failed to create PR list cache directory: %s\n' "$AIDEVOPS_GH_PR_LIST_CACHE_DIR" >&2
		fi
		if ! rm -rf "$PULSE_PR_LIST_PROVIDER_CACHE_DIR"; then
			printf '[pulse-wrapper] Failed to reset PR list provider cache directory: %s\n' "$PULSE_PR_LIST_PROVIDER_CACHE_DIR" >&2
		fi
		if ! mkdir -p "$PULSE_PR_LIST_PROVIDER_CACHE_DIR"; then
			printf '[pulse-wrapper] Failed to create PR list provider cache directory: %s\n' "$PULSE_PR_LIST_PROVIDER_CACHE_DIR" >&2
		fi
		echo "[pulse-wrapper] Per-cycle PR list cache enabled for duplicate repo open-PR reads ttl=${AIDEVOPS_GH_PR_LIST_CACHE_TTL}s; provider exact-output cache enabled for GraphQL-only PR lists (GH#23604)" >>"$LOGFILE"
	else
		export PULSE_PR_LIST_PROVIDER_CACHE_DISABLE=1
	fi

	# --canary short-circuit (GH#18790): sourcing, _pulse_handle_self_check,
	# and acquire_instance_lock have all passed cleanly. The EXIT trap releases
	# the lock. Return 0 without entering the pulse loop, session gate, dedup,
	# log rotation, or any side-effecting stage.
	if [[ "${PULSE_CANARY_MODE:-0}" == "1" ]]; then
		printf 'canary: ok (sourcing + _pulse_handle_self_check + acquire_instance_lock passed)\n'
		return 0
	fi
	if [[ "${PULSE_DRY_RUN:-0}" != "1" ]]; then
		_pulse_cycle_state_start
		write_pulse_health_file || true
	fi

	# GH#22631: `circuit-breaker-helper.sh status` can report an overdue
	# supervisor breaker until `check` is invoked. Refresh once per real pulse
	# cycle so expired cooldowns auto-close without manual operator action.
	_pulse_refresh_supervisor_circuit_breaker || true

	if ! check_session_gate; then
		_pulse_cycle_state_note_blocker session-gate pulse-wrapper session-gate || true
		_pulse_cycle_state_finish_if_needed blocked
		return 0
	fi

	if ! check_dedup; then
		_pulse_cycle_state_note_blocker dedup pulse-wrapper dedup || true
		_pulse_cycle_state_finish_if_needed blocked
		return 0
	fi

	# GH#22479: classify budget for priority scheduling instead of skipping the
	# whole cycle. Merge/dispatch/safety stages keep first claim; optional stages
	# defer in reserve mode. The t2690 dispatch breaker still fail-closes actual
	# worker launch at the emergency floor.
	_pulse_set_graphql_budget_priority
	local _cycle_dispatch_before
	_cycle_dispatch_before=$(_pulse_capture_dispatch_total)
	if [[ "${PULSE_DRY_RUN:-0}" != "1" ]]; then
		pulse_event_refill_drain "cycle-entry" || true
	fi

	# GH#22478: if GraphQL headroom is already inside the REST fallback reserve,
	# force all supported read/list wrappers through REST for the whole pulse
	# cycle. This remains as a stronger low-budget fallback for paths not covered
	# by REST-first semantic-safety checks.
	unset AIDEVOPS_GH_FORCE_REST_READS
	if [[ "${AIDEVOPS_PULSE_FORCE_REST_READS_ON_LOW_GRAPHQL:-1}" == "1" ]] && declare -F _cb_rate_limit_json >/dev/null 2>&1; then
		local _gh22478_rate_json="" _gh22478_remaining="" _gh22478_threshold="${AIDEVOPS_GH_REST_FALLBACK_THRESHOLD:-3000}"
		_gh22478_rate_json=$(_cb_rate_limit_json normal 2>/dev/null) || _gh22478_rate_json=""
		if [[ -n "$_gh22478_rate_json" ]]; then
			_gh22478_remaining=$(printf '%s' "$_gh22478_rate_json" | jq -r '.resources.graphql.remaining // ""' 2>/dev/null) || _gh22478_remaining=""
			if [[ "$_gh22478_remaining" =~ ^[0-9]+$ && "$_gh22478_threshold" =~ ^[0-9]+$ && "$_gh22478_remaining" -le "$_gh22478_threshold" ]]; then
				export AIDEVOPS_GH_FORCE_REST_READS=1
				echo "[pulse-wrapper] GraphQL remaining ${_gh22478_remaining} <= REST fallback threshold ${_gh22478_threshold}; forcing REST-backed read/list wrappers for this cycle (GH#22478)" >>"$LOGFILE"
				if declare -F pulse_stats_increment >/dev/null 2>&1; then
					pulse_stats_increment "pulse_graphql_low_force_rest_reads" 2>/dev/null || true
				fi
			fi
		fi
	fi

	# t2994: pre-warm L3 caches when sentinel is stale. Runs after lock,
	# canary, session, and dedup gates have all passed (so a real cycle is
	# about to run) and BEFORE prefetch_state inside the cycle. Steady-state
	# launchd respawns skip via the staleness gate; first-cycle-after-deploy
	# (or after a long quiet period) primes once. See helper comment for
	# the launchd-bypass rationale.
	_pulse_run_optional_stage "cache_prime" _pulse_prime_caches_if_stale || true

	# GH#21756: Runaway-log self-healing detector. Catches pulse-wrapper.log
	# growing at MB/s from tight error loops (the GH#21729 failure mode).
	# Sentinel-gated (every 5 min) — modelled on cache-prime pattern (t2994).
	# Fail-open: never blocks the pulse cycle.
	_pulse_check_runaway_log || true

	# Recover dependency close events missed by async merge/issue-close races.
	# Sentinel-gated to bound API use; the reconciler itself fails closed.
	_pulse_reconcile_stale_blocked_if_due || true

	# t3077: LLM-driven fix-the-fixer detector. Classifies new auto-dispatch
	# issues — when the work itself touches the worker dispatch system,
	# applies the `fix-the-fixer` label so the dispatcher can enable extra
	# observability (verbose lifecycle, tighter watchdog, preflight sentinel)
	# and avoid the canonical broken-dispatch-can-not-fix-itself trap.
	# Sentinel-gated hourly. Fail-open: never blocks the pulse cycle.
	_pulse_run_optional_stage "fix_the_fixer_detector" _pulse_run_fix_the_fixer_detector_if_stale || true

	# Rotate hot log to cold archive if over cap (t1886)
	# Run before any log writes so the new cycle starts with a fresh hot log.
	rotate_pulse_log || true

	# Record cycle start for append_cycle_index duration tracking (t1886)
	local _cycle_start_epoch
	_cycle_start_epoch=$(date +%s)

	# t2749: Defence-in-depth — clean up any stale Phase 2 consolidation
	# sentinels from a previous cycle before preflight stages run. With
	# PID-scoped naming (pulse-cycle-$$-consolidation-fired) a different
	# PID produces a different filename, so stale files from a crash can
	# only exist when the OS reuses the same PID. This glob sweep is the
	# safety net for that rare case. Runs after lock acquisition so only
	# one process sweeps at a time.
	# shellcheck disable=SC2086,SC2015
	rm -f "${HOME}/.aidevops/cache/pulse-cycle-"*"-consolidation-fired" 2>/dev/null || true

	# Phase 0 (t1963): --dry-run short-circuits here. Bootstrap, sourcing,
	# config validation, lock acquisition, session gate, dedup guard, and
	# log rotation have all run cleanly by this point — that is the Phase 0
	# scope of the dry-run smoke test. Pre-flight stages below are skipped
	# because they start touching worktrees, GitHub state, and process
	# spawning. Later phases may shim those sites individually.
	if [[ "${PULSE_DRY_RUN:-0}" == "1" ]]; then
		printf 'dry-run: ok (bootstrap + sourcing + lock + session-gate + dedup + log-rotate exercised; pre-flight stages and beyond skipped)\n'
		return 0
	fi

	# GH#27777: bracket every real pulse cycle with typed production evidence.
	# The fail-open finish hook is also registered in the EXIT cleanup path so
	# unexpected set -e exits publish a conservative partial cycle rather than
	# silently dropping the observation window.
	_pulse_efficiency_cycle_start
	_pulse_cycle_state_publish preflight || true

	# t3068: drain any pending approval-trigger records before the regular
	# cycle. Backstop for the dedicated 60s --merge-only plist; if an
	# approval landed since the last merge-only tick, we pick it up here
	# rather than waiting for the next 60s cycle. Best-effort — never aborts
	# the cycle. See pulse-wrapper-bootstrap.sh::_drain_merge_trigger_file_if_present.
	_drain_merge_trigger_file_if_present || true

	# Run pre-flight stages (cleanup, prefetch, normalization)
	if ! _run_preflight_stages; then
		_pulse_cycle_state_note_blocker preflight-failed pulse-wrapper preflight || true
		_pulse_record_cycle_outcome "$_cycle_dispatch_before"
		_pulse_cycle_state_write_terminal_if_current || true
		_pulse_efficiency_cycle_finish idle
		return 0
	fi

	# Re-check stop flag immediately before run_pulse() — a stop may have
	# been issued during the prefetch/cleanup phase above (t2943)
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag appeared during setup — aborting before run_pulse()" >>"$LOGFILE"
		_pulse_cycle_state_note_blocker stop-requested pulse-wrapper stop-flag || true
		_pulse_record_cycle_outcome "$_cycle_dispatch_before"
		_pulse_cycle_state_write_terminal_if_current || true
		_pulse_efficiency_cycle_finish idle
		return 0
	fi

	# Run deterministic pipeline: merge pass, dep graph, blocked-status refresh,
	# fill floor and routine evaluation. GH#18689:
	# extracted to helper.
	_pulse_cycle_state_publish deterministic || true
	_pulse_run_deterministic_pipeline
	pulse_event_refill_drain "cycle-final" || true

	# Run LLM supervisor if stall/daily-sweep/force conditions are met.
	# GH#18689: extracted to _pulse_maybe_run_llm_supervisor().
	_pulse_cycle_state_publish supervising || true
	local _cycle_index_epoch
	_cycle_index_epoch=$(date +%s)
	local _cycle_index_duration=$((_cycle_index_epoch - _cycle_start_epoch))
	append_cycle_index "$_cycle_index_duration" || true
	# Release the instance lock BEFORE the LLM session so the next 2-min cycle
	# can run deterministic ops concurrently. Terminal publication briefly
	# reacquires this lock and writes only when health still names this cycle,
	# preventing a slow supervisor from overwriting a newer cycle (GH#28361).
	release_instance_lock
	_pulse_run_optional_stage "llm_supervisor" _pulse_maybe_run_llm_supervisor || true

	# GH#28361: compute one terminal typed outcome after both deterministic and
	# LLM dispatch paths, then project it through health and idle-backoff
	# contracts. A cumulative registration count detects launches even when a
	# different worker completes during the same cycle.
	_pulse_record_cycle_outcome "$_cycle_dispatch_before"
	_pulse_cycle_state_write_terminal_if_current || true

	# t3033: self-respawn when source file was modified during this cycle.
	#
	# If aidevops update / setup.sh deployed a new pulse-wrapper.sh while this
	# cycle was running, exec ourselves at the end of the cycle so the NEXT
	# cycle runs fresh code immediately — without waiting for the next launchd
	# tick (up to 180s later). exec preserves PID and launchd attachment so
	# KeepAlive sees no process exit.
	#
	# Lock protocol: we release the instance lock BEFORE exec so the re-exec'd
	# process can acquire it cleanly. exec does NOT trigger EXIT traps (bash
	# replaces the process image), so both the instance lock and runtime bundle
	# lease must be released explicitly here. The rate-limit t3018 self-heal
	# handles the resulting state: no live lock holder → stale stamp cleared →
	# proceeds normally.
	#
	# In-flight workers: workers are detached via setsid (_dlw_exec_detached)
	# and survive parent re-exec regardless. No in-flight dispatch is interrupted.
	#
	# Opt-out: AIDEVOPS_SKIP_SOURCE_REEXEC=1 (debugging / testing).
	if [[ "${AIDEVOPS_SKIP_SOURCE_REEXEC:-0}" != "1" ]]; then
		local _pw_mtime_now
		_pw_mtime_now=$(_file_mtime_epoch "$_pw_self")
		if [[ "$_pw_mtime_now" =~ ^[0-9]+$ ]] &&
			[[ "$_pw_mtime_loaded" =~ ^[0-9]+$ ]] &&
			[[ "$_pw_mtime_now" -gt 0 ]] &&
			[[ "$_pw_mtime_now" != "$_pw_mtime_loaded" ]]; then
			echo "[pulse-wrapper] t3033: source modified (${_pw_mtime_loaded} -> ${_pw_mtime_now}) — releasing lock and re-execing for fresh code" >>"$WRAPPER_LOGFILE"
			_pulse_efficiency_cycle_finish
			release_instance_lock
			aidevops_runtime_bundle_lease_release
			exec "$_pw_self" "$@"
			# exec should not return; if it does, log and fall through to normal exit
			echo "[pulse-wrapper] t3033: exec failed for '${_pw_self}' — continuing with normal exit" >>"$WRAPPER_LOGFILE"
		fi
	fi

	_pulse_efficiency_cycle_finish
	return 0
}

#######################################
# Kill orphaned opencode processes
#
# Criteria (ALL must be true):
#   - No TTY (headless — not a user's terminal tab)
#   - Not a current worker (/full-loop or /review-issue-pr not in command)
#   - Not the supervisor pulse (Supervisor Pulse not in command)
#   - Not a strategic review (Strategic Review not in command)
#   - Older than ORPHAN_MAX_AGE seconds
#
# These are completed headless sessions where opencode entered idle
# state with a file watcher and never exited.
#######################################

#######################################
# Kill workers stalled on rate-limited providers.
#
# When a provider hits its rate limit, already-running workers don't exit —
# they hang indefinitely waiting for the API to respond. The retry/rotation
# logic in headless-runtime-helper.sh only runs AFTER the process exits,
# creating a deadlock: worker waits for API → API is rate-limited → worker
# never exits → rotation never fires → slot wasted permanently.
#
# Observed in production: 20 of 24 worker slots consumed by stalled openai
# workers with 306 bytes of output (just the sandbox startup line, zero LLM
# activity) for 20-30 minutes. 0% CPU, 0 commits, 0 PRs.
#
# Detection: a worker running >STALLED_WORKER_MIN_AGE seconds with a log
# file ≤STALLED_WORKER_MAX_LOG_BYTES is stalled. The log file only contains
# the sandbox startup line when the LLM never responded.
#
# Action: kill the stalled worker, record provider backoff so the next
# dispatch rotates to a working provider, and log the kill for audit.
#######################################
STALLED_WORKER_MIN_AGE="${STALLED_WORKER_MIN_AGE:-300}"             # 5 minutes
STALLED_WORKER_MAX_LOG_BYTES="${STALLED_WORKER_MAX_LOG_BYTES:-500}" # just the startup line

#######################################
# Kill stale opencode processes (TTY-attached)
#
# cleanup_orphans only handles headless (no-TTY) processes. Workers
# dispatched via terminal tabs retain a TTY, so they survive the orphan
# reaper. When OpenCode completes a task it enters an idle file-watcher
# state (0% CPU) and never exits — consuming memory and TTY slots.
#
# Criteria (ALL must be true):
#   - Is a .opencode binary process
#   - Launched as a headless worker (command contains --format json)
#   - Older than STALE_OPENCODE_MAX_AGE seconds (default: 4 hours)
#   - CPU usage below PULSE_IDLE_CPU_THRESHOLD (default: 5%)
#   - Not the current interactive session (skip our own PID tree)
#
# Interactive sessions (no --format json) are NEVER killed — they may be
# idle because the user stepped away, not because the task completed.
#
# Also kills the parent node launcher and grandparent zsh for each
# stale .opencode process to fully reclaim the terminal tab.
#######################################
STALE_OPENCODE_MAX_AGE="${STALE_OPENCODE_MAX_AGE:-28800}" # 8 hours — was 4h, increased to avoid killing long-running complex tasks

#######################################
# Enrich failed issues with thinking-tier analysis before re-dispatch.
#
# When a worker fails (premature_exit, idle kill), the issue body often
# lacks the implementation context needed for success. This function
# spawns an inline thinking-tier worker to analyze the codebase and append
# a "## Worker Guidance" section with concrete file paths, patterns,
# and verification commands.
#
# Triggered by: fast_fail_record sets enrichment_needed=true on the
# first non-rate-limit failure. Runs at most once per issue.
#
# Arguments:
#   $1 - available worker slots
# Outputs: updated available count to stdout
# Exit code: always 0
#######################################
ENRICHMENT_MAX_PER_CYCLE="${ENRICHMENT_MAX_PER_CYCLE:-2}"

#######################################
# Dispatch FOSS contribution workers when idle capacity exists (t1702)
#
# Reads the pre-fetched FOSS scan from STATE_FILE and dispatches workers
# for eligible repos. Respects the FOSS_MAX_DISPATCH_PER_CYCLE cap and
# available worker slots.
#
# Arguments:
#   $1 - available worker slots (AVAILABLE)
#   $2 - repos JSON path (default: REPOS_JSON)
#
# Outputs: updated available count to stdout (one integer)
# Exit code: always 0
#######################################

#######################################
# Sync GitHub issue refs to TODO.md and close completed issues for a repo
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - repo path (canonical path on disk)
#
# Exit code: always 0
#######################################
# sync_todo_refs_for_repo and _pulse_is_sourced provided by
# pulse-wrapper-cycle.sh (GH#21311 / t2936-child).

# Only run main when executed directly, not when sourced.
# The pulse agent sources this file to access helper functions
# (check_external_contributor_pr, check_permission_failure_pr)
# without triggering the full pulse lifecycle.
#
# t3014/t3016 (GH#21551, GH#21557): The source check MUST be evaluated
# inline at top-level here — not delegated to _pulse_is_sourced() in
# pulse-wrapper-cycle.sh. Inside that function, ${BASH_SOURCE[0]} resolves
# to the function's *defining* file (pulse-wrapper-cycle.sh), not the
# entry script. PR #21553 moved the function into the sourced library and
# silently broke the gate: the comparison `BASH_SOURCE[0] != $0` always
# evaluated TRUE (cycle.sh != pulse-wrapper.sh), main() never ran, and
# `pulse-wrapper.sh --canary` returned exit 0 with no output. Production
# survived only because the deployed copy predated the merge — the next
# `aidevops update` would have bricked the pulse loop. Fix: do the check
# at file-scope here, where ${BASH_SOURCE[0]} correctly references this
# very file. Keep _pulse_is_sourced() in cycle.sh for callers that need a
# function-shaped helper.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
	main "$@"
fi
