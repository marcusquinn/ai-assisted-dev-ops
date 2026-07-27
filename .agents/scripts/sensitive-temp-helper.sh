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

	[[ "$candidate" == /* && "$candidate" != "/" ]] || return 1
	current_uid=$(id -u) || return 1
	while [[ -n "$remainder" ]]; do
		component="${remainder%%/*}"
		if [[ "$remainder" == */* ]]; then
			remainder="${remainder#*/}"
		else
			remainder=""
		fi
		[[ -n "$component" && "$component" != "." && "$component" != ".." ]] || return 1
		current="${current}/${component}"
		[[ -d "$current" && ! -L "$current" ]] || return 1
		owner_uid=$(stat -f '%u' "$current" 2>/dev/null || stat -c '%u' "$current" 2>/dev/null) || return 1
		[[ "$owner_uid" =~ ^[0-9]+$ ]] || return 1
		[[ "$owner_uid" == "0" || "$owner_uid" == "$current_uid" ]] || return 1
		# BSD %Lp omits special bits; %p retains the sticky bit (and file type).
		# GNU %a returns permission bits only. The masks below work for either.
		mode=$(stat -f '%p' "$current" 2>/dev/null || stat -c '%a' "$current" 2>/dev/null) || return 1
		[[ "$mode" =~ ^[0-7]{3,6}$ ]] || return 1
		mode_value=$((8#$mode))
		[[ -z "$remainder" ]] && is_final=1 || is_final=0
		if ((mode_value & 0022)); then
			[[ "$is_final" -eq 0 ]] || return 1
			((mode_value & 01000)) || return 1
		fi
	done
	return 0
}

aidevops_sensitive_temp_root() {
	local configured_root="${AIDEVOPS_TEMP_DIR:-${HOME:?}/.aidevops/.agent-workspace/tmp}"
	local temp_root=""
	local owner_uid=""
	local current_uid=""
	local mode=""

	[[ "$configured_root" == /* && "$configured_root" != "/" ]] || return 1
	[[ "$configured_root" != *$'\n'* && "$configured_root" != *$'\r'* && "$configured_root" != *$'\t'* ]] || return 1
	[[ ! -L "$configured_root" ]] || return 1
	(umask 077 && mkdir -p "$configured_root") || return 1
	[[ -d "$configured_root" && ! -L "$configured_root" ]] || return 1
	temp_root=$(cd "$configured_root" 2>/dev/null && pwd -P) || return 1
	_aidevops_sensitive_temp_physical_path_is_safe "$temp_root" || return 1
	current_uid=$(id -u) || return 1
	owner_uid=$(stat -f '%u' "$temp_root" 2>/dev/null || stat -c '%u' "$temp_root" 2>/dev/null) || return 1
	[[ "$owner_uid" == "$current_uid" ]] || return 1
	chmod 700 "$temp_root" || return 1
	mode=$(stat -f '%Lp' "$temp_root" 2>/dev/null || stat -c '%a' "$temp_root" 2>/dev/null) || return 1
	[[ "$mode" == "700" ]] || return 1
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
