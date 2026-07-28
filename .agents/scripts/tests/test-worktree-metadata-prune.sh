#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
GIT_SHIM="${SCRIPT_DIR}/git"
TEST_ROOT=$(mktemp -d)
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
REPO="${TEST_ROOT}/repo"
LINKED="${TEST_ROOT}/linked"
FAILED_LINKED="${TEST_ROOT}/failed-linked"
RECOVERABLE_LINKED="${TEST_ROOT}/recoverable-linked"
RECOVERABLE_MISSING_LINKED="${TEST_ROOT}/recoverable-missing-linked"
MOVE_FAILED_LINKED="${TEST_ROOT}/move-failed-linked"
PRUNE_FAILED_LINKED="${TEST_ROOT}/prune-failed-linked"
DIRTY_LINKED="${TEST_ROOT}/dirty-linked"
OWNERSHIP_LINKED="${TEST_ROOT}/ownership-linked"
INTEGRATION_LINKED="${TEST_ROOT}/integration-linked"
RECOVERABLE_TRASH="${TEST_ROOT}/recoverable-trash"
RECOVERABLE_FALLBACK_SOURCE="${TEST_ROOT}/recoverable-fallback-source"
RECOVERABLE_FALLBACK_HOME="${TEST_ROOT}/recoverable-fallback-home"
RECOVERABLE_FALLBACK_BIN="${TEST_ROOT}/recoverable-fallback-bin"
SHIM_BIN="${TEST_ROOT}/bin"
TEST_PATH="${SHIM_BIN}:/usr/bin:/bin:/usr/sbin:/sbin"
FAILING_GIT="${TEST_ROOT}/failing-git"
QUERY_FAILING_GIT="${TEST_ROOT}/query-failing-git"
POST_PRUNE_QUERY_FAILING_GIT="${TEST_ROOT}/post-prune-query-failing-git"
POST_PRUNE_QUERY_STATE="${TEST_ROOT}/post-prune-query-state"
RUNTIME_PID=""

teardown() {
	if [[ "$RUNTIME_PID" =~ ^[0-9]+$ ]]; then
		kill "$RUNTIME_PID" 2>/dev/null || true
		wait "$RUNTIME_PID" 2>/dev/null || true
	fi
	rm -rf "$TEST_ROOT"
	return 0
}
trap teardown EXIT

mkdir -p "$REPO" "$SHIM_BIN"
/usr/bin/git -C "$REPO" init -q -b main
/usr/bin/git -C "$REPO" config user.name Test
/usr/bin/git -C "$REPO" config user.email test@example.invalid
/usr/bin/git -C "$REPO" config commit.gpgsign false
printf 'seed\n' >"${REPO}/README.md"
/usr/bin/git -C "$REPO" add README.md
/usr/bin/git -C "$REPO" commit -q -m seed
/usr/bin/git -C "$REPO" worktree add -q -b feature/prune-test "$LINKED"
/usr/bin/git -C "$REPO" worktree add -q -b feature/prune-failure "$FAILED_LINKED"
/usr/bin/git -C "$REPO" worktree add -q -b feature/recoverable-success "$RECOVERABLE_LINKED"
/usr/bin/git -C "$REPO" worktree add -q -b feature/recoverable-missing "$RECOVERABLE_MISSING_LINKED"
/usr/bin/git -C "$REPO" worktree add -q -b feature/recoverable-move-failure "$MOVE_FAILED_LINKED"
/usr/bin/git -C "$REPO" worktree add -q -b feature/recoverable-prune-failure "$PRUNE_FAILED_LINKED"
/usr/bin/git -C "$REPO" worktree add -q -b feature/recoverable-dirty "$DIRTY_LINKED"
/usr/bin/git -C "$REPO" worktree add -q -b feature/recoverable-ownership "$OWNERSHIP_LINKED"
/usr/bin/git -C "$REPO" worktree add -q -b feature/recoverable-integration "$INTEGRATION_LINKED"
ln -s "$GIT_SHIM" "${SHIM_BIN}/git"

if PATH="$TEST_PATH" git -C "$REPO" worktree prune >/dev/null 2>&1; then
	printf 'FAIL canonical Git shim unexpectedly allowed direct metadata prune\n'
	exit 1
fi

mkdir -p "${TEST_ROOT}/home"
if ! output=$(
	cd "$REPO" || exit 1
	HOME="${TEST_ROOT}/home" PATH="$TEST_PATH" \
		bash "${SCRIPT_DIR}/worktree-helper.sh" remove "$LINKED" 2>&1
); then
	printf 'FAIL worktree-helper removal failed with canonical Git shim active: %s\n' "$output"
	exit 1
fi

if /usr/bin/git -C "$REPO" worktree list --porcelain | grep -Fqx "worktree $LINKED"; then
	printf 'FAIL linked worktree metadata remains after helper removal\n'
	exit 1
fi

printf 'PASS worktree-helper prunes metadata with canonical Git shim active\n'

cat >"$FAILING_GIT" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"worktree prune"* ]]; then
	exit 1
fi
if [[ "$*" == *"worktree list --porcelain"* ]]; then
	/usr/bin/git "$@" || exit 1
	printf 'worktree %s\n\n' "${FAILED_LINKED_FOR_TEST:?}"
	exit 0
fi
exec /usr/bin/git "$@"
EOF
chmod +x "$FAILING_GIT"

if output=$(
	cd "$REPO" || exit 1
	HOME="${TEST_ROOT}/home" PATH="$TEST_PATH" AIDEVOPS_REAL_GIT_BIN="$FAILING_GIT" \
		FAILED_LINKED_FOR_TEST="$FAILED_LINKED" \
		bash "${SCRIPT_DIR}/worktree-helper.sh" remove "$FAILED_LINKED" 2>&1
); then
	printf 'FAIL worktree-helper reported success when metadata prune failed\n'
	exit 1
fi
if [[ "$output" != *"Partial cleanup:"* || "$output" != *"Recovery:"* ]]; then
	printf 'FAIL prune failure omitted partial-cleanup recovery guidance: %s\n' "$output"
	exit 1
fi
printf 'PASS worktree-helper returns partial-cleanup guidance when metadata prune fails\n'

cat >"$QUERY_FAILING_GIT" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"worktree list --porcelain"* ]]; then
	exit 1
fi
exec /usr/bin/git "$@"
EOF
chmod +x "$QUERY_FAILING_GIT"
# shellcheck source=../audit-worktree-removal-helper.sh
source "${SCRIPT_DIR}/audit-worktree-removal-helper.sh"
if AIDEVOPS_REAL_GIT_BIN="$QUERY_FAILING_GIT" \
	prune_missing_worktree_metadata "$REPO" "${TEST_ROOT}/missing-query-target"; then
	printf 'FAIL metadata query failure was treated as successful cleanup\n'
	exit 1
fi
printf 'PASS metadata query failure cannot report cleanup success\n'

if (
	_worktree_cleanup_real_git() {
		return 0
	}
	prune_missing_worktree_metadata "$REPO" "${TEST_ROOT}/missing-empty-git-target"
); then
	printf 'FAIL empty native Git path was treated as successful cleanup\n'
	exit 1
fi
printf 'PASS empty native Git path cannot report cleanup success\n'

cat >"$POST_PRUNE_QUERY_FAILING_GIT" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"worktree list --porcelain"* ]]; then
	query_count=0
	if [[ -f "${POST_PRUNE_QUERY_STATE_FOR_TEST:?}" ]]; then
		read -r query_count <"$POST_PRUNE_QUERY_STATE_FOR_TEST"
	fi
	query_count=$((query_count + 1))
	printf '%s\n' "$query_count" >"$POST_PRUNE_QUERY_STATE_FOR_TEST"
	if [[ "$query_count" -eq 1 ]]; then
		printf 'worktree %s\n\n' "${POST_PRUNE_TARGET_FOR_TEST:?}"
		exit 0
	fi
	exit 1
fi
if [[ "$*" == *"worktree prune"* ]]; then
	exit 0
fi
exec /usr/bin/git "$@"
EOF
chmod +x "$POST_PRUNE_QUERY_FAILING_GIT"
if AIDEVOPS_REAL_GIT_BIN="$POST_PRUNE_QUERY_FAILING_GIT" \
	POST_PRUNE_QUERY_STATE_FOR_TEST="$POST_PRUNE_QUERY_STATE" \
	POST_PRUNE_TARGET_FOR_TEST="${TEST_ROOT}/missing-post-prune-query-target" \
	prune_missing_worktree_metadata "$REPO" "${TEST_ROOT}/missing-post-prune-query-target"; then
	printf 'FAIL post-prune metadata query failure was treated as successful cleanup\n'
	exit 1
fi
printf 'PASS post-prune metadata query failure cannot report cleanup success\n'

# Exercise the degraded-visibility removal primitive with native Git. The
# candidate must be moved recoverably, metadata must be proven absent, and only
# then may the stable completion event be emitted.
git() {
	/usr/bin/git "$@"
	return $?
}
is_registered_canonical() {
	local worktree_path="$1"
	: "$worktree_path"
	return 1
}
worktree_has_changes() {
	local worktree_path="$1"
	if /usr/bin/git -C "$worktree_path" status --porcelain 2>/dev/null | grep -q .; then
		return 0
	fi
	return 1
}
is_worktree_owned_by_others() {
	local worktree_path="$1"
	: "$worktree_path"
	return 1
}
unregister_worktree() {
	local worktree_path="$1"
	: "$worktree_path"
	return 0
}
claim_worktree_ownership() {
	local worktree_path="$1"
	local worktree_branch="$2"
	: "$worktree_path" "$worktree_branch"
	return 0
}
localdev_auto_branch_rm() {
	local worktree_branch="$1"
	: "$worktree_branch"
	return 0
}
capture_worktree_process_cwds() {
	printf '%s\n' "/unrelated-readable-cwd"
	return "${_WT_CWD_CAPTURE_DEGRADED_RC:-2}"
}

[[ -z "${RED+x}" ]] && RED=""
[[ -z "${YELLOW+x}" ]] && YELLOW=""
[[ -z "${BLUE+x}" ]] && BLUE=""
[[ -z "${NC+x}" ]] && NC=""
_WTAR_WH_CALLER="worktree-helper.sh"
# shellcheck source=../worktree-clean-lib.sh
source "${SCRIPT_DIR}/worktree-clean-lib.sh"
worktree_is_in_grace_period() {
	local worktree_path="$1"
	: "$worktree_path"
	return 1
}
_branch_has_active_interactive_claim() {
	local worktree_path="$1"
	local worktree_branch="$2"
	: "$worktree_path" "$worktree_branch"
	return 1
}
_clean_branch_has_exact_merged_pr() {
	local worktree_branch="$1"
	local merged_prs="${2:-}"
	_clean_branch_list_contains_exact "$worktree_branch" "$merged_prs"
	return $?
}
branch_was_pushed() {
	local worktree_branch="$1"
	: "$worktree_branch"
	return 1
}
_branch_exists_on_any_remote() {
	local worktree_branch="$1"
	: "$worktree_branch"
	return 0
}

missing_move_target="${TEST_ROOT}/never-created-worktree"
if ! _clean_move_worktree_recoverably "$missing_move_target" ||
	[[ "$_WT_CLEAN_RECOVERABLE_FAILURE_DETAIL" != "path-already-gone" ]]; then
	printf 'FAIL absent recoverable source was not treated as idempotent success\n'
	exit 1
fi
printf 'PASS absent recoverable source is an explicit idempotent success\n'

rm -rf "$RECOVERABLE_MISSING_LINKED"
missing_recovery_output=$(
	cd "$REPO" || exit 1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$RECOVERABLE_TRASH" \
		_clean_remove_classified_worktree "$RECOVERABLE_MISSING_LINKED" "feature/recoverable-missing" \
		"false" "false" "visibility=degraded" "$REPO" "$_WT_CLEAN_MODE_RECOVERABLE" "true"
)
[[ "$(printf '%s\n' "$missing_recovery_output" | grep -cFx "$_WT_CLEAN_COMPLETED_EVENT")" -eq 1 ]] || {
	printf 'FAIL absent recoverable source did not complete metadata cleanup: %s\n' "$missing_recovery_output"
	exit 1
}
if /usr/bin/git -C "$REPO" worktree list --porcelain | grep -Fqx "worktree $RECOVERABLE_MISSING_LINKED"; then
	printf 'FAIL absent recoverable source left exact Git worktree metadata registered\n'
	exit 1
fi
printf 'PASS absent recoverable source continues through verified metadata pruning\n'

recovery_output=$(
	cd "$REPO" || exit 1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$RECOVERABLE_TRASH" \
		_clean_remove_classified_worktree "$RECOVERABLE_LINKED" "feature/recoverable-success" \
		"false" "false" "visibility=degraded" "$REPO" "$_WT_CLEAN_MODE_RECOVERABLE" "true"
)
[[ "$(printf '%s\n' "$recovery_output" | grep -cFx "$_WT_CLEAN_COMPLETED_EVENT")" -eq 1 ]] || {
	printf 'FAIL recoverable cleanup did not emit exactly one verified completion event: %s\n' "$recovery_output"
	exit 1
}
[[ ! -e "$RECOVERABLE_LINKED" ]] || {
	printf 'FAIL recoverable cleanup left original candidate path in place\n'
	exit 1
}
if /usr/bin/git -C "$REPO" worktree list --porcelain | grep -Fqx "worktree $RECOVERABLE_LINKED"; then
	printf 'FAIL recoverable cleanup left exact Git worktree metadata registered\n'
	exit 1
fi
compgen -G "${RECOVERABLE_TRASH}/*/recoverable-linked" >/dev/null || {
	printf 'FAIL recoverable cleanup did not preserve candidate files in trash\n'
	exit 1
}
printf 'PASS degraded cleanup emits completion only after recoverable move and exact metadata absence\n'

mkdir -p "$RECOVERABLE_FALLBACK_SOURCE" "$RECOVERABLE_FALLBACK_HOME" "$RECOVERABLE_FALLBACK_BIN"
printf 'recoverable fixture\n' >"${RECOVERABLE_FALLBACK_SOURCE}/fixture.txt"
for backend in trash gio; do
	cat >"${RECOVERABLE_FALLBACK_BIN}/${backend}" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
	chmod +x "${RECOVERABLE_FALLBACK_BIN}/${backend}"
done
if ! HOME="$RECOVERABLE_FALLBACK_HOME" PATH="$RECOVERABLE_FALLBACK_BIN:/usr/bin:/bin" \
	_clean_move_worktree_recoverably "$RECOVERABLE_FALLBACK_SOURCE"; then
	printf 'FAIL recoverable cleanup stopped after trash and gio backend failures: %s\n' \
		"${_WT_CLEAN_RECOVERABLE_FAILURE_DETAIL:-unknown}"
	exit 1
fi
[[ ! -e "$RECOVERABLE_FALLBACK_SOURCE" ]] || {
	printf 'FAIL recoverable cleanup fallback left the source path in place\n'
	exit 1
}
compgen -G "${RECOVERABLE_FALLBACK_HOME}/.Trash/aidevops-worktree-cleanup-*/recoverable-fallback-source" >/dev/null || {
	printf 'FAIL recoverable cleanup did not fall through to the home trash bucket\n'
	exit 1
}
printf 'PASS failed trash and gio backends fall through to the home trash bucket\n'

move_failure_output=""
if move_failure_output=$(
	cd "$REPO" || exit 1
	_clean_move_worktree_recoverably() {
		local worktree_path="$1"
		: "$worktree_path"
		return 1
	}
	_clean_remove_classified_worktree "$MOVE_FAILED_LINKED" "feature/recoverable-move-failure" \
		"false" "false" "visibility=degraded" "$REPO" "$_WT_CLEAN_MODE_RECOVERABLE" "true"
); then
	printf 'FAIL recoverable move failure reported cleanup success\n'
	exit 1
fi
[[ -d "$MOVE_FAILED_LINKED" && "$move_failure_output" != *"$_WT_CLEAN_COMPLETED_EVENT"* ]] || {
	printf 'FAIL recoverable move failure removed candidate or emitted completion\n'
	exit 1
}
printf 'PASS recoverable move failure remains fail-closed with zero completion events\n'

prune_failure_output=""
if prune_failure_output=$(
	cd "$REPO" || exit 1
	prune_missing_worktree_metadata() {
		local repo_context="$1"
		local worktree_path="$2"
		: "$repo_context" "$worktree_path"
		return 1
	}
	AIDEVOPS_WORKTREE_TRASH_ROOT="$RECOVERABLE_TRASH" \
		_clean_remove_classified_worktree "$PRUNE_FAILED_LINKED" "feature/recoverable-prune-failure" \
		"false" "false" "visibility=degraded" "$REPO" "$_WT_CLEAN_MODE_RECOVERABLE" "true"
); then
	printf 'FAIL metadata prune failure reported cleanup success\n'
	exit 1
fi
[[ ! -e "$PRUNE_FAILED_LINKED" && "$prune_failure_output" != *"$_WT_CLEAN_COMPLETED_EVENT"* ]] || {
	printf 'FAIL metadata prune failure emitted completion or left an irreversible state\n'
	exit 1
}
/usr/bin/git -C "$REPO" worktree list --porcelain | grep -Fqx "worktree $PRUNE_FAILED_LINKED" || {
	printf 'FAIL metadata prune failure fixture did not preserve stale metadata for recovery\n'
	exit 1
}
printf 'PASS metadata prune failure remains recoverable and emits zero completion events\n'

printf 'dirty state\n' >"${DIRTY_LINKED}/dirty.txt"
dirty_output=""
if dirty_output=$(
	cd "$REPO" || exit 1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$RECOVERABLE_TRASH" \
		_clean_remove_classified_worktree "$DIRTY_LINKED" "feature/recoverable-dirty" \
		"true" "false" "visibility=degraded" "$REPO" "$_WT_CLEAN_MODE_RECOVERABLE" "true"
); then
	printf 'FAIL --force-merged authorized dirty degraded cleanup\n'
	exit 1
fi
[[ -f "${DIRTY_LINKED}/dirty.txt" && "$dirty_output" != *"$_WT_CLEAN_COMPLETED_EVENT"* ]] || {
	printf 'FAIL dirty degraded candidate was altered or reported complete\n'
	exit 1
}
printf 'PASS --force-merged cannot authorize dirty degraded cleanup\n'

owned_output=""
if owned_output=$(
	cd "$REPO" || exit 1
	is_worktree_owned_by_others() {
		local worktree_path="$1"
		: "$worktree_path"
		return 0
	}
	_clean_remove_classified_worktree "$OWNERSHIP_LINKED" "feature/recoverable-ownership" \
		"false" "false" "visibility=degraded" "$REPO" "$_WT_CLEAN_MODE_RECOVERABLE" "true"
); then
	printf 'FAIL owned degraded candidate reported cleanup success\n'
	exit 1
fi
[[ -d "$OWNERSHIP_LINKED" && "$owned_output" != *"$_WT_CLEAN_COMPLETED_EVENT"* ]] || {
	printf 'FAIL owned degraded candidate was altered or reported complete\n'
	exit 1
}

claimed_output=""
if claimed_output=$(
	cd "$REPO" || exit 1
	_branch_has_active_interactive_claim() {
		local worktree_path="$1"
		local worktree_branch="$2"
		: "$worktree_path" "$worktree_branch"
		return 0
	}
	_clean_remove_classified_worktree "$OWNERSHIP_LINKED" "feature/recoverable-ownership" \
		"false" "false" "visibility=degraded" "$REPO" "$_WT_CLEAN_MODE_RECOVERABLE" "true"
); then
	printf 'FAIL claimed degraded candidate reported cleanup success\n'
	exit 1
fi
[[ -d "$OWNERSHIP_LINKED" && "$claimed_output" != *"$_WT_CLEAN_COMPLETED_EVENT"* ]] || {
	printf 'FAIL claimed degraded candidate was altered or reported complete\n'
	exit 1
}
printf 'PASS owned and claimed degraded candidates remain blocked\n'

if (
	WORKTREE_REMOVAL_GUARD_REASON="$_WT_CWD_REASON_DEGRADED"
	_clean_branch_has_exact_merged_pr() { return 1; }
	_clean_degraded_visibility_fallback_allowed "$OWNERSHIP_LINKED" "feature/recoverable-ownership" \
		"merged" "" "" "" "visibility=degraded"
); then
	printf 'FAIL degraded cleanup accepted a candidate without terminal PR proof\n'
	exit 1
fi
printf 'PASS degraded cleanup requires terminal PR proof\n'

# Replace the focused ownership stubs with the production registry before the
# integrated pass. A distinct stable runtime PID forces cleanup to prove that
# both post-acquisition checks use the exact leaf-PID lease it just claimed.
export WORKTREE_REGISTRY_DIR="${TEST_ROOT}/registry"
export WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DIR}/worktree-registry.db"
sleep 30 &
RUNTIME_PID=$!
export OPENCODE_PID="$RUNTIME_PID"
# shellcheck source=../shared-worktree-registry.sh
source "${SCRIPT_DIR}/shared-worktree-registry.sh"

integration_output=$(
	cd "$REPO" || exit 1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$RECOVERABLE_TRASH" \
		_clean_remove_merged "main" "$REPO" "false" "feature/recoverable-integration" "" "true" ""
)
[[ ! -e "$INTEGRATION_LINKED" ]] || {
	printf 'FAIL degraded terminal-PR candidate was not removed by the integrated cleanup pass\n'
	exit 1
}
[[ "$(printf '%s\n' "$integration_output" | grep -cFx "$_WT_CLEAN_COMPLETED_EVENT")" -eq 1 ]] || {
	printf 'FAIL integrated degraded cleanup did not emit one verified completion event: %s\n' "$integration_output"
	exit 1
}
if /usr/bin/git -C "$REPO" worktree list --porcelain | grep -Fqx "worktree $INTEGRATION_LINKED"; then
	printf 'FAIL integrated degraded cleanup left exact metadata registered\n'
	exit 1
fi
printf 'PASS integrated degraded cleanup removes a clean terminal-PR candidate recoverably\n'
