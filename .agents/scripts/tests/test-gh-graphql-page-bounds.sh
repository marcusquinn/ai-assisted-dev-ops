#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
SHIM_SOURCE="${REPO_ROOT}/.agents/scripts/gh"
HELPER="${REPO_ROOT}/.agents/scripts/github-graphql-page-helper.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gh-graphql-bounds.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() {
	local name="$1"
	printf 'PASS %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	printf 'FAIL %s: %s\n' "$name" "$detail" >&2
	FAIL=$((FAIL + 1))
	return 0
}

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/shim"
cp "$SHIM_SOURCE" "$TMP_ROOT/shim/gh"
cp "${REPO_ROOT}/.agents/scripts/gh-native-transport-lib.sh" "$TMP_ROOT/shim/gh-native-transport-lib.sh"
cp "${REPO_ROOT}/.agents/scripts/gh-api-guards-lib.sh" "$TMP_ROOT/shim/gh-api-guards-lib.sh"
cp "${REPO_ROOT}/.agents/scripts/gh-write-policy-lib.sh" "$TMP_ROOT/shim/gh-write-policy-lib.sh"
chmod +x "$TMP_ROOT/shim/gh"
export GH_CALL_LOG="$TMP_ROOT/gh-calls.log"
export PATH="$TMP_ROOT/bin:$PATH"
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"

cat >"$TMP_ROOT/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$GH_CALL_LOG"

input_file=""
while [[ $# -gt 0 ]]; do
	arg="$1"
	if [[ "$arg" == "--input" && $# -gt 1 ]]; then
		input_file="$2"
		break
	fi
	shift
done

if [[ -z "$input_file" ]]; then
	printf '{}\n'
	exit 0
fi

page_size=$(jq -r '.variables.pageSize' "$input_file")
cursor=$(jq -r '.variables.cursor // ""' "$input_file")
printf 'page_size=%s cursor=%s\n' "$page_size" "$cursor" >>"$GH_CALL_LOG"
if [[ "${MOCK_API_FAIL:-0}" == "1" ]]; then
	printf 'mock transport failure\n' >&2
	printf '{"errors":[{"message":"mock failure"}]}\n'
	exit 1
fi

if [[ -z "$cursor" ]]; then start=1; else start=$((cursor + 1)); fi
available=$((151 - start))
count="$page_size"
if [[ "$available" -lt "$count" ]]; then count="$available"; fi
end=$((start + count - 1))
if [[ "$end" -lt 150 ]]; then has_next=true; else has_next=false; fi
jq -n --argjson start "$start" --argjson count "$count" --argjson has_next "$has_next" --arg cursor "$end" \
	'{data:{repository:{issues:{nodes:[range($start; $start + $count) | {id:("node-" + tostring)}],pageInfo:{hasNextPage:$has_next,endCursor:$cursor}}}}}'
exit 0
MOCK
chmod +x "$TMP_ROOT/bin/gh"

SHIM="$TMP_ROOT/shim/gh"

assert_oversized_blocked() {
	local name="$1"
	local flag="$2"
	local field="$3"
	: >"$GH_CALL_LOG"
	if "$SHIM" api graphql "$flag" "$field" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
		fail "$name" "oversized query unexpectedly succeeded"
		return 0
	fi
	if [[ -s "$GH_CALL_LOG" ]]; then
		fail "$name" "real gh mock was invoked"
		return 0
	fi
	if ! grep -q 'GRAPHQL_PAGE_BOUND_EXCEEDED requested=120 maximum=100' "$TMP_ROOT/err"; then
		fail "$name" "stable diagnostic missing"
		return 0
	fi
	pass "$name"
	return 0
}

assert_oversized_blocked "short raw field blocks first:120" -f 'query=query { repository { issues(first: 120) { nodes { id } } } }'
assert_oversized_blocked "typed field blocks last:120" -F 'query=query { repository { issues(last:120) { nodes { id } } } }'
assert_oversized_blocked "long raw field blocks first:120" --raw-field 'query=query { repository { issues(first: 120) { nodes { id } } } }'

: >"$GH_CALL_LOG"
if "$SHIM" api graphql --field='query=query { repository { issues(first: 100) { nodes { id } } } }' >/dev/null 2>"$TMP_ROOT/err" \
	&& [[ -s "$GH_CALL_LOG" ]]; then
	pass "literal values through 100 pass unchanged"
else
	fail "literal values through 100 pass unchanged" "bounded query did not reach real gh"
fi

: >"$GH_CALL_LOG"
# GraphQL variable syntax must remain literal.
# shellcheck disable=SC2016
if "$SHIM" api graphql -f 'query=query($pageSize: Int!) { repository { issues(first: $pageSize) { nodes { id } } } }' >/dev/null 2>"$TMP_ROOT/err" \
	&& [[ -s "$GH_CALL_LOG" ]] \
	&& grep -q 'GRAPHQL_PAGE_BOUND_UNVERIFIED' "$TMP_ROOT/err"; then
	pass "dynamic page variable fails open with warning"
else
	fail "dynamic page variable fails open with warning" "query was blocked or warning was absent"
fi

cat >"$TMP_ROOT/query.graphql" <<'QUERY'
query($pageSize: Int!, $cursor: String) {
  repository(owner: "owner", name: "repo") {
    issues(first: $pageSize, after: $cursor) {
      nodes { id }
      pageInfo { hasNextPage endCursor }
    }
  }
}
QUERY

: >"$GH_CALL_LOG"
if result=$("$HELPER" --query-file "$TMP_ROOT/query.graphql" --connection-jq '.data.repository.issues' --total 150 --max-pages 3 --page-size 120 --max-retries 2) \
	&& [[ $(jq -r '.pageInfo.complete' <<<"$result") == "true" ]] \
	&& [[ $(jq -r '.pageInfo.itemCount' <<<"$result") == "150" ]] \
	&& [[ $(jq -r '.pageInfo.pages' <<<"$result") == "2" ]] \
	&& ! grep -Eq 'page_size=(10[1-9]|1[1-9][0-9]|[2-9][0-9]{2,})' "$GH_CALL_LOG"; then
	pass "helper retrieves multiple bounded pages"
else
	fail "helper retrieves multiple bounded pages" "result was incomplete or a request exceeded 100"
fi

: >"$GH_CALL_LOG"
set +e
result=$("$HELPER" --query-file "$TMP_ROOT/query.graphql" --connection-jq '.data.repository.issues' --total 150 --max-pages 1 --page-size 100 2>"$TMP_ROOT/err")
rc=$?
set -e
if [[ "$rc" -ne 0 ]] \
	&& [[ $(jq -r '.pageInfo.complete' <<<"$result") == "false" ]] \
	&& [[ $(jq -r '.pageInfo.reason' <<<"$result") == "page_budget_exhausted" ]] \
	&& [[ $(jq -r '.pageInfo.itemCount' <<<"$result") == "100" ]]; then
	pass "page budget returns explicitly incomplete partial data"
else
	fail "page budget returns explicitly incomplete partial data" "partial-result contract was not preserved"
fi

: >"$GH_CALL_LOG"
set +e
result=$(MOCK_API_FAIL=1 "$HELPER" --query-file "$TMP_ROOT/query.graphql" --connection-jq '.data.repository.issues' --total 150 --max-pages 3 --max-retries 2 2>"$TMP_ROOT/err")
rc=$?
set -e
attempts=$(grep -c '^api graphql --input ' "$GH_CALL_LOG" || true)
if [[ "$rc" -ne 0 ]] \
	&& [[ "$attempts" -eq 3 ]] \
	&& [[ $(jq -r '.pageInfo.complete' <<<"$result") == "false" ]] \
	&& [[ $(jq -r '.pageInfo.reason' <<<"$result") == "api_error" ]] \
	&& grep -q '^mock transport failure$' "$TMP_ROOT/err" \
	&& grep -q '^\[{"message":"mock failure"}\]$' "$TMP_ROOT/err"; then
	pass "API retries expose final failure diagnostics"
else
	fail "API retries expose final failure diagnostics" "expected 3 attempts, incomplete api_error result, and final stderr/error details"
fi

# Guard the reviewed merge/dispatch/approval inventory. These files have no
# intentional executable bare-GraphQL exceptions: documentation mentions are
# allowed, while command-shaped occurrences must name a bounded module adapter.
guarded_graphql_sources=(
	"${REPO_ROOT}/.agents/scripts/pr-review-thread-response-scanner.sh"
	"${REPO_ROOT}/.agents/scripts/pulse-merge-gates.sh"
	"${REPO_ROOT}/.agents/scripts/pulse-merge-feedback.sh"
	"${REPO_ROOT}/.agents/scripts/dispatch-dedup-pr.sh"
	"${REPO_ROOT}/.agents/scripts/dispatch-single-issue-helper.sh"
	"${REPO_ROOT}/.agents/scripts/pulse-wrapper-bootstrap.sh"
	"${REPO_ROOT}/.agents/scripts/pr-supersession-helper.sh"
	"${REPO_ROOT}/.agents/scripts/pre-dispatch-validator-helper.sh"
	"${REPO_ROOT}/.agents/scripts/trusted-dependabot-lib.sh"
	"${REPO_ROOT}/.agents/scripts/full-loop-helper-merge.sh"
	"${REPO_ROOT}/.agents/scripts/post-merge-review-scanner.sh"
	"${REPO_ROOT}/.agents/scripts/pulse-nmr-approval.sh"
)
guard_failed=0
for guarded_source in "${guarded_graphql_sources[@]}"; do
	while IFS= read -r graphql_line; do
		if [[ ! "$graphql_line" =~ _[a-z0-9_]+_gh_(read|call)([[:space:]]+(read|write))?[[:space:]]+gh[[:space:]]+api[[:space:]]+graphql ]]; then
			fail "hot-path GraphQL calls use bounded adapters" "${guarded_source}: ${graphql_line}"
			guard_failed=1
		fi
	done < <(grep -E 'gh api graphql([[:space:]]+\\|[[:space:]]+-)' "$guarded_source" || true)
done
if [[ "$guard_failed" -eq 0 ]]; then
	pass "hot-path GraphQL calls use bounded adapters"
fi

printf '\nRan %s tests, %s failed.\n' "$((PASS + FAIL))" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
