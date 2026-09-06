#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#30926 unchanged terminal-blocker suppression.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TESTS_RUN=0
TESTS_FAILED=0
TEST_DEPENDENCIES='{"nodes":[],"truncated":false}'
TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

print_result() {
	local name="$1"
	local status="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# shellcheck source=../terminal-blocker-circuit.sh
source "${SCRIPT_DIR}/terminal-blocker-circuit.sh"
# shellcheck source=../headless-runtime-failure.sh
source "${SCRIPT_DIR}/headless-runtime-failure.sh"

_terminal_blocker_dependency_signature() {
	local repo_slug="$1"
	local issue_number="$2"
	[[ -n "$repo_slug" && "$issue_number" =~ ^[0-9]+$ ]] || return 1
	[[ "$TEST_DEPENDENCIES" != "unavailable" ]] || return 1
	printf '%s\n' "$TEST_DEPENDENCIES"
	return 0
}

_terminal_blocker_target_revision() {
	local repo_path="$1"
	[[ -n "$repo_path" && "$TEST_TARGET_REVISION" != "unavailable" ]] || return 1
	printf '%s\n' "$TEST_TARGET_REVISION"
	return 0
}

test_normalized_blocker_fingerprint() {
	local first_output="${TEST_ROOT}/first.ndjson"
	local second_output="${TEST_ROOT}/second.ndjson"
	gh() { printf '%s\n' '{"body":"## How\nFix the helper"}'; return 0; }
	export WORKER_ISSUE_NUMBER=42 DISPATCH_REPO_SLUG="owner/repo"
	printf '%s\n' '{"type":"text","text":"BLOCKED: Canonical Files Scope heading is absent. runner=alpha session=ses_123"}' >"$first_output"
	printf '%s\n' '{"type":"text","text":"BLOCKED: Cannot edit until the brief declares permitted files. runner=beta attempt=two"}' >"$second_output"
	terminal_blocker_capture_output "$first_output"
	local first_fingerprint="$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
	terminal_blocker_capture_output "$second_output"
	local second_fingerprint="$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
	local status=1
	if [[ "$(_terminal_blocker_reason "$first_fingerprint")" == "missing_files_scope" && "$first_fingerprint" == "$second_fingerprint" ]]; then
		status=0
	fi
	unset -f gh
	unset WORKER_ISSUE_NUMBER DISPATCH_REPO_SLUG AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	print_result "different prose and runner identities converge on verified missing scope" "$status"
	return 0
}

test_worker_contract_reason_protocol() {
	# Load the real producer in a subshell so its sourced libraries cannot alter
	# the release-path fixture overrides used by the remaining tests.
	local contract="" reason="" output="${TEST_ROOT}/contract.ndjson" status=0
	contract=$(
		# shellcheck source=../headless-runtime-lib.sh
		source "${SCRIPT_DIR}/headless-runtime-lib.sh"
		append_worker_headless_contract '/full-loop Fix the scoped helper'
	) || status=1
	reason=$(printf '%s\n' "$contract" | rg '^TERMINAL_BLOCKER_REASON=target_code_blocker$') || status=1
	[[ "$contract" == *'TERMINAL_BLOCKER_REASON=missing_files_scope'* &&
		"$contract" == *'SAME final assistant text message'* &&
		"$contract" == *'unknown evidence stays retryable'* ]] || status=1
	jq -nc --arg text "BLOCKED: target defect cannot be repaired in scope
${reason}" '{type:"text",part:{text:$text}}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == target_code_blocker ]] || status=1
	local issue='{"title":"Fix helper","body":"### Files Scope\n- helper.sh"}'
	local revision="" changed="" comments=""
	revision=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT")
	comments=$(jq -nc --arg body "<!-- aidevops:terminal-blocker-circuit revision=${revision} blocker=${AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT} -->" \
		'[{body:$body,created_at:"2026-08-31T10:00:00Z",author_association:"MEMBER"}]')
	terminal_blocker_circuit_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || status=1
	TEST_TARGET_REVISION='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
	changed=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT")
	[[ "$changed" != "$revision" ]] || status=1
	terminal_blocker_circuit_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	unset AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	print_result "injected contract reason reaches capture and code-sensitive hold re-arms on target change" "$status"
	return 0
}

test_task_revision_inputs() {
	local issue_json='{"title":"Fix scope","body":"Files Scope: a.sh"}'
	local first="" same="" changed_body="" changed_dependency="" changed_target=""
	first=$(terminal_blocker_task_revision "$issue_json" "owner/repo" 42 "$TEST_ROOT")
	same=$(terminal_blocker_task_revision "$issue_json" "owner/repo" 42 "$TEST_ROOT")
	changed_body=$(terminal_blocker_task_revision '{"title":"Fix scope","body":"Files Scope: b.sh"}' "owner/repo" 42 "$TEST_ROOT")
	TEST_DEPENDENCIES='{"nodes":[{"number":9,"state":"CLOSED"}],"truncated":false}'
	changed_dependency=$(terminal_blocker_task_revision "$issue_json" "owner/repo" 42 "$TEST_ROOT")
	TEST_DEPENDENCIES='{"nodes":[],"truncated":false}'
	TEST_TARGET_REVISION='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
	changed_target=$(terminal_blocker_task_revision "$issue_json" "owner/repo" 42 "$TEST_ROOT")
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	local status=1
	if [[ "$first" == "$same" && "$first" != "$changed_body" &&
		"$first" != "$changed_dependency" && "$first" != "$changed_target" ]]; then
		status=0
	fi
	print_result "task revision binds brief, dependency state, and target revision" "$status"
	return 0
}

test_release_modes_and_retry() {
	local revision='111111111111111111111111'
	local blocker=""
	blocker=$(_terminal_blocker_hash 'v2:target_code_blocker')
	local observation="<!-- aidevops:terminal-blocker-observation revision=${revision} blocker=${blocker} -->"
	local circuit="<!-- aidevops:terminal-blocker-circuit revision=${revision} blocker=${blocker} -->"
	local empty='[]'
	local observed="[{\"body\":\"${observation}\",\"created_at\":\"2026-08-31T10:00:00Z\"}]"
	local opened="[{\"body\":\"${observation}\",\"created_at\":\"2026-08-31T10:00:00Z\"},{\"body\":\"${circuit}\",\"created_at\":\"2026-08-31T10:05:00Z\"}]"
	local retried="[{\"body\":\"${observation}\",\"created_at\":\"2026-08-31T10:00:00Z\"},{\"body\":\"${circuit}\",\"created_at\":\"2026-08-31T10:05:00Z\"},{\"body\":\"terminal-blocker-circuit:retry\",\"created_at\":\"2026-08-31T10:10:00Z\",\"author_association\":\"OWNER\"}]"
	observed=$(printf '%s' "$observed" | jq -c 'map(.author_association="OWNER")')
	opened=$(printf '%s' "$opened" | jq -c 'map(.author_association="OWNER")')
	retried=$(printf '%s' "$retried" | jq -c 'map(.author_association="OWNER")')
	local status=1
	if [[ "$(terminal_blocker_release_mode "$empty" "$revision" "$blocker")" == "first" &&
	"$(terminal_blocker_release_mode "$observed" "$revision" "$blocker")" == "circuit" &&
	"$(terminal_blocker_release_mode "$opened" "$revision" "$blocker")" == "open" &&
	"$(terminal_blocker_release_mode "$retried" "$revision" "$blocker")" == "first" ]]; then
		status=0
	fi
	print_result "second identical blocker opens a durable hold and maintainer retry re-arms it" "$status"
	return 0
}

test_dispatch_hold_revalidates_revision() {
	local issue_json='{"title":"Fix scope","body":"Files Scope: a.sh"}'
	local revision=""
	revision=$(terminal_blocker_task_revision "$issue_json" "owner/repo" 42 "$TEST_ROOT")
	local blocker=""
	blocker=$(_terminal_blocker_hash 'v2:target_code_blocker')
	local comments="[{\"body\":\"<!-- aidevops:terminal-blocker-circuit revision=${revision} blocker=${blocker} -->\",\"created_at\":\"2026-08-31T10:05:00Z\",\"author_association\":\"MEMBER\"}]"
	local same_status=0 changed_status=0 ambiguous_status=0
	terminal_blocker_circuit_active "$comments" "$issue_json" "owner/repo" 42 "$TEST_ROOT" >/dev/null || same_status=$?
	terminal_blocker_circuit_active "$comments" '{"title":"Fix scope","body":"Files Scope: b.sh"}' \
		"owner/repo" 42 "$TEST_ROOT" >/dev/null && changed_status=1
	TEST_DEPENDENCIES="unavailable"
	terminal_blocker_circuit_active "$comments" "$issue_json" "owner/repo" 42 "$TEST_ROOT" >/dev/null && ambiguous_status=1
	TEST_DEPENDENCIES='{"nodes":[],"truncated":false}'
	local status=1
	if [[ "$same_status" -eq 0 && "$changed_status" -eq 0 && "$ambiguous_status" -eq 0 ]]; then
		status=0
	fi
	print_result "dispatch hold is cross-runner durable but fails open on changed or ambiguous identity" "$status"
	return 0
}

test_release_integration_bounds_comments() {
	local test_comments='[]'
	local posted_count=0 first_body="" second_body="" cleanup_count=0
	terminal_blocker_fetch_trusted_comments() {
		local issue_number="$1"
		local repo_slug="$2"
		[[ "$issue_number" == "42" && "$repo_slug" == "owner/repo" ]] || return 1
		printf '%s\n' "$test_comments"
		return 0
	}
	_hrff_release_repo_state_is_managed() { return 0; }
	_hrff_resolve_release_runner_login() {
		printf 'runner-one\n'
		return 0
	}
	clear_active_status_on_release() {
		cleanup_count=$((cleanup_count + 1))
		return 0
	}
	_unlock_issue_after_dispatch_release() {
		cleanup_count=$((cleanup_count + 1))
		return 0
	}
	gh() {
		if [[ "$1" == "api" && "$2" == "repos/owner/repo/issues/42" ]]; then
			printf '%s\n' '{"title":"Fix scope","body":"Files Scope: a.sh"}'
			return 0
		fi
		return 1
	}
	_hrff_post_claim_released_comment() {
		local issue_number="$1"
		local repo_slug="$2"
		local body="$3"
		[[ "$issue_number" == "42" && "$repo_slug" == "owner/repo" ]] || return 1
		posted_count=$((posted_count + 1))
		if [[ "$posted_count" -eq 1 ]]; then
			first_body="$body"
		else
			second_body="$body"
		fi
		local created_at="2026-08-31T10:0${posted_count}:00Z"
		test_comments=$(printf '%s' "$test_comments" | jq -c \
			--arg body "$body" --arg created_at "$created_at" \
			'. + [{body: $body, created_at: $created_at, author_association: "MEMBER"}]')
		return 0
	}

	export DISPATCH_REPO_SLUG="owner/repo"
	export WORKER_ISSUE_NUMBER=42
	export AIDEVOPS_TERMINAL_BLOCKER_REPO_PATH="$TEST_ROOT"
	AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=$(_terminal_blocker_hash 'v2:target_code_blocker')
	export AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	_release_dispatch_claim "issue-42" "blocked"
	_release_dispatch_claim "issue-42" "blocked"
	_release_dispatch_claim "issue-42" "blocked"

	local status=1
	if [[ "$posted_count" -eq 2 && "$first_body" == *"aidevops:terminal-blocker-observation"* &&
		"$second_body" == *"TERMINAL_BLOCKER_CIRCUIT active=true observations=2"* &&
		"$second_body" == *"CLAIM_RELEASED reason=blocked"* && "$cleanup_count" -eq 6 ]]; then
		status=0
	fi
	print_result "release path posts one observation and one circuit comment across repeated blockers" "$status"
	test_comments='[]'
	posted_count=0
	cleanup_count=0
	AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=$(_terminal_blocker_hash 'v2:unknown')
	_release_dispatch_claim "issue-42" "blocked"
	_release_dispatch_claim "issue-42" "blocked"
	_release_dispatch_claim "issue-42" "blocked"
	status=1
	if [[ "$posted_count" -eq 3 && "$cleanup_count" -eq 6 &&
		"$first_body" == *'reason=unknown owner=worker-triage'* &&
		"$second_body" == *'CLAIM_RELEASED reason=blocked'* && "$second_body" != *'Next action:'* ]]; then
		status=0
	fi
	print_result "unknown repeat releases each claim without repeating recovery prose or holding dispatch" "$status"
	unset DISPATCH_REPO_SLUG WORKER_ISSUE_NUMBER AIDEVOPS_TERMINAL_BLOCKER_REPO_PATH \
		AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	return 0
}

test_brief_only_revision() {
	local issue='{"title":"Fix helper","body":"## How\nFix helper"}'
	local first="" changed="" blocker="" comments="" status=0
	blocker=$(_terminal_blocker_hash 'v2:missing_files_scope')
	first=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" missing_files_scope)
	TEST_TARGET_REVISION='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
	TEST_DEPENDENCIES='unavailable'
	changed=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" missing_files_scope)
	[[ "$first" == "$changed" ]] || status=1
	comments=$(jq -nc --arg body "<!-- aidevops:terminal-blocker-circuit revision=${first} blocker=${blocker} -->" \
		'[{body:$body,created_at:"2026-08-31T10:00:00Z",author_association:"MEMBER"}]')
	terminal_blocker_circuit_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || status=1
	terminal_blocker_circuit_active "$comments" '{"title":"Fix helper","body":"### Files Scope\n- helper.sh"}' \
		owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	comments=$(printf '%s' "$comments" | jq -c '. + [{body:"terminal-blocker-circuit:retry",created_at:"2026-08-31T11:00:00Z",author_association:"MEMBER"}]')
	terminal_blocker_circuit_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	TEST_DEPENDENCIES='{"nodes":[],"truncated":false}'
	print_result "brief hold ignores target/dependency changes but corrected brief and trusted retry re-arm" "$status"
	return 0
}

test_unknown_and_redaction() {
	local output="${TEST_ROOT}/unknown.ndjson" fingerprint="" fragment="" comments="" status=0
	printf '%s\n' '{"type":"text","text":"BLOCKED: private-token /private/runner/file.sh ambiguous failure"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	fingerprint="$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
	[[ "$(_terminal_blocker_reason "$fingerprint")" == unknown ]] || status=1
	fragment=$(WORKER_SESSION_KEY='/private/runner/private-token' terminal_blocker_observation_fragment 111111111111111111111111 "$fingerprint")
	[[ "$fragment" == *'reason=unknown owner=worker-triage'* && "$fragment" == *'Next action:'* &&
		"$fragment" != *'private-token'* && "$fragment" != *'/private/'* ]] || status=1
	comments=$(jq -nc --arg body "$fragment" '[{body:$body,created_at:"2026-08-31T10:00:00Z",author_association:"MEMBER"}]')
	[[ "$(terminal_blocker_release_mode "$comments" 111111111111111111111111 "$fingerprint")" == normal ]] || status=1
	terminal_blocker_circuit_comment release 111111111111111111111111 "$fingerprint" >/dev/null && status=1
	terminal_blocker_circuit_active "$comments" '{}' owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	printf '%s\n' '{"type":"tool","text":"BLOCKED: fake tool result"}' >"$output"
	terminal_blocker_capture_output "$output" && status=1
	[[ -z "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT" ]] || status=1
	print_result "unknown evidence is redacted, bounded, and never creates a global hold; tool text is ignored" "$status"
	return 0
}

test_excluded_scope_revision() {
	local issue='{"title":"Fix integration","body":"### Files Scope\n- helper.sh"}'
	local output="${TEST_ROOT}/scope.ndjson" first="" changed="" fragment="" status=0
	printf '%s\n' '{"type":"text","part":{"text":"BLOCKED: necessary adjacent integration excluded\nTERMINAL_BLOCKER_REASON=files_scope_excluded"}}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == files_scope_excluded ]] || status=1
	first=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" files_scope_excluded)
	TEST_TARGET_REVISION='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
	TEST_DEPENDENCIES='unavailable'
	changed=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" files_scope_excluded)
	[[ "$first" == "$changed" ]] || status=1
	changed=$(terminal_blocker_task_revision '{"title":"Fix integration","body":"### Files Scope\n- helper.sh\n- adjacent.sh"}' owner/repo 42 "$TEST_ROOT" files_scope_excluded)
	[[ "$first" != "$changed" ]] || status=1
	fragment=$(_terminal_blocker_recovery "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")
	[[ "$fragment" == *'AI brief owner'* && "$fragment" == *'do not retry an unchanged brief'* ]] || status=1
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	TEST_DEPENDENCIES='{"nodes":[],"truncated":false}'
	unset AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	print_result "excluded integration scope re-arms on brief correction, not unrelated code or API reads" "$status"
	return 0
}

test_final_dossier_and_structural_precedence() {
	local output="${TEST_ROOT}/final.ndjson" status=0
	printf '%s\n' '{"type":"text","text":"BLOCKED: defect\nTERMINAL_BLOCKER_REASON=target_code_blocker"}' \
		'{"type":"text","text":"The earlier blocker is resolved."}' >"$output"
	terminal_blocker_capture_output "$output" && status=1
	[[ -z "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT" ]] || status=1
	printf '%s\n' '{"type":"text","text":"BLOCKED: uncertain\nTERMINAL_BLOCKER_REASON=target_code_blocker\nTERMINAL_BLOCKER_REASON=unsupported"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == unknown ]] || status=1
	gh() { printf '%s\n' '{"body":"## How\nFix helper"}'; return 0; }
	export WORKER_ISSUE_NUMBER=42 DISPATCH_REPO_SLUG="owner/repo"
	printf '%s\n' '{"type":"text","text":"BLOCKED: defect\nTERMINAL_BLOCKER_REASON=target_code_blocker"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == missing_files_scope ]] || status=1
	unset -f gh
	unset WORKER_ISSUE_NUMBER DISPATCH_REPO_SLUG AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	print_result "resolved dossiers and mixed reasons cannot hold; verified missing scope takes precedence" "$status"
	return 0
}

test_legacy_blocked_backoff() {
	local comments="" changed="" result="" status=0
	# No local metrics, fingerprints or task revision: reproduce legacy releases
	# by two runners, as seen on GH#31378. Exercise the actual dispatch gate.
	comments=$(jq -nc '[range(2) | {id:(. + 1), body:("<!-- ops:start -->\nCLAIM_RELEASED reason=blocked runner=runner-" + tostring + " ts=ignored\n<!-- ops:end -->"), author:("runner-" + tostring), author_association:"MEMBER", created_at:"2026-09-06T12:00:00Z"}]')
	result=$(TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_circuit_active "$comments" '{}' owner/repo 42 '') || status=1
	[[ "$result" == 'TERMINAL_BLOCKER_BACKOFF failures=2 retry_after=1788696900' ]] || status=1
	TERMINAL_BLOCKER_NOW_EPOCH=1788696900 terminal_blocker_backoff_active "$comments" >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c '.[0:1]')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [{body:"terminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-09-06T12:00:01Z"}]')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696002 terminal_blocker_backoff_active "$changed" >/dev/null && status=1
	changed=$(jq -nc '[range(400) | {body:"CLAIM_RELEASED reason=blocked runner=runner ts=ignored",author:"runner",author_association:"OWNER",created_at:"2026-09-06T12:00:00Z"}]')
	result=$(TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed") || status=1
	[[ "$result" == 'TERMINAL_BLOCKER_BACKOFF failures=400 retry_after=1788782400' ]] || status=1
	TERMINAL_BLOCKER_NOW_EPOCH=1788782400 terminal_blocker_backoff_active "$changed" >/dev/null && status=1
	print_result "legacy blocked releases impose cross-runner exponential backoff with expiry, cap and trusted retry" "$status"
	return 0
}

test_blocked_backoff_trust() {
	local comments="" changed="" association="" status=0
	comments=$(jq -nc '[range(2) | {body:"CLAIM_RELEASED reason=blocked runner=runner ts=ignored",author:"runner",author_association:"OWNER",created_at:"2026-09-06T12:00:00Z"}]')
	for association in COLLABORATOR CONTRIBUTOR NONE; do
		changed=$(printf '%s' "$comments" | jq -c --arg association "$association" 'map(.author_association=$association)')
		TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null && status=1
	done
	changed=$(printf '%s' "$comments" | jq -c 'map(.author="impostor")')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c 'map(.body="> " + .body)')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null && status=1
	TERMINAL_BLOCKER_NOW_EPOCH=1788695999 terminal_blocker_backoff_active "$comments" >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c 'map(.created_at="invalid")')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [{body:"terminal-blocker-circuit:retry",author_association:"COLLABORATOR",created_at:"2026-09-06T12:00:01Z"}]')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696002 terminal_blocker_backoff_active "$changed" >/dev/null || status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [{body:"A maintainer can post terminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-09-06T12:00:01Z"}]')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696002 terminal_blocker_backoff_active "$changed" >/dev/null || status=1
	print_result "backoff rejects untrusted, forged, quoted, invalid and future evidence; recovery prose cannot reset it" "$status"
	return 0
}

test_permission_blocker_continuation() {
	local output="${TEST_ROOT}/permission.ndjson" status=0 fingerprint="" revision="" changed="" comments="" contract=""
	contract=$(
		# shellcheck source=../headless-runtime-lib.sh
		source "${SCRIPT_DIR}/headless-runtime-lib.sh"
		append_worker_headless_contract '/full-loop Resume after source denial'
	) || status=1
	[[ "$contract" == *'TERMINAL_BLOCKER_REASON=permission_required'* ]] || status=1
	printf '%s\n' '{"type":"text","part":{"text":"BLOCKED: prior protected-source denial has no changed exact-context grant\nTERMINAL_BLOCKER_REASON=permission_required"}}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	fingerprint="$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
	[[ "$(_terminal_blocker_reason "$fingerprint")" == permission_required ]] || status=1
	revision=$(terminal_blocker_task_revision '{}' owner/repo 42 '') || status=1
	TEST_DEPENDENCIES=unavailable
	TEST_TARGET_REVISION=unavailable
	changed=$(terminal_blocker_task_revision '{"body":"changed brief"}' owner/repo 42 '') || status=1
	[[ "$revision" == "$changed" ]] || status=1
	comments=$(jq -nc --arg body "<!-- aidevops:terminal-blocker-circuit revision=${revision} blocker=${fingerprint} -->" '[{body:$body,created_at:"2026-09-06T12:00:00Z",author_association:"OWNER"}]')
	terminal_blocker_circuit_active "$comments" '{}' owner/repo 42 '' >/dev/null || status=1
	terminal_blocker_circuit_active "$comments" '{}' owner/repo 43 '' >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c 'map(.author_association="COLLABORATOR")')
	terminal_blocker_circuit_active "$changed" '{}' owner/repo 42 '' >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [.[0] | .author_association="COLLABORATOR" | .created_at="2026-09-06T12:00:30Z" | .body |= sub("revision=[a-f0-9]+"; "revision=aaaaaaaaaaaaaaaaaaaaaaaa")]')
	terminal_blocker_circuit_active "$changed" '{}' owner/repo 42 '' >/dev/null || status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [{body:"terminal-blocker-circuit:retry",created_at:"2026-09-06T12:01:00Z",author_association:"COLLABORATOR"}]')
	terminal_blocker_circuit_active "$changed" '{}' owner/repo 42 '' >/dev/null || status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [{body:"Please post terminal-blocker-circuit:retry",created_at:"2026-09-06T12:01:00Z",author_association:"OWNER"}]')
	terminal_blocker_circuit_active "$changed" '{}' owner/repo 42 '' >/dev/null || status=1
	local tied="" variant="" id=""
	tied=$(printf '%s' "$comments" | jq -c '.[0].id=10 | . + [{id:11,body:"terminal-blocker-circuit:retry",created_at:.[0].created_at,author_association:"OWNER"}]')
	terminal_blocker_circuit_active "$tied" '{}' owner/repo 42 '' >/dev/null && status=1
	[[ "$(terminal_blocker_release_mode "$tied" "$revision" "$fingerprint")" == first ]] || status=1
	variant=$(printf '%s' "$tied" | jq -c 'reverse')
	terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null && status=1
	variant=$(printf '%s' "$tied" | jq -c '.[0].id=12')
	terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null || status=1
	[[ "$(terminal_blocker_release_mode "$variant" "$revision" "$fingerprint")" == open ]] || status=1
	variant=$(printf '%s' "$tied" | jq -c '. + [.[0] | .id=12] | reverse')
	terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null || status=1
	variant=$(printf '%s' "$tied" | jq -c '. + [.[1] | .id=9] | reverse')
	terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null && status=1
	[[ "$(_terminal_blocker_latest_retry_at "$variant")" == '2026-09-06T12:00:00Z' ]] || status=1
	# Missing, malformed and equal IDs cannot prove that a tied retry is later.
	for id in null '"11"' -1 11.5 9007199254740992 10; do
		variant=$(printf '%s' "$tied" | jq -c --argjson id "$id" '.[1].id=$id')
		terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null || status=1
		[[ "$(terminal_blocker_release_mode "$variant" "$revision" "$fingerprint")" == open ]] || status=1
	done
	variant=$(printf '%s' "$tied" | jq -c 'del(.[0].id)')
	terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null || status=1
	variant=$(printf '%s' "$tied" | jq -c '.[1].author_association="COLLABORATOR"')
	terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null || status=1
	variant=$(printf '%s' "$tied" | jq -c '.[1].body="> terminal-blocker-circuit:retry"')
	terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null || status=1
	variant=$(printf '%s' "$tied" | jq -c '.[1].created_at="invalid"')
	terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null || status=1
	print_result "same-second permission retry ordering is conservative and independent of input order" "$status"
	comments=$(printf '%s' "$comments" | jq -c '. + [{body:"terminal-blocker-circuit:retry",created_at:"2026-09-06T12:01:00Z",author_association:"OWNER"}]')
	terminal_blocker_circuit_active "$comments" '{}' owner/repo 42 '' >/dev/null && status=1
	[[ "$(_terminal_blocker_recovery "$fingerprint")" == *'Retry is scheduling consent only'* ]] || status=1
	TEST_DEPENDENCIES='{"nodes":[],"truncated":false}'
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	unset AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	print_result "continued permission denial has a stable class; edits and API outages do not re-arm; retry grants nothing" "$status"
	return 0
}

test_same_second_release_ordering() {
	local comments="" changed="" marker="" selected="" fingerprint="" status=0
	fingerprint=$(_terminal_blocker_hash 'v2:target_code_blocker')
	marker="<!-- aidevops:terminal-blocker-observation revision=111111111111111111111111 blocker=${fingerprint} -->"
	comments=$(jq -nc --arg body "$marker" '[{id:10,body:$body,created_at:"2026-09-06T12:00:00Z",author_association:"MEMBER"}, {id:11,body:"terminal-blocker-circuit:retry",created_at:"2026-09-06T12:00:00Z",author_association:"OWNER"}]')
	[[ "$(terminal_blocker_release_mode "$comments" 111111111111111111111111 "$fingerprint")" == first ]] || status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [.[0] | .id=12] | reverse')
	[[ "$(terminal_blocker_release_mode "$changed" 111111111111111111111111 "$fingerprint")" == circuit ]] || status=1
	selected=$(_terminal_blocker_latest_marker "$changed" "$marker" | jq -r '.id')
	[[ "$selected" == 12 ]] || status=1
	comments=$(jq -nc '[range(10;12) | {id:.,body:"CLAIM_RELEASED reason=blocked runner=runner ts=ignored",author:"runner",author_association:"OWNER",created_at:"2026-09-06T12:00:00Z"}] + [{id:12,body:"terminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-09-06T12:00:00Z"}]')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$comments" >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [.[0] | .id=13] | reverse')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [.[0] | .id=13] + [.[1] | .id=14] | reverse')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null || status=1
	changed=$(printf '%s' "$comments" | jq -c 'map(del(.id))')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null || status=1
	changed=$(printf '%s' "$comments" | jq -c '.[2].body += "\naidevops:terminal-blocker-circuit"')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null || status=1
	print_result "same-second observations and post-retry releases survive reordered evidence; legacy ties retain bounded backoff" "$status"
	return 0
}

test_blocked_backoff_cli() {
	local result="" status=0
	result=$(
		gh() {
			[[ "$1" == api && "$2" == 'repos/owner/repo/issues/42/comments?per_page=100' ]] || return 1
			# Deliberately reverse pages: the retry is older by ID, not timestamp.
			jq -nc '[[range(13;15) | {id:.,body:"CLAIM_RELEASED reason=blocked runner=runner ts=ignored",user:{login:"runner"},author_association:"OWNER",created_at:"2026-09-06T12:00:00Z"}], [{id:12,body:"terminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-09-06T12:00:00Z"}]]'
			return 0
		}
		export -f gh
		local fetched=""
		# Restore the real fetcher after the earlier release integration stub.
		unset _TERMINAL_BLOCKER_CIRCUIT_LOADED
		# shellcheck source=../terminal-blocker-circuit.sh
		source "${SCRIPT_DIR}/terminal-blocker-circuit.sh"
		fetched=$(terminal_blocker_fetch_trusted_comments 42 owner/repo) || exit 1
		[[ "$(printf '%s' "$fetched" | jq -c 'map(.id)')" == '[13,14,12]' ]] || exit 1
		TERMINAL_BLOCKER_NOW_EPOCH=1788696001 bash "${SCRIPT_DIR}/dispatch-dedup-helper.sh" has-dispatch-comment 42 owner/repo runner
	) || status=1
	[[ "$result" == 'TERMINAL_BLOCKER_BACKOFF failures=2 retry_after=1788696900' ]] || status=1
	print_result "production dispatch CLI preserves paginated API authors and blocks legacy repeated releases" "$status"
	return 0
}

main() {
	test_normalized_blocker_fingerprint
	test_worker_contract_reason_protocol
	test_task_revision_inputs
	test_release_modes_and_retry
	test_dispatch_hold_revalidates_revision
	test_brief_only_revision
	test_excluded_scope_revision
	test_unknown_and_redaction
	test_final_dossier_and_structural_precedence
	test_release_integration_bounds_comments
	test_legacy_blocked_backoff
	test_blocked_backoff_trust
	test_permission_blocker_continuation
	test_same_second_release_ordering
	test_blocked_backoff_cli
	printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
}

main "$@"
