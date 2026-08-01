#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-check-workflows-helper.sh — fixture tests for check-workflows-helper.sh (t2778)
#
# Issue: GH#20648
#
# Scenarios covered:
#   1. No workflow file → classified NO-WORKFLOW
#   2. Self-caller (uses: ./...) → CURRENT/SELF-CALLER
#   3. Downstream caller @main → CURRENT/CALLER (byte-identical to canonical)
#   4. Downstream caller @v3.9.0 (pinned variant) → CURRENT/CALLER
#   5. Downstream caller with extra triggers → DRIFTED/CALLER
#   6. Legacy full-copy with issue-sync-helper.sh invocation → NEEDS-MIGRATION
#   7. Legacy full-copy without helper (inline logic) → NEEDS-MIGRATION
#   8. local_only repo → LOCAL-ONLY (no filesystem check)
#   9. repos.json missing → exit 2 with error
#  10. --repo filter narrows to one row
#  11. --json output parses as JSON
#  16. Current caller plus obsolete framework scripts → legacy-artifact warning
#  17. Legacy-artifact manifest without a trailing newline processes its final row
#  18. Unset HOME exits cleanly instead of raising an unbound-variable error
#  19. Stale local checkout reports local evidence and upstream divergence
#  20. Repository-scoped checks prefer a matching caller-owned linked worktree
#      without relying on Git 2.31's --path-format option
#  13a. Verbose mirror drift shows the rendered and normalised comparison
#
# Strategy: Each scenario writes a temporary repos.json + temporary repo trees
# under a per-test TMPDIR, points HOME at it, and invokes the helper. No
# network calls, no real GitHub API.

set -uo pipefail

# Fixture repositories are disposable. Export a test-local native Git boundary
# so child helper shells cannot inherit the runtime's canonical-repo guard while
# the normal PATH remains available for dependencies such as jq.
git() {
	local _git_bin="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"
	"$_git_bin" "$@"
	return $?
}
export -f git

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../check-workflows-helper.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
CANONICAL_TEMPLATE="$REPO_ROOT/.agents/templates/workflows/issue-sync-caller.yml"

if [[ ! -f "$HELPER" ]]; then
	echo "SKIP: helper not found at $HELPER" >&2
	exit 0
fi
if [[ ! -f "$CANONICAL_TEMPLATE" ]]; then
	echo "SKIP: canonical template not found at $CANONICAL_TEMPLATE" >&2
	exit 0
fi

readonly _T_GREEN='\033[0;32m'
readonly _T_RED='\033[0;31m'
readonly _T_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

_pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '%bPASS%b %s\n' "$_T_GREEN" "$_T_RESET" "$name"
	return 0
}

_fail() {
	local name="$1"
	local msg="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '%bFAIL%b %s\n' "$_T_RED" "$_T_RESET" "$name"
	[[ -n "$msg" ]] && printf '       %s\n' "$msg"
	return 0
}

# ─── Fixture helpers ────────────────────────────────────────────────────────

_setup_fake_home() {
	local _root="$1"
	# Directory layout mirrors the real aidevops install so the helper's
	# `_resolve_canonical_template` picks up the deployed copy.
	mkdir -p "$_root/.config/aidevops"
	mkdir -p "$_root/.aidevops/agents/templates/workflows"
	cp "$CANONICAL_TEMPLATE" "$_root/.aidevops/agents/templates/workflows/issue-sync-caller.yml"
	return 0
}

_write_repos_json() {
	local _root="$1"
	local _json="$2"
	printf '%s\n' "$_json" >"$_root/.config/aidevops/repos.json"
	return 0
}

_make_repo_with_workflow() {
	local _path="$1"
	local _content="${2:-}"
	mkdir -p "$_path/.github/workflows"
	if [[ -n "$_content" ]]; then
		printf '%s' "$_content" >"$_path/.github/workflows/issue-sync.yml"
	fi
	return 0
}

# ─── Scenario runner ────────────────────────────────────────────────────────

# _run_and_classify <fake-home-root> [extra-args...]
# Emits the classification for the only (or --repo-filtered) row on stdout.
_run_and_classify() {
	local _root="$1"
	shift
	HOME="$_root" bash "$HELPER" --json "$@" 2>/dev/null |
		jq -r 'select(.slug != "") | .classification' |
		head -n 1
	return 0
}

# ─── Tests ──────────────────────────────────────────────────────────────────

# Test 1: No workflow file
TMPDIR_1="$(mktemp -d)"
_setup_fake_home "$TMPDIR_1"
mkdir -p "$TMPDIR_1/repos/test-repo"
_write_repos_json "$TMPDIR_1" \
	"$(jq -n --arg path "$TMPDIR_1/repos/test-repo" '{initialized_repos: [{slug: "x/no-wf", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_1")
if [[ "$result" == "NO-WORKFLOW" ]]; then
	_pass "missing workflow file → NO-WORKFLOW"
else
	_fail "missing workflow file → NO-WORKFLOW" "got: $result"
fi
rm -rf "$TMPDIR_1"

# Test 2: Self-caller
TMPDIR_2="$(mktemp -d)"
_setup_fake_home "$TMPDIR_2"
SELF_CALLER_YAML='name: Issue Sync

on: { push: { branches: [main] } }

jobs:
  sync:
    uses: ./.github/workflows/issue-sync-reusable.yml
    secrets: inherit
'
_make_repo_with_workflow "$TMPDIR_2/repos/aidevops-self" "$SELF_CALLER_YAML"
_write_repos_json "$TMPDIR_2" \
	"$(jq -n --arg path "$TMPDIR_2/repos/aidevops-self" '{initialized_repos: [{slug: "x/self", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_2")
if [[ "$result" == "CURRENT/SELF-CALLER" ]]; then
	_pass "self-caller (./...) → CURRENT/SELF-CALLER"
else
	_fail "self-caller (./...) → CURRENT/SELF-CALLER" "got: $result"
fi
rm -rf "$TMPDIR_2"

# Test 3: Downstream caller byte-identical to canonical
TMPDIR_3="$(mktemp -d)"
_setup_fake_home "$TMPDIR_3"
_make_repo_with_workflow "$TMPDIR_3/repos/downstream-current"
cp "$CANONICAL_TEMPLATE" "$TMPDIR_3/repos/downstream-current/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_3" \
	"$(jq -n --arg path "$TMPDIR_3/repos/downstream-current" '{initialized_repos: [{slug: "x/current", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_3")
if [[ "$result" == "CURRENT/CALLER" ]]; then
	_pass "byte-identical downstream caller → CURRENT/CALLER"
else
	_fail "byte-identical downstream caller → CURRENT/CALLER" "got: $result"
fi
rm -rf "$TMPDIR_3"

# Test 4: Downstream caller with version-pinned ref
TMPDIR_4="$(mktemp -d)"
_setup_fake_home "$TMPDIR_4"
_make_repo_with_workflow "$TMPDIR_4/repos/downstream-pinned"
sed -e 's|issue-sync-reusable\.yml@main|issue-sync-reusable.yml@v3.9.0|g' \
	-e 's|aidevops_ref: main|aidevops_ref: v3.9.0|g' \
	"$CANONICAL_TEMPLATE" >"$TMPDIR_4/repos/downstream-pinned/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_4" \
	"$(jq -n --arg path "$TMPDIR_4/repos/downstream-pinned" '{initialized_repos: [{slug: "x/pinned", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_4")
if [[ "$result" == "CURRENT/CALLER" ]]; then
	_pass "pinned @v3.9.0 caller → CURRENT/CALLER (normalised @ref)"
else
	_fail "pinned @v3.9.0 caller → CURRENT/CALLER (normalised @ref)" "got: $result"
fi
rm -rf "$TMPDIR_4"

# Test 4b: A pinned reusable YAML with a mutable helper ref is drift.
TMPDIR_4B="$(mktemp -d)"
_setup_fake_home "$TMPDIR_4B"
_make_repo_with_workflow "$TMPDIR_4B/repos/downstream-split-pin"
sed 's|issue-sync-reusable\.yml@main|issue-sync-reusable.yml@v3.9.0|g' \
	"$CANONICAL_TEMPLATE" >"$TMPDIR_4B/repos/downstream-split-pin/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_4B" \
	"$(jq -n --arg path "$TMPDIR_4B/repos/downstream-split-pin" '{initialized_repos: [{slug: "x/split-pin", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_4B")
verbose_result=$(HOME="$TMPDIR_4B" bash "$HELPER" \
	--repo "x/split-pin" --workflow issue-sync --verbose 2>/dev/null)
if [[ "$result" == "DRIFTED/CALLER" ]] &&
	[[ "$verbose_result" == *"helper provenance mismatch"* ]]; then
	_pass "pinned reusable with helper on main → actionable DRIFTED/CALLER diagnostics"
else
	_fail "pinned reusable with helper on main → actionable DRIFTED/CALLER diagnostics" \
		"classification: $result; output: $verbose_result"
fi
rm -rf "$TMPDIR_4B"

# Test 4c: Valid punctuation in a coherently coupled ref remains current.
TMPDIR_4C="$(mktemp -d)"
_setup_fake_home "$TMPDIR_4C"
_make_repo_with_workflow "$TMPDIR_4C/repos/downstream-punctuation-ref"
sed -e 's|issue-sync-reusable\.yml@main|issue-sync-reusable.yml@release#candidate|g' \
	-e 's|aidevops_ref: main|aidevops_ref: release#candidate|g' \
	"$CANONICAL_TEMPLATE" >"$TMPDIR_4C/repos/downstream-punctuation-ref/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_4C" \
	"$(jq -n --arg path "$TMPDIR_4C/repos/downstream-punctuation-ref" '{initialized_repos: [{slug: "x/punctuation-ref", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_4C")
if [[ "$result" == "CURRENT/CALLER" ]]; then
	_pass "coupled release#candidate ref → CURRENT/CALLER"
else
	_fail "coupled release#candidate ref → CURRENT/CALLER" "got: $result"
fi
rm -rf "$TMPDIR_4C"

# Test 5: Caller with extra triggers → DRIFTED/CALLER
TMPDIR_5="$(mktemp -d)"
_setup_fake_home "$TMPDIR_5"
_make_repo_with_workflow "$TMPDIR_5/repos/downstream-drifted"
# Take canonical and append a new trigger path
{
	cat "$CANONICAL_TEMPLATE"
	printf '\n# Local customisation — should trigger DRIFTED detection\n'
	printf '# (any content change after normalising @ref counts as drift)\n'
} >"$TMPDIR_5/repos/downstream-drifted/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_5" \
	"$(jq -n --arg path "$TMPDIR_5/repos/downstream-drifted" '{initialized_repos: [{slug: "x/drifted", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_5")
if [[ "$result" == "DRIFTED/CALLER" ]]; then
	_pass "caller with local modifications → DRIFTED/CALLER"
else
	_fail "caller with local modifications → DRIFTED/CALLER" "got: $result"
fi
rm -rf "$TMPDIR_5"

# Test 6: Legacy full-copy with issue-sync-helper.sh reference → NEEDS-MIGRATION
TMPDIR_6="$(mktemp -d)"
_setup_fake_home "$TMPDIR_6"
FULL_COPY_WITH_HELPER='name: Issue Sync

on: { push: { branches: [main] } }

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bash .agents/scripts/issue-sync-helper.sh push
'
_make_repo_with_workflow "$TMPDIR_6/repos/legacy-full-copy" "$FULL_COPY_WITH_HELPER"
_write_repos_json "$TMPDIR_6" \
	"$(jq -n --arg path "$TMPDIR_6/repos/legacy-full-copy" '{initialized_repos: [{slug: "x/legacy", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_6")
if [[ "$result" == "NEEDS-MIGRATION" ]]; then
	_pass "legacy full-copy with helper ref → NEEDS-MIGRATION"
else
	_fail "legacy full-copy with helper ref → NEEDS-MIGRATION" "got: $result"
fi
rm -rf "$TMPDIR_6"

# Test 7: Legacy full-copy with inline parsing (no helper) → NEEDS-MIGRATION
TMPDIR_7="$(mktemp -d)"
_setup_fake_home "$TMPDIR_7"
# shellcheck disable=SC2016  # literal YAML content — no expansion wanted
FULL_COPY_INLINE='name: Issue Sync

on: { push: { branches: [main] } }

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          # Parse TODO.md for ref:GH# markers and create issues inline
          while IFS= read -r line; do
            echo "$line" | grep -oE "t[0-9]+"
          done < TODO.md
'
_make_repo_with_workflow "$TMPDIR_7/repos/legacy-inline" "$FULL_COPY_INLINE"
_write_repos_json "$TMPDIR_7" \
	"$(jq -n --arg path "$TMPDIR_7/repos/legacy-inline" '{initialized_repos: [{slug: "x/inline", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_7")
if [[ "$result" == "NEEDS-MIGRATION" ]]; then
	_pass "legacy inline-logic full-copy → NEEDS-MIGRATION"
else
	_fail "legacy inline-logic full-copy → NEEDS-MIGRATION" "got: $result"
fi
rm -rf "$TMPDIR_7"

# Test 8: local_only repo → LOCAL-ONLY (no filesystem check needed)
TMPDIR_8="$(mktemp -d)"
_setup_fake_home "$TMPDIR_8"
_write_repos_json "$TMPDIR_8" \
	"$(jq -n --arg path "$TMPDIR_8/repos/local-only-repo" '{initialized_repos: [{slug: "", path: $path, local_only: true}]}')"
result=$(_run_and_classify "$TMPDIR_8")
if [[ "$result" == "LOCAL-ONLY" ]]; then
	_pass "local_only: true → LOCAL-ONLY (no fs check)"
else
	_fail "local_only: true → LOCAL-ONLY (no fs check)" "got: $result"
fi
rm -rf "$TMPDIR_8"

# Test 9: repos.json missing → exit 2
TMPDIR_9="$(mktemp -d)"
mkdir -p "$TMPDIR_9/.config/aidevops"
mkdir -p "$TMPDIR_9/.aidevops/agents/templates/workflows"
cp "$CANONICAL_TEMPLATE" "$TMPDIR_9/.aidevops/agents/templates/workflows/issue-sync-caller.yml"
# Deliberately omit repos.json
HOME="$TMPDIR_9" bash "$HELPER" >/dev/null 2>&1
exit_code=$?
if [[ "$exit_code" -eq 2 ]]; then
	_pass "missing repos.json → exit 2"
else
	_fail "missing repos.json → exit 2" "got exit code: $exit_code"
fi
rm -rf "$TMPDIR_9"

# Test 10: --repo + --workflow filters narrow to exactly one row
# Note: --repo alone returns one row per known workflow type (N rows for N
# managed workflows). Adding --workflow narrows to a single (repo×workflow)
# row — this tests both filter flags working in concert.
TMPDIR_10="$(mktemp -d)"
_setup_fake_home "$TMPDIR_10"
_make_repo_with_workflow "$TMPDIR_10/repos/a"
cp "$CANONICAL_TEMPLATE" "$TMPDIR_10/repos/a/.github/workflows/issue-sync.yml"
_make_repo_with_workflow "$TMPDIR_10/repos/b"
cp "$CANONICAL_TEMPLATE" "$TMPDIR_10/repos/b/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_10" \
	"$(jq -n \
		--arg pa "$TMPDIR_10/repos/a" \
		--arg pb "$TMPDIR_10/repos/b" \
		'{initialized_repos: [{slug: "x/a", path: $pa, local_only: false}, {slug: "x/b", path: $pb, local_only: false}]}')"
count=$(HOME="$TMPDIR_10" bash "$HELPER" --json --repo "x/a" --workflow "issue-sync" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$count" == "1" ]]; then
	_pass "--repo + --workflow filters narrow to single row"
else
	_fail "--repo + --workflow filters narrow to single row" "expected 1 row, got $count"
fi
rm -rf "$TMPDIR_10"

# Test 11: --json emits parseable JSON per row
TMPDIR_11="$(mktemp -d)"
_setup_fake_home "$TMPDIR_11"
_make_repo_with_workflow "$TMPDIR_11/repos/good"
cp "$CANONICAL_TEMPLATE" "$TMPDIR_11/repos/good/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_11" \
	"$(jq -n --arg path "$TMPDIR_11/repos/good" '{initialized_repos: [{slug: "x/good", path: $path, local_only: false}]}')"
json_row=$(HOME="$TMPDIR_11" bash "$HELPER" --json 2>/dev/null | head -n 1)
if printf '%s' "$json_row" | jq -e '.slug and .path and .classification' >/dev/null 2>&1; then
	_pass "--json emits well-formed JSON per row"
else
	_fail "--json emits well-formed JSON per row" "got: $json_row"
fi
rm -rf "$TMPDIR_11"

# Test 12: downstream caller with branches: [develop] → CURRENT/CALLER
# Verifies the branch-filter normalisation: a repo whose default branch is `develop`
# (installed by sync-workflows with branches: [develop]) is not flagged as DRIFTED.
TMPDIR_12="$(mktemp -d)"
_setup_fake_home "$TMPDIR_12"
_make_repo_with_workflow "$TMPDIR_12/repos/downstream-develop"
# Take canonical and replace `branches: [main]` with `branches: [develop]`.
sed 's/branches: \[main\]/branches: [develop]/' \
	"$CANONICAL_TEMPLATE" >"$TMPDIR_12/repos/downstream-develop/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_12" \
	"$(jq -n --arg path "$TMPDIR_12/repos/downstream-develop" \
		'{initialized_repos: [{slug: "x/develop-repo", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_12")
if [[ "$result" == "CURRENT/CALLER" ]]; then
	_pass "canonical caller with branches: [develop] → CURRENT/CALLER (normalised branch filter)"
else
	_fail "canonical caller with branches: [develop] → CURRENT/CALLER (normalised branch filter)" \
		"got: $result"
fi
rm -rf "$TMPDIR_12"

# Test 13: Configured org-owned reusable repo + pinned SHA + rendered comments → CURRENT/CALLER.
TMPDIR_13="$(mktemp -d)"
_setup_fake_home "$TMPDIR_13"
_make_repo_with_workflow "$TMPDIR_13/repos/org-current"
sed \
	-e 's|marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml@main|ORG/.github/.github/workflows/issue-sync-reusable.yml@1234567890abcdef1234567890abcdef12345678|g' \
	-e 's|marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml|ORG/.github/.github/workflows/issue-sync-reusable.yml|g' \
	-e 's|^      aidevops_ref: main|      aidevops_repository: ORG/.github\
      aidevops_ref: 1234567890abcdef1234567890abcdef12345678|' \
	-e 's|^    secrets:$|    secrets:\
      AIDEVOPS_READ_TOKEN: ${{ secrets.AIDEVOPS_READ_TOKEN }}|' \
	"$CANONICAL_TEMPLATE" >"$TMPDIR_13/repos/org-current/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_13" \
	"$(jq -n --arg path "$TMPDIR_13/repos/org-current" '{workflow_reusable_repo: "ORG/.github", workflow_reusable_ref: "1234567890abcdef1234567890abcdef12345678", initialized_repos: [{slug: "x/org-current", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_13")
if [[ "$result" == "CURRENT/CALLER" ]]; then
	_pass "configured org-owned pinned caller with rendered comments → CURRENT/CALLER"
else
	_fail "configured org-owned pinned caller with rendered comments → CURRENT/CALLER" "got: $result"
fi
rm -rf "$TMPDIR_13"

# Test 13a: Verbose caller diagnostics must display the same rendered and
# normalised comparison that produced DRIFTED/CALLER (GH#29142).
TMPDIR_13A="$(mktemp -d)"
_setup_fake_home "$TMPDIR_13A"
_make_repo_with_workflow "$TMPDIR_13A/repos/org-header-drift"
sed \
	-e 's|^    branches: \[main\]$|    branches: [develop]|' \
	-e 's|^    uses: marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml@main$|    uses: ORG/.github/.github/workflows/issue-sync-reusable.yml@release#candidate|' \
	-e 's|^    secrets:$|    secrets:\
      AIDEVOPS_READ_TOKEN: ${{ secrets.AIDEVOPS_READ_TOKEN }}|' \
	-e 's|^    with:$|    with:\
      runner: ubuntu-latest-arm64|' \
	-e 's|^      aidevops_ref: main$|      aidevops_repository: ORG/.github\
      aidevops_ref: release#candidate|' \
	"$CANONICAL_TEMPLATE" >"$TMPDIR_13A/repos/org-header-drift/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_13A" \
	"$(jq -n --arg path "$TMPDIR_13A/repos/org-header-drift" \
		'{workflow_reusable_repo: "ORG/.github", workflow_reusable_ref: "1234567890abcdef1234567890abcdef12345678", initialized_repos: [{slug: "x/org-header-drift", path: $path, local_only: false}]}')"
verbose_output=$(HOME="$TMPDIR_13A" bash "$HELPER" \
	--repo "x/org-header-drift" --workflow issue-sync --verbose 2>/dev/null)
verbose_rc=$?
if [[ "$verbose_rc" -eq 1 ]] &&
	[[ "$verbose_output" == *"DRIFTED/CALLER"* ]] &&
	[[ "$verbose_output" == *"-# Upstream logic lives in: ORG/.github/.github/workflows/issue-sync-reusable.yml"* ]] &&
	[[ "$verbose_output" == *"+# Upstream logic lives in: marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml"* ]] &&
	! printf '%s\n' "$verbose_output" | grep -Eq '^[+-][[:space:]]+(uses:|branches:|runner:|aidevops_(repository|ref):)'; then
	_pass "GH#29142 verbose drift → rendered header delta without normalised-away noise"
else
	_fail "GH#29142 verbose drift → rendered header delta without normalised-away noise" \
		"rc=$verbose_rc; output: $verbose_output"
fi
rm -rf "$TMPDIR_13A"

# Test 14: Unconfigured third-party reusable repo is not silently trusted.
TMPDIR_14="$(mktemp -d)"
_setup_fake_home "$TMPDIR_14"
_make_repo_with_workflow "$TMPDIR_14/repos/untrusted"
sed 's|marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml@main|OTHER/.github/.github/workflows/issue-sync-reusable.yml@main|g' \
	"$CANONICAL_TEMPLATE" >"$TMPDIR_14/repos/untrusted/.github/workflows/issue-sync.yml"
_write_repos_json "$TMPDIR_14" \
	"$(jq -n --arg path "$TMPDIR_14/repos/untrusted" '{workflow_reusable_repo: "ORG/.github", initialized_repos: [{slug: "x/untrusted", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_14")
if [[ "$result" == "NEEDS-MIGRATION" ]]; then
	_pass "unconfigured third-party caller → NEEDS-MIGRATION"
else
	_fail "unconfigured third-party caller → NEEDS-MIGRATION" "got: $result"
fi
rm -rf "$TMPDIR_14"

# Test 15: Registered org-owned reusable repo still surfaces reusable content drift.
TMPDIR_15="$(mktemp -d)"
_setup_fake_home "$TMPDIR_15"
mkdir -p "$TMPDIR_15/repos/org-dotgithub/.github/workflows"
printf '%s\n' 'name: stale org-owned reusable copy' >"$TMPDIR_15/repos/org-dotgithub/.github/workflows/issue-sync-reusable.yml"
_write_repos_json "$TMPDIR_15" \
	"$(jq -n --arg path "$TMPDIR_15/repos/org-dotgithub" '{workflow_reusable_repo: "ORG/.github", initialized_repos: [{slug: "ORG/.github", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_15" --repo "ORG/.github")
if [[ "$result" == "DRIFTED/REUSABLE" ]]; then
	_pass "org-owned reusable content drift → DRIFTED/REUSABLE"
else
	_fail "org-owned reusable content drift → DRIFTED/REUSABLE" "got: $result"
fi
rm -rf "$TMPDIR_15"

# Test 16: A current reusable caller must still report known superseded scripts.
TMPDIR_16="$(mktemp -d)"
_setup_fake_home "$TMPDIR_16"
_make_repo_with_workflow "$TMPDIR_16/repos/downstream-legacy-artifacts"
cp "$CANONICAL_TEMPLATE" "$TMPDIR_16/repos/downstream-legacy-artifacts/.github/workflows/issue-sync.yml"
mkdir -p "$TMPDIR_16/repos/downstream-legacy-artifacts/.agents/scripts"
printf '%s\n' '# locally modified legacy helper — warning only' > \
	"$TMPDIR_16/repos/downstream-legacy-artifacts/.agents/scripts/issue-sync-helper.sh"
_write_repos_json "$TMPDIR_16" \
	"$(jq -n --arg path "$TMPDIR_16/repos/downstream-legacy-artifacts" '{initialized_repos: [{slug: "x/legacy-artifacts", path: $path, local_only: false}]}')"
json_row=$(HOME="$TMPDIR_16" bash "$HELPER" --json --repo "x/legacy-artifacts" --workflow issue-sync 2>/dev/null)
result=$(printf '%s\n' "$json_row" | jq -r '.classification')
note=$(printf '%s\n' "$json_row" | jq -r '.note')
if [[ "$result" == "CURRENT/CALLER + LEGACY_ARTIFACTS" ]] &&
	[[ "$note" == *".agents/scripts/issue-sync-helper.sh"* ]] &&
	[[ "$note" == *"no files removed"* ]]; then
	_pass "current caller with modified obsolete helper → LEGACY_ARTIFACTS warning"
else
	_fail "current caller with modified obsolete helper → LEGACY_ARTIFACTS warning" \
		"classification: $result; note: $note"
fi
rm -rf "$TMPDIR_16"

# Test 17: The final manifest row must be processed without a trailing newline.
TMPDIR_17="$(mktemp -d)"
_setup_fake_home "$TMPDIR_17"
_make_repo_with_workflow "$TMPDIR_17/repos/no-trailing-newline"
cp "$CANONICAL_TEMPLATE" "$TMPDIR_17/repos/no-trailing-newline/.github/workflows/issue-sync.yml"
mkdir -p "$TMPDIR_17/repos/no-trailing-newline/.agents/scripts"
printf '%s\n' '# legacy helper' >"$TMPDIR_17/repos/no-trailing-newline/.agents/scripts/issue-sync-helper.sh"
mkdir -p "$TMPDIR_17/.aidevops/agents/configs"
printf '%s' $'issue-sync\t.agents/scripts/issue-sync-helper.sh\tissue-sync-reusable.yml\tv3.32.31' > \
	"$TMPDIR_17/.aidevops/agents/configs/workflow-legacy-artifacts.tsv"
_write_repos_json "$TMPDIR_17" \
	"$(jq -n --arg path "$TMPDIR_17/repos/no-trailing-newline" '{initialized_repos: [{slug: "x/no-trailing-newline", path: $path, local_only: false}]}')"
result=$(_run_and_classify "$TMPDIR_17" --repo "x/no-trailing-newline" --workflow issue-sync)
if [[ "$result" == "CURRENT/CALLER + LEGACY_ARTIFACTS" ]]; then
	_pass "manifest final row without trailing newline → LEGACY_ARTIFACTS warning"
else
	_fail "manifest final row without trailing newline → LEGACY_ARTIFACTS warning" "got: $result"
fi
rm -rf "$TMPDIR_17"

# Test 18: HOME is not guaranteed in constrained execution environments.
unset_home_output=$(env -u HOME bash "$HELPER" --json 2>&1 || true)
if [[ "$unset_home_output" == *"repos.json not found"* ]] &&
	[[ "$unset_home_output" != *"unbound variable"* ]]; then
	_pass "unset HOME → clean missing-config error"
else
	_fail "unset HOME → clean missing-config error" "got: $unset_home_output"
fi

# Test 19: A stale registered checkout must disclose that its classification is
# local evidence and that the branch is behind its known upstream ref.
TMPDIR_19="$(mktemp -d)"
_setup_fake_home "$TMPDIR_19"
BARE_19="$TMPDIR_19/remote.git"
REPO_19="$TMPDIR_19/repos/stale-local"
git init --bare -q "$BARE_19"
mkdir -p "$REPO_19/.github/workflows"
git -C "$REPO_19" init -q
git -C "$REPO_19" config user.email test@example.com
git -C "$REPO_19" config user.name Test
git -C "$REPO_19" config commit.gpgsign false
git -C "$REPO_19" checkout -q -b main
{
	cat "$CANONICAL_TEMPLATE"
	printf '\n# stale local drift\n'
} >"$REPO_19/.github/workflows/issue-sync.yml"
git -C "$REPO_19" add -A
git -C "$REPO_19" commit -q -m "stale workflow"
STALE_SHA_19=$(git -C "$REPO_19" rev-parse HEAD)
git -C "$REPO_19" remote add origin "$BARE_19"
git -C "$REPO_19" push -q -u origin main
git --git-dir="$BARE_19" symbolic-ref HEAD refs/heads/main
cp "$CANONICAL_TEMPLATE" "$REPO_19/.github/workflows/issue-sync.yml"
git -C "$REPO_19" add -A
git -C "$REPO_19" commit -q -m "canonical remote workflow"
git -C "$REPO_19" push -q origin main
git -C "$REPO_19" reset -q --hard "$STALE_SHA_19"
_write_repos_json "$TMPDIR_19" \
	"$(jq -n --arg path "$REPO_19" '{initialized_repos: [{slug: "x/stale-local", path: $path, local_only: false}]}')"
json_row=$(HOME="$TMPDIR_19" bash "$HELPER" --json --repo x/stale-local --workflow issue-sync 2>/dev/null || true)
human_row=$(HOME="$TMPDIR_19" bash "$HELPER" --repo x/stale-local --workflow issue-sync 2>/dev/null || true)
if [[ "$(printf '%s\n' "$json_row" | jq -r '.classification')" == "DRIFTED/CALLER" ]] &&
	[[ "$(printf '%s\n' "$json_row" | jq -r '.evidence.source')" == "local" ]] &&
	[[ "$(printf '%s\n' "$json_row" | jq -r '.evidence.behind')" == "1" ]] &&
	[[ "$human_row" == *"local evidence; main is 1 commit(s) behind origin/main"* ]]; then
	_pass "stale checkout → local evidence with upstream-behind warning"
else
	_fail "stale checkout → local evidence with upstream-behind warning" \
		"json: $json_row; human: $human_row"
fi
rm -rf "$TMPDIR_19"

# Test 20: A repository-scoped check launched from a matching linked worktree
# must classify that worktree rather than the registered canonical checkout.
TMPDIR_20="$(mktemp -d)"
_setup_fake_home "$TMPDIR_20"
REAL_GIT_20="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"
BARE_20="$TMPDIR_20/remote.git"
REPO_20="$TMPDIR_20/repos/canonical"
LINKED_20="$TMPDIR_20/worktrees/caller-owned"
git init --bare -q "$BARE_20"
mkdir -p "$REPO_20/.github/workflows" "$(dirname "$LINKED_20")"
git -C "$REPO_20" init -q
git -C "$REPO_20" config user.email test@example.com
git -C "$REPO_20" config user.name Test
git -C "$REPO_20" config commit.gpgsign false
git -C "$REPO_20" checkout -q -b main
cp "$CANONICAL_TEMPLATE" "$REPO_20/.github/workflows/issue-sync.yml"
git -C "$REPO_20" add -A
git -C "$REPO_20" commit -q -m "canonical workflow"
git -C "$REPO_20" remote add origin "$BARE_20"
git -C "$REPO_20" push -q -u origin main
git --git-dir="$BARE_20" symbolic-ref HEAD refs/heads/main
git -C "$REPO_20" worktree add -q -b caller-owned "$LINKED_20" main
printf '\n# caller-owned worktree drift\n' >>"$LINKED_20/.github/workflows/issue-sync.yml"
git -C "$LINKED_20" add -A
git -C "$LINKED_20" commit -q -m "linked worktree drift"
printf 'unrelated canonical dirt\n' >"$REPO_20/unrelated.txt"
_write_repos_json "$TMPDIR_20" \
	"$(jq -n --arg path "$REPO_20" '{initialized_repos: [{slug: "x/caller-owned", path: $path, local_only: false}]}')"
mkdir -p "$TMPDIR_20/bin"
cat >"$TMPDIR_20/bin/git" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
	[[ "\$arg" == --path-format=* ]] && exit 129
done
exec "$REAL_GIT_20" "\$@"
EOF
chmod +x "$TMPDIR_20/bin/git"
json_row=$(cd "$LINKED_20" && HOME="$TMPDIR_20" AIDEVOPS_TEST_GIT_BIN="$TMPDIR_20/bin/git" bash "$HELPER" \
	--json --repo x/caller-owned --workflow issue-sync 2>/dev/null || true)
LINKED_ROOT_20=$(git -C "$LINKED_20" rev-parse --show-toplevel)
if [[ "$(printf '%s\n' "$json_row" | jq -r '.classification')" == "DRIFTED/CALLER" ]] &&
	[[ "$(printf '%s\n' "$json_row" | jq -r '.path')" == "$LINKED_ROOT_20" ]] &&
	[[ "$(printf '%s\n' "$json_row" | jq -r '.evidence.source')" == "caller-worktree" ]] &&
	[[ -f "$REPO_20/unrelated.txt" ]]; then
	_pass "repository-scoped check → Git 2.25-compatible linked-worktree evidence"
else
	_fail "repository-scoped check → caller-owned linked-worktree evidence" "json: $json_row"
fi
rm -rf "$TMPDIR_20"

# ─── Summary ────────────────────────────────────────────────────────────────

echo
if ((TESTS_FAILED == 0)); then
	printf '%bAll %d test(s) passed%b\n' "$_T_GREEN" "$TESTS_RUN" "$_T_RESET"
	exit 0
else
	printf '%b%d of %d test(s) failed%b\n' "$_T_RED" "$TESTS_FAILED" "$TESTS_RUN" "$_T_RESET"
	exit 1
fi
