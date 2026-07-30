#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${TEST_DIR}/.."
TEST_ROOT="$(mktemp -d)"

cleanup() {
	rm -rf "$TEST_ROOT" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

export HOME="${TEST_ROOT}/home"
export AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp"
export WRAPPER_LOGFILE="${TEST_ROOT}/pulse-wrapper.log"
export LOGFILE="$WRAPPER_LOGFILE"
mkdir -p "$HOME" "$AIDEVOPS_TEMP_DIR"
: >"$WRAPPER_LOGFILE"

# shellcheck source=../pulse-todo-sync-workspace.sh
source "${SCRIPTS_DIR}/pulse-todo-sync-workspace.sh"

make_workspace() {
	local name="$1"
	local owner_pid="$2"
	local owner_start="$3"
	local owner_created="$4"
	local workspace="${AIDEVOPS_TEMP_DIR}/${name}"
	mkdir -p "${workspace}/repo/.git"
	printf '%s\t%s\t%s\t%s\n' "$_PTSW_MARKER_VERSION" "$owner_pid" "$owner_created" "$owner_start" >"${workspace}/${_PTSW_OWNER_MARKER}"
	printf '%s\n' "$workspace"
	return 0
}

old_epoch=$(($(date +%s) - 7200))
active_start=$(_ptsw_process_start_fingerprint "$$")

for index in 1 2 3 4 5 6 7; do
	make_workspace "pulse-todo-sync.AAAA${index}${index}" "999999" "dead-${index}" "$old_epoch" >/dev/null
done
make_workspace "pulse-todo-sync.ZZZZZZ" "$$" "$active_start" "$old_epoch" >/dev/null
mkdir -p "${AIDEVOPS_TEMP_DIR}/pulse-todo-sync.BADBAD/repo/.git"

export PULSE_TODO_SYNC_MAX_RECOVERIES_PER_RUN=5
export PULSE_TODO_SYNC_PRESSURE_COUNT_THRESHOLD=6
export PULSE_TODO_SYNC_STALE_CLEANUP_MODE=delete
removed=$(_ptsw_sweep_stale_workspaces)

[[ "$removed" -eq 7 ]] || {
	printf 'FAIL expected dynamic cleanup to remove 7 stale workspaces, got %s\n' "$removed" >&2
	exit 1
}
[[ -d "${AIDEVOPS_TEMP_DIR}/pulse-todo-sync.ZZZZZZ" ]] || {
	printf 'FAIL active owner workspace was removed\n' >&2
	exit 1
}
[[ -d "${AIDEVOPS_TEMP_DIR}/pulse-todo-sync.BADBAD" ]] || {
	printf 'FAIL markerless legacy workspace should not be direct-deleted\n' >&2
	exit 1
}
if compgen -G "${AIDEVOPS_TEMP_DIR}/pulse-todo-sync.AAAA*" >/dev/null; then
	printf 'FAIL stale dead-owner workspaces remain\n' >&2
	exit 1
fi
grep -q 'mode=delete' "$WRAPPER_LOGFILE" || {
	printf 'FAIL cleanup log did not record direct delete mode\n' >&2
	exit 1
}

printf 'PASS TODO-sync stale cleanup scales under pressure and preserves active/legacy workspaces\n'
