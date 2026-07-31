#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# t2019: Unit tests for the triage-review output-shape and JSON
# extraction path in pulse-ancillary-dispatch.sh.
#
# What this guards:
#   - _extract_review_text_from_json correctly extracts text events
#     from OpenCode --format json output.
#   - _extract_review_text_from_json correctly extracts text events
#     from Claude CLI --output-format stream-json output.
#   - _extract_review_text_from_json falls back to raw content when
#     no JSON events parse (legacy/plain-text path).
#   - The oversized-output ceiling suppresses >20KB extracted text.
#   - Exact first-line, required-field, recommendation-match, and word-limit
#     validation rejects model format drift.
#   - A clean, exact review embedded in JSON is posted through a body file.
#   - Suppression diagnostics retain metadata but never model/runtime output.
#
# Harness style: mocked gh, isolated HOME, stub cache helpers.

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"
GH_CALL_LOG=""
LOGFILE=""
HEADLESS_INVOCATION_LOG=""
TRIAGE_CACHE_LOG=""
TRIAGE_LIFECYCLE_LOG=""
POSTED_BODY_LOG=""
EPHEMERAL_BODY_LOG=""
MOCK_COMMENT_WRITE_FAILURE=0
MOCK_REVIEW_LABEL_WRITE_FAILURE=0
MOCK_PR_REVISION_PAIR=""
readonly EXPECTED_TEXT_SNAPSHOT_HASH="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
MOCK_CURRENT_TEXT_SNAPSHOT_HASH="$EXPECTED_TEXT_SNAPSHOT_HASH"
readonly EXPECTED_PUBLIC_REVISION="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
MOCK_CURRENT_PUBLIC_REVISION="$EXPECTED_PUBLIC_REVISION"
_PAD_JSON_ARRAY_TYPE="array"
_PAD_JSON_STRING_TYPE="string"
_PAD_TRIAGE_RUNTIME_TEMP_FAILURE_REASON="triage-runtime-temp-failed"
_PAD_TRIAGE_OUTCOME_POSTED="posted"
_PAD_TRIAGE_OUTCOME_REVIEW_FAILED="review_failed"
_PAD_TRIAGE_OUTCOME_INFRASTRUCTURE_FAILED="infrastructure_failed"
_PAD_TRIAGE_LAST_OUTCOME=""
_PAD_TRIAGE_MAX_COMMENTS=100
_PAD_TRIAGE_MAX_COMMENT_BYTES=1048576

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
	export AIDEVOPS_TEMP_DIR="${TEST_ROOT}/managed-temp"
	export AIDEVOPS_SENSITIVE_TEMP_DIR="$AIDEVOPS_TEMP_DIR"
	mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/agents/scripts" \
		"$AIDEVOPS_TEMP_DIR"
	AIDEVOPS_TEMP_DIR=$(cd "$AIDEVOPS_TEMP_DIR" && pwd -P)
	export AIDEVOPS_TEMP_DIR
	LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
	: >"$LOGFILE"
	GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_CALL_LOG"
	HEADLESS_INVOCATION_LOG="${TEST_ROOT}/headless-invocations.log"
	: >"$HEADLESS_INVOCATION_LOG"
	TRIAGE_CACHE_LOG="${TEST_ROOT}/triage-cache.log"
	: >"$TRIAGE_CACHE_LOG"
	TRIAGE_LIFECYCLE_LOG="${TEST_ROOT}/triage-lifecycle.log"
	: >"$TRIAGE_LIFECYCLE_LOG"
	POSTED_BODY_LOG="${TEST_ROOT}/posted-body.log"
	: >"$POSTED_BODY_LOG"
	EPHEMERAL_BODY_LOG="${TEST_ROOT}/ephemeral-body.log"
	: >"$EPHEMERAL_BODY_LOG"
	export TRIAGE_SIGNATURE_HELPER="${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh"
	cat >"$TRIAGE_SIGNATURE_HELPER" <<'SIG_STUB'
#!/usr/bin/env bash
if [[ "${TRIAGE_TEST_SIGNATURE_FAILURE:-0}" == "1" ]]; then
	exit 1
fi
printf '\n<!-- aidevops:sig -->\n---\n[test signature]\n'
exit 0
SIG_STUB
	chmod +x "$TRIAGE_SIGNATURE_HELPER"
	MOCK_COMMENT_WRITE_FAILURE=0
	MOCK_REVIEW_LABEL_WRITE_FAILURE=0
	MOCK_PR_REVISION_PAIR=""
	MOCK_CURRENT_TEXT_SNAPSHOT_HASH="$EXPECTED_TEXT_SNAPSHOT_HASH"
	MOCK_CURRENT_PUBLIC_REVISION="$EXPECTED_PUBLIC_REVISION"
	unset TRIAGE_TEST_RUNTIME_EXIT_STATUS TRIAGE_TEST_SIGNATURE_FAILURE 2>/dev/null || true
	return 0
}

teardown_test_env() {
	export HOME="${ORIGINAL_HOME}"
	unset AIDEVOPS_TEMP_DIR AIDEVOPS_SENSITIVE_TEMP_DIR TRIAGE_SIGNATURE_HELPER TRIAGE_TEST_RUNTIME_EXIT_STATUS \
		TRIAGE_TEST_SIGNATURE_FAILURE 2>/dev/null || true
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Stub the t2393 comment wrappers so production code calling
# `gh_issue_comment` / `gh_pr_comment` reaches the mock below. The real
# wrappers live in shared-constants.sh, which this test doesn't source.
# shellcheck disable=SC2317
gh_issue_comment() { gh issue comment "$@" && return 0 || return 1; }
# shellcheck disable=SC2317
gh_pr_comment() { gh pr comment "$@" && return 0 || return 1; }
export -f gh_issue_comment gh_pr_comment

# Mock gh that records calls. Every call returns success so the
# dispatch path can complete without real network access.
gh() {
	local command_name="${1:-}"
	local action="${2:-}"
	local call_args="$*"
	local previous=""
	local argument=""
	printf '%s\n' "$call_args" >>"$GH_CALL_LOG"
	if [[ "$command_name" == "issue" && "$action" == "comment" ]]; then
		printf '%s\n' "${AIDEVOPS_GH_EPHEMERAL_BODY_FILE:-}" >>"$EPHEMERAL_BODY_LOG"
	fi
	for argument in "$@"; do
		if [[ "$previous" == "--body-file" && -f "$argument" ]]; then
			command cat "$argument" >"$POSTED_BODY_LOG"
			break
		fi
		previous="$argument"
	done
	if [[ "$command_name" == "issue" && "$action" == "comment" && \
		"$MOCK_COMMENT_WRITE_FAILURE" -eq 1 ]]; then
		return 1
	fi
	if [[ "$command_name" == "issue" && "$action" == "edit" && \
		"$call_args" == *"--add-label review:"* && \
		"$MOCK_REVIEW_LABEL_WRITE_FAILURE" -eq 1 ]]; then
		return 1
	fi
	case "$command_name" in
	issue)
		if [[ "$action" == "view" ]]; then
			local viewed_number="${3:-0}"
			jq -cn --argjson number "$viewed_number" '{
				number: $number,
				title: "Stable test title",
				body: "Stable test body",
				author: {login: "external"},
				labels: [{name: "needs-maintainer-review"}],
				createdAt: "2026-07-27T00:00:00Z",
				updatedAt: "2026-07-27T00:01:00Z"
			}'
		fi
		return 0
		;;
	api)
		if [[ "$call_args" == *"/comments?per_page=100"* ]]; then
			printf '%s\n' '[[{"id":1,"user":{"login":"external"},"author_association":"CONTRIBUTOR","body":"Stable test comment","created_at":"2026-07-27T00:01:00Z","updated_at":"2026-07-27T00:01:00Z"}]]'
			return 0
		fi
		if [[ "$call_args" == *"/pulls/"* && "$call_args" == *"--jq"* && \
			-n "$MOCK_PR_REVISION_PAIR" ]]; then
			printf '%s\n' "$MOCK_PR_REVISION_PAIR"
			return 0
		fi
		if [[ "$call_args" == *"repos/owner/repo/commits"* && \
			"$call_args" == *"per_page=1"* ]]; then
			printf '%s\n' "$MOCK_CURRENT_PUBLIC_REVISION"
			return 0
		fi
		# Return empty JSON for any read, zero for count queries.
		printf '0\n'
		return 0
		;;
	esac
	return 0
}
export -f gh

# Stub cache helpers and lock helpers so _dispatch_triage_review_worker
# can be invoked directly without sourcing the full pulse-wrapper boot.
_triage_content_hash() { printf 'deadbeef\n'; }
_triage_is_cached() { return 1; }
_triage_update_cache() { printf 'update %s %s %s\n' "$1" "$2" "$3" >>"$TRIAGE_CACHE_LOG"; return 0; }
_triage_increment_failure() { printf 'increment %s %s %s\n' "$1" "$2" "$3" >>"$TRIAGE_CACHE_LOG"; return 1; }
_triage_awaiting_contributor_reply() { return 1; }
lock_issue_for_worker() {
	local issue_num="$1"
	local repo_slug="$2"
	printf 'lock %s %s\n' "$issue_num" "$repo_slug" >>"$TRIAGE_LIFECYCLE_LOG"
	return 0
}
unlock_issue_after_worker() {
	local issue_num="$1"
	local repo_slug="$2"
	printf 'unlock %s %s\n' "$issue_num" "$repo_slug" >>"$TRIAGE_LIFECYCLE_LOG"
	return 0
}
export -f _triage_content_hash _triage_is_cached _triage_update_cache \
	_triage_increment_failure _triage_awaiting_contributor_reply \
	lock_issue_for_worker unlock_issue_after_worker

# Load just the functions under test from the production file using
# awk/sed extraction — same pattern as test-triage-failure-escalation.sh.
# We load:
#   - _extract_review_text_from_json
#   - _log_suppressed_triage_output
#   - _ensure_triage_failed_label
#   - _post_triage_escalation_comment
#   - _dispatch_triage_review_worker
load_helpers_under_test() {
	local src
	local here
	here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	src="${AIDEVOPS_SOURCE:-${here}/../pulse-ancillary-dispatch.sh}"
	if [[ ! -f "$src" ]]; then
		printf 'ERROR: cannot locate pulse-ancillary-dispatch.sh (tried %s)\n' "$src" >&2
		exit 2
	fi
	# Extract the pre-post snapshot fence, then the posting/dispatch helper block.
	# The fence now lives before _ensure_triage_failed_label in production, so the
	# historical single-range extraction silently omitted it.
	local tmp
	tmp=$(mktemp)
	awk '
	/^_triage_post_snapshot_failure_reason\(\) \{/{flag=1}
	flag{print}
	/^_triage_fetch_pr_snapshot\(\) \{/{flag=0}
	' "$src" |
		sed '/^_triage_fetch_pr_snapshot()/,$d' >"$tmp"
	awk '
	/^_ensure_triage_failed_label\(\) \{/{flag=1}
	flag{print}
	/^dispatch_triage_reviews\(\) \{/{flag=0}
	' "$src" |
		sed '/^dispatch_triage_reviews()/,$d' >>"$tmp"
	# shellcheck source=../sensitive-temp-helper.sh
	source "${here}/../sensitive-temp-helper.sh"
	# shellcheck disable=SC1090
	source "$tmp"
	rm -f "$tmp"
	_triage_current_text_snapshot_hash() {
		printf '%s\n' "$MOCK_CURRENT_TEXT_SNAPSHOT_HASH"
		return 0
	}
	_triage_prefetch_issue() {
		local issue_json_var="$3"
		local issue_comments_var="$4"
		local issue_body_var="$5"
		printf -v "$issue_json_var" '%s' '{}'
		printf -v "$issue_comments_var" '%s' '[]'
		printf -v "$issue_body_var" '%s' ''
		return 0
	}
	_triage_default_branch_revision_rest() {
		printf '%s\n' "$MOCK_CURRENT_PUBLIC_REVISION"
		return 0
	}
	_triage_pr_revision_pair_rest() {
		printf '%s\n' "$MOCK_PR_REVISION_PAIR"
		return 0
	}
	return 0
}

# ------------------------------ Helpers ------------------------------

# Write an OpenCode-format JSON output file containing a review text.
_make_opencode_json() {
	local output_file="$1"
	local text="$2"
	# Escape backslashes and double-quotes for JSON, then encode newlines.
	local escaped
	escaped=$(printf '%s' "$text" | python3 -c '
import json, sys
sys.stdout.write(json.dumps(sys.stdin.read()))
')
	{
		printf '{"type":"step_start","sessionID":"test-session"}\n'
		printf '{"type":"text","text":%s}\n' "$escaped"
		printf '{"type":"step_finish"}\n'
	} >"$output_file"
}

# Write a Claude CLI stream-json output file containing a review text.
_make_claude_stream_json() {
	local output_file="$1"
	local text="$2"
	local escaped
	escaped=$(printf '%s' "$text" | python3 -c '
import json, sys
sys.stdout.write(json.dumps(sys.stdin.read()))
')
	{
		printf '{"type":"system","subtype":"init"}\n'
		printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' "$escaped"
		printf '{"type":"result","subtype":"success"}\n'
	} >"$output_file"
}

# Make a sandboxed headless-runtime-helper stub that copies a pre-prepared
# file to the output file path the caller passes.
_install_headless_stub() {
	local payload_file="$1"
	local stub_dir="${TEST_ROOT}/stubs"
	mkdir -p "$stub_dir"
	export HEADLESS_RUNTIME_HELPER="${stub_dir}/headless-runtime-helper.sh"
	cat >"$HEADLESS_RUNTIME_HELPER" <<STUB_EOF
#!/usr/bin/env bash
# Test stub: concatenate the payload to stdout so the caller's
# >"\$review_output_file" 2>&1 captures it.
printf '%s\n' "\$*" >>"${HEADLESS_INVOCATION_LOG}"
printf 'env HEADLESS=%s WORKER_ISSUE_NUMBER=%s WORKER_REPO_SLUG=%s WORKER_WORKTREE_PATH=%s\n' "\${HEADLESS:-}" "\${WORKER_ISSUE_NUMBER:-}" "\${WORKER_REPO_SLUG:-}" "\${WORKER_WORKTREE_PATH:-}" >>"${HEADLESS_INVOCATION_LOG}"
cat "${payload_file}"
exit "\${TRIAGE_TEST_RUNTIME_EXIT_STATUS:-0}"
STUB_EOF
	chmod +x "$HEADLESS_RUNTIME_HELPER"
	return 0
}

_make_managed_prompt_file() {
	local purpose="$1"
	local prompt_dir=""
	prompt_dir=$(_triage_create_sensitive_artifact_dir "$purpose") || return 1
	local prompt_file="${prompt_dir}/prompt.txt"
	if ! printf 'test prompt\n' >"$prompt_file"; then
		_triage_cleanup_sensitive_artifact_dir "$prompt_dir" || true
		return 1
	fi
	printf '%s\n' "$prompt_file"
	return 0
}

_install_headless_contract_failure_stub() {
	local stub_dir="${TEST_ROOT}/stubs"
	mkdir -p "$stub_dir"
	export HEADLESS_RUNTIME_HELPER="${stub_dir}/headless-runtime-helper.sh"
	cat >"$HEADLESS_RUNTIME_HELPER" <<STUB_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${HEADLESS_INVOCATION_LOG}"
printf '%b\n' '\033[0;31m[ERROR]\033[0m [fatal] WORKER_ISSUE_NUMBER unset — issue worker env contract missing; aborting before model launch'
exit 1
STUB_EOF
	chmod +x "$HEADLESS_RUNTIME_HELPER"
	return 0
}

_valid_review_text() {
	cat <<'REVIEW_EOF'
## Review: Recommendation: Approve

### Issue Validation

| Check | Status | Notes |
|-------|--------|-------|
| Reproducible | Yes | Documented |
| Not duplicate | Yes | none found |
| Actual bug | Yes | confirmed |
| In scope | Yes | project goal |

**Root Cause:** Off-by-one in loop bound.

### Scope & Recommendation

- **Scope creep:** Low
- **Complexity tier:** `tier:simple`
- **Recommendation:** APPROVE
- **PR disposition:** NOT APPLICABLE — implement the issue directly.
- **Recommended labels:** bug, tier:simple
- **Implementation guidance:** Fix the loop bound at line 42.
REVIEW_EOF
	return 0
}

_valid_pr_review_text() {
	cat <<'REVIEW_EOF'
## Review: Recommendation: Request Changes

### Issue Validation

| Check | Status | Notes |
|-------|--------|-------|
| Reproducible | Yes | Documented |
| Not duplicate | Yes | none found |
| Actual bug | Yes | confirmed |
| In scope | Yes | project goal |

**Root Cause:** Off-by-one in loop bound.

### Solution Evaluation (PR only — omit section for issues)

| Criterion | Assessment | Notes |
|-----------|------------|-------|
| Simplicity | Good | focused change |
| Correctness | Needs Work | wrong boundary |
| Completeness | Good | edge cases covered |
| Security | Good | no concern |

### Scope & Recommendation

- **Scope creep:** Low
- **Complexity tier:** `tier:simple`
- **Recommendation:** REQUEST CHANGES
- **PR disposition:** REPAIR — update the loop boundary.
- **Recommended labels:** bug, tier:simple
- **Implementation guidance:** Fix the loop boundary; rerun the focused unit test.
REVIEW_EOF
	return 0
}

# ------------------------------ Tests ------------------------------

test_extract_opencode_json_returns_text() {
	setup_test_env
	load_helpers_under_test
	local payload="${TEST_ROOT}/payload.json"
	_make_opencode_json "$payload" "## Review: Approved

### Issue Validation

Looks good."
	local extracted
	extracted=$(_extract_review_text_from_json "$payload")
	if [[ "$extracted" == *"## Review: Approved"* && "$extracted" == *"Looks good"* ]]; then
		print_result "_extract_review_text_from_json extracts OpenCode text events" 0
	else
		print_result "_extract_review_text_from_json extracts OpenCode text events" 1 \
			"extracted='$extracted'"
	fi
	teardown_test_env
}

test_extract_claude_stream_json_returns_text() {
	setup_test_env
	load_helpers_under_test
	local payload="${TEST_ROOT}/payload.json"
	_make_claude_stream_json "$payload" "## Review: Needs Changes

### Solution Evaluation

Refactor needed."
	local extracted
	extracted=$(_extract_review_text_from_json "$payload")
	if [[ "$extracted" == *"## Review: Needs Changes"* && "$extracted" == *"Refactor needed"* ]]; then
		print_result "_extract_review_text_from_json extracts Claude stream-json assistant events" 0
	else
		print_result "_extract_review_text_from_json extracts Claude stream-json assistant events" 1 \
			"extracted='$extracted'"
	fi
	teardown_test_env
}

test_extract_plain_text_fallback() {
	setup_test_env
	load_helpers_under_test
	local payload="${TEST_ROOT}/payload.json"
	printf '## Review: Approved\n\nThis is plain text, no JSON.\n' >"$payload"
	local extracted
	extracted=$(_extract_review_text_from_json "$payload")
	if [[ "$extracted" == *"## Review: Approved"* ]]; then
		print_result "_extract_review_text_from_json falls back to raw content when no JSON" 0
	else
		print_result "_extract_review_text_from_json falls back to raw content when no JSON" 1 \
			"extracted='$extracted'"
	fi
	teardown_test_env
}

test_extract_concats_multiple_text_events() {
	setup_test_env
	load_helpers_under_test
	local payload="${TEST_ROOT}/payload.json"
	{
		printf '{"type":"text","text":"## Review: Approved\\n"}\n'
		printf '{"type":"text","text":"\\n### Issue Validation\\n"}\n'
		printf '{"type":"text","text":"Looks correct."}\n'
	} >"$payload"
	local extracted
	extracted=$(_extract_review_text_from_json "$payload")
	if [[ "$extracted" == *"## Review: Approved"* && "$extracted" == *"Looks correct"* ]]; then
		print_result "_extract_review_text_from_json concatenates multiple text events" 0
	else
		print_result "_extract_review_text_from_json concatenates multiple text events" 1 \
			"extracted='$extracted'"
	fi
	teardown_test_env
}

test_review_shape_enforces_exact_contract() {
	setup_test_env
	load_helpers_under_test
	local valid_review=""
	valid_review=$(_valid_review_text)
	local ok=0
	local details=""
	local reason=""

	reason=$(_triage_review_shape_failure_reason "$valid_review" "issue")
	if [[ -n "$reason" ]]; then
		ok=1
		details="valid=${reason}"
	fi
	local valid_pr_review=""
	valid_pr_review=$(_valid_pr_review_text)
	reason=$(_triage_review_shape_failure_reason "$valid_pr_review" "pr")
	if [[ -n "$reason" ]]; then
		ok=1
		details="${details} valid_pr=${reason}"
	fi

	reason=$(_triage_review_shape_failure_reason "Analysis follows."$'\n'"${valid_review}" "issue")
	if [[ "$reason" != "invalid-review-first-line" ]]; then
		ok=1
		details="${details} preamble=${reason:-<empty>}"
	fi

	reason=$(_triage_review_shape_failure_reason "${valid_review}"$'\n'"## Review: Recommendation: Approve" "issue")
	if [[ "$reason" != "duplicate-review-header" ]]; then
		ok=1
		details="${details} duplicate=${reason:-<empty>}"
	fi

	local missing_field="${valid_review/- **PR disposition:** NOT APPLICABLE — implement the issue directly./}"
	reason=$(_triage_review_shape_failure_reason "$missing_field" "issue")
	if [[ "$reason" != "invalid-review-shape" ]]; then
		ok=1
		details="${details} missing=${reason:-<empty>}"
	fi

	local mismatched="${valid_review/APPROVE/DECLINE}"
	reason=$(_triage_review_shape_failure_reason "$mismatched" "issue")
	if [[ "$reason" != "recommendation-mismatch" ]]; then
		ok=1
		details="${details} mismatch=${reason:-<empty>}"
	fi

	local extra_heading="${valid_review}"$'\n\n'"### Unrequested Analysis"$'\n\n'"Unexpected heading content."
	reason=$(_triage_review_shape_failure_reason "$extra_heading" "issue")
	if [[ "$reason" != "invalid-review-shape" ]]; then
		ok=1
		details="${details} extra_heading=${reason:-<empty>}"
	fi

	reason=$(_triage_review_shape_failure_reason \
		"${valid_review}"$'\n'"Unrequested trailing prose." "issue")
	if [[ "$reason" != "invalid-review-shape" ]]; then
		ok=1
		details="${details} trailing_prose=${reason:-<empty>}"
	fi

	local over_limit=""
	over_limit="${valid_review}"$'\n'"$(python3 -c 'print("word " * 801)')"
	reason=$(_triage_review_shape_failure_reason "$over_limit" "issue")
	if [[ "$reason" != "review-word-limit" ]]; then
		ok=1
		details="${details} word_limit=${reason:-<empty>}"
	fi

	reason=$(_triage_review_shape_failure_reason "$valid_pr_review" "issue")
	if [[ "$reason" != "invalid-review-shape" ]]; then
		ok=1
		details="${details} pr_as_issue=${reason:-<empty>}"
	fi
	reason=$(_triage_review_shape_failure_reason "$valid_review" "pr")
	if [[ "$reason" != "invalid-review-shape" ]]; then
		ok=1
		details="${details} issue_as_pr=${reason:-<empty>}"
	fi

	print_result "review shape enforces exact bounded recommendation contract" "$ok" "$details"
	teardown_test_env
}

test_dispatch_accepts_clean_review_in_json() {
	setup_test_env
	load_helpers_under_test
	# Synthesise the runtime output the stub will return: a clean review
	# wrapped in OpenCode JSON.
	local payload="${TEST_ROOT}/payload.json"
	_make_opencode_json "$payload" "$(_valid_review_text)"
	_install_headless_stub "$payload"

	# Use the production managed artifact path so prompt, output, and cleanup
	# behavior are exercised together.
	local prompt_file=""
	prompt_file=$(_make_managed_prompt_file "review-test")
	local prompt_dir="${prompt_file%/*}"

	_dispatch_triage_review_worker \
		"18400" "owner/repo" "/tmp/repo" "$prompt_file" "hash123" "" "issue" \
		"" "$EXPECTED_TEXT_SNAPSHOT_HASH" "$EXPECTED_PUBLIC_REVISION" \
		2>/dev/null
	if grep -q '^issue comment 18400 --repo owner/repo --body-file ' "$GH_CALL_LOG"; then
		print_result "dispatch accepts clean review embedded in OpenCode JSON" 0
	else
		print_result "dispatch accepts clean review embedded in OpenCode JSON" 1 \
			"gh call log (last lines):
$(tail -5 "$GH_CALL_LOG")"
	fi
	local label_line="" comment_line=""
	label_line=$(grep -n -- '--add-label review:approve' "$GH_CALL_LOG" | cut -d: -f1 | head -n 1)
	comment_line=$(grep -n '^issue comment 18400 ' "$GH_CALL_LOG" | cut -d: -f1 | head -n 1)
	if [[ -n "$label_line" && -n "$comment_line" && "$label_line" -lt "$comment_line" ]] && \
		grep -q -- '--remove-label review:feedback --remove-label review:decline --add-label review:approve' "$GH_CALL_LOG"; then
		print_result "advisory approve label is made mutually exclusive before comment transport" 0
	else
		print_result "advisory approve label is made mutually exclusive before comment transport" 1
	fi
	if grep -qF '<!-- aidevops:triage-review -->' "$POSTED_BODY_LOG"; then
		print_result "posted triage review carries trusted cache marker" 0
	else
		print_result "posted triage review carries trusted cache marker" 1
	fi
	if grep -qF '<!-- aidevops:sig -->' "$POSTED_BODY_LOG" && \
		grep -q "^${AIDEVOPS_TEMP_DIR}/aidevops-triage-comment\.[A-Za-z0-9]*/comment.md$" \
			"$EPHEMERAL_BODY_LOG"; then
		print_result "triage comment uses canonical signature and explicit ephemeral transport" 0
	else
		print_result "triage comment uses canonical signature and explicit ephemeral transport" 1
	fi
	if [[ ! -e "$prompt_dir" ]]; then
		print_result "triage dispatch removes managed prompt and output directory" 0
	else
		print_result "triage dispatch removes managed prompt and output directory" 1 \
			"retained=${prompt_dir}"
	fi
	if grep -q -- '--role triage' "$HEADLESS_INVOCATION_LOG"; then
		print_result "triage dispatch uses distinct triage role" 0
	else
		print_result "triage dispatch uses distinct triage role" 1 \
			"headless invocation log:\n$(cat "$HEADLESS_INVOCATION_LOG")"
	fi
	if grep -q 'env HEADLESS=1 WORKER_ISSUE_NUMBER= WORKER_REPO_SLUG= WORKER_WORKTREE_PATH=' "$HEADLESS_INVOCATION_LOG"; then
		print_result "triage dispatch excludes implementation-worker authority" 0
	else
		print_result "triage dispatch excludes implementation-worker authority" 1 \
			"headless invocation log:\n$(cat "$HEADLESS_INVOCATION_LOG")"
	fi
	if [[ ! -s "$TRIAGE_LIFECYCLE_LOG" ]]; then
		print_result "triage dispatch performs no implementation-worker lock lifecycle writes" 0
	else
		print_result "triage dispatch performs no implementation-worker lock lifecycle writes" 1 \
			"lifecycle calls:\n$(cat "$TRIAGE_LIFECYCLE_LOG")"
	fi
	teardown_test_env
}

test_recommendation_labels_map_exact_decisions() {
	setup_test_env
	load_helpers_under_test
	local approve_review="" feedback_review="" decline_review="" ok=0 detail=""
	approve_review=$(_valid_review_text)
	feedback_review=$(_valid_pr_review_text)
	decline_review="## Review: Recommendation: Decline"$'\n'"${approve_review#*$'\n'}"
	_set_triage_recommendation_label "29001" "owner/repo" "$approve_review" || ok=1
	_set_triage_recommendation_label "29002" "owner/repo" "$feedback_review" || ok=1
	_set_triage_recommendation_label "29003" "owner/repo" "$decline_review" || ok=1
	grep -q 'issue edit 29001 .*--add-label review:approve' "$GH_CALL_LOG" || {
		ok=1
		detail="${detail} approve-missing"
	}
	grep -q 'issue edit 29002 .*--add-label review:feedback' "$GH_CALL_LOG" || {
		ok=1
		detail="${detail} feedback-missing"
	}
	grep -q 'issue edit 29003 .*--add-label review:decline' "$GH_CALL_LOG" || {
		ok=1
		detail="${detail} decline-missing"
	}
	print_result "exact triage decisions map to canonical advisory labels" "$ok" "$detail"
	teardown_test_env
}

test_review_label_write_failure_blocks_comment_and_cache() {
	setup_test_env
	load_helpers_under_test
	local payload="${TEST_ROOT}/payload.json"
	_make_opencode_json "$payload" "$(_valid_review_text)"
	_install_headless_stub "$payload"
	MOCK_REVIEW_LABEL_WRITE_FAILURE=1
	local prompt_file="" ok=0 detail=""
	prompt_file=$(_make_managed_prompt_file "review-label-write")
	_dispatch_triage_review_worker \
		"29004" "owner/repo" "/tmp/repo" "$prompt_file" "hash-label-write" "" "issue" \
		"" "$EXPECTED_TEXT_SNAPSHOT_HASH" "$EXPECTED_PUBLIC_REVISION" 2>/dev/null
	if grep -q 'issue comment 29004' "$GH_CALL_LOG"; then
		ok=1
		detail="comment posted"
	fi
	if [[ -s "$TRIAGE_CACHE_LOG" ]]; then
		ok=1
		detail="${detail} cache/retry mutated"
	fi
	if ! grep -q 'github-review-label-write-failed' "$LOGFILE"; then
		ok=1
		detail="${detail} infrastructure classification missing"
	fi
	print_result "advisory label write failure suppresses comment and remains retryable" "$ok" "$detail"
	teardown_test_env
}

test_signature_failure_blocks_comment_transport() {
	setup_test_env
	load_helpers_under_test
	export TRIAGE_TEST_SIGNATURE_FAILURE=1
	local post_status=0
	_post_triage_review_comment "28705" "owner/repo" "$(_valid_review_text)" \
		|| post_status=$?
	unset TRIAGE_TEST_SIGNATURE_FAILURE

	local ok=0
	local detail=""
	if [[ "$post_status" -eq 0 ]]; then
		ok=1
		detail="signature failure returned success"
	fi
	if [[ -s "$GH_CALL_LOG" ]]; then
		ok=1
		detail="${detail} GitHub write attempted"
	fi
	if compgen -G "${AIDEVOPS_TEMP_DIR}/aidevops-triage-comment.*" >/dev/null; then
		ok=1
		detail="${detail} comment artifact retained"
	fi
	print_result "signature failure blocks ephemeral comment transport and cleans artifacts" \
		"$ok" "$detail"
	teardown_test_env
}

test_dispatch_rejects_issue_schema_for_pr() {
	setup_test_env
	load_helpers_under_test
	local payload="${TEST_ROOT}/payload.json"
	_make_opencode_json "$payload" "$(_valid_review_text)"
	_install_headless_stub "$payload"
	local prompt_file=""
	prompt_file=$(_make_managed_prompt_file "pr-shape")

	_dispatch_triage_review_worker \
		"18405" "owner/repo" "/tmp/repo" "$prompt_file" "hash-pr-shape" "" "pr" \
		"" "$EXPECTED_TEXT_SNAPSHOT_HASH" "$EXPECTED_PUBLIC_REVISION" \
		2>/dev/null

	local debug_log="${HOME}/.aidevops/logs/triage-review-debug.log"
	if ! grep -q 'issue comment 18405 --repo owner/repo --body' "$GH_CALL_LOG" && \
		[[ -f "$debug_log" ]] && grep -q 'failure_reason: invalid-review-shape' "$debug_log"; then
		print_result "PR dispatch rejects issue-only review schema" 0
	else
		print_result "PR dispatch rejects issue-only review schema" 1 \
			"gh calls:\n$(cat "$GH_CALL_LOG")"
	fi
	teardown_test_env
}

test_prelaunch_classifier_covers_runtime_guard_modes() {
	setup_test_env
	load_helpers_under_test

	local ok=0
	local sample=""
	local reason=""
	for sample in \
		'[fatal] WORKER_WORKTREE_PATH does not exist: /tmp/missing' \
		'[ownership-fence] incomplete worker ownership contract for issue #42: repo=owner/repo runner=missing' \
		'[fatal] worker ownership unavailable: worker_ownership_lost' \
		'[fatal] runtime ownership fence stopped before model launch' \
		'[WARN] OpenCode version drift: installed=1.2.3, pin=1.2.4 -- reinstalling' \
		'[fatal] opencode version mismatch: expected pinned runtime' \
		'[fatal] launch cwd is deleted and no valid fallback directory is available'; do
		reason=$(_triage_runtime_infra_failure_reason "$sample")
		[[ "$reason" == 'prelaunch-contract-failure' ]] || ok=1
	done

	for reason in github-comment-write-failed github-review-label-write-failed triage-runtime-failed \
		triage-runtime-temp-failed github-current-snapshot-changed-before-post \
		github-pr-revision-changed-before-post github-public-revision-changed-before-post \
		triage-evidence-too-large triage-prompt-too-large; do
		if ! _triage_failure_is_infrastructure "$reason"; then
			ok=1
			break
		fi
	done

	if [[ "$ok" -eq 0 ]]; then
		print_result "prelaunch classifier covers runtime guard failure modes" 0
	else
		print_result "prelaunch classifier covers runtime guard failure modes" 1 \
			"last sample='${sample}' reason='${reason}'"
	fi
	teardown_test_env
}

test_dispatch_suppresses_oversized_output() {
	setup_test_env
	load_helpers_under_test
	# Build a 25KB review that DOES have a ## Review header. The size
	# ceiling should catch it BEFORE the header check, tagging as
	# oversized-output.
	local long_body
	long_body="## Review: Needs Changes

$(python3 -c 'print("x" * 24000)')

More content..."
	local payload="${TEST_ROOT}/payload.json"
	_make_opencode_json "$payload" "$long_body"
	_install_headless_stub "$payload"

	local prompt_file=""
	prompt_file=$(_make_managed_prompt_file "oversized")

	_dispatch_triage_review_worker \
		"18401" "owner/repo" "/tmp/repo" "$prompt_file" "hash124" "" "issue" \
		"" "$EXPECTED_TEXT_SNAPSHOT_HASH" "$EXPECTED_PUBLIC_REVISION" \
		2>/dev/null

	# Must NOT have posted a review comment
	if grep -q 'issue comment 18401 --repo owner/repo --body' "$GH_CALL_LOG"; then
		print_result "dispatch suppresses oversized output (>20KB)" 1 \
			"gh issue comment was called despite oversized output"
		teardown_test_env
		return 0
	fi
	# Must have logged the oversized suppression
	if grep -q 'oversized output' "$LOGFILE"; then
		print_result "dispatch suppresses oversized output (>20KB)" 0
	else
		print_result "dispatch suppresses oversized output (>20KB)" 1 \
			"LOGFILE did not contain 'oversized output'
LOGFILE: $(cat "$LOGFILE")"
	fi
	# Debug log must exist and contain the failure_reason tag.
	local debug_log="${HOME}/.aidevops/logs/triage-review-debug.log"
	if [[ -f "$debug_log" ]] && grep -q 'failure_reason: oversized-output' "$debug_log"; then
		print_result "oversized suppression writes to debug log with correct tag" 0
	else
		print_result "oversized suppression writes to debug log with correct tag" 1 \
			"debug log missing or wrong content"
	fi
	teardown_test_env
}

test_dispatch_suppresses_headerless_json_output() {
	setup_test_env
	load_helpers_under_test
	# JSON output that does NOT contain `## Review:` anywhere in the text.
	local payload="${TEST_ROOT}/payload.json"
	_make_opencode_json "$payload" "I'll analyze this issue. Looking at the context, it seems reasonable. I recommend approving but I don't have a ## Review header here because the model drifted."
	_install_headless_stub "$payload"

	local prompt_file=""
	prompt_file=$(_make_managed_prompt_file "headerless")

	_dispatch_triage_review_worker \
		"18402" "owner/repo" "/tmp/repo" "$prompt_file" "hash125" "" "issue" \
		"" "$EXPECTED_TEXT_SNAPSHOT_HASH" "$EXPECTED_PUBLIC_REVISION" \
		2>/dev/null

	# Must NOT have posted a review comment
	if grep -q 'issue comment 18402 --repo owner/repo --body' "$GH_CALL_LOG"; then
		print_result "dispatch suppresses headerless JSON output" 1 \
			"gh issue comment was called despite missing ## Review header"
		teardown_test_env
		return 0
	fi
	# Strict validation rejects a response whose first line is not exact.
	local debug_log="${HOME}/.aidevops/logs/triage-review-debug.log"
	if [[ -f "$debug_log" ]] && grep -q 'failure_reason: invalid-review-first-line' "$debug_log"; then
		print_result "dispatch suppresses headerless JSON output with exact-first-line tag" 0
	else
		print_result "dispatch suppresses headerless JSON output with exact-first-line tag" 1 \
			"debug log content:
$(cat "$debug_log" 2>/dev/null || echo "<missing>")"
	fi
	teardown_test_env
}

test_dispatch_suppresses_raw_sandbox_output() {
	setup_test_env
	load_helpers_under_test
	# Raw (non-JSON) output containing infra markers — simulates the
	# attempt-3 failure mode on #18428.
	local payload="${TEST_ROOT}/payload.json"
	cat >"$payload" <<'RAW_EOF'
[SANDBOX] starting worker with timeout=300s network_blocked=true
[INFO] Executing opencode run --agent build-plus
/opt/homebrew/bin/opencode: loading config
UNTRUSTED_OUTPUT_SENTINEL_28705
Model response: error reading file
RAW_EOF
	_install_headless_stub "$payload"

	local prompt_file=""
	prompt_file=$(_make_managed_prompt_file "raw-output")

	_dispatch_triage_review_worker \
		"18403" "owner/repo" "/tmp/repo" "$prompt_file" "hash126" "" "issue" \
		"" "$EXPECTED_TEXT_SNAPSHOT_HASH" "$EXPECTED_PUBLIC_REVISION" \
		2>/dev/null

	# Must NOT have posted a review comment
	if grep -q 'issue comment 18403 --repo owner/repo --body' "$GH_CALL_LOG"; then
		print_result "dispatch suppresses raw sandbox output" 1 \
			"gh issue comment was called despite raw sandbox markers"
		teardown_test_env
		return 0
	fi
	local debug_log="${HOME}/.aidevops/logs/triage-review-debug.log"
	if [[ -f "$debug_log" ]] && grep -q 'failure_reason: raw-sandbox-output' "$debug_log"; then
		print_result "dispatch suppresses raw sandbox output with raw-sandbox-output tag" 0
	else
		print_result "dispatch suppresses raw sandbox output with raw-sandbox-output tag" 1 \
			"debug log content:
$(cat "$debug_log" 2>/dev/null || echo "<missing>")"
	fi
	# Suppression diagnostics retain metadata only; no raw or redacted sample is
	# durable because arbitrary public output is not safe diagnostic content.
	if [[ -f "$debug_log" ]] && \
		! grep -qE '/opt/homebrew|UNTRUSTED_OUTPUT_SENTINEL_28705|\[SANDBOX\]|sample_' "$debug_log"; then
		print_result "suppression debug log retains metadata without output content" 0
	else
		print_result "suppression debug log retains metadata without output content" 1 \
			"debug log retained raw or redacted output"
	fi
	teardown_test_env
}

test_prelaunch_contract_failure_is_infrastructure() {
	setup_test_env
	load_helpers_under_test
	_install_headless_contract_failure_stub

	local prompt_file=""
	prompt_file=$(_make_managed_prompt_file "contract")

	_dispatch_triage_review_worker \
		"23854" "owner/repo" "/tmp/repo" "$prompt_file" "hash-contract" "" "issue" \
		"" "$EXPECTED_TEXT_SNAPSHOT_HASH" "$EXPECTED_PUBLIC_REVISION" \
		2>/dev/null

	local debug_log="${HOME}/.aidevops/logs/triage-review-debug.log"
	if [[ ! -s "$debug_log" ]] && ! grep -q 'issue comment 23854' "$GH_CALL_LOG"; then
		print_result "prelaunch contract failure bypasses review parsing and posting" 0
	else
		print_result "prelaunch contract failure bypasses review parsing and posting" 1 \
			"debug log content:\n$(cat "$debug_log" 2>/dev/null || echo "<missing>")"
	fi

	if grep -q 'prelaunch-contract-failure' "$LOGFILE"; then
		print_result "prelaunch contract failure is classified as infrastructure" 0
	else
		print_result "prelaunch contract failure is classified as infrastructure" 1 \
			"LOGFILE:\n$(cat "$LOGFILE")"
	fi

	if [[ ! -s "$TRIAGE_CACHE_LOG" ]]; then
		print_result "prelaunch infrastructure failure does not consume triage cache or retry" 0
	else
		print_result "prelaunch infrastructure failure does not consume triage cache or retry" 1 \
			"cache log:\n$(cat "$TRIAGE_CACHE_LOG")"
	fi

	if ! grep -q -- '--add-label triage-failed' "$GH_CALL_LOG"; then
		print_result "prelaunch infrastructure failure does not add triage-failed" 0
	else
		print_result "prelaunch infrastructure failure does not add triage-failed" 1 \
			"gh calls:\n$(cat "$GH_CALL_LOG")"
	fi
	teardown_test_env
}

test_nonzero_runtime_with_valid_json_blocks_post_and_cache() {
	setup_test_env
	load_helpers_under_test
	local payload="${TEST_ROOT}/payload.json"
	_make_opencode_json "$payload" "$(_valid_review_text)"
	_install_headless_stub "$payload"
	export TRIAGE_TEST_RUNTIME_EXIT_STATUS=86
	local prompt_file=""
	prompt_file=$(_make_managed_prompt_file "runtime-failure")
	local prompt_dir="${prompt_file%/*}"

	_dispatch_triage_review_worker \
		"28705" "owner/repo" "/tmp/repo" "$prompt_file" \
		"hash-runtime-failure" "" "issue" "" "$EXPECTED_TEXT_SNAPSHOT_HASH" \
		"$EXPECTED_PUBLIC_REVISION" \
		2>/dev/null
	unset TRIAGE_TEST_RUNTIME_EXIT_STATUS

	local ok=0
	local detail=""
	if grep -q 'issue comment 28705' "$GH_CALL_LOG"; then
		ok=1
		detail="comment posted"
	fi
	if [[ -s "$TRIAGE_CACHE_LOG" ]]; then
		ok=1
		detail="${detail} cache/retry mutated"
	fi
	if ! grep -q 'triage-runtime-failed' "$LOGFILE"; then
		ok=1
		detail="${detail} runtime failure not classified"
	fi
	if [[ -e "$prompt_dir" ]]; then
		ok=1
		detail="${detail} runtime artifacts retained"
	fi
	print_result "non-zero runtime with valid JSON blocks post and cache" "$ok" "$detail"
	teardown_test_env
}

test_review_artifact_cleanup_failure_blocks_post_and_cache() {
	setup_test_env
	load_helpers_under_test
	local payload="${TEST_ROOT}/payload.json"
	_make_opencode_json "$payload" "$(_valid_review_text)"
	_install_headless_stub "$payload"
	local prompt_file=""
	prompt_file=$(_make_managed_prompt_file "cleanup-failure")
	_triage_cleanup_sensitive_artifact_dir() {
		local artifact_dir="$1"
		: "$artifact_dir"
		return 1
	}

	local dispatch_status=0
	_dispatch_triage_review_worker \
		"28706" "owner/repo" "/tmp/repo" "$prompt_file" \
		"hash-cleanup-failure" "" "issue" "" "$EXPECTED_TEXT_SNAPSHOT_HASH" \
		"$EXPECTED_PUBLIC_REVISION" \
		2>/dev/null || dispatch_status=$?

	local ok=0
	local detail=""
	if [[ "$dispatch_status" -ne 0 ]]; then
		ok=1
		detail="dispatch_status=${dispatch_status}"
	fi
	if grep -q 'issue comment 28706' "$GH_CALL_LOG"; then
		ok=1
		detail="comment posted"
	fi
	if [[ -s "$TRIAGE_CACHE_LOG" ]]; then
		ok=1
		detail="${detail} cache/retry mutated"
	fi
	if ! grep -q 'triage-runtime-temp-failed' "$LOGFILE"; then
		ok=1
		detail="${detail} cleanup failure not classified"
	fi
	print_result "review artifact cleanup failure blocks post and cache" "$ok" "$detail"
	teardown_test_env
}

test_pr_revision_change_before_post_blocks_comment_and_cache() {
	setup_test_env
	load_helpers_under_test
	local payload="${TEST_ROOT}/payload.json"
	_make_opencode_json "$payload" "$(_valid_pr_review_text)"
	_install_headless_stub "$payload"
	local prompt_file=""
	prompt_file=$(_make_managed_prompt_file "revision-change")
	local base_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	local reviewed_head="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	local current_head="cccccccccccccccccccccccccccccccccccccccc"
	MOCK_PR_REVISION_PAIR="${base_sha}:${current_head}"

	_dispatch_triage_review_worker \
		"28707" "owner/repo" "/tmp/repo" "$prompt_file" \
		"hash-revision-change" "" "pr" "${base_sha}:${reviewed_head}" \
		"$EXPECTED_TEXT_SNAPSHOT_HASH" "$reviewed_head" \
		2>/dev/null

	local ok=0
	local detail=""
	if grep -q 'issue comment 28707' "$GH_CALL_LOG"; then
		ok=1
		detail="comment posted"
	fi
	if [[ -s "$TRIAGE_CACHE_LOG" ]]; then
		ok=1
		detail="${detail} cache/retry mutated"
	fi
	if ! grep -q 'github-pr-revision-changed-before-post' "$LOGFILE"; then
		ok=1
		detail="${detail} revision race not classified"
	fi
	print_result "PR revision change immediately before post blocks comment and cache" \
		"$ok" "$detail"
	teardown_test_env
}

test_issue_text_change_before_post_blocks_comment_and_cache() {
	setup_test_env
	load_helpers_under_test
	local payload="${TEST_ROOT}/payload.json"
	_make_opencode_json "$payload" "$(_valid_review_text)"
	_install_headless_stub "$payload"
	local prompt_file=""
	prompt_file=$(_make_managed_prompt_file "text-snapshot-change")
	MOCK_CURRENT_TEXT_SNAPSHOT_HASH="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

	_dispatch_triage_review_worker \
		"28708" "owner/repo" "/tmp/repo" "$prompt_file" \
		"hash-text-snapshot-change" "" "issue" "" \
		"$EXPECTED_TEXT_SNAPSHOT_HASH" "$EXPECTED_PUBLIC_REVISION" 2>/dev/null

	local ok=0
	local detail=""
	if grep -q 'issue comment 28708' "$GH_CALL_LOG"; then
		ok=1
		detail="comment posted"
	fi
	if [[ -s "$TRIAGE_CACHE_LOG" ]]; then
		ok=1
		detail="${detail} cache/retry mutated"
	fi
	if ! grep -q 'github-current-snapshot-changed-before-post' "$LOGFILE"; then
		ok=1
		detail="${detail} text snapshot race not classified"
	fi
	print_result "issue or PR text change immediately before post blocks comment and cache" \
		"$ok" "$detail"
	teardown_test_env
}

test_issue_public_revision_change_before_post_blocks_comment_and_cache() {
	setup_test_env
	load_helpers_under_test
	local payload="${TEST_ROOT}/payload.json"
	_make_opencode_json "$payload" "$(_valid_review_text)"
	_install_headless_stub "$payload"
	local prompt_file=""
	prompt_file=$(_make_managed_prompt_file "public-revision-change")
	MOCK_CURRENT_PUBLIC_REVISION="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

	_dispatch_triage_review_worker \
		"28709" "owner/repo" "/tmp/repo" "$prompt_file" \
		"hash-public-revision-change" "" "issue" "" \
		"$EXPECTED_TEXT_SNAPSHOT_HASH" "$EXPECTED_PUBLIC_REVISION" 2>/dev/null

	local ok=0
	local detail=""
	if grep -q 'issue comment 28709' "$GH_CALL_LOG"; then
		ok=1
		detail="comment posted"
	fi
	if [[ -s "$TRIAGE_CACHE_LOG" ]]; then
		ok=1
		detail="${detail} cache/retry mutated"
	fi
	if ! grep -q 'github-public-revision-changed-before-post' "$LOGFILE"; then
		ok=1
		detail="${detail} public revision race not classified"
	fi
	print_result "issue evidence revision change immediately before post blocks comment and cache" \
		"$ok" "$detail"
	teardown_test_env
	return 0
}

test_comment_write_failure_is_infrastructure() {
	setup_test_env
	load_helpers_under_test
	local payload="${TEST_ROOT}/payload.json"
	_make_opencode_json "$payload" "$(_valid_review_text)"
	_install_headless_stub "$payload"
	MOCK_COMMENT_WRITE_FAILURE=1

	local prompt_file=""
	prompt_file=$(_make_managed_prompt_file "comment-write")
	_dispatch_triage_review_worker \
		"28705" "owner/repo" "/tmp/repo" "$prompt_file" "hash-comment-write" "" "issue" \
		"" "$EXPECTED_TEXT_SNAPSHOT_HASH" "$EXPECTED_PUBLIC_REVISION" \
		2>/dev/null

	local ok=0
	local detail=""
	if ! grep -q 'github-comment-write-failed' "$LOGFILE"; then
		ok=1
		detail="infrastructure classification missing"
	fi
	if ! grep -q -- '--remove-label triage-failed' "$GH_CALL_LOG"; then
		ok=1
		detail="${detail} stale triage-failed not removed"
	fi
	if grep -q -- '--add-label triage-failed' "$GH_CALL_LOG"; then
		ok=1
		detail="${detail} triage-failed added"
	fi
	if [[ -s "$TRIAGE_CACHE_LOG" ]]; then
		ok=1
		detail="${detail} retry/cache budget consumed"
	fi
	print_result "comment write failure is infrastructure and clears stale triage state" "$ok" "$detail"
	teardown_test_env
}

test_post_escalation_handles_oversized_reason() {
	setup_test_env
	load_helpers_under_test
	# MOCK_COMMENTS_MARKER_COUNT was used in the t2016 test; we
	# redefine gh here to always return 0 (no existing marker) so the
	# escalation helper posts a comment.
	gh() {
		printf '%s\n' "$*" >>"$GH_CALL_LOG"
		case "${1:-}" in
		api)
			printf '0\n'
			return 0
			;;
		esac
		return 0
	}
	export -f gh
	_post_triage_escalation_comment "18404" "owner/repo" "oversized-output" 1 25000
	if grep -q '^issue comment 18404 --repo owner/repo --body-file' "$GH_CALL_LOG"; then
		print_result "_post_triage_escalation_comment accepts oversized-output reason and posts" 0
	else
		print_result "_post_triage_escalation_comment accepts oversized-output reason and posts" 1 \
			"gh call log did not contain issue comment invocation"
	fi
	teardown_test_env
}

main() {
	test_extract_opencode_json_returns_text
	test_extract_claude_stream_json_returns_text
	test_extract_plain_text_fallback
	test_extract_concats_multiple_text_events
	test_review_shape_enforces_exact_contract
	test_dispatch_accepts_clean_review_in_json
	test_recommendation_labels_map_exact_decisions
	test_review_label_write_failure_blocks_comment_and_cache
	test_signature_failure_blocks_comment_transport
	test_dispatch_rejects_issue_schema_for_pr
	test_dispatch_suppresses_oversized_output
	test_dispatch_suppresses_headerless_json_output
	test_dispatch_suppresses_raw_sandbox_output
	test_prelaunch_classifier_covers_runtime_guard_modes
	test_prelaunch_contract_failure_is_infrastructure
	test_nonzero_runtime_with_valid_json_blocks_post_and_cache
	test_review_artifact_cleanup_failure_blocks_post_and_cache
	test_pr_revision_change_before_post_blocks_comment_and_cache
	test_issue_text_change_before_post_blocks_comment_and_cache
	test_issue_public_revision_change_before_post_blocks_comment_and_cache
	test_comment_write_failure_is_infrastructure
	test_post_escalation_handles_oversized_reason

	echo ""
	echo "Results: ${TESTS_RUN} tests, $((TESTS_RUN - TESTS_FAILED)) passed, ${TESTS_FAILED} failed"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
