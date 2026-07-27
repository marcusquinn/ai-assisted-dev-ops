#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$REPO_DIR/.agents/scripts/deploy-agents-on-merge.sh"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

pass() {
	local name="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "\033[0;32mPASS\033[0m %s\n" "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "\033[0;31mFAIL\033[0m %s\n" "$name"
	if [[ -n "$detail" ]]; then
		printf "     %s\n" "$detail"
	fi
	return 0
}

assert_eq() {
	local actual="$1"
	local expected="$2"
	local name="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$name"
	else
		fail "$name" "Expected '$expected', got '$actual'"
	fi
	return 0
}

assert_contains() {
	local haystack="$1"
	local needle="$2"
	local name="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "Missing substring: $needle"
	fi
	return 0
}

assert_not_contains() {
	local haystack="$1"
	local needle="$2"
	local name="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "Unexpected substring: $needle"
	fi
	return 0
}

create_base_repo() {
	local dir="$1"
	/usr/bin/git init "$dir" >/dev/null 2>&1
	/usr/bin/git -C "$dir" checkout -b main >/dev/null 2>&1 || true
	/usr/bin/git -C "$dir" config user.email test@example.invalid
	/usr/bin/git -C "$dir" config user.name Test
	/usr/bin/git -C "$dir" config commit.gpgsign false
	mkdir -p "$dir/.agents/scripts"
	echo "echo ok" >"$dir/.agents/scripts/example.sh"
	echo "2.0.0" >"$dir/VERSION"
	cat >"$dir/setup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${MOCK_REQUIRE_SOURCE_LOCK:-0}" == "1" ]]; then
	[[ -d "$repo_root/.git/aidevops-canonical-recovery.lock" ]]
	printf 'source-lock=held\n'
fi
printf 'setup:%s\n' "$*"
[[ -z "${AIDEVOPS_AGENTS_DIR+x}" && -z "${AGENTS_DIR+x}" ]]
exit "${MOCK_SETUP_EXIT_CODE:-0}"
EOF
	chmod +x "$dir/setup.sh"
	/usr/bin/git -C "$dir" add . >/dev/null 2>&1
	/usr/bin/git -C "$dir" commit -m "initial" >/dev/null 2>&1
	return 0
}

run_script() {
	local repo="$1"
	local expected_sha=""
	shift
	expected_sha=$(/usr/bin/git -C "$repo" rev-parse HEAD)
	bash "$SCRIPT_PATH" --repo "$repo" --expected-sha "$expected_sha" "$@" 2>&1
	return $?
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export HOME="$TMP_DIR/home"
mkdir -p "$HOME"

# Test 1: Invalid commit should fail fast (exit 1)
TEST_REPO_INVALID="$TMP_DIR/repo-invalid"
create_base_repo "$TEST_REPO_INVALID"

set +e
invalid_output="$(run_script "$TEST_REPO_INVALID" --diff "--bad-ref" --quiet)"
invalid_status=$?
set -e

assert_eq "$invalid_status" "1" "Invalid --diff commit exits with status 1"
assert_contains "$invalid_output" "Invalid commit reference" "Invalid --diff commit logs validation error"

# Test 2: git diff failure should return 1 (not 2/no-op)
TEST_REPO_DIFF_FAIL="$TMP_DIR/repo-diff-fail"
create_base_repo "$TEST_REPO_DIFF_FAIL"

FAKE_BIN="$TMP_DIR/fake-bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-C" ]]; then
	repo_path="$2"
	shift 2
else
	repo_path=""
fi

if [[ -n "${GIT_COMMAND_LOG:-}" ]]; then
	printf '%s\n' "$*" >>"$GIT_COMMAND_LOG"
fi

if [[ "$1" == "diff" && "$2" == "--name-only" ]]; then
	printf 'simulated git diff failure\n' >&2
	exit 128
fi

if [[ -n "$repo_path" ]]; then
	exec /usr/bin/git -C "$repo_path" "$@"
fi

exec /usr/bin/git "$@"
EOF
chmod +x "$FAKE_BIN/git"

set +e
diff_fail_output="$(PATH="$FAKE_BIN:/usr/bin:/bin" run_script "$TEST_REPO_DIFF_FAIL" --diff HEAD --quiet)"
diff_fail_status=$?
set -e

assert_eq "$diff_fail_status" "1" "git diff failure exits with status 1"
assert_contains "$diff_fail_output" "Failed to detect changed agent files: simulated git diff failure" "git diff failure logs actionable error"

# Test 3: Real changed agent files should deploy successfully
TEST_REPO_CHANGED="$TMP_DIR/repo-changed"
create_base_repo "$TEST_REPO_CHANGED"

echo "echo updated" >"$TEST_REPO_CHANGED/.agents/scripts/example.sh"
/usr/bin/git -C "$TEST_REPO_CHANGED" add .agents/scripts/example.sh >/dev/null 2>&1
/usr/bin/git -C "$TEST_REPO_CHANGED" commit -m "update script" >/dev/null 2>&1

set +e
changed_output="$(run_script "$TEST_REPO_CHANGED" --diff HEAD~1)"
changed_status=$?
set -e

assert_eq "$changed_status" "0" "Changed script deploy exits with status 0"
assert_contains "$changed_output" "using fast scripts-only deploy" "Changed script deploy selects scripts-only path"
assert_contains "$changed_output" "setup:--stage ai-session" "Changed script deploy routes through transactional setup"

# Test 4: Exact source provenance is mandatory before any setup mutation
TEST_REPO_REQUIRED="$TMP_DIR/repo-required"
create_base_repo "$TEST_REPO_REQUIRED"

set +e
required_output="$(bash "$SCRIPT_PATH" --repo "$TEST_REPO_REQUIRED" --scripts-only --quiet 2>&1)"
required_status=$?
set -e

assert_eq "$required_status" "1" "Missing --expected-sha fails before deployment"
assert_contains "$required_output" "Exact source provenance is required" "Missing provenance reports the recovery contract"

# Test 5: A stale expected SHA fails closed and preserves the active bundle
TEST_REPO_STALE="$TMP_DIR/repo-stale"
create_base_repo "$TEST_REPO_STALE"
stale_expected=$(/usr/bin/git -C "$TEST_REPO_STALE" rev-parse HEAD)
printf '%s\n' 'new source' >"$TEST_REPO_STALE/.agents/scripts/new.sh"
/usr/bin/git -C "$TEST_REPO_STALE" add .agents/scripts/new.sh
/usr/bin/git -C "$TEST_REPO_STALE" commit -m "advance source" >/dev/null 2>&1
mkdir -p "$HOME/.aidevops/agents"
printf '%s\n' 'active-before-stale-check' >"$HOME/.aidevops/agents/active-sentinel"

set +e
stale_output="$(bash "$SCRIPT_PATH" --repo "$TEST_REPO_STALE" --expected-sha "$stale_expected" --scripts-only --quiet 2>&1)"
stale_status=$?
set -e

assert_eq "$stale_status" "1" "Stale source checkout fails closed"
assert_contains "$stale_output" "Source checkout is stale" "Stale source reports exact-SHA mismatch"
active_after_stale=$(<"$HOME/.aidevops/agents/active-sentinel")
assert_eq "$active_after_stale" "active-before-stale-check" "Stale source leaves active bundle bytes unchanged"
assert_not_contains "$stale_output" "setup:" "Stale source fails before setup staging"

# Test 6: Dirty source state fails before activation
TEST_REPO_DIRTY="$TMP_DIR/repo-dirty"
create_base_repo "$TEST_REPO_DIRTY"
dirty_expected=$(/usr/bin/git -C "$TEST_REPO_DIRTY" rev-parse HEAD)
printf '%s\n' 'uncommitted source' >>"$TEST_REPO_DIRTY/.agents/scripts/example.sh"
printf '%s\n' 'active-before-dirty-check' >"$HOME/.aidevops/agents/active-sentinel"

set +e
dirty_output="$(bash "$SCRIPT_PATH" --repo "$TEST_REPO_DIRTY" --expected-sha "$dirty_expected" --scripts-only --quiet 2>&1)"
dirty_status=$?
set -e

assert_eq "$dirty_status" "1" "Dirty source checkout fails closed"
assert_contains "$dirty_output" "Source checkout is dirty" "Dirty source reports provenance failure"
active_after_dirty=$(<"$HOME/.aidevops/agents/active-sentinel")
assert_eq "$active_after_dirty" "active-before-dirty-check" "Dirty source leaves active bundle bytes unchanged"
assert_not_contains "$dirty_output" "setup:" "Dirty source fails before setup staging"

# Test 7: Canonical source lock remains held through transactional setup
TEST_REPO_LOCK="$TMP_DIR/repo-lock"
create_base_repo "$TEST_REPO_LOCK"
set +e
lock_output="$(MOCK_REQUIRE_SOURCE_LOCK=1 run_script "$TEST_REPO_LOCK" --scripts-only)"
lock_status=$?
set -e

assert_eq "$lock_status" "0" "Canonical source lock permits one deployment"
assert_contains "$lock_output" "source-lock=held" "Canonical recovery lock is held through activation"

# Test 8: Successful deployment performs no Git mutation command
TEST_REPO_READ_ONLY="$TMP_DIR/repo-read-only"
create_base_repo "$TEST_REPO_READ_ONLY"
GIT_COMMAND_LOG="$TMP_DIR/git-commands.log"
: >"$GIT_COMMAND_LOG"

set +e
read_only_output="$(GIT_COMMAND_LOG="$GIT_COMMAND_LOG" PATH="$FAKE_BIN:/usr/bin:/bin" run_script "$TEST_REPO_READ_ONLY" --scripts-only --quiet)"
read_only_status=$?
set -e

assert_eq "$read_only_status" "0" "Read-only source deployment succeeds"
git_commands=$(<"$GIT_COMMAND_LOG")
forbidden_git_command=""
while IFS= read -r git_command; do
	case "$git_command" in
	pull* | merge* | reset* | clean* | checkout* | switch* | worktree*)
		forbidden_git_command="$git_command"
		break
		;;
	esac
done <<<"$git_commands"
assert_eq "$forbidden_git_command" "" "Deployment executes no pull, merge, reset, clean, checkout, switch, or worktree mutation"

# Test 9: Full deploy must isolate immutable session pins from setup.sh
TEST_REPO_FULL="$TMP_DIR/repo-full"
create_base_repo "$TEST_REPO_FULL"
cat >"$TEST_REPO_FULL/setup.sh" <<'EOF'
#!/usr/bin/env bash
[[ -z "${AIDEVOPS_AGENTS_DIR+x}" && -z "${AGENTS_DIR+x}" ]]
EOF
chmod +x "$TEST_REPO_FULL/setup.sh"
/usr/bin/git -C "$TEST_REPO_FULL" add setup.sh
/usr/bin/git -C "$TEST_REPO_FULL" commit -m "update full setup fixture" >/dev/null 2>&1

set +e
full_output="$(HOME="$TMP_DIR/home" AIDEVOPS_AGENTS_DIR="$TMP_DIR/home/.aidevops/runtime-bundles/old/agents" AGENTS_DIR="$TMP_DIR/home/.aidevops/runtime-bundles/old/agents" run_script "$TEST_REPO_FULL" --full)"
full_status=$?
set -e

assert_eq "$full_status" "0" "Full deploy unsets inherited runtime pins"

# Test 10: Invalid stable HOME fails before setup mutation
set +e
invalid_home_output="$(HOME='' AIDEVOPS_AGENTS_DIR="/tmp/runtime-bundles/old/agents" run_script "$TEST_REPO_FULL" --full)"
invalid_home_status=$?
set -e

assert_eq "$invalid_home_status" "1" "Full deploy rejects an empty HOME"
assert_contains "$invalid_home_output" "stable agents target" "Invalid HOME reports stable-target failure"

printf "\nRan %d tests, %d failed.\n" "$TOTAL_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
	exit 1
fi

exit 0
