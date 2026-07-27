#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
WRAPPER_SCRIPT="${SCRIPT_DIR}/../pulse-wrapper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
PS_MOCK_OUTPUT=""
GH_ISSUE_LIST_JSON="[]"
GH_ISSUE_LIST_EXIT=0
GH_ISSUE_LIST_ERR=""
GH_PR_LIST_JSON="[]"
GH_PR_CHECK_STATUS_JSON="[]"
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"
	# shellcheck source=/dev/null
	source "$WRAPPER_SCRIPT"

	# Override gh wrapper functions AFTER sourcing pulse-wrapper.sh so these
	# definitions shadow the real implementations.  gh_issue_list and gh_pr_list
	# call _gh_with_timeout which invokes the external `timeout` binary; that
	# spawns a new process which cannot see shell-function stubs.  Overriding at
	# this level bypasses _gh_with_timeout entirely and is the canonical test
	# pattern (see test-large-file-gate-dedup.sh:94-131).
	gh_issue_list() {
		if [[ "$GH_ISSUE_LIST_EXIT" -ne 0 ]]; then
			printf '%s\n' "$GH_ISSUE_LIST_ERR" >&2
			return "$GH_ISSUE_LIST_EXIT"
		fi
		printf '%s\n' "$GH_ISSUE_LIST_JSON"
		return 0
	}

	gh_pr_list() {
		printf '%s\n' "$GH_PR_LIST_JSON"
		return 0
	}

	# GH#21799: gh_pr_check_status_rest_batch replaces statusCheckRollup in
	# count_runnable_candidates.  Return pre-set per-test check status JSON.
	gh_pr_check_status_rest_batch() {
		printf '%s\n' "$GH_PR_CHECK_STATUS_JSON"
		return 0
	}

	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

ps() {
	printf '%s\n' "$PS_MOCK_OUTPUT"
	return 0
}

gh() {
	if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
		printf '%s\n' "$GH_ISSUE_LIST_JSON"
		return 0
	fi

	if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
		printf '%s\n' "$GH_PR_LIST_JSON"
		return 0
	fi

	if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
		printf 'owner\n'
		return 0
	fi

	printf 'unsupported gh invocation in test stub\n' >&2
	return 1
}

run_count() {
	local mock_output="$1"
	PS_MOCK_OUTPUT="$mock_output"
	count_active_workers
	return 0
}

test_counts_workers_and_ignores_supervisor_session() {
	local output
	output=$(run_count "/usr/local/bin/.opencode run --dir /repo-a --title \"Issue #100\" \"/full-loop Implement issue #100\"
/usr/local/bin/.opencode run --dir /repo-b --title \"Issue #101 mentions /pulse\" \"/full-loop Implement issue #101 -- pulse reliability\"
/usr/local/bin/.opencode run --role pulse --session-key supervisor-pulse --dir /repo-a --title \"Supervisor Pulse\" --prompt \"/pulse state includes /full-loop markers\"
/usr/local/bin/.opencode run --dir /repo-c --title \"Routine\" \"/routine check\"")

	if [[ "$output" == "2" ]]; then
		print_result "counts full-loop workers without broad /pulse exclusions" 0
		return 0
	fi

	print_result "counts full-loop workers without broad /pulse exclusions" 1 "Expected 2 active workers, got '${output}'"
	return 0
}

test_returns_zero_when_no_full_loop_workers() {
	local output
	output=$(run_count "/usr/local/bin/.opencode run --role pulse --session-key supervisor-pulse --dir /repo-a --title \"Supervisor Pulse\" --prompt \"/pulse\"
/usr/local/bin/.opencode run --dir /repo-c --title \"Routine\" \"/routine check\"")

	if [[ "$output" == "0" ]]; then
		print_result "returns zero when no matching workers exist" 0
		return 0
	fi

	print_result "returns zero when no matching workers exist" 1 "Expected 0 active workers, got '${output}'"
	return 0
}

test_does_not_exclude_non_supervisor_role_pulse_commands() {
	local output
	output=$(run_count "/usr/local/bin/.opencode run --role pulse --session-key another-session --dir /repo-a --title \"Issue #200\" \"/full-loop Implement issue #200\"")

	if [[ "$output" == "1" ]]; then
		print_result "keeps non-supervisor role pulse commands countable" 0
		return 0
	fi

	print_result "keeps non-supervisor role pulse commands countable" 1 "Expected 1 active worker, got '${output}'"
	return 0
}

# Fix #1 & #2: prefetch_active_workers must use the same filter as count_active_workers
# so the snapshot count is consistent with the global capacity counter and the
# supervisor pulse is excluded via token-boundary matching (not substring grep).
test_prefetch_active_workers_excludes_supervisor() {
	PS_MOCK_OUTPUT="1 00:01 /usr/local/bin/.opencode run --dir /repo-a --title \"Issue #100\" \"/full-loop Implement issue #100\"
2 00:02 /usr/local/bin/.opencode run --role pulse --session-key supervisor-pulse --dir /repo-a --title \"Supervisor Pulse\" --prompt \"/pulse state includes /full-loop markers\"
3 00:03 /usr/local/bin/.opencode run --dir /repo-b --title \"Issue #101\" \"/full-loop Implement issue #101\""

	local prefetch_out
	prefetch_out=$(prefetch_active_workers 2>/dev/null)

	# Supervisor pulse must not appear in the snapshot
	if echo "$prefetch_out" | grep -q 'supervisor-pulse'; then
		print_result "prefetch_active_workers excludes supervisor pulse" 1 \
			"Supervisor pulse appeared in prefetch output"
		return 0
	fi

	# Both worker PIDs (1 and 3) must appear
	if echo "$prefetch_out" | grep -q 'PID 1' && echo "$prefetch_out" | grep -q 'PID 3'; then
		print_result "prefetch_active_workers excludes supervisor pulse" 0
		return 0
	fi

	print_result "prefetch_active_workers excludes supervisor pulse" 1 \
		"Expected PIDs 1 and 3 in prefetch output, got: $(echo "$prefetch_out" | grep 'PID' || echo 'none')"
	return 0
}

test_prefetch_active_workers_consistent_with_count() {
	PS_MOCK_OUTPUT="1 00:01 /usr/local/bin/.opencode run --dir /repo-a --title \"Issue #100\" \"/full-loop Implement issue #100\"
2 00:02 /usr/local/bin/.opencode run --role pulse --session-key supervisor-pulse --dir /repo-a --title \"Supervisor Pulse\" --prompt \"/pulse\"
3 00:03 /usr/local/bin/.opencode run --dir /repo-b --title \"Issue #101\" \"/full-loop Implement issue #101\""

	local count_out prefetch_worker_count
	count_out=$(count_active_workers)
	prefetch_worker_count=$(prefetch_active_workers 2>/dev/null | grep -c '^- PID' 2>/dev/null || true)

	if [[ "$count_out" == "$prefetch_worker_count" ]]; then
		print_result "prefetch_active_workers count matches count_active_workers" 0
		return 0
	fi

	print_result "prefetch_active_workers count matches count_active_workers" 1 \
		"count_active_workers=${count_out}, prefetch worker lines=${prefetch_worker_count}"
	return 0
}

# Fix #3: has_worker_for_repo_issue must use exact --dir matching to prevent
# sibling-path false positives (e.g. /tmp/aidevops matching /tmp/aidevops-tools).
test_has_worker_exact_dir_match_no_sibling_false_positive() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/aidevops","pulse":true}]}\n' \
		>"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	# Sibling repo path — must NOT match
	PS_MOCK_OUTPUT="/usr/local/bin/.opencode run --dir /tmp/aidevops-tools --title \"Issue #42\" \"/full-loop Implement issue #42\""

	if has_worker_for_repo_issue "42" "owner/repo"; then
		print_result "has_worker_for_repo_issue rejects sibling-path match" 1 \
			"Sibling path /tmp/aidevops-tools incorrectly matched repo /tmp/aidevops"
		return 0
	fi

	print_result "has_worker_for_repo_issue rejects sibling-path match" 0
	return 0
}

test_has_worker_exact_dir_match_accepts_correct_path() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/aidevops","pulse":true}]}\n' \
		>"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	# Exact repo path — must match
	PS_MOCK_OUTPUT="/usr/local/bin/.opencode run --dir /tmp/aidevops --title \"Issue #42\" \"/full-loop Implement issue #42\""

	if has_worker_for_repo_issue "42" "owner/repo"; then
		print_result "has_worker_for_repo_issue accepts exact path match" 0
		return 0
	fi

	print_result "has_worker_for_repo_issue accepts exact path match" 1 \
		"Exact path /tmp/aidevops was not matched"
	return 0
}

test_counts_review_issue_pr_workers() {
	# GH#12374: /review-issue-pr workers must be counted alongside /full-loop workers.
	local output
	output=$(run_count "/usr/local/bin/.opencode run --dir /repo-a --title \"Issue #300\" \"/review-issue-pr Review issue #300\"
/usr/local/bin/.opencode run --dir /repo-b --title \"Issue #301\" \"/full-loop Implement issue #301\"
/usr/local/bin/.opencode run --dir /repo-c --title \"Issue #302\" \"/review-issue-pr Review issue #302\"")

	if [[ "$output" == "3" ]]; then
		print_result "counts /review-issue-pr workers alongside /full-loop (GH#12374)" 0
		return 0
	fi

	print_result "counts /review-issue-pr workers alongside /full-loop (GH#12374)" 1 "Expected 3 active workers, got '${output}'"
	return 0
}

test_list_dispatchable_candidates_default_open_except_needs_labels() {
	GH_ISSUE_LIST_EXIT=0
	GH_ISSUE_LIST_ERR=""
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/repo","pulse":true,"maintainer":"maintainer-bot"}]}\n' >"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	GH_ISSUE_LIST_JSON='[
	  {"number":1,"title":"unassigned","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[{"name":"priority:high"}]},
	  {"number":2,"title":"owner assigned","updatedAt":"2026-03-31T00:01:00Z","assignees":[{"login":"owner"}],"labels":[{"name":"quality-debt"}]},
	  {"number":3,"title":"maintainer assigned","updatedAt":"2026-03-31T00:02:00Z","assignees":[{"login":"maintainer-bot"}],"labels":[{"name":"file-size-debt"}]},
	  {"number":4,"title":"runner assigned","updatedAt":"2026-03-31T00:03:00Z","assignees":[{"login":"other-runner"}],"labels":[{"name":"priority:high"}]},
	  {"number":5,"title":"owner queued","updatedAt":"2026-03-31T00:04:00Z","assignees":[{"login":"owner"}],"labels":[{"name":"status:queued"}]},
	  {"number":6,"title":"needs review","updatedAt":"2026-03-31T00:05:00Z","assignees":[],"labels":[{"name":"needs-maintainer-review"}]},
	  {"number":7,"title":"needs docs","updatedAt":"2026-03-31T00:06:00Z","assignees":[],"labels":[{"name":"needs-docs"}]},
	  {"number":8,"title":"supervisor telemetry","updatedAt":"2026-03-31T00:07:00Z","assignees":[],"labels":[{"name":"supervisor"}]},
	  {"number":9,"title":"in progress but runnable","updatedAt":"2026-03-31T00:08:00Z","assignees":[{"login":"owner"}],"labels":[{"name":"status:in-progress"}]},
	  {"number":10,"title":"Infrastructure outage: 2 checks affected","updatedAt":"2026-03-31T00:09:00Z","assignees":[],"labels":[{"name":"infrastructure"},{"name":"source:ci-failure-miner"},{"name":"status:available"}]},
	  {"number":11,"title":"auto dispatch in review","updatedAt":"2026-03-31T00:10:00Z","assignees":[{"login":"owner"}],"labels":[{"name":"status:in-review"},{"name":"auto-dispatch"}]}
	]'
	GH_PR_LIST_JSON='[]'

	local output
	output=$(list_dispatchable_issue_candidates "owner/repo" 100)

	# t2924 filters active status labels at candidate-build time to avoid
	# re-evaluating always-blocked candidates every pulse cycle. auto-dispatch is
	# the exception: it must reach Layer 6 so stale assignment recovery can unstick
	# worker-intended issues left with status:in-review.
	if [[ "$output" == *$'1|unassigned'* && "$output" == *$'2|owner assigned'* && "$output" == *$'3|maintainer assigned'* && "$output" == *$'4|runner assigned'* && "$output" == *$'5|owner queued'* && "$output" == *$'11|auto dispatch in review'* && "$output" != *$'6|needs review'* && "$output" != *$'7|needs docs'* && "$output" != *$'8|supervisor telemetry'* && "$output" != *$'9|in progress but runnable'* && "$output" != *$'10|Infrastructure outage: 2 checks affected'* ]]; then
		print_result "list_dispatchable_issue_candidates lets auto-dispatch active-status issues reach dedup" 0
		return 0
	fi

	print_result "list_dispatchable_issue_candidates lets auto-dispatch active-status issues reach dedup" 1 "Unexpected candidate set: ${output}"
	return 0
}

test_list_dispatchable_candidates_logs_cooldown_skip_not_failure() {
	GH_ISSUE_LIST_JSON='[]'
	GH_ISSUE_LIST_EXIT=75
	GH_ISSUE_LIST_ERR='[gh-cooldown] secondary-rate-limit active=true skip=read expires_at=2026-06-19T00:00:00Z'
	: >"$LOGFILE"

	local output log_text
	output=$(list_dispatchable_issue_candidates "owner/repo" 100)
	log_text=$(<"$LOGFILE")
	GH_ISSUE_LIST_EXIT=0
	GH_ISSUE_LIST_ERR=""

	if [[ -z "$output" && "$log_text" == *"cooldown skip"* && "$log_text" != *"FAILED"* ]]; then
		print_result "list_dispatchable_issue_candidates treats secondary cooldown as expected skip" 0
		return 0
	fi

	print_result "list_dispatchable_issue_candidates treats secondary cooldown as expected skip" 1 \
		"output=${output:-<empty>} log=${log_text:-<empty>}"
	return 0
}

test_count_runnable_candidates_counts_default_open_backlog() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/repo","pulse":true,"maintainer":"maintainer-bot"}]}\n' >"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	GH_ISSUE_LIST_JSON='[
	  {"number":1,"title":"unassigned","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[]},
	  {"number":2,"title":"owner assigned","updatedAt":"2026-03-31T00:01:00Z","assignees":[{"login":"owner"}],"labels":[]},
	  {"number":3,"title":"maintainer assigned","updatedAt":"2026-03-31T00:02:00Z","assignees":[{"login":"maintainer-bot"}],"labels":[]},
	  {"number":4,"title":"runner assigned","updatedAt":"2026-03-31T00:03:00Z","assignees":[{"login":"other-runner"}],"labels":[]}
	]'
	# GH#21799: fixtures use headRefOid + REST check status (no statusCheckRollup).
	# PR 1: CHANGES_REQUESTED → counted. PR 2: APPROVED + FAIL check → counted.
	GH_PR_LIST_JSON='[
	  {"number":1,"reviewDecision":"CHANGES_REQUESTED","headRefOid":"aaa111"},
	  {"number":2,"reviewDecision":"APPROVED","headRefOid":"bbb222"}
	]'
	GH_PR_CHECK_STATUS_JSON='[
	  {"number":1,"status":"PASS"},
	  {"number":2,"status":"FAIL"}
	]'

	local count
	count=$(count_runnable_candidates)

	if [[ "$count" == "6" ]]; then
		print_result "count_runnable_candidates counts default-open backlog" 0
		return 0
	fi

	print_result "count_runnable_candidates counts default-open backlog" 1 "Expected 6 runnable items, got '${count}'"
	return 0
}

test_count_runnable_candidates_keeps_stdout_numeric_with_debug() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/repo","pulse":true,"maintainer":"maintainer-bot"}]}\n' >"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	GH_ISSUE_LIST_JSON='[
	  {"number":1,"title":"unassigned","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[]}
	]'
	# GH#21799: fixtures use headRefOid + REST check status (no statusCheckRollup).
	GH_PR_LIST_JSON='[
	  {"number":1,"reviewDecision":"CHANGES_REQUESTED","headRefOid":"aaa111"}
	]'
	GH_PR_CHECK_STATUS_JSON='[{"number":1,"status":"PASS"}]'

	local count stderr_file
	stderr_file="${TEST_ROOT}/count-runnable-debug.stderr"
	PULSE_DEBUG=1 count=$(count_runnable_candidates 2>"$stderr_file")

	if [[ "$count" == "2" ]] && grep -q 'count_runnable_candidates repo=owner/repo issues=1 prs=1 total=2' "$stderr_file"; then
		print_result "count_runnable_candidates keeps stdout numeric with debug enabled" 0
		return 0
	fi

	print_result "count_runnable_candidates keeps stdout numeric with debug enabled" 1 \
		"Expected numeric stdout 2 with stderr debug log; got count='${count}', stderr='$(tr '\n' '|' <"$stderr_file")'"
	return 0
}

test_count_queued_without_worker_keeps_stdout_numeric_with_debug() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/repo","pulse":true}]}\n' >"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	GH_ISSUE_LIST_JSON='[
	  {"number":11,"assignees":[]}
	]'
	has_worker_for_repo_issue() {
		return 1
	}

	local count stderr_file
	stderr_file="${TEST_ROOT}/count-queued-debug.stderr"
	PULSE_DEBUG=1 count=$(count_queued_without_worker 2>"$stderr_file")
	unset -f has_worker_for_repo_issue

	if [[ "$count" == "1" ]] && grep -q 'count_queued_without_worker repo=owner/repo queued=1' "$stderr_file" && grep -q 'count_queued_without_worker repo=owner/repo issue=11 missing_worker=true' "$stderr_file"; then
		print_result "count_queued_without_worker keeps stdout numeric with debug enabled" 0
		return 0
	fi

	print_result "count_queued_without_worker keeps stdout numeric with debug enabled" 1 \
		"Expected numeric stdout 1 with stderr debug logs; got count='${count}', stderr='$(tr '\n' '|' <"$stderr_file")'"
	return 0
}

test_queue_governor_enters_merge_heavy_at_critical_backlog() {
	STATE_FILE="${HOME}/.aidevops/logs/pulse-state.txt"
	QUEUE_METRICS_FILE="${HOME}/.aidevops/logs/pulse-queue-metrics"
	: >"$STATE_FILE"
	printf '12\n' >"${HOME}/.aidevops/logs/pulse-max-workers"
	PS_MOCK_OUTPUT="/usr/local/bin/.opencode run --dir /repo-a --title \"Issue #100\" \"/full-loop Implement issue #100\"
/usr/local/bin/.opencode run --dir /repo-b --title \"Issue #101\" \"/full-loop Implement issue #101\"
/usr/local/bin/.opencode run --dir /repo-c --title \"Issue #102\" \"/full-loop Implement issue #102\""

	_compute_queue_governor_guidance 180 40 12 8

	local state_text
	state_text=$(<"$STATE_FILE")
	if [[ "$state_text" == *"PULSE_QUEUE_MODE=merge-heavy"* && "$state_text" == *"PULSE_PR_BACKLOG_BAND=critical"* && "$state_text" == *"NEW_ISSUE_DISPATCH_PCT=10"* && "$state_text" == *"PULSE_WORKER_UTILIZATION_PCT=25"* ]]; then
		print_result "queue governor enters merge-heavy at critical backlog" 0
		return 0
	fi

	print_result "queue governor enters merge-heavy at critical backlog" 1 "Unexpected governor output: ${state_text}"
	return 0
}

test_queue_governor_enters_pr_heavy_at_heavy_backlog() {
	STATE_FILE="${HOME}/.aidevops/logs/pulse-state.txt"
	QUEUE_METRICS_FILE="${HOME}/.aidevops/logs/pulse-queue-metrics"
	: >"$STATE_FILE"
	printf 'prev_total_prs=80\nprev_total_issues=110\nprev_ready_prs=4\nprev_failing_prs=10\nprev_recorded_at=1\n' >"$QUEUE_METRICS_FILE"
	printf '8\n' >"${HOME}/.aidevops/logs/pulse-max-workers"
	PS_MOCK_OUTPUT="/usr/local/bin/.opencode run --dir /repo-a --title \"Issue #200\" \"/full-loop Implement issue #200\""

	_compute_queue_governor_guidance 110 120 3 28

	local state_text
	state_text=$(<"$STATE_FILE")
	if [[ "$state_text" == *"PULSE_QUEUE_MODE=pr-heavy"* && "$state_text" == *"PULSE_PR_BACKLOG_BAND=heavy"* && "$state_text" == *"PR_REMEDIATION_FOCUS_PCT=75"* && "$state_text" == *"NEW_ISSUE_DISPATCH_PCT=25"* ]]; then
		print_result "queue governor enters pr-heavy at heavy backlog" 0
		return 0
	fi

	print_result "queue governor enters pr-heavy at heavy backlog" 1 "Unexpected governor output: ${state_text}"
	return 0
}

test_queue_governor_reports_drain_rate_telemetry() {
	STATE_FILE="${HOME}/.aidevops/logs/pulse-state.txt"
	QUEUE_METRICS_FILE="${HOME}/.aidevops/logs/pulse-queue-metrics"
	: >"$STATE_FILE"
	local now_epoch previous_epoch
	now_epoch=$(date +%s)
	previous_epoch=$((now_epoch - 1800))
	printf 'prev_total_prs=120\nprev_total_issues=80\nprev_ready_prs=8\nprev_failing_prs=18\nprev_recorded_at=%s\n' "$previous_epoch" >"$QUEUE_METRICS_FILE"
	printf '6\n' >"${HOME}/.aidevops/logs/pulse-max-workers"
	PS_MOCK_OUTPUT="/usr/local/bin/.opencode run --dir /repo-a --title \"Issue #300\" \"/full-loop Implement issue #300\"
/usr/local/bin/.opencode run --dir /repo-b --title \"Issue #301\" \"/full-loop Implement issue #301\""

	_compute_queue_governor_guidance 114 82 6 16

	local state_text
	state_text=$(<"$STATE_FILE")
	local drain_rate_seen="false"
	if [[ "$state_text" == *"ESTIMATED_MERGE_DRAIN_PER_HOUR=12"* || "$state_text" == *"ESTIMATED_MERGE_DRAIN_PER_HOUR=11"* ]]; then
		drain_rate_seen="true"
	fi
	if [[ "$state_text" == *"OPEN_PR_DRAIN_PER_CYCLE=6"* && "$drain_rate_seen" == "true" && "$state_text" == *"PULSE_ACTIVE_WORKERS=2"* && "$state_text" == *"PULSE_MAX_WORKERS=6"* && "$state_text" == *"PULSE_WORKER_UTILIZATION_PCT=33"* ]]; then
		print_result "queue governor reports drain rate telemetry" 0
		return 0
	fi

	print_result "queue governor reports drain rate telemetry" 1 "Unexpected telemetry output: ${state_text}"
	return 0
}

# ─── dispatch_triage_reviews tests (GH#15655) ────────────────────────────────
#
# These tests exercise the parse → resolve → metadata → dispatch path of
# dispatch_triage_reviews() without external reads or real worker processes.
#
# Key regressions guarded:
#   #15614 — function never called (ordering bug, not tested here)
#   #15617 — grep -P (GNU-only), state-file format mismatch, wrong jq path
#   #15631 — head -n -2 (GNU-only) in model-availability-helper.sh
#   #15636 — ${model_args[@]} unbound variable under set -u

# Stub prompt construction and worker dispatch so these tests exercise the
# candidate parse, repository resolution, metadata propagation, and slot
# accounting path without GitHub reads, sensitive artifacts, or model launch.
# Prompt security and runtime dispatch have dedicated regression suites.
_setup_dispatch_stub() {
	export DISPATCH_LOG_FILE="${TEST_ROOT}/dispatch.log"
	export TRIAGE_CLEANUP_LOG_FILE="${TEST_ROOT}/triage-cleanup.log"
	: >"$DISPATCH_LOG_FILE"
	: >"$TRIAGE_CLEANUP_LOG_FILE"

	local default_snapshot_hash=""
	local default_public_revision=""
	printf -v default_snapshot_hash '%064d' 0
	printf -v default_public_revision '%040d' 0
	TRIAGE_TEST_PROMPT_METADATA="issue||${default_snapshot_hash}|${default_public_revision}"

	_build_triage_review_prompt() {
		local issue_num="$1"
		local repo_slug="$2"
		local repo_path="$3"
		local artifact_dir="${TEST_ROOT}/prompt-artifacts-${issue_num}"
		local prompt_file="${artifact_dir}/prompt-${repo_slug//\//-}-${repo_path##*/}.md"
		mkdir -p "$artifact_dir"
		printf 'test prompt for %s\n' "$issue_num" >"$prompt_file"
		printf '%s|test-content-%s|%s\n' \
			"$prompt_file" "$issue_num" "$TRIAGE_TEST_PROMPT_METADATA"
		return 0
	}

	_triage_cleanup_sensitive_artifact_dir() {
		local artifact_dir="$1"
		printf '%s\n' "$artifact_dir" >>"$TRIAGE_CLEANUP_LOG_FILE"
		rm -rf "$artifact_dir"
		return 0
	}

	_dispatch_triage_review_worker() {
		local issue_num="$1"
		local repo_slug="$2"
		local repo_path="$3"
		printf '%s|%s|%s\n' "$issue_num" "$repo_slug" "$repo_path" \
			>>"$DISPATCH_LOG_FILE"
		return 0
	}

	return 0
}

_make_repos_json() {
	local slug="$1"
	local path="$2"
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"%s","path":"%s","pulse":true}]}\n' \
		"$slug" "$path" >"$repos_json_path"
	printf '%s\n' "$repos_json_path"
	return 0
}

_make_state_file() {
	local state_path="${TEST_ROOT}/pulse-state.txt"
	printf '%s' "$1" >"$state_path"
	printf '%s\n' "$state_path"
	return 0
}

# ── Test 1: slot count decremented for each dispatched triage review ──────────
test_dispatch_triage_reviews_decrements_slot_count() {
	DISPATCH_LOG_FILE="${TEST_ROOT}/dispatch-t1.log"
	: >"$DISPATCH_LOG_FILE"

	local repos_json
	repos_json=$(_make_repos_json "owner/repo" "/tmp/repo")

	local state_file
	state_file=$(_make_state_file "## owner/repo

- Issue #100: Fix login bug [status: **needs-review**] [created: 2026-01-01T00:00:00Z]
- Issue #101: Add dark mode [status: **needs-review**] [created: 2026-01-02T00:00:00Z]
- Issue #102: Already reviewed [status: **reviewed**] [created: 2026-01-03T00:00:00Z]
")

	STATE_FILE="$state_file"
	TRIAGE_STATE_FILE="$state_file"
	# model-availability-helper.sh is not available in test env; resolved_model
	# will be empty, which exercises the no-model branch (same as production
	# when all models are rate-limited).
	local remaining
	remaining=$(dispatch_triage_reviews 5 "$repos_json" 2>/dev/null)

	# 2 needs-review issues dispatched → 5 - 2 = 3 remaining
	if [[ "$remaining" == "3" ]]; then
		print_result "dispatch_triage_reviews decrements slot count for each dispatch" 0
		return 0
	fi

	print_result "dispatch_triage_reviews decrements slot count for each dispatch" 1 \
		"Expected remaining=3, got '${remaining}'"
	return 0
}

# ── Test 2: no stderr errors (catches GNU grep -P / head -n -N regressions) ───
test_dispatch_triage_reviews_no_stderr_errors() {
	local repos_json
	repos_json=$(_make_repos_json "owner/repo" "/tmp/repo")

	local state_file
	state_file=$(_make_state_file "## owner/repo

- Issue #200: Needs triage [status: **needs-review**] [created: 2026-01-01T00:00:00Z]
")

	STATE_FILE="$state_file"
	TRIAGE_STATE_FILE="$state_file"
	local stderr_file="${TEST_ROOT}/triage-stderr.txt"
	dispatch_triage_reviews 3 "$repos_json" 2>"$stderr_file" >/dev/null

	local stderr_content
	stderr_content=$(<"$stderr_file")

	# Fail if any of the known macOS-incompatible error strings appear.
	if [[ "$stderr_content" == *"illegal line count"* ]]; then
		print_result "dispatch_triage_reviews produces no 'illegal line count' stderr (head -n -N)" 1 \
			"stderr: ${stderr_content}"
		return 0
	fi
	if [[ "$stderr_content" == *"unbound variable"* ]]; then
		print_result "dispatch_triage_reviews produces no 'unbound variable' stderr (set -u)" 1 \
			"stderr: ${stderr_content}"
		return 0
	fi
	if [[ "$stderr_content" == *"invalid option"* && "$stderr_content" == *"grep"* ]]; then
		print_result "dispatch_triage_reviews produces no grep -P stderr (GNU-only flag)" 1 \
			"stderr: ${stderr_content}"
		return 0
	fi

	print_result "dispatch_triage_reviews produces no macOS-incompatible stderr errors" 0
	return 0
}

# ── Test 3: returns available unchanged when no needs-review entries ──────────
test_dispatch_triage_reviews_returns_available_when_no_candidates() {
	local repos_json
	repos_json=$(_make_repos_json "owner/repo" "/tmp/repo")

	local state_file
	state_file=$(_make_state_file "## owner/repo

- Issue #300: Already done [status: **reviewed**] [created: 2026-01-01T00:00:00Z]
")

	STATE_FILE="$state_file"
	TRIAGE_STATE_FILE="$state_file"
	local remaining
	remaining=$(dispatch_triage_reviews 4 "$repos_json" 2>/dev/null)

	if [[ "$remaining" == "4" ]]; then
		print_result "dispatch_triage_reviews returns available unchanged when no candidates" 0
		return 0
	fi

	print_result "dispatch_triage_reviews returns available unchanged when no candidates" 1 \
		"Expected remaining=4, got '${remaining}'"
	return 0
}

# ── Test 4: caps dispatches at triage_max=2 even with more candidates ─────────
test_dispatch_triage_reviews_caps_at_triage_max() {
	local repos_json
	repos_json=$(_make_repos_json "owner/repo" "/tmp/repo")

	local state_file
	state_file=$(_make_state_file "## owner/repo

- Issue #400: First [status: **needs-review**] [created: 2026-01-01T00:00:00Z]
- Issue #401: Second [status: **needs-review**] [created: 2026-01-02T00:00:00Z]
- Issue #402: Third [status: **needs-review**] [created: 2026-01-03T00:00:00Z]
")

	STATE_FILE="$state_file"
	TRIAGE_STATE_FILE="$state_file"
	local remaining
	remaining=$(dispatch_triage_reviews 10 "$repos_json" 2>/dev/null)

	# triage_max=2, so only 2 dispatched → 10 - 2 = 8
	if [[ "$remaining" == "8" ]]; then
		print_result "dispatch_triage_reviews caps dispatches at triage_max=2" 0
		return 0
	fi

	print_result "dispatch_triage_reviews caps dispatches at triage_max=2" 1 \
		"Expected remaining=8 (capped at 2 dispatches), got '${remaining}'"
	return 0
}

# ── Test 5: returns available=0 unchanged when no slots ──────────────────────
test_dispatch_triage_reviews_returns_zero_when_no_slots() {
	local repos_json
	repos_json=$(_make_repos_json "owner/repo" "/tmp/repo")

	local state_file
	state_file=$(_make_state_file "## owner/repo

- Issue #500: Needs triage [status: **needs-review**] [created: 2026-01-01T00:00:00Z]
")

	STATE_FILE="$state_file"
	TRIAGE_STATE_FILE="$state_file"
	local remaining
	remaining=$(dispatch_triage_reviews 0 "$repos_json" 2>/dev/null)

	if [[ "$remaining" == "0" ]]; then
		print_result "dispatch_triage_reviews returns 0 when no slots available" 0
		return 0
	fi

	print_result "dispatch_triage_reviews returns 0 when no slots available" 1 \
		"Expected remaining=0, got '${remaining}'"
	return 0
}

# ── Test 6: jq path uses .initialized_repos[] not .[] ────────────────────────
# Regression for #15617 bug 4: wrong jq path caused path lookup to return empty,
# so no workers were dispatched even when candidates existed.
test_dispatch_triage_reviews_resolves_repo_path_via_initialized_repos() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	# Use the correct .initialized_repos[] structure; a flat .[] would fail.
	printf '{"initialized_repos":[{"slug":"owner/myrepo","path":"/tmp/myrepo","pulse":true}]}\n' \
		>"$repos_json_path"

	local state_file
	state_file=$(_make_state_file "## owner/myrepo

- Issue #600: Needs triage [status: **needs-review**] [created: 2026-01-01T00:00:00Z]
")

	STATE_FILE="$state_file"
	TRIAGE_STATE_FILE="$state_file"
	local remaining
	remaining=$(dispatch_triage_reviews 3 "$repos_json_path" 2>/dev/null)

	# Path resolved correctly → 1 dispatch → 3 - 1 = 2
	if [[ "$remaining" == "2" ]]; then
		print_result "dispatch_triage_reviews resolves repo path via .initialized_repos[] (not .[])" 0
		return 0
	fi

	print_result "dispatch_triage_reviews resolves repo path via .initialized_repos[] (not .[])" 1 \
		"Expected remaining=2 (1 dispatch), got '${remaining}' — likely jq path bug"
	return 0
}

# ── Test 7: returns available unchanged when state file is missing ────────────
test_dispatch_triage_reviews_returns_available_when_no_state_file() {
	local repos_json
	repos_json=$(_make_repos_json "owner/repo" "/tmp/repo")

	# Clear TRIAGE_STATE_FILE so the function falls back to deriving from STATE_FILE.
	TRIAGE_STATE_FILE=""
	STATE_FILE="/nonexistent/state-file-that-does-not-exist.txt"
	local remaining
	remaining=$(dispatch_triage_reviews 7 "$repos_json" 2>/dev/null)

	if [[ "$remaining" == "7" ]]; then
		print_result "dispatch_triage_reviews returns available unchanged when state file missing" 0
		return 0
	fi

	print_result "dispatch_triage_reviews returns available unchanged when state file missing" 1 \
		"Expected remaining=7, got '${remaining}'"
	return 0
}

_assert_malformed_triage_metadata_rejected() {
	local case_name="$1"
	local issue_num="$2"
	local metadata="$3"
	local repos_json
	repos_json=$(_make_repos_json "owner/repo" "/tmp/repo")
	local state_file
	state_file=$(_make_state_file "## owner/repo

- Issue #${issue_num}: Malformed metadata [status: **needs-review**] [created: 2026-01-01T00:00:00Z]
")

	TRIAGE_TEST_PROMPT_METADATA="$metadata"
	DISPATCH_LOG_FILE="${TEST_ROOT}/dispatch-malformed-${issue_num}.log"
	: >"$DISPATCH_LOG_FILE"
	: >"$TRIAGE_CLEANUP_LOG_FILE"
	: >"$LOGFILE"
	STATE_FILE="$state_file"
	TRIAGE_STATE_FILE="$state_file"

	local remaining
	remaining=$(dispatch_triage_reviews 3 "$repos_json" 2>/dev/null)
	local artifact_dir="${TEST_ROOT}/prompt-artifacts-${issue_num}"
	local failure=""
	[[ "$remaining" == "3" ]] || failure="${failure} remaining=${remaining};"
	[[ ! -s "$DISPATCH_LOG_FILE" ]] || failure="${failure} worker-dispatched;"
	[[ ! -d "$artifact_dir" ]] || failure="${failure} artifact-not-removed;"
	grep -Fxq "$artifact_dir" "$TRIAGE_CLEANUP_LOG_FILE" 2>/dev/null || failure="${failure} cleanup-not-called;"
	grep -q "reason=triage-item-kind-propagation-failed" "$LOGFILE" 2>/dev/null || failure="${failure} infrastructure-retry-not-recorded;"

	if [[ -z "$failure" ]]; then
		print_result "dispatch_triage_reviews rejects ${case_name}" 0
		return 0
	fi

	print_result "dispatch_triage_reviews rejects ${case_name}" 1 "$failure"
	return 0
}

# ── Test 8: malformed propagated metadata fails closed before dispatch ────────
test_dispatch_triage_reviews_rejects_malformed_metadata() {
	local snapshot_hash=""
	local public_revision=""
	local alternate_revision=""
	local base_revision=""
	printf -v snapshot_hash '%064d' 0
	printf -v public_revision '%040d' 0
	printf -v alternate_revision '%040d' 1
	printf -v base_revision '%040d' 2

	_assert_malformed_triage_metadata_rejected \
		"unknown item kind" 701 "unknown||${snapshot_hash}|${public_revision}"
	_assert_malformed_triage_metadata_rejected \
		"issue metadata carrying a PR revision" 702 \
		"issue|${base_revision}:${public_revision}|${snapshot_hash}|${public_revision}"
	_assert_malformed_triage_metadata_rejected \
		"malformed snapshot hash" 703 "issue||not-a-snapshot|${public_revision}"
	_assert_malformed_triage_metadata_rejected \
		"malformed public revision" 704 "issue||${snapshot_hash}|not-a-revision"
	_assert_malformed_triage_metadata_rejected \
		"malformed PR revision" 705 "pr|not-a-pr-revision|${snapshot_hash}|${public_revision}"
	_assert_malformed_triage_metadata_rejected \
		"PR head disagreeing with public revision" 706 \
		"pr|${base_revision}:${alternate_revision}|${snapshot_hash}|${public_revision}"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	_setup_dispatch_stub

	test_counts_workers_and_ignores_supervisor_session
	test_returns_zero_when_no_full_loop_workers
	test_does_not_exclude_non_supervisor_role_pulse_commands
	test_prefetch_active_workers_excludes_supervisor
	test_prefetch_active_workers_consistent_with_count
	test_has_worker_exact_dir_match_no_sibling_false_positive
	test_has_worker_exact_dir_match_accepts_correct_path
	test_counts_review_issue_pr_workers
	test_list_dispatchable_candidates_default_open_except_needs_labels
	test_list_dispatchable_candidates_logs_cooldown_skip_not_failure
	test_count_runnable_candidates_counts_default_open_backlog
	test_count_runnable_candidates_keeps_stdout_numeric_with_debug
	test_count_queued_without_worker_keeps_stdout_numeric_with_debug
	test_queue_governor_enters_merge_heavy_at_critical_backlog
	test_queue_governor_enters_pr_heavy_at_heavy_backlog
	test_queue_governor_reports_drain_rate_telemetry
	test_dispatch_triage_reviews_decrements_slot_count
	test_dispatch_triage_reviews_no_stderr_errors
	test_dispatch_triage_reviews_returns_available_when_no_candidates
	test_dispatch_triage_reviews_caps_at_triage_max
	test_dispatch_triage_reviews_returns_zero_when_no_slots
	test_dispatch_triage_reviews_resolves_repo_path_via_initialized_repos
	test_dispatch_triage_reviews_returns_available_when_no_state_file
	test_dispatch_triage_reviews_rejects_malformed_metadata

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
