#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

print_result() {
	local name="$1"
	local passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="$TEST_ROOT/home"
	export LOGFILE="$TEST_ROOT/pulse.log"
	export PULSE_PREFETCH_CACHE_FILE="$TEST_ROOT/prefetch-cache.json"
	export PULSE_BATCH_PREFETCH_CACHE_DIR="$TEST_ROOT/batch-cache"
	export PULSE_BATCH_PREFETCH_ENABLED=1
	export PULSE_BATCH_SNAPSHOT_AUTH_SCOPE=github.com
	export PULSE_PREFETCH_FULL_SWEEP_INTERVAL=86400
	export PULSE_PREFETCH_PR_LIMIT=100
	export PULSE_PREFETCH_ISSUE_LIMIT=100
	export DAILY_PR_CAP=10
	mkdir -p "$HOME" "$PULSE_BATCH_PREFETCH_CACHE_DIR" "$TEST_ROOT/bin"
	: >"$LOGFILE"
	: >"$TEST_ROOT/provider-calls.log"
	: >"$TEST_ROOT/github-list-calls.log"
	: >"$TEST_ROOT/telemetry.log"

	export CANONICAL_HELPER_REAL="$SCRIPTS_DIR/pulse-batch-prefetch-helper.sh"
	export CANONICAL_HELPER_LEDGER="$TEST_ROOT/provider-calls.log"
	cat >"$TEST_ROOT/bin/canonical-helper" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CANONICAL_HELPER_LEDGER"
exec "$CANONICAL_HELPER_REAL" "$@"
SH
	chmod +x "$TEST_ROOT/bin/canonical-helper"
	export PULSE_BATCH_PREFETCH_HELPER="$TEST_ROOT/bin/canonical-helper"
	return 0
}

teardown_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

gh_issue_list() {
	printf 'issues %s\n' "$*" >>"$TEST_ROOT/github-list-calls.log"
	printf '[]'
	return 0
}

gh_pr_list() {
	printf 'prs %s\n' "$*" >>"$TEST_ROOT/github-list-calls.log"
	printf '[]'
	return 0
}

pulse_pr_list_get() {
	printf 'exact-prs %s\n' "$*" >>"$TEST_ROOT/github-list-calls.log"
	printf '[]'
	return 0
}

gh_record_call() {
	printf '%s\n' "$*" >>"$TEST_ROOT/telemetry.log"
	return 0
}

gh_pr_check_status_rest_batch() {
	printf '[]'
	return 0
}

_filter_non_task_issues() {
	jq -c '.'
	return 0
}

SCRIPT_DIR="$SCRIPTS_DIR"
export SCRIPT_DIR
# shellcheck source=../pulse-prefetch-infra.sh
source "$SCRIPTS_DIR/pulse-prefetch-infra.sh"
# shellcheck source=../pulse-prefetch-fetch.sh
source "$SCRIPTS_DIR/pulse-prefetch-fetch.sh"
# shellcheck source=../pulse-prefetch-repo.sh
source "$SCRIPTS_DIR/pulse-prefetch-repo.sh"

check_repo_tier_skip() {
	local slug="$1"
	[[ -n "$slug" ]] || return 1
	return 0
}

update_repo_tier_check_timestamp() {
	local slug="$1"
	[[ -n "$slug" ]] || return 1
	return 0
}

ISSUE_ITEMS='[{"number":3,"title":"Issue","state":"open","labels":[],"updatedAt":"2026-07-18T09:00:00Z","assignees":[],"authorAssociation":"MEMBER","author":{"login":"member","type":"User","is_bot":false}}]'
PR_ITEMS='[{"number":7,"title":"PR","labels":[],"updatedAt":"2026-07-18T09:00:00Z","assignees":[],"createdAt":"2026-07-17T09:00:00Z","author":{"login":"dev"},"headRefOid":"abcdef123456","headRefName":"feature"}]'

snapshot_path() {
	local kind="$1"
	printf '%s/%s-owner__repo.json\n' "$PULSE_BATCH_PREFETCH_CACHE_DIR" "$kind"
	return 0
}

write_snapshot() {
	local kind="$1"
	local items="$2"
	local complete="$3"
	local generation="$4"
	local projection="$5"
	local timestamp="${6:-}"
	local auth_scope="${7:-${PULSE_BATCH_SNAPSHOT_AUTH_SCOPE}|${AIDEVOPS_GH_API_POOL:-default}}"
	[[ -n "$timestamp" ]] || timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	jq -n --arg schema "$_PREFETCH_SNAPSHOT_SCHEMA" --arg repo "owner/repo" \
		--arg kind "$kind" --arg projection "$projection" --arg auth_scope "$auth_scope" \
		--arg generation "$generation" --arg timestamp "$timestamp" \
		--argjson complete "$complete" --argjson items "$items" \
		'{schema:$schema,repository:$repo,collection:$kind,projection:$projection,
		  auth_scope:$auth_scope,generation:$generation,source:"fixture",
		  complete:$complete,truncated:($complete|not),fetched_at:$timestamp,
		  timestamp:$timestamp,items:$items}' >"$(snapshot_path "$kind")"
	return 0
}

write_complete_pair() {
	local generation="${1:-generation-a}"
	local issue_items="${2:-$ISSUE_ITEMS}"
	local pr_items="${3:-$PR_ITEMS}"
	write_snapshot issues "$issue_items" true "$generation" "$_PREFETCH_ISSUES_PROJECTION"
	write_snapshot prs "$pr_items" true "$generation" "$_PREFETCH_PRS_PROJECTION"
	return 0
}

test_single_resolution_and_local_reuse() {
	write_complete_pair
	: >"$TEST_ROOT/provider-calls.log"
	: >"$TEST_ROOT/github-list-calls.log"
	_prefetch_single_repo_load_snapshots owner/repo

	local provider_count=""
	provider_count=$(wc -l <"$TEST_ROOT/provider-calls.log" | tr -d ' ')
	local passed=0
	if [[ "$provider_count" != "2" ]] \
		|| [[ "$(grep -c '^read-snapshot --kind issues --slug owner/repo$' "$TEST_ROOT/provider-calls.log")" != "1" ]] \
		|| [[ "$(grep -c '^read-snapshot --kind prs --slug owner/repo$' "$TEST_ROOT/provider-calls.log")" != "1" ]] \
		|| [[ "$PREFETCH_CANONICAL_SNAPSHOT_COMPLETE" != "true" ]]; then
		passed=1
	fi
	print_result "one provider decision per collection yields a complete pair" "$passed"

	local fingerprint="" cache_entry=""
	fingerprint=$(_compute_repo_state_fingerprint owner/repo \
		"$PREFETCH_CANONICAL_ISSUES_SNAPSHOT" "$PREFETCH_CANONICAL_PRS_SNAPSHOT")
	cache_entry=$(jq -n --arg fp "$fingerprint" \
		'{state_fingerprint:$fp,state_fingerprint_schema:"canonical-snapshot-v1",prs:[],issues:[]}')
	if _prefetch_detect_cache_hit owner/repo "$cache_entry" \
		"$PREFETCH_CANONICAL_ISSUES_SNAPSHOT" "$PREFETCH_CANONICAL_PRS_SNAPSHOT" \
		&& [[ ! -s "$TEST_ROOT/github-list-calls.log" ]]; then
		print_result "canonical cache-hit decision is local and transport-free" 0
	else
		print_result "canonical cache-hit decision is local and transport-free" 1
	fi

	local prs_output="$TEST_ROOT/prs-output.txt"
	local issues_output="$TEST_ROOT/issues-output.txt"
	_prefetch_repo_prs owner/repo '{}' full "$PREFETCH_CANONICAL_PRS_SNAPSHOT" >"$prs_output"
	_prefetch_repo_issues owner/repo '{}' full "$PREFETCH_CANONICAL_ISSUES_SNAPSHOT" >"$issues_output"
	local provider_after=""
	provider_after=$(wc -l <"$TEST_ROOT/provider-calls.log" | tr -d ' ')
	if [[ "$provider_after" == "2" && ! -s "$TEST_ROOT/github-list-calls.log" ]] \
		&& grep -q 'review: UNKNOWN' "$prs_output" \
		&& grep -q 'Issue #3' "$issues_output"; then
		print_result "prefetch output reuses loaded snapshots without reopening providers" 0
	else
		print_result "prefetch output reuses loaded snapshots without reopening providers" 1
	fi
	return 0
}

test_complete_empty_pair_is_authoritative() {
	write_complete_pair generation-empty '[]' '[]'
	_prefetch_single_repo_load_snapshots owner/repo
	local fingerprint="" cache_entry=""
	fingerprint=$(_compute_repo_state_fingerprint owner/repo \
		"$PREFETCH_CANONICAL_ISSUES_SNAPSHOT" "$PREFETCH_CANONICAL_PRS_SNAPSHOT")
	cache_entry=$(jq -n --arg fp "$fingerprint" \
		'{state_fingerprint:$fp,state_fingerprint_schema:"canonical-snapshot-v1"}')
	if [[ "$fingerprint" =~ ^[0-9a-f]{16}$ ]] \
		&& _prefetch_detect_cache_hit owner/repo "$cache_entry" \
			"$PREFETCH_CANONICAL_ISSUES_SNAPSHOT" "$PREFETCH_CANONICAL_PRS_SNAPSHOT"; then
		print_result "complete empty snapshots remain authoritative cache-hit inputs" 0
	else
		print_result "complete empty snapshots remain authoritative cache-hit inputs" 1
	fi
	return 0
}

test_single_repo_cycle_threads_one_snapshot_pair() {
	write_complete_pair generation-cycle
	_prefetch_single_repo_load_snapshots owner/repo
	local fingerprint="" now="" entry="" output_file="$TEST_ROOT/repo-output.txt"
	fingerprint=$(_compute_repo_state_fingerprint owner/repo \
		"$PREFETCH_CANONICAL_ISSUES_SNAPSHOT" "$PREFETCH_CANONICAL_PRS_SNAPSHOT")
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	entry=$(_prefetch_build_cache_entry \
		"$now" "$now" "$fingerprint" "$PR_ITEMS" "$ISSUE_ITEMS" true generation-cycle)
	_prefetch_cache_set owner/repo "$entry"
	: >"$TEST_ROOT/provider-calls.log"
	: >"$TEST_ROOT/github-list-calls.log"
	_PULSE_HEALTH_IDLE_REPO_SKIPS=0
	_prefetch_single_repo owner/repo "$TEST_ROOT/repo" "$output_file"

	local provider_count="" stored_generation=""
	provider_count=$(wc -l <"$TEST_ROOT/provider-calls.log" | tr -d ' ')
	stored_generation=$(_prefetch_cache_get owner/repo | jq -r '.snapshot_generation')
	if [[ "$provider_count" == "2" && ! -s "$TEST_ROOT/github-list-calls.log" ]] \
		&& grep -q 'State cache hit' "$output_file" \
		&& grep -q 'PR #7' "$output_file" \
		&& grep -q 'Issue #3' "$output_file" \
		&& [[ "$stored_generation" == "generation-cycle" ]]; then
		print_result "single-repo cycle threads one snapshot pair through hit, output, and persistence" 0
	else
		print_result "single-repo cycle threads one snapshot pair through hit, output, and persistence" 1
	fi
	return 0
}

test_local_eviction_invalidates_completeness() {
	write_complete_pair generation-eviction
	"$PULSE_BATCH_PREFETCH_HELPER" evict-issue owner/repo 3 >/dev/null
	local complete="" source=""
	complete=$(jq -r '.complete' "$(snapshot_path issues)")
	source=$(jq -r '.source' "$(snapshot_path issues)")
	_prefetch_single_repo_load_snapshots owner/repo
	if [[ "$complete" == "false" && "$source" == "local-eviction" ]] \
		&& [[ "$PREFETCH_CANONICAL_SNAPSHOT_COMPLETE" == "false" ]]; then
		print_result "local cache eviction invalidates canonical completeness" 0
	else
		print_result "local cache eviction invalidates canonical completeness" 1
	fi
	return 0
}

assert_pair_misses() {
	local name="$1"
	_prefetch_single_repo_load_snapshots owner/repo
	local fingerprint=""
	fingerprint=$(_compute_repo_state_fingerprint owner/repo \
		"$PREFETCH_CANONICAL_ISSUES_SNAPSHOT" "$PREFETCH_CANONICAL_PRS_SNAPSHOT")
	if [[ "$PREFETCH_CANONICAL_SNAPSHOT_COMPLETE" == "false" && -z "$fingerprint" ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1
	fi
	return 0
}

test_incomplete_and_incompatible_pairs_miss() {
	write_complete_pair generation-partial
	write_snapshot issues "$ISSUE_ITEMS" false generation-partial "$_PREFETCH_ISSUES_PROJECTION"
	assert_pair_misses "partial snapshots cannot produce cache hits"

	write_complete_pair generation-a
	write_snapshot prs "$PR_ITEMS" true generation-b "$_PREFETCH_PRS_PROJECTION"
	assert_pair_misses "mixed snapshot generations cannot produce cache hits"

	write_complete_pair generation-projection
	write_snapshot prs "$PR_ITEMS" true generation-projection narrow-projection
	assert_pair_misses "projection-incompatible snapshots cannot produce cache hits"

	write_complete_pair generation-auth
	write_snapshot issues "$ISSUE_ITEMS" true generation-auth "$_PREFETCH_ISSUES_PROJECTION" "" other-account
	assert_pair_misses "auth-scope-incompatible snapshots cannot produce cache hits"

	write_complete_pair generation-stale
	write_snapshot issues "$ISSUE_ITEMS" true generation-stale "$_PREFETCH_ISSUES_PROJECTION" 2026-01-01T00:00:00Z
	assert_pair_misses "stale snapshots cannot produce cache hits"

	write_complete_pair generation-malformed
	printf '{malformed\n' >"$(snapshot_path prs)"
	assert_pair_misses "malformed snapshots cannot produce cache hits"
	return 0
}

test_cache_entry_records_snapshot_contract() {
	local entry=""
	entry=$(_prefetch_build_cache_entry \
		2026-07-18T10:00:00Z 2026-07-18T10:00:00Z abcdef1234567890 \
		"$PR_ITEMS" "$ISSUE_ITEMS" true generation-cache)
	if printf '%s' "$entry" | jq -e '
		.state_fingerprint_schema == "canonical-snapshot-v1" and
		.snapshot_generation == "generation-cache" and .snapshot_complete == true
	' >/dev/null; then
		print_result "summary cache records canonical fingerprint schema and generation" 0
	else
		print_result "summary cache records canonical fingerprint schema and generation" 1
	fi
	return 0
}

test_rest_first_prefetch_avoids_unattributed_review_search() {
	local pr_err="$TEST_ROOT/pr-fetch.err"
	: >"$pr_err"
	: >"$TEST_ROOT/github-list-calls.log"
	AIDEVOPS_GH_REST_FIRST_READS=1
	PREFETCH_PR_SWEEP_MODE="delta"
	_prefetch_prs_try_delta owner/repo '{}' "$pr_err"
	if [[ "$PREFETCH_PR_SWEEP_MODE" == "full" && ! -s "$TEST_ROOT/github-list-calls.log" ]]; then
		print_result "REST-first prefetch bypasses GraphQL-only delta search" 0
	else
		print_result "REST-first prefetch bypasses GraphQL-only delta search" 1
	fi
	unset AIDEVOPS_GH_REST_FIRST_READS

	: >"$TEST_ROOT/github-list-calls.log"
	_prefetch_prs_fetch_full owner/repo "$pr_err"
	if grep -q -- '--json number,title,updatedAt,headRefName,headRefOid,createdAt,author' \
		"$TEST_ROOT/github-list-calls.log" \
		&& ! grep -q 'reviewDecision' "$TEST_ROOT/github-list-calls.log"; then
		print_result "full prefetch projection remains REST-equivalent" 0
	else
		print_result "full prefetch projection remains REST-equivalent" 1
	fi
	return 0
}

setup_env
trap teardown_env EXIT
test_single_resolution_and_local_reuse
test_complete_empty_pair_is_authoritative
test_single_repo_cycle_threads_one_snapshot_pair
test_local_eviction_invalidates_completeness
test_incomplete_and_incompatible_pairs_miss
test_cache_entry_records_snapshot_contract
test_rest_first_prefetch_avoids_unattributed_review_search

printf 'Tests run: %s\n' "$TESTS_RUN"
printf 'Tests failed: %s\n' "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
