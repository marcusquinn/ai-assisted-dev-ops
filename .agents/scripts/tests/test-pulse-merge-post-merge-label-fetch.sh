#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-post-merge-label-fetch.sh — GH#22219/GH#27502 regression guard.
#
# Verifies _handle_post_merge_actions behaviour around optional PR labels:
# a provided empty 5th argument is authoritative and must not refetch, while an
# omitted 5th argument falls back to fetching PR labels before setting solved
# attribution. It also verifies that repeated or concurrent post-merge handling
# converges on one marker-bearing PR completion summary.

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
MERGE_FILE="${SCRIPT_DIR_TEST}/../pulse-merge.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	if [[ -n "$detail" ]]; then
		printf '     %s\n' "$detail"
	fi
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	export TIMEOUT_CALL_LOG="${TEST_ROOT}/timeout-calls.log"
	export SOLVED_LABEL_LOG="${TEST_ROOT}/solved-labels.log"
	export TEST_PR_COMMENTS_FILE="${TEST_ROOT}/pr-comments.json"
	export TEST_PR_SNAPSHOT_QUEUE_FILE="${TEST_ROOT}/pr-comment-snapshots.ndjson"
	: >"$LOGFILE"
	: >"$GH_CALL_LOG"
	: >"$TIMEOUT_CALL_LOG"
	: >"$SOLVED_LABEL_LOG"
	: >"$TEST_PR_SNAPSHOT_QUEUE_FILE"
	printf '[]\n' >"$TEST_PR_COMMENTS_FILE"

	export AGENTS_DIR="${TEST_ROOT}"
	mkdir -p "${AGENTS_DIR}/scripts"
	cat >"${AGENTS_DIR}/scripts/gh-signature-helper.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "${AGENTS_DIR}/scripts/gh-signature-helper.sh"

	export PULSE_START_EPOCH
	PULSE_START_EPOCH=$(date +%s)
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

set_pr_comments() {
	local comments_json="$1"
	printf '%s\n' "$comments_json" >"$TEST_PR_COMMENTS_FILE"
	return 0
}

set_comment_snapshots() {
	local snapshots="$1"
	printf '%s\n' "$snapshots" >"$TEST_PR_SNAPSHOT_QUEUE_FILE"
	return 0
}

assert_completion_candidate_count() {
	local expected_count="$1"
	local pr_number="$2"
	local label="$3"
	local actual_count
	actual_count=$(jq --arg closeout_marker "<!-- PULSE_MERGE_CLOSEOUT:PR#${pr_number} -->" \
		--arg legacy_generic_text "Completed via PR #${pr_number}, merged to" \
		--arg legacy_merge_text "Merged via PR #${pr_number} to" \
		--arg merge_attribution 'Merged by deterministic merge pass (pulse-wrapper.sh).' \
		--arg summary_marker '<!-- MERGE_SUMMARY -->' '
		[ .[] | select(
			((.body // "") | contains($closeout_marker)) or
			((.body // "") | contains($summary_marker)) or
			(
				((.body // "") | contains($legacy_merge_text)) and
				((.body // "") | contains($merge_attribution))
			) or
			(
				((.body // "") | contains($legacy_generic_text)) and
				((.body // "") | contains($merge_attribution))
			)
		) ] | length
	' "$TEST_PR_COMMENTS_FILE")
	if [[ "$actual_count" == "$expected_count" ]]; then
		pass "$label"
	else
		fail "$label" "Expected ${expected_count} completion candidate(s), found ${actual_count}"
	fi
	return 0
}

define_function_under_test() {
	local fn_src
	fn_src=$(awk '
		/^_pm_issue_api\(\) \{/,/^}$/ { print }
		/^_pm_build_closing_comment\(\) \{/,/^}$/ { print }
		/^_pm_select_pr_closeout_comment_id\(\) \{/,/^}$/ { print }
		/^_pm_reconcile_pr_closeout_comments\(\) \{/,/^}$/ { print }
		/^_pm_upsert_pr_closing_comment\(\) \{/,/^}$/ { print }
		/^_pm_resolve_superseded_original_issue\(\) \{/,/^}$/ { print }
		/^_handle_post_merge_actions\(\) \{/,/^}$/ { print }
		/^_extract_linked_issue\(\) \{/,/^}$/ { print }
	' "$MERGE_FILE")
	if [[ -z "$fn_src" ]]; then
		printf 'ERROR: could not extract _handle_post_merge_actions from %s\n' "$MERGE_FILE" >&2
		return 1
	fi
	_PM_PARENT_TASK_LABEL_NEEDLE=",parent-task,"
	eval "$fn_src"
	return 0
}

gh() {
	local api_path="${2:-}" arg="" body="" comment_id="" next_id="" snapshot="" state_tmp=""
	printf '%s\n' "$*" >>"$GH_CALL_LOG"
	if [[ "$1" == "api" && "$api_path" == "repos/marcusquinn/aidevops/pulls/33333" ]]; then
		printf '{"number":33333}\n'
		return 0
	fi
	if [[ "$1" == "api" && "$api_path" == "repos/marcusquinn/aidevops/pulls/"* ]]; then
		return 1
	fi
	if [[ "$1" == "api" && "$api_path" == *"/comments?per_page=100" ]]; then
		if IFS= read -r snapshot <"$TEST_PR_SNAPSHOT_QUEUE_FILE" && [[ -n "$snapshot" ]]; then
			printf '%s\n' "$snapshot"
			state_tmp="${TEST_PR_SNAPSHOT_QUEUE_FILE}.tmp"
			sed '1d' "$TEST_PR_SNAPSHOT_QUEUE_FILE" >"$state_tmp"
			mv "$state_tmp" "$TEST_PR_SNAPSHOT_QUEUE_FILE"
			return 0
		fi
		jq -c '[.]' "$TEST_PR_COMMENTS_FILE"
		return 0
	fi
	for arg in "$@"; do
		case "$arg" in
		body=*) body="${arg#body=}" ;;
		esac
	done
	if [[ "$1" == "api" && "$api_path" == *"/issues/comments/"* && "$*" == *"--method PATCH"* ]]; then
		comment_id="${api_path##*/}"
		if [[ ! "$comment_id" =~ ^[0-9]+$ ]]; then
			return 1
		fi
		if [[ ",${TEST_FAIL_PATCH_IDS:-}," == *",${comment_id},"* ]]; then
			return 1
		fi
		state_tmp="${TEST_PR_COMMENTS_FILE}.tmp"
		jq --argjson id "$comment_id" --arg body "$body" \
			'map(if .id == $id then .body = $body else . end)' \
			"$TEST_PR_COMMENTS_FILE" >"$state_tmp"
		mv "$state_tmp" "$TEST_PR_COMMENTS_FILE"
		return 0
	fi
	if [[ "$1" == "api" && "$api_path" == *"/issues/comments/"* && "$*" == *"--method DELETE"* ]]; then
		comment_id="${api_path##*/}"
		state_tmp="${TEST_PR_COMMENTS_FILE}.tmp"
		jq --argjson id "$comment_id" 'map(select(.id != $id))' \
			"$TEST_PR_COMMENTS_FILE" >"$state_tmp"
		mv "$state_tmp" "$TEST_PR_COMMENTS_FILE"
		return 0
	fi
	if [[ "$1" == "api" && "$api_path" == *"/issues/"*"/comments" && "$*" == *"--method POST"* ]]; then
		next_id=$(jq '[.[].id] | max // 400' "$TEST_PR_COMMENTS_FILE")
		next_id=$((next_id + 1))
		state_tmp="${TEST_PR_COMMENTS_FILE}.tmp"
		jq --argjson id "$next_id" --arg body "$body" \
			'. + [{id: $id, created_at: "2026-07-13T17:00:00Z", body: $body}]' \
			"$TEST_PR_COMMENTS_FILE" >"$state_tmp"
		mv "$state_tmp" "$TEST_PR_COMMENTS_FILE"
		printf '%s\n' "$next_id"
		return 0
	fi
	if [[ "$1" == "api" && "$*" == *"/comments"* ]]; then
		printf '[]\n'
	fi
	return 0
}

install_helper_stubs() {
	export TEST_FAIL_PATCH_IDS=""
	gh_pr_comment() {
		gh pr comment "$@"
		return 0
	}
	gh_issue_comment() {
		gh issue comment "$@"
		return 0
	}
	_gh_with_timeout() {
		local access_mode="$1"
		shift
		printf '%s %s\n' "$access_mode" "$*" >>"$TIMEOUT_CALL_LOG"
		"$@"
		return $?
	}
	gh_pr_view() {
		printf 'pr view %s\n' "$*" >>"$GH_CALL_LOG"
		if [[ "$1" == "33333" && "$*" == *"--json body"* ]]; then
			printf 'Resolves #22219\n'
			return 0
		fi
		if [[ "$1" == "33333" && "$*" == *"--json title"* ]]; then
			printf 'GH#22219: original worker PR\n'
			return 0
		fi
		printf '%s\n' "${TEST_PR_LABELS:-}"
		return 0
	}
	set_solved_label() {
		local issue="$1"
		local repo="$2"
		local actor="$3"
		printf '%s %s %s\n' "$issue" "$repo" "$actor" >>"$SOLVED_LABEL_LOG"
		return 0
	}
	clear_terminal_issue_dispatch_labels() {
		local issue="$1"
		local repo="$2"
		local context="$3"
		printf 'cleanup %s %s %s\n' "$issue" "$repo" "$context" >>"$GH_CALL_LOG"
		return 0
	}
	set_issue_status() {
		local issue="$1"
		local repo="$2"
		local status="$3"
		printf 'status %s %s %s\n' "$issue" "$repo" "$status" >>"$GH_CALL_LOG"
		return 0
	}
	unlock_issue_after_worker() { return 0; }
	fast_fail_reset() { return 0; }
	reconcile_dependants_after_verified_closure() { return 0; }
	_release_interactive_claim_on_merge() { return 0; }
	auto_file_next_phase() { return 0; }
	_unblock_circuit_breaker_meta_pr() { return 0; }
	_pm_handle_partial_parent_closeout() { return 0; }
	sleep() { return 0; }
	return 0
}

assert_log_contains() {
	local file="$1"
	local pattern="$2"
	local label="$3"
	if grep -q -- "$pattern" "$file"; then
		pass "$label"
	else
		fail "$label" "Expected pattern '$pattern' in $file"
	fi
	return 0
}

assert_log_not_contains() {
	local file="$1"
	local pattern="$2"
	local label="$3"
	if grep -q -- "$pattern" "$file"; then
		fail "$label" "Unexpected pattern '$pattern' in $file"
	else
		pass "$label"
	fi
	return 0
}

test_provided_empty_pr_labels_skip_refetch() {
	: >"$GH_CALL_LOG"
	: >"$SOLVED_LABEL_LOG"
	export TEST_PR_LABELS="origin:worker"

	_handle_post_merge_actions "22585" "marcusquinn/aidevops" "22219" "merged" ""

	assert_log_not_contains "$GH_CALL_LOG" "pr view" \
		"provided empty pr_labels skips fallback fetch"
	assert_log_contains "$SOLVED_LABEL_LOG" "22219 marcusquinn/aidevops interactive" \
		"provided empty pr_labels keeps interactive solved attribution"
	assert_log_contains "$GH_CALL_LOG" "cleanup 22219 marcusquinn/aidevops post-merge-pr-22585" \
		"post-merge close strips terminal dispatch labels"
	assert_log_contains "$GH_CALL_LOG" "status 22219 marcusquinn/aidevops done" \
		"post-merge close converges the linked issue to status:done"
	return 0
}

test_omitted_pr_labels_fetches_fallback() {
	: >"$GH_CALL_LOG"
	: >"$SOLVED_LABEL_LOG"
	export TEST_PR_LABELS="origin:worker"

	_handle_post_merge_actions "22585" "marcusquinn/aidevops" "22219" "merged"

	assert_log_contains "$GH_CALL_LOG" "pr view 22585" \
		"omitted pr_labels fetches fallback labels"
	assert_log_contains "$SOLVED_LABEL_LOG" "22219 marcusquinn/aidevops worker" \
		"fallback labels drive worker solved attribution"
	return 0
}

test_superseded_pr_closes_original_issue() {
	: >"$GH_CALL_LOG"
	: >"$SOLVED_LABEL_LOG"
	export TEST_PR_LABELS="origin:worker"

	_handle_post_merge_actions "44444" "marcusquinn/aidevops" "33333" "merged" "origin:worker"

	assert_log_contains "$GH_CALL_LOG" "repos/marcusquinn/aidevops/pulls/33333" \
		"superseded chain checks whether linked issue is a PR"
	assert_log_contains "$GH_CALL_LOG" "issue close 22219" \
		"superseded chain closes original issue"
	assert_log_contains "$SOLVED_LABEL_LOG" "22219 marcusquinn/aidevops worker" \
		"superseded chain marks original issue solved by worker"
	assert_log_contains "$GH_CALL_LOG" "cleanup 22219 marcusquinn/aidevops post-merge-superseded-pr-44444" \
		"superseded close strips terminal dispatch labels"
	assert_log_contains "$GH_CALL_LOG" "status 22219 marcusquinn/aidevops done" \
		"superseded close converges the original issue to status:done"
	return 0
}

test_closing_comment_uses_pr_base_ref() {
	: >"$GH_CALL_LOG"
	: >"$SOLVED_LABEL_LOG"
	export TEST_PR_LABELS="origin:worker"

	_handle_post_merge_actions "753" "marcusquinn/aidevops" "25350" "merged" "origin:worker" "develop"

	assert_log_contains "$GH_CALL_LOG" "Merged via PR #753 to develop" \
		"closing comment names non-main PR base ref"
	assert_log_not_contains "$GH_CALL_LOG" "Merged via PR #753 to main" \
		"closing comment does not hardcode main when base ref is provided"
	return 0
}

test_closing_comment_defaults_to_main_for_legacy_callers() {
	: >"$GH_CALL_LOG"
	: >"$SOLVED_LABEL_LOG"
	export TEST_PR_LABELS="origin:worker"

	_handle_post_merge_actions "754" "marcusquinn/aidevops" "25350" "" "origin:worker"

	assert_log_contains "$GH_CALL_LOG" "Completed via PR #754, merged to main" \
		"legacy post-merge callers default closing comment base ref to main"
	return 0
}

test_pr_closeout_reuses_merge_summary_comment() {
	: >"$GH_CALL_LOG"
	: >"$TIMEOUT_CALL_LOG"
	set_pr_comments '[{"id":101,"created_at":"2026-07-13T16:00:00Z","body":"<!-- MERGE_SUMMARY --> original"}]'

	_handle_post_merge_actions "755" "marcusquinn/aidevops" "" "merged" "origin:worker"

	assert_log_contains "$GH_CALL_LOG" "issues/comments/101 --method PATCH" \
		"PR closeout patches the canonical MERGE_SUMMARY comment"
	assert_log_contains "$GH_CALL_LOG" "PULSE_MERGE_CLOSEOUT:PR#755" \
		"patched PR closeout receives the deterministic singleton marker"
	assert_log_not_contains "$GH_CALL_LOG" "issues/755/comments --method POST" \
		"PR closeout does not append when MERGE_SUMMARY exists"
	assert_completion_candidate_count 1 755 \
		"MERGE_SUMMARY upsert leaves exactly one completion candidate"
	local bounded_read_count=""
	bounded_read_count=$(grep -cF 'read gh api repos/marcusquinn/aidevops/issues/755/comments?per_page=100 --paginate --slurp' \
		"$TIMEOUT_CALL_LOG" 2>/dev/null || true)
	if [[ "$bounded_read_count" -ge 3 ]]; then
		pass "PR closeout initial and reconciliation pagination reads are bounded"
	else
		fail "PR closeout initial and reconciliation pagination reads are bounded" \
			"Expected at least 3 bounded reads, found ${bounded_read_count}"
	fi
	return 0
}

test_pr_closeout_reuses_existing_closeout_comment() {
	: >"$GH_CALL_LOG"
	set_pr_comments '[{"id":201,"created_at":"2026-07-13T16:00:00Z","body":"<!-- PULSE_MERGE_CLOSEOUT:PR#756 --> existing"}]'

	_handle_post_merge_actions "756" "marcusquinn/aidevops" "" "merged" "origin:worker"
	_handle_post_merge_actions "756" "marcusquinn/aidevops" "" "merged" "origin:worker"

	assert_log_contains "$GH_CALL_LOG" "issues/comments/201 --method PATCH" \
		"repeated PR closeout handling updates the existing singleton"
	assert_log_not_contains "$GH_CALL_LOG" "issues/756/comments --method POST" \
		"repeated PR closeout handling never appends another summary"
	assert_completion_candidate_count 1 756 \
		"repeated PR closeout handling leaves exactly one completion candidate"
	return 0
}

test_pr_closeout_reconciles_concurrent_duplicates() {
	: >"$GH_CALL_LOG"
	set_pr_comments '[{"id":301,"created_at":"2026-07-13T16:00:00Z","body":"<!-- PULSE_MERGE_CLOSEOUT:PR#757 --> first"},{"id":302,"created_at":"2026-07-13T16:00:04Z","body":"<!-- MERGE_SUMMARY --> duplicate source"},{"id":303,"created_at":"2026-07-13T16:00:08Z","body":"duplicate closeout\nMerged via PR #757 to develop.\n_Merged by deterministic merge pass (pulse-wrapper.sh)._"},{"id":304,"created_at":"2026-07-13T16:00:12Z","body":"Completed via PR #757, merged to develop.\n_Merged by deterministic merge pass (pulse-wrapper.sh)._"}]'

	_handle_post_merge_actions "757" "marcusquinn/aidevops" "" "merged" "origin:worker"

	assert_log_contains "$GH_CALL_LOG" "issues/comments/301 --method PATCH" \
		"concurrent closeout reconciliation preserves the oldest singleton"
	assert_log_contains "$GH_CALL_LOG" "issues/comments/302 --method DELETE" \
		"concurrent closeout reconciliation deletes duplicate MERGE_SUMMARY comments"
	assert_log_contains "$GH_CALL_LOG" "issues/comments/303 --method DELETE" \
		"concurrent closeout reconciliation deletes legacy unmarked duplicates"
	assert_log_contains "$GH_CALL_LOG" "issues/comments/304 --method DELETE" \
		"concurrent closeout reconciliation deletes legacy generic duplicates"
	assert_completion_candidate_count 1 757 \
		"concurrent closeout reconciliation converges to one completion candidate"
	return 0
}

test_pr_closeout_rechecks_delayed_visibility() {
	: >"$GH_CALL_LOG"
	set_pr_comments '[{"id":401,"created_at":"2026-07-13T16:00:00Z","body":"<!-- PULSE_MERGE_CLOSEOUT:PR#759 --> first"},{"id":402,"created_at":"2026-07-13T16:00:08Z","body":"<!-- PULSE_MERGE_CLOSEOUT:PR#759 --> delayed duplicate"}]'
	set_comment_snapshots '[[{"id":402,"created_at":"2026-07-13T16:00:08Z","body":"<!-- PULSE_MERGE_CLOSEOUT:PR#759 --> delayed duplicate"}]]'

	_pm_reconcile_pr_closeout_comments "759" "marcusquinn/aidevops" \
		'<!-- PULSE_MERGE_CLOSEOUT:PR#759 --> canonical'

	assert_log_contains "$GH_CALL_LOG" "issues/comments/402 --method DELETE" \
		"reconciliation rechecks after an apparently clean delayed snapshot"
	assert_completion_candidate_count 1 759 \
		"delayed visibility reconciliation converges to one candidate"
	return 0
}

test_pr_closeout_preserves_duplicates_when_canonical_refresh_fails() {
	: >"$GH_CALL_LOG"
	export TEST_FAIL_PATCH_IDS="501"
	set_pr_comments '[{"id":501,"created_at":"2026-07-13T16:00:00Z","body":"<!-- MERGE_SUMMARY --> stale source"},{"id":502,"created_at":"2026-07-13T16:00:08Z","body":"<!-- PULSE_MERGE_CLOSEOUT:PR#760 --> valid fallback"}]'

	_pm_reconcile_pr_closeout_comments "760" "marcusquinn/aidevops" \
		'<!-- PULSE_MERGE_CLOSEOUT:PR#760 --> canonical'

	assert_log_not_contains "$GH_CALL_LOG" "--method DELETE" \
		"failed canonical refresh never deletes the valid fallback"
	assert_log_contains "$LOGFILE" "did not reach two stable singleton observations" \
		"failed canonical refresh reports exhausted convergence"
	assert_completion_candidate_count 2 760 \
		"failed canonical refresh preserves both recoverable candidates"
	export TEST_FAIL_PATCH_IDS=""
	return 0
}

test_pr_closeout_fallback_posts_marked_comment() {
	: >"$GH_CALL_LOG"
	set_pr_comments '[]'

	_handle_post_merge_actions "758" "marcusquinn/aidevops" "" "merged" "origin:worker"

	assert_log_contains "$GH_CALL_LOG" "issues/758/comments --method POST" \
		"PR closeout fallback posts when no reusable comment exists"
	assert_log_contains "$GH_CALL_LOG" "PULSE_MERGE_CLOSEOUT:PR#758" \
		"PR closeout fallback is marked for post-write convergence"
	assert_completion_candidate_count 1 758 \
		"PR closeout fallback leaves exactly one completion candidate"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	define_function_under_test
	install_helper_stubs

	test_provided_empty_pr_labels_skip_refetch
	test_omitted_pr_labels_fetches_fallback
	test_superseded_pr_closes_original_issue
	test_closing_comment_uses_pr_base_ref
	test_closing_comment_defaults_to_main_for_legacy_callers
	test_pr_closeout_reuses_merge_summary_comment
	test_pr_closeout_reuses_existing_closeout_comment
	test_pr_closeout_reconciles_concurrent_duplicates
	test_pr_closeout_rechecks_delayed_visibility
	test_pr_closeout_preserves_duplicates_when_canonical_refresh_fails
	test_pr_closeout_fallback_posts_marked_comment

	printf '\nTests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
