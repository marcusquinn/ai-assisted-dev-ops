#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for GH#22948 dispatch guards: PR objects and interactive/review hold
# labels must block worker dispatch before label/assignee mutation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CORE_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-core.sh"
LAYERS_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-dedup-layers.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
MOCK_GH_TARGET_IS_PR="0"
_PULSE_DISPATCH_FALSE="false"

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

define_helpers_under_test() {
	local helper_src
	helper_src=$(python3 - "$CORE_SCRIPT" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
for name in ("_dispatch_target_is_pull_request", "_dispatch_has_interactive_hold"):
    start = text.index(f"{name}() {{")
    depth = 0
    end = None
    for offset, char in enumerate(text[start:]):
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                end = start + offset + 1
                break
    if end is None:
        raise SystemExit(f"could not extract {name}")
    print(text[start:end])
PY
	)
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract dispatch guard helpers from %s\n' "$CORE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$helper_src"
	return 0
}

# shellcheck disable=SC2317
gh() {
	if [[ "${1:-}" == "api" && "${2:-}" == repos/*/issues/* ]]; then
		case "$MOCK_GH_TARGET_IS_PR" in
		1) printf '{"number":1108,"pull_request":{"url":"https://api.github.invalid/pulls/1108"}}\n' ;;
		api_fail) return 1 ;;
		*) printf '{"number":22948}\n' ;;
		esac
		return 0
	fi
	printf 'unexpected gh call: %s\n' "$*" >&2
	return 1
}

test_pr_guard_uses_rest_issue_object() {
	MOCK_GH_TARGET_IS_PR="1"
	if _dispatch_target_is_pull_request 1108 owner/repo; then
		print_result "PR guard blocks REST pull_request objects" 0
		return 0
	fi
	print_result "PR guard blocks REST pull_request objects" 1 "expected PR detection from gh api"
	return 0
}

test_pr_guard_allows_plain_issue() {
	MOCK_GH_TARGET_IS_PR="0"
	if _dispatch_target_is_pull_request 22948 owner/repo; then
		print_result "PR guard allows plain issue objects" 1 "plain issue was classified as PR"
		return 0
	fi
	print_result "PR guard allows plain issue objects" 0
	return 0
}

test_interactive_hold_blocks_in_review_without_handoff() {
	local meta='{"labels":[{"name":"status:in-review"}]}'
	if _dispatch_has_interactive_hold "$meta"; then
		print_result "interactive hold blocks status:in-review without handoff" 0
		return 0
	fi
	print_result "interactive hold blocks status:in-review without handoff" 1 "expected status:in-review to block"
	return 0
}

test_interactive_hold_allows_unassigned_origin_interactive() {
	local meta='{"labels":[{"name":"origin:interactive"},{"name":"status:available"},{"name":"bug"}],"assignees":[]}'
	if _dispatch_has_interactive_hold "$meta"; then
		print_result "interactive hold allows unassigned origin:interactive backlog" 1 "provenance-only origin:interactive must not strand available work"
		return 0
	fi
	print_result "interactive hold allows unassigned origin:interactive backlog" 0
	return 0
}

test_interactive_hold_blocks_assigned_origin_interactive() {
	local meta='{"labels":[{"name":"origin:interactive"},{"name":"bug"}],"assignees":[{"login":"owner"}]}'
	if _dispatch_has_interactive_hold "$meta"; then
		print_result "interactive hold blocks assigned origin:interactive" 0
		return 0
	fi
	print_result "interactive hold blocks assigned origin:interactive" 1 "expected assigned origin:interactive work to block"
	return 0
}

test_interactive_hold_allows_auto_dispatch_handoff() {
	local meta='{"labels":[{"name":"origin:interactive"},{"name":"auto-dispatch"},{"name":"bug"}]}'
	if _dispatch_has_interactive_hold "$meta"; then
		print_result "interactive hold allows auto-dispatch handoff" 1 "auto-dispatch should override provenance-only origin:interactive"
		return 0
	fi
	print_result "interactive hold allows auto-dispatch handoff" 0
	return 0
}

test_interactive_hold_allows_auto_dispatch_review_handoff() {
	local meta='{"labels":[{"name":"status:in-review"},{"name":"auto-dispatch"},{"name":"bug"}]}'
	if _dispatch_has_interactive_hold "$meta"; then
		print_result "interactive hold allows auto-dispatch review handoff" 1 "auto-dispatch should route status:in-review to stale-claim dedup"
		return 0
	fi
	print_result "interactive hold allows auto-dispatch review handoff" 0
	return 0
}

test_interactive_hold_allows_worker_issue() {
	local meta='{"labels":[{"name":"auto-dispatch"},{"name":"origin:worker"}]}'
	if _dispatch_has_interactive_hold "$meta"; then
		print_result "interactive hold allows worker-labelled issue" 1 "origin:worker should not block this guard"
		return 0
	fi
	print_result "interactive hold allows worker-labelled issue" 0
	return 0
}

test_interactive_hold_emits_structured_block_reason() {
	if grep -q 'DISPATCH_BLOCK_REASON reason=interactive_review_hold' "$LAYERS_SCRIPT" && grep -q 'return 3' "$CORE_SCRIPT"; then
		print_result "interactive hold emits structured benign block reason" 0
		return 0
	fi
	print_result "interactive hold emits structured benign block reason" 1 "expected structured reason and benign rc=3 in dispatch core"
	return 0
}

test_checkpoint_route_precedes_generic_interactive_hold() {
	if grep -q '_dispatch_interactive_hold_gate' "$CORE_SCRIPT" && python3 - "$LAYERS_SCRIPT" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
start = text.index("_dispatch_interactive_hold_gate() {")
end = text.index("\n}\n", start)
body = text[start:end]
if body.index("_dispatch_interactive_worker_checkpoint_continuation") >= body.index("reason=interactive_review_hold"):
    raise SystemExit(1)
PY
	then
		print_result "verified checkpoint route precedes generic interactive hold" 0
		return 0
	fi
	print_result "verified checkpoint route precedes generic interactive hold" 1
	return 0
}

test_pr_guard_emits_structured_block_reason() {
	if grep -q 'DISPATCH_BLOCK_REASON reason=pr_target_not_dispatchable' "$CORE_SCRIPT" && grep -q 'target is a pull request, not a dispatchable issue' "$CORE_SCRIPT"; then
		print_result "PR target guard emits structured benign block reason" 0
		return 0
	fi
	print_result "PR target guard emits structured benign block reason" 1 "expected PR target structured reason in dispatch core"
	return 0
}

test_dedup_guard_emits_structured_block_reason() {
	if grep -q "classify-blocker \"\$_dedup_block_signal\"" "$CORE_SCRIPT" \
		&& grep -q "signal=\${_dedup_block_signal}" "$CORE_SCRIPT" \
		&& grep -q 'dedup_guard_blocked' "$CORE_SCRIPT"; then
		print_result "dedup guard emits classified structured block reason" 0
		return 0
	fi
	print_result "dedup guard emits classified structured block reason" 1 "expected dedup guard to classify captured blocker signal with fallback"
	return 0
}

main() {
	if ! define_helpers_under_test; then
		return 1
	fi

	test_pr_guard_uses_rest_issue_object
	test_pr_guard_allows_plain_issue
	test_interactive_hold_blocks_in_review_without_handoff
	test_interactive_hold_allows_unassigned_origin_interactive
	test_interactive_hold_blocks_assigned_origin_interactive
	test_interactive_hold_allows_auto_dispatch_handoff
	test_interactive_hold_allows_auto_dispatch_review_handoff
	test_interactive_hold_allows_worker_issue
	test_interactive_hold_emits_structured_block_reason
	test_checkpoint_route_precedes_generic_interactive_hold
	test_pr_guard_emits_structured_block_reason
	test_dedup_guard_emits_structured_block_reason

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
