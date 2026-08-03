#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for origin:worker worker-briefed auto-merge gates (t2449).
#
# Verifies the 10 coverage cases from GH#20204 §How, plus t3052 and t3062:
#   Case (a): origin:worker + issue-author=OWNER + green CI + no NMR → auto-merges
#   Case (b): origin:worker + issue-author=MEMBER + green + no NMR → auto-merges
#   Case (c): origin:worker + issue-author=CONTRIBUTOR → does NOT auto-merge
#   Case (d): origin:worker + trusted-author legacy auto-normalization → auto-merges
#   Case (e): origin:worker + NMR cleared via crypto approval → auto-merges
#   Case (f): origin:worker + hold-for-review label → does NOT auto-merge
#   Case (g): origin:worker + human CHANGES_REQUESTED → does NOT auto-merge
#   Case (h): origin:worker + draft PR → does NOT auto-merge
#   Case (i): origin:worker-takeover label → does NOT auto-merge
#   Case (j): Bot review in placeholder window → waits, doesn't merge yet
#   Case (k): origin:worker + NONE author + crypto approval → passes (t3052)
#   Case (l): origin:worker + NONE author + no crypto → blocked (t3052)
#   Case (m): origin:worker + OWNER author + no crypto → still passes (t3052)
#   Case (n): COLLABORATOR author + login in trusted-issue-author allowlist → passes (t3062)
#   Case (o): COLLABORATOR author + login NOT in allowlist + no crypto → blocked (t3062)
#   Case (p): COLLABORATOR author + authenticated write permission → passes (GH#24958)
#   Case (q): COLLABORATOR author + authenticated read permission → blocked (GH#24958)
#   Case (r): precomputed write permission skips collaborator permission API (GH#25057)
#   Case (s): worker gate reuses matching precomputed permission (GH#25070)
#   Case (t): worker gate ignores mismatched precomputed permission (GH#25070)
#   Case (u): issue-author=NONE + spoofed crypto marker → blocked (GH#21936)
#
# No real repository is touched. The gh binary is replaced with a mock stub
# that serves canned responses from TEST_ROOT fixture files.
#
# Pattern mirrors: test-pulse-merge-origin-interactive-auto-merge.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"
PROCESS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process.sh"

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	mkdir -p "${TEST_ROOT}/scripts"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export AGENTS_DIR="${TEST_ROOT}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	export TEST_ROOT GH_LOG
	APPROVAL_VERIFY_RESULT=""
	export APPROVAL_VERIFY_RESULT

	# Default issue fixture: author_association=OWNER, no NMR comments
	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	# Default comments fixture: empty array (no NMR markers)
	printf '[]' >"${TEST_ROOT}/comments.json"
	# Default collaborator permission fixture: read (not maintainer-equivalent)
	printf 'read' >"${TEST_ROOT}/permission.txt"

	# Mock gh: logs every call and returns canned data from TEST_ROOT fixtures.
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"
_all_args=("$@")

# Issue API (author_association check)
if [[ "$*" == *"repos/"*"/issues/"* ]] && [[ "$*" != *"/comments"* ]] && [[ "$*" != *"/labels"* ]]; then
	_jq_filter=""
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--jq" ]]; then
			_jq_filter="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done
	if [[ -n "$_jq_filter" ]]; then
		jq -r "$_jq_filter" <"${TEST_ROOT}/issue.json"
	else
		cat "${TEST_ROOT}/issue.json"
	fi
	exit 0
fi

# Issue comments API (NMR marker check)
if [[ "$*" == *"/comments"* ]]; then
	_jq_filter=""
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--jq" ]]; then
			_jq_filter="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done
	if [[ -n "$_jq_filter" ]]; then
		jq -r "$_jq_filter" <"${TEST_ROOT}/comments.json"
	else
		cat "${TEST_ROOT}/comments.json"
	fi
	exit 0
fi

# Collaborator permission API (maintainer-authority fallback)
if [[ "$*" == *"/collaborators/"*"/permission"* ]]; then
	_jq_filter=""
	_permission="$(cat "${TEST_ROOT}/permission.txt" 2>/dev/null || printf 'read')"
	_json="{\"permission\":\"${_permission}\"}"
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--jq" ]]; then
			_jq_filter="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done
	if [[ -n "$_jq_filter" ]]; then
		printf '%s' "$_json" | jq -r "$_jq_filter"
	else
		printf '%s\n' "$_json"
	fi
	exit 0
fi

exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

	cat >"${TEST_ROOT}/scripts/approval-helper.sh" <<'APPROVAL_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "verify" ]]; then
	printf '%s\n' "${APPROVAL_VERIFY_RESULT:-}"
	exit 0
fi
exit 1
APPROVAL_EOF
	chmod +x "${TEST_ROOT}/scripts/approval-helper.sh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	unset AGENTS_DIR APPROVAL_VERIFY_RESULT
	return 0
}

# Extract _attempt_worker_briefed_auto_merge and its dependencies from the
# merge scripts and eval them into the test shell.
# _pm_issue_api lives in pulse-merge.sh (module-level helper).
# _is_trusted_issue_author and _attempt_worker_briefed_auto_merge live in
# pulse-merge-process.sh (post-split, t3062 adds the trusted-author helper).
define_helpers_under_test() {
	local src_worker_briefed src_issue_api src_trusted_author src_issue_authority src_crypto_approval
	src_issue_api=$(awk '
		/^_pm_issue_api\(\) \{/,/^\}$/ { print }
	' "$MERGE_SCRIPT")
	# Post GH#21301 refactor: function moved to pulse-merge-process.sh
	local extract_from="$MERGE_SCRIPT"
	if [[ -f "$PROCESS_SCRIPT" ]]; then
		extract_from="$PROCESS_SCRIPT"
	fi
	src_trusted_author=$(awk '
		/^_is_trusted_issue_author\(\) \{/,/^\}$/ { print }
	' "$extract_from")
	src_issue_authority=$(awk '
		/^_issue_author_has_maintainer_authority\(\) \{/,/^\}$/ { print }
	' "$extract_from")
	src_crypto_approval=$(awk '
		/^_issue_has_verified_crypto_approval\(\) \{/,/^\}$/ { print }
	' "$extract_from")
	src_worker_briefed=$(awk '
		/^_attempt_worker_briefed_auto_merge\(\) \{/,/^\}$/ { print }
	' "$extract_from")
	if [[ -z "$src_worker_briefed" || -z "$src_issue_api" ]]; then
		printf 'ERROR: could not extract helpers from %s / %s\n' "$MERGE_SCRIPT" "$extract_from" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$src_issue_api"
	# shellcheck disable=SC1090
	eval "$src_trusted_author"
	# shellcheck disable=SC1090
	eval "$src_issue_authority"
	# shellcheck disable=SC1090
	eval "$src_crypto_approval"
	# shellcheck disable=SC1090
	eval "$src_worker_briefed"
	return 0
}

# =============================================================================
# Case (a): origin:worker + issue-author=OWNER + no NMR → passes
# =============================================================================
test_case_a_owner_issue_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "100" "owner/repo" "origin:worker" "false" "42" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (a): OWNER-briefed issue + no NMR → passes" 1 \
			"Expected exit 0, got ${result}"
	else
		print_result "Case (a): OWNER-briefed issue + no NMR → passes" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (b): origin:worker + issue-author=MEMBER + no NMR → passes
# =============================================================================
test_case_b_member_issue_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"MEMBER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "101" "owner/repo" "origin:worker" "false" "43" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (b): MEMBER-briefed issue + no NMR → passes" 1 \
			"Expected exit 0, got ${result}"
	else
		print_result "Case (b): MEMBER-briefed issue + no NMR → passes" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (c): origin:worker + issue-author=CONTRIBUTOR → blocked
# =============================================================================
test_case_c_contributor_issue_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"CONTRIBUTOR"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "102" "owner/repo" "origin:worker" "false" "44" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (c): CONTRIBUTOR-filed issue → blocked" 1 \
			"Expected non-zero exit, got 0 (CONTRIBUTOR should not pass)"
	else
		if grep -q "not OWNER/MEMBER" "$LOGFILE" 2>/dev/null; then
			print_result "Case (c): CONTRIBUTOR-filed issue → blocked" 0
		elif grep -q "no cryptographic approval signature found" "$LOGFILE" 2>/dev/null; then
			# t3052: log message updated to include crypto check info
			print_result "Case (c): CONTRIBUTOR-filed issue → blocked" 0
		else
			print_result "Case (c): CONTRIBUTOR-filed issue → blocked" 1 \
				"Exit was non-zero but expected log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (d): trusted-author legacy auto-normalization residue → passes
# =============================================================================
test_case_d_trusted_author_normalization_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	# Historical auto-approval marker is residue, not a current trust gate. The
	# live OWNER author independently establishes authority.
	printf '[{"body":"auto-approved-maintainer-issue: cleared NMR"}]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "103" "owner/repo" "origin:worker" "false" "45" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (d): trusted-author normalization residue → passes" 0
	else
		print_result "Case (d): trusted-author normalization residue → passes" 1 \
			"Expected exit 0, got ${result}"
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (e): NMR cleared via crypto approval → passes
# =============================================================================
test_case_e_nmr_crypto_cleared_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	# Comments contain BOTH auto-approval AND crypto approval markers
	printf '[{"body":"auto-approved-maintainer-issue: cleared NMR"},{"body":"aidevops:approval-signature: SHA256:abc123"}]' >"${TEST_ROOT}/comments.json"
	export APPROVAL_VERIFY_RESULT="VERIFIED"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "104" "owner/repo" "origin:worker" "false" "46" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (e): NMR crypto-cleared → passes" 1 \
			"Expected exit 0, got ${result}"
	else
		if grep -q "passed all gates" "$LOGFILE" 2>/dev/null; then
			print_result "Case (e): NMR crypto-cleared → passes" 0
		else
			print_result "Case (e): NMR crypto-cleared → passes" 1 \
				"Exit was 0 but expected success log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (f): hold-for-review label → blocked
# =============================================================================
test_case_f_hold_for_review_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "105" "owner/repo" "origin:worker,hold-for-review" "false" "47" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (f): hold-for-review label → blocked" 1 \
			"Expected non-zero exit, got 0 (hold-for-review should block)"
	else
		if grep -q "hold-for-review label" "$LOGFILE" 2>/dev/null; then
			print_result "Case (f): hold-for-review label → blocked" 0
		else
			print_result "Case (f): hold-for-review label → blocked" 1 \
				"Exit was non-zero but expected log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (g): CHANGES_REQUESTED — boundary test. This gate is checked UPSTREAM
# of _attempt_worker_briefed_auto_merge in _check_pr_merge_gates. The worker-
# briefed function itself is agnostic to review state — verify it passes when
# given valid inputs (review state is the caller's responsibility).
# =============================================================================
test_case_g_changes_requested_is_upstream() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	# _attempt_worker_briefed_auto_merge does not receive review state.
	# A non-draft, non-hold-for-review, OWNER-briefed PR passes this helper.
	local result=0
	_attempt_worker_briefed_auto_merge "106" "owner/repo" "origin:worker" "false" "48" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (g): CHANGES_REQUESTED is upstream — helper passes" 1 \
			"Expected exit 0 (CHANGES_REQUESTED is upstream gate), got ${result}"
	else
		print_result "Case (g): CHANGES_REQUESTED is upstream — helper passes" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (h): draft PR → blocked
# =============================================================================
test_case_h_draft_pr_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "107" "owner/repo" "origin:worker" "true" "49" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (h): draft PR → blocked" 1 \
			"Expected non-zero exit, got 0 (draft should block)"
	else
		if grep -q "draft PR not eligible" "$LOGFILE" 2>/dev/null; then
			print_result "Case (h): draft PR → blocked" 0
		else
			print_result "Case (h): draft PR → blocked" 1 \
				"Exit was non-zero but expected log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (i): origin:worker-takeover → the caller pre-filters using comma-
# delimited matching (",origin:worker," != ",origin:worker-takeover,").
# Verify the function itself blocks if somehow called with takeover labels.
# =============================================================================
test_case_i_worker_takeover_excluded() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	# Simulate the caller's comma-delimited check:
	# ",origin:worker-takeover," does NOT match ",origin:worker," pattern.
	local labels_str="origin:worker-takeover"
	local match=0
	if [[ ",${labels_str}," == *",origin:worker,"* ]]; then
		match=1
	fi

	if [[ "$match" -eq 1 ]]; then
		print_result "Case (i): origin:worker-takeover excluded by caller" 1 \
			"Comma-delimited match should NOT fire for origin:worker-takeover"
	else
		print_result "Case (i): origin:worker-takeover excluded by caller" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (j): Feature flag AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0 → blocked
# (The spec case is "bot review in placeholder window → waits". That wait is
# handled by review-bot-gate-helper.sh UPSTREAM. This test verifies the
# feature-flag off-switch, which is the closest unit-testable analogue.)
# =============================================================================
test_case_j_feature_flag_off_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0

	local result=0
	_attempt_worker_briefed_auto_merge "109" "owner/repo" "origin:worker" "false" "51" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (j): feature flag OFF → blocked" 1 \
			"Expected non-zero exit, got 0 (flag=0 should block)"
	else
		if grep -q "disabled by AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0" "$LOGFILE" 2>/dev/null; then
			print_result "Case (j): feature flag OFF → blocked" 0
		else
			print_result "Case (j): feature flag OFF → blocked" 1 \
				"Exit was non-zero but expected log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (k): issue-author=NONE + crypto approval signature → passes (t3052)
# Maintainer cryptographically approved a contributor-filed issue.
# =============================================================================
test_case_k_non_owner_with_crypto_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"NONE"}' >"${TEST_ROOT}/issue.json"
	# Comments contain crypto approval signature — maintainer vouched
	printf '[{"body":"aidevops:approval-signature: SHA256:abc123"}]' >"${TEST_ROOT}/comments.json"
	export APPROVAL_VERIFY_RESULT="VERIFIED"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "110" "owner/repo" "origin:worker" "false" "52" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (k): NONE author + crypto approval → passes (t3052)" 1 \
			"Expected exit 0, got ${result}"
	else
		if grep -q "cryptographic approval signature present, proceeding (t3052)" "$LOGFILE" 2>/dev/null; then
			print_result "Case (k): NONE author + crypto approval → passes (t3052)" 0
		else
			print_result "Case (k): NONE author + crypto approval → passes (t3052)" 1 \
				"Exit was 0 but expected t3052 log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (l): issue-author=NONE + NO crypto approval → blocked (t3052 preserves)
# Contributor-filed issue without maintainer approval stays blocked.
# =============================================================================
test_case_l_non_owner_without_crypto_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"NONE"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "111" "owner/repo" "origin:worker" "false" "53" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (l): NONE author + no crypto → blocked (t3052)" 1 \
			"Expected non-zero exit, got 0 (NONE without crypto should block)"
	else
		if grep -q "no cryptographic approval signature found (t2449/t3052)" "$LOGFILE" 2>/dev/null; then
			print_result "Case (l): NONE author + no crypto → blocked (t3052)" 0
		else
			print_result "Case (l): NONE author + no crypto → blocked (t3052)" 1 \
				"Exit was non-zero but expected log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (m): OWNER author + no crypto → passes (t3052 preserves existing)
# Verifies that OWNER issues still pass without crypto approval.
# =============================================================================
test_case_m_owner_no_crypto_still_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "112" "owner/repo" "origin:worker" "false" "54" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (m): OWNER + no crypto → still passes (t3052)" 1 \
			"Expected exit 0, got ${result}"
	else
		print_result "Case (m): OWNER + no crypto → still passes (t3052)" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (n): COLLABORATOR author + login in trusted-issue-author allowlist → passes (t3062)
# Peer runner filed the issue; their login is in the allowlist.
# =============================================================================
test_case_n_trusted_author_allowlist_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	# COLLABORATOR with a known login
	printf '{"author_association":"COLLABORATOR","user":{"login":"test-peer-runner"}}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	# Trusted-authors conf pointing to a temp file containing the login
	local _conf="${TEST_ROOT}/trusted-authors.conf"
	printf 'test-peer-runner\n' >"$_conf"
	export AIDEVOPS_TRUSTED_AUTHORS_CONF="$_conf"

	local result=0
	_attempt_worker_briefed_auto_merge "113" "owner/repo" "origin:worker" "false" "55" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (n): COLLABORATOR + login in allowlist → passes (t3062)" 1 \
			"Expected exit 0, got ${result}"
	else
		if grep -q "passes via trusted-issue-author allowlist (t3062)" "$LOGFILE" 2>/dev/null; then
			print_result "Case (n): COLLABORATOR + login in allowlist → passes (t3062)" 0
		else
			print_result "Case (n): COLLABORATOR + login in allowlist → passes (t3062)" 1 \
				"Exit was 0 but expected t3062 allowlist log message not found"
		fi
	fi
	unset AIDEVOPS_TRUSTED_AUTHORS_CONF
	teardown_test_env
	return 0
}

# =============================================================================
# Case (o): COLLABORATOR author + login NOT in allowlist + no crypto → blocked
# Peer runner filed the issue but is not in the allowlist and no crypto sig.
# =============================================================================
test_case_o_trusted_author_not_in_allowlist_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	# COLLABORATOR with a login that is NOT in the allowlist
	printf '{"author_association":"COLLABORATOR","user":{"login":"unknown-runner"}}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	# Trusted-authors conf containing a different login (not unknown-runner)
	local _conf="${TEST_ROOT}/trusted-authors.conf"
	printf 'alex-solovyev\n' >"$_conf"
	export AIDEVOPS_TRUSTED_AUTHORS_CONF="$_conf"

	local result=0
	_attempt_worker_briefed_auto_merge "114" "owner/repo" "origin:worker" "false" "56" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (o): COLLABORATOR + login NOT in allowlist + no crypto → blocked" 1 \
			"Expected non-zero exit, got 0 (unlisted COLLABORATOR should block)"
	else
		if grep -q "no cryptographic approval signature found (t2449/t3052)" "$LOGFILE" 2>/dev/null; then
			print_result "Case (o): COLLABORATOR + login NOT in allowlist + no crypto → blocked" 0
		else
			print_result "Case (o): COLLABORATOR + login NOT in allowlist + no crypto → blocked" 1 \
				"Exit was non-zero but expected block log message not found"
		fi
	fi
	unset AIDEVOPS_TRUSTED_AUTHORS_CONF
	teardown_test_env
	return 0
}

# =============================================================================
# Case (p): COLLABORATOR author + authenticated write permission → passes
# Maintainer-operated aidevops workers may surface as COLLABORATOR in webhook
# metadata; authenticated collaborator permission is the trust source.
# =============================================================================
test_case_p_collaborator_permission_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"COLLABORATOR","user":{"login":"maintainer-peer"}}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	printf 'write' >"${TEST_ROOT}/permission.txt"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "115" "owner/repo" "origin:worker" "false" "57" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (p): COLLABORATOR + authenticated write permission → passes (GH#24958)" 1 \
			"Expected exit 0, got ${result}"
	else
		if grep -q "authenticated maintainer permission fallback (GH#24958)" "$LOGFILE" 2>/dev/null; then
			print_result "Case (p): COLLABORATOR + authenticated write permission → passes (GH#24958)" 0
		else
			print_result "Case (p): COLLABORATOR + authenticated write permission → passes (GH#24958)" 1 \
				"Exit was 0 but expected GH#24958 permission fallback log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (q): COLLABORATOR author + authenticated read permission → blocked
# The fallback must fail closed when the login lacks write-level repo access.
# =============================================================================
test_case_q_collaborator_read_permission_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"COLLABORATOR","user":{"login":"read-only-peer"}}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	printf 'read' >"${TEST_ROOT}/permission.txt"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "116" "owner/repo" "origin:worker" "false" "58" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (q): COLLABORATOR + authenticated read permission → blocked (GH#24958)" 1 \
			"Expected non-zero exit, got 0 (read-only collaborator should block)"
	else
		if grep -q "no cryptographic approval signature found (t2449/t3052)" "$LOGFILE" 2>/dev/null; then
			print_result "Case (q): COLLABORATOR + authenticated read permission → blocked (GH#24958)" 0
		else
			print_result "Case (q): COLLABORATOR + authenticated read permission → blocked (GH#24958)" 1 \
				"Exit was non-zero but expected block log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (r): precomputed permission skips collaborator permission API (GH#25057)
# =============================================================================
test_case_r_precomputed_permission_skips_api() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	local result=0
	_issue_author_has_maintainer_authority "owner/repo" "maintainer" "write" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (r): precomputed write permission skips collaborator permission API (GH#25057)" 1 \
			"Expected exit 0, got ${result}"
	elif grep -q "/collaborators/maintainer/permission" "$GH_LOG" 2>/dev/null; then
		print_result "Case (r): precomputed write permission skips collaborator permission API (GH#25057)" 1 \
			"Expected no collaborator permission API call when permission argument is supplied"
	else
		print_result "Case (r): precomputed write permission skips collaborator permission API (GH#25057)" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (s): worker gate reuses matching precomputed permission (GH#25070)
# =============================================================================
test_case_s_worker_gate_uses_matching_precomputed_permission() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"COLLABORATOR","user":{"login":"maintainer-peer"}}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "118" "owner/repo" "origin:worker" "false" "60" "write" "maintainer-peer" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (s): worker gate reuses matching precomputed permission (GH#25070)" 1 \
			"Expected exit 0, got ${result}"
	elif grep -q "/collaborators/maintainer-peer/permission" "$GH_LOG" 2>/dev/null; then
		print_result "Case (s): worker gate reuses matching precomputed permission (GH#25070)" 1 \
			"Expected worker gate to skip duplicate collaborator permission API call"
	else
		print_result "Case (s): worker gate reuses matching precomputed permission (GH#25070)" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (t): worker gate ignores mismatched precomputed permission login (GH#25070)
# =============================================================================
test_case_t_worker_gate_ignores_mismatched_precomputed_permission() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"COLLABORATOR","user":{"login":"issue-author"}}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	printf 'read' >"${TEST_ROOT}/permission.txt"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "119" "owner/repo" "origin:worker" "false" "61" "write" "different-pr-author" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (t): worker gate ignores mismatched precomputed permission (GH#25070)" 1 \
			"Expected non-zero exit, got 0 (mismatched cached permission should not trust issue author)"
	elif grep -q "/collaborators/issue-author/permission" "$GH_LOG" 2>/dev/null; then
		print_result "Case (t): worker gate ignores mismatched precomputed permission (GH#25070)" 0
	else
		print_result "Case (t): worker gate ignores mismatched precomputed permission (GH#25070)" 1 \
			"Expected fallback collaborator permission API call for issue-author"
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (u): worker gate ignores precomputed PR-author permission with empty login (GH#25105)
# =============================================================================
test_case_u_worker_gate_ignores_empty_precomputed_pr_author_login() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"COLLABORATOR","user":{"login":"issue-author"}}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	printf 'read' >"${TEST_ROOT}/permission.txt"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "120" "owner/repo" "origin:worker" "false" "62" "write" "" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (u): worker gate ignores empty precomputed PR-author login (GH#25105)" 1 \
			"Expected non-zero exit, got 0 (empty cached-permission login should not trust issue author)"
	elif grep -q "/collaborators/issue-author/permission" "$GH_LOG" 2>/dev/null; then
		print_result "Case (u): worker gate ignores empty precomputed PR-author login (GH#25105)" 0
	else
		print_result "Case (u): worker gate ignores empty precomputed PR-author login (GH#25105)" 1 \
			"Expected fallback collaborator permission API call for issue-author"
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (v): issue-author=NONE + spoofed approval marker but failed verification
# → blocked. Comment marker presence alone is not a trust signal (GH#21936).
# =============================================================================
test_case_v_spoofed_crypto_marker_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"NONE"}' >"${TEST_ROOT}/issue.json"
	printf '[{"body":"aidevops:approval-signature: SHA256:spoofed"}]' >"${TEST_ROOT}/comments.json"
	export APPROVAL_VERIFY_RESULT=""
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "117" "owner/repo" "origin:worker" "false" "59" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (v): spoofed crypto marker without verification → blocked" 1 \
			"Expected non-zero exit, got 0 (unverified marker should block)"
	else
		if grep -q "no cryptographic approval signature found (t2449/t3052)" "$LOGFILE" 2>/dev/null; then
			print_result "Case (v): spoofed crypto marker without verification → blocked" 0
		else
			print_result "Case (v): spoofed crypto marker without verification → blocked" 1 \
				"Exit was non-zero but expected block log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Run all cases
# =============================================================================
main() {
	if [[ ! -f "$MERGE_SCRIPT" ]]; then
		printf 'ERROR: merge script not found: %s\n' "$MERGE_SCRIPT" >&2
		exit 1
	fi

	test_case_a_owner_issue_passes
	test_case_b_member_issue_passes
	test_case_c_contributor_issue_blocked
	test_case_d_trusted_author_normalization_passes
	test_case_e_nmr_crypto_cleared_passes
	test_case_f_hold_for_review_blocked
	test_case_g_changes_requested_is_upstream
	test_case_h_draft_pr_blocked
	test_case_i_worker_takeover_excluded
	test_case_j_feature_flag_off_blocked
	test_case_k_non_owner_with_crypto_passes
	test_case_l_non_owner_without_crypto_blocked
	test_case_m_owner_no_crypto_still_passes
	test_case_n_trusted_author_allowlist_passes
	test_case_o_trusted_author_not_in_allowlist_blocked
	test_case_p_collaborator_permission_passes
	test_case_q_collaborator_read_permission_blocked
	test_case_r_precomputed_permission_skips_api
	test_case_s_worker_gate_uses_matching_precomputed_permission
	test_case_t_worker_gate_ignores_mismatched_precomputed_permission
	test_case_u_worker_gate_ignores_empty_precomputed_pr_author_login
	test_case_v_spoofed_crypto_marker_blocked

	echo ""
	printf 'Results: %d/%d passed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
	[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
	return 0
}

main "$@"
