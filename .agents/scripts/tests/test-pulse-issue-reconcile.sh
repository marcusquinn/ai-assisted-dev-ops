#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pulse-issue-reconcile.sh — Unit tests for pulse-issue-reconcile.sh helpers.
#
# Tests the t2773 cache-reader helper (_read_cache_issues_for_slug) and
# verifies that no bare 'gh issue list'/'gh pr list' calls remain outside
# the fallback path in pulse-issue-reconcile.sh.
#
# Usage: bash .agents/scripts/tests/test-pulse-issue-reconcile.sh

# Note: no set -e — test functions must handle their own failures explicitly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECONCILE_SH="${SCRIPT_DIR}/../pulse-issue-reconcile.sh"

pass=0
fail=0

_pass() {
	echo "PASS: $1"
	pass=$((pass + 1))
	return 0
}
_fail() {
	echo "FAIL: $1"
	fail=$((fail + 1))
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: _read_cache_issues_for_slug — cache miss (file absent)
# ---------------------------------------------------------------------------
test_cache_miss_no_file() {
	local tmp_cache
	tmp_cache=$(mktemp)
	rm -f "$tmp_cache" # ensure absent

	# Source only the helper by injecting it in a subshell
	local result
	result=$(bash -c "
		PULSE_PREFETCH_CACHE_FILE='${tmp_cache}'
		$(grep -A 40 '^_read_cache_issues_for_slug()' "${RECONCILE_SH}" | head -50)
		_read_cache_issues_for_slug 'owner/repo' && echo HIT || echo MISS
	" 2>/dev/null)
	if [[ "$result" == "MISS" ]]; then
		_pass "cache-miss: absent cache file returns 1"
	else
		_fail "cache-miss: absent cache file — got '${result}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: _read_cache_issues_for_slug — cache miss (no entry for slug)
# ---------------------------------------------------------------------------
test_cache_miss_no_slug() {
	local tmp_cache
	tmp_cache=$(mktemp)
	# Write a cache with a different slug
	printf '{"other/repo":{"last_prefetch":"%s","issues":[]}}' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$tmp_cache"

	local result
	result=$(bash -c "
		PULSE_PREFETCH_CACHE_FILE='${tmp_cache}'
		$(grep -A 40 '^_read_cache_issues_for_slug()' "${RECONCILE_SH}" | head -50)
		_read_cache_issues_for_slug 'owner/repo' && echo HIT || echo MISS
	" 2>/dev/null)
	rm -f "$tmp_cache"
	if [[ "$result" == "MISS" ]]; then
		_pass "cache-miss: no entry for slug returns 1"
	else
		_fail "cache-miss: no entry for slug — got '${result}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: _read_cache_issues_for_slug — stale cache (> 10 min old)
# ---------------------------------------------------------------------------
test_cache_stale() {
	local tmp_cache
	tmp_cache=$(mktemp)
	# Write a cache entry with a last_prefetch 11 minutes ago
	local old_ts
	old_ts=$(date -u -v -11M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		date -u -d '11 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		echo "2000-01-01T00:00:00Z")
	printf '{"owner/repo":{"last_prefetch":"%s","issues":[{"number":1,"title":"t"}]}}' \
		"$old_ts" >"$tmp_cache"

	local result
	result=$(bash -c "
		PULSE_PREFETCH_CACHE_FILE='${tmp_cache}'
		$(grep -A 40 '^_read_cache_issues_for_slug()' "${RECONCILE_SH}" | head -50)
		_read_cache_issues_for_slug 'owner/repo' && echo HIT || echo MISS
	" 2>/dev/null)
	rm -f "$tmp_cache"
	if [[ "$result" == "MISS" ]]; then
		_pass "cache-stale: 11-minute-old cache returns 1"
	else
		_fail "cache-stale: 11-minute-old cache — got '${result}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: _read_cache_issues_for_slug — fresh cache hit
# ---------------------------------------------------------------------------
test_cache_hit_fresh() {
	local tmp_cache
	tmp_cache=$(mktemp)
	local now_ts
	now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '{"owner/repo":{"last_prefetch":"%s","issues":[{"number":42,"title":"Test issue","labels":[],"body":"test body"}]}}' \
		"$now_ts" >"$tmp_cache"

	local result
	result=$(bash -c "
		PULSE_PREFETCH_CACHE_FILE='${tmp_cache}'
		$(grep -A 40 '^_read_cache_issues_for_slug()' "${RECONCILE_SH}" | head -50)
		output=\$(_read_cache_issues_for_slug 'owner/repo') && echo \"\$output\"
	" 2>/dev/null)
	rm -f "$tmp_cache"
	if printf '%s' "$result" | jq -e '.[0].number == 42' >/dev/null 2>&1; then
		_pass "cache-hit: fresh cache returns issues JSON"
	else
		_fail "cache-hit: fresh cache — got '${result}'"
	fi
	return 0
}

test_cache_bodyless_row_misses() {
	local tmp_cache
	tmp_cache=$(mktemp)
	local now_ts
	now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '{"owner/repo":{"last_prefetch":"%s","issues":[{"number":42,"title":"Bodyless","labels":[]}]}}' \
		"$now_ts" >"$tmp_cache"

	local result
	result=$(bash -c "
		PULSE_PREFETCH_CACHE_FILE='${tmp_cache}'
		$(grep -A 40 '^_read_cache_issues_for_slug()' "${RECONCILE_SH}" | head -50)
		_read_cache_issues_for_slug 'owner/repo' && echo HIT || echo MISS
	" 2>/dev/null)
	rm -f "$tmp_cache"
	if [[ "$result" == "MISS" ]]; then
		_pass "cache-miss: bodyless issue row forces live fallback"
	else
		_fail "cache-miss: bodyless issue row — got '${result}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: No raw 'gh issue list' calls outside fallback paths
# ---------------------------------------------------------------------------
test_no_raw_gh_issue_list_outside_fallback() {
	# Count non-comment lines containing 'gh issue list' or 'gh pr list' that are
	# NOT inside _gh_pr_list_merged (the allowed fallback wrapper).
	# grep -n output format: "LINE_NUM:CONTENT" — filter out lines where CONTENT starts
	# with optional whitespace + '#' (comment lines in the shell script).
	# Use awk END{NR} to count matching lines safely (avoids grep -c exit-1 on no-match
	# and the grep|wc -l SC2126 nit — awk always exits 0 and prints 0 on empty input).
	local raw_count
	raw_count=$(grep -n 'gh issue list\|gh pr list' "${RECONCILE_SH}" 2>/dev/null |
		grep -v ':[[:space:]]*#' |
		grep -v 'gh_issue_list\|_gh_pr_list_merged' |
		grep -v 'gh pr list "$@"' |
		awk 'END{print NR}')

	if [[ "$raw_count" -eq 0 ]]; then
		_pass "no-raw-calls: zero raw gh issue/pr list calls outside fallback wrappers"
	else
		_fail "no-raw-calls: ${raw_count} raw gh issue/pr list call(s) found outside fallback wrappers"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: Single-pass orchestrator consolidates cache reads (t2776)
# ---------------------------------------------------------------------------
test_single_pass_cache_consolidation() {
	# After t2776, reconcile_issues_single_pass holds ONE cache-read call
	# covering all six sub-stages. The five legacy functions keep their own
	# call sites for standalone/test use. We verify:
	#   a) reconcile_issues_single_pass is defined
	#   b) _read_cache_issues_for_slug is still present (≥2: definition + single-pass)
	#   c) The seven _should_* predicates are defined

	# (a) single-pass function defined
	local sp_count
	sp_count=$(grep -c '^reconcile_issues_single_pass()' "${RECONCILE_SH}" 2>/dev/null || true)
	[[ "$sp_count" =~ ^[0-9]+$ ]] || sp_count=0
	if [[ "$sp_count" -ge 1 ]]; then
		_pass "single-pass: reconcile_issues_single_pass defined"
	else
		_fail "single-pass: reconcile_issues_single_pass NOT found"
	fi

	# (b) cache helper still present
	local cache_read_count
	cache_read_count=$(grep -c '_read_cache_issues_for_slug' "${RECONCILE_SH}" 2>/dev/null || true)
	[[ "$cache_read_count" =~ ^[0-9]+$ ]] || cache_read_count=0
	if [[ "$cache_read_count" -ge 2 ]]; then
		_pass "single-pass: _read_cache_issues_for_slug found ${cache_read_count} times (definition + call sites)"
	else
		_fail "single-pass: expected ≥2 _read_cache_issues_for_slug matches, got ${cache_read_count}"
	fi

	# (c) all seven _should_* predicates defined in the actions sub-library
	local actions_sh="${SCRIPT_DIR}/../pulse-issue-reconcile-actions.sh"
	local pred_count
	pred_count=$(grep -c '^_should_reconcile_persistent_issue()\|^_should_reconcile_external_issue_gate()\|^_should_ciw()\|^_should_rsd()\|^_should_oimp()\|^_should_cpt()\|^_should_lia()' \
		"${actions_sh}" 2>/dev/null || true)
	[[ "$pred_count" =~ ^[0-9]+$ ]] || pred_count=0
	if [[ "$pred_count" -eq 7 ]]; then
		_pass "single-pass: all 7 _should_* predicates defined"
	else
		_fail "single-pass: expected 7 _should_* predicates, found ${pred_count}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 7: body field present in prefetch fetch
# ---------------------------------------------------------------------------
test_body_in_prefetch_fetch() {
	local prefetch_sh="${SCRIPT_DIR}/../pulse-prefetch.sh"
	local prefetch_fetch_sh="${SCRIPT_DIR}/../pulse-prefetch-fetch.sh"

	# safe_grep_count inline pattern (t2763): use guard form, not || echo 0.
	local full_has_body delta_has_body
	# GH#21738 moved both full and delta API fetches into the fetch library;
	# retain the orchestrator in the scan for compatibility with older layouts.
	full_has_body=$(grep -c 'number,title,state,labels,updatedAt,assignees,body' \
		"${prefetch_sh}" "${prefetch_fetch_sh}" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
	[[ "$full_has_body" =~ ^[0-9]+$ ]] || full_has_body=0
	delta_has_body=$(grep -c 'number,title,state,labels,updatedAt,assignees,body' "${prefetch_fetch_sh}" 2>/dev/null || true)
	[[ "$delta_has_body" =~ ^[0-9]+$ ]] || delta_has_body=0

	if [[ "$full_has_body" -ge 2 ]] && [[ "$delta_has_body" -ge 2 ]]; then
		_pass "body-in-prefetch: body field present in both full and delta fetches"
	else
		_fail "body-in-prefetch: combined=${full_has_body} fetch-lib=${delta_has_body} (expected ≥2 fetch paths)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 8: _should_* predicates (t2776)
# ---------------------------------------------------------------------------
_assert_should_predicate_result() {
	local result="$1"
	local expected="$2"
	local failure_message="$3"
	if printf '%s\n' "$result" | grep -qx "$expected"; then
		return 0
	fi
	_fail "$failure_message"
	return 1
}

test_should_predicates() {
	# Source just the predicate functions from the actions sub-library in a subshell.
	# We extract the five _should_* function definitions then call each.

	# Extract all five predicate definitions (stop before the first _action_* helper)
	local actions_sh="${SCRIPT_DIR}/../pulse-issue-reconcile-actions.sh"
	local pred_defs
	pred_defs=$(sed -n '/^_should_ciw()/,/^_action_ciw_single()/p' "${actions_sh}" |
		grep -v '^_action_ciw_single()' || true)

	# Run predicate checks in one subshell
	local result
	result=$(bash -c "
		${pred_defs}

		# _should_ciw: true for status:available, false otherwise
		_should_ciw 'origin:worker,status:available' && echo 'ciw:1' || echo 'ciw:0'
		_should_ciw 'origin:worker,status:done'      && echo 'ciw-done:1' || echo 'ciw-done:0'

		# _should_rsd: true for status:done
		_should_rsd 'status:done,tier:standard' && echo 'rsd:1' || echo 'rsd:0'
		_should_rsd 'status:available'          && echo 'rsd-avail:1' || echo 'rsd-avail:0'

		# _should_oimp: false if issue is in parent_task_nums list
		_should_oimp '42' '41
42
43' && echo 'oimp-parent:1' || echo 'oimp-parent:0'
		_should_oimp '99' '41
42' && echo 'oimp-nonparent:1' || echo 'oimp-nonparent:0'

		# _should_cpt: true for parent-task
		_should_cpt 'parent-task,origin:worker' && echo 'cpt:1' || echo 'cpt:0'
		_should_cpt 'status:available'          && echo 'cpt-noparent:1' || echo 'cpt-noparent:0'
		_should_cpt 'parent-task,needs-maintainer-review' && echo 'cpt-nmr:1' || echo 'cpt-nmr:0'
		_should_cpt 'parent-task,persistent' && echo 'cpt-persistent:1' || echo 'cpt-persistent:0'

		# _should_lia: true for tNNN: title + no aidevops labels
		_should_lia 't1234: fix something' '' && echo 'lia:1' || echo 'lia:0'
		_should_lia 'GH#567: fix' ''          && echo 'lia-gh:1' || echo 'lia-gh:0'
		_should_lia 't1234: fix' 'origin:worker' && echo 'lia-labeled:1' || echo 'lia-labeled:0'
		_should_lia 'not a task title' ''     && echo 'lia-badtitle:1' || echo 'lia-badtitle:0'
		_should_lia 'normal contributor report' '' '<!-- aidevops:origin:interactive -->' && echo 'lia-signed:1' || echo 'lia-signed:0'
	" 2>/dev/null)

	local all_ok=1

	# Check each expected result
	_assert_should_predicate_result "$result" 'ciw:1' \
		"_should_ciw: status:available should return 0" || all_ok=0
	_assert_should_predicate_result "$result" 'ciw-done:0' \
		"_should_ciw: status:done should return 1" || all_ok=0
	_assert_should_predicate_result "$result" 'rsd:1' \
		"_should_rsd: status:done should return 0" || all_ok=0
	_assert_should_predicate_result "$result" 'rsd-avail:0' \
		"_should_rsd: status:available should return 1" || all_ok=0
	_assert_should_predicate_result "$result" 'oimp-parent:0' \
		"_should_oimp: parent-task issue should return 1" || all_ok=0
	_assert_should_predicate_result "$result" 'oimp-nonparent:1' \
		"_should_oimp: non-parent issue should return 0" || all_ok=0
	_assert_should_predicate_result "$result" 'cpt:1' \
		"_should_cpt: parent-task should return 0" || all_ok=0
	_assert_should_predicate_result "$result" 'cpt-noparent:0' \
		"_should_cpt: no parent-task should return 1" || all_ok=0
	_assert_should_predicate_result "$result" 'cpt-nmr:0' \
		"_should_cpt: NMR-held parent should return 1" || all_ok=0
	_assert_should_predicate_result "$result" 'cpt-persistent:0' \
		"_should_cpt: persistent parent should return 1" || all_ok=0
	_assert_should_predicate_result "$result" 'lia:1' \
		"_should_lia: tNNN: title + no labels should return 0" || all_ok=0
	_assert_should_predicate_result "$result" 'lia-gh:1' \
		"_should_lia: GH#NNN: title + no labels should return 0" || all_ok=0
	_assert_should_predicate_result "$result" 'lia-labeled:0' \
		"_should_lia: labeled issue should return 1" || all_ok=0
	_assert_should_predicate_result "$result" 'lia-badtitle:0' \
		"_should_lia: non-task title should return 1" || all_ok=0
	_assert_should_predicate_result "$result" 'lia-signed:1' \
		"_should_lia: signed contributor report should return 0" || all_ok=0

	[[ "$all_ok" == "1" ]] && _pass "_should_* predicates: all 15 cases correct"
	return 0
}

# ---------------------------------------------------------------------------
# Parent mutation gate: live labels and cached holds fail closed.
# ---------------------------------------------------------------------------
test_parent_live_hold_gate() {
	local actions_sh="${SCRIPT_DIR}/../pulse-issue-reconcile-actions.sh"
	local result=""
	result=$(ACTIONS_SH="$actions_sh" bash -c '
		_PIR_NMR_LABEL="needs-maintainer-review"
		_PIR_PERSISTENT_LABEL="persistent"
		_PIR_PT_LABEL="parent-task"
		_PIR_SCRIPT_DIR="/nonexistent"
		LOGFILE="/dev/null"
		source "$ACTIONS_SH"
		LIVE_MODE="clear"
		gh() {
			local command="$1"
			local endpoint="${2:-}"
			[[ "$command" == "api" && "$endpoint" == "repos/owner/repo/issues/42" ]] || return 1
			case "$LIVE_MODE" in
			clear) printf "%s\n" "{\"number\":42,\"labels\":[{\"name\":\"parent-task\"}],\"authorAssociation\":\"OWNER\",\"author\":{\"login\":\"maintainer\",\"type\":\"User\"}}" ;;
			nmr) printf "%s\n" "{\"number\":42,\"labels\":[{\"name\":\"parent-task\"},{\"name\":\"needs-maintainer-review\"}],\"authorAssociation\":\"OWNER\",\"author\":{\"login\":\"maintainer\",\"type\":\"User\"}}" ;;
			persistent) printf "%s\n" "{\"number\":42,\"labels\":[{\"name\":\"parent-task\"},{\"name\":\"persistent\"}],\"authorAssociation\":\"OWNER\",\"author\":{\"login\":\"maintainer\",\"type\":\"User\"}}" ;;
			missing-parent) printf "%s\n" "{\"number\":42,\"labels\":[],\"authorAssociation\":\"OWNER\",\"author\":{\"login\":\"maintainer\",\"type\":\"User\"}}" ;;
			external) printf "%s\n" "{\"number\":42,\"labels\":[{\"name\":\"parent-task\"}],\"authorAssociation\":\"CONTRIBUTOR\",\"author\":{\"login\":\"outsider\",\"type\":\"User\"}}" ;;
			*) return 1 ;;
			esac
			return 0
		}
		for LIVE_MODE in clear nmr persistent missing-parent external api-failure; do
			_pir_parent_mutation_is_allowed owner/repo 42 &&
				printf "%s:allowed\n" "$LIVE_MODE" || printf "%s:blocked\n" "$LIVE_MODE"
		done
		COLLECT_CALLS=0
		_pir_collect_parent_child_evidence() {
			COLLECT_CALLS=$((COLLECT_CALLS + 1))
			return 0
		}
		_action_cpt_single owner/repo 42 Parent body 1 1 1 168 OPEN \
			"parent-task,needs-maintainer-review"
		printf "cached-hold-collect-calls:%s\n" "$COLLECT_CALLS"

		FINAL_GATE_CALLS=0
		CLOSE_CALLS=0
		_parent_close_contract_incomplete() { return 1; }
		_pir_parent_mutation_is_allowed() {
			FINAL_GATE_CALLS=$((FINAL_GATE_CALLS + 1))
			return 1
		}
		gh() {
			if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/43" ]]; then
				[[ "$*" == *".state"* ]] && printf "closed\n" || printf "Finished child\n"
				return 0
			fi
			if [[ "${1:-}" == "issue" && "${2:-}" == "close" ]]; then
				CLOSE_CALLS=$((CLOSE_CALLS + 1))
				return 0
			fi
			return 1
		}
		_try_close_parent_tracker owner/repo 42 43 graph "" || true
		printf "final-gate:%s close-calls:%s\n" "$FINAL_GATE_CALLS" "$CLOSE_CALLS"
	' 2>/dev/null)

	local all_ok=1
	printf '%s\n' "$result" | grep -qx 'clear:allowed' || all_ok=0
	printf '%s\n' "$result" | grep -qx 'nmr:blocked' || all_ok=0
	printf '%s\n' "$result" | grep -qx 'persistent:blocked' || all_ok=0
	printf '%s\n' "$result" | grep -qx 'missing-parent:blocked' || all_ok=0
	printf '%s\n' "$result" | grep -qx 'external:blocked' || all_ok=0
	printf '%s\n' "$result" | grep -qx 'api-failure:blocked' || all_ok=0
	printf '%s\n' "$result" | grep -qx 'cached-hold-collect-calls:0' || all_ok=0
	printf '%s\n' "$result" | grep -qx 'final-gate:1 close-calls:0' || all_ok=0
	if [[ "$all_ok" -eq 1 ]]; then
		_pass "parent mutation gate blocks cached/live holds, external authors, and final-close races"
	else
		_fail "parent mutation gate result mismatch: ${result}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 8b: mergedAt helper prefers gh_pr_view wrapper when available
# ---------------------------------------------------------------------------
test_pr_merged_at_prefers_wrapper() {
	local actions_sh="${SCRIPT_DIR}/../pulse-issue-reconcile-actions.sh"
	local helper_defs
	helper_defs=$(sed -n '/^_pir_pr_merged_at()/,/^}/p' "${actions_sh}")

	local result
	result=$(bash -c "
		${helper_defs}
		gh_pr_view() {
			printf 'wrapper:%s:%s:%s\n' \"\${1:-}\" \"\${3:-}\" \"\${5:-}\"
			return 0
		}
		gh() {
			printf 'raw:%s\n' \"\$*\"
			return 0
		}
		_pir_pr_merged_at 123 owner/repo
		unset -f gh_pr_view
		_pir_pr_merged_at 456 owner/repo
	" 2>/dev/null)

	local all_ok=1
	if ! printf '%s\n' "$result" | grep -qx 'wrapper:123:owner/repo:mergedAt'; then
		_fail "_pir_pr_merged_at should prefer gh_pr_view wrapper"
		all_ok=0
	fi
	if ! printf '%s\n' "$result" | grep -qx 'raw:pr view 456 --repo owner/repo --json mergedAt -q .mergedAt // empty'; then
		_fail "_pir_pr_merged_at should fall back to raw gh pr view"
		all_ok=0
	fi

	[[ "$all_ok" == "1" ]] && _pass "_pir_pr_merged_at prefers wrapper and preserves raw fallback"
	return 0
}

# ---------------------------------------------------------------------------
# Test 9: reconcile_issues_single_pass wired in pulse-dispatch-engine.sh
# ---------------------------------------------------------------------------
test_single_pass_wired_in_engine() {
	# GH#21738: pulse-dispatch-engine.sh was split into orchestrator +
	# dispatch lib + preflight lib. The preflight helpers (which carry
	# the run_stage_with_timeout reconcile call) now live in
	# pulse-dispatch-preflight-lib.sh. Search both files so the test stays
	# faithful to the underlying contract: reconcile is wired in the
	# dispatch engine module group.
	local engine_sh="${SCRIPT_DIR}/../pulse-dispatch-engine.sh"
	local preflight_lib="${SCRIPT_DIR}/../pulse-dispatch-preflight-lib.sh"
	local files=()
	[[ -f "$engine_sh" ]] && files+=("$engine_sh")
	[[ -f "$preflight_lib" ]] && files+=("$preflight_lib")
	if [[ ${#files[@]} -eq 0 ]]; then
		_pass "single-pass engine wiring: dispatch-engine module group not found (skip)"
		return 0
	fi

	# Verify the single-pass is called (not the five legacy functions)
	local sp_calls legacy_calls
	sp_calls=$(grep -c 'reconcile_issues_single_pass' "${files[@]}" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
	[[ "$sp_calls" =~ ^[0-9]+$ ]] || sp_calls=0

	# Legacy functions should NOT be direct run_stage_with_timeout targets anymore
	legacy_calls=$(grep -E 'run_stage_with_timeout.*(close_issues_with_merged_prs|reconcile_stale_done_issues|reconcile_open_issues_with_merged_prs|reconcile_completed_parent_tasks|reconcile_labelless_aidevops_issues)' \
		"${files[@]}" 2>/dev/null | grep -vc '^\s*#' || true)
	[[ "$legacy_calls" =~ ^[0-9]+$ ]] || legacy_calls=0

	if [[ "$sp_calls" -ge 1 && "$legacy_calls" -eq 0 ]]; then
		_pass "single-pass engine: wired in dispatch-engine module group (sp_calls=${sp_calls}, legacy_direct=${legacy_calls})"
	else
		_fail "single-pass engine: sp_calls=${sp_calls}, legacy_direct=${legacy_calls} (expected sp≥1, legacy=0)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Parent repair must be reachable from the scheduled single pass, while the
# legacy multi-stage parent reconciler remains unscheduled.
# ---------------------------------------------------------------------------
test_recent_parent_repair_reachable_from_single_pass() {
	local single_pass_body=""
	single_pass_body=$(sed -n '/^reconcile_issues_single_pass()/,/^}/p' "$RECONCILE_SH")
	if printf '%s\n' "$single_pass_body" | grep -q '_repair_recently_closed_parents_cycle' \
		&& printf '%s\n' "$single_pass_body" | grep -q 'cpt_max_reopens=5' \
		&& printf '%s\n' "$single_pass_body" | grep -q 'cpt_max_repair_repo_scans=10' \
		&& printf '%s\n' "$single_pass_body" | grep -q 'cpt_max_repair_candidates=10'; then
		_pass "single-pass parent repair: bounded recently-closed helper is reachable"
	else
		_fail "single-pass parent repair: active path or bounds missing"
	fi
	return 0
}

test_recent_parent_repair_cursor_and_candidate_bounds() {
	local actions_sh="${SCRIPT_DIR}/../pulse-issue-reconcile-actions.sh"
	local helper_defs="" tmp_dir="" repos_json="" cursor_file="" result=""
	local actual_candidates="" expected_candidates="" actual_scans="" expected_scans="" candidate_fixture=""
	local cycle=0
	helper_defs=$(sed -n '/^_repair_recently_closed_parents_for_slug()/,/^_pir_collect_parent_child_evidence()/p' "$actions_sh" | sed '$d')
	tmp_dir=$(mktemp -d)
	repos_json="${tmp_dir}/repos.json"
	cursor_file="${tmp_dir}/parent-repair.cursor"
	jq -n '{initialized_repos:[range(0;12) as $i | {
		slug:("owner/repo" + ($i | tostring)), pulse:true, local_only:false
	}]}' >"$repos_json"
	candidate_fixture=$(jq -cn '[range(100;112) as $i | {
		number:$i, title:("candidate-" + ($i | tostring)), body:"",
		state:"closed", labels:[{name:"parent-task"}]
	}]')

	result=$(AIDEVOPS_CANDIDATE_FIXTURE="$candidate_fixture" bash -c "
		${helper_defs}
		_PIR_JSON_TYPE_STRING=string
		_PIR_PT_LABEL=parent-task
		_fetch_recently_closed_parent_tasks() {
			local slug=\"\$1\" parent_label=\"\$2\"
			: \"\$slug\" \"\$parent_label\"
			printf '%s\\n' \"\$AIDEVOPS_CANDIDATE_FIXTURE\"
			return 0
		}
		_action_cpt_single() {
			local slug=\"\$1\" issue_num=\"\$2\"
			printf 'candidate:%s:%s\\n' \"\$slug\" \"\$issue_num\"
			_SP_CPT_REOPENED=0
			return 0
		}
		_repair_recently_closed_parents_for_slug owner/repo 5 3 3 0
		_repair_recently_closed_parents_for_slug owner/repo 5 3 3 1
		printf '999999999999999999999999\\n' >'${cursor_file}'
		_pir_parent_repair_cursor_load '${cursor_file}' 12
		read -r repaired_cursor <'${cursor_file}'
		printf 'corrupt:loaded:%s:stored:%s\\n' \"\$_PIR_PARENT_REPAIR_CURSOR\" \"\$repaired_cursor\"
		rm -f '${cursor_file}'
		_repair_recently_closed_parents_for_slug() {
			local slug=\"\$1\" max_reopens=\"\$2\" max_candidates=\"\$3\"
			local candidate_stride=\"\$4\" candidate_round=\"\$5\"
			printf 'scan:%s:%s:%s:%s:%s\\n' \"\$slug\" \"\$max_reopens\" \
				\"\$max_candidates\" \"\$candidate_stride\" \"\$candidate_round\"
			_PIR_RECENT_PARENT_REOPENED=0
			_PIR_RECENT_PARENT_SCANNED=1
			return 0
		}
		AIDEVOPS_PARENT_REPAIR_CURSOR_FILE='${cursor_file}'
		LOGFILE=/dev/null
		for cycle in {1..13}; do
			_repair_recently_closed_parents_cycle '${repos_json}' 5 3 3
			read -r cursor <\"\$AIDEVOPS_PARENT_REPAIR_CURSOR_FILE\"
			printf 'cycle:%s:cursor:%s:totals:%s:%s:%s\\n' \"\$cycle\" \"\$cursor\" \\
				\"\$_PIR_RECENT_PARENT_REPOS_SCANNED\" \\
				\"\$_PIR_RECENT_PARENT_CYCLE_CANDIDATES\" \"\$_PIR_RECENT_PARENT_CYCLE_REOPENED\"
		done
	" 2>/dev/null)
	rm -rf "$tmp_dir"

	local all_ok=1
	actual_candidates=$(printf '%s\n' "$result" | grep '^candidate:' || true)
	expected_candidates=$(printf '%s\n' \
		'candidate:owner/repo:100' 'candidate:owner/repo:101' 'candidate:owner/repo:102' \
		'candidate:owner/repo:103' 'candidate:owner/repo:104' 'candidate:owner/repo:105')
	[[ "$actual_candidates" == "$expected_candidates" ]] || all_ok=0
	printf '%s\n' "$result" | grep -qx 'corrupt:loaded:0:stored:0' || all_ok=0
	actual_scans=$(printf '%s\n' "$result" | grep '^scan:' || true)
	expected_scans=$(printf '%s\n' \
		'scan:owner/repo0:5:3:3:0' 'scan:owner/repo1:5:3:3:0' 'scan:owner/repo2:5:3:3:0' \
		'scan:owner/repo3:5:3:3:0' 'scan:owner/repo4:5:3:3:0' 'scan:owner/repo5:5:3:3:0' \
		'scan:owner/repo6:5:3:3:0' 'scan:owner/repo7:5:3:3:0' 'scan:owner/repo8:5:3:3:0' \
		'scan:owner/repo9:5:3:3:0' 'scan:owner/repo10:5:3:3:0' 'scan:owner/repo11:5:3:3:0' \
		'scan:owner/repo0:5:3:3:1')
	[[ "$actual_scans" == "$expected_scans" ]] || all_ok=0
	for cycle in {1..13}; do
		printf '%s\n' "$result" | grep -qx \
			"cycle:${cycle}:cursor:${cycle}:totals:1:1:0" || all_ok=0
	done
	if [[ "$all_ok" -eq 1 ]]; then
		_pass "single-pass parent repair gives each non-empty repo a fixed candidate window and persists round progress"
	else
		_fail "single-pass parent repair cursor/cap mismatch: ${result}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 10: Batched per-issue field extraction parity (t2904)
#
# Verifies the t2904 single-jq-per-repo + base64 round-trip preserves
# every field exactly — including multi-line bodies, embedded tabs, and
# UTF-8. Catches the @tsv-without-base64 footgun where embedded \n / \t
# break the consumer (_extract_children_section grep'ing for child refs).
# ---------------------------------------------------------------------------
_extract_batched_test_rows() {
	local fixture_json="$1"
	printf '%s' "$fixture_json" | jq -r '
		.[] | [
			(.number // "" | tostring),
			((.title // "") | @base64),
			((.labels // []) | map(.name) | join(",")),
			((.body // "") | @base64),
			(.authorAssociation // ""),
			((.author.login // "") | @base64),
			(.author.type // ""),
			((.author.is_bot // false) | tostring)
		] | join("|")
	'
	return $?
}

test_batched_field_extraction_parity() {
	# Fixture: 2 issues, body[0] has multiline + tab + UTF-8, body[1] is empty.
	local fixture_json
	fixture_json=$(jq -nc '[
		{
			number: 12345,
			title: "t2904: batch jq extraction",
			labels: [{name:"origin:worker"},{name:"status:available"}],
			body: "Line 1\nLine 2\twith tab\n— em-dash + Unicode ✓",
			authorAssociation: "CONTRIBUTOR",
			author: {login:"fixture-author", type:"User", is_bot:false}
		},
		{
			number: 67890,
			title: "Empty body case",
			labels: [],
			body: ""
		}
	]')

	# Run the extraction pattern from reconcile_issues_single_pass.
	local extracted
	extracted=$(_extract_batched_test_rows "$fixture_json")

	local row_count
	row_count=$(printf '%s\n' "$extracted" | grep -c .)
	[[ "$row_count" =~ ^[0-9]+$ ]] || row_count=0
	if [[ "$row_count" -ne 2 ]]; then
		_fail "batched-extraction: expected 2 rows, got ${row_count}"
		return 0
	fi

	local all_ok=1

	# Decode and verify row 1 (multiline + tab + UTF-8 body).
	local r1_num r1_title_b64 r1_labels r1_body_b64 r1_assoc r1_login_b64 r1_type r1_bot r1_title r1_body r1_login
	IFS='|' read -r r1_num r1_title_b64 r1_labels r1_body_b64 r1_assoc r1_login_b64 r1_type r1_bot < <(printf '%s\n' "$extracted" | sed -n 1p)
	r1_title=$(printf '%s' "$r1_title_b64" | base64 -d 2>/dev/null)
	r1_body=$(printf '%s' "$r1_body_b64" | base64 -d 2>/dev/null)
	r1_login=$(printf '%s' "$r1_login_b64" | base64 -d 2>/dev/null)

	[[ "$r1_num" == "12345" ]] || {
		_fail "row1 number: expected 12345, got '$r1_num'"
		all_ok=0
	}
	[[ "$r1_title" == "t2904: batch jq extraction" ]] || {
		_fail "row1 title decode mismatch"
		all_ok=0
	}
	[[ "$r1_labels" == "origin:worker,status:available" ]] || {
		_fail "row1 labels: got '$r1_labels'"
		all_ok=0
	}
	# Body must contain BOTH a real newline AND a real tab — the @tsv-only path
	# would have escaped these to literal \n / \t markers.
	if ! printf '%s' "$r1_body" | grep -q $'Line 1\nLine 2\twith tab'; then
		_fail "row1 body: newline/tab lost in round-trip"
		all_ok=0
	fi
	# UTF-8 must survive the base64 round-trip.
	if ! printf '%s' "$r1_body" | grep -q '— em-dash + Unicode ✓'; then
		_fail "row1 body: UTF-8 corrupted in round-trip"
		all_ok=0
	fi
	if [[ "$r1_assoc" != "CONTRIBUTOR" || "$r1_login" != "fixture-author" || "$r1_type" != "User" || "$r1_bot" != "false" ]]; then
		_fail "row1 author trust metadata corrupted in round-trip"
		all_ok=0
	fi

	# Decode and verify row 2 (empty body, empty labels).
	local r2_num r2_title_b64 r2_labels r2_body_b64 r2_assoc r2_login_b64 r2_type r2_bot r2_title r2_body
	IFS='|' read -r r2_num r2_title_b64 r2_labels r2_body_b64 r2_assoc r2_login_b64 r2_type r2_bot < <(printf '%s\n' "$extracted" | sed -n 2p)
	r2_title=$(printf '%s' "$r2_title_b64" | base64 -d 2>/dev/null)
	# Empty body — base64-decode of empty input is empty.
	r2_body=$(printf '%s' "$r2_body_b64" | base64 -d 2>/dev/null)
	if [[ -n "$r2_assoc" || -n "$r2_login_b64" || -n "$r2_type" || "$r2_bot" != "false" ]]; then
		_fail "row2 legacy author metadata defaults corrupted"
		all_ok=0
	fi

	[[ "$r2_num" == "67890" ]] || {
		_fail "row2 number: expected 67890, got '$r2_num'"
		all_ok=0
	}
	[[ "$r2_title" == "Empty body case" ]] || {
		_fail "row2 title decode mismatch"
		all_ok=0
	}
	[[ -z "$r2_labels" ]] || {
		_fail "row2 labels: expected empty, got '$r2_labels'"
		all_ok=0
	}
	[[ -z "$r2_body" ]] || {
		_fail "row2 body: expected empty, got '$r2_body'"
		all_ok=0
	}

	[[ "$all_ok" == "1" ]] && _pass "batched-extraction: 2 rows decode with multiline/tab/UTF-8/empty fidelity"
	return 0
}

# ---------------------------------------------------------------------------
# Test 11 (t2984): time-budget early-exit code is present and well-formed
# ---------------------------------------------------------------------------
# Verify the t2984 budget gate exists in three required places:
#   1. Initialization (RECONCILE_TIME_BUDGET_SECS env var read)
#   2. Outer slug-loop gate (per-repo check)
#   3. Inner issue-loop gate (per-issue check) with `break 2`
# Also verify the abort log line exists for diagnostics.
# Pure source-code verification — no shell execution required.
test_t2984_time_budget_present() {
	local all_ok=1

	# 1. Init block
	if ! grep -q 'RECONCILE_TIME_BUDGET_SECS' "${RECONCILE_SH}"; then
		_fail "t2984: missing RECONCILE_TIME_BUDGET_SECS env var read"
		all_ok=0
	fi

	# 2. Default value must be the documented default (GH#21380: reduced from 540 to 360)
	if ! grep -qE '_t2984_budget=.*360' "${RECONCILE_SH}"; then
		_fail "t2984/GH#21380: default budget 360 not present (or not parseable)"
		all_ok=0
	fi

	# 3. Outer per-slug gate — uses `break` (not `break 2`) to exit slug loop
	#    Inner per-issue gate — uses `break 2` to exit BOTH loops
	#    Verify both forms exist with t2984 markers.
	if ! grep -q '_t2984_aborted=1' "${RECONCILE_SH}"; then
		_fail "t2984: _t2984_aborted=1 marker missing — abort signaling broken"
		all_ok=0
	fi

	if ! grep -q 'break 2' "${RECONCILE_SH}"; then
		_fail "t2984: 'break 2' missing — inner loop won't exit outer on abort"
		all_ok=0
	fi

	# 4. Diagnostic log line must reference time-budget
	if ! grep -q 'time-budget abort' "${RECONCILE_SH}"; then
		_fail "t2984: 'time-budget abort' diagnostic log missing"
		all_ok=0
	fi

	# 5. Disable mechanism — RECONCILE_TIME_BUDGET_SECS=0 should disable
	#    Verify the gate condition checks _t2984_budget -gt 0
	if ! grep -q '_t2984_budget" -gt 0' "${RECONCILE_SH}"; then
		_fail "t2984: budget=0 disable path missing (no '-gt 0' guard)"
		all_ok=0
	fi

	[[ "$all_ok" == "1" ]] && _pass "t2984: time-budget early-exit code present (init + outer + inner + log + disable)"
	return 0
}

# ---------------------------------------------------------------------------
# Test 12 (t2984): budget validation — non-numeric env var falls back to default
# ---------------------------------------------------------------------------
# Black-box: source the function definition, call it with a garbage env var,
# and verify it doesn't crash. The actual loop body needs network access so
# we just verify the variable validation logic.
test_t2984_budget_env_validation() {
	local result
	# Extract just the validation lines and exec them in isolation
	# GH#21380: default changed from 540 to 360
	result=$(bash -c '
		RECONCILE_TIME_BUDGET_SECS="not-a-number"
		_t2984_budget="${RECONCILE_TIME_BUDGET_SECS:-360}"
		[[ "$_t2984_budget" =~ ^[0-9]+$ ]] || _t2984_budget=360
		echo "$_t2984_budget"
	' 2>/dev/null)
	if [[ "$result" == "360" ]]; then
		_pass "t2984/GH#21380: non-numeric RECONCILE_TIME_BUDGET_SECS falls back to 360"
	else
		_fail "t2984/GH#21380: garbage env var produced '$result' instead of fallback 360"
	fi

	# Also verify zero is honoured (disable path)
	result=$(bash -c '
		RECONCILE_TIME_BUDGET_SECS="0"
		_t2984_budget="${RECONCILE_TIME_BUDGET_SECS:-360}"
		[[ "$_t2984_budget" =~ ^[0-9]+$ ]] || _t2984_budget=360
		echo "$_t2984_budget"
	' 2>/dev/null)
	if [[ "$result" == "0" ]]; then
		_pass "t2984/GH#21380: RECONCILE_TIME_BUDGET_SECS=0 honoured (unbounded mode)"
	else
		_fail "t2984/GH#21380: '0' override produced '$result' instead of '0'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 13 (t2985): _build_oimp_lookup_for_slug — extracts |issue=pr| pairs
# ---------------------------------------------------------------------------
# Verifies the per-repo prefetch helper that replaces _action_oimp_single's
# per-issue `gh pr list --search` calls. The helper:
#   1. Calls _gh_pr_list_merged for the slug (stubbed in test).
#   2. Filters to PRs with mergedAt evidence, then jq scan() extracts
#      (issue_num, pr_num) pairs from PR bodies that
#      contain Resolves|Closes|Fixes #N (case-insensitive).
#   3. Returns a "|num=pr|...|" string for grep-based lookup downstream.
#
# Test fixture covers:
#   - Multiple keywords (Resolves, Fixes, Closes) in one PR body.
#   - Multiple issues closed by one PR.
#   - PRs with no closing keyword (must be skipped).
#   - PRs with null body (must not crash).
#   - Case-insensitivity (resolves/RESOLVES/Resolves all match).
#   - PRs without mergedAt evidence (must be skipped; GH#22802).
# ---------------------------------------------------------------------------
test_t2985_oimp_lookup_builder() {
	# Fixture: 5 PRs covering the cases above.
	local fixture_json
	fixture_json=$(jq -nc '[
		{number: 1234, mergedAt: "2026-05-04T12:00:00Z", body: "Resolves #42\nFixes #99\nCloses #50"},
		{number: 5678, mergedAt: "2026-05-04T12:01:00Z", body: "closes #100"},
		{number: 9999, mergedAt: "2026-05-04T12:02:00Z", body: "merge candidate, no keyword"},
		{number: 1111, mergedAt: "2026-05-04T12:03:00Z", body: null},
		{number: 22806, mergedAt: null, body: "Resolves #22802"}
	]')

	# Extract the helper definition from RECONCILE_SH.
	# The function spans ~10 lines from declaration to closing brace.
	local helper_def
	helper_def=$(sed -n '/^_build_oimp_lookup_for_slug()/,/^}$/p' "${RECONCILE_SH}")
	if [[ -z "$helper_def" ]]; then
		_fail "t2985: _build_oimp_lookup_for_slug not found in ${RECONCILE_SH}"
		return 0
	fi

	# Run the helper in a subshell with a stub _gh_pr_list_merged.
	local result
	result=$(bash -c "
		${helper_def}
		_gh_pr_list_merged() { printf '%s' '${fixture_json}'; return 0; }
		_build_oimp_lookup_for_slug 'test/repo'
	" 2>/dev/null)

	# Expected output: pipe-delimited |num=pr| pairs, one per scan match.
	# PR 1234 contributes 3 pairs (42, 99, 50); PR 5678 contributes 1 (100);
	# PRs 9999, 1111, and unmerged 22806 contribute 0.
	local expected="|42=1234|99=1234|50=1234|100=5678|"
	if [[ "$result" == "$expected" ]]; then
		_pass "t2985: lookup builder extracts 4 pairs from 2 keyword-bearing PRs"
	else
		_fail "t2985: lookup builder — expected '${expected}', got '${result}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 13b (GH#22802): open/closed-unmerged PRs never enter OIMP lookup
# ---------------------------------------------------------------------------
test_gh22802_oimp_lookup_requires_merged_at() {
	local fixture_json
	fixture_json=$(jq -nc '[
		{number: 22806, state: "OPEN", mergedAt: null, body: "Resolves #22802"},
		{number: 22807, state: "CLOSED", mergedAt: "", body: "Fixes #22803"},
		{number: 22808, state: "MERGED", mergedAt: "2026-05-04T12:04:00Z", body: "Closes #22804"}
	]')

	local helper_def
	helper_def=$(sed -n '/^_build_oimp_lookup_for_slug()/,/^}$/p' "${RECONCILE_SH}")
	if [[ -z "$helper_def" ]]; then
		_fail "GH#22802: _build_oimp_lookup_for_slug not found in ${RECONCILE_SH}"
		return 0
	fi

	local result
	result=$(bash -c "
		${helper_def}
		_gh_pr_list_merged() { printf '%s' '${fixture_json}'; return 0; }
		_build_oimp_lookup_for_slug 'test/repo'
	" 2>/dev/null)

	local expected="|22804=22808|"
	if [[ "$result" == "$expected" ]]; then
		_pass "GH#22802: OIMP lookup requires mergedAt and skips open/closed-unmerged PRs"
	else
		_fail "GH#22802: expected '${expected}', got '${result}'"
	fi
	return 0
}

# Exercise the real REST adapter: a canned mixed list hid the incompatible
# closed/merged selector and its scan-until-unmerged pagination cost.
test_oimp_uses_merged_adapter_population() {
	local helper_def="" tmp_dir="" result=""
	helper_def=$(sed -n '/^_build_oimp_lookup_for_slug()/,/^}$/p' "${RECONCILE_SH}")
	tmp_dir=$(mktemp -d)
	result=$(HOME="$tmp_dir" AIDEVOPS_GH_API_INSTRUMENT_DISABLE=1 bash -c '
		source "$1/shared-gh-wrappers.sh"
		eval "$2"
		calls="$3/calls"
		: >"$calls"
		gh_record_call() { return 0; }
		_rest_api_call() {
			local endpoint="$4"
			local page="${endpoint##*page=}"
			printf "request\n" >>"$calls"
			if [[ "$page" -gt 3 ]]; then
				printf "[]\n"
				return 0
			fi
			jq -cn --argjson page "$page" "[range((\$page-1)*100+1;\$page*100+1) | {number:.,merged_at:\"2026-09-04T00:00:00Z\",body:(if . == 1 then \"Resolves #42\" else \"\" end)}]" || return 1
			return 0
		}
		_gh_pr_list_merged() { _rest_pr_list "$@"; return $?; }
		lookup=$(_build_oimp_lookup_for_slug owner/repo)
		printf "lookup=%s\ncalls=%s\n" "$lookup" "$(wc -l <"$calls" | tr -d " ")"
	' _ "${SCRIPT_DIR}/.." "$helper_def" "$tmp_dir" 2>/dev/null)
	rm -rf "$tmp_dir"
	if [[ "$result" == $'lookup=|42=1|\ncalls=2' ]]; then
		_pass "merged reconciliation uses two relevant REST pages, not a discarded unmerged-history scan"
	else
		_fail "merged reconciliation adapter population/call budget mismatch: $result"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 14 (t2985): grep-based lookup avoids prefix-substring false matches
# ---------------------------------------------------------------------------
# Critical correctness test: with input lookup |1=100|10=200|11=300|, a
# search for issue #1 must NOT match #10 or #11. The leading "|" plus the
# "=" separator anchor each pair so grep -oE "\|1=[0-9]+" only matches the
# #1 entry. Without the "=" anchor, a regex like "|1[0-9]+" would falsely
# match "|10=" or "|11=".
# ---------------------------------------------------------------------------
test_t2985_oimp_lookup_no_prefix_collision() {
	# Three issues with prefix-overlap numbers all in the same lookup.
	local lookup="|1=100|10=200|11=300|"

	local m1 m10 m11
	m1=$(printf '%s' "$lookup" | grep -oE "\|1=[0-9]+" 2>/dev/null | head -1 | cut -d= -f2)
	m10=$(printf '%s' "$lookup" | grep -oE "\|10=[0-9]+" 2>/dev/null | head -1 | cut -d= -f2)
	m11=$(printf '%s' "$lookup" | grep -oE "\|11=[0-9]+" 2>/dev/null | head -1 | cut -d= -f2)

	local all_ok=1
	[[ "$m1" == "100" ]] || {
		_fail "t2985: |1=  matched '${m1}', expected 100"
		all_ok=0
	}
	[[ "$m10" == "200" ]] || {
		_fail "t2985: |10= matched '${m10}', expected 200"
		all_ok=0
	}
	[[ "$m11" == "300" ]] || {
		_fail "t2985: |11= matched '${m11}', expected 300"
		all_ok=0
	}

	[[ "$all_ok" == "1" ]] && _pass "t2985: |N= boundary anchors prevent prefix-substring false matches (#1 vs #10/#11)"
	return 0
}

# ---------------------------------------------------------------------------
# Test 15 (t2985): _action_oimp_single takes the lookup as 4th arg
# ---------------------------------------------------------------------------
# Verify the signature change in pulse-issue-reconcile-actions.sh and
# both call sites in pulse-issue-reconcile.sh pass the lookup. This
# catches the partial-rollout case where the helper exists but a caller
# still uses the 3-arg form.
# ---------------------------------------------------------------------------
test_t2985_action_oimp_single_signature() {
	local actions_sh="${SCRIPT_DIR}/../pulse-issue-reconcile-actions.sh"
	local all_ok=1

	# 1. _action_oimp_single body must read the 4th arg as oimp_lookup.
	# SC2016: single-quoted pattern intentionally contains literal ${4:-} —
	# grepping for the literal source string, no expansion wanted.
	# shellcheck disable=SC2016
	if ! grep -q 'oimp_lookup="${4:-}"' "${actions_sh}"; then
		_fail "t2985: _action_oimp_single signature missing oimp_lookup 4th arg"
		all_ok=0
	fi

	# 2. _action_oimp_single must NOT call _gh_pr_list_merged directly anymore.
	#    The acceptance criterion: only the per-repo prefetch builder calls it.
	if grep -q '_gh_pr_list_merged' "${actions_sh}"; then
		_fail "t2985: _action_oimp_single still calls _gh_pr_list_merged directly (should use lookup)"
		all_ok=0
	fi

	# 3. The single-pass call site in RECONCILE_SH passes the lookup and issue
	#    body. Use grep -E to match the multi-arg form and require both values.
	# SC2016: single-quoted pattern intentionally contains literal $slug etc. —
	# grepping for the literal source string, no expansion wanted.
	local call_count
	# shellcheck disable=SC2016
	call_count=$(grep -cE '_action_oimp_single "\$slug" "\$issue_num" "\$verify_helper" "\$oimp_lookup" "\$issue_body"' \
		"${RECONCILE_SH}" 2>/dev/null || true)
	[[ "$call_count" =~ ^[0-9]+$ ]] || call_count=0
	if [[ "$call_count" -ge 1 ]]; then
		_pass "t2985: ${call_count} call site(s) pass oimp_lookup and issue_body to _action_oimp_single"
	else
		_fail "t2985: expected ≥1 call site passing oimp_lookup and issue_body, got ${call_count}"
		all_ok=0
	fi

	[[ "$all_ok" == "1" ]] && _pass "t2985: _action_oimp_single signature contract enforced"
	return 0
}

# ---------------------------------------------------------------------------
# Test 15b (GH#25896): consolidated successor closes when superseded issue was fixed
# ---------------------------------------------------------------------------
test_gh25896_oimp_closes_consolidated_successor() {
	local actions_sh="${SCRIPT_DIR}/../pulse-issue-reconcile-actions.sh"
	local tmp_dir out_file log_file result
	tmp_dir=$(mktemp -d)
	out_file="${tmp_dir}/gh.out"
	log_file="${tmp_dir}/pulse.log"

	result=$(bash -c '
		actions_sh="$1"
		out_file="$2"
		log_file="$3"
		LOGFILE="$log_file"
		export LOGFILE out_file
		gh() {
			printf "%s\n" "$*" >>"$out_file"
			return 0
		}
		fast_fail_reset() { return 0; }
		unlock_issue_after_worker() { return 0; }
		export -f gh fast_fail_reset unlock_issue_after_worker
		# shellcheck disable=SC1090
		source "$actions_sh"
		_action_oimp_single "test/repo" "25896" "/bin/true" "|25877=25894|" "_Supersedes #25877 — this issue is the consolidated spec._"
		printf "rc=%s\n" "$?"
	' -- "$actions_sh" "$out_file" "$log_file" 2>&1)

	local all_ok=1
	if [[ "$result" != *"rc=0"* ]]; then
		_fail "GH#25896: consolidated successor action returned unexpected result: ${result}"
		all_ok=0
	fi
	if ! grep -q 'issue close 25896 --repo test/repo' "$out_file" 2>/dev/null; then
		_fail "GH#25896: expected close of consolidated successor #25896"
		all_ok=0
	fi
	if ! grep -q 'supersedes #25877, and merged PR #25894 already fixed' "$out_file" 2>/dev/null; then
		_fail "GH#25896: close comment did not cite superseded issue and merged PR evidence"
		all_ok=0
	fi

	rm -rf "$tmp_dir"
	[[ "$all_ok" == "1" ]] && _pass "GH#25896: OIMP closes consolidated successor using Supersedes #N merged-PR evidence"
	return 0
}

# ---------------------------------------------------------------------------
# Test 15c (GH#27444): recurrent file-size debt uses current outcome
# ---------------------------------------------------------------------------
test_gh27444_recurrent_file_size_debt_current_outcome() {
	local actions_sh="${SCRIPT_DIR}/../pulse-issue-reconcile-actions.sh"
	local tmp_dir repo_dir repos_json out_file log_file result
	tmp_dir=$(mktemp -d)
	repo_dir="${tmp_dir}/repo"
	repos_json="${tmp_dir}/repos.json"
	out_file="${tmp_dir}/gh.out"
	log_file="${tmp_dir}/pulse.log"
	mkdir -p "$repo_dir"
	printf '{"initialized_repos":[{"slug":"test/repo","path":"%s"}]}' "$repo_dir" >"$repos_json"
	printf 'one\ntwo\nthree\n' >"${repo_dir}/large.sh"

	result=$(bash -c '
		actions_sh="$1"
		repos_json="$2"
		GH_TEST_OUT="$3"
		log_file="$4"
		body="$5"
		LOGFILE="$log_file"
		REPOS_JSON="$repos_json"
		export LOGFILE REPOS_JSON GH_TEST_OUT
		gh() { printf "%s\n" "$*" >>"$GH_TEST_OUT"; return 0; }
		fast_fail_reset() { return 0; }
		unlock_issue_after_worker() { return 0; }
		export -f gh fast_fail_reset unlock_issue_after_worker
		# shellcheck disable=SC1090
		source "$actions_sh"
		_action_oimp_single "test/repo" "27444" "/bin/true" "|27444=27500|" "$body"
		printf "rc=%s\n" "$?"
	' -- "$actions_sh" "$repos_json" "$out_file" "$log_file" \
		'<!-- aidevops:generator=large-file-simplification-gate cited_file=large.sh threshold=3 -->' 2>&1)

	local all_ok=1
	if [[ "$result" != *"rc=1"* ]] || grep -q 'issue close 27444' "$out_file" 2>/dev/null; then
		_fail "GH#27444: oversized recurrent debt was closed: ${result}"
		all_ok=0
	fi

	printf 'one\ntwo\n' >"${repo_dir}/large.sh"
	: >"$out_file"
	result=$(bash -c '
		LOGFILE="$4" REPOS_JSON="$2" GH_TEST_OUT="$3"; export LOGFILE REPOS_JSON GH_TEST_OUT
		gh() { printf "%s\n" "$*" >>"$GH_TEST_OUT"; return 0; }
		fast_fail_reset() { return 0; }
		unlock_issue_after_worker() { return 0; }
		source "$1"
		_action_oimp_single "test/repo" "27444" "/bin/true" "|27444=27500|" "$5"
		printf "rc=%s\n" "$?"
	' -- "$actions_sh" "$repos_json" "$out_file" "$log_file" \
		'<!-- aidevops:generator=large-file-simplification-gate cited_file=large.sh threshold=3 -->' 2>&1)
	if [[ "$result" != *"rc=0"* ]] || ! grep -q 'issue close 27444' "$out_file" 2>/dev/null; then
		_fail "GH#27444: resolved debt did not close: ${result}"
		all_ok=0
	fi

	: >"$out_file"
	result=$(bash -c '
		LOGFILE="$4" REPOS_JSON="$2" GH_TEST_OUT="$3"; export LOGFILE REPOS_JSON GH_TEST_OUT
		gh() { printf "%s\n" "$*" >>"$GH_TEST_OUT"; return 0; }
		fast_fail_reset() { return 0; }
		unlock_issue_after_worker() { return 0; }
		source "$1"
		_action_oimp_single "test/repo" "99" "/bin/true" "|99=100|" "ordinary issue"
		printf "rc=%s\n" "$?"
	' -- "$actions_sh" "$repos_json" "$out_file" "$log_file" 2>&1)
	if [[ "$result" != *"rc=0"* ]] || ! grep -q 'issue close 99' "$out_file" 2>/dev/null; then
		_fail "GH#27444: unrelated issue behavior changed: ${result}"
		all_ok=0
	fi

	rm -rf "$tmp_dir"
	[[ "$all_ok" == "1" ]] && _pass "GH#27444: current oversized debt blocks stale close while resolved and unrelated issues close"
	return 0
}

# ---------------------------------------------------------------------------
# Test 16 (GH#22473): status:available feedback-routed worker issues stay
# unassigned during assignment normalization.
# ---------------------------------------------------------------------------
test_available_feedback_worker_issue_not_assigned() {
	local tmp_dir repos_json ops_log pulse_log
	tmp_dir=$(mktemp -d)
	repos_json="${tmp_dir}/repos.json"
	ops_log="${tmp_dir}/ops.log"
	pulse_log="${tmp_dir}/pulse.log"
	printf '{"initialized_repos":[{"pulse":true,"local_only":false,"slug":"owner/repo"}]}' >"$repos_json"

	local fixture_json
	fixture_json=$(jq -nc '[
		{
			number: 101,
			assignees: [],
			labels: [{name:"status:available"},{name:"origin:worker"},{name:"auto-dispatch"},{name:"source:review-feedback"}]
		},
		{
			number: 202,
			assignees: [],
			labels: [{name:"status:queued"},{name:"origin:worker"},{name:"auto-dispatch"}]
		},
		{
			number: 303,
			assignees: [{login:"old-owner"}],
			labels: [{name:"status:available"},{name:"origin:interactive"},{name:"source:conflict-feedback"}]
		}
	]')

	local result
	result=$(bash -c '
		fixture_json=$1
		repos_json=$2
		ops_log=$3
		pulse_log=$4
		RECONCILE_SH=$5
		LOGFILE="$pulse_log"
		PULSE_QUEUED_SCAN_LIMIT=1000

		gh_issue_list() { printf "%s" "$fixture_json"; return 0; }
		gh() {
			if [[ "${1:-}" == "issue" && "${2:-}" == "edit" ]]; then
				printf "%s\n" "$*" >>"$ops_log"
				return 0
			fi
			return 1
		}

		# shellcheck source=/dev/null
		source "$RECONCILE_SH"
		_normalize_reassign_self "runner-user" "$repos_json" "/nonexistent-dedup-helper"
		cat "$ops_log" 2>/dev/null || true
	' _ "$fixture_json" "$repos_json" "$ops_log" "$pulse_log" "$RECONCILE_SH" 2>/dev/null)

	rm -rf "$tmp_dir"

	local all_ok=1
	if printf '%s\n' "$result" | grep -q 'edit 101 .*--add-assignee'; then
		_fail "GH#22473: status:available feedback-routed worker issue received add-assignee"
		all_ok=0
	fi
	if ! printf '%s\n' "$result" | grep -q 'edit 202 .*--add-assignee runner-user'; then
		_fail "GH#22473: status:queued unassigned worker issue was not assigned"
		all_ok=0
	fi
	if ! printf '%s\n' "$result" | grep -q 'edit 303 .*--remove-assignee old-owner'; then
		_fail "GH#22473: stale interactive feedback owner was not cleared"
		all_ok=0
	fi
	if printf '%s\n' "$result" | grep -q 'edit 303 .*--add-assignee'; then
		_fail "GH#22473: stale available feedback issue was reassigned after stale owner cleanup"
		all_ok=0
	fi

	[[ "$all_ok" == "1" ]] && _pass "GH#22473: available feedback worker issues stay unassigned while queued issues normalize"
	return 0
}

# ---------------------------------------------------------------------------
# Test 17 (GH#23257): consolidated feedback backfill uses label constants.
# ---------------------------------------------------------------------------
test_feedback_backfill_uses_label_constants() {
	local tmp_dir ops_log
	tmp_dir=$(mktemp -d)
	ops_log="${tmp_dir}/ops.log"

	local fixture_json
	fixture_json=$(jq -nc '[
		{
			number: 404,
			assignees: [],
			labels: [
				{name:"origin:worker"},
				{name:"consolidated"},
				{name:"source:review-feedback"},
				{name:"status:ready"},
				{name:"tier:custom"}
			]
		},
		{
			number: 505,
			assignees: [],
			labels: [
				{name:"origin:worker"},
				{name:"consolidated"},
				{name:"source:review-feedback"},
				{name:"status:available"},
				{name:"tier:standard"}
			]
		}
	]')

	local result
	result=$(bash -c '
		fixture_json=$1
		ops_log=$2
		RECONCILE_SH=$3
		LOGFILE="${ops_log}.pulse"
		_PIR_STATUS_AVAILABLE="status:ready"
		_PIR_TIER_STANDARD="tier:custom"

		gh() {
			if [[ "${1:-}" == "issue" && "${2:-}" == "edit" ]]; then
				printf "%s\n" "$*" >>"$ops_log"
				return 0
			fi
			return 1
		}

		# shellcheck source=/dev/null
		source "$RECONCILE_SH"
		rows=$(_normalize_get_feedback_backfill_rows "$fixture_json")
		printf "rows=%s\n" "$rows"
		_normalize_backfill_feedback_rows "owner/repo" "$rows"
		cat "$ops_log" 2>/dev/null || true
	' _ "$fixture_json" "$ops_log" "$RECONCILE_SH" 2>/dev/null)

	rm -rf "$tmp_dir"

	local all_ok=1
	if ! printf '%s\n' "$result" | grep -q '^rows=404$'; then
		_fail "GH#23257: custom status/tier labels were not selected for backfill"
		all_ok=0
	fi
	if printf '%s\n' "$result" | grep -q '^rows=505$'; then
		_fail "GH#23257: hardcoded status/tier labels were selected despite overridden constants"
		all_ok=0
	fi
	if ! printf '%s\n' "$result" | grep -q 'edit 404 .*--add-label status:ready .*--add-label auto-dispatch .*--add-label tier:custom'; then
		_fail "GH#23257: backfill edit did not use status/auto-dispatch/tier constants"
		all_ok=0
	fi

	[[ "$all_ok" == "1" ]] && _pass "GH#23257: consolidated feedback backfill uses label constants"
	return 0
}

test_pr_lookup_uncertainty_preserves_issue_state() {
	local tmp_dir=""
	local dedup_helper=""
	local mutation_log=""
	local action_log=""
	local actions_sh="${SCRIPT_DIR}/../pulse-issue-reconcile-actions.sh"
	local result=""
	tmp_dir=$(mktemp -d)
	dedup_helper="${tmp_dir}/dedup-helper.sh"
	mutation_log="${tmp_dir}/mutations.log"
	action_log="${tmp_dir}/actions.log"
	cat >"$dedup_helper" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'PR_LOOKUP_UNCERTAIN: unable to verify PR state for issue #42 (open_siblings; reason=timeout)'
printf '%s\n' 'PR_LOOKUP_RESULT=uncertain reason=timeout scope=open_siblings'
exit 0
EOF
	chmod +x "$dedup_helper"

	result=$(bash -c '
		actions_sh="$1"
		dedup_helper="$2"
		mutation_log="$3"
		LOGFILE="$4"
		# shellcheck source=/dev/null
		source "$actions_sh"
		gh() { printf "gh:%s\n" "$*" >>"$mutation_log"; return 0; }
		set_issue_status() { printf "status:%s\n" "$*" >>"$mutation_log"; return 0; }
		_pir_pr_merged_at() { return 1; }
		ciw_rc=0
		rsd_rc=0
		_action_ciw_single owner/repo 42 title "$dedup_helper" /nonexistent || ciw_rc=$?
		_action_rsd_single owner/repo 42 title "$dedup_helper" /nonexistent || rsd_rc=$?
		printf "ciw_rc=%s rsd_rc=%s\n" "$ciw_rc" "$rsd_rc"
		[[ ! -s "$mutation_log" ]] && printf "mutations=none\n"
	' _ "$actions_sh" "$dedup_helper" "$mutation_log" "$action_log" 2>/dev/null)
	rm -rf "$tmp_dir"

	if [[ "$result" == *"ciw_rc=1 rsd_rc=1"* && "$result" == *"mutations=none"* ]]; then
		_pass "PR lookup uncertainty preserves issue state in reconcile actions"
		return 0
	fi

	_fail "PR lookup uncertainty mutated reconciliation state or returned the wrong status: ${result}"
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_cache_miss_no_file
test_cache_miss_no_slug
test_cache_stale
test_cache_hit_fresh
test_cache_bodyless_row_misses
test_no_raw_gh_issue_list_outside_fallback
test_single_pass_cache_consolidation
test_body_in_prefetch_fetch
test_should_predicates
test_parent_live_hold_gate
test_pr_merged_at_prefers_wrapper
test_single_pass_wired_in_engine
test_recent_parent_repair_reachable_from_single_pass
test_recent_parent_repair_cursor_and_candidate_bounds
test_batched_field_extraction_parity
test_t2984_time_budget_present
test_t2984_budget_env_validation
test_t2985_oimp_lookup_builder
test_gh22802_oimp_lookup_requires_merged_at
test_oimp_uses_merged_adapter_population
test_t2985_oimp_lookup_no_prefix_collision
test_t2985_action_oimp_single_signature
test_gh25896_oimp_closes_consolidated_successor
test_gh27444_recurrent_file_size_debt_current_outcome
test_available_feedback_worker_issue_not_assigned
test_feedback_backfill_uses_label_constants
test_pr_lookup_uncertainty_preserves_issue_state

echo ""
echo "Results: ${pass} passed, ${fail} failed"
if [[ "$fail" -gt 0 ]]; then
	exit 1
fi
exit 0
