#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
GUARD="${SCRIPT_DIR}/canonical-git-command-guard.py"
SHIM="${SCRIPT_DIR}/git"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
REPO="${TEST_ROOT}/repo"
LINKED="${TEST_ROOT}/linked"
TESTS=0
FAILURES=0

# Fixture setup must bypass the guard under test; policy assertions invoke the
# shim explicitly below.
git() {
	/usr/bin/git "$@"
	return $?
}

pass() {
	TESTS=$((TESTS + 1))
	printf 'PASS %s\n' "$1"
	return 0
}
fail() {
	TESTS=$((TESTS + 1))
	FAILURES=$((FAILURES + 1))
	printf 'FAIL %s\n' "$1"
	return 0
}

mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config commit.gpgsign false
printf 'seed\n' >"${REPO}/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m seed
INITIAL_HEAD=$(git -C "$REPO" rev-parse HEAD)

assert_blocked() {
	local name="$1"
	local command="$2"
	local output=""
	output=$(python3 "$GUARD" --cwd "$REPO" --command "$command" 2>&1)
	local rc=$?
	if [[ "$rc" -eq 42 && "$output" == *"BLOCKED by canonical Git guard"* ]]; then
		pass "$name"
	else
		fail "$name (rc=$rc output=$output)"
	fi
	return 0
}

assert_allowed() {
	local name="$1"
	local cwd="$2"
	local command="$3"
	if python3 "$GUARD" --cwd "$cwd" --command "$command" >/dev/null 2>&1; then
		pass "$name"
	else
		fail "$name"
	fi
	return 0
}

assert_allowed_with_temp_root() {
	local name="$1"
	local cwd="$2"
	local command="$3"
	if TMPDIR="$TEST_ROOT" python3 "$GUARD" --cwd "$cwd" --command "$command" >/dev/null 2>&1; then
		pass "$name"
	else
		fail "$name"
	fi
	return 0
}

assert_blocked "blocks canonical detached switch" "git switch --detach main"
GUIDANCE_OUTPUT=$(python3 "$GUARD" --cwd "$REPO" --command "git pull --ff-only origin main" 2>&1)
RECOVERY_HELPER="${SCRIPT_DIR}/canonical-recovery-helper.sh"
QUOTED_RECOVERY_HELPER=$(python3 -c 'import shlex, sys; print(shlex.quote(sys.argv[1]))' "$RECOVERY_HELPER")
if [[ "$GUIDANCE_OUTPUT" == *"${QUOTED_RECOVERY_HELPER} fast-forward-current"* && -x "$RECOVERY_HELPER" ]]; then
	pass "blocked canonical pull points to an executable audited fast-forward workflow"
else
	fail "blocked canonical pull omits executable audited fast-forward guidance"
fi
assert_blocked "blocks canonical branch rename" "git branch -m main safety/example"
assert_blocked "blocks canonical branch creation with reflog flag" "git branch -l feature/new"
assert_blocked "blocks canonical non-default switch" "git switch safety/example"
assert_blocked "blocks git -C canonical reset" "git -C '$REPO' reset --hard HEAD"
assert_blocked "blocks relative git -C canonical reset" "cd '$TEST_ROOT' && git -C repo reset --hard HEAD"
# shellcheck disable=SC2016
assert_blocked "blocks variable-derived git -C target" '/usr/bin/git -C "$REPO" switch --detach main'
# shellcheck disable=SC2016
assert_blocked "blocks command-substitution git -C target" '/usr/bin/git -C "$(pwd)" branch -M renamed'
# shellcheck disable=SC2016
assert_blocked "blocks attached variable git-dir target" '/usr/bin/git --git-dir="$REPO/.git" --work-tree="$REPO" switch --detach main'
# shellcheck disable=SC2016
assert_blocked "blocks environment variable Git target" 'env GIT_DIR="$REPO/.git" GIT_WORK_TREE="$REPO" /usr/bin/git switch --detach main'
assert_blocked "blocks literal environment Git target" "env GIT_DIR='$REPO/.git' GIT_WORK_TREE='$REPO' /usr/bin/git switch --detach main"
# shellcheck disable=SC2016
assert_blocked "blocks quoted environment assignment name" 'env '\''GIT_DIR='\''"$REPO/.git" '\''GIT_WORK_TREE='\''"$REPO" /usr/bin/git switch --detach main'
assert_blocked "blocks tilde git -C target" '/usr/bin/git -C ~/repo switch --detach main'
assert_blocked "blocks wrapped canonical switch" "env TEST=1 command git switch feature/example"
assert_blocked "blocks nested absolute Git bypass" "bash -c '/usr/bin/git switch --detach main'"
assert_blocked "blocks chained canonical mutation" "git status && git branch -M renamed"
assert_blocked "blocks canonical update-ref plumbing" "/usr/bin/git update-ref refs/heads/main HEAD"
assert_blocked "blocks merge-tree writes in a canonical checkout" \
	"git merge-tree --write-tree '$INITIAL_HEAD' '$INITIAL_HEAD'"
assert_blocked "blocks destructive clean with exclude containing n" "git clean --force --exclude=nope"
assert_blocked "blocks interactive clean" "git clean --interactive"
assert_blocked "blocks canonical symbolic-ref update" "git symbolic-ref HEAD refs/heads/safety/example"
assert_blocked "blocks canonical symbolic-ref update with reflog reason" "git symbolic-ref -m reason HEAD refs/heads/safety/example"
assert_blocked "blocks canonical symbolic-ref deletion" "git symbolic-ref --delete refs/remotes/origin/HEAD"
assert_blocked "blocks canonical symbolic-ref short deletion" "git symbolic-ref -d refs/remotes/origin/HEAD"
assert_blocked "blocks canonical symbolic-ref combined deletion flags" "git symbolic-ref -qd refs/remotes/origin/HEAD"
assert_blocked "blocks canonical symbolic-ref unknown options" "git symbolic-ref --bogus refs/remotes/origin/HEAD"
assert_blocked "blocks canonical symbolic-ref without a ref" "git symbolic-ref --short"
assert_blocked "blocks canonical symbolic-ref option terminator" "git symbolic-ref -- refs/remotes/origin/HEAD"
assert_blocked "blocks canonical symbolic-ref second ref after option terminator" "git symbolic-ref -- HEAD refs/heads/safety/example"

if [[ "$(git -C "$REPO" symbolic-ref --short HEAD)" == "main" ]] &&
	[[ "$(git -C "$REPO" rev-parse HEAD)" == "$INITIAL_HEAD" ]] &&
	! git -C "$REPO" show-ref --verify --quiet refs/heads/safety/example; then
	pass "blocked sequence leaves canonical refs unchanged"
else
	fail "blocked sequence leaves canonical refs unchanged"
fi

assert_allowed "allows canonical status" "$REPO" "git status --short"
assert_allowed "allows canonical diff-files query" "$REPO" "git diff-files --name-only"
assert_allowed "allows canonical branch listing" "$REPO" "git branch -vv --no-abbrev"
assert_allowed "allows canonical branch pattern listing" "$REPO" "git branch --list 'feature/*'"
assert_allowed "allows canonical branch containment query" "$REPO" "git branch --contains main"
assert_allowed "allows canonical ref format validation" "$REPO" "git check-ref-format --branch feature/valid-ref"
assert_allowed "allows canonical ls-remote query" "$REPO" "git ls-remote origin refs/heads/main"
assert_allowed "allows canonical rev-list tag query" "$REPO" "git rev-list -n 1 HEAD"
assert_allowed "allows canonical rev-list count query" "$REPO" "git rev-list --count HEAD"
assert_allowed "allows canonical rev-list root query" "$REPO" "git rev-list --max-parents=0 HEAD"
assert_allowed "allows canonical symbolic-ref query" "$REPO" "git symbolic-ref refs/remotes/origin/HEAD"
assert_allowed "allows canonical short symbolic-ref query" "$REPO" "git symbolic-ref --short refs/remotes/origin/HEAD"
assert_allowed "allows reordered canonical symbolic-ref query flags" "$REPO" "git symbolic-ref refs/remotes/origin/HEAD --quiet --short"
assert_allowed "allows canonical non-recursive symbolic-ref query" "$REPO" "git symbolic-ref --no-recurse refs/remotes/origin/HEAD"
assert_allowed "allows canonical worktree creation" "$REPO" "git worktree add '$LINKED' -b feature/example"

PROSPECTIVE_CONTEXT=$(mktemp -d "${TEST_ROOT}/aidevops-prospective-todo.XXXXXX")
PROSPECTIVE_REPO="${PROSPECTIVE_CONTEXT}/repository.git"
git -C "$PROSPECTIVE_CONTEXT" init --bare -q repository.git
assert_allowed_with_temp_root "allows the pinned merge-tree probe in its isolated bare temp repo" \
	"$PROSPECTIVE_REPO" "git merge-tree --write-tree '$INITIAL_HEAD' '$INITIAL_HEAD'"
assert_blocked "blocks unrelated writes in the isolated bare temp repo" \
	"git -C '$PROSPECTIVE_REPO' update-ref refs/heads/main '$INITIAL_HEAD'"

git -C "$REPO" worktree add -q -b feature/example "$LINKED"
assert_allowed "allows normal Git mutation in linked worktree" "$LINKED" "git switch -c feature/linked-child"
assert_allowed "allows rev-list query in linked worktree" "$LINKED" "git rev-list --count HEAD"

git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
DEFAULT_BRANCH=$(
	unset -f git
	export PATH="${SCRIPT_DIR}:/usr/bin:/bin"
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/pulse-canonical-maintenance.sh"
	_get_default_branch_for_repo "$REPO"
)
if [[ "$DEFAULT_BRANCH" == "develop" ]]; then
	pass "deployed shim lets pulse resolve a non-main default branch"
else
	fail "deployed shim lets pulse resolve a non-main default branch (output=$DEFAULT_BRANCH)"
fi

if (cd "$REPO" && PATH="${SCRIPT_DIR}:/usr/bin:/bin" "$SHIM" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/unsafe >/dev/null 2>&1) ||
	(cd "$REPO" && PATH="${SCRIPT_DIR}:/usr/bin:/bin" "$SHIM" symbolic-ref --delete refs/remotes/origin/HEAD >/dev/null 2>&1); then
	fail "PATH shim blocks symbolic-ref mutation before execution"
elif [[ "$(git -C "$REPO" symbolic-ref --short refs/remotes/origin/HEAD)" == "origin/develop" ]]; then
	pass "PATH shim blocks symbolic-ref mutation before execution"
else
	fail "PATH shim left canonical symbolic ref changed"
fi

VALID_REF_RC=0
INVALID_REF_RC=0
NATIVE_INVALID_REF_RC=0
git check-ref-format --branch "invalid ref" >/dev/null 2>&1 || NATIVE_INVALID_REF_RC=$?
(cd "$REPO" && PATH="${SCRIPT_DIR}:/usr/bin:/bin" "$SHIM" check-ref-format --branch feature/valid-ref >/dev/null) || VALID_REF_RC=$?
(cd "$REPO" && PATH="${SCRIPT_DIR}:/usr/bin:/bin" "$SHIM" check-ref-format --branch "invalid ref" >/dev/null 2>&1) || INVALID_REF_RC=$?
if [[ "$VALID_REF_RC" -eq 0 && "$NATIVE_INVALID_REF_RC" -ne 0 && "$INVALID_REF_RC" -eq "$NATIVE_INVALID_REF_RC" ]]; then
	pass "PATH shim preserves native ref format validation"
else
	fail "PATH shim preserves native ref format validation (valid_rc=${VALID_REF_RC}, invalid_rc=${INVALID_REF_RC}, native_invalid_rc=${NATIVE_INVALID_REF_RC})"
fi

if (cd "$REPO" && PATH="${SCRIPT_DIR}:$PATH" "$SHIM" switch --detach main >/dev/null 2>&1); then
	fail "PATH shim blocks canonical detached switch"
else
	[[ "$(git -C "$REPO" branch --show-current)" == "main" ]] && pass "PATH shim blocks canonical detached switch before execution" || fail "PATH shim changed canonical HEAD"
fi
if (cd "$LINKED" && PATH="${SCRIPT_DIR}:$PATH" "$SHIM" switch -q -c feature/linked-child); then
	pass "PATH shim allows linked-worktree branch mutation"
else
	fail "PATH shim allows linked-worktree branch mutation"
fi

SHIM_BIN="${TEST_ROOT}/bin"
mkdir -p "$SHIM_BIN"
ln -s "$SHIM" "${SHIM_BIN}/git"
if (cd "$REPO" && env PATH="${SHIM_BIN}:/usr/bin:/bin" git status --short >/dev/null); then
	pass "deployed symlink shim resolves policy engine"
else
	fail "deployed symlink shim resolves policy engine"
fi
if (cd "$REPO" && env PATH="${SHIM_BIN}:/usr/bin:/bin" git switch --detach main >/dev/null 2>&1); then
	fail "deployed symlink shim blocks canonical mutation"
else
	[[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "main" ]] && pass "deployed symlink shim blocks canonical mutation" || fail "symlink shim changed canonical HEAD"
fi

OLD_BUNDLE="${TEST_ROOT}/.aidevops/runtime-bundles/old/agents/scripts"
NEW_BUNDLE="${TEST_ROOT}/.aidevops/runtime-bundles/new/agents/scripts"
mkdir -p "$OLD_BUNDLE" "$NEW_BUNDLE"
cp "$SHIM" "${OLD_BUNDLE}/git"
cp "$SHIM" "${NEW_BUNDLE}/git"
ln -s "$GUARD" "${OLD_BUNDLE}/canonical-git-command-guard.py"
ln -s "$GUARD" "${NEW_BUNDLE}/canonical-git-command-guard.py"
ln -s "${SCRIPT_DIR}/canonical_git_policy.py" "${OLD_BUNDLE}/canonical_git_policy.py"
ln -s "${SCRIPT_DIR}/canonical_git_policy.py" "${NEW_BUNDLE}/canonical_git_policy.py"
ln -s "${SCRIPT_DIR}/canonical_git_invocation.py" "${OLD_BUNDLE}/canonical_git_invocation.py"
ln -s "${SCRIPT_DIR}/canonical_git_invocation.py" "${NEW_BUNDLE}/canonical_git_invocation.py"
ln -s "${SCRIPT_DIR}/canonical_git_readonly.py" "${OLD_BUNDLE}/canonical_git_readonly.py"
ln -s "${SCRIPT_DIR}/canonical_git_readonly.py" "${NEW_BUNDLE}/canonical_git_readonly.py"
ln -s "${SCRIPT_DIR}/canonical_git_ref_queries.py" "${OLD_BUNDLE}/canonical_git_ref_queries.py"
ln -s "${SCRIPT_DIR}/canonical_git_ref_queries.py" "${NEW_BUNDLE}/canonical_git_ref_queries.py"
ln -s "${SCRIPT_DIR}/canonical_git_repository.py" "${OLD_BUNDLE}/canonical_git_repository.py"
ln -s "${SCRIPT_DIR}/canonical_git_repository.py" "${NEW_BUNDLE}/canonical_git_repository.py"
ln -s "${SCRIPT_DIR}/canonical_shell_parser.py" "${OLD_BUNDLE}/canonical_shell_parser.py"
ln -s "${SCRIPT_DIR}/canonical_shell_parser.py" "${NEW_BUNDLE}/canonical_shell_parser.py"
if (cd "$REPO" && env PATH="${OLD_BUNDLE}:${NEW_BUNDLE}:/usr/bin:/bin" "${OLD_BUNDLE}/git" status --short >/dev/null); then
	pass "runtime-bundle shim skips every aidevops shim generation"
else
	fail "runtime-bundle shim skips every aidevops shim generation"
fi

REENTRY_OUTPUT=$(env AIDEVOPS_CANONICAL_GIT_GUARD_ACTIVE=1 "$SHIM" status 2>&1)
REENTRY_RC=$?
if [[ "$REENTRY_RC" -eq 126 && "$REENTRY_OUTPUT" == *"recursive aidevops Git shim invocation"* ]]; then
	pass "recursive shim re-entry fails immediately with bounded diagnostic"
else
	fail "recursive shim re-entry is blocked (rc=$REENTRY_RC output=$REENTRY_OUTPUT)"
fi

SLOW_GIT="${TEST_ROOT}/slow-git"
printf '#!/usr/bin/env bash\nsleep 6\n' >"$SLOW_GIT"
chmod +x "$SLOW_GIT"
TIMEOUT_OUTPUT=$(python3 "$GUARD" --cwd "$REPO" --argv-json '["status"]' --real-git "$SLOW_GIT" 2>&1)
TIMEOUT_RC=$?
if [[ "$TIMEOUT_RC" -eq 42 && "$TIMEOUT_OUTPUT" == *"native Git repository probe timed out"* && "$TIMEOUT_OUTPUT" != *"Traceback"* ]]; then
	pass "native Git probe timeout fails closed without traceback"
else
	fail "native Git probe timeout is bounded (rc=$TIMEOUT_RC output=$TIMEOUT_OUTPUT)"
fi

LITERAL_REPO="${TEST_ROOT}/repo[1]"
mkdir -p "$LITERAL_REPO"
/usr/bin/git -C "$LITERAL_REPO" init -q -b main
if (cd "$LITERAL_REPO" && env PATH="${SHIM_BIN}:/usr/bin:/bin" git status --short >/dev/null); then
	pass "shim accepts already-expanded literal metacharacter path"
else
	fail "shim accepts already-expanded literal metacharacter path"
fi

printf '\nTests: %d, Failures: %d\n' "$TESTS" "$FAILURES"
[[ "$FAILURES" -eq 0 ]]
