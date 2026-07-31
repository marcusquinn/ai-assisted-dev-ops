#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-security-posture-public-pr-gating.sh — GH#22195 regression guard.
#
# Verifies public ADMIN repositories fail posture checks when default-branch PR
# merge gating is incomplete, while classic and rulesets-backed protection with
# review + required checks passes the branch protection phase.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
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

TMP=$(mktemp -d -t gh22195.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

FAKE_REPO="$TMP/fake-repo"
mkdir -p "$FAKE_REPO/.git"
mkdir -p "$FAKE_REPO/.github/workflows"
touch "$FAKE_REPO/.github/workflows/linked-issue-check.yml"

OUTPUT_LOG="$TMP/output.log"
FINDINGS_CRITICAL=0
FINDINGS_WARNING=0
FINDINGS_INFO=0
FINDINGS_PASS=0
FINDINGS_JSON="[]"

readonly CLASSIC_GOOD='{"required_pull_request_reviews":{"required_approving_review_count":1},"required_status_checks":{"contexts":["review-bot-gate"]},"enforce_admins":{"enabled":true}}'
readonly CLASSIC_NO_REVIEWS='{"required_pull_request_reviews":{"required_approving_review_count":0},"required_status_checks":{"contexts":["review-bot-gate"]},"enforce_admins":{"enabled":true}}'
readonly CLASSIC_NO_PR='{"required_status_checks":{"contexts":["review-bot-gate"]},"enforce_admins":{"enabled":true}}'
readonly CLASSIC_NO_CHECKS='{"required_pull_request_reviews":{"required_approving_review_count":1},"required_status_checks":{"contexts":[]},"enforce_admins":{"enabled":true}}'
readonly CLASSIC_ADMIN_BYPASS='{"required_pull_request_reviews":{"required_approving_review_count":1},"required_status_checks":{"contexts":["review-bot-gate"]},"enforce_admins":{"enabled":false}}'
readonly REPO_PUBLIC_ADMIN='{"private":false,"permissions":{"admin":true}}'
readonly RULESETS_LIST_ACTIVE='[{"id":1000,"enforcement":"active"}]'
readonly RULESET_GOOD='{"conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1}},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"review-bot-gate"}]}}],"bypass_actors":[]}'
readonly RULESET_NO_REVIEWS='{"conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":0}},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"review-bot-gate"}]}}],"bypass_actors":[]}'
readonly RULESET_NO_PR='{"conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"review-bot-gate"}]}}],"bypass_actors":[]}'
readonly RULESET_NO_CHECKS='{"conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1}}],"bypass_actors":[]}'
readonly CLASSIC_LINKED_ISSUE='{"required_status_checks":{"contexts":["linked-issue-check"]}}'
readonly RULESET_LINKED_ISSUE='{"conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"linked-issue-check"}]}}],"bypass_actors":[]}'

STUB_REPO_JSON="$REPO_PUBLIC_ADMIN"
STUB_PROTECTION_RESPONSE="$CLASSIC_GOOD"
STUB_RULESETS_LIST=""
STUB_RULESET_DETAIL=""
STUB_COLLABORATORS_RESPONSE='[{"login":"owner","type":"User","role_name":"admin","permissions":{"admin":true,"push":true}}]'
STUB_COLLABORATORS_AVAILABLE=true

gh() {
	local cmd="$1"
	case "$cmd" in
	api)
		local url=""
		local arg
		for arg in "$@"; do
			case "$arg" in
			repos/*) url="$arg" ;;
			esac
		done
		case "$url" in
		"repos/testowner/testrepo")
			printf '%s\n' "$STUB_REPO_JSON"
			return 0
			;;
		*"/branches/main/protection")
			if [[ -n "$STUB_PROTECTION_RESPONSE" ]]; then
				printf '%s\n' "$STUB_PROTECTION_RESPONSE"
				return 0
			fi
			printf '%s\n' "Branch not protected"
			return 1
			;;
		*"/rulesets/"*)
			if [[ -n "$STUB_RULESET_DETAIL" ]]; then
				printf '%s\n' "$STUB_RULESET_DETAIL"
				return 0
			fi
			return 1
			;;
		*"/rulesets")
			if [[ -n "$STUB_RULESETS_LIST" ]]; then
				printf '%s\n' "$STUB_RULESETS_LIST"
				return 0
			fi
			return 1
			;;
		*"/collaborators?per_page=100")
			if [[ "$STUB_COLLABORATORS_AVAILABLE" == true ]]; then
				printf '%s\n' "$STUB_COLLABORATORS_RESPONSE" | command jq -c '.[] | {login: .login, type: .type, role: .role_name, permissions: .permissions}'
				return 0
			fi
			return 1
			;;
		esac
		return 1
		;;
	esac
	return 0
}

git() {
	local subcmd="${2:-}"
	if [[ "$subcmd" == "symbolic-ref" ]]; then
		printf '%s\n' "refs/remotes/origin/main"
		return 0
	fi
	command git "$@"
}

jq() {
	command jq "$@"
}

export -f gh git jq

print_header() { local msg="$1"; printf '[HEADER] %s\n' "$msg" >>"$OUTPUT_LOG"; return 0; }
print_info() { local msg="$1"; printf '[INFO] %s\n' "$msg" >>"$OUTPUT_LOG"; return 0; }
print_pass() { local msg="$1"; printf '[PASS] %s\n' "$msg" >>"$OUTPUT_LOG"; return 0; }
print_warn() { local msg="$1"; printf '[WARN] %s\n' "$msg" >>"$OUTPUT_LOG"; return 0; }
print_crit() { local msg="$1"; printf '[CRIT] %s\n' "$msg" >>"$OUTPUT_LOG"; return 0; }
print_skip() { local msg="$1"; printf '[SKIP] %s\n' "$msg" >>"$OUTPUT_LOG"; return 0; }

add_finding() {
	local severity="$1"
	local _category="$2"
	local _message="$3"
	case "$severity" in
	critical) FINDINGS_CRITICAL=$((FINDINGS_CRITICAL + 1)) ;;
	warning) FINDINGS_WARNING=$((FINDINGS_WARNING + 1)) ;;
	info) FINDINGS_INFO=$((FINDINGS_INFO + 1)) ;;
	pass) FINDINGS_PASS=$((FINDINGS_PASS + 1)) ;;
	esac
	return 0
}

resolve_slug() {
	local _repo_path="$1"
	printf '%s\n' "testowner/testrepo"
	return 0
}

# shellcheck source=../security-posture-helper-repo.sh
source "${SCRIPTS_DIR}/security-posture-helper-repo.sh"

SEVERITY_CRITICAL="critical"
SEVERITY_WARNING="warning"
SEVERITY_INFO="info"
SEVERITY_PASS="pass"
CAT_BRANCH_PROTECTION="branch_protection"
CAT_LINKED_ISSUE_GATE="linked_issue_gate"

reset_state() {
	FINDINGS_CRITICAL=0
	FINDINGS_WARNING=0
	FINDINGS_INFO=0
	FINDINGS_PASS=0
	true >"$OUTPUT_LOG"
	STUB_REPO_JSON="$REPO_PUBLIC_ADMIN"
	STUB_PROTECTION_RESPONSE="$CLASSIC_GOOD"
	STUB_RULESETS_LIST=""
	STUB_RULESET_DETAIL=""
	STUB_COLLABORATORS_RESPONSE='[{"login":"owner","type":"User","role_name":"admin","permissions":{"admin":true,"push":true}}]'
	STUB_COLLABORATORS_AVAILABLE=true
	return 0
}

assert_counts() {
	local name="$1"
	local expected_critical="$2"
	local expected_warning="$3"
	if [[ "$FINDINGS_CRITICAL" -eq "$expected_critical" && "$FINDINGS_WARNING" -eq "$expected_warning" ]]; then
		pass "$name"
	else
		fail "$name" "critical=$FINDINGS_CRITICAL warning=$FINDINGS_WARNING output=$(tr '\n' ';' <"$OUTPUT_LOG")"
	fi
	return 0
}

reset_state
STUB_PROTECTION_RESPONSE=""
check_branch_protection "$FAKE_REPO"
assert_counts "public ADMIN without classic protection or rulesets is critical" 1 0

reset_state
STUB_PROTECTION_RESPONSE="$CLASSIC_NO_REVIEWS"
check_branch_protection "$FAKE_REPO"
assert_counts "verified solo-maintainer classic protection allows zero approvals" 0 0

reset_state
STUB_PROTECTION_RESPONSE="$CLASSIC_NO_PR"
check_branch_protection "$FAKE_REPO"
assert_counts "verified solo-maintainer classic protection still requires pull requests" 1 0

reset_state
STUB_PROTECTION_RESPONSE="$CLASSIC_NO_REVIEWS"
STUB_COLLABORATORS_RESPONSE='[{"login":"owner","type":"User","role_name":"admin"},{"login":"maintainer","type":"User","role_name":"write"}]'
check_branch_protection "$FAKE_REPO"
assert_counts "multi-maintainer classic protection without reviews is critical" 1 0

reset_state
STUB_PROTECTION_RESPONSE="$CLASSIC_NO_REVIEWS"
STUB_COLLABORATORS_AVAILABLE=false
check_branch_protection "$FAKE_REPO"
assert_counts "unknown collaborator topology retains strict classic review finding" 1 0

reset_state
STUB_PROTECTION_RESPONSE="$CLASSIC_NO_CHECKS"
check_branch_protection "$FAKE_REPO"
assert_counts "public ADMIN classic protection without checks is critical" 1 0

reset_state
STUB_PROTECTION_RESPONSE="$CLASSIC_ADMIN_BYPASS"
check_branch_protection "$FAKE_REPO"
assert_counts "public ADMIN classic protection with admin bypass is critical" 1 0

reset_state
STUB_PROTECTION_RESPONSE=""
STUB_RULESETS_LIST="$RULESETS_LIST_ACTIVE"
STUB_RULESET_DETAIL="$RULESET_GOOD"
check_branch_protection "$FAKE_REPO"
assert_counts "public ADMIN rulesets with reviews and checks pass" 0 0

reset_state
STUB_PROTECTION_RESPONSE=""
STUB_RULESETS_LIST="$RULESETS_LIST_ACTIVE"
STUB_RULESET_DETAIL="$RULESET_NO_REVIEWS"
check_branch_protection "$FAKE_REPO"
assert_counts "verified solo-maintainer rulesets allow zero approvals" 0 0

reset_state
STUB_PROTECTION_RESPONSE=""
STUB_RULESETS_LIST="$RULESETS_LIST_ACTIVE"
STUB_RULESET_DETAIL="$RULESET_NO_PR"
check_branch_protection "$FAKE_REPO"
assert_counts "verified solo-maintainer rulesets still require pull requests" 1 0

reset_state
STUB_PROTECTION_RESPONSE=""
STUB_RULESETS_LIST="$RULESETS_LIST_ACTIVE"
STUB_RULESET_DETAIL="$RULESET_NO_REVIEWS"
STUB_COLLABORATORS_RESPONSE='[{"login":"owner","type":"User","role_name":"admin"},{"login":"maintainer","type":"User","role_name":"maintain"},{"login":"ci-bot","type":"Bot","role_name":"write"}]'
check_branch_protection "$FAKE_REPO"
assert_counts "multi-maintainer rulesets without reviews remain critical while bots are excluded" 1 0

reset_state
STUB_PROTECTION_RESPONSE=""
STUB_RULESETS_LIST="$RULESETS_LIST_ACTIVE"
STUB_RULESET_DETAIL="$RULESET_NO_CHECKS"
check_branch_protection "$FAKE_REPO"
assert_counts "public ADMIN rulesets without checks is critical" 1 0

reset_state
STUB_PROTECTION_RESPONSE="$CLASSIC_LINKED_ISSUE"
check_linked_issue_gate "$FAKE_REPO"
assert_counts "linked-issue-check required via classic protection passes" 0 0

reset_state
STUB_PROTECTION_RESPONSE=""
STUB_RULESETS_LIST="$RULESETS_LIST_ACTIVE"
STUB_RULESET_DETAIL="$RULESET_LINKED_ISSUE"
check_linked_issue_gate "$FAKE_REPO"
assert_counts "linked-issue-check required via rulesets passes" 0 0

reset_state
STUB_PROTECTION_RESPONSE="$CLASSIC_NO_CHECKS"
check_linked_issue_gate "$FAKE_REPO"
assert_counts "linked-issue-check workflow not required warns" 0 1

printf '\nRan %d tests, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi

exit 0
