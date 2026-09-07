#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Offline production recovery/merge functions with bounded forge fixtures.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../release-lane-helper.sh
source "$SCRIPT_DIR/release-lane-helper.sh"

BASE='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":101,"phase":"reserved","tag":null,"updated_at":"2020-01-01T00:00:00Z","terminal_receipt":null,"operation_token":"fixture","reservation_contract":"fenced-prepublication/v1","executor":{"pid":123,"host_id":"fixture","started_at":"fixture"}}'
STATE="$BASE"
HEAD_SHA="1111111111111111111111111111111111111111"
OWNER_STATE=dead
READ_FAIL=0
WRITE_FAIL=0
PERMISSION=true
WRITES=0

release_lane_read() {
	[[ "$READ_FAIL" == 0 ]] || return 1
	_AIDEVOPS_RELEASE_LANE_JSON="$STATE"
	_AIDEVOPS_RELEASE_LANE_HEAD="$HEAD_SHA"
	return 0
}
_release_lane_executor_observe() {
	jq -cn --arg state "$OWNER_STATE" '{state:$state,reason:"fixture"}'
	return 0
}
_release_lane_write() {
	[[ "$WRITE_FAIL" == 0 && "$3" == "$HEAD_SHA" ]] || return 2
	WRITES=$((WRITES + 1))
	STATE="$2"
	_AIDEVOPS_RELEASE_LANE_JSON="$STATE"
	return 0
}
gh() {
	[[ "$*" == 'api repos/test/repo --jq '* ]] || return 1
	[[ "$PERMISSION" != unavailable ]] || return 1
	printf '%s\n' "$PERMISSION"
	return 0
}

refused() {
	local name="$1"
	local before="$STATE"
	if release_lane_recover_reservation test/repo 101 >/dev/null 2>&1; then
		printf 'FAIL unexpectedly recovered: %s\n' "$name"
		exit 1
	fi
	[[ "$STATE" == "$before" && "$WRITES" == 0 ]] || exit 1
	printf 'PASS refusal: %s\n' "$name"
	return 0
}

for OWNER_STATE in live unknown; do refused "$OWNER_STATE executor"; done
OWNER_STATE=dead
for transform in 'del(.reservation_contract)' '.tag="v1.2.3"' '.phase="preparing"' '.phase="remote-publication"' '.phase="future"' '.prepublication_recovery={}' '.aggregate_recovery={}' '.aggregate_successor={}' '.reserved_authorization_refresh={}' '.terminal_receipt="failed"' '.source_pr=202'; do
	STATE=$(jq -c "$transform" <<<"$BASE")
	refused "$transform"
done
STATE=$(jq -c --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '.updated_at=$now' <<<"$BASE")
refused 'recent reservation'
STATE="$BASE"
READ_FAIL=1
refused 'unavailable lane'
READ_FAIL=0
for PERMISSION in false unavailable; do refused 'unverified write authority'; done
PERMISSION=true
WRITE_FAIL=1
refused 'competing CAS writer'
WRITE_FAIL=0
if release_lane_recover_reservation test/repo 101 "2222222222222222222222222222222222222222"; then exit 1; fi
[[ "$WRITES" == 0 ]] || exit 1
printf 'PASS stale observation refuses mutation\n'

RECENT=$(python3 -c 'from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc)-timedelta(seconds=100)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
STATE=$(jq -c --arg recent "$RECENT" '.updated_at=$recent' <<<"$BASE")
AIDEVOPS_RELEASE_LANE_STALE_SECONDS=1 refused 'caller cannot shorten five-minute recovery grace'
STATE="$BASE"

STATE=$(jq -c '.phase="preparing"' <<<"$BASE")
report=$(release_lane_liveness_report "$STATE")
[[ "$report" == *"Rerun the exact authorized release command"* ]] || exit 1
printf 'PASS dead tagless preparing status routes through fenced same-command recovery\n'
STATE="$BASE"

AIDEVOPS_RELEASE_LANE_COORDINATED_REPO=test/repo release_lane_merge_guard test/repo 202 main feature/ordinary
[[ "$WRITES" == 0 ]] || exit 1
release_lane_recover_reservation test/repo 101
[[ "$WRITES" == 1 ]] || exit 1
jq -e '.active == false and .terminal_receipt == "abandoned-prepublication" and .reservation_recovery.observed_head != null' <<<"$STATE" >/dev/null
release_lane_recover_reservation test/repo 101
[[ "$WRITES" == 1 ]] || exit 1
printf 'PASS ordinary merge leaves publisher state unchanged; explicit recovery remains idempotent\n'
