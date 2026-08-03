#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NMR_SCRIPT="${SCRIPT_DIR}/../pulse-nmr-approval.sh"

TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '     %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT="$(mktemp -d -t nmr-authority.XXXXXX)"
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export REPOS_JSON="${TEST_ROOT}/repos.json"
	export POSTED_COMMENT="${TEST_ROOT}/posted-comment.txt"
	export STATUS_CALLS_FILE="${TEST_ROOT}/status-calls.txt"
	export ISSUE_EDIT_CALLS_FILE="${TEST_ROOT}/issue-edit-calls.txt"
	export AGENTS_DIR="${TEST_ROOT}"
	export ISSUE_ASSOC="OWNER"
	export ISSUE_API_AUTHOR="maintainer"
	export ISSUE_AUTHOR_TYPE="User"
	export ISSUE_LABELS_JSON='[]'
	export ISSUE_LIST_AUTHOR="maintainer"
	export ACTOR_PERMISSION="write"
	export AUTHOR_PERMISSION="write"
	export NMR_TIMELINE_JSON='[]'
	export ISSUE_COMMENTS_JSON='[]'
	export COMMENTS_API_FAIL=0
	export TIMELINE_API_FAIL=0
	export ISSUE_API_FAIL=0
	export STATUS_SET_FAIL=0
	: >"$LOGFILE"
	: >"$POSTED_COMMENT"
	: >"$STATUS_CALLS_FILE"
	: >"$ISSUE_EDIT_CALLS_FILE"
	printf '{"initialized_repos":[{"slug":"owner/repo","maintainer":"maintainer","pulse":true}]}' >"$REPOS_JSON"
	cat >"${TEST_ROOT}/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "api" ]]; then
	path="${2:-}"
	if [[ "$path" == "-i" ]]; then
		path="${3:-}"
		if [[ "$path" == */collaborators/runner/permission ]]; then
			printf 'HTTP/2.0 200 OK\n\n{"permission":"%s"}\n' "${ACTOR_PERMISSION:-none}"
			exit 0
		fi
		if [[ "$path" == */collaborators/trusted-author/permission ]]; then
			printf 'HTTP/2.0 200 OK\n\n{"permission":"%s"}\n' "${AUTHOR_PERMISSION:-none}"
			exit 0
		fi
	fi
	jq_filter=""
	shift 2 2>/dev/null || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--jq) jq_filter="$2"; shift 2 ;;
			--paginate|--slurp) shift ;;
			*) shift ;;
		esac
	done
	if [[ "$path" == "user" ]]; then
		printf '{"login":"runner"}\n' | jq -r "${jq_filter:-.}"
		exit 0
	fi
	if [[ "$path" == */collaborators/runner/permission ]]; then
		printf '{"permission":"%s"}\n' "${ACTOR_PERMISSION:-none}" | jq -r "${jq_filter:-.}"
		exit 0
	fi
	if [[ "$path" == */collaborators/trusted-author/permission ]]; then
		printf '{"permission":"%s"}\n' "${AUTHOR_PERMISSION:-none}" | jq -r "${jq_filter:-.}"
		exit 0
	fi
	if [[ "$path" == */issues/24479 ]]; then
		[[ "${ISSUE_API_FAIL:-0}" -eq 0 ]] || exit 1
		printf '{"user":{"login":"%s","type":"%s"},"author_association":"%s","labels":%s}\n' \
			"${ISSUE_API_AUTHOR:-maintainer}" "${ISSUE_AUTHOR_TYPE:-User}" \
			"${ISSUE_ASSOC:-NONE}" "${ISSUE_LABELS_JSON:-[]}"
		exit 0
	fi
	if [[ "$path" == */timeline ]]; then
		[[ "${TIMELINE_API_FAIL:-0}" -eq 0 ]] || exit 1
		printf '%s\n' "${NMR_TIMELINE_JSON:-[]}"
		exit 0
	fi
	if [[ "$path" == */comments ]]; then
		[[ "${COMMENTS_API_FAIL:-0}" -eq 0 ]] || exit 1
		printf '%s\n' "${ISSUE_COMMENTS_JSON:-[]}"
		exit 0
	fi
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "lock" ]]; then
	exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "edit" ]]; then
	printf '%s\n' "$*" >>"${ISSUE_EDIT_CALLS_FILE}"
	exit 0
fi
printf 'unsupported gh invocation: %s\n' "$*" >&2
exit 1
GH_STUB
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	unset AGENTS_DIR
	return 0
}

gh_issue_list() {
	printf '[{"number":24479,"author":{"login":"%s"}}]\n' "${ISSUE_LIST_AUTHOR:-maintainer}"
	return 0
}
export -f gh_issue_list

gh_issue_comment() {
	local body=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--body)
			body="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done
	printf '%s\n' "$body" >"$POSTED_COMMENT"
	return 0
}
export -f gh_issue_comment

set_issue_status() {
	local issue_num="$1"
	local slug="$2"
	local target_name="$3"
	[[ "${STATUS_SET_FAIL:-0}" -eq 0 ]] || return 1
	printf '%s %s %s\n' "$issue_num" "$slug" "$target_name" >"$STATUS_CALLS_FILE"
	ISSUE_LABELS_JSON=$(printf '%s' "$ISSUE_LABELS_JSON" | jq -c --arg target "status:${target_name}" \
		'[.[] | select(((.name // "") | startswith("status:")) | not)] + [{"name": $target}]') || return 1
	export ISSUE_LABELS_JSON
	return 0
}
export -f set_issue_status

run_auto_approve() {
	# shellcheck disable=SC1090
	source "$NMR_SCRIPT"
	# Keep reason-classification tests from writing the user's persistent cache.
	_nmr_record_revalidation_state() {
		return 0
	}
	auto_approve_maintainer_issues
	return 0
}

test_blocks_none_author_association() {
	setup_test_env
	export ISSUE_ASSOC="NONE"
	run_auto_approve
	if [[ ! -s "$POSTED_COMMENT" ]]; then
		print_result "auto-approval blocks maintainer-login issue with NONE association" 0
	else
		print_result "auto-approval blocks maintainer-login issue with NONE association" 1 "unexpected approval comment"
	fi
	teardown_test_env
	return 0
}

test_blocks_external_author_even_with_nmr_automation() {
	setup_test_env
	export ISSUE_LIST_AUTHOR="external-contributor"
	export ISSUE_API_AUTHOR="external-contributor"
	export ISSUE_ASSOC="NONE"
	run_auto_approve
	if [[ ! -s "$POSTED_COMMENT" ]]; then
		print_result "auto-approval blocks non-maintainer issue author with NMR" 0
	else
		print_result "auto-approval blocks non-maintainer issue author with NMR" 1 "unexpected approval comment"
	fi
	teardown_test_env
	return 0
}

test_blocks_actor_without_write_permission() {
	setup_test_env
	export ISSUE_ASSOC="OWNER"
	export ACTOR_PERMISSION="read"
	run_auto_approve
	if [[ ! -s "$POSTED_COMMENT" ]]; then
		print_result "auto-approval blocks runner without upstream write authority" 0
	else
		print_result "auto-approval blocks runner without upstream write authority" 1 "unexpected approval comment"
	fi
	teardown_test_env
	return 0
}

test_allows_owner_author_with_write_permission() {
	setup_test_env
	export ISSUE_ASSOC="OWNER"
	export ACTOR_PERMISSION="write"
	export NMR_TIMELINE_JSON='[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"maintainer"},"created_at":"2026-07-30T20:00:00Z"}]'
	run_auto_approve
	if ! grep -q 'aidevops-signed-approval' "$POSTED_COMMENT" 2>/dev/null; then
		print_result "trusted OWNER normalization does not post a synthetic approval" 0
	else
		print_result "trusted OWNER normalization does not post a synthetic approval" 1 "unexpected approval marker"
	fi
	if grep -q -- '^24479 owner/repo available$' "$STATUS_CALLS_FILE" 2>/dev/null \
		&& grep -q -- '--remove-label needs-maintainer-review --add-label auto-dispatch' "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null; then
		print_result "auto-approval establishes available status before clearing NMR" 0
	else
		print_result "auto-approval establishes available status before clearing NMR" 1 \
			"status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_allows_write_authorized_collaborator() {
	setup_test_env
	export ISSUE_LIST_AUTHOR="trusted-author"
	export ISSUE_API_AUTHOR="trusted-author"
	export ISSUE_ASSOC="COLLABORATOR"
	export AUTHOR_PERMISSION="write"
	export NMR_TIMELINE_JSON='[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"trusted-author"},"created_at":"2026-07-30T20:00:00Z"}]'
	run_auto_approve
	if ! grep -q 'aidevops-signed-approval' "$POSTED_COMMENT" 2>/dev/null \
		&& grep -q -- '^24479 owner/repo available$' "$STATUS_CALLS_FILE" 2>/dev/null \
		&& grep -q -- '--remove-label needs-maintainer-review --add-label auto-dispatch' "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null; then
		print_result "trusted collaborator normalization clears NMR without synthetic approval" 0
	else
		print_result "trusted collaborator normalization clears NMR without synthetic approval" 1 "unexpected approval marker or missing status transition"
	fi
	teardown_test_env
	return 0
}

test_blocks_read_only_collaborator() {
	setup_test_env
	export ISSUE_LIST_AUTHOR="trusted-author"
	export ISSUE_API_AUTHOR="trusted-author"
	export ISSUE_ASSOC="COLLABORATOR"
	export AUTHOR_PERMISSION="read"
	run_auto_approve
	if [[ ! -s "$POSTED_COMMENT" ]]; then
		print_result "auto-approval blocks read-only collaborator issues" 0
	else
		print_result "auto-approval blocks read-only collaborator issues" 1 "unexpected approval comment"
	fi
	teardown_test_env
	return 0
}

test_external_origin_bot_requires_approval() {
	setup_test_env
	export ISSUE_LIST_AUTHOR="github-actions[bot]"
	export ISSUE_API_AUTHOR="github-actions[bot]"
	export ISSUE_AUTHOR_TYPE="Bot"
	export ISSUE_ASSOC="NONE"
	export ISSUE_LABELS_JSON='[{"name":"external-contributor"},{"name":"needs-maintainer-review"}]'
	run_auto_approve
	if [[ ! -s "$POSTED_COMMENT" && ! -s "$STATUS_CALLS_FILE" ]]; then
		print_result "trusted bot preserves explicit external-origin approval gate" 0
	else
		print_result "trusted bot preserves explicit external-origin approval gate" 1 "unexpected approval or status transition"
	fi
	# shellcheck disable=SC1090
	source "$NMR_SCRIPT"
	if issue_has_required_approval 24479 owner/repo true; then
		print_result "external-origin bot still requires cryptographic approval" 1 "authority gate was bypassed"
	else
		print_result "external-origin bot still requires cryptographic approval" 0
	fi
	teardown_test_env
	return 0
}

test_clears_unreasoned_peer_nmr() {
	setup_test_env
	export ISSUE_LIST_AUTHOR="trusted-author"
	export ISSUE_API_AUTHOR="trusted-author"
	export ISSUE_ASSOC="COLLABORATOR"
	export AUTHOR_PERMISSION="write"
	export NMR_TIMELINE_JSON='[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"trusted-author"},"created_at":"2026-07-30T20:00:00Z"}]'
	run_auto_approve
	if [[ ! -s "$POSTED_COMMENT" ]] \
		&& grep -q -- '^24479 owner/repo available$' "$STATUS_CALLS_FILE" 2>/dev/null \
		&& grep -q -- '--remove-label needs-maintainer-review --add-label auto-dispatch' "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null \
		&& ! grep -q -- 'hold-for-review' "$STATUS_CALLS_FILE" "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null; then
		print_result "unreasoned trusted-author NMR clears without manufacturing a hold" 0
	else
		print_result "unreasoned trusted-author NMR clears without manufacturing a hold" 1 \
			"comment=$(<"$POSTED_COMMENT") status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_structured_reason_becomes_explicit_hold() {
	setup_test_env
	export ISSUE_LIST_AUTHOR="trusted-author"
	export ISSUE_API_AUTHOR="trusted-author"
	export ISSUE_ASSOC="COLLABORATOR"
	export AUTHOR_PERMISSION="write"
	export ISSUE_LABELS_JSON='[{"name":"needs-maintainer-review"},{"name":"status:in-review"}]'
	export NMR_TIMELINE_JSON='[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"trusted-author"},"created_at":"2026-07-30T20:00:00Z"}]'
	export ISSUE_COMMENTS_JSON='[{"created_at":"2026-07-30T20:00:01Z","body":"<!-- nmr-reason code=security class=genuine-authority -->"}]'
	run_auto_approve
	if grep -q -- '--remove-label needs-maintainer-review --add-label hold-for-review' "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null \
		&& [[ ! -s "$STATUS_CALLS_FILE" ]] \
		&& grep -q -- 'nmr-decision-packet reason=security' "$POSTED_COMMENT" 2>/dev/null; then
		print_result "structured genuine-authority reason becomes explicit hold and preserves status" 0
	else
		print_result "structured genuine-authority reason becomes explicit hold and preserves status" 1 \
			"comment=$(<"$POSTED_COMMENT") status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_trusted_clear_preserves_active_status() {
	setup_test_env
	export ISSUE_LABELS_JSON='[{"name":"needs-maintainer-review"},{"name":"status:in-review"},{"name":"auto-dispatch"}]'
	export NMR_TIMELINE_JSON='[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"maintainer"},"created_at":"2026-07-30T20:00:00Z"}]'
	run_auto_approve
	if [[ ! -s "$STATUS_CALLS_FILE" ]] \
		&& grep -q -- '--remove-label needs-maintainer-review' "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null \
		&& ! grep -q -- 'status:available\|hold-for-review' "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null; then
		print_result "trusted NMR cleanup preserves active lifecycle status" 0
	else
		print_result "trusted NMR cleanup preserves active lifecycle status" 1 \
			"status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_trusted_clear_preserves_existing_explicit_hold() {
	setup_test_env
	export ISSUE_LABELS_JSON='[{"name":"needs-maintainer-review"},{"name":"hold-for-review"},{"name":"status:available"}]'
	export NMR_TIMELINE_JSON='[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"maintainer"},"created_at":"2026-07-30T20:00:00Z"}]'
	run_auto_approve
	if [[ ! -s "$STATUS_CALLS_FILE" ]] \
		&& grep -q -- '--remove-label needs-maintainer-review' "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null \
		&& ! grep -q -- '--add-label auto-dispatch' "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null; then
		print_result "trusted NMR cleanup preserves an independently explicit hold" 0
	else
		print_result "trusted NMR cleanup preserves an independently explicit hold" 1 \
			"status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_legacy_breaker_becomes_structural_block() {
	setup_test_env
	export ISSUE_LABELS_JSON='[{"name":"needs-maintainer-review"},{"name":"auto-dispatch"}]'
	export NMR_TIMELINE_JSON='[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"maintainer"},"created_at":"2026-07-30T20:00:00Z"}]'
	export ISSUE_COMMENTS_JSON='[{"created_at":"2026-07-30T20:00:02Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->"}]'
	run_auto_approve
	if grep -q -- '^24479 owner/repo blocked$' "$STATUS_CALLS_FILE" 2>/dev/null \
		&& grep -q -- '--remove-label needs-maintainer-review --add-label auto-dispatch' "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null \
		&& ! grep -q -- 'hold-for-review' "$STATUS_CALLS_FILE" "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null; then
		print_result "legacy machine breaker becomes status:blocked instead of a human hold" 0
	else
		print_result "legacy machine breaker becomes status:blocked instead of a human hold" 1 \
			"status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_cost_breaker_becomes_structural_block() {
	setup_test_env
	export ISSUE_LABELS_JSON='[{"name":"needs-maintainer-review"},{"name":"auto-dispatch"}]'
	export NMR_TIMELINE_JSON='[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"maintainer"},"created_at":"2026-07-30T20:00:00Z"}]'
	export ISSUE_COMMENTS_JSON='[{"created_at":"2026-07-30T20:00:02Z","body":"<!-- cost-circuit-breaker:fired tier=thinking -->"}]'
	run_auto_approve
	if grep -q -- '^24479 owner/repo blocked$' "$STATUS_CALLS_FILE" 2>/dev/null \
		&& grep -q -- '--remove-label needs-maintainer-review --add-label auto-dispatch' "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null \
		&& ! grep -q -- 'hold-for-review' "$STATUS_CALLS_FILE" "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null; then
		print_result "cost circuit breaker becomes status:blocked instead of a human hold" 0
	else
		print_result "cost circuit breaker becomes status:blocked instead of a human hold" 1 \
			"status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_security_label_wins_over_machine_breaker() {
	setup_test_env
	export ISSUE_LABELS_JSON='[{"name":"needs-maintainer-review"},{"name":"security"},{"name":"status:available"},{"name":"auto-dispatch"}]'
	export NMR_TIMELINE_JSON='[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"maintainer"},"created_at":"2026-07-30T20:00:00Z"}]'
	export ISSUE_COMMENTS_JSON='[{"created_at":"2026-07-30T20:00:02Z","body":"<!-- cost-circuit-breaker:fired tier=thinking -->"}]'
	run_auto_approve
	if [[ ! -s "$STATUS_CALLS_FILE" ]] \
		&& grep -q -- '--remove-label needs-maintainer-review --add-label hold-for-review' "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null \
		&& grep -q -- 'nmr-decision-packet reason=security' "$POSTED_COMMENT" 2>/dev/null; then
		print_result "security label takes precedence over machine-breaker recovery" 0
	else
		print_result "security label takes precedence over machine-breaker recovery" 1 \
			"comment=$(<"$POSTED_COMMENT") status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_breaker_preserves_hold_while_setting_blocked() {
	setup_test_env
	export ISSUE_LABELS_JSON='[{"name":"needs-maintainer-review"},{"name":"hold-for-review"},{"name":"status:available"},{"name":"auto-dispatch"}]'
	export NMR_TIMELINE_JSON='[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"maintainer"},"created_at":"2026-07-30T20:00:00Z"}]'
	export ISSUE_COMMENTS_JSON='[{"created_at":"2026-07-30T20:00:02Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->"}]'
	run_auto_approve
	if grep -q -- '^24479 owner/repo blocked$' "$STATUS_CALLS_FILE" 2>/dev/null \
		&& grep -q -- '--remove-label needs-maintainer-review' "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null \
		&& ! grep -q -- '--add-label auto-dispatch\|--add-label hold-for-review' "$STATUS_CALLS_FILE" "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null; then
		print_result "machine blocker preserves explicit hold while converging status:blocked" 0
	else
		print_result "machine blocker preserves explicit hold while converging status:blocked" 1 \
			"status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_breaker_preserves_no_auto_while_setting_blocked() {
	setup_test_env
	export ISSUE_LABELS_JSON='[{"name":"needs-maintainer-review"},{"name":"no-auto-dispatch"},{"name":"status:available"},{"name":"auto-dispatch"}]'
	export NMR_TIMELINE_JSON='[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"maintainer"},"created_at":"2026-07-30T20:00:00Z"}]'
	export ISSUE_COMMENTS_JSON='[{"created_at":"2026-07-30T20:00:02Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->"}]'
	run_auto_approve
	if grep -q -- '^24479 owner/repo blocked$' "$STATUS_CALLS_FILE" 2>/dev/null \
		&& grep -q -- '--remove-label needs-maintainer-review' "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null \
		&& ! grep -q -- '--add-label auto-dispatch\|hold-for-review' "$STATUS_CALLS_FILE" "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null; then
		print_result "machine blocker preserves no-auto-dispatch while converging status:blocked" 0
	else
		print_result "machine blocker preserves no-auto-dispatch while converging status:blocked" 1 \
			"status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_blocked_status_failure_retains_nmr() {
	setup_test_env
	export ISSUE_LABELS_JSON='[{"name":"needs-maintainer-review"},{"name":"status:available"},{"name":"auto-dispatch"}]'
	export NMR_TIMELINE_JSON='[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"maintainer"},"created_at":"2026-07-30T20:00:00Z"}]'
	export ISSUE_COMMENTS_JSON='[{"created_at":"2026-07-30T20:00:02Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->"}]'
	export STATUS_SET_FAIL=1
	run_auto_approve
	if [[ ! -s "$STATUS_CALLS_FILE" && ! -s "$ISSUE_EDIT_CALLS_FILE" ]]; then
		print_result "blocked status failure retains NMR and dispatch labels" 0
	else
		print_result "blocked status failure retains NMR and dispatch labels" 1 \
			"status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_available_status_failure_retains_nmr() {
	setup_test_env
	export ISSUE_LABELS_JSON='[{"name":"needs-maintainer-review"}]'
	export NMR_TIMELINE_JSON='[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"maintainer"},"created_at":"2026-07-30T20:00:00Z"}]'
	export STATUS_SET_FAIL=1
	run_auto_approve
	if [[ ! -s "$STATUS_CALLS_FILE" && ! -s "$ISSUE_EDIT_CALLS_FILE" ]]; then
		print_result "available status failure retains NMR and dispatch labels" 0
	else
		print_result "available status failure retains NMR and dispatch labels" 1 \
			"status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_resolved_breaker_preserves_active_status() {
	setup_test_env
	export ISSUE_LABELS_JSON='[{"name":"needs-maintainer-review"},{"name":"status:in-review"},{"name":"auto-dispatch"}]'
	# shellcheck disable=SC1090
	source "$NMR_SCRIPT"
	_NMR_FORCE_AVAILABLE=1
	_nmr_restore_dispatchable_state 24479 owner/repo
	if [[ ! -s "$STATUS_CALLS_FILE" ]] \
		&& grep -q -- '--remove-label needs-maintainer-review --add-label auto-dispatch' "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null; then
		print_result "resolved breaker retry preserves active lifecycle status" 0
	else
		print_result "resolved breaker retry preserves active lifecycle status" 1 \
			"status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_resolved_breaker_recovers_blocked_status() {
	setup_test_env
	export ISSUE_LABELS_JSON='[{"name":"needs-maintainer-review"},{"name":"status:blocked"},{"name":"auto-dispatch"}]'
	# shellcheck disable=SC1090
	source "$NMR_SCRIPT"
	_NMR_FORCE_AVAILABLE=1
	_nmr_restore_dispatchable_state 24479 owner/repo
	if grep -q -- '^24479 owner/repo available$' "$STATUS_CALLS_FILE" 2>/dev/null \
		&& grep -q -- '--remove-label needs-maintainer-review --add-label auto-dispatch' "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null; then
		print_result "resolved breaker retry restores status:available from blocked" 0
	else
		print_result "resolved breaker retry restores status:available from blocked" 1 \
			"status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_conflicting_statuses_defer_recovery_in_any_order() {
	setup_test_env
	# shellcheck disable=SC1090
	source "$NMR_SCRIPT"
	_NMR_FORCE_AVAILABLE=1
	local first_rc=0
	local second_rc=0
	local first_clean=0
	local second_clean=0
	export ISSUE_LABELS_JSON='[{"name":"needs-maintainer-review"},{"name":"status:blocked"},{"name":"status:in-review"},{"name":"auto-dispatch"}]'
	_nmr_restore_dispatchable_state 24479 owner/repo || first_rc=$?
	[[ "$first_rc" -ne 0 && ! -s "$STATUS_CALLS_FILE" && ! -s "$ISSUE_EDIT_CALLS_FILE" ]] && first_clean=1
	: >"$STATUS_CALLS_FILE"
	: >"$ISSUE_EDIT_CALLS_FILE"
	export ISSUE_LABELS_JSON='[{"name":"needs-maintainer-review"},{"name":"status:in-review"},{"name":"status:blocked"},{"name":"auto-dispatch"}]'
	_nmr_restore_dispatchable_state 24479 owner/repo || second_rc=$?
	[[ "$second_rc" -ne 0 && ! -s "$STATUS_CALLS_FILE" && ! -s "$ISSUE_EDIT_CALLS_FILE" ]] && second_clean=1
	if [[ "$first_clean" -eq 1 && "$second_clean" -eq 1 ]]; then
		print_result "conflicting lifecycle statuses defer NMR recovery independent of label order" 0
	else
		print_result "conflicting lifecycle statuses defer NMR recovery independent of label order" 1 \
			"first_rc=${first_rc} first_clean=${first_clean} second_rc=${second_rc} second_clean=${second_clean}"
	fi
	teardown_test_env
	return 0
}

test_incomplete_labels_defer_trusted_cleanup() {
	setup_test_env
	export ISSUE_LABELS_JSON='null'
	export NMR_TIMELINE_JSON='[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"maintainer"},"created_at":"2026-07-30T20:00:00Z"}]'
	run_auto_approve
	if [[ ! -s "$STATUS_CALLS_FILE" && ! -s "$ISSUE_EDIT_CALLS_FILE" && ! -s "$POSTED_COMMENT" ]]; then
		print_result "incomplete live labels defer trusted cleanup" 0
	else
		print_result "incomplete live labels defer trusted cleanup" 1 \
			"comment=$(<"$POSTED_COMMENT") status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_label_helpers_reject_incomplete_metadata() {
	setup_test_env
	export ISSUE_LABELS_JSON='null'
	# shellcheck disable=SC1090
	source "$NMR_SCRIPT"
	local security_rc=0
	local state_rc=0
	local authority_rc=0
	local empty_name_authority_rc=0
	_nmr_application_is_security_sensitive 24479 owner/repo '{"labels":null}' || security_rc=$?
	_nmr_issue_label_state 24479 owner/repo >/dev/null || state_rc=$?
	_nmr_issue_author_has_repo_write_authority 24479 owner/repo || authority_rc=$?
	export ISSUE_LABELS_JSON='[{"name":""}]'
	export ISSUE_API_AUTHOR='github-actions[bot]'
	export ISSUE_AUTHOR_TYPE='Bot'
	export ISSUE_ASSOC='NONE'
	_nmr_issue_author_has_repo_write_authority 24479 owner/repo || empty_name_authority_rc=$?
	if [[ "$security_rc" -eq 2 && "$state_rc" -ne 0 && "$authority_rc" -eq 2 && "$empty_name_authority_rc" -eq 2 ]]; then
		print_result "authority, security, and lifecycle helpers reject incomplete label metadata" 0
	else
		print_result "authority, security, and lifecycle helpers reject incomplete label metadata" 1 \
			"security_rc=${security_rc} state_rc=${state_rc} authority_rc=${authority_rc} empty_name_authority_rc=${empty_name_authority_rc}"
	fi
	teardown_test_env
	return 0
}

test_crypto_approval_preserves_independent_security_hold() {
	setup_test_env
	export ISSUE_LABELS_JSON='[{"name":"needs-maintainer-review"},{"name":"security"},{"name":"status:in-review"}]'
	# shellcheck disable=SC1090
	source "$NMR_SCRIPT"
	_nmr_apply_auto_approval_transition 24479 owner/repo "$NMR_TRANSITION_CRYPTO_APPROVED" "test approval"
	if [[ "$_NMR_AUTO_TRANSITION_RESULT" == "$NMR_AUTO_RESULT_APPROVED" && ! -s "$STATUS_CALLS_FILE" ]] \
		&& grep -q -- '--remove-label needs-maintainer-review --add-label hold-for-review' "$ISSUE_EDIT_CALLS_FILE" 2>/dev/null \
		&& grep -q -- 'aidevops-signed-approval' "$POSTED_COMMENT" 2>/dev/null; then
		print_result "cryptographic authority approval preserves independent security hold" 0
	else
		print_result "cryptographic authority approval preserves independent security hold" 1 \
			"result=${_NMR_AUTO_TRANSITION_RESULT:-none} comment=$(<"$POSTED_COMMENT") status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_comments_failure_defers_trusted_cleanup() {
	setup_test_env
	export ISSUE_LABELS_JSON='[{"name":"needs-maintainer-review"}]'
	export NMR_TIMELINE_JSON='[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"maintainer"},"created_at":"2026-07-30T20:00:00Z"}]'
	export COMMENTS_API_FAIL=1
	run_auto_approve
	if [[ ! -s "$STATUS_CALLS_FILE" && ! -s "$ISSUE_EDIT_CALLS_FILE" && ! -s "$POSTED_COMMENT" ]]; then
		print_result "comment evidence failure defers trusted cleanup without manufacturing a hold" 0
	else
		print_result "comment evidence failure defers trusted cleanup without manufacturing a hold" 1 \
			"comment=$(<"$POSTED_COMMENT") status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_timeline_failure_defers_trusted_cleanup() {
	setup_test_env
	export ISSUE_LABELS_JSON='[{"name":"needs-maintainer-review"}]'
	export TIMELINE_API_FAIL=1
	run_auto_approve
	if [[ ! -s "$STATUS_CALLS_FILE" && ! -s "$ISSUE_EDIT_CALLS_FILE" && ! -s "$POSTED_COMMENT" ]]; then
		print_result "timeline evidence failure defers trusted cleanup without manufacturing a hold" 0
	else
		print_result "timeline evidence failure defers trusted cleanup without manufacturing a hold" 1 \
			"comment=$(<"$POSTED_COMMENT") status=$(<"$STATUS_CALLS_FILE") edit=$(<"$ISSUE_EDIT_CALLS_FILE")"
	fi
	teardown_test_env
	return 0
}

test_decision_packet_is_idempotent_across_pages() {
	setup_test_env
	export ISSUE_COMMENTS_JSON='[[{"body":"unrelated"}],[{"body":"<!-- nmr-decision-packet reason=security -->"}]]'
	# shellcheck disable=SC1090
	source "$NMR_SCRIPT"
	_nmr_emit_decision_packet 24479 owner/repo security
	if [[ ! -s "$POSTED_COMMENT" ]]; then
		print_result "paginated prior decision packet suppresses duplicate comment" 0
	else
		print_result "paginated prior decision packet suppresses duplicate comment" 1 "comment=$(<"$POSTED_COMMENT")"
	fi
	teardown_test_env
	return 0
}

test_decision_packet_defers_when_comments_unavailable() {
	setup_test_env
	export COMMENTS_API_FAIL=1
	# shellcheck disable=SC1090
	source "$NMR_SCRIPT"
	_nmr_emit_decision_packet 24479 owner/repo security
	if [[ ! -s "$POSTED_COMMENT" ]]; then
		print_result "decision packet does not duplicate when comments are unavailable" 0
	else
		print_result "decision packet does not duplicate when comments are unavailable" 1 "comment=$(<"$POSTED_COMMENT")"
	fi
	teardown_test_env
	return 0
}

test_ever_nmr_history_bypasses_self_approval_for_trusted_author() {
	setup_test_env
	# shellcheck disable=SC1090
	source "$NMR_SCRIPT"
	if issue_has_required_approval 24479 owner/repo true; then
		print_result "ever-NMR history does not require trusted OWNER self-approval" 0
	else
		print_result "ever-NMR history does not require trusted OWNER self-approval" 1 "trusted author remained blocked"
	fi
	teardown_test_env
	return 0
}

test_ever_nmr_history_still_blocks_external_author() {
	setup_test_env
	export ISSUE_API_AUTHOR="external-contributor"
	export ISSUE_ASSOC="NONE"
	# shellcheck disable=SC1090
	source "$NMR_SCRIPT"
	if issue_has_required_approval 24479 owner/repo true; then
		print_result "ever-NMR history still requires external-author approval" 1 "external author bypassed approval"
	else
		print_result "ever-NMR history still requires external-author approval" 0
	fi
	teardown_test_env
	return 0
}

main() {
	test_blocks_none_author_association
	test_blocks_external_author_even_with_nmr_automation
	test_blocks_actor_without_write_permission
	test_allows_owner_author_with_write_permission
	test_allows_write_authorized_collaborator
	test_blocks_read_only_collaborator
	test_external_origin_bot_requires_approval
	test_clears_unreasoned_peer_nmr
	test_structured_reason_becomes_explicit_hold
	test_trusted_clear_preserves_active_status
	test_trusted_clear_preserves_existing_explicit_hold
	test_legacy_breaker_becomes_structural_block
	test_cost_breaker_becomes_structural_block
	test_security_label_wins_over_machine_breaker
	test_breaker_preserves_hold_while_setting_blocked
	test_breaker_preserves_no_auto_while_setting_blocked
	test_blocked_status_failure_retains_nmr
	test_available_status_failure_retains_nmr
	test_resolved_breaker_preserves_active_status
	test_resolved_breaker_recovers_blocked_status
	test_conflicting_statuses_defer_recovery_in_any_order
	test_incomplete_labels_defer_trusted_cleanup
	test_label_helpers_reject_incomplete_metadata
	test_crypto_approval_preserves_independent_security_hold
	test_comments_failure_defers_trusted_cleanup
	test_timeline_failure_defers_trusted_cleanup
	test_decision_packet_is_idempotent_across_pages
	test_decision_packet_defers_when_comments_unavailable
	test_ever_nmr_history_bypasses_self_approval_for_trusted_author
	test_ever_nmr_history_still_blocks_external_author
	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Tests failed: %d\n' "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
