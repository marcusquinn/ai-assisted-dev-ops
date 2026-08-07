#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-sync-pat-detection.sh — t2374 / t2806 regression guard.
#
# Verifies check_sync_pat() in security-posture-helper.sh correctly detects
# repos that need SYNC_PAT but don't have it set, and skips repos where
# SYNC_PAT is not needed — across BOTH classic branch-protection and
# repository-rulesets (t2806) protection mechanisms.
#
# Test cases:
#   1. issue-sync.yml + classic protection + NO SYNC_PAT → emits advisory
#   2. issue-sync.yml + classic protection + HAS SYNC_PAT → no advisory
#   3. No issue-sync.yml → no advisory (irrelevant)
#   4. No protection (classic or rulesets) → no advisory
#   5. Dismissed advisory → skip silently
#   6. Stale advisory cleaned up when SYNC_PAT set
#   7. issue-sync.yml + rulesets-only (pull_request) + NO SYNC_PAT → emits advisory (t2806)
#   8. issue-sync.yml + rulesets-only (required_status_checks) + NO SYNC_PAT → emits advisory (t2806)
#   9. issue-sync.yml + rulesets-only (no relevant rules) → no advisory
#  10. issue-sync.yml + both classic + rulesets + NO SYNC_PAT → classic wins, emits advisory
#  11. ruleset targeting another branch → no advisory
#  12. protected branch + Actions PR creation enabled → no advisory
#  13. classic protection with zero approvals + Actions PR creation disabled → emits advisory
#  14. classic protection without PR/check requirements → no advisory
#
# Stub strategy: a single configurable gh() stub dispatches based on
# STUB_* variables set per test. This avoids redefining gh() 6 times
# and eliminates direct positional parameter usage across stub functions.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$msg"
	return 0
}

fail() {
	local msg="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$msg"
	if [[ -n "$detail" ]]; then
		printf '       %s\n' "$detail"
	fi
	return 0
}

# =============================================================================
# Sandbox setup
# =============================================================================
TMP=$(mktemp -d -t t2374.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# Override HOME so advisory files go into sandbox
export HOME="$TMP"
mkdir -p "$TMP/.aidevops/advisories"

# Create a fake repo dir
FAKE_REPO="$TMP/fake-repo"
mkdir -p "$FAKE_REPO/.git"

# Constants for stub responses
readonly ISSUE_SYNC_RESPONSE='{"name":"issue-sync.yml"}'
readonly PROTECTION_WITH_REVIEWS='{"required_pull_request_reviews":{"required_approving_review_count":1}}'
readonly PROTECTION_WITHOUT_REVIEWS='{"required_pull_request_reviews":{"required_approving_review_count":0}}'
readonly PROTECTION_WITHOUT_PUBLICATION_GATE='{"enforce_admins":{"enabled":true},"allow_force_pushes":{"enabled":false}}'
readonly GH_API_SYNC_PATTERN="contents/.github/workflows/issue-sync.yml"
readonly GH_API_PROT_PATTERN="/protection"
readonly GH_API_RULESETS_LIST_PATTERN="/rulesets"
readonly GH_API_ACTIONS_PERMISSIONS_PATTERN="actions/permissions/workflow"

# Rulesets fixtures (t2806)
readonly RULESETS_LIST_WITH_ACTIVE='[{"id":1000,"enforcement":"active"}]'
readonly RULESETS_LIST_EMPTY='[]'

# Active ruleset on default branch with pull_request rule
readonly RULESET_DETAIL_PULL_REQUEST='{"conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":[{"type":"pull_request"},{"type":"non_fast_forward"}]}'
# Active ruleset on default branch with required_status_checks only
readonly RULESET_DETAIL_STATUS_CHECKS='{"conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":[{"type":"required_status_checks"},{"type":"deletion"}]}'
# Active ruleset on default branch with no relevant protection rules
readonly RULESET_DETAIL_NO_RELEVANT='{"conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":[{"type":"non_fast_forward"},{"type":"deletion"}]}'
# Active ruleset NOT matching default branch
readonly RULESET_DETAIL_OTHER_BRANCH='{"conditions":{"ref_name":{"include":["refs/heads/feature"]}},"rules":[{"type":"pull_request"}]}'

# =============================================================================
# Configurable stub variables (set per test case)
# =============================================================================
STUB_HAS_ISSUE_SYNC="true"       # "true" = API returns 200, "false" = API returns 1
STUB_PROTECTION_RESPONSE=""      # JSON response from /protection, empty = no protection
STUB_SECRET_RESPONSE=""          # Output from gh secret list, empty = no SYNC_PAT
STUB_RULESETS_LIST=""            # JSON response for /rulesets list endpoint
STUB_RULESET_DETAIL=""           # JSON response for /rulesets/{id} detail endpoint
STUB_ACTIONS_PR_CREATION="false" # "true" when GITHUB_TOKEN may create PRs

# Single shared gh stub — dispatches based on STUB_* variables
gh() {
	local cmd="$1"
	case "$cmd" in
	auth)
		return 0
		;;
	api)
		local url="${2:-}"
		if [[ "$url" == *"$GH_API_SYNC_PATTERN"* ]]; then
			if [[ "$STUB_HAS_ISSUE_SYNC" == "true" ]]; then
				echo "$ISSUE_SYNC_RESPONSE"
				return 0
			fi
			return 1
		elif [[ "$url" == *"$GH_API_ACTIONS_PERMISSIONS_PATTERN"* ]]; then
			printf '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":%s}\n' \
				"$STUB_ACTIONS_PR_CREATION"
			return 0
		elif [[ "$url" == *"$GH_API_PROT_PATTERN"* ]]; then
			if [[ -n "$STUB_PROTECTION_RESPONSE" ]]; then
				echo "$STUB_PROTECTION_RESPONSE"
				return 0
			fi
			echo "Branch not protected"
			return 1
		elif [[ "$url" == *"/rulesets/"* ]]; then
			# Individual ruleset detail endpoint
			if [[ -n "$STUB_RULESET_DETAIL" ]]; then
				echo "$STUB_RULESET_DETAIL"
				return 0
			fi
			return 1
		elif [[ "$url" == *"$GH_API_RULESETS_LIST_PATTERN" ]]; then
			# List rulesets endpoint (suffix match)
			if [[ -n "$STUB_RULESETS_LIST" ]]; then
				echo "$STUB_RULESETS_LIST"
				return 0
			fi
			return 1
		fi
		return 1
		;;
	secret)
		echo "$STUB_SECRET_RESPONSE"
		return 0
		;;
	esac
	return 0
}

# Stub git for default branch detection
git() {
	local subcmd="${2:-}"
	if [[ "$subcmd" == "symbolic-ref" ]]; then
		echo "refs/remotes/origin/main"
		return 0
	fi
	command git "$@"
}

# Stub jq: delegate to real jq so rulesets detail parsing works end-to-end.
# For protection JSON parsing (classic path), real jq also works correctly
# against the fixture, so no special-casing is needed.
jq() {
	command jq "$@"
}

export -f gh git jq

# =============================================================================
# Source the helper to get check_sync_pat
# =============================================================================

# Prevent shared-constants.sh from doing anything destructive
export AIDEVOPS_AGENTS_DIR="$TMP/.aidevops/agents"
mkdir -p "$AIDEVOPS_AGENTS_DIR"

# Source shared-constants.sh fallbacks
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${CYAN+x}" ]] && CYAN='\033[0;36m'
[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# Counters (same as in the helper)
FINDINGS_CRITICAL=0
FINDINGS_WARNING=0
FINDINGS_INFO=0
FINDINGS_PASS=0
FINDINGS_JSON="[]"

# Stubs for print functions — capture output for assertions
OUTPUT_LOG="$TMP/output.log"

print_header() {
	local msg="$1"
	echo "[HEADER] $msg" >>"$OUTPUT_LOG"
	return 0
}
print_info() {
	local msg="$1"
	echo "[INFO] $msg" >>"$OUTPUT_LOG"
	return 0
}
print_pass() {
	local msg="$1"
	echo "[PASS] $msg" >>"$OUTPUT_LOG"
	((++FINDINGS_PASS))
	return 0
}
print_warn() {
	local msg="$1"
	echo "[WARN] $msg" >>"$OUTPUT_LOG"
	((++FINDINGS_WARNING))
	return 0
}
print_crit() {
	local msg="$1"
	echo "[CRIT] $msg" >>"$OUTPUT_LOG"
	((++FINDINGS_CRITICAL))
	return 0
}
print_skip() {
	local msg="$1"
	echo "[SKIP] $msg" >>"$OUTPUT_LOG"
	((++FINDINGS_INFO))
	return 0
}

add_finding() {
	# No-op for tests — we check output log and advisory files instead
	return 0
}

# resolve_slug stub
resolve_slug() {
	echo "testowner/testrepo"
	return 0
}

# Extract function bodies from the helper (check_sync_pat + its sub-functions).
# Order matters: _branch_is_rulesets_protected is called by _check_sync_pat_need
# (t2806), so it must be defined first.
eval "$(sed -n '/^_emit_sync_pat_advisory()/,/^}/p' "${SCRIPTS_DIR}/security-posture-helper-repo.sh")"
eval "$(sed -n '/^_ruleset_targets_default_branch()/,/^}/p' "${SCRIPTS_DIR}/security-posture-helper-repo.sh")"
eval "$(sed -n '/^_default_branch_ruleset_details()/,/^}/p' "${SCRIPTS_DIR}/security-posture-helper-repo.sh")"
eval "$(sed -n '/^_branch_is_rulesets_protected()/,/^}/p' "${SCRIPTS_DIR}/security-posture-helper-repo.sh")"
eval "$(sed -n '/^_actions_can_create_pull_requests()/,/^}/p' "${SCRIPTS_DIR}/security-posture-helper-repo.sh")"
eval "$(sed -n '/^_check_sync_pat_need()/,/^}/p' "${SCRIPTS_DIR}/security-posture-helper-repo.sh")"
eval "$(sed -n '/^check_sync_pat()/,/^}/p' "${SCRIPTS_DIR}/security-posture-helper-repo.sh")"

# =============================================================================
# Severity constants needed by the function
# =============================================================================
SEVERITY_CRITICAL="critical"
SEVERITY_WARNING="warning"
SEVERITY_INFO="info"
SEVERITY_PASS="pass"
CAT_SYNC_PAT="sync_pat"
SYNC_PAT_NEED_NOT_NEEDED="not_needed"
SYNC_PAT_PROTECTION_CLASSIC="classic"
RULESET_ENFORCEMENT_ACTIVE="active"
RULESET_DEFAULT_BRANCH_TOKEN="~DEFAULT_BRANCH"
RULESET_ALL_BRANCHES_TOKEN="~ALL"
RULESET_ALL_HEADS_PATTERN="refs/heads/*"

# Global result variable (t2806). _check_sync_pat_need writes here instead
# of using stdout capture, which was broken by print_pass stdout output.
SYNC_PAT_NEED_RESULT=""

# =============================================================================
# Helper to reset state between tests
# =============================================================================
reset_state() {
	FINDINGS_CRITICAL=0
	FINDINGS_WARNING=0
	FINDINGS_INFO=0
	FINDINGS_PASS=0
	FINDINGS_JSON="[]"
	true >"$OUTPUT_LOG"
	rm -f "$TMP/.aidevops/advisories/sync-pat-"*
	rm -f "$TMP/.aidevops/advisories/.dismissed-sync-pat-"*
	# Reset stub defaults
	STUB_HAS_ISSUE_SYNC="true"
	STUB_PROTECTION_RESPONSE="$PROTECTION_WITH_REVIEWS"
	STUB_SECRET_RESPONSE=""
	# Rulesets defaults to "no rulesets" (t2806). Individual tests that
	# exercise the rulesets path set STUB_RULESETS_LIST and STUB_RULESET_DETAIL.
	STUB_RULESETS_LIST=""
	STUB_RULESET_DETAIL=""
	STUB_ACTIONS_PR_CREATION="false"
	return 0
}

ADVISORY_PATH="$TMP/.aidevops/advisories/sync-pat-testowner-testrepo.advisory"

# =============================================================================
# Test 1: Needs SYNC_PAT — emits advisory
# =============================================================================
printf '\n%sTest 1: Repo needs SYNC_PAT (issue-sync + protection + no secret)%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
STUB_HAS_ISSUE_SYNC="true"
STUB_PROTECTION_RESPONSE="$PROTECTION_WITH_REVIEWS"
STUB_SECRET_RESPONSE=""

check_sync_pat "$FAKE_REPO"

if [[ -f "$ADVISORY_PATH" ]]; then
	pass "Advisory file created for repo needing SYNC_PAT"
else
	fail "Advisory file NOT created" "Expected: $ADVISORY_PATH"
fi

if [[ -f "$ADVISORY_PATH" ]] && grep -q "gh secret set SYNC_PAT" "$ADVISORY_PATH" 2>/dev/null; then
	pass "Advisory contains remediation command"
else
	fail "Advisory missing remediation command"
fi

if grep -q '\[WARN\].*SYNC_PAT not set' "$OUTPUT_LOG" 2>/dev/null; then
	pass "Warning emitted for missing SYNC_PAT"
else
	fail "No warning emitted" "Log: $(cat "$OUTPUT_LOG")"
fi

# =============================================================================
# Test 2: SYNC_PAT already set — no advisory
# =============================================================================
printf '\n%sTest 2: SYNC_PAT already set — should pass cleanly%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
STUB_SECRET_RESPONSE="SYNC_PAT"

check_sync_pat "$FAKE_REPO"

if [[ ! -f "$ADVISORY_PATH" ]]; then
	pass "No advisory when SYNC_PAT is set"
else
	fail "Advisory created despite SYNC_PAT being set"
fi

if grep -q '\[PASS\].*SYNC_PAT is set' "$OUTPUT_LOG" 2>/dev/null; then
	pass "Pass message emitted for set SYNC_PAT"
else
	fail "No pass message" "Log: $(cat "$OUTPUT_LOG")"
fi

# =============================================================================
# Test 3: No issue-sync.yml — no advisory
# =============================================================================
printf '\n%sTest 3: No issue-sync.yml — should skip%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
STUB_HAS_ISSUE_SYNC="false"

check_sync_pat "$FAKE_REPO"

if [[ ! -f "$ADVISORY_PATH" ]]; then
	pass "No advisory when issue-sync.yml absent"
else
	fail "Advisory created for repo without issue-sync.yml"
fi

if grep -q '\[PASS\].*No issue-sync.yml' "$OUTPUT_LOG" 2>/dev/null; then
	pass "Pass message emitted for no issue-sync.yml"
else
	fail "No pass message for absent workflow" "Log: $(cat "$OUTPUT_LOG")"
fi

# =============================================================================
# Test 4: No branch protection requiring reviews — no advisory
# =============================================================================
printf '\n%sTest 4: No branch protection requiring reviews — should skip%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
STUB_PROTECTION_RESPONSE=""

check_sync_pat "$FAKE_REPO"

if [[ ! -f "$ADVISORY_PATH" ]]; then
	pass "No advisory when no branch protection"
else
	fail "Advisory created for repo without branch protection"
fi

if grep -q '\[PASS\].*No branch protection' "$OUTPUT_LOG" 2>/dev/null; then
	pass "Pass message emitted for no branch protection"
else
	fail "No pass message for unprotected branch" "Log: $(cat "$OUTPUT_LOG")"
fi

# =============================================================================
# Test 5: Dismissed advisory — should skip silently
# =============================================================================
printf '\n%sTest 5: Dismissed advisory — should skip%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
touch "$TMP/.aidevops/advisories/.dismissed-sync-pat-testowner-testrepo"

check_sync_pat "$FAKE_REPO"

if [[ ! -f "$ADVISORY_PATH" ]]; then
	pass "No advisory when dismissed"
else
	fail "Advisory created despite being dismissed"
fi

if grep -q '\[PASS\].*dismissed' "$OUTPUT_LOG" 2>/dev/null; then
	pass "Pass message emitted for dismissed advisory"
else
	fail "No pass message for dismissed advisory" "Log: $(cat "$OUTPUT_LOG")"
fi

# =============================================================================
# Test 6: Stale advisory cleaned up when SYNC_PAT is set
# =============================================================================
printf '\n%sTest 6: Stale advisory cleaned up when SYNC_PAT set%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
echo "stale" >"$ADVISORY_PATH"
STUB_SECRET_RESPONSE="SYNC_PAT"

check_sync_pat "$FAKE_REPO"

if [[ ! -f "$ADVISORY_PATH" ]]; then
	pass "Stale advisory cleaned up after SYNC_PAT set"
else
	fail "Stale advisory NOT cleaned up"
fi

# =============================================================================
# Test 7 (t2806): Rulesets-only protection with pull_request rule — emits advisory
# =============================================================================
printf '\n%sTest 7 (t2806): Rulesets-only protection (pull_request) — should advise%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
STUB_PROTECTION_RESPONSE="" # Classic API returns 404
STUB_RULESETS_LIST="$RULESETS_LIST_WITH_ACTIVE"
STUB_RULESET_DETAIL="$RULESET_DETAIL_PULL_REQUEST"
STUB_SECRET_RESPONSE=""

check_sync_pat "$FAKE_REPO"

if [[ -f "$ADVISORY_PATH" ]]; then
	pass "Advisory fired for rulesets-protected repo (pull_request rule)"
else
	fail "Advisory NOT fired for rulesets-protected repo" "Log: $(cat "$OUTPUT_LOG")"
fi

if [[ -f "$ADVISORY_PATH" ]] && grep -q "rulesets-based" "$ADVISORY_PATH" 2>/dev/null; then
	pass "Advisory mentions rulesets-based protection"
else
	fail "Advisory missing rulesets-based description"
fi

# =============================================================================
# Test 8 (t2806): Rulesets-only with required_status_checks — emits advisory
# =============================================================================
printf '\n%sTest 8 (t2806): Rulesets-only (required_status_checks) — should advise%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
STUB_PROTECTION_RESPONSE=""
STUB_RULESETS_LIST="$RULESETS_LIST_WITH_ACTIVE"
STUB_RULESET_DETAIL="$RULESET_DETAIL_STATUS_CHECKS"
STUB_SECRET_RESPONSE=""

check_sync_pat "$FAKE_REPO"

if [[ -f "$ADVISORY_PATH" ]]; then
	pass "Advisory fired for rulesets with required_status_checks (example-repo/develop case)"
else
	fail "Advisory NOT fired for status-checks rulesets" "Log: $(cat "$OUTPUT_LOG")"
fi

# =============================================================================
# Test 9 (t2806): Rulesets-only with no relevant rules — no advisory
# =============================================================================
printf '\n%sTest 9 (t2806): Rulesets with only deletion/non_fast_forward — no advisory%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
STUB_PROTECTION_RESPONSE=""
STUB_RULESETS_LIST="$RULESETS_LIST_WITH_ACTIVE"
STUB_RULESET_DETAIL="$RULESET_DETAIL_NO_RELEVANT"
STUB_SECRET_RESPONSE=""

check_sync_pat "$FAKE_REPO"

if [[ ! -f "$ADVISORY_PATH" ]]; then
	pass "No advisory when rulesets have no meaningful protection rules"
else
	fail "Advisory fired for rulesets with no review/check rules"
fi

if grep -q '\[PASS\].*No branch protection' "$OUTPUT_LOG" 2>/dev/null; then
	pass "PASS message emitted when only deletion/non_fast_forward rules present"
else
	fail "Expected pass message for non-protective rulesets" "Log: $(cat "$OUTPUT_LOG")"
fi

# =============================================================================
# Test 10 (t2806): Both classic and rulesets — classic path wins, emits advisory
# =============================================================================
printf '\n%sTest 10 (t2806): Both classic + rulesets protection — classic takes precedence%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
STUB_PROTECTION_RESPONSE="$PROTECTION_WITH_REVIEWS"
STUB_RULESETS_LIST="$RULESETS_LIST_WITH_ACTIVE"
STUB_RULESET_DETAIL="$RULESET_DETAIL_PULL_REQUEST"
STUB_SECRET_RESPONSE=""

check_sync_pat "$FAKE_REPO"

if [[ -f "$ADVISORY_PATH" ]]; then
	pass "Advisory fired when both classic and rulesets present"
else
	fail "Advisory NOT fired for dual-protection repo"
fi

if [[ -f "$ADVISORY_PATH" ]] && grep -q "requiring.*approving review" "$ADVISORY_PATH" 2>/dev/null; then
	pass "Classic protection description wins when both exist"
else
	fail "Classic description missing — rulesets path may have taken precedence" "Advisory: $(cat "$ADVISORY_PATH" 2>/dev/null || echo "<missing>")"
fi

# =============================================================================
# Test 11 (t2806): Rulesets targeting a non-default branch — no advisory
# =============================================================================
printf '\n%sTest 11 (t2806): Ruleset targeting feature/ branch, not default — no advisory%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
STUB_PROTECTION_RESPONSE=""
STUB_RULESETS_LIST="$RULESETS_LIST_WITH_ACTIVE"
STUB_RULESET_DETAIL="$RULESET_DETAIL_OTHER_BRANCH"
STUB_SECRET_RESPONSE=""

check_sync_pat "$FAKE_REPO"

if [[ ! -f "$ADVISORY_PATH" ]]; then
	pass "No advisory when rulesets target non-default branch"
else
	fail "Advisory fired despite rulesets not matching default branch"
fi

# =============================================================================
# Test 12: Protected branch with Actions PR creation enabled — no PAT needed
# =============================================================================
printf '\n%sTest 12: Actions PR creation enabled — should skip%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
echo "stale" >"$ADVISORY_PATH"
STUB_ACTIONS_PR_CREATION="true"

check_sync_pat "$FAKE_REPO"

if [[ ! -f "$ADVISORY_PATH" ]]; then
	pass "Actions PR creation removes the SYNC_PAT requirement and stale advisory"
else
	fail "Advisory retained despite Actions PR creation being enabled"
fi

if grep -q '\[PASS\].*Actions can create the issue-sync PR' "$OUTPUT_LOG" 2>/dev/null; then
	pass "Pass message identifies the sufficient job-token PR path"
else
	fail "No pass message for enabled Actions PR creation" "Log: $(cat "$OUTPUT_LOG")"
fi

# =============================================================================
# Test 13: Zero approvals still needs PAT when Actions cannot create the PR
# =============================================================================
printf '\n%sTest 13: Zero approvals with Actions PR creation disabled — should advise%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
STUB_PROTECTION_RESPONSE="$PROTECTION_WITHOUT_REVIEWS"

check_sync_pat "$FAKE_REPO"

if [[ -f "$ADVISORY_PATH" ]]; then
	pass "Protected PR path advises despite zero required approvals"
else
	fail "No advisory for protected PR path with disabled Actions PR creation"
fi

# =============================================================================
# Test 14: Classic protection without PR/check requirements — no PAT needed
# =============================================================================
printf '\n%sTest 14: Non-publication classic protection — should skip%s\n' "$TEST_BLUE" "$TEST_NC"
reset_state
STUB_PROTECTION_RESPONSE="$PROTECTION_WITHOUT_PUBLICATION_GATE"

check_sync_pat "$FAKE_REPO"

if [[ ! -f "$ADVISORY_PATH" ]]; then
	pass "Non-publication branch protection does not trigger a SYNC_PAT advisory"
else
	fail "Advisory fired for protection that does not block direct publication"
fi

if grep -q '\[PASS\].*does not block direct issue-sync publication' "$OUTPUT_LOG" 2>/dev/null; then
	pass "Pass message identifies non-publication branch protection"
else
	fail "No pass message for non-publication branch protection" "Log: $(cat "$OUTPUT_LOG")"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "======================================="
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
else
	printf '%s%d of %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
fi
echo "======================================="

exit "$TESTS_FAILED"
