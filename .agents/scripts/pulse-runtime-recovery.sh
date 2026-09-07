#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

# Bootstrap-time repair for a deployed Pulse bundle that is behind a clean,
# exact canonical main checkout. This file is sourced before Pulse acquires its
# runtime lease, allowing setup's atomic bundle transition to proceed safely.

[[ -n "${_AIDEVOPS_PULSE_RUNTIME_RECOVERY_LOADED:-}" ]] && return 0
_AIDEVOPS_PULSE_RUNTIME_RECOVERY_LOADED=1
PULSE_RUNTIME_RECOVERY_BLOCKED_STATUS="blocked"

_pulse_runtime_recovery_record() {
	local status="$1"
	local reason="$2"
	local canonical_sha="${3:-}"
	local deployed_sha="${4:-}"
	local state_file="${AIDEVOPS_PULSE_RUNTIME_RECOVERY_STATE_FILE:-${HOME}/.aidevops/cache/pulse-runtime-recovery.json}"
	local state_dir="${state_file%/*}"
	local temporary="${state_file}.$$"
	local recorded_epoch=""
	recorded_epoch=$(date +%s)

	mkdir -p "$state_dir" 2>/dev/null || return 0
	if command -v jq >/dev/null 2>&1; then
		jq -n --arg status "$status" --arg reason "$reason" \
			--arg canonical "$canonical_sha" --arg deployed "$deployed_sha" \
			--arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			--argjson epoch "$recorded_epoch" \
			'{schema:"aidevops-pulse-runtime-recovery/v1",status:$status,reason:$reason,canonical_sha:$canonical,deployed_sha:$deployed,recorded_at:$at,recorded_epoch:$epoch}' \
			>"$temporary" 2>/dev/null && mv "$temporary" "$state_file"
	else
		printf 'status=%s\nreason=%s\ncanonical_sha=%s\ndeployed_sha=%s\nrecorded_epoch=%s\n' \
			"$status" "$reason" "$canonical_sha" "$deployed_sha" "$recorded_epoch" >"$temporary" 2>/dev/null && mv "$temporary" "$state_file"
	fi
	rm -f "$temporary" 2>/dev/null || true
	return 0
}

_pulse_runtime_recovery_last_attempt_epoch() {
	local state_file="${AIDEVOPS_PULSE_RUNTIME_RECOVERY_STATE_FILE:-${HOME}/.aidevops/cache/pulse-runtime-recovery.json}"
	[[ -f "$state_file" ]] || {
		printf '0\n'
		return 0
	}
	if command -v jq >/dev/null 2>&1; then
		local recorded="" recorded_epoch=""
		recorded_epoch=$(jq -r '.recorded_epoch // 0' "$state_file" 2>/dev/null || true)
		if [[ "$recorded_epoch" =~ ^[0-9]+$ && "$recorded_epoch" -gt 0 ]]; then
			printf '%s\n' "$recorded_epoch"
			return 0
		fi
		recorded=$(jq -r '.recorded_at // ""' "$state_file" 2>/dev/null || true)
		if [[ -n "$recorded" ]]; then
			date -j -f '%Y-%m-%dT%H:%M:%SZ' "$recorded" +%s 2>/dev/null || date -d "$recorded" +%s 2>/dev/null || printf '0\n'
			return 0
		fi
	fi
	local key="" value=""
	while IFS='=' read -r key value; do
		if [[ "$key" == "recorded_epoch" && "$value" =~ ^[0-9]+$ ]]; then
			printf '%s\n' "$value"
			return 0
		fi
	done <"$state_file"
	printf '0\n'
	return 0
}

_pulse_runtime_recovery_run_setup() {
	local setup_script="$1"
	local timeout_seconds="${AIDEVOPS_PULSE_RUNTIME_RECOVERY_TIMEOUT_SECONDS:-240}"
	[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || timeout_seconds=240

	if command -v timeout >/dev/null 2>&1; then
		env -u AIDEVOPS_AGENTS_DIR -u AGENTS_DIR AIDEVOPS_NON_INTERACTIVE=true \
			timeout --signal=TERM --kill-after=15 "$timeout_seconds" bash "$setup_script" --stage ai-session
		return $?
	fi
	if command -v gtimeout >/dev/null 2>&1; then
		env -u AIDEVOPS_AGENTS_DIR -u AGENTS_DIR AIDEVOPS_NON_INTERACTIVE=true \
			gtimeout --signal=TERM --kill-after=15 "$timeout_seconds" bash "$setup_script" --stage ai-session
		return $?
	fi

	# macOS ships Perl even when GNU timeout is unavailable. alarm bounds the
	# setup owner; setup's own EXIT cleanup handles any interrupted transition.
	# Perl source is intentionally single-quoted.
	# shellcheck disable=SC2016
	env -u AIDEVOPS_AGENTS_DIR -u AGENTS_DIR AIDEVOPS_NON_INTERACTIVE=true \
		perl -e '$timeout=shift; $SIG{ALRM}=sub{kill "TERM", $$; exit 124}; alarm $timeout; exec @ARGV' \
		"$timeout_seconds" bash "$setup_script" --stage ai-session
	return $?
}

_pulse_runtime_recovery_acquire_lock() {
	local lock_dir="$1"
	local owner_pid="" lock_mtime="0" now="" grace="${AIDEVOPS_PULSE_RUNTIME_RECOVERY_OWNERLESS_GRACE_SECONDS:-300}"
	mkdir -p "${lock_dir%/*}" 2>/dev/null || return 1
	if mkdir "$lock_dir" 2>/dev/null; then
		printf '%s\n' "$$" >"${lock_dir}/pid" 2>/dev/null || {
			rmdir "$lock_dir" 2>/dev/null || true
			return 1
		}
		return 0
	fi
	if [[ -r "${lock_dir}/pid" ]]; then
		IFS= read -r owner_pid <"${lock_dir}/pid" || owner_pid=""
	fi
	if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
		return 1
	fi
	if [[ -z "$owner_pid" || ! "$owner_pid" =~ ^[0-9]+$ ]]; then
		[[ "$grace" =~ ^[0-9]+$ ]] || grace=300
		if declare -F _file_mtime_epoch >/dev/null 2>&1; then
			lock_mtime=$(_file_mtime_epoch "$lock_dir" 2>/dev/null || printf '0')
		fi
		now=$(date +%s)
		[[ "$lock_mtime" =~ ^[0-9]+$ ]] || lock_mtime=0
		((now - lock_mtime >= grace)) || return 1
	fi
	rm -f "${lock_dir}/pid" 2>/dev/null || return 1
	rmdir "$lock_dir" 2>/dev/null || return 1
	if mkdir "$lock_dir" 2>/dev/null; then
		printf '%s\n' "$$" >"${lock_dir}/pid" 2>/dev/null || {
			rmdir "$lock_dir" 2>/dev/null || true
			return 1
		}
		return 0
	fi
	return 1
}

pulse_runtime_recover_if_safe() {
	[[ "${AIDEVOPS_PULSE_RUNTIME_RECOVERY_ENABLED:-1}" == "1" ]] || return 0
	[[ "${AIDEVOPS_PULSE_RUNTIME_RECOVERY_ACTIVE:-0}" != "1" ]] || return 0
	case " ${*:-} " in
	*" --self-check "* | *" --dry-run "* | *" --canary "*) return 0 ;;
	esac

	local repo_path="${AIDEVOPS_REPO_PATH:-${HOME}/Git/aidevops}"
	local stamp_file="${AIDEVOPS_DEPLOYED_SHA_FILE:-${HOME}/.aidevops/.deployed-sha}"
	local setup_script="${repo_path}/setup.sh"
	local canonical_sha="" upstream_sha="" deployed_sha="" branch="" last_attempt="0"
	local now="" cooldown="${AIDEVOPS_PULSE_RUNTIME_RECOVERY_COOLDOWN_SECONDS:-3600}"
	local lock_dir="${AIDEVOPS_PULSE_RUNTIME_RECOVERY_LOCK_DIR:-${HOME}/.aidevops/cache/pulse-runtime-recovery.lock.d}"

	[[ -d "${repo_path}/.git" || -f "${repo_path}/.git" ]] || return 0
	[[ -r "$setup_script" && -r "$stamp_file" ]] || return 0
	canonical_sha=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || true)
	upstream_sha=$(git -C "$repo_path" rev-parse refs/remotes/origin/main 2>/dev/null || true)
	IFS= read -r deployed_sha <"$stamp_file" || deployed_sha=""
	deployed_sha="${deployed_sha//[[:space:]]/}"
	[[ "$canonical_sha" =~ ^[0-9a-fA-F]{7,64}$ && "$deployed_sha" =~ ^[0-9a-fA-F]{7,64}$ ]] || return 0
	[[ "$canonical_sha" != "$deployed_sha" ]] || return 0

	branch=$(git -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	if [[ "$branch" != "main" ]]; then
		_pulse_runtime_recovery_record "$PULSE_RUNTIME_RECOVERY_BLOCKED_STATUS" "canonical_non_main" "$canonical_sha" "$deployed_sha"
		return 0
	fi
	if [[ ! "$upstream_sha" =~ ^[0-9a-fA-F]{7,64}$ || "$canonical_sha" != "$upstream_sha" ]]; then
		_pulse_runtime_recovery_record "$PULSE_RUNTIME_RECOVERY_BLOCKED_STATUS" "canonical_not_exact_origin_main" "$canonical_sha" "$deployed_sha"
		return 0
	fi
	if ! git -C "$repo_path" diff --quiet 2>/dev/null || ! git -C "$repo_path" diff --cached --quiet 2>/dev/null; then
		_pulse_runtime_recovery_record "$PULSE_RUNTIME_RECOVERY_BLOCKED_STATUS" "canonical_dirty" "$canonical_sha" "$deployed_sha"
		return 0
	fi
	if ! git -C "$repo_path" merge-base --is-ancestor "$deployed_sha" "$canonical_sha" 2>/dev/null; then
		_pulse_runtime_recovery_record "$PULSE_RUNTIME_RECOVERY_BLOCKED_STATUS" "deployment_not_ancestor" "$canonical_sha" "$deployed_sha"
		return 0
	fi
	if ! git -C "$repo_path" diff --name-only "$deployed_sha" "$canonical_sha" -- \
		.agents/scripts/ .agents/agents/ .agents/workflows/ .agents/prompts/ .agents/hooks/ setup.sh aidevops.sh 2>/dev/null | grep -q .; then
		return 0
	fi

	[[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=3600
	now=$(date +%s)
	last_attempt=$(_pulse_runtime_recovery_last_attempt_epoch)
	[[ "$last_attempt" =~ ^[0-9]+$ ]] || last_attempt=0
	if ((now - last_attempt < cooldown)); then
		return 0
	fi
	if ! _pulse_runtime_recovery_acquire_lock "$lock_dir"; then
		_pulse_runtime_recovery_record "deferred" "recovery_already_running" "$canonical_sha" "$deployed_sha"
		return 0
	fi
	trap 'rm -f "${lock_dir:-}/pid" 2>/dev/null || true; rmdir "${lock_dir:-}" 2>/dev/null || true' RETURN
	_pulse_runtime_recovery_record "attempting" "safe_canonical_deployment" "$canonical_sha" "$deployed_sha"

	local setup_rc=0
	AIDEVOPS_PULSE_RUNTIME_RECOVERY_ACTIVE=1 _pulse_runtime_recovery_run_setup "$setup_script" || setup_rc=$?
	if [[ "$setup_rc" -ne 0 ]]; then
		_pulse_runtime_recovery_record "$PULSE_RUNTIME_RECOVERY_BLOCKED_STATUS" "setup_failed_exit_${setup_rc}" "$canonical_sha" "$deployed_sha"
		return 0
	fi
	local activated_sha=""
	IFS= read -r activated_sha <"$stamp_file" || activated_sha=""
	activated_sha="${activated_sha//[[:space:]]/}"
	if [[ "$activated_sha" != "$canonical_sha" ]]; then
		_pulse_runtime_recovery_record "$PULSE_RUNTIME_RECOVERY_BLOCKED_STATUS" "activation_not_converged" "$canonical_sha" "$activated_sha"
		return 0
	fi
	_pulse_runtime_recovery_record "recovered" "activated_canonical_runtime" "$canonical_sha" "$deployed_sha"
	if [[ "${AIDEVOPS_PULSE_RUNTIME_RECOVERY_NO_REEXEC:-0}" != "1" && -x "${HOME}/.aidevops/agents/scripts/pulse-wrapper.sh" ]]; then
		rm -f "${lock_dir}/pid" 2>/dev/null || true
		rmdir "$lock_dir" 2>/dev/null || true
		export AIDEVOPS_PULSE_RUNTIME_RECOVERY_ACTIVE=1
		exec "${HOME}/.aidevops/agents/scripts/pulse-wrapper.sh" "$@"
	fi
	return 0
}
