#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC2016  # single-quoted regex/grep patterns are literal by design
#
# test-parent-phase-dep-parser.sh — tests for t2877 (GH#20972)
#
# Tests for the cross-phase dependency parser helpers added to
# issue-sync-relationships.sh:
#
#   _resolve_single_phase_ref  — exact and prefix-match phase → issue num
#   _expand_slash_notation     — P0.5b/c → P0.5b + P0.5c
#   _expand_phase_refs_to_nums — full tokeniser: handles +, comma, slash
#   _parse_parent_phase_deps   — full parser: phases table + dep section → PAIRs
#
# Test coverage:
#
#   Class A — _resolve_single_phase_ref
#     1.  Exact match returns correct issue number
#     2.  Bare phase (P1) returns all children (P1a, P1c)
#     3.  Decimal bare phase (P0.5) returns all children (P0.5a, P0.5b, P0.5c)
#     4.  Unknown phase returns empty
#
#   Class B — _expand_slash_notation
#     5.  P0.5b/c expands to both P0.5b and P0.5c issue numbers
#     6.  P4a/P4b (both start with P) expands to both issue numbers
#     7.  Single element (no slash) returns the one issue number
#
#   Class C — _expand_phase_refs_to_nums
#     8.  "P0a + P0b" returns two numbers
#     9.  "P4 + P1c + P0.5b/c" returns all expanded numbers
#    10.  "P1 children" strips "children" and returns P1 prefix matches
#    11.  Empty / whitespace input returns nothing
#
#   Class D — _parse_parent_phase_deps (full t2840 dependency line shapes)
#    12.  No phases table → no output
#    13.  Phases table present, no dep section → no output
#    14.  "P2d blocked by P2c" → one PAIR
#    15.  "P1 children blocked by P0a + P0b" → four PAIRs (2×2)
#    16.  "P2c blocked by P0.5a + P0.5c" → two PAIRs
#    17.  "P0.5 children blocked by P0a" → three PAIRs (3 P0.5 children × 1)
#    18.  "P5c blocked by P4a + P4b" → two PAIRs
#    19.  "P6 blocked by P4 + P1c + P0.5b/c" → 2×5 = 10 PAIRs
#    20.  "P2a/P2b can ship in parallel with P0" → zero PAIRs (skip)
#    21.  Idempotent: same body → same PAIR output (deterministic)
#    22.  cmd_backfill_cross_phase_blocked_by --dry-run prints DRY-RUN lines
#    23.  Missing --issue flag → non-zero exit
#
# Strategy:
#   - Source issue-sync-helper.sh (which sources issue-sync-relationships.sh)
#     with a stubbed gh binary that returns success for all mutations and
#     canned node IDs for all issue views.
#   - Pure string-processing tests (Class A-D) need no network.
#   - Class E (cmd_*) uses a stub gh to record mutations.

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

assert_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" == *"$needle"* ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '       expected to contain: %s\n' "$needle"
		printf '       actual: %s\n' "$haystack"
	fi
	return 0
}

assert_not_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" != *"$needle"* ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '       expected NOT to contain: %s\n' "$needle"
		printf '       actual: %s\n' "$haystack"
	fi
	return 0
}

assert_empty() {
	local label="$1" val="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -z "$val" ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '       expected empty, got: %s\n' "$val"
	fi
	return 0
}

count_lines() {
	local text="$1"
	# Use safe grep-c pattern (t2763): grep -c exits 1 on zero-match and still
	# prints "0"; "|| echo 0" would stack "0\n0". Use || true and validate instead.
	local _n
	_n=$(printf '%s' "$text" | grep -c '.' 2>/dev/null || true)
	[[ "$_n" =~ ^[0-9]+$ ]] || _n=0
	printf '%s\n' "$_n"
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/issue-sync-helper.sh"

if [[ ! -f "$HELPER" ]]; then
	printf 'test harness cannot find helper at %s\n' "$HELPER" >&2
	exit 1
fi

TMP=$(mktemp -d -t t2877-phase-dep.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------------
# Stubbed gh binary
# -----------------------------------------------------------------------------
GH_LOG="${TMP}/gh.log"
export GH_LOG
: >"$GH_LOG"

mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"

cmd1="${1:-}"
cmd2="${2:-}"

# gh issue view <N> --json body
if [[ "$cmd1" == "issue" && "$cmd2" == "view" ]]; then
	num="${3:-}"
	var="GH_ISSUE_${num}_JSON"
	payload="${!var:-}"
	if [[ -z "$payload" ]]; then
		payload='{"title":"","body":"","labels":[]}'
	fi
	# honour --jq if jq available
	jq_filter=""
	prev=""
	for arg in "$@"; do
		if [[ "$prev" == "--jq" ]]; then jq_filter="$arg"; fi
		prev="$arg"
	done
	if [[ -n "$jq_filter" ]] && command -v jq >/dev/null 2>&1; then
		printf '%s\n' "$payload" | jq -r "$jq_filter"
	else
		printf '%s\n' "$payload"
	fi
	exit 0
fi

# gh api graphql -f query=...
if [[ "$cmd1" == "api" && "$cmd2" == "graphql" ]]; then
	[[ "${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" == "1" && "$*" == *"rateLimit"* ]] || exit 1
	for arg in "$@"; do
		if [[ "$arg" == *"addBlockedBy"* ]]; then
			printf '%s\n' '{"data":{"addBlockedBy":{"issue":{"number":99}},"rateLimit":{"cost":1}}}'
			exit 0
		fi
		if [[ "$arg" == *"blockedBy(first:100)"* ]]; then
			printf '%s\n' '{"data":{"node":{"blockedBy":{"nodes":[],"pageInfo":{"hasNextPage":false}}},"rateLimit":{"cost":1}}}'
			exit 0
		fi
		if [[ "$arg" == *"issue(number"* ]]; then
			printf '%s\n' '{"data":{"repository":{"issue":{"id":"NODE_STUB_ID"}},"rateLimit":{"cost":1}}}'
			exit 0
		fi
	done
	printf '%s\n' '{}'
	exit 0
fi

# gh api rate_limit
if [[ "$cmd1" == "api" && "$cmd2" == "rate_limit" ]]; then
	printf '%s\n' '{"resources":{"graphql":{"remaining":5000}}}'
	exit 0
fi

# gh api /repos/.../issues/NNN → REST node_id fallback
if [[ "$cmd1" == "api" && "$cmd2" =~ ^/repos/ ]]; then
	printf '%s\n' '{"node_id":"REST_NODE_STUB"}'
	exit 0
fi

printf '%s\n' '{}'
exit 0
STUB
chmod +x "${TMP}/bin/gh"

# Prepend stub directory to PATH so both the helper and sub-processes use it.
export PATH="${TMP}/bin:${PATH}"

# Source the helper (which sources issue-sync-relationships.sh)
DRY_RUN="false"
VERBOSE="false"
REPO_SLUG="marcusquinn/aidevops"
FORCE_CLOSE="false"
FORCE_ENRICH="false"
FORCE_PUSH="false"
# shellcheck disable=SC1090
source "$HELPER" >/dev/null 2>&1 || true
# Re-prepend stub: issue-sync-helper.sh resets PATH to system paths internally
# (line 32: export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"), which pushes
# the stub binary to the end and lets the real gh take over. Re-adding here
# ensures sub-process calls from cmd_* functions use the stub, not real gh.
export PATH="${TMP}/bin:${PATH}"

# Expose functions loaded via sourced sub-files
# (issue-sync-relationships.sh is sourced inside issue-sync-helper.sh)

# Minimal _init_cmd stub so cmd_backfill_cross_phase_blocked_by can initialise.
# In real usage _init_cmd sets _CMD_REPO and _CMD_TODO. Here we set them directly.
_CMD_REPO="${REPO_SLUG:-marcusquinn/aidevops}"
_CMD_TODO="${TMP}/TODO.md"
printf '' >"$_CMD_TODO"

# Override _init_cmd so command tests don't require a full TODO.md / repo context.
_init_cmd() {
	_CMD_REPO="${REPO_SLUG:-marcusquinn/aidevops}"
	_CMD_TODO="${TMP}/TODO.md"
	return 0
}

# --------------------------------------------------------------------------
# Shared fixture: phase_map matching t2840 / #20892 subset
# --------------------------------------------------------------------------
# P0 children
PHASE_MAP=""
PHASE_MAP+="P0a=20896"$'\n'
PHASE_MAP+="P0b=20895"$'\n'
PHASE_MAP+="P0c=20897"$'\n'
# P0.5 children
PHASE_MAP+="P0.5a=20899"$'\n'
PHASE_MAP+="P0.5b=20900"$'\n'
PHASE_MAP+="P0.5c=20901"$'\n'
# P1 children
PHASE_MAP+="P1a=20902"$'\n'
PHASE_MAP+="P1c=20903"$'\n'
# P2 children
PHASE_MAP+="P2a=20930"$'\n'
PHASE_MAP+="P2b=20931"$'\n'
PHASE_MAP+="P2c=20932"$'\n'
PHASE_MAP+="P2d=20933"$'\n'
# P4 children
PHASE_MAP+="P4a=20904"$'\n'
PHASE_MAP+="P4b=20905"$'\n'
PHASE_MAP+="P4c=20906"$'\n'
# P5 children
PHASE_MAP+="P5a=20908"$'\n'
PHASE_MAP+="P5b=20909"$'\n'
PHASE_MAP+="P5c=20910"$'\n'
# P6 children
PHASE_MAP+="P6a=20911"$'\n'
PHASE_MAP+="P6b=20912"$'\n'

# Build a synthetic parent body that matches the t2840 format.
# Used by Class D tests.
read -r -d '' PARENT_BODY <<'BODY' || true
## Phases & Children

### P0 — knowledge plane skeleton

| Child | Title |
|---|---|
| t2844 / #20896 | P0a: knowledge plane directory contract + provisioning |
| t2843 / #20895 | P0b: knowledge CLI surface |
| t2845 / #20897 | P0c: knowledge review gate routine |

### P0.5 — sensitivity + LLM routing layer

| Child | Title |
|---|---|
| t2846 / #20899 | P0.5a: sensitivity classification schema |
| t2847 / #20900 | P0.5b: LLM routing helper |
| t2848 / #20901 | P0.5c: Ollama integration |

### P1 — kind-aware enrichment

| Child | Title |
|---|---|
| t2849 / #20902 | P1a: kind-aware enrichment |
| t2850 / #20903 | P1c: PageIndex tree generation |

### P2 — `_inbox/` capture

| Child | Title |
|---|---|
| t2866 / #20930 | P2a: _inbox/ directory contract |
| t2867 / #20931 | P2b: inbox capture CLI |
| t2868 / #20932 | P2c: inbox triage routine |
| t2869 / #20933 | P2d: pulse digest |

### P4 — cases plane

| Child | Title |
|---|---|
| t2851 / #20904 | P4a: case dossier contract |
| t2852 / #20905 | P4b: case CLI surface |
| t2853 / #20906 | P4c: case milestone |

### P5 — email channel

| Child | Title |
|---|---|
| t2854 / #20908 | P5a: .eml ingestion |
| t2855 / #20909 | P5b: IMAP polling |
| t2856 / #20910 | P5c: email thread reconstruction |

### P6 — AI comms agent

| Child | Title |
|---|---|
| t2857 / #20911 | P6a: aidevops case draft agent |
| t2858 / #20912 | P6b: aidevops case chase |

## Cross-Phase Dependencies

- P0.5 children blocked by P0a (need plane substrate to stamp meta.json)
- P1 children blocked by P0a + P0b (need directory contract + CLI before structured extraction)
- P2a/P2b can ship in parallel with P0 (independent directory contract)
- P2c blocked by P0.5a + P0.5c (sensitivity-first triage requires local detector + Ollama)
- P2d blocked by P2c (digest reads from triage.log)
- P4 children blocked by P0a + P0b + P0.5a (cases plane uses sensitivity stamps)
- P5 children blocked by P0a + P0b + P1a (email is a kind of knowledge ingestion)
- P5c blocked by P4a + P4b (filter→case-attach uses case CLI)
- P6 blocked by P4 + P1c + P0.5b/c (drafts use cases, RAG, LLM routing)

Within each phase, children that don't depend on each other can run in parallel.

## Reference

Full design: todo/tasks/t2840-brief.md
BODY

# =============================================================================
# Class A — _resolve_single_phase_ref
# =============================================================================
printf '\n%s--- Class A: _resolve_single_phase_ref ---%s\n' "$TEST_BLUE" "$TEST_NC"

# Test 1: exact match returns correct issue number
result=$(_resolve_single_phase_ref "P0a" "$PHASE_MAP")
[[ "$result" == "20896" ]] && pass "1. exact match P0a → 20896" \
	|| fail "1. exact match P0a → 20896" "got: ${result}"

# Test 2: bare phase P1 returns both P1 children
result=$(_resolve_single_phase_ref "P1" "$PHASE_MAP")
assert_contains "2. bare P1 includes P1a (20902)" "20902" "$result"
assert_contains "2. bare P1 includes P1c (20903)" "20903" "$result"

# Test 3: decimal bare phase P0.5 returns all three children
result=$(_resolve_single_phase_ref "P0.5" "$PHASE_MAP")
assert_contains "3. bare P0.5 includes P0.5a (20899)" "20899" "$result"
assert_contains "3. bare P0.5 includes P0.5b (20900)" "20900" "$result"
assert_contains "3. bare P0.5 includes P0.5c (20901)" "20901" "$result"

# Test 4: unknown phase returns empty
result=$(_resolve_single_phase_ref "P9x" "$PHASE_MAP")
assert_empty "4. unknown phase P9x → empty" "$result"

# =============================================================================
# Class B — _expand_slash_notation
# =============================================================================
printf '\n%s--- Class B: _expand_slash_notation ---%s\n' "$TEST_BLUE" "$TEST_NC"

# Test 5: P0.5b/c expands to P0.5b and P0.5c
result=$(_expand_slash_notation "P0.5b/c" "$PHASE_MAP")
assert_contains "5. P0.5b/c includes P0.5b (20900)" "20900" "$result"
assert_contains "5. P0.5b/c includes P0.5c (20901)" "20901" "$result"
line_count=$(count_lines "$result")
[[ "$line_count" -eq 2 ]] && pass "5. P0.5b/c expands to exactly 2 issue numbers" \
	|| fail "5. P0.5b/c expands to exactly 2 issue numbers" "got count: ${line_count}, val: ${result}"

# Test 6: P4a/P4b (both start with P) expands to both
result=$(_expand_slash_notation "P4a/P4b" "$PHASE_MAP")
assert_contains "6. P4a/P4b includes P4a (20904)" "20904" "$result"
assert_contains "6. P4a/P4b includes P4b (20905)" "20905" "$result"

# Test 7: single element (no slash) returns the one number
result=$(_expand_slash_notation "P2c" "$PHASE_MAP")
[[ "$result" == "20932" ]] && pass "7. single P2c → 20932" \
	|| fail "7. single P2c → 20932" "got: ${result}"

# =============================================================================
# Class C — _expand_phase_refs_to_nums
# =============================================================================
printf '\n%s--- Class C: _expand_phase_refs_to_nums ---%s\n' "$TEST_BLUE" "$TEST_NC"

# Test 8: "P0a + P0b" returns two issue numbers
result=$(_expand_phase_refs_to_nums "P0a + P0b" "$PHASE_MAP")
assert_contains "8. P0a + P0b includes 20896" "20896" "$result"
assert_contains "8. P0a + P0b includes 20895" "20895" "$result"

# Test 9: "P4 + P1c + P0.5b/c" returns all expanded numbers
result=$(_expand_phase_refs_to_nums "P4 + P1c + P0.5b/c" "$PHASE_MAP")
assert_contains "9. P4+P1c+P0.5b/c includes P4a (20904)" "20904" "$result"
assert_contains "9. P4+P1c+P0.5b/c includes P4b (20905)" "20905" "$result"
assert_contains "9. P4+P1c+P0.5b/c includes P4c (20906)" "20906" "$result"
assert_contains "9. P4+P1c+P0.5b/c includes P1c (20903)" "20903" "$result"
assert_contains "9. P4+P1c+P0.5b/c includes P0.5b (20900)" "20900" "$result"
assert_contains "9. P4+P1c+P0.5b/c includes P0.5c (20901)" "20901" "$result"

# Test 10: "P1 children" strips "children" and returns P1 prefix matches
result=$(_expand_phase_refs_to_nums "P1 children" "$PHASE_MAP")
assert_contains "10. P1 children includes P1a (20902)" "20902" "$result"
assert_contains "10. P1 children includes P1c (20903)" "20903" "$result"

# Test 11: empty input returns nothing
result=$(_expand_phase_refs_to_nums "" "$PHASE_MAP")
assert_empty "11. empty input returns empty" "$result"

# =============================================================================
# Class D — _parse_parent_phase_deps (full parser)
# =============================================================================
printf '\n%s--- Class D: _parse_parent_phase_deps ---%s\n' "$TEST_BLUE" "$TEST_NC"

# Test 12: no phases table → no output
BODY_NO_TABLE="## Cross-Phase Dependencies

- P1 children blocked by P0a
"
result=$(_parse_parent_phase_deps "$BODY_NO_TABLE")
assert_empty "12. no phases table → no PAIR output" "$result"

# Test 13: phases table present, no dep section → no output
BODY_NO_DEP_SECTION="## Phases & Children

| t100 / #100 | P1a: first child |
| t101 / #101 | P0a: blocker |

## Other Section

Some other content.
"
result=$(_parse_parent_phase_deps "$BODY_NO_DEP_SECTION")
assert_empty "13. no dep section → no PAIR output" "$result"

# Test 14: simple single-blocker line "P2d blocked by P2c"
BODY_SIMPLE="## Phases & Children

| t100 / #100 | P2d: digest |
| t101 / #101 | P2c: triage |

## Cross-Phase Dependencies

- P2d blocked by P2c (digest reads from triage.log)
"
result=$(_parse_parent_phase_deps "$BODY_SIMPLE")
assert_contains "14. P2d blocked by P2c → PAIR:100:101" "PAIR:100:101" "$result"
line_count=$(count_lines "$result")
[[ "$line_count" -eq 1 ]] && pass "14. exactly one PAIR" \
	|| fail "14. exactly one PAIR" "got count: ${line_count}"

# Test 15: "P1 children blocked by P0a + P0b" → 4 pairs (2 children × 2 blockers)
BODY_P1_DEP="## Phases & Children

| t1 / #1001 | P1a: child A |
| t2 / #1002 | P1c: child C |
| t3 / #2001 | P0a: blocker A |
| t4 / #2002 | P0b: blocker B |

## Cross-Phase Dependencies

- P1 children blocked by P0a + P0b
"
result=$(_parse_parent_phase_deps "$BODY_P1_DEP")
assert_contains "15. P1a blocked by P0a → PAIR:1001:2001" "PAIR:1001:2001" "$result"
assert_contains "15. P1a blocked by P0b → PAIR:1001:2002" "PAIR:1001:2002" "$result"
assert_contains "15. P1c blocked by P0a → PAIR:1002:2001" "PAIR:1002:2001" "$result"
assert_contains "15. P1c blocked by P0b → PAIR:1002:2002" "PAIR:1002:2002" "$result"
line_count=$(count_lines "$result")
[[ "$line_count" -eq 4 ]] && pass "15. exactly 4 PAIRs" \
	|| fail "15. exactly 4 PAIRs (P1×(P0a+P0b))" "got count: ${line_count}, pairs: ${result}"

# Test 16: "P2c blocked by P0.5a + P0.5c" → 2 pairs
BODY_P2C_DEP="## Phases & Children

| t1 / #3001 | P2c: triage |
| t2 / #4001 | P0.5a: sensitivity |
| t3 / #4003 | P0.5c: Ollama |

## Cross-Phase Dependencies

- P2c blocked by P0.5a + P0.5c (sensitivity-first triage)
"
result=$(_parse_parent_phase_deps "$BODY_P2C_DEP")
assert_contains "16. P2c blocked by P0.5a → PAIR:3001:4001" "PAIR:3001:4001" "$result"
assert_contains "16. P2c blocked by P0.5c → PAIR:3001:4003" "PAIR:3001:4003" "$result"
line_count=$(count_lines "$result")
[[ "$line_count" -eq 2 ]] && pass "16. exactly 2 PAIRs" \
	|| fail "16. exactly 2 PAIRs" "got count: ${line_count}"

# Test 17: "P0.5 children blocked by P0a" → 3 pairs (3 P0.5 children × 1 blocker)
BODY_P05_DEP="## Phases & Children

| t1 / #5001 | P0.5a: sensitivity schema |
| t2 / #5002 | P0.5b: LLM routing |
| t3 / #5003 | P0.5c: Ollama |
| t4 / #6001 | P0a: dir contract |

## Cross-Phase Dependencies

- P0.5 children blocked by P0a (need plane substrate)
"
result=$(_parse_parent_phase_deps "$BODY_P05_DEP")
assert_contains "17. P0.5a blocked by P0a → PAIR:5001:6001" "PAIR:5001:6001" "$result"
assert_contains "17. P0.5b blocked by P0a → PAIR:5002:6001" "PAIR:5002:6001" "$result"
assert_contains "17. P0.5c blocked by P0a → PAIR:5003:6001" "PAIR:5003:6001" "$result"
line_count=$(count_lines "$result")
[[ "$line_count" -eq 3 ]] && pass "17. exactly 3 PAIRs" \
	|| fail "17. exactly 3 PAIRs" "got count: ${line_count}"

# Test 18: "P5c blocked by P4a + P4b" → 2 pairs
BODY_P5C_DEP="## Phases & Children

| t1 / #7001 | P5c: email thread |
| t2 / #8001 | P4a: case dossier |
| t3 / #8002 | P4b: case CLI |

## Cross-Phase Dependencies

- P5c blocked by P4a + P4b (filter→case-attach uses case CLI)
"
result=$(_parse_parent_phase_deps "$BODY_P5C_DEP")
assert_contains "18. P5c blocked by P4a → PAIR:7001:8001" "PAIR:7001:8001" "$result"
assert_contains "18. P5c blocked by P4b → PAIR:7001:8002" "PAIR:7001:8002" "$result"
line_count=$(count_lines "$result")
[[ "$line_count" -eq 2 ]] && pass "18. exactly 2 PAIRs" \
	|| fail "18. exactly 2 PAIRs" "got count: ${line_count}"

# Test 19: "P6 blocked by P4 + P1c + P0.5b/c" → 2×5 = 10 PAIRs
BODY_P6_DEP="## Phases & Children

| t1 / #9001 | P6a: draft agent |
| t2 / #9002 | P6b: case chase |
| t3 / #10001 | P4a: case dossier |
| t4 / #10002 | P4b: case CLI |
| t5 / #10003 | P4c: milestone |
| t6 / #11001 | P1c: PageIndex |
| t7 / #12001 | P0.5b: LLM routing |
| t8 / #12002 | P0.5c: Ollama |

## Cross-Phase Dependencies

- P6 blocked by P4 + P1c + P0.5b/c (drafts use cases, RAG, LLM routing)
"
result=$(_parse_parent_phase_deps "$BODY_P6_DEP")
# P6a blocked by each blocker (5 pairs)
assert_contains "19. P6a blocked by P4a" "PAIR:9001:10001" "$result"
assert_contains "19. P6a blocked by P4b" "PAIR:9001:10002" "$result"
assert_contains "19. P6a blocked by P4c" "PAIR:9001:10003" "$result"
assert_contains "19. P6a blocked by P1c" "PAIR:9001:11001" "$result"
assert_contains "19. P6a blocked by P0.5b" "PAIR:9001:12001" "$result"
assert_contains "19. P6a blocked by P0.5c" "PAIR:9001:12002" "$result"
# P6b blocked by each blocker (5 pairs)
assert_contains "19. P6b blocked by P4a" "PAIR:9002:10001" "$result"
assert_contains "19. P6b blocked by P4b" "PAIR:9002:10002" "$result"
assert_contains "19. P6b blocked by P4c" "PAIR:9002:10003" "$result"
assert_contains "19. P6b blocked by P1c" "PAIR:9002:11001" "$result"
assert_contains "19. P6b blocked by P0.5b" "PAIR:9002:12001" "$result"
assert_contains "19. P6b blocked by P0.5c" "PAIR:9002:12002" "$result"
line_count=$(count_lines "$result")
[[ "$line_count" -eq 12 ]] && pass "19. exactly 12 PAIRs (2×6 blockers)" \
	|| fail "19. exactly 12 PAIRs (2×6 blockers)" "got count: ${line_count}"

# Test 20: "P2a/P2b can ship in parallel" → zero PAIRs (skipped)
BODY_PARALLEL="## Phases & Children

| t1 / #13001 | P2a: inbox dir |
| t2 / #13002 | P2b: inbox capture |
| t3 / #14001 | P0a: dir contract |

## Cross-Phase Dependencies

- P2a/P2b can ship in parallel with P0 (independent directory contract)
"
result=$(_parse_parent_phase_deps "$BODY_PARALLEL")
assert_empty "20. parallel line generates no PAIRs" "$result"

# Test 21: idempotent — same body → same PAIR output
result1=$(_parse_parent_phase_deps "$PARENT_BODY")
result2=$(_parse_parent_phase_deps "$PARENT_BODY")
[[ "$result1" == "$result2" ]] && pass "21. idempotent: same body → identical PAIR output" \
	|| fail "21. idempotent: same body → identical PAIR output" "outputs differ"

# Verify the full t2840 body produces expected pairs from the first 8 dep lines
result_full=$(_parse_parent_phase_deps "$PARENT_BODY")
# P0.5 children blocked by P0a
assert_contains "t2840: P0.5a blocked by P0a" "PAIR:20899:20896" "$result_full"
assert_contains "t2840: P0.5b blocked by P0a" "PAIR:20900:20896" "$result_full"
assert_contains "t2840: P0.5c blocked by P0a" "PAIR:20901:20896" "$result_full"
# P1 children blocked by P0a + P0b
assert_contains "t2840: P1a blocked by P0a" "PAIR:20902:20896" "$result_full"
assert_contains "t2840: P1a blocked by P0b" "PAIR:20902:20895" "$result_full"
assert_contains "t2840: P1c blocked by P0a" "PAIR:20903:20896" "$result_full"
assert_contains "t2840: P1c blocked by P0b" "PAIR:20903:20895" "$result_full"
# P2c blocked by P0.5a + P0.5c
assert_contains "t2840: P2c blocked by P0.5a" "PAIR:20932:20899" "$result_full"
assert_contains "t2840: P2c blocked by P0.5c" "PAIR:20932:20901" "$result_full"
# P2d blocked by P2c
assert_contains "t2840: P2d blocked by P2c" "PAIR:20933:20932" "$result_full"
# P6 blocked by P4 + P1c + P0.5b/c
assert_contains "t2840: P6a blocked by P4a" "PAIR:20911:20904" "$result_full"
assert_contains "t2840: P6b blocked by P0.5b" "PAIR:20912:20900" "$result_full"
assert_contains "t2840: P6b blocked by P0.5c" "PAIR:20912:20901" "$result_full"
# Parallel line is NOT present
assert_not_contains "t2840: P2a parallel skipped" "PAIR:20930:" "$result_full"

# =============================================================================
# Class E — cmd_backfill_cross_phase_blocked_by
# =============================================================================
printf '\n%s--- Class E: cmd_backfill_cross_phase_blocked_by ---%s\n' "$TEST_BLUE" "$TEST_NC"

# Test 22: --dry-run prints DRY-RUN lines for each pair (uses stub gh)
# Set up issue view response: return a body with one simple dep
export GH_ISSUE_99_JSON='{"body":"## Phases \u0026 Children\n\n| t1 / #101 | P1a: child |\n| t2 / #201 | P0a: blocker |\n\n## Cross-Phase Dependencies\n\n- P1 children blocked by P0a\n"}'

DRY_RUN="true"
: >"$GH_LOG"
dry_output=$(cmd_backfill_cross_phase_blocked_by --issue 99 2>&1)
DRY_RUN="false"

assert_contains "22. --dry-run output contains DRY-RUN" "DRY-RUN" "$dry_output"
# No addBlockedBy mutation should have been called
dry_mutations=$(grep "addBlockedBy" "$GH_LOG" 2>/dev/null || true)
assert_empty "22. --dry-run makes no addBlockedBy mutations" "$dry_mutations"

# Test 23: missing --issue flag → non-zero exit and error message
set +e
err_output=$(cmd_backfill_cross_phase_blocked_by 2>&1)
err_rc=$?
set -e
[[ "$err_rc" -ne 0 ]] && pass "23. missing --issue exits non-zero" \
	|| fail "23. missing --issue exits non-zero" "got rc: ${err_rc}"
assert_contains "23. error message mentions --issue" "--issue" "$err_output"

# =============================================================================
# Summary
# =============================================================================
printf '\n%s=== Results ===%s\n' "$TEST_BLUE" "$TEST_NC"
printf 'Tests run: %d\n' "$TESTS_RUN"
printf 'Tests failed: %d\n' "$TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
