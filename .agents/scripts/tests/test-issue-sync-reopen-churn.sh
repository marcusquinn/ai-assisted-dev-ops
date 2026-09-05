#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for the TODO reopen guard notification-churn fixes.
set -euo pipefail

PASS=0
FAIL=0

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cat >"$TMPDIR/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/200" ]]; then
	printf '{"number":200,"pull_request":{}}\n'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/201" ]]; then
	printf '{"number":201,"title":"plain issue"}\n'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/208" ]]; then
	printf '{"number":208,"title":"declined issue","state":"closed","state_reason":"NOT_PLANNED","closed_at":"2026-08-20T14:15:16Z"}\n'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/209" ]]; then
	printf '{"number":209,"title":"declined issue without closure time","state":"closed","state_reason":"NOT_PLANNED"}\n'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/212" ]]; then
	printf '{"number":212,"title":"completed issue with unavailable comments","state":"closed","state_reason":"COMPLETED","closed_at":"2026-08-22T14:15:16Z"}\n'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/202/comments" ]]; then
	printf '[{"body":"Reopened: TODO.md still has this as `[ ]` (open) and no merged PR was found."}]\n'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/203/comments" ]]; then
	printf '[{"body":"Unrelated comment"}]\n'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/204/comments" ]]; then
	printf '{"message":"server error"}\n'
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
	[[ "${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" == "1" && "$*" == *"rateLimit"* ]] || exit 1
	case "$*" in
	*"number=205"*)
		printf '%s\n' '{"data":{"repository":{"nameWithOwner":"owner/repo","issue":{"closedByPullRequestsReferences":{"nodes":[{"number":27347,"url":"https://github.com/owner/repo/pull/27347","state":"MERGED","mergedAt":"2026-07-12T14:55:46Z","repository":{"nameWithOwner":"owner/repo"}}],"pageInfo":{"hasNextPage":false}}}},"rateLimit":{"cost":1}}}'
		exit 0
		;;
	*"number=206"*)
		printf '%s\n' '{"data":{"repository":{"nameWithOwner":"owner/repo","issue":{"closedByPullRequestsReferences":{"nodes":[],"pageInfo":{"hasNextPage":true}}}},"rateLimit":{"cost":1}}}'
		exit 0
		;;
	*"number=207"*)
		printf '%s\n' '{"data":{"repository":{"nameWithOwner":"owner/repo","issue":{"closedByPullRequestsReferences":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}}'
		exit 0
		;;
	*"number=212"*)
		printf '%s\n' '{"data":{"repository":{"nameWithOwner":"owner/repo","issue":{"closedByPullRequestsReferences":{"nodes":[],"pageInfo":{"hasNextPage":false}}}},"rateLimit":{"cost":1}}}'
		exit 0
		;;
	esac
fi
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
STUB
chmod +x "$TMPDIR/gh"

cat >"$TMPDIR/gh-signature-helper.sh" <<'STUB'
#!/usr/bin/env bash
printf '\n<!-- aidevops:sig -->\n---\n[mock-sig]\n'
exit 0
STUB
chmod +x "$TMPDIR/gh-signature-helper.sh"
export PATH="$TMPDIR:$PATH"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_PATH="${TEST_DIR}/../issue-sync-helper-close.sh"

log_verbose() { return 0; }

# shellcheck source=../issue-sync-lib.sh
source "${TEST_DIR}/../issue-sync-lib.sh"
# shellcheck source=../issue-sync-helper-close.sh
source "$HELPER_PATH"

check_success() {
	local label="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		PASS=$((PASS + 1))
		printf 'PASS: %s\n' "$label"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s\n' "$label"
	fi
	return 0
}

check_failure() {
	local label="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s\n' "$label"
	else
		PASS=$((PASS + 1))
		printf 'PASS: %s\n' "$label"
	fi
	return 0
}

check_output() {
	local label="$1"
	local expected="$2"
	shift 2
	local actual=""
	actual=$("$@" 2>/dev/null || true)
	if [[ "$actual" == "$expected" ]]; then
		PASS=$((PASS + 1))
		printf 'PASS: %s\n' "$label"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s (expected %s, got %s)\n' "$label" "$expected" "$actual"
	fi
	return 0
}

check_success "PR refs are identified before reopen" _reopen_ref_is_pull_request "owner/repo" "200"
check_failure "plain issue refs are not treated as PRs" _reopen_ref_is_pull_request "owner/repo" "201"
check_success "prefetched PR refs skip redundant API calls" _reopen_ref_is_pull_request "owner/repo" "999" '{"number":999,"pull_request":{}}'
check_failure "unexpected issue payloads are not treated as PRs" _reopen_ref_is_pull_request "owner/repo" "999" '{"message":"server error"}'
check_success "prior canonical reopen comments are detected" _has_prior_reopen_comment "owner/repo" "202"
check_failure "unrelated comments do not suppress reopen" _has_prior_reopen_comment "owner/repo" "203"
check_failure "unexpected comments payloads do not suppress reopen" _has_prior_reopen_comment "owner/repo" "204"
check_success "GraphQL NOT_PLANNED reason is skipped" _is_not_planned_state_reason "NOT_PLANNED"
check_success "REST not_planned reason is skipped" _is_not_planned_state_reason "not_planned"
check_success "hyphenated not-planned reason is skipped" _is_not_planned_state_reason "not-planned"
check_failure "completed reason is not treated as not planned" _is_not_planned_state_reason "COMPLETED"
check_failure "missing close reason is not treated as not planned" _is_not_planned_state_reason

todo_file="$TMPDIR/TODO.md"
cat >"$todo_file" <<'EOF'
# TODO

```markdown
- [ ] t208 example row ref:GH#208
```

- [ ] t208 live declined row ref:GH#208 logged:2026-08-01
- [>] t210 claimed declined row ref:GH#210 logged:2026-08-02
- [x] t211 completed row ref:GH#211 completed:2026-08-03
- [ ] t209 incomplete closure evidence ref:GH#209 logged:2026-08-04
- [ ] t212 completed issue with unavailable evidence ref:GH#212 logged:2026-08-05
EOF

export DRY_RUN=false
reopen_rc=0
if _reopen_incomplete_task_line "owner/repo" "$todo_file" "" \
	'- [ ] t208 live declined row ref:GH#208 logged:2026-08-01'; then
	reopen_rc=0
else
	reopen_rc=$?
fi
check_output "NOT_PLANNED reconciliation reports the terminal skip class" "12" printf '%s' "$reopen_rc"
check_success "NOT_PLANNED reconciliation marks only the live row declined" \
	grep -Fqx -- '- [-] t208 live declined row ref:GH#208 logged:2026-08-01 declined:2026-08-20' "$todo_file"
check_success "NOT_PLANNED reconciliation preserves the code-fenced example" \
	grep -Fqx -- '- [ ] t208 example row ref:GH#208' "$todo_file"

check_success "claimed TODO rows converge to the same declined state" \
	_mark_todo_not_planned "t210" "210" "$todo_file" "2026-08-21"
before_repeat=$(grep -F -- 't210 claimed declined row' "$todo_file")
check_success "repeated declined-row reconciliation is idempotent" \
	_mark_todo_not_planned "t210" "210" "$todo_file" "2026-08-21"
after_repeat=$(grep -F -- 't210 claimed declined row' "$todo_file")
check_output "repeated reconciliation remains byte-stable" "$before_repeat" printf '%s' "$after_repeat"
check_failure "completed TODO rows are never rewritten as declined" \
	_mark_todo_not_planned "t211" "211" "$todo_file" "2026-08-21"

missing_time_rc=0
if _reopen_incomplete_task_line "owner/repo" "$todo_file" "" \
	'- [ ] t209 incomplete closure evidence ref:GH#209 logged:2026-08-04'; then
	missing_time_rc=0
else
	missing_time_rc=$?
fi
check_output "NOT_PLANNED without deterministic closure evidence fails closed" "11" printf '%s' "$missing_time_rc"
check_success "failed closure evidence leaves the live row unchanged" \
	grep -Fqx -- '- [ ] t209 incomplete closure evidence ref:GH#209 logged:2026-08-04' "$todo_file"

_gh_find_merged_pr_evidence() {
	local repo="$1"
	local task_id="$2"
	[[ "$repo" == "owner/repo" ]] || return 1
	[[ "$task_id" == "t-title-unavailable" ]] && return 2
	[[ "$task_id" == "t-title-match" ]] || return 1
	printf '%s\n' '42|https://github.com/owner/repo/pull/42'
	return 0
}

check_output "task-title merged PR remains the first reopen proof" \
	"42|https://github.com/owner/repo/pull/42" \
	_reopen_find_merged_pr "owner/repo" "t-title-match" "999"
check_output "structural closing PR prevents false reopen when title omits task ID" \
	"27347|https://github.com/owner/repo/pull/27347" \
	_reopen_find_merged_pr "owner/repo" "t18109" "205"
check_output "structural closing PR remains positive evidence after title lookup failure" \
	"27347|https://github.com/owner/repo/pull/27347" \
	_reopen_find_merged_pr "owner/repo" "t-title-unavailable" "205"
check_failure "truncated structural closing relationships fail closed" _reopen_find_merged_pr "owner/repo" "t18109" "206"
check_failure "unmetered structural closing relationships fail closed" _reopen_find_merged_pr "owner/repo" "t18109" "207"
check_failure "invalid issue coordinates fail closed" _reopen_find_merged_pr "owner/repo" "t18109" "not-a-number"

unavailable_evidence_rc=0
if _reopen_incomplete_task_line "owner/repo" "$todo_file" "" \
	'- [ ] t212 completed issue with unavailable evidence ref:GH#212 logged:2026-08-05'; then
	unavailable_evidence_rc=0
else
	unavailable_evidence_rc=$?
fi
check_output "unavailable completion lookup never reopens a completed issue" "11" printf '%s' "$unavailable_evidence_rc"
check_success "unavailable completion lookup leaves stale TODO state unchanged" \
	grep -Fqx -- '- [ ] t212 completed issue with unavailable evidence ref:GH#212 logged:2026-08-05' "$todo_file"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
