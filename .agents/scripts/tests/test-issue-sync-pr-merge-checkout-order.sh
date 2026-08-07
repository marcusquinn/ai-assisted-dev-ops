#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#22613: the issue-sync-reusable.yml `sync-on-pr-merge`
# job uses two checkouts — an early framework checkout into `__aidevops/`
# (for the gh PATH shim) and a later "Checkout repo for TODO.md update" that
# pulls the caller repo into the workspace root.
#
# The second checkout uses `actions/checkout@v4` without `clean: false`, which
# default-deletes the workspace contents — including the `__aidevops/`
# subdirectory created by the early checkout. Without a re-checkout step
# AFTER the second checkout, the subsequent "Update TODO.md proof-log" step
# fails with `bash: __aidevops/.agents/scripts/issue-sync-git-push-helper.sh:
# No such file or directory` on every merged PR.
#
# This test asserts that the `sync-on-pr-merge` job has either:
#   (a) a `Re-checkout aidevops framework scripts` step AFTER the
#       `Checkout repo for TODO.md update` step, OR
#   (b) `clean: false` on the `Checkout repo for TODO.md update` step.
#
# Either invariant prevents the regression. The current canonical fix is (a).
# GH#27119 additionally requires the PATH shims to live outside GITHUB_WORKSPACE
# while keeping the canonical Git guard parked until trusted checkout completes.
# Otherwise actions/checkout either loses its selected executable during cleanup
# or routes its required init/config/remote/submodule commands through the guard.

set -euo pipefail

PASS=0
FAIL=0
RESULT_PREFIX_OK="PASS"
RESULT_PREFIX_BAD="FAIL"

# --- Resolve workflow path relative to this test ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/issue-sync-reusable.yml"

if [[ ! -f "${WORKFLOW_FILE}" ]]; then
	echo "${RESULT_PREFIX_BAD}: workflow file not found: ${WORKFLOW_FILE}"
	exit 1
fi

# --- Helper: extract a job's body (line range) by job key ---
# Usage: extract_job_lines <job_key>
# Prints the start and end line numbers (inclusive) of the job's YAML body.
# Job body runs from `<job_key>:` line until the next sibling job key or EOF.
extract_job_lines() {
	local job_key="$1"
	local file="${WORKFLOW_FILE}"
	local start
	start=$(awk -v k="${job_key}:" '
		/^  [a-z][a-zA-Z0-9_-]*:[[:space:]]*$/ {
			if ($1 == k) { print NR; exit }
		}
	' "${file}")

	if [[ -z "${start}" ]]; then
		printf '0 0\n'
		return 0
	fi

	# Find the next sibling job key (2-space indent, ends in colon) after start.
	local end
	end=$(awk -v start="${start}" '
		NR > start && /^  [a-z][a-zA-Z0-9_-]*:[[:space:]]*$/ { print NR-1; exit }
		END { if (!found) print NR }
	' "${file}")

	printf '%s %s\n' "${start}" "${end}"
	return 0
}

# --- Single assertion function ---
check() {
	local ok="$1" tc="$2" detail="$3"
	if [[ "${ok}" == "1" ]]; then
		PASS=$((PASS + 1))
		echo "${RESULT_PREFIX_OK}: ${tc}"
	else
		FAIL=$((FAIL + 1))
		echo "${RESULT_PREFIX_BAD}: ${tc} — ${detail}"
	fi
	return 0
}

# ============================================================
# Test 1: sync-on-pr-merge job exists
# ============================================================
read -r JOB_START JOB_END <<<"$(extract_job_lines 'sync-on-pr-merge')"
if [[ "${JOB_START}" == "0" ]]; then
	check 0 "sync-on-pr-merge job present" "job not found in ${WORKFLOW_FILE}"
	echo ""
	echo "Summary: ${PASS} passed, ${FAIL} failed"
	exit 1
fi
check 1 "sync-on-pr-merge job present" ""
JOB_BODY=$(sed -n "${JOB_START},${JOB_END}p" "${WORKFLOW_FILE}")

# ============================================================
# Test 2: PATH shims survive caller-repo workspace cleanup.
# ============================================================
# shellcheck disable=SC2016 # Assert literal workflow expressions, not test-shell expansion.
if printf '%s\n' "${JOB_BODY}" | grep -qE 'SHIM_DIR[[:space:]]*=[[:space:]]*"?\$\{?RUNNER_TEMP\}?/[^"]+"?' &&
	printf '%s\n' "${JOB_BODY}" | grep -qE 'echo[[:space:]]+"?\$\{?SHIM_DIR\}?"?[[:space:]]*>>[[:space:]]*"?\$\{?GITHUB_PATH\}?"?'; then
	check 1 "sync-on-pr-merge stages PATH shims outside GITHUB_WORKSPACE" ""
else
	check 0 "sync-on-pr-merge stages PATH shims outside GITHUB_WORKSPACE" \
		"GITHUB_PATH must reference a RUNNER_TEMP shim directory so actions/checkout cannot delete its selected git executable"
fi

# ============================================================
# Test 3: trusted checkouts cannot select the canonical Git guard. The guard is
# parked before the caller checkout, enabled only after framework restore, and
# parked again before actions/checkout performs its post-job cleanup.
# ============================================================
PARK_GUARD_REL_LINE=$(printf '%s\n' "${JOB_BODY}" | grep -nE 'mv[[:space:]]+"?\$\{SHIM_DIR\}/git"?[[:space:]]+"?\$\{SHIM_DIR\}/aidevops-git-guard"?' | cut -d: -f1 | head -1 || true)
CALLER_CHECKOUT_REL_LINE=$(printf '%s\n' "${JOB_BODY}" | grep -nE 'name:[[:space:]]+Checkout repo before closing-hygiene validation' | cut -d: -f1 || true)
RESTORE_REL_LINE=$(printf '%s\n' "${JOB_BODY}" | grep -nE 'name:[[:space:]]+Restore framework scripts before task resolution' | cut -d: -f1 || true)
ENABLE_GUARD_REL_LINE=$(printf '%s\n' "${JOB_BODY}" | grep -nE 'name:[[:space:]]+Enable canonical Git guard after trusted checkouts' | cut -d: -f1 || true)
RESOLVE_REL_LINE=$(printf '%s\n' "${JOB_BODY}" | grep -nE 'name:[[:space:]]+Resolve task-backed closing issues' | cut -d: -f1 || true)
PLANS_REL_LINE=$(printf '%s\n' "${JOB_BODY}" | grep -nE 'name:[[:space:]]+Sync PLANS\.md status from TODO\.md completions' | cut -d: -f1 || true)
PARK_CLEANUP_REL_LINE=$(printf '%s\n' "${JOB_BODY}" | grep -nE 'name:[[:space:]]+Park canonical Git guard before action cleanup' | cut -d: -f1 || true)

if [[ -n "${PARK_GUARD_REL_LINE}" && -n "${CALLER_CHECKOUT_REL_LINE}" &&
	"${PARK_GUARD_REL_LINE}" -lt "${CALLER_CHECKOUT_REL_LINE}" ]]; then
	check 1 "canonical Git guard is parked before trusted checkout" ""
else
	check 0 "canonical Git guard is parked before trusted checkout" "actions/checkout could select the canonical guard"
fi

if [[ -n "${RESTORE_REL_LINE}" && -n "${ENABLE_GUARD_REL_LINE}" && -n "${RESOLVE_REL_LINE}" &&
	"${RESTORE_REL_LINE}" -lt "${ENABLE_GUARD_REL_LINE}" &&
	"${ENABLE_GUARD_REL_LINE}" -lt "${RESOLVE_REL_LINE}" ]]; then
	check 1 "canonical Git guard is enabled after trusted checkouts" ""
else
	check 0 "canonical Git guard is enabled after trusted checkouts" "guard activation must follow framework restore and precede shell mutation steps"
fi

if [[ -n "${PLANS_REL_LINE}" && -n "${PARK_CLEANUP_REL_LINE}" &&
	"${PLANS_REL_LINE}" -lt "${PARK_CLEANUP_REL_LINE}" ]] &&
	printf '%s\n' "${JOB_BODY}" | grep -A1 -E 'name:[[:space:]]+Park canonical Git guard before action cleanup' | grep -qE 'if:[[:space:]]+always\(\)'; then
	check 1 "canonical Git guard is always parked before action cleanup" ""
else
	check 0 "canonical Git guard is always parked before action cleanup" "final guard parking must follow every guarded shell mutation and run even after failures"
fi

# Exercise the command sequence used by actions/checkout while the shim is
# parked. This fixture catches any future change that republishes `git` early.
FIXTURE_ROOT=$(mktemp -d)
trap 'rm -rf "${FIXTURE_ROOT}"' EXIT
FIXTURE_SHIM_DIR="${FIXTURE_ROOT}/shim"
FIXTURE_HOME="${FIXTURE_ROOT}/home"
FIXTURE_REPO="${FIXTURE_ROOT}/repo"
mkdir -p "${FIXTURE_SHIM_DIR}" "${FIXTURE_HOME}"
cp "${REPO_ROOT}/.agents/scripts/git" "${FIXTURE_SHIM_DIR}/aidevops-git-guard"
if (
	export HOME="${FIXTURE_HOME}"
	export PATH="${FIXTURE_SHIM_DIR}:/usr/bin:/bin"
	FIXTURE_GIT=$(command -v git) &&
		[[ "${FIXTURE_GIT}" != "${FIXTURE_SHIM_DIR}/git" ]] &&
		git config --global --add safe.directory "${FIXTURE_REPO}" &&
		git init -q "${FIXTURE_REPO}" &&
		git -C "${FIXTURE_REPO}" remote add origin "${FIXTURE_ROOT}/upstream.git" &&
		git -C "${FIXTURE_REPO}" config --local gc.auto 0 &&
		git -C "${FIXTURE_REPO}" submodule foreach --recursive true
); then
	check 1 "trusted checkout init/config/remote/submodule fixture bypasses parked guard" ""
else
	check 0 "trusted checkout init/config/remote/submodule fixture bypasses parked guard" "trusted actions/checkout commands did not use the runner Git binary"
fi
mv "${FIXTURE_SHIM_DIR}/aidevops-git-guard" "${FIXTURE_SHIM_DIR}/git"
ACTIVE_GIT=$(PATH="${FIXTURE_SHIM_DIR}:/usr/bin:/bin" command -v git)
mv "${FIXTURE_SHIM_DIR}/git" "${FIXTURE_SHIM_DIR}/aidevops-git-guard"
CLEANUP_GIT=$(PATH="${FIXTURE_SHIM_DIR}:/usr/bin:/bin" command -v git || true)
if [[ "${ACTIVE_GIT}" == "${FIXTURE_SHIM_DIR}/git" && "${CLEANUP_GIT}" != "${FIXTURE_SHIM_DIR}/git" ]]; then
	check 1 "guard activation is bounded to workflow shell steps" ""
else
	check 0 "guard activation is bounded to workflow shell steps" "post-job cleanup could still resolve the canonical guard"
fi
rm -rf "${FIXTURE_ROOT}"
trap - EXIT

# ============================================================
# Test 4: job has merged == true guard (defends against #22607
#         which falsely claimed the guard was missing)
# ============================================================
if printf '%s\n' "${JOB_BODY}" | grep -qE 'github\.event\.pull_request\.merged[[:space:]]*==[[:space:]]*true'; then
	check 1 "sync-on-pr-merge has merged == true guard" ""
else
	check 0 "sync-on-pr-merge has merged == true guard" "job-level if guard missing — premature completion-marking risk on non-merge events"
fi

# ============================================================
# Test 5: a single caller checkout establishes the validated TODO snapshot,
# followed by framework restoration and resolution. No later caller checkout
# may replace that snapshot before proof-log mutation.
# ============================================================
PROOF_REL_LINE=$(printf '%s\n' "${JOB_BODY}" | grep -nE 'name:[[:space:]]+Update TODO\.md proof-log' | cut -d: -f1 || true)
CALLER_CHECKOUT_COUNT=$(printf '%s\n' "${JOB_BODY}" | grep -cE 'name:[[:space:]]+Checkout repo (before closing-hygiene validation|for TODO\.md update)' || true)

if [[ -z "${CALLER_CHECKOUT_REL_LINE}" ]]; then
	check 0 "early caller checkout step present" "validated TODO snapshot checkout is missing"
else
	check 1 "early caller checkout step present" ""
fi

if [[ -n "$CALLER_CHECKOUT_REL_LINE" && -n "$RESTORE_REL_LINE" && -n "$RESOLVE_REL_LINE" && -n "$PROOF_REL_LINE" &&
	"$CALLER_CHECKOUT_REL_LINE" -lt "$RESTORE_REL_LINE" &&
	"$RESTORE_REL_LINE" -lt "$RESOLVE_REL_LINE" &&
	"$RESOLVE_REL_LINE" -lt "$PROOF_REL_LINE" ]]; then
	check 1 "caller snapshot -> framework restore -> resolve -> proof order preserved" ""
else
	check 0 "caller snapshot -> framework restore -> resolve -> proof order preserved" "step order is unsafe"
fi

if [[ "$CALLER_CHECKOUT_COUNT" -eq 1 ]]; then
	check 1 "validated TODO snapshot is not replaced by a later caller checkout" ""
else
	check 0 "validated TODO snapshot is not replaced by a later caller checkout" "found $CALLER_CHECKOUT_COUNT caller checkouts"
fi

# ============================================================
# Test 6: task-backed proof publication uses the protected-branch-safe issue
# sync publisher, while PLANS.md keeps the capability-scoped planner.
# ============================================================
PROOF_BODY=$(printf '%s\n' "${JOB_BODY}" | awk '
	/name:[[:space:]]+Update TODO\.md proof-log/ { capture=1 }
	capture && /name:[[:space:]]+Sync PLANS\.md status from TODO\.md completions/ { exit }
	capture { print }
')
PLANS_BODY=$(printf '%s\n' "${JOB_BODY}" | awk '
	/name:[[:space:]]+Sync PLANS\.md status from TODO\.md completions/ { capture=1 }
	capture && /name:[[:space:]]+Park canonical Git guard before action cleanup/ { exit }
	capture { print }
')
# shellcheck disable=SC2016 # Assert the literal workflow variable reference.
if printf '%s\n' "${JOB_BODY}" | grep -qE 'AIDEVOPS_PLANNING_GIT_BIN=.*RUNNER_GIT' &&
	printf '%s\n' "${PROOF_BODY}" | grep -qE 'issue-sync-git-push-helper\.sh"?[[:space:]]+publish-todo[[:space:]]+main' &&
	! printf '%s\n' "${PROOF_BODY}" | grep -qE 'planning_publish[[:space:]]' &&
	! printf '%s\n' "${PROOF_BODY}" | grep -qE '^[[:space:]]+git[[:space:]]+(config|add|commit|pull|push)' &&
	printf '%s\n' "${PLANS_BODY}" | grep -qE 'planning_publish[[:space:]]' &&
	! printf '%s\n' "${PLANS_BODY}" | grep -qE '^[[:space:]]+git[[:space:]]+(config|add|commit|pull|push)'; then
	check 1 "task proof uses PR-safe publication and plan status uses capability-scoped publication" ""
else
	check 0 "task proof uses PR-safe publication and plan status uses capability-scoped publication" \
		"TODO proof must use issue-sync-git-push-helper.sh; PLANS must use planning-publisher.sh"
fi

# ============================================================
# Test 7: every legacy issue-sync TODO writer routes through the same helper.
# The deterministic helper owns GH006 detection and PR deduplication.
# ============================================================
PUBLISH_CALL_COUNT=$(grep -cE 'issue-sync-git-push-helper\.sh"?[[:space:]]+publish-todo[[:space:]]+main' "$WORKFLOW_FILE" || true)
LEGACY_PUSH_COUNT=$(grep -cE 'issue-sync-git-push-helper\.sh[[:space:]]+push-todo[[:space:]]+main' "$WORKFLOW_FILE" || true)
if [[ "$PUBLISH_CALL_COUNT" -eq 4 && "$LEGACY_PUSH_COUNT" -eq 0 ]]; then
	check 1 "all four TODO publication paths share the idempotent PR-safe helper" ""
else
	check 0 "all four TODO publication paths share the idempotent PR-safe helper" \
		"publish calls=${PUBLISH_CALL_COUNT}, legacy pushes=${LEGACY_PUSH_COUNT}"
fi

# ============================================================
# Test 8: missing SYNC_PAT is informational because GH006 has a durable PR
# fallback. The workflow must not advise weakening protection or PAT bypass.
# ============================================================
if grep -q 'GH006 will update one protected-branch PR' "$WORKFLOW_FILE" &&
	! grep -qE 'gh secret set SYNC_PAT|will be rejected by branch protection|bypass(es)? branch protection' "$WORKFLOW_FILE"; then
	check 1 "credential notices describe PR fallback without bypass guidance" ""
else
	check 0 "credential notices describe PR fallback without bypass guidance" \
		"stale protected-branch bypass guidance remains"
fi

# ============================================================
# Test 9: every PR-safe publication step prefers the job token while exposing
# SYNC_PAT only as the bounded API fallback for disabled Actions PR creation.
# ============================================================
PR_TOKEN_FALLBACK_COUNT=$(grep -cE 'AIDEVOPS_ISSUE_SYNC_PR_TOKEN:[[:space:]]+\$\{\{ secrets\.SYNC_PAT \}\}' "$WORKFLOW_FILE" || true)
if [[ "$PR_TOKEN_FALLBACK_COUNT" -eq 4 ]]; then
	check 1 "all four TODO publication paths expose the bounded PR token fallback" ""
else
	check 0 "all four TODO publication paths expose the bounded PR token fallback" \
		"fallback exports=${PR_TOKEN_FALLBACK_COUNT}"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "Summary: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
	exit 1
fi
exit 0
