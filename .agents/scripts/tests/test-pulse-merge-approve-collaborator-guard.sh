#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for approve_collaborator_pr() defense-in-depth author guard (t2933).
#
# Background — GH#17671 supply-chain incident
# -------------------------------------------
# In April 2025 an external contributor (non-collaborator) opened PR #17671 against
# this repo. The PR added a workflow file that invoked an attacker-controlled
# action. `approve_collaborator_pr` was invoked anyway because the upstream
# gate at the time only inspected linked-issue labels, not the PR author. The
# PR shipped an "Auto-approved by pulse — collaborator PR" body even though
# the author was not a collaborator. Subsequent hardening (PR #17868 added
# Check 0 to maintainer-gate; PR #17877 protected the NMR label;
# `_check_pr_merge_gates` line ~1060 added an upstream `_is_collaborator_author`
# check on the PR author) closed the live exploit.
#
# What this test guards
# ---------------------
# The function `approve_collaborator_pr` itself trusts its `$pr_author`
# argument unless self-protected. A future refactor of `_check_pr_merge_gates`
# could quietly remove the upstream collaborator check; the function would
# then re-introduce the GH#17671 supply-chain hole as soon as a single
# caller passed a non-collaborator author through. The defense-in-depth
# guard added in t2933 makes the function refuse to approve in that case
# REGARDLESS of what its callers do. These tests pin that contract so the
# guard can never silently regress.
#
# These tests exercise the helper in isolation with a mock `gh` stub. No
# real repository is touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# approve_collaborator_pr was extracted to pulse-merge-gates.sh during the
# pulse-merge split. The test extracts it via awk for isolated execution under
# a mock gh stub, so the source file must point at where the function actually
# lives — not the orchestrator that only calls it. Without this repoint the
# extraction returns empty and the test exits FATAL, blocking every PR via the
# Framework Validation required check (t3032).
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge-gates.sh"
# _is_collaborator_author was extracted to pulse-merge-author-checks.sh (GH#21426)
AUTHOR_CHECKS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-author-checks.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""

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

# Reset state between cases.
reset_mock_state() {
	: >"$GH_LOG"
	: >"$LOGFILE"
	# Default: collaborators set contains "pulse-runner" only.
	cat >"${TEST_ROOT}/collaborators.txt" <<'EOF'
pulse-runner
EOF
	# Default authenticated user is the pulse runner.
	echo "pulse-runner" >"${TEST_ROOT}/current-user.txt"
	# Default: no prior reviews.
	printf '[]\n' >"${TEST_ROOT}/reviews.json"
	printf '0\n' >"${TEST_ROOT}/reviews-exit-code.txt"
	# Default: no crypto-approval markers in comments (count 0).
	# Controls the mock gh comments endpoint response for _has_maintainer_crypto_approval.
	echo "0" >"${TEST_ROOT}/crypto-comment-count.txt"
	# Default: linked issue number returned by the _extract_linked_issue stub.
	echo "999" >"${TEST_ROOT}/linked-issue.txt"
	# Default: no current-head V2 PR approval.
	echo "NO_APPROVAL" >"${TEST_ROOT}/crypto-approval-result.txt"
	rm -f "${TEST_ROOT}/approval-response-head.txt" "${TEST_ROOT}/issue-sync-trusted"
	return 0
}

write_approval_helper_mocks() {
	# Marker presence alone has no authority; fixtures emit explicit V2 states.
	export AGENTS_DIR="${TEST_ROOT}/mock-agents"
	mkdir -p "${AGENTS_DIR}/scripts"
	cat >"${AGENTS_DIR}/scripts/approval-helper.sh" <<'AHEOF'
#!/usr/bin/env bash
cat "${TEST_ROOT}/crypto-approval-result.txt"
return 0 2>/dev/null || exit 0
AHEOF
	chmod +x "${AGENTS_DIR}/scripts/approval-helper.sh"
	cat >"${AGENTS_DIR}/scripts/review-bot-gate-helper.sh" <<'RBEOF'
#!/usr/bin/env bash
printf '%s\n' "review-helper $*" >>"${GH_LOG:-/dev/null}"
[[ "${1:-}" == "is-trusted-issue-sync-pr" && -f "${TEST_ROOT}/issue-sync-trusted" && -n "${4:-}" ]]
RBEOF
	chmod +x "${AGENTS_DIR}/scripts/review-bot-gate-helper.sh"
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	export TEST_ROOT GH_LOG
	write_approval_helper_mocks

	# Mock gh: logs every call and answers the five endpoints that
	# `approve_collaborator_pr`, `_is_collaborator_author`, and
	# `_has_maintainer_crypto_approval` use.
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

# `gh api user --jq '.login'` — return current user fixture
if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
	cat "${TEST_ROOT}/current-user.txt"
	exit 0
fi

	# `gh api -i /repos/SLUG/collaborators/USER/permission` — return status+body.
	# Used by the App-aware collaborator permission lookup helper.
if [[ "${1:-}" == "api" && "${2:-}" == "-i" && "$*" == *"/collaborators/"*"/permission" ]]; then
	# Extract the username segment between /collaborators/ and /permission.
	_user="${3#*/collaborators/}"
	_user="${_user%/permission}"
	if grep -Fxq "$_user" "${TEST_ROOT}/collaborators.txt"; then
		printf 'HTTP/2.0 200 OK\n\n{"permission":"admin"}\n'
	else
		printf 'HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}\n'
	fi
	exit 0
fi

# `gh api repos/SLUG/collaborators/USER/permission --jq '.permission'`
if [[ "${1:-}" == "api" && "$*" == *"/collaborators/"*"/permission"* && "$*" == *"--jq"* ]]; then
	_user="${2#*/collaborators/}"
	_user="${_user%/permission}"
	if grep -Fxq "$_user" "${TEST_ROOT}/collaborators.txt"; then
		printf 'admin\n'
	else
		printf '\n'
	fi
	exit 0
fi

# `gh api -X POST repos/SLUG/pulls/N/reviews ... commit_id=SHA` — exact-head
# approval mutation. Return the requested commit unless a race fixture overrides
# the response, allowing the caller's post-mutation binding check to be pinned.
if [[ "${1:-}" == "api" && "${2:-}" == "-X" && "${3:-}" == "POST" &&
	"${4:-}" == repos/*/pulls/*/reviews ]]; then
	_response_head=""
	for _arg in "$@"; do
		case "$_arg" in
		commit_id=*) _response_head="${_arg#commit_id=}" ;;
		esac
	done
	if [[ -s "${TEST_ROOT}/approval-response-head.txt" ]]; then
		_response_head=$(<"${TEST_ROOT}/approval-response-head.txt")
	fi
	printf '{"state":"APPROVED","commit_id":"%s"}\n' "$_response_head"
	exit 0
fi

# `gh api repos/SLUG/pulls/N/reviews` — existing trusted approval
if [[ "${1:-}" == "api" && "$*" == *"/pulls/"*"/reviews"* ]]; then
	_reviews_exit_code=$(<"${TEST_ROOT}/reviews-exit-code.txt")
	if [[ "$_reviews_exit_code" -ne 0 ]]; then
		exit "$_reviews_exit_code"
	fi
	jq -r "${4:-.}" "${TEST_ROOT}/reviews.json"
	exit 0
fi

# Legacy marker-count endpoint fixture. It remains to prove Case O cannot make
# linked-issue marker presence substitute for current PR-specific V2 authority.
if [[ "${1:-}" == "api" && "$*" == *"/issues/"*"/comments"* && "$*" == *"--jq"* ]]; then
	cat "${TEST_ROOT}/crypto-comment-count.txt" 2>/dev/null || printf '0\n'
	exit 0
fi

# `gh pr review N --repo SLUG --approve --body "..."`
if [[ "${1:-}" == "pr" && "${2:-}" == "review" ]]; then
	# Already logged via the line at top of mock — exit 0 to claim approval.
	exit 0
fi

# Anything else: log and exit 0 so unrelated calls don't fail the test.
exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Extract approve_collaborator_pr from pulse-merge-gates.sh AND its dependencies:
#   - _is_collaborator_author from pulse-merge-author-checks.sh (GH#21426 split)
#   - _has_maintainer_crypto_approval from pulse-merge-gates.sh (t3063)
# All three are needed; approve_collaborator_pr calls both helpers.
# _extract_linked_issue (called by _has_maintainer_crypto_approval) is provided
# as a test stub that returns a fixed linked issue number from a fixture file,
# keeping the unit boundary at approve_collaborator_pr.
define_helpers_under_test() {
	local approve_src
	local runner_src
	local crypto_src
	local current_head_crypto_src
	local trusted_approval_src
	local issue_sync_src
	local exact_head_approval_src
	approve_src=$(awk '
		/^approve_collaborator_pr\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	runner_src=$(awk '
		/^_approve_collaborator_runner_has_write\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	# _has_maintainer_crypto_approval was added in t3063
	crypto_src=$(awk '
		/^_has_maintainer_crypto_approval\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	current_head_crypto_src=$(awk '
		/^_external_pr_current_head_crypto_approved\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	trusted_approval_src=$(awk '
		/^_trusted_existing_approver\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	issue_sync_src=$(awk '
		/^_pulse_is_trusted_issue_sync_pr\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	exact_head_approval_src=$(awk '
		/^_pulse_approve_pr_at_head\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")

	if [[ -z "$approve_src" ]]; then
		printf 'ERROR: could not extract approve_collaborator_pr from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	if [[ -z "$runner_src" ]]; then
		printf 'ERROR: could not extract _approve_collaborator_runner_has_write from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	if [[ -z "$crypto_src" ]]; then
		printf 'ERROR: could not extract _has_maintainer_crypto_approval from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	if [[ -z "$current_head_crypto_src" ]]; then
		printf 'ERROR: could not extract _external_pr_current_head_crypto_approved from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	if [[ -z "$trusted_approval_src" ]]; then
		printf 'ERROR: could not extract _trusted_existing_approver from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	if [[ -z "$issue_sync_src" ]]; then
		printf 'ERROR: could not extract _pulse_is_trusted_issue_sync_pr from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	if [[ -z "$exact_head_approval_src" ]]; then
		printf 'ERROR: could not extract _pulse_approve_pr_at_head from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi

	# Stub _extract_linked_issue — returns a fixed linked issue number
	# from the fixture file, avoiding a dependency on pulse-merge.sh.
	# shellcheck disable=SC2317
	_extract_linked_issue() {
		cat "${TEST_ROOT}/linked-issue.txt" 2>/dev/null || true
		return 0
	}
	# This test focuses on the collaborator/crypto guard. Dependabot-specific
	# allowances are covered by test-pulse-merge-trusted-dependabot.sh.
	_is_trusted_dependabot_update_pr() { return 1; }

	# shellcheck source=../pulse-merge-author-checks.sh
	source "$AUTHOR_CHECKS_SCRIPT"
	# shellcheck disable=SC1090
	eval "$runner_src"
	# shellcheck disable=SC1090
	eval "$current_head_crypto_src"
	# shellcheck disable=SC1090
	eval "$crypto_src"
	# shellcheck disable=SC1090
	eval "$trusted_approval_src"
	# shellcheck disable=SC1090
	eval "$issue_sync_src"
	# shellcheck disable=SC1090
	eval "$exact_head_approval_src"
	# shellcheck disable=SC1090
	eval "$approve_src"
	return 0
}

# Helper: count legacy or exact-head approval mutations in the log.
count_approve_calls() {
	grep -Ec 'gh pr review|gh api -X POST repos/.*/pulls/[0-9]+/reviews' "$GH_LOG" 2>/dev/null || true
}

# =============================================================================
# Case A: PR author IS collaborator, runner IS collaborator, runner != author
#         → approval SHOULD fire.
# =============================================================================

test_case_a_collaborator_author_approves() {
	reset_mock_state
	# Add the PR author as a collaborator alongside the pulse runner.
	cat >"${TEST_ROOT}/collaborators.txt" <<'EOF'
pulse-runner
trusted-contributor
EOF

	local result=0
	approve_collaborator_pr "100" "owner/repo" "trusted-contributor" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case A: collaborator author — approval succeeds" 1 \
			"Expected exit 0, got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	# Verify gh pr review --approve was called.
	local approve_count
	approve_count=$(count_approve_calls)
	if [[ "${approve_count:-0}" -lt 1 ]]; then
		print_result "Case A: collaborator author — approve API called" 1 \
			"Expected at least one 'gh pr review' call. Log: $(cat "$GH_LOG")"
		return 0
	fi
	# Verify approval body names the actual checks performed (t2933 fix to
	# the misleading "collaborator PR" body that shipped for years).
	if ! grep -qF "confirmed collaborator" "$GH_LOG"; then
		print_result "Case A: collaborator author — approval body accurate" 1 \
			"Expected 'confirmed collaborator' in approval body. Log: $(cat "$GH_LOG")"
		return 0
	fi
	print_result "Case A: collaborator author — approves PR with accurate body" 0
	return 0
}

# =============================================================================
# Case B (PRIMARY REGRESSION CASE — GH#17671):
#         PR author NOT a collaborator, runner IS collaborator
#         → guard MUST refuse approval.
# =============================================================================

test_case_b_non_collaborator_author_refused() {
	reset_mock_state
	# Pulse runner is the only collaborator; PR author is external.
	cat >"${TEST_ROOT}/collaborators.txt" <<'EOF'
pulse-runner
EOF

	local result=0
	approve_collaborator_pr "200" "owner/repo" "external-contributor" || result=$?

	# Function returns 0 (skip is not failure) but MUST NOT call gh pr review.
	if [[ "$result" -ne 0 ]]; then
		print_result "Case B: non-collaborator author — function returns 0 (skip)" 1 \
			"Expected exit 0, got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	local approve_count
	approve_count=$(count_approve_calls)
	if [[ "${approve_count:-0}" -gt 0 ]]; then
		print_result "Case B: non-collaborator author — NO approve API call" 1 \
			"Expected zero 'gh pr review' calls (GH#17671 defense-in-depth). Log: $(cat "$GH_LOG")"
		return 0
	fi
	# Verify the t2933 refusal log line is present so future debugging can
	# attribute the skip to the correct guard.
	if ! grep -qF "GH#17671 defense-in-depth, t2933" "$LOGFILE"; then
		print_result "Case B: non-collaborator author — refusal logged with audit trail" 1 \
			"Expected GH#17671/t2933 attribution in skip log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case B: non-collaborator author — refused with audit-trail log" 0
	return 0
}

# =============================================================================
# Case C: Self-authored PR (runner == author) → skip; --admin merge handles it.
# =============================================================================

test_case_c_self_authored_skipped() {
	reset_mock_state
	echo "pulse-runner" >"${TEST_ROOT}/current-user.txt"

	local result=0
	approve_collaborator_pr "300" "owner/repo" "pulse-runner" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case C: self-authored — function returns 0" 1 \
			"Expected exit 0, got ${result}"
		return 0
	fi
	local approve_count
	approve_count=$(count_approve_calls)
	if [[ "${approve_count:-0}" -gt 0 ]]; then
		print_result "Case C: self-authored — NO approve API call" 1 \
			"Expected zero approve calls (--admin handles it). Log: $(cat "$GH_LOG")"
		return 0
	fi
	if ! grep -qF "self-authored" "$LOGFILE"; then
		print_result "Case C: self-authored — skip logged" 1 \
			"Expected 'self-authored' in log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case C: self-authored — skipped (--admin handles it)" 0
	return 0
}

# =============================================================================
# Case D: Pulse runner lacks write access → skip approval (no-op).
#         Earlier guard, predates the t2933 author check; still must hold.
# =============================================================================

test_case_d_runner_lacks_write_access_skipped() {
	reset_mock_state
	# Runner is NOT in the collaborators file — pretend pulse runs as a
	# token whose user has no write access on this repo.
	cat >"${TEST_ROOT}/collaborators.txt" <<'EOF'
trusted-contributor
EOF
	echo "low-priv-user" >"${TEST_ROOT}/current-user.txt"

	local result=0
	approve_collaborator_pr "400" "owner/repo" "trusted-contributor" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case D: runner lacks write — function returns 0" 1 \
			"Expected exit 0, got ${result}"
		return 0
	fi
	local approve_count
	approve_count=$(count_approve_calls)
	if [[ "${approve_count:-0}" -gt 0 ]]; then
		print_result "Case D: runner lacks write — NO approve API call" 1 \
			"Expected zero approve calls. Log: $(cat "$GH_LOG")"
		return 0
	fi
	if ! grep -qF "lacks write access" "$LOGFILE"; then
		print_result "Case D: runner lacks write — skip logged" 1 \
			"Expected 'lacks write access' in log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case D: runner lacks write access — skipped" 0
	return 0
}

# =============================================================================
# Case E (GH#27514): another trusted pulse identity already approved this head.
#                    Skip before identity/permission reads and review writes.
# =============================================================================

test_case_e_cross_account_approval_short_circuits() {
	reset_mock_state
	cat >"${TEST_ROOT}/reviews.json" <<'EOF'
[{"state":"APPROVED","commit_id":"head-500","author_association":"COLLABORATOR","user":{"login":"other-pulse-runner"}}]
EOF

	local result=0
	approve_collaborator_pr "500" "owner/repo" "trusted-contributor" "head-500" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case E: cross-account approval — function returns 0" 1 \
			"Expected exit 0, got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	if [[ "$(count_approve_calls)" -ne 0 ]]; then
		print_result "Case E: cross-account approval — no duplicate review write" 1 \
			"Expected zero approve calls. Calls: $(cat "$GH_LOG")"
		return 0
	fi
	if grep -qF "gh api user" "$GH_LOG" || grep -qF "/collaborators/" "$GH_LOG"; then
		print_result "Case E: cross-account approval — avoids redundant identity reads" 1 \
			"Expected only the reviews read. Calls: $(cat "$GH_LOG")"
		return 0
	fi
	if ! grep -qF "already has a trusted approval" "$LOGFILE"; then
		print_result "Case E: cross-account approval — skip is auditable" 1 \
			"Expected trusted-approval skip log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case E: cross-account approval — skips duplicate write with one read" 0
	return 0
}

# =============================================================================
# Case F (GH#27514 trust boundary): external or stale approvals do not suppress
# the guarded pulse approval for the current head.
# =============================================================================

test_case_f_untrusted_or_stale_approval_does_not_short_circuit() {
	reset_mock_state
	cat >"${TEST_ROOT}/collaborators.txt" <<'EOF'
pulse-runner
trusted-contributor
EOF
	cat >"${TEST_ROOT}/reviews.json" <<'EOF'
[
  {"state":"APPROVED","commit_id":"head-600","author_association":"CONTRIBUTOR","user":{"login":"external-reviewer"}},
  {"state":"APPROVED","commit_id":"old-head","author_association":"OWNER","user":{"login":"trusted-but-stale"}}
]
EOF

	local result=0
	approve_collaborator_pr "600" "owner/repo" "trusted-contributor" "head-600" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case F: untrusted/stale approvals — function returns 0" 1 \
			"Expected exit 0, got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	if [[ "$(count_approve_calls)" -ne 1 ]]; then
		print_result "Case F: untrusted/stale approvals — guarded review still posts" 1 \
			"Expected one approve call. Calls: $(cat "$GH_LOG")"
		return 0
	fi
	print_result "Case F: untrusted/stale approvals — do not bypass guarded approval" 0
	return 0
}

# =============================================================================
# Case G (GH#27525): an empty reviews response must not be passed to jq.
# API failures fail open without adding a misleading jq parse error to stderr.
# =============================================================================

test_case_g_empty_reviews_response_skips_jq() {
	reset_mock_state
	: >"${TEST_ROOT}/reviews.json"
	local approver=""
	local stderr_file="${TEST_ROOT}/trusted-approval.stderr"

	approver=$(_trusted_existing_approver "owner/repo" "700" "head-700" 2>"$stderr_file")
	if [[ -n "$approver" ]]; then
		print_result "Case G: empty reviews response — no approver returned" 1 \
			"Expected an empty approver, got ${approver}"
		return 0
	fi
	if [[ -s "$stderr_file" ]]; then
		print_result "Case G: empty reviews response — jq is not invoked" 1 \
			"Expected empty stderr, got: $(<"$stderr_file")"
		return 0
	fi
	print_result "Case G: empty reviews response — jq is not invoked" 0
	return 0
}

test_case_h_failed_reviews_request_skips_jq() {
	reset_mock_state
	printf '1\n' >"${TEST_ROOT}/reviews-exit-code.txt"
	local approver=""
	local stderr_file="${TEST_ROOT}/trusted-approval-failure.stderr"

	approver=$(_trusted_existing_approver "owner/repo" "800" "head-800" 2>"$stderr_file")
	if [[ -n "$approver" ]]; then
		print_result "Case H: failed reviews request — no approver returned" 1 \
			"Expected an empty approver, got ${approver}"
		return 0
	fi
	if [[ -s "$stderr_file" ]]; then
		print_result "Case H: failed reviews request — jq is not invoked" 1 \
			"Expected empty stderr, got: $(<"$stderr_file")"
		return 0
	fi
	print_result "Case H: failed reviews request — jq is not invoked" 0
	return 0
}

# =============================================================================
# Case N (t3063): CONTRIBUTOR author + crypto-approval on PR itself → approves.
# The crypto-approval bypass in approve_collaborator_pr should allow approval
# even though the PR author is not a collaborator.
# =============================================================================

test_case_n_contributor_with_crypto_on_pr() {
	reset_mock_state
	# PR author is NOT a collaborator; exact-current-head V2 authority verifies.
	echo "VERIFIED" >"${TEST_ROOT}/crypto-approval-result.txt"

	local result=0
	approve_collaborator_pr "910" "owner/repo" "external-contributor" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case N: CONTRIBUTOR + crypto on PR — function returns 0" 1 \
			"Expected exit 0, got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	local approve_count
	approve_count=$(count_approve_calls)
	if [[ "${approve_count:-0}" -lt 1 ]]; then
		print_result "Case N: CONTRIBUTOR + crypto on PR — approve API called" 1 \
			"Expected at least one 'gh pr review' call. Log: $(cat "$GH_LOG")"
		return 0
	fi
	if ! grep -qF "t3063" "$LOGFILE"; then
		print_result "Case N: CONTRIBUTOR + crypto on PR — t3063 bypass logged" 1 \
			"Expected 't3063' in log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case N: CONTRIBUTOR + crypto-approval on PR — approved via t3063 bypass" 0
	return 0
}

# =============================================================================
# Case O (V2 hardening): CONTRIBUTOR author + linked-issue approval only → blocks.
# Development authority cannot authorize a future or changed external PR head.
# =============================================================================

test_case_o_contributor_with_crypto_on_linked_issue() {
	reset_mock_state
	# A linked issue exists, but the PR-specific verifier returns no authority.
	echo "1" >"${TEST_ROOT}/crypto-comment-count.txt"

	local result=0
	approve_collaborator_pr "920" "owner/repo" "external-contributor" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case O: CONTRIBUTOR + crypto on linked issue — function returns 0" 1 \
			"Expected exit 0, got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	local approve_count
	approve_count=$(count_approve_calls)
	if [[ "${approve_count:-0}" -gt 0 ]]; then
		print_result "Case O: linked-issue approval alone — NO approve API call" 1 \
			"Expected zero 'gh pr review' calls. Log: $(cat "$GH_LOG")"
		return 0
	fi
	if ! grep -qF "GH#17671 defense-in-depth" "$LOGFILE"; then
		print_result "Case O: linked-issue approval alone — refusal audited" 1 \
			"Expected GH#17671 refusal in log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case O: linked-issue approval alone cannot authorize external PR" 0
	return 0
}

# =============================================================================
# Case P (t3063 regression — GH#17671 preservation):
#         CONTRIBUTOR author + NO crypto-approval → still refuses.
# The crypto bypass must NOT weaken the existing Case B guard: when there is
# no crypto approval, external contributors are still blocked from auto-approval.
# =============================================================================

test_case_p_contributor_no_crypto_still_refused() {
	reset_mock_state
	# PR author is NOT a collaborator; crypto-comment-count stays at default 0.
	# Pulse runner IS a collaborator (default state).

	local result=0
	approve_collaborator_pr "930" "owner/repo" "external-contributor" || result=$?

	# Function must return 0 (skip, not error) — same as Case B.
	if [[ "$result" -ne 0 ]]; then
		print_result "Case P: CONTRIBUTOR + no crypto — function returns 0 (skip)" 1 \
			"Expected exit 0, got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	local approve_count
	approve_count=$(count_approve_calls)
	if [[ "${approve_count:-0}" -gt 0 ]]; then
		print_result "Case P: CONTRIBUTOR + no crypto — NO approve API call" 1 \
			"Expected zero 'gh pr review' calls (GH#17671 preserved). Log: $(cat "$GH_LOG")"
		return 0
	fi
	# Verify the t2933 refusal log line is present (not the t3063 bypass).
	if ! grep -qF "GH#17671 defense-in-depth, t2933" "$LOGFILE"; then
		print_result "Case P: CONTRIBUTOR + no crypto — refusal logged with t2933 audit trail" 1 \
			"Expected GH#17671/t2933 attribution in skip log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case P: CONTRIBUTOR + no crypto — refused (GH#17671 guard preserved)" 0
	return 0
}

test_case_q_trusted_issue_sync_can_be_approved() {
	reset_mock_state
	touch "${TEST_ROOT}/issue-sync-trusted"

	local result=0
	approve_collaborator_pr "940" "owner/repo" "app/github-actions" "head-940" || result=$?
	if [[ "$result" -eq 0 && "$(count_approve_calls)" -eq 1 ]] &&
		grep -qF "review-helper is-trusted-issue-sync-pr 940 owner/repo head-940" "$GH_LOG" &&
		grep -qF "commit_id=head-940" "$GH_LOG" &&
		grep -qF "trusted repository-generated Issue Sync PR verified" "$GH_LOG"; then
		print_result "Case Q: exact-head Issue Sync automation receives head-bound approval" 0
		return 0
	fi
	print_result "Case Q: exact-head Issue Sync automation is approved" 1 \
		"rc=${result}; approve=$(count_approve_calls); calls=$(cat "$GH_LOG"); log=$(cat "$LOGFILE")"
	return 0
}

test_case_s_issue_sync_approval_response_mismatch_fails() {
	reset_mock_state
	touch "${TEST_ROOT}/issue-sync-trusted"
	printf 'raced-head\n' >"${TEST_ROOT}/approval-response-head.txt"

	local result=0
	approve_collaborator_pr "942" "owner/repo" "app/github-actions" "head-942" || result=$?
	if [[ "$result" -eq 1 && "$(count_approve_calls)" -eq 1 ]] &&
		grep -qF "commit_id=head-942" "$GH_LOG" &&
		grep -qF "failed to approve PR #942" "$LOGFILE"; then
		print_result "Case S: mismatched approval response fails closed" 0
		return 0
	fi
	print_result "Case S: mismatched approval response is rejected" 1 \
		"rc=${result}; approve=$(count_approve_calls); calls=$(cat "$GH_LOG"); log=$(cat "$LOGFILE")"
	return 0
}

test_case_r_unverified_issue_sync_is_not_approved() {
	reset_mock_state

	local result=0
	approve_collaborator_pr "941" "owner/repo" "app/github-actions" "head-941" || result=$?
	if [[ "$result" -eq 0 && "$(count_approve_calls)" -eq 0 ]] &&
		grep -qF "GH#17671 defense-in-depth" "$LOGFILE"; then
		print_result "Case R: unverified Actions automation remains blocked from approval" 0
		return 0
	fi
	print_result "Case R: unverified Actions automation is not approved" 1 \
		"rc=${result}; approve=$(count_approve_calls); log=$(cat "$LOGFILE")"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_helpers_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_case_a_collaborator_author_approves
	test_case_b_non_collaborator_author_refused
	test_case_c_self_authored_skipped
	test_case_d_runner_lacks_write_access_skipped
	test_case_e_cross_account_approval_short_circuits
	test_case_f_untrusted_or_stale_approval_does_not_short_circuit
	test_case_g_empty_reviews_response_skips_jq
	test_case_h_failed_reviews_request_skips_jq
	test_case_n_contributor_with_crypto_on_pr
	test_case_o_contributor_with_crypto_on_linked_issue
	test_case_p_contributor_no_crypto_still_refused
	test_case_q_trusted_issue_sync_can_be_approved
	test_case_r_unverified_issue_sync_is_not_approved
	test_case_s_issue_sync_approval_response_mismatch_fails

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
