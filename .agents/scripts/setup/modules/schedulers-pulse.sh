#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Schedulers Pulse Sub-Library -- Pulse resolution, supervisor setup, plist
# generation, and watchdog installation functions.
# =============================================================================
# This sub-library is sourced by .agents/scripts/setup/modules/schedulers.sh (the orchestrator).
# It covers:
#   - Modern bash resolution for launchd ProgramArguments
#   - Pulse consent resolution and install decision
#   - OpenCode binary discovery (nvm/volta/fnm sweep, legacy paths)
#   - Supervisor pulse installation (launchd + Linux)
#   - Plist content generation (pulse + watchdog)
#   - Pulse watchdog installation
#
# Usage: source "${SCRIPT_DIR}/schedulers-pulse.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning)
#   - schedulers-linux.sh (must be sourced separately; _install_scheduler_linux
#     is called by _install_supervisor_pulse and _install_pulse_watchdog_systemd)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SCHEDULERS_PULSE_LIB_LOADED:-}" ]] && return 0
_SCHEDULERS_PULSE_LIB_LOADED=1

# SCRIPT_DIR fallback — needed when sourced from test harnesses that don't set it.
# Pure-bash dirname replacement (avoids external binary dependency).
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_sched_pulse_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_sched_pulse_lib_path" == "${BASH_SOURCE[0]}" ]] && _sched_pulse_lib_path="."
	SCRIPT_DIR="$(cd "$_sched_pulse_lib_path" && pwd)"
	unset _sched_pulse_lib_path
fi

_schedulers_pulse_dir="${BASH_SOURCE[0]%/*}"
[[ "$_schedulers_pulse_dir" == "${BASH_SOURCE[0]}" ]] && _schedulers_pulse_dir="."
# shellcheck source=../../plist-env-overrides-lib.sh
source "${_schedulers_pulse_dir}/../../plist-env-overrides-lib.sh"
unset _schedulers_pulse_dir

# --- Functions ---

# Resolve the modern bash binary path for use in launchd ProgramArguments.
# Launchd bypasses the shebang when ProgramArguments specifies an explicit
# interpreter, so we must resolve the path at plist generation time.
# Falls back to /bin/bash if no modern bash is available (the re-exec guard
# in shared-constants.sh provides defense-in-depth). (GH#19632 / t2176)
_resolve_modern_bash() {
	local candidate
	for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash /home/linuxbrew/.linuxbrew/bin/bash; do
		if [[ -x "$candidate" ]]; then
			# Verify it's actually bash 4+
			local ver
			# shellcheck disable=SC2016  # single quotes intentional: evaluated by $candidate, not current shell
			ver=$("$candidate" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null) || continue
			if [[ "${ver:-0}" -ge 4 ]]; then
				printf '%s' "$candidate"
				return 0
			fi
		fi
	done
	# No modern bash found — fall back to /bin/bash. The re-exec guard in
	# shared-constants.sh handles this case at runtime.
	printf '%s' "/bin/bash"
	return 0
}

# Resolve the user's pulse consent setting from all config layers.
# Priority: env var > jsonc config > legacy .conf. Prints the raw value
# (may be empty if never configured, or "true"/"false").
_resolve_pulse_consent() {
	local _pulse_user_config=""

	# Read explicit user consent from config.jsonc (not merged defaults).
	# Empty = user never configured this; "true"/"false" = explicit choice.
	if type _jsonc_get_raw &>/dev/null && [[ -f "${JSONC_USER:-$HOME/.config/aidevops/config.jsonc}" ]]; then
		_pulse_user_config=$(_jsonc_get_raw "${JSONC_USER:-$HOME/.config/aidevops/config.jsonc}" "orchestration.supervisor_pulse")
	fi

	# Also check legacy .conf user override
	if [[ -z "$_pulse_user_config" && -f "${FEATURE_TOGGLES_USER:-$HOME/.config/aidevops/feature-toggles.conf}" ]]; then
		local _legacy_val
		# Use awk instead of grep|tail|cut — grep exits 1 on no match, which
		# aborts the script under set -euo pipefail. awk always exits 0.
		_legacy_val=$(awk -F= '/^supervisor_pulse=/{val=$2} END{print val}' "${FEATURE_TOGGLES_USER:-$HOME/.config/aidevops/feature-toggles.conf}")
		if [[ -n "$_legacy_val" ]]; then
			_pulse_user_config="$_legacy_val"
		fi
	fi

	# Also check env var override (highest priority)
	if [[ -n "${AIDEVOPS_SUPERVISOR_PULSE:-}" ]]; then
		_pulse_user_config="$AIDEVOPS_SUPERVISOR_PULSE"
	fi

	printf '%s' "$_pulse_user_config"
	return 0
}

# Determine whether to install the pulse based on consent state.
# Handles interactive prompting and persisting the user's choice.
# Args: $1=pulse_user_config (raw), $2=wrapper_script path
# Prints "true" or "false".
_determine_pulse_install() {
	local _pulse_user_config="$1"
	local wrapper_script="$2"
	local _do_install=false
	local _pulse_lower
	_pulse_lower=$(echo "$_pulse_user_config" | tr '[:upper:]' '[:lower:]')

	if [[ "$_pulse_lower" == "false" ]]; then
		# User explicitly declined — never prompt, never install
		_do_install=false
	elif [[ "$_pulse_lower" == "true" ]]; then
		# User explicitly consented — install/regenerate
		_do_install=true
	elif [[ -z "$_pulse_user_config" ]]; then
		# No explicit config — fresh install or never configured
		if [[ "$NON_INTERACTIVE" == "true" ]]; then
			# Non-interactive: default OFF, do not install without consent
			_do_install=false
		elif [[ -f "$wrapper_script" ]]; then
			# Interactive: prompt with default-no
			# All user-facing output goes to stderr so $() captures only the result
			local enable_pulse=""
			echo "" >&2
			echo "The supervisor pulse enables autonomous orchestration." >&2
			echo "It will act under your GitHub identity and consume API credits:" >&2
			echo "  - Dispatches AI workers to implement tasks from GitHub issues" >&2
			echo "  - Creates PRs, merges passing PRs, files improvement issues" >&2
			echo "  - 4-hourly strategic review (thinking-tier) for queue health" >&2
			echo "  - Circuit breaker pauses dispatch on consecutive failures" >&2
			echo "" >&2
			setup_prompt enable_pulse "Enable supervisor pulse? [y/N]: " "n"
			if [[ "$enable_pulse" =~ ^[Yy]$ ]]; then
				_do_install=true
				# Record explicit consent
				if type cmd_set &>/dev/null; then
					cmd_set "orchestration.supervisor_pulse" "true" || true
				fi
			else
				_do_install=false
				# Record explicit decline so we never re-prompt on updates
				if type cmd_set &>/dev/null; then
					cmd_set "orchestration.supervisor_pulse" "false" || true
				fi
				print_info "Skipped. Enable later: aidevops config set orchestration.supervisor_pulse true && ./setup.sh" >&2
			fi
		fi
	fi

	# Guard: wrapper must exist
	if [[ "$_do_install" == "true" && ! -f "$wrapper_script" ]]; then
		# Wrapper not deployed yet — skip (will install on next run after rsync)
		_do_install=false
	fi

	printf '%s' "$_do_install"
	return 0
}

# GH#17769: These functions are deprecated — model routing is now derived
# from the OAuth pool + routing table at runtime. Kept as no-ops for one
# release cycle in case external scripts call them.
_resolve_headless_models_override() {
	printf '%s' ""
	return 0
}

_resolve_pulse_model_override() {
	printf '%s' ""
	return 0
}

_is_pulse_installed() {
	local pulse_label="$1"

	if _scheduler_detect_installed \
		"Supervisor pulse" \
		"$pulse_label" \
		"" \
		"pulse-wrapper" \
		"" \
		"" \
		"" \
		"aidevops-supervisor-pulse"; then
		return 0
	fi

	return 1
}

# t2954: Sweep Node version manager install roots (nvm, volta, fnm) for
# an opencode binary. Linux runners overwhelmingly install Node via nvm,
# which the legacy fixed-paths sweep in step 4b misses entirely — the
# alex-solovyev runner (Apr 2026, 9-day dispatch outage) is the canonical
# failure mode. Most-recent Node version wins (sort -rV). Each candidate
# is product-validated when the validator is in scope; nvm/volta/fnm can
# all host either anomalyco/opencode (from `npm i -g opencode`) or the
# Anthropic claude CLI (from `npm i -g @anthropic-ai/claude-code`) under
# the same `opencode` bin name, so validation is mandatory.
# $1 = "1" if _setup_validate_opencode_binary is callable, else "0".
# Returns 0 + prints path on hit, 1 on miss.
_sweep_nvm_volta_fnm_for_opencode() {
	local _have_validator="${1:-0}"
	local _root _version_dir _candidate
	for _root in \
		"$HOME/.nvm/versions/node" \
		"$HOME/.volta/tools/image/node" \
		"$HOME/.local/share/fnm/node-versions"; do
		[[ -d "$_root" ]] || continue
		while IFS= read -r _version_dir; do
			# nvm + volta: <ver>/bin/opencode; fnm: <ver>/installation/bin/opencode
			for _candidate in \
				"$_version_dir/bin/opencode" \
				"$_version_dir/installation/bin/opencode"; do
				[[ -x "$_candidate" ]] || continue
				if [[ "$_have_validator" -eq 1 ]] && \
					! _setup_validate_opencode_binary "$_candidate"; then
					continue
				fi
				printf '%s' "$_candidate"
				return 0
			done
		done < <(find "$_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -rV)
	done
	return 1
}

# t2954: Legacy fixed-install-paths sweep for an opencode binary. Used as
# a last-resort discovery when persistence, runtime registry, live PATH,
# and the Node-version-manager sweep all came up empty. Every candidate
# is an OpenCode path only and is product-validated when the validator is
# in scope; Claude paths must never be returned as OPENCODE_BIN.
# $1 = "1" if _setup_validate_opencode_binary is callable, else "0".
# Returns 0 + prints path on hit, 1 on miss.
_sweep_legacy_install_paths_for_opencode() {
	local _have_validator="${1:-0}"
	local _candidate
	for _candidate in \
		/opt/homebrew/bin/opencode \
		/usr/local/bin/opencode \
		/home/linuxbrew/.linuxbrew/bin/opencode \
		"$HOME/.npm-global/bin/opencode" \
		"$HOME/.local/bin/opencode" \
		"$HOME/.bun/bin/opencode"; do
		[[ -x "$_candidate" ]] || continue
		if [[ "$_have_validator" -eq 1 ]] && \
			! _setup_validate_opencode_binary "$_candidate"; then
			continue
		fi
		printf '%s' "$_candidate"
		return 0
	done
	return 1
}

_pulse_validate_opencode_candidate() {
	local _candidate="${1:-}" _have_validator="${2:-0}"
	[[ -n "$_candidate" ]] && [[ -x "$_candidate" ]] || return 1
	if [[ "$_have_validator" -eq 1 ]] && \
		! _setup_validate_opencode_binary "$_candidate"; then
		return 1
	fi
	printf '%s' "$_candidate"
	return 0
}

# t2954: Persist a resolved runtime path with product validation. Persisting
# an unvalidated path is exactly how the alex-solovyev runner locked in
# its 9-day dispatch outage — claude was persisted as OPENCODE_BIN and
# every subsequent canary fired `config_error` against the 1h negative
# cache. With validation, a wrong-product result silently no-ops the
# write and the next resolver run gets a fresh shot at finding a real
# opencode binary.
# $1 = path to persist; $2 = persistence file path; $3 = "1"/"0" validator-available flag.
_persist_pulse_runtime_path() {
	local _bin="${1:-}" _file="${2:-}" _have_validator="${3:-0}"
	[[ -n "$_bin" ]] && [[ -x "$_bin" ]] || return 0
	if [[ "$_have_validator" -eq 1 ]]; then
		_setup_validate_opencode_binary "$_bin" || return 0
	fi
	mkdir -p "$(dirname "$_file")" 2>/dev/null || true
	printf '%s\n' "$_bin" >"$_file" 2>/dev/null || true
	return 0
}

_pulse_clear_canary_negative_cache() {
	local _state_dir="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
	rm -f "${_state_dir}/canary-last-fail" "${_state_dir}/canary-last-fail.reason" 2>/dev/null || true
	return 0
}

_pulse_daemon_path_for_opencode() {
	local _opencode_bin="${1:-}"
	local _opencode_dir=""
	local _path=""

	if [[ -n "$_opencode_bin" ]]; then
		_opencode_dir=$(dirname "$_opencode_bin" || printf '')
		[[ "$_opencode_dir" == /* ]] || _opencode_dir=""
	fi
	_path="${HOME}/.local/bin:${HOME}/.aidevops/agents/scripts${_opencode_dir:+:$_opencode_dir}:/usr/local/bin:/usr/bin:/bin"
	printf '%s' "$_path"
	return 0
}

_pulse_normalize_opencode_binary() {
	local _opencode_bin="${1:-}"
	local _normalized="$_opencode_bin"

	[[ -n "$_opencode_bin" ]] || return 1
	if declare -F _setup_ensure_opencode_stable_shim >/dev/null 2>&1; then
		_normalized=$(_setup_ensure_opencode_stable_shim "$_opencode_bin" 2>/dev/null || printf '%s' "$_opencode_bin")
	elif [[ "$_opencode_bin" == "${HOME}/.local/bin/opencode" ]]; then
		_pulse_clear_canary_negative_cache
	fi
	printf '%s' "$_normalized"
	return 0
}

_pulse_extract_login_shell_opencode_binary() {
	local _line=""
	local _opencode_bin=""

	while IFS= read -r _line; do
		case "$_line" in
			__AIDEVOPS_OPENCODE__/*) _opencode_bin="${_line#__AIDEVOPS_OPENCODE__}" ;;
		esac
	done
	printf '%s' "$_opencode_bin"
	return 0
}

_pulse_write_direct_opencode_shim() {
	local _opencode_bin="${1:-}"
	local _home="${HOME:-}"
	local _shim_dir="${_home:+$_home/.local/bin}"
	local _shim_path="${_shim_dir:+$_shim_dir/opencode}"
	local _shim_tmp=""
	local _opencode_dir=""

	[[ -n "$_home" ]] || return 1
	[[ -n "$_opencode_bin" && -x "$_opencode_bin" ]] || return 1
	_opencode_dir=$(dirname "$_opencode_bin")
	mkdir -p "$_shim_dir" || return 1
	_shim_tmp=$(mktemp "${_shim_path}.tmp.XXXXXX") || return 1
	if ! cat >"$_shim_tmp" <<EOF
#!/usr/bin/env bash
# Generated by aidevops setup: daemon-safe OpenCode shim.
# aidevops:terminal-title-owner
export PATH="${_opencode_dir}\${HOME:+:\$HOME/.local/bin}\${HOME:+:\$HOME/.aidevops/agents/scripts}:/usr/local/bin:/usr/bin:/bin\${PATH:+:\$PATH}"
export AIDEVOPS_TERMINAL_TITLE_OWNER="\${AIDEVOPS_TERMINAL_TITLE_OWNER:-aidevops}"
if [[ "\$AIDEVOPS_TERMINAL_TITLE_OWNER" == "aidevops" ]]; then
	export OPENCODE_DISABLE_TERMINAL_TITLE="\${OPENCODE_DISABLE_TERMINAL_TITLE:-1}"
fi
exec "$_opencode_bin" "\$@"
EOF
	then
		rm -f "$_shim_tmp"
		return 1
	fi
	chmod +x "$_shim_tmp" || {
		rm -f "$_shim_tmp"
		return 1
	}
	mv -f "$_shim_tmp" "$_shim_path" || {
		rm -f "$_shim_tmp"
		return 1
	}
	printf '%s' "$_shim_path"
	return 0
}

_resolve_pulse_runtime_binary() {
	# GH#18439 + t2954. Persist the resolved binary across setup.sh
	# invocations so aidevops-auto-update.timer (systemd minimal PATH)
	# does not silently regenerate cron with the legacy macOS fallback,
	# AND validate every accepted candidate so the wrong product (claude
	# CLI under the opencode bin name) cannot silently take the slot.
	local _home="${HOME:-}"
	local _persisted_file="${_home}/.config/aidevops/scheduler-runtime-bin"
	local opencode_bin=""
	local _explicit_opencode_bin="${OPENCODE_BIN:-}"
	local _have_validator=0
	[[ -n "$_home" ]] || return 1
	declare -F _setup_validate_opencode_binary >/dev/null 2>&1 && _have_validator=1

	# Setup can be invoked by a systemd auto-update process whose PATH omits
	# nvm/fnm/volta. Prefer the current interactive shell's explicit OpenCode
	# path when it is supplied, then persist the daemon-safe shim below.
	if [[ -n "$_explicit_opencode_bin" ]]; then
		opencode_bin=$(_pulse_validate_opencode_candidate "$_explicit_opencode_bin" "$_have_validator" || true)
	fi

	# 1. Persisted path (validated). Drop+re-resolve on validation failure.
	if [[ -z "$opencode_bin" && -f "$_persisted_file" ]]; then
		local _persisted
		_persisted=$(head -n1 "$_persisted_file" 2>/dev/null || true)
		if [[ -n "$_persisted" ]] && [[ -x "$_persisted" ]]; then
			if [[ "$_have_validator" -eq 0 ]] || \
				_setup_validate_opencode_binary "$_persisted"; then
				printf '%s' "$_persisted"
				return 0
			fi
		fi
	fi

	# 2. Runtime-registry lookup via live PATH.
	if type rt_list_headless &>/dev/null; then
		local _sched_rt_id="" _sched_bin=""
		while IFS= read -r _sched_rt_id; do
			_sched_bin=$(rt_binary "$_sched_rt_id") || continue
			if [[ -n "$_sched_bin" ]] && command -v "$_sched_bin" &>/dev/null; then
				opencode_bin=$(_pulse_validate_opencode_candidate "$(command -v "$_sched_bin")" "$_have_validator" || true)
				[[ -n "$opencode_bin" ]] && break
			fi
		done < <(rt_list_headless)
	fi

	# 3. Direct PATH lookup. Wrong-product binaries are rejected so discovery
	# can continue to Node-version-manager and fixed OpenCode-only paths.
	if [[ -z "$opencode_bin" ]] && command -v opencode &>/dev/null; then
		opencode_bin=$(_pulse_validate_opencode_candidate "$(command -v opencode)" "$_have_validator" || true)
	fi

	# setup_opencode_cli can refresh the NVM installation after this module was
	# sourced. Ask a login shell once before filesystem sweeps so the resolver
	# sees the same OpenCode binary as an interactive user even under systemd's
	# minimal PATH.
	if [[ -z "$opencode_bin" ]]; then
		local _login_shell_bin=""
		_login_shell_bin=$(
			/bin/bash -lc 'printf "__AIDEVOPS_OPENCODE__%s\n" "$(command -v opencode || true)"' |
				_pulse_extract_login_shell_opencode_binary || true
		)
		opencode_bin=$(_pulse_validate_opencode_candidate "$_login_shell_bin" "$_have_validator" || true)
	fi

	# 4a. Node version manager sweep (nvm, volta, fnm). Linux-friendly.
	[[ -z "$opencode_bin" ]] && opencode_bin=$(_sweep_nvm_volta_fnm_for_opencode "$_have_validator" || true)

	# 4b. Legacy fixed-install-paths sweep (Homebrew, npm-global, bun, .local/bin).
	[[ -z "$opencode_bin" ]] && opencode_bin=$(_sweep_legacy_install_paths_for_opencode "$_have_validator" || true)

	# Prefer the daemon-visible stable shim when setup can create/validate it.
	# This keeps systemd workers off nvm/fnm/volta internals while preserving
	# those managers' node binary on the wrapper PATH.
	if [[ -n "$opencode_bin" ]]; then
		opencode_bin=$(_pulse_normalize_opencode_binary "$opencode_bin" || printf '%s' "$opencode_bin")
		if [[ "$opencode_bin" != "${_home}/.local/bin/opencode" ]]; then
			opencode_bin=$(_pulse_write_direct_opencode_shim "$opencode_bin" || printf '%s' "$opencode_bin")
		fi
	fi

	# Persist (validated). Wrong-product results silently no-op the write.
	_persist_pulse_runtime_path "$opencode_bin" "$_persisted_file" "$_have_validator"

	printf '%s' "$opencode_bin"
	return 0
}

_build_pulse_linux_env() {
	# GH#17546/GH#17769: Model config is derived from pool + routing table at
	# runtime. No model env vars embedded in cron/systemd.
	local opencode_bin="${1:-}"
	local _pulse_env="PULSE_DIR=${HOME}/.aidevops/.agent-workspace
PULSE_STALE_THRESHOLD=${PULSE_STALE_THRESHOLD_SECONDS}
AIDEVOPS_PULSE_ASYNC_POST_DISPATCH_HOUSEKEEPING=0"

	# GH#18439 Bug 2: embed resolved runtime binary path so pulse-wrapper.sh
	# and headless-runtime-helper.sh find the correct binary under systemd's
	# minimal PATH (e.g. when aidevops-auto-update.timer regenerates the
	# service file). Mirrors the macOS launchd <OPENCODE_BIN> key.
	if [[ -n "$opencode_bin" ]]; then
		_pulse_env+=$'\n'"OPENCODE_BIN=${opencode_bin}"
	fi
	_pulse_env+=$'\n'"PATH=$(_pulse_daemon_path_for_opencode "$opencode_bin")"

	printf '%s' "$_pulse_env"
	return 0
}

# Read orchestration.pulse_interval_seconds from settings.json.
# Falls back to legacy supervisor.pulse_interval_seconds, then 180, when the
# file is missing, the key is absent, or jq is unavailable.
# Clamps to the validated range [30, 3600].
# GH#18018: previously this was hardcoded as "120" in _install_supervisor_pulse.
# t2744: default raised 120 → 180 to reduce GraphQL pressure (33% fewer cycles)
#        on multi-repo setups where per-cycle cost chronically exceeds 5000/hr.
_read_pulse_interval_seconds() {
	local _settings_file="$HOME/.config/aidevops/settings.json"
	local _interval=180

	if command -v jq >/dev/null 2>&1 && [[ -f "$_settings_file" ]]; then
		local _raw
		_raw=$(jq -r '.orchestration.pulse_interval_seconds // .supervisor.pulse_interval_seconds // empty' "$_settings_file" 2>/dev/null) || _raw=""
		if [[ -n "$_raw" ]] && [[ "$_raw" =~ ^[0-9]+$ ]]; then
			_interval="$_raw"
		fi
	fi

	# Clamp to validated range (mirrors settings-helper.sh validation: 30-3600)
	if [[ "$_interval" -lt 30 ]]; then
		_interval=30
	elif [[ "$_interval" -gt 3600 ]]; then
		_interval=3600
	fi

	printf '%d' "$_interval"
	return 0
}

# Convert an interval in seconds to a cron schedule expression (e.g. "*/2 * * * *").
# Minimum granularity is 1 minute. Intervals that don't divide evenly into minutes
# are rounded down to whole minutes with a warning.
# Args: $1 = interval_seconds
_seconds_to_cron_schedule() {
	local _interval_sec="$1"
	local _minutes=$((_interval_sec / 60))
	local _remainder=$((_interval_sec % 60))

	# Clamp to at least 1 minute
	if [[ "$_minutes" -lt 1 ]]; then
		_minutes=1
	fi

	# Warn if interval doesn't divide evenly into minutes
	if [[ "$_remainder" -ne 0 ]]; then
		echo "[schedulers] Warning: pulse_interval_seconds=${_interval_sec} does not divide evenly into minutes; rounding down to ${_minutes}min for cron schedule (systemd uses exact seconds)" >&2
	fi

	# cron step values must be 1-59; */60 is invalid. Use @hourly for exactly 60 min,
	# clamp anything above 59 to 59 (the _read_pulse_interval_seconds cap is 3600s=60min).
	if [[ "$_minutes" -ge 60 ]]; then
		printf '@hourly'
	else
		printf '*/%d * * * *' "$_minutes"
	fi
	return 0
}

_install_supervisor_pulse() {
	local _os="$1"
	local pulse_label="$2"
	local wrapper_script="$3"
	local opencode_bin="$4"
	local _pulse_installed="$5"

	mkdir -p "$HOME/.aidevops/logs"

	if [[ "$_os" == "Darwin" ]]; then
		_install_pulse_launchd "$pulse_label" "$wrapper_script" "$opencode_bin" "$_pulse_installed"
		return 0
	fi

	# GH#18018: read user-configured interval instead of hardcoding 120s / */2 cron
	local _pulse_interval_sec
	_pulse_interval_sec=$(_read_pulse_interval_seconds)
	local _pulse_cron_schedule
	_pulse_cron_schedule=$(_seconds_to_cron_schedule "$_pulse_interval_sec")
	# Build a human-readable interval label: show minutes for exact multiples of 60, seconds otherwise
	local _pulse_interval_label
	if (( _pulse_interval_sec % 60 == 0 )); then
		_pulse_interval_label="$((_pulse_interval_sec / 60)) min"
	else
		_pulse_interval_label="${_pulse_interval_sec}s"
	fi

	local _pulse_timeout_sec=$((PULSE_STALE_THRESHOLD_SECONDS + 60))
	local _pulse_env=""
	# GH#18439 Bug 2: thread resolved runtime binary path through to the
	# Linux env builder so OPENCODE_BIN is embedded in the systemd service
	# file (parity with the macOS launchd plist at line 415).
	_pulse_env=$(_build_pulse_linux_env "$opencode_bin")
	_install_scheduler_linux \
		"aidevops-supervisor-pulse" \
		"aidevops: supervisor-pulse" \
		"${_pulse_cron_schedule}" \
		"\"${wrapper_script}\"" \
		"${_pulse_interval_sec}" \
		"$HOME/.aidevops/logs/pulse-wrapper.log" \
		"$_pulse_env" \
		"Supervisor pulse enabled (every ${_pulse_interval_label})" \
		"Failed to install supervisor pulse scheduler. See runners.md for manual setup." \
		"true" \
		"false" \
		"" \
		"${_pulse_timeout_sec}"
	return 0
}

# Setup the supervisor pulse scheduler (consent-gated autonomous orchestration).
# Uses pulse-wrapper.sh which handles dedup, orphan cleanup, and RAM-based concurrency.
# macOS: launchd plist invoking wrapper | Linux: cron entry invoking wrapper
# The plist is ALWAYS regenerated on setup.sh to pick up config changes (env vars,
# thresholds). Only the first-install prompt is gated on consent state.
#######################################
# t2119: Record the schedulers.sh template hash to the shared state
# directory. auto-update-helper.sh's check_launchd_plist_drift compares
# this against the current hash on every update cycle — whenever
# schedulers.sh changes without a VERSION bump (PR #19079 scenario),
# drift is detected and setup.sh --non-interactive is re-run to
# regenerate the installed plists.
#
# Called from setup_supervisor_pulse unconditionally so the hash is
# kept current on every setup.sh run, whether pulse is installed,
# upgraded, or disabled. Whole-file hash is the simplest signal that
# any plist-generating change has occurred.
#######################################
_schedulers_record_template_hash() {
	local state_dir="$HOME/.aidevops/.agent-workspace/tmp"
	mkdir -p "$state_dir" 2>/dev/null || return 0
	local hash_file="$state_dir/schedulers-template-hash.state"
	local schedulers_src="${BASH_SOURCE[0]:-}"
	[[ -f "$schedulers_src" ]] || return 0
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$schedulers_src" 2>/dev/null | awk '{print $1}' >"$hash_file" 2>/dev/null || true
	elif command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$schedulers_src" 2>/dev/null | awk '{print $1}' >"$hash_file" 2>/dev/null || true
	fi
	return 0
}

_pulse_runtime_pin_preserves_scheduler() {
	local pulse_installed="$1"
	local pinned_root=""
	local pin_rc=0
	declare -F pulse_runtime_pin_resolve >/dev/null 2>&1 || return 1
	pinned_root=$(pulse_runtime_pin_resolve 2>/dev/null) || pin_rc=$?
	case "$pin_rc" in
	0)
		[[ "${AIDEVOPS_PULSE_RUNTIME_PIN_REFRESH_SCHEDULERS:-0}" != "1" ]] || return 1
		[[ -n "$pinned_root" && "$pulse_installed" == "true" ]] || return 1
		return 0
		;;
	1 | 3) return 1 ;;
	*) return 2 ;;
	esac
	return 1
}

setup_supervisor_pulse() {
	local _os="$1"

	# Record template hash so auto-update can detect drift between
	# schedulers.sh and the installed plists on macOS (t2119).
	_schedulers_record_template_hash

	# Ensure crontab has a global PATH= line (Linux only; macOS uses launchd env).
	# Must run before any cron entries are installed so they inherit the PATH.
	if [[ "$_os" != "Darwin" ]]; then
		_ensure_cron_path
		_reconcile_linux_scheduler_duplicates
	fi

	# Consent model (GH#2926):
	#   - Default OFF: supervisor_pulse defaults to false in all config layers
	#   - Explicit consent required: user must type "y" (prompt defaults to [y/N])
	#   - Consent persisted: written to config.jsonc so it survives updates
	#   - Never silently re-enabled: if config says false, skip entirely
	#   - Non-interactive: only installs if config explicitly says true
	local wrapper_script="$HOME/.aidevops/agents/scripts/pulse-wrapper.sh"
	local pulse_label="com.aidevops.aidevops-supervisor-pulse"

	local _pulse_user_config
	_pulse_user_config=$(_resolve_pulse_consent)

	local _do_install
	_do_install=$(_determine_pulse_install "$_pulse_user_config" "$wrapper_script")

	local _pulse_lower
	_pulse_lower=$(echo "$_pulse_user_config" | tr '[:upper:]' '[:lower:]')

	# Detect if pulse is already installed (for upgrade messaging)
	# Uses shared helper to check launchd, cron, and systemd (GH#17381)
	local _pulse_installed=false
	local _pin_scheduler_rc=0
	if _is_pulse_installed "$pulse_label"; then
		_pulse_installed=true
	fi

	# Detect dispatch backend binary location (t1665.5 — registry-driven)
	local opencode_bin=""
	opencode_bin=$(_resolve_pulse_runtime_binary)

	if [[ "$_do_install" == "true" ]]; then
		_pulse_runtime_pin_preserves_scheduler "$_pulse_installed" || _pin_scheduler_rc=$?
		if [[ "$_pin_scheduler_rc" -eq 0 ]]; then
			print_info "Supervisor pulse scheduler preserved while its bounded runtime pin is active"
		elif [[ "$_pin_scheduler_rc" -eq 1 ]]; then
			_install_supervisor_pulse "$_os" "$pulse_label" "$wrapper_script" "$opencode_bin" "$_pulse_installed"
		else
			print_error "Supervisor pulse scheduler refused an invalid runtime pin"
			return 1
		fi
	elif [[ "$_pulse_lower" == "false" && "$_pulse_installed" == "true" ]]; then
		# User explicitly disabled but pulse is still installed — clean up
		_uninstall_pulse "$_os" "$pulse_label"
	fi

	# Export effective pulse state for setup_stats_wrapper.
	# Use the actual install decision (_do_install), not just the consent string,
	# so stats wrapper tracks the real scheduler state (e.g., wrapper missing → false).
	PULSE_CONSENT_LOWER="$_pulse_lower"
	if [[ "$_do_install" == "true" ]]; then
		PULSE_ENABLED="true"
	else
		PULSE_ENABLED="false"
	fi
	return 0
}

# Clean up old/legacy pulse launchd plists before reinstalling.
# Args: $1=pulse_label, $2=pulse_plist path
_cleanup_old_pulse_plists() {
	local pulse_label="$1"
	local pulse_plist="$2"

	# Unload old plist if upgrading
	if _launchd_has_agent "$pulse_label"; then
		launchctl unload "$pulse_plist" || true
		pkill -f 'Supervisor Pulse' 2>/dev/null || true
	fi

	# Also clean up old label if present
	local old_plist="$HOME/Library/LaunchAgents/com.aidevops.supervisor-pulse.plist"
	if [[ -f "$old_plist" ]]; then
		launchctl unload "$old_plist" || true
		rm -f "$old_plist"
	fi
	return 0
}

# Build XML environment variable fragment for headless model overrides.
# GH#17546: Model config was removed from plist embedding.
# GH#17769: Model routing is now derived from pool + routing table at runtime.
# No env vars needed — pulse-wrapper.sh reads the routing table directly.
_build_pulse_headless_env_xml() {
	# Intentionally empty — model config read from credentials.sh at runtime.
	printf '%s' ""
	return 0
}

# Log which env var overrides were injected from plist-env-overrides.json for a label.
# Prints to stdout (setup.sh output). No-op when file absent or label not found.
# Args: $1=plist_label, $2=override_file (optional)
_log_plist_env_overrides() {
	local _label="$1"
	local _override_file="${2:-}"
	[[ -n "$_override_file" ]] || _override_file=$(_plist_env_overrides_file)

	[[ -f "$_override_file" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	jq empty "$_override_file" 2>/dev/null || return 0

	local _keys
	_keys=$(jq -r --arg label "$_label" '
		.[$label] // {} |
		keys[] |
		select(startswith("_") | not)
	' "$_override_file" 2>/dev/null) || return 0

	[[ -z "$_keys" ]] && return 0

	local _count
	_count=$(echo "$_keys" | wc -l | tr -d ' ')
	local _keys_inline
	_keys_inline=$(echo "$_keys" | tr '\n' ' ' | sed 's/ $//')
	print_info "  plist-env-overrides: injected ${_count} var(s) into ${_label}: ${_keys_inline}"
	return 0
}

# Generate the full pulse launchd plist XML content.
# Args: $1=pulse_label, $2=wrapper_script, $3=opencode_bin
# Prints the complete plist XML to stdout.
#
# StartInterval is read from supervisor.pulse_interval_seconds in
# settings.json via _read_pulse_interval_seconds (default 180 — t2744).
# Previously this was hardcoded as 120, meaning macOS users could not
# tune the pulse cadence via settings (Linux/cron path always honoured
# the setting). The hardcoding is now removed; the macOS path matches
# the Linux path's behaviour.
_generate_pulse_plist_content() {
	local pulse_label="$1"
	local wrapper_script="$2"
	local opencode_bin="$3"

	# XML-escape paths for safe plist embedding (prevents injection
	# if $HOME or paths contain &, <, > characters)
	local _xml_wrapper_script _xml_home _xml_opencode_bin _xml_pulse_dir _xml_path
	_xml_wrapper_script=$(_xml_escape "$wrapper_script")
	_xml_home=$(_xml_escape "$HOME")
	_xml_opencode_bin=$(_xml_escape "$opencode_bin")
	# Use neutral workspace path for PULSE_DIR so supervisor sessions
	# are not associated with any specific managed repo (GH#5136).
	_xml_pulse_dir=$(_xml_escape "${HOME}/.aidevops/.agent-workspace")
	_xml_path=$(_xml_escape "$(aidevops_launchd_sanitized_path "$PATH")")

	local _headless_xml_env
	_headless_xml_env=$(_build_pulse_headless_env_xml)

	# Resolve modern bash for ProgramArguments — launchd bypasses shebangs
	# when an explicit interpreter is specified. (GH#19632 / t2176)
	local _xml_bash_bin
	_xml_bash_bin=$(_xml_escape "$(_resolve_modern_bash)")

	# Resolve the configured pulse interval (settings.json, with default).
	# Already validated to [30, 3600] inside _read_pulse_interval_seconds.
	local _pulse_interval_sec
	_pulse_interval_sec=$(_read_pulse_interval_seconds)

	# Inject user-owned plist env overrides (GH#20563 / t2759).
	# Reads ~/.config/aidevops/plist-env-overrides.json when present.
	# A legacy bundle-local file remains readable until setup migrates it.
	# Missing file or label not found → emits nothing (no-op, safe default).
	local _env_overrides_xml
	_env_overrides_xml=$(_build_plist_env_overrides_xml "$pulse_label")

	cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${pulse_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${_xml_bash_bin}</string>
		<string>${_xml_wrapper_script}</string>
	</array>
	<key>StartInterval</key>
	<integer>${_pulse_interval_sec}</integer>
	<key>StandardOutPath</key>
	<string>${_xml_home}/.aidevops/logs/pulse-wrapper.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_home}/.aidevops/logs/pulse-wrapper.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>${_xml_path}</string>
		<key>HOME</key>
		<string>${_xml_home}</string>
		<key>OPENCODE_BIN</key>
		<string>${_xml_opencode_bin}</string>
		<key>PULSE_DIR</key>
		<string>${_xml_pulse_dir}</string>
		<key>PULSE_STALE_THRESHOLD</key>
		<string>${PULSE_STALE_THRESHOLD_SECONDS}</string>
		${_headless_xml_env}
${_env_overrides_xml}	</dict>
	<key>SoftResourceLimits</key>
	<dict>
		<key>NumberOfFiles</key>
		<integer>4096</integer>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ThrottleInterval</key>
	<integer>30</integer>
</dict>
</plist>
PLIST
	return 0
}

# Install supervisor pulse via launchd (macOS)
_install_pulse_launchd() {
	local pulse_label="$1"
	local wrapper_script="$2"
	local opencode_bin="$3"
	local _pulse_installed="$4"
	local pulse_plist="$HOME/Library/LaunchAgents/${pulse_label}.plist"

	# Capture plist content before touching the existing file.
	# This avoids the "unload old, then write fails" window that leaves a 0-byte plist.
	local pulse_plist_content
	pulse_plist_content=$(_generate_pulse_plist_content "$pulse_label" "$wrapper_script" "$opencode_bin")

	# Defensive: if generation produced empty content, refuse to touch the existing plist.
	if [[ -z "$pulse_plist_content" ]]; then
		print_warning "Pulse plist generation produced empty content — leaving existing plist untouched"
		return 1
	fi

	# Resolve interval for the user-facing message (matches what the plist contains).
	local _interval_sec _interval_label
	_interval_sec=$(_read_pulse_interval_seconds)
	if (( _interval_sec % 60 == 0 )); then
		_interval_label="$((_interval_sec / 60)) min"
	else
		_interval_label="${_interval_sec}s"
	fi

	# One-time legacy cleanup: unload and remove the old-label plist if present.
	# Users on stale installs may have com.aidevops.supervisor-pulse (legacy) and
	# com.aidevops.aidevops-supervisor-pulse (current) both loaded, causing 2x
	# dispatch.  Only targets the hardcoded legacy path; idempotent — no-op when
	# the legacy file is absent.
	local _legacy_plist="$HOME/Library/LaunchAgents/com.aidevops.supervisor-pulse.plist"
	if [[ -f "$_legacy_plist" ]]; then
		launchctl unload "$_legacy_plist" 2>/dev/null || true
		rm -f "$_legacy_plist"
	fi

	# _launchd_install_if_changed handles unload-before-replace only when content
	# has changed, and writes atomically via tmp+rename (see setup.sh).
	# shell-portability: ignore next — _install_pulse_launchd is macOS-only (launchd)
	if _launchd_install_if_changed "$pulse_label" "$pulse_plist" "$pulse_plist_content"; then
		if [[ "$_pulse_installed" == "true" ]]; then
			print_info "Supervisor pulse updated (launchd config regenerated, every ${_interval_label})"
		else
			print_info "Supervisor pulse enabled (launchd, every ${_interval_label})"
		fi
		# Log any user-provided env var overrides that were injected (GH#20563 / t2759)
		_log_plist_env_overrides "$pulse_label"
	else
		print_warning "Failed to load supervisor pulse LaunchAgent"
	fi
	return 0
}

# Generate the pulse-watchdog launchd plist XML content.
# Args: $1=label, $2=tick_script, $3=bash_bin
# Prints the complete plist XML to stdout.
#
# The watchdog is an independent launchd job that runs every 60s and revives
# pulse if it has been dead longer than (StartInterval + grace). Layered
# defense alongside the pulse plist's KeepAlive=<dict><SuccessfulExit=false>
# (auto-restart on crash) and StartInterval (scheduled cadence). Catches the
# "clean exit + lost launchd schedule" failure mode that no other layer covers.
# (t2939)
_generate_pulse_watchdog_plist_content() {
	local watchdog_label="$1"
	local tick_script="$2"
	local bash_bin="$3"

	local _xml_label _xml_tick _xml_bash _xml_home _xml_path
	_xml_label=$(_xml_escape "$watchdog_label")
	_xml_tick=$(_xml_escape "$tick_script")
	_xml_bash=$(_xml_escape "$bash_bin")
	_xml_home=$(_xml_escape "$HOME")
	_xml_path=$(_xml_escape "$(aidevops_launchd_sanitized_path "$PATH")")

	cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${_xml_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${_xml_bash}</string>
		<string>${_xml_tick}</string>
	</array>
	<key>StartInterval</key>
	<integer>60</integer>
	<key>StandardOutPath</key>
	<string>${_xml_home}/.aidevops/logs/pulse-watchdog-launchd.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_home}/.aidevops/logs/pulse-watchdog-launchd.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>${_xml_path}</string>
		<key>HOME</key>
		<string>${_xml_home}</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ThrottleInterval</key>
	<integer>30</integer>
</dict>
</plist>
PLIST
	return 0
}

# Install the pulse-watchdog via launchd (macOS).
# t2939: independent revival mechanism — see _generate_pulse_watchdog_plist_content
# header for the layering rationale.
_install_pulse_watchdog_launchd() {
	local watchdog_label="sh.aidevops.pulse-watchdog"
	local tick_script="$HOME/.aidevops/agents/scripts/pulse-watchdog-tick.sh"
	local watchdog_plist="$HOME/Library/LaunchAgents/${watchdog_label}.plist"

	# Refuse to install if the tick script is missing — the watchdog would
	# fire-and-fail every 60s, polluting logs without doing useful work.
	if [[ ! -x "$tick_script" ]]; then
		print_warning "Pulse watchdog tick script missing or non-executable: $tick_script"
		return 1
	fi

	local _xml_bash_bin
	_xml_bash_bin=$(_resolve_modern_bash)

	local watchdog_plist_content
	watchdog_plist_content=$(_generate_pulse_watchdog_plist_content "$watchdog_label" "$tick_script" "$_xml_bash_bin")

	if [[ -z "$watchdog_plist_content" ]]; then
		print_warning "Pulse watchdog plist generation produced empty content — skipping"
		return 1
	fi

	# shell-portability: ignore next — _install_pulse_watchdog_launchd is macOS-only
	if _launchd_install_if_changed "$watchdog_label" "$watchdog_plist" "$watchdog_plist_content"; then
		print_info "Pulse watchdog enabled (launchd, every 60s)"
	else
		print_warning "Failed to load pulse watchdog LaunchAgent"
	fi
	return 0
}

# Install the pulse-watchdog via systemd (Linux).
# t2939: parallels _install_pulse_watchdog_launchd for systems with systemd --user.
_install_pulse_watchdog_systemd() {
	local tick_script="$HOME/.aidevops/agents/scripts/pulse-watchdog-tick.sh"
	local watchdog_systemd="aidevops-pulse-watchdog"
	local watchdog_log="$HOME/.aidevops/logs/pulse-watchdog-launchd.log"

	if [[ ! -x "$tick_script" ]]; then
		print_warning "Pulse watchdog tick script missing or non-executable: $tick_script"
		return 1
	fi

	# Reuse the standard scheduler installer (cron-fallback aware).
	# StartInterval=60 maps to every-minute cron schedule.
	# shell-portability: ignore next — _install_scheduler_linux is Linux-only
	_install_scheduler_linux \
		"$watchdog_systemd" \
		"aidevops: pulse-watchdog" \
		"$CRON_EVERY_MINUTE" \
		"\"${tick_script}\"" \
		"60" \
		"$watchdog_log" \
		"" \
		"Pulse watchdog enabled (every 60s)" \
		"Failed to install pulse watchdog scheduler" \
		"true" \
		"false"
	return 0
}

# Setup the pulse-watchdog scheduler (parallels setup_supervisor_pulse).
# t2939: layered defense — only installs when supervisor pulse is enabled,
# since a watchdog without a pulse to watch is a no-op every 60s.
#
# Args: $1 = pulse effective state ("true"/"false")
setup_pulse_watchdog() {
	local _pulse_effective="$1"
	local watchdog_label="sh.aidevops.pulse-watchdog"
	local watchdog_systemd="aidevops-pulse-watchdog"

	if [[ "$_pulse_effective" != "true" ]]; then
		# Pulse disabled — uninstall the watchdog if present.
		_uninstall_scheduler \
			"$(uname -s)" \
			"$watchdog_label" \
			"$watchdog_systemd" \
			"aidevops: pulse-watchdog" \
			"Pulse watchdog disabled (pulse is off)"
		return 0
	fi

	mkdir -p "$HOME/.aidevops/logs"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		_install_pulse_watchdog_launchd
	else
		_install_pulse_watchdog_systemd
	fi
	return 0
}
