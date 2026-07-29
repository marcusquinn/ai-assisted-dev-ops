#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for t2922 / GH#21097: _check_required_checks_passing in pulse-merge.sh.
#
# Problem: non-required check contexts (CodeRabbit, qlty, linked-issue-check,
# url-allowlist, etc.) report null/pending status indefinitely and cause
# `gh pr checks --required` to fail-closed via an API quirk, blocking auto-merge
# of origin:worker PRs whose branch-protection-required checks all passed.
#
# Fix: _check_required_checks_passing fetches required contexts from classic
# branch protection plus active matching repository rulesets, then cross-
# references the PR's REST check-runs (GH#21799 migration). If all required
# contexts pass, the function returns 0, allowing the origin:worker bypass
# path to proceed.
#
# Scenarios tested:
#   1. all_required_pass — all required contexts SUCCESS, including the
#      maintainer-gate legacy status alias → return 0
#   2. phantom_pending_only — required pass + non-required null/pending → return 0
#   3. one_required_failing — one required FAILURE → return 1
#   4. required_context_absent — required context not in rollup (NOT_FOUND) → return 1
#   5. no_required_contexts — no classic/ruleset contexts → return 0
#   6. rulesets_required_on_404 — rulesets-only required check failing → return 1
#   7. rulesets_required_on_404_pass — rulesets-only required check passing → return 0
#   8. rulesets_required_with_simple_glob — `*` ruleset applies → return 1
#   9. rulesets_required_with_plain_branch — plain branch pattern applies → return 1
#   10. rulesets_excludes_default_branch — exclusion wins → return 0
#   11. rulesets_non_matching_branch — non-default ruleset ignored → return 0
#   12. default_branch_api_error — can't get default branch → return 1 (fail-closed)
#   13. branch_protection_api_error — can't get branch protection → return 1 (fail-closed)
#   14. checks_api_error — can't get REST check-runs → return 1 (fail-closed)
#
# Strategy: source shared-gh-wrappers-checks.sh for `gh_pr_check_runs_rest`,
# extract _check_required_checks_passing from pulse-merge-process.sh, eval it,
# and exercise against a mock `gh` stub keyed on MOCK_*_MODE env vars.
#
# The mock handles seven gh invocations (post GH#21799 migration):
#   1. gh api repos/SLUG                              → default branch
#   2. gh api repos/SLUG/branches/.../protection/...  → required_status_checks
#   3. gh api repos/SLUG/rulesets                    → repository ruleset list
#   4. gh api repos/SLUG/rulesets/ID                 → repository ruleset detail
#   5. gh pr view NUM --json headRefOid              → PR HEAD SHA
#   6. gh api repos/SLUG/commits/SHA/check-runs      → check-run states
#   7. gh api repos/SLUG/commits/SHA/status          → legacy status contexts
#      (t3250: includes `Maintainer Review & Assignee Gate` alias for repos
#      whose branch protection still requires the pre-reusable workflow name)
#
# Mode variables:
#   MOCK_REPO_MODE     — controls gh api repos/<slug> response
#   MOCK_BP_MODE       — controls branch protection required_status_checks response
#   MOCK_RULESETS_MODE — controls repository ruleset list/detail responses
#   MOCK_ROLLUP_MODE   — controls REST check-runs/status response (legacy name retained)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# _check_required_checks_passing was moved to pulse-merge-process.sh
# (GH#21595, t3030).
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process.sh"
REQUIRED_CHECKS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-required-checks.sh"

readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%sFAIL%s %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	export GH_QUOTA_LOG="${TEST_ROOT}/gh-quota.log"
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="three_required"
	export MOCK_RULESETS_MODE="none"
	export MOCK_ROLLUP_MODE="all_required_pass"
	: >"$LOGFILE"
	: >"$GH_CALL_LOG"
	: >"$GH_QUOTA_LOG"

	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Mock gh for test-pulse-merge-phantom-pending-checks.sh
# Records every invocation and returns canned responses for several call types:
#   1. gh api repos/SLUG                → default branch
#   2. gh api repos/SLUG/branches/...  → required_status_checks contexts
#   3. gh api repos/SLUG/rulesets       → repository ruleset list/detail
#   4. gh pr view NUM --json statusCheckRollup → PR check states
#
# Mode env vars:
#   MOCK_REPO_MODE     — ok | error
#   MOCK_BP_MODE       — three_required | no_required | not_found | error
#   MOCK_RULESETS_MODE — none | active_required | active_required_star |
#                        active_required_plain_branch |
#                        active_required_excluded_default |
#                        active_required_other_branch | error | detail_error
#   MOCK_ROLLUP_MODE   — all_required_pass | phantom_pending | one_required_failing |
#                        required_absent | error
printf '%s\n' "$*" >> "${GH_CALL_LOG}"

# Helper: apply --jq expression from args if present
apply_jq() {
	local json="$1"
	shift
	local jq_expr=""
	local prev=""
	for arg in "$@"; do
		if [[ "$prev" == "--jq" ]]; then
			jq_expr="$arg"
			break
		fi
		prev="$arg"
	done
	if [[ -n "$jq_expr" ]]; then
		printf '%s' "$json" | jq -r "$jq_expr"
		return 0
	fi
	printf '%s\n' "$json"
	return 0
}

# Match: gh api repos/SLUG/rulesets/ID (repository ruleset detail)
if [[ "$1" == "api" && "$2" == repos/* && "$*" == *"/rulesets/"* ]]; then
	case "${MOCK_RULESETS_MODE:-none}" in
	active_required)
		apply_jq '{"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"review-bot-gate"}]}}]}' "$@"
		exit 0
		;;
	active_required_star)
		apply_jq '{"conditions":{"ref_name":{"include":["*"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"review-bot-gate"}]}}]}' "$@"
		exit 0
		;;
	active_required_plain_branch)
		apply_jq '{"conditions":{"ref_name":{"include":["main"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"review-bot-gate"}]}}]}' "$@"
		exit 0
		;;
	active_required_excluded_default)
		apply_jq '{"conditions":{"ref_name":{"include":["*"],"exclude":["main"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"review-bot-gate"}]}}]}' "$@"
		exit 0
		;;
	active_required_other_branch)
		apply_jq '{"conditions":{"ref_name":{"include":["refs/heads/release"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"review-bot-gate"}]}}]}' "$@"
		exit 0
		;;
	detail_error)
		printf 'gh: mock ruleset detail API error\n' >&2
		exit 1
		;;
	*)
		apply_jq '{"conditions":{"ref_name":{"include":[]}},"rules":[]}' "$@"
		exit 0
		;;
	esac
fi

# Match: gh api repos/SLUG/rulesets (repository ruleset list)
if [[ "$1" == "api" && "$2" == repos/* && "$*" == *"/rulesets"* ]]; then
	case "${MOCK_RULESETS_MODE:-none}" in
	none)
		apply_jq '[]' "$@"
		exit 0
		;;
	active_required | active_required_star | active_required_plain_branch | \
		active_required_excluded_default | active_required_other_branch | detail_error)
		apply_jq '[{"id":101,"enforcement":"active"}]' "$@"
		exit 0
		;;
	error)
		printf 'gh: mock rulesets API error\n' >&2
		exit 1
		;;
	esac
fi

# Match: gh api repos/SLUG  (repo info — default branch)
# Detected by: $1 == api, $2 starts with "repos/", no other path segments.
# Must exclude /commits/ for the GH#21799 REST check-runs/status branches
# below to be reachable.
if [[ "$1" == "api" && "$2" == repos/* && "$*" != *"/branches/"* \
	&& "$*" != *"/issues/"* && "$*" != *"/pulls/"* \
	&& "$*" != *"/commits/"* && "$*" != *"/rulesets"* ]]; then
	case "${MOCK_REPO_MODE:-ok}" in
	ok)
		apply_jq '{"default_branch":"main"}' "$@"
		exit 0
		;;
	error)
		printf 'gh: mock repo API error\n' >&2
		exit 1
		;;
	esac
fi

# Match: gh api repos/SLUG/branches/BRANCH/protection/required_status_checks
if [[ "$1" == "api" && "$*" == *"protection/required_status_checks"* ]]; then
	printf '%s|%s\n' "${AIDEVOPS_GH_QUOTA_COST:-}" \
		"${AIDEVOPS_GH_ROUTE_DECISION:-}" >>"${GH_QUOTA_LOG}"
	local_json=""
	case "${MOCK_BP_MODE:-three_required}" in
	three_required)
		local_json='{"contexts":["review-bot-gate","Maintainer Review & Assignee Gate","Complexity Analysis"]}'
		;;
	no_required)
		local_json='{"contexts":[]}'
		;;
	not_found)
		printf 'gh: HTTP 404: Not Found\n' >&2
		exit 1
		;;
	error)
		printf 'gh: mock branch-protection API error\n' >&2
		exit 1
		;;
	esac
	apply_jq "$local_json" "$@"
	exit 0
fi

# Match: gh pr view NUM --json headRefOid (GH#21799)
# Returns a fake HEAD SHA so the helper can issue REST check-runs queries.
if [[ "$1" == "pr" && "$2" == "view" && "$*" == *"headRefOid"* ]]; then
	local_json='{"headRefOid":"abc123def456789000000000000000000000abcd"}'
	apply_jq "$local_json" "$@"
	exit 0
fi

# Match: gh api repos/SLUG/commits/SHA/check-runs (GH#21799)
# Returns the GitHub Actions / Apps check-run list. Mock data normalised to
# the lowercase `conclusion`/`status` shape that GitHub returns.
if [[ "$1" == "api" && "$*" == *"/check-runs"* ]]; then
	local_json=""
	case "${MOCK_ROLLUP_MODE:-all_required_pass}" in
	all_required_pass)
		# All three required checks pass. The maintainer-gate CheckRun name is
		# what reusable workflow callers emit; the exact legacy required context
		# is satisfied by the /status alias below (t3250).
		local_json='{"check_runs":[
			{"name":"review-bot-gate","conclusion":"success","status":"completed"},
			{"name":"gate / Maintainer Review & Assignee Gate","conclusion":"success","status":"completed"},
			{"name":"Complexity Analysis","conclusion":"success","status":"completed"}
		]}'
		;;
	phantom_pending)
		# Required checks pass; non-required checks report null/pending.
		local_json='{"check_runs":[
			{"name":"review-bot-gate","conclusion":"success","status":"completed"},
			{"name":"gate / Maintainer Review & Assignee Gate","conclusion":"success","status":"completed"},
			{"name":"Complexity Analysis","conclusion":"success","status":"completed"},
			{"name":"coderabbit-review","conclusion":null,"status":"queued"},
			{"name":"qlty-check","conclusion":null,"status":"queued"},
			{"name":"linked-issue-check","conclusion":null,"status":"in_progress"},
			{"name":"url-allowlist","conclusion":null,"status":"in_progress"}
		]}'
		;;
	one_required_failing)
		# review-bot-gate is FAILURE; other required checks pass.
		local_json='{"check_runs":[
			{"name":"review-bot-gate","conclusion":"failure","status":"completed"},
			{"name":"gate / Maintainer Review & Assignee Gate","conclusion":"success","status":"completed"},
			{"name":"Complexity Analysis","conclusion":"success","status":"completed"}
		]}'
		;;
	required_absent)
		# review-bot-gate is missing from check-runs; other required checks pass.
		local_json='{"check_runs":[
			{"name":"gate / Maintainer Review & Assignee Gate","conclusion":"success","status":"completed"},
			{"name":"Complexity Analysis","conclusion":"success","status":"completed"}
		]}'
		;;
	error)
		printf 'gh: mock REST check-runs error\n' >&2
		exit 1
		;;
	esac
	apply_jq "$local_json" "$@"
	exit 0
fi

# Match: gh api repos/SLUG/commits/SHA/status (GH#21799)
# t3250: maintainer-gate-reusable.yml posts both the stable `maintainer-gate`
# commit status and a legacy `Maintainer Review & Assignee Gate` alias so repos
# with stale branch protection still see an exact required context.
if [[ "$1" == "api" && "$*" == *"/commits/"* && "$*" == *"/status"* ]]; then
	local_json='{"statuses":[
		{"context":"maintainer-gate","state":"success"},
		{"context":"Maintainer Review & Assignee Gate","state":"success"}
	]}'
	apply_jq "$local_json" "$@"
	exit 0
fi

# Unhandled gh invocations: silent success
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Source the shared required-context helpers and extract only the Pulse-specific
# pass/fail classifier from pulse-merge-process.sh.
define_function_under_test() {
	# Source the REST check-runs helper so the extracted function can call
	# `gh_pr_check_runs_rest` (GH#21799 migration). Sub-library only — avoids
	# pulling in the full shared-gh-wrappers.sh orchestrator.
	local checks_lib="${SCRIPT_DIR}/../shared-gh-wrappers-checks.sh"
	if [[ ! -f "$checks_lib" ]]; then
		printf 'ERROR: shared-gh-wrappers-checks.sh not found at %s\n' \
			"$checks_lib" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from sibling lib
	source "$checks_lib"
	# shellcheck disable=SC1090  # dynamic source from sibling lib
	source "$REQUIRED_CHECKS_SCRIPT"
	gh_pr_view() {
		if gh pr view "$@"; then
			return 0
		fi
		return 1
	}

	local fn_src
	fn_src=$(awk '
		/^_check_required_checks_passing\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$fn_src" ]]; then
		printf 'ERROR: could not extract _check_required_checks_passing from %s\n' \
			"$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$fn_src"
	return 0
}

assert_returns() {
	local expected_rc="$1"
	local label="$2"
	local actual_rc=0
	_check_required_checks_passing "marcusquinn/aidevops" "21097" || actual_rc=$?
	if [[ "$actual_rc" -eq "$expected_rc" ]]; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected rc=$expected_rc, got rc=$actual_rc"
	fi
	return 0
}

assert_log_contains() {
	local pattern="$1"
	local label="$2"
	if grep -q -- "$pattern" "$LOGFILE" 2>/dev/null; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected log line matching: $pattern"
	fi
	return 0
}

reset_logs() {
	: >"$LOGFILE"
	: >"$GH_CALL_LOG"
	: >"$GH_QUOTA_LOG"
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="three_required"
	export MOCK_RULESETS_MODE="none"
	export MOCK_ROLLUP_MODE="all_required_pass"
	return 0
}

# ── Test cases ──────────────────────────────────────────────────────────────

test_all_required_pass() {
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="three_required"
	export MOCK_ROLLUP_MODE="all_required_pass"
	assert_returns 0 "all required checks SUCCESS via check-runs/status alias → allowed"
	assert_log_contains "all required contexts passing" \
		"all_required_pass: pass message logged"
	assert_log_contains "t2922" "all_required_pass: log tagged t2922"
	return 0
}

test_phantom_pending_non_required() {
	# The key scenario from GH#21097: non-required checks (CodeRabbit, qlty,
	# linked-issue-check, url-allowlist) report null/pending indefinitely.
	# Required checks all pass — function should return 0 to unblock the merge.
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="three_required"
	export MOCK_ROLLUP_MODE="phantom_pending"
	assert_returns 0 "required pass + non-required null/pending → allowed (GH#21097)"
	assert_log_contains "all required contexts passing" \
		"phantom_pending: pass message logged"
	return 0
}

test_one_required_failing() {
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="three_required"
	export MOCK_ROLLUP_MODE="one_required_failing"
	assert_returns 1 "one required context FAILURE → blocked"
	assert_log_contains "required context(s) not passing" \
		"one_required_failing: block message logged"
	assert_log_contains "t2922" "one_required_failing: log tagged t2922"
	return 0
}

test_required_context_absent_from_rollup() {
	# A required context that hasn't reported at all is treated as non-passing.
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="three_required"
	export MOCK_ROLLUP_MODE="required_absent"
	assert_returns 1 "required context absent from rollup → blocked"
	assert_log_contains "required context(s) not passing" \
		"required_absent: block message logged"
	return 0
}

test_no_required_contexts() {
	# Repo has no required checks in classic branch protection or rulesets.
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="no_required"
	export MOCK_ROLLUP_MODE="all_required_pass"
	assert_returns 0 "no required contexts in branch protection or rulesets → allowed"
	assert_log_contains "no branch/ruleset contexts" \
		"no_required: pass message logged"
	return 0
}

test_rulesets_required_on_branch_protection_404_block() {
	# GH#23019: rulesets-only required checks must be enforced even when the
	# classic branch-protection endpoint returns 404.
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="not_found"
	export MOCK_RULESETS_MODE="active_required"
	export MOCK_ROLLUP_MODE="one_required_failing"
	assert_returns 1 "branch protection 404 + failing ruleset-required check → blocked"
	assert_log_contains "active rulesets require contexts" \
		"rulesets_404_block: ruleset context logged"
	assert_log_contains "required context(s) not passing" \
		"rulesets_404_block: block message logged"
	if grep -Fqx '1|pulse-branch-protection-required-contexts-rest' "$GH_QUOTA_LOG"; then
		print_result "branch protection HTTP 404 carries explicit one-request cost" 0
	else
		print_result "branch protection HTTP 404 carries explicit one-request cost" 1 \
			"quota log: $(cat "$GH_QUOTA_LOG")"
	fi
	return 0
}

test_rulesets_required_on_branch_protection_404_pass() {
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="not_found"
	export MOCK_RULESETS_MODE="active_required"
	export MOCK_ROLLUP_MODE="all_required_pass"
	assert_returns 0 "branch protection 404 + passing ruleset-required check → allowed"
	assert_log_contains "active rulesets require contexts" \
		"rulesets_404_pass: ruleset context logged"
	assert_log_contains "all required contexts passing" \
		"rulesets_404_pass: pass message logged"
	return 0
}

test_rulesets_required_with_simple_glob() {
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="not_found"
	export MOCK_RULESETS_MODE="active_required_star"
	export MOCK_ROLLUP_MODE="one_required_failing"
	assert_returns 1 "branch protection 404 + simple '*' ruleset glob → blocked"
	assert_log_contains "active rulesets require contexts" \
		"rulesets_star_glob: ruleset context logged"
	assert_log_contains "required context(s) not passing" \
		"rulesets_star_glob: block message logged"
	return 0
}

test_rulesets_required_with_plain_branch() {
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="not_found"
	export MOCK_RULESETS_MODE="active_required_plain_branch"
	export MOCK_ROLLUP_MODE="one_required_failing"
	assert_returns 1 "branch protection 404 + plain default-branch ruleset → blocked"
	assert_log_contains "active rulesets require contexts" \
		"rulesets_plain_branch: ruleset context logged"
	assert_log_contains "required context(s) not passing" \
		"rulesets_plain_branch: block message logged"
	return 0
}

test_rulesets_excludes_default_branch() {
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="not_found"
	export MOCK_RULESETS_MODE="active_required_excluded_default"
	export MOCK_ROLLUP_MODE="one_required_failing"
	assert_returns 0 "branch protection 404 + ruleset excluding default branch → allowed"
	assert_log_contains "no classic branch protection or required ruleset contexts" \
		"rulesets_excluded_default: empty-context message logged"
	return 0
}

test_rulesets_non_matching_branch_ignored() {
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="not_found"
	export MOCK_RULESETS_MODE="active_required_other_branch"
	export MOCK_ROLLUP_MODE="one_required_failing"
	assert_returns 0 "branch protection 404 + non-default ruleset → allowed"
	assert_log_contains "no classic branch protection or required ruleset contexts" \
		"rulesets_non_default: empty-context message logged"
	return 0
}

test_default_branch_api_error() {
	reset_logs
	export MOCK_REPO_MODE="error"
	export MOCK_BP_MODE="three_required"
	export MOCK_ROLLUP_MODE="all_required_pass"
	assert_returns 1 "default branch API error → blocked (fail-closed)"
	assert_log_contains "failed to resolve default branch" \
		"db_error: fail-closed message logged"
	return 0
}

test_branch_protection_api_error() {
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="error"
	export MOCK_ROLLUP_MODE="all_required_pass"
	assert_returns 1 "branch protection API error → blocked (fail-closed)"
	assert_log_contains "branch protection API failed" \
		"bp_error: fail-closed message logged"
	return 0
}

test_rollup_api_error() {
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="three_required"
	export MOCK_ROLLUP_MODE="error"
	assert_returns 1 "REST check-runs API error → blocked (fail-closed)"
	assert_log_contains "REST check-runs fetch failed" \
		"rollup_error: fail-closed message logged"
	return 0
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_function_under_test; then
		printf 'FATAL: function extraction failed\n' >&2
		return 1
	fi

	test_all_required_pass
	test_phantom_pending_non_required
	test_one_required_failing
	test_required_context_absent_from_rollup
	test_no_required_contexts
	test_rulesets_required_on_branch_protection_404_block
	test_rulesets_required_on_branch_protection_404_pass
	test_rulesets_required_with_simple_glob
	test_rulesets_required_with_plain_branch
	test_rulesets_excludes_default_branch
	test_rulesets_non_matching_branch_ignored
	test_default_branch_api_error
	test_branch_protection_api_error
	test_rollup_api_error

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
