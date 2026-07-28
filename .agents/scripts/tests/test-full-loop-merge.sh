#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-full-loop-merge.sh — Regression tests for _merge_execute admin fallback signaling (t2247)
#
# Verifies:
#   1. Admin fallback fires all three signaling artifacts (PR comment, audit log, label)
#   2. Explicit --admin caller does NOT trigger extra signaling (back-compat)
#   3. Non-branch-protection errors do NOT trigger fallback
#   4. GraphQL rate-limit errors fall back to REST pull merge after the gate
#   5. Review-gate failures prevent both CLI merge and REST fallback
#   6. Interactive --auto review-policy blocks fall through to --admin only
#      after PR readiness and maintainer-review gates pass
#   7. Post-merge verification retries cache-disabled reads without replaying
#      the irreversible merge mutation
#   8. Squash merges use the validated PR title as an explicit subject and
#      reject invalid titles before any merge mutation
#
# Strategy: stub gh, audit-log-helper.sh, and gh-signature-helper.sh in a temp
# directory prepended to PATH, then source the merge sub-library.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
HANDOFF_ROOT=""
HANDOFF_REPO=""
HANDOFF_RECEIPT_DIR=""
HANDOFF_RECEIPT=""
HANDOFF_SOURCE_HEAD=""
HANDOFF_PUBLISHED_COMMIT=""

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
	mkdir -p "${TEST_ROOT}/bin"
	mkdir -p "${TEST_ROOT}/logs"

	# Stub gh-signature-helper.sh
	cat >"${TEST_ROOT}/bin/gh-signature-helper.sh" <<'STUB'
#!/usr/bin/env bash
echo "---"
echo "test-signature-footer"
STUB
	chmod +x "${TEST_ROOT}/bin/gh-signature-helper.sh"

	# Stub audit-log-helper.sh — records invocations to a log file
	cat >"${TEST_ROOT}/bin/audit-log-helper.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${TEST_ROOT}/logs/audit-log-calls.txt"
STUB
	chmod +x "${TEST_ROOT}/bin/audit-log-helper.sh"

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

write_gh_stub_header() {
	local mode="$1"

	cat >"${TEST_ROOT}/bin/gh" <<GHSTUB
#!/usr/bin/env bash
# Log all gh calls
_gh_cmd="\$1"
_gh_sub="\$2"
echo "gh \$*" >> "${TEST_ROOT}/logs/gh-calls.txt"

_merge_count_file="${TEST_ROOT}/logs/merge-count.txt"

if [[ "\$_gh_cmd" == "pr" && "\$_gh_sub" == "merge" ]]; then
	if [[ "$mode" == "stale-cache-401" ]]; then
		_merge_count=0
		if [[ -f "\$_merge_count_file" ]]; then
			_merge_count=\$(cat "\$_merge_count_file")
		fi
		_merge_count=\$((_merge_count + 1))
		printf '%s\n' "\$_merge_count" >"\$_merge_count_file"
		if [[ "\$_merge_count" -eq 1 ]]; then
			echo 'non-200 OK status code: 401 Unauthorized body: "{ \"message\": \"Requires authentication\" }"' >&2
			exit 1
		fi
		echo "Merged PR after cache remediation"
		exit 0
	fi

	# Check if --admin flag is present
	_gh_has_admin=0
	for _gh_arg in "\$@"; do
		if [[ "\$_gh_arg" == "--admin" ]]; then
			_gh_has_admin=1
		fi
	done

	if [[ "$mode" == "fallback" || "$mode" == "fallback-nmr" || "$mode" == "auto-review-required" ]]; then
		if [[ "\$_gh_has_admin" -eq 1 ]]; then
			echo "Merged PR"
			exit 0
		elif [[ "$mode" == "auto-review-required" ]]; then
			echo "At least 1 approving review is required; cannot approve your own pull request" >&2
			exit 1
		else
			echo "At least 1 approving review is required" >&2
			exit 1
		fi
	elif [[ "$mode" == "explicit-admin" ]]; then
		echo "Merged PR"
		exit 0
	elif [[ "$mode" == "other-error" ]]; then
		echo "Something completely different went wrong" >&2
		exit 1
	elif [[ "$mode" == "graphql-rate-limit" || "$mode" == "graphql-rate-limit-rest-fail" ]]; then
		echo "GraphQL: API rate limit already exceeded for user ID 12345. (rateLimitExceeded)" >&2
		exit 1
	fi
fi
GHSTUB
	return 0
}

write_gh_stub_pr_issue_views() {
	local mode="$1"

	cat >>"${TEST_ROOT}/bin/gh" <<GHSTUB

	if [[ "\$_gh_cmd" == "pr" && "\$_gh_sub" == "view" ]]; then
	if [[ "\$*" == *"--json title --jq .title"* ]]; then
		if [[ "$mode" == "invalid-squash-title" ]]; then
			echo 'Document recovery'
		else
			echo 'GH#28721: fix: preserve reviewed squash subject'
		fi
		exit 0
	fi
	if [[ "\$*" == *"--json state,isDraft,reviewDecision,headRefOid"* ]]; then
		_review_decision=""
		[[ "$mode" == "late-review-block" ]] && _review_decision="CHANGES_REQUESTED"
		printf '{"state":"OPEN","isDraft":false,"reviewDecision":"%s","headRefOid":"abc123headsha"}\n' "\$_review_decision"
		exit 0
	fi
	if [[ "\$*" == *"--json state,mergedAt,mergeCommit"* ]]; then
		_evidence_count=0
		if [[ -f "${TEST_ROOT}/logs/evidence-count.txt" ]]; then
			_evidence_count=\$(<"${TEST_ROOT}/logs/evidence-count.txt")
		fi
		_evidence_count=\$((_evidence_count + 1))
		printf '%s\n' "\$_evidence_count" >"${TEST_ROOT}/logs/evidence-count.txt"
		printf '%s\n' "\${AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE:-0}" >>"${TEST_ROOT}/logs/evidence-cache-control.txt"
		case "$mode" in
		post-merge-api-failure) exit 70 ;;
		post-merge-unmerged) echo '{"state":"OPEN","mergedAt":null,"mergeCommit":null}'; exit 0 ;;
		post-merge-stale)
			if [[ "\$_evidence_count" -eq 1 ]]; then
				echo '{"state":"OPEN","mergedAt":null,"mergeCommit":null}'
				exit 0
			fi
			;;
		esac
		echo '{"state":"MERGED","mergedAt":"2026-07-11T00:00:00Z","mergeCommit":{"oid":"merged123sha"}}'
		exit 0
	fi
	if [[ "\$*" == *"--json author,labels,isCrossRepository,headRefOid,closingIssuesReferences,body"* ]]; then
		if [[ "$mode" == "fallback-nmr" ]]; then
			echo '{"author":{"login":"tester"},"labels":[],"isCrossRepository":false,"headRefOid":"abc123headsha","closingIssuesReferences":[{"number":24354}],"body":"Resolves #22621"}'
		else
			echo '{"author":{"login":"tester"},"labels":[],"isCrossRepository":false,"headRefOid":"abc123headsha","closingIssuesReferences":[],"body":"Resolves #22621"}'
		fi
		exit 0
	fi
	if [[ "\$*" == *"--json isDraft,reviewDecision,statusCheckRollup"* ]]; then
		if [[ "$mode" == "auto-review-required" ]]; then
			echo '{"isDraft":false,"reviewDecision":"","statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS","status":"COMPLETED"}]}'
		else
			echo '{"isDraft":false,"reviewDecision":"","statusCheckRollup":[]}'
		fi
		exit 0
	fi
	if [[ "\$*" == *"--json closingIssuesReferences,body"* ]]; then
		if [[ "$mode" == "fallback-nmr" ]]; then
			echo '{"closingIssuesReferences":[{"number":24354}],"body":"Resolves #22621"}'
		else
			echo '{"closingIssuesReferences":[],"body":"Resolves #22621"}'
		fi
		exit 0
	fi
	if [[ "\$*" == *"--json closingIssuesReferences"* ]]; then
		if [[ "$mode" == "fallback-nmr" ]]; then
			echo '24354'
		else
			echo ''
		fi
		exit 0
	fi
	if [[ "\$*" == *"--json body"* ]]; then
		echo 'Resolves #22621'
		exit 0
	fi
	echo '{}'
	exit 0
fi

if [[ "\$_gh_cmd" == "issue" && "\$_gh_sub" == "view" ]]; then
	if [[ "$mode" == "fallback-nmr" ]]; then
		echo 'needs-maintainer-review'
	else
		echo ''
	fi
	exit 0
fi
GHSTUB
	return 0
}

write_gh_stub_api() {
	local mode="$1"

	cat >>"${TEST_ROOT}/bin/gh" <<GHSTUB

if [[ "\$_gh_cmd" == "api" ]]; then
	echo "gh api \$*" >> "${TEST_ROOT}/logs/gh-api-calls.txt"
	if [[ "\$*" == "user" ]]; then
		echo '{"login":"tester"}'
		exit 0
	fi
	if [[ "\$*" == *"repos/testorg/testrepo/collaborators/tester/permission"* ]]; then
		if [[ "\$*" == *" -i "* ]]; then
			printf 'HTTP/2 200\ncontent-type: application/json\n\n{"permission":"write"}\n'
		else
			echo 'write'
		fi
		exit 0
	fi
	if [[ "\$*" == *"repos/testorg/testrepo/pulls/42/merge"* ]]; then
		if [[ "$mode" == "graphql-rate-limit-rest-fail" ]]; then
			echo "REST merge failed" >&2
			exit 1
		fi
		echo '{"merged":true,"message":"Pull Request successfully merged"}'
		exit 0
	fi
	if [[ "\$*" == *"repos/testorg/testrepo/pulls/42"* ]]; then
		if [[ "$mode" == "head-fetch-failure" ]]; then
			echo 'transient pull lookup failure' >&2
			exit 1
		fi
		echo 'abc123headsha'
		exit 0
	fi
	echo '{}'
	exit 0
fi
GHSTUB
	return 0
}

write_gh_stub_pr_mutations() {
	cat >>"${TEST_ROOT}/bin/gh" <<GHSTUB

if [[ "\$_gh_cmd" == "pr" && "\$_gh_sub" == "comment" ]]; then
	echo "pr comment \$*" >> "${TEST_ROOT}/logs/pr-comments.txt"
	exit 0
fi

if [[ "\$_gh_cmd" == "pr" && "\$_gh_sub" == "edit" ]]; then
	echo "pr edit \$*" >> "${TEST_ROOT}/logs/pr-edits.txt"
	exit 0
fi

# Default: succeed silently
exit 0
GHSTUB
	return 0
}

# Create a gh stub that simulates merge behavior.
# Args:
#   $1 = "fallback" — first merge fails with branch-protection error, --admin succeeds
#   $2 = "explicit-admin" — merge with --admin succeeds immediately (no fallback)
#   $3 = "other-error" — merge fails with non-branch-protection error
#   $4 = "graphql-rate-limit" — gh pr merge fails with GraphQL quota, REST succeeds
#   $5 = "graphql-rate-limit-rest-fail" — gh pr merge fails with GraphQL quota, REST fails
#   $6 = "fallback-nmr" — branch protection fails, but linked issue still needs maintainer review
#   $7 = "stale-cache-401" — first gh pr merge returns cached 401, live auth succeeds, retry succeeds
#   $8 = "auto-review-required" — --auto is blocked only by self-review policy; --admin succeeds
create_gh_stub() {
	local mode="$1"

	write_gh_stub_header "$mode"
	write_gh_stub_pr_issue_views "$mode"
	write_gh_stub_api "$mode"
	write_gh_stub_pr_mutations
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# Run _merge_execute in an isolated subprocess.
# Sources the full-loop merge sub-library directly with shared constants loaded
# so we get merge functions without invoking the full-loop main entrypoint.
# Args: pr_number repo merge_method has_admin has_auto
run_merge_execute() {
	local pr_number="$1"
	local repo="$2"
	local merge_method="$3"
	local has_admin="$4"
	local has_auto="$5"

	local scripts_dir="${SCRIPT_DIR}/.."

	# Build a temporary script that sources the merge helper in isolation.
	# Using a temp file avoids heredoc/process-substitution escaping issues with $.
	local tmp_runner=""
	tmp_runner=$(mktemp)
	cat >"$tmp_runner" <<RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${scripts_dir}'
source '${scripts_dir}/shared-constants.sh'
source '${scripts_dir}/full-loop-helper-merge.sh'
_merge_guard_prospective_todo() { return 0; }
_merge_execute '$pr_number' '$repo' '$merge_method' '$has_admin' '$has_auto'
RUNNER_EOF
	chmod +x "$tmp_runner"

	# Run in a subprocess with our stubs on PATH
	local rc=0
	env PATH="${TEST_ROOT}/bin:${scripts_dir}:${PATH}" \
		HOME="${TEST_ROOT}/home" \
		FULL_LOOP_HEADLESS="${FULL_LOOP_HEADLESS:-}" \
		FULL_LOOP_VERIFIED_PR_HEAD_SHA="${FULL_LOOP_VERIFIED_PR_HEAD_SHA:-}" \
		AIDEVOPS_HEADLESS= \
		Claude_HEADLESS= \
		GITHUB_ACTIONS= \
		AIDEVOPS_MODEL="test-model" \
		bash "$tmp_runner" 2>&1 || rc=$?
	rm -f "$tmp_runner"
	return $rc
}

# Run cmd_merge in an isolated subprocess with a controlled review-bot gate.
# Args: pr_number repo gate_rc
run_cmd_merge_with_gate() {
	local pr_number="$1"
	local repo="$2"
	local gate_rc="$3"
	local scripts_dir="${SCRIPT_DIR}/.."
	local tmp_runner=""
	tmp_runner=$(mktemp)
	cat >"$tmp_runner" <<RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${scripts_dir}'
source '${scripts_dir}/shared-constants.sh'
source '${scripts_dir}/full-loop-helper-merge.sh'
cmd_pre_merge_gate() { return '${gate_rc}'; }
_merge_guard_prospective_todo() { return 0; }
_retarget_stacked_children_interactive() { return 0; }
release_interactive_claim_on_merge() { return 0; }
auto_file_next_phase() { printf '%s %s\n' "\$1" "\$2" >> "${TEST_ROOT}/logs/phase-autofile.txt"; return 0; }
cmd_merge '$pr_number' '$repo'
RUNNER_EOF
	chmod +x "$tmp_runner"

	local rc=0
	env PATH="${TEST_ROOT}/bin:${scripts_dir}:${PATH}" \
		HOME="${TEST_ROOT}/home" \
		FULL_LOOP_HEADLESS="${FULL_LOOP_HEADLESS:-}" \
		AIDEVOPS_MODEL="test-model" \
		bash "$tmp_runner" 2>&1 || rc=$?
	rm -f "$tmp_runner"
	return $rc
}

# Run cmd_merge with a counted finalizer and bounded evidence retries.
# Args: pr_number repo
run_cmd_merge_for_evidence() {
	local pr_number="$1"
	local repo="$2"
	local scripts_dir="${SCRIPT_DIR}/.."
	local tmp_runner=""
	tmp_runner=$(mktemp)
	cat >"$tmp_runner" <<RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${scripts_dir}'
source '${scripts_dir}/shared-constants.sh'
source '${scripts_dir}/full-loop-helper-merge.sh'
cmd_pre_merge_gate() { return 0; }
_merge_guard_prospective_todo() { return 0; }
_retarget_stacked_children_interactive() { return 0; }
_merge_report_canonical_sync_state() { return 0; }
_merge_finalize_post_merge() {
	local count=0
	[[ -f '${TEST_ROOT}/logs/finalize-count.txt' ]] && count=\$(<'${TEST_ROOT}/logs/finalize-count.txt')
	count=\$((count + 1))
	printf '%s\n' "\$count" >'${TEST_ROOT}/logs/finalize-count.txt'
	return 0
}
cmd_merge '$pr_number' '$repo'
RUNNER_EOF
	chmod +x "$tmp_runner"

	local rc=0
	env PATH="${TEST_ROOT}/bin:${scripts_dir}:${PATH}" \
		HOME="${TEST_ROOT}/home" \
		FULL_LOOP_MERGED_EVIDENCE_ATTEMPTS=2 \
		FULL_LOOP_MERGED_EVIDENCE_DELAY_SECONDS=0 \
		AIDEVOPS_MODEL="test-model" \
		bash "$tmp_runner" 2>&1 || rc=$?
	rm -f "$tmp_runner"
	return $rc
}

# Test 1: Admin fallback fires and produces all three signaling artifacts
test_admin_fallback_signals() {
	# Clear logs
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "fallback"

	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" >/dev/null 2>&1 || true

	# (a) Check PR comment was posted
	local pr_comment_posted=0
	if [[ -f "${TEST_ROOT}/logs/pr-comments.txt" ]]; then
		if grep -q "pr comment" "${TEST_ROOT}/logs/pr-comments.txt"; then
			pr_comment_posted=1
		fi
	fi
	print_result "admin fallback: PR comment posted" "$((1 - pr_comment_posted))"

	# (b) Check audit log was called
	local audit_logged=0
	if [[ -f "${TEST_ROOT}/logs/audit-log-calls.txt" ]]; then
		if grep -q "merge-admin-fallback" "${TEST_ROOT}/logs/audit-log-calls.txt"; then
			audit_logged=1
		fi
	fi
	print_result "admin fallback: audit log entry written" "$((1 - audit_logged))"

	# (c) Check admin-merge label was applied
	local label_applied=0
	if [[ -f "${TEST_ROOT}/logs/pr-edits.txt" ]]; then
		if grep -q "admin-merge" "${TEST_ROOT}/logs/pr-edits.txt"; then
			label_applied=1
		fi
	fi
	print_result "admin fallback: admin-merge label applied" "$((1 - label_applied))"

	return 0
}

# Test 2b: Admin fallback refuses to bypass a linked issue still needing maintainer review.
test_admin_fallback_blocks_needs_maintainer_review_issue() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "fallback-nmr"

	local exit_code=0
	local out=""
	out=$(run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" 2>&1) || exit_code=$?
	print_result "admin fallback: needs-maintainer-review blocks merge" "$((exit_code == 0 ? 1 : 0))" "output=$out"

	local admin_called=0
	if [[ -f "${TEST_ROOT}/logs/gh-calls.txt" ]] && grep -q -- '--admin' "${TEST_ROOT}/logs/gh-calls.txt"; then
		admin_called=1
	fi
	print_result "admin fallback: blocked before --admin retry" "$admin_called"

	local signaled=0
	if [[ -f "${TEST_ROOT}/logs/pr-comments.txt" ]] ||
		[[ -f "${TEST_ROOT}/logs/audit-log-calls.txt" ]] ||
		[[ -f "${TEST_ROOT}/logs/pr-edits.txt" ]]; then
		signaled=1
	fi
	print_result "admin fallback: no success signaling when maintainer gate blocks" "$signaled"

	return 0
}

# Test 2: Explicit --admin caller does NOT trigger extra signaling
test_explicit_admin_no_signaling() {
	# Clear logs
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "explicit-admin"

	run_merge_execute "42" "testorg/testrepo" "--squash" "1" "0" >/dev/null 2>&1 || true

	# PR comment should NOT have been posted (explicit --admin is not a fallback)
	local pr_comment_posted=0
	if [[ -f "${TEST_ROOT}/logs/pr-comments.txt" ]]; then
		if grep -q "pr comment" "${TEST_ROOT}/logs/pr-comments.txt"; then
			pr_comment_posted=1
		fi
	fi
	print_result "explicit --admin: no extra PR comment" "$pr_comment_posted"

	# Audit log should NOT have been called
	local audit_logged=0
	if [[ -f "${TEST_ROOT}/logs/audit-log-calls.txt" ]]; then
		if grep -q "merge-admin-fallback" "${TEST_ROOT}/logs/audit-log-calls.txt"; then
			audit_logged=1
		fi
	fi
	print_result "explicit --admin: no extra audit log" "$audit_logged"

	# Label should NOT have been applied
	local label_applied=0
	if [[ -f "${TEST_ROOT}/logs/pr-edits.txt" ]]; then
		if grep -q "admin-merge" "${TEST_ROOT}/logs/pr-edits.txt"; then
			label_applied=1
		fi
	fi
	print_result "explicit --admin: no admin-merge label" "$label_applied"

	return 0
}

# Test 3: Non-branch-protection errors do NOT trigger fallback at all
test_other_error_no_fallback() {
	# Clear logs
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "other-error"

	local exit_code=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" >/dev/null 2>&1 || exit_code=$?

	# Should have failed (exit code != 0)
	print_result "other error: merge fails without fallback" "$((exit_code == 0 ? 1 : 0))"

	# No signaling should have fired
	local any_signaling=0
	if [[ -f "${TEST_ROOT}/logs/pr-comments.txt" ]] ||
		[[ -f "${TEST_ROOT}/logs/audit-log-calls.txt" ]] ||
		[[ -f "${TEST_ROOT}/logs/pr-edits.txt" ]]; then
		any_signaling=1
	fi
	print_result "other error: no signaling artifacts" "$any_signaling"

	return 0
}

test_late_review_blocks_every_merge_transport() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "late-review-block"

	local exit_code=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "1" "0" >/dev/null 2>&1 || exit_code=$?
	local merge_calls=0
	merge_calls=$(grep -c '^gh pr merge' "${TEST_ROOT}/logs/gh-calls.txt" 2>/dev/null || true)
	print_result "late review: live CHANGES_REQUESTED blocks merge" "$((exit_code == 0 ? 1 : 0))"
	print_result "late review: admin merge transport is never invoked" "$((merge_calls == 0 ? 0 : 1))" "merge_calls=$merge_calls"
	return 0
}

# Test 4: GraphQL rate-limit failures use the REST pull merge endpoint.
test_graphql_rate_limit_rest_fallback() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "graphql-rate-limit"

	local exit_code=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" >/dev/null 2>&1 || exit_code=$?
	print_result "GraphQL rate-limit: REST fallback succeeds" "$exit_code"

	local rest_called=0
	if [[ -f "${TEST_ROOT}/logs/gh-api-calls.txt" ]] &&
		grep -q "repos/testorg/testrepo/pulls/42/merge" "${TEST_ROOT}/logs/gh-api-calls.txt" &&
		grep -q "sha=abc123headsha" "${TEST_ROOT}/logs/gh-api-calls.txt" &&
		grep -q "merge_method=squash" "${TEST_ROOT}/logs/gh-api-calls.txt" &&
		grep -q "commit_title=GH#28721: fix: preserve reviewed squash subject" "${TEST_ROOT}/logs/gh-api-calls.txt"; then
		rest_called=1
	fi
	print_result "GraphQL rate-limit: REST pull merge endpoint called with verified SHA" "$((1 - rest_called))"

	return 0
}

# Test 5: GraphQL REST fallback through cmd_merge triggers sequential phase auto-filing.
test_graphql_rate_limit_cmd_merge_phase_autofile() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "graphql-rate-limit"

	local exit_code=0
	run_cmd_merge_with_gate "42" "testorg/testrepo" "0" >/dev/null 2>&1 || exit_code=$?
	print_result "GraphQL rate-limit cmd_merge: REST fallback succeeds" "$exit_code"

	local phase_called=0
	if [[ -f "${TEST_ROOT}/logs/phase-autofile.txt" ]] &&
		grep -q "22621 testorg/testrepo" "${TEST_ROOT}/logs/phase-autofile.txt"; then
		phase_called=1
	fi
	print_result "GraphQL rate-limit cmd_merge: phase autofile called for linked issue" "$((1 - phase_called))"

	return 0
}

# Test 6: REST fallback is not used for --auto because it would merge immediately.
test_graphql_rate_limit_auto_no_rest_fallback() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "graphql-rate-limit"

	local exit_code=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "1" >/dev/null 2>&1 || exit_code=$?
	print_result "GraphQL rate-limit with --auto: merge fails without immediate REST merge" "$((exit_code == 0 ? 1 : 0))"

	local rest_called=0
	if [[ -f "${TEST_ROOT}/logs/gh-api-calls.txt" ]] &&
		grep -q "repos/testorg/testrepo/pulls/42/merge" "${TEST_ROOT}/logs/gh-api-calls.txt"; then
		rest_called=1
	fi
	print_result "GraphQL rate-limit with --auto: REST fallback not called" "$rest_called"

	return 0
}

# Test 7: Review-bot gate failure prevents both gh pr merge and REST fallback.
test_review_gate_failure_blocks_rest_fallback() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "graphql-rate-limit"

	local exit_code=0
	run_cmd_merge_with_gate "42" "testorg/testrepo" "1" >/dev/null 2>&1 || exit_code=$?
	print_result "review gate failure: cmd_merge exits non-zero" "$((exit_code == 0 ? 1 : 0))"

	local merge_called=0
	if [[ -f "${TEST_ROOT}/logs/gh-calls.txt" ]] && grep -q "pr merge" "${TEST_ROOT}/logs/gh-calls.txt"; then
		merge_called=1
	fi
	print_result "review gate failure: gh pr merge not called" "$merge_called"

	local rest_called=0
	[[ -f "${TEST_ROOT}/logs/gh-api-calls.txt" ]] && rest_called=1
	print_result "review gate failure: REST fallback not called" "$rest_called"

	return 0
}

# Test 7b: Interactive --auto review-required block uses admin fallback when safe.
test_auto_review_required_interactive_admin_fallback() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "auto-review-required"

	local exit_code=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "1" >/dev/null 2>&1 || exit_code=$?
	print_result "auto review-required: interactive admin fallback succeeds" "$exit_code"

	local auto_called=0
	local admin_called=0
	if [[ -f "${TEST_ROOT}/logs/gh-calls.txt" ]]; then
		grep -q -- '--auto' "${TEST_ROOT}/logs/gh-calls.txt" && auto_called=1
		grep -q -- '--admin' "${TEST_ROOT}/logs/gh-calls.txt" && admin_called=1
	fi
	print_result "auto review-required: --auto attempted first" "$((1 - auto_called))"
	print_result "auto review-required: --admin fallback attempted" "$((1 - admin_called))"

	return 0
}

# Test 7c: Headless --auto review-required block does not admin-bypass.
test_auto_review_required_headless_no_admin_fallback() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "auto-review-required"

	local exit_code=0
	FULL_LOOP_HEADLESS=true run_merge_execute "42" "testorg/testrepo" "--squash" "0" "1" >/dev/null 2>&1 || exit_code=$?
	print_result "auto review-required headless: merge remains blocked" "$((exit_code == 0 ? 1 : 0))"

	local admin_called=0
	if [[ -f "${TEST_ROOT}/logs/gh-calls.txt" ]] && grep -q -- '--admin' "${TEST_ROOT}/logs/gh-calls.txt"; then
		admin_called=1
	fi
	print_result "auto review-required headless: --admin not attempted" "$admin_called"

	return 0
}

# Test 8: cached gh HTTP 401 is quarantined and gh pr merge is retried once.
test_stale_cache_401_retry() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	rm -rf "${TEST_ROOT:?}/home"
	mkdir -p "${TEST_ROOT}/home/.cache/gh/api" "${TEST_ROOT}/home/.cache/gh/graphql"
	cat >"${TEST_ROOT}/home/.cache/gh/graphql-401.cache" <<'CACHE'
HTTP/2.0 401 Unauthorized
X-Gh-Cache-Ttl: 24h0m0s
{"message":"Requires authentication","documentation_url":"https://docs.github.com/graphql"}
CACHE
	cat >"${TEST_ROOT}/home/.cache/gh/api/shared.cache" <<'CACHE'
HTTP/2.0 401 Unauthorized
X-Gh-Cache-Ttl: 24h0m0s
{"message":"Requires authentication","documentation_url":"https://docs.github.com/rest"}
CACHE
	cat >"${TEST_ROOT}/home/.cache/gh/graphql/shared.cache" <<'CACHE'
HTTP/2.0 401 Unauthorized
X-Gh-Cache-Ttl: 24h0m0s
{"message":"Requires authentication","documentation_url":"https://docs.github.com/graphql"}
CACHE
	cat >"${TEST_ROOT}/home/.cache/gh/healthy.cache" <<'CACHE'
HTTP/2.0 200 OK
{"data":{"viewer":{"login":"tester"}}}
CACHE

	create_gh_stub "stale-cache-401"

	local exit_code=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" >/dev/null 2>&1 || exit_code=$?
	print_result "stale gh cache 401: retry succeeds" "$exit_code"

	local merge_count="0"
	[[ -f "${TEST_ROOT}/logs/merge-count.txt" ]] && merge_count=$(cat "${TEST_ROOT}/logs/merge-count.txt")
	print_result "stale gh cache 401: gh pr merge called exactly twice" "$((merge_count == 2 ? 0 : 1))" "merge_count=${merge_count}"

	local stale_quarantined=0
	if [[ ! -f "${TEST_ROOT}/home/.cache/gh/graphql-401.cache" ]] && \
		find "${TEST_ROOT}/home/.cache/gh" -path '*/aidevops-quarantine-*/graphql-401.cache' -type f | grep -q .; then
		stale_quarantined=1
	fi
	print_result "stale gh cache 401: top-level 401 cache quarantined" "$((1 - stale_quarantined))"

	local collision_paths_preserved=0
	if [[ ! -f "${TEST_ROOT}/home/.cache/gh/api/shared.cache" ]] && \
		[[ ! -f "${TEST_ROOT}/home/.cache/gh/graphql/shared.cache" ]] && \
		find "${TEST_ROOT}/home/.cache/gh" -path '*/aidevops-quarantine-*/api/shared.cache' -type f | grep -q . && \
		find "${TEST_ROOT}/home/.cache/gh" -path '*/aidevops-quarantine-*/graphql/shared.cache' -type f | grep -q .; then
		collision_paths_preserved=1
	fi
	print_result "stale gh cache 401: quarantine preserves relative paths" "$((1 - collision_paths_preserved))"

	local healthy_preserved=0
	[[ -f "${TEST_ROOT}/home/.cache/gh/healthy.cache" ]] && healthy_preserved=1
	print_result "stale gh cache 401: healthy cache preserved" "$((1 - healthy_preserved))"

	return 0
}

# Test 9: 401 detection only matches authentication-shaped merge errors.
test_auth_401_detection_avoids_numeric_false_positives() {
	source "${SCRIPT_DIR}/../gh-merge-cache-remediation-lib.sh"

	local false_positive=0
	gh_merge_output_is_auth_401 "Merged PR #401" && false_positive=1
	print_result "auth 401 detection: PR number 401 is not auth" "$false_positive"

	false_positive=0
	gh_merge_output_is_auth_401 "Merged commit a401b2c" && false_positive=1
	print_result "auth 401 detection: SHA fragment 401 is not auth" "$false_positive"

	local auth_detected=0
	gh_merge_output_is_auth_401 "HTTP/2.0 401 Unauthorized" && auth_detected=1
	print_result "auth 401 detection: HTTP 401 remains auth" "$((1 - auth_detected))"

	return 0
}

# Test 10: PR readiness accepts pre-fetched JSON and does not call gh again.
test_pr_ready_accepts_prefetched_json() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	cat >"${TEST_ROOT}/bin/gh" <<GHSTUB
#!/usr/bin/env bash
echo "gh \$*" >> "${TEST_ROOT}/logs/gh-calls.txt"
exit 90
GHSTUB
	chmod +x "${TEST_ROOT}/bin/gh"

	local scripts_dir="${SCRIPT_DIR}/.."
	local tmp_runner=""
	tmp_runner=$(mktemp)
	cat >"$tmp_runner" <<RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${scripts_dir}'
source '${scripts_dir}/shared-constants.sh'
source '${scripts_dir}/full-loop-helper-merge.sh'
_merge_pr_ready_for_interactive_admin_bypass '42' 'testorg/testrepo' '{"isDraft":false,"reviewDecision":"","statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS","status":"COMPLETED"}]}'
RUNNER_EOF
	chmod +x "$tmp_runner"

	local rc=0
	env PATH="${TEST_ROOT}/bin:${scripts_dir}:${PATH}" bash "$tmp_runner" >/dev/null 2>&1 || rc=$?
	rm -f "$tmp_runner"

	print_result "PR readiness: prefetched passing JSON is accepted" "$rc"

	local gh_called=0
	[[ -f "${TEST_ROOT}/logs/gh-calls.txt" ]] && gh_called=1
	print_result "PR readiness: prefetched JSON skips gh pr view" "$gh_called"

	return 0
}

# Test 11: simplified passish check still blocks non-passing rollup entries.
test_pr_ready_blocks_nonpassing_rollup() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	local scripts_dir="${SCRIPT_DIR}/.."
	local tmp_runner=""
	tmp_runner=$(mktemp)
	cat >"$tmp_runner" <<RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${scripts_dir}'
source '${scripts_dir}/shared-constants.sh'
source '${scripts_dir}/full-loop-helper-merge.sh'
_merge_pr_ready_for_interactive_admin_bypass '42' 'testorg/testrepo' '{"isDraft":false,"reviewDecision":"","statusCheckRollup":[{"name":"ci","conclusion":"","status":"IN_PROGRESS"}]}'
RUNNER_EOF
	chmod +x "$tmp_runner"

	local rc=0
	env PATH="${TEST_ROOT}/bin:${scripts_dir}:${PATH}" bash "$tmp_runner" >/dev/null 2>&1 || rc=$?
	rm -f "$tmp_runner"

	print_result "PR readiness: non-passing rollup remains blocked" "$((rc == 0 ? 1 : 0))"

	return 0
}

# Test 12: A failed head lookup is reported as unavailable evidence, not drift.
test_verified_head_lookup_failure_is_not_reported_as_drift() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "head-fetch-failure"

	local output=""
	local rc=0
	output=$(FULL_LOOP_VERIFIED_PR_HEAD_SHA="verified123" run_merge_execute \
		"42" "testorg/testrepo" "--squash" "0" "0") || rc=$?
	print_result "verified head lookup failure: merge remains blocked" "$((rc == 0 ? 1 : 0))"

	local reports_retrieval_failure=0
	[[ "$output" == *"Could not retrieve PR #42 head SHA for verification"* ]] && reports_retrieval_failure=1
	print_result "verified head lookup failure: retrieval error is explicit" "$((1 - reports_retrieval_failure))"

	local reports_false_drift=0
	[[ "$output" == *"head changed after remote verification"* ]] && reports_false_drift=1
	print_result "verified head lookup failure: no false drift diagnosis" "$reports_false_drift"
	return 0
}

# Test 13: stale post-merge evidence converges without replaying the mutation.
test_post_merge_stale_evidence_retries_fresh_read() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "post-merge-stale"

	local output=""
	local rc=0
	output=$(run_cmd_merge_for_evidence "42" "testorg/testrepo") || rc=$?
	print_result "post-merge evidence: stale first read converges" "$rc" "output=$output"

	local merge_calls=0 evidence_calls=0 cache_disabled_calls=0 finalize_count=0
	merge_calls=$(grep -c '^gh pr merge' "${TEST_ROOT}/logs/gh-calls.txt" || true)
	evidence_calls=$(<"${TEST_ROOT}/logs/evidence-count.txt")
	cache_disabled_calls=$(grep -c '^1$' "${TEST_ROOT}/logs/evidence-cache-control.txt" || true)
	[[ -f "${TEST_ROOT}/logs/finalize-count.txt" ]] && finalize_count=$(<"${TEST_ROOT}/logs/finalize-count.txt")
	print_result "post-merge evidence: mutation executes exactly once" "$((merge_calls == 1 ? 0 : 1))" "merge_calls=$merge_calls"
	print_result "post-merge evidence: retry reads are cache-disabled" "$((evidence_calls == 2 && cache_disabled_calls == 2 ? 0 : 1))" "evidence_calls=$evidence_calls cache_disabled_calls=$cache_disabled_calls"
	print_result "post-merge evidence: finalizer executes exactly once" "$((finalize_count == 1 ? 0 : 1))" "finalize_count=$finalize_count"
	print_result "post-merge evidence: lifecycle reports merge SHA" "$([[ "$output" == *"LIFECYCLE_STATE=MERGED merge_sha=merged123sha"* ]] && printf '0' || printf '1')" "output=$output"
	return 0
}

# Test 14: persistently unmerged evidence fails closed after bounded reads.
test_post_merge_unmerged_evidence_fails_closed() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "post-merge-unmerged"

	local rc=0
	run_cmd_merge_for_evidence "42" "testorg/testrepo" >/dev/null 2>&1 || rc=$?
	local merge_calls=0 evidence_calls=0 finalize_count=0
	merge_calls=$(grep -c '^gh pr merge' "${TEST_ROOT}/logs/gh-calls.txt" || true)
	evidence_calls=$(<"${TEST_ROOT}/logs/evidence-count.txt")
	[[ -f "${TEST_ROOT}/logs/finalize-count.txt" ]] && finalize_count=$(<"${TEST_ROOT}/logs/finalize-count.txt")
	print_result "post-merge evidence: persistent OPEN fails closed" "$((rc == 0 ? 1 : 0))"
	print_result "post-merge evidence: persistent OPEN does not replay merge" "$((merge_calls == 1 && evidence_calls == 2 ? 0 : 1))" "merge_calls=$merge_calls evidence_calls=$evidence_calls"
	print_result "post-merge evidence: persistent OPEN skips finalizer" "$((finalize_count == 0 ? 0 : 1))" "finalize_count=$finalize_count"
	return 0
}

# Test 15: API-indeterminate evidence fails closed without replaying the mutation.
test_post_merge_api_indeterminate_fails_closed() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "post-merge-api-failure"

	local rc=0
	run_cmd_merge_for_evidence "42" "testorg/testrepo" >/dev/null 2>&1 || rc=$?
	local merge_calls=0 evidence_calls=0 finalize_count=0
	merge_calls=$(grep -c '^gh pr merge' "${TEST_ROOT}/logs/gh-calls.txt" || true)
	evidence_calls=$(<"${TEST_ROOT}/logs/evidence-count.txt")
	[[ -f "${TEST_ROOT}/logs/finalize-count.txt" ]] && finalize_count=$(<"${TEST_ROOT}/logs/finalize-count.txt")
	print_result "post-merge evidence: API-indeterminate state fails closed" "$((rc == 0 ? 1 : 0))"
	print_result "post-merge evidence: API failure does not replay merge" "$((merge_calls == 1 && evidence_calls == 2 ? 0 : 1))" "merge_calls=$merge_calls evidence_calls=$evidence_calls"
	print_result "post-merge evidence: API failure skips finalizer" "$((finalize_count == 0 ? 0 : 1))" "finalize_count=$finalize_count"
	return 0
}

test_wip_draft_takeover_uses_reviewed_pr_title() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	# The source branch's sole inherited commit is "wip: document recovery".
	# The merge wrapper must ignore that GitHub default and bind the squash
	# commit to the separately reviewed, compliant PR title from the stub.
	create_gh_stub "explicit-admin"

	local rc=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "1" "0" >/dev/null 2>&1 || rc=$?
	local subject_present=0
	if grep -q -- '--subject GH#28721: fix: preserve reviewed squash subject' "${TEST_ROOT}/logs/gh-calls.txt"; then
		subject_present=1
	fi
	print_result "wip draft takeover: reviewed PR title is explicit" "$((rc == 0 && subject_present == 1 ? 0 : 1))"
	return 0
}

test_invalid_squash_title_blocks_before_merge() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "invalid-squash-title"

	local rc=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" >/dev/null 2>&1 || rc=$?
	local merge_calls=0
	merge_calls=$(grep -c '^gh pr merge' "${TEST_ROOT}/logs/gh-calls.txt" 2>/dev/null || true)
	print_result "squash subject: invalid title fails closed" "$((rc == 0 ? 1 : 0))"
	print_result "squash subject: invalid title blocks before mutation" "$((merge_calls == 0 ? 0 : 1))" "merge_calls=$merge_calls"
	return 0
}

test_non_squash_skips_subject_override() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "explicit-admin"

	local rc=0
	run_merge_execute "42" "testorg/testrepo" "--merge" "1" "0" >/dev/null 2>&1 || rc=$?
	local subject_present=0 title_reads=0
	grep -q -- '--subject' "${TEST_ROOT}/logs/gh-calls.txt" && subject_present=1
	title_reads=$(grep -c -- '--json title' "${TEST_ROOT}/logs/gh-calls.txt" 2>/dev/null || true)
	print_result "non-squash: existing merge behavior is preserved" "$((rc == 0 && subject_present == 0 && title_reads == 0 ? 0 : 1))"
	return 0
}

handoff_state_digest() {
	local repo="$1"
	{
		/usr/bin/git -C "$repo" rev-parse HEAD
		/usr/bin/git -C "$repo" ls-files -s
		/usr/bin/git -C "$repo" diff --binary
		/usr/bin/git -C "$repo" diff --cached --binary
		/usr/bin/git -C "$repo" status --porcelain=v1 --untracked-files=all
	} | /usr/bin/git -C "$repo" hash-object --stdin
	return $?
}

create_planning_handoff_fixture() {
	local fixture_name="$1"
	local scripts_dir="${SCRIPT_DIR}/.."
	local publication_output=""
	HANDOFF_ROOT="${TEST_ROOT}/handoff-${fixture_name}"
	HANDOFF_REPO="${HANDOFF_ROOT}/work"
	HANDOFF_RECEIPT_DIR="${HANDOFF_ROOT}/receipts"
	HANDOFF_RECEIPT=""
	HANDOFF_SOURCE_HEAD=""
	HANDOFF_PUBLISHED_COMMIT=""
	mkdir -p "$HANDOFF_ROOT" || return 1
	/usr/bin/git init --bare --initial-branch=main "${HANDOFF_ROOT}/remote.git" >/dev/null 2>&1 || return 1
	/usr/bin/git clone "${HANDOFF_ROOT}/remote.git" "$HANDOFF_REPO" >/dev/null 2>&1 || return 1
	/usr/bin/git -C "$HANDOFF_REPO" config user.email test@test.local || return 1
	/usr/bin/git -C "$HANDOFF_REPO" config user.name Test || return 1
	/usr/bin/git -C "$HANDOFF_REPO" config commit.gpgsign false || return 1
	printf '# Tasks\n' >"${HANDOFF_REPO}/TODO.md"
	printf 'base\n' >"${HANDOFF_REPO}/README.md"
	/usr/bin/git -C "$HANDOFF_REPO" add TODO.md README.md || return 1
	/usr/bin/git -C "$HANDOFF_REPO" commit -q -m seed || return 1
	/usr/bin/git -C "$HANDOFF_REPO" push -q origin main || return 1
	printf '%s\n' '- [ ] t900 checkout-free handoff ref:GH#900' >>"${HANDOFF_REPO}/TODO.md"
	cp "${HANDOFF_REPO}/TODO.md" "${HANDOFF_ROOT}/expected-TODO.md" || return 1
	publication_output=$(
		SCRIPT_DIR="$scripts_dir"
		# shellcheck source=../planning-publisher.sh
		source "${scripts_dir}/planning-publisher.sh"
		AIDEVOPS_PLANNING_GIT_BIN=/usr/bin/git \
			AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true \
			AIDEVOPS_PLANNING_RECEIPT_DIR="$HANDOFF_RECEIPT_DIR" \
			AIDEVOPS_PLANNING_WRITE_RECEIPT=true \
			planning_publish "$HANDOFF_REPO" "plan: checkout-free handoff" origin main || exit $?
		printf '%s\t%s\t%s\n' "$PLANNING_PUBLICATION_RECEIPT" "$PLANNING_PUBLICATION_SOURCE_HEAD" "$PLANNING_PUBLISHED_COMMIT"
	) || return 1
	IFS=$'\t' read -r HANDOFF_RECEIPT HANDOFF_SOURCE_HEAD HANDOFF_PUBLISHED_COMMIT <<<"$publication_output"
	[[ -f "$HANDOFF_RECEIPT" && -n "$HANDOFF_SOURCE_HEAD" && -n "$HANDOFF_PUBLISHED_COMMIT" ]]
	return $?
}

write_handoff_gh_stub() {
	cat >"${TEST_ROOT}/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
	if [[ "$*" == *"--json state,isDraft,reviewDecision,headRefOid,headRefName"* ]]; then
		printf '{"state":"OPEN","isDraft":false,"reviewDecision":"","headRefOid":"%s","headRefName":"main"}\n' "${HANDOFF_EXPECTED_HEAD:?}"
		exit 0
	fi
	if [[ "$*" == *"--json headRefOid"* ]]; then
		printf '%s\n' "${HANDOFF_EXPECTED_HEAD:?}"
		exit 0
	fi
fi
exit 1
GHSTUB
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

run_handoff_readiness() {
	local repo="$1"
	local receipt_dir="$2"
	local expected_head="$3"
	local scripts_dir="${SCRIPT_DIR}/.."
	local tmp_runner=""
	local rc=0
	write_handoff_gh_stub || return 1
	tmp_runner=$(mktemp) || return 1
	cat >"$tmp_runner" <<RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${scripts_dir}'
HEADLESS=true
source '${scripts_dir}/shared-constants.sh'
source '${scripts_dir}/full-loop-helper-commit.sh'
_full_loop_query_required_checks() {
	local pr_number="\$1"
	local repo="\$2"
	local pr_head_ref="\$3"
	: "\$pr_number" "\$repo" "\$pr_head_ref"
	FULL_LOOP_REQUIRED_CHECKS_JSON='[]'
	FULL_LOOP_REQUIRED_CHECKS_SUCCESS_EVIDENCE='no-required-checks'
	FULL_LOOP_REQUIRED_CHECKS_SUCCESS_SUMMARY='no required checks are configured'
	return 0
}
_full_loop_persist_pr_check_evidence() {
	local status="\$1"
	local head_sha="\$2"
	local evidence="\${3:-}"
	: "\$status" "\$head_sha" "\$evidence"
	return 0
}
cd '${repo}'
_full_loop_verify_pr_readiness '42' 'testorg/testrepo'
RUNNER_EOF
	chmod +x "$tmp_runner"
	env PATH="${TEST_ROOT}/bin:/usr/bin:/bin:/opt/homebrew/bin:${PATH}" \
		HANDOFF_EXPECTED_HEAD="$expected_head" \
		AIDEVOPS_PLANNING_GIT_BIN=/usr/bin/git \
		AIDEVOPS_PLANNING_RECEIPT_DIR="$receipt_dir" \
		bash "$tmp_runner" 2>&1 || rc=$?
	rm -f "$tmp_runner"
	return $rc
}

test_checkout_free_publication_readiness_handoff() {
	local output="" before="" after="" valid_rc=0 changed_rc=0 added_rc=0 ordinary_rc=0 advanced_rc=0
	local ordinary_repo="" ordinary_receipts="" ordinary_head=""
	local advanced_repo="" advanced_receipts="" advanced_root="" advanced_head=""
	create_planning_handoff_fixture valid || {
		print_result "planning handoff: fixture setup succeeds" 1
		return 0
	}
	before=$(handoff_state_digest "$HANDOFF_REPO")
	output=$(run_handoff_readiness "$HANDOFF_REPO" "$HANDOFF_RECEIPT_DIR" "$HANDOFF_PUBLISHED_COMMIT") || valid_rc=$?
	after=$(handoff_state_digest "$HANDOFF_REPO")
	print_result "planning handoff: exact checkout-free receipt passes readiness" "$valid_rc" "output=$output"
	print_result "planning handoff: readiness preserves local HEAD, index, and files" "$([[ "$before" == "$after" ]] && printf '0' || printf '1')"
	printf '%s\n' '- [ ] t901 post-publication drift ref:GH#901' >>"${HANDOFF_REPO}/TODO.md"
	run_handoff_readiness "$HANDOFF_REPO" "$HANDOFF_RECEIPT_DIR" "$HANDOFF_PUBLISHED_COMMIT" >/dev/null 2>&1 || changed_rc=$?
	print_result "planning handoff: changed local planning snapshot is blocked" "$((changed_rc == 0 ? 1 : 0))"
	cp "${HANDOFF_ROOT}/expected-TODO.md" "${HANDOFF_REPO}/TODO.md" || return 0
	mkdir -p "${HANDOFF_REPO}/todo" || return 0
	printf '%s\n' '# Added after publication' >"${HANDOFF_REPO}/todo/t902.md"
	run_handoff_readiness "$HANDOFF_REPO" "$HANDOFF_RECEIPT_DIR" "$HANDOFF_PUBLISHED_COMMIT" >/dev/null 2>&1 || added_rc=$?
	print_result "planning handoff: newly added planning path is blocked" "$((added_rc == 0 ? 1 : 0))"

	create_planning_handoff_fixture ordinary || return 0
	ordinary_repo="$HANDOFF_REPO"
	ordinary_receipts="$HANDOFF_RECEIPT_DIR"
	ordinary_head="$HANDOFF_PUBLISHED_COMMIT"
	printf 'ordinary local commit\n' >>"${ordinary_repo}/README.md"
	/usr/bin/git -C "$ordinary_repo" add README.md
	/usr/bin/git -C "$ordinary_repo" commit -q -m 'ordinary local drift'
	run_handoff_readiness "$ordinary_repo" "$ordinary_receipts" "$ordinary_head" >/dev/null 2>&1 || ordinary_rc=$?
	print_result "planning handoff: ordinary unpushed local commit remains blocked" "$((ordinary_rc == 0 ? 1 : 0))"

	create_planning_handoff_fixture advanced || return 0
	advanced_repo="$HANDOFF_REPO"
	advanced_receipts="$HANDOFF_RECEIPT_DIR"
	advanced_root="$HANDOFF_ROOT"
	/usr/bin/git clone "${advanced_root}/remote.git" "${advanced_root}/competitor" >/dev/null 2>&1 || return 0
	/usr/bin/git -C "${advanced_root}/competitor" config user.email test@test.local
	/usr/bin/git -C "${advanced_root}/competitor" config user.name Test
	/usr/bin/git -C "${advanced_root}/competitor" config commit.gpgsign false
	printf 'remote advancement\n' >>"${advanced_root}/competitor/README.md"
	/usr/bin/git -C "${advanced_root}/competitor" commit -q -am 'advance remote head'
	/usr/bin/git -C "${advanced_root}/competitor" push -q origin main
	advanced_head=$(/usr/bin/git -C "${advanced_root}/competitor" rev-parse HEAD)
	run_handoff_readiness "$advanced_repo" "$advanced_receipts" "$advanced_head" >/dev/null 2>&1 || advanced_rc=$?
	print_result "planning handoff: advanced remote PR head makes receipt stale" "$((advanced_rc == 0 ? 1 : 0))"
	return 0
}

run_prospective_todo_guard() {
	local fixture_dir="$1"
	local base_sha="$2"
	local head_sha="$3"
	local fetch_mode="${4:-stub}"
	local scripts_dir="${SCRIPT_DIR}/.."
	local tmp_runner=""
	local verification_tmp="${fixture_dir}/verification-tmp"
	local fetch_override=""
	if [[ "$fetch_mode" == "stub" ]]; then
		fetch_override='_merge_fetch_pinned_commit_objects() { return 0; }'
	fi
	mkdir -p "$verification_tmp"
	tmp_runner=$(mktemp)
	cat >"$tmp_runner" <<RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${scripts_dir}'
source '${scripts_dir}/shared-constants.sh'
source '${scripts_dir}/full-loop-helper-merge.sh'
_merge_fetch_pr_refs_rest() { printf 'main\t%s\t%s\n' '${base_sha}' '${head_sha}'; return 0; }
${fetch_override}
cd '${fixture_dir}'
_merge_guard_prospective_todo '42' 'testorg/testrepo'
RUNNER_EOF
	chmod +x "$tmp_runner"
	local rc=0
	env PATH="${TEST_ROOT}/bin:/usr/bin:/bin:${scripts_dir}:${PATH}" TMPDIR="$verification_tmp" \
		bash "$tmp_runner" 2>&1 || rc=$?
	rm -f "$tmp_runner"
	[[ "$rc" -eq 0 ]] && return 0
	return 1
}

prospective_contexts_clean() {
	local fixture_dir="$1"
	local leftovers=""
	leftovers=$(compgen -G "${fixture_dir}/verification-tmp/aidevops-prospective-todo.*" || true)
	[[ -z "$leftovers" ]]
	return $?
}

prospective_git_storage_digest() {
	local fixture_dir="$1"
	{
		/usr/bin/git -C "$fixture_dir" count-objects -v
		/usr/bin/git -C "$fixture_dir" for-each-ref --format='%(refname) %(objectname)'
	} | /usr/bin/git -C "$fixture_dir" hash-object --stdin
	return $?
}

create_prospective_fixture() {
	local mode="$1"
	local fixture_dir="${TEST_ROOT}/prospective-${mode}"
	mkdir -p "$fixture_dir"
	(
		cd "$fixture_dir" || exit 1
		/usr/bin/git init -q
		/usr/bin/git config user.email test@test.local
		/usr/bin/git config user.name Test
		/usr/bin/git config commit.gpgsign false
		printf '## Base tasks\n- [ ] t1 Root ref:GH#1\n\n## Branch tasks\n' >TODO.md
		/usr/bin/git add TODO.md
		/usr/bin/git commit -q -m root
		local root_sha=""
		root_sha=$(/usr/bin/git rev-parse HEAD)
		printf '## Base tasks\n- [ ] t1 Root ref:GH#1\n- [ ] t2 Base addition ref:GH#2\n\n## Branch tasks\n' >TODO.md
		/usr/bin/git commit -q -am base
		/usr/bin/git rev-parse HEAD >base.sha
		/usr/bin/git checkout -q --detach "$root_sha"
		if [[ "$mode" == "collision" ]]; then
			printf '## Base tasks\n- [ ] t1 Root ref:GH#1\n\n## Branch tasks\n- [ ] t2 Head addition ref:GH#2\n' >TODO.md
		else
			printf '## Base tasks\n- [ ] t1 Root ref:GH#1\n\n## Branch tasks\n- [ ] t3 Unique head addition ref:GH#3\n' >TODO.md
		fi
		/usr/bin/git commit -q -am head
		/usr/bin/git rev-parse HEAD >head.sha
	)
	printf '%s\n' "$fixture_dir"
	return 0
}

create_prospective_fetch_fixture() {
	local fixture_root="${TEST_ROOT}/prospective-fetch"
	local remote_repo="${fixture_root}/remote.git"
	local fixture_dir="${fixture_root}/work"
	local competitor="${fixture_root}/competitor"
	local root_sha="" base_sha="" head_sha=""
	mkdir -p "$fixture_root" || return 1
	/usr/bin/git init --bare --initial-branch=main "$remote_repo" >/dev/null 2>&1 || return 1
	/usr/bin/git clone "$remote_repo" "$fixture_dir" >/dev/null 2>&1 || return 1
	/usr/bin/git -C "$fixture_dir" config user.email test@test.local || return 1
	/usr/bin/git -C "$fixture_dir" config user.name Test || return 1
	/usr/bin/git -C "$fixture_dir" config commit.gpgsign false || return 1
	printf '## Base tasks\n- [ ] t1 Root ref:GH#1\n\n## Branch tasks\n' >"${fixture_dir}/TODO.md"
	/usr/bin/git -C "$fixture_dir" add TODO.md || return 1
	/usr/bin/git -C "$fixture_dir" commit -q -m root || return 1
	root_sha=$(/usr/bin/git -C "$fixture_dir" rev-parse HEAD) || return 1
	/usr/bin/git -C "$fixture_dir" push -q origin main || return 1
	printf '## Base tasks\n- [ ] t1 Root ref:GH#1\n- [ ] t2 Base addition ref:GH#2\n\n## Branch tasks\n' >"${fixture_dir}/TODO.md"
	/usr/bin/git -C "$fixture_dir" commit -q -am base || return 1
	base_sha=$(/usr/bin/git -C "$fixture_dir" rev-parse HEAD) || return 1
	/usr/bin/git -C "$fixture_dir" push -q origin main || return 1
	/usr/bin/git clone "$remote_repo" "$competitor" >/dev/null 2>&1 || return 1
	/usr/bin/git -C "$competitor" config user.email test@test.local || return 1
	/usr/bin/git -C "$competitor" config user.name Test || return 1
	/usr/bin/git -C "$competitor" config commit.gpgsign false || return 1
	/usr/bin/git -C "$competitor" checkout -q --detach "$root_sha" || return 1
	printf '## Base tasks\n- [ ] t1 Root ref:GH#1\n\n## Branch tasks\n- [ ] t3 Unique head addition ref:GH#3\n' >"${competitor}/TODO.md"
	/usr/bin/git -C "$competitor" commit -q -am head || return 1
	head_sha=$(/usr/bin/git -C "$competitor" rev-parse HEAD) || return 1
	/usr/bin/git -C "$competitor" push -q origin "${head_sha}:refs/pull/42/head" || return 1
	printf '%s\n' "$base_sha" >"${fixture_root}/base.sha"
	printf '%s\n' "$head_sha" >"${fixture_root}/head.sha"
	printf '%s\n' "$fixture_dir"
	return 0
}

test_prospective_todo_merge_guard() {
	local fixture_dir="" fixture_root="" base_sha="" head_sha="" output="" rc=0 objects_before="" objects_after=""
	local cleanup_rc=0 isolation_rc=0 storage_before="" storage_after="" absent_before=0 absent_after=0
	fixture_dir=$(create_prospective_fixture collision)
	base_sha=$(<"${fixture_dir}/base.sha")
	head_sha=$(<"${fixture_dir}/head.sha")
	objects_before=$(/usr/bin/git -C "$fixture_dir" count-objects -v)
	output=$(run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha") || rc=$?
	objects_after=$(/usr/bin/git -C "$fixture_dir" count-objects -v)
	prospective_contexts_clean "$fixture_dir" || cleanup_rc=$?
	[[ "$cleanup_rc" -eq 0 && "$objects_before" == "$objects_after" ]] || isolation_rc=1
	print_result "prospective TODO: merge-only collision is blocked" "$((rc == 0 ? 1 : 0))" "output=$output"
	print_result "prospective TODO: task and issue duplicates are reported" "$([[ "$output" == *"Duplicate task ID: t2"* && "$output" == *"Duplicate issue mapping: ref:GH#2"* ]] && printf '0' || printf '1')" "output=$output"
	print_result "prospective TODO: collision writes only to cleaned isolated context" "$isolation_rc"

	rc=0
	cleanup_rc=0
	isolation_rc=0
	fixture_dir=$(create_prospective_fixture unique)
	base_sha=$(<"${fixture_dir}/base.sha")
	head_sha=$(<"${fixture_dir}/head.sha")
	objects_before=$(/usr/bin/git -C "$fixture_dir" count-objects -v)
	run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha" >/dev/null || rc=$?
	objects_after=$(/usr/bin/git -C "$fixture_dir" count-objects -v)
	prospective_contexts_clean "$fixture_dir" || cleanup_rc=$?
	[[ "$cleanup_rc" -eq 0 && "$objects_before" == "$objects_after" ]] || isolation_rc=1
	print_result "prospective TODO: unique stale branch passes" "$rc"
	print_result "prospective TODO: success writes only to cleaned isolated context" "$isolation_rc"

	rc=0
	cleanup_rc=0
	output=$(run_prospective_todo_guard "$fixture_dir" deadbeef deadbeef) || rc=$?
	print_result "prospective TODO: indeterminate merge-tree fails closed" "$((rc == 0 ? 1 : 0))" "output=$output"
	prospective_contexts_clean "$fixture_dir" || cleanup_rc=$?
	print_result "prospective TODO: failure cleans isolated context" "$cleanup_rc"

	rc=0
	cleanup_rc=0
	isolation_rc=0
	fixture_dir=$(create_prospective_fetch_fixture) || return 0
	fixture_root="${fixture_dir%/work}"
	base_sha=$(<"${fixture_root}/base.sha")
	head_sha=$(<"${fixture_root}/head.sha")
	storage_before=$(prospective_git_storage_digest "$fixture_dir")
	if /usr/bin/git -C "$fixture_dir" cat-file -e "${head_sha}^{commit}" 2>/dev/null; then absent_before=1; fi
	run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha" live >/dev/null || rc=$?
	storage_after=$(prospective_git_storage_digest "$fixture_dir")
	if /usr/bin/git -C "$fixture_dir" cat-file -e "${head_sha}^{commit}" 2>/dev/null; then absent_after=1; fi
	prospective_contexts_clean "$fixture_dir" || cleanup_rc=$?
	[[ "$rc" -eq 0 && "$cleanup_rc" -eq 0 && "$absent_before" -eq 0 && "$absent_after" -eq 0 && \
		"$storage_before" == "$storage_after" ]] || isolation_rc=1
	print_result "prospective TODO: missing PR objects fetch only into cleaned isolated context" "$isolation_rc"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	echo "=== Admin merge fallback signaling tests (t2247) ==="
	echo ""

	test_admin_fallback_signals
	test_admin_fallback_blocks_needs_maintainer_review_issue
	test_explicit_admin_no_signaling
	test_other_error_no_fallback
	test_late_review_blocks_every_merge_transport
	test_graphql_rate_limit_rest_fallback
	test_graphql_rate_limit_cmd_merge_phase_autofile
	test_graphql_rate_limit_auto_no_rest_fallback
	test_review_gate_failure_blocks_rest_fallback
	test_auto_review_required_interactive_admin_fallback
	test_auto_review_required_headless_no_admin_fallback
	test_stale_cache_401_retry
	test_auth_401_detection_avoids_numeric_false_positives
	test_pr_ready_accepts_prefetched_json
	test_pr_ready_blocks_nonpassing_rollup
	test_verified_head_lookup_failure_is_not_reported_as_drift
	test_post_merge_stale_evidence_retries_fresh_read
	test_post_merge_unmerged_evidence_fails_closed
	test_post_merge_api_indeterminate_fails_closed
	test_wip_draft_takeover_uses_reviewed_pr_title
	test_invalid_squash_title_blocks_before_merge
	test_non_squash_skips_subject_override
	test_checkout_free_publication_readiness_handoff
	test_prospective_todo_merge_guard

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
