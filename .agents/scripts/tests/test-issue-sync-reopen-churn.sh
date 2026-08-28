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
if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/301" ]]; then
	printf '{"number":301,"state":"closed","state_reason":"not_planned"}\n'
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

NOT_PLANNED_TODO="$TMPDIR/not-planned-todo.md"
DRY_RUN="false"
cat >"$NOT_PLANNED_TODO" <<'TODO'
```markdown
- [ ] t303 fenced example ref:GH#303
```
- [ ] t301 first live task ref:GH#301
- [>] t302 active live task ref:GH#302
TODO

_todo_task_line_num() {
	local task_id="$1"
	local todo_file="$2"
	awk -v wanted="$task_id" '
		/^[[:space:]]*```/ { in_fence = !in_fence; next }
		!in_fence && $0 ~ /^[[:space:]]*- \[[ >-]\] / {
			remaining = $0
			sub(/^[[:space:]]*- \[[ >-]\] /, "", remaining)
			split(remaining, fields, /[[:space:]]+/)
			if (fields[1] == wanted) { print NR; exit }
		}
	' "$todo_file"
	return 0
}

sed_inplace() {
	local expression="$1"
	local todo_file="$2"
	sed -i.bak -E "$expression" "$todo_file" || return 1
	rm -f "${todo_file}.bak"
	return 0
}

log_verbose() {
	return 0
}

reopen_status=0
_reopen_incomplete_task_line "owner/repo" "$NOT_PLANNED_TODO" "" \
	"- [ ] t301 first live task ref:GH#301" || reopen_status=$?
if [[ "$reopen_status" -eq 12 ]]; then
	PASS=$((PASS + 1))
	printf 'PASS: not-planned issue terminalizes unchecked task through reopen lifecycle\n'
else
	FAIL=$((FAIL + 1))
	printf 'FAIL: not-planned issue terminalizes unchecked task through reopen lifecycle\n'
fi
check_success "not-planned rows terminalize active tasks" \
	_mark_reopen_not_planned_task "t302" "$NOT_PLANNED_TODO" "302"
check_success "not-planned terminalization is idempotent" \
	_mark_reopen_not_planned_task "t301" "$NOT_PLANNED_TODO" "301"
if grep -qE '^\- \[-\] t301 first live task ref:GH#301 declined:[0-9]{4}-[0-9]{2}-[0-9]{2}$' "$NOT_PLANNED_TODO" &&
	grep -qE '^\- \[-\] t302 active live task ref:GH#302 declined:[0-9]{4}-[0-9]{2}-[0-9]{2}$' "$NOT_PLANNED_TODO" &&
	grep -q '^\- \[ \] t303 fenced example ref:GH#303$' "$NOT_PLANNED_TODO" &&
	[[ "$(grep -Ec '^\- \[-\] t301 .*declined:' "$NOT_PLANNED_TODO")" -eq 1 ]]; then
	PASS=$((PASS + 1))
	printf 'PASS: not-planned terminalization preserves refs, skips fenced examples, and adds one proof\n'
else
	FAIL=$((FAIL + 1))
	printf 'FAIL: not-planned terminalization preserves refs, skips fenced examples, and adds one proof\n'
fi

gh_find_merged_pr() {
	local repo="$1"
	local task_id="$2"
	[[ "$repo" == "owner/repo" && "$task_id" == "t-title-match" ]] || return 1
	printf '%s\n' '42|https://github.com/owner/repo/pull/42'
	return 0
}

check_output "task-title merged PR remains the first reopen proof" \
	"42|https://github.com/owner/repo/pull/42" \
	_reopen_find_merged_pr "owner/repo" "t-title-match" "999"
check_output "structural closing PR prevents false reopen when title omits task ID" \
	"27347|https://github.com/owner/repo/pull/27347" \
	_reopen_find_merged_pr "owner/repo" "t18109" "205"
check_failure "truncated structural closing relationships fail closed" _reopen_find_merged_pr "owner/repo" "t18109" "206"
check_failure "unmetered structural closing relationships fail closed" _reopen_find_merged_pr "owner/repo" "t18109" "207"
check_failure "invalid issue coordinates fail closed" _reopen_find_merged_pr "owner/repo" "t18109" "not-a-number"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
