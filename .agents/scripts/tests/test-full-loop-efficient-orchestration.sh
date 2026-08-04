#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass() {
	printf 'PASS %s\n' "$1"
	return 0
}

fail() {
	printf 'FAIL %s\n' "$1" >&2
	exit 1
}

print_info() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }
print_success() { return 0; }
print_phase() { return 0; }
is_headless() { [[ "${HEADLESS:-false}" == "true" ]]; }

SCRIPT_DIR="$SCRIPTS_DIR"
STATE_DIR="${TMP_DIR}/state"
STATE_FILE="${STATE_DIR}/full-loop.local.state"
DEFAULT_MAX_TASK_ITERATIONS=50
DEFAULT_MAX_PREFLIGHT_ITERATIONS=5
DEFAULT_MAX_PR_ITERATIONS=20
HEADLESS=false
_FG_PID_FILE=""
# shellcheck source=../full-loop-helper-state.sh
source "${SCRIPTS_DIR}/full-loop-helper-state.sh"

_init_start_defaults
PHASE_STATUS="waiting"
PHASE_ATTEMPT=1
PHASE_STARTED_AT="2026-01-01T00:00:00Z"
NEXT_ACTION="complete-task-development"
save_state "task" "fixture task"
output=$(_launch_background "fixture task")
printf '%s' "$output" | grep -q 'FULL_LOOP_START_RESULT=initialized-only' || fail "background start did not report initialized-only"
[[ ! -f "${STATE_DIR}/full-loop.pid" ]] || fail "initialized-only start wrote a PID"
load_state
[[ "$EXECUTOR_STATUS" == "initialized-only" && "$NEXT_ACTION" == "attach-executor-or-resume" ]] || fail "initialized-only evidence was not persisted"
[[ -s "${STATE_DIR}/full-loop-events.jsonl" ]] || fail "executor event evidence was not recorded"
pass "background start never implies an unlaunched executor is running"

_full_loop_acquire_transition_lock || fail "first transition lock acquisition failed"
_full_loop_acquire_transition_lock || fail "re-entrant transition lock acquisition failed"
_full_loop_release_transition_lock
[[ -f "${STATE_DIR}/full-loop-transition.lock" ]] || fail "nested release dropped an outer transition lock"
_full_loop_release_transition_lock
[[ ! -e "${STATE_DIR}/full-loop-transition.lock" ]] || fail "transition lock was not released"
printf '%s:%s:1\n' "$$" "$(date +%s)" >"${STATE_DIR}/full-loop-transition.lock"
if _full_loop_acquire_transition_lock 2>/dev/null; then
	fail "transition lock accepted a different live owner token"
fi
rm -f "${STATE_DIR}/full-loop-transition.lock"
printf '999999:%s:1\n' "$(date +%s)" >"${STATE_DIR}/full-loop-transition.lock"
_full_loop_acquire_transition_lock || fail "stale transition lock was not reclaimed"
_full_loop_release_transition_lock
pass "state transitions are protected by an ownership-aware lock"

# shellcheck source=../task-decompose-helper.sh
source "${SCRIPTS_DIR}/task-decompose-helper.sh"
plan=$(extract_decompose_json '{"subtasks":[{"id":"unit-a","description":"A","effort":"simple","owns":{"files":["a.sh"],"questions":[]},"blocked_by":[]},{"id":"unit-b","description":"B","effort":"standard","owns":{"files":["b.sh"],"questions":[]},"blocked_by":[]},{"id":"unit-c","description":"C","effort":"thinking","owns":{"files":["c.sh"],"questions":[]},"blocked_by":[0,1]}],"strategy":"breadth-first","max_parallel":2}' 5)
[[ "$(printf '%s' "$plan" | jq -r '.subtasks[2].blocked_by | join(",")')" == "0,1" ]] || fail "valid dependency graph was rejected"
[[ "$(printf '%s' "$plan" | jq -r '.max_parallel')" == "2" ]] || fail "bounded concurrency was not preserved"
overlap=$(extract_decompose_json '{"subtasks":[{"description":"A","owns":{"files":["same.sh"]},"blocked_by":[]},{"description":"B","owns":{"files":["same.sh"]},"blocked_by":[]}],"strategy":"breadth-first"}' 5)
[[ -z "$overlap" ]] || fail "parallel overlapping file ownership was accepted"
cycle=$(extract_decompose_json '{"subtasks":[{"description":"A","owns":{"files":["a.sh"]},"blocked_by":[1]},{"description":"B","owns":{"files":["b.sh"]},"blocked_by":[0]}],"strategy":"breadth-first"}' 5)
[[ -z "$cycle" ]] || fail "cyclic dependency graph was accepted"
alias_path=$(extract_decompose_json '{"subtasks":[{"description":"A","owns":{"files":["src/a.sh"]},"blocked_by":[]},{"description":"B","owns":{"files":["./src/a.sh"]},"blocked_by":[]}],"strategy":"breadth-first"}' 5)
[[ -z "$alias_path" ]] || fail "non-canonical ownership path was accepted"
trailing_path=$(extract_decompose_json '{"subtasks":[{"description":"A","owns":{"files":["src/module/"]},"blocked_by":[]}],"strategy":"breadth-first"}' 5)
[[ -z "$trailing_path" ]] || fail "trailing-slash ownership path was accepted"
pass "session plan validates dependencies, tiers, and non-overlapping ownership"

legacy_plan=$(
	command() {
		if [[ "${1:-}" == "-v" && "${2:-}" == "jq" ]]; then
			return 1
		fi
		builtin command "$@"
		return $?
	}
	heuristic_decompose "Build login and registration"
)
printf '%s' "$legacy_plan" | grep -q '"subtasks"' || fail "no-jq heuristic fallback emitted no plan"
printf '%s' "$legacy_plan" | grep -q '"strategy":"breadth-first"' || fail "no-jq heuristic fallback omitted strategy"
printf '%s' "$legacy_plan" | grep -q '"schema_version":1' || fail "no-jq heuristic fallback omitted schema version"
printf '%s' "$legacy_plan" | grep -q '"owns":{"files":\[\],"questions":' || fail "no-jq heuristic fallback omitted ownership"
printf '%s' "$legacy_plan" | grep -q '"reuse_key":"unit-1"' || fail "no-jq heuristic fallback omitted reuse key"
pass "heuristic decomposition remains available without jq"

# shellcheck source=../full-loop-helper-commit.sh
source "${SCRIPTS_DIR}/full-loop-helper-commit.sh"
CHECK_MODE="pending"
POST_CHECK_HEAD="abc123"
PR_VIEW_CACHE_CONTROL_FILE="${TMP_DIR}/pr-view-cache-control.log"
: >"$PR_VIEW_CACHE_CONTROL_FILE"
gh() {
	if [[ "$1" == "api" && "$2" == "graphql" ]]; then
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"state":"OPEN","isDraft":false,"reviewDecision":"","headRefOid":"abc123","headRefName":"fixture-remote"}},"rateLimit":{"cost":1}}}'
		return 0
	fi
	if [[ "$1" == "api" && "$2" == "repos/owner/repo" ]]; then
		if [[ "$CHECK_MODE" == "api-error" ]]; then
			return 1
		fi
		printf '%s\n' 'main'
		return 0
	fi
	if [[ "$1" == "api" && "$2" == *"/protection/required_status_checks" ]]; then
		if [[ "$CHECK_MODE" == "no-required" ]]; then
			printf '%s\n' 'gh: HTTP 404: Not Found' >&2
			return 1
		fi
		printf '%s\n' '{"contexts":["required"]}'
		return 0
	fi
	if [[ "$1" == "api" && "$2" == "repos/owner/repo/rulesets" ]]; then
		printf '%s\n' '[]'
		return 0
	fi
	if [[ "$1 $2" == "pr view" ]]; then
		printf '%s\n' "${AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE:-0}" >>"$PR_VIEW_CACHE_CONTROL_FILE"
		if printf '%s\n' "$*" | grep -q -- '--jq'; then
			printf '%s\n' "$POST_CHECK_HEAD"
			return 0
		fi
		printf '{"state":"OPEN","isDraft":false,"reviewDecision":"","headRefOid":"abc123","headRefName":"fixture-remote"}\n'
		return 0
	fi
	if [[ "$1 $2" == "pr checks" ]]; then
		case "$CHECK_MODE" in
		pending)
			printf '[{"name":"required","state":"IN_PROGRESS","bucket":"pending"}]\n'
			return 8
			;;
		failure)
			printf '[{"name":"required","state":"FAILURE","bucket":"fail"}]\n'
			return 1
			;;
		success)
			printf '[{"name":"required","state":"SUCCESS","bucket":"pass"}]\n'
			return 0
			;;
		no-required)
			printf 'required-check CLI must not run when configuration has no contexts\n' >&2
			return 99
			;;
		api-error)
			printf 'HTTP 503: service unavailable\n' >&2
			return 1
			;;
		changed-wording)
			printf "no required checks configured for the 'fixture-remote' branch\n" >&2
			return 1
			;;
		malformed)
			printf 'not-json\n'
			return 0
			;;
		empty-array)
			printf '[]\n'
			return 0
			;;
		esac
	fi
	return 1
}

gh_pr_checks_exact_json() {
	local repo_slug="$1"
	local pr_number="$2"
	local selection_mode="$3"
	: "$repo_slug" "$pr_number" "$selection_mode"
	case "$CHECK_MODE" in
	pending)
		printf '[{"name":"required","state":"IN_PROGRESS","bucket":"pending"}]\n'
		return 8
		;;
	failure)
		printf '[{"name":"required","state":"FAILURE","bucket":"fail"}]\n'
		return 1
		;;
	success)
		printf '[{"name":"required","state":"SUCCESS","bucket":"pass"}]\n'
		return 0
		;;
	no-required)
		printf 'exact check helper must not run when configuration has no contexts\n' >&2
		return 99
		;;
	api-error)
		printf 'exact check read unavailable\n' >&2
		return 2
		;;
	changed-wording)
		printf "no required checks configured for the 'fixture-remote' branch\n" >&2
		return 1
		;;
	malformed)
		printf 'not-json\n'
		return 0
		;;
	empty-array)
		printf '[]\n'
		return 0
		;;
	*) return 2 ;;
	esac
}

FULL_LOOP_PR_CHECK_STATUS=""
_full_loop_verify_pr_readiness 42 owner/repo && fail "pending checks passed readiness"
[[ "$FULL_LOOP_PR_CHECK_STATUS" == "pending" ]] || fail "pending checks were not classified as pending"
load_state
[[ "$PR_CHECK_STATUS" == "pending" && "$PR_CHECK_HEAD" == "abc123" ]] || fail "pending exact-head evidence was not persisted"
CHECK_MODE="failure"
_full_loop_verify_pr_readiness 42 owner/repo && fail "terminal failure passed readiness"
[[ "$FULL_LOOP_PR_CHECK_STATUS" == "terminal-failure" ]] || fail "terminal failure was not classified"
printf '%s' "$FULL_LOOP_PR_FAILURE_EVIDENCE" | jq -e 'length == 1 and .[0].name == "required"' >/dev/null || fail "focused failure evidence missing"
load_state
[[ "$PR_CHECK_STATUS" == "terminal-failure" && "$PR_CHECK_EVIDENCE" == "required" ]] || fail "terminal failure evidence was not persisted"
CHECK_MODE="success"
_full_loop_verify_pr_readiness 42 owner/repo || fail "terminal success failed readiness"
[[ "$FULL_LOOP_PR_CHECK_STATUS" == "terminal-success" ]] || fail "terminal success was not classified"
load_state
[[ "$PR_CHECK_STATUS" == "terminal-success" && "$PR_CHECK_HEAD" == "abc123" ]] || fail "terminal success evidence was not persisted"
CHECK_MODE="no-required"
_full_loop_verify_pr_readiness 42 owner/repo || fail "explicit no-required-checks evidence failed readiness"
[[ "$FULL_LOOP_PR_CHECK_STATUS" == "terminal-success" ]] || fail "explicit no-required-checks evidence was not terminal-success"
load_state
[[ "$PR_CHECK_STATUS" == "terminal-success" && "$PR_CHECK_EVIDENCE" == "no-required-checks" ]] || fail "explicit no-required-checks evidence was not persisted"
for CHECK_MODE in api-error changed-wording malformed empty-array; do
	_full_loop_verify_pr_readiness 42 owner/repo && fail "indeterminate required-check response passed readiness: ${CHECK_MODE}"
	[[ "$FULL_LOOP_PR_CHECK_STATUS" == "indeterminate" ]] || fail "indeterminate required-check response was misclassified: ${CHECK_MODE}"
done
load_state
[[ "$PR_CHECK_STATUS" == "indeterminate" && "$PR_CHECK_EVIDENCE" == "unavailable" ]] || fail "indeterminate required-check evidence was not persisted"
CHECK_MODE="success"
POST_CHECK_HEAD="def456"
_full_loop_verify_pr_readiness 42 owner/repo && fail "head drift during check query passed readiness"
load_state
[[ "$PR_CHECK_STATUS" == "indeterminate" && "$PR_CHECK_HEAD" == "def456" ]] || fail "head drift did not invalidate durable success evidence"
POST_CHECK_HEAD="abc123"
if [[ ! -s "$PR_VIEW_CACHE_CONTROL_FILE" ]] || grep -qv '^1$' "$PR_VIEW_CACHE_CONTROL_FILE"; then
	fail "PR readiness reads did not bypass stale PR view caches"
fi
pass "PR readiness reads bypass stale PR view caches"
pass "PR convergence distinguishes pending, failure, no-required, indeterminate, and exact-head success"

EXECUTOR_STATUS="running"
EXECUTOR_PID="$$"
EXECUTOR_IDENTITY="bash"
PHASE_STATUS="running"
printf '%s %s\n' "$RUN_ID" '2020-01-01T00:00:00Z' >"${STATE_DIR}/full-loop.heartbeat"
save_state "task" "fixture task"
stale_status=$(cmd_status --json)
printf '%s' "$stale_status" | jq -e '.executor_status == "stale" and .heartbeat_at == "2020-01-01T00:00:00Z"' >/dev/null || fail "stale heartbeat was reported as live"
pass "executor status requires a fresh run-associated heartbeat"

rm -f "$STATE_FILE"
inactive_status=$(cmd_status --json)
printf '%s' "$inactive_status" | jq -e '.active == false and .executor_status == "inactive"' >/dev/null || fail "inactive status was not valid JSON"
pass "inactive lifecycle status is machine-readable JSON"

printf 'All efficient full-loop orchestration tests passed\n'
