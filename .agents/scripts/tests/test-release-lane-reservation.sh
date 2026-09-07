#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Snapshot publication serializes publishers, not ordinary merges or queues.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../release-lane-helper.sh
source "$SCRIPT_DIR/release-lane-helper.sh"

state='{"active":false,"source_pr":101,"phase":"terminal","terminal_receipt":"published"}'
export AIDEVOPS_RELEASE_LANE_COORDINATED_REPO=test/repo
release_lane_read() {
	_AIDEVOPS_RELEASE_LANE_JSON="$state"
	return 0
}
# No real API or publication commands are permitted in this fixture.
gh() { return 1; }

failures=0
expect_guard() {
	local name="$1"
	local expected="$2"
	local rc=0
	shift 2
	release_lane_merge_guard "$@" >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -eq "$expected" ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s: expected=%s actual=%s\n' "$name" "$expected" "$rc"
		failures=$((failures + 1))
	fi
	return 0
}

expect_guard 'admission before reservation' 0 test/repo 202 main aidevops/issue-sync-todo
for phase in reserved preparing reconcile-required remote-publication exact-tag-deployment future-phase; do
	state=$(jq -cn --arg phase "$phase" \
		'{active:true,source_pr:101,phase:$phase,tag:null,terminal_receipt:null}')
	expect_guard "ordinary TODO admitted in $phase" 0 test/repo 202 main aidevops/issue-sync-todo
	expect_guard "other repository unaffected in $phase" 0 other/repo 202 main feature/work
	expect_guard "other base unaffected in $phase" 0 test/repo 202 develop feature/work
done

# Stale release state does not grant publication, but cannot freeze merges.
state='{"active":true,"source_pr":101,"phase":"terminal","terminal_receipt":null}'
expect_guard 'inconsistent publisher phase leaves merge policy independent' 0 test/repo 202 main feature/work
state='{"active":true,"source_pr":101,"phase":"reserved","terminal_receipt":"published"}'
expect_guard 'stale receipt does not freeze merges' 0 test/repo 202 main feature/work
state='{"active":false,"source_pr":101,"phase":"terminal","terminal_receipt":"published"}'
expect_guard 'ordinary work resumes after terminal receipt' 0 test/repo 202 main aidevops/issue-sync-todo

release_lane_read() { return 1; }
expect_guard 'publisher API uncertainty does not defer merge' 0 test/repo 202 main feature/work
release_lane_read() { return 2; }
expect_guard 'absent lane retains legacy behavior' 0 test/repo 202 main feature/work

# Publisher reservation is independent of host merge admission and queue APIs.
empty_pages='[{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}]'
queue_response="$empty_pages"
api_rc=0
writes=0
gh() {
	[[ "$1 $2" == 'api graphql' && "$*" == *'--paginate --slurp'* &&
		"$*" == *'mergeQueueEntry'* && "$*" == *'autoMergeRequest'* ]] || return 1
	printf '%s\n' "$queue_response"
	return "$api_rc"
}
_release_lane_write() {
	writes=$((writes + 1))
	_AIDEVOPS_RELEASE_LANE_JSON="$2"
	return 0
}
expect_acquire() {
	local name="$1"
	local expected="$2"
	local expected_writes="$3"
	local rc=0
	writes=0
	release_lane_acquire test/repo 101 101 >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -eq "$expected" && "$writes" -eq "$expected_writes" ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s: rc=%s writes=%s\n' "$name" "$rc" "$writes"
		failures=$((failures + 1))
	fi
	return 0
}
expect_acquire 'empty host queue allows one reservation' 0 1
queue_response=$(jq \
	'.[0].data.repository.pullRequests.nodes=[{number:202,autoMergeRequest:null,mergeQueueEntry:null}]
	 | . + . | .[0].data.repository.pullRequests.pageInfo={hasNextPage:true,endCursor:"page-one"}' <<<"$empty_pages")
expect_acquire 'two clean pages with unqueued PRs allow reservation' 0 1
for field in autoMergeRequest mergeQueueEntry; do
	queue_response=$(jq --arg field "$field" \
		'.[0].data.repository.pullRequests.nodes=[{number:202,autoMergeRequest:null,mergeQueueEntry:null} | .[$field]={id:"queued"}]' <<<"$empty_pages")
	expect_acquire "pre-existing $field permits publisher reservation" 0 1
done
queue_response=$(jq --argjson queued "$queue_response" \
	'.[0].data.repository.pullRequests.pageInfo={hasNextPage:true,endCursor:"page-one"} | . + $queued' <<<"$empty_pages")
expect_acquire 'queued entry on second page permits reservation' 0 1
queue_response=$(jq '.[0].data.repository.pullRequests.pageInfo.hasNextPage=true' <<<"$empty_pages")
expect_acquire 'queue pagination is not a publisher dependency' 0 1
queue_response='[{"errors":[{"message":"unavailable"}],"data":{"repository":null}}]'
expect_acquire 'queue GraphQL uncertainty is not a publisher dependency' 0 1
queue_response=$(jq '.[0].data.repository.pullRequests.nodes=[{number:202}]' <<<"$empty_pages")
expect_acquire 'queue fields are not a publisher dependency' 0 1
queue_response="$empty_pages"
api_rc=1
expect_acquire 'queue transport is not a publisher dependency' 0 1

# Queue API failure must not displace or strand an existing release owner.
state='{"active":true,"source_pr":101,"phase":"remote-publication","tag":"v1.2.3","operation_token":"fixture-owner"}'
release_lane_read() {
	_AIDEVOPS_RELEASE_LANE_JSON="$state"
	return 0
}
expect_acquire 'same-source resume does not require fresh queue admission' 0 0
state='{"active":true,"source_pr":303,"phase":"remote-publication","tag":"v1.2.3"}'
expect_acquire 'competing actor cannot displace reservation' 75 0
[[ "$failures" -eq 0 ]]
