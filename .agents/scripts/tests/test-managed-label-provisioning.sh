#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for existence-aware managed-label provisioning.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TEST_ROOT=$(mktemp -d -t managed-labels.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
CALL_LOG="${TEST_ROOT}/calls.log"
TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local description="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS: %s\n' "$description"
	return 0
}

fail() {
	local description="$1"
	local detail="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL: %s — %s\n' "$description" "$detail" >&2
	return 0
}

assert_count() {
	local description="$1"
	local expected="$2"
	local pattern="$3"
	local actual=0
	actual=$(grep -c -- "$pattern" "$CALL_LOG" 2>/dev/null || true)
	if [[ "$actual" -eq "$expected" ]]; then
		pass "$description"
	else
		fail "$description" "expected ${expected}, got ${actual}: ${pattern}"
	fi
	return 0
}

# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/shared-gh-wrappers.sh"

TEST_LABEL_SNAPSHOT=""
TEST_INVENTORY_RC=0
_gh_with_timeout() {
	local op_class="$1"
	shift
	printf '%s route=%s %s\n' "$op_class" "${AIDEVOPS_GH_ROUTE_DECISION:-unset}" "$*" >>"$CALL_LOG"
	if [[ "${1:-}" == "gh" && "${2:-}" == "api" ]]; then
		[[ "$TEST_INVENTORY_RC" -eq 0 ]] || return "$TEST_INVENTORY_RC"
		printf '%s\n' "$TEST_LABEL_SNAPSHOT"
	fi
	return 0
}

# A converged repository performs inventory reads but no duplicate writes.
: >"$CALL_LOG"
_ORIGIN_LABELS_ENSURED=""
_SOLVED_LABELS_ENSURED=""
TEST_INVENTORY_RC=0
TEST_LABEL_SNAPSHOT=$'origin:worker\norigin:interactive\norigin:worker-takeover\nsolved:worker\nsolved:interactive'
_ensure_origin_labels_for_args --repo owner/repo
ensure_solved_labels_exist owner/repo
assert_count "converged labels use attributed REST inventory" 2 \
	'read route=managed-label-inventory-rest gh api /repos/owner/repo/labels?per_page=100 --paginate'
assert_count "converged labels perform zero creates" 0 'write route=managed-label-create-rest gh label create'

# Only labels absent from the snapshot are created.
: >"$CALL_LOG"
_ORIGIN_LABELS_ENSURED=""
_SOLVED_LABELS_ENSURED=""
TEST_LABEL_SNAPSHOT=$'origin:worker\norigin:interactive\nsolved:worker'
_ensure_origin_labels_for_args --repo owner/repo
ensure_solved_labels_exist owner/repo
assert_count "missing origin label is created once" 1 'gh label create origin:worker-takeover '
assert_count "missing solved label is created once" 1 'gh label create solved:interactive '
assert_count "present origin labels are not recreated" 0 'gh label create origin:worker --repo'
assert_count "present solved labels are not recreated" 0 'gh label create solved:worker --repo'

# Tracking creation reuses the canonical origin set and adds its own labels.
: >"$CALL_LOG"
TEST_LABEL_SNAPSHOT=$'origin:worker\norigin:interactive\norigin:worker-takeover'
managed_labels_ensure_tracking_set owner/repo \
	_gh_managed_label_names_snapshot _gh_managed_label_create_runner
assert_count "tracking set provisions status label" 1 'gh label create status:in-review '
assert_count "tracking set provisions bug label" 1 'gh label create bug '
assert_count "tracking set reuses present origins" 0 'gh label create origin:'

# Approval transitions provision every label before posting signed evidence.
: >"$CALL_LOG"
TEST_LABEL_SNAPSHOT='needs-maintainer-review'
managed_labels_ensure_approval_set owner/repo issue \
	_gh_managed_label_names_snapshot _gh_managed_label_create_runner
assert_count "issue approval creates missing dispatch label" 1 'gh label create auto-dispatch '
assert_count "issue approval creates missing dispatch mutex label" 1 'gh label create no-auto-dispatch '
assert_count "issue approval reuses present review label" 0 'gh label create needs-maintainer-review '

: >"$CALL_LOG"
TEST_LABEL_SNAPSHOT=$'needs-maintainer-review\nauto-dispatch\nno-auto-dispatch'
managed_labels_ensure_approval_set owner/repo issue \
	_gh_managed_label_names_snapshot _gh_managed_label_create_runner
assert_count "converged issue approval performs zero creates" 0 'write route=managed-label-create-rest gh label create'

: >"$CALL_LOG"
TEST_LABEL_SNAPSHOT=""
managed_labels_ensure_approval_set owner/repo pr \
	_gh_managed_label_names_snapshot _gh_managed_label_create_runner
assert_count "PR approval creates only the review label" 1 'gh label create needs-maintainer-review '
assert_count "PR approval does not create dispatch label" 0 'gh label create auto-dispatch '
assert_count "PR approval does not create dispatch mutex label" 0 'gh label create no-auto-dispatch '

# Failed inventory is fail-closed: do not fan out speculative writes or cache.
: >"$CALL_LOG"
_ORIGIN_LABELS_ENSURED=""
_SOLVED_LABELS_ENSURED=""
TEST_INVENTORY_RC=1
if ensure_origin_labels_exist owner/repo; then
	fail "origin inventory failure propagates" "expected non-zero status"
else
	pass "origin inventory failure propagates"
fi
if ensure_solved_labels_exist owner/repo; then
	fail "solved inventory failure propagates" "expected non-zero status"
else
	pass "solved inventory failure propagates"
fi
assert_count "failed inventory performs zero creates" 0 'write route=managed-label-create-rest gh label create'

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf 'PASS: test-managed-label-provisioning — %d assertions\n' "$TESTS_RUN"
	exit 0
fi

printf 'FAIL: test-managed-label-provisioning — %d/%d failed\n' "$TESTS_FAILED" "$TESTS_RUN" >&2
exit 1
