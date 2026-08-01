#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for the `_close_conflicting_pr` close-comment wording
# (GH#17574 / t2032) AND the file-overlap verification (GH#18815).
#
# Verifies that when the deterministic merge pass detects "work already
# on main", the close comment:
#   1. Says "landed on <base branch>" — NOT "committed directly to main"
#   2. Includes "(via PR #NNN)" when the matching commit has a
#      squash-merge suffix
#   3. Omits the parenthetical when no PR number is parseable
#   4. (GH#18815) Only fires when the matching commit and the closing PR
#      share a non-planning file path. A planning-only match (e.g., the
#      #18760 ↔ #18749 false positive) must NOT close the PR.
#   5. (GH#18815) Fails CLOSED when file lookups error out — leave the PR
#      open and post a rebase nudge instead of discarding work.

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""
STUB_DIR=""
CAPTURED_COMMENT_FILE=""

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

# Stub `gh` for the new file-overlap-aware contract. The stub dispatches on
# argument shape and reads predetermined response files written by each test
# case. This keeps the stub stable across tests — only the response files
# change per case.
#
# Response files (written by set_responses):
#   $TEST_ROOT/commits.json     — output for `gh api repos/.../commits` (JSON array)
#   $TEST_ROOT/commit-files.txt — output for `gh api repos/.../commits/SHA` (lines)
#   $TEST_ROOT/pr-files.txt     — output for `gh pr view N --json files` (lines)
#   $TEST_ROOT/pr-labels.txt    — output for `gh pr view N --json labels` (lines)
#   $TEST_ROOT/pr-branch.txt    — head branch for `gh pr view N --json headRefName`
#   $TEST_ROOT/pr-base-branch.txt — base branch for `gh pr view N --json baseRefName`
#
# A missing or empty response file makes the stub exit 1, simulating a gh
# API failure for the relevant call.
write_stub_gh() {
	cat >"${STUB_DIR}/gh" <<STUB_EOF
#!/usr/bin/env bash
TEST_ROOT="${TEST_ROOT}"
CAPTURED_COMMENT_FILE="${CAPTURED_COMMENT_FILE}"

if [[ "\$1" == "api" ]]; then
	url="\$2"
	if [[ "\$url" =~ /commits/[a-f0-9]+\$ ]]; then
		# gh api repos/X/Y/commits/SHA --jq '.files[].filename'
		response="\${TEST_ROOT}/commit-files.txt"
		if [[ ! -s "\$response" ]]; then
			exit 1
		fi
		cat "\$response"
		exit 0
	elif [[ "\$url" =~ /commits\$ ]]; then
		# gh api repos/X/Y/commits --jq '[.[] | {sha, subject}]'
		response="\${TEST_ROOT}/commits.json"
		if [[ ! -s "\$response" ]]; then
			exit 1
		fi
		cat "\$response"
		exit 0
	fi
	exit 0
fi

if [[ "\$1" == "pr" && "\$2" == "close" ]]; then
	shift 2
	while [[ \$# -gt 0 ]]; do
		if [[ "\$1" == "--comment" ]]; then
			printf '%s' "\$2" >"\${CAPTURED_COMMENT_FILE}"
			shift 2
		else
			shift
		fi
	done
	exit 0
fi

	if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
	field=""
	args=("\$@")
	i=2
	while [[ \$i -lt \${#args[@]} ]]; do
		if [[ "\${args[\$i]}" == "--json" ]]; then
			j=\$((i + 1))
			field="\${args[\$j]}"
			break
		fi
		i=\$((i + 1))
	done
	case "\$field" in
		"headRefName,baseRefName")
			head_branch="feature/test"; base_branch="main"
			[[ -f "\${TEST_ROOT}/pr-branch.txt" ]] && head_branch=\$(cat "\${TEST_ROOT}/pr-branch.txt")
			[[ -f "\${TEST_ROOT}/pr-base-branch.txt" ]] && base_branch=\$(cat "\${TEST_ROOT}/pr-base-branch.txt")
			printf '%s\t%s\n' "\$head_branch" "\$base_branch"
			exit 0
			;;
		labels)
			response="\${TEST_ROOT}/pr-labels.txt"
			if [[ -f "\$response" ]]; then cat "\$response"; fi
			exit 0
			;;
		"labels,author")
			# GH#20485/GH#29170: _close_conflicting_pr_check_ownership_guard fetches
			# labels + author metadata in one call. Return pr-meta.json if
			# present; fall back to a default that simulates a worker PR
			# (origin:worker label, bot author) so existing tests are unaffected.
			response="\${TEST_ROOT}/pr-meta.json"
			if [[ -f "\$response" ]]; then
				cat "\$response"
			else
				echo '{"labels":[{"name":"origin:worker"}],"author":{"login":"aidevops-worker[bot]"}}'
			fi
			exit 0
			;;
		files)
			response="\${TEST_ROOT}/pr-files.txt"
			if [[ ! -s "\$response" ]]; then exit 1; fi
			cat "\$response"
			exit 0
			;;
		headRefName)
			response="\${TEST_ROOT}/pr-branch.txt"
			if [[ -f "\$response" ]]; then cat "\$response"; else echo "feature/test"; fi
			exit 0
			;;
		*)
			exit 0
			;;
	esac
fi

exit 0
STUB_EOF
	chmod +x "${STUB_DIR}/gh"
	return 0
}

setup_sandbox() {
	TEST_ROOT=$(mktemp -d)
	STUB_DIR="${TEST_ROOT}/stubs"
	CAPTURED_COMMENT_FILE="${TEST_ROOT}/captured-comment.txt"
	mkdir -p "$STUB_DIR"
	: >"$CAPTURED_COMMENT_FILE"

	write_stub_gh

	export PATH="${STUB_DIR}:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	return 0
}

teardown_sandbox() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Source the helpers under test from pulse-merge-conflict.sh in isolation.
# The parent module is sourced by pulse-wrapper.sh and depends on bootstrap
# state, so we extract just the function bodies into a temp file and
# source that.
#
# GH#19836: These helpers were extracted from pulse-merge.sh to
# pulse-merge-conflict.sh in PR #19842 (conflict-handling cluster).
load_functions_under_test() {
	local repo_root
	repo_root=$(cd "$(dirname "$0")/../../.." && pwd)
	local src="${repo_root}/.agents/scripts/pulse-merge-conflict.sh"
	local tmp_fn="${TEST_ROOT}/pulse-merge-funcs.sh"

	# Extract these functions in order:
	#   _get_pr_branch_refs_for_conflict_comment      (GH#25780)
	#   _post_rebase_nudge_on_interactive_conflicting (label-fetch fail path)
	#   _post_rebase_nudge_on_contributor_conflicting (GH#20485)
	#   _is_planning_path_for_overlap
	#   _verify_pr_overlaps_commit
	#   _post_rebase_nudge_on_worker_conflicting
	#   _parse_squash_merge_pr                         (t2438)
	#   _find_task_id_match_on_main                    (t2438)
	#   _close_conflicting_pr_check_ownership_guard    (GH#20485, replaces _check_interactive_guard)
	#   _close_conflicting_pr_classify_landed          (t2438)
	#   _close_conflicting_pr_comment_landed           (t2438)
	#   _close_conflicting_pr_comment_not_landed       (t2438)
	#   _close_conflicting_pr                          (orchestrator)
	# Each definition uses tab-indented bodies with a column-0 "}" closer.
	awk '
		/^_get_pr_branch_refs_for_conflict_comment\(\) \{$/       { fn=1 }
		/^_post_rebase_nudge_on_interactive_conflicting\(\) \{$/ { fn=1 }
		/^_post_rebase_nudge_on_contributor_conflicting\(\) \{$/  { fn=1 }
		/^_is_planning_path_for_overlap\(\) \{$/                  { fn=1 }
		/^_verify_pr_overlaps_commit\(\) \{$/                     { fn=1 }
		/^_post_rebase_nudge_on_worker_conflicting\(\) \{$/       { fn=1 }
		/^_parse_squash_merge_pr\(\) \{$/                         { fn=1 }
		/^_find_task_id_match_on_main\(\) \{$/                    { fn=1 }
		/^_close_conflicting_pr_check_ownership_guard\(\) \{$/    { fn=1 }
		/^_close_conflicting_pr_classify_landed\(\) \{$/          { fn=1 }
		/^_close_conflicting_pr_comment_landed\(\) \{$/           { fn=1 }
		/^_close_conflicting_pr_comment_not_landed\(\) \{$/       { fn=1 }
		/^_close_conflicting_pr\(\) \{$/                          { fn=1 }
		fn { print }
		fn && /^\}$/ { fn=0 }
	' "$src" >"$tmp_fn"

	# _carry_forward_pr_diff is called by the "not-landed" branch; stub it
	# so the carry-forward side effect doesn't try to hit gh during tests.
	# The stubbed gh would satisfy it too, but declaring the function
	# explicitly keeps the test hermetic.
	cat >>"$tmp_fn" <<'STUB_EOF'
_carry_forward_pr_diff() { return 0; }
_extract_linked_issue() { return 0; }
_close_superseded_duplicate_issue_if_verified() { return 0; }
STUB_EOF

	# shellcheck source=/dev/null
	source "$tmp_fn"
	return 0
}

# Helper to write per-test response files.
# Optional 4th arg: pr-meta JSON for _close_conflicting_pr_check_ownership_guard.
# Default simulates a worker-origin PR (origin:worker label, bot author) so
# existing tests that expect closes are unaffected by GH#20485.
set_responses() {
	local commits_json="$1"
	local commit_files="$2"
	local pr_files="$3"
	local pr_meta_json="${4:-}"
	printf '%s' "$commits_json" >"${TEST_ROOT}/commits.json"
	printf '%s' "$commit_files" >"${TEST_ROOT}/commit-files.txt"
	printf '%s' "$pr_files" >"${TEST_ROOT}/pr-files.txt"
	# Default empty labels (no origin:interactive)
	: >"${TEST_ROOT}/pr-labels.txt"
	echo "feature/test" >"${TEST_ROOT}/pr-branch.txt"
	echo "develop" >"${TEST_ROOT}/pr-base-branch.txt"
	# GH#20485/GH#29170: ownership guard metadata. Default = worker-origin bot PR
	# so existing close-path tests still proceed to the close logic.
	if [[ -n "$pr_meta_json" ]]; then
		printf '%s' "$pr_meta_json" >"${TEST_ROOT}/pr-meta.json"
	else
		printf '%s' '{"labels":[{"name":"origin:worker"}],"author":{"login":"aidevops-worker[bot]"}}' \
			>"${TEST_ROOT}/pr-meta.json"
	fi
	return 0
}

# ── Test cases ──

test_wording_with_squash_merge_pr_number() {
	setup_sandbox
	# Matching commit has the standard squash-merge "(#18480)" suffix AND
	# touches the same implementation file as the closing PR — genuine duplicate.
	set_responses \
		'[{"sha":"abc1234567890abcdef","subject":"t2017: teach /review-issue-pr to do temporal-duplicate checks (#18480)"},{"sha":"def4567890abcdef","subject":"chore: something else"}]' \
		'.agents/workflows/review-issue-pr.md' \
		'.agents/workflows/review-issue-pr.md'

	load_functions_under_test

	_close_conflicting_pr "18486" "marcusquinn/aidevops" \
		"t2017: enhance /review-issue-pr with temporal-duplicate checks"

	local body
	body=$(cat "$CAPTURED_COMMENT_FILE")

	local result=0
	if ! printf '%s' "$body" | grep -q "has already landed on develop (via PR #18480)"; then
		result=1
	fi
	if printf '%s' "$body" | grep -q "committed directly to main"; then
		result=1
	fi

	print_result "cites '(via PR #NNN)' when matching commit has squash-merge suffix" \
		"$result" \
		"got: $(printf '%s' "$body" | head -c 200)"
	teardown_sandbox
	return 0
}

test_wording_without_pr_number_fallback() {
	setup_sandbox
	# Matching commit is a direct-to-main commit with no "(#NNN)" suffix
	# but DOES touch the same implementation file → genuine duplicate.
	set_responses \
		'[{"sha":"abc1234567890abcdef","subject":"t2017: direct push to main without going through a PR"},{"sha":"def4567890abcdef","subject":"chore: unrelated"}]' \
		'.agents/workflows/review-issue-pr.md' \
		'.agents/workflows/review-issue-pr.md'

	load_functions_under_test

	_close_conflicting_pr "18486" "marcusquinn/aidevops" \
		"t2017: enhance /review-issue-pr"

	local body
	body=$(cat "$CAPTURED_COMMENT_FILE")

	local result=0
	if ! printf '%s' "$body" | grep -q "has already landed on develop,"; then
		result=1
	fi
	if printf '%s' "$body" | grep -q "(via PR #"; then
		result=1
	fi
	if printf '%s' "$body" | grep -q "committed directly to main"; then
		result=1
	fi

	print_result "omits parenthetical when no PR number parseable" \
		"$result" \
		"got: $(printf '%s' "$body" | head -c 200)"
	teardown_sandbox
	return 0
}

test_no_match_uses_fallback_message() {
	setup_sandbox
	# No commit on main matches the task ID → falls through to the
	# "work NOT on main" branch; comment must NOT claim it landed.
	set_responses \
		'[{"sha":"abc1234567890abcdef","subject":"chore: totally unrelated commit"},{"sha":"def4567890abcdef","subject":"feat: still unrelated"}]' \
		'.agents/workflows/review-issue-pr.md' \
		'.agents/workflows/review-issue-pr.md'

	load_functions_under_test

	_close_conflicting_pr "18486" "marcusquinn/aidevops" \
		"t2017: enhance /review-issue-pr"

	local body
	body=$(cat "$CAPTURED_COMMENT_FILE")

	local result=0
	if printf '%s' "$body" | grep -q "landed on develop"; then
		result=1
	fi
	if printf '%s' "$body" | grep -q "committed directly to main"; then
		result=1
	fi
	if ! printf '%s' "$body" | grep -q "merge conflicts"; then
		result=1
	fi

	print_result "no-match uses 're-attempt' fallback, not 'landed on base branch'" \
		"$result" \
		"got: $(printf '%s' "$body" | head -c 200)"
	teardown_sandbox
	return 0
}

# GH#18815 regression: reproduces the PR #18760 false-positive close.
# The matching commit only touches planning files (TODO.md + briefs); the
# closing PR touches an implementation script. The function MUST NOT close.
test_no_close_when_matching_commit_only_touches_planning_files() {
	setup_sandbox
	set_responses \
		'[{"sha":"deadbeefcafe1234","subject":"plan(t2059, t2060): file follow-ups from GH#18538 worker-is-triager session (#18749)"},{"sha":"def4567890abcdef","subject":"chore: unrelated"}]' \
		"$(printf 'TODO.md\ntodo/tasks/t2059-brief.md\ntodo/tasks/t2060-brief.md')" \
		"$(printf '.agents/scripts/task-complete-helper.sh\n.agents/scripts/tests/test-task-complete-move.sh\nTODO.md')"

	load_functions_under_test

	_close_conflicting_pr "18760" "marcusquinn/aidevops" \
		"t2060: fix(task-complete-helper): move completed entries to ## Done instead of in-place marking"

	local body
	body=$(cat "$CAPTURED_COMMENT_FILE")

	local result=0
	# Must NOT have called gh pr close (captured comment file is empty)
	if [[ -s "$CAPTURED_COMMENT_FILE" ]]; then
		result=1
	fi
	# Must have logged the false-positive detection
	if ! grep -q "false-positive heuristic" "$LOGFILE"; then
		result=1
	fi
	if ! grep -q "GH#18815" "$LOGFILE"; then
		result=1
	fi

	print_result "GH#18815: planning-only match leaves PR open (no close)" \
		"$result" \
		"captured-comment=$(printf '%s' "$body" | head -c 100); log=$(head -3 "$LOGFILE")"
	teardown_sandbox
	return 0
}

# GH#18815 regression: confirms genuine duplicates (real implementation
# file overlap) still close as before.
test_close_when_matching_commit_overlaps_implementation_files() {
	setup_sandbox
	set_responses \
		'[{"sha":"abc1234567890abcdef","subject":"t2060: fix(task-complete-helper) (#18999)"},{"sha":"def4567890abcdef","subject":"chore: unrelated"}]' \
		"$(printf '.agents/scripts/task-complete-helper.sh\nTODO.md')" \
		"$(printf '.agents/scripts/task-complete-helper.sh\n.agents/scripts/tests/test-task-complete-move.sh\nTODO.md')"

	load_functions_under_test

	_close_conflicting_pr "18760" "marcusquinn/aidevops" \
		"t2060: fix(task-complete-helper): move completed entries to ## Done instead of in-place marking"

	local body
	body=$(cat "$CAPTURED_COMMENT_FILE")

	local result=0
	if [[ ! -s "$CAPTURED_COMMENT_FILE" ]]; then
		result=1
	fi
	if ! printf '%s' "$body" | grep -q "has already landed on develop (via PR #18999)"; then
		result=1
	fi

	print_result "GH#18815: real implementation overlap still closes PR" \
		"$result" \
		"got: $(printf '%s' "$body" | head -c 200)"
	teardown_sandbox
	return 0
}

# GH#18815 regression: file lookup failure → fail-CLOSED → no auto-close.
# Simulates a gh API failure on the commit-files lookup.
test_no_close_when_commit_files_lookup_fails() {
	setup_sandbox
	set_responses \
		'[{"sha":"abc1234567890abcdef","subject":"t2060: fix(task-complete-helper) (#18999)"}]' \
		'' \
		"$(printf '.agents/scripts/task-complete-helper.sh\nTODO.md')"

	load_functions_under_test

	_close_conflicting_pr "18760" "marcusquinn/aidevops" \
		"t2060: fix(task-complete-helper): move completed entries to ## Done instead of in-place marking"

	local body
	body=$(cat "$CAPTURED_COMMENT_FILE")

	local result=0
	if [[ -s "$CAPTURED_COMMENT_FILE" ]]; then
		result=1
	fi
	if ! grep -q "false-positive heuristic" "$LOGFILE"; then
		result=1
	fi

	print_result "GH#18815: commit-files lookup failure leaves PR open (fail-CLOSED)" \
		"$result" \
		"captured-comment=$(printf '%s' "$body" | head -c 100); log=$(head -3 "$LOGFILE")"
	teardown_sandbox
	return 0
}

# GH#18815 regression: PR-files lookup failure → fail-CLOSED → no auto-close.
test_no_close_when_pr_files_lookup_fails() {
	setup_sandbox
	set_responses \
		'[{"sha":"abc1234567890abcdef","subject":"t2060: fix(task-complete-helper) (#18999)"}]' \
		"$(printf '.agents/scripts/task-complete-helper.sh\nTODO.md')" \
		''

	load_functions_under_test

	_close_conflicting_pr "18760" "marcusquinn/aidevops" \
		"t2060: fix(task-complete-helper): move completed entries to ## Done instead of in-place marking"

	local body
	body=$(cat "$CAPTURED_COMMENT_FILE")

	local result=0
	if [[ -s "$CAPTURED_COMMENT_FILE" ]]; then
		result=1
	fi
	if ! grep -q "false-positive heuristic" "$LOGFILE"; then
		result=1
	fi

	print_result "GH#18815: PR-files lookup failure leaves PR open (fail-CLOSED)" \
		"$result" \
		"captured-comment=$(printf '%s' "$body" | head -c 100); log=$(head -3 "$LOGFILE")"
	teardown_sandbox
	return 0
}

# ── GH#20485: External contributor PR protection ──

# GH#20485: Non-bot author with no origin label → skip close, post nudge.
test_no_close_for_external_contributor_pr() {
	setup_sandbox
	# No task-ID match on main, so the flow reaches Gate 1. PR has no origin
	# label and a human contributor author — must NOT be closed.
	set_responses \
		'[{"sha":"abc1234567890abcdef","subject":"chore: unrelated commit"},{"sha":"def4567890abcdef","subject":"feat: also unrelated"}]' \
		'.agents/scripts/pulse-merge-conflict.sh' \
		'.agents/scripts/pulse-merge-conflict.sh' \
		'{"labels":[],"author":{"login":"superdav42"}}'

	load_functions_under_test

	# Stub _gh_idempotent_comment so we can detect the nudge post attempt
	_gh_idempotent_comment() { return 0; }

	_close_conflicting_pr "20485" "marcusquinn/aidevops" \
		"superdav42: my feature"

	local result=0
	# Must NOT have called gh pr close (captured comment file is empty)
	if [[ -s "$CAPTURED_COMMENT_FILE" ]]; then
		result=1
	fi
	# Must have logged the contributor protection
	if ! grep -q "GH#20485" "$LOGFILE"; then
		result=1
	fi
	if ! grep -q "superdav42" "$LOGFILE"; then
		result=1
	fi

	print_result "GH#20485: external contributor PR left open (no close)" \
		"$result" \
		"captured-comment=$(cat "$CAPTURED_COMMENT_FILE" | head -c 100); log=$(head -5 "$LOGFILE")"
	teardown_sandbox
	return 0
}

# GH#20485: origin:worker label present → proceed with close (pulse owns it).
test_close_for_worker_origin_pr() {
	setup_sandbox
	# No commit match, worker PR → should close.
	set_responses \
		'[{"sha":"abc1234567890abcdef","subject":"chore: unrelated commit"}]' \
		'.agents/scripts/pulse-merge-conflict.sh' \
		'.agents/scripts/pulse-merge-conflict.sh' \
		'{"labels":[{"name":"origin:worker"}],"author":{"login":"superdav42"}}'

	load_functions_under_test

	_close_conflicting_pr "20486" "marcusquinn/aidevops" \
		"t9999: worker-created PR"

	local result=0
	# origin:worker → guard returns 1 → close proceeds
	if [[ ! -s "$CAPTURED_COMMENT_FILE" ]]; then
		result=1
	fi
	if ! grep -q "merge conflicts" "$(cat "$CAPTURED_COMMENT_FILE" 2>/dev/null || true)" 2>/dev/null; then
		# check the comment has the expected text
		local body
		body=$(cat "$CAPTURED_COMMENT_FILE" 2>/dev/null || true)
		if ! printf '%s' "$body" | grep -q "merge conflicts"; then
			result=1
		fi
	fi

	print_result "GH#20485: origin:worker PR is still closed on conflicts" \
		"$result" \
		"captured=$(cat "$CAPTURED_COMMENT_FILE" | head -c 150)"
	teardown_sandbox
	return 0
}

# GH#20485: origin:worker-takeover label → proceed with close (ownership transferred).
test_close_for_worker_takeover_pr() {
	setup_sandbox
	set_responses \
		'[{"sha":"abc1234567890abcdef","subject":"chore: unrelated commit"}]' \
		'.agents/scripts/pulse-merge-conflict.sh' \
		'.agents/scripts/pulse-merge-conflict.sh' \
		'{"labels":[{"name":"origin:worker-takeover"},{"name":"origin:interactive"}],"author":{"login":"marcusquinn"}}'

	load_functions_under_test

	_close_conflicting_pr "20487" "marcusquinn/aidevops" \
		"t9999: worker-takeover PR"

	local result=0
	# origin:worker-takeover → guard returns 1 → close proceeds
	# (even though origin:interactive is also present; worker-takeover takes precedence
	# over interactive in the guard because worker-takeover is checked first)
	# Actually: interactive is checked FIRST and returns 0 (skip). Test expects no-close.
	# Correction: origin:interactive guard fires first → no close.
	# This tests that origin:worker-takeover WITHOUT origin:interactive → close.

	teardown_sandbox

	# Re-run without origin:interactive
	setup_sandbox
	set_responses \
		'[{"sha":"abc1234567890abcdef","subject":"chore: unrelated commit"}]' \
		'.agents/scripts/pulse-merge-conflict.sh' \
		'.agents/scripts/pulse-merge-conflict.sh' \
		'{"labels":[{"name":"origin:worker-takeover"}],"author":{"login":"superdav42"}}'

	load_functions_under_test

	_close_conflicting_pr "20488" "marcusquinn/aidevops" \
		"t9999: worker-takeover PR"

	if [[ ! -s "$CAPTURED_COMMENT_FILE" ]]; then
		result=1
	fi

	print_result "GH#20485: origin:worker-takeover PR is closed on conflicts" \
		"$result" \
		"captured=$(cat "$CAPTURED_COMMENT_FILE" | head -c 150)"
	teardown_sandbox
	return 0
}

# GH#20485: bot author with no origin label → proceed with close (no human loses work).
test_close_for_bot_author_no_label_pr() {
	setup_sandbox
	set_responses \
		'[{"sha":"abc1234567890abcdef","subject":"chore: unrelated commit"}]' \
		'.agents/scripts/pulse-merge-conflict.sh' \
		'.agents/scripts/pulse-merge-conflict.sh' \
		'{"labels":[],"author":{"login":"dependabot[bot]"}}'

	load_functions_under_test

	_close_conflicting_pr "20489" "marcusquinn/aidevops" \
		"chore: dependabot update"

	local result=0
	if [[ ! -s "$CAPTURED_COMMENT_FILE" ]]; then
		result=1
	fi

	print_result "GH#20485: bot-author PR with no origin label is still closed" \
		"$result" \
		"captured=$(cat "$CAPTURED_COMMENT_FILE" | head -c 150)"
	teardown_sandbox
	return 0
}

# GH#20485: metadata fetch failure → fail CLOSED → no close.
test_no_close_on_metadata_fetch_failure() {
	# Simulate gh pr view returning non-zero for the REST-preservable metadata shape.
	local tmp_sandbox
	tmp_sandbox=$(mktemp -d)
	local stub_dir="${tmp_sandbox}/stubs"
	local captured="${tmp_sandbox}/captured.txt"
	local log_file="${tmp_sandbox}/pulse.log"
	mkdir -p "$stub_dir"
	: >"$captured"
	: >"$log_file"

	# Write a stub that fails on the metadata fetch
	cat >"${stub_dir}/gh" <<STUB_EOF
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  field=""
  args=("\$@")
  i=2
  while [[ \$i -lt \${#args[@]} ]]; do
    if [[ "\${args[\$i]}" == "--json" ]]; then
      j=\$((i + 1))
      field="\${args[\$j]}"
      break
    fi
    i=\$((i + 1))
  done
  if [[ "\$field" == "labels,author" ]]; then
    exit 1
  fi
fi
exit 0
STUB_EOF
	chmod +x "${stub_dir}/gh"

	local old_path="$PATH"
	export PATH="${stub_dir}:${PATH}"
	export LOGFILE="$log_file"

	# Source functions from the real script
	local repo_root
	repo_root=$(cd "$(dirname "$0")/../../.." && pwd)
	local src="${repo_root}/.agents/scripts/pulse-merge-conflict.sh"
	local tmp_fn="${tmp_sandbox}/funcs.sh"
	awk '
		/^_post_rebase_nudge_on_interactive_conflicting\(\) \{$/ { fn=1 }
		/^_post_rebase_nudge_on_contributor_conflicting\(\) \{$/  { fn=1 }
		/^_is_planning_path_for_overlap\(\) \{$/                  { fn=1 }
		/^_verify_pr_overlaps_commit\(\) \{$/                     { fn=1 }
		/^_post_rebase_nudge_on_worker_conflicting\(\) \{$/       { fn=1 }
		/^_parse_squash_merge_pr\(\) \{$/                         { fn=1 }
		/^_find_task_id_match_on_main\(\) \{$/                    { fn=1 }
		/^_close_conflicting_pr_check_ownership_guard\(\) \{$/    { fn=1 }
		/^_close_conflicting_pr_classify_landed\(\) \{$/          { fn=1 }
		/^_close_conflicting_pr_comment_landed\(\) \{$/           { fn=1 }
		/^_close_conflicting_pr_comment_not_landed\(\) \{$/       { fn=1 }
		/^_close_conflicting_pr\(\) \{$/                          { fn=1 }
		fn { print }
		fn && /^\}$/ { fn=0 }
	' "$src" >"$tmp_fn"
	cat >>"$tmp_fn" <<'STUB_EOF'
_carry_forward_pr_diff() { return 0; }
_extract_linked_issue() { return 0; }
STUB_EOF
	# shellcheck source=/dev/null
	source "$tmp_fn"

	_close_conflicting_pr "99999" "marcusquinn/aidevops" "t9999: metadata-fail test"

	local result=0
	if [[ -s "$captured" ]]; then
		result=1
	fi
	if ! grep -q "failed to fetch metadata" "$log_file"; then
		result=1
	fi

	export PATH="$old_path"
	rm -rf "$tmp_sandbox"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$result" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "GH#20485: metadata fetch failure leaves PR open (fail-CLOSED)"
	else
		printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "GH#20485: metadata fetch failure leaves PR open (fail-CLOSED)"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# ── Run all tests ──

test_wording_with_squash_merge_pr_number
test_wording_without_pr_number_fallback
test_no_match_uses_fallback_message
test_no_close_when_matching_commit_only_touches_planning_files
test_close_when_matching_commit_overlaps_implementation_files
test_no_close_when_commit_files_lookup_fails
test_no_close_when_pr_files_lookup_fails
test_no_close_for_external_contributor_pr
test_close_for_worker_origin_pr
test_close_for_worker_takeover_pr
test_close_for_bot_author_no_label_pr
test_no_close_on_metadata_fetch_failure

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
