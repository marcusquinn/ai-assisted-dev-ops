#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#23087/GH#24438: when GitHub rulesets reject the
# historical `gh pr merge --admin` path, deterministic merge first asks GitHub
# to auto-merge/queue the PR without admin bypass instead of recording another
# failed zero-progress cycle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"
MERGE_PROCESS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process.sh"
REQUIRED_CHECKS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-required-checks.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""
REMEDIATION_LOG=""
MERGE_EVENT_LOG=""
CACHE_INVALIDATION_LOG=""
_OW_LABEL_PAT=",origin:worker,"
RULESET_GATE_HEAD=""

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

_install_ruleset_gh_stub() {
cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

mode="${GH_STUB_MODE:-ruleset}"

if [[ "$1" == "api" && "${2:-}" == "user" ]]; then
	printf '%s\n' '{"login":"tester"}'
	exit 0
fi

if [[ "$mode" == "stale-cache-401" && "$1" == "pr" && "$2" == "merge" && "$*" == *"--admin"* ]]; then
	count_file="${TEST_ROOT}/merge-count.txt"
	count=0
	if [[ -f "$count_file" ]]; then
		count=$(cat "$count_file")
	fi
	count=$((count + 1))
	printf '%s\n' "$count" >"$count_file"
	if [[ "$count" -eq 1 ]]; then
		printf '%s\n' 'non-200 OK status code: 401 Unauthorized body: "{ \"message\": \"Requires authentication\" }"' >&2
		exit 1
	fi
	exit 0
fi

if [[ "$mode" == "terminal-closed" && "$1" == "pr" && "$2" == "merge" ]]; then
	printf '%s\n' 'X Pull request owner/repo#77 is not mergeable: the pull request is closed.' >&2
	exit 1
fi

if [[ "$mode" == "terminal-closed" && "$1" == "pr" && "$2" == "view" && "$*" == *"--json state"* ]]; then
	printf '%s\n' 'CLOSED'
	exit 0
fi

if [[ "$mode" == "conversation-chain" && "$1" == "pr" && "$2" == "merge" && "$*" == *"--admin"* ]]; then
	printf '%s\n' 'GraphQL: Repository rule violations found' >&2
	printf '%s\n' 'GraphQL: A conversation must be resolved before merging' >&2
	exit 1
fi

if [[ "$mode" == "conversation-chain" && "$1" == "pr" && "$2" == "merge" && "$*" == *"--auto"* ]]; then
	printf '%s\n' 'GraphQL: Pull request is not eligible for native auto-merge' >&2
	exit 1
fi

if [[ "$mode" == "conversation-chain" && "$1" == "pr" && "$2" == "merge" ]]; then
	printf '%s\n' 'X Pull request owner/repo#77 is not mergeable: the base branch policy prohibits the merge.' >&2
	exit 1
fi

if [[ "$mode" == "expected-check" && "$1" == "pr" && "$2" == "merge" && "$*" == *"--admin"* ]]; then
	printf '%s\n' 'GraphQL: Required status check "review-bot-gate" is expected. (mergePullRequest)' >&2
	exit 1
fi

if [[ "$mode" == "pending-check" && "$1" == "pr" && "$2" == "merge" && "$*" == *"--admin"* ]]; then
	printf '%s\n' 'GraphQL: Required status check "maintainer-gate" is pending. (mergePullRequest)' >&2
	exit 1
fi

if [[ ( "$mode" == "expected-check" || "$mode" == "pending-check" ) && "$1" == "api" && "${2:-}" == "--method" && "${3:-}" == "PUT" && "${4:-}" == "repos/owner/repo/pulls/77/update-branch" ]]; then
	exit 0
fi

if [[ "$1" == "pr" && "$2" == "merge" && "$*" == *"--admin"* ]]; then
	printf '%s\n' 'GraphQL: Repository rule violations found' >&2
	exit 1
fi

if [[ "$1" == "pr" && "$2" == "merge" && "$*" == *"--auto"* ]]; then
	exit 0
fi

if [[ "$1" == "pr" && "$2" == "merge" ]]; then
	printf '%s\n' 'X Pull request owner/repo#77 is not mergeable: the base branch policy prohibits the merge.' >&2
	exit 1
fi

exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export GH_STUB_MODE="${GH_STUB_MODE:-ruleset}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	REMEDIATION_LOG="${TEST_ROOT}/remediation.log"
	: >"$REMEDIATION_LOG"
	MERGE_EVENT_LOG="${TEST_ROOT}/merge-events.log"
	: >"$MERGE_EVENT_LOG"
	CACHE_INVALIDATION_LOG="${TEST_ROOT}/cache-invalidations.log"
	: >"$CACHE_INVALIDATION_LOG"
	export TEST_ROOT GH_LOG REMEDIATION_LOG MERGE_EVENT_LOG CACHE_INVALIDATION_LOG
	FINAL_GATE_RC=0
	FINAL_GATE_BLOCKER_KIND=""
	PREFLIGHT_REMEDIATION_CALLS=0
	_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND=""
	_install_ruleset_gh_stub
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

define_function_under_test() {
	local src_invalidate
	local src_normalize_pr_state
	local src_terminal
	local src_process
	local src_webhook_process
	src_invalidate=$(awk '
		/^_pulse_merge_invalidate_pr_list_cache\(\) \{/,/^\}$/ { print }
	' "$MERGE_SCRIPT")
	src_normalize_pr_state=$(awk '
		/^_pmp_normalize_pr_lifecycle_state_into\(\) \{/,/^\}$/ { print }
	' "$MERGE_PROCESS_SCRIPT")
	src_terminal=$(awk '
		/^_pulse_merge_failure_is_terminal\(\) \{/,/^\}$/ { print }
	' "$MERGE_SCRIPT")
	src_process=$(awk '
		/^_process_single_ready_pr\(\) \{/,/^\}$/ { print }
	' "$MERGE_SCRIPT")
	src_webhook_process=$(awk '
		/^process_pr\(\) \{/,/^\}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$src_invalidate" || -z "$src_normalize_pr_state" || -z "$src_terminal" || -z "$src_process" || -z "$src_webhook_process" ]]; then
		printf 'ERROR: could not extract merge helpers from %s and %s\n' "$MERGE_SCRIPT" "$MERGE_PROCESS_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	source "${SCRIPT_DIR}/../gh-merge-cache-remediation-lib.sh"
	# shellcheck disable=SC1090
	eval "$src_invalidate"
	# shellcheck disable=SC1090
	eval "$src_normalize_pr_state"
	# shellcheck disable=SC1090
	eval "$src_terminal"
	# shellcheck disable=SC1090
	eval "$src_process"
	# shellcheck disable=SC1090
	eval "$src_webhook_process"
	return 0
}

_pmp_normalize_mergeable_state_into() {
	local __var_name="$1"
	local __value="$2"
	printf -v "$__var_name" '%s' "$__value"
	return 0
}

_pmp_normalize_review_decision_into() {
	local __var_name="$1"
	local __value="$2"
	printf -v "$__var_name" '%s' "$__value"
	return 0
}

_pmp_review_decision_is_unknown() {
	local __value="$1"
	[[ -z "$__value" || "$__value" == "UNKNOWN" ]]
	return $?
}

PULSE_UNKNOWN_STATE="UNKNOWN"
PULSE_MERGE_BOOL_TRUE="true"
PMRC_JSON_ARRAY="array"
PMRC_JSON_NUMBER="number"
PMRC_JSON_OBJECT="object"
PMRC_JSON_STRING="string"
_resolve_pr_mergeable_status() { return 0; }
_extract_linked_issue() { printf '123'; return 0; }
_check_pr_merge_gates() { return 0; }
_pr_required_checks_pass() { return 0; }
approve_collaborator_pr() { return 0; }
_check_ruleset_required_reviews_passing() {
	local repo_slug="$1"
	local pr_number="$2"
	local pr_author="$3"
	local expected_head_sha="$4"
	: "$repo_slug" "$pr_number" "$pr_author"
	RULESET_GATE_HEAD="$expected_head_sha"
	return 0
}
_extract_merge_summary() { printf 'summary'; return 0; }
_retarget_stacked_children() { return 0; }
_pmp_is_protected_release_pr() { return 1; }
_pulse_merge_admin_safety_check() { return 0; }
_pulse_merge_final_trust_gate() {
	_PULSE_FINAL_REQUIRES_SYNCHRONOUS_MERGE=0
	_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="${FINAL_GATE_BLOCKER_KIND:-}"
	return "${FINAL_GATE_RC:-0}"
}
_set_native_auto_merge_or_skip() { return 1; }
_repo_allows_auto_merge() { return "${REPO_ALLOWS_AUTO_MERGE_RC:-0}"; }
_attempt_existing_auto_merge_behind_update_branch() { return 1; }
_attempt_green_behind_update_branch() { return "${GREEN_BEHIND_UPDATE_RC:-1}"; }
_pmp_update_branch_rest() {
	local pr_number="$1"
	local repo_slug="$2"
	gh api --method PUT "repos/${repo_slug}/pulls/${pr_number}/update-branch"
	return $?
}
sleep() {
	local seconds="$1"
	printf 'sleep:%s\n' "$seconds" >>"$MERGE_EVENT_LOG"
	return 0
}
_pmp_record_deterministic_progress_now() {
	local merged_count="$1"
	local progress_count="$2"
	printf 'progress:%s:%s\n' "$merged_count" "$progress_count" >>"$MERGE_EVENT_LOG"
	return 0
}
_handle_post_merge_actions() {
	printf 'post-merge\n' >>"$MERGE_EVENT_LOG"
	return 0
}
_pulse_merge_ready_pr_json_fields() {
	printf 'number,state,mergeable,reviewDecision,author,title,updatedAt,headRefOid,headRefName,baseRefName,labels,isDraft'
	return 0
}

RULESET_REVIEWS_JSON="[]"

_pmrc_gh_read() {
	local command_name="$1"
	shift
	if [[ "$command_name" == "gh" && "$*" == *"repos/owner/repo --jq .default_branch"* ]]; then
		printf 'main\n'
		return 0
	fi
	if [[ "$command_name" == "gh" && "$*" == *"repos/owner/repo/pulls/77/reviews?per_page=100"* ]]; then
		printf '%s\n' "$RULESET_REVIEWS_JSON"
		return 0
	fi
	return 1
}

_ruleset_required_review_policy_for_default_branch() {
	local repo_slug="$1"
	local default_branch="$2"
	[[ "$repo_slug" == "owner/repo" && "$default_branch" == "main" ]] || return 1
	printf '1\t0\n'
	return 0
}

define_ruleset_review_function_under_test() {
	local helper_src=""
	helper_src=$(awk '
		/^_check_ruleset_required_reviews_passing\(\) \{/,/^\}$/ { print }
	' "$REQUIRED_CHECKS_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract ruleset review helper from %s\n' "$REQUIRED_CHECKS_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$helper_src"
	return 0
}

assert_ruleset_review_sequence() {
	local test_name="$1"
	local reviews_json="$2"
	local expected_rc="$3"
	local pr_author="${4-author}"
	local actual_rc=0
	RULESET_REVIEWS_JSON="$reviews_json"
	_check_ruleset_required_reviews_passing "owner/repo" "77" "$pr_author" "head-current" || actual_rc=$?
	if [[ "$actual_rc" -eq "$expected_rc" ]]; then
		print_result "$test_name" 0
		return 0
	fi
	print_result "$test_name" 1 "expected rc=${expected_rc}, actual rc=${actual_rc}"
	return 0
}

test_ruleset_required_review_decision_sequences() {
	setup_test_env
	define_ruleset_review_function_under_test || {
		teardown_test_env
		return 0
	}

	assert_ruleset_review_sequence "APPROVED then COMMENTED preserves approval" \
		'[[{"id":1,"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-08-23T10:00:00Z"},{"id":2,"user":{"login":"reviewer"},"state":"COMMENTED","submitted_at":"2026-08-23T11:00:00Z"}]]' 0
	assert_ruleset_review_sequence "CHANGES_REQUESTED then COMMENTED remains unapproved" \
		'[[{"id":3,"user":{"login":"reviewer"},"state":"CHANGES_REQUESTED","submitted_at":"2026-08-23T10:00:00Z"},{"id":4,"user":{"login":"reviewer"},"state":"COMMENTED","submitted_at":"2026-08-23T11:00:00Z"}]]' 1
	assert_ruleset_review_sequence "APPROVED then CHANGES_REQUESTED remains unapproved" \
		'[[{"id":5,"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-08-23T10:00:00Z"},{"id":6,"user":{"login":"reviewer"},"state":"CHANGES_REQUESTED","submitted_at":"2026-08-23T11:00:00Z"}]]' 1
	assert_ruleset_review_sequence "APPROVED then DISMISSED remains unapproved" \
		'[[{"id":7,"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-08-23T10:00:00Z"},{"id":8,"user":{"login":"reviewer"},"state":"DISMISSED","submitted_at":"2026-08-23T11:00:00Z"}]]' 1
	assert_ruleset_review_sequence "PR author approval remains excluded" \
		'[[{"id":9,"user":{"login":"author"},"state":"APPROVED","submitted_at":"2026-08-23T10:00:00Z"}]]' 1
	assert_ruleset_review_sequence "malformed substantive review fails closed" \
		'[[{"id":10,"user":{"login":"reviewer"},"state":"APPROVED"}]]' 1
	assert_ruleset_review_sequence "unknown review state fails closed" \
		'[[{"id":11,"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-08-23T10:00:00Z"},{"id":12,"user":{"login":"reviewer"},"state":"CHANGES_REQUESTED ","submitted_at":"2026-08-23T11:00:00Z"}]]' 1
	assert_ruleset_review_sequence "malformed review timestamp fails closed" \
		'[[{"id":13,"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"not-rfc3339"}]]' 1
	assert_ruleset_review_sequence "non-positive review id fails closed" \
		'[[{"id":0,"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-08-23T10:00:00Z"}]]' 1
	assert_ruleset_review_sequence "PR author exclusion is case-insensitive" \
		'[[{"id":14,"user":{"login":"Author"},"state":"APPROVED","submitted_at":"2026-08-23T10:00:00Z"}]]' 1
	assert_ruleset_review_sequence "lowercase review state fails closed" \
		'[[{"id":15,"user":{"login":"reviewer"},"state":"approved","submitted_at":"2026-08-23T10:00:00Z"}]]' 1
	assert_ruleset_review_sequence "COMMENTED without ordering fields remains non-substantive" \
		'[[{"id":16,"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-08-23T10:00:00Z"},{"state":"COMMENTED"}]]' 0
	assert_ruleset_review_sequence "PENDING without ordering fields remains non-substantive" \
		'[[{"id":17,"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-08-23T10:00:00Z"},{"state":"PENDING"}]]' 0
	assert_ruleset_review_sequence "missing PR author fails closed" \
		'[[{"id":18,"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-08-23T10:00:00Z"}]]' 1 ""

	teardown_test_env
	return 0
}

gh_pr_view() {
	local pr_number="$1"
	shift
	if [[ -n "${PR_VIEW_STATE:-}" ]]; then
		printf '{"number":%s,"state":"%s","mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"webhook test","headRefOid":"head-current"}' \
			"$pr_number" "$PR_VIEW_STATE"
		return 0
	fi
	printf '{"labels":[]}'
	return 0
}

pulse_pr_list_cache_invalidate_repo() {
	local repo_slug="$1"
	printf '%s\n' "$repo_slug" >>"${CACHE_INVALIDATION_LOG:?}"
	return 0
}

_pulse_merge_maybe_dispatch_review_thread_remediation() {
	local pr_number="$1"
	local repo_slug="$2"
	local merge_output="$3"
	printf 'pr=%s repo=%s\n%s\n' "$pr_number" "$repo_slug" "$merge_output" >>"${REMEDIATION_LOG:?}"
	return 0
}

_pulse_merge_maybe_dispatch_preflight_remediation() {
	local pr_number="$1"
	local repo_slug="$2"
	PREFLIGHT_REMEDIATION_CALLS=$((PREFLIGHT_REMEDIATION_CALLS + 1))
	printf 'preflight pr=%s repo=%s blocker=%s\n' \
		"$pr_number" "$repo_slug" "${_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND:-}" >>"${REMEDIATION_LOG:?}"
	_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND=""
	return 0
}

prepare_stale_cache_fixture() {
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.cache/gh"
	cat >"${HOME}/.cache/gh/graphql-401.cache" <<'CACHE'
HTTP/2.0 401 Unauthorized
X-Gh-Cache-Ttl: 24h0m0s
{"message":"Requires authentication","documentation_url":"https://docs.github.com/graphql"}
CACHE
	cat >"${HOME}/.cache/gh/healthy.cache" <<'CACHE'
HTTP/2.0 200 OK
{"data":{"viewer":{"login":"tester"}}}
CACHE
	return 0
}

test_ruleset_violation_enables_auto_merge_without_admin() {
	setup_test_env
	define_function_under_test || { teardown_test_env; return 0; }

	local pr_obj='{"number":77,"state":"OPEN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"test","headRefOid":"head-current"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "ruleset violation fallback returns merged" 1 "Expected 0, got ${result}; log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'gh pr merge 77 --repo owner/repo --squash --admin' "$GH_LOG"; then
		print_result "ruleset violation fallback tries admin first" 1 "gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	if [[ "$RULESET_GATE_HEAD" != "head-current" ]]; then
		print_result "ruleset approval gate receives current PR head" 1 "expected head-current, got ${RULESET_GATE_HEAD:-empty}"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'gh pr merge 77 --repo owner/repo --auto --squash --match-head-commit head-current$' "$GH_LOG"; then
		print_result "ruleset violation fallback enables native auto-merge" 1 "gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	if grep -qE 'gh pr merge 77 --repo owner/repo --squash$' "$GH_LOG"; then
		print_result "ruleset violation fallback avoids direct policy-prohibited merge" 1 "gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'evaluating protection-respecting fallbacks.*GH#24438' "$LOGFILE"; then
		print_result "ruleset violation fallback writes audit log" 1 "pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	print_result "ruleset violation fallback enables native auto-merge and succeeds" 0
	teardown_test_env
	return 0
}

test_ruleset_violation_skips_native_auto_merge_when_disabled() {
	REPO_ALLOWS_AUTO_MERGE_RC=1
	setup_test_env
	define_function_under_test || {
		teardown_test_env
		unset REPO_ALLOWS_AUTO_MERGE_RC
		return 0
	}

	local pr_obj='{"number":77,"state":"OPEN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"test","headRefOid":"head-current"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -eq 3 ]] &&
		! grep -qE 'gh pr merge 77 .*--auto' "$GH_LOG" &&
		grep -qE 'gh pr merge 77 --repo owner/repo --squash --match-head-commit head-current$' "$GH_LOG" &&
		grep -qF 'native auto-merge skipped: repository does not allow auto-merge' "$LOGFILE"; then
		print_result "ruleset fallback skips native auto-merge when repository disables it" 0
	else
		print_result "ruleset fallback skips native auto-merge when repository disables it" 1 \
			"result=${result}; gh log: $(tr '\n' ';' <"$GH_LOG"); pulse log: $(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	unset REPO_ALLOWS_AUTO_MERGE_RC
	return 0
}

test_green_behind_update_defers_before_merge_attempts() {
	unset GH_STUB_MODE
	GREEN_BEHIND_UPDATE_RC=0
	setup_test_env
	define_function_under_test || { teardown_test_env; unset GREEN_BEHIND_UPDATE_RC; return 0; }

	local pr_obj='{"number":77,"state":"OPEN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"test"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 1 ]]; then
		print_result "green BEHIND update defers before merge attempts" 1 \
			"Expected 1, got ${result}; log: $(cat "$LOGFILE")"
		teardown_test_env
		unset GREEN_BEHIND_UPDATE_RC
		return 0
	fi
	if grep -qE 'gh pr merge 77' "$GH_LOG"; then
		print_result "green BEHIND update avoids admin/native/direct merge writes" 1 \
			"gh log: $(cat "$GH_LOG")"
		teardown_test_env
		unset GREEN_BEHIND_UPDATE_RC
		return 0
	fi
	print_result "green BEHIND update defers before merge attempts" 0
	teardown_test_env
	unset GREEN_BEHIND_UPDATE_RC
	return 0
}

test_draft_pr_without_origin_labels_skips_merge_write() {
	unset GH_STUB_MODE
	setup_test_env
	define_function_under_test || { teardown_test_env; return 0; }

	local pr_obj='{"number":88,"state":"OPEN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"draft test","labels":[],"isDraft":true}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 1 ]]; then
		print_result "draft PR without origin labels skips merge" 1 "Expected 1, got ${result}; log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	if grep -qE 'gh pr merge 88' "$GH_LOG"; then
		print_result "draft PR without origin labels makes no merge write" 1 "gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'draft PR not eligible for auto-merge.*GH#23525' "$LOGFILE"; then
		print_result "draft PR without origin labels writes skip log" 1 "pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	print_result "draft PR without origin labels is blocked before gh pr merge" 0
	teardown_test_env
	return 0
}

test_lowercase_open_pr_enters_merge_pipeline() {
	setup_test_env
	define_function_under_test || { teardown_test_env; return 0; }

	local pr_obj='{"number":78,"state":"open","mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"lowercase open test","labels":[],"isDraft":false,"headRefOid":"head-current"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "lowercase open PR enters batch merge pipeline" 1 "Expected 0, got ${result}; log: $(<"$LOGFILE")"
	elif ! grep -qE 'gh pr merge 78 ' "$GH_LOG"; then
		print_result "lowercase open PR enters batch merge pipeline" 1 "gh log: $(<"$GH_LOG")"
	elif grep -qF 'state=open is not OPEN' "$LOGFILE"; then
		print_result "lowercase open PR enters batch merge pipeline" 1 "pulse log: $(<"$LOGFILE")"
	else
		print_result "lowercase open PR enters batch merge pipeline" 0
	fi
	teardown_test_env
	return 0
}

test_lowercase_open_pr_enters_webhook_merge_pipeline() {
	PR_VIEW_STATE="open"
	setup_test_env
	define_function_under_test || { teardown_test_env; unset PR_VIEW_STATE; return 0; }

	local result=0
	process_pr "owner/repo" "79" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "lowercase open PR enters webhook merge pipeline" 1 "Expected 0, got ${result}; log: $(<"$LOGFILE")"
	elif ! grep -qF 'webhook-triggered merge attempt for owner/repo#79' "$LOGFILE"; then
		print_result "lowercase open PR enters webhook merge pipeline" 1 "pulse log: $(<"$LOGFILE")"
	elif ! grep -qE 'gh pr merge 79 ' "$GH_LOG"; then
		print_result "lowercase open PR enters webhook merge pipeline" 1 "gh log: $(<"$GH_LOG")"
	else
		print_result "lowercase open PR enters webhook merge pipeline" 0
	fi
	teardown_test_env
	unset PR_VIEW_STATE
	return 0
}

test_lowercase_closed_pr_skips_before_merge_pipeline() {
	unset GH_STUB_MODE
	setup_test_env
	define_function_under_test || { teardown_test_env; return 0; }

	local pr_obj='{"number":89,"state":"closed","mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"closed test","labels":[],"isDraft":false}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 1 ]]; then
		print_result "non-OPEN PR skips merge pipeline" 1 "Expected 1, got ${result}; log: $(<"$LOGFILE")"
	elif [[ -s "$GH_LOG" ]]; then
		print_result "non-OPEN PR makes no GitHub calls" 1 "gh log: $(<"$GH_LOG")"
	elif ! grep -qF 'state=CLOSED is not OPEN (GH#28279)' "$LOGFILE"; then
		print_result "non-OPEN PR writes skip audit log" 1 "pulse log: $(<"$LOGFILE")"
	else
		print_result "non-OPEN PR is blocked before merge pipeline" 0
	fi
	teardown_test_env
	return 0
}

test_unknown_and_missing_pr_states_skip_before_merge_pipeline() {
	unset GH_STUB_MODE
	setup_test_env
	define_function_under_test || { teardown_test_env; return 0; }

	local unknown_obj='{"number":90,"state":"unexpected","mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"unknown state test","labels":[],"isDraft":false}'
	local missing_obj='{"number":91,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"missing state test","labels":[],"isDraft":false}'
	local unknown_result=0
	local missing_result=0
	_process_single_ready_pr "owner/repo" "$unknown_obj" || unknown_result=$?
	_process_single_ready_pr "owner/repo" "$missing_obj" || missing_result=$?

	if [[ "$unknown_result" -ne 1 || "$missing_result" -ne 1 ]]; then
		print_result "unknown and missing PR states remain blocked" 1 \
			"unknown=${unknown_result} missing=${missing_result}; log: $(<"$LOGFILE")"
	elif [[ -s "$GH_LOG" ]]; then
		print_result "unknown and missing PR states remain blocked" 1 "gh log: $(<"$GH_LOG")"
	elif ! grep -qF 'state=unexpected is not OPEN' "$LOGFILE" || ! grep -qF 'state=missing is not OPEN' "$LOGFILE"; then
		print_result "unknown and missing PR states remain blocked" 1 "pulse log: $(<"$LOGFILE")"
	else
		print_result "unknown and missing PR states remain blocked" 0
	fi
	teardown_test_env
	return 0
}

test_expected_required_check_updates_branch_and_defers() {
	GH_STUB_MODE="expected-check"
	setup_test_env
	define_function_under_test || { teardown_test_env; unset GH_STUB_MODE; return 0; }

	local pr_obj='{"number":77,"state":"OPEN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"test"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 4 ]]; then
		print_result "expected required-check blocker defers after update-branch" 1 \
			"Expected 4, got ${result}; log: $(cat "$LOGFILE")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi
	if ! grep -qE 'gh api --method PUT repos/owner/repo/pulls/77/update-branch' "$GH_LOG"; then
		print_result "expected required-check blocker invokes update-branch" 1 \
			"gh log: $(cat "$GH_LOG")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi
	if ! grep -qE 'expected/pending required status check.*GH#26899' "$LOGFILE"; then
		print_result "expected required-check blocker writes defer audit log" 1 \
			"pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi
	print_result "expected required-check blocker updates branch and defers" 0
	teardown_test_env
	unset GH_STUB_MODE
	return 0
}

test_pending_required_check_updates_branch_and_defers() {
	GH_STUB_MODE="pending-check"
	setup_test_env
	define_function_under_test || { teardown_test_env; unset GH_STUB_MODE; return 0; }

	local pr_obj='{"number":77,"state":"OPEN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"test"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 4 ]]; then
		print_result "pending required-check blocker defers after update-branch" 1 \
			"Expected 4, got ${result}; log: $(cat "$LOGFILE")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi
	if ! grep -qE 'gh api --method PUT repos/owner/repo/pulls/77/update-branch' "$GH_LOG"; then
		print_result "pending required-check blocker invokes update-branch" 1 \
			"gh log: $(cat "$GH_LOG")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi
	print_result "pending required-check blocker updates branch and defers" 0
	teardown_test_env
	unset GH_STUB_MODE
	return 0
}

test_stale_cache_401_retries_admin_merge_once() {
	GH_STUB_MODE="stale-cache-401"
	setup_test_env
	prepare_stale_cache_fixture
	define_function_under_test || { teardown_test_env; unset GH_STUB_MODE; return 0; }

	local pr_obj='{"number":77,"state":"OPEN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"test"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "stale cache 401 retries admin merge" 1 "Expected 0, got ${result}; log: $(cat "$LOGFILE")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	local merge_count="0"
	[[ -f "${TEST_ROOT}/merge-count.txt" ]] && merge_count=$(cat "${TEST_ROOT}/merge-count.txt")
	if [[ "$merge_count" != "2" ]]; then
		print_result "stale cache 401 retries admin merge exactly once" 1 "merge_count=${merge_count}; gh log: $(cat "$GH_LOG")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	local merge_events=""
	merge_events=$(tr '\n' ' ' <"$MERGE_EVENT_LOG")
	if [[ "$merge_events" != "progress:1:0 sleep:1 post-merge " ]]; then
		print_result "successful merge records recovery before interruptible post-merge work" 1 \
			"event order: ${merge_events:-none}"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi
	print_result "successful merge records recovery before interruptible post-merge work" 0
	if [[ "$(<"$CACHE_INVALIDATION_LOG")" != "owner/repo" ]]; then
		print_result "successful merge invalidates repository PR-list caches" 1 \
			"invalidations=$(tr '\n' ';' <"$CACHE_INVALIDATION_LOG")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi
	print_result "successful merge invalidates repository PR-list caches" 0

	if [[ -f "${HOME}/.cache/gh/graphql-401.cache" ]] || \
		! find "${HOME}/.cache/gh" -path '*/aidevops-quarantine-*/*graphql-401.cache*' -type f | grep -q .; then
		print_result "stale cache 401 quarantines only matching cache file" 1 "cache remediation did not quarantine stale 401 file"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	if [[ ! -f "${HOME}/.cache/gh/healthy.cache" ]]; then
		print_result "stale cache 401 preserves healthy cache file" 1 "healthy cache file was moved"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	if ! grep -qE 'quarantined 1 stale gh HTTP 401 cache file' "$LOGFILE"; then
		print_result "stale cache 401 writes remediation audit log" 1 "pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	print_result "stale cache 401 retries admin merge once and succeeds" 0
	teardown_test_env
	unset GH_STUB_MODE
	return 0
}

test_terminal_merge_failure_refreshes_state_and_invalidates_cache() {
	GH_STUB_MODE="terminal-closed"
	setup_test_env
	define_function_under_test || { teardown_test_env; unset GH_STUB_MODE; return 0; }

	local pr_obj='{"number":77,"state":"OPEN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"test","headRefOid":"head-current"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 1 ]]; then
		print_result "terminal merge failure becomes a stale-cache skip" 1 \
			"Expected 1, got ${result}; log: $(tr '\n' ';' <"$LOGFILE")"
	elif ! grep -qE '^gh pr view 77 --repo owner/repo --json state --jq ' "$GH_LOG"; then
		print_result "terminal merge failure performs uncached state refresh" 1 \
			"gh log: $(tr '\n' ';' <"$GH_LOG")"
	elif [[ "$(<"$CACHE_INVALIDATION_LOG")" != "owner/repo" ]]; then
		print_result "terminal merge failure invalidates repository PR-list caches" 1 \
			"invalidations=$(tr '\n' ';' <"$CACHE_INVALIDATION_LOG")"
	elif [[ -s "$REMEDIATION_LOG" ]]; then
		print_result "terminal merge failure suppresses stale remediation" 1 \
			"remediation=$(tr '\n' ';' <"$REMEDIATION_LOG")"
	elif ! grep -qF 'fresh state=CLOSED is terminal (GH#28280)' "$LOGFILE"; then
		print_result "terminal merge failure writes stale-cache audit log" 1 \
			"pulse log: $(tr '\n' ';' <"$LOGFILE")"
	else
		print_result "terminal merge failure refreshes state, invalidates cache, and skips remediation" 0
	fi
	teardown_test_env
	unset GH_STUB_MODE
	return 0
}

test_ruleset_fallback_failure_preserves_admin_conversation_context() {
	GH_STUB_MODE="conversation-chain"
	setup_test_env
	define_function_under_test || { teardown_test_env; unset GH_STUB_MODE; return 0; }

	local pr_obj='{"number":77,"state":"OPEN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"test"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 3 ]]; then
		print_result "fallback-chain failure preserves admin conversation context" 1 \
			"Expected 3, got ${result}; log: $(tr '\n' ';' <"$LOGFILE")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	if ! grep -qF 'A conversation must be resolved' "$REMEDIATION_LOG"; then
		print_result "fallback-chain failure preserves admin conversation context" 1 \
			"remediation did not receive admin blocker: $(tr '\n' ';' <"$REMEDIATION_LOG")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	if ! grep -qF '[native auto-merge fallback]' "$REMEDIATION_LOG" \
		|| ! grep -qF '[direct merge fallback]' "$REMEDIATION_LOG"; then
		print_result "fallback-chain failure preserves admin conversation context" 1 \
			"remediation did not receive accumulated fallback attempts: $(tr '\n' ';' <"$REMEDIATION_LOG")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	if ! grep -qF 'A conversation must be resolved' "$LOGFILE"; then
		print_result "fallback-chain failure preserves admin conversation context" 1 \
			"final failure log did not retain admin blocker: $(tr '\n' ';' <"$LOGFILE")"
		teardown_test_env
		unset GH_STUB_MODE
		return 0
	fi

	print_result "fallback-chain failure preserves admin conversation context" 0
	teardown_test_env
	unset GH_STUB_MODE
	return 0
}

test_final_preflight_thread_blocker_dispatches_before_merge() {
	setup_test_env
	define_function_under_test || {
		teardown_test_env
		return 0
	}
	FINAL_GATE_RC=1
	FINAL_GATE_BLOCKER_KIND="required-review-threads"

	local pr_obj='{"number":77,"state":"OPEN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"test","headRefOid":"head-current"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 1 ]]; then
		print_result "final preflight thread blocker defers merge" 1 \
			"Expected 1, got ${result}; log: $(tr '\n' ';' <"$LOGFILE")"
	elif [[ "$PREFLIGHT_REMEDIATION_CALLS" -ne 1 ]] ||
		! grep -qF 'preflight pr=77 repo=owner/repo blocker=required-review-threads' "$REMEDIATION_LOG"; then
		print_result "final preflight thread blocker dispatches remediation" 1 \
			"calls=${PREFLIGHT_REMEDIATION_CALLS}; remediation=$(tr '\n' ';' <"$REMEDIATION_LOG")"
	elif grep -qE '^gh pr merge ' "$GH_LOG"; then
		print_result "final preflight thread blocker prevents merge write" 1 \
			"gh log: $(tr '\n' ';' <"$GH_LOG")"
	else
		print_result "final preflight thread blocker dispatches before merge write" 0
	fi
	teardown_test_env
	return 0
}

main() {
	test_ruleset_violation_enables_auto_merge_without_admin
	test_ruleset_violation_skips_native_auto_merge_when_disabled
	test_green_behind_update_defers_before_merge_attempts
	test_draft_pr_without_origin_labels_skips_merge_write
	test_lowercase_open_pr_enters_merge_pipeline
	test_lowercase_open_pr_enters_webhook_merge_pipeline
	test_lowercase_closed_pr_skips_before_merge_pipeline
	test_unknown_and_missing_pr_states_skip_before_merge_pipeline
	test_expected_required_check_updates_branch_and_defers
	test_pending_required_check_updates_branch_and_defers
	test_final_preflight_thread_blocker_dispatches_before_merge
	test_stale_cache_401_retries_admin_merge_once
	test_terminal_merge_failure_refreshes_state_and_invalidates_cache
	test_ruleset_fallback_failure_preserves_admin_conversation_context
	test_ruleset_required_review_decision_sequences

	printf '\n=================================\n'
	printf 'Tests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	printf '=================================\n'

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
