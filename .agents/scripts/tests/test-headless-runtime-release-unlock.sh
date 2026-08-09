#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test: worker CLAIM_RELEASED must unlock the issue that dispatch
# locked before worker launch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_HOME="$(mktemp -d)"
CALL_LOG="${TMP_HOME}/gh-calls.log"
: >"$CALL_LOG"
export AIDEVOPS_TEST_MODE=1
export AIDEVOPS_REPO_STATE_GUARD_TEST_BYPASS=1

cleanup() {
	rm -rf "$TMP_HOME"
	return 0
}
trap cleanup EXIT

print_warning() {
	local message="$1"
	printf 'WARN %s\n' "$message" >>"$CALL_LOG"
	return 0
}

print_info() {
	local message="$1"
	printf 'INFO %s\n' "$message" >>"$CALL_LOG"
	return 0
}

clear_active_status_on_release() {
	local issue_number="$1"
	local repo_slug="$2"
	local runner_name="$3"
	printf 'CLEAR issue=%s repo=%s runner=%s\n' "$issue_number" "$repo_slug" "$runner_name" >>"$CALL_LOG"
	return 0
}

whoami() {
	printf 'local-os-user\n'
	return 0
}

gh() {
	local cmd="${1:-}"
	shift || true
	case "$cmd" in
	api)
		local path="${1:-}"
		shift || true
		if [[ "$path" == "user" ]]; then
			printf 'api-login\n'
			return 0
		fi
		local method="GET" body="" prev=""
		local arg
		for arg in "$@"; do
			if [[ "$prev" == "--method" ]]; then
				method="$arg"
			fi
			if [[ "$arg" == body=* ]]; then
				body="${arg#body=}"
			fi
			prev="$arg"
		done
		printf 'API method=%s path=%s body=%s\n' "$method" "$path" "$body" >>"$CALL_LOG"
		if [[ "$path" == */comments && "$method" == "POST" ]]; then
			local attempt_count=0
			if [[ -f "${TMP_HOME}/comment-attempts" ]]; then
				attempt_count=$(<"${TMP_HOME}/comment-attempts")
			fi
			attempt_count=$((attempt_count + 1))
			printf '%s\n' "$attempt_count" >"${TMP_HOME}/comment-attempts"
			if [[ "$attempt_count" -le "${GH_COMMENT_FAILURES_BEFORE_SUCCESS:-0}" ]]; then
				printf 'temporary comment failure %s\n' "$attempt_count" >&2
				return 1
			fi
		fi
		printf '{}\n'
		;;
	issue)
		local subcmd="${1:-}"
		shift || true
		if [[ "$subcmd" == "unlock" ]]; then
			local issue_number="${1:-}"
			shift || true
			local repo_slug="" prev=""
			local arg
			for arg in "$@"; do
				if [[ "$prev" == "--repo" ]]; then
					repo_slug="$arg"
				fi
				prev="$arg"
			done
			printf 'UNLOCK issue=%s repo=%s\n' "$issue_number" "$repo_slug" >>"$CALL_LOG"
			case "${GH_UNLOCK_MODE:-success}" in
			already_unlocked)
				printf 'GraphQL: Issue is not locked\n' >&2
				return 1
				;;
			hard_fail)
				printf 'GraphQL: repository access denied\n' >&2
				return 1
				;;
			*) ;;
			esac
		fi
		;;
	*) ;;
	esac
	return 0
}

# shellcheck source=../headless-runtime-failure.sh
source "${SCRIPT_DIR}/headless-runtime-failure.sh"

unset DISPATCH_REPO_SLUG WORKER_ISSUE_NUMBER
_release_dispatch_claim "supervisor-pulse" "process_exit" "1" "0"
if grep -q 'Cannot release claim: missing issue= repo=' "$CALL_LOG"; then
	printf 'FAIL empty non-worker claim release emitted warning\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi
printf 'PASS empty non-worker claim release is a silent no-op\n'
: >"$CALL_LOG"

export DISPATCH_REPO_SLUG="owner/repo"
export WORKER_GITHUB_LOGIN="assigned-bot"
_release_dispatch_claim "issue-12345" "worker_noop" "0" "0"

if grep -q 'CLAIM_RELEASED reason=worker_noop' "$CALL_LOG" &&
	grep -q 'CLEAR issue=12345 repo=owner/repo runner=assigned-bot' "$CALL_LOG" &&
	grep -q 'runner=assigned-bot' "$CALL_LOG" &&
	! grep -q 'runner=local-os-user' "$CALL_LOG" &&
	grep -q 'UNLOCK issue=12345 repo=owner/repo' "$CALL_LOG"; then
	printf 'PASS release posts claim, clears assigned GitHub login, and unlocks issue\n'
else
	printf 'FAIL release lifecycle missing expected calls\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

: >"$CALL_LOG"
rm -f "${TMP_HOME}/comment-attempts"
export WORKER_ISSUE_NUMBER="12345"
export AIDEVOPS_PR_REPAIR_NUMBER="12345"
export AIDEVOPS_PR_REPAIR_HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
export AIDEVOPS_PR_REPAIR_HEAD_REF="feature/review"
_release_dispatch_claim "pr-review-thread-response-owner-repo-12345" "worker_failed" "1" "0"
if grep -q 'scanner owns lifecycle state' "$CALL_LOG" && \
	! grep -q '^API ' "$CALL_LOG" && ! grep -q '^CLEAR ' "$CALL_LOG" && ! grep -q '^UNLOCK ' "$CALL_LOG"; then
	printf 'PASS direct PR repair leaves release lifecycle to scanner without issue mutations\n'
else
	printf 'FAIL direct PR repair performed generic issue release mutations\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

: >"$CALL_LOG"
rm -f "${TMP_HOME}/comment-attempts"
export AIDEVOPS_PR_REPAIR_NUMBER="67890"
_release_dispatch_claim "issue-12345" "worker_noop" "0" "0"
if grep -q 'CLAIM_RELEASED reason=worker_noop' "$CALL_LOG" && \
	grep -q 'CLEAR issue=12345 repo=owner/repo runner=assigned-bot' "$CALL_LOG" && \
	grep -q 'UNLOCK issue=12345 repo=owner/repo' "$CALL_LOG"; then
	printf 'PASS linked-issue PR repair preserves generic issue release lifecycle\n'
else
	printf 'FAIL linked-issue PR repair skipped strict issue release lifecycle\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi
unset WORKER_ISSUE_NUMBER AIDEVOPS_PR_REPAIR_NUMBER AIDEVOPS_PR_REPAIR_HEAD_SHA AIDEVOPS_PR_REPAIR_HEAD_REF

: >"$CALL_LOG"
rm -f "${TMP_HOME}/comment-attempts"
if GH_COMMENT_FAILURES_BEFORE_SUCCESS=2 AIDEVOPS_CLAIM_RELEASE_POST_ATTEMPTS=3 \
	AIDEVOPS_CLAIM_RELEASE_POST_RETRY_DELAY=0 \
	_release_dispatch_claim "issue-12345" "worker_noop" "0" "0" && \
	[[ "$(<"${TMP_HOME}/comment-attempts")" == "3" ]] && \
	grep -q 'CLEAR issue=12345 repo=owner/repo runner=assigned-bot' "$CALL_LOG" && \
	grep -q 'UNLOCK issue=12345 repo=owner/repo' "$CALL_LOG"; then
	printf 'PASS release comment retries transient persistence failures\n'
else
	printf 'FAIL release comment did not retry transient persistence failures\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

: >"$CALL_LOG"
rm -f "${TMP_HOME}/comment-attempts"
if GH_COMMENT_FAILURES_BEFORE_SUCCESS=5 AIDEVOPS_CLAIM_RELEASE_POST_ATTEMPTS=2 \
	AIDEVOPS_CLAIM_RELEASE_POST_RETRY_DELAY=0 \
	_release_dispatch_claim "issue-12345" "worker_noop" "0" "0"; then
	printf 'FAIL exhausted release comment persistence was reported as successful\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi
if [[ "$(<"${TMP_HOME}/comment-attempts")" == "2" ]] && \
	grep -q 'WARN Failed to post CLAIM_RELEASED on #12345 after 2 attempt(s)' "$CALL_LOG" && \
	! grep -q '^CLEAR ' "$CALL_LOG" && ! grep -q '^UNLOCK ' "$CALL_LOG"; then
	printf 'PASS exhausted release comment persistence is surfaced and remains retryable\n'
else
	printf 'FAIL exhausted release comment persistence was not surfaced safely\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

: >"$CALL_LOG"
rm -f "${TMP_HOME}/comment-attempts"
_release_dispatch_claim "issue-12345" "worker_ownership_lost" "1" "0"
if grep -q 'CLAIM_RELEASED reason=worker_ownership_lost' "$CALL_LOG" && \
	! grep -q '^CLEAR ' "$CALL_LOG" && ! grep -q '^UNLOCK ' "$CALL_LOG"; then
	printf 'PASS ownership-loss release terminalizes lease without changing live issue ownership\n'
else
	printf 'FAIL ownership-loss release changed live issue ownership\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

: >"$CALL_LOG"
rm -f "${TMP_HOME}/comment-attempts"
_release_dispatch_claim "issue-12345" "worker_draft_checkpoint" "1" "0"
if grep -q 'CLAIM_RELEASED reason=worker_draft_checkpoint' "$CALL_LOG" && \
	grep -q 'Preserving issue ownership and review state for draft checkpoint #12345' "$CALL_LOG" && \
	! grep -q '^CLEAR ' "$CALL_LOG" && ! grep -q '^UNLOCK ' "$CALL_LOG"; then
	printf 'PASS draft-checkpoint release preserves assignment and review state\n'
else
	printf 'FAIL draft-checkpoint release cleared continuation ownership\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

: >"$CALL_LOG"
GH_UNLOCK_MODE=already_unlocked _unlock_issue_after_dispatch_release "12345" "owner/repo"
if grep -q 'INFO Release unlock skipped for GitHub issue #12345 in owner/repo: already unlocked' "$CALL_LOG" &&
	! grep -q 'WARN Failed to unlock released' "$CALL_LOG"; then
	printf 'PASS already-unlocked release cleanup is benign\n'
else
	printf 'FAIL already-unlocked release cleanup was not benign\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

: >"$CALL_LOG"
GH_UNLOCK_MODE=hard_fail _unlock_issue_after_dispatch_release "12345" "owner/repo"
if grep -q 'WARN Failed to unlock released GitHub issue #12345 in owner/repo (non-fatal): GraphQL: repository access denied' "$CALL_LOG"; then
	printf 'PASS hard unlock failures include issue, repo, and cause\n'
else
	printf 'FAIL hard unlock failure did not include issue, repo, and cause\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

: >"$CALL_LOG"
GH_UNLOCK_MODE=success _unlock_issue_after_dispatch_release "004" "owner/repo"
if grep -q 'INFO Skipping release unlock for local task ID 004 in owner/repo: not a GitHub issue number' "$CALL_LOG" &&
	! grep -q 'UNLOCK issue=004' "$CALL_LOG"; then
	printf 'PASS leading-zero local task IDs are not formatted as GitHub issues\n'
	exit 0
fi

printf 'FAIL leading-zero local task ID handling was not explicit\n'
sed 's/^/  /' "$CALL_LOG"
exit 1
