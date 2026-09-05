#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
PULSE_WRAPPER_SCRIPT="${SCRIPT_DIR}/../pulse-wrapper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""
PS_FIXTURE_FILE=""

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
	PS_FIXTURE_FILE="${TEST_ROOT}/ps-fixture.txt"
	export HOME="${TEST_ROOT}/home"
	export AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp"
	mkdir -p "$AIDEVOPS_TEMP_DIR"
	mkdir -p "${HOME}/.aidevops/agents/configs" "${HOME}/.aidevops/logs"
	cat >"${HOME}/.aidevops/agents/configs/aidevops.defaults.jsonc" <<'JSON'
{}
JSON

	export REPOS_JSON="${TEST_ROOT}/repos.json"
	cat >"${REPOS_JSON}" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "marcusquinn/aidevops",
      "path": "/tmp/aidevops"
    }
  ]
}
JSON

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

capture_function_definitions() {
	declare -f "$@" 2>/dev/null || true
	return 0
}

restore_function_definitions() {
	local definitions="$1"
	shift
	unset -f "$@" 2>/dev/null || true
	if [[ -n "$definitions" ]]; then
		eval "$definitions"
	fi
	return 0
}

set_ps_fixture() {
	local content="$1"
	printf '%s\n' "$content" >"$PS_FIXTURE_FILE"
	return 0
}

ps() {
	# t2190: record the exact flags used so tests can assert that
	# worker-detection paths always call ps with unlimited width (`ww`).
	# Must write to a file, not a variable — `ps` is typically invoked in
	# a pipe (e.g. `ps axwwo ... | awk ...`), which runs in a subshell
	# whose variable mutations never propagate back to the parent.
	if [[ -n "${PS_INVOCATION_LOG_FILE:-}" ]]; then
		printf '%s\n' "${1:-}" >>"$PS_INVOCATION_LOG_FILE" 2>/dev/null || true
	fi

	# t2190: canonical path — ps axwwo (unlimited width; works on BSD and procps).
	if [[ "${1:-}" == "axwwo" && "${2:-}" == "pid,stat,etime,command" ]]; then
		cat "$PS_FIXTURE_FILE"
		return 0
	fi
	if [[ "${1:-}" == "axwwo" && "${2:-}" == "pid,etime,command" ]]; then
		cat "$PS_FIXTURE_FILE"
		return 0
	fi
	# Backward compat: pre-t2190 callers used `axo` — intercept so the test
	# still feeds the fixture (but a new t2190 regression test asserts zero
	# bare-`axo` calls; leaving this here only prevents a collateral test
	# breakage if a call site is missed during conversion).
	if [[ "${1:-}" == "axo" && "${2:-}" == "pid,stat,etime,command" ]]; then
		cat "$PS_FIXTURE_FILE"
		return 0
	fi
	if [[ "${1:-}" == "axo" && "${2:-}" == "pid,etime,command" ]]; then
		cat "$PS_FIXTURE_FILE"
		return 0
	fi
	command ps "$@"
	return 0
}

set_dedup_helper_fixture() {
	local has_open_pr_exit="$1"
	local has_open_pr_output="${2:-}"

	cat >"${TEST_ROOT}/dispatch-dedup-helper.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

command_name="\${1:-}"

case "\$command_name" in
is-duplicate)
	exit 1
	;;
has-open-pr)
	if [[ "${has_open_pr_exit}" -eq 0 ]]; then
		if [[ -n "${has_open_pr_output}" ]]; then
			printf '%s\n' "${has_open_pr_output}"
		fi
		exit 0
	fi
	exit 1
	;;
*)
	exit 1
	;;
esac
EOF

	chmod +x "${TEST_ROOT}/dispatch-dedup-helper.sh"
	return 0
}

set_dispatch_claim_helper_fixture() {
	cat >"${TEST_ROOT}/dispatch-claim-helper.sh" <<'FIXTURE'
#!/usr/bin/env bash
exit 0
FIXTURE
	chmod +x "${TEST_ROOT}/dispatch-claim-helper.sh"
	return 0
}

set_successful_dispatch_helpers_fixture() {
	cat >"${TEST_ROOT}/dispatch-dedup-helper.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
	claim)
		printf 'CLAIMED comment_id=9001 lease_token=fixture-lease-token device=fixture-device\n'
		exit 0
		;;
	*) exit 1 ;;
esac
FIXTURE
	cat >"${TEST_ROOT}/dispatch-ledger-helper.sh" <<'FIXTURE'
#!/usr/bin/env bash
case "${1:-}" in
check-issue) exit 1 ;;
*) exit 0 ;;
esac
FIXTURE
	chmod +x "${TEST_ROOT}/dispatch-dedup-helper.sh" "${TEST_ROOT}/dispatch-ledger-helper.sh"
	set_dispatch_claim_helper_fixture
	return 0
}

set_successful_dispatch_function_stubs() {
	FIXTURE_ISSUE_LOCKED=false
	gh_issue_view() {
		local issue_number="$1"
		printf '{"number":%s,"state":"OPEN","title":"Issue #%s: fixture dispatch","labels":[{"name":"tier:simple"}],"assignees":[],"body":"## Worker Guidance","author":{"login":"testuser"}}\n' \
			"${issue_number}" "${issue_number}"
		return 0
	}
	export -f gh_issue_view
	gh() {
		if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
			printf 'OPEN\n'
			return 0
		fi
		if [[ "${1:-}" == "issue" && "${2:-}" == "lock" ]]; then
			FIXTURE_ISSUE_LOCKED=true
			return 0
		fi
		if [[ "${1:-}" == "api" && "${2:-}" == *"/events?per_page=100" ]]; then
			printf '[[]]\n'
			return 0
		fi
		if [[ "${1:-}" == "api" && "${2:-}" == repos/*/issues/* ]]; then
			if [[ " $* " == *" --jq "* ]]; then
				if [[ " $* " == *".locked"* ]]; then
					printf '%s\n' "${FIXTURE_ISSUE_LOCKED}"
					return 0
				fi
				printf 'OWNER|User|testuser|false\n'
				return 0
			fi
			if [[ "${2##*/}" =~ ^[0-9]+$ ]]; then
				printf '{"number":%s,"state":"open","locked":%s,"author_association":"OWNER","user":{"type":"User","login":"testuser"},"labels":[{"name":"tier:simple"}]}\n' \
					"${2##*/}" "${FIXTURE_ISSUE_LOCKED}"
			else
				printf '{}\n'
			fi
			return 0
		fi
		return 0
	}
	export -f gh
	is_blocked_by_unresolved() { return 1; }
	_check_nmr_approval_gate() { return 1; }
	set_issue_status() { return 0; }
	_dlw_precreate_worktree() {
		local issue_number="$1"
		_DLW_WORKTREE_PATH="${TEST_ROOT}/worktree-${issue_number}"
		_DLW_WORKTREE_BRANCH="feature/test-gh${issue_number}"
		_DLW_WORKTREE_REUSED=0
		mkdir -p "$_DLW_WORKTREE_PATH"
		return 0
	}
	_dispatch_registered_worktree_count() {
		printf '0\n'
		return 0
	}
	return 0
}

test_counts_plain_and_dot_prefixed_opencode_workers() {
	# Line 125: supervisor /pulse — excluded by standalone /pulse filter
	# Line 126: worker whose session-key contains /pulse-related (not standalone) — must be counted
	set_ps_fixture "123 S 00:10 opencode run --dir /tmp/aidevops --title Issue #4342 \"/full-loop Implement issue #4342\"
124 S 00:11 /Users/test/.opencode/bin/opencode run --dir /tmp/aidevops --title Issue #4343 \"/full-loop Implement issue #4343\"
125 S 00:20 opencode run --dir /tmp/aidevops --title Supervisor Pulse \"/pulse\"
126 S 00:05 opencode run --dir /tmp/aidevops --session-key issue-4344 --title Issue #4344 \"/full-loop Implement issue #4344 -- fix /pulse-related bug\""

	local count
	count=$(count_active_workers)
	# Lines 123, 124, 126 are workers; line 125 is the supervisor /pulse (excluded)
	if [[ "$count" != "3" ]]; then
		print_result "count_active_workers excludes supervisor /pulse but counts worker with /pulse in args" 1 "Expected 3, got ${count}"
		return 0
	fi

	print_result "count_active_workers excludes supervisor /pulse but counts worker with /pulse in args" 0
	return 0
}

test_deduplicates_process_chain_to_one_logical_worker() {
	# t5072: A single opencode worker spawns a 3-process chain:
	#   bash sandbox-exec-helper.sh run ... -- opencode run ...  (top-level launcher)
	#   node /opt/homebrew/bin/opencode run ...                  (node child)
	#   /path/to/.opencode run ...                               (binary grandchild)
	# All three contain /full-loop and opencode — only the launcher must be counted.
	set_ps_fixture "200 S 00:30 bash /home/user/.aidevops/agents/scripts/sandbox-exec-helper.sh run --timeout 3600 --allow-secret-io -- /opt/homebrew/bin/opencode run \"/full-loop Implement issue #5072\" --dir /tmp/aidevops --title Issue #5072
201 S 00:30 node /opt/homebrew/bin/opencode run \"/full-loop Implement issue #5072\" --dir /tmp/aidevops --title Issue #5072
202 S 00:30 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #5072\" --dir /tmp/aidevops --title Issue #5072"

	local count
	count=$(count_active_workers)
	# Only line 200 (sandbox launcher) should be counted; 201 and 202 are child processes
	if [[ "$count" != "1" ]]; then
		print_result "count_active_workers deduplicates 3-process chain to 1 logical worker" 1 "Expected 1, got ${count} (process chain not deduplicated)"
		return 0
	fi

	print_result "count_active_workers deduplicates 3-process chain to 1 logical worker" 0
	return 0
}

test_deduplicates_multiple_workers_with_process_chains() {
	# t5072: Two logical workers, each spawning a 3-process chain = 6 OS processes.
	# count_active_workers must return 2, not 6.
	set_ps_fixture "300 S 01:00 bash /home/user/.aidevops/agents/scripts/sandbox-exec-helper.sh run --timeout 3600 --allow-secret-io -- /opt/homebrew/bin/opencode run \"/full-loop Implement issue #5001\" --dir /tmp/aidevops --title Issue #5001
301 S 01:00 node /opt/homebrew/bin/opencode run \"/full-loop Implement issue #5001\" --dir /tmp/aidevops --title Issue #5001
302 S 01:00 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #5001\" --dir /tmp/aidevops --title Issue #5001
310 S 00:20 bash /home/user/.aidevops/agents/scripts/sandbox-exec-helper.sh run --timeout 3600 --allow-secret-io -- /opt/homebrew/bin/opencode run \"/full-loop Implement issue #5002\" --dir /tmp/aidevops --title Issue #5002
311 S 00:20 node /opt/homebrew/bin/opencode run \"/full-loop Implement issue #5002\" --dir /tmp/aidevops --title Issue #5002
312 S 00:20 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #5002\" --dir /tmp/aidevops --title Issue #5002"

	local count
	count=$(count_active_workers)
	if [[ "$count" != "2" ]]; then
		print_result "count_active_workers counts 2 logical workers from 6 process-chain entries" 1 "Expected 2, got ${count}"
		return 0
	fi

	print_result "count_active_workers counts 2 logical workers from 6 process-chain entries" 0
	return 0
}

test_repo_issue_detection_uses_filtered_worker_list() {
	set_ps_fixture "211 S 00:31 opencode run --dir /tmp/aidevops --session-key issue-4342 --title Issue #4342: fix \"/full-loop Implement issue #4342\"
212 S 00:31 opencode run --dir /tmp/other --session-key issue-4342 --title Issue #4342: other \"/full-loop Implement issue #4342\"
213 S 00:05 opencode run --dir /tmp/aidevops --title Supervisor Pulse \"/pulse\"
214 S 00:12 opencode run --dir /tmp/aidevops-tools --session-key issue-4342 --title Issue #4342: tools \"/full-loop Implement issue #4342\""

	if ! has_worker_for_repo_issue "4342" "marcusquinn/aidevops"; then
		print_result "has_worker_for_repo_issue matches scoped worker process" 1 "Expected worker match for repo issue"
		return 0
	fi

	if has_worker_for_repo_issue "9999" "marcusquinn/aidevops"; then
		print_result "has_worker_for_repo_issue rejects unrelated issues" 1 "Expected no worker match for issue 9999"
		return 0
	fi

	# Line 214 uses /tmp/aidevops-tools — a prefix of /tmp/aidevops — must NOT match
	# Add a second repo entry for aidevops-tools to verify exact path matching
	cat >"${REPOS_JSON}" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "marcusquinn/aidevops",
      "path": "/tmp/aidevops"
    },
    {
      "slug": "marcusquinn/aidevops-tools",
      "path": "/tmp/aidevops-tools"
    }
  ]
}
JSON
	# Worker 214 is for aidevops-tools, not aidevops — should not count for aidevops
	local count_aidevops
	count_aidevops=$(list_active_worker_processes | awk -v path="/tmp/aidevops" '
		BEGIN { esc = path; gsub(/[][(){}.^$*+?|\\]/, "\\\\&", esc) }
		$0 ~ ("--dir[[:space:]]+" esc "([[:space:]]|$)") { count++ }
		END { print count + 0 }
	')
	if [[ "$count_aidevops" != "1" ]]; then
		print_result "has_worker_for_repo_issue does not match prefix-sibling repo path" 1 "Expected 1 match for /tmp/aidevops, got ${count_aidevops}"
		return 0
	fi

	print_result "has_worker_for_repo_issue matches scoped worker process" 0
	print_result "has_worker_for_repo_issue rejects unrelated issues" 0
	print_result "has_worker_for_repo_issue does not match prefix-sibling repo path" 0
	return 0
}

test_excludes_zombie_and_stopped_processes() {
	# GH#6413: Zombie (Z) and stopped (T) processes must be excluded from
	# active worker counts. SN (sleeping, low priority) processes that are
	# NOT zombie/stopped should still be counted — SN is a valid running state.
	set_ps_fixture "400 S 00:10 opencode run --dir /tmp/aidevops --title Issue #4400 \"/full-loop Implement issue #4400\"
401 Z 00:30 opencode run --dir /tmp/aidevops --title Issue #4401 \"/full-loop Implement issue #4401\"
402 SN 00:45 opencode run --dir /tmp/aidevops --title Issue #4402 \"/full-loop Implement issue #4402\"
403 T 01:00 opencode run --dir /tmp/aidevops --title Issue #4403 \"/full-loop Implement issue #4403\"
404 Ss 00:05 opencode run --dir /tmp/aidevops --title Issue #4404 \"/full-loop Implement issue #4404\"
405 Zs 00:15 opencode run --dir /tmp/aidevops --title Issue #4405 \"/full-loop Implement issue #4405\"
406 TN 00:20 opencode run --dir /tmp/aidevops --title Issue #4406 \"/full-loop Implement issue #4406\""

	local count
	count=$(count_active_workers)
	# Lines 400 (S), 402 (SN), 404 (Ss) are valid running states — counted
	# Lines 401 (Z), 403 (T), 405 (Zs), 406 (TN) are zombie/stopped — excluded
	if [[ "$count" != "3" ]]; then
		print_result "count_active_workers excludes zombie and stopped processes" 1 "Expected 3, got ${count}"
		return 0
	fi

	print_result "count_active_workers excludes zombie and stopped processes" 0
	return 0
}

test_has_worker_for_repo_issue_session_key_fallback() {
	# GH#6453: When get_repo_path_by_slug returns empty (slug not in repos.json),
	# has_worker_for_repo_issue must fall back to matching by --session-key.
	# This prevents false-negatives that cause the backfill cycle to re-dispatch
	# already-running workers.
	local original_repos_json="$REPOS_JSON"

	# Use a repos.json that does NOT contain the slug being tested
	cat >"${REPOS_JSON}" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "marcusquinn/other-repo",
      "path": "/tmp/other-repo"
    }
  ]
}
JSON

	# Worker process with --session-key issue-6426 but slug not in repos.json
	set_ps_fixture "500 S 00:15 bash /home/user/.aidevops/agents/scripts/sandbox-exec-helper.sh run --timeout 3600 --allow-secret-io -- opencode run \"/full-loop Implement issue #6426\" --dir /tmp/aidevops --session-key issue-6426 --title Issue #6426"

	# Should detect the worker via session-key fallback even though slug is not in repos.json
	if ! has_worker_for_repo_issue "6426" "marcusquinn/aidevops"; then
		REPOS_JSON="$original_repos_json"
		print_result "has_worker_for_repo_issue session-key fallback detects worker when slug not in repos.json" 1 "Expected worker match via session-key fallback"
		return 0
	fi

	# Should not match a different issue number
	if has_worker_for_repo_issue "9999" "marcusquinn/aidevops"; then
		REPOS_JSON="$original_repos_json"
		print_result "has_worker_for_repo_issue session-key fallback rejects wrong issue number" 1 "Expected no match for issue 9999"
		return 0
	fi

	REPOS_JSON="$original_repos_json"
	print_result "has_worker_for_repo_issue session-key fallback detects worker when slug not in repos.json" 0
	print_result "has_worker_for_repo_issue session-key fallback rejects wrong issue number" 0
	return 0
}

test_counts_standalone_opencode_binary_workers() {
	# GH#12361: Workers dispatched via headless-runtime-helper.sh without
	# sandbox-exec-helper.sh run as /bin/.opencode processes directly.
	# These must be counted as active workers, not excluded.
	set_ps_fixture "600 S 00:15 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #12361\" --dir /tmp/aidevops --session-key issue-12361 --title Issue #12361
601 S 00:20 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #12362\" --dir /tmp/aidevops --session-key issue-12362 --title Issue #12362
602 S 00:25 opencode run --dir /tmp/aidevops --title Issue #12363 \"/full-loop Implement issue #12363\""

	local count
	count=$(count_active_workers)
	# All three are standalone workers (no sandbox launcher) — all must be counted
	if [[ "$count" != "3" ]]; then
		print_result "count_active_workers counts standalone /bin/.opencode workers (GH#12361)" 1 "Expected 3, got ${count}"
		return 0
	fi

	print_result "count_active_workers counts standalone /bin/.opencode workers (GH#12361)" 0
	return 0
}

test_counts_headless_runtime_helper_wrapper_without_child_process() {
	# GH#14944: The live worker may be visible only as the outer
	# headless-runtime-helper.sh wrapper before/without an opencode child in ps.
	set_ps_fixture "650 S 00:18 bash /Users/test/.aidevops/agents/scripts/headless-runtime-helper.sh run --role worker --session-key issue-14944 --dir /tmp/aidevops --title Issue #14944 --prompt-file /tmp/pulse-14944.prompt"

	local count output
	count=$(count_active_workers)
	if [[ "$count" != "1" ]]; then
		print_result "count_active_workers counts wrapper-only headless-runtime-helper worker (GH#14944)" 1 "Expected 1, got ${count}"
		return 0
	fi

	output=$(list_active_worker_processes)
	if ! echo "$output" | grep -q "^650 "; then
		print_result "count_active_workers counts wrapper-only headless-runtime-helper worker (GH#14944)" 1 "Expected wrapper PID 650 in output"
		return 0
	fi

	print_result "count_active_workers counts wrapper-only headless-runtime-helper worker (GH#14944)" 0
	return 0
}

test_deduplicates_headless_runtime_helper_wrapper_with_child_processes() {
	# GH#14944: Wrapper + sandbox + opencode child chain should count as one
	# logical worker, keeping the outer headless-runtime-helper wrapper PID.
	set_ps_fixture "660 S 00:20 bash /Users/test/.aidevops/agents/scripts/headless-runtime-helper.sh run --role worker --session-key issue-14944 --dir /tmp/aidevops --title Issue #14944 --prompt-file /tmp/pulse-14944.prompt
661 S 00:19 bash /Users/test/.aidevops/agents/scripts/sandbox-exec-helper.sh run --timeout 3600 --allow-secret-io -- /opt/homebrew/bin/opencode run \"/full-loop Implement issue #14944\" --dir /tmp/aidevops --session-key issue-14944 --title Issue #14944
662 S 00:19 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #14944\" --dir /tmp/aidevops --session-key issue-14944 --title Issue #14944"

	local count output
	count=$(count_active_workers)
	if [[ "$count" != "1" ]]; then
		print_result "count_active_workers deduplicates headless-runtime-helper wrapper with children (GH#14944)" 1 "Expected 1, got ${count}"
		return 0
	fi

	output=$(list_active_worker_processes)
	if ! echo "$output" | grep -q "^660 "; then
		print_result "count_active_workers deduplicates headless-runtime-helper wrapper with children (GH#14944)" 1 "Expected wrapper PID 660 in output"
		return 0
	fi
	if echo "$output" | grep -q "^661 \|^662 "; then
		print_result "count_active_workers deduplicates headless-runtime-helper wrapper with children (GH#14944)" 1 "Expected child PIDs 661/662 to be deduplicated away"
		return 0
	fi

	print_result "count_active_workers deduplicates headless-runtime-helper wrapper with children (GH#14944)" 0
	return 0
}

test_deduplicates_chain_but_keeps_standalone_opencode_binary() {
	# GH#12361: Mix of sandbox-launched chain and standalone /bin/.opencode worker.
	# The chain (issue #5001) should deduplicate to 1; the standalone (issue #12361)
	# should be kept — total 2 logical workers.
	set_ps_fixture "700 S 01:00 bash /home/user/.aidevops/agents/scripts/sandbox-exec-helper.sh run --timeout 3600 --allow-secret-io -- /opt/homebrew/bin/opencode run \"/full-loop Implement issue #5001\" --dir /tmp/aidevops --title Issue #5001
701 S 01:00 node /opt/homebrew/bin/opencode run \"/full-loop Implement issue #5001\" --dir /tmp/aidevops --title Issue #5001
702 S 01:00 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #5001\" --dir /tmp/aidevops --title Issue #5001
710 S 00:15 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #12361\" --dir /tmp/aidevops --session-key issue-12361 --title Issue #12361"

	local count
	count=$(count_active_workers)
	if [[ "$count" != "2" ]]; then
		print_result "count_active_workers deduplicates chain but keeps standalone /bin/.opencode worker" 1 "Expected 2, got ${count}"
		return 0
	fi

	# Verify the sandbox launcher (PID 700) is kept for the chain, not the binary child
	local output
	output=$(list_active_worker_processes)
	if ! echo "$output" | grep -q "^700 "; then
		print_result "count_active_workers deduplicates chain but keeps standalone /bin/.opencode worker" 1 "Expected sandbox launcher PID 700 in output"
		return 0
	fi
	# Verify the standalone worker (PID 710) is kept
	if ! echo "$output" | grep -q "^710 "; then
		print_result "count_active_workers deduplicates chain but keeps standalone /bin/.opencode worker" 1 "Expected standalone worker PID 710 in output"
		return 0
	fi

	print_result "count_active_workers deduplicates chain but keeps standalone /bin/.opencode worker" 0
	return 0
}

test_counts_review_issue_pr_workers() {
	# GH#12374: Workers running /review-issue-pr must be counted by
	# count_active_workers, not just /full-loop workers.
	set_ps_fixture "800 S 00:10 opencode run --dir /tmp/aidevops --title Issue #9001 \"/review-issue-pr Review issue #9001\"
801 S 00:20 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #9002\" --dir /tmp/aidevops --session-key issue-9002 --title Issue #9002
802 S 00:15 opencode run --dir /tmp/aidevops --title Issue #9003 \"/review-issue-pr Review issue #9003\""

	local count
	count=$(count_active_workers)
	# 2 review-issue-pr + 1 full-loop = 3 workers
	if [[ "$count" != "3" ]]; then
		print_result "count_active_workers counts /review-issue-pr workers (GH#12374)" 1 "Expected 3, got ${count}"
		return 0
	fi

	print_result "count_active_workers counts /review-issue-pr workers (GH#12374)" 0
	return 0
}

test_review_issue_pr_session_key_fallback_dedup() {
	# GH#12374 CodeRabbit feedback: /review-issue-pr workers may not carry
	# "Issue #NNN" markers but DO have --session-key issue-NNN. The dedup_key
	# extraction must fall back to --session-key so these workers are
	# deduplicated and counted correctly.
	set_ps_fixture "900 S 00:10 opencode run --dir /tmp/aidevops --session-key issue-9010 --title review-9010 \"/review-issue-pr 9010\"
901 S 00:10 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run --dir /tmp/aidevops --session-key issue-9010 --title review-9010 \"/review-issue-pr 9010\"
902 S 00:15 opencode run --dir /tmp/aidevops --session-key issue-9011 --title review-9011 \"/review-issue-pr 9011\""

	local count
	count=$(count_active_workers)
	# PIDs 900+901 share session-key issue-9010 + same --dir → deduplicate to 1
	# PID 902 is a separate worker (issue-9011) → 1
	# Total: 2
	if [[ "$count" != "2" ]]; then
		print_result "review-issue-pr session-key fallback deduplicates correctly (GH#12374)" 1 "Expected 2, got ${count}"
		return 0
	fi

	print_result "review-issue-pr session-key fallback deduplicates correctly (GH#12374)" 0
	return 0
}

test_review_thread_response_session_key_fallback_dedup() {
	# GH#24625: review-thread response workers use pr-review-thread-response
	# session keys. The dedup key extraction must fall back to that key and
	# preserve only the trailing PR number, even when the repo slug contains digits.
	set_ps_fixture "950 S 00:10 opencode run --dir /tmp/repo --session-key pr-review-thread-response-org2--repo-206 --title PR #206 \"/full-loop respond\"
951 S 00:11 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run --dir /tmp/repo --session-key pr-review-thread-response-org2--repo-206 --title PR #206 \"/full-loop respond\"
952 S 00:09 opencode run --dir /tmp/repo --session-key pr-review-thread-response-org2--repo-207 --title PR #207 \"/full-loop respond\""

	local count output line_count
	count=$(count_active_workers)
	if [[ "$count" != "2" ]]; then
		print_result "review-thread response session-key fallback deduplicates correctly (GH#24625)" 1 "Expected 2, got ${count}"
		return 0
	fi

	output=$(list_active_worker_processes)
	line_count=$(printf '%s\n' "$output" | awk 'END { print NR }')
	if [[ "$line_count" != "2" ]]; then
		print_result "review-thread response session-key fallback deduplicates correctly (GH#24625)" 1 "Expected 2 logical workers in output, got ${line_count}: ${output}"
		return 0
	fi
	if ! printf '%s\n' "$output" | grep -q "^950 "; then
		print_result "review-thread response session-key fallback deduplicates correctly (GH#24625)" 1 "Expected PID 950 in output"
		return 0
	fi
	if printf '%s\n' "$output" | grep -q "^951 "; then
		print_result "review-thread response session-key fallback deduplicates correctly (GH#24625)" 1 "Expected duplicate PID 951 to be deduplicated away"
		return 0
	fi
	if ! printf '%s\n' "$output" | grep -q "^952 "; then
		print_result "review-thread response session-key fallback deduplicates correctly (GH#24625)" 1 "Expected PID 952 in output"
		return 0
	fi

	print_result "review-thread response session-key fallback deduplicates correctly (GH#24625)" 0
	return 0
}

test_worker_title_prefixes_issue_number() {
	local title
	title=$(_dlw_build_worker_title "21994" "t3237: standardize session title guidance" "Issue #21994")

	if [[ "$title" != "Issue #21994: t3237: standardize session title guidance" ]]; then
		print_result "worker session title prefixes issue number" 1 "Expected issue-prefixed title, got '${title}'"
		return 0
	fi

	title=$(_dlw_build_worker_title "21994" "Issue #21994: existing prefix" "fallback")
	if [[ "$title" != "Issue #21994: existing prefix" ]]; then
		print_result "worker session title prefixes issue number" 1 "Expected existing prefix to be preserved, got '${title}'"
		return 0
	fi

	print_result "worker session title prefixes issue number" 0
	return 0
}

test_check_dispatch_dedup_treats_merged_pr_as_duplicate() {
	local original_script_dir="$SCRIPT_DIR"
	SCRIPT_DIR="$TEST_ROOT"

	set_ps_fixture ""
	set_dedup_helper_fixture 0 'merged PR #1145 references issue #4527 via "closes" keyword'

	if check_dispatch_dedup "4527" "marcusquinn/aidevops" "Issue #4527: prevent redispatch" "t4527: prevent redispatch"; then
		SCRIPT_DIR="$original_script_dir"
		print_result "check_dispatch_dedup skips dispatch when merged PR exists" 0
		return 0
	fi

	SCRIPT_DIR="$original_script_dir"
	print_result "check_dispatch_dedup skips dispatch when merged PR exists" 1 "Expected dedup check to block merged issue"
	return 0
}

test_dispatch_with_dedup_blocks_when_duplicate() {
	local original_script_dir="$SCRIPT_DIR"
	SCRIPT_DIR="$TEST_ROOT"

	set_ps_fixture ""
	# Dedup helper returns 0 for has-open-pr → duplicate detected → check_dispatch_dedup returns 0
	set_dedup_helper_fixture 0 'merged PR #1145 references issue #9999 via "closes" keyword'

	local dispatch_rc=0
	dispatch_with_dedup "9999" "marcusquinn/aidevops" "Issue #9999: test dedup" "t9999: test dedup" \
		"testuser" "/tmp/aidevops" "/full-loop test" || dispatch_rc=$?

	SCRIPT_DIR="$original_script_dir"

	if [[ "$dispatch_rc" -eq 1 ]]; then
		print_result "dispatch_with_dedup blocks when dedup detects duplicate (GH#12436)" 0
		return 0
	fi

	print_result "dispatch_with_dedup blocks when dedup detects duplicate (GH#12436)" 1 \
		"Expected exit 1 (blocked), got ${dispatch_rc}"
	return 0
}

test_dispatch_with_dedup_fails_closed_when_issue_metadata_missing() {
	local original_script_dir="$SCRIPT_DIR"
	local original_function_definitions
	original_function_definitions=$(capture_function_definitions gh_issue_view)
	SCRIPT_DIR="$TEST_ROOT"

	set_ps_fixture ""

	# Stub the production metadata wrapper to fail so dispatch stays fail closed.
	gh_issue_view() {
		return 1
	}
	export -f gh_issue_view

	local dispatch_rc=0
	dispatch_with_dedup "7777" "marcusquinn/aidevops" "Issue #7777: fail-closed" "t7777: fail-closed" \
		"testuser" "/tmp/aidevops" "/full-loop test" || dispatch_rc=$?

	SCRIPT_DIR="$original_script_dir"
	restore_function_definitions "$original_function_definitions" gh_issue_view

	if [[ "$dispatch_rc" -eq 1 ]]; then
		print_result "dispatch_with_dedup fails closed when issue metadata lookup fails (GH#14409)" 0
		return 0
	fi

	print_result "dispatch_with_dedup fails closed when issue metadata lookup fails (GH#14409)" 1 \
		"Expected exit 1 (blocked), got ${dispatch_rc}"
	return 0
}

test_dispatch_with_dedup_proceeds_when_no_duplicate() {
	local original_script_dir="$SCRIPT_DIR"
	local original_function_definitions
	original_function_definitions=$(capture_function_definitions gh gh_issue_view is_blocked_by_unresolved _check_nmr_approval_gate set_issue_status _dlw_precreate_worktree _dispatch_registered_worktree_count)
	SCRIPT_DIR="$TEST_ROOT"

	set_ps_fixture ""

	set_successful_dispatch_helpers_fixture

	# Create a no-op HEADLESS_RUNTIME_HELPER stub so the worker launch succeeds
	local original_helper="$HEADLESS_RUNTIME_HELPER"
	HEADLESS_RUNTIME_HELPER="${TEST_ROOT}/headless-stub.sh"
	cat >"$HEADLESS_RUNTIME_HELPER" <<'STUB'
#!/usr/bin/env bash
# Stub: do nothing, exit immediately
exit 0
STUB
	chmod +x "$HEADLESS_RUNTIME_HELPER"

	set_successful_dispatch_function_stubs

	local dispatch_rc=0 pre_runtime_failure=""
	dispatch_with_dedup "8888" "marcusquinn/aidevops" "Issue #8888: test pass" "t8888: test pass" \
		"testuser" "/tmp/aidevops" "/full-loop test" || dispatch_rc=$?
	pre_runtime_failure="${_DLW_LAST_PRE_RUNTIME_FAILURE:-}"

	# Restore
	HEADLESS_RUNTIME_HELPER="$original_helper"
	SCRIPT_DIR="$original_script_dir"
	restore_function_definitions "$original_function_definitions" gh gh_issue_view is_blocked_by_unresolved _check_nmr_approval_gate set_issue_status _dlw_precreate_worktree _dispatch_registered_worktree_count

	if [[ "$dispatch_rc" -eq 0 ]]; then
		print_result "dispatch_with_dedup proceeds when no duplicate detected (GH#12436)" 0
		return 0
	fi

	print_result "dispatch_with_dedup proceeds when no duplicate detected (GH#12436)" 1 \
		"Expected exit 0 (dispatched), got ${dispatch_rc}; pre-runtime failure=${pre_runtime_failure:-none}"
	return 0
}

test_dispatch_with_dedup_detaches_worker_stdio() {
	local original_script_dir="$SCRIPT_DIR"
	local original_helper="$HEADLESS_RUNTIME_HELPER"
	local original_function_definitions
	original_function_definitions=$(capture_function_definitions gh gh_issue_view is_blocked_by_unresolved _check_nmr_approval_gate set_issue_status _dlw_precreate_worktree _dispatch_registered_worktree_count)
	local stdin_capture="${TEST_ROOT}/worker-stdin.txt"
	local issue_log="" fallback_log=""
	issue_log=$(aidevops_pulse_worker_log_path "marcusquinn/aidevops" "8890")
	fallback_log=$(aidevops_pulse_worker_log_fallback_path "8890")
	SCRIPT_DIR="$TEST_ROOT"

	rm -f "$stdin_capture" "$issue_log" "$fallback_log"
	set_ps_fixture ""
	set_successful_dispatch_helpers_fixture

	HEADLESS_RUNTIME_HELPER="${TEST_ROOT}/headless-stdin-stub.sh"
	cat >"$HEADLESS_RUNTIME_HELPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cat >"${stdin_capture}"
printf 'stub worker output\n'
exit 0
EOF
	chmod +x "$HEADLESS_RUNTIME_HELPER"

	set_successful_dispatch_function_stubs

	local dispatch_rc=0 pre_runtime_failure=""
	dispatch_with_dedup "8890" "marcusquinn/aidevops" "Issue #8890: stdio detach" "t8890: stdio detach" \
		"testuser" "/tmp/aidevops" "/full-loop test" <<<"candidate-stream-must-not-leak" || dispatch_rc=$?
	pre_runtime_failure="${_DLW_LAST_PRE_RUNTIME_FAILURE:-}"

	local stdin_contents=""
	if [[ -f "$stdin_capture" ]]; then
		stdin_contents=$(tr '\n' ' ' <"$stdin_capture")
	fi
	local issue_log_contents=""
	if [[ -f "$issue_log" ]]; then
		issue_log_contents=$(tr '\n' ' ' <"$issue_log")
	fi

	HEADLESS_RUNTIME_HELPER="$original_helper"
	SCRIPT_DIR="$original_script_dir"
	restore_function_definitions "$original_function_definitions" gh gh_issue_view is_blocked_by_unresolved _check_nmr_approval_gate set_issue_status _dlw_precreate_worktree _dispatch_registered_worktree_count
	rm -f "$issue_log" "$fallback_log"

	if [[ "$dispatch_rc" -eq 0 && -z "$stdin_contents" && "$issue_log_contents" == *"stub worker output"* ]]; then
		print_result "dispatch_with_dedup detaches stdin and captures worker output to issue log (GH#14483)" 0
		return 0
	fi

	print_result "dispatch_with_dedup detaches stdin and captures worker output to issue log (GH#14483)" 1 \
		"dispatch_rc=${dispatch_rc}, pre-runtime failure=${pre_runtime_failure:-none}, stdin='${stdin_contents}', issue_log='${issue_log_contents}'"
	return 0
}

test_dispatch_with_dedup_passes_explicit_model_override() {
	local original_script_dir="$SCRIPT_DIR"
	local original_helper="$HEADLESS_RUNTIME_HELPER"
	local original_function_definitions
	original_function_definitions=$(capture_function_definitions gh gh_issue_view is_blocked_by_unresolved _check_nmr_approval_gate set_issue_status _dlw_precreate_worktree _dispatch_registered_worktree_count)
	local args_log="${TEST_ROOT}/worker-args.log"
	SCRIPT_DIR="$TEST_ROOT"

	set_ps_fixture ""
	: >"$args_log"
	set_successful_dispatch_helpers_fixture

	HEADLESS_RUNTIME_HELPER="${TEST_ROOT}/headless-model-stub.sh"
	cat >"$HEADLESS_RUNTIME_HELPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >"${args_log}"
exit 0
EOF
	chmod +x "$HEADLESS_RUNTIME_HELPER"

	set_successful_dispatch_function_stubs

	local dispatch_rc=0 pre_runtime_failure=""
	dispatch_with_dedup "8891" "marcusquinn/aidevops" "Issue #8891: model override" "t8891: model override" \
		"testuser" "/tmp/aidevops" "/full-loop test" "issue-8891" "anthropic/claude-haiku-4-5" || dispatch_rc=$?
	pre_runtime_failure="${_DLW_LAST_PRE_RUNTIME_FAILURE:-}"

	local args_contents=""
	if [[ -f "$args_log" ]]; then
		args_contents=$(tr '\n' ' ' <"$args_log")
	fi

	HEADLESS_RUNTIME_HELPER="$original_helper"
	SCRIPT_DIR="$original_script_dir"
	restore_function_definitions "$original_function_definitions" gh gh_issue_view is_blocked_by_unresolved _check_nmr_approval_gate set_issue_status _dlw_precreate_worktree _dispatch_registered_worktree_count

	if [[ "$dispatch_rc" -eq 0 && "$args_contents" == *"--initial-model anthropic/claude-haiku-4-5"* ]]; then
		print_result "dispatch_with_dedup forwards explicit model override to worker launch" 0
		return 0
	fi

	print_result "dispatch_with_dedup forwards explicit model override to worker launch" 1 \
		"dispatch_rc=${dispatch_rc}, pre-runtime failure=${pre_runtime_failure:-none}, args='${args_contents}'"
	return 0
}

test_build_ranked_dispatch_candidates_json_scores_candidates() {
	local original_repos_json="$REPOS_JSON"
	cat >"${REPOS_JSON}" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "marcusquinn/aidevops",
      "path": "/tmp/aidevops",
      "pulse": true,
      "priority": "tooling",
      "maintainer": "marcusquinn"
    },
    {
      "slug": "webapp",
      "path": "/tmp/webapp",
      "pulse": true,
      "priority": "product",
      "maintainer": "marcusquinn"
    }
  ]
}
JSON

	gh_issue_list() {
		if [[ "${1:-}" == "--repo" ]]; then
			if [[ "${2:-}" == "marcusquinn/aidevops" ]]; then
				printf '%s\n' '[
				  {"number":7001,"title":"tooling simplification","url":"https://github.com/marcusquinn/aidevops/issues/7001","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[{"name":"file-size-debt"}]},
				  {"number":7002,"title":"tooling bug","url":"https://github.com/marcusquinn/aidevops/issues/7002","updatedAt":"2026-03-31T00:01:00Z","assignees":[],"labels":[{"name":"bug"}]}
				]'
				return 0
			fi
			if [[ "${2:-}" == "webapp" ]]; then
				printf '%s\n' '[
				  {"number":8001,"title":"product simplification","url":"webapp#8001","updatedAt":"2026-03-31T00:02:00Z","assignees":[],"labels":[{"name":"function-complexity-debt"}]}
				]'
				return 0
			fi
		fi
		return 1
	}
	export -f gh_issue_list

	local ordered_numbers
	ordered_numbers=$(build_ranked_dispatch_candidates_json 20 | jq -r '.[].number' 2>/dev/null || true)

	unset -f gh_issue_list
	REPOS_JSON="$original_repos_json"

	if [[ "$ordered_numbers" == $'7002\n7001\n8001' ]]; then
		print_result "build_ranked_dispatch_candidates_json orders bug before tooling simplification before product simplification" 0
		return 0
	fi

	print_result "build_ranked_dispatch_candidates_json orders bug before tooling simplification before product simplification" 1 \
		"Unexpected order: ${ordered_numbers}"
	return 0
}

test_build_ranked_dispatch_candidates_json_respects_priority_labels() {
	local original_repos_json="$REPOS_JSON"
	cat >"${REPOS_JSON}" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "marcusquinn/aidevops",
      "path": "/tmp/aidevops",
      "pulse": true,
      "priority": "tooling",
      "maintainer": "marcusquinn"
    }
  ]
}
JSON

	gh_issue_list() {
		if [[ "${1:-}" == "--repo" && "${2:-}" == "marcusquinn/aidevops" ]]; then
			printf '%s\n' '[
			  {"number":9100,"title":"unlabeled task","url":"#9100","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[]},
			  {"number":9101,"title":"low priority task","url":"#9101","updatedAt":"2026-03-31T00:01:00Z","assignees":[],"labels":[{"name":"priority:low"}]},
			  {"number":9102,"title":"bug task","url":"#9102","updatedAt":"2026-03-31T00:02:00Z","assignees":[],"labels":[{"name":"bug"}]},
			  {"number":9103,"title":"medium priority task","url":"#9103","updatedAt":"2026-03-31T00:03:00Z","assignees":[],"labels":[{"name":"priority:medium"}]},
			  {"number":9104,"title":"high priority task","url":"#9104","updatedAt":"2026-03-31T00:04:00Z","assignees":[],"labels":[{"name":"priority:high"}]},
			  {"number":9105,"title":"critical priority task","url":"#9105","updatedAt":"2026-03-31T00:05:00Z","assignees":[],"labels":[{"name":"priority:critical"}]}
			]'
			return 0
		fi
		return 1
	}
	export -f gh_issue_list

	local ordered_numbers
	ordered_numbers=$(build_ranked_dispatch_candidates_json 20 | jq -r '.[].number' 2>/dev/null || true)

	unset -f gh_issue_list
	REPOS_JSON="$original_repos_json"

	if [[ "$ordered_numbers" == $'9105\n9104\n9103\n9102\n9101\n9100' ]]; then
		print_result "build_ranked_dispatch_candidates_json respects critical/high/medium/low labels" 0
		return 0
	fi

	print_result "build_ranked_dispatch_candidates_json respects critical/high/medium/low labels" 1 \
		"Unexpected order: ${ordered_numbers}"
	return 0
}

test_build_ranked_dispatch_candidates_json_prioritizes_security_quality_debt() {
	local original_repos_json="$REPOS_JSON"
	cat >"${REPOS_JSON}" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "marcusquinn/aidevops",
      "path": "/tmp/aidevops",
      "pulse": true,
      "priority": "tooling",
      "maintainer": "marcusquinn"
    }
  ]
}
JSON

	gh_issue_list() {
		if [[ "${1:-}" == "--repo" && "${2:-}" == "marcusquinn/aidevops" ]]; then
			printf '%s\n' '[
			  {"number":9201,"title":"ordinary high quality debt","url":"#9201","updatedAt":"2026-03-31T00:01:00Z","assignees":[],"labels":[{"name":"quality-debt"},{"name":"priority:high"}]},
			  {"number":9202,"title":"security high quality debt","url":"#9202","updatedAt":"2026-03-31T00:02:00Z","assignees":[],"labels":[{"name":"quality-debt"},{"name":"security"},{"name":"priority:high"}]}
			]'
			return 0
		fi
		return 1
	}
	export -f gh_issue_list

	local ordered_numbers
	ordered_numbers=$(build_ranked_dispatch_candidates_json 20 | jq -r '.[].number' 2>/dev/null || true)

	unset -f gh_issue_list
	REPOS_JSON="$original_repos_json"

	if [[ "$ordered_numbers" == $'9202\n9201' ]]; then
		print_result "build_ranked_dispatch_candidates_json prioritizes security quality-debt" 0
		return 0
	fi

	print_result "build_ranked_dispatch_candidates_json prioritizes security quality-debt" 1 \
		"Unexpected order: ${ordered_numbers}"
	return 0
}

test_build_ranked_dispatch_candidates_json_excludes_pull_requests() {
	local original_repos_json="$REPOS_JSON"
	cat >"${REPOS_JSON}" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "marcusquinn/aidevops",
      "path": "/tmp/aidevops",
      "pulse": true,
      "priority": "tooling",
      "maintainer": "marcusquinn"
    }
  ]
}
JSON

	gh_issue_list() {
		if [[ "${1:-}" == "--repo" && "${2:-}" == "marcusquinn/aidevops" ]]; then
			printf '%s\n' '[
			  {"number":9301,"title":"pull request target","url":"https://github.com/marcusquinn/aidevops/pull/9301","updatedAt":"2026-03-31T00:01:00Z","assignees":[],"labels":[{"name":"bug"}],"pull_request":{"url":"https://api.github.com/repos/marcusquinn/aidevops/pulls/9301"}},
			  {"number":9302,"title":"issue target","url":"https://github.com/marcusquinn/aidevops/issues/9302","updatedAt":"2026-03-31T00:02:00Z","assignees":[],"labels":[{"name":"bug"}]}
			]'
			return 0
		fi
		return 1
	}
	export -f gh_issue_list

	local ordered_numbers
	ordered_numbers=$(build_ranked_dispatch_candidates_json 20 | jq -r '.[].number' 2>/dev/null || true)

	unset -f gh_issue_list
	REPOS_JSON="$original_repos_json"

	if [[ "$ordered_numbers" == "9302" ]]; then
		print_result "build_ranked_dispatch_candidates_json excludes pull requests from implementation dispatch" 0
		return 0
	fi

	print_result "build_ranked_dispatch_candidates_json excludes pull requests from implementation dispatch" 1 \
		"Unexpected candidate numbers: ${ordered_numbers}"
	return 0
}

test_build_ranked_dispatch_candidates_json_applies_capped_age_bonus() {
	local original_repos_json="$REPOS_JSON"
	local original_age_bonus_per_day="$PULSE_DISPATCH_AGE_BONUS_PER_DAY"
	local original_age_bonus_cap="$PULSE_DISPATCH_AGE_BONUS_CAP"
	cat >"${REPOS_JSON}" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "marcusquinn/aidevops",
      "path": "/tmp/aidevops",
      "pulse": true,
      "priority": "tooling",
      "maintainer": "marcusquinn"
    }
  ]
}
JSON

	gh_issue_list() {
		if [[ "${1:-}" == "--repo" && "${2:-}" == "marcusquinn/aidevops" ]]; then
			printf '%s\n' '[
			  {"number":9303,"title":"old later update","url":"#9303","createdAt":"2020-01-01T00:00:00Z","updatedAt":"2026-03-31T00:02:00Z","assignees":[],"labels":[{"name":"bug"}]},
			  {"number":9304,"title":"future issue","url":"#9304","createdAt":"2099-01-01T00:00:00Z","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[{"name":"bug"}]},
			  {"number":9305,"title":"old earlier update","url":"#9305","createdAt":"2020-01-01T00:00:00Z","updatedAt":"2026-03-31T00:01:00Z","assignees":[],"labels":[{"name":"bug"}]},
			  {"number":9306,"title":"slightly newer capped issue","url":"#9306","createdAt":"2021-01-01T00:00:00Z","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[{"name":"bug"}]}
			]'
			return 0
		fi
		return 1
	}
	export -f gh_issue_list
	PULSE_DISPATCH_AGE_BONUS_PER_DAY=10
	PULSE_DISPATCH_AGE_BONUS_CAP=100

	local ranked_json ordered_numbers age_bonuses
	ranked_json=$(build_ranked_dispatch_candidates_json 20)
	ordered_numbers=$(printf '%s' "$ranked_json" | jq -r '.[].number' 2>/dev/null || true)
	age_bonuses=$(printf '%s' "$ranked_json" | jq -r '[.[] | {key: (.number | tostring), value: .age_bonus}] | from_entries | [."9303", ."9304", ."9305", ."9306"] | join(",")' 2>/dev/null || true)

	unset -f gh_issue_list
	REPOS_JSON="$original_repos_json"
	PULSE_DISPATCH_AGE_BONUS_PER_DAY="$original_age_bonus_per_day"
	PULSE_DISPATCH_AGE_BONUS_CAP="$original_age_bonus_cap"

	if [[ "$ordered_numbers" == $'9305\n9303\n9306\n9304' && "$age_bonuses" == "100,0,100,100" ]]; then
		print_result "build_ranked_dispatch_candidates_json caps age bonus and uses creation/update tie-breaks" 0
		return 0
	fi

	print_result "build_ranked_dispatch_candidates_json caps age bonus and uses creation/update tie-breaks" 1 \
		"Unexpected order/bonuses: order=${ordered_numbers//$'\n'/,} bonuses=${age_bonuses}"
	return 0
}

_test_capacity_model_for_labels() {
	local labels="$1"
	case ",${labels}," in
	*,tier:thinking,*) printf '%s\n' "anthropic/claude-opus-4-6" ;;
	*,tier:standard,*) printf '%s\n' "anthropic/claude-sonnet-4-6" ;;
	*,tier:simple,*) printf '%s\n' "anthropic/claude-haiku-4-5" ;;
	*) printf '\n' ;;
	esac
	return 0
}

_test_capacity_candidates() {
	local mode="$1"
	printf '%s\n' '[
	  {"number":9101,"repo_slug":"marcusquinn/aidevops","repo_path":"/tmp/aidevops","url":"https://github.com/marcusquinn/aidevops/issues/9101","title":"candidate one","labels":["bug"],"updatedAt":"2026-03-31T00:00:00Z","score":8000},
	  {"number":9102,"repo_slug":"marcusquinn/aidevops","repo_path":"/tmp/aidevops","url":"https://github.com/marcusquinn/aidevops/issues/9102","title":"candidate two","labels":["file-size-debt","tier:simple"],"updatedAt":"2026-03-31T00:01:00Z","score":4000},
	  {"number":9103,"repo_slug":"marcusquinn/aidevops","repo_path":"/tmp/aidevops","url":"https://github.com/marcusquinn/aidevops/issues/9103","title":"candidate three","labels":["function-complexity-debt"],"updatedAt":"2026-03-31T00:02:00Z","score":4000}
	]' | jq -c --arg mode "$mode" 'map(
		if $mode == "product" and .number == 9102 then
			.repo_slug="o/product" | .repo_path="/tmp/product" | .url="" | .repo_priority="product"
		else .repo_priority="tooling" end | .product_discovery_complete=true)'
	return $?
}

test_dispatch_max_dispatches_up_to_capacity() {
	local reservation_mode="${1:-tooling}"
	local REPOS_JSON="${TEST_ROOT}/reservation-integration.json"
	local PRODUCT_RESERVATION_PCT=50
	local original_rest_gate=""
	original_rest_gate=$(capture_function_definitions _dispatch_rest_core_progress_allows_next)
	_dispatch_rest_core_progress_allows_next() { return 0; }
	jq -nc --arg mode "$reservation_mode" '{initialized_repos:
		(if $mode == "product" then [{slug:"o/product",path:"/tmp/product",pulse:true,priority:"product"}] else [] end)}' >"$REPOS_JSON"
	local dispatch_log="${TEST_ROOT}/deterministic-dispatch.log"
	local original_function_definitions
	original_function_definitions=$(capture_function_definitions gh resolve_dispatch_model_for_labels build_ranked_dispatch_candidates_json _dispatch_compute_capacity _dispatch_ranked_candidates_json _dispatch_run_prepasses _dispatch_order_idle_borrowing_candidates _dispatch_max_compute_parallel _dispatch_graphql_budget_allows_next _dispatch_should_skip_candidate _dispatch_check_model_concurrency_cap _pulse_refresh_repo _dispatch_with_timeout count_runnable_candidates count_queued_without_worker dispatch_with_dedup check_worker_launch _dispatch_maybe_engage_throttle)
	: >"$dispatch_log"

	resolve_dispatch_model_for_labels() {
		local labels="${1:-}"
		_test_capacity_model_for_labels "$labels"
		return $?
	}

	build_ranked_dispatch_candidates_json() {
		_test_capacity_candidates "$reservation_mode"
		return $?
	}
	_dispatch_compute_capacity() {
		printf '2 0 2\n'
		return 0
	}
	_dispatch_ranked_candidates_json() {
		build_ranked_dispatch_candidates_json
		return 0
	}
	_dispatch_run_prepasses() {
		local available_slots="$1"
		printf '%s 0 0\n' "$available_slots"
		return 0
	}
	_dispatch_order_idle_borrowing_candidates() {
		local candidates_json="$1"
		printf '%s\n' "$candidates_json"
		return 0
	}
	_dispatch_max_compute_parallel() {
		printf '1\n'
		return 0
	}
	_dispatch_graphql_budget_allows_next() { return 0; }
	_dispatch_should_skip_candidate() { return 1; }
	_dispatch_check_model_concurrency_cap() { return 0; }
	_pulse_refresh_repo() { return 0; }
	_dispatch_with_timeout() {
		dispatch_with_dedup "$@"
		return $?
	}
	count_runnable_candidates() {
		printf '3\n'
		return 0
	}
	count_queued_without_worker() {
		printf '0\n'
		return 0
	}
	dispatch_with_dedup() {
		printf '%s|%s\n' "$1" "${9:-}" >>"$dispatch_log"
		return 0
	}
	check_worker_launch() { return 0; }
	_dispatch_maybe_engage_throttle() { return 0; }
	gh() {
		if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
			printf 'testuser\n'
			return 0
		fi
		return 0
	}
	export -f gh

	local dispatch_count dispatched_numbers
	dispatch_count=$(dispatch_max)
	dispatched_numbers=$(tr '\n' ',' <"$dispatch_log" | sed 's/,$//')
	restore_function_definitions "$original_rest_gate" _dispatch_rest_core_progress_allows_next

	restore_function_definitions "$original_function_definitions" gh resolve_dispatch_model_for_labels build_ranked_dispatch_candidates_json _dispatch_compute_capacity _dispatch_ranked_candidates_json _dispatch_run_prepasses _dispatch_order_idle_borrowing_candidates _dispatch_max_compute_parallel _dispatch_graphql_budget_allows_next _dispatch_should_skip_candidate _dispatch_check_model_concurrency_cap _pulse_refresh_repo _dispatch_with_timeout count_runnable_candidates count_queued_without_worker dispatch_with_dedup check_worker_launch _dispatch_maybe_engage_throttle

	local expected_numbers="9101|,9102|anthropic/claude-haiku-4-5"
	[[ "$reservation_mode" != product ]] || expected_numbers="9102|anthropic/claude-haiku-4-5,9101|"
	if [[ "$dispatch_count" == "2" && "$dispatched_numbers" == "$expected_numbers" ]]; then
		print_result "dispatch_max enforces ${reservation_mode} policy, capacity, and simple-tier override" 0
		return 0
	fi

	print_result "dispatch_max dispatches ranked candidates up to capacity and honors simple-tier override" 1 \
		"Expected count=2 and issues 9101,9102; got count=${dispatch_count}, issues=${dispatched_numbers}"
	return 0
}

test_build_ranked_dispatch_candidates_json_respects_schedule_gate() {
	local original_repos_json="$REPOS_JSON"
	cat >"${REPOS_JSON}" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "marcusquinn/aidevops",
      "path": "/tmp/aidevops",
      "pulse": true,
      "priority": "tooling"
    },
    {
      "slug": "webapp",
      "path": "/tmp/webapp",
      "pulse": true,
      "priority": "product"
    }
  ]
}
JSON

	check_repo_pulse_schedule() {
		[[ "$1" == "marcusquinn/aidevops" ]]
	}
	gh_issue_list() {
		if [[ "${1:-}" == "--repo" ]]; then
			if [[ "${2:-}" == "marcusquinn/aidevops" ]]; then
				printf '%s\n' '[{"number":9201,"title":"allowed","url":"https://github.com/marcusquinn/aidevops/issues/9201","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[{"name":"bug"}]}]'
				return 0
			fi
			if [[ "${2:-}" == "webapp" ]]; then
				printf '%s\n' '[{"number":9202,"title":"blocked by schedule","url":"webapp#9202","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[{"name":"bug"}]}]'
				return 0
			fi
		fi
		return 1
	}
	export -f gh_issue_list

	local candidate_numbers
	candidate_numbers=$(build_ranked_dispatch_candidates_json 20 | jq -r '.[].number' 2>/dev/null || true)

	unset -f gh_issue_list check_repo_pulse_schedule
	REPOS_JSON="$original_repos_json"

	if [[ "$candidate_numbers" == "9201" ]]; then
		print_result "build_ranked_dispatch_candidates_json skips repos outside schedule gate" 0
		return 0
	fi

	print_result "build_ranked_dispatch_candidates_json skips repos outside schedule gate" 1 \
		"Unexpected scheduled candidate set: ${candidate_numbers}"
	return 0
}

test_build_ranked_dispatch_candidates_json_accepts_array_pulse_hours() {
	local original_repos_json="$REPOS_JSON"
	local schedule_args_log="${TEST_ROOT}/pulse-hours-array-schedule-args.log"
	: >"$schedule_args_log"
	cat >"${REPOS_JSON}" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "marcusquinn/aidevops",
      "path": "/tmp/aidevops",
      "pulse": true,
      "priority": "tooling",
      "pulse_hours": [9, 17]
    }
  ]
}
JSON

	check_repo_pulse_schedule() {
		printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >>"$schedule_args_log"
		return 0
	}
	gh_issue_list() {
		if [[ "${1:-}" == "--repo" && "${2:-}" == "marcusquinn/aidevops" ]]; then
			printf '%s\n' '[{"number":9251,"title":"array pulse hours","url":"https://github.com/marcusquinn/aidevops/issues/9251","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[{"name":"bug"}]}]'
			return 0
		fi
		return 1
	}
	export -f gh_issue_list

	local candidate_numbers schedule_args
	candidate_numbers=$(build_ranked_dispatch_candidates_json 20 | jq -r '.[].number' 2>/dev/null || true)
	schedule_args=$(cat "$schedule_args_log" 2>/dev/null || true)

	unset -f gh_issue_list check_repo_pulse_schedule
	REPOS_JSON="$original_repos_json"

	if [[ "$candidate_numbers" == "9251" && "$schedule_args" == "marcusquinn/aidevops|9|17|" ]]; then
		print_result "build_ranked_dispatch_candidates_json accepts array pulse_hours" 0
		return 0
	fi

	print_result "build_ranked_dispatch_candidates_json accepts array pulse_hours" 1 \
		"candidate_numbers='${candidate_numbers}', schedule_args='${schedule_args}'"
	return 0
}

test_dispatch_max_honors_stop_flag() {
	local dispatch_log="${TEST_ROOT}/deterministic-stop.log"
	local original_function_definitions
	original_function_definitions=$(capture_function_definitions build_ranked_dispatch_candidates_json dispatch_with_dedup)
	: >"$dispatch_log"
	touch "$STOP_FLAG"

	build_ranked_dispatch_candidates_json() {
		printf '%s\n' '[{"number":9301,"repo_slug":"marcusquinn/aidevops","repo_path":"/tmp/aidevops","url":"https://github.com/marcusquinn/aidevops/issues/9301","title":"candidate one","labels":["bug"],"updatedAt":"2026-03-31T00:00:00Z","score":8000}]'
	}
	dispatch_with_dedup() {
		printf '%s\n' "$1" >>"$dispatch_log"
		return 0
	}

	local dispatch_count dispatched_numbers
	dispatch_count=$(dispatch_max)
	dispatched_numbers=$(tr '\n' ',' <"$dispatch_log" | sed 's/,$//')

	rm -f "$STOP_FLAG"
	restore_function_definitions "$original_function_definitions" build_ranked_dispatch_candidates_json dispatch_with_dedup

	if [[ "$dispatch_count" == "0" && -z "$dispatched_numbers" ]]; then
		print_result "dispatch_max skips dispatch when stop flag is present" 0
		return 0
	fi

	print_result "dispatch_max skips dispatch when stop flag is present" 1 \
		"Expected no dispatch with stop flag; got count=${dispatch_count}, issues=${dispatched_numbers}"
	return 0
}

test_dispatch_max_skips_broad_prelaunch_counts() {
	local original_rest_gate=""
	original_rest_gate=$(capture_function_definitions _dispatch_rest_core_progress_allows_next)
	_dispatch_rest_core_progress_allows_next() { return 0; }
	local dispatch_log="${TEST_ROOT}/deterministic-no-broad-counts.log"
	local count_call_log="${TEST_ROOT}/deterministic-broad-count-calls.log"
	local login_call_log="${TEST_ROOT}/deterministic-login-calls.log"
	local original_function_definitions
	original_function_definitions=$(capture_function_definitions gh build_ranked_dispatch_candidates_json _dispatch_compute_capacity _dispatch_ranked_candidates_json _dispatch_run_prepasses _dispatch_order_idle_borrowing_candidates _dispatch_max_compute_parallel _dispatch_graphql_budget_allows_next _dispatch_should_skip_candidate _dispatch_check_model_concurrency_cap _pulse_refresh_repo _dispatch_with_timeout count_runnable_candidates count_queued_without_worker dispatch_with_dedup check_worker_launch _dispatch_maybe_engage_throttle)
	: >"$dispatch_log"
	: >"$count_call_log"
	: >"$login_call_log"

	build_ranked_dispatch_candidates_json() {
		printf '%s\n' '[
		  {"number":9401,"repo_slug":"marcusquinn/aidevops","repo_path":"/tmp/aidevops","url":"https://github.com/marcusquinn/aidevops/issues/9401","title":"candidate one","labels":["bug"],"updatedAt":"2026-03-31T00:00:00Z","score":8000}
		]'
	}
	_dispatch_compute_capacity() {
		printf '2 0 2\n'
		return 0
	}
	_dispatch_ranked_candidates_json() {
		if [[ "${TEST_EMPTY_CANDIDATES:-0}" == "1" ]]; then
			printf '[]\n'
			return 0
		fi
		build_ranked_dispatch_candidates_json
		return 0
	}
	_dispatch_run_prepasses() {
		local available_slots="$1"
		printf '%s 0 0\n' "$available_slots"
		return 0
	}
	_dispatch_order_idle_borrowing_candidates() {
		local candidates_json="$1"
		printf '%s\n' "$candidates_json"
		return 0
	}
	_dispatch_max_compute_parallel() {
		printf '1\n'
		return 0
	}
	_dispatch_graphql_budget_allows_next() { return 0; }
	_dispatch_should_skip_candidate() { return 1; }
	_dispatch_check_model_concurrency_cap() { return 0; }
	_pulse_refresh_repo() { return 0; }
	_dispatch_with_timeout() {
		dispatch_with_dedup "$@"
		return $?
	}
	count_runnable_candidates() {
		printf 'count_runnable_candidates\n' >>"$count_call_log"
		return 1
	}
	count_queued_without_worker() {
		printf 'count_queued_without_worker\n' >>"$count_call_log"
		return 1
	}
	dispatch_with_dedup() {
		printf '%s\n' "$1" >>"$dispatch_log"
		return 0
	}
	check_worker_launch() { return 0; }
	_dispatch_maybe_engage_throttle() { return 0; }
	gh() {
		if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
			printf 'login\n' >>"$login_call_log"
			printf 'testuser\n'
			return 0
		fi
		return 0
	}
	export -f gh

	local dispatch_count empty_dispatch_count dispatched_numbers count_call_count login_call_count
	dispatch_count=$(dispatch_max)
	TEST_EMPTY_CANDIDATES=1
	empty_dispatch_count=$(dispatch_max)
	unset TEST_EMPTY_CANDIDATES
	dispatched_numbers=$(tr '\n' ',' <"$dispatch_log" | sed 's/,$//')
	count_call_count=$(wc -l <"$count_call_log" | tr -d ' ')
	login_call_count=$(wc -l <"$login_call_log" | tr -d ' ')
	restore_function_definitions "$original_rest_gate" _dispatch_rest_core_progress_allows_next

	restore_function_definitions "$original_function_definitions" gh build_ranked_dispatch_candidates_json _dispatch_compute_capacity _dispatch_ranked_candidates_json _dispatch_run_prepasses _dispatch_order_idle_borrowing_candidates _dispatch_max_compute_parallel _dispatch_graphql_budget_allows_next _dispatch_should_skip_candidate _dispatch_check_model_concurrency_cap _pulse_refresh_repo _dispatch_with_timeout count_runnable_candidates count_queued_without_worker dispatch_with_dedup check_worker_launch _dispatch_maybe_engage_throttle

	if [[ "$dispatch_count" == "1" && "$empty_dispatch_count" == "0" && "$dispatched_numbers" == "9401" && "$count_call_count" == "0" && "$login_call_count" == "1" ]]; then
		print_result "dispatch_max skips broad pre-launch counts and empty-snapshot login" 0
		return 0
	fi

	print_result "dispatch_max skips broad pre-launch counts and empty-snapshot login" 1 \
		"Expected dispatch=1, empty=0, issue=9401, broad_counts=0, login_calls=1; got dispatch=${dispatch_count}, empty=${empty_dispatch_count}, issues=${dispatched_numbers}, broad_counts=${count_call_count}, login_calls=${login_call_count}"
	return 0
}

test_active_pulse_refill_skips_without_idle_or_stall_signal() {
	local original_function_definitions
	original_function_definitions=$(capture_function_definitions get_max_workers_target count_active_workers count_runnable_candidates count_queued_without_worker run_underfill_worker_recycler dispatch_max)
	get_max_workers_target() { echo 4; }
	count_active_workers() { echo 1; }
	count_runnable_candidates() { echo 9; }
	count_queued_without_worker() { echo 2; }
	run_underfill_worker_recycler() {
		printf 'recycler\n' >>"${TEST_ROOT}/active-refill-skip.log"
		return 0
	}
	dispatch_max() {
		printf 'dispatch\n' >>"${TEST_ROOT}/active-refill-skip.log"
		return 0
	}

	local last_refill_epoch
	last_refill_epoch=$(maybe_refill_underfilled_pool_during_active_pulse 0 60 0 true)

	restore_function_definitions "$original_function_definitions" get_max_workers_target count_active_workers count_runnable_candidates count_queued_without_worker run_underfill_worker_recycler dispatch_max

	if [[ "$last_refill_epoch" == "0" && ! -e "${TEST_ROOT}/active-refill-skip.log" ]]; then
		print_result "maybe_refill_underfilled_pool_during_active_pulse waits for idle or stall evidence" 0
		return 0
	fi

	print_result "maybe_refill_underfilled_pool_during_active_pulse waits for idle or stall evidence" 1 \
		"Expected no refill without idle/stall; got epoch=${last_refill_epoch}"
	return 0
}

test_active_pulse_refill_dispatches_when_underfilled_and_idle() {
	local action_log="${TEST_ROOT}/active-refill.log"
	local original_function_definitions original_refill_interval="${PULSE_ACTIVE_REFILL_INTERVAL:-}"
	local had_original_refill_interval=0
	original_function_definitions=$(capture_function_definitions get_max_workers_target count_active_workers count_runnable_candidates count_queued_without_worker run_underfill_worker_recycler dispatch_max _dispatch_min_worker_floor_refill)
	if [[ -n "${PULSE_ACTIVE_REFILL_INTERVAL+x}" ]]; then
		had_original_refill_interval=1
	fi
	: >"$action_log"
	export PULSE_ACTIVE_REFILL_INTERVAL=120

	get_max_workers_target() { echo 6; }
	count_active_workers() { echo 1; }
	count_runnable_candidates() { echo 12; }
	count_queued_without_worker() { echo 3; }
	run_underfill_worker_recycler() {
		printf 'recycler\n' >>"$action_log"
		return 0
	}
	dispatch_max() {
		printf 'dispatch\n' >>"$action_log"
		return 0
	}
	_dispatch_min_worker_floor_refill() {
		return 0
	}

	local first_refill second_refill actions
	first_refill=$(maybe_refill_underfilled_pool_during_active_pulse 0 0 60 true)
	second_refill=$(maybe_refill_underfilled_pool_during_active_pulse "$first_refill" 0 60 true)
	actions=$(tr '\n' ',' <"$action_log" | sed 's/,$//')

	restore_function_definitions "$original_function_definitions" get_max_workers_target count_active_workers count_runnable_candidates count_queued_without_worker run_underfill_worker_recycler dispatch_max _dispatch_min_worker_floor_refill
	if [[ "$had_original_refill_interval" -eq 1 ]]; then
		export PULSE_ACTIVE_REFILL_INTERVAL="$original_refill_interval"
	else
		unset PULSE_ACTIVE_REFILL_INTERVAL
	fi

	if [[ "$first_refill" =~ ^[0-9]+$ && "$first_refill" -gt 0 && "$second_refill" == "$first_refill" && "$actions" == "recycler,dispatch" ]]; then
		print_result "maybe_refill_underfilled_pool_during_active_pulse refills once per interval when idle" 0
		return 0
	fi

	print_result "maybe_refill_underfilled_pool_during_active_pulse refills once per interval when idle" 1 \
		"Expected one recycler+dispatch pass with cooldown; got first=${first_refill}, second=${second_refill}, actions=${actions}"
	return 0
}

test_worker_detection_uses_unlimited_width_ps_flag() {
	# t2190: Linux procps truncates the command column to the detected
	# terminal width (~80 cols) when ps output is piped. Worker commands
	# carry the full HEADLESS_CONTINUATION_CONTRACT_V6 prompt (5000+ chars),
	# so substrings needed by list_active_workers.awk (`--role worker`,
	# `/full-loop`, `--session-key issue-NNN`, `--dir <path>`) end up past
	# position 80 and get stripped. The awk regex then fails to match,
	# has_worker_for_repo_issue returns false within the 35s grace window,
	# and recover_failed_launch_state unassigns the worker — every dispatch
	# cycle loops on the same issue.
	#
	# Fix: all ps invocations in worker-detection paths must pass `ww`
	# (axwwo = unlimited width; works on both BSD ps and procps).
	#
	# This test asserts the canonical invocation form at runtime.
	# NB: Must rely on list_active_worker_processes directly, not
	# count_active_workers — earlier tests `unset -f count_active_workers`
	# as part of their teardown, so by the time this test runs the
	# wrapper is gone but the lower-level function is still defined.
	local log_file="${TEST_ROOT}/ps-invocations.log"
	: >"$log_file"
	PS_INVOCATION_LOG_FILE="$log_file"
	export PS_INVOCATION_LOG_FILE

	set_ps_fixture "100 S 00:10 bash /Users/test/.aidevops/agents/scripts/headless-runtime-helper.sh run --role worker --session-key issue-2190 --dir /tmp/aidevops --title Issue #2190 --prompt-file /tmp/pulse-2190.prompt"

	local output
	output=$(list_active_worker_processes)
	local count
	count=$(printf '%s\n' "$output" | grep -c '^100 ' || true)

	local invocations
	invocations=$(tr '\n' ',' <"$log_file" | sed 's/,$//')

	unset PS_INVOCATION_LOG_FILE

	# Must have at least one axwwo invocation.
	if ! grep -qxE 'axwwo' "$log_file"; then
		print_result "worker-detection calls ps with unlimited-width flag (t2190)" 1 \
			"Expected at least one 'ps axwwo' call, got: ${invocations:-<empty>}"
		return 0
	fi

	# Must have zero bare axo invocations (Linux truncation foot-gun).
	if grep -qxE 'axo' "$log_file"; then
		print_result "worker-detection calls ps with unlimited-width flag (t2190)" 1 \
			"Regression: found bare 'ps axo' call — Linux procps will truncate. Use 'ps axwwo'. Log: ${invocations}"
		return 0
	fi

	# And the fixture should have been detected as a worker.
	if [[ "$count" != "1" ]]; then
		print_result "worker-detection calls ps with unlimited-width flag (t2190)" 1 \
			"Expected 1 worker detected (PID 100), got ${count}. list output: ${output}"
		return 0
	fi

	print_result "worker-detection calls ps with unlimited-width flag (t2190)" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	# shellcheck source=/dev/null
	source "$PULSE_WRAPPER_SCRIPT"

	test_counts_plain_and_dot_prefixed_opencode_workers
	test_deduplicates_process_chain_to_one_logical_worker
	test_deduplicates_multiple_workers_with_process_chains
	test_repo_issue_detection_uses_filtered_worker_list
	test_excludes_zombie_and_stopped_processes
	test_has_worker_for_repo_issue_session_key_fallback
	test_counts_standalone_opencode_binary_workers
	test_deduplicates_chain_but_keeps_standalone_opencode_binary
	test_counts_review_issue_pr_workers
	test_review_issue_pr_session_key_fallback_dedup
	test_review_thread_response_session_key_fallback_dedup
	test_worker_title_prefixes_issue_number
	test_check_dispatch_dedup_treats_merged_pr_as_duplicate
	test_dispatch_with_dedup_blocks_when_duplicate
	test_dispatch_with_dedup_fails_closed_when_issue_metadata_missing
	test_dispatch_with_dedup_proceeds_when_no_duplicate
	test_dispatch_with_dedup_detaches_worker_stdio
	test_dispatch_with_dedup_passes_explicit_model_override
	test_build_ranked_dispatch_candidates_json_scores_candidates
	test_build_ranked_dispatch_candidates_json_respects_priority_labels
	test_build_ranked_dispatch_candidates_json_prioritizes_security_quality_debt
	test_build_ranked_dispatch_candidates_json_excludes_pull_requests
	test_build_ranked_dispatch_candidates_json_applies_capped_age_bonus
	test_build_ranked_dispatch_candidates_json_respects_schedule_gate
	test_build_ranked_dispatch_candidates_json_accepts_array_pulse_hours
	test_dispatch_max_dispatches_up_to_capacity
	test_dispatch_max_dispatches_up_to_capacity product
	test_dispatch_max_honors_stop_flag
	test_dispatch_max_skips_broad_prelaunch_counts
	test_active_pulse_refill_skips_without_idle_or_stall_signal
	test_active_pulse_refill_dispatches_when_underfilled_and_idle
	test_worker_detection_uses_unlimited_width_ps_flag

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
