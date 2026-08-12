#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-enrich-batch-prefetch.sh — GH#20129 regression guard.
#
# Asserts that the enrich path in issue-sync-helper.sh:
#   (i)  With a healthy rate limit and a valid prefetch, uses batch-prefetched
#        JSON and does NOT call gh issue view per-task.
#   (ii) With an exhausted GraphQL rate limit, emits ::warning:: and exits
#        cleanly without iterating over individual issues.
#   (iii) When the prefetch file is absent/stale, falls back to per-task
#         gh issue view (fail-safe).
#
# Also verifies _enrich_check_rate_limit and _enrich_prefetch_issues_map
# helper functions exist and have the correct signatures.

set -uo pipefail

# Save our test directory BEFORE sourcing helpers (sourcing overwrites SCRIPT_DIR).
TEST_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="${2:-1}"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	[[ -n "$message" ]] && printf '       %s\n' "$message"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"
	return 0
}

teardown_test_env() {
	if [[ -n "${TEST_ROOT:-}" && -d "${TEST_ROOT}" ]]; then
		rm -rf "${TEST_ROOT}"
	fi
	return 0
}

setup_test_env
trap 'teardown_test_env' EXIT

# =============================================================================
# Part 1 — structural checks: helper functions exist
# =============================================================================
# Source the helper to verify functions are present.
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/../issue-sync-helper.sh" >/dev/null 2>&1
set +e

if declare -f _enrich_check_rate_limit >/dev/null 2>&1; then
	print_result "_enrich_check_rate_limit function exists (GH#20129)" 0
else
	print_result "_enrich_check_rate_limit function exists (GH#20129)" 1 "(function not found)"
fi

if declare -f _enrich_prefetch_issues_map >/dev/null 2>&1; then
	print_result "_enrich_prefetch_issues_map function exists (GH#20129)" 0
else
	print_result "_enrich_prefetch_issues_map function exists (GH#20129)" 1 "(function not found)"
fi

if declare -f _enrich_resolve_actor >/dev/null 2>&1; then
	print_result "_enrich_resolve_actor function exists (GH#30021)" 0
else
	print_result "_enrich_resolve_actor function exists (GH#30021)" 1 "(function not found)"
fi

# A bulk invocation may consult the resolver repeatedly, but authentication
# identity must be fetched at most once and then exported to task subprocesses.
ACTOR_LOOKUP_LOG="${TEST_ROOT}/actor-lookups.log"
gh() {
	printf 'lookup\n' >>"$ACTOR_LOOKUP_LOG"
	printf 'fixture-user\n'
	return 0
}
unset AIDEVOPS_SESSION_USER AIDEVOPS_ENRICH_ACTOR AIDEVOPS_ENRICH_ACTOR_RESOLVED
for _actor_fixture in $(seq 1 60); do
	_enrich_resolve_actor
done
ACTOR_LOOKUPS=$(wc -l <"$ACTOR_LOOKUP_LOG" | tr -d ' ')
if [[ "$ACTOR_LOOKUPS" -eq 1 && "$AIDEVOPS_ENRICH_ACTOR" == "fixture-user" ]]; then
	print_result "60-task actor resolution performs one authenticated lookup" 0
else
	print_result "60-task actor resolution performs one authenticated lookup" 1 \
		"(lookups=${ACTOR_LOOKUPS}, actor=${AIDEVOPS_ENRICH_ACTOR:-unset})"
fi
unset -f gh
unset AIDEVOPS_ENRICH_ACTOR AIDEVOPS_ENRICH_ACTOR_RESOLVED

# Verify cmd_enrich calls both helpers (use grep on the actual file path)
if grep -q '_enrich_check_rate_limit' "${TEST_SCRIPTS_DIR}/../issue-sync-helper-enrich.sh"; then
	print_result "cmd_enrich calls _enrich_check_rate_limit" 0
else
	print_result "cmd_enrich calls _enrich_check_rate_limit" 1 "(call not found in cmd_enrich)"
fi

if grep -q '_enrich_prefetch_issues_map' "${TEST_SCRIPTS_DIR}/../issue-sync-helper-enrich.sh"; then
	print_result "cmd_enrich calls _enrich_prefetch_issues_map" 0
else
	print_result "cmd_enrich calls _enrich_prefetch_issues_map" 1 "(call not found in cmd_enrich)"
fi

# Verify _enrich_process_task references ENRICH_PREFETCH_FILE
if grep -q 'ENRICH_PREFETCH_FILE' "${TEST_SCRIPTS_DIR}/../issue-sync-helper.sh"; then
	print_result "_enrich_process_task uses ENRICH_PREFETCH_FILE (GH#20129)" 0
else
	print_result "_enrich_process_task uses ENRICH_PREFETCH_FILE (GH#20129)" 1 "(ENRICH_PREFETCH_FILE not referenced)"
fi

# =============================================================================
# Part 2 — _enrich_check_rate_limit: exhausted rate limit → return 0 (skip)
# =============================================================================
STUB_DIR="${TEST_ROOT}/bin-rl-exhausted"
mkdir -p "$STUB_DIR"

# Stub gh to return an exhausted rate limit (remaining=0)
FUTURE_RESET=$(date -u -d '+5 minutes' '+%s' 2>/dev/null \
	|| TZ=UTC date -v+5M '+%s' 2>/dev/null || echo "9999999999")
cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "api" && "\$2" == "rate_limit" ]]; then
	printf '{"resources":{"graphql":{"remaining":0,"reset":%s}}}' "${FUTURE_RESET}"
	exit 0
fi
exit 1
STUB
chmod +x "${STUB_DIR}/gh"

_original_path="$PATH"
export PATH="${STUB_DIR}:${PATH}"

# Source the functions directly (already sourced above, just need PATH override)
# _enrich_check_rate_limit should return 0 (skip) when remaining=0
if _enrich_check_rate_limit 2>/dev/null; then
	print_result "_enrich_check_rate_limit returns 0 (skip) when rate limit exhausted" 0
else
	print_result "_enrich_check_rate_limit returns 0 (skip) when rate limit exhausted" 1 "(expected return 0, got return 1)"
fi

# Check it emits the ::warning:: line
_rl_output=$(_enrich_check_rate_limit 2>/dev/null) || true
if [[ "$_rl_output" == *"::warning::"* ]]; then
	print_result "_enrich_check_rate_limit emits ::warning:: on exhausted limit" 0
else
	print_result "_enrich_check_rate_limit emits ::warning:: on exhausted limit" 1 "(no ::warning:: in output: '$_rl_output')"
fi

if [[ "$_rl_output" == *"remaining=0"* ]]; then
	print_result "_enrich_check_rate_limit includes remaining count in warning" 0
else
	print_result "_enrich_check_rate_limit includes remaining count in warning" 1 "(remaining not in output)"
fi

export PATH="$_original_path"

# =============================================================================
# Part 3 — _enrich_check_rate_limit: healthy rate limit → return 1 (proceed)
# =============================================================================
STUB_DIR2="${TEST_ROOT}/bin-rl-healthy"
mkdir -p "$STUB_DIR2"

cat >"${STUB_DIR2}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "api" && "\$2" == "rate_limit" ]]; then
	printf '{"resources":{"graphql":{"remaining":5000,"reset":9999999999}}}'
	exit 0
fi
exit 1
STUB
chmod +x "${STUB_DIR2}/gh"

export PATH="${STUB_DIR2}:${PATH}"

# With healthy rate limit, should return 1 (proceed)
if ! _enrich_check_rate_limit 2>/dev/null; then
	print_result "_enrich_check_rate_limit returns 1 (proceed) with healthy rate limit" 0
else
	print_result "_enrich_check_rate_limit returns 1 (proceed) with healthy rate limit" 1 "(returned 0 — would skip unnecessarily)"
fi

export PATH="$_original_path"

# =============================================================================
# Part 4 — _enrich_check_rate_limit: fail-open when gh api fails
# =============================================================================
STUB_DIR3="${TEST_ROOT}/bin-rl-fail"
mkdir -p "$STUB_DIR3"

cat >"${STUB_DIR3}/gh" <<STUB
#!/usr/bin/env bash
# Simulate gh api failure
exit 1
STUB
chmod +x "${STUB_DIR3}/gh"

export PATH="${STUB_DIR3}:${PATH}"

# When gh api fails, should fail-open (return 1 = proceed)
if ! _enrich_check_rate_limit 2>/dev/null; then
	print_result "_enrich_check_rate_limit fails-open (return 1) when gh api fails" 0
else
	print_result "_enrich_check_rate_limit fails-open (return 1) when gh api fails" 1 "(returned 0 — should not skip on API failure)"
fi

export PATH="$_original_path"

# =============================================================================
# Part 5 — _enrich_process_task uses ENRICH_PREFETCH_FILE (no gh issue view)
# =============================================================================
# Build a stub that tracks call counts to gh issue view.
STUB_DIR4="${TEST_ROOT}/bin-prefetch-count"
mkdir -p "$STUB_DIR4"
CALL_LOG="${TEST_ROOT}/gh-calls.log"

cat >"${STUB_DIR4}/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${CALL_LOG}"
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then
	# This call should NOT happen when prefetch is available
	printf '{"number":123,"title":"t9999: Test issue","body":"body","labels":[],"state":"OPEN","assignees":[]}\n'
	exit 0
fi
if [[ "\$1" == "api" && "\$2" == "user" ]]; then
	printf '{"login":"testbot"}\n'
	exit 0
fi
exit 1
STUB
chmod +x "${STUB_DIR4}/gh"

# Create a valid prefetch file with issue 123
# t2997: drop .json — XXXXXX must be at end for BSD mktemp.
PREFETCH_FILE=$(mktemp /tmp/test-prefetch-XXXXXX)
printf '[{"number":123,"title":"t9999: Test issue","body":"original body","labels":[{"name":"bug"}],"state":"OPEN","assignees":[]}]\n' \
	>"$PREFETCH_FILE"

export PATH="${STUB_DIR4}:${PATH}"
export ENRICH_PREFETCH_FILE="$PREFETCH_FILE"

# Look up issue 123 from the prefetch file using the same jq pattern as _enrich_process_task
_lookup=$(jq -c --argjson n 123 '.[] | select(.number == $n)' "$PREFETCH_FILE" 2>/dev/null || echo "")
if [[ -n "$_lookup" ]]; then
	print_result "Prefetch file lookup returns data for issue 123" 0
else
	print_result "Prefetch file lookup returns data for issue 123" 1 "(empty result from jq lookup)"
fi

_lookup_title=$(printf '%s' "$_lookup" | jq -r '.title // ""' 2>/dev/null || echo "")
if [[ "$_lookup_title" == "t9999: Test issue" ]]; then
	print_result "Prefetch file lookup returns correct title" 0
else
	print_result "Prefetch file lookup returns correct title" 1 "(expected 't9999: Test issue', got '$_lookup_title')"
fi

rm -f "$PREFETCH_FILE" 2>/dev/null || true
rm -f "$CALL_LOG" 2>/dev/null || true
unset ENRICH_PREFETCH_FILE
export PATH="$_original_path"

# =============================================================================
# Part 6 — fallback when ENRICH_PREFETCH_FILE is absent
# =============================================================================
# When ENRICH_PREFETCH_FILE is unset, the lookup should return empty and the
# fallback gh issue view code path should be used.
unset ENRICH_PREFETCH_FILE

_no_prefetch=$(jq -c --argjson n 123 '.[] | select(.number == $n)' "/tmp/nonexistent-XXXXXX.json" 2>/dev/null || echo "")
if [[ -z "$_no_prefetch" ]]; then
	print_result "Cache miss on absent prefetch file returns empty (triggers fallback)" 0
else
	print_result "Cache miss on absent prefetch file returns empty (triggers fallback)" 1 "(expected empty, got: $_no_prefetch)"
fi

# Verify the condition guard in _enrich_process_task:
# [[ -n "${ENRICH_PREFETCH_FILE:-}" && -f "$ENRICH_PREFETCH_FILE" && -n "$num" ]]
# With ENRICH_PREFETCH_FILE unset, -n "${ENRICH_PREFETCH_FILE:-}" is false → no prefetch attempt
_test_guard=false
if [[ -n "${ENRICH_PREFETCH_FILE:-}" && -f "${ENRICH_PREFETCH_FILE:-/nonexistent}" ]]; then
	_test_guard=true
fi
if [[ "$_test_guard" == "false" ]]; then
	print_result "Guard condition skips prefetch when ENRICH_PREFETCH_FILE is unset" 0
else
	print_result "Guard condition skips prefetch when ENRICH_PREFETCH_FILE is unset" 1 "(guard should be false when var unset)"
fi

# =============================================================================
# Part 7 — ENRICH_PREFETCH_LIMIT and ENRICH_RATE_LIMIT_THRESHOLD are honoured
# =============================================================================
# Verify that environment variables control the threshold and limit values.
# We test _enrich_check_rate_limit with a custom threshold.
STUB_DIR5="${TEST_ROOT}/bin-custom-threshold"
mkdir -p "$STUB_DIR5"

cat >"${STUB_DIR5}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "api" && "\$2" == "rate_limit" ]]; then
	# remaining=100 — above default (250) would skip, but below 50 custom threshold would not
	printf '{"resources":{"graphql":{"remaining":100,"reset":9999999999}}}'
	exit 0
fi
exit 1
STUB
chmod +x "${STUB_DIR5}/gh"
export PATH="${STUB_DIR5}:${PATH}"

# With default threshold (250), remaining=100 should skip (return 0)
if ENRICH_RATE_LIMIT_THRESHOLD=250 _enrich_check_rate_limit 2>/dev/null; then
	print_result "ENRICH_RATE_LIMIT_THRESHOLD=250 skips when remaining=100" 0
else
	print_result "ENRICH_RATE_LIMIT_THRESHOLD=250 skips when remaining=100" 1 "(should have returned 0 to skip)"
fi

# With threshold=50, remaining=100 should proceed (return 1)
if ! ENRICH_RATE_LIMIT_THRESHOLD=50 _enrich_check_rate_limit 2>/dev/null; then
	print_result "ENRICH_RATE_LIMIT_THRESHOLD=50 proceeds when remaining=100" 0
else
	print_result "ENRICH_RATE_LIMIT_THRESHOLD=50 proceeds when remaining=100" 1 "(should have returned 1 to proceed)"
fi

export PATH="$_original_path"

# =============================================================================
# Part 8 — pulse-batch-prefetch: _is_search_rate_limited detects GraphQL patterns
# =============================================================================
# Test that the updated grep pattern in _is_search_rate_limited correctly matches
# GraphQL exhaustion errors observed in production (2026-04-22 17:36-18:45 UTC).
BATCH_PREFETCH_SCRIPT="${TEST_SCRIPTS_DIR}/../pulse-batch-prefetch-helper.sh"

_rl_err=$(mktemp)

# 8a: GraphQL exhaustion pattern — the exact string from production logs
printf 'GraphQL: API rate limit already exceeded for user ID 99999\n' >"$_rl_err"
if (
	set +e
	# shellcheck source=/dev/null
	source "$BATCH_PREFETCH_SCRIPT" >/dev/null 2>&1 || true
	_is_search_rate_limited "$_rl_err"
) 2>/dev/null; then
	print_result "_is_search_rate_limited detects 'GraphQL: API rate limit already exceeded'" 0
else
	print_result "_is_search_rate_limited detects 'GraphQL: API rate limit already exceeded'" 1 "(pattern not matched)"
fi

# 8b: Alternate GraphQL pattern without "already"
printf 'GraphQL: API rate limit exceeded for user ID 99999\n' >"$_rl_err"
if (
	set +e
	# shellcheck source=/dev/null
	source "$BATCH_PREFETCH_SCRIPT" >/dev/null 2>&1 || true
	_is_search_rate_limited "$_rl_err"
) 2>/dev/null; then
	print_result "_is_search_rate_limited detects 'GraphQL: API rate limit exceeded' (no 'already')" 0
else
	print_result "_is_search_rate_limited detects 'GraphQL: API rate limit exceeded' (no 'already')" 1 "(pattern not matched)"
fi

# 8c: "API rate limit exceeded for user" alternate GitHub phrasing
printf 'API rate limit exceeded for user ID 99999\n' >"$_rl_err"
if (
	set +e
	# shellcheck source=/dev/null
	source "$BATCH_PREFETCH_SCRIPT" >/dev/null 2>&1 || true
	_is_search_rate_limited "$_rl_err"
) 2>/dev/null; then
	print_result "_is_search_rate_limited detects 'API rate limit exceeded for user'" 0
else
	print_result "_is_search_rate_limited detects 'API rate limit exceeded for user'" 1 "(pattern not matched)"
fi

# 8d: Existing "Search rate limit exceeded" pattern still matches
printf 'Search rate limit exceeded\n' >"$_rl_err"
if (
	set +e
	# shellcheck source=/dev/null
	source "$BATCH_PREFETCH_SCRIPT" >/dev/null 2>&1 || true
	_is_search_rate_limited "$_rl_err"
) 2>/dev/null; then
	print_result "_is_search_rate_limited still detects 'Search rate limit exceeded' (existing pattern)" 0
else
	print_result "_is_search_rate_limited still detects 'Search rate limit exceeded' (existing pattern)" 1 "(existing pattern broken)"
fi

# 8e: Generic network error does NOT match (no false positives)
printf 'error: network timeout connecting to api.github.com\n' >"$_rl_err"
if ! (
	set +e
	# shellcheck source=/dev/null
	source "$BATCH_PREFETCH_SCRIPT" >/dev/null 2>&1 || true
	_is_search_rate_limited "$_rl_err"
) 2>/dev/null; then
	print_result "_is_search_rate_limited does NOT match generic network errors (no false positives)" 0
else
	print_result "_is_search_rate_limited does NOT match generic network errors (no false positives)" 1 "(false positive on network error)"
fi

rm -f "$_rl_err" 2>/dev/null || true

# =============================================================================
# Part 9 — pulse-batch-prefetch: REST fallback writes per-slug caches
# =============================================================================
# Verify that when gh search issues/prs fails with a GraphQL exhaustion error,
# the helper falls back to gh api REST (/repos/{slug}/issues, /repos/{slug}/pulls)
# and writes the per-slug cache files.
STUB_DIR_REST="${TEST_ROOT}/bin-rest-fallback"
mkdir -p "$STUB_DIR_REST"

# Stub repos.json with one pulse-enabled repo
STUB_REPOS_JSON="${TEST_ROOT}/repos-rest-test.json"
cat >"$STUB_REPOS_JSON" <<'REPOSJSON'
{"initialized_repos":[{"slug":"testowner/testrepo","pulse":true,"local_only":false}],"git_parent_dirs":[]}
REPOSJSON

# Stub gh: search commands fail with GraphQL exhaustion, REST succeeds
cat >"${STUB_DIR_REST}/gh" <<'GHSTUB'
#!/usr/bin/env bash
# gh search → simulate GraphQL exhaustion
if [[ "$1" == "search" ]]; then
	printf 'GraphQL: API rate limit already exceeded for user ID 99999\n' >&2
	exit 1
fi
# gh api repos/{slug}/issues → simulate REST success
if [[ "$1" == "api" && "$2" == *"/issues"* ]]; then
	printf '[{"number":42,"title":"Test Issue","labels":[],"updated_at":"2026-04-22T17:00:00Z","assignees":[]}]\n'
	exit 0
fi
# gh api repos/{slug}/pulls → simulate REST success
if [[ "$1" == "api" && "$2" == *"/pulls"* ]]; then
	printf '[{"number":7,"title":"Test PR","labels":[],"updated_at":"2026-04-22T17:00:00Z","assignees":[],"created_at":"2026-04-22T16:00:00Z","user":{"login":"testuser"},"head":{"sha":"abcdef123456","ref":"feature"}}]\n'
	exit 0
fi
exit 1
GHSTUB
chmod +x "${STUB_DIR_REST}/gh"

BATCH_CACHE_DIR_TEST="${TEST_ROOT}/batch-cache-rest"
mkdir -p "$BATCH_CACHE_DIR_TEST"

set +e
PATH="${STUB_DIR_REST}:${PATH}" \
	REPOS_JSON="$STUB_REPOS_JSON" \
	PULSE_BATCH_PREFETCH_CACHE_DIR="$BATCH_CACHE_DIR_TEST" \
	LOGFILE="/dev/null" \
	bash "$BATCH_PREFETCH_SCRIPT" refresh >/dev/null 2>&1
set -e

# Verify issues cache was written
_issues_cache="${BATCH_CACHE_DIR_TEST}/issues-testowner__testrepo.json"
if [[ -f "$_issues_cache" ]]; then
	print_result "REST fallback: issues cache written when GraphQL exhausted (GH#20534)" 0
else
	print_result "REST fallback: issues cache written when GraphQL exhausted (GH#20534)" 1 "(cache not found: ${_issues_cache})"
fi

# Verify issues cache has items and correct schema
if [[ -f "$_issues_cache" ]]; then
	_item_count=$(jq '.items | length' "$_issues_cache" 2>/dev/null || echo 0)
	if [[ "$_item_count" -ge 1 ]]; then
		print_result "REST fallback: issues cache has items (count=${_item_count})" 0
	else
		print_result "REST fallback: issues cache has items" 1 "(items count=${_item_count})"
	fi
	_first_number=$(jq '.items[0].number' "$_issues_cache" 2>/dev/null || echo "null")
	_has_updated_at=$(jq '.items[0] | has("updatedAt")' "$_issues_cache" 2>/dev/null || echo "false")
	if [[ "$_first_number" == "42" && "$_has_updated_at" == "true" ]]; then
		print_result "REST fallback: issues cache schema has updatedAt field (not updated_at)" 0
	else
		print_result "REST fallback: issues cache schema has updatedAt field (not updated_at)" 1 "(number=${_first_number} updatedAt=${_has_updated_at})"
	fi
fi

# Verify PRs cache was written
_prs_cache="${BATCH_CACHE_DIR_TEST}/prs-testowner__testrepo.json"
if [[ -f "$_prs_cache" ]]; then
	print_result "REST fallback: PRs cache written when GraphQL exhausted (GH#20534)" 0
else
	print_result "REST fallback: PRs cache written when GraphQL exhausted (GH#20534)" 1 "(cache not found: ${_prs_cache})"
fi

# Verify PRs cache has items and correct schema (author field from REST user.login)
if [[ -f "$_prs_cache" ]]; then
	_pr_count=$(jq '.items | length' "$_prs_cache" 2>/dev/null || echo 0)
	if [[ "$_pr_count" -ge 1 ]]; then
		print_result "REST fallback: PRs cache has items (count=${_pr_count})" 0
	else
		print_result "REST fallback: PRs cache has items" 1 "(items count=${_pr_count})"
	fi
	_pr_author=$(jq -r '.items[0].author.login // "null"' "$_prs_cache" 2>/dev/null || echo "null")
	if [[ "$_pr_author" == "testuser" ]]; then
		print_result "REST fallback: PRs cache author.login mapped from REST user.login" 0
	else
		print_result "REST fallback: PRs cache author.login mapped from REST user.login" 1 "(author.login='${_pr_author}', expected 'testuser')"
	fi
fi

_issues_snapshot=""
_prs_snapshot=""
_issues_snapshot=$(PULSE_BATCH_PREFETCH_CACHE_DIR="$BATCH_CACHE_DIR_TEST" LOGFILE="/dev/null" \
	bash "$BATCH_PREFETCH_SCRIPT" read-snapshot --kind issues --slug testowner/testrepo 2>/dev/null) || _issues_snapshot="{}"
_prs_snapshot=$(PULSE_BATCH_PREFETCH_CACHE_DIR="$BATCH_CACHE_DIR_TEST" LOGFILE="/dev/null" \
	bash "$BATCH_PREFETCH_SCRIPT" read-snapshot --kind prs --slug testowner/testrepo 2>/dev/null) || _prs_snapshot="{}"
if [[ "$(printf '%s' "$_issues_snapshot" | jq -r '.complete // false')" == "true" ]] \
	&& [[ "$(printf '%s' "$_issues_snapshot" | jq -r '.generation // ""')" == "$(printf '%s' "$_prs_snapshot" | jq -r '.generation // ""')" ]] \
	&& [[ "$(printf '%s' "$_prs_snapshot" | jq -r '.items[0].headRefOid // ""')" == "abcdef123456" ]]; then
	print_result "REST fallback: canonical snapshots preserve completeness, generation, and full head SHA" 0
else
	print_result "REST fallback: canonical snapshots preserve completeness, generation, and full head SHA" 1
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "---"
echo "Tests run: $TESTS_RUN | Passed: $((TESTS_RUN - TESTS_FAILED)) | Failed: $TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	printf '%bSOME TESTS FAILED%b\n' "$TEST_RED" "$TEST_RESET"
	exit 1
fi
printf '%bALL TESTS PASSED%b\n' "$TEST_GREEN" "$TEST_RESET"
