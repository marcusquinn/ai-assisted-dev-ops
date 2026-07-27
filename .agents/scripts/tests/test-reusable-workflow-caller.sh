#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-reusable-workflow-caller.sh — Structural tests for the reusable workflow pattern (t2770)
#
# Issues: GH#20662 (issue-sync), GH#20727 (review-bot-gate)
#
# Scenarios covered (issue-sync — tests 1-8):
#   1. .github/workflows/issue-sync-reusable.yml exists and is valid YAML
#   2. Reusable workflow declares `on: workflow_call:` with expected inputs/secrets
#   3. .github/workflows/issue-sync.yml is a thin caller (uses: ./.github/workflows/...)
#   4. .agents/templates/workflows/issue-sync-caller.yml exists
#   5. Downstream caller template references marcusquinn/aidevops reusable path
#   6. Event guards in the reusable workflow accept both pull_request and pull_request_target
#   7. Every checkout of the caller repo is paired with a checkout of marcusquinn/aidevops
#      into __aidevops/ (so helpers resolve via __aidevops/.agents/scripts/*)
#   8. No residual bare .agents/scripts/ helper invocations in the reusable workflow
#
# Scenarios covered (review-bot-gate — tests 9-14, GH#20727):
#   9.  .github/workflows/review-bot-gate-reusable.yml exists
#  10.  Reusable workflow declares `on: workflow_call:` with aidevops_ref input
#  11.  .github/workflows/review-bot-gate.yml is a thin self-caller
#  12.  .agents/templates/workflows/review-bot-gate-caller.yml exists
#  13.  Downstream caller template references marcusquinn/aidevops reusable path
#  14.  Reusable workflow uses __aidevops/ path (runtime-fetched, no SHA pin)
#  GH#28316-A. Both callers and the reusable workflow share one eligibility matrix
#  GH#28316-B. Concurrency applies only to eligible caller jobs, preserving queued evaluators
#
# Strategy: Parse YAML + grep for structural invariants. No network calls, no GitHub API.
# Skips gracefully if python3 / yaml module missing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1

readonly _T_GREEN='\033[0;32m'
readonly _T_RED='\033[0;31m'
readonly _T_YELLOW='\033[0;33m'
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

_skip() {
	local name="$1"
	local msg="${2:-}"
	printf '%bSKIP%b %s' "$_T_YELLOW" "$_T_RESET" "$name"
	[[ -n "$msg" ]] && printf ' (%s)' "$msg"
	printf '\n'
	return 0
}

# ---------------------------------------------------------------------------
# Paths under test
# ---------------------------------------------------------------------------

REUSABLE_WF="$REPO_ROOT/.github/workflows/issue-sync-reusable.yml"
SELF_CALLER_WF="$REPO_ROOT/.github/workflows/issue-sync.yml"
DOWNSTREAM_TEMPLATE="$REPO_ROOT/.agents/templates/workflows/issue-sync-caller.yml"

# ---------------------------------------------------------------------------
# Test 1: Reusable workflow file exists
# ---------------------------------------------------------------------------

if [[ -f "$REUSABLE_WF" ]]; then
	_pass "reusable workflow file exists"
else
	_fail "reusable workflow file exists" "missing: $REUSABLE_WF"
fi

# ---------------------------------------------------------------------------
# Test 2: Reusable workflow is valid YAML and declares workflow_call
# ---------------------------------------------------------------------------

if ! command -v python3 >/dev/null 2>&1; then
	_skip "reusable workflow YAML parse" "python3 unavailable"
elif ! python3 -c "import yaml" 2>/dev/null; then
	_skip "reusable workflow YAML parse" "pyyaml unavailable"
else
	if [[ ! -f "$REUSABLE_WF" ]]; then
		_skip "reusable workflow YAML parse" "file missing"
	else
		# YAML parses cleanly, `on:` has `workflow_call:` key, inputs include `command`
		parse_result="$(python3 - "$REUSABLE_WF" <<'PYEOF' 2>&1
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
# YAML parses `on` as the boolean True (PyYAML quirk)
on = doc.get('on') or doc.get(True)
if not isinstance(on, dict):
    print("FAIL: `on:` is not a mapping"); sys.exit(1)
if 'workflow_call' not in on:
    print(f"FAIL: `on:` missing `workflow_call`. Keys: {list(on.keys())}"); sys.exit(1)
wc = on['workflow_call'] or {}
inputs = wc.get('inputs', {}) or {}
if 'command' not in inputs:
    print(f"FAIL: workflow_call.inputs missing `command`. Keys: {list(inputs.keys())}"); sys.exit(1)
print("OK")
PYEOF
)"
		if [[ "$parse_result" == "OK" ]]; then
			_pass "reusable workflow declares workflow_call with command input"
		else
			_fail "reusable workflow declares workflow_call with command input" "$parse_result"
		fi
	fi
fi

# ---------------------------------------------------------------------------
# Test 3: Self-caller (aidevops's own issue-sync.yml) uses the local reusable
# ---------------------------------------------------------------------------

if [[ -f "$SELF_CALLER_WF" ]]; then
	if grep -Eq "uses:\s*\./\.github/workflows/issue-sync-reusable\.yml" "$SELF_CALLER_WF"; then
		_pass "self-caller uses local reusable workflow"
	else
		_fail "self-caller uses local reusable workflow" \
			"expected 'uses: ./.github/workflows/issue-sync-reusable.yml' in $SELF_CALLER_WF"
	fi
else
	_fail "self-caller uses local reusable workflow" "missing: $SELF_CALLER_WF"
fi

# ---------------------------------------------------------------------------
# Test 4: Downstream caller template exists
# ---------------------------------------------------------------------------

if [[ -f "$DOWNSTREAM_TEMPLATE" ]]; then
	_pass "downstream caller template exists"
else
	_fail "downstream caller template exists" "missing: $DOWNSTREAM_TEMPLATE"
fi

# ---------------------------------------------------------------------------
# Test 5: Downstream caller references marcusquinn/aidevops reusable path
# ---------------------------------------------------------------------------

if [[ -f "$DOWNSTREAM_TEMPLATE" ]]; then
	if grep -Eq "uses:\s*marcusquinn/aidevops/\.github/workflows/issue-sync-reusable\.yml@" \
		"$DOWNSTREAM_TEMPLATE"; then
		_pass "downstream template references marcusquinn/aidevops reusable path"
	else
		_fail "downstream template references marcusquinn/aidevops reusable path" \
			"expected 'uses: marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml@<ref>' in $DOWNSTREAM_TEMPLATE"
	fi

	# Cross-account reusable workflows require explicit secret forwarding. Keep
	# SYNC_PAT available only to the reusable workflow's write paths.
	# shellcheck disable=SC2016
	if grep -qF 'SYNC_PAT: ${{ secrets.SYNC_PAT }}' "$DOWNSTREAM_TEMPLATE"; then
		_pass "downstream template explicitly forwards SYNC_PAT"
	else
		_fail "downstream template explicitly forwards SYNC_PAT" \
			"missing explicit SYNC_PAT forwarding for cross-account write paths"
	fi
fi

# ---------------------------------------------------------------------------
# Test 6: Event guards in reusable workflow accept both pull_request variants
# ---------------------------------------------------------------------------

if [[ -f "$REUSABLE_WF" ]]; then
	# Guards that reference only pull_request_target would break downstream
	# callers that chose pull_request for their security model.
	bare_pr_target_count=$(grep -cE "github\.event_name\s*==\s*'pull_request_target'(\s|$)" "$REUSABLE_WF" 2>/dev/null || true)
	[[ "$bare_pr_target_count" =~ ^[0-9]+$ ]] || bare_pr_target_count=0
	compound_guard_count=$(grep -cE "(github\.event_name\s*==\s*'pull_request_target'\s*\|\|\s*github\.event_name\s*==\s*'pull_request')|(github\.event_name\s*==\s*'pull_request'\s*\|\|\s*github\.event_name\s*==\s*'pull_request_target')" "$REUSABLE_WF" 2>/dev/null || true)
	[[ "$compound_guard_count" =~ ^[0-9]+$ ]] || compound_guard_count=0

	# The compound form is what we want. A bare pull_request_target guard without
	# the compound form is a regression (downstream pull_request callers would skip).
	# We allow bare mentions inside comments/docstrings by requiring the condition
	# guards (if:) to use the compound form.
	if_guard_bare=$(grep -cE "^\s*if:.*github\.event_name\s*==\s*'pull_request_target'" "$REUSABLE_WF" 2>/dev/null || true)
	[[ "$if_guard_bare" =~ ^[0-9]+$ ]] || if_guard_bare=0
	if_guard_compound=$(grep -cE "^\s*if:.*github\.event_name\s*==\s*'pull_request_target'.*\|\|.*github\.event_name\s*==\s*'pull_request'" "$REUSABLE_WF" 2>/dev/null || true)
	[[ "$if_guard_compound" =~ ^[0-9]+$ ]] || if_guard_compound=0

	if (( if_guard_bare == if_guard_compound )); then
		_pass "all pull_request_target guards include pull_request fallback"
	else
		_fail "all pull_request_target guards include pull_request fallback" \
			"bare guards=$if_guard_bare, compound guards=$if_guard_compound in $REUSABLE_WF"
	fi
fi

# ---------------------------------------------------------------------------
# Test 7: Framework-script paths use __aidevops/ prefix (runtime-fetched)
# ---------------------------------------------------------------------------

if [[ -f "$REUSABLE_WF" ]]; then
	# Count references to .agents/scripts/ that are NOT preceded by __aidevops/
	# (allow references in comments/paths-filter lists — restrict to `bash` / `run:` invocations)
	stray=$(grep -nE "(bash|run:)\s+\.agents/scripts/" "$REUSABLE_WF" 2>/dev/null || true)
	if [[ -z "$stray" ]]; then
		_pass "no bare .agents/scripts/ invocations (runtime-fetched via __aidevops/)"
	else
		_fail "no bare .agents/scripts/ invocations" "found:
$stray"
	fi

	# Sanity: at least one __aidevops/.agents/scripts/ invocation should exist
	aidevops_refs=$(grep -cE "__aidevops/\.agents/scripts/" "$REUSABLE_WF" 2>/dev/null || true)
	[[ "$aidevops_refs" =~ ^[0-9]+$ ]] || aidevops_refs=0
	if (( aidevops_refs > 0 )); then
		_pass "reusable workflow invokes framework scripts via __aidevops/ ($aidevops_refs references)"
	else
		_fail "reusable workflow invokes framework scripts via __aidevops/" \
			"no __aidevops/.agents/scripts/ references found"
	fi
fi

# ---------------------------------------------------------------------------
# Test 8: Every caller-checkout is paired with a framework checkout
# ---------------------------------------------------------------------------

if [[ -f "$REUSABLE_WF" ]] && command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
	pairing_result="$(python3 - "$REUSABLE_WF" <<'PYEOF' 2>&1
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {}) or {}
bad = []
for jname, jdef in jobs.items():
    if not isinstance(jdef, dict):
        continue
    steps = jdef.get('steps', []) or []
    # Find checkouts
    co_steps = []
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        uses = step.get('uses', '') or ''
        if uses.startswith('actions/checkout@'):
            with_ = step.get('with', {}) or {}
            repo = (with_.get('repository') or '').strip()
            path = (with_.get('path') or '').strip()
            co_steps.append((i, repo, path))
    # Jobs that do any work with framework scripts must have at least one
    # framework checkout (configured aidevops repository, path: __aidevops)
    job_yaml = yaml.safe_dump(jdef)
    needs_framework = '__aidevops/.agents/scripts/' in job_yaml
    if not needs_framework:
        continue
    has_framework_checkout = any(
        (('aidevops_repository' in r or r == 'marcusquinn/aidevops') and p == '__aidevops')
        for (_, r, p) in co_steps
    )
    if not has_framework_checkout:
        bad.append(jname)
if bad:
    print(f"FAIL: jobs use __aidevops/ but lack framework checkout: {bad}")
    sys.exit(1)
print("OK")
PYEOF
)"
	if [[ "$pairing_result" == "OK" ]]; then
		_pass "every job using framework scripts checks out marcusquinn/aidevops into __aidevops/"
	else
		_fail "every job using framework scripts checks out marcusquinn/aidevops into __aidevops/" \
			"$pairing_result"
	fi
else
	_skip "framework-checkout pairing" "yaml unavailable"
fi

# ---------------------------------------------------------------------------
# review-bot-gate tests (GH#20727)
# ---------------------------------------------------------------------------

RBG_REUSABLE_WF="$REPO_ROOT/.github/workflows/review-bot-gate-reusable.yml"
RBG_SELF_CALLER_WF="$REPO_ROOT/.github/workflows/review-bot-gate.yml"
RBG_DOWNSTREAM_TEMPLATE="$REPO_ROOT/.agents/templates/workflows/review-bot-gate-caller.yml"

# ---------------------------------------------------------------------------
# Test 9: Reusable review-bot-gate workflow file exists
# ---------------------------------------------------------------------------

if [[ -f "$RBG_REUSABLE_WF" ]]; then
	_pass "review-bot-gate reusable workflow file exists"
else
	_fail "review-bot-gate reusable workflow file exists" "missing: $RBG_REUSABLE_WF"
fi

# ---------------------------------------------------------------------------
# Review gate eligibility/concurrency matrix (GH#28316)
# ---------------------------------------------------------------------------

if [[ ! -f "$RBG_REUSABLE_WF" || ! -f "$RBG_SELF_CALLER_WF" || ! -f "$RBG_DOWNSTREAM_TEMPLATE" ]]; then
	_skip "review-bot eligibility and job concurrency matrix" "workflow file missing"
elif ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" 2>/dev/null; then
	_skip "review-bot eligibility and job concurrency matrix" "python3 or pyyaml unavailable"
else
	if python3 - "$RBG_SELF_CALLER_WF" "$RBG_DOWNSTREAM_TEMPLATE" "$RBG_REUSABLE_WF" <<'PYEOF'
import re
import sys
import yaml


def load(path):
    with open(path) as stream:
        return yaml.safe_load(stream)


def normalize(expression):
    return re.sub(r"\s+", " ", expression or "").strip()


self_caller, downstream, reusable = [load(path) for path in sys.argv[1:]]
callers = (("self", self_caller), ("downstream", downstream))
caller_expressions = []
for name, workflow in callers:
    if "concurrency" in workflow:
        print(f"FAIL: {name} caller retains workflow-level concurrency")
        sys.exit(1)
    gate = (workflow.get("jobs") or {}).get("gate") or {}
    concurrency = gate.get("concurrency") or {}
    if concurrency.get("cancel-in-progress") is not False:
        print(f"FAIL: {name} caller gate must preserve active evaluators")
        sys.exit(1)
    if "review-bot-gate-" not in (concurrency.get("group") or ""):
        print(f"FAIL: {name} caller gate lacks per-PR concurrency")
        sys.exit(1)
    caller_expressions.append(normalize(gate.get("if")))

reusable_job = (reusable.get("jobs") or {}).get("review-bot-gate") or {}
expressions = caller_expressions + [normalize(reusable_job.get("if"))]
if not expressions[0] or len(set(expressions)) != 1:
    print("FAIL: self, downstream, and reusable eligibility expressions drifted")
    sys.exit(1)

expression = expressions[0]
supported_actors = [
    "coderabbitai",
    "coderabbitai[bot]",
    "gemini-code-assist",
    "gemini-code-assist[bot]",
    "augment-code",
    "augment-code[bot]",
    "augmentcode",
    "augmentcode[bot]",
    "copilot",
    "copilot[bot]",
    "github-actions[bot]",
]
fixtures = [
    ("pull_request", "human", True, None, True),
    ("pull_request_review", "human", True, None, False),
    ("pull_request_review_comment", "copilot[bot]", True, 99, False),
    ("issue_comment", "gemini-code-assist[bot]", False, None, False),
    ("issue_comment", "human", True, None, False),
]
for actor in supported_actors:
    fixtures.extend([
        ("pull_request_review", actor, True, None, True),
        ("pull_request_review_comment", actor, True, None, True),
        ("pull_request_review_comment", actor, True, 99, False),
        ("issue_comment", actor, True, None, True),
    ])


def evaluate(event_name, actor, is_pr, reply_id):
    candidate = expression
    candidate = re.sub(r"\bnull\b", "None", candidate)
    replacements = {
        "github.event.comment.in_reply_to_id": repr(reply_id),
        "github.event.issue.pull_request": repr(is_pr),
        "github.event_name": repr(event_name),
        "github.actor": repr(actor),
        "&&": "and",
        "||": "or",
    }
    for source, target in replacements.items():
        candidate = candidate.replace(source, target)
    if re.search(r"[^A-Za-z0-9_\s\[\]'\"().=-]", candidate):
        raise ValueError(f"unsupported eligibility token: {candidate}")
    return bool(eval(candidate, {"__builtins__": {}}, {}))


for fixture in fixtures:
    actual = evaluate(*fixture[:4])
    if actual is not fixture[4]:
        print(f"FAIL: eligibility fixture {fixture[:4]} => {actual}, expected {fixture[4]}")
        sys.exit(1)

# GitHub permits one active and one pending run per concurrency group. Simulate
# an eligible evaluator followed by replacement noise ending in an inline reply:
# only the evaluator may enter the job-level group, so it remains able to publish
# the exact-head status from the reusable workflow's always() status step.
burst = [
    ("pull_request", "human", True, None, True),
    ("issue_comment", "human", True, None, False),
    ("pull_request_review_comment", "copilot[bot]", True, 99, False),
]
admitted = [fixture for fixture in burst if evaluate(*fixture[:4])]
if len(admitted) != 1 or admitted[0] != burst[0]:
    print(f"FAIL: replacement burst admitted ineligible events: {admitted}")
    sys.exit(1)
status_steps = [
    step for step in (reusable_job.get("steps") or [])
    if step.get("name") == "Post review-bot-gate commit status"
]
if len(status_steps) != 1 or status_steps[0].get("if") != "always()":
    print("FAIL: eligible evaluator does not retain an always-run exact-head status publisher")
    sys.exit(1)
PYEOF
	then
		_pass "review-bot eligibility precedes durable per-PR job concurrency"
	else
		_fail "review-bot eligibility precedes durable per-PR job concurrency" \
			"matrix fixture failed; see Python output above"
	fi
fi

# ---------------------------------------------------------------------------
# Test 10: Reusable review-bot-gate workflow declares workflow_call with aidevops_ref input
# ---------------------------------------------------------------------------

if ! command -v python3 >/dev/null 2>&1; then
	_skip "review-bot-gate reusable workflow YAML parse" "python3 unavailable"
elif ! python3 -c "import yaml" 2>/dev/null; then
	_skip "review-bot-gate reusable workflow YAML parse" "pyyaml unavailable"
else
	if [[ ! -f "$RBG_REUSABLE_WF" ]]; then
		_skip "review-bot-gate reusable workflow YAML parse" "file missing"
	else
		parse_result="$(python3 - "$RBG_REUSABLE_WF" <<'PYEOF' 2>&1
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
on = doc.get('on') or doc.get(True)
if not isinstance(on, dict):
    print("FAIL: `on:` is not a mapping"); sys.exit(1)
if 'workflow_call' not in on:
    print(f"FAIL: `on:` missing `workflow_call`. Keys: {list(on.keys())}"); sys.exit(1)
wc = on['workflow_call'] or {}
inputs = wc.get('inputs', {}) or {}
for required_input in ('aidevops_repository', 'aidevops_ref'):
    if required_input not in inputs:
        print(f"FAIL: workflow_call.inputs missing `{required_input}`. Keys: {list(inputs.keys())}"); sys.exit(1)
print("OK")
PYEOF
)"
		if [[ "$parse_result" == "OK" ]]; then
			_pass "review-bot-gate reusable workflow declares coupled repository/ref inputs"
		else
			_fail "review-bot-gate reusable workflow declares workflow_call with aidevops_ref input" "$parse_result"
		fi
	fi
fi

# ---------------------------------------------------------------------------
# Test 11: Self-caller (aidevops's own review-bot-gate.yml) uses local reusable
# ---------------------------------------------------------------------------

if [[ -f "$RBG_SELF_CALLER_WF" ]]; then
	if grep -Eq "uses:\s*\./\.github/workflows/review-bot-gate-reusable\.yml" "$RBG_SELF_CALLER_WF"; then
		_pass "review-bot-gate self-caller uses local reusable workflow"
	else
		_fail "review-bot-gate self-caller uses local reusable workflow" \
			"expected 'uses: ./.github/workflows/review-bot-gate-reusable.yml' in $RBG_SELF_CALLER_WF"
	fi
else
	_fail "review-bot-gate self-caller uses local reusable workflow" "missing: $RBG_SELF_CALLER_WF"
fi

# ---------------------------------------------------------------------------
# Test 12: Downstream caller template exists
# ---------------------------------------------------------------------------

if [[ -f "$RBG_DOWNSTREAM_TEMPLATE" ]]; then
	_pass "review-bot-gate downstream caller template exists"
else
	_fail "review-bot-gate downstream caller template exists" "missing: $RBG_DOWNSTREAM_TEMPLATE"
fi

# ---------------------------------------------------------------------------
# Test 13: Downstream caller references marcusquinn/aidevops reusable path and uses secrets: inherit
# ---------------------------------------------------------------------------

if [[ -f "$RBG_DOWNSTREAM_TEMPLATE" ]]; then
	if grep -Eq "uses:\s*marcusquinn/aidevops/\.github/workflows/review-bot-gate-reusable\.yml@" \
		"$RBG_DOWNSTREAM_TEMPLATE"; then
		_pass "review-bot-gate downstream template references marcusquinn/aidevops reusable path"
	else
		_fail "review-bot-gate downstream template references marcusquinn/aidevops reusable path" \
			"expected 'uses: marcusquinn/aidevops/.github/workflows/review-bot-gate-reusable.yml@<ref>' in $RBG_DOWNSTREAM_TEMPLATE"
	fi

	if grep -Eq "secrets:\s*inherit" "$RBG_DOWNSTREAM_TEMPLATE"; then
		_pass "review-bot-gate downstream template uses 'secrets: inherit'"
	else
		_fail "review-bot-gate downstream template uses 'secrets: inherit'" \
			"missing 'secrets: inherit' in $RBG_DOWNSTREAM_TEMPLATE"
	fi
fi

# ---------------------------------------------------------------------------
# Test 14: Reusable review-bot-gate workflow uses __aidevops/ (no SHA pin)
# ---------------------------------------------------------------------------

if [[ -f "$RBG_REUSABLE_WF" ]]; then
	# The old pattern hard-pinned a SHA and used path: .aidevops-helper
	# GH#20727 fix: runtime-fetched into __aidevops/ using inputs.aidevops_ref
	if grep -qE "path:\s*__aidevops" "$RBG_REUSABLE_WF"; then
		_pass "review-bot-gate reusable workflow fetches helper into __aidevops/"
	else
		_fail "review-bot-gate reusable workflow fetches helper into __aidevops/" \
			"expected 'path: __aidevops' in the checkout step — GH#20727 pattern not applied"
	fi

	# Confirm no SHA pin on the aidevops checkout (ref uses inputs.aidevops_ref)
	if grep -qE "ref:\s*\\\$\{\{[[:space:]]*inputs\.aidevops_ref" "$RBG_REUSABLE_WF"; then
		_pass "review-bot-gate reusable workflow uses inputs.aidevops_ref (not a hard-coded SHA)"
	else
		_fail "review-bot-gate reusable workflow uses inputs.aidevops_ref" \
			"expected 'ref: \${{ inputs.aidevops_ref ... }}' — SHA pin not eliminated"
	fi

	if grep -qF "repository: \${{ inputs.aidevops_repository || 'marcusquinn/aidevops' }}" "$RBG_REUSABLE_WF"; then
		_pass "review-bot-gate reusable workflow uses inputs.aidevops_repository"
	else
		_fail "review-bot-gate reusable workflow uses inputs.aidevops_repository" \
			"expected helper checkout repository to use the provenance input"
	fi

	# Helper path must not reference .aidevops-helper/ in functional (non-comment) lines.
	# Comments mentioning the old path for historical context are allowed.
	if grep -v "^\s*#" "$RBG_REUSABLE_WF" | grep -q ".aidevops-helper"; then
		_fail "review-bot-gate reusable workflow has no functional .aidevops-helper/ reference" \
			"found stale .aidevops-helper/ path in non-comment line — GH#20727 migration incomplete"
	else
		_pass "review-bot-gate reusable workflow has no functional .aidevops-helper/ reference"
	fi
fi

# ---------------------------------------------------------------------------
# Tests 15-17: GH#20807 — closing-keyword-only semantics in sync-on-pr-merge
# Verifies the issue-sync-reusable.yml extract step uses word-boundary regex
# for LINKED_ISSUES and that FOR_REF_ISSUES is passed to Apply closing hygiene.
# ---------------------------------------------------------------------------

# Test 15: LINKED_ISSUES regex uses \b word-boundary anchors
if [[ -f "$REUSABLE_WF" ]]; then
	if grep -qE "grep.*\\\\b.*close\[ds\]\?.*resolve\[ds\]\?" "$REUSABLE_WF" 2>/dev/null; then
		_pass "LINKED_ISSUES regex uses \\b word-boundary anchors (GH#20807)"
	else
		_fail "LINKED_ISSUES regex uses \\b word-boundary anchors (GH#20807)" \
			"expected '\\b(close[ds]?|...) pattern in LINKED_ISSUES extraction — without \\b, substrings like 'discloses' match 'closes'"
	fi
fi

# Test 16: FOR_REF_ISSUES is passed to the Apply closing hygiene step
if [[ -f "$REUSABLE_WF" ]]; then
	# The env var should appear in the Apply closing hygiene step env block
	if grep -qE "FOR_REF_ISSUES:.*steps\.extract\.outputs\.for_ref_issues" "$REUSABLE_WF" 2>/dev/null; then
		_pass "FOR_REF_ISSUES passed to Apply closing hygiene step (GH#20807)"
	else
		_fail "FOR_REF_ISSUES passed to Apply closing hygiene step (GH#20807)" \
			"expected 'FOR_REF_ISSUES: \${{ steps.extract.outputs.for_ref_issues }}' in Apply closing hygiene env — without this, Ref/For issues could receive status:done"
	fi
fi

# Test 17: Apply closing hygiene step has explicit FOR_REF_ISSUES veto guard
if [[ -f "$REUSABLE_WF" ]]; then
	if grep -qE "grep.*-xv.*_ref_num|for _ref_num in.*FOR_REF" "$REUSABLE_WF" 2>/dev/null; then
		_pass "Apply closing hygiene has FOR_REF_ISSUES veto guard (GH#20807)"
	else
		_fail "Apply closing hygiene has FOR_REF_ISSUES veto guard (GH#20807)" \
			"expected 'for _ref_num in \$FOR_REF_ISSUES' filter in Apply closing hygiene — this guard prevents Ref/For issues from receiving status:done even if the keyword regex false-positives"
	fi
fi

# ---------------------------------------------------------------------------
# Tests 18-19: GH#20967/GH#27615 — caller permission ceilings
# Repos with default_workflow_permissions: read cause startup_failure unless
# callers grant every permission requested by their reusable workflow jobs.
# ---------------------------------------------------------------------------

# Test 18: issue-sync caller ceiling equals the union of reusable job permissions
if [[ ! -f "$DOWNSTREAM_TEMPLATE" || ! -f "$REUSABLE_WF" ]]; then
	_skip "issue-sync caller permissions equal reusable job union" "workflow or template file missing"
elif ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" 2>/dev/null; then
	_skip "issue-sync caller permissions equal reusable job union" "python3 or pyyaml unavailable"
else
	permission_result="$(python3 - "$REUSABLE_WF" "$DOWNSTREAM_TEMPLATE" <<'PYEOF' 2>&1
import sys
import yaml

with open(sys.argv[1]) as reusable_file:
    reusable = yaml.safe_load(reusable_file)
with open(sys.argv[2]) as caller_file:
    caller = yaml.safe_load(caller_file)
if not isinstance(reusable, dict):
    print("FAIL: reusable workflow root must be a mapping")
    sys.exit(1)
if not isinstance(caller, dict):
    print("FAIL: caller workflow root must be a mapping")
    sys.exit(1)

levels = {"none": 0, "read": 1, "write": 2}

def permission_union(workflow):
    top_permissions = workflow.get("permissions", {}) or {}
    if not isinstance(top_permissions, dict):
        print("FAIL: reusable top-level permissions must be an explicit mapping")
        sys.exit(1)
    required = {}
    for job_name, job in (workflow.get("jobs", {}) or {}).items():
        if not isinstance(job, dict):
            continue
        permissions = job.get("permissions") if "permissions" in job else top_permissions
        permissions = permissions or {}
        if not isinstance(permissions, dict):
            print(f"FAIL: job {job_name} permissions must be an explicit mapping")
            sys.exit(1)
        for permission, level in permissions.items():
            if level not in levels:
                print(f"FAIL: unsupported permission level {permission}={level}")
                sys.exit(1)
            # An omitted caller key already means none, so only granted access
            # contributes to the required ceiling.
            if levels[level] > levels.get(required.get(permission, "none"), 0):
                required[permission] = level
    return required

fixtures = [
    ({"permissions": {"actions": "read"}, "jobs": {"inherited": {}}}, {"actions": "read"}),
    ({"jobs": {"disabled": {"permissions": {"actions": "none"}}}}, {}),
]
for fixture, expected in fixtures:
    actual = permission_union(fixture)
    if actual != expected:
        print(f"FAIL: permission-union fixture={actual}; expected={expected}")
        sys.exit(1)

required = permission_union(reusable)

granted = caller.get("permissions", {}) or {}
if not isinstance(granted, dict):
    print("FAIL: caller permissions must be an explicit mapping")
    sys.exit(1)
if granted != required:
    print(f"FAIL: caller={granted}; required_union={required}")
    sys.exit(1)
print("OK")
PYEOF
)"
	if [[ "$permission_result" == "OK" ]]; then
		_pass "issue-sync caller permissions equal reusable job union (GH#27615)"
	else
		_fail "issue-sync caller permissions equal reusable job union (GH#27615)" \
			"$permission_result"
	fi
fi

# Test 19: review-bot-gate-caller.yml declares a permissions: block
if [[ -f "$RBG_DOWNSTREAM_TEMPLATE" ]]; then
	if grep -qE "^permissions:" "$RBG_DOWNSTREAM_TEMPLATE" 2>/dev/null; then
		_pass "review-bot-gate-caller.yml declares top-level permissions: block (GH#20967)"
	else
		_fail "review-bot-gate-caller.yml declares top-level permissions: block (GH#20967)" \
			"missing 'permissions:' in $RBG_DOWNSTREAM_TEMPLATE — repos with default_workflow_permissions: read will get startup_failure"
	fi
else
	_skip "review-bot-gate-caller.yml permissions check" "template file missing"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
if (( TESTS_FAILED == 0 )); then
	printf '%bAll %d test(s) passed%b\n' "$_T_GREEN" "$TESTS_RUN" "$_T_RESET"
	exit 0
else
	printf '%b%d of %d test(s) failed%b\n' "$_T_RED" "$TESTS_FAILED" "$TESTS_RUN" "$_T_RESET"
	exit 1
fi
