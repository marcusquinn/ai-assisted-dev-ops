#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."
TEST_ROOT=""
PASS=0
FAIL=0

setup() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "$HOME"
	unset AIDEVOPS_PULSE_TMP_DIR
	unset XDG_RUNTIME_DIR
	# shellcheck source=../shared-constants.sh
	source "${SCRIPTS_DIR}/shared-constants.sh"
	# shellcheck source=../pulse-dispatch-worker-launch.sh
	source "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh"
	return 0
}

teardown() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT" || true
	return 0
}

record() {
	local name="$1"
	local rc="$2"
	if [[ "$rc" -eq 0 ]]; then
		printf 'ok - %s\n' "$name"
		PASS=$((PASS + 1))
	else
		printf 'not ok - %s\n' "$name"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

test_fallback_home_workspace() {
	local root=""
	root=$(aidevops_pulse_tmp_root)
	[[ "$root" == "${HOME}/.aidevops/.agent-workspace/tmp/pulse" ]] || return 1
	[[ -d "$root" ]] || return 1
	return 0
}

test_xdg_runtime_preferred() {
	local runtime="${TEST_ROOT}/runtime"
	local root=""
	mkdir -p "$runtime"
	export XDG_RUNTIME_DIR="$runtime"
	root=$(aidevops_pulse_tmp_root)
	[[ "$root" == "${runtime}/aidevops/pulse" ]] || return 1
	return 0
}

test_override_wins() {
	local override="${TEST_ROOT}/override-pulse"
	local root=""
	export AIDEVOPS_PULSE_TMP_DIR="$override"
	root=$(aidevops_pulse_tmp_root)
	[[ "$root" == "$override" ]] || return 1
	return 0
}

test_worker_log_setup_uses_per_user_dir() {
	unset AIDEVOPS_PULSE_TMP_DIR
	unset XDG_RUNTIME_DIR
	local worker_log=""
	local fallback_log=""
	worker_log=$(_dlw_setup_worker_log "owner/repo" "12345")
	fallback_log=$(aidevops_pulse_worker_log_fallback_path "12345")
	[[ "$worker_log" == "${HOME}/.aidevops/.agent-workspace/tmp/pulse/pulse-owner-repo-12345.log" ]] || return 1
	[[ -f "$worker_log" ]] || return 1
	[[ -L "$fallback_log" ]] || return 1
	[[ ! -e "/tmp/pulse-owner-repo-12345.log" ]] || return 1
	return 0
}

test_cleanup_removes_only_old_pulse_logs() {
	local root=""
	root=$(aidevops_pulse_tmp_root)
	local old_log="${root}/pulse-old.log"
	local new_log="${root}/pulse-new.log"
	local other_file="${root}/not-pulse.log"
	: >"$old_log"
	: >"$new_log"
	: >"$other_file"
	python3 - "$old_log" <<'PY'
import os
import sys
import time
old = time.time() - 7200
os.utime(sys.argv[1], (old, old))
PY
	aidevops_pulse_tmp_cleanup 60
	[[ ! -e "$old_log" ]] || return 1
	[[ -e "$new_log" ]] || return 1
	[[ -e "$other_file" ]] || return 1
	return 0
}

test_cleanup_sweeps_stale_todo_sync_workspace() {
	local workspace="${HOME}/.aidevops/.agent-workspace/tmp/pulse-todo-sync.STALE1"
	local marker="${workspace}/.aidevops-pulse-todo-sync-owner"
	local old_epoch=0
	old_epoch=$(($(date +%s) - 7200))
	mkdir -p "${workspace}/repo/.git"
	printf '%s\t%s\t%s\t%s\n' "v1" "999999" "$old_epoch" "dead-owner" >"$marker"
	aidevops_pulse_tmp_cleanup 60
	[[ ! -e "$workspace" && ! -L "$workspace" ]] || return 1
	return 0
}

main() {
	setup
	if test_fallback_home_workspace; then record "fallback home pulse tmp" 0; else record "fallback home pulse tmp" 1; fi
	if test_xdg_runtime_preferred; then record "xdg runtime preferred" 0; else record "xdg runtime preferred" 1; fi
	if test_override_wins; then record "override wins" 0; else record "override wins" 1; fi
	if test_worker_log_setup_uses_per_user_dir; then record "worker log setup avoids global tmp" 0; else record "worker log setup avoids global tmp" 1; fi
	if test_cleanup_removes_only_old_pulse_logs; then record "cleanup removes old pulse logs" 0; else record "cleanup removes old pulse logs" 1; fi
	if test_cleanup_sweeps_stale_todo_sync_workspace; then record "cleanup sweeps stale TODO-sync workspaces" 0; else record "cleanup sweeps stale TODO-sync workspaces" 1; fi
	teardown
	printf '\nPassed: %s, Failed: %s\n' "$PASS" "$FAIL"
	[[ "$FAIL" -eq 0 ]] || return 1
	return 0
}

main "$@"
