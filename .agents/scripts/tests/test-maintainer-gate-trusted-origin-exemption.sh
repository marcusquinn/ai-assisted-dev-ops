#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-maintainer-gate-trusted-origin-exemption.sh — t2451 regression guard.
#
# Structural assertions over `.github/workflows/maintainer-gate-reusable.yml`:
#
#   A. The file parses as valid YAML.
#   B. Job 1 Check 2 includes a HAS_TRUSTED_ORIGIN_LABEL computation
#      referencing both origin:worker and origin:interactive, with
#      explicit github-actions[bot]/REPO_OWNER issue-author gating.
#   C. The HAS_TRUSTED_ORIGIN_LABEL path includes the non-maintainer
#      comment defence-in-depth check (author_association == "NONE"
#      or "CONTRIBUTOR").
#   D. The exemption condition accepts HAS_TRUSTED_ORIGIN_LABEL
#      alongside the existing github-actions[bot] and HAS_AUTOMATION_LABEL
#      paths.
#   E. Job 3 (retrigger-pr-checks) mirrors the trusted-origin skip for
#      origin:worker PRs with OWNER/MEMBER author and a trusted issue author
#      with no non-maintainer comments.
#   F. REPO_OWNER env var is wired through both Job 1 and Job 3 steps.
#   G. GH#24546/GH#24958 private-org CONTRIBUTOR/COLLABORATOR fallback uses authenticated
#      collaborator permission metadata and fails closed.
#
# Static shape checks cover the shared trust rules. Job 3's inline shell is also
# executed below with mocked REST metadata, status publication, and rerun APIs.
#
# NOTE: not using `set -e` — assertions capture non-zero exits.

set -uo pipefail

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# Resolve the workflow file relative to the test (tests live in .agents/scripts/tests/)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/maintainer-gate-reusable.yml"
TEST_TMP_ROOT=""
if ! TEST_TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/test-maintainer-gate-job3-XXXXXX"); then
	printf 'ERROR: failed to create temporary directory\n' >&2
	exit 1
fi
trap '[[ -n "${TEST_TMP_ROOT:-}" ]] && rm -rf -- "$TEST_TMP_ROOT"' EXIT

if [[ ! -f "$WORKFLOW_FILE" ]]; then
	print_result "workflow file exists" 1 "not found: $WORKFLOW_FILE"
	printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	exit 1
fi
print_result "workflow file exists" 0

# -------------------------------------------------------------------
# Check A: YAML parses
# -------------------------------------------------------------------
if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$WORKFLOW_FILE" 2>/dev/null; then
	print_result "maintainer-gate-reusable.yml parses as valid YAML" 0
else
	print_result "maintainer-gate-reusable.yml parses as valid YAML" 1 "python3 yaml.safe_load failed"
fi

assert_contains() {
	local pattern="$1" label="$2"
	if grep -qE -- "$pattern" "$WORKFLOW_FILE" 2>/dev/null; then
		print_result "$label" 0
	else
		print_result "$label" 1 "pattern '${pattern}' not found"
	fi
	return 0
}

# -------------------------------------------------------------------
# Check B: HAS_TRUSTED_ORIGIN_LABEL computation exists
# -------------------------------------------------------------------
assert_contains "HAS_TRUSTED_ORIGIN_LABEL=false" \
	"initialises HAS_TRUSTED_ORIGIN_LABEL to false"
assert_contains "origin:worker" \
	"references origin:worker label"
assert_contains "origin:interactive" \
	"references origin:interactive label (existing + mirror)"
assert_contains "ISSUE_AUTHOR.*github-actions\[bot\]" \
	"gates trust on bot-authored issues"
# shellcheck disable=SC2016  # literal $REPO_OWNER is the search pattern
assert_contains 'ISSUE_AUTHOR.*\$REPO_OWNER' \
	"gates trust on owner-authored issues (REPO_OWNER check)"

# -------------------------------------------------------------------
# Check C: non-maintainer comment defence-in-depth
# -------------------------------------------------------------------
assert_contains "author_association.*NONE.*CONTRIBUTOR" \
	"filters non-maintainer comments on the trusted path (NONE, CONTRIBUTOR)"
assert_contains "NON_MAINT_COMMENTS" \
	"computes NON_MAINT_COMMENTS count on the trusted path"

# -------------------------------------------------------------------
# Check D: exemption condition accepts HAS_TRUSTED_ORIGIN_LABEL
# -------------------------------------------------------------------
assert_contains 'HAS_TRUSTED_ORIGIN_LABEL.*==.*"true"' \
	"exemption condition evaluates HAS_TRUSTED_ORIGIN_LABEL"
assert_contains 'HAS_AUTOMATION_LABEL.*==.*"true"' \
	"exemption condition still accepts HAS_AUTOMATION_LABEL (back-compat)"

# -------------------------------------------------------------------
# Check E: Job 3 mirror — origin:worker skip with trusted issue author
# -------------------------------------------------------------------
assert_contains "ISSUE_TRUSTED_J3" \
	"Job 3 computes ISSUE_TRUSTED_J3 for origin:worker PRs"
assert_contains "NON_MAINT_COMMENTS_J3" \
	"Job 3 checks non-maintainer comments on trusted path"
assert_contains "SKIP rerun.*origin:worker" \
	"Job 3 emits SKIP rerun message for origin:worker"

# -------------------------------------------------------------------
# Check F: REPO_OWNER env wired through both jobs
# -------------------------------------------------------------------
# Job 1 should have REPO_OWNER in env, and Job 3 too.
# Count occurrences: expect at least 2 REPO_OWNER env entries.
owner_env_count=$(grep -cE 'REPO_OWNER:[[:space:]]*\$\{\{[[:space:]]*github\.repository_owner' \
	"$WORKFLOW_FILE" 2>/dev/null || echo "0")
if [[ "$owner_env_count" -ge 2 ]]; then
	print_result "REPO_OWNER env in both Job 1 and Job 3 (found $owner_env_count entries)" 0
else
	print_result "REPO_OWNER env in both Job 1 and Job 3" 1 \
		"expected >=2 occurrences, found $owner_env_count"
fi

# -------------------------------------------------------------------
# Check G: GH#24546/GH#24958 private-org CONTRIBUTOR/COLLABORATOR permission fallback
# -------------------------------------------------------------------
assert_contains "PR_AUTHOR:[[:space:]]*\\$\\{\\{[[:space:]]*github\.event\.pull_request\.user\.login" \
	"Job 1 exposes PR_AUTHOR for permission fallback"
assert_contains "pr_author_has_maintainer_authority" \
	"defines shared maintainer-authority helper"
assert_contains "CONTRIBUTOR\|COLLABORATOR" \
	"helper routes ambiguous CONTRIBUTOR/COLLABORATOR webhook association through permission fallback"
assert_contains "collaborators/.*/permission" \
	"helper uses authenticated collaborator permission endpoint"
assert_contains "admin\|maintain\|write" \
	"helper accepts admin/maintain/write permissions"
assert_contains "permission fallback failed" \
	"helper logs and fails closed on permission API failure"
assert_contains "#aidevops:trust-boundary GH#24546" \
	"trust-boundary marker documents authenticated fallback"
assert_contains "GH#24546/GH#24958" \
	"trust-boundary marker covers maintainer-operated collaborator fallback"
assert_contains "pulls/.*PR_NUM" \
	"Job 3 reads PR metadata from the REST pulls endpoint"
assert_contains "author_association.*user.login.*head.sha.*state" \
	"Job 3 projects REST author association, login, exact head, and state metadata"
if grep -q 'authorAssociation' "$WORKFLOW_FILE" 2>/dev/null; then
	print_result "Job 3 avoids unsupported gh authorAssociation projection" 1
else
	print_result "Job 3 avoids unsupported gh authorAssociation projection" 0
fi
assert_contains "rerun_maintainer_gate_with_retry" \
	"Job 3 defines bounded rerun scheduling"
assert_contains "per_page=100" \
	"Job 3 queries multiple exact-head workflow runs"
assert_contains 'select\(\.status == "completed" and \(\.conclusion != null\)\)' \
	"Job 3 selects a terminal rerunnable workflow run"
assert_contains "post_maintainer_gate_status_with_retry error" \
	"Job 3 replaces unresolved pending with terminal error"

# -------------------------------------------------------------------
# Check H: execute Job 3 inline shell against mocked API fixtures
# -------------------------------------------------------------------
JOB3_RUN_SCRIPT=$(python3 -c 'import sys,yaml; data=yaml.safe_load(open(sys.argv[1])); print(data["jobs"]["retrigger-pr-checks"]["steps"][0]["run"])' "$WORKFLOW_FILE" 2>/dev/null || true)

gh() {
	local command=""
	local subcommand=""
	if [[ $# -gt 0 ]]; then
		command="$1"
		shift
	fi
	if [[ $# -gt 0 ]]; then
		subcommand="$1"
		shift
	fi
	local args="$*"
	if [[ "$command" == "pr" && "$subcommand" == "list" ]]; then
		printf '%s\n' '[{"number":101,"body":"Resolves #42","title":"fixture"}]'
		return 0
	fi
	if [[ "$command" == "api" && "$subcommand" == "repos/owner/repo/pulls/101" ]]; then
		case "$FIXTURE_LOOKUP_MODE" in
		pr-missing)
			printf 'gh: Not Found (HTTP 404)\n' >&2
			return 1
			;;
		pr-failure) return 1 ;;
		pr-closed)
			printf '{"labels":%s,"assoc":"%s","author":"fixture-author","head_sha":"fixture-head","state":"closed"}\n' \
				"$FIXTURE_LABELS_JSON" "$FIXTURE_ASSOCIATION"
			return 0
			;;
		pr-state-missing)
			printf '{"labels":%s,"assoc":"%s","author":"fixture-author","head_sha":"fixture-head","state":null}\n' \
				"$FIXTURE_LABELS_JSON" "$FIXTURE_ASSOCIATION"
			return 0
			;;
		esac
		printf '{"labels":%s,"assoc":"%s","author":"fixture-author","head_sha":"fixture-head","state":"open"}\n' \
			"$FIXTURE_LABELS_JSON" "$FIXTURE_ASSOCIATION"
		return 0
	fi
	if [[ "$command" == "api" && "$subcommand" == "repos/owner/repo/collaborators/fixture-author/permission" ]]; then
		printf '%s\n' "$FIXTURE_PERMISSION"
		return 0
	fi
	if [[ "$command" == "api" && "$subcommand" == repos/owner/repo/statuses/* ]]; then
		local status=""
		case "$args" in
		*"state=success"*) status="success" ;;
		*"state=pending"*) status="pending" ;;
		*"state=error"*) status="error" ;;
		esac
		[[ -n "$status" ]] && printf '%s\n' "$status" >>"$FIXTURE_STATUS_FILE"
		return 0
	fi
	if [[ "$command" == "api" && "$subcommand" == repos/owner/repo/actions/workflows/maintainer-gate.yml/runs* ]]; then
		case "$FIXTURE_LOOKUP_MODE" in
		failure) return 1 ;;
		missing) printf '{"completed":null,"active":null}\n' ;;
		active) printf '{"completed":null,"active":{"id":502,"status":"in_progress"}}\n' ;;
		active-and-completed) printf '{"completed":{"id":501,"status":"completed","conclusion":"success"},"active":{"id":502,"status":"in_progress"}}\n' ;;
		*) printf '{"completed":{"id":501,"status":"completed","conclusion":"success"},"active":null}\n' ;;
		esac
		return 0
	fi
	if [[ "$command" == "api" && "$subcommand" == "repos/owner/repo/actions/runs/501/rerun" ]]; then
		local rerun_count=0
		rerun_count=$(<"$FIXTURE_RERUN_FILE")
		rerun_count=$((rerun_count + 1))
		printf '%s' "$rerun_count" >"$FIXTURE_RERUN_FILE"
		if [[ "$rerun_count" -gt "$FIXTURE_RERUN_FAILURES" ]]; then
			return 0
		fi
		return 1
	fi
	return 1
}

sleep() {
	local seconds="$1"
	[[ -n "$seconds" ]]
	return 0
}

run_job3_fixture() {
	local fixture_name="$1"
	local association="$2"
	local labels_json="$3"
	local permission="$4"
	local rerun_failures="$5"
	local lookup_mode="$6"
	local expected_rc="$7"
	local expected_statuses="$8"
	local expected_reruns="$9"
	local fixture_dir="${TEST_TMP_ROOT}/${fixture_name//[^A-Za-z0-9]/-}"
	local status_file="${fixture_dir}/statuses"
	local rerun_file="${fixture_dir}/reruns"
	local fixture_rc=0

	rm -rf "$fixture_dir"
	mkdir -p "$fixture_dir"
	printf '0' >"$rerun_file"
	(
		export ISSUE_NUMBER=42 REPO="owner/repo" REPO_OWNER="owner"
		export FIXTURE_ASSOCIATION="$association" FIXTURE_LABELS_JSON="$labels_json"
		export FIXTURE_PERMISSION="$permission" FIXTURE_RERUN_FAILURES="$rerun_failures"
		export FIXTURE_LOOKUP_MODE="$lookup_mode" FIXTURE_STATUS_FILE="$status_file"
		export FIXTURE_RERUN_FILE="$rerun_file"
		export -f gh sleep
		bash -c "$JOB3_RUN_SCRIPT"
	) >/dev/null 2>&1 || fixture_rc=$?

	local actual_statuses=""
	local actual_reruns=0
	[[ -s "$status_file" ]] && actual_statuses=$(sort -u "$status_file" | tr '\n' ',' | sed 's/,$//')
	[[ -s "$rerun_file" ]] && actual_reruns=$(<"$rerun_file")
	if [[ "$fixture_rc" -eq "$expected_rc" && "$actual_statuses" == "$expected_statuses" && "$actual_reruns" -eq "$expected_reruns" ]]; then
		print_result "Job 3 fixture: $fixture_name" 0
	else
		print_result "Job 3 fixture: $fixture_name" 1 \
			"rc=$fixture_rc statuses=${actual_statuses:-<empty>} reruns=$actual_reruns"
	fi
	rm -rf "$fixture_dir"
	return 0
}

if [[ -z "$JOB3_RUN_SCRIPT" ]]; then
	print_result "extracts Job 3 executable shell" 1
else
	print_result "extracts Job 3 executable shell" 0
	run_job3_fixture "OWNER exemption" "OWNER" '["origin:interactive"]' "" 0 "found" 0 "success" 0
	run_job3_fixture "MEMBER exemption" "MEMBER" '["origin:interactive"]' "" 0 "found" 0 "success" 0
	run_job3_fixture "COLLABORATOR write exemption" "COLLABORATOR" '["origin:interactive"]' "write" 0 "found" 0 "success" 0
	run_job3_fixture "accepted rerun" "NONE" '[]' "" 0 "found" 0 "pending" 1
	run_job3_fixture "completed run selected behind active run" "NONE" '[]' "" 0 "active-and-completed" 0 "pending" 1
	run_job3_fixture "transient rerun rejection retries" "NONE" '[]' "" 2 "found" 0 "pending" 3
	run_job3_fixture "exhausted rerun becomes terminal" "NONE" '[]' "" 3 "found" 1 "error,pending" 3
	run_job3_fixture "active run remains status owner" "NONE" '[]' "" 0 "active" 0 "" 0
	run_job3_fixture "missing run becomes terminal without pending" "NONE" '[]' "" 0 "missing" 1 "error" 0
	run_job3_fixture "run lookup failure remains fail closed" "NONE" '[]' "" 0 "failure" 1 "error" 0
	run_job3_fixture "closed PR is a non-blocking diagnostic" "NONE" '[]' "" 0 "pr-closed" 0 "" 0
	run_job3_fixture "missing PR is a non-blocking diagnostic" "NONE" '[]' "" 0 "pr-missing" 0 "" 0
	run_job3_fixture "missing PR state remains fail closed" "NONE" '[]' "" 0 "pr-state-missing" 1 "" 0
	run_job3_fixture "transient PR metadata failure remains fail closed" "NONE" '[]' "" 0 "pr-failure" 1 "" 0
fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
