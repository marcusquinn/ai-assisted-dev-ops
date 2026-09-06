#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-brief-readiness.sh — regression tests for brief-readiness-helper.sh (t2417)
#
# Covers:
#   1. Worker-ready body detection (score >= threshold → exit 0)
#   2. Minimal body detection (score < threshold → exit 1)
#   3. Edge case: score-3 body (just under threshold → exit 1)
#   4. Stub brief creation (writes valid markdown)
#   5. Similarity scoring (high overlap → high %, low overlap → low %)
#   6. Threshold override via BRIEF_READINESS_THRESHOLD env var

set -u
set +e

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
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
		printf '        %s\n' "$2"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Locate the helper
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../brief-readiness-helper.sh"

if [[ ! -x "$HELPER" ]]; then
	echo "FATAL: brief-readiness-helper.sh not found or not executable at $HELPER" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Test fixtures — body texts with varying heading counts
# ---------------------------------------------------------------------------

# 5 headings → worker-ready (above default threshold of 4)
BODY_WORKER_READY="# t1234: Example task

## Session Origin

Created in interactive session.

## What

Implement the foo feature.

## Why

Because the bar needs it.

## How

### Files to modify

- EDIT: src/foo.sh:10-20

### Implementation Steps

1. Do the thing.

## Acceptance

- [ ] Tests pass
- [ ] Lint clean
- [ ] Feature works
"

# 2 headings → NOT worker-ready
BODY_MINIMAL="# Bug report

## Description

Something is broken.

Steps to reproduce:
1. Open app
2. Click button
3. See error
"

# 3 headings → just under threshold (NOT worker-ready at default 4)
BODY_SCORE_3="# t5678: Another task

## What

Fix the broken widget.

## Why

Users are complaining.

## Acceptance

- [ ] Widget works
- [ ] No regressions
"

# 4 headings → exactly at threshold (worker-ready)
BODY_SCORE_4="# t9999: Threshold test

## Task

Do the thing.

## Why

Reasons.

## How

Steps here.

## Acceptance

- [ ] Done
"

# 7 headings → all of them (worker-ready)
BODY_ALL_HEADINGS="# t0001: Full body

## Task

Full specification.

## Why

All the reasons.

## How

Detailed steps.

## Acceptance

All criteria met.

## What

Also this heading.

## Session Origin

Created somewhere.

## Files to modify

- EDIT: file.sh
"

# Markdown fixtures intentionally use literal backticks.
# shellcheck disable=SC2016
BODY_V2_COMPLETE='<!-- aidevops:brief-schema=v2 -->
# Complete schema-v2 brief

## Task
Harden state updates.

## Why
Concurrent migration writes must remain compatible.

## How

### Files to Modify
- EDIT: `src/state.sh`

### Complete Write Surface
- **Callers/readers:** `src/app.sh` reads the state emitted by the writer
- **Writers/mutation paths:** `src/state.sh` is the only writer found by search
- **Tests/fixtures:** `tests/test-state.sh` covers current and migrated state
- **Schemas/config:** N/A because search found no schema for this shell state
- **Generated/deployed mirrors:** `dist/state.sh` is generated during deployment
- **Migrations/backfills:** `scripts/migrate-state.sh` upgrades existing records
- **Cleanup/rollback paths:** `scripts/rollback-state.sh` restores the prior format

### Implementation Steps
1. Make the state replacement atomic and version-aware.

### Hazards and Compatibility
- **Concurrency/atomicity:** write a temporary file and rename it atomically
- **Migration/rollback:** migrate readers before writers and retain rollback parsing
- **Mixed-version/backward compatibility:** old readers continue accepting v1 records
- **Idempotency/retry:** replaying the migration preserves an already migrated record
- **Partial failure/recovery:** interrupted temporary files are ignored and cleaned up

### Verification Before Dispatch
shellcheck src/state.sh scripts/migrate-state.sh scripts/rollback-state.sh
bash tests/test-state.sh
- **Surface mapping:** shellcheck covers writers and migration scripts; the focused test covers mixed-version reads, retries, and rollback

## Acceptance Criteria
- [ ] Concurrent writers produce one complete state record.
- [ ] A failed migration never replaces a valid existing record or regresses v1 reads.
'

BODY_V2_HEADINGS_ONLY='<!-- aidevops:brief-schema=v2 -->
## Task
Do work.
## Why
It is needed.
## How
### Complete Write Surface
### Hazards and Compatibility
### Verification Before Dispatch
## Acceptance Criteria
- [ ] Done
'

# shellcheck disable=SC2016
BODY_V2_DOC_ONLY='<!-- aidevops:brief-schema=v2 -->
## Task
Document the command.
## Why
Operators need accurate usage.
## How
### Files to Modify
- NEW: `docs/command.md`
### Complete Write Surface
- **Callers/readers:** `docs/index.md` will link to the new guide
- **Writers/mutation paths:** N/A because documentation-only work performs no writes
- **Tests/fixtures:** `tests/test-doc-links.sh` checks documentation links
- **Schemas/config:** N/A because search found no schema or config for prose
- **Generated/deployed mirrors:** N/A because evidence shows docs deploy directly
- **Migrations/backfills:** N/A because documentation-only work stores no records
- **Cleanup/rollback paths:** N/A because git revert removes the new-file-only guide
### Implementation Steps
1. Add the guide and index link.
### Hazards and Compatibility
- **Concurrency/atomicity:** N/A because documentation-only edits have no runtime writes
- **Migration/rollback:** rollback is a normal documentation revert
- **Mixed-version/backward compatibility:** existing command syntax remains documented unchanged
- **Idempotency/retry:** rebuilding docs repeatedly produces the same output
- **Partial failure/recovery:** a failed docs build publishes no partial site
### Verification Before Dispatch
bash tests/test-doc-links.sh
- **Surface mapping:** the link test covers the new guide and its only reader
## Acceptance Criteria
- [ ] The command guide is reachable from the docs index.
- [ ] Existing documentation links do not regress or become broken.
'

# shellcheck disable=SC2016
BODY_V2_NEW_FILE_ONLY='<!-- aidevops:brief-schema=v2 -->
## Task
Add an isolated formatter.
## Why
The new format needs a dedicated implementation.
## How
### Files to Modify
- NEW: `src/formatter.sh`
### Complete Write Surface
- **Callers/readers:** `src/cli.sh` will call the new formatter
- **Writers/mutation paths:** N/A because search shows the new-file-only formatter returns text without writes
- **Tests/fixtures:** `tests/test-formatter.sh` is the new focused fixture
- **Schemas/config:** N/A because evidence shows plain text has no schema
- **Generated/deployed mirrors:** `dist/formatter.sh` is copied by the existing build
- **Migrations/backfills:** N/A because no persisted data exists to migrate
- **Cleanup/rollback paths:** N/A because removing the caller and new file fully rolls back
### Implementation Steps
1. Add the formatter and wire its caller.
### Hazards and Compatibility
- **Concurrency/atomicity:** N/A because the pure formatter has no shared state
- **Migration/rollback:** removal of the new caller restores prior behavior
- **Mixed-version/backward compatibility:** the existing output remains the default
- **Idempotency/retry:** repeated calls with the same input return the same output
- **Partial failure/recovery:** formatter failures return before output is emitted
### Verification Before Dispatch
shellcheck src/formatter.sh
bash tests/test-formatter.sh
- **Surface mapping:** shellcheck covers the new file and the focused test covers caller compatibility
## Acceptance Criteria
- [ ] The caller can select the new formatter.
- [ ] Invalid input never changes the existing default output.
'

# Exercise the producer, not a hand-crafted GitHub-only heading repair.
BODY_V2_LEGACY="$BODY_V2_COMPLETE"
BODY_V2_COMPLETE=$("$HELPER" scope-normalize "$BODY_V2_COMPLETE")
BODY_V2_DOC_ONLY=$("$HELPER" scope-normalize "$BODY_V2_DOC_ONLY")
BODY_V2_NEW_FILE_ONLY=$("$HELPER" scope-normalize "$BODY_V2_NEW_FILE_ONLY")

# shellcheck disable=SC2016
BODY_V2_NO_FILES=$(printf '%s\n' "$BODY_V2_COMPLETE" | grep -vE '^### Files to Modify$|^- EDIT: `src/state\.sh`$')
BODY_V2_NO_STEPS=$(printf '%s\n' "$BODY_V2_COMPLETE" | grep -vE '^### Implementation Steps$|^1\. Make the state replacement')
BODY_V2_VERIFICATION_PROSE_ONLY=$(printf '%s\n' "$BODY_V2_COMPLETE" | grep -vE '^shellcheck |^bash tests/test-state\.sh$')
BODY_V2_LOOKALIKE_HEADINGS=$(printf '%s\n' "$BODY_V2_COMPLETE" | sed \
	-e 's/^### Files to Modify$/### Files to Modify Later/' \
	-e 's/^### Complete Write Surface$/### Complete Write Surface Example/' \
	-e 's/^### Implementation Steps$/### Implementation Steps TBD/' \
	-e 's/^### Hazards and Compatibility$/### Hazards and Compatibility Notes/' \
	-e 's/^### Verification Before Dispatch$/### Verification Before Dispatch Example/' \
	-e 's/^## Acceptance Criteria$/## Acceptance Criteria Example/')

# shellcheck disable=SC2016
BODY_V2_FENCED_SECTIONS='<!-- aidevops:brief-schema=v2 -->
## Task
Harden state updates.
## Why
Readers require compatible records.
## How
```markdown
### Files to Modify
- EDIT: `src/state.sh`
### Complete Write Surface
- **Callers/readers:** `src/app.sh` reads state
- **Writers/mutation paths:** `src/state.sh` writes state
- **Tests/fixtures:** `tests/state.sh` tests state
- **Schemas/config:** N/A because search found no schema
- **Generated/deployed mirrors:** N/A because evidence shows direct deployment
- **Migrations/backfills:** `migrate.sh` migrates state
- **Cleanup/rollback paths:** `rollback.sh` restores state
### Implementation Steps
1. Update state atomically.
### Hazards and Compatibility
- **Concurrency/atomicity:** use atomic rename
- **Migration/rollback:** preserve rollback ordering
- **Mixed-version/backward compatibility:** preserve old readers
- **Idempotency/retry:** replay is safe
- **Partial failure/recovery:** ignore partial files
### Verification Before Dispatch
shellcheck src/state.sh
- **Surface mapping:** shellcheck covers the writer
```
## Acceptance Criteria
- [ ] Writers produce a complete record.
- [ ] Failed writes never replace valid state.
'

# shellcheck disable=SC2016
BODY_V2_FENCED_CONTENT='<!-- aidevops:brief-schema=v2 -->
## Task
Harden state updates.
## Why
Readers require compatible records.
## How
### Files to Modify
```markdown
- EDIT: `src/state.sh`
```
### Complete Write Surface
```markdown
- **Callers/readers:** `src/app.sh` reads state
- **Writers/mutation paths:** `src/state.sh` writes state
- **Tests/fixtures:** `tests/state.sh` tests state
- **Schemas/config:** N/A because search found no schema
- **Generated/deployed mirrors:** N/A because evidence shows direct deployment
- **Migrations/backfills:** `migrate.sh` migrates state
- **Cleanup/rollback paths:** `rollback.sh` restores state
```
### Implementation Steps
```markdown
1. Update state atomically.
```
### Hazards and Compatibility
```markdown
- **Concurrency/atomicity:** use atomic rename
- **Migration/rollback:** preserve rollback ordering
- **Mixed-version/backward compatibility:** preserve old readers
- **Idempotency/retry:** replay is safe
- **Partial failure/recovery:** ignore partial files
```
### Verification Before Dispatch
```bash
shellcheck src/state.sh
```
- **Surface mapping:** shellcheck covers the writer
## Acceptance Criteria
```markdown
- [ ] Writers produce a complete record.
- [ ] Failed writes never replace valid state.
```
'

# shellcheck disable=SC2016
BODY_V2_MIXED_FENCES='<!-- aidevops:brief-schema=v2 -->
## Task
Harden state updates.
## Why
Readers require compatible records.
## How
### Files to Modify
````markdown
```text
- EDIT: `src/state.sh`
```
~~~
{path placeholder inside the four-backtick example}
~~~
````
## Acceptance Criteria
- [ ] Writers produce a complete record.
- [ ] Failed writes never replace valid state.
'

# Legitimate placeholder-like syntax inside code must not fail prose validation.
# shellcheck disable=SC2016
BODY_V2_WITH_CODE_SYNTAX="${BODY_V2_COMPLETE}

## Technical Notes
Use \`\${config_path}\` with \`map<Path>\` at the boundary.

\`\`\`javascript
const record = { path: configPath, command: runCommand };
\`\`\`
"

# Generated GitHub wrappers are prose structure, not unfinished placeholders.
# Their inner text must remain available to normal readiness checks.
BODY_V2_WITH_GENERATED_HTML="${BODY_V2_COMPLETE}

## Related Context

<details open class=\"generated-context\"><summary data-kind=\"related-file\"><code dir=\"ltr\">src/related.sh</code></summary>
Generated architecture context remains part of the composed issue body.
<details><summary>Nested context</summary>Nested evidence remains visible.</details>
</details>
"

BODY_V2_WITH_PATH_PLACEHOLDER="${BODY_V2_COMPLETE}

The implementation still needs <path> before dispatch."

BODY_V2_WITH_COMMAND_PLACEHOLDER="${BODY_V2_COMPLETE}

<details><summary>Verification still required</summary>Run <command> before dispatch.</details>"

BODY_V2_COLLAPSED_CONTRACT="<details>
<summary>Worker implementation contract</summary>

${BODY_V2_COMPLETE}

</details>"

BODY_V2_DONE_WHEN=$(printf '%s\n' "$BODY_V2_COMPLETE" | sed \
	-e 's/^## Acceptance Criteria$/## Done when/')

# Short concrete paths remain substantive, and Bun is a supported verifier.
# shellcheck disable=SC2016
BODY_V2_SHORT_PATH_BUN=$(printf '%s\n' "$BODY_V2_COMPLETE" | sed \
	-e 's|^- \*\*Callers/readers:\*\*.*$|- **Callers/readers:** `app.py`|' \
	-e 's|^shellcheck src/state.sh.*$|bun test|' \
	-e '/^bash tests\/test-state\.sh$/d')

# Negative language in prose must not replace a negative observable criterion.
BODY_V2_NEGATIVE_PROSE_ONLY=$(printf '%s\n' "$BODY_V2_COMPLETE" | sed \
	's/^- \[ \] A failed migration never replaces a valid existing record or regresses v1 reads\.$/- [ ] Migration failures return an observable error./')
BODY_V2_NEGATIVE_PROSE_ONLY="${BODY_V2_NEGATIVE_PROSE_ONLY}
This prose says the implementation must not regress readers."

# Fenced headings cannot provide the schema-v2 heading score.
BODY_V2_FENCED_SCORE_BYPASS=$(printf '%s\n' "$BODY_V2_COMPLETE" | grep -vE '^## (Task|Why|How)$')
BODY_V2_FENCED_SCORE_BYPASS="${BODY_V2_FENCED_SCORE_BYPASS}

\`\`\`markdown
## Task
## Why
\`\`\`"

# A marker shown only as a fenced example must not upgrade a legacy brief.
BODY_LEGACY_WITH_FENCED_MARKER="${BODY_SCORE_4}

\`\`\`markdown
<!-- aidevops:brief-schema=v2 -->
\`\`\`"

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

echo "=== test-brief-readiness.sh ==="
echo ""

# --- Test 1: Worker-ready body (5 headings, threshold 4) → exit 0 ---
output=$("$HELPER" check --body "$BODY_WORKER_READY" 2>/dev/null)
rc=$?
if [[ $rc -eq 0 ]]; then
	pass "T1: worker-ready body → exit 0"
else
	fail "T1: worker-ready body → exit 0" "got exit $rc, output: $output"
fi

# Verify output contains WORKER_READY=true
if printf '%s\n' "$output" | grep -q 'WORKER_READY=true'; then
	pass "T1b: output contains WORKER_READY=true"
else
	fail "T1b: output contains WORKER_READY=true" "output: $output"
fi

# --- Test 2: Minimal body (2 headings) → exit 1 ---
output=$("$HELPER" check --body "$BODY_MINIMAL" 2>/dev/null)
rc=$?
if [[ $rc -eq 1 ]]; then
	pass "T2: minimal body → exit 1"
else
	fail "T2: minimal body → exit 1" "got exit $rc, output: $output"
fi

if printf '%s\n' "$output" | grep -q 'WORKER_READY=false'; then
	pass "T2b: output contains WORKER_READY=false"
else
	fail "T2b: output contains WORKER_READY=false" "output: $output"
fi

# --- Test 3: Score-3 body (just under threshold) → exit 1 ---
output=$("$HELPER" check --body "$BODY_SCORE_3" 2>/dev/null)
rc=$?
if [[ $rc -eq 1 ]]; then
	pass "T3: score-3 body → exit 1 (under threshold)"
else
	fail "T3: score-3 body → exit 1 (under threshold)" "got exit $rc, output: $output"
fi

# Verify score is 3
score=$(printf '%s\n' "$output" | grep '^SCORE=' | sed 's/SCORE=//')
if [[ "$score" -eq 3 ]]; then
	pass "T3b: score is 3"
else
	fail "T3b: score is 3" "got score=$score"
fi

# --- Test 4: Score-4 body (exactly at threshold) → exit 0 ---
output=$("$HELPER" check --body "$BODY_SCORE_4" 2>/dev/null)
rc=$?
if [[ $rc -eq 0 ]]; then
	pass "T4: score-4 body → exit 0 (at threshold)"
else
	fail "T4: score-4 body → exit 0 (at threshold)" "got exit $rc, output: $output"
fi

# --- Test 5: All headings (score 7) → exit 0 ---
output=$("$HELPER" check --body "$BODY_ALL_HEADINGS" 2>/dev/null)
rc=$?
score=$(printf '%s\n' "$output" | grep '^SCORE=' | sed 's/SCORE=//')
if [[ $rc -eq 0 && "$score" -eq 7 ]]; then
	pass "T5: all-headings body → exit 0 with score 7"
else
	fail "T5: all-headings body → exit 0 with score 7" "got exit=$rc score=$score"
fi

# --- Test 6: Threshold override via env var ---
# BODY_WORKER_READY scores 6 (5 explicit ## headings + ### Files to modify
# which contains "## Files to modify" as a substring). threshold=7 → fail.
output=$(BRIEF_READINESS_THRESHOLD=7 "$HELPER" check --body "$BODY_WORKER_READY" 2>/dev/null)
rc=$?
if [[ $rc -eq 1 ]]; then
	pass "T6: threshold=7, score-6 body → exit 1"
else
	fail "T6: threshold=7, score-6 body → exit 1" "got exit $rc"
fi

# BODY_SCORE_3 scores 3 (## What, ## Why, ## Acceptance). threshold=3 → pass.
output=$(BRIEF_READINESS_THRESHOLD=3 "$HELPER" check --body "$BODY_SCORE_3" 2>/dev/null)
rc=$?
if [[ $rc -eq 0 ]]; then
	pass "T6b: threshold=3, score-3 body → exit 0"
else
	fail "T6b: threshold=3, score-3 body → exit 0" "got exit $rc"
fi

# --- Test 7: Stub brief creation ---
TMP_REPO=$(mktemp -d)
mkdir -p "$TMP_REPO/todo/tasks"

# Stub gh command for offline testing
GH_STUB_DIR=$(mktemp -d)
cat >"$GH_STUB_DIR/gh" <<'GHSTUB'
#!/usr/bin/env bash
# Stub gh for test-brief-readiness.sh
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
	if [[ "${*}" == *"--jq '.title'"* ]] || [[ "${*}" == *"--jq .title"* ]]; then
		echo "Test Issue Title"
	elif [[ "${*}" == *"--jq '.body'"* ]] || [[ "${*}" == *"--jq .body"* ]]; then
		echo "Test body"
	else
		printf '%s\n' '{"body":"Test body","title":"Test Issue Title","url":"https://github.com/owner/repo/issues/12345","updatedAt":"2026-09-06T00:00:00Z","id":"I_fixture"}'
	fi
fi
exit 0
GHSTUB
chmod +x "$GH_STUB_DIR/gh"

# Run stub creation with stubbed gh
PATH="$GH_STUB_DIR:$PATH" "$HELPER" stub "t9999" "12345" "owner/repo" "$TMP_REPO" 2>/dev/null
stub_rc=$?
brief_file="$TMP_REPO/todo/tasks/t9999-brief.md"

if [[ $stub_rc -eq 0 && -f "$brief_file" ]]; then
	pass "T7: stub brief created successfully"
else
	fail "T7: stub brief created successfully" "exit=$stub_rc, exists=$(test -f "$brief_file" && echo yes || echo no)"
fi

# Check legacy stub invocation now retains body and provenance
if grep -q "Test body" "$brief_file" && grep -q 'aidevops:forge-capture-v1' "$brief_file"; then
	pass "T7b: capture contains full body and provenance"
else
	fail "T7b: capture contains full body and provenance"
fi

# Capture coverage must not imply a full event export or executable authority.
if grep -q '"coverage": "issue-body-only"' "$brief_file" && grep -q '"authority": "revalidate"' "$brief_file"; then
	pass "T7c: capture declares its coverage and authority limits"
else
	fail "T7c: capture declares its coverage and authority limits"
fi

# --- Test 8: Stub skips if brief already exists ---
echo "# Existing brief" >"$brief_file"
PATH="$GH_STUB_DIR:$PATH" "$HELPER" stub "t9999" "12345" "owner/repo" "$TMP_REPO" 2>/dev/null
existing_content=$(cat "$brief_file")
if [[ "$existing_content" == "# Existing brief" ]]; then
	pass "T8: stub skips when brief already exists"
else
	fail "T8: stub skips when brief already exists" "content was overwritten"
fi

# --- Test 9: Similarity scoring ---
# Create a brief that mostly duplicates the worker-ready body
sim_brief_file=$(mktemp)
printf '%s\n' "$BODY_WORKER_READY" >"$sim_brief_file"

output=$("$HELPER" similarity "$sim_brief_file" --body "$BODY_WORKER_READY" 2>/dev/null)
sim_rc=$?
similarity=$(printf '%s\n' "$output" | grep '^SIMILARITY=' | sed 's/SIMILARITY=//')

# Note: similarity is computed on lines >= 10 chars after normalisation,
# so short heading lines are excluded — identical content may not reach 100%.
if [[ $sim_rc -eq 0 && "$similarity" -ge 50 ]]; then
	pass "T9: identical content → similarity ≥50% ($similarity%)"
else
	fail "T9: identical content → similarity ≥50%" "got sim=$similarity%, exit=$sim_rc"
fi

# Low similarity: brief with different content
echo "Completely different content that shares nothing with the issue body whatsoever" >"$sim_brief_file"
output=$("$HELPER" similarity "$sim_brief_file" --body "$BODY_WORKER_READY" 2>/dev/null)
similarity=$(printf '%s\n' "$output" | grep '^SIMILARITY=' | sed 's/SIMILARITY=//')

if [[ "$similarity" -le 20 ]]; then
	pass "T9b: different content → similarity ≤20% ($similarity%)"
else
	fail "T9b: different content → similarity ≤20%" "got $similarity%"
fi

# --- Test 10: Usage error (no args to check) ---
"$HELPER" check 2>/dev/null
rc=$?
if [[ $rc -eq 2 ]]; then
	pass "T10: check with no args → exit 2 (usage error)"
else
	fail "T10: check with no args → exit 2 (usage error)" "got exit $rc"
fi

# --- Test 11: Case-insensitive heading matching ---
BODY_LOWERCASE="# task

## task

Info here.

## why

Reasons.

## how

Steps.

## acceptance

Criteria.
"
output=$("$HELPER" check --body "$BODY_LOWERCASE" 2>/dev/null)
rc=$?
if [[ $rc -eq 0 ]]; then
	pass "T11: case-insensitive heading matching → exit 0"
else
	fail "T11: case-insensitive heading matching → exit 0" "got exit $rc, output: $output"
fi

# --- Test 12: schema-v2 complete concurrency/migration/compatibility brief passes ---
output=$("$HELPER" check --body "$BODY_V2_COMPLETE" 2>/dev/null)
rc=$?
if [[ $rc -eq 0 && "$output" == *"SCHEMA=v2"* && "$output" == *"VALIDATION_ERRORS=none"* ]]; then
	pass "T12: substantive schema-v2 brief passes"
else
	fail "T12: substantive schema-v2 brief passes" "got exit $rc, output: $output"
fi

# --- Test 13: headings-only schema-v2 brief fails ---
output=$("$HELPER" check --body "$BODY_V2_HEADINGS_ONLY" 2>/dev/null)
rc=$?
if [[ $rc -eq 1 && "$output" == *"WORKER_READY=false"* && "$output" == *"VALIDATION_ERRORS="* ]]; then
	pass "T13: headings-only schema-v2 brief is rejected"
else
	fail "T13: headings-only schema-v2 brief is rejected" "got exit $rc, output: $output"
fi

# --- Test 14: evidence-backed documentation-only N/A values pass ---
output=$("$HELPER" check --body "$BODY_V2_DOC_ONLY" 2>/dev/null)
rc=$?
if [[ $rc -eq 0 ]]; then
	pass "T14: documentation-only schema-v2 brief passes"
else
	fail "T14: documentation-only schema-v2 brief passes" "got exit $rc, output: $output"
fi

# --- Test 15: evidence-backed new-file-only N/A values pass ---
if "$HELPER" check --body "$BODY_V2_NEW_FILE_ONLY" >/dev/null 2>&1; then
	pass "T15: new-file-only schema-v2 brief passes"
else
	fail "T15: new-file-only schema-v2 brief passes" "readiness check failed"
fi

# --- Test 16: historical unmarked briefs remain legacy-compatible ---
output=$("$HELPER" check --body "$BODY_SCORE_4" 2>/dev/null)
if [[ "$output" == *"WORKER_READY=true"* && "$output" == *"SCHEMA=legacy"* ]]; then
	pass "T16: historical unmarked brief keeps legacy readiness"
else
	fail "T16: historical unmarked brief keeps legacy readiness" "output: $output"
fi

# --- Test 17: schema-v2 requires a concrete file target ---
output=$("$HELPER" check --body "$BODY_V2_NO_FILES" 2>/dev/null)
if [[ "$output" == *"files-to-modify:target"* ]]; then
	pass "T17: schema-v2 brief without a file target is rejected"
else
	fail "T17: missing file target rejection" "output: $output"
fi

# --- Test 18: schema-v2 requires a substantive implementation step ---
output=$("$HELPER" check --body "$BODY_V2_NO_STEPS" 2>/dev/null)
if [[ "$output" == *"implementation-steps:substantive"* ]]; then
	pass "T18: schema-v2 brief without implementation steps is rejected"
else
	fail "T18: missing implementation step rejection" "output: $output"
fi

# --- Test 19: prose mentioning a tool is not an executable command ---
output=$("$HELPER" check --body "$BODY_V2_VERIFICATION_PROSE_ONLY" 2>/dev/null)
if [[ "$output" == *"verification:command"* ]]; then
	pass "T19: verification prose without a command is rejected"
else
	fail "T19: executable verification rejection" "output: $output"
fi

# --- Test 20: required headings inside a fenced example do not satisfy readiness ---
output=$("$HELPER" check --body "$BODY_V2_FENCED_SECTIONS" 2>/dev/null)
if [[ "$output" == *"WORKER_READY=false"* && "$output" == *"write-surface:"* ]]; then
	pass "T20: fenced example sections do not satisfy schema-v2 readiness"
else
	fail "T20: fenced heading rejection" "output: $output"
fi

# --- Test 21: legitimate shell, generic, and object syntax in code is accepted ---
if "$HELPER" check --body "$BODY_V2_WITH_CODE_SYNTAX" >/dev/null 2>&1; then
	pass "T21: placeholder-like syntax inside code remains valid"
else
	fail "T21: code syntax false-positive guard" "readiness check failed"
fi

# --- Test 22: fenced examples cannot populate genuine readiness sections ---
output=$("$HELPER" check --body "$BODY_V2_FENCED_CONTENT" 2>/dev/null)
if [[ "$output" == *"files-to-modify:target"* && "$output" == *"write-surface:"* && "$output" == *"acceptance:multiple-observable-criteria"* ]]; then
	pass "T22: fenced content cannot satisfy genuine schema-v2 sections"
else
	fail "T22: fenced content bypass rejection" "output: $output"
fi

# --- Test 23: mixed and shorter fence delimiters remain inside their opener ---
output=$("$HELPER" check --body "$BODY_V2_MIXED_FENCES" 2>/dev/null)
if [[ "$output" == *"files-to-modify:target"* && "$output" != *"placeholder:unfilled"* ]]; then
	pass "T23: four-character fences ignore shorter and mixed delimiters"
else
	fail "T23: Markdown fence delimiter tracking" "output: $output"
fi

# --- Test 24: suffixed lookalike headings do not satisfy canonical sections ---
output=$("$HELPER" check --body "$BODY_V2_LOOKALIKE_HEADINGS" 2>/dev/null)
if [[ "$output" == *"files-to-modify:target"* && "$output" == *"implementation-steps:substantive"* && "$output" == *"acceptance:multiple-observable-criteria"* ]]; then
	pass "T24: lookalike heading prefixes are rejected"
else
	fail "T24: exact schema-v2 heading matching" "output: $output"
fi

# --- Test 25: short concrete paths and Bun verification remain valid ---
if "$HELPER" check --body "$BODY_V2_SHORT_PATH_BUN" >/dev/null 2>&1; then
	pass "T25: short paths and Bun verification are accepted"
else
	fail "T25: short path or Bun verifier compatibility" "readiness check failed"
fi

# --- Test 26: negative evidence must be an observable checkbox criterion ---
output=$("$HELPER" check --body "$BODY_V2_NEGATIVE_PROSE_ONLY" 2>/dev/null)
if [[ "$output" == *"acceptance:negative-regression"* ]]; then
	pass "T26: negative prose cannot replace a negative acceptance criterion"
else
	fail "T26: negative acceptance criterion enforcement" "output: $output"
fi

# --- Test 27: fenced headings cannot provide the schema-v2 heading score ---
output=$("$HELPER" check --body "$BODY_V2_FENCED_SCORE_BYPASS" 2>/dev/null)
if [[ "$output" == *"WORKER_READY=false"* && "$output" == *"SCHEMA=v2"* ]]; then
	pass "T27: fenced headings do not increase the schema-v2 score"
else
	fail "T27: fence-aware schema-v2 scoring" "output: $output"
fi

# --- Test 28: a fenced schema marker does not upgrade a legacy brief ---
output=$("$HELPER" check --body "$BODY_LEGACY_WITH_FENCED_MARKER" 2>/dev/null)
if [[ "$output" == *"WORKER_READY=true"* && "$output" == *"SCHEMA=legacy"* ]]; then
	pass "T28: fenced schema marker remains a legacy example"
else
	fail "T28: fence-aware schema marker detection" "output: $output"
fi

# --- Test 29: generated HTML wrappers, attributes, and nesting are accepted ---
output=$("$HELPER" check --body "$BODY_V2_WITH_GENERATED_HTML" 2>/dev/null)
rc=$?
if [[ $rc -eq 0 && "$output" == *"WORKER_READY=true"* && "$output" == *"VALIDATION_ERRORS=none"* ]]; then
	pass "T29: generated HTML wrappers are normalized without losing inner text"
else
	fail "T29: generated HTML wrapper normalization" "got exit $rc, output: $output"
fi

# --- Test 30: unknown path placeholders remain rejectable prose ---
output=$("$HELPER" check --body "$BODY_V2_WITH_PATH_PLACEHOLDER" 2>/dev/null)
if [[ "$output" == *"WORKER_READY=false"* && "$output" == *"placeholder:unfilled"* ]]; then
	pass "T30: unknown <path> placeholder remains rejected"
else
	fail "T30: unknown path placeholder rejection" "output: $output"
fi

# --- Test 31: generated wrappers preserve unknown placeholders in inner prose ---
output=$("$HELPER" check --body "$BODY_V2_WITH_COMMAND_PLACEHOLDER" 2>/dev/null)
if [[ "$output" == *"WORKER_READY=false"* && "$output" == *"placeholder:unfilled"* ]]; then
	pass "T31: generated wrappers preserve and reject inner <command> placeholders"
else
	fail "T31: generated wrapper inner-text preservation" "output: $output"
fi

# --- Test 32: a complete schema-v2 contract remains ready inside details ---
output=$("$HELPER" check --body "$BODY_V2_COLLAPSED_CONTRACT")
rc=$?
if [[ $rc -eq 0 && "$output" == *"WORKER_READY=true"* && "$output" == *"VALIDATION_ERRORS=none"* ]]; then
	pass "T32: collapsed worker contract remains schema-v2 ready"
else
	fail "T32: collapsed worker contract readiness" "got exit $rc, output: $output"
fi

# --- Test 33: reader-facing Done when is accepted as the criteria contract ---
output=$("$HELPER" check --body "$BODY_V2_DONE_WHEN")
rc=$?
if [[ $rc -eq 0 && "$output" == *"WORKER_READY=true"* && "$output" == *"VALIDATION_ERRORS=none"* ]]; then
	pass "T33: Done when remains schema-v2 ready"
else
	fail "T33: Done when readiness alias" "got exit $rc, output: $output"
fi

# Producer/consumer scope contract (GH#31390).
if ! "$HELPER" check --body "$BODY_V2_LEGACY" >/dev/null 2>&1 &&
	"$HELPER" scope-check "$BODY_V2_COMPLETE" &&
	[[ "$("$HELPER" scope-normalize "$BODY_V2_COMPLETE")" == "$BODY_V2_COMPLETE" ]]; then
	pass "scope: legacy requires preparation; prepared canonical contract is idempotent"
else
	fail "scope: readiness and idempotency"
fi

# shellcheck disable=SC2016
scope_legacy='### Files to Modify
- `EDIT: src/one.sh`, `NEW: src/two.sh` — bounded changes
- READ: src/readonly.sh
- Inspect `src/reference.sh` before editing.
```markdown
- EDIT: src/fenced.sh
```
<!-- - EDIT: src/comment.sh -->
### Exclusions
- EDIT: src/excluded.sh
## Callers
- EDIT: src/caller.sh'
scope_prepared=$("$HELPER" scope-normalize "$scope_legacy")
# shellcheck disable=SC2016
scope_expected=$'## Files Scope\n\n- `src/one.sh`\n- `src/two.sh`'
if [[ "$scope_prepared" == *"$scope_expected" ]] &&
	[[ "$scope_prepared" == "$scope_legacy"* ]]; then
	pass "scope: only explicit declarations survive, explanations retained"
else
	fail "scope: declaration extraction"
fi

# shellcheck disable=SC2016 # Literal declaration syntax under test.
for declaration in 'EDIT:' 'EDIT: src/*.sh' 'EDIT: ../escape.sh' 'EDIT: /absolute.sh' \
	'EDIT: src/a.sh src/b.sh' 'EDIT: `src/a.sh`/extra' 'EDIT: src/a.sh — read-only' \
	'EDIT: src/a.sh — leave unchanged; reference context only' \
	'EDIT: src/a.sh — must remain untouched' \
	'EDIT: src/a.sh — preserve this file unchanged' \
	'EDIT: src/a.sh — keep unchanged' 'EDIT: src/a.sh — do not touch' \
	'EDIT: src/a.sh, NEW:' 'EDIT: {path}' 'READ: src/a.sh'; do
	if "$HELPER" scope-normalize $'### Files to Modify\n- '"$declaration" >/dev/null 2>&1; then
		fail "scope: rejects ambiguous declaration $declaration"
	else
		pass "scope: rejects ambiguous declaration $declaration"
	fi
done
for heading in '## files scope' '# Files Scope' '## Files Scope <!-- note -->'; do
	if "$HELPER" scope-normalize "$scope_legacy"$'\n'"$heading"$'\n- src/existing.sh' >/dev/null 2>&1; then
		fail "scope: malformed existing heading is not replaced: $heading"
	else
		pass "scope: malformed existing heading is not replaced: $heading"
	fi
done
if "$HELPER" scope-normalize $'<!-- aidevops-signed-approval -->\n'"$scope_legacy" >/dev/null 2>&1; then
	fail "scope: signed content cannot gain permissions"
else
	pass "scope: signed content cannot gain permissions"
fi

# Exercise the unchanged pre-push consumer against an actual prepared local
# brief in a disposable linked worktree. No live root or GitHub writes.
test_scope_local_roundtrip() (
	local fixture="" base="" work="" before="" head="" denied=""
	local hook="$SCRIPT_DIR/../../hooks/scope-guard-pre-push.sh"
	fixture=$(mktemp -d) || return 1
	fixture=$(cd "$fixture" && pwd -P) || return 1
	trap 'rm -rf "$fixture"' EXIT
	mkdir -p "$fixture/base/todo/tasks" "$fixture/base/src" || return 1
	base="$fixture/base"
	work="$fixture/work"
	git -C "$base" init -q || return 1
	printf '%s\n' "$scope_legacy" >"$base/todo/tasks/t9999-brief.md"
	printf 'initial\n' >"$base/src/one.sh"
	git -C "$base" add . || return 1
	git -C "$base" -c user.name=Fixture -c user.email=fixture@example.invalid \
		-c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm initial || return 1
	if "$HELPER" prepare-scope "$base/todo/tasks/t9999-brief.md" >/dev/null 2>&1; then
		return 1
	fi
	git -C "$base" worktree add -qb feature/t9999-scope "$work" || return 1
	"$HELPER" prepare-scope "$work/todo/tasks/t9999-brief.md" || return 1
	before=$(<"$work/todo/tasks/t9999-brief.md")
	[[ "$before" == "$scope_prepared" ]] || return 1
	"$HELPER" prepare-scope "$work/todo/tasks/t9999-brief.md" || return 1
	[[ "$(<"$work/todo/tasks/t9999-brief.md")" == "$before" ]] || return 1
	git -C "$work" add todo/tasks/t9999-brief.md || return 1
	git -C "$work" -c user.name=Fixture -c user.email=fixture@example.invalid \
		-c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm prepared || return 1
	base=$(git -C "$work" rev-parse HEAD)
	printf 'changed\n' >"$work/src/one.sh"
	printf 'new\n' >"$work/src/two.sh"
	git -C "$work" add src/one.sh src/two.sh || return 1
	git -C "$work" -c user.name=Fixture -c user.email=fixture@example.invalid \
		-c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm allowed || return 1
	head=$(git -C "$work" rev-parse HEAD)
	(cd "$work" && printf 'refs/heads/feature/t9999-scope %s refs/heads/feature/t9999-scope %s\n' "$head" "$base" | SCOPE_GUARD_DISABLE=0 bash "$hook") || return 1
	for denied in readonly reference fenced comment excluded caller unrelated; do
		printf 'denied\n' >"$work/src/$denied.sh"
	done
	git -C "$work" add src || return 1
	git -C "$work" -c user.name=Fixture -c user.email=fixture@example.invalid \
		-c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm denied || return 1
	head=$(git -C "$work" rev-parse HEAD)
	if (cd "$work" && printf 'refs/heads/feature/t9999-scope %s refs/heads/feature/t9999-scope %s\n' "$head" "$base" | SCOPE_GUARD_DISABLE=0 bash "$hook") >/dev/null 2>&1; then
		return 1
	fi
	return 0
)
if test_scope_local_roundtrip; then
	pass "scope: local author preparation and unchanged pre-push guard enforce exact paths"
else
	fail "scope: local producer-to-consumer round trip"
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -rf "$TMP_REPO" "$GH_STUB_DIR" "$sim_brief_file" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $TESTS_RUN tests, $TESTS_FAILED failed"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
	exit 1
fi
exit 0
