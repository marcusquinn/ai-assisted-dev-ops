#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-backfill-sub-issues.sh — tests for t2114 (GH#19093)
#
# The `backfill-sub-issues` subcommand in issue-sync-helper.sh links a child
# issue to its parent using GitHub state alone (title + body), without
# consulting TODO.md or brief files. Three detection mechanisms cover the
# common cases observed in the wild:
#
#   1. Dot-notation in title — "t1873.2: foo" → parent t1873 (resolved via
#      `gh search issues` against the same repo).
#   2. Explicit `Parent:` line in body — `Parent: tNNN` / `Parent: GH#NNN` /
#      `Parent: #NNN`, including bold-markdown and backtick-quoted variants.
#   3. `Blocked by: tNNN` where the referenced task carries the `parent-task`
#      label on GitHub. This is the only case that requires the label check —
#      it prevents peer-dependency blockers from being misread as parents.
#
# Test coverage:
#   Class A — _detect_parent_from_gh_state
#     1. Dot-notation title resolves to parent issue number
#     2. `Parent: #NNN` returns the raw number directly
#     3. `Parent: GH#NNN` returns the raw number
#     4. `**Parent:** `tNNN`` (bold-markdown) resolves via gh search
#     5. `Blocked by: tNNN` with parent-task label returns the parent
#     6. `Blocked by: tNNN` WITHOUT parent-task label returns empty
#     7. No detection signals returns empty
#     8. Comma-separated `Blocked by:` — first parent-tagged blocker wins
#
#   Class B — cmd_backfill_sub_issues
#     9. --issue N --dry-run prints "Would link" and does NOT call addSubIssue
#    10. --issue N (no dry-run) calls addSubIssue mutation
#    11. --issue N with no parent signal produces "Linked: 0"
#
# Strategy:
#   - Install a stubbed `gh` binary on PATH. The stub inspects its arguments
#     and returns canned JSON for `gh issue view`, `gh issue list`, and
#     `gh search issues`. GraphQL mutations are recorded to a log and return
#     a success payload. Label lookups consult an env-var allowlist.
#   - Source issue-sync-helper.sh AFTER the stub is on PATH (the helper's
#     internal PATH-reset at top-of-file is worked around by setting PATH
#     both before and after the source).

set -u

# Use TEST_-prefixed color vars to avoid colliding with the readonly vars
# defined by shared-constants.sh when the helper is sourced later.
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
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/issue-sync-helper.sh"

if [[ ! -f "$HELPER" ]]; then
	printf 'test harness cannot find helper at %s\n' "$HELPER" >&2
	exit 1
fi

TMP=$(mktemp -d -t t2114-backfill.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------------
# Stubbed gh binary
# -----------------------------------------------------------------------------
# The stub reads its argument pattern and emits canned JSON:
#   gh issue view <N> ...    → uses GH_ISSUE_<N>_JSON env
#   gh issue list ...        → uses GH_ISSUE_LIST_JSON env
#   gh search issues <q> ... → uses GH_SEARCH_<q>_JSON env
#   gh api graphql -f query=...addSubIssue...  → logged, success payload
# Any --jq filter is honoured if jq is available.

GH_LOG="${TMP}/gh.log"
export GH_LOG
: >"$GH_LOG"

mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"

cmd1="${1:-}"
cmd2="${2:-}"

_emit() {
	local payload="$1"
	local jq_filter=""
	local prev=""
	for arg in "$@"; do
		if [[ "$prev" == "--jq" ]]; then
			jq_filter="$arg"
		fi
		prev="$arg"
	done
	if [[ -n "$jq_filter" ]] && command -v jq >/dev/null 2>&1; then
		printf '%s\n' "$payload" | jq -r "$jq_filter"
	else
		printf '%s\n' "$payload"
	fi
}

# gh issue view <N> ...
if [[ "$cmd1" == "issue" && "$cmd2" == "view" ]]; then
	num="${3:-}"
	var="GH_ISSUE_${num}_JSON"
	# Avoid ${!var:-{...}} — bash indirect expansion has a brace-matching
	# bug that appends an extra } when the variable IS set and the default
	# contains { (GH#19942 test discovery).
	payload="${!var}"
	if [[ -z "$payload" ]]; then
		payload='{"title":"","body":"","labels":[]}'
	fi
	_emit "$payload" "$@"
	exit 0
fi

# gh issue list ...
if [[ "$cmd1" == "issue" && "$cmd2" == "list" ]]; then
	payload="${GH_ISSUE_LIST_JSON:-[]}"
	_emit "$payload" "$@"
	exit 0
fi

# gh search issues <q> ...
# Env var lookup: dots in task IDs become underscores because bash
# identifiers cannot contain `.` — attempting indirect expansion with
# `${!var}` on a dotted name aborts the shell with "invalid variable name".
# So: always normalise dots to underscores before the lookup. Callers
# expose fixtures as e.g. `GH_SEARCH_t1873_2_JSON` for task ID `t1873.2`.
if [[ "$cmd1" == "search" && "$cmd2" == "issues" ]]; then
	q="${3:-}"
	q_safe="${q//./_}"
	var="GH_SEARCH_${q_safe}_JSON"
	payload="${!var:-[]}"
	_emit "$payload" "$@"
	exit 0
fi

# gh api graphql -f query=...
if [[ "$cmd1" == "api" && "$cmd2" == "graphql" ]]; then
	# Check the mutation name in the query body
	if [[ "$*" == *"addSubIssue"* ]]; then
		[[ "${AIDEVOPS_GH_QUOTA_COST:-}" == "1" && "$*" != *"rateLimit"* ]] || exit 1
	else
		[[ "${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" == "1" && "$*" == *"rateLimit"* ]] || exit 1
	fi
	for arg in "$@"; do
		if [[ "$arg" == *"addSubIssue"* ]]; then
			printf '%s\n' '{"data":{"addSubIssue":{"issue":{"number":1}}}}'
			exit 0
		fi
		if [[ "$arg" == *"subIssues(first:100)"* ]]; then
			printf '%s\n' '{"data":{"node":{"subIssues":{"nodes":[],"pageInfo":{"hasNextPage":false}}},"rateLimit":{"cost":1}}}'
			exit 0
		fi
		if [[ "$arg" == *"issue(number"* ]]; then
			# resolve_gh_node_id query — fail when _GH_GRAPHQL_NODE_FAIL=1 is set
			if [[ "${_GH_GRAPHQL_NODE_FAIL:-0}" == "1" ]]; then
				printf '%s\n' '{"data":{"repository":{"issue":null},"rateLimit":{"cost":1}}}'
				exit 0
			fi
			printf '%s\n' '{"data":{"repository":{"issue":{"id":"NODE_STUB_ID"}},"rateLimit":{"cost":1}}}'
			exit 0
		fi
	done
	printf '%s\n' '{}'
	exit 0
fi

# gh api rate_limit → used by _rest_should_fallback
if [[ "$cmd1" == "api" && "$cmd2" == "rate_limit" ]]; then
	printf '%s\n' '{"resources":{"graphql":{"remaining":5000}}}'
	exit 0
fi

# gh api /repos/.../issues/NNN → REST node_id fallback (t2739)
# Returns {"node_id":"..."} when GH_REST_NODE_<num> env var is set.
if [[ "$cmd1" == "api" && "$cmd2" =~ ^/repos/ ]]; then
	num=$(basename "$cmd2")
	var="GH_REST_NODE_${num}"
	payload="${!var:-}"
	if [[ -n "$payload" ]]; then
		_emit "$payload" "$@"
		exit 0
	fi
	# No fixture: return empty body (REST also failed)
	printf '\n'
	exit 0
fi

# gh auth status
if [[ "$cmd1" == "auth" && "$cmd2" == "status" ]]; then
	exit 0
fi

# Default: success, no output
exit 0
STUB
chmod +x "${TMP}/bin/gh"

# Put the stub first on PATH. Source the helper (which resets PATH internally),
# then prepend again.
export PATH="${TMP}/bin:${PATH}"

# Stubs for functions called by _init_cmd — we short-circuit _init_cmd itself
# for Class B by overriding it after sourcing, so these are just defence.
print_warning() { :; }
print_info() { printf '%s\n' "$*"; }
print_error() { printf 'ERROR: %s\n' "$*" >&2; }
print_success() { :; }

# Minimal fake project root so _init_cmd's call to find_project_root works if
# we ever let it run. For Class B we override _init_cmd directly.
FAKE_PROJECT_ROOT="${TMP}/fake-project"
mkdir -p "$FAKE_PROJECT_ROOT"
: >"${FAKE_PROJECT_ROOT}/TODO.md"

# shellcheck source=../issue-sync-helper.sh
source "$HELPER" >/dev/null 2>&1 || true
export PATH="${TMP}/bin:${PATH}"

# Override _init_cmd for Class B so it doesn't require a real git repo.
_init_cmd() {
	_CMD_ROOT="$FAKE_PROJECT_ROOT"
	_CMD_REPO="owner/repo"
	_CMD_TODO="${FAKE_PROJECT_ROOT}/TODO.md"
	return 0
}

# Pre-initialize node ID cache and rate-limited flag file to prevent EXIT trap
# chaining. _init_node_id_cache's trap chains the parent's EXIT trap into
# subshells; on bash 5.x, subshells inherit EXIT traps, so when $(cmd | tail -1)
# exits, the chained trap fires and deletes $TMP prematurely. Pre-initializing
# skips the trap setup entirely (both guards check -z before creating files).
_NODE_ID_CACHE_FILE="${TMP}/node_cache"
: >"$_NODE_ID_CACHE_FILE"
_NODE_ID_RATE_LIMITED_FILE="${TMP}/rate_limited_flag"
: >"$_NODE_ID_RATE_LIMITED_FILE"

printf '%sRunning backfill-sub-issues tests (t2114)%s\n' "$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Class A: _detect_parent_from_gh_state
# =============================================================================

# Parent t1873 lives at issue #100. t1873.2 lives at #200.
export GH_SEARCH_t1873_JSON='[{"number":100,"title":"t1873: parent task"},{"number":200,"title":"t1873.2: child task"}]'
# t1874 parent lives at #101 and carries the parent-task label.
export GH_SEARCH_t1874_JSON='[{"number":101,"title":"t1874: parent with label"}]'
# t1875 is a peer dependency (no parent-task label).
export GH_SEARCH_t1875_JSON='[{"number":102,"title":"t1875: peer dependency"}]'
# t1876 parent carrying parent-task label, used for multi-blocker test.
export GH_SEARCH_t1876_JSON='[{"number":103,"title":"t1876: parent multi"}]'

# Canned views for label lookups
export GH_ISSUE_101_JSON='{"title":"t1874: parent with label","body":"","labels":[{"name":"parent-task"},{"name":"enhancement"}]}'
export GH_ISSUE_102_JSON='{"title":"t1875: peer dependency","body":"","labels":[{"name":"bug"}]}'
export GH_ISSUE_103_JSON='{"title":"t1876: parent multi","body":"","labels":[{"name":"parent-task"}]}'

# ---- Test 1: dot-notation in title resolves via gh search ----
result=$(_detect_parent_from_gh_state "t1873.2: child of 1873" "" "owner/repo")
if [[ "$result" == "100" ]]; then
	pass "dot-notation title resolves to parent issue number"
else
	fail "dot-notation title resolves to parent issue number" "got '$result'"
fi

# ---- Test 2: Parent: #NNN returns raw number ----
result=$(_detect_parent_from_gh_state "child foo" "Some preamble
Parent: #500
More text" "owner/repo")
if [[ "$result" == "500" ]]; then
	pass "Parent: #NNN returns raw issue number"
else
	fail "Parent: #NNN returns raw issue number" "got '$result'"
fi

# ---- Test 3: Parent: GH#NNN returns raw number ----
result=$(_detect_parent_from_gh_state "child foo" "Parent: GH#501" "owner/repo")
if [[ "$result" == "501" ]]; then
	pass "Parent: GH#NNN returns raw issue number"
else
	fail "Parent: GH#NNN returns raw issue number" "got '$result'"
fi

# ---- Test 4: **Parent:** `tNNN` (bold markdown) resolves via gh search ----
result=$(_detect_parent_from_gh_state "child foo" "**Parent:** \`t1873\`" "owner/repo")
if [[ "$result" == "100" ]]; then
	pass "bold-markdown **Parent:** \`tNNN\` resolves via gh search"
else
	fail "bold-markdown **Parent:** \`tNNN\` resolves via gh search" "got '$result'"
fi

# ---- Test 5: Blocked by: tNNN with parent-task label ----
result=$(_detect_parent_from_gh_state "child foo" "**Blocked by:** \`t1874\`" "owner/repo")
if [[ "$result" == "101" ]]; then
	pass "Blocked by: with parent-task label returns the parent"
else
	fail "Blocked by: with parent-task label returns the parent" "got '$result'"
fi

# ---- Test 6: Blocked by: tNNN WITHOUT parent-task label ----
result=$(_detect_parent_from_gh_state "child foo" "Blocked by: t1875" "owner/repo")
if [[ -z "$result" ]]; then
	pass "Blocked by: without parent-task label returns empty"
else
	fail "Blocked by: without parent-task label returns empty" "got '$result'"
fi

# ---- Test 7: No detection signals ----
result=$(_detect_parent_from_gh_state "plain title" "just a regular body with no parent reference" "owner/repo")
if [[ -z "$result" ]]; then
	pass "no detection signals returns empty"
else
	fail "no detection signals returns empty" "got '$result'"
fi

# ---- Test 8: comma-separated Blocked by: — first parent-tagged blocker wins ----
result=$(_detect_parent_from_gh_state "child foo" "**Blocked by:** \`t1875,t1876\`" "owner/repo")
if [[ "$result" == "103" ]]; then
	pass "comma-separated Blocked by: picks the first parent-tagged blocker"
else
	fail "comma-separated Blocked by: picks the first parent-tagged blocker" "got '$result'"
fi

# ---- Test 8a: multi-level dot-notation (regression coverage for CR#4) ----
# A title of "t1873.2.1: ..." must resolve to the immediate parent t1873.2
# (issue #200 in the fixture), NOT the root t1873 (#100). Previously the
# helper's Method 1 regex anchored on `^(t[0-9]+)\.[0-9]+:[[:space:]]` which
# failed to match the extra `.1` segment entirely, causing every multi-level
# child to be reported as "no parent".
#
# The dotted fixture is exposed to the stub via a dot-to-underscore rewrite
# (`GH_SEARCH_t1873_2_JSON`) because bash identifiers cannot contain `.`.
# The helper's internal jq filter escapes dots before matching the title so
# sibling collisions (e.g. `t18732:`) are rejected.
export GH_SEARCH_t1873_2_JSON='[{"number":100,"title":"t1873: parent task"},{"number":200,"title":"t1873.2: child task"},{"number":301,"title":"t18732: totally unrelated"}]'
result=$(_detect_parent_from_gh_state "t1873.2.1: deeper grandchild" "" "owner/repo")
if [[ "$result" == "200" ]]; then
	pass "multi-level dot-notation resolves to immediate parent (t1873.2.1 → t1873.2)"
else
	fail "multi-level dot-notation resolves to immediate parent (t1873.2.1 → t1873.2)" \
		"got '$result' (expected 200)"
fi

# =============================================================================
# Class B: cmd_backfill_sub_issues
# =============================================================================

# Issue #200 is a t1873.2 child; _backfill_one_issue will detect parent #100.
export GH_ISSUE_200_JSON='{"title":"t1873.2: child of 1873","body":"implementation","labels":[]}'
# Issue #201 has no parent signal.
export GH_ISSUE_201_JSON='{"title":"standalone task","body":"nothing here","labels":[]}'

# ---- Test 9: --issue N --dry-run prints "Would link", does not mutate ----
: >"$GH_LOG"
DRY_RUN="true" cmd_backfill_sub_issues --issue 200 >"${TMP}/out.9" 2>&1 || true
DRY_RUN="false"

if grep -q 'Would link #200 as sub-issue of #100' "${TMP}/out.9"; then
	if ! grep -q 'addSubIssue' "$GH_LOG"; then
		pass "dry-run prints Would link and skips addSubIssue mutation"
	else
		fail "dry-run prints Would link and skips addSubIssue mutation" \
			"unexpected addSubIssue in gh.log: $(tr '\n' '|' <"$GH_LOG" | head -c 200)"
	fi
else
	fail "dry-run prints Would link and skips addSubIssue mutation" \
		"missing 'Would link' in output: $(tr '\n' '|' <"${TMP}/out.9" | head -c 200)"
fi

# ---- Test 10: --issue N (no dry-run) calls addSubIssue ----
: >"$GH_LOG"
cmd_backfill_sub_issues --issue 200 >"${TMP}/out.10" 2>&1 || true

if grep -q 'addSubIssue' "$GH_LOG"; then
	pass "live run calls addSubIssue mutation for detected parent"
else
	fail "live run calls addSubIssue mutation for detected parent" \
		"missing addSubIssue in gh.log: $(tr '\n' '|' <"$GH_LOG" | head -c 200)"
fi

# ---- Test 11: --issue N with no parent signal → Linked: 0 ----
: >"$GH_LOG"
cmd_backfill_sub_issues --issue 201 >"${TMP}/out.11" 2>&1 || true

if grep -q 'Linked: 0' "${TMP}/out.11"; then
	if ! grep -q 'addSubIssue' "$GH_LOG"; then
		pass "no parent detected → Linked: 0, no mutation"
	else
		fail "no parent detected → Linked: 0, no mutation" \
			"unexpected addSubIssue in gh.log"
	fi
else
	fail "no parent detected → Linked: 0, no mutation" \
		"missing 'Linked: 0' in output: $(tr '\n' '|' <"${TMP}/out.11" | head -c 200)"
fi

# =============================================================================
# Class C: Parent-side detection — _extract_children_section,
#           _extract_child_references, _backfill_parent_children (GH#19942)
# =============================================================================

printf '\n%sRunning parent-side detection tests (GH#19942)%s\n' "$TEST_BLUE" "$TEST_NC"

# ---- Test 12: _extract_children_section extracts ## Children section ----
_test_body_12="## Summary
Some overview text

## Children

- #301 — first child
- #302 — second child
| LOW | t2350 | #303 | third child |

## Related

See #9999 in prose"

section_12=$(_extract_children_section "$_test_body_12")
if printf '%s' "$section_12" | grep -q '#301' && printf '%s' "$section_12" | grep -q '#303'; then
	if ! printf '%s' "$section_12" | grep -q '#9999'; then
		pass "_extract_children_section extracts ## Children, excludes ## Related"
	else
		fail "_extract_children_section extracts ## Children, excludes ## Related" \
			"section leaked #9999 from ## Related"
	fi
else
	fail "_extract_children_section extracts ## Children, excludes ## Related" \
		"section missing expected references: $(printf '%s' "$section_12" | tr '\n' '|' | head -c 200)"
fi

# ---- Test 13: _extract_children_section matches aliases (case-insensitive) ----
_test_body_13="## sub-issues

- #401 — sub one
- #402 — sub two"

section_13=$(_extract_children_section "$_test_body_13")
if printf '%s' "$section_13" | grep -q '#401'; then
	pass "_extract_children_section matches ## sub-issues alias (case-insensitive)"
else
	fail "_extract_children_section matches ## sub-issues alias (case-insensitive)" \
		"got: $(printf '%s' "$section_13" | tr '\n' '|' | head -c 200)"
fi

# ---- Test 14: _extract_child_references extracts list and table refs ----
_test_section_14="
- #301 — first child
- t2350 / #302 — second child
| LOW | t2350 | #303 | third child |
| --- | --- | --- | --- |
some prose with #9999 that is not in a list or table"

refs_14=$(_extract_child_references "$_test_section_14")
if printf '%s\n' "$refs_14" | grep -q '^301$' && \
   printf '%s\n' "$refs_14" | grep -q '^302$' && \
   printf '%s\n' "$refs_14" | grep -q '^303$'; then
	if ! printf '%s\n' "$refs_14" | grep -q '^9999$'; then
		pass "_extract_child_references extracts list/table refs, rejects prose"
	else
		fail "_extract_child_references extracts list/table refs, rejects prose" \
			"extracted #9999 from prose line"
	fi
else
	fail "_extract_child_references extracts list/table refs, rejects prose" \
		"missing expected refs: $(printf '%s' "$refs_14" | tr '\n' ',' | head -c 200)"
fi

# ---- Test 15: _extract_child_references handles GH#NNN format ----
_test_section_15="- GH#501 — issue with GH prefix
- #502 — normal ref"

refs_15=$(_extract_child_references "$_test_section_15")
if printf '%s\n' "$refs_15" | grep -q '^501$' && \
   printf '%s\n' "$refs_15" | grep -q '^502$'; then
	pass "_extract_child_references handles GH#NNN format"
else
	fail "_extract_child_references handles GH#NNN format" \
		"got: $(printf '%s' "$refs_15" | tr '\n' ',' | head -c 200)"
fi

# ---- Test 16: cmd_backfill_sub_issues with parent-task issue (dry-run) ----
# Umbrella parent #300 with ## Children section listing 3 children
export GH_ISSUE_300_JSON='{"title":"t2349: umbrella parent","body":"## Summary\nOverview\n\n## Children\n\n- #301 — first child\n- #302 — second child\n| LOW | t2350 | #303 | third child |\n\nSee #9999 in prose","labels":[{"name":"parent-task"},{"name":"enhancement"}]}'
export GH_ISSUE_301_JSON='{"title":"t2349.1: first child","body":"","labels":[]}'
export GH_ISSUE_302_JSON='{"title":"t2349.2: second child","body":"","labels":[]}'
export GH_ISSUE_303_JSON='{"title":"t2350: third child","body":"","labels":[]}'

: >"$GH_LOG"
DRY_RUN="true" cmd_backfill_sub_issues --issue 300 >"${TMP}/out.16" 2>&1 || true
DRY_RUN="false"

# Should report 3 children would be linked
count_16=$(grep -c 'Would link.*sub-issue of #300 (parent-side)' "${TMP}/out.16" 2>/dev/null) || count_16=0
if [[ "$count_16" -eq 3 ]]; then
	if ! grep -q 'addSubIssue' "$GH_LOG"; then
		pass "parent-side dry-run reports 3 children, no mutation"
	else
		fail "parent-side dry-run reports 3 children, no mutation" \
			"unexpected addSubIssue in gh.log"
	fi
else
	fail "parent-side dry-run reports 3 children, no mutation" \
		"expected 3 'Would link' lines, got $count_16; output: $(tr '\n' '|' <"${TMP}/out.16" | head -c 300)"
fi

# ---- Test 17: cmd_backfill_sub_issues with parent-task issue (live) ----
: >"$GH_LOG"
cmd_backfill_sub_issues --issue 300 >"${TMP}/out.17" 2>&1 || true

add_count_17=$(grep -c 'addSubIssue' "$GH_LOG" 2>/dev/null) || add_count_17=0
if [[ "$add_count_17" -eq 3 ]]; then
	pass "parent-side live run calls addSubIssue 3 times"
else
	fail "parent-side live run calls addSubIssue 3 times" \
		"expected 3 addSubIssue calls, got $add_count_17; log: $(tr '\n' '|' <"$GH_LOG" | head -c 300)"
fi

# ---- Test 18: prose #NNN outside ## Children does NOT produce false link ----
# The body has "See #9999 in prose" outside the Children section
if ! grep -q '9999' "$GH_LOG"; then
	pass "prose #9999 outside Children section not linked"
else
	fail "prose #9999 outside Children section not linked" \
		"found 9999 reference in gh.log (false positive)"
fi

# ---- Test 19: parent-task issue without ## Children section → Linked: 0 ----
export GH_ISSUE_304_JSON='{"title":"t2351: parent no children","body":"Just a regular parent\n\nSee #305 in prose","labels":[{"name":"parent-task"}]}'

: >"$GH_LOG"
cmd_backfill_sub_issues --issue 304 >"${TMP}/out.19" 2>&1 || true

if grep -q 'Linked: 0' "${TMP}/out.19"; then
	if ! grep -q 'addSubIssue' "$GH_LOG"; then
		pass "parent-task without Children section → Linked: 0, no mutation"
	else
		fail "parent-task without Children section → Linked: 0, no mutation" \
			"unexpected addSubIssue in gh.log"
	fi
else
	fail "parent-task without Children section → Linked: 0, no mutation" \
		"missing 'Linked: 0' in output: $(tr '\n' '|' <"${TMP}/out.19" | head -c 200)"
fi

# ---- Test 20: existing child-side detection still works with pre-fetched data ----
# Issue #200 is a t1873.2 child (set up in Class B fixtures above)
: >"$GH_LOG"
cmd_backfill_sub_issues --issue 200 >"${TMP}/out.20" 2>&1 || true

if grep -q 'addSubIssue' "$GH_LOG"; then
	pass "child-side detection still works through pre-fetch routing (regression)"
else
	fail "child-side detection still works through pre-fetch routing (regression)" \
		"missing addSubIssue in gh.log: $(tr '\n' '|' <"$GH_LOG" | head -c 200)"
fi

# =============================================================================
# Class D: REST fallback for node-ID resolution (t2739)
# =============================================================================
# Tests 21–22 exercise the new REST path in _cached_node_id.
# Strategy:
#   - Override the resolve_gh_node_id bash function to return empty, simulating
#     GraphQL budget exhaustion without needing stub-level plumbing.
#   - Set _GH_SHOULD_FALLBACK_OVERRIDE=1 so _rest_should_fallback
#     returns true without needing a real rate-limit state.
#   - For test 21: GH_REST_NODE_<num> fixtures supply node IDs via REST
#     → link succeeds (addSubIssue mutation fires).
#   - For test 22: no REST fixtures → both paths fail → RATE_LIMITED emitted
#     and Rate-limited: 1 appears in the summary.

printf '\n%sRunning REST fallback tests (t2739)%s\n' "$TEST_BLUE" "$TEST_NC"

# Issue #400: child that maps to parent #100 via dot-notation (t1873.2 fixture)
# Use the same parent/child fixture as test 9/10 (#200 → parent #100) so the
# parent-detection logic is already proven; only node resolution changes.
export GH_ISSUE_400_JSON='{"title":"t1873.2: child of 1873","body":"REST fallback child","labels":[]}'
# Override resolve_gh_node_id to return empty (simulating GraphQL exhaustion).
# The real function is in issue-sync-lib.sh; bash function override works here.
resolve_gh_node_id() { echo ""; return 0; }
export _GH_SHOULD_FALLBACK_OVERRIDE=1

# ---- Test 21: REST fallback fires, link succeeds ----
# Provide REST node_id for both child (#400) and parent (#100).
export GH_REST_NODE_400='{"node_id":"REST_CHILD_NODE"}'
export GH_REST_NODE_100='{"node_id":"REST_PARENT_NODE"}'
# Clear node cache so it doesn't serve stale GraphQL-resolved entries.
: >"$_NODE_ID_CACHE_FILE"

: >"$GH_LOG"
cmd_backfill_sub_issues --issue 400 >"${TMP}/out.21" 2>&1 || true

if grep -q 'addSubIssue' "$GH_LOG"; then
	pass "REST fallback: link succeeds when GraphQL exhausted but REST returns node_id"
else
	fail "REST fallback: link succeeds when GraphQL exhausted but REST returns node_id" \
		"missing addSubIssue in gh.log: $(tr '\n' '|' <"$GH_LOG" | head -c 300)"
fi

# ---- Test 22: RATE_LIMITED emitted when both GraphQL and REST fail ----
# Remove REST fixtures so the stub returns empty for /repos/.../issues/NNN.
unset GH_REST_NODE_400 GH_REST_NODE_100
: >"$_NODE_ID_CACHE_FILE"

: >"$GH_LOG"
cmd_backfill_sub_issues --issue 400 >"${TMP}/out.22" 2>&1 || true

if grep -q 'Rate-limited: 1' "${TMP}/out.22"; then
	if ! grep -q 'addSubIssue' "$GH_LOG"; then
		pass "RATE_LIMITED emitted distinctly when both GraphQL and REST fail"
	else
		fail "RATE_LIMITED emitted distinctly when both GraphQL and REST fail" \
			"unexpected addSubIssue in gh.log"
	fi
else
	fail "RATE_LIMITED emitted distinctly when both GraphQL and REST fail" \
		"missing 'Rate-limited: 1' in output: $(tr '\n' '|' <"${TMP}/out.22" | head -c 300)"
fi

# Restore normal behaviour for any future tests.
unset _GH_SHOULD_FALLBACK_OVERRIDE
unset _GH_GRAPHQL_NODE_FAIL
resolve_gh_node_id() {
	local issue_number="$1" repo="$2"
	local owner="${repo%%/*}" name="${repo##*/}"
	local node_id
	# shellcheck disable=SC2016  # GraphQL variables are expanded by GitHub, not shell.
	node_id=$(gh api graphql \
		-f query='query($owner:String!,$name:String!,$num:Int!){repository(owner:$owner,name:$name){issue(number:$num){id}}}' \
		-f owner="$owner" -f name="$name" -F num="$issue_number" \
		--jq '.data.repository.issue.id' 2>/dev/null || echo "")
	echo "$node_id"
	return 0
}

# =============================================================================
# Summary
# =============================================================================

echo
echo "============================================"
printf 'Tests run:    %d\n' "$TESTS_RUN"
printf 'Tests failed: %d\n' "$TESTS_FAILED"
echo "============================================"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
