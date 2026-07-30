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
	export ISSUE_ASSOC="OWNER"
	export ISSUE_API_AUTHOR="maintainer"
	export ISSUE_LIST_AUTHOR="maintainer"
	export ACTOR_PERMISSION="write"
	export AUTHOR_PERMISSION="write"
	export NMR_TIMELINE_JSON='[]'
	: >"$LOGFILE"
	: >"$POSTED_COMMENT"
	: >"$STATUS_CALLS_FILE"
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
		printf '{"user":{"login":"%s"},"author_association":"%s","labels":[]}\n' "${ISSUE_API_AUTHOR:-maintainer}" "${ISSUE_ASSOC:-NONE}"
		exit 0
	fi
	if [[ "$path" == */timeline ]]; then
		printf '%s\n' "${NMR_TIMELINE_JSON:-[]}"
		exit 0
	fi
	if [[ "$path" == */comments ]]; then
		printf '[]\n'
		exit 0
	fi
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "lock" ]]; then
	exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "edit" ]]; then
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
	printf '%s\n' "$*" >"$STATUS_CALLS_FILE"
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
	run_auto_approve
	if grep -q 'aidevops-signed-approval' "$POSTED_COMMENT" 2>/dev/null; then
		print_result "auto-approval allows upstream OWNER author and write-capable runner" 0
	else
		print_result "auto-approval allows upstream OWNER author and write-capable runner" 1 "approval comment missing"
	fi
	if grep -q -- '^24479 owner/repo available --remove-label needs-maintainer-review --add-label auto-dispatch$' "$STATUS_CALLS_FILE" 2>/dev/null; then
		print_result "auto-approval atomically restores complete dispatchable state" 0
	else
		print_result "auto-approval atomically restores complete dispatchable state" 1 "status call: $(cat "$STATUS_CALLS_FILE")"
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
	run_auto_approve
	if grep -q 'aidevops-signed-approval' "$POSTED_COMMENT" 2>/dev/null; then
		print_result "auto-approval allows write-authorized collaborator issues" 0
	else
		print_result "auto-approval allows write-authorized collaborator issues" 1 "approval comment missing"
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

test_preserves_peer_maintainer_manual_hold() {
	setup_test_env
	export ISSUE_LIST_AUTHOR="trusted-author"
	export ISSUE_API_AUTHOR="trusted-author"
	export ISSUE_ASSOC="COLLABORATOR"
	export AUTHOR_PERMISSION="write"
	export NMR_TIMELINE_JSON='[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"trusted-author"},"created_at":"2026-07-30T20:00:00Z"}]'
	run_auto_approve
	if ! grep -q 'aidevops-signed-approval' "$POSTED_COMMENT" 2>/dev/null && [[ ! -s "$STATUS_CALLS_FILE" ]]; then
		print_result "auto-approval preserves peer maintainer manual NMR hold" 0
	else
		print_result "auto-approval preserves peer maintainer manual NMR hold" 1 "unexpected approval or status transition"
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
	test_preserves_peer_maintainer_manual_hold
	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Tests failed: %d\n' "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
