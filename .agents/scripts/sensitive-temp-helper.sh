#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Managed Sensitive Temporary Artifact Helpers
# =============================================================================
# Creates private framework-owned temporary directories and starts detached
# cleanup guardians. Callers still remove artifacts synchronously; guardians
# cover SIGKILL/abrupt parent loss and enforce a bounded maximum lifetime.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_SENSITIVE_TEMP_HELPER_LOADED:-}" ]] && return 0
_SENSITIVE_TEMP_HELPER_LOADED=1
_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN="unknown"

_aidevops_sensitive_temp_reject() {
	local component="$1"
	local owner_uid="$2"
	local mode="$3"
	local reason="$4"
	printf '[sensitive-temp] rejected component=%q owner_uid=%s mode=%s reason=%s\n' \
		"$component" "${owner_uid:-$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN}" \
		"${mode:-$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN}" "$reason" >&2
	return 1
}

_aidevops_sensitive_temp_stat_owner_uid() {
	local path="$1"
	local owner_uid=""
	owner_uid=$(stat -c '%u' "$path" 2>/dev/null || true)
	if [[ ! "$owner_uid" =~ ^[0-9]+$ ]]; then
		owner_uid=$(stat -f '%u' "$path" 2>/dev/null || true)
	fi
	[[ "$owner_uid" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$owner_uid"
	return 0
}

_aidevops_sensitive_temp_stat_mode() {
	local path="$1"
	local bsd_format="$2"
	local mode=""
	mode=$(stat -c '%a' "$path" 2>/dev/null || true)
	if [[ ! "$mode" =~ ^[0-7]{3,6}$ ]]; then
		mode=$(stat -f "$bsd_format" "$path" 2>/dev/null || true)
	fi
	[[ "$mode" =~ ^[0-7]{3,6}$ ]] || return 1
	printf '%s\n' "$mode"
	return 0
}

_aidevops_sensitive_temp_physical_path_is_safe() {
	local candidate="$1"
	local remainder="${candidate#/}"
	local current=""
	local component=""
	local mode=""
	local owner_uid=""
	local current_uid=""
	local mode_value=0
	local is_final=0

	if [[ "$candidate" != /* || "$candidate" == "/" ]]; then
		_aidevops_sensitive_temp_reject "$candidate" "$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" \
			"$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" "absolute_non_root_path_required"
		return 1
	fi
	current_uid=$(id -u) || {
		_aidevops_sensitive_temp_reject "$candidate" "$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" \
			"$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" "current_uid_unavailable"
		return 1
	}
	while [[ -n "$remainder" ]]; do
		component="${remainder%%/*}"
		if [[ "$remainder" == */* ]]; then
			remainder="${remainder#*/}"
		else
			remainder=""
		fi
		if [[ -z "$component" || "$component" == "." || "$component" == ".." ]]; then
			_aidevops_sensitive_temp_reject "${current}/${component}" "$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" \
				"$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" "invalid_path_component"
			return 1
		fi
		current="${current}/${component}"
		if [[ ! -d "$current" || -L "$current" ]]; then
			_aidevops_sensitive_temp_reject "$current" "$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" \
				"$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" "missing_non_directory_or_symlink_component"
			return 1
		fi
		owner_uid=$(_aidevops_sensitive_temp_stat_owner_uid "$current") || {
			_aidevops_sensitive_temp_reject "$current" "$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" \
				"$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" "owner_stat_failed"
			return 1
		}
		# BSD %Lp omits special bits; %p retains the sticky bit (and file type).
		# GNU %a returns permission bits only. The masks below work for either.
		mode=$(_aidevops_sensitive_temp_stat_mode "$current" '%p') || {
			_aidevops_sensitive_temp_reject "$current" "$owner_uid" \
				"$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" "mode_stat_failed"
			return 1
		}
		if [[ ! "$owner_uid" =~ ^[0-9]+$ || ! "$mode" =~ ^[0-7]{3,6}$ ]]; then
			_aidevops_sensitive_temp_reject "$current" "$owner_uid" "$mode" "invalid_owner_or_mode"
			return 1
		fi
		if [[ "$owner_uid" != "0" && "$owner_uid" != "$current_uid" ]]; then
			_aidevops_sensitive_temp_reject "$current" "$owner_uid" "$mode" "foreign_owned_component"
			return 1
		fi
		mode_value=$((8#$mode))
		[[ -z "$remainder" ]] && is_final=1 || is_final=0
		if ((mode_value & 0022)); then
			if [[ "$is_final" -eq 1 ]]; then
				_aidevops_sensitive_temp_reject "$current" "$owner_uid" "$mode" "writable_sensitive_root"
				return 1
			fi
			if ! ((mode_value & 01000)); then
				_aidevops_sensitive_temp_reject "$current" "$owner_uid" "$mode" "writable_non_sticky_ancestor"
				return 1
			fi
		fi
	done
	return 0
}

aidevops_sensitive_temp_root() {
	# AIDEVOPS_TEMP_DIR is intentionally not used here: it is the collaborative
	# framework workspace and may legitimately inherit a group-friendly umask.
	# Sensitive runtime output instead uses a private sibling hierarchy whose
	# nearest mutable ancestor is created under umask 077.
	local configured_root="${AIDEVOPS_SENSITIVE_TEMP_DIR:-${HOME:?}/.aidevops-private/tmp}"
	local temp_root=""
	local owner_uid=""
	local current_uid=""
	local mode=""

	if [[ "$configured_root" != /* || "$configured_root" == "/" ]]; then
		_aidevops_sensitive_temp_reject "$configured_root" "$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" \
			"$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" "configured_root_must_be_absolute"
		return 1
	fi
	if [[ "$configured_root" == *$'\n'* || "$configured_root" == *$'\r'* || "$configured_root" == *$'\t'* ]]; then
		_aidevops_sensitive_temp_reject "$configured_root" "$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" \
			"$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" "configured_root_contains_control_character"
		return 1
	fi
	if [[ -L "$configured_root" ]]; then
		_aidevops_sensitive_temp_reject "$configured_root" "$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" \
			"$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" "configured_root_is_symlink"
		return 1
	fi
	(umask 077 && mkdir -p "$configured_root") || {
		_aidevops_sensitive_temp_reject "$configured_root" "$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" \
			"$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" "configured_root_creation_failed"
		return 1
	}
	if [[ ! -d "$configured_root" || -L "$configured_root" ]]; then
		_aidevops_sensitive_temp_reject "$configured_root" "$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" \
			"$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" "configured_root_not_private_directory"
		return 1
	fi
	temp_root=$(cd "$configured_root" 2>/dev/null && pwd -P) || {
		_aidevops_sensitive_temp_reject "$configured_root" "$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" \
			"$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" "configured_root_resolution_failed"
		return 1
	}
	_aidevops_sensitive_temp_physical_path_is_safe "$temp_root" || return 1
	current_uid=$(id -u) || {
		_aidevops_sensitive_temp_reject "$temp_root" "$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" \
			"$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" "current_uid_unavailable"
		return 1
	}
	owner_uid=$(_aidevops_sensitive_temp_stat_owner_uid "$temp_root") || {
		_aidevops_sensitive_temp_reject "$temp_root" "$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" \
			"$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" "owner_stat_failed"
		return 1
	}
	if [[ "$owner_uid" != "$current_uid" ]]; then
		_aidevops_sensitive_temp_reject "$temp_root" "$owner_uid" \
			"$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" "sensitive_root_not_current_user_owned"
		return 1
	fi
	chmod 700 "$temp_root" || {
		_aidevops_sensitive_temp_reject "$temp_root" "$owner_uid" \
			"$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" "sensitive_root_chmod_failed"
		return 1
	}
	mode=$(_aidevops_sensitive_temp_stat_mode "$temp_root" '%Lp') || {
		_aidevops_sensitive_temp_reject "$temp_root" "$owner_uid" \
			"$_AIDEVOPS_SENSITIVE_TEMP_UNKNOWN" "mode_stat_failed"
		return 1
	}
	if [[ "$mode" != "700" ]]; then
		_aidevops_sensitive_temp_reject "$temp_root" "$owner_uid" "$mode" "sensitive_root_mode_not_700"
		return 1
	fi
	printf '%s\n' "$temp_root"
	return 0
}

aidevops_sensitive_temp_create_dir() {
	local purpose="$1"
	local temp_root=""
	[[ "$purpose" =~ ^[a-z0-9-]+$ ]] || return 1
	temp_root=$(aidevops_sensitive_temp_root) || return 1
	(umask 077 && mktemp -d "${temp_root}/aidevops-${purpose}.XXXXXX") || return 1
	return 0
}

# Start a detached process that removes one managed path when its owner exits
# or the retention deadline expires. Only the path is passed to the guardian;
# artifact contents never enter argv, stdout, stderr, or logs.
aidevops_sensitive_temp_start_guardian() {
	local guarded_path="$1"
	local owner_pid="$2"
	local max_age_seconds="$3"
	local poll_seconds="$4"
	local managed_temp_root=""
	local guarded_parent="${guarded_path%/*}"
	local guarded_name="${guarded_path##*/}"
	managed_temp_root=$(aidevops_sensitive_temp_root) || return 1

	[[ "$guarded_path" == /* && "$guarded_parent" == "$managed_temp_root" ]] || return 1
	[[ "$guarded_name" == aidevops-* && "$guarded_name" != */* ]] || return 1
	[[ -e "$guarded_path" && ! -L "$guarded_path" ]] || return 1
	[[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || return 1
	[[ "$max_age_seconds" =~ ^[1-9][0-9]*$ ]] || return 1
	[[ "$poll_seconds" =~ ^[1-9][0-9]*$ ]] || return 1
	command -v python3 >/dev/null 2>&1 || return 1

	(
		exec python3 - "$guarded_path" "$owner_pid" "$max_age_seconds" "$poll_seconds" \
			"$managed_temp_root" </dev/null >/dev/null 2>&1 <<'PY'
import os
import shutil
import signal
import stat
import sys
import time

path, owner_text, max_age_text, poll_text, managed_root = sys.argv[1:]
owner_pid = int(owner_text)
max_age = int(max_age_text)
poll = int(poll_text)
parent = os.path.realpath(os.path.dirname(path))
name = os.path.basename(path)
if parent != os.path.realpath(managed_root) or not name.startswith("aidevops-"):
    raise SystemExit(1)

try:
    os.setsid()
except OSError:
    pass

def cleanup():
    try:
        mode = os.lstat(path).st_mode
    except FileNotFoundError:
        return True
    try:
        if stat.S_ISDIR(mode) and not stat.S_ISLNK(mode):
            shutil.rmtree(path)
        else:
            os.unlink(path)
    except FileNotFoundError:
        return True
    except OSError:
        return False
    return not os.path.lexists(path)

def cleanup_until(cleanup_deadline):
    while True:
        if cleanup():
            return True
        if time.monotonic() >= cleanup_deadline:
            return False
        time.sleep(min(poll, 1))

def stop(_signum, _frame):
    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, signal.SIG_IGN)
    cleanup_ok = cleanup_until(time.monotonic() + max(60, poll * 5))
    raise SystemExit(0 if cleanup_ok else 1)

for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(signum, stop)

deadline = time.monotonic() + max_age
while time.monotonic() < deadline:
    try:
        os.kill(owner_pid, 0)
    except (ProcessLookupError, PermissionError):
        break
    if not os.path.lexists(path):
        raise SystemExit(0)
    time.sleep(poll)
cleanup_ok = cleanup_until(time.monotonic() + max(60, poll * 5))
raise SystemExit(0 if cleanup_ok else 1)
PY
	) &
	local guardian_pid=$!
	disown "$guardian_pid" 2>/dev/null || true
	return 0
}

aidevops_sensitive_temp_cleanup() {
	local guarded_path="$1"
	local managed_temp_root=""
	local guarded_parent="${guarded_path%/*}"
	local guarded_name="${guarded_path##*/}"
	managed_temp_root=$(aidevops_sensitive_temp_root) || return 1
	[[ "$guarded_path" == /* && "$guarded_parent" == "$managed_temp_root" ]] || return 1
	[[ "$guarded_name" == aidevops-* && "$guarded_name" != */* ]] || return 1
	rm -rf -- "$guarded_path" || return 1
	[[ ! -e "$guarded_path" && ! -L "$guarded_path" ]] || return 1
	return 0
}
