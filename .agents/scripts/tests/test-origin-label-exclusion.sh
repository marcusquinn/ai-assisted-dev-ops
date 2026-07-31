#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-origin-label-exclusion.sh — t2200 regression guard.
#
# Verifies that the origin label mutual exclusion invariant works:
#
#   1. ORIGIN_LABELS constant contains exactly the three expected labels.
#   2. set_origin_label produces the correct --add-label/--remove-label
#      flags for each origin kind (tested via a mock gh that records args).
#   3. set_origin_label rejects invalid origin kinds.
#   4. Back-to-back calls correctly flip origin labels (no drift).
#   5. The --pr flag routes to `gh pr edit` instead of `gh issue edit`.
#   6. Inline flag expansion in pulse-dispatch-worker-launch.sh includes
#      remove-label for sibling origins (grep-based structural check).
#
# Failure motivating this test: GH#19638 accumulated both
# origin:interactive AND origin:worker because edit sites added one
# without removing the other.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# Sandbox HOME so sourcing is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# Create a mock gh that records its arguments to a state file
GH_RECORD_FILE="${TEST_ROOT}/gh_calls.log"
MOCK_BIN_DIR="${TEST_ROOT}/mockbin"
mkdir -p "$MOCK_BIN_DIR"
cat >"${MOCK_BIN_DIR}/gh" <<'MOCK'
#!/usr/bin/env bash
# Mock gh: record all arguments and optionally fail selected calls.
printf '%s\n' "$*" >> "${GH_RECORD_FILE}"
if [[ "${GH_FAIL_ISSUE_EDIT:-0}" == "1" && "$1" == "issue" && "$2" == "edit" ]]; then
	printf 'GraphQL: API rate limit already exceeded for user ID 99999\n' >&2
	exit 1
fi
if [[ "$1" == "api" ]] && grep -q 'issues/801/labels' "${GH_RECORD_FILE}" 2>/dev/null && grep -q 'api -X POST' "${GH_RECORD_FILE}" 2>/dev/null; then
	exit 1
fi
exit 0
MOCK
chmod +x "${MOCK_BIN_DIR}/gh"
export PATH="${MOCK_BIN_DIR}:${PATH}"
export GH_RECORD_FILE

# Source shared-constants.sh to get the functions under test.
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1
set +e

# =============================================================================
# Part 1 — ORIGIN_LABELS constant
# =============================================================================
expected_labels="interactive worker worker-takeover"
actual_labels="${ORIGIN_LABELS[*]}"
if [[ "$actual_labels" == "$expected_labels" ]]; then
	print_result "ORIGIN_LABELS contains exactly 3 expected labels" 0
else
	print_result "ORIGIN_LABELS contains exactly 3 expected labels" 1 \
		"(expected: '$expected_labels', got: '$actual_labels')"
fi

# =============================================================================
# Part 2 — set_origin_label produces correct flags for origin:worker
# =============================================================================
: >"$GH_RECORD_FILE"
set_origin_label 100 "owner/repo" "worker" >/dev/null 2>&1
last_call=$(tail -1 "$GH_RECORD_FILE" 2>/dev/null || echo "")

# Should contain: issue edit 100 --repo owner/repo
#                 --add-label origin:worker
#                 --remove-label origin:interactive
#                 --remove-label origin:worker-takeover
if echo "$last_call" | grep -q 'issue edit 100' &&
	echo "$last_call" | grep -q -- '--add-label origin:worker' &&
	echo "$last_call" | grep -q -- '--remove-label origin:interactive' &&
	echo "$last_call" | grep -q -- '--remove-label origin:worker-takeover'; then
	print_result "set_origin_label worker: adds worker, removes interactive+takeover" 0
else
	print_result "set_origin_label worker: adds worker, removes interactive+takeover" 1 \
		"(gh call: $last_call)"
fi

# =============================================================================
# Part 3 — set_origin_label produces correct flags for origin:interactive
# =============================================================================
: >"$GH_RECORD_FILE"
set_origin_label 200 "owner/repo" "interactive" >/dev/null 2>&1
last_call=$(tail -1 "$GH_RECORD_FILE" 2>/dev/null || echo "")

if echo "$last_call" | grep -q 'issue edit 200' &&
	echo "$last_call" | grep -q -- '--add-label origin:interactive' &&
	echo "$last_call" | grep -q -- '--remove-label origin:worker[^-]' &&
	echo "$last_call" | grep -q -- '--remove-label origin:worker-takeover'; then
	print_result "set_origin_label interactive: adds interactive, removes worker+takeover" 0
else
	print_result "set_origin_label interactive: adds interactive, removes worker+takeover" 1 \
		"(gh call: $last_call)"
fi

# =============================================================================
# Part 4 — set_origin_label produces correct flags for origin:worker-takeover
# =============================================================================
: >"$GH_RECORD_FILE"
set_origin_label 300 "owner/repo" "worker-takeover" >/dev/null 2>&1
last_call=$(tail -1 "$GH_RECORD_FILE" 2>/dev/null || echo "")

if echo "$last_call" | grep -q 'issue edit 300' &&
	echo "$last_call" | grep -q -- '--add-label origin:worker-takeover' &&
	echo "$last_call" | grep -q -- '--remove-label origin:interactive' &&
	echo "$last_call" | grep -q -- '--remove-label origin:worker[^-]'; then
	print_result "set_origin_label worker-takeover: adds takeover, removes interactive+worker" 0
else
	print_result "set_origin_label worker-takeover: adds takeover, removes interactive+worker" 1 \
		"(gh call: $last_call)"
fi

# =============================================================================
# Part 5 — set_origin_label rejects invalid origin
# =============================================================================
: >"$GH_RECORD_FILE"
set_origin_label 400 "owner/repo" "bogus" >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 2 ]]; then
	print_result "set_origin_label rejects invalid origin with exit 2" 0
else
	print_result "set_origin_label rejects invalid origin with exit 2" 1 \
		"(got exit $rc)"
fi

# Verify no gh call was made for the invalid case
gh_calls=$(wc -l <"$GH_RECORD_FILE" 2>/dev/null | tr -d ' ')
# The file may contain label-create calls from ensure_origin_labels_exist
# but should NOT contain an "issue edit 400" call
if ! grep -q 'issue edit 400' "$GH_RECORD_FILE" 2>/dev/null; then
	print_result "set_origin_label invalid: no gh issue edit call made" 0
else
	print_result "set_origin_label invalid: no gh issue edit call made" 1
fi

# =============================================================================
# Part 6 — set_origin_label with --pr flag routes to pr edit
# =============================================================================
: >"$GH_RECORD_FILE"
set_origin_label 500 "owner/repo" "worker" --pr >/dev/null 2>&1
last_call=$(tail -1 "$GH_RECORD_FILE" 2>/dev/null || echo "")

if echo "$last_call" | grep -q 'pr edit 500'; then
	print_result "set_origin_label --pr: routes to gh pr edit" 0
else
	print_result "set_origin_label --pr: routes to gh pr edit" 1 \
		"(gh call: $last_call)"
fi

# =============================================================================
# Part 7 — set_origin_label passes through extra flags
# =============================================================================
: >"$GH_RECORD_FILE"
set_origin_label 600 "owner/repo" "interactive" \
	--add-assignee "testuser" --add-label "bug" >/dev/null 2>&1
last_call=$(tail -1 "$GH_RECORD_FILE" 2>/dev/null || echo "")

if echo "$last_call" | grep -q -- '--add-assignee testuser' &&
	echo "$last_call" | grep -q -- '--add-label bug'; then
	print_result "set_origin_label passes through extra flags" 0
else
	print_result "set_origin_label passes through extra flags" 1 \
		"(gh call: $last_call)"
fi

# =============================================================================
# Part 8 — Back-to-back origin flips produce correct calls
# =============================================================================
: >"$GH_RECORD_FILE"
set_origin_label 700 "owner/repo" "interactive" >/dev/null 2>&1
set_origin_label 700 "owner/repo" "worker" >/dev/null 2>&1

# Last call should be the worker one
last_call=$(grep 'issue edit 700' "$GH_RECORD_FILE" | tail -1)
if echo "$last_call" | grep -q -- '--add-label origin:worker' &&
	echo "$last_call" | grep -q -- '--remove-label origin:interactive'; then
	print_result "back-to-back flip: interactive→worker produces correct final call" 0
else
	print_result "back-to-back flip: interactive→worker produces correct final call" 1 \
		"(gh call: $last_call)"
fi

# =============================================================================
# Part 9 — GraphQL failure falls back to REST label endpoints
# =============================================================================
: >"$GH_RECORD_FILE"
export GH_FAIL_ISSUE_EDIT=1 GH_FAIL_REST_LABEL_POST=0
set_origin_label 800 "owner/repo" "worker" >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 0 ]] &&
	grep -q 'api -X DELETE /repos/owner/repo/issues/800/labels/origin:interactive' "$GH_RECORD_FILE" 2>/dev/null &&
	grep -q 'api -X DELETE /repos/owner/repo/issues/800/labels/origin:worker-takeover' "$GH_RECORD_FILE" 2>/dev/null &&
	grep -q 'api -X POST /repos/owner/repo/issues/800/labels -f labels\[\]=origin:worker' "$GH_RECORD_FILE" 2>/dev/null; then
	print_result "set_origin_label GraphQL exhaustion: REST DELETE/POST fallback succeeds" 0
else
	print_result "set_origin_label GraphQL exhaustion: REST DELETE/POST fallback succeeds" 1 \
		"(rc=$rc calls: $(tr '\n' ';' <"$GH_RECORD_FILE"))"
fi
unset GH_FAIL_ISSUE_EDIT GH_FAIL_REST_LABEL_POST

# =============================================================================
# Part 10 — GraphQL failure + REST failure stays failed
# =============================================================================
: >"$GH_RECORD_FILE"
_set_origin_label_rest() {
	printf '%s\n' "rest fallback forced failure $*" >>"$GH_RECORD_FILE"
	return 1
}
export GH_FAIL_ISSUE_EDIT=1 GH_FAIL_REST_LABEL_POST=1
set_origin_label 801 "owner/repo" "worker" >/dev/null 2>&1
rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result "set_origin_label GraphQL exhaustion: REST failure returns non-zero" 0
else
	print_result "set_origin_label GraphQL exhaustion: REST failure returns non-zero" 1 \
		"(expected non-zero, calls: $(tr '\n' ';' <"$GH_RECORD_FILE"))"
fi
unset GH_FAIL_ISSUE_EDIT GH_FAIL_REST_LABEL_POST

# =============================================================================
# Part 11 — Structural check: dispatch preserves immutable origin provenance.
# Worker ownership is represented by status + assignee, not origin relabeling.
# =============================================================================
launch_file="${TEST_SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh"
if [[ -f "$launch_file" ]]; then
	if grep -q 'Preserve origin:\* labels as immutable creation provenance' "$launch_file" &&
		! grep -qE '(add|remove)-label.*origin:(interactive|worker|worker-takeover)' "$launch_file"; then
		print_result "pulse-dispatch-worker-launch.sh preserves origin provenance" 0
	else
		print_result "pulse-dispatch-worker-launch.sh preserves origin provenance" 1 \
			"(dispatch must not mutate origin labels)"
	fi
else
	print_result "pulse-dispatch-worker-launch.sh preserves origin provenance" 1 \
		"(file not found)"
fi

# =============================================================================
# Part 10 — Structural check: no raw --add-label "origin: outside helpers
# =============================================================================
# Find all --add-label "origin: occurrences in non-test scripts, excluding:
# - shared-constants.sh (the helper itself)
# - tests/ directory
# - comment lines
# - reconcile-origin-labels.sh (uses set_origin_label)
raw_origin_sites=$(rg --line-number -g '*.sh' \
	'--add-label.*"origin:(interactive|worker|worker-takeover)"' \
	"${TEST_SCRIPTS_DIR}/" 2>/dev/null |
	grep -v '/tests/' |
	grep -v 'shared-constants\.sh' |
	grep -v 'reconcile-origin-labels\.sh' |
	grep -v '^\s*#' |
	grep -v 'remove-label' || true)

# Exclude creation-path sites (gh_create_issue/gh_create_pr use --label not --add-label)
# and prompt templates (string literals in heredocs)
# pulse-dispatch-worker-launch.sh must not mutate immutable origin provenance.
# Allow: pulse-issue-reconcile.sh (inline flags with corresponding remove-labels)
# Allow: pulse-triage.sh (creation-path gh_create_issue calls)
# Allow: pulse-dispatch-large-file-gate.sh (creation-path)
if [[ -z "$raw_origin_sites" ]]; then
	print_result "no raw --add-label origin: without sibling removal (clean)" 0
else
	# Filter out sites that also have remove-label nearby (same function)
	non_compliant=""
	while IFS= read -r line; do
		local_file="${line%%:*}"
		# Check if the same file also has remove-label for sibling origins
		if grep -q 'remove-label.*origin:interactive' "$local_file" 2>/dev/null &&
			grep -q 'remove-label.*origin:worker-takeover' "$local_file" 2>/dev/null; then
			continue
		fi
		non_compliant="${non_compliant}${line}\n"
	done <<<"$raw_origin_sites"

	if [[ -z "$non_compliant" ]]; then
		print_result "no raw --add-label origin: without sibling removal (clean)" 0
	else
		print_result "no raw --add-label origin: without sibling removal (clean)" 1 \
			"(non-compliant sites found)"
	fi
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] && exit 0 || exit 1
