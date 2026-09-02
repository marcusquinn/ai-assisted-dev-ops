#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Lifecycle Helper (t2579) — canonical start/stop/restart management
# =============================================================================
# The pulse is a long-running bash process that sources framework scripts at
# startup. Deploying updated scripts to ~/.aidevops/agents/scripts/ does NOT
# affect a running pulse — it keeps using the old code in memory. This helper
# is the single source of truth for pulse lifecycle operations.
#
# Subcommands:
#   is-running              Exit 0 if any pulse PID alive, 1 otherwise.
#   status                  Print pulse PIDs + uptime (informational).
#   start                   Start pulse in background (no-op if already running).
#   stop                    Stop all pulse instances (SIGTERM, then SIGKILL).
#   restart                 Force stop + start.
#   restart-if-running      No-op if pulse not running, otherwise stop + start.
#                           Used by setup.sh and aidevops update.
#   reconcile-managed       Serialize with runtime activation, stop stale Pulse
#                           instances, and start only when its supervisor is enabled.
#
# Env:
#   AIDEVOPS_SKIP_PULSE_RESTART=1     Skip restart operations (for debug).
#   AIDEVOPS_PULSE_RESTART_WAIT=3     Seconds between stop and start (default 3).
#   AIDEVOPS_PULSE_SIGTERM_WAIT=2     Seconds before escalating to SIGKILL.
#   AIDEVOPS_PULSE_EXPECTED_MAX_INSTANCES=3
#                                     status: warn only when MAIN pulse PID
#                                     count exceeds this threshold (default 3 —
#                                     see t2774 lock-release window). Sidecars
#                                     (--merge-only / --self-check / --dry-run /
#                                     --canary, GH#21903) are excluded from the
#                                     count and reported separately. Set to 1
#                                     for legacy strict-singleton check.
#   AIDEVOPS_PULSE_MANAGED_ENABLED=true
#                                     reconcile-managed may start Pulse.
#   AIDEVOPS_ACTIVE_AGENTS_LINK=<path>
#                                     activation link to resolve under the
#                                     shared runtime transition lock.
#   AIDEVOPS_PULSE_MERGE_PROCESS_PATTERN=<regex>
#                                     test override for stale merge routines.
#
# Exit codes:
#   0  Success (includes no-op cases)
#   1  Pulse not running (is-running only)
#   2  Invalid subcommand or missing pulse-wrapper.sh
#   3  status: pulse-wrapper instance pile-up detected (GH#21433/GH#21903)
#      — count exceeds AIDEVOPS_PULSE_EXPECTED_MAX_INSTANCES (default 3)
#
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

# Paths
_PULSE_AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-${HOME}/.aidevops/agents}"
_PULSE_ACTIVE_AGENTS_LINK="${AIDEVOPS_ACTIVE_AGENTS_LINK:-${HOME}/.aidevops/agents}"
_PULSE_BOOTSTRAP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
_PULSE_RUNTIME_PIN_HELPER="${_PULSE_BOOTSTRAP_SCRIPT_DIR}/pulse-runtime-pin.sh"
if [[ -r "$_PULSE_RUNTIME_PIN_HELPER" ]]; then
	# shellcheck source=./pulse-runtime-pin.sh
	source "$_PULSE_RUNTIME_PIN_HELPER"
	if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
		pulse_runtime_pin_reexec "${_PULSE_BOOTSTRAP_SCRIPT_DIR%/scripts}" "scripts/pulse-lifecycle-helper.sh" "$@" || {
			_PULSE_PIN_RC=$?
			exit "$_PULSE_PIN_RC"
		}
	fi
	_PULSE_PIN_RC=0
	if _PULSE_PINNED_ROOT=$(pulse_runtime_pin_resolve 2>/dev/null); then
		_PULSE_AGENTS_DIR="$_PULSE_PINNED_ROOT"
		_PULSE_ACTIVE_AGENTS_LINK="$_PULSE_PINNED_ROOT"
	else
		_PULSE_PIN_RC=$?
		case "$_PULSE_PIN_RC" in
		1 | 3) ;;
		*)
			printf '[pulse-lifecycle] FATAL: Pulse runtime pin is invalid\n' >&2
			return 2 2>/dev/null || exit 2
			;;
		esac
	fi
fi
unset _PULSE_BOOTSTRAP_SCRIPT_DIR _PULSE_RUNTIME_PIN_HELPER _PULSE_PINNED_ROOT _PULSE_PIN_RC
_PULSE_SCRIPT="${_PULSE_AGENTS_DIR}/scripts/pulse-wrapper.sh"
_PULSE_LOG="${HOME}/.aidevops/logs/pulse-wrapper.log"

# Process-match pattern for pgrep. The production default matches any
# pulse-wrapper.sh script regardless of path. Tests may override this to
# isolate mock pulses from the live user pulse (the mock's path is embedded
# in the pattern). See tests/test-pulse-lifecycle-helper.sh.
_PULSE_PATTERN="${AIDEVOPS_PULSE_PROCESS_PATTERN:-(^|/)pulse-wrapper\\.sh( |\$)}"
_PULSE_MERGE_PATTERN="${AIDEVOPS_PULSE_MERGE_PROCESS_PATTERN:-(^|/)pulse-merge-routine\\.sh( |\$)}"

# Timing
_PULSE_RESTART_WAIT="${AIDEVOPS_PULSE_RESTART_WAIT:-3}"
_PULSE_SIGTERM_WAIT="${AIDEVOPS_PULSE_SIGTERM_WAIT:-2}"
# launchd may accept kickstart before scheduler load permits the process to run.
# Keep this proof window bounded while tolerating starts beyond the former 5s.
_PULSE_LAUNCHD_START_WAIT=15

# Expected-max coexistence threshold (GH#21903).
#
# After the t2774 design change, pulse-wrapper.sh releases the instance lock
# BEFORE the LLM session (pulse-wrapper.sh::_pulse_run_deterministic_pipeline
# at line ~1337) so the next launchd cycle can run deterministic ops while
# the previous wrapper is still in its LLM phase. Multiple alive
# pulse-wrapper.sh processes are therefore EXPECTED in steady state — not
# a singleton-invariant violation. Typical counts:
#   1 — single cycle, no LLM-phase overlap
#   2 — cycle N's LLM phase + cycle N+1's deterministic phase (most common)
#   3 — cycle N + N+1 both in LLM phase + cycle N+2 just acquired the lock
#       (rare; happens when an LLM phase exceeds 2 launchd cycles ~360s)
#
# A pile-up beyond this threshold indicates a real problem: launchd
# respawn outpacing cycle completion, hung LLM phases failing to exit, or
# the t3002 lock race regressing. _status warns at counts > the threshold.
#
# Override: AIDEVOPS_PULSE_EXPECTED_MAX_INSTANCES=<integer>. Setting to 1
# restores the legacy strict-singleton check (warn on any coexistence) —
# only useful for environments where the t2774 lock-release window has
# been disabled (PULSE_LLM_DISABLED=1 etc.).
_PULSE_EXPECTED_MAX_INSTANCES="${AIDEVOPS_PULSE_EXPECTED_MAX_INSTANCES:-3}"
[[ "$_PULSE_EXPECTED_MAX_INSTANCES" =~ ^[0-9]+$ ]] || _PULSE_EXPECTED_MAX_INSTANCES=3
_PULSE_EXPECTED_MAX_INSTANCES=$((10#$_PULSE_EXPECTED_MAX_INSTANCES))
[[ "$_PULSE_EXPECTED_MAX_INSTANCES" -ge 1 ]] || _PULSE_EXPECTED_MAX_INSTANCES=1

# Sidecar pulse roles (GH#21903 follow-up). pulse-wrapper.sh runs in two distinct
# modes:
#   MAIN: full deterministic + LLM cycle (bare invocation, no role flag)
#   SIDECAR: short-lived deterministic-only roles dispatched by separate
#     launchd plists. They short-circuit BEFORE acquire_instance_lock and
#     never enter the LLM phase. Recognised flags:
#       --merge-only  PR auto-merge sidecar (GH#21247 plist, every 60s)
#       --self-check  pulse health probe / canary
#       --dry-run     preview cycle without side effects
#       --canary      pre-dispatch validator
#
# Sidecars MUST NOT count toward the main-pulse PILE-UP threshold above —
# a single 60s --merge-only sidecar would otherwise permanently consume one
# of the three threshold slots, leaving only two main pulses for the
# legitimate t2774 overlap window. _pulse_pids filters them out; status
# reports them informationally on a separate line.
_PULSE_SIDECAR_FLAGS_RE='(--merge-only|--self-check|--dry-run|--canary)'

# ANSI colors (guarded — don't collide with shared-constants)
[[ -z "${_PL_GREEN+x}" ]] && _PL_GREEN='\033[0;32m'
[[ -z "${_PL_BLUE+x}" ]] && _PL_BLUE='\033[0;34m'
[[ -z "${_PL_YELLOW+x}" ]] && _PL_YELLOW='\033[1;33m'
[[ -z "${_PL_RED+x}" ]] && _PL_RED='\033[0;31m'
[[ -z "${_PL_NC+x}" ]] && _PL_NC='\033[0m'

_pl_info() {
	local _msg="$1"
	printf '%b[INFO]%b %s\n' "$_PL_BLUE" "$_PL_NC" "$_msg"
	return 0
}

_pl_ok() {
	local _msg="$1"
	printf '%b[OK]%b %s\n' "$_PL_GREEN" "$_PL_NC" "$_msg"
	return 0
}

_pl_warn() {
	local _msg="$1"
	printf '%b[WARN]%b %s\n' "$_PL_YELLOW" "$_PL_NC" "$_msg" >&2
	return 0
}

_pl_err() {
	local _msg="$1"
	printf '%b[ERROR]%b %s\n' "$_PL_RED" "$_PL_NC" "$_msg" >&2
	return 0
}

_pulse_refresh_active_runtime() {
	local active_root=""
	active_root=$(resolve_aidevops_runtime_bundle_root "$_PULSE_ACTIVE_AGENTS_LINK") || return 1
	[[ -x "$active_root/scripts/pulse-wrapper.sh" ]] || return 1
	_PULSE_AGENTS_DIR="$active_root"
	_PULSE_SCRIPT="${_PULSE_AGENTS_DIR}/scripts/pulse-wrapper.sh"
	return 0
}

_pulse_runtime_bundle_id() {
	local manifest_line=""
	if [[ -r "$_PULSE_AGENTS_DIR/.bundle-manifest" ]]; then
		while IFS= read -r manifest_line; do
			case "$manifest_line" in
			bundle_id=*)
				printf '%s\n' "${manifest_line#bundle_id=}"
				return 0
				;;
			esac
		done <"$_PULSE_AGENTS_DIR/.bundle-manifest"
	fi
	printf '%s\n' "unknown"
	return 0
}

_pulse_launchd_supervisor_disabled() {
	local os_name="${AIDEVOPS_PULSE_OS_NAME:-}"
	local pulse_label="${AIDEVOPS_PULSE_LAUNCHD_LABEL:-com.aidevops.aidevops-supervisor-pulse}"
	local disabled_state=""
	local disabled_line=""
	[[ -n "$os_name" ]] || os_name=$(uname -s 2>/dev/null || printf 'unknown')
	[[ "$os_name" == "Darwin" ]] || return 1
	command -v launchctl >/dev/null 2>&1 || return 1
	disabled_state=$(launchctl print-disabled "gui/$(id -u)" 2>/dev/null) || return 1
	while IFS= read -r disabled_line; do
		if [[ "$disabled_line" == *"$pulse_label"* && "$disabled_line" == *"=> true"* ]]; then
			return 0
		fi
	done <<<"$disabled_state"
	return 1
}

_pulse_launchd_supervisor_present() {
	local os_name="${AIDEVOPS_PULSE_OS_NAME:-}"
	local pulse_label="${AIDEVOPS_PULSE_LAUNCHD_LABEL:-com.aidevops.aidevops-supervisor-pulse}"
	local pulse_plist="${HOME}/Library/LaunchAgents/${pulse_label}.plist"
	[[ -n "$os_name" ]] || os_name=$(uname -s 2>/dev/null || printf 'unknown')
	[[ "$os_name" == "Darwin" ]] || return 1
	command -v launchctl >/dev/null 2>&1 || return 1
	[[ -f "$pulse_plist" ]] && return 0
	launchctl print "gui/$(id -u)/${pulse_label}" >/dev/null 2>&1 || return 1
	return 0
}

_pulse_wait_for_launchd_runtime() {
	local baseline_pids="$1"
	local waited_seconds=0
	local active_pid=""
	while true; do
		if active_pid=$(_pulse_find_active_runtime_pid_since "$baseline_pids"); then
			printf '%s\n' "$active_pid"
			return 0
		fi
		[[ "$waited_seconds" -lt "$_PULSE_LAUNCHD_START_WAIT" ]] || return 1
		sleep 1
		waited_seconds=$((waited_seconds + 1))
	done
}

_pulse_start_managed() {
	local pulse_label="${AIDEVOPS_PULSE_LAUNCHD_LABEL:-com.aidevops.aidevops-supervisor-pulse}"
	local launchd_target=""
	local baseline_pids=""
	local active_pid=""
	launchd_target="gui/$(id -u)/${pulse_label}"
	if _pulse_launchd_supervisor_present; then
		_pl_info "Requesting Pulse restart from launchd supervisor ${pulse_label}"
		# KeepAlive may already have replaced the process stopped by reconciliation.
		# Snapshot again immediately before kickstart so only a process created by
		# this managed replacement can satisfy the activation proof below.
		baseline_pids=$(_pulse_pids)
		if ! launchctl kickstart -k "$launchd_target" >/dev/null 2>&1; then
			_pl_err "launchd could not restart Pulse; refusing an unmanaged fallback"
			return 1
		fi
		if active_pid=$(_pulse_wait_for_launchd_runtime "$baseline_pids"); then
			_pl_ok "Pulse restarted by launchd from the activated bundle (PID ${active_pid})"
			return 0
		fi
		_pl_err "launchd accepted the Pulse restart but no new activated-bundle process appeared"
		return 1
	fi
	_start_activated_runtime
	return $?
}

# _pulse_pids_raw: print ALL matching pulse PIDs including subshells of the
# pulse cycle (one per line). Used by _stop_all which must SIGTERM every
# pulse process — not just the top-level one (GH#21549).
_pulse_pids_raw() {
	pgrep -f "$_PULSE_PATTERN" 2>/dev/null || true
	return 0
}

# _pulse_merge_pids_raw: print standalone merge-routine PIDs. These routines
# source the runtime once at startup just like pulse-wrapper.sh, so setup-time
# reconciliation must retire pre-activation instances as well.
_pulse_merge_pids_raw() {
	pgrep -f "$_PULSE_MERGE_PATTERN" 2>/dev/null || true
	return 0
}

_pulse_pid_list_contains() {
	local _pids="$1"
	local _wanted="$2"
	local _pid=""
	while IFS= read -r _pid; do
		[[ -n "$_pid" && "$_pid" == "$_wanted" ]] && return 0
	done <<<"$_pids"
	return 1
}

# Snapshot every runtime process whose sourced code must be replaced. The
# snapshot is deliberate: a launchd KeepAlive replacement created after this
# point belongs to the activated bundle and is not a failed-stop residual.
_pulse_reconciliation_pids_raw() {
	local _wrapper_pids=""
	local _merge_pids=""
	local _emitted=""
	local _pid=""
	_wrapper_pids=$(_pulse_pids_raw)
	_merge_pids=$(_pulse_merge_pids_raw)
	while IFS= read -r _pid; do
		[[ "$_pid" =~ ^[0-9]+$ ]] || continue
		if ! _pulse_pid_list_contains "$_emitted" "$_pid"; then
			printf '%s\n' "$_pid"
			_emitted="${_emitted}${_emitted:+$'\n'}${_pid}"
		fi
	done <<<"$_wrapper_pids"
	while IFS= read -r _pid; do
		[[ "$_pid" =~ ^[0-9]+$ ]] || continue
		if ! _pulse_pid_list_contains "$_emitted" "$_pid"; then
			printf '%s\n' "$_pid"
			_emitted="${_emitted}${_emitted:+$'\n'}${_pid}"
		fi
	done <<<"$_merge_pids"
	return 0
}

_pulse_process_start_token() {
	local _pid="$1"
	local _stat_content=""
	local _stat_after_comm=""
	local _start_token=""
	[[ "$_pid" =~ ^[0-9]+$ ]] || return 1
	if [[ -r "/proc/${_pid}/stat" ]]; then
		_stat_content=$(<"/proc/${_pid}/stat") || _stat_content=""
		[[ -n "$_stat_content" ]] || return 1
		_stat_after_comm="${_stat_content##*) }"
		_start_token=$(printf '%s\n' "$_stat_after_comm" | awk '{print $20}') || _start_token=""
	else
		_start_token=$(LC_ALL=C ps -p "$_pid" -o lstart= 2>/dev/null | tr -s ' ') || _start_token=""
		_start_token="${_start_token#"${_start_token%%[![:space:]]*}"}"
		_start_token="${_start_token%"${_start_token##*[![:space:]]}"}"
	fi
	[[ -n "$_start_token" ]] || return 1
	printf '%s\n' "$_start_token"
	return 0
}

# Capture PID plus process start time before signalling. A numeric PID alone is
# not a stable identity: a fast exit followed by PID reuse could otherwise let
# reconciliation signal an unrelated process during the TERM/KILL windows.
_pulse_reconciliation_identities() {
	local _pids=""
	local _pid=""
	local _start_token=""
	_pids=$(_pulse_reconciliation_pids_raw)
	while IFS= read -r _pid; do
		[[ "$_pid" =~ ^[0-9]+$ ]] || continue
		if ! _start_token=$(_pulse_process_start_token "$_pid"); then
			if kill -0 "$_pid" 2>/dev/null; then
				_pl_err "Unable to capture stable identity for Pulse PID ${_pid}; refusing to signal it"
				return 1
			fi
			continue
		fi
		printf '%s\t%s\n' "$_pid" "$_start_token"
	done <<<"$_pids"
	return 0
}

_pulse_identity_is_reconciliation_process() {
	local _pid="$1"
	local _expected_start="$2"
	local _current_start=""
	local _command=""
	[[ "$_pid" =~ ^[0-9]+$ && -n "$_expected_start" ]] || return 1
	kill -0 "$_pid" 2>/dev/null || return 1
	_current_start=$(_pulse_process_start_token "$_pid") || return 1
	[[ "$_current_start" == "$_expected_start" ]] || return 1
	_command=$(ps -p "$_pid" -o command= 2>/dev/null || true)
	[[ "$_command" =~ $_PULSE_PATTERN || "$_command" =~ $_PULSE_MERGE_PATTERN ]] || return 1
	return 0
}

# Return only snapshot identities that are still alive, retain their original
# process start time, and still identify as Pulse runtime processes.
_pulse_snapshot_survivors() {
	local _identities="$1"
	local _pid=""
	local _start_token=""
	while IFS=$'\t' read -r _pid _start_token; do
		[[ -n "$_pid" && -n "$_start_token" ]] || continue
		if _pulse_identity_is_reconciliation_process "$_pid" "$_start_token"; then
			printf '%s\t%s\n' "$_pid" "$_start_token"
		fi
	done <<<"$_identities"
	return 0
}

_pulse_signal_snapshot() {
	local _signal="$1"
	local _identities="$2"
	local _pid=""
	local _start_token=""
	while IFS=$'\t' read -r _pid _start_token; do
		[[ -n "$_pid" && -n "$_start_token" ]] || continue
		_pulse_identity_is_reconciliation_process "$_pid" "$_start_token" || continue
		kill "-${_signal}" "$_pid" 2>/dev/null || true
	done <<<"$_identities"
	return 0
}

_pulse_identity_pids() {
	local _identities="$1"
	local _pid=""
	local _start_token=""
	while IFS=$'\t' read -r _pid _start_token; do
		[[ -n "$_pid" && -n "$_start_token" ]] || continue
		printf '%s\n' "$_pid"
	done <<<"$_identities"
	return 0
}

_pulse_pid_invokes_script() {
	local _pid="$1"
	local _script_path="$2"
	local _command_line=""
	local _command_arg=""
	local _command_name=""
	local _arg_index=0
	local _options_done=false
	[[ "$_pid" =~ ^[0-9]+$ && -n "$_script_path" ]] || return 1

	if [[ -r "/proc/${_pid}/cmdline" ]]; then
		while IFS= read -r -d '' _command_arg; do
			if [[ "$_arg_index" -eq 0 ]]; then
				[[ "$_command_arg" == "$_script_path" ]] && return 0
				_command_name="${_command_arg##*/}"
				case "$_command_name" in
				bash | dash | ksh | sh | zsh) ;;
				*) return 1 ;;
				esac
				_arg_index=1
				continue
			fi
			if [[ "$_options_done" == "false" ]]; then
				case "$_command_arg" in
				--)
					_options_done=true
					continue
					;;
				-*c*) return 1 ;;
				-*) continue ;;
				esac
			fi
			[[ "$_command_arg" == "$_script_path" ]] && return 0
			return 1
		done <"/proc/${_pid}/cmdline"
		return 1
	fi

	_command_line=$(ps -p "$_pid" -o command= 2>/dev/null) || _command_line=""
	case "$_command_line" in
	"$_script_path" | "$_script_path "*) return 0 ;;
	esac
	for _command_name in bash dash ksh sh zsh; do
		case "$_command_line" in
		"${_command_name} ${_script_path}" | "${_command_name} ${_script_path} "* | */"${_command_name} ${_script_path}" | */"${_command_name} ${_script_path} "*)
			return 0
			;;
		esac
	done
	return 1
}

# Verify a candidate PID against the activated runtime. Immutable production
# bundles expose an authoritative PID lease. All roots also require exact
# script invocation so an observer that merely mentions the wrapper path cannot
# satisfy setup's activated-runtime proof.
_pulse_pid_uses_active_runtime() {
	local _pid="$1"
	local _active_root=""
	local _bundles_root="${AIDEVOPS_RUNTIME_BUNDLES_DIR:-${HOME}/.aidevops/runtime-bundles}"
	local _physical_bundles_root=""
	local _bundle_dir=""
	local _bundle_id=""
	local _lease_file=""
	local _lease_root=""
	local _active_link_script="${_PULSE_ACTIVE_AGENTS_LINK%/}/scripts/pulse-wrapper.sh"
	[[ "$_pid" =~ ^[0-9]+$ ]] || return 1
	if ! _pulse_pid_invokes_script "$_pid" "$_PULSE_SCRIPT" &&
		! _pulse_pid_invokes_script "$_pid" "$_active_link_script"; then
		return 1
	fi
	_active_root=$(cd "$_PULSE_AGENTS_DIR" 2>/dev/null && pwd -P) || return 1
	if [[ -d "$_bundles_root" ]]; then
		_physical_bundles_root=$(cd "$_bundles_root" 2>/dev/null && pwd -P) || return 1
		_bundle_dir="${_active_root%/agents}"
		if [[ "$_bundle_dir" != "$_active_root" && "${_bundle_dir%/*}" == "$_physical_bundles_root" ]]; then
			_bundle_id="${_bundle_dir##*/}"
			_lease_file="${_physical_bundles_root}/.leases/${_bundle_id}/${_pid}"
			[[ -r "$_lease_file" ]] || return 1
			IFS= read -r _lease_root <"$_lease_file" || return 1
			[[ "$_lease_root" == "$_active_root" ]] && return 0
			return 1
		fi
	fi
	return 0
}

_pulse_find_active_runtime_pid_since() {
	local _baseline_pids="$1"
	local _current_pids=""
	local _pid=""
	_current_pids=$(_pulse_pids)
	while IFS= read -r _pid; do
		[[ "$_pid" =~ ^[0-9]+$ ]] || continue
		_pulse_pid_list_contains "$_baseline_pids" "$_pid" && continue
		if _pulse_pid_uses_active_runtime "$_pid"; then
			printf '%s\n' "$_pid"
			return 0
		fi
	done <<<"$_current_pids"
	return 1
}

# _pulse_emit_pid: print one PID while tolerating early-closing consumers.
#
# Watchdog/status callers may pipe PID lists into consumers that intentionally
# exit after the first match. Bash's printf reports EPIPE as noisy "Broken pipe"
# stderr output unless stderr is suppressed at the emit site. Callers ignore
# SIGPIPE for the full emit loop and restore the prior trap afterwards; return 1
# to tell the caller to stop emitting without treating the closed pipe as
# discovery failure.
_pulse_emit_pid() {
	local _pid="$1" _rc=0
	printf '%s\n' "$_pid" 2>/dev/null || _rc=$?
	[[ "$_rc" -eq 0 ]] || return 1
	return 0
}

_pulse_restore_pipe_trap() {
	local _pipe_trap="$1"
	if [[ "$_pipe_trap" == *"trap -- '' SIGPIPE"* || "$_pipe_trap" == *"trap -- '' PIPE"* ]]; then
		trap '' PIPE
	else
		trap - PIPE
	fi
	return 0
}

# _pulse_pids: print only top-level MAIN pulse PIDs (one per line). Subshells
# of a running pulse cycle inherit the parent's argv so naive pgrep over-counts.
# This function filters to PIDs whose PARENT command is NOT itself
# pulse-wrapper.sh, eliminating the subshell false positives that trigger
# spurious "MULTIPLE pulse instances detected" warnings (GH#21549, GH#21581),
# AND filters out short-lived sidecar roles (--merge-only, --self-check,
# --dry-run, --canary, GH#21903) so they don't consume threshold slots
# reserved for legitimate t2774 main-pulse overlap.
#
# Three-layer filter:
#   Layer 1 (subshell guard, fast path): if PPID=1 (init/launchd), the process
#     is a canonical top-level instance — include unless filtered by Layer 3.
#     Subshells always have PPID = the pulse PID (> 1), so PPID=1 is a reliable
#     signal for production instances started by the system process manager
#     (launchd on macOS, systemd/init on Linux).
#   Layer 2 (subshell guard, fallback): for manually-started instances
#     (PPID != 1), skip PIDs whose parent command itself contains
#     pulse-wrapper.sh — the process is a subshell of a running pulse.
#   Layer 3 (sidecar guard, GH#21903): skip PIDs whose argv contains any
#     sidecar role flag. Sidecars are categorically different from main
#     pulse cycles and reported separately by _pulse_pids_sidecar.
#
# Empty output = no main pulse running.
# _stop_all uses _pulse_pids_raw (not this function) so it still SIGTERMs
# all pulse processes including subshells AND sidecars on `stop`.
_pulse_pids() {
	local _pids="" _pid="" _ppid="" _ppid_cmd="" _cmd="" _pipe_trap=""
	_pids=$(_pulse_pids_raw)
	[[ -z "$_pids" ]] && return 0
	_pipe_trap=$(trap -p PIPE || true)
	trap '' PIPE
	while read -r _pid; do
		_ppid=$(ps -p "$_pid" -o ppid= 2>/dev/null | tr -d ' ')
		[[ -z "$_ppid" || "$_ppid" == "0" ]] && continue
		# Layer 1 (fast path): process started by init/launchd (PPID=1) is the
		# canonical top-level instance. Subshells of pulse always have PPID = the
		# pulse PID itself (> 1), never 1.
		if [[ "$_ppid" == "1" ]]; then
			# Layer 3 (sidecar guard): skip if argv contains a sidecar flag.
			_cmd=$(ps -p "$_pid" -o command= 2>/dev/null)
			[[ "$_cmd" =~ $_PULSE_SIDECAR_FLAGS_RE ]] && continue
			_pulse_emit_pid "$_pid" || break
			continue
		fi
		# Layer 2 (fallback for manually-started instances): skip PIDs whose
		# parent command contains pulse-wrapper.sh (= direct subshell of pulse).
		_ppid_cmd=$(ps -p "$_ppid" -o command= 2>/dev/null)
		[[ "$_ppid_cmd" =~ pulse-wrapper\.sh ]] && continue
		# Layer 3 (sidecar guard): also skip non-launchd-started sidecars
		# (manual --merge-only invocations during testing or debugging).
		_cmd=$(ps -p "$_pid" -o command= 2>/dev/null)
		[[ "$_cmd" =~ $_PULSE_SIDECAR_FLAGS_RE ]] && continue
		_pulse_emit_pid "$_pid" || break
	done <<<"$_pids"
	_pulse_restore_pipe_trap "$_pipe_trap"
	return 0
}

# _pulse_pids_sidecar: print only top-level SIDECAR pulse PIDs (one per line).
# Mirror of _pulse_pids but inverts Layer 3 — emit only PIDs whose argv
# matches _PULSE_SIDECAR_FLAGS_RE. Used by _status to display sidecars
# informationally without counting them toward the PILE-UP threshold.
# Subshell guards (Layers 1 and 2) still apply — sidecars run as top-level
# launchd-spawned processes (PPID=1), never as subshells of a main pulse.
_pulse_pids_sidecar() {
	local _pids="" _pid="" _ppid="" _ppid_cmd="" _cmd="" _pipe_trap=""
	_pids=$(_pulse_pids_raw)
	[[ -z "$_pids" ]] && return 0
	_pipe_trap=$(trap -p PIPE || true)
	trap '' PIPE
	while read -r _pid; do
		_ppid=$(ps -p "$_pid" -o ppid= 2>/dev/null | tr -d ' ')
		[[ -z "$_ppid" || "$_ppid" == "0" ]] && continue
		if [[ "$_ppid" != "1" ]]; then
			_ppid_cmd=$(ps -p "$_ppid" -o command= 2>/dev/null)
			[[ "$_ppid_cmd" =~ pulse-wrapper\.sh ]] && continue
		fi
		_cmd=$(ps -p "$_pid" -o command= 2>/dev/null)
		if [[ "$_cmd" =~ $_PULSE_SIDECAR_FLAGS_RE ]]; then
			_pulse_emit_pid "$_pid" || break
		fi
	done <<<"$_pids"
	_pulse_restore_pipe_trap "$_pipe_trap"
	return 0
}

# _is_running: exit 0 if any pulse PID alive, 1 otherwise.
_is_running() {
	local _pids
	_pids=$(_pulse_pids)
	[[ -n "$_pids" ]]
}

# _stop_all: terminate every pulse PID. SIGTERM first, escalate to SIGKILL
# if any survive after _PULSE_SIGTERM_WAIT seconds. Idempotent.
# Uses _pulse_pids_raw (not _pulse_pids) so that subshells of the pulse cycle
# are included in both the display list and the survivor check (GH#21549).
_stop_all() {
	local _pids
	_pids=$(_pulse_pids_raw)
	if [[ -z "$_pids" ]]; then
		return 0
	fi

	_pl_info "Stopping pulse instance(s): $(echo "$_pids" | tr '\n' ' ')"
	# SIGTERM: allow graceful shutdown (release locks, write state).
	# pkill returns 0 if any matched, 1 if none — ignore both.
	pkill -TERM -f "$_PULSE_PATTERN" 2>/dev/null || true
	sleep "$_PULSE_SIGTERM_WAIT"

	# Escalate if any survived — check ALL processes including subshells.
	local _survivors
	_survivors=$(_pulse_pids_raw)
	if [[ -n "$_survivors" ]]; then
		_pl_warn "SIGTERM timeout, escalating to SIGKILL: $(echo "$_survivors" | tr '\n' ' ')"
		pkill -KILL -f "$_PULSE_PATTERN" 2>/dev/null || true
		sleep 1
	fi

	# Final check — use raw to catch any residual including subshells.
	local _residual
	_residual=$(_pulse_pids_raw)
	if [[ -n "$_residual" ]]; then
		_pl_err "Failed to stop pulse after SIGKILL — residual PIDs: $(echo "$_residual" | tr '\n' ' ')"
		return 1
	fi
	return 0
}

# Stop only the processes present at the beginning of setup reconciliation.
# Unlike _stop_all, the final check intentionally ignores later PIDs: launchd
# KeepAlive may immediately create the intended active-bundle replacement.
_stop_reconciliation_processes() {
	local _identities=""
	local _survivors=""
	local _residual=""
	local _display_pids=""
	if ! _identities=$(_pulse_reconciliation_identities); then
		return 1
	fi
	[[ -n "$_identities" ]] || return 0

	_display_pids=$(_pulse_identity_pids "$_identities" | tr '\n' ' ')
	_pl_info "Stopping pre-reconciliation Pulse process(es): ${_display_pids}"
	_survivors=$(_pulse_snapshot_survivors "$_identities")
	_pulse_signal_snapshot TERM "$_survivors"
	sleep "$_PULSE_SIGTERM_WAIT"
	_survivors=$(_pulse_snapshot_survivors "$_identities")
	if [[ -n "$_survivors" ]]; then
		_display_pids=$(_pulse_identity_pids "$_survivors" | tr '\n' ' ')
		_pl_warn "SIGTERM timeout, escalating pre-reconciliation PIDs to SIGKILL: ${_display_pids}"
		_pulse_signal_snapshot KILL "$_survivors"
		sleep 1
	fi

	_residual=$(_pulse_snapshot_survivors "$_identities")
	if [[ -n "$_residual" ]]; then
		_display_pids=$(_pulse_identity_pids "$_residual" | tr '\n' ' ')
		_pl_err "Failed to retire pre-reconciliation Pulse processes after SIGKILL — residual PIDs: ${_display_pids}"
		return 1
	fi
	return 0
}

# _pulse_launch_unmanaged: launch pulse in background via nohup.
_pulse_launch_unmanaged() {
	mkdir -p "${_PULSE_LOG%/*}"

	# t2994: cache priming moved into pulse-wrapper.sh::main() with a
	# staleness gate. The original t2992 hook here never fired under
	# launchd-managed pulse on macOS because launchd's KeepAlive
	# auto-respawns inside this helper's stop→sleep→start window, so
	# _start's _is_running early-return skipped priming entirely. The
	# in-pulse hook fires regardless of how pulse boots (manual restart,
	# launchd respawn, aidevops update, setup.sh ensure-running).

	# GH#20580: set AIDEVOPS_PULSE_SOURCE so pulse-wrapper.sh records this
	# invocation as "lifecycle-helper" in its invocation_sources counter.
	AIDEVOPS_PULSE_SOURCE=lifecycle-helper nohup "$_PULSE_SCRIPT" >>"$_PULSE_LOG" 2>&1 &
	disown 2>/dev/null || true

	# Give nohup a moment to fork and let pulse-wrapper emit its startup banner.
	sleep 1
	return 0
}

_pulse_require_script() {
	if [[ ! -x "$_PULSE_SCRIPT" ]]; then
		_pl_err "pulse-wrapper.sh not found or not executable: $_PULSE_SCRIPT"
		return 2
	fi
	return 0
}

# _start: launch pulse in background via nohup. No-op if already running.
_start() {
	if _is_running; then
		_pl_info "Pulse already running (PIDs: $(_pulse_pids | tr '\n' ' '))"
		return 0
	fi

	_pulse_require_script || return $?
	_pulse_launch_unmanaged

	if _is_running; then
		_pl_ok "Pulse started (PID: $(_pulse_pids | head -1))"
		return 0
	fi
	_pl_err "Pulse failed to start — check $_PULSE_LOG"
	return 1
}

_start_activated_runtime() {
	local active_pid=""
	if active_pid=$(_pulse_find_active_runtime_pid_since ""); then
		_pl_info "Pulse already running from the activated bundle (PID ${active_pid})"
		return 0
	fi
	_pulse_require_script || return $?
	_pulse_launch_unmanaged
	if active_pid=$(_pulse_find_active_runtime_pid_since ""); then
		_pl_ok "Pulse is running from the activated bundle (PID ${active_pid})"
		return 0
	fi
	_pl_err "Pulse started but its activated runtime bundle could not be verified"
	return 1
}

# _restart: force stop + start. Honours AIDEVOPS_SKIP_PULSE_RESTART env opt-out.
_restart() {
	if [[ "${AIDEVOPS_SKIP_PULSE_RESTART:-0}" == "1" ]]; then
		_pl_info "AIDEVOPS_SKIP_PULSE_RESTART=1 — skipping pulse restart"
		return 0
	fi

	_stop_all || return $?
	sleep "$_PULSE_RESTART_WAIT"
	_start
}

# _restart_if_running: canonical entry point for update/deploy flows.
# No-op if pulse isn't running (user hasn't enabled it yet, or has it stopped).
# Otherwise full stop + start to pick up fresh code.
_restart_if_running() {
	if [[ "${AIDEVOPS_SKIP_PULSE_RESTART:-0}" == "1" ]]; then
		_pl_info "AIDEVOPS_SKIP_PULSE_RESTART=1 — skipping pulse restart-if-running"
		return 0
	fi

	if ! _is_running; then
		# Not running — nothing to restart. Silent success.
		return 0
	fi

	_pl_info "Restarting pulse to load updated scripts..."
	_stop_all || return $?
	sleep "$_PULSE_RESTART_WAIT"
	_start
}

# _reconcile_managed: setup-only lifecycle path. The shared transition lock
# prevents a concurrent activation/restart interleave from leaving an older
# Pulse revision running. Re-resolve after the restart delay in case a waiting
# activation won the lock immediately before this process.
_reconcile_managed() {
	local runtime_module="${_PULSE_AGENTS_DIR}/scripts/setup/modules/agent-runtime.sh"
	local reconcile_rc=0
	local bundle_id=""
	local supervisor_disabled=false
	local disabled_residual=""

	if [[ ! -r "$runtime_module" ]]; then
		_pl_err "Runtime transition support is missing from the activated bundle"
		return 2
	fi
	# shellcheck source=setup/modules/agent-runtime.sh
	source "$runtime_module"
	if ! aidevops_runtime_transition_lock_acquire; then
		_pl_err "Unable to acquire the runtime transition lock"
		return 1
	fi

	if [[ "${AIDEVOPS_PULSE_MANAGED_ENABLED:-false}" != "true" ]]; then
		supervisor_disabled=true
	elif _pulse_launchd_supervisor_disabled; then
		supervisor_disabled=true
	fi

	if ! _pulse_refresh_active_runtime; then
		_pl_err "Unable to resolve the active runtime bundle"
		reconcile_rc=1
	elif [[ "$supervisor_disabled" == "true" ]]; then
		_stop_reconciliation_processes || reconcile_rc=$?
		disabled_residual=$(_pulse_reconciliation_pids_raw)
		if [[ "$reconcile_rc" -eq 0 && -n "$disabled_residual" ]]; then
			_pl_err "Pulse supervisor is disabled but runtime processes remain: $(printf '%s\n' "$disabled_residual" | tr '\n' ' ')"
			reconcile_rc=1
		fi
		[[ "$reconcile_rc" -eq 0 ]] && _pl_info "Pulse remains stopped because its supervisor is disabled"
	else
		_stop_reconciliation_processes || reconcile_rc=$?
		if [[ "$reconcile_rc" -eq 0 ]]; then
			sleep "$_PULSE_RESTART_WAIT"
			if ! _pulse_refresh_active_runtime; then
				_pl_err "Unable to re-resolve the active runtime bundle before Pulse start"
				reconcile_rc=1
			else
				bundle_id=$(_pulse_runtime_bundle_id)
				_pl_info "Starting Pulse from activated runtime bundle ${bundle_id}"
				_pulse_start_managed || reconcile_rc=$?
			fi
		fi
	fi

	aidevops_runtime_transition_lock_release
	[[ "$reconcile_rc" -eq 0 ]] || return "$reconcile_rc"
	return 0
}

# _status: human-readable PID + age. Reports lock-holder PID and warns ONLY
# when the alive-PID count exceeds AIDEVOPS_PULSE_EXPECTED_MAX_INSTANCES
# (default 3 — see the constant block above for the t2774 design rationale).
#
# History note (GH#21433 → GH#21903):
#   GH#4513/GH#21433 originally framed coexistence of pulse-wrapper.sh PIDs as
#   a "singleton invariant violation". After t2774 (lock release before LLM
#   phase) and t3002 (post-write race fix) landed, brief coexistence of 2-3
#   PIDs is the EXPECTED steady state — not a violation. The warning was
#   firing on legitimate post-release overlap, training operators to ignore
#   it. GH#21903 reframes it as PILE-UP detection: warn only when the count
#   exceeds the threshold (genuine respawn-outpacing-cycle-completion pattern).
_status() {
	local _pids="" _sidecar_pids=""
	_pids=$(_pulse_pids)
	_sidecar_pids=$(_pulse_pids_sidecar)
	if [[ -z "$_pids" && -z "$_sidecar_pids" ]]; then
		printf 'Pulse: not running\n'
		return 0
	fi

	# Count MAIN PIDs only (sidecars are listed separately and don't count
	# toward the PILE-UP threshold, GH#21903).
	local _pid_count=0
	if [[ -n "$_pids" ]]; then
		_pid_count=$(printf '%s\n' "$_pids" | wc -l | tr -d ' ')
		[[ "$_pid_count" =~ ^[0-9]+$ ]] || _pid_count=0
	fi

	if [[ "$_pid_count" -eq 0 ]]; then
		printf 'Pulse: not running (sidecar(s) only)\n'
	else
		printf 'Pulse: running (%s instance%s)\n' "$_pid_count" "$([[ $_pid_count -eq 1 ]] || printf 's')"
	fi

	# Read lock-holder PID for cross-reference (GH#21433 acceptance criterion).
	# AIDEVOPS_PULSE_LOCK_DIR overrides the default path — useful for tests
	# that must isolate from the real user lockdir (GH#21581).
	local _lockdir="${AIDEVOPS_PULSE_LOCK_DIR:-${HOME}/.aidevops/logs/pulse-wrapper.lockdir}"
	local _lock_pid=""
	if [[ -f "${_lockdir}/pid" ]]; then
		_lock_pid=$(cat "${_lockdir}/pid" 2>/dev/null || echo "")
	fi
	if [[ -n "$_lock_pid" ]]; then
		printf '  Lock holder PID: %s\n' "$_lock_pid"
	elif [[ -n "$_pids" ]]; then
		# The instance lock is intentionally released BEFORE the LLM dispatch
		# session (pulse-wrapper.sh calls release_instance_lock before exec'ing
		# the LLM supervisor) so the next launchd respawn finds no lock and exits
		# immediately. An empty lockdir/pid while a pulse process is alive is
		# therefore expected during active LLM dispatch — it is NOT an error.
		printf '  Lock holder PID: (none — lock released for LLM dispatch; process alive)\n'
	else
		printf '  Lock holder PID: (LOCKDIR/pid missing or empty)\n'
	fi

	local _pid
	if [[ -n "$_pids" ]]; then
		while IFS= read -r _pid; do
			local _etime
			_etime=$(ps -p "$_pid" -o etime= 2>/dev/null | tr -d ' ')
			local _marker=""
			[[ "$_pid" == "$_lock_pid" ]] && _marker=" (lock holder)"
			printf '  PID %s%s (uptime %s)\n' "$_pid" "$_marker" "${_etime:-unknown}"
		done <<<"$_pids"
	fi

	# Sidecar listing (informational only — does NOT count toward PILE-UP).
	if [[ -n "$_sidecar_pids" ]]; then
		local _sidecar_count
		_sidecar_count=$(printf '%s\n' "$_sidecar_pids" | wc -l | tr -d ' ')
		[[ "$_sidecar_count" =~ ^[0-9]+$ ]] || _sidecar_count=0
		printf '  Sidecar%s: %s alive (excluded from PILE-UP threshold, GH#21903)\n' \
			"$([[ $_sidecar_count -eq 1 ]] || printf 's')" "$_sidecar_count"
		while IFS= read -r _pid; do
			local _setime="" _scmd="" _srole=""
			_setime=$(ps -p "$_pid" -o etime= 2>/dev/null | tr -d ' ')
			_scmd=$(ps -p "$_pid" -o command= 2>/dev/null)
			# Extract role flag from argv for the display label.
			_srole=$(printf '%s' "$_scmd" | grep -oE "$_PULSE_SIDECAR_FLAGS_RE" | head -1)
			printf '    PID %s [%s] (uptime %s)\n' "$_pid" "${_srole:-sidecar}" "${_setime:-unknown}"
		done <<<"$_sidecar_pids"
	fi

	# PILE-UP check applies to MAIN count only — sidecars are categorically
	# different and counted separately above (GH#21903).
	if [[ "$_pid_count" -gt "$_PULSE_EXPECTED_MAX_INSTANCES" ]]; then
		_pl_warn "PILE-UP: $_pid_count main pulse-wrapper.sh processes alive (threshold $_PULSE_EXPECTED_MAX_INSTANCES, GH#21903)"
		_pl_warn "Up to $_PULSE_EXPECTED_MAX_INSTANCES is normal post-t2774 (lock released before LLM phase)."
		_pl_warn "Pile-up beyond that suggests launchd respawn outpacing cycle completion or hung LLM phases."
		_pl_warn "Sidecars (--merge-only / --self-check / --dry-run / --canary) are excluded from this count."
		_pl_warn "Recommendation: $(basename "$0") restart    # full stop+start to recover"
		# Exit non-zero so callers (scripts, monitoring) can detect the anomaly.
		return 3
	fi
	return 0
}

_usage() {
	cat <<'EOF'
Usage: pulse-lifecycle-helper.sh <command>

Commands:
  is-running            Exit 0 if pulse running, 1 if not.
  status                Print running PIDs and uptime.
  start                 Start pulse (no-op if already running).
  stop                  Stop all pulse instances.
  restart               Force stop + start.
  restart-if-running    Restart only if running; no-op otherwise.
  reconcile-managed     Reconcile with the active bundle and supervisor state.

Env:
  AIDEVOPS_SKIP_PULSE_RESTART=1            Skip restart operations.
  AIDEVOPS_PULSE_RESTART_WAIT=3            Seconds between stop and start.
  AIDEVOPS_PULSE_SIGTERM_WAIT=2            Seconds before escalating to SIGKILL.
  AIDEVOPS_PULSE_EXPECTED_MAX_INSTANCES=3  Status warn threshold (MAIN only;
                                           sidecars excluded — GH#21903).
  AIDEVOPS_AGENTS_DIR=<path>               Override ~/.aidevops/agents.
  AIDEVOPS_ACTIVE_AGENTS_LINK=<path>        Active runtime link for reconciliation.
  AIDEVOPS_PULSE_MANAGED_ENABLED=true       Allow reconcile-managed to start Pulse.
  AIDEVOPS_PULSE_MERGE_PROCESS_PATTERN=...  Override merge-routine match (tests).

Exit codes:
  0  Success
  1  Pulse not running (is-running only) / pulse failed to start
  2  Invalid subcommand or missing pulse-wrapper.sh
  3  status: main-pulse pile-up detected (count > threshold, GH#21433/GH#21903)
EOF
	return 0
}

main() {
	local _cmd="${1:-}"
	case "$_cmd" in
	is-running)
		_is_running && exit 0 || exit 1
		;;
	status)
		_status
		;;
	start)
		_start
		;;
	stop)
		_stop_all
		;;
	restart)
		_restart
		;;
	restart-if-running)
		_restart_if_running
		;;
	reconcile-managed)
		_reconcile_managed
		;;
	-h | --help | help | "")
		_usage
		exit 0
		;;
	*)
		_pl_err "Unknown command: $_cmd"
		_usage
		exit 2
		;;
	esac
}

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
