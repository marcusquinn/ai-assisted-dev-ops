#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dispatch-footprint-overlap.sh — t2117 regression guard.
#
# Asserts the file-footprint overlap throttle works correctly:
#
#   1. _footprint_extract_paths parses explicit EDIT:/NEW:/File: declarations
#      from issue bodies, ignores context references, and strips line qualifiers.
#   2. Ordinary prose beginning with "File" is not treated as a declaration.
#   3. _footprint_check_overlap detects overlap between a candidate and
#      in-flight issues (via mock data).
#   4. _footprint_check_overlap allows dispatch when file sets are disjoint.
#   5. _footprint_extract_paths returns empty for issues with no file paths.
#   6. Overlap detection handles normalisation (stripping .agents/ prefix).
#
# Failure history motivating this test: GH#19106 (CONFLICTING cascades
# from overlapping file edits by parallel workers).

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

# Source the footprint module directly
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/dispatch-dedup-footprint.sh"

# =============================================================================
# Test 1 — _footprint_extract_paths parses EDIT/NEW/File prefix paths
# =============================================================================
# shellcheck disable=SC2016 # Markdown backticks are literal fixture content.
body_with_edits='## Files to Modify

- `EDIT: .agents/scripts/pulse-wrapper.sh:45-60` — add throttle
- `NEW: .agents/scripts/dispatch-dedup-footprint.sh` — new module
- `EDIT: .agents/configs/complexity-thresholds.conf` — update threshold
- File: `docs/dispatch.md` — update behavior documentation'

result=$(_footprint_extract_paths "$body_with_edits")
expected='.agents/configs/complexity-thresholds.conf
.agents/scripts/dispatch-dedup-footprint.sh
.agents/scripts/pulse-wrapper.sh
docs/dispatch.md'
if [[ "$result" == "$expected" ]]; then
	print_result "extract_paths: parses EDIT/NEW/File prefixed paths" 0
else
	print_result "extract_paths: parses EDIT/NEW/File prefixed paths" 1 "(got: ${result})"
fi

# =============================================================================
# Test 2 — _footprint_extract_paths strips line qualifiers
# =============================================================================
# shellcheck disable=SC2016 # Markdown backticks are literal fixture content.
body_with_lines='- `EDIT: scripts/helper.sh:1477` — fix bug
- `EDIT: scripts/other.sh:221-253` — refactor section'

result=$(_footprint_extract_paths "$body_with_lines")
# Should NOT contain :1477 or :221-253
if printf '%s' "$result" | grep -q ":[0-9]"; then
	print_result "extract_paths: strips line qualifiers" 1 "(line qualifiers still present: ${result})"
else
	print_result "extract_paths: strips line qualifiers" 0
fi

# =============================================================================
# Test 3 — _footprint_extract_paths ignores context-only paths
# =============================================================================
# shellcheck disable=SC2016 # Markdown backticks are literal fixture content.
body_context_only='## Context

Root-cause data and prior fix: GH#19106 / PR #19107. Relevant files:
- `.agents/scripts/dispatch-dedup-helper.sh` (the dedup ledger)
- `.agents/scripts/pulse-wrapper.sh` (dispatch caller)
- `.agents/templates/brief-template.md` (Files to modify section format)'

result=$(_footprint_extract_paths "$body_context_only")
if [[ -z "$result" ]]; then
	print_result "extract_paths: ignores context-only paths" 0
else
	print_result "extract_paths: ignores context-only paths" 1 "(got: ${result})"
fi

# =============================================================================
# Test 4 — _footprint_extract_paths ignores non-declaration "File" prose
# =============================================================================
body_file_refs='## Pre-flight

File refs verified against the current implementation.
No files are declared for modification in this section.'

result=$(_footprint_extract_paths "$body_file_refs")
if [[ -z "$result" ]]; then
	print_result "extract_paths: ignores File prose without an explicit colon" 0
else
	print_result "extract_paths: ignores File prose without an explicit colon" 1 "(got: ${result})"
fi

# =============================================================================
# Test 5 — _footprint_extract_paths returns only declared paths in mixed briefs
# =============================================================================
# shellcheck disable=SC2016 # Markdown backticks are literal fixture content.
body_mixed='## Files to Modify

- EDIT: `.agents/scripts/dispatch-dedup-footprint.sh:60-90` — intent-aware parser
- NEW: `.agents/scripts/tests/test-footprint-intent.sh` — regression coverage

## Reference Pattern

- `.agents/scripts/pulse-dispatch-large-file-gate.sh` — context only
- `.agents/scripts/tests/test-large-file-gate-extract-edit-only.sh` — context only'

result=$(_footprint_extract_paths "$body_mixed")
expected='.agents/scripts/dispatch-dedup-footprint.sh
.agents/scripts/tests/test-footprint-intent.sh'
if [[ "$result" == "$expected" ]]; then
	print_result "extract_paths: mixed brief returns only declared targets" 0
else
	print_result "extract_paths: mixed brief returns only declared targets" 1 "(got: ${result})"
fi

# =============================================================================
# Test 6 — _footprint_extract_paths returns empty for no-path body
# =============================================================================
body_no_paths='This issue is about improving performance.
No specific files mentioned here, just a general discussion.'

result=$(_footprint_extract_paths "$body_no_paths")
if [[ -z "$result" ]]; then
	print_result "extract_paths: returns empty for body with no file paths" 0
else
	print_result "extract_paths: returns empty for body with no file paths" 1 "(got: ${result})"
fi

# =============================================================================
# Test 7 — _footprint_check_overlap detects overlap via mock cache
# =============================================================================
# Simulate an in-flight issue #100 modifying pulse-wrapper.sh
_FOOTPRINT_CACHE_REPO="test/repo"
_FOOTPRINT_CACHE_DATA="scripts/pulse-wrapper.sh|100\nscripts/shared-constants.sh|100\n"
_FOOTPRINT_CACHE_EPOCH=$(date +%s)

# Candidate issue #200 also targets pulse-wrapper.sh
# shellcheck disable=SC2016 # Markdown backticks are literal fixture content.
candidate_body='## Files to Modify
- `EDIT: scripts/pulse-wrapper.sh:100-120` — add new feature'

signal=""
overlap_rc=1
signal=$(_footprint_check_overlap "200" "test/repo" "$candidate_body") && overlap_rc=0 || overlap_rc=$?
if [[ "$overlap_rc" -eq 0 ]] && printf '%s' "$signal" | grep -q "FOOTPRINT_OVERLAP"; then
	print_result "check_overlap: detects overlapping files with in-flight issue" 0
else
	print_result "check_overlap: detects overlapping files with in-flight issue" 1 "(rc=${overlap_rc}, signal=${signal})"
fi

# =============================================================================
# Test 8 — _footprint_check_overlap allows disjoint file sets
# =============================================================================
# In-flight #100 modifies pulse-wrapper.sh, candidate #201 modifies a different file
_FOOTPRINT_CACHE_REPO="test/repo"
_FOOTPRINT_CACHE_DATA="scripts/pulse-wrapper.sh|100\n"
_FOOTPRINT_CACHE_EPOCH=$(date +%s)

# shellcheck disable=SC2016 # Markdown backticks are literal fixture content.
disjoint_body='## Files to Modify
- `EDIT: scripts/dispatch-claim-helper.sh:50-70` — different file entirely'

signal=""
overlap_rc=1
signal=$(_footprint_check_overlap "201" "test/repo" "$disjoint_body") && overlap_rc=0 || overlap_rc=$?
if [[ "$overlap_rc" -eq 1 ]]; then
	print_result "check_overlap: allows disjoint file sets" 0
else
	print_result "check_overlap: allows disjoint file sets" 1 "(rc=${overlap_rc}, signal=${signal})"
fi

# =============================================================================
# Test 9 — _footprint_check_overlap handles .agents/ prefix normalisation
# =============================================================================
# In-flight #100 has path without .agents/ prefix
_FOOTPRINT_CACHE_REPO="test/repo"
_FOOTPRINT_CACHE_DATA="scripts/pulse-wrapper.sh|100\n"
_FOOTPRINT_CACHE_EPOCH=$(date +%s)

# Candidate references same file WITH .agents/ prefix
# shellcheck disable=SC2016 # Markdown backticks are literal fixture content.
normalise_body='## Files to Modify
- `EDIT: .agents/scripts/pulse-wrapper.sh:200-220` — same file, different prefix'

signal=""
overlap_rc=1
signal=$(_footprint_check_overlap "202" "test/repo" "$normalise_body") && overlap_rc=0 || overlap_rc=$?
if [[ "$overlap_rc" -eq 0 ]] && printf '%s' "$signal" | grep -q "FOOTPRINT_OVERLAP"; then
	print_result "check_overlap: handles .agents/ prefix normalisation" 0
else
	print_result "check_overlap: handles .agents/ prefix normalisation" 1 "(rc=${overlap_rc}, signal=${signal})"
fi

# =============================================================================
# Test 10 — _footprint_check_overlap excludes self from in-flight check
# =============================================================================
# In-flight includes issue #300 itself
_FOOTPRINT_CACHE_REPO="test/repo"
_FOOTPRINT_CACHE_DATA="scripts/pulse-wrapper.sh|300\n"
_FOOTPRINT_CACHE_EPOCH=$(date +%s)

# shellcheck disable=SC2016 # Markdown backticks are literal fixture content.
self_body='## Files to Modify
- `EDIT: scripts/pulse-wrapper.sh:50-60` — same file as self'

signal=""
overlap_rc=1
signal=$(_footprint_check_overlap "300" "test/repo" "$self_body") && overlap_rc=0 || overlap_rc=$?
if [[ "$overlap_rc" -eq 1 ]]; then
	print_result "check_overlap: excludes self from overlap detection" 0
else
	print_result "check_overlap: excludes self from overlap detection" 1 "(rc=${overlap_rc}, signal=${signal})"
fi

# =============================================================================
# Test 11 — _footprint_get_inflight excludes parent-task coordination footprints
# =============================================================================
TEST_BIN="${TEST_ROOT}/bin"
mkdir -p "$TEST_BIN"
cat >"${TEST_BIN}/gh" <<'MOCK_GH'
#!/usr/bin/env bash
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
	[[ "${MOCK_BLOCKER_FAIL:-0}" == "1" ]] && exit 1
	printf '{"number":401,"state":"%s","body":"## Files to Modify\\n- `EDIT: %s`","labels":[{"name":"%s"}]}\n' \
		"${MOCK_BLOCKER_STATE:-OPEN}" "${MOCK_BLOCKER_PATH:-.agents/scripts/pulse-wrapper.sh}" \
		"${MOCK_BLOCKER_LABEL:-status:in-review}"
	exit 0
fi

label=""
while [[ "$#" -gt 0 ]]; do
	case "${1:-}" in
		--label)
			shift
			label="${1:-}"
			;;
	esac
	shift || true
done

if [[ "$label" == "status:in-review" ]]; then
	printf '%s\n' '[{"number":400,"body":"## Files to Modify\n- `EDIT: docs/gui/control-plane.md`","labels":[{"name":"status:in-review"},{"name":"parent-task"}]},{"number":401,"body":"## Files to Modify\n- `EDIT: .agents/scripts/pulse-wrapper.sh`","labels":[{"name":"status:in-review"}]}]'
else
	printf '[]\n'
fi
MOCK_GH
chmod +x "${TEST_BIN}/gh"

OLD_PATH="$PATH"
PATH="${TEST_BIN}:$PATH"
_FOOTPRINT_CACHE_REPO=""
_FOOTPRINT_CACHE_DATA=""
_FOOTPRINT_CACHE_EPOCH=0

result=$(_footprint_get_inflight "test/repo" "999")
PATH="$OLD_PATH"
if printf '%s' "$result" | grep -q "pulse-wrapper.sh|401" &&
	! printf '%s' "$result" | grep -q "docs/gui/control-plane.md|400"; then
	print_result "get_inflight: excludes parent-task coordination footprints" 0
else
	print_result "get_inflight: excludes parent-task coordination footprints" 1 "(got: ${result})"
fi

# =============================================================================
# Test 12 — durable defer suppresses unchanged overlap across cycles
# =============================================================================
_FOOTPRINT_DEFER_STATE_DIR="${TEST_ROOT}/footprint-defers"
_FOOTPRINT_DEFER_TTL_SECONDS=1800
LOGFILE="${TEST_ROOT}/pulse.log"
export PATH="${TEST_BIN}:$OLD_PATH"
# shellcheck disable=SC2016 # Markdown backticks are literal fixture content.
candidate_body='## Files to Modify
- `EDIT: .agents/scripts/pulse-wrapper.sh:100-120` — same file'
inflight_data='.agents/scripts/pulse-wrapper.sh|401'
_footprint_defer_record_overlap "500" "test/repo" \
	"$(_footprint_extract_paths "$candidate_body")" "$inflight_data" "401" ".agents/scripts/pulse-wrapper.sh"
candidate_json=$(jq -cn --arg body "$candidate_body" '{body:$body,labels:[{"name":"auto-dispatch"}]}')
if _footprint_defer_should_suppress "500" "test/repo" "$candidate_json"; then
	status_json=$(_footprint_defer_status_json "500" "test/repo")
	suppressed_count=$(printf '%s' "$status_json" | jq -r '.suppressed_count // 0')
	if [[ "$suppressed_count" == "1" && "$(printf '%s' "$status_json" | jq -r '.active')" == "true" ]]; then
		print_result "durable defer: suppresses unchanged active overlap" 0
	else
		print_result "durable defer: suppresses unchanged active overlap" 1 "(state=${status_json})"
	fi
else
	print_result "durable defer: suppresses unchanged active overlap" 1 "(unexpected reconsideration)"
fi

# =============================================================================
# Test 13 — candidate footprint changes wake the defer
# =============================================================================
# shellcheck disable=SC2016 # Markdown backticks are literal fixture content.
changed_body='## Files to Modify
- `EDIT: .agents/scripts/other.sh` — changed file'
changed_json=$(jq -cn --arg body "$changed_body" '{body:$body,labels:[{"name":"auto-dispatch"}]}')
if _footprint_defer_should_suppress "500" "test/repo" "$changed_json"; then
	print_result "durable defer: candidate footprint change wakes reconsideration" 1 "(still suppressed)"
else
	status_json=$(_footprint_defer_status_json "500" "test/repo")
	wake_reason=$(printf '%s' "$status_json" | jq -r '.wake_reason // ""')
	if [[ "$wake_reason" == "candidate_footprint_changed" ]]; then
		print_result "durable defer: candidate footprint change wakes reconsideration" 0
	else
		print_result "durable defer: candidate footprint change wakes reconsideration" 1 "(state=${status_json})"
	fi
fi

# =============================================================================
# Test 14 — blocker lifecycle changes wake the defer
# =============================================================================
_footprint_defer_record_overlap "501" "test/repo" \
	"$(_footprint_extract_paths "$candidate_body")" "$inflight_data" "401" ".agents/scripts/pulse-wrapper.sh"
MOCK_BLOCKER_STATE=CLOSED
export MOCK_BLOCKER_STATE
if _footprint_defer_should_suppress "501" "test/repo" "$candidate_json"; then
	print_result "durable defer: blocker close wakes reconsideration" 1 "(still suppressed)"
else
	status_json=$(_footprint_defer_status_json "501" "test/repo")
	wake_reason=$(printf '%s' "$status_json" | jq -r '.wake_reason // ""')
	if [[ "$wake_reason" == "blocker_lifecycle_changed" ]]; then
		print_result "durable defer: blocker close wakes reconsideration" 0
	else
		print_result "durable defer: blocker close wakes reconsideration" 1 "(state=${status_json})"
	fi
fi
unset MOCK_BLOCKER_STATE

# =============================================================================
# Test 15 — malformed state falls through to the live overlap check
# =============================================================================
state_path=$(_footprint_defer_state_path "test/repo" "502")
mkdir -p "${state_path%/*}"
printf '{malformed\n' >"$state_path"
if _footprint_defer_should_suppress "502" "test/repo" "$candidate_json"; then
	print_result "durable defer: malformed state fails through to live check" 1 "(unsafe suppression)"
else
	print_result "durable defer: malformed state fails through to live check" 0
fi

# =============================================================================
# Test 16 — blocker footprint changes wake the defer
# =============================================================================
_footprint_defer_record_overlap "503" "test/repo" \
	"$(_footprint_extract_paths "$candidate_body")" "$inflight_data" "401" ".agents/scripts/pulse-wrapper.sh"
MOCK_BLOCKER_PATH=.agents/scripts/changed.sh
export MOCK_BLOCKER_PATH
if _footprint_defer_should_suppress "503" "test/repo" "$candidate_json"; then
	print_result "durable defer: blocker footprint change wakes reconsideration" 1 "(still suppressed)"
else
	status_json=$(_footprint_defer_status_json "503" "test/repo")
	wake_reason=$(printf '%s' "$status_json" | jq -r '.wake_reason // ""')
	if [[ "$wake_reason" == "blocker_footprint_changed" ]]; then
		print_result "durable defer: blocker footprint change wakes reconsideration" 0
	else
		print_result "durable defer: blocker footprint change wakes reconsideration" 1 "(state=${status_json})"
	fi
fi
unset MOCK_BLOCKER_PATH

# =============================================================================
# Test 17 — force-dispatch explicitly wakes but does not authorize overlap
# =============================================================================
_footprint_defer_record_overlap "504" "test/repo" \
	"$(_footprint_extract_paths "$candidate_body")" "$inflight_data" "401" ".agents/scripts/pulse-wrapper.sh"
force_json=$(jq -cn --arg body "$candidate_body" '{body:$body,labels:[{"name":"force-dispatch"}]}')
if _footprint_defer_should_suppress "504" "test/repo" "$force_json"; then
	print_result "durable defer: operator reconsideration wakes live check" 1 "(still suppressed)"
else
	status_json=$(_footprint_defer_status_json "504" "test/repo")
	wake_reason=$(printf '%s' "$status_json" | jq -r '.wake_reason // ""')
	if [[ "$wake_reason" == "operator_reconsideration" ]]; then
		print_result "durable defer: operator reconsideration wakes live check" 0
	else
		print_result "durable defer: operator reconsideration wakes live check" 1 "(state=${status_json})"
	fi
fi

# =============================================================================
# Test 18 — bounded cooldown expiry wakes the live check
# =============================================================================
_footprint_defer_record_overlap "505" "test/repo" \
	"$(_footprint_extract_paths "$candidate_body")" "$inflight_data" "401" ".agents/scripts/pulse-wrapper.sh"
state_path=$(_footprint_defer_state_path "test/repo" "505")
state_json=$(_footprint_defer_read_json "$state_path")
state_json=$(printf '%s' "$state_json" | jq -c '.expires_at = 0')
_footprint_defer_write_json "$state_path" "$state_json"
if _footprint_defer_should_suppress "505" "test/repo" "$candidate_json"; then
	print_result "durable defer: cooldown expiry wakes reconsideration" 1 "(still suppressed)"
else
	status_json=$(_footprint_defer_status_json "505" "test/repo")
	wake_reason=$(printf '%s' "$status_json" | jq -r '.wake_reason // ""')
	if [[ "$wake_reason" == "cooldown_expired" ]]; then
		print_result "durable defer: cooldown expiry wakes reconsideration" 0
	else
		print_result "durable defer: cooldown expiry wakes reconsideration" 1 "(state=${status_json})"
	fi
fi

# =============================================================================
# Test 19 — blocker refresh failure remains safely suppressed
# =============================================================================
_footprint_defer_record_overlap "506" "test/repo" \
	"$(_footprint_extract_paths "$candidate_body")" "$inflight_data" "401" ".agents/scripts/pulse-wrapper.sh"
MOCK_BLOCKER_FAIL=1
export MOCK_BLOCKER_FAIL
if _footprint_defer_should_suppress "506" "test/repo" "$candidate_json"; then
	print_result "durable defer: blocker refresh failure remains fail-closed" 0
else
	print_result "durable defer: blocker refresh failure remains fail-closed" 1 "(unsafe reconsideration)"
fi
unset MOCK_BLOCKER_FAIL
PATH="$OLD_PATH"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "Tests: ${TESTS_RUN} run, ${TESTS_FAILED} failed"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
