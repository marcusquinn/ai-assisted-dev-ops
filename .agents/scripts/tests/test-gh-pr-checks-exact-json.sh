#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LIB="${TEST_DIR}/../shared-gh-wrappers-checks.sh"
TEST_ROOT="$(mktemp -d)"
CALL_LOG="${TEST_ROOT}/gh-calls.log"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "${TEST_ROOT}/bin"
: >"$CALL_LOG"

cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "api" ]]; then
	printf 'unexpected command: %s\n' "$*" >&2
	exit 90
fi

endpoint="${2:-}"
if [[ "$endpoint" == "repos/owner/repo/pulls/42" ]]; then
	printf 'rest|%s|%s|%s\n' "${AIDEVOPS_GH_QUOTA_COST:-}" \
		"${AIDEVOPS_GH_ROUTE_DECISION:-}" "$*" >>"$CALL_LOG"
	if [[ "${GH_TEST_MODE:-multipage}" == "identity-error" ]]; then
		exit 1
	fi
	if [[ "${GH_TEST_MODE:-multipage}" == "identity-cooldown" ||
		"${GH_TEST_MODE:-multipage}" == "identity-read-deferred" ]]; then
		exit 75
	fi
	if [[ "${GH_TEST_MODE:-multipage}" == "identity-malformed" ]]; then
		printf '%s\n' '{"number":42,"node_id":"","head":{"ref":"feature/test","sha":"bad"}}'
		exit 0
	fi
	printf '%s\n' '{"number":42,"node_id":"PR_fixture","head":{"ref":"feature/test","sha":"0123456789abcdef0123456789abcdef01234567"}}'
	exit 0
fi

if [[ "$endpoint" != "graphql" ]]; then
	printf 'unexpected endpoint: %s\n' "$endpoint" >&2
	exit 91
fi

printf 'graphql|%s|%s|%s\n' "${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" \
	"${AIDEVOPS_GH_ROUTE_DECISION:-}" "$*" >>"$CALL_LOG"

mode="${GH_TEST_MODE:-multipage}"
args="$*"
page=1
[[ "$args" == *"endCursor=CURSOR1"* ]] && page=2

if [[ "$mode" == "graphql-cooldown" ]]; then
	exit 75
fi
if [[ "$mode" == "graphql-error" ]]; then
	printf '%s\n' '{"data":{"node":null,"rateLimit":{"cost":2}},"errors":[{"message":"field unavailable"}]}'
	exit 0
fi
if [[ "$mode" == "missing-rollup" ]]; then
	printf '%s\n' '{"data":{"node":{"__typename":"PullRequest","statusCheckRollup":{"nodes":[]}},"rateLimit":{"cost":1}}}'
	exit 0
fi

nodes='[]'
has_next=false
end_cursor=''
cost=1
case "$mode" in
multipage)
	if [[ "$page" -eq 1 ]]; then
		nodes='[
			{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-08-01T00:00:00Z","completedAt":"2026-08-01T00:01:00Z","detailsUrl":"https://example.invalid/old","isRequired":true,"checkSuite":{"workflowRun":{"event":"push","workflow":{"name":"CI"}}}},
			{"__typename":"CheckRun","name":"shadowed","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-08-01T00:05:00Z","completedAt":"2026-08-01T00:06:00Z","detailsUrl":"","isRequired":true,"checkSuite":{"workflowRun":{"event":"push","workflow":{"name":"CI"}}}},
			{"__typename":"StatusContext","context":"legacy","state":"PENDING","targetUrl":"","createdAt":"2026-08-01T00:00:00Z","description":"old status","isRequired":true}
		]'
		has_next=true
		end_cursor='CURSOR1'
		cost=2
	else
		nodes='[
			{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-08-01T01:00:00Z","completedAt":"2026-08-01T01:01:00Z","detailsUrl":"https://example.invalid/new","isRequired":true,"checkSuite":{"workflowRun":{"event":"push","workflow":{"name":"CI"}}}},
			{"__typename":"CheckRun","name":"shadowed","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-08-01T01:05:00Z","completedAt":"2026-08-01T01:06:00Z","detailsUrl":"","isRequired":false,"checkSuite":{"workflowRun":{"event":"push","workflow":{"name":"CI"}}}},
			{"__typename":"CheckRun","name":"deploy","status":"COMPLETED","conclusion":"SKIPPED","startedAt":"2026-08-01T00:30:00Z","completedAt":"2026-08-01T00:31:00Z","detailsUrl":"","isRequired":true,"checkSuite":{"workflowRun":{"event":"workflow_dispatch","workflow":{"name":"Release"}}}},
			{"__typename":"CheckRun","name":"optional","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-08-01T00:20:00Z","completedAt":"2026-08-01T00:21:00Z","detailsUrl":"","isRequired":false,"checkSuite":{"workflowRun":{"event":"pull_request","workflow":{"name":"Advisory"}}}},
			{"__typename":"StatusContext","context":"legacy","state":"SUCCESS","targetUrl":"https://example.invalid/status","createdAt":"2026-08-01T02:00:00Z","description":"new status","isRequired":true}
		]'
		cost=3
	fi
	;;
pending)
	nodes='[{"__typename":"CheckRun","name":"pending","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-08-01T00:00:00Z","completedAt":null,"detailsUrl":"","isRequired":true,"checkSuite":{"workflowRun":{"event":"push","workflow":{"name":"CI"}}}}]'
	;;
cancel)
	nodes='[{"__typename":"CheckRun","name":"cancelled","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-08-01T00:00:00Z","completedAt":"2026-08-01T00:01:00Z","detailsUrl":"","isRequired":true,"checkSuite":{"workflowRun":{"event":"push","workflow":{"name":"CI"}}}}]'
	;;
no-required)
	nodes='[{"__typename":"StatusContext","context":"optional","state":"SUCCESS","targetUrl":"","createdAt":"2026-08-01T00:00:00Z","description":"","isRequired":false}]'
	;;
empty)
	nodes='[]'
	;;
missing-cost)
	nodes='[{"__typename":"StatusContext","context":"required","state":"SUCCESS","targetUrl":"","createdAt":"2026-08-01T00:00:00Z","description":"","isRequired":true}]'
	;;
zero-cost)
	nodes='[{"__typename":"StatusContext","context":"required","state":"SUCCESS","targetUrl":"","createdAt":"2026-08-01T00:00:00Z","description":"","isRequired":true}]'
	cost=0
	;;
repeated-cursor)
	nodes='[{"__typename":"StatusContext","context":"required","state":"SUCCESS","targetUrl":"","createdAt":"2026-08-01T00:00:00Z","description":"","isRequired":true}]'
	has_next=true
	end_cursor='CURSOR1'
	;;
*)
	printf 'unknown fixture mode: %s\n' "$mode" >&2
	exit 92
	;;
esac

if [[ "$mode" == "missing-cost" ]]; then
	jq -nc --argjson nodes "$nodes" --argjson has_next "$has_next" --arg end_cursor "$end_cursor" '
		{data:{node:{__typename:"PullRequest",statusCheckRollup:{nodes:[{commit:{statusCheckRollup:{contexts:{nodes:$nodes,pageInfo:{hasNextPage:$has_next,endCursor:(if $end_cursor == "" then null else $end_cursor end)}}}}}]}}}}
	'
	exit 0
fi

jq -nc --argjson nodes "$nodes" --argjson has_next "$has_next" --arg end_cursor "$end_cursor" --argjson cost "$cost" '
	{data:{
		node:{__typename:"PullRequest",statusCheckRollup:{nodes:[{commit:{statusCheckRollup:{contexts:{nodes:$nodes,pageInfo:{hasNextPage:$has_next,endCursor:(if $end_cursor == "" then null else $end_cursor end)}}}}}]}},
		rateLimit:{cost:$cost}
	}}
'
exit 0
STUB
chmod +x "${TEST_ROOT}/bin/gh"

export CALL_LOG
export PATH="${TEST_ROOT}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
# shellcheck source=../shared-gh-wrappers-checks.sh
source "$LIB"

_gh_secondary_cooldown_expires_at() {
	printf '1893456000'
	return 0
}

_gh_secondary_cooldown_active() {
	[[ "${GH_TEST_MODE:-}" == *"cooldown"* ]] || return 1
	return 0
}

PASS_COUNT=0
FAIL_COUNT=0
CASE_RC=0
CASE_OUT=""
CASE_ERR=""

pass() {
	local description="$1"
	printf 'PASS: %s\n' "$description"
	PASS_COUNT=$((PASS_COUNT + 1))
	return 0
}

fail() {
	local description="$1"
	local detail="${2:-}"
	printf 'FAIL: %s%s\n' "$description" "${detail:+ — $detail}"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	return 0
}

assert_eq() {
	local description="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$description"
	else
		fail "$description" "expected ${expected}, got ${actual}"
	fi
	return 0
}

assert_contains() {
	local description="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == *"$expected"* ]]; then
		pass "$description"
	else
		fail "$description" "missing ${expected}"
	fi
	return 0
}

assert_json() {
	local description="$1"
	local filter="$2"
	local payload="$3"
	if printf '%s' "$payload" | jq -e "$filter" >/dev/null 2>&1; then
		pass "$description"
	else
		fail "$description" "payload did not satisfy ${filter}"
	fi
	return 0
}

run_case() {
	local fixture_mode="$1"
	local selection_mode="$2"
	local max_pages="${3:-20}"
	local out_file="${TEST_ROOT}/case.out"
	local err_file="${TEST_ROOT}/case.err"
	: >"$out_file"
	: >"$err_file"
	set +e
	GH_TEST_MODE="$fixture_mode" AIDEVOPS_GH_PR_CHECKS_MAX_PAGES="$max_pages" \
		gh_pr_checks_exact_json owner/repo 42 "$selection_mode" >"$out_file" 2>"$err_file"
	CASE_RC=$?
	set -e
	CASE_OUT=$(<"$out_file")
	CASE_ERR=$(<"$err_file")
	return 0
}

: >"$CALL_LOG"
run_case multipage required
assert_eq "terminal failures return one" "1" "$CASE_RC"
assert_json "multipage results deduplicate before required filtering" \
	'length == 3 and ([.[].name] | sort) == ["build","deploy","legacy"]' "$CASE_OUT"
assert_json "newest duplicate and bucket mapping match gh CLI" \
	'first(.[] | select(.name == "build")) | .state == "FAILURE" and .bucket == "fail" and .link == "https://example.invalid/new" and .workflow == "CI" and .event == "push"' "$CASE_OUT"
assert_json "status contexts and skipped checks retain projected fields" \
	'(first(.[] | select(.name == "legacy")) | .state == "SUCCESS" and .bucket == "pass" and .description == "new status") and (first(.[] | select(.name == "deploy")) | .bucket == "skipping")' "$CASE_OUT"
assert_eq "identity REST read is fixed-cost attributed" "1" \
	"$(grep -c '^rest|1|gh-pr-checks-identity-rest|' "$CALL_LOG" || true)"
assert_eq "every GraphQL page uses response-owned cost attribution" "2" \
	"$(grep -c '^graphql|1|gh-pr-checks-status-rollup-exact-cost|' "$CALL_LOG" || true)"
assert_contains "GraphQL query requests operation-owned cost" "rateLimit { cost }" "$(<"$CALL_LOG")"
assert_contains "second page uses the returned cursor" "endCursor=CURSOR1" "$(<"$CALL_LOG")"

run_case multipage all
assert_json "all mode retains optional checks and only the newest duplicate" \
	'length == 5 and any(.[]; .name == "optional") and ([.[] | select(.name == "shadowed")] | length) == 1' "$CASE_OUT"

run_case pending required
assert_eq "pending checks return eight" "8" "$CASE_RC"
assert_json "in-progress CheckRun maps to pending" 'length == 1 and .[0].state == "IN_PROGRESS" and .[0].bucket == "pending"' "$CASE_OUT"

run_case cancel required
assert_eq "cancel-only output preserves native zero exit" "0" "$CASE_RC"
assert_json "cancelled CheckRun maps to cancel" 'length == 1 and .[0].state == "CANCELLED" and .[0].bucket == "cancel"' "$CASE_OUT"

run_case no-required required
assert_eq "no required checks returns one" "1" "$CASE_RC"
assert_eq "no required checks emits no JSON" "" "$CASE_OUT"
assert_eq "no required diagnostic matches native CLI" "no required checks reported on the 'feature/test' branch" "$CASE_ERR"

run_case empty all
assert_eq "no checks returns one" "1" "$CASE_RC"
assert_eq "no checks never becomes empty-array success" "" "$CASE_OUT"
assert_eq "no checks diagnostic names the immutable identity branch" "no checks reported on the 'feature/test' branch" "$CASE_ERR"

for failure_mode in identity-error identity-malformed missing-cost zero-cost graphql-error missing-rollup repeated-cursor; do
	run_case "$failure_mode" required
	assert_eq "${failure_mode} fails indeterminate" "2" "$CASE_RC"
	assert_eq "${failure_mode} emits no JSON" "" "$CASE_OUT"
done

run_case identity-cooldown required
assert_eq "cooldown identity read keeps the exact-check public exit contract" "2" "$CASE_RC"
assert_contains "cooldown identity read preserves a stable classification" \
	"error_kind=github-api-cooldown expires_at=1893456000 operation=pull-request-identity-read" "$CASE_ERR"

run_case graphql-cooldown required
assert_eq "cooldown status-rollup read keeps the exact-check public exit contract" "2" "$CASE_RC"
assert_contains "cooldown status-rollup read preserves a stable classification" \
	"error_kind=github-api-cooldown expires_at=1893456000 operation=status-rollup-page-1-read" "$CASE_ERR"

run_case identity-read-deferred required
assert_eq "non-cooldown read deferral keeps the exact-check public exit contract" "2" "$CASE_RC"
assert_contains "non-cooldown read deferral is not mislabeled as a cooldown" \
	"error_kind=github-api-read-deferred operation=pull-request-identity-read" "$CASE_ERR"

run_case multipage required 1
assert_eq "page bound fails closed" "2" "$CASE_RC"
assert_contains "page bound is diagnosed" "pagination exceeded 1 pages" "$CASE_ERR"

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
if [[ "$FAIL_COUNT" -ne 0 ]]; then
	exit 1
fi
exit 0
