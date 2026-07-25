#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=../pulse-merge-required-checks.sh
source "${SCRIPT_DIR}/../pulse-merge-required-checks.sh"

TEST_ROOT="$(mktemp -d -t pulse-preflight-snapshot.XXXXXX)"
LOGFILE="${TEST_ROOT}/pulse.log"
AIDEVOPS_REPOS_JSON="${TEST_ROOT}/repos.json"
export AIDEVOPS_REPOS_JSON
cat >"$AIDEVOPS_REPOS_JSON" <<'EOF'
{"initialized_repos":[{"slug":"owner/repo","review_gate":{"advisory_check_contexts":["CodeFactor"]}}]}
EOF
PULSE_MERGE_QUIET_PERIOD_SECONDS=30
PULSE_MERGE_NOW_EPOCH="$(_pmrc_iso_to_epoch '2026-01-01T00:10:00Z')"
PULSE_MERGE_INFRA_RERUN_STATE_DIR="${TEST_ROOT}/infra-reruns"
SNAPSHOT_MODE="happy_advisory"
RERUN_CALLS=0
TESTS_RUN=0
TESTS_FAILED=0
EVIDENCE_LOG="${TEST_ROOT}/efficiency-evidence.log"
: >"$EVIDENCE_LOG"

gh_record_efficiency_evidence() {
	local name="$1"
	local value="$2"
	printf '%s=%s\n' "$name" "$value" >>"$EVIDENCE_LOG"
	return 0
}

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

_pmrc_gh_read() {
	local command="${1:-}"
	local subcommand="${2:-}"
	local endpoint="${3:-}"

	[[ "$command" == "gh" && "$subcommand" == "api" ]] || return 1
	case "${SNAPSHOT_MODE}:${endpoint}" in
	"pr_fetch_error:repos/owner/repo/pulls/7" | "check_runs_error:"*check-runs* | \
		"status_error:"*commits/sha-reviewed/status* | "reviews_error:"*pulls/7/reviews* | \
		"issue_comments_error:"*issues/7/comments* | "inline_comments_error:"*pulls/7/comments*)
		return 1
		;;
	"pr_parse_error:repos/owner/repo/pulls/7" | "activity_parse_error:"*pulls/7/comments*)
		printf '%s\n' '{'
		return 0
		;;
	"pr_empty:repos/owner/repo/pulls/7")
		return 0
		;;
	esac
	"$@"
	return $?
}

_required_contexts_for_default_branch() {
	local repo_slug="$1"
	[[ -n "$repo_slug" ]] || return 1
	[[ "$SNAPSHOT_MODE" == "required_contexts_error" ]] && return 1
	printf 'required-a\n'
	[[ "$SNAPSHOT_MODE" == "maintainer_alias_fail" || "$SNAPSHOT_MODE" == "maintainer_infra_fail" ]] && printf 'Maintainer Review & Assignee Gate\n'
	return 0
}

_ci_check_url_has_infra_failure_log() {
	local repo_slug="$1"
	local check_url="$2"
	[[ -n "$repo_slug" ]] || return 1
	[[ "$SNAPSHOT_MODE" == "infra_fail" && "$check_url" == "https://github.com/owner/repo/actions/runs/101/job/202" ||
		"$SNAPSHOT_MODE" == "required_infra_fail" && "$check_url" == "https://github.com/owner/repo/actions/runs/303/job/404" ||
		"$SNAPSHOT_MODE" == "maintainer_infra_fail" && "$check_url" == "https://github.com/owner/repo/actions/runs/505/job/606" ]]
	return $?
}

stub_review_threads() {
	if [[ "$SNAPSHOT_MODE" == "review_threads_paginated" ]]; then
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true},"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"gemini-code-assist[bot]"}}]}}]}}},"rateLimit":{"cost":1}}}'
	elif [[ "$SNAPSHOT_MODE" == "unresolved" ]]; then
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"gemini-code-assist[bot]"}}]}}]}}},"rateLimit":{"cost":1}}}'
	elif [[ "$SNAPSHOT_MODE" == human_* ]]; then
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"human-reviewer"}}]}}]}}},"rateLimit":{"cost":1}}}'
	elif [[ "$SNAPSHOT_MODE" == "review_threads_cost_changed" ]]; then
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}},"rateLimit":{"cost":2}}}'
	else
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}},"rateLimit":{"cost":1}}}'
	fi
	return 0
}

stub_effective_rules() {
	local endpoint="$1"
	if [[ "$SNAPSHOT_MODE" == "human_rules_error" ]]; then
		return 1
	elif [[ "$SNAPSHOT_MODE" == "human_rules_malformed" ]]; then
		printf '%s\n' '{"unexpected":"object"}'
	elif [[ "$SNAPSHOT_MODE" == "human_required_slash" && "$endpoint" != "repos/owner/repo/rules/branches/release%2F1.x" ]]; then
		return 1
	elif [[ "$SNAPSHOT_MODE" == "human_required" || "$SNAPSHOT_MODE" == "human_required_slash" ]]; then
		printf '%s\n' '[{"type":"pull_request","ruleset_source":"arbitrary-policy-name","parameters":{"required_review_thread_resolution":true}}]'
	else
		printf '%s\n' '[{"type":"pull_request","parameters":{"required_review_thread_resolution":false}}]'
	fi
	return 0
}

stub_inline_comments() {
	if [[ "$SNAPSHOT_MODE" == "stale_gate" || "$SNAPSHOT_MODE" == "unresolved" ]]; then
		printf '%s\n' '[[{"user":{"login":"gemini-code-assist[bot]"},"created_at":"2026-01-01T00:00:40Z","updated_at":"2026-01-01T00:00:40Z"}]]'
	elif [[ "$SNAPSHOT_MODE" == "large_bot_activity" ]]; then
		printf '[[{"user":{"login":"gemini-code-assist[bot]"},"created_at":"2026-01-01T00:00:40Z","body":"'
		dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\000' x
		printf '"}]]\n'
	elif [[ "$SNAPSHOT_MODE" == "activity_wrong_shape" ]]; then
		printf '%s\n' '[{}]'
	else
		printf '%s\n' '[[]]'
	fi
	return 0
}

gh() {
	local command="$1"
	local endpoint="${2:-}"
	if [[ "$command" == "run" && "$endpoint" == "rerun" ]]; then
		RERUN_CALLS=$((RERUN_CALLS + 1))
		return 0
	fi
	[[ "$command" == "api" ]] || return 1

	if [[ "$endpoint" == "graphql" ]]; then
		stub_review_threads
		return $?
	fi

	case "$endpoint" in
	repos/owner/repo/pulls/7)
		if [[ "$SNAPSHOT_MODE" == "new_head" ]]; then
			printf '%s\n' '{"head":{"sha":"sha-new"},"base":{"ref":"main"}}'
		elif [[ "$SNAPSHOT_MODE" == "human_required_slash" ]]; then
			printf '%s\n' '{"head":{"sha":"sha-reviewed"},"base":{"ref":"release/1.x"}}'
		else
			printf '%s\n' '{"head":{"sha":"sha-reviewed"},"base":{"ref":"main"}}'
		fi
		;;
	repos/owner/repo/rules/branches/*)
		stub_effective_rules "$endpoint"
		return $?
		;;
	*check-runs*)
		if [[ "$SNAPSHOT_MODE" == "large_payload" ]]; then
			printf '[{"padding":"'
			dd if=/dev/zero bs=1024 count=512 2>/dev/null | tr '\000' x
			printf '","check_runs":[{"name":"required-a","status":"completed","conclusion":"success","completed_at":"2026-01-01T00:01:00Z"}]}]\n'
			return 0
		fi
		[[ "$SNAPSHOT_MODE" == "empty_check_runs" ]] && return 0
		local required_conclusion="success" required_url="" broad_status="completed" broad_conclusion="success"
		local broad_completed_at="2026-01-01T00:01:00Z" extra_check=""
		[[ "$SNAPSHOT_MODE" == "required_fail" ]] && required_conclusion="failure"
		if [[ "$SNAPSHOT_MODE" == "required_infra_fail" ]]; then
			required_conclusion="failure"
			required_url=',"details_url":"https://github.com/owner/repo/actions/runs/303/job/404"'
		fi
		if [[ "$SNAPSHOT_MODE" == "pending" ]]; then
			broad_status="in_progress"
			broad_conclusion="null"
		fi
		[[ "$SNAPSHOT_MODE" == "recent" ]] && broad_completed_at="2026-01-01T00:09:50Z"
		if [[ "$SNAPSHOT_MODE" == "unclassified_fail" ]]; then
			extra_check=',{"name":"CodeFactor","status":"completed","conclusion":"failure","details_url":"https://github.com/owner/repo/runs/99","completed_at":"2026-01-01T00:01:00Z"}'
		elif [[ "$SNAPSHOT_MODE" == "infra_fail" ]]; then
			extra_check=',{"name":"sync / Record ordered forge event","status":"completed","conclusion":"failure","details_url":"https://github.com/owner/repo/actions/runs/101/job/202","completed_at":"2026-01-01T00:01:00Z"}'
		elif [[ "$SNAPSHOT_MODE" == "configured_fail" ]]; then
			extra_check=',{"name":"CodeFactor","status":"completed","conclusion":"failure","completed_at":"2026-01-01T00:01:00Z"}'
		elif [[ "$SNAPSHOT_MODE" == "maintainer_alias_fail" ]]; then
			extra_check=',{"name":"maintainer-gate","status":"completed","conclusion":"success","completed_at":"2026-01-01T00:01:00Z"},{"name":"Maintainer Review & Assignee Gate","status":"completed","conclusion":"failure","completed_at":"2026-01-01T00:01:01Z"},{"name":"gate / Maintainer Review & Assignee Gate","status":"completed","conclusion":"success","completed_at":"2026-01-01T00:01:02Z"}'
		elif [[ "$SNAPSHOT_MODE" == "maintainer_infra_fail" ]]; then
			extra_check=',{"name":"gate / Maintainer Review & Assignee Gate","status":"completed","conclusion":"failure","details_url":"https://github.com/owner/repo/actions/runs/505/job/606","completed_at":"2026-01-01T00:01:02Z"}'
		elif [[ "$SNAPSHOT_MODE" == "maintainer_stable_fail" ]]; then
			extra_check=',{"name":"maintainer-gate","status":"completed","conclusion":"failure","completed_at":"2026-01-01T00:01:02Z"},{"name":"gate / Maintainer Review & Assignee Gate","status":"completed","conclusion":"success","completed_at":"2026-01-01T00:01:01Z"}'
		elif [[ "$SNAPSHOT_MODE" == "maintainer_legacy_fail" ]]; then
			extra_check=',{"name":"Maintainer Review & Assignee Gate","status":"completed","conclusion":"failure","completed_at":"2026-01-01T00:01:01Z"},{"name":"gate / Maintainer Review & Assignee Gate","status":"completed","conclusion":"failure","completed_at":"2026-01-01T00:01:02Z"}'
		elif [[ "$SNAPSHOT_MODE" == "skipped_companion_rerun" ]]; then
			extra_check=',{"name":"Qlty Smell Regression","status":"completed","conclusion":"skipped","completed_at":"2026-01-01T00:02:00Z"}'
		elif [[ "$SNAPSHOT_MODE" == "same_name_source_conflict" ]]; then
			extra_check=',{"name":"ProviderMirror","status":"completed","conclusion":"success","completed_at":"2026-01-01T00:01:02Z"}'
		fi
		printf '[{"check_runs":[{"name":"required-a","status":"completed","conclusion":"%s"%s,"completed_at":"2026-01-01T00:01:00Z"},{"name":"Framework Validation","status":"%s","conclusion":%s,"completed_at":"%s"},{"name":"Qlty Smell Regression","status":"completed","conclusion":"success","completed_at":"2026-01-01T00:01:00Z"},{"name":"Qlty Smell Threshold","status":"completed","conclusion":"failure","completed_at":"2026-01-01T00:01:00Z"}%s]}]\n' \
			"$required_conclusion" "$required_url" "$broad_status" "$([[ "$broad_conclusion" == "null" ]] && printf 'null' || printf '"%s"' "$broad_conclusion")" "$broad_completed_at" "$extra_check"
		;;
	*commits/sha-reviewed/status*)
		local gate_at="2026-01-01T00:01:10Z"
		[[ "$SNAPSHOT_MODE" == "stale_gate" ]] && gate_at="2026-01-01T00:00:20Z"
		if [[ "$SNAPSHOT_MODE" == "no_status_gate" ]]; then
			printf '%s\n' '{"statuses":[]}'
		elif [[ "$SNAPSHOT_MODE" == "same_name_source_conflict" ]]; then
			printf '{"statuses":[{"context":"review-bot-gate","state":"success","updated_at":"%s"},{"context":"ProviderMirror","state":"failure","updated_at":"2026-01-01T00:01:03Z"}]}\n' "$gate_at"
		else
			printf '{"statuses":[{"context":"review-bot-gate","state":"success","updated_at":"%s"}]}\n' "$gate_at"
		fi
		;;
	*pulls/7/reviews*)
		printf '%s\n' '[[{"user":{"login":"gemini-code-assist[bot]"},"submitted_at":"2026-01-01T00:00:30Z"}]]'
		;;
	*issues/7/comments*)
		printf '%s\n' '[[]]'
		;;
	*pulls/7/comments*)
		stub_inline_comments
		return $?
		;;
	*)
		printf 'Unhandled gh endpoint: %s\n' "$endpoint" >&2
		return 1
		;;
	esac
	return 0
}

assert_gate() {
	local description="$1"
	local mode="$2"
	local expected_rc="$3"
	local rc=0
	SNAPSHOT_MODE="$mode"
	: >"$LOGFILE"
	_pulse_merge_preflight_snapshot_gate owner/repo 7 sha-reviewed || rc=$?
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq "$expected_rc" ]]; then
		printf 'PASS %s\n' "$description"
		return 0
	fi
	printf 'FAIL %s (expected rc=%s, actual rc=%s)\n' "$description" "$expected_rc" "$rc"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_gate_blocker() {
	local description="$1"
	local mode="$2"
	local expected_rc="$3"
	local expected_blocker="$4"

	assert_gate "$description" "$mode" "$expected_rc"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "${_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND:-}" == "$expected_blocker" ]]; then
		printf 'PASS %s exports blocker %s\n' "$description" "${expected_blocker:-<none>}"
		return 0
	fi
	printf 'FAIL %s exported blocker %s (expected %s)\n' \
		"$description" "${_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND:-<none>}" "${expected_blocker:-<none>}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_gate_logged() {
	local description="$1"
	local mode="$2"
	local expected_log="$3"

	assert_gate "$description" "$mode" 1
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -q "$expected_log" "$LOGFILE"; then
		printf 'PASS %s is audited\n' "$description"
		return 0
	fi
	printf 'FAIL %s did not log: %s\n' "$description" "$expected_log"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_snapshot_acquisition_failures_are_audited() {
	assert_gate_logged "pull-request fetch failure" pr_fetch_error "pull-request fetch failed"
	assert_gate_logged "empty pull-request response" pr_empty "pull-request parse failed"
	assert_gate_logged "pull-request parse failure" pr_parse_error "pull-request parse failed"
	assert_gate_logged "required-context lookup failure" required_contexts_error "required-context lookup failed"
	assert_gate_logged "check-runs fetch failure" check_runs_error "check-runs fetch failed"
	assert_gate_logged "commit-status fetch failure" status_error "commit-status fetch failed"
	assert_gate_logged "check-set parse failure" empty_check_runs "check-set parse failed"
	assert_gate_logged "reviews fetch failure" reviews_error "reviews fetch failed"
	assert_gate_logged "issue-comments fetch failure" issue_comments_error "issue-comments fetch failed"
	assert_gate_logged "inline-comments fetch failure" inline_comments_error "inline-comments fetch failed"
	assert_gate_logged "bot-activity parse failure" activity_parse_error "bot-activity parse failed"
	assert_gate_logged "wrong-shaped bot-activity response" activity_wrong_shape "bot-activity parse failed"
	return 0
}

assert_large_bot_activity_streams() {
	local activity=""
	local rc=0
	SNAPSHOT_MODE="large_bot_activity"
	: >"$LOGFILE"
	activity=$(_pmrc_snapshot_bot_activity_json owner/repo 7) || rc=$?
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]] && jq -e \
		'.count == 2 and .latest_at == "2026-01-01T00:00:40Z"' \
		<<<"$activity" >/dev/null; then
		printf 'PASS oversized inline-comment payload contributes bot activity\n'
		return 0
	fi
	printf 'FAIL oversized inline-comment payload did not produce expected activity (rc=%s, output=%s)\n' \
		"$rc" "$activity"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_human_review_thread_rules() {
	assert_gate_blocker "unresolved human thread blocks when effective rules require resolution" \
		human_required 1 "$PMRC_BLOCKER_REQUIRED_REVIEW_THREADS"
	if grep -q "requires thread resolution" "$LOGFILE"; then
		printf 'PASS required human thread blocker is audited\n'
	else
		printf 'FAIL required human thread blocker is audited\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate_blocker "unresolved human thread passes when effective rules do not require resolution" human_not_required 0 ""
	assert_gate_blocker "required human thread supports slash-containing base branches" \
		human_required_slash 1 "$PMRC_BLOCKER_REQUIRED_REVIEW_THREADS"
	assert_gate_blocker "effective-rules API failure with unresolved human thread fails closed" \
		human_rules_error 1 "$PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE"
	assert_gate_blocker "malformed effective-rules response with unresolved human thread fails closed" \
		human_rules_malformed 1 "$PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE"
	return 0
}

set_live_evidence() {
	local status="$1"
	local head_sha="${2:-sha-reviewed}"
	local author_class="${3:-trusted}"
	local permitted="${4:-true}"
	local observed_at="${5:-2026-01-01T00:10:00Z}"
	_PULSE_REVIEW_GATE_EVIDENCE=$(jq -nc --arg status "$status" --arg head "$head_sha" --arg class "$author_class" --arg observed_at "$observed_at" --argjson permitted "$permitted" '
		{schema:"aidevops.review-gate-evidence/v1",repo:"owner/repo",pr:"7",head_sha:$head,status:$status,author:{login:"reviewer",association:(if $class == "trusted" then "MEMBER" else "CONTRIBUTOR" end),class:$class},permitted:$permitted,reason:"test",state:(if $permitted then "pass" else "waiting" end),merge_gate:(if $permitted then "clear" else "blocked" end),exit_code:0,observed_at:$observed_at}
	')
	return 0
}

assert_infrastructure_rerun_unset_defaults_safe() {
	local output="" rc=0
	output=$(
		unset LOGFILE HOME AIDEVOPS_TEMP_DIR PULSE_MERGE_INFRA_RERUN_STATE_DIR
		_pmrc_rerun_infrastructure_check owner/repo 7 required-a \
			"https://github.com/owner/repo/actions/runs/707/job/808"
	) 2>&1 || rc=$?
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 1 && -z "$output" ]]; then
		printf 'PASS unset HOME fails closed without resolving a root-level state directory\n'
		return 0
	fi
	printf 'FAIL unset HOME was not handled safely (rc=%s, output=%s)\n' "$rc" "$output"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_infrastructure_rerun_unset_logfile_safe() {
	local output="" rc=0 stderr_file="${TEST_ROOT}/unset-log-stderr"
	(
		unset LOGFILE HOME AIDEVOPS_TEMP_DIR
		PULSE_MERGE_INFRA_RERUN_STATE_DIR="${TEST_ROOT}/unset-log-reruns"
		_pmrc_rerun_infrastructure_check owner/repo 7 required-a \
			"https://github.com/owner/repo/actions/runs/909/job/1001"
	) 2>"$stderr_file" || rc=$?
	output=$(<"$stderr_file")
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 && "$output" == *"requested infrastructure rerun"* ]]; then
		printf 'PASS unset LOGFILE falls back to stderr under set -u\n'
		return 0
	fi
	printf 'FAIL unset LOGFILE was not handled safely (rc=%s, output=%s)\n' "$rc" "$output"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_review_and_head_snapshot_cases() {
	assert_gate "same-name check-run and status retain independent source failures" same_name_source_conflict 1
	set_live_evidence PASS
	assert_gate "configured non-required provider failure passes with typed current-head evidence" configured_fail 0
	set_live_evidence PASS_ADVISORY
	assert_gate "configured provider failure passes with trusted advisory-default evidence" configured_fail 0
	set_live_evidence PASS_ADVISORY sha-reviewed external false
	assert_gate "configured provider failure blocks external advisory evidence" configured_fail 1
	set_live_evidence PASS_RATE_LIMITED sha-reviewed external false
	assert_gate "configured provider failure blocks external rate-limit evidence" configured_fail 1
	_PULSE_REVIEW_GATE_EVIDENCE=""
	assert_gate "stable maintainer-gate success supersedes stale alias failures" maintainer_alias_fail 0
	assert_gate "stable maintainer-gate failure remains one logical blocker" maintainer_stable_fail 1
	if [[ "$(grep -c "maintainer-gate family is terminal-failure" "$LOGFILE" || true)" -eq 1 ]]; then
		printf 'PASS maintainer-gate aliases emit one audited blocker\n'
	else
		printf 'FAIL maintainer-gate aliases did not emit exactly one blocker\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate "legacy maintainer aliases fail closed without stable context" maintainer_legacy_fail 1
	assert_gate "infrastructure-failed maintainer gate requests rerun and stays blocked" maintainer_infra_fail 1
	if [[ "$RERUN_CALLS" -eq 2 ]] && grep -q "maintainer-gate family has a proven infrastructure failure" "$LOGFILE"; then
		printf 'PASS infrastructure-failed maintainer gate requests audited rerun\n'
	else
		printf 'FAIL infrastructure-failed maintainer gate rerun was not requested\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate_blocker "unresolved late inline finding blocks merge" unresolved 1 "$PMRC_BLOCKER_REVIEW_BOT_THREADS"
	assert_gate_blocker "paginated review-thread snapshot fails closed without actionable remediation" \
		review_threads_paginated 1 "$PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE"
	assert_gate_logged "review-thread quota-cost contract drift" \
		review_threads_cost_changed "GraphQL cost contract changed"
	assert_human_review_thread_rules
	assert_gate "late review activity invalidates stale gate success" stale_gate 1
	set_live_evidence PASS sha-reviewed trusted true 2026-01-01T00:00:50Z
	assert_gate "newer typed live evidence supersedes a stale status context" stale_gate 0
	set_live_evidence PASS sha-reviewed trusted true 2026-01-01T00:00:35Z
	assert_gate "typed live evidence predating late activity fails closed" stale_gate 1
	_PULSE_REVIEW_GATE_EVIDENCE=""
	assert_gate "missing status gate fails closed without live evidence" no_status_gate 1
	set_live_evidence PASS_ADVISORY
	_PULSE_REVIEW_GATE_EVIDENCE=$(jq -c 'del(.observed_at)' <<<"$_PULSE_REVIEW_GATE_EVIDENCE")
	assert_gate "live evidence without an observation timestamp fails closed" no_status_gate 1
	set_live_evidence PASS_ADVISORY
	assert_gate "trusted advisory evidence permits repositories without a status context" no_status_gate 0
	set_live_evidence PASS sha-other
	assert_gate "live gate evidence for another head fails closed" no_status_gate 1
	_PULSE_REVIEW_GATE_EVIDENCE=""
	assert_gate "new commit invalidates reviewed head" new_head 1
	assert_gate "bounded quiet period blocks recent check completion" recent 1
	return 0
}

main() {
	assert_infrastructure_rerun_unset_defaults_safe
	assert_infrastructure_rerun_unset_logfile_safe
	assert_snapshot_acquisition_failures_are_audited
	assert_gate "large paginated check payload streams without argument overflow" large_payload 0
	assert_large_bot_activity_streams
	assert_gate "large inline-comment payload streams through preflight" large_bot_activity 0
	assert_gate "terminal checks with explicit baseline advisory pass" happy_advisory 0
	if grep -q "IGNORED non-required baseline advisory failure 'Qlty Smell Threshold'" "$LOGFILE"; then
		printf 'PASS ignored advisory failure is audited\n'
	else
		printf 'FAIL ignored advisory failure is audited\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate "skipped rerun preserves successful baseline companion" skipped_companion_rerun 0
	: >"$EVIDENCE_LOG"
	assert_gate "active broad check blocks merge" pending 1
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$(grep -c '^guardrails.required_check_merge_preflight_mismatches=1$' "$EVIDENCE_LOG")" == "1" \
		&& "$(grep -c '^guardrails.stale_positive_decisions=1$' "$EVIDENCE_LOG")" == "1" ]]; then
		printf 'PASS live preflight mismatch emits typed guardrail and stale-positive evidence\n'
	else
		printf 'FAIL live preflight mismatch did not emit both guardrail events\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	assert_gate "terminal failed required check blocks merge" required_fail 1
	assert_gate "infrastructure-failed required check requests rerun and stays blocked" required_infra_fail 1
	if [[ "$RERUN_CALLS" -eq 1 ]] && grep -q "requested infrastructure rerun.*run=303" "$LOGFILE"; then
		printf 'PASS infrastructure-failed required check requests one audited rerun\n'
	else
		printf 'FAIL infrastructure-failed required check rerun was not requested once\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate "infrastructure rerun cooldown keeps merge blocked without duplicate write" required_infra_fail 1
	if [[ "$RERUN_CALLS" -eq 1 ]] && grep -q "infrastructure rerun cooldown active.*run=303" "$LOGFILE"; then
		printf 'PASS infrastructure rerun cooldown suppresses duplicate write\n'
	else
		printf 'FAIL infrastructure rerun cooldown did not suppress duplicate write\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate "unclassified non-required failure blocks merge" unclassified_fail 1
	if jq -e 'length == 1 and .[0].name == "CodeFactor" and .[0].bucket == "fail" and .[0].conclusion == "failure" and .[0].link == "https://github.com/owner/repo/runs/99"' \
		<<<"$_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON" >/dev/null; then
		printf 'PASS terminal blocker evidence is exported for CI repair\n'
	else
		printf 'FAIL terminal blocker evidence is exported for CI repair: %s\n' "$_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate "classified non-required infrastructure failure does not block merge" infra_fail 0
	if grep -q "IGNORED non-required infrastructure failure 'sync / Record ordered forge event'" "$LOGFILE"; then
		printf 'PASS ignored infrastructure failure is audited\n'
	else
		printf 'FAIL ignored infrastructure failure is audited\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate "later accepted snapshot resets prior blocker evidence" happy_advisory 0
	if [[ "$_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON" == "[]" ]]; then
		printf 'PASS accepted snapshot clears prior blocker evidence\n'
	else
		printf 'FAIL accepted snapshot clears prior blocker evidence: %s\n' "$_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_review_and_head_snapshot_cases
	printf '\nTests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
