#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-task-id-collision-guard.sh — Test harness for task-id-collision-guard.sh
#
# Covers all acceptance criteria cases:
#   1. Reject: t-ID > counter AND not in linked issue title
#   2. Allow: t-ID ≤ counter (claimed)
#   3. Allow: cross-reference confirmed via linked issue title
#   4. Allow: commit with no t-IDs at all
#   5. Allow: fail-open on gh API failure / offline
#   6. Allow (bypass): --no-verify / TASK_ID_GUARD_DISABLE=1
#   7. CI mode: check-pr scans range and finds violations
#   8. Allow: stale-worktree — t-IDs claimed after worktree creation (GH#19054)
#   9. Allow: leading-zero .task-counter doesn't trigger octal crash (GH#19667)
#  10. Allow: Ref #NNN where linked issue title contains the t-ID (GH#19783)
#  11. Allow: For #NNN where linked issue title contains the t-ID (GH#19783)
#  12. Reject: Ref #NNN where linked issue title does NOT contain the t-ID (GH#19783)
#  13. Reject: PR title tNNN not in any commit AND not confirmed via linked issue (GH#19987)
#  14. Allow: PR title tNNN confirmed via PR body Resolves #NNN with matching issue title (GH#19987)
#  15. Allow: t-ID ≤ counter when claimed in repo history (GH#20291)
#  16. Allow: check-pr skips merge commits via --no-merges regardless of subject (t2895)
#  17. Allow: subagent/library name with t<digits> substring not extracted as t-ID (GH#21402 / t2993)
#  18. Allow: multiple product names with embedded t<digits> cause no false positives (GH#21402 / t2993)
#  19. Allow: cached branch-subject range claim is read even when it is the final line (GH#22558)
#  22. Allow: push squash commit uses its associated PR body as linked-issue proof (GH#29591)
#  23. Reject: push commit above the counter without associated issue proof (GH#29591)

set -u

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${SCRIPT_DIR}/../../hooks/task-id-collision-guard.sh"
DEPLOYED_GUARD="$HOME/.aidevops/agents/hooks/task-id-collision-guard.sh"

# Prefer deployed if repo copy not found
if [[ ! -f "$GUARD" ]]; then
	GUARD="$DEPLOYED_GUARD"
fi

if [[ ! -f "$GUARD" ]]; then
	printf '%s[FATAL]%s task-id-collision-guard.sh not found at:\n' "$RED" "$NC" >&2
	printf '  %s\n' "${SCRIPT_DIR}/../../hooks/task-id-collision-guard.sh" >&2
	printf '  %s\n' "$DEPLOYED_GUARD" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pass() {
	local name="${1:-}"
	printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="${1:-}"
	local detail="${2:-}"
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$name"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  - ${name}: ${detail}"
	return 0
}

# Run the guard with a message file and a mock counter.
# Sets up a temporary git repo to provide a merge base with .task-counter = N.
# Returns the exit code of the guard.
#
# Optional 4th arg: space-separated list of t-IDs to pre-claim on the work
# branch via "chore: claim tNNN [test-nonce]" commits. Phase 1 (t2567) requires
# a branch claim commit for t-IDs ≤ counter that lack a Resolves footer. Pass
# the t-IDs referenced in the commit message so the guard allows them.
_run_with_counter() {
	local msg="${1:-}"
	local counter_val="${2:-10}"
	local gh_available="${3:-no}" # "yes" or "no"
	local claim_ids="${4:-}"      # optional space-sep t-IDs to pre-claim on branch

	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# Create a temporary git repo that acts as the remote/merge-base
	local base_repo="${tmpdir}/base"
	mkdir -p "$base_repo"
	git -C "$base_repo" init -q
	git -C "$base_repo" config user.email "test@test.local"
	git -C "$base_repo" config user.name "Test"
	git -C "$base_repo" config commit.gpgsign false
	git -C "$base_repo" config tag.gpgsign false
	printf '%s' "$counter_val" >"${base_repo}/.task-counter"
	git -C "$base_repo" add .task-counter
	git -C "$base_repo" commit -q -m "init"

	# Create a work repo branched off the base
	local work_repo="${tmpdir}/work"
	git clone -q "$base_repo" "$work_repo" 2>/dev/null
	git -C "$work_repo" config user.email "test@test.local"
	git -C "$work_repo" config user.name "Test"
	git -C "$work_repo" config commit.gpgsign false
	git -C "$work_repo" config tag.gpgsign false

	# Add claim commits for any t-IDs that need branch-level authorisation
	# (Phase 1 / t2567: claim-task-id.sh makes claim commits on the feature
	# branch, so the guard finds them in merge-base..HEAD).
	local claim_id
	for claim_id in $claim_ids; do
		printf 'claim-marker' >"${work_repo}/${claim_id}-claim.txt"
		git -C "$work_repo" add "${claim_id}-claim.txt"
		git -C "$work_repo" commit -q -m "chore: claim ${claim_id} [test-nonce]"
	done

	# Add a commit so HEAD != merge-base (even when no claim IDs provided)
	printf 'change' >"${work_repo}/change.txt"
	git -C "$work_repo" add change.txt
	git -C "$work_repo" commit -q -m "wip"

	# Write the message file
	local msg_file="${tmpdir}/COMMIT_EDITMSG"
	printf '%s' "$msg" >"$msg_file"

	# Run the guard from the work repo context.
	# Optionally disable gh CLI by PATH manipulation.
	local rc
	if [[ "$gh_available" == "no" ]]; then
		# Stub gh to fail so the guard falls back to fail-open
		local fake_bin="${tmpdir}/bin"
		mkdir -p "$fake_bin"
		printf '#!/usr/bin/env bash\nexit 1\n' >"${fake_bin}/gh"
		chmod +x "${fake_bin}/gh"
		PATH="${fake_bin}:$PATH" \
			GIT_DIR="${work_repo}/.git" \
			bash "$GUARD" "$msg_file" 2>/dev/null
		rc=$?
	else
		GIT_DIR="${work_repo}/.git" \
			bash "$GUARD" "$msg_file" 2>/dev/null
		rc=$?
	fi
	return "$rc"
}

# ---------------------------------------------------------------------------
# Case 1: Reject — t-ID > counter, no cross-ref
# ---------------------------------------------------------------------------
test_rejects_invented_tid() {
	local name="case-1: rejects invented t-ID > counter"
	# Counter = 100; message references t99999 which is beyond counter
	local msg="feat(foo): bar (t99999)"
	local rc
	_run_with_counter "$msg" "100"
	rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 1 (reject), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 2: Allow — t-ID ≤ counter, with branch claim commit (Phase 1 t2567)
# ---------------------------------------------------------------------------
test_allows_claimed_tid() {
	local name="case-2: allows claimed t-ID ≤ counter when branch has claim commit"
	local msg="feat(foo): implement t50 feature"
	local rc
	# Pass "t50" as the 4th arg so _run_with_counter adds "chore: claim t50 [...]"
	# to the work branch before the "wip" commit. Phase 1 requires this to allow
	# a t-ID ≤ counter without a Resolves footer.
	_run_with_counter "$msg" "100" "no" "t50"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (allow), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 3: Allow — no t-IDs at all
# ---------------------------------------------------------------------------
test_allows_no_tids() {
	local name="case-3: allows commit with no t-IDs"
	local msg="chore: update README with installation instructions"
	local rc
	_run_with_counter "$msg" "100"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (allow), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 4: Allow — fail-open when gh API fails (closing issue present, gh errors)
# This validates acceptance criterion: "fail-safe on gh API failure or offline state"
# ---------------------------------------------------------------------------
test_failopen_on_gh_failure() {
	local name="case-4: fail-open when gh API fails with closing issue present"
	# Message has t99999 (> counter) AND a Resolves footer, but gh fails
	local msg
	msg=$(printf 'feat(foo): invented id (t99999)\n\nResolves #123\n')
	local rc
	# Pass gh_available=no — stubs gh to exit 1 (API/offline failure)
	_run_with_counter "$msg" "100" "no"
	rc=$?
	# Fail-open = exit 0 (guard cannot verify cross-ref, CI will catch on push)
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (fail-open on gh failure), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 5: Allow — bypass via TASK_ID_GUARD_DISABLE=1
# ---------------------------------------------------------------------------
test_bypass_env_var() {
	local name="case-5: bypass via TASK_ID_GUARD_DISABLE=1"
	local msg="feat(foo): bar (t99999)"
	local msg_file
	msg_file=$(mktemp)
	printf '%s' "$msg" >"$msg_file"
	local rc
	TASK_ID_GUARD_DISABLE=1 bash "$GUARD" "$msg_file" 2>/dev/null
	rc=$?
	rm -f "$msg_file"
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (bypass), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 6: Allow — merge commit subject is skipped
# ---------------------------------------------------------------------------
test_skips_merge_commits() {
	local name="case-6: skips merge commit subjects"
	local msg="Merge branch 'feature/t99999-foo' into main"
	local rc
	_run_with_counter "$msg" "100"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (merge commit skipped), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 7: CI check-pr mode — scans range, finds violations
# Uses a real git repo but stubs the gh CLI
# ---------------------------------------------------------------------------
test_check_pr_mode() {
	local name="case-7: check-pr mode detects invented t-ID in range"

	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local base_repo="${tmpdir}/base"
	mkdir -p "$base_repo"
	git -C "$base_repo" init -q
	git -C "$base_repo" config user.email "test@test.local"
	git -C "$base_repo" config user.name "Test"
	git -C "$base_repo" config commit.gpgsign false
	printf '100' >"${base_repo}/.task-counter"
	git -C "$base_repo" add .task-counter
	git -C "$base_repo" commit -q -m "init"

	local work_repo="${tmpdir}/work"
	git clone -q "$base_repo" "$work_repo" 2>/dev/null
	git -C "$work_repo" config user.email "test@test.local"
	git -C "$work_repo" config user.name "Test"
	git -C "$work_repo" config commit.gpgsign false

	# Add a commit with an invented t-ID
	printf 'change' >"${work_repo}/change.txt"
	git -C "$work_repo" add change.txt
	git -C "$work_repo" commit -q -m "feat: invented id (t99999)"

	# Stub gh to fail so cross-ref lookup does not influence result
	local fake_bin="${tmpdir}/bin"
	mkdir -p "$fake_bin"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${fake_bin}/gh"
	chmod +x "${fake_bin}/gh"

	local rc
	PATH="${fake_bin}:$PATH" \
		GIT_DIR="${work_repo}/.git" \
		bash "$GUARD" check-pr 9999 2>/dev/null
	rc=$?

	if [[ "$rc" -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 1 (violation detected), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 8: Allow — stale-worktree scenario (GH#19054) with Phase 1 branch claims
#
# Simulates the observed failure:
#   1. Worktree created at main tip X (counter=10)
#   2. Worker claims t11 and t12 ON ITS OWN BRANCH (via claim-task-id.sh), which
#      in the real framework adds "chore: claim tNNN [nonce]" commits to the branch.
#      This is consistent with how claim-task-id.sh operates on feature branches
#      (as visible in this repo's git log: the CAS commits land on the feature branch).
#   3. Commit in the worktree references t11 and t12
#
# With the OLD counter-only guard: merge-base=X → counter=10 → t11,t12 > 10 → BLOCK
# With the stale-worktree fix (GH#19054): _resolve_current_counter reads HEAD (12) → ALLOW
# With Phase 1 (t2567): branch claim commits for t11,t12 are found → ALLOW
# ---------------------------------------------------------------------------
test_stale_worktree_scenario() {
	local name="case-8: allows t-IDs claimed on feature branch (stale-worktree with Phase 1)"

	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# Create the "origin" repo with counter=10 on main
	local base_repo="${tmpdir}/base"
	mkdir -p "$base_repo"
	git -C "$base_repo" init -q
	git -C "$base_repo" config user.email "test@test.local"
	git -C "$base_repo" config user.name "Test"
	git -C "$base_repo" config commit.gpgsign false
	git -C "$base_repo" config tag.gpgsign false
	printf '10' >"${base_repo}/.task-counter"
	git -C "$base_repo" add .task-counter
	git -C "$base_repo" commit -q -m "init: counter=10"

	# Clone to simulate a worktree created at counter=10
	local work_repo="${tmpdir}/work"
	git clone -q "$base_repo" "$work_repo" 2>/dev/null
	git -C "$work_repo" config user.email "test@test.local"
	git -C "$work_repo" config user.name "Test"
	git -C "$work_repo" config commit.gpgsign false
	git -C "$work_repo" config tag.gpgsign false

	# Add a WIP commit to work_repo so HEAD diverges from origin/main
	printf 'impl' >"${work_repo}/impl.txt"
	git -C "$work_repo" add impl.txt
	git -C "$work_repo" commit -q -m "wip: implementation placeholder"

	# Simulate claim-task-id.sh runs ON THE FEATURE BRANCH (counter → 11 → 12).
	# In the real framework, workers run claim-task-id.sh in their worktree, which
	# appends the CAS claim commit to the current branch (not to origin/main).
	# This allows _branch_has_claim() to find t11 and t12 in merge-base..HEAD.
	printf '11' >"${work_repo}/.task-counter"
	git -C "$work_repo" add .task-counter
	git -C "$work_repo" commit -q -m "chore: claim t11 [test-nonce]"
	printf '12' >"${work_repo}/.task-counter"
	git -C "$work_repo" add .task-counter
	git -C "$work_repo" commit -q -m "chore: claim t12 [test-nonce]"

	# Write a commit message referencing t11 and t12 (both legitimately claimed on branch).
	# NOTE: the old message referenced t2109 which is a real framework task ID — using
	# it here would trigger Phase 1 for t2109 (no branch claim for t2109 in the test repo).
	# Keep the message to only reference t-IDs that have claim commits on this branch.
	local msg="feat: implement stale-worktree fix for t11 t12"
	local msg_file="${tmpdir}/COMMIT_EDITMSG"
	printf '%s' "$msg" >"$msg_file"

	# Stub gh to fail — guard must rely on branch claim + counter comparison
	local fake_bin="${tmpdir}/bin"
	mkdir -p "$fake_bin"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${fake_bin}/gh"
	chmod +x "${fake_bin}/gh"

	local rc
	PATH="${fake_bin}:$PATH" \
		GIT_DIR="${work_repo}/.git" \
		bash "$GUARD" "$msg_file" 2>/dev/null
	rc=$?

	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (t11,t12 ≤ counter 12 and branch claims found), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 9: Allow — leading-zero .task-counter doesn't trigger octal crash
# (GH#19667: _resolve_current_counter octal-trap symmetry fix)
# ---------------------------------------------------------------------------
test_octal_trap_leading_zero_counter() {
	local name="case-9: allows t-ID ≤ leading-zero counter (octal-trap in _resolve_current_counter)"
	# Counter written as "09" — was read by _resolve_current_counter via
	# [[ "$val" -gt "$best" ]] which triggers bash's octal parser on the
	# second comparison iteration (when $best is already "09").
	# After the fix: ((10#$val > 10#$best)) forces decimal, so 9 ≤ 9 → allowed.
	# Phase 1 (t2567): also requires "chore: claim t9 [...]" on the branch.
	local msg="feat: implement GH#19667 t9"
	local rc
	_run_with_counter "$msg" "09" "no" "t9"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (t9 ≤ counter 09 in base-10), got $rc (likely octal crash)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Helper: run the guard with a mocked gh CLI that returns a known issue title.
# Args:
#   msg         = commit message text
#   counter_val = .task-counter value
#   issue_num   = issue number the mock gh should respond to
#   issue_title = title the mock gh returns for that issue
# ---------------------------------------------------------------------------
_run_with_mock_gh_title() {
	local msg="${1:-}"
	local counter_val="${2:-10}"
	local issue_num="${3:-}"
	local issue_title="${4:-}"

	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# Create base git repo
	local base_repo="${tmpdir}/base"
	mkdir -p "$base_repo"
	git -C "$base_repo" init -q
	git -C "$base_repo" config user.email "test@test.local"
	git -C "$base_repo" config user.name "Test"
	git -C "$base_repo" config commit.gpgsign false
	git -C "$base_repo" config tag.gpgsign false
	printf '%s' "$counter_val" >"${base_repo}/.task-counter"
	git -C "$base_repo" add .task-counter
	git -C "$base_repo" commit -q -m "init"

	local work_repo="${tmpdir}/work"
	git clone -q "$base_repo" "$work_repo" 2>/dev/null
	git -C "$work_repo" config user.email "test@test.local"
	git -C "$work_repo" config user.name "Test"
	git -C "$work_repo" config commit.gpgsign false
	git -C "$work_repo" config tag.gpgsign false

	printf 'change' >"${work_repo}/change.txt"
	git -C "$work_repo" add change.txt
	git -C "$work_repo" commit -q -m "wip"

	local msg_file="${tmpdir}/COMMIT_EDITMSG"
	printf '%s' "$msg" >"$msg_file"

	# Mock gh: return the supplied title as JSON when queried for the given issue_num
	local fake_bin="${tmpdir}/bin"
	mkdir -p "$fake_bin"
	cat >"${fake_bin}/gh" <<GHEOF
#!/usr/bin/env bash
# Mock gh for test: responds to "gh issue view <N> --json title --jq .title"
# Scan all arguments for a numeric token matching the expected issue number.
found=0
for arg in "\$@"; do
    if [[ "\$arg" == "${issue_num}" ]]; then
        found=1
        break
    fi
done
if [[ "\$found" == "1" ]]; then
    printf '%s\n' "${issue_title}"
    exit 0
fi
exit 1
GHEOF
	chmod +x "${fake_bin}/gh"

	local rc
	PATH="${fake_bin}:$PATH" \
		GIT_DIR="${work_repo}/.git" \
		bash "$GUARD" "$msg_file" 2>/dev/null
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		return 0
	fi
	return 1
}

# ---------------------------------------------------------------------------
# Case 10: Allow — Ref #NNN where issue title contains the t-ID
# (AC1 from issue #19783)
# ---------------------------------------------------------------------------
test_ref_keyword_with_matching_title() {
	local name="case-10: allows Ref #NNN when linked issue title contains the t-ID"
	# Counter = 100; t99999 > counter; but Ref footer links to issue 42 whose
	# title contains t99999, confirming the ID was legitimately claimed.
	local msg
	msg=$(printf 't99999: brief for self-healing improvement\n\nRef #42')
	local rc
	_run_with_mock_gh_title "$msg" "100" "42" "t99999: feat(issue-sync): detect umbrella-style parent-tasks"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (Ref #NNN confirmed via issue title), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 11: Allow — For #NNN where issue title contains the t-ID
# (AC2 from issue #19783)
# ---------------------------------------------------------------------------
test_for_keyword_with_matching_title() {
	local name="case-11: allows For #NNN when linked issue title contains the t-ID"
	local msg
	msg=$(printf 't99999: add brief for parent-task phase\n\nFor #42')
	local rc
	_run_with_mock_gh_title "$msg" "100" "42" "t99999: parent-task phase-1 planning"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (For #NNN confirmed via issue title), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 12: Reject — Ref #NNN where issue title does NOT contain the t-ID
# (AC3 from issue #19783 — regression guard)
# ---------------------------------------------------------------------------
test_ref_keyword_without_matching_title() {
	local name="case-12: rejects Ref #NNN when linked issue title does NOT contain the t-ID"
	# t99999 > counter; Ref footer points to issue 42 whose title is unrelated
	local msg
	msg=$(printf 't99999: some commit\n\nRef #42')
	local rc
	_run_with_mock_gh_title "$msg" "100" "42" "chore: unrelated task with no matching ID"
	rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 1 (Ref with non-matching title still blocked), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Helper: run check-pr mode with a mocked gh that returns a specific PR
# title and body, plus optional issue view responses.
#
# The mock gh reads its return values from environment variables at runtime,
# so special characters in titles/bodies are handled safely.
#
# Args:
#   arg1 = pr_num       (PR number to pass to check-pr, e.g. 9999)
#   arg2 = counter_val  (.task-counter value, e.g. "100")
#   arg3 = pr_title     (value gh returns for the PR title)
#   arg4 = pr_body      (value gh returns for the PR body; may contain Resolves)
#   arg5 = issue_num    (issue number the mock gh.issue view handles; optional)
#   arg6 = issue_title  (title the mock gh returns for that issue; optional)
# Returns the exit code of the guard.
# ---------------------------------------------------------------------------
_run_check_pr_with_pr_title() {
	local pr_num="${1:-9999}"
	local counter_val="${2:-100}"
	local pr_title="${3:-}"
	local pr_body="${4:-}"
	local issue_num="${5:-}"
	local issue_title="${6:-}"

	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# Base repo with .task-counter
	local base_repo="${tmpdir}/base"
	mkdir -p "$base_repo"
	git -C "$base_repo" init -q
	git -C "$base_repo" config user.email "test@test.local"
	git -C "$base_repo" config user.name "Test"
	git -C "$base_repo" config commit.gpgsign false
	git -C "$base_repo" config tag.gpgsign false
	printf '%s' "$counter_val" >"${base_repo}/.task-counter"
	git -C "$base_repo" add .task-counter
	git -C "$base_repo" commit -q -m "init"

	local work_repo="${tmpdir}/work"
	git clone -q "$base_repo" "$work_repo" 2>/dev/null
	git -C "$work_repo" config user.email "test@test.local"
	git -C "$work_repo" config user.name "Test"
	git -C "$work_repo" config commit.gpgsign false
	git -C "$work_repo" config tag.gpgsign false

	# A clean commit with NO tNNN reference — simulates a worker commit that
	# never called claim-task-id.sh but the PR title carries the t-ID.
	printf 'change' >"${work_repo}/change.txt"
	git -C "$work_repo" add change.txt
	git -C "$work_repo" commit -q -m "feat(issue-sync): parent-side detection for umbrella-style parent-task backfill"

	# Mock gh reads return values from env vars set at invocation time.
	# Using a single-quoted heredoc delimiter ('GHEOF') so that the env var
	# references inside are literal strings — they expand at mock runtime.
	local fake_bin="${tmpdir}/bin"
	mkdir -p "$fake_bin"
	cat >"${fake_bin}/gh" <<'GHEOF'
#!/usr/bin/env bash
# Mock gh for PR title test.
# GH_MOCK_PR_TITLE, GH_MOCK_PR_BODY, GH_MOCK_ISSUE_NUM, GH_MOCK_ISSUE_TITLE
# are set in the outer environment when the guard is invoked.
if [[ "$1" == "pr" && "$2" == "view" ]]; then
	for arg in "$@"; do
		if [[ "$arg" == ".title" ]]; then
			printf '%s\n' "${GH_MOCK_PR_TITLE:-}"
			exit 0
		fi
		if [[ "$arg" == ".body" ]]; then
			printf '%s\n' "${GH_MOCK_PR_BODY:-}"
			exit 0
		fi
	done
fi
if [[ "$1" == "issue" && "$2" == "view" ]]; then
	expected="${GH_MOCK_ISSUE_NUM:-__none__}"
	for arg in "$@"; do
		if [[ "$arg" == "$expected" ]]; then
			printf '%s\n' "${GH_MOCK_ISSUE_TITLE:-}"
			exit 0
		fi
	done
	exit 1
fi
exit 1
GHEOF
	chmod +x "${fake_bin}/gh"

	local rc
	PATH="${fake_bin}:$PATH" \
		GIT_DIR="${work_repo}/.git" \
		GH_MOCK_PR_TITLE="$pr_title" \
		GH_MOCK_PR_BODY="$pr_body" \
		GH_MOCK_ISSUE_NUM="$issue_num" \
		GH_MOCK_ISSUE_TITLE="$issue_title" \
		bash "$GUARD" check-pr "$pr_num" 2>/dev/null
	rc=$?
	return "$rc"
}

# ---------------------------------------------------------------------------
# Case 13: Reject — PR title tNNN not in any commit AND not confirmed via issue
# (GH#19987: gap in check-pr where title t-ID was invisible to the guard)
# ---------------------------------------------------------------------------
test_check_pr_rejects_invented_tid_in_title() {
	local name="case-13: check-pr blocks PR title tNNN absent from commits and unconfirmed via issue"
	# Counter = 100; single commit has no tNNN reference.
	# PR title advertises t9999 (> counter); PR body has no Resolves footer.
	# Expected: exit 1 — invented t-ID in title should be blocked.
	local rc
	_run_check_pr_with_pr_title \
		"9999" \
		"100" \
		"t9999: feat(issue-sync): invented title ID" \
		"" \
		"" \
		""
	rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 1 (invented tNNN in PR title blocked), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 14: Allow — PR title tNNN confirmed via PR body Resolves #NNN
# where the linked issue title contains the same t-ID (GH#19987).
# This validates that the title+body concatenation gives _check_message
# the cross-reference context it needs to allow a legitimate PR.
# ---------------------------------------------------------------------------
test_check_pr_allows_pr_title_tid_confirmed_via_body() {
	local name="case-14: check-pr allows PR title tNNN when PR body Resolves #NNN with matching issue title"
	# Counter = 100; t9999 > counter BUT Resolves #42 links to an issue
	# whose title starts with t9999 — confirming the ID was legitimately claimed.
	local rc
	_run_check_pr_with_pr_title \
		"9999" \
		"100" \
		"t9999: feat(issue-sync): legitimate claimed title ID" \
		"Resolves #42" \
		"42" \
		"t9999: feat(issue-sync): legitimate claimed title ID"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (PR title tNNN confirmed via body Resolves + issue title), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test case 15: Allow t-ID ≤ counter when claimed in repo history (GH#20291)
# Scenario: PR body contains prose reference to a t-ID that was claimed in
# a prior merged PR. The guard should allow it via repo-wide claim lookup.
# ---------------------------------------------------------------------------
test_repo_wide_claim_in_prose() {
	local name="case-15: allow t-ID ≤ counter when claimed in repo history (prose reference)"
	# Counter = 100; t50 ≤ counter but claimed in prior merged commit.
	# PR body contains prose "the t50 REST fallback covers..." — should allow.
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# Create a temporary git repo with a prior merged claim commit
	local base_repo="${tmpdir}/base"
	mkdir -p "$base_repo"
	git -C "$base_repo" init -q -b main
	git -C "$base_repo" config user.email "test@test.local"
	git -C "$base_repo" config user.name "Test"
	git -C "$base_repo" config commit.gpgsign false
	git -C "$base_repo" config tag.gpgsign false
	printf '100' >"${base_repo}/.task-counter"
	git -C "$base_repo" add .task-counter
	git -C "$base_repo" commit -q -m "init"

	# Create a work repo with a prior merged claim commit on main
	local work_repo="${tmpdir}/work"
	git -C "$base_repo" clone -q . "$work_repo"
	git -C "$work_repo" config user.email "test@test.local"
	git -C "$work_repo" config user.name "Test"
	git -C "$work_repo" config commit.gpgsign false
	git -C "$work_repo" config tag.gpgsign false

	# Add a prior claim commit on main (simulating a merged PR)
	touch "${work_repo}/t50-marker.txt"
	git -C "$work_repo" add "t50-marker.txt"
	git -C "$work_repo" commit -q -m "chore: claim t50 [prior-merge]"

	# Create a feature branch for the new PR
	git -C "$work_repo" checkout -q -b feature/t51-new-feature
	touch "${work_repo}/feature.txt"
	git -C "$work_repo" add "feature.txt"
	git -C "$work_repo" commit -q -m "feat: add new feature"

	# Create a commit message with prose reference to t50 (claimed in prior merge)
	local msg_file="${tmpdir}/msg.txt"
	cat >"$msg_file" <<'EOF'
feat: implement feature

The t50 REST fallback covers GraphQL exhaustion scenarios.
This feature builds on that foundation.
EOF

	# Run the guard in the feature branch context
	local rc
	(
		cd "$work_repo" || exit 1
		TASK_ID_GUARD_DEBUG=0 bash "$GUARD" "$msg_file"
	)
	rc=$?

	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (t50 claimed in repo history), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 16: check-pr skips merge commits via --no-merges regardless of subject
# (t2895 — the previous `^(Merge|fixup!|squash!)` subject-regex filter was
# bypassed by custom merge subjects, e.g. "feat: pulled main into feature".
# `--no-merges` filters structurally on commit topology, not subject text.)
#
# This is the canonical regression test for the t2895 perf fix. With the OLD
# range (`merge-base..HEAD`) and the OLD subject filter:
#   - merge commit with subject "feat: pull main (mentions t99999)" was scanned
#   - t99999 > counter, no Resolves, no branch claim → REJECT
# With the NEW range (`origin/main..HEAD --no-merges`):
#   - merge commit excluded structurally, regardless of subject text
#   - only the feature-branch commit is scanned (clean, no t-IDs) → ALLOW
# ---------------------------------------------------------------------------
test_check_pr_skips_merge_commits_via_no_merges() {
	local name="case-16: check-pr skips merge commits via --no-merges (custom merge subject)"

	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# Base/origin repo with .task-counter=100
	local base_repo="${tmpdir}/base"
	mkdir -p "$base_repo"
	git -C "$base_repo" init -q -b main
	git -C "$base_repo" config user.email "test@test.local"
	git -C "$base_repo" config user.name "Test"
	git -C "$base_repo" config commit.gpgsign false
	git -C "$base_repo" config tag.gpgsign false
	printf '100' >"${base_repo}/.task-counter"
	git -C "$base_repo" add .task-counter
	git -C "$base_repo" commit -q -m "init: counter=100"

	# Clone work_repo (origin/main = init)
	local work_repo="${tmpdir}/work"
	git clone -q "$base_repo" "$work_repo" 2>/dev/null
	git -C "$work_repo" config user.email "test@test.local"
	git -C "$work_repo" config user.name "Test"
	git -C "$work_repo" config commit.gpgsign false
	git -C "$work_repo" config tag.gpgsign false

	# Feature branch off main
	git -C "$work_repo" checkout -q -b feature/test-branch

	# Clean feature commit (no t-IDs)
	printf 'feature' >"${work_repo}/feature.txt"
	git -C "$work_repo" add feature.txt
	git -C "$work_repo" commit -q -m "feat: clean feature commit"

	# Move main forward with an upstream commit (any subject, no invented IDs)
	printf 'upstream' >"${base_repo}/upstream.txt"
	git -C "$base_repo" add upstream.txt
	git -C "$base_repo" commit -q -m "feat: upstream change"

	# Fetch upstream commit into work_repo (updates origin/main)
	git -C "$work_repo" fetch -q origin main

	# Merge origin/main into feature with a CUSTOM SUBJECT containing an
	# invented t-ID. The OLD subject-regex filter `^(Merge|fixup!|squash!)`
	# does NOT match "feat: pull main..." and would scan this merge commit,
	# finding t99999 in the subject and rejecting. The NEW `--no-merges`
	# filter excludes it structurally regardless of subject text.
	git -C "$work_repo" merge -q --no-ff \
		-m "feat: pull main into feature (mentions t99999)" \
		origin/main

	# Stub gh to fail so PR title scan fails-open and doesn't affect the result
	local fake_bin="${tmpdir}/bin"
	mkdir -p "$fake_bin"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${fake_bin}/gh"
	chmod +x "${fake_bin}/gh"

	local rc
	PATH="${fake_bin}:$PATH" \
		GIT_DIR="${work_repo}/.git" \
		bash "$GUARD" check-pr 9999 2>/dev/null
	rc=$?

	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (merge commit excluded by --no-merges regardless of subject text), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 19: cached branch subjects keep a trailing newline for while-read loops
# (GH#22558 — command substitution strips trailing newlines when populating the
# cache. Range claims are found by a `while read` loop rather than the single-ID
# grep path, so the final cached line must still be delivered to the loop.)
# ---------------------------------------------------------------------------
test_check_pr_cached_branch_subjects_read_final_range_claim() {
	local name="case-19: cached branch subjects preserve final range-claim line"

	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local base_repo="${tmpdir}/base"
	mkdir -p "$base_repo"
	git -C "$base_repo" init -q -b main
	git -C "$base_repo" config user.email "test@test.local"
	git -C "$base_repo" config user.name "Test"
	git -C "$base_repo" config commit.gpgsign false
	git -C "$base_repo" config tag.gpgsign false
	printf '200' >"${base_repo}/.task-counter"
	git -C "$base_repo" add .task-counter
	git -C "$base_repo" commit -q -m "init: counter=200"

	local work_repo="${tmpdir}/work"
	git clone -q "$base_repo" "$work_repo" 2>/dev/null
	git -C "$work_repo" config user.email "test@test.local"
	git -C "$work_repo" config user.name "Test"
	git -C "$work_repo" config commit.gpgsign false
	git -C "$work_repo" config tag.gpgsign false
	git -C "$work_repo" checkout -q -b feature/test-branch

	# The range claim is the oldest commit in base..HEAD, so `git log` emits it
	# last. This reproduces the cached-output missing-newline failure path.
	printf 'claim' >"${work_repo}/claim.txt"
	git -C "$work_repo" add claim.txt
	git -C "$work_repo" commit -q -m "chore: claim t120..t130 [test-nonce]"

	printf 'feature' >"${work_repo}/feature.txt"
	git -C "$work_repo" add feature.txt
	git -C "$work_repo" commit -q -m "feat: implement t123 feature"

	local fake_bin="${tmpdir}/bin"
	mkdir -p "$fake_bin"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${fake_bin}/gh"
	chmod +x "${fake_bin}/gh"

	local rc
	PATH="${fake_bin}:$PATH" \
		GIT_DIR="${work_repo}/.git" \
		bash "$GUARD" check-pr 9999 2>/dev/null
	rc=$?

	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (final cached range claim read by while loop), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 17: Allow — subagent/library name containing t<digits> is not a t-ID
#           (GH#21402 / t2993 — context7 false-positive class)
# ---------------------------------------------------------------------------
test_no_false_positive_subagent_name() {
	local name="case-17: allows commit body containing context7 without false t7 extraction"
	# t2991 is legitimately claimed on the branch (counter=3000, so t2991 <= 3000).
	# The body also contains "context7" which the OLD regex extracted as "t7".
	# With the fix, "t7" must NOT be extracted from "context7" — only "t2991" is.
	local msg
	msg="t2991: fix subagent permission task using context7"$'\n\n'"Resolves #9999"
	local rc
	_run_with_counter "$msg" "3000" "no" "t2991"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (allow — context7 must not yield false t7); got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 18: Allow — multiple subagent names with t<digits> substrings, no false positives
#           (GH#21402 / t2993 — broader false-positive coverage)
# ---------------------------------------------------------------------------
test_no_false_positive_multiple_subagent_names() {
	local name="case-18: allows body with gpt4, next13, wp7-cms without false t-ID extraction"
	# Counter = 50 so any t-ID > 50 would be rejected unless cross-referenced.
	# The body contains only library/product names with embedded digit sequences
	# (gpt4 → t4, next13 → t13, wp7-cms → no t match) but NO legitimate t-ID.
	# With fix: no t-IDs extracted → allowed.
	# Without fix: t4 and t13 extracted → rejected as > counter without cross-ref.
	local msg="chore: update product list with gpt4, next13, and wp7-cms integrations"
	local rc
	_run_with_counter "$msg" "50"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (allow — gpt4/next13 must not yield false t4/t13); got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 20: Allow — canonical task-brief paths do not make valid PR IDs malformed
# ---------------------------------------------------------------------------
test_check_pr_allows_canonical_task_brief_path() {
	local name="case-20: check-pr allows a canonical task-brief path in the PR body"
	local rc
	_run_check_pr_with_pr_title \
		"9999" \
		"20000" \
		"t18139: implement repository campaigns" \
		$'Implementation: todo/tasks/t18139-brief.md\n\nResolves #42' \
		"42" \
		"t18139: implement repository campaigns"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (canonical task-brief path accepted), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 21: Reject — malformed IDs remain blocked inside task-like brief paths
# ---------------------------------------------------------------------------
test_check_pr_rejects_malformed_task_brief_path() {
	local name="case-21: check-pr rejects a malformed task ID in a brief path"
	local rc
	_run_check_pr_with_pr_title \
		"9999" \
		"20000" \
		"chore: document implementation" \
		"Implementation: todo/tasks/t018139-brief.md" \
		"" \
		""
	rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 1 (malformed task ID blocked), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 22: Allow — a push squash commit gets linked-issue proof from its PR body
# ---------------------------------------------------------------------------
test_check_push_associated_pr_issue_proof() {
	local name="case-22: check-push allows squash commit validated by associated PR issue"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local work_repo="${tmpdir}/work"
	mkdir -p "$work_repo"
	git -C "$work_repo" init -q -b main
	git -C "$work_repo" config user.email "test@test.local"
	git -C "$work_repo" config user.name "Test"
	git -C "$work_repo" config commit.gpgsign false
	git -C "$work_repo" config tag.gpgsign false
	printf '100' >"${work_repo}/.task-counter"
	git -C "$work_repo" add .task-counter
	git -C "$work_repo" commit -q -m "init: counter=100"
	local before_sha
	before_sha=$(git -C "$work_repo" rev-parse HEAD)
	printf 'change' >"${work_repo}/change.txt"
	git -C "$work_repo" add change.txt
	git -C "$work_repo" commit -q -m "t99999: valid squashed change"
	local after_sha
	after_sha=$(git -C "$work_repo" rev-parse HEAD)

	local fake_bin="${tmpdir}/bin"
	mkdir -p "$fake_bin"
	cat >"${fake_bin}/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$1" == "api" ]]; then
	found_jq=0
	for arg in "$@"; do
		if [[ "$arg" == '.[] | (.title + "\n\n" + (.body // ""))' ]]; then
			found_jq=1
		fi
	done
	[[ "$found_jq" == "1" ]] || exit 1
	printf 't99999: valid squashed change\n\nResolves #42\n'
	exit 0
fi
if [[ "$1" == "issue" && "$2" == "view" ]]; then
	printf 't99999: claimed task\n'
	exit 0
fi
exit 1
GHEOF
	chmod +x "${fake_bin}/gh"

	local rc=0
	PATH="${fake_bin}:$PATH" \
		GITHUB_REPOSITORY="example/repo" \
		GIT_DIR="${work_repo}/.git" \
		GIT_WORK_TREE="$work_repo" \
		bash "$GUARD" check-push "$before_sha" "$after_sha" 2>/dev/null || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (associated PR body links matching issue), got $rc"
	fi

	name="case-23: check-push rejects commit without associated PR issue proof"
	cat >"${fake_bin}/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$1" == "api" ]]; then
	exit 0
fi
exit 1
GHEOF
	chmod +x "${fake_bin}/gh"
	rc=0
	PATH="${fake_bin}:$PATH" \
		GITHUB_REPOSITORY="example/repo" \
		GIT_DIR="${work_repo}/.git" \
		GIT_WORK_TREE="$work_repo" \
		bash "$GUARD" check-push "$before_sha" "$after_sha" 2>/dev/null || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 1 (no associated issue proof), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
main() {
	printf 'Running task-id-collision-guard tests...\n\n'

	test_rejects_invented_tid
	test_allows_claimed_tid
	test_allows_no_tids
	test_failopen_on_gh_failure
	test_bypass_env_var
	test_skips_merge_commits
	test_check_pr_mode
	test_stale_worktree_scenario
	test_octal_trap_leading_zero_counter
	test_ref_keyword_with_matching_title
	test_for_keyword_with_matching_title
	test_ref_keyword_without_matching_title
	test_check_pr_rejects_invented_tid_in_title
	test_check_pr_allows_pr_title_tid_confirmed_via_body
	test_repo_wide_claim_in_prose
	test_check_pr_skips_merge_commits_via_no_merges
	test_check_pr_cached_branch_subjects_read_final_range_claim
	test_no_false_positive_subagent_name
	test_no_false_positive_multiple_subagent_names
	test_check_pr_allows_canonical_task_brief_path
	test_check_pr_rejects_malformed_task_brief_path
	test_check_push_associated_pr_issue_proof

	printf '\n'
	printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
	if [[ "$FAIL" -gt 0 ]]; then
		printf '\nFailed tests:%b\n' "$ERRORS"
		return 1
	fi
	return 0
}

main "$@"
