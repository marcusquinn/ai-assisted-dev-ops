#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Aggregate release receipt reconciliation regression tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "${TEST_ROOT}/receipts" "${TEST_ROOT}/release"

# shellcheck source=../full-loop-release-helper.sh
source "${SCRIPT_DIR}/full-loop-release-helper.sh" help >/dev/null

AIDEVOPS_FULL_LOOP_RECEIPT_DIR="${TEST_ROOT}/receipts"
export AIDEVOPS_FULL_LOOP_RECEIPT_DIR

sha90=$(printf '%040d' 90)
sha91=$(printf '%040d' 91)
sha99=$(printf '%040d' 99)
expected_tag_commit=$(printf '%040d' 123)
source_json=$(jq -cn --arg sha90 "$sha90" --arg sha91 "$sha91" --arg sha99 "$sha99" '
	{mode:"aggregate",source_pr:99,source_merge:$sha99,
	 aggregated_sources:[{pr:90,merge:$sha90},{pr:91,merge:$sha91}]}
')

printf 'not-requested\n' >"${TEST_ROOT}/receipts/test_repo-90.status"
_full_loop_validate_release_candidates test/repo "$source_json" || {
	printf 'FAIL authorized aggregate rejected prior release:not-requested evidence\n'
	exit 1
}

direct_json=$(jq -cn --arg sha90 "$sha90" '{mode:"direct",source_pr:90,source_merge:$sha90,aggregated_sources:[]}')
if _full_loop_validate_release_candidates test/repo "$direct_json" >/dev/null 2>&1; then
	printf 'FAIL direct release replaced terminal release:not-requested evidence\n'
	exit 1
fi
printf 'PASS only exact aggregate members may retain release:not-requested evidence\n'

printf 'published\n' >"${TEST_ROOT}/receipts/test_repo-91.status"
if _full_loop_validate_release_candidates test/repo "$source_json" >/dev/null 2>&1; then
	printf 'FAIL aggregate accepted an already published source receipt\n'
	exit 1
fi
rm -f "${TEST_ROOT}/receipts/test_repo-91.status"

printf '1.2.3\n' >"${TEST_ROOT}/release/VERSION"
git() {
	local args="$*"
	if [[ "$args" == *" rev-parse refs/tags/v1.2.3^{commit}"* ]]; then
		printf '%s\n' "$expected_tag_commit"
		return 0
	fi
	return 1
}
_full_loop_update_superseded_cleanup_receipt() {
	return 0
}

_full_loop_persist_release_success test/repo "${TEST_ROOT}/release" "$source_json" 99 "$sha99" || {
	printf 'FAIL authorized aggregate release receipts did not persist\n'
	exit 1
}
_full_loop_persist_release_success test/repo "${TEST_ROOT}/release" "$source_json" 99 "$sha99" || {
	printf 'FAIL authorized aggregate release receipt persistence was not idempotent\n'
	exit 1
}

if [[ "$(<"${TEST_ROOT}/receipts/test_repo-90.status")" != "not-requested" ]] ||
	[[ "$(<"${TEST_ROOT}/receipts/test_repo-91.status")" != "superseded" ]] ||
	[[ "$(<"${TEST_ROOT}/receipts/test_repo-99.status")" != "published" ]]; then
	printf 'FAIL aggregate reconciliation rewrote historical receipt semantics\n'
	exit 1
fi
jq -e --arg source_merge "$sha90" --arg aggregate_merge "$sha99" \
	--arg release_commit "$expected_tag_commit" '
	.evidence_type == "authorized-aggregate-inclusion" and .status == "included"
	and .prior_release_status == "not-requested" and .pr_number == 90
	and .source_merge == $source_merge and .aggregate_pr == 99
	and .aggregate_merge == $aggregate_merge and .release_tag == "v1.2.3"
	and .release_commit == $release_commit
' "${TEST_ROOT}/receipts/test_repo-90.inclusion.json" >/dev/null || {
	printf 'FAIL authorized aggregate inclusion evidence was incomplete\n'
	exit 1
}

printf 'PASS aggregate publication preserves no-release receipts with auditable inclusion evidence\n'
exit 0
