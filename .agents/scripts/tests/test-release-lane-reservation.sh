#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#31377: a reservation must fence ordinary merges before publication starts.
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
	expect_guard "ordinary TODO deferred in $phase" 75 test/repo 202 main aidevops/issue-sync-todo
	expect_guard "other repository unaffected in $phase" 0 other/repo 202 main feature/work
	expect_guard "other base unaffected in $phase" 0 test/repo 202 develop feature/work
done

# A stale phase/receipt must not reopen an active lane to concurrent actors.
state='{"active":true,"source_pr":101,"phase":"terminal","terminal_receipt":null}'
expect_guard 'inconsistent terminal phase stays closed' 75 test/repo 202 main feature/work
state='{"active":true,"source_pr":101,"phase":"reserved","terminal_receipt":"published"}'
expect_guard 'stale receipt cannot override active ownership' 75 test/repo 202 main feature/work
state='{"active":false,"source_pr":101,"phase":"terminal","terminal_receipt":"published"}'
expect_guard 'ordinary work resumes after terminal receipt' 0 test/repo 202 main aidevops/issue-sync-todo

release_lane_read() { return 1; }
expect_guard 'API uncertainty defers merge' 75 test/repo 202 main feature/work
release_lane_read() { return 2; }
expect_guard 'absent lane retains legacy behavior' 0 test/repo 202 main feature/work
[[ "$failures" -eq 0 ]]
