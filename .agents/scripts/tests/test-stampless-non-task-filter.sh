#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-stampless-non-task-filter.sh — GH#20048 regression guard.
#
# Asserts that _filter_non_task_issues (shared-gh-wrappers.sh) correctly
# removes issues carrying any NON_TASK_LABELS member, and that both
# _isc_list_stampless_interactive_claims (interactive-session-helper.sh)
# and _normalize_unassign_stampless_interactive (pulse-issue-reconcile.sh)
# apply the filter before emitting candidates.
#
# The tests use a mixed fixture: one real stampless interactive claim,
# one routine-tracking issue, one supervisor issue, and one
# needs-maintainer-review issue. Only the real claim should survive
# filtering.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# NOT readonly — shared-constants.sh declares readonly RED/GREEN/RESET
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

# Sandbox HOME
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/interactive-claims"
export LOGFILE="${HOME}/.aidevops/logs/test.log"

# Source shared-constants (which sources shared-gh-wrappers.sh with the new code)
# Prevent the bash re-exec guard from re-launching under a different bash:
export AIDEVOPS_BASH_REEXECED=1
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/shared-constants.sh"

# =============================================================================
# Fixture: mixed JSON array of issues
# =============================================================================
FIXTURE_JSON='[
  {"number": 100, "updatedAt": "2026-04-10T00:00:00Z", "labels": [{"name": "origin:interactive"}, {"name": "bug"}]},
  {"number": 200, "updatedAt": "2026-04-10T00:00:00Z", "labels": [{"name": "origin:interactive"}, {"name": "routine-tracking"}]},
  {"number": 300, "updatedAt": "2026-04-10T00:00:00Z", "labels": [{"name": "origin:interactive"}, {"name": "supervisor"}]},
  {"number": 400, "updatedAt": "2026-04-10T00:00:00Z", "labels": [{"name": "origin:interactive"}, {"name": "needs-maintainer-review"}]},
  {"number": 500, "updatedAt": "2026-04-10T00:00:00Z", "labels": [{"name": "origin:interactive"}, {"name": "contributor"}]},
  {"number": 600, "updatedAt": "2026-04-10T00:00:00Z", "labels": [{"name": "origin:interactive"}, {"name": "persistent"}]},
  {"number": 700, "updatedAt": "2026-04-10T00:00:00Z", "labels": [{"name": "origin:interactive"}, {"name": "quality-review"}]},
  {"number": 800, "updatedAt": "2026-04-10T00:00:00Z", "labels": [{"name": "origin:interactive"}, {"name": "on hold"}]},
  {"number": 900, "updatedAt": "2026-04-10T00:00:00Z", "labels": [{"name": "origin:interactive"}, {"name": "blocked"}]}
]'

# =============================================================================
# Test 1: NON_TASK_LABELS array contains the expected 8 labels
# =============================================================================
expected_count=8
actual_count=${#NON_TASK_LABELS[@]}
if [[ "$actual_count" -eq "$expected_count" ]]; then
	print_result "NON_TASK_LABELS has ${expected_count} elements" 0
else
	print_result "NON_TASK_LABELS has ${expected_count} elements" 1 \
		"(got ${actual_count}: ${NON_TASK_LABELS[*]})"
fi

# =============================================================================
# Test 2: NON_TASK_LABELS contains all required members
# =============================================================================
required_labels=("supervisor" "contributor" "persistent" "quality-review" "needs-maintainer-review" "routine-tracking" "on hold" "blocked")
all_present=true
for label in "${required_labels[@]}"; do
	found=false
	for ntl in "${NON_TASK_LABELS[@]}"; do
		if [[ "$ntl" == "$label" ]]; then
			found=true
			break
		fi
	done
	if [[ "$found" == "false" ]]; then
		all_present=false
		print_result "NON_TASK_LABELS contains '${label}'" 1
	fi
done
if [[ "$all_present" == "true" ]]; then
	print_result "NON_TASK_LABELS contains all required members" 0
fi

# =============================================================================
# Test 3: _filter_non_task_issues removes all non-task issues
# =============================================================================
filtered=$(echo "$FIXTURE_JSON" | _filter_non_task_issues)
filtered_count=$(echo "$filtered" | jq 'length')
if [[ "$filtered_count" -eq 1 ]]; then
	print_result "_filter_non_task_issues: 1 of 9 issues survive" 0
else
	print_result "_filter_non_task_issues: 1 of 9 issues survive" 1 \
		"(got ${filtered_count})"
fi

# =============================================================================
# Test 4: The surviving issue is #100 (the real claim)
# =============================================================================
surviving_number=$(echo "$filtered" | jq '.[0].number')
if [[ "$surviving_number" -eq 100 ]]; then
	print_result "_filter_non_task_issues: surviving issue is #100" 0
else
	print_result "_filter_non_task_issues: surviving issue is #100" 1 \
		"(got #${surviving_number})"
fi

# =============================================================================
# Test 5: _filter_non_task_issues handles empty input
# =============================================================================
empty_result=$(echo "[]" | _filter_non_task_issues)
empty_count=$(echo "$empty_result" | jq 'length')
if [[ "$empty_count" -eq 0 ]]; then
	print_result "_filter_non_task_issues: empty input → empty output" 0
else
	print_result "_filter_non_task_issues: empty input → empty output" 1 \
		"(got ${empty_count})"
fi

# =============================================================================
# Test 6: _filter_non_task_issues preserves issues with no NON_TASK labels
# =============================================================================
clean_json='[
  {"number": 1, "labels": [{"name": "bug"}]},
  {"number": 2, "labels": [{"name": "enhancement"}]},
  {"number": 3, "labels": []}
]'
clean_result=$(echo "$clean_json" | _filter_non_task_issues)
clean_count=$(echo "$clean_result" | jq 'length')
if [[ "$clean_count" -eq 3 ]]; then
	print_result "_filter_non_task_issues: clean issues all survive" 0
else
	print_result "_filter_non_task_issues: clean issues all survive" 1 \
		"(got ${clean_count})"
fi

# =============================================================================
# Test 7: _filter_non_task_issues filters issue with multiple labels
#          (one non-task label among several task labels)
# =============================================================================
multi_json='[
  {"number": 10, "labels": [{"name": "bug"}, {"name": "enhancement"}, {"name": "routine-tracking"}]},
  {"number": 20, "labels": [{"name": "bug"}, {"name": "enhancement"}]}
]'
multi_result=$(echo "$multi_json" | _filter_non_task_issues)
multi_count=$(echo "$multi_result" | jq 'length')
multi_num=$(echo "$multi_result" | jq '.[0].number')
if [[ "$multi_count" -eq 1 && "$multi_num" -eq 20 ]]; then
	print_result "_filter_non_task_issues: multi-label issue with one non-task is filtered" 0
else
	print_result "_filter_non_task_issues: multi-label issue with one non-task is filtered" 1 \
		"(count=${multi_count}, num=${multi_num})"
fi

# =============================================================================
# Test 8: Verify Site A (_isc_list_stampless_interactive_claims) uses filter
#          by stubbing gh to return the fixture and checking output.
# =============================================================================

# Create stub bin directory
STUB_BIN="${TEST_ROOT}/stub-bin"
mkdir -p "$STUB_BIN"

# gh stub: return fixture JSON for issue list, simulate offline for other calls
cat > "${STUB_BIN}/gh" <<'STUB_EOF'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*)
    cat <<'JSON'
[
  {"number": 100, "updatedAt": "2026-04-10T00:00:00Z", "labels": [{"name": "origin:interactive"}, {"name": "bug"}]},
  {"number": 200, "updatedAt": "2026-04-10T00:00:00Z", "labels": [{"name": "origin:interactive"}, {"name": "routine-tracking"}]},
  {"number": 300, "updatedAt": "2026-04-10T00:00:00Z", "labels": [{"name": "origin:interactive"}, {"name": "supervisor"}]},
  {"number": 400, "updatedAt": "2026-04-10T00:00:00Z", "labels": [{"name": "origin:interactive"}, {"name": "needs-maintainer-review"}]}
]
JSON
    ;;
  *"auth status"*)
    echo "Logged in to github.com account testuser"
    ;;
  *)
    exit 1
    ;;
esac
STUB_EOF
chmod +x "${STUB_BIN}/gh"

# Source the interactive-session-helper to get _isc_list_stampless_interactive_claims
# First, set SCRIPT_DIR so the source chain works
export SCRIPT_DIR="$TEST_SCRIPTS_DIR"

# Source helper (the `[[ "${BASH_SOURCE[0]}" == "$0" ]]` guard prevents main from running)
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/interactive-session-helper.sh"

# Run with stubbed PATH
site_a_output=$(PATH="${STUB_BIN}:${PATH}" _isc_list_stampless_interactive_claims testuser "owner/repo" 2>/dev/null)

# Count output rows (compact JSON, one per line)
site_a_count=0
if [[ -n "$site_a_output" ]]; then
	site_a_count=$(echo "$site_a_output" | wc -l | tr -d ' ')
fi

# Only issue #100 should be emitted (no stamp file exists for it)
if [[ "$site_a_count" -eq 1 ]]; then
	site_a_num=$(echo "$site_a_output" | jq -r '.number' 2>/dev/null | head -1)
	if [[ "$site_a_num" == "100" ]]; then
		print_result "Site A: _isc_list_stampless_interactive_claims filters non-task issues" 0
	else
		print_result "Site A: _isc_list_stampless_interactive_claims filters non-task issues" 1 \
			"(expected #100, got #${site_a_num})"
	fi
else
	print_result "Site A: _isc_list_stampless_interactive_claims filters non-task issues" 1 \
		"(expected 1 row, got ${site_a_count})"
fi

# =============================================================================
# Test 9: Verify Site B (_normalize_unassign_stampless_interactive) uses filter
#          by stubbing gh and checking that only the real claim gets unassigned.
# =============================================================================

# Create repos.json fixture
REPOS_JSON="${TEST_ROOT}/repos.json"
cat > "$REPOS_JSON" <<'REPOS'
{
  "initialized_repos": [
    {"slug": "owner/repo", "pulse": true, "local_only": false}
  ]
}
REPOS

# gh stub for Site B: track issue edit calls
EDIT_LOG="${TEST_ROOT}/edit-calls.log"
: > "$EDIT_LOG"

cat > "${STUB_BIN}/gh" <<STUB_EOF
#!/usr/bin/env bash
case "\$*" in
  *"issue list"*)
    cat <<'JSON'
[
  {"number": 100, "updatedAt": "2026-01-01T00:00:00Z", "labels": [{"name": "origin:interactive"}, {"name": "bug"}]},
  {"number": 200, "updatedAt": "2026-01-01T00:00:00Z", "labels": [{"name": "origin:interactive"}, {"name": "routine-tracking"}]},
  {"number": 300, "updatedAt": "2026-01-01T00:00:00Z", "labels": [{"name": "origin:interactive"}, {"name": "supervisor"}]}
]
JSON
    ;;
  *"issue edit"*)
    echo "\$*" >> "${EDIT_LOG}"
    ;;
  *)
    exit 1
    ;;
esac
STUB_EOF
chmod +x "${STUB_BIN}/gh"

# Set required globals for _normalize_unassign_stampless_interactive
export PULSE_QUEUED_SCAN_LIMIT=200
repo_allows_pulse_write_actions() {
	local repo_slug="$1"
	[[ "$repo_slug" == "owner/repo" ]]
	return $?
}

# Source pulse-issue-reconcile.sh (sub-library of pulse-wrapper.sh)
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/pulse-issue-reconcile.sh" 2>/dev/null || true

# Run with stubbed PATH: now_epoch far in the future so all issues are "old enough"
PATH="${STUB_BIN}:${PATH}" _normalize_unassign_stampless_interactive \
	testuser "$REPOS_JSON" 9999999999 86400 2>/dev/null || true

# Only issue #100 should have been edited (unassigned)
edit_count=$(wc -l < "$EDIT_LOG" | tr -d ' ')
if [[ "$edit_count" -eq 1 ]]; then
	if grep -q "100" "$EDIT_LOG" 2>/dev/null; then
		print_result "Site B: _normalize_unassign_stampless_interactive filters non-task issues" 0
	else
		print_result "Site B: _normalize_unassign_stampless_interactive filters non-task issues" 1 \
			"(edit call did not target #100: $(cat "$EDIT_LOG"))"
	fi
else
	print_result "Site B: _normalize_unassign_stampless_interactive filters non-task issues" 1 \
		"(expected 1 edit call, got ${edit_count})"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "---"
printf '%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
