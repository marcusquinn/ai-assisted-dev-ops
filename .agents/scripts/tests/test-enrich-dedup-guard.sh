#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-enrich-dedup-guard.sh — GH#19856 regression guard.
#
# Asserts that the enrich path in issue-sync-helper.sh respects the
# dispatch-dedup-helper.sh read-only assignment guard before modifying issue
# labels, title, or body. Also verifies that coordination-signal labels
# are protected by _is_protected_label.
#
# Failure history: GH#19856 — runner B's enrich path stripped runner A's
# active claim labels (status:in-review, origin:interactive) because
# enrich ran upstream of the dedup guard.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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

# Sandbox HOME so sourcing is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# =============================================================================
# Part 1 — _is_protected_label protects coordination-signal labels
# =============================================================================
# Source issue-sync-helper.sh to get access to _is_protected_label.
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/issue-sync-helper.sh" >/dev/null 2>&1
set +e

# Labels that MUST be protected (coordination signals from GH#19856).
# publication:pending must survive enrich until default-branch reconciliation
# validates its canonical TODO/brief mapping and removes the hold last.
for lbl in "no-auto-dispatch" "publication:pending" "no-takeover" "consolidation-in-progress" \
	"coderabbit-nits-ok" "ratchet-bump" "new-file-smell-ok"; do
	if _is_protected_label "$lbl"; then
		print_result "_is_protected_label protects '$lbl'" 0
	else
		print_result "_is_protected_label protects '$lbl'" 1 "(expected return 0 — label should be protected)"
	fi
done

# Prefix-protected namespaces must still work
for lbl in "status:in-review" "status:claimed" "status:in-progress" \
	"status:queued" "origin:interactive" "origin:worker" "tier:standard"; do
	if _is_protected_label "$lbl"; then
		print_result "_is_protected_label protects '$lbl' (prefix)" 0
	else
		print_result "_is_protected_label protects '$lbl' (prefix)" 1 "(expected return 0)"
	fi
done

# Pre-existing exact-match labels must still work (regression guard)
for lbl in "parent-task" "meta" "auto-dispatch" "persistent" \
	"needs-maintainer-review" "not-planned" "duplicate" "wontfix" \
	"already-fixed"; do
	if _is_protected_label "$lbl"; then
		print_result "_is_protected_label still protects '$lbl'" 0
	else
		print_result "_is_protected_label still protects '$lbl'" 1 "(regression)"
	fi
done

# Non-coordination labels must NOT be protected
for lbl in "bug" "enhancement" "simplification" "architecture"; do
	if ! _is_protected_label "$lbl"; then
		print_result "_is_protected_label allows removal of '$lbl'" 0
	else
		print_result "_is_protected_label allows removal of '$lbl'" 1 "(unexpected protection)"
	fi
done

# =============================================================================
# Part 2 — read-only assignment inspection blocks on active claims
# =============================================================================
# Stub the `gh` CLI to return synthetic issue payloads.
STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"
GH_WRITE_LOG="${TEST_ROOT}/gh-writes.log"
: >"$GH_WRITE_LOG"
export GH_WRITE_LOG

write_stub_gh() {
	local payload="$1"
	local fail_reads="${2:-false}"
	cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
# Stub gh for test — returns pre-configured JSON for issue view
_main() {
	local cmd="\$1" sub="\$2"
	if [[ "\$cmd" == "issue" && ("\$sub" == "edit" || "\$sub" == "comment") ]]; then
		printf '%s\n' "\$*" >>"\${GH_WRITE_LOG}"
		return 0
	fi
	if [[ "\$cmd" == "issue" && "\$sub" == "view" ]]; then
		[[ "${fail_reads}" == "true" ]] && return 1
		echo '${payload}'
		return 0
	fi
	if [[ "\$cmd" == "api" ]]; then
		[[ "${fail_reads}" == "true" ]] && return 1
		if [[ "\${2:-}" == /repos/*/issues/* || "\${2:-}" == repos/*/issues/* ]]; then
			echo '${payload}'
			return 0
		fi
		echo '{"login": "testbot"}'
		return 0
	fi
	return 1
}
_main "\$@"
STUB
	chmod +x "${STUB_DIR}/gh"
	return 0
}

# Prepend stub dir so our stub shadows the real gh
export PATH="${STUB_DIR}:${PATH}"

# Test: issue with status:in-review + assignee should block (return 0)
write_stub_gh '{"state":"OPEN","assignees":[{"login":"runnerA"}],"labels":[{"name":"status:in-review"}]}'
_dedup_result=$("${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh" is-assigned-read-only 123 "test/repo" "runnerB" 2>/dev/null) || true
if [[ -n "$_dedup_result" ]]; then
	print_result "is-assigned blocks when status:in-review + other assignee" 0
else
	print_result "is-assigned blocks when status:in-review + other assignee" 1 "(expected block, got pass)"
fi

# Test: issue with origin:interactive + assignee should block
write_stub_gh '{"state":"OPEN","assignees":[{"login":"maintainer"}],"labels":[{"name":"origin:interactive"}]}'
_dedup_result=$("${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh" is-assigned-read-only 123 "test/repo" "runnerB" 2>/dev/null) || true
if [[ -n "$_dedup_result" ]]; then
	print_result "is-assigned blocks when origin:interactive + assignee" 0
else
	print_result "is-assigned blocks when origin:interactive + assignee" 1 "(expected block, got pass)"
fi

# Test: issue with status:claimed + assignee should block
write_stub_gh '{"state":"OPEN","assignees":[{"login":"runnerA"}],"labels":[{"name":"status:claimed"}]}'
_dedup_result=$("${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh" is-assigned-read-only 123 "test/repo" "runnerB" 2>/dev/null) || true
if [[ -n "$_dedup_result" ]]; then
	print_result "is-assigned blocks when status:claimed + other assignee" 0
else
	print_result "is-assigned blocks when status:claimed + other assignee" 1 "(expected block, got pass)"
fi

# Test: issue with no active labels + no assignee should pass (return 1)
write_stub_gh '{"state":"OPEN","assignees":[],"labels":[{"name":"bug"}]}'
_dedup_result=$("${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh" is-assigned-read-only 123 "test/repo" "runnerB" 2>/dev/null) || true
if [[ -z "$_dedup_result" ]]; then
	print_result "is-assigned allows when no claim + no assignee" 0
else
	print_result "is-assigned allows when no claim + no assignee" 1 "(expected pass, got block: $_dedup_result)"
fi

# =============================================================================
# Part 3 — _enrich_process_task aborts when dedup guard fires
# =============================================================================
# Check that the extracted helper function exists
if grep -q '_enrich_check_active_claim()' "${TEST_SCRIPTS_DIR}/issue-sync-helper-enrich.sh"; then
	print_result "_enrich_check_active_claim function exists (GH#19856)" 0
else
	print_result "_enrich_check_active_claim function exists (GH#19856)" 1 "(function not found)"
fi

# Check that _enrich_process_task calls the guard
if grep -q 'if _enrich_check_active_claim' "${TEST_SCRIPTS_DIR}/issue-sync-helper.sh"; then
	print_result "_enrich_process_task calls GH#19856 dedup guard" 0
else
	print_result "_enrich_process_task calls GH#19856 dedup guard" 1 "(guard call not found in _enrich_process_task)"
fi

# Exercise the real enrich guard with an old interactive claim. The read-only
# path must block enrichment without edit/comment recovery writes (GH#28498).
: >"$GH_WRITE_LOG"
export AIDEVOPS_SESSION_USER="runnerB"
active_claim_json='{"state":"OPEN","assignees":[{"login":"runnerA"}],"labels":[{"name":"origin:interactive"},{"name":"status:in-review"}]}'
if _enrich_check_active_claim 123 "test/repo" "t28498" "$active_claim_json" >/dev/null 2>&1 \
	&& [[ ! -s "$GH_WRITE_LOG" ]]; then
	print_result "enrich guard blocks active interactive claim with zero GitHub writes" 0
else
	print_result "enrich guard blocks active interactive claim with zero GitHub writes" 1 "(guard passed or emitted a write)"
fi

# A structurally blocked task must return before authoritative body composition.
# This keeps broad no-op sweeps on their prefetched, read-only path (GH#30021).
TODO_FIXTURE="${TEST_ROOT}/TODO.md"
mkdir -p "${TEST_ROOT}/todo/tasks"
printf '%s\n' '- [ ] t30021: Blocked fixture #bug ref:GH#123' >"$TODO_FIXTURE"
compose_issue_body() {
	printf 'compose\n' >>"${TEST_ROOT}/compose-calls.log"
	printf 'unexpected body\n'
	return 0
}
require_task_issue_mapping() {
	return 0
}
: >"${TEST_ROOT}/compose-calls.log"
ENRICH_PREFETCH_FILE="${TEST_ROOT}/prefetch.json"
printf '%s\n' "[$active_claim_json]" >"$ENRICH_PREFETCH_FILE"
if _enrich_process_task "t30021" "test/repo" "$TODO_FIXTURE" "$TEST_ROOT" \
	'- [ ] t30021: Blocked fixture #bug ref:GH#123' >/dev/null 2>&1 &&
	[[ ! -s "${TEST_ROOT}/compose-calls.log" ]]; then
	print_result "blocked enrich task returns before authoritative body composition" 0
else
	print_result "blocked enrich task returns before authoritative body composition" 1 "(compose_issue_body was called)"
fi
unset ENRICH_PREFETCH_FILE

# Metadata uncertainty must also fail closed without trying recovery writes.
: >"$GH_WRITE_LOG"
write_stub_gh '{}' true
if _enrich_check_active_claim 123 "test/repo" "t28498" "" >/dev/null 2>&1 \
	&& [[ ! -s "$GH_WRITE_LOG" ]]; then
	print_result "enrich guard fails closed on uncertain metadata with zero GitHub writes" 0
else
	print_result "enrich guard fails closed on uncertain metadata with zero GitHub writes" 1 "(guard passed or emitted a write)"
fi

# Part 3b — _ensure_issue_body_has_brief also has the guard
if grep -q 'is-assigned-read-only' "${TEST_SCRIPTS_DIR}/pulse-dispatch-core.sh"; then
	print_result "_ensure_issue_body_has_brief contains GH#19856 dedup guard" 0
else
	print_result "_ensure_issue_body_has_brief contains GH#19856 dedup guard" 1 "(guard code not found)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "---"
echo "Tests run: $TESTS_RUN | Passed: $((TESTS_RUN - TESTS_FAILED)) | Failed: $TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	echo "${TEST_RED}SOME TESTS FAILED${TEST_RESET}"
	exit 1
fi
echo "${TEST_GREEN}ALL TESTS PASSED${TEST_RESET}"
exit 0
