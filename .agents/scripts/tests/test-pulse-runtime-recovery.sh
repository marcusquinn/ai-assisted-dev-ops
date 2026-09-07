#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=../pulse-runtime-recovery.sh
source "${REPO_ROOT}/.agents/scripts/pulse-runtime-recovery.sh"

TEST_ROOT=""
TESTS_RUN=0

cleanup() {
	[[ -z "$TEST_ROOT" ]] || rm -rf "$TEST_ROOT"
}

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	[[ "$actual" == "$expected" ]] || fail "${message}: expected=${expected} actual=${actual}"
	printf 'PASS: %s\n' "$message"
}

new_fixture() {
	local name="$1"
	local root="${TEST_ROOT}/${name}"
	local repo="${root}/repo"
	local remote="${root}/origin.git"
	local home="${root}/home"
	mkdir -p "${repo}/.agents/scripts" "${home}/.aidevops/cache"
	git init -q --bare -b main "$remote"
	git init -q -b main "$repo"
	git -C "$repo" config user.name Test
	git -C "$repo" config user.email test@example.invalid
	cat >"${repo}/setup.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")" && pwd)"
git -C "$repo_dir" rev-parse HEAD >"$AIDEVOPS_DEPLOYED_SHA_FILE"
SH
	chmod +x "${repo}/setup.sh"
	printf 'old\n' >"${repo}/.agents/scripts/runtime.sh"
	git -C "$repo" add setup.sh .agents/scripts/runtime.sh
	git -C "$repo" commit -qm base
	git -C "$repo" remote add origin "$remote"
	git -C "$repo" push -qu origin main
	git -C "$repo" rev-parse HEAD >"${root}/base.sha"
	printf 'new\n' >"${repo}/.agents/scripts/runtime.sh"
	git -C "$repo" commit -qam runtime-change
	git -C "$repo" push -qu origin main
	printf '%s\n' "$repo" >"${root}/repo.path"
	printf '%s\n' "$home" >"${root}/home.path"
}

run_recovery() {
	local fixture="$1"
	local repo="" home="" base_sha=""
	IFS= read -r repo <"${fixture}/repo.path"
	IFS= read -r home <"${fixture}/home.path"
	IFS= read -r base_sha <"${fixture}/base.sha"
	mkdir -p "${home}/.aidevops"
	printf '%s\n' "$base_sha" >"${home}/.aidevops/.deployed-sha"
	HOME="$home" \
		AIDEVOPS_REPO_PATH="$repo" \
		AIDEVOPS_DEPLOYED_SHA_FILE="${home}/.aidevops/.deployed-sha" \
		AIDEVOPS_PULSE_RUNTIME_RECOVERY_STATE_FILE="${fixture}/state.json" \
		AIDEVOPS_PULSE_RUNTIME_RECOVERY_LOCK_DIR="${fixture}/recovery.lock.d" \
		AIDEVOPS_PULSE_RUNTIME_RECOVERY_COOLDOWN_SECONDS=0 \
		AIDEVOPS_PULSE_RUNTIME_RECOVERY_NO_REEXEC=1 \
		pulse_runtime_recover_if_safe
}

test_safe_runtime_recovery() {
	local fixture="${TEST_ROOT}/safe"
	local repo="" canonical_sha="" deployed_sha=""
	new_fixture safe
	run_recovery "$fixture"
	IFS= read -r repo <"${fixture}/repo.path"
	canonical_sha=$(git -C "$repo" rev-parse HEAD)
	IFS= read -r deployed_sha <"${fixture}/home/.aidevops/.deployed-sha"
	assert_eq "$canonical_sha" "$deployed_sha" "safe stale runtime activates canonical HEAD"
	assert_eq "recovered" "$(jq -r '.status' "${fixture}/state.json")" "successful recovery is recorded"
}

test_dirty_canonical_is_preserved() {
	local fixture="${TEST_ROOT}/dirty"
	local repo="" base_sha="" deployed_sha=""
	new_fixture dirty
	IFS= read -r repo <"${fixture}/repo.path"
	printf 'dirty\n' >>"${repo}/.agents/scripts/runtime.sh"
	run_recovery "$fixture"
	IFS= read -r base_sha <"${fixture}/base.sha"
	IFS= read -r deployed_sha <"${fixture}/home/.aidevops/.deployed-sha"
	assert_eq "$base_sha" "$deployed_sha" "dirty canonical checkout is not deployed"
	assert_eq "canonical_dirty" "$(jq -r '.reason' "${fixture}/state.json")" "dirty block records an exact reason"
}

test_non_exact_main_is_preserved() {
	local fixture="${TEST_ROOT}/ahead"
	local repo="" base_sha="" deployed_sha=""
	new_fixture ahead
	IFS= read -r repo <"${fixture}/repo.path"
	printf 'local ahead\n' >>"${repo}/.agents/scripts/runtime.sh"
	git -C "$repo" commit -qam local-ahead
	run_recovery "$fixture"
	IFS= read -r base_sha <"${fixture}/base.sha"
	IFS= read -r deployed_sha <"${fixture}/home/.aidevops/.deployed-sha"
	assert_eq "$base_sha" "$deployed_sha" "local-ahead main is not deployed"
	assert_eq "canonical_not_exact_origin_main" "$(jq -r '.reason' "${fixture}/state.json")" "non-exact main records a safe recovery action"
}

test_key_value_cooldown_state() {
	local state_file="${TEST_ROOT}/fallback-state"
	local expected="" actual=""
	expected=$(date +%s)
	printf 'status=blocked\nrecorded_epoch=%s\n' "$expected" >"$state_file"
	actual=$(AIDEVOPS_PULSE_RUNTIME_RECOVERY_STATE_FILE="$state_file" _pulse_runtime_recovery_last_attempt_epoch)
	assert_eq "$expected" "$actual" "key-value fallback retains cooldown epoch"
}

test_dead_owner_lock_is_reclaimed() {
	local fixture="${TEST_ROOT}/stale-lock"
	new_fixture stale-lock
	mkdir "${fixture}/recovery.lock.d"
	printf '99999999\n' >"${fixture}/recovery.lock.d/pid"
	run_recovery "$fixture"
	assert_eq "recovered" "$(jq -r '.status' "${fixture}/state.json")" "dead recovery owner does not strand the runtime"
	[[ ! -e "${fixture}/recovery.lock.d" ]] || fail "reclaimed recovery lock remains after completion"
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	test_safe_runtime_recovery
	test_dirty_canonical_is_preserved
	test_non_exact_main_is_preserved
	test_key_value_cooldown_state
	test_dead_owner_lock_is_reclaimed
	printf 'Results: %s checks passed\n' "$TESTS_RUN"
}

main "$@"
