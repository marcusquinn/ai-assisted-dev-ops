#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Pulse temporary workspace helpers (t3619).
# Use a per-user runtime directory for pulse worker scratch/log files. Plain
# /tmp/pulse-*.log names collide across multiple aidevops users on one server;
# this helper prefers XDG_RUNTIME_DIR when available and falls back to the
# aidevops user workspace on macOS, cron, SSH, and headless sessions.

[[ -n "${_PULSE_TEMP_HELPER_LOADED:-}" ]] && return 0
_PULSE_TEMP_HELPER_LOADED=1

aidevops_pulse_tmp_root() {
	local root=""
	if [[ -n "${AIDEVOPS_PULSE_TMP_DIR:-}" ]]; then
		root="$AIDEVOPS_PULSE_TMP_DIR"
	elif [[ -n "${XDG_RUNTIME_DIR:-}" && -d "${XDG_RUNTIME_DIR:-}" && -w "${XDG_RUNTIME_DIR:-}" ]]; then
		root="${XDG_RUNTIME_DIR}/aidevops/pulse"
	else
		root="${HOME}/.aidevops/.agent-workspace/tmp/pulse"
	fi
	mkdir -p "$root" 2>/dev/null || return 1
	chmod 700 "$root" || return 1
	printf '%s\n' "$root"
	return 0
}

aidevops_pulse_worker_log_path() {
	local repo_slug="$1"
	local issue_number="$2"
	local root="" safe_slug=""
	root=$(aidevops_pulse_tmp_root) || return 1
	safe_slug=$(printf '%s' "$repo_slug" | tr '/:' '--')
	printf '%s/pulse-%s-%s.log\n' "$root" "$safe_slug" "$issue_number"
	return 0
}

aidevops_pulse_worker_log_fallback_path() {
	local issue_number="$1"
	local root=""
	root=$(aidevops_pulse_tmp_root) || return 1
	printf '%s/pulse-%s.log\n' "$root" "$issue_number"
	return 0
}

aidevops_pulse_worker_log_candidates() {
	local repo_slug="$1"
	local issue_number="$2"
	local primary="" fallback=""
	primary=$(aidevops_pulse_worker_log_path "$repo_slug" "$issue_number") || return 1
	fallback=$(aidevops_pulse_worker_log_fallback_path "$issue_number") || return 1
	printf '%s\n%s\n' "$primary" "$fallback"
	return 0
}

aidevops_pulse_tmp_cleanup() {
	local max_age_minutes="${1:-2880}"
	local root=""
	local helper=""
	local temp_root=""
	[[ "$max_age_minutes" =~ ^[0-9]+$ ]] || max_age_minutes=2880
	root=$(aidevops_pulse_tmp_root) || return 0
	# Best-effort cleanup with exact minutes on macOS/Linux. Files currently open
	# by a worker are normally newer than the age threshold and therefore kept.
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$root" "$max_age_minutes" <<'PY' 2>/dev/null || true
import os
import sys
import time

root = sys.argv[1]
max_age_seconds = int(sys.argv[2]) * 60
now = time.time()
for name in os.listdir(root):
    if not (name.startswith("pulse-") and name.endswith(".log")):
        continue
    path = os.path.join(root, name)
    try:
        st = os.lstat(path)
    except OSError:
        continue
    if now - st.st_mtime <= max_age_seconds:
        continue
    try:
        os.unlink(path)
    except OSError:
        pass
PY
	fi
	helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pulse-todo-sync-workspace.sh"
	if [[ -f "$helper" ]]; then
		# shellcheck source=pulse-todo-sync-workspace.sh
		source "$helper"
		temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
		AIDEVOPS_TEMP_DIR="$temp_root" \
			PULSE_TODO_SYNC_STALE_CLEANUP_MODE="${PULSE_TODO_SYNC_STALE_CLEANUP_MODE:-delete}" \
			_ptsw_sweep_stale_workspaces >/dev/null || true
	fi
	return 0
}
