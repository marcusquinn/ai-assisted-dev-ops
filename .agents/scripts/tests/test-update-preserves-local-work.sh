#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
PASS_COUNT=0
FAIL_COUNT=0
export GIT_AUTHOR_NAME=Test
export GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test
export GIT_COMMITTER_EMAIL=test@example.invalid
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() {
	printf 'PASS %s\n' "$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	return 0
}

fail() {
	printf 'FAIL %s: %s\n' "$1" "$2" >&2
	FAIL_COUNT=$((FAIL_COUNT + 1))
	return 0
}

extract_function() {
	local source_file="$1"
	local function_name="$2"
	local output_file="$3"
	awk -v function_name="$function_name" '
		$0 ~ "^" function_name "\\(\\)[[:space:]]*\\{" { capturing = 1 }
		capturing {
			print
			line = $0
			open_count = gsub(/\{/, "", line)
			line = $0
			close_count = gsub(/\}/, "", line)
			depth += open_count - close_count
			if (depth == 0) exit
		}
	' "$source_file" >"$output_file"
	[[ -s "$output_file" ]]
	return 0
}

setup_repo() {
	local repo="$1"
	git init -q -b main "$repo"
	printf 'upstream\n' >"$repo/VERSION"
	git -C "$repo" add VERSION
	git -C "$repo" commit -qm initial
	return 0
}

setup_synced_repo() {
	local repo="$1"
	local remote="$2"
	git init -q --bare -b main "$remote"
	setup_repo "$repo"
	git -C "$repo" remote add origin "$remote"
	git -C "$repo" push -qu origin main
	return 0
}

setup_ahead_repo() {
	local repo="$1"
	local remote="$2"
	git init -q --bare -b main "$remote"
	setup_repo "$repo"
	git -C "$repo" remote add origin "$remote"
	git -C "$repo" push -qu origin main
	printf 'local commit\n' >"$repo/VERSION"
	git -C "$repo" commit -am local -q
	return 0
}

setup_behind_repo() {
	local repo="$1"
	local remote="$2"
	local peer="$3"
	git init -q --bare -b main "$remote"
	setup_repo "$repo"
	git -C "$repo" remote add origin "$remote"
	git -C "$repo" push -qu origin main
	git clone -q "$remote" "$peer"
	printf 'remote update\n' >"$peer/VERSION"
	git -C "$peer" commit -am remote -q
	git -C "$peer" push -q origin main
	return 0
}

setup_diverged_repo() {
	local repo="$1"
	local remote="$2"
	local peer="$3"
	git init -q --bare -b main "$remote"
	setup_repo "$repo"
	git -C "$repo" remote add origin "$remote"
	git -C "$repo" push -qu origin main
	git clone -q "$remote" "$peer"
	printf 'remote\n' >"$peer/VERSION"
	git -C "$peer" commit -am remote -q
	git -C "$peer" push -q origin main
	printf 'local\n' >"$repo/VERSION"
	git -C "$repo" commit -am local -q
	return 0
}

extract_function "$REPO_ROOT/aidevops.sh" cmd_update "$TEST_ROOT/cmd-update.sh"
extract_function "$REPO_ROOT/.agents/scripts/auto-update-helper.sh" _cmd_check_git_update "$TEST_ROOT/auto-update.sh"
extract_function "$REPO_ROOT/.agents/scripts/auto-update-helper-check.sh" _cmd_check_git_update "$TEST_ROOT/auto-update-check-lib.sh"
# shellcheck source=/dev/null
source "$TEST_ROOT/cmd-update.sh"
# shellcheck source=/dev/null
source "$TEST_ROOT/auto-update.sh"

print_header() { :; }
print_info() { :; }
print_warning() { :; }
print_error() { :; }
print_success() { :; }
get_version() { printf '1.0.0\n'; }
check_dir() { [[ -d "$1" ]]; }
_update_repo_verify_files_changed() { return 1; }
_update_check_workflow_drift() { :; }
_update_verify_signature() { :; }
_run_update_setup() { return 0; }
_update_fresh_install() { return 0; }
_update_sync_projects() { :; }
_update_reconcile_repo_verify() { :; }
_update_check_homebrew() { :; }
_update_check_planning() { :; }
_update_check_tools() { :; }
_update_sweep_opencode_symlinks() { :; }
_update_check_setsid() { :; }
_migrate_settings_supervisor_to_orchestration() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
LAST_UPDATE_STATUS=""
update_state() {
	local action="$1"
	local version="${2:-}"
	local status="${3:-success}"
	: "$action" "$version"
	LAST_UPDATE_STATUS="$status"
	return 0
}
AGENTS_DIR="$TEST_ROOT/no-agents"
AIDEVOPS_SKIP_PULSE_RESTART=1
_AIDEVOPS_UPDATE_TRUE=true

assert_dirty_change_preserved() {
	local name="$1"
	local repo="$2"
	if git -C "$repo" diff --quiet && git -C "$repo" diff --cached --quiet; then
		fail "$name" "working tree was cleaned"
	elif [[ "$(<"$repo/VERSION")" != 'local change' ]]; then
		fail "$name" "VERSION content changed"
	else
		pass "$name"
	fi
	return 0
}

for mode in staged unstaged; do
	repo="$TEST_ROOT/cmd-update-$mode"
	setup_repo "$repo"
	printf 'local change' >"$repo/VERSION"
	[[ "$mode" == staged ]] && git -C "$repo" add VERSION
	INSTALL_DIR="$repo"
	if cmd_update --skip-project-sync --compact >/dev/null 2>&1; then
		fail "cmd_update $mode changes return nonzero" "unexpected success"
	else
		assert_dirty_change_preserved "cmd_update preserves $mode changes" "$repo"
	fi
done

for mode in staged unstaged; do
	repo="$TEST_ROOT/auto-update-$mode"
	setup_repo "$repo"
	printf 'local change' >"$repo/VERSION"
	[[ "$mode" == staged ]] && git -C "$repo" add VERSION
	INSTALL_DIR="$repo"
	LOG_FILE="$TEST_ROOT/auto-update-$mode.log"
	if _cmd_check_git_update 1.0.1 >/dev/null 2>&1; then
		fail "auto update $mode changes return nonzero" "unexpected success"
	else
		assert_dirty_change_preserved "auto update preserves $mode changes" "$repo"
	fi
done

auto_behind_repo="$TEST_ROOT/auto-update-behind"
auto_behind_remote="$TEST_ROOT/auto-update-behind.git"
auto_behind_peer="$TEST_ROOT/auto-update-behind-peer"
setup_behind_repo "$auto_behind_repo" "$auto_behind_remote" "$auto_behind_peer"
auto_remote_commit="$(git -C "$auto_behind_peer" rev-parse HEAD)"
INSTALL_DIR="$auto_behind_repo"
LOG_FILE="$TEST_ROOT/auto-update-behind.log"
if ! _cmd_check_git_update 1.0.1 >/dev/null 2>&1; then
	fail 'auto update fast-forwards after fetch' 'update failed'
elif [[ "$(git -C "$auto_behind_repo" rev-parse HEAD)" != "$auto_remote_commit" ]]; then
	fail 'auto update fast-forwards after fetch' 'HEAD does not match fetched commit'
else
	pass 'auto update fast-forwards after fetch'
fi

auto_dirty_behind_repo="$TEST_ROOT/auto-update-dirty-behind"
auto_dirty_behind_remote="$TEST_ROOT/auto-update-dirty-behind.git"
auto_dirty_behind_peer="$TEST_ROOT/auto-update-dirty-behind-peer"
setup_behind_repo "$auto_dirty_behind_repo" "$auto_dirty_behind_remote" "$auto_dirty_behind_peer"
auto_dirty_behind_commit="$(git -C "$auto_dirty_behind_repo" rev-parse HEAD)"
printf 'preserved local diagnostic\n' >>"$auto_dirty_behind_repo/VERSION"
INSTALL_DIR="$auto_dirty_behind_repo"
LOG_FILE="$TEST_ROOT/auto-update-dirty-behind.log"
LAST_UPDATE_STATUS=""
if _cmd_check_git_update 1.0.1 >/dev/null 2>&1; then
	fail 'auto update reports stale dirty canonical checkout' 'unexpected success'
elif [[ "$(git -C "$auto_dirty_behind_repo" rev-parse HEAD)" != "$auto_dirty_behind_commit" ]]; then
	fail 'auto update reports stale dirty canonical checkout' 'HEAD changed'
elif [[ "$LAST_UPDATE_STATUS" != "runtime_stale_local_changes" ]]; then
	fail 'auto update reports stale dirty canonical checkout' "status=$LAST_UPDATE_STATUS"
elif [[ "$(<"$auto_dirty_behind_repo/VERSION")" != *"preserved local diagnostic"* ]]; then
	fail 'auto update reports stale dirty canonical checkout' 'local diagnostic content changed'
else
	pass 'auto update reports stale dirty canonical checkout'
fi

auto_detached_repo="$TEST_ROOT/auto-update-detached"
auto_detached_remote="$TEST_ROOT/auto-update-detached.git"
setup_synced_repo "$auto_detached_repo" "$auto_detached_remote"
auto_detached_commit="$(git -C "$auto_detached_repo" rev-parse HEAD)"
git -C "$auto_detached_repo" checkout -q --detach
INSTALL_DIR="$auto_detached_repo"
LOG_FILE="$TEST_ROOT/auto-update-detached.log"
LAST_UPDATE_STATUS=""
if _cmd_check_git_update 1.0.1 >/dev/null 2>&1; then
	fail 'auto update rejects detached exact-SHA checkout' 'unexpected success'
elif [[ "$(git -C "$auto_detached_repo" rev-parse HEAD)" != "$auto_detached_commit" ]]; then
	fail 'auto update rejects detached exact-SHA checkout' 'HEAD changed'
elif [[ "$LAST_UPDATE_STATUS" != "runtime_stale_branch" ]]; then
	fail 'auto update rejects detached exact-SHA checkout' "status=$LAST_UPDATE_STATUS"
else
	pass 'auto update rejects detached exact-SHA checkout'
fi

interactive_repo="$TEST_ROOT/cmd-update-diverged"
interactive_remote="$TEST_ROOT/cmd-update-diverged.git"
interactive_peer="$TEST_ROOT/cmd-update-peer"
setup_diverged_repo "$interactive_repo" "$interactive_remote" "$interactive_peer"
interactive_commit="$(git -C "$interactive_repo" rev-parse HEAD)"
INSTALL_DIR="$interactive_repo"
if cmd_update --skip-project-sync --compact >/dev/null 2>&1; then
	fail 'cmd_update divergence returns nonzero' 'unexpected success'
elif [[ "$(git -C "$interactive_repo" rev-parse HEAD)" != "$interactive_commit" ]]; then
	fail 'cmd_update preserves divergent local commit' 'HEAD changed'
else
	pass 'cmd_update preserves divergent local commit'
fi

auto_repo="$TEST_ROOT/auto-update-diverged"
auto_remote="$TEST_ROOT/auto-update-diverged.git"
auto_peer="$TEST_ROOT/auto-update-peer"
setup_diverged_repo "$auto_repo" "$auto_remote" "$auto_peer"
auto_commit="$(git -C "$auto_repo" rev-parse HEAD)"
INSTALL_DIR="$auto_repo"
LOG_FILE="$TEST_ROOT/auto-update-diverged.log"
if _cmd_check_git_update 1.0.1 >/dev/null 2>&1; then
	fail 'auto update divergence returns nonzero' 'unexpected success'
elif [[ "$(git -C "$auto_repo" rev-parse HEAD)" != "$auto_commit" ]]; then
	fail 'auto update preserves divergent local commit' 'HEAD changed'
else
	pass 'auto update preserves divergent local commit'
fi

interactive_ahead_repo="$TEST_ROOT/cmd-update-ahead"
interactive_ahead_remote="$TEST_ROOT/cmd-update-ahead.git"
setup_ahead_repo "$interactive_ahead_repo" "$interactive_ahead_remote"
interactive_ahead_commit="$(git -C "$interactive_ahead_repo" rev-parse HEAD)"
INSTALL_DIR="$interactive_ahead_repo"
if cmd_update --skip-project-sync --compact >/dev/null 2>&1; then
	fail 'cmd_update local-ahead history returns nonzero' 'unexpected success'
elif [[ "$(git -C "$interactive_ahead_repo" rev-parse HEAD)" != "$interactive_ahead_commit" ]]; then
	fail 'cmd_update preserves local-ahead commit' 'HEAD changed'
else
	pass 'cmd_update preserves local-ahead commit'
fi

auto_ahead_repo="$TEST_ROOT/auto-update-ahead"
auto_ahead_remote="$TEST_ROOT/auto-update-ahead.git"
setup_ahead_repo "$auto_ahead_repo" "$auto_ahead_remote"
auto_ahead_commit="$(git -C "$auto_ahead_repo" rev-parse HEAD)"
INSTALL_DIR="$auto_ahead_repo"
LOG_FILE="$TEST_ROOT/auto-update-ahead.log"
if _cmd_check_git_update 1.0.1 >/dev/null 2>&1; then
	fail 'auto update local-ahead history returns nonzero' 'unexpected success'
elif [[ "$(git -C "$auto_ahead_repo" rev-parse HEAD)" != "$auto_ahead_commit" ]]; then
	fail 'auto update preserves local-ahead commit' 'HEAD changed'
else
	pass 'auto update preserves local-ahead commit'
fi

# The extracted check sub-library is independently sourceable and must retain
# the same fail-closed behavior as the monolithic scheduler entry point.
# shellcheck source=/dev/null
source "$TEST_ROOT/auto-update-check-lib.sh"
for mode in staged unstaged; do
	repo="$TEST_ROOT/check-lib-$mode"
	setup_repo "$repo"
	printf 'local change' >"$repo/VERSION"
	[[ "$mode" == staged ]] && git -C "$repo" add VERSION
	INSTALL_DIR="$repo"
	LOG_FILE="$TEST_ROOT/check-lib-$mode.log"
	if _cmd_check_git_update 1.0.1 >/dev/null 2>&1; then
		fail "check library $mode changes return nonzero" "unexpected success"
	else
		assert_dirty_change_preserved "check library preserves $mode changes" "$repo"
	fi
done

check_lib_behind_repo="$TEST_ROOT/check-lib-behind"
check_lib_behind_remote="$TEST_ROOT/check-lib-behind.git"
check_lib_behind_peer="$TEST_ROOT/check-lib-behind-peer"
setup_behind_repo "$check_lib_behind_repo" "$check_lib_behind_remote" "$check_lib_behind_peer"
check_lib_remote_commit="$(git -C "$check_lib_behind_peer" rev-parse HEAD)"
INSTALL_DIR="$check_lib_behind_repo"
LOG_FILE="$TEST_ROOT/check-lib-behind.log"
if ! _cmd_check_git_update 1.0.1 >/dev/null 2>&1; then
	fail 'check library fast-forwards after fetch' 'update failed'
elif [[ "$(git -C "$check_lib_behind_repo" rev-parse HEAD)" != "$check_lib_remote_commit" ]]; then
	fail 'check library fast-forwards after fetch' 'HEAD does not match fetched commit'
else
	pass 'check library fast-forwards after fetch'
fi

check_lib_detached_repo="$TEST_ROOT/check-lib-detached"
check_lib_detached_remote="$TEST_ROOT/check-lib-detached.git"
setup_synced_repo "$check_lib_detached_repo" "$check_lib_detached_remote"
check_lib_detached_commit="$(git -C "$check_lib_detached_repo" rev-parse HEAD)"
git -C "$check_lib_detached_repo" checkout -q --detach
INSTALL_DIR="$check_lib_detached_repo"
LOG_FILE="$TEST_ROOT/check-lib-detached.log"
LAST_UPDATE_STATUS=""
if _cmd_check_git_update 1.0.1 >/dev/null 2>&1; then
	fail 'check library rejects detached exact-SHA checkout' 'unexpected success'
elif [[ "$(git -C "$check_lib_detached_repo" rev-parse HEAD)" != "$check_lib_detached_commit" ]]; then
	fail 'check library rejects detached exact-SHA checkout' 'HEAD changed'
elif [[ "$LAST_UPDATE_STATUS" != "runtime_stale_branch" ]]; then
	fail 'check library rejects detached exact-SHA checkout' "status=$LAST_UPDATE_STATUS"
else
	pass 'check library rejects detached exact-SHA checkout'
fi

check_lib_diverged_repo="$TEST_ROOT/check-lib-diverged"
check_lib_diverged_remote="$TEST_ROOT/check-lib-diverged.git"
check_lib_diverged_peer="$TEST_ROOT/check-lib-peer"
setup_diverged_repo "$check_lib_diverged_repo" "$check_lib_diverged_remote" "$check_lib_diverged_peer"
check_lib_diverged_commit="$(git -C "$check_lib_diverged_repo" rev-parse HEAD)"
INSTALL_DIR="$check_lib_diverged_repo"
LOG_FILE="$TEST_ROOT/check-lib-diverged.log"
if _cmd_check_git_update 1.0.1 >/dev/null 2>&1; then
	fail 'check library divergence returns nonzero' 'unexpected success'
elif [[ "$(git -C "$check_lib_diverged_repo" rev-parse HEAD)" != "$check_lib_diverged_commit" ]]; then
	fail 'check library preserves divergent local commit' 'HEAD changed'
else
	pass 'check library preserves divergent local commit'
fi

check_lib_ahead_repo="$TEST_ROOT/check-lib-ahead"
check_lib_ahead_remote="$TEST_ROOT/check-lib-ahead.git"
setup_ahead_repo "$check_lib_ahead_repo" "$check_lib_ahead_remote"
check_lib_ahead_commit="$(git -C "$check_lib_ahead_repo" rev-parse HEAD)"
INSTALL_DIR="$check_lib_ahead_repo"
LOG_FILE="$TEST_ROOT/check-lib-ahead.log"
if _cmd_check_git_update 1.0.1 >/dev/null 2>&1; then
	fail 'check library local-ahead history returns nonzero' 'unexpected success'
elif [[ "$(git -C "$check_lib_ahead_repo" rev-parse HEAD)" != "$check_lib_ahead_commit" ]]; then
	fail 'check library preserves local-ahead commit' 'HEAD changed'
else
	pass 'check library preserves local-ahead commit'
fi

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
